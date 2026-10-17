# Mac でビルドした image を guest の Docker へ送る

Issue #25 では、Mac で `--platform linux/amd64` を付けてビルドした image を書き出し、Mac 上の QEMU の guest にある Docker へ読み込めるかと、その時間を測りました。tailnet 越しの転送と iPad 実機は、この検証には含めていません。

## 環境

| 項目 | 値 |
| --- | --- |
| guest の kernel と initrd | Issue #20 (`spikes/007-guest-rebuild/`) でビルドした `bzImage` と、tctiSH の `initrd.img` |
| QEMU | tctiSH が固定する fork の TCTI backend (QEMU 11.1.2)。guest は 4 CPU、メモリ 1GB |
| guest の Docker | 空の `empty.qcow` から起動した Alpine で `apk add docker` を実行して入れた (Docker 29.9.1)。`dockerd --bridge=none --iptables=false --ip6tables=false` で起動した |
| Mac の Docker | OrbStack (Docker 29.8.2、aarch64) |
| 転送の方法 | `docker save -o` で tar に書き出し、`ssh <guest> docker load < tar` で読み込む。guest の SSH は Mac の loopback に転送した port |

## image

`alpine:3.20` に、`/dev/urandom` から作った乱数のファイルを `COPY` しただけの image です。乱数なので圧縮は効きません。

| 名前 | 乱数のファイル | `docker image inspect` の Size (Mac) | 書き出した tar |
| --- | --- | --- | --- |
| `spike-transfer:92mb` | 92MB | 104,276,574 bytes | 104,576,000 bytes |
| `spike-transfer:492mb` | 492MB | 523,706,974 bytes | 524,006,400 bytes |

## 手順

`measure.sh <作業用ディレクトリ> <乱数のファイルの MB> <guest への ssh コマンド>` が、ビルド、書き出し、読み込みを順に実行して、`time` の出力を出します。

```sh
./measure.sh "$work" 92 ssh -p 13022 root@127.0.0.1
./measure.sh "$work" 492 ssh -p 13022 root@127.0.0.1
```

## 結果

どちらも `docker load` は `Loaded image: ...` で終わり、guest 側の `docker image inspect` は `arch=amd64` を返しました。

| image | 書き出し (`docker save`) | guest への読み込み (`docker load`) |
| --- | --- | --- |
| 92MB (tar 約100MB) | 2.123 秒 | 1 分 14.293 秒 |
| 492MB (tar 約500MB) | 9.470 秒 | 5 分 30.393 秒 |

```text
== save   (92MB)
real	0m2.123s
== load into the guest over ssh
Loaded image: spike-transfer:92mb
real	1m14.293s
arch=amd64 size=209507690

== save   (492MB)
real	0m9.470s
== load into the guest over ssh
Loaded image: spike-transfer:492mb
real	5m30.393s
arch=amd64 size=1048372587
```

- 読み込みは、tar の大きさにほぼ比例しました (約100MB で 74 秒、約500MB で 330 秒)。
- 書き出しは、同じ image を別の回に測ると 1.2 秒から 38.5 秒の間でばらつきました。回ごとの値の差の原因は調べていません。
- guest 側の `docker image inspect` の Size は、Mac 側のおよそ2倍でした。理由は調べていません。
- 測ったのは Mac 上の QEMU です。iPad 実機での時間は、Issue #26 で測ります。
- `docker run` で、読み込んだ image を実際に動かすことは、この検証には含めていません。
