# guest の起動の処理を直す

Issue #22 では、tctiSH の guest の起動の処理 (`assets/overlay/init`) を直し、`docker exec` と、Docker の既定の置き場 (`/var/lib/docker`) が使えるかを確かめました。kernel は [Issue #20 の結果](README.md) で作った `bzImage` を、変更せずに使っています。

## 直したところ

`init-docker.patch` は、tctiSH の `76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4` の `assets/overlay/init` に当てる差分です。変更は2つです。

| 変更 | 内容 |
| --- | --- |
| `/var/lib/docker` | 永続の ext4 ディスクの `docker` ディレクトリを、guest の `/var/lib/docker` に bind mount する |
| root の切り替え | `exec chroot` だけで切り替える処理をやめ、union を `/` に `mount --move` してから `chroot .` する |

もとの init は union を `/var/tcti-rootfs/rw-union` に作り、`chroot` だけで入っていました。`/var/lib/docker` が overlay の上にあると、Docker の overlayfs は upperdir に使えません。

## 固定した入力

| 入力 | 値 |
| --- | --- |
| tctiSH | `76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4` (`assets/overlay/init` の SHA-256 は `451de1144e73347801c3f353aef4a9868b839e092904805dfebf5c28e4f60c39`) |
| `bzImage` | Issue #20 でビルドしたもの。SHA-256 は `87c1742cd9d40508fa351b3a107378a4352f8aa0e8458addd2e0c25e0c407116` |
| `initrd.img` | tctiSH の `assets/initrd.img` に、直した `init` だけの cpio を連結したもの |
| QEMU | Issue #20 で Mac 向けにビルドした tctiSH の fork (`tcti` backend) |
| Docker | guest で `apk add docker` した 29.9.1 |

kernel と rootfs はビルドし直していないので、Linux の機械は使っていません。

## initrd の作り方

kernel は、連結した initramfs の後ろの file で前の file を上書きします。`init` だけを入れた cpio を、もとの `initrd.img` の後ろに足しました。

```sh
mkdir pack && cp init pack/init && chmod 755 pack/init
(cd pack && echo init | bsdtar --format newc --uid 0 --gid 0 -cf - -T -) | gzip -9n > patch.cpio.gz
cat initrd.img patch.cpio.gz > initrd-new.img
```

## 試した手順

guest は、Mac の QEMU で `-m 2G -smp 4`、disk は `empty.qcow` の複製で起動しました。app の既定は 1 GiB です。kernel に netfilter、bridge、veth が無いので、dockerd には `--iptables=false --bridge=none` を付け、container は `--network none` で起動しました。保存先の指定 (`--data-root`、`-g`、`daemon.json`) は、どの場合も付けていません。

```sh
apk add docker
dockerd --iptables=false --bridge=none &
docker pull alpine:3.22
docker run -d --name t1 --network none alpine:3.22 sleep 600
docker exec t1 cat /etc/os-release
```

## 結果

3つの init で同じ手順を試しました。

| init | `docker run` | `docker exec t1 cat /etc/os-release` |
| --- | --- | --- |
| もとの init | 失敗 | container が起動しないので実行できない |
| bind mount だけ (`chroot` のまま) | 成功 | 成功するが、container の中ではなく guest の root の内容が返る |
| 直した init (bind mount と `mount --move`) | 成功 | container の中の内容が返る |

もとの init では、`docker pull` は通りましたが、container の起動が失敗しました。

```text
docker: Error response from daemon: failed to mount /tmp/containerd-mount...: mount source: "overlay", target: "/tmp/containerd-mount...", fstype: overlay, ... err: invalid argument
[   77.427531] overlay: filesystem on /var/lib/docker/containerd/daemon/io.containerd.snapshotter.v1.overlayfs/snapshots/2/work not supported as upperdir
```

bind mount だけの init では、container は起動しましたが、`docker exec` は guest の root を見ました。`VERSION_ID` が、container の `3.22.6` ではなく guest の `3.25.0_alpha20260805` で、`ls /` に guest の `init`、`ios_host`、`var/tcti-rootfs` が出ました。

直した init の結果です。

```text
 Storage Driver: overlayfs
 Docker Root Dir: /var/lib/docker
$ docker exec t1 cat /etc/os-release
NAME="Alpine Linux"
ID=alpine
VERSION_ID=3.22.6
PRETTY_NAME="Alpine Linux v3.22"
$ docker exec t1 ls /
bin dev etc home lib media mnt opt proc root run sbin srv sys tmp usr var
$ df /var/lib/docker
/dev/vda             205314024    299924 194511956   0% /var/lib/docker
```

guest を `poweroff` してもう一度起動すると、`alpine:3.22` の image が残っていました。`docker start t1` の後の `docker exec` と、`docker run --rm` も通りました。

## 試していないこと

- Docker の既定のネットワークと `docker compose` は、kernel に netfilter、bridge、veth が要るので、Issue #21 と #23 で扱います。この検証では `--network none` だけです。
- iPad の実機では試していません。
- app の既定の 1 GiB のメモリでは試していません。
- 起動を繰り返したときの `/var/run/docker.pid` は、guest の `/var/run` が永続の overlay の上にあるため、前の起動の file が残ります。2回目の起動で、同じ PID の process が動いていると dockerd が `process with PID ... is still running` で始まりませんでした。この検証では file を消して回避しました。直してはいません。
