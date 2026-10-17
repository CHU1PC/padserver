# guest の kernel にネットワークの機能を足す

Issue #21 では、[#20 で再ビルドした kernel](README.md) に netfilter、bridge、veth を足し、Docker を既定のネットワークのまま起動できるかを確かめました。

## 結論

kernel の設定を [network.config](network.config) の 52 個の symbol を足すと、Docker の既定の bridge ネットワークが動きました。`docker run -p 8080:80 nginx:alpine` に guest の中から `curl` が通り、container から外へも出られました。

ただし、これは Linux x86_64 上の upstream QEMU 10.0 (KVM) で確かめた結果です。tctiSH の QEMU fork (TCTI) と iPad の実機では試していません。

## 固定した入力

| 入力 | 値 |
| --- | --- |
| tctiSH | `76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4` (#20 と同じ) |
| Linux | `6.18.53` (#20 と同じ) |
| kernel の設定 | `assets/kernel/tctish.config` の末尾に `network.config` を足したもの |
| toolchain | #20 と同じ Nix 環境 (`nixos/nix` の image も同じ digest) |
| 出来た `bzImage` | 9.5M、SHA-256 は `42f36070d9045be2131f9e0c1e42656ee8f048f6878eafdbdf0402131602b87f` |
| 比べた元の `bzImage` | tctiSH が同梱するもの、SHA-256 は `1cb0b9bd148355aadce20c0075592700a817af855cd225d0dd6850c0494e8a53` |
| guest の Docker | Alpine の `docker` 29.9.1 と `iptables`、`ip6tables`、`curl` を `apk add` で入れた |

`build_kernel.sh` は、足した symbol がすべて解決された設定に入ったかを検証します。最初の試行では `CONFIG_NF_CONNTRACK_NETLINK` (6.18 では `NF_CT_NETLINK` に改名) と `CONFIG_BRIDGE_VLAN_FILTERING` (`VLAN_8021Q` が要る) が黙って落ち、検証が失敗しました。直した版でビルドは通りました。

## 足した設定

[network.config](network.config) に全部あります。分類は次の通りです。

| 分類 | symbol |
| --- | --- |
| netfilter の土台 | `NETFILTER`、`NETFILTER_ADVANCED`、`NETFILTER_NETLINK`、`NF_CONNTRACK`、`NF_CT_NETLINK`、`NF_CONNTRACK_MARK`、`NF_NAT` |
| nftables | `NF_TABLES`、`NF_TABLES_INET`、`NF_TABLES_IPV4`、`NF_TABLES_IPV6`、`NFT_CT`、`NFT_NAT`、`NFT_MASQ`、`NFT_REDIR`、`NFT_REJECT`、`NFT_COMPAT` |
| xtables と iptables | `NETFILTER_XTABLES`、`NETFILTER_XTABLES_LEGACY`、`NETFILTER_XT_*` の MARK、CONNMARK、NAT、MASQUERADE、REDIRECT、CHECKSUM、TCPMSS、ADDRTYPE、CONNTRACK、COMMENT、MULTIPORT、STATE、`IP_NF_*` と `IP6_NF_*` |
| bridge と veth | `BRIDGE`、`BRIDGE_NETFILTER`、`VLAN_8021Q`、`BRIDGE_VLAN_FILTERING`、`VETH` |

この kernel は module を読み込めないので、すべて組み込みにしました。`NET_NS` などの namespace と cgroup は、元の設定で既に有効です。

どの symbol が必須かは切り分けていません。Docker の check-config が挙げる項目と、Alpine の `iptables` が使う nftables 側を、まとめて足しました。Alpine の `iptables` は nft 版で、`nft` コマンドは入っていません。このため、Docker は `iptables` を呼びました。

## 手順

ビルドは Linux x86_64 (WSL) の Docker で、#20 と同じ command を使いました。CPU は8個、メモリは12 GiB に制限しました。

```sh
cat network.config >> assets/kernel/tctish.config
DOCKER_CONFIG="$empty_docker_config" docker run --rm --cpus=8 --memory=12g \
  -v "$build_checkout:/src" -w /src \
  -e 'NIX_CONFIG=experimental-features = nix-command flakes' \
  nixos/nix@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c \
  nix develop path:/src/assets/kernel -c env TCTISH_TOOLCHAIN=1 bash /src/assets/build_kernel.sh
```

```text
Kernel: arch/x86/boot/bzImage is ready  (#1)
==> wrote assets/bzImage (9.5M)
==> kernel release: 6.18.53tctish
```

guest の起動は、Mac ではなく WSL の Docker の中の `alpine` に入れた QEMU 10.0 で行いました。`-M pc -cpu host -accel kvm`、メモリ 1 GiB、CPU 4個、`-netdev user,net=192.168.100.0/24` で、tctiSH の `boot_guest.sh` と同じ `bzImage`、`initrd.img`、`empty.qcow` を使いました。

## 結果

### 元の kernel では dockerd が起動しない

同梱の `bzImage` で `apk add docker iptables` の後に `dockerd` を起動した結果です。

```text
failed to start daemon: Error initializing network controller: error obtaining controller instance: failed to register "bridge" driver: failed to create NAT chain DOCKER: iptables failed: iptables --wait -t nat -N DOCKER: iptables: Failed to initialize nft: Protocol not supported
 (exit status 1)
```

### 新しい kernel では dockerd が起動する

```text
$ uname -a
Linux tctiSH 6.18.53tctish #1 SMP Tue Jan  1 00:00:00 UTC 1980 x86_64 Linux
$ docker info | grep -E "Server Version|Storage Driver"
 Server Version: 29.9.1
 Storage Driver: overlayfs
$ iptables -t nat -S
-N DOCKER
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
-A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER
-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
```

`docker0` と `veth*` が作られ、`-p 8080:80` の DNAT の規則も入りました。

### 終わりの確認

下の2つは、`ip link set lo up` の後の結果です (次の節を参照).

```text
$ docker run -d -p 8080:80 --name web nginx:alpine
$ docker ps
CONTAINER ID   IMAGE          COMMAND                  CREATED         STATUS         PORTS                  NAMES
3c8a9ab248e1   nginx:alpine   "/docker-entrypoint.…"   4 seconds ago   Up 3 seconds   0.0.0.0:8080->80/tcp   web

$ curl -sS -i http://127.0.0.1:8080/ | head -3
HTTP/1.1 200 OK
Server: nginx/1.31.7
Date: Sat, 17 Oct 2026 14:41:40 GMT

$ docker run --rm alpine:latest wget -q -S -O /dev/null http://example.com 2>&1 | head -2
  HTTP/1.1 200 OK
  Date: Sat, 17 Oct 2026 14:41:40 GMT
```

次の項目も同じ guest で確かめました。

| 確認 | 結果 |
| --- | --- |
| guest の eth0 の IP の 8080 番への `curl` | `HTTP/1.1 200 OK` |
| container の bridge 上の IP への `curl` | `200` |
| container の中から `ping -c 2 1.1.1.1` | 2 packets 受信、損失 0% |
| container の中から `nslookup example.com` | 名前が引けた |
| `docker network create n1` と、同じ network の別 container から `wget http://srv/` | nginx の HTML が返った |

## 見つかった別の問題

この検証で、kernel とは別の問題を2つ見つけました。どちらも guest の起動の処理 (Issue #22) の範囲で、ここでは直していません。

| 問題 | 症状 | この検証での回避 |
| --- | --- | --- |
| guest の root が overlay で、Docker の置き場も overlay の上になる | `docker run` が `overlay: filesystem on ... not supported as upperdir` で失敗する. `/var/tcti-rootfs/rw-ios/` の下に置いても同じだった | `dockerd --data-root` を tmpfs (900 MiB) に向けた. 再起動で消え、容量はメモリに縛られる |
| loopback (`lo`) が DOWN のまま | `curl http://127.0.0.1:8080/` が timeout する. 何も動いていない plain な listener でも同じ | `ip link set lo up` を手で実行した |

## 試していないこと

- tctiSH の QEMU fork (TCTI) での起動と、iPad の実機での動作。QEMU 10.0 の KVM での結果なので、速度と、emulate 時の挙動は別である。
- `docker exec` と `docker compose`。
- 再起動をまたいだ状態。dockerd は毎回手で起動した。
- IPv6 の container。`ip6tables` の側は、symbol を足しただけで動作は確かめていない。
- `network.config` の各 symbol が必須かどうか。
