# docker compose を動かす

Issue #23 では、[#21 の kernel](NETWORK.md) と [#22 の init](BOOT.md) を重ねた guest に compose を入れ、FastAPI と Postgres の 2 つの service の構成を動かせるかを確かめました。compose を guest に plugin として入れる形と、compose の CLI を container として動かす形の、2 つを試しました。

## 結論

2 つの形のどちらでも、`docker compose up -d` の後に、FastAPI が service の名前 `db` で Postgres に繋がりました。`GET /db` が Postgres のバージョンと、insert した行の数を返しました。

ただし、これは Linux x86_64 上の upstream QEMU 10.0 (KVM) で確かめた結果です。tctiSH の QEMU fork (TCTI) と iPad の実機では試していません。

## 固定した入力

| 入力 | 値 |
| --- | --- |
| tctiSH | `76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4` (#20 と同じ) |
| `bzImage` | Issue #21 でビルドしたもの。SHA-256 は `42f36070d9045be2131f9e0c1e42656ee8f048f6878eafdbdf0402131602b87f`。Linux の機械に残っていた作業 checkout の file の SHA-256 が、[NETWORK.md](NETWORK.md) の値と一致したので、ビルドし直さずに使った |
| `init` | `assets/overlay/init` に [init-docker.patch](init-docker.patch) を当てたもの |
| `initrd.img` | tctiSH の `assets/initrd.img` に、直した `init` だけの cpio を連結したもの ([BOOT.md](BOOT.md) と同じ作り方) |
| guest の Docker | Alpine の `docker` 29.9.1 |
| compose | Alpine の `docker-cli-compose` 5.6.0 (plugin の形). `docker/compose-bin:latest` の `docker-compose` v5.6.0 (container の形) |
| service | `postgres:18-alpine` (18.6) と、`python:3.13-alpine` に `fastapi`、`uvicorn`、`psycopg[binary]` を入れた image |

構成の file は [compose/](compose) にあります。`compose.yaml` の `api` は `build: .` で、guest の中でビルドします。`api` は `DATABASE_URL` の host に `db` を使います。`db` には `pg_isready` の healthcheck があり、`api` は `depends_on` の `condition: service_healthy` で待ちます。

## 手順

guest は、WSL の Docker の中の `alpine` に入れた QEMU 10.0 で起動しました。#21 と同じく `-M pc -cpu host -accel kvm`、CPU 4 個、`-netdev user,net=192.168.100.0/24` ですが、メモリは 2 GiB です。container の名前には `q23-` を付け、終わったら `docker rm -f` で消しました。disk は `empty.qcow` の複製です。

```sh
ip link set lo up
rm -f /var/run/docker.pid
dockerd &
apk add docker docker-cli-compose iptables ip6tables curl
```

`lo` を上げる行と、`docker.pid` を消す行は、下の「回避した問題」にあります。保存先の指定 (`--data-root`) と `--iptables=false` は付けていません。

## 形 A: guest に compose の plugin を入れる

```text
$ docker compose version
Docker Compose version v5.6.0
$ cd /root/app && docker compose up -d --build
 Image app-api Built
 Network app_default Created
 Container app-db-1 Created
 Container app-api-1 Created
 Container app-db-1 Started
 Container app-db-1 Healthy
 Container app-api-1 Started
$ docker compose ps
NAME        IMAGE                COMMAND                  SERVICE   CREATED              STATUS                        PORTS
app-api-1   app-api              "uvicorn app:app --h…"   api       About a minute ago   Up About a minute             0.0.0.0:8000->8000/tcp, [::]:8000->8000/tcp
app-db-1    postgres:18-alpine   "docker-entrypoint.s…"   db        About a minute ago   Up About a minute (healthy)   5432/tcp
$ curl -sS http://127.0.0.1:8000/db
{"host":"db","postgres":"18.6","hits":1}
$ curl -sS http://127.0.0.1:8000/db
{"host":"db","postgres":"18.6","hits":2}
$ curl -sS http://127.0.0.1:8000/health
{"status":"ok"}
$ docker compose exec api python -c 'import socket; print(socket.gethostbyname("db"))'
172.18.0.2
```

`docker compose down -v` も通り、container と network が消えました。

## 形 B: compose の CLI を container として動かす

guest の `docker` の `docker compose` が使えない状態 (`apk del docker-cli-compose` の後。`docker: unknown command: docker compose`) で試しました。

| image | 結果 |
| --- | --- |
| `docker/compose:latest` | 中身は compose 1.26.2 (2020 年) で、`compose.yaml` を読まず (`docker-compose.yml` と `docker-compose.yaml` だけ)、`Can't find a suitable configuration file` で止まった。これ以上は試していない |
| `docker/compose-bin:latest` の `/docker-compose` を alpine に入れた image ([compose/Dockerfile.compose-cli](compose/Dockerfile.compose-cli)) | 通った |

```text
$ docker build -t compose-cli -f Dockerfile.compose-cli .
$ docker run --rm compose-cli version
Docker Compose version v5.6.0
$ docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    -v /root/app:/root/app -w /root/app compose-cli up -d --build
 Network app_default Created
 Container app-db-1 Created
 Container app-api-1 Created
 Container app-db-1 Started
 Container app-db-1 Healthy
 Container app-api-1 Started
$ docker ps --format '{{.Names}} {{.Status}}'
app-api-1 Up 5 seconds
app-db-1 Up 9 seconds (healthy)
$ curl -sS http://127.0.0.1:8000/db
{"host":"db","postgres":"18.6","hits":1}
$ curl -sS http://127.0.0.1:8000/db
{"host":"db","postgres":"18.6","hits":2}
```

`up -d --build` は image が手元にある状態で 26 秒でした。`down -v` も同じ形で通りました。guest の socket と、project の directory を、guest の中と同じ path で container に渡す必要があります。project の path がずれると、`build` と bind mount の path が guest の側で解決されません (試していない)。

## 再起動をまたいだ状態

形 A のまま `poweroff` し、同じ disk で起動し直しました。

| 確認 | 結果 |
| --- | --- |
| image (`postgres:18-alpine`, `app-api`) | 残っていた |
| 起動し直した直後の container | `Exited (255)`。`docker compose up -d` で起動した |
| Postgres の data (anonymous volume) | 残っていた。`/db` の `hits` が 2 から始まった |
| `apk add` で入れた `docker-cli-compose` | 残っていた |

## 回避した問題

[NETWORK.md](NETWORK.md) と [BOOT.md](BOOT.md) で見つかった 2 つの問題は、この検証でも起きました。直してはいません。

| 問題 | 症状 | この検証での回避 |
| --- | --- | --- |
| loopback (`lo`) が DOWN のまま | 起動し直した直後に `ip addr show lo` が `state DOWN`。`curl http://127.0.0.1:8000/health` が `curl: (28) Connection timed out after 5001 milliseconds`。同じ port への guest の eth0 の IP 経由の `curl` は `{"status":"ok"}`。container どうし (`api` から `db`) は、`lo` が DOWN のままでも繋がった (最初の起動では `lo` を上げてから compose を動かしたので、この点は再起動の後の `up` だけで確認した) | `ip link set lo up` を手で実行した |
| `/var/run/docker.pid` が残る | 再起動した後も、前の起動の `/var/run/docker.pid` (`195`) が残っていた。今回は、その PID の process が動いていなかったので、dockerd は始まった。BOOT.md の `process with PID ... is still running` では、再現していない | 起動の前に `rm -f /var/run/docker.pid` を実行する手順にした |

## 試していないこと

- tctiSH の QEMU fork (TCTI) での起動と、iPad の実機での動作。速度と、emulate 時の挙動は別である。
- app の既定の 1 GiB のメモリ。この検証は 2 GiB で、compose の動作中の guest の使用量は約 209 MiB、buff/cache は約 1.1 GiB だった。
- `docker/compose:latest` (compose 1.26.2) での `up`。
- `restart:` の方針の指定と、guest の起動時に dockerd と compose を自動で始める仕組み。dockerd は毎回手で起動した。
- compose の `build` を、外から image を送り込む形 (Mac でビルドして読み込む)。
- 長時間の動作と、複数回の再起動。再起動は 1 回だけである。
