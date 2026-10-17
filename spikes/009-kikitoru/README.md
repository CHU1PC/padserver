# Kikitoru を Mac の guest で動かす

Issue #27 (V21) では、Kikitoru の backend と worker の image を linux/amd64 でビルドして、Mac 上の QEMU の guest で、Postgres と migrate と一緒に `docker compose` で起動できるかと、その時間とメモリを測りました。tailnet 越しの転送と iPad 実機は、この検証には含めていません (実機は Issue #28)。

## 結論

Kikitoru の4つの service (db, migrate, backend, worker) が、guest の `docker compose up -d` で起動し、backend は DB を使う endpoint に `200` を返しました。guest のメモリが 2GiB でも、アプリの既定の 1GiB でも、同じ結果でした。

起動は遅く、`docker compose up -d` を始めてから backend が最初に応答するまで、約3分 (182.78 秒から 190.29 秒、8回) かかりました。起動した後の応答は速く、DB を使う `GET /auth/me` の中央値は約 0.08 秒でした。この時間を「実用になる」とみなすかは、この検証では判断していません。

外のサービス (AWS、Google) には接続していません。鍵は見本の値です。文字起こしと要約の経路 (`POST /api/v1/audio/summarize`、worker のジョブの処理) と、Google の認証は、試していません。

## 環境と固定した入力

| 項目 | 値 |
| --- | --- |
| Kikitoru | 別のリポジトリの commit `975182f` の `backend/` と `docker-compose.yml` (`git archive` で取り出して、作業用ディレクトリでビルドした。元のリポジトリは変更していない) |
| ビルド | Mac の OrbStack (Docker 29.8.2、aarch64) で `docker build --platform linux/amd64 -t kikitoru-backend:spike backend` |
| guest の kernel | Issue #21 の `bzImage` (SHA-256 は `42f36070d9045be2131f9e0c1e42656ee8f048f6878eafdbdf0402131602b87f`) |
| guest の init | Issue #22 の `init-docker.patch` を当てた `initrd.img` |
| QEMU | tctiSH が固定する fork の TCTI backend (QEMU 11.1.2)。CPU 4個、メモリは 2GiB と 1GiB の2通り、disk は空の `empty.qcow` |
| guest の Docker | Alpine の `apk add docker docker-cli-compose iptables ip6tables curl postgresql-client` (Docker 29.9.1、Compose v5.6.0)。`dockerd` は引数無しで起動した |
| 送り方 | Issue #25 と同じ。`docker save` した tar を `ssh <guest> docker load` で読み込む |

guest の起動は、起動してから SSH が通るまで 13 から 15 秒でした (3回)。起動した後に、次の2つを手で実行しました。どちらも [BOOT.md](../007-guest-rebuild/BOOT.md) と [NETWORK.md](../007-guest-rebuild/NETWORK.md) にある既知の問題で、この検証では直していません。

```sh
ip link set lo up
rm -f /var/run/docker.pid
```

## image

Kikitoru の `backend/Dockerfile` は1つで、compose は backend、migrate、worker の3つの service を同じ Dockerfile からビルドします。この検証では1回だけビルドして、3つの service が同じ image を使う形にしました ([compose.yaml](compose.yaml))。

| image | Mac の `docker image inspect` の Size | 書き出した tar | guest の `docker image ls` の Size |
| --- | --- | --- | --- |
| `kikitoru-backend:spike` (`python:3.13-slim-bookworm` に ffmpeg、libsndfile、libmagic、uv と依存を入れたもの) | 894,377,998 bytes | 911,818,240 bytes | 1.87GB |
| `postgres:18-alpine` (`--platform linux/amd64` で取得) | 304MB | 306,678,784 bytes | 619MB |

```text
$ docker image inspect kikitoru-backend:spike --format 'arch={{.Architecture}} size={{.Size}}'
arch=amd64 size=894377998
```

読み込みの時間です。

| image | 読み込み (`docker load`) |
| --- | --- |
| `postgres:18-alpine` (tar 約307MB) | 3 分 11.17 秒 |
| `kikitoru-backend:spike` (tar 約912MB) | 測れなかった |

`kikitoru-backend:spike` の読み込みは、`real 31m46.412s` でした。ただし途中で Mac の disk の空きが 600MiB まで減り、QEMU が `VM status: paused (io-error)` で止まりました。空きを増やして `cont` で再開するまでの時間が入っているので、この値は読み込みの時間として使えません。止まる前の約 20 分は進んでいたので、約 912MB は、Issue #25 の傾き (約 500MB で 5 分 30 秒) より遅い可能性があります。測り直してはいません。

## 構成

[compose.yaml](compose.yaml) は、Kikitoru の `docker-compose.yml` から、次の点だけを変えました。

| 変えた点 | 理由 |
| --- | --- |
| `build:` を `image: kikitoru-backend:spike` にした | Mac でビルドした image を使うため |
| 環境変数を見本の値にした (`POSTGRES_PASSWORD: dummy-password`、`GOOGLE_API_KEY: dummy`、`S3_BUCKET: dummy-bucket` など) | 外のサービスの鍵を使わないため |
| `COOKIE_SECURE: "false"` | guest の中から HTTP で試すため |
| `.env` からの展開をやめて値を直接書き、`SESSION_EXPIRY_DAYS`、`ALLOWED_ORIGINS`、`ENABLE_DOCS` など、設定に既定値がある変数を外した | 外のサービスに関係しない変数は、アプリの既定値のままにするため |

service の構成 (`depends_on` の条件、migrate の command、worker の `restart` と `stop_grace_period`、`ports`) は、Kikitoru のままです。

## 測り方

[measure.sh](measure.sh) を、guest の中で `sh measure.sh /root/k <起動の回数> <要求の回数>` として実行しました (`/root/k` に `compose.yaml`、`seed.sql`、`measure.sh` を置いた)。時刻は guest の `/proc/uptime` です。

- **起動**: `docker compose down -v` で volume ごと消してから、`docker compose up -d` を始めた時刻を 0 として、4つの時刻を 0.5 秒おきの poll で測る。
  - `db_healthy`: db の healthcheck が `healthy` になる。
  - `migrate_done`: migrate が `exited/0` になる。
  - `backend_first_401`: guest の `curl http://127.0.0.1:8000/api/v1/summaries` が、最初に `401` を返す。
  - `worker_running`: worker の container が `running` になる。worker は待ち受けず、起動の直後のログが空だったので、「container が動き始めた」ことだけを表す。
- **応答**: 起動の後に、[seed.sql](seed.sql) で承認済みの利用者とセッションを1つ入れ、guest の中から `curl` を30回ずつ、順に送る。接続は1回ごとに張り直す。
- **メモリ**: guest の `free -m` と `docker stats --no-stream`。

Kikitoru には health 用の endpoint がありません (`/health` などは `main.py` に無い)。そこで次の2つを使いました。

| 名前 | 要求 | 何を確かめるか |
| --- | --- | --- |
| no-db | `GET /api/v1/summaries` を cookie 無しで送る | app が動いて `401` を返す。cookie が無いので DB には触れない |
| db | `GET /auth/me` と `GET /api/v1/summaries` を、cookie `session_token=spike-token` 付きで送る | `user_sessions`、`users` を引いて `200`。`/api/v1/summaries` は、さらに `summaries` を引く |

文字起こしと要約の要求 (`POST /api/v1/audio/summarize`) は、AWS Transcribe と S3 と Gemini に接続するので、試す対象から外しました。Google の認証 (`/auth/google/*`) も、外への接続が要るので外しました。

## 結果

### 起動の時間

guest のメモリが 2GiB の6回と、1GiB の2回です。どれも `down -v` の後の、volume が空の状態からの起動です。image は guest に読み込み済みです。

| メモリ | db が healthy | migrate が終わる | worker が running | backend が最初に `401` |
| --- | --- | --- | --- | --- |
| 2GiB | 35.18 秒 | 94.99 秒 | 98.31 秒 | 185.00 秒 |
| 2GiB | 35.61 秒 | 95.01 秒 | 96.60 秒 | 186.34 秒 |
| 2GiB | 35.52 秒 | 94.80 秒 | 96.30 秒 | 186.58 秒 |
| 2GiB | 34.59 秒 | 93.56 秒 | 94.55 秒 | 182.78 秒 |
| 2GiB | 35.19 秒 | 95.05 秒 | 98.59 秒 | 185.11 秒 |
| 2GiB | 35.55 秒 | 94.97 秒 | 98.42 秒 | 184.10 秒 |
| 1GiB | 35.53 秒 | 98.00 秒 | 98.88 秒 | 190.29 秒 |
| 1GiB | 35.54 秒 | 94.87 秒 | 98.35 秒 | 185.77 秒 |

- backend は migrate が終わってから、さらに約 90 秒かかりました。コンテナが起動してから、`fastapi run` が `Application startup complete.` を出すまでの時間です。
- 最初の3回 (2GiB の上の3行) は、同じ手順の1回目の実行です。応答の集計に使った awk が guest の busybox に無い関数を呼んで止まったので、script を直して、同じ手順をもう一度実行しました (下の3行)。
- 測った poll 自体が、emulate された guest の CPU を使っています。poll の間隔は 0.5 秒で、1回の poll は `docker inspect` と `curl` を呼びます。poll 無しの時間は測っていません。

### 応答の時間

guest の中から、`curl` の `time_total` を、30回ずつ順に測りました (2GiB と 1GiB で同じ形の結果)。

| 要求 | 回数と結果 | 最初の1回 | 最小 | 中央値 | 最大 |
| --- | --- | --- | --- | --- | --- |
| no-db `GET /api/v1/summaries` (cookie 無し) | 2GiB: `401` x30。1GiB: `401` x30 | 0.038 秒 (2GiB)、0.037 秒 (1GiB) | 0.033 秒、0.034 秒 | 0.036 秒、0.036 秒 | 0.057 秒、0.055 秒 |
| db `GET /auth/me` (cookie) | `200` x30、`200` x30 | 1.254 秒、1.338 秒 | 0.074 秒、0.071 秒 | 0.079 秒、0.080 秒 | 1.254 秒、1.338 秒 |
| db `GET /api/v1/summaries` (cookie) | `200` x30、`200` x30 | 0.437 秒、0.509 秒 | 0.118 秒、0.119 秒 | 0.122 秒、0.127 秒 | 0.437 秒、0.509 秒 |

- 各セルの2つの値は、左が 2GiB、右が 1GiB です。
- DB を使う最初の要求だけが遅く (0.4 秒から 1.3 秒)、DB への接続を張ったためと見えますが、原因は調べていません。
- `/api/v1/summaries` に `200` が返るのは、DB に利用者と session がある場合です。summaries の行は無いので、返る items は空です。

### メモリ

| 時点 | guest 2GiB: `free -m` の used | guest 1GiB: used |
| --- | --- | --- |
| stack を止めた状態 (dockerd だけ) | 93MiB から 110MiB (3回) | 78MiB、98MiB |
| 起動した後 | 368MiB から 370MiB | 339MiB |
| 要求を送った後 | 387MiB | 368MiB |

起動した後の `docker stats --no-stream` です。

```text
2GiB の guest
NAME          MEM USAGE / LIMIT     CPU %
k-backend-1   119.1MiB / 1.938GiB   0.82%
k-worker-1    136.4MiB / 1.938GiB   104.64%
k-db-1        43.19MiB / 1.938GiB   0.07%

1GiB の guest
NAME          MEM USAGE / LIMIT     CPU %
k-worker-1    143.7MiB / 977.6MiB   101.81%
k-backend-1   130.5MiB / 977.6MiB   0.74%
k-db-1        58.8MiB / 977.6MiB    0.01%
```

- 1GiB の guest でも、container は OOM で落ちず、`free -m` の available は最小 556MiB でした。
- worker の CPU は、起動の直後に約 100% でした。少し後に `docker stats --no-stream` を取り直すと 24.49% でした。worker は2秒ごとに DB を poll します (`POLL_INTERVAL_SECONDS = 2`)。この CPU の使い方が、起動から何分続くかは測っていません。

## 手順

```sh
# Mac
git -C <Kikitoru> archive 975182f backend docker-compose.yml | tar -x -C <作業用ディレクトリ>
docker build --platform linux/amd64 -t kikitoru-backend:spike <作業用ディレクトリ>/backend
docker save kikitoru-backend:spike -o kikitoru.tar
docker pull --platform linux/amd64 postgres:18-alpine && docker save postgres:18-alpine -o postgres.tar
ssh <guest> docker load < kikitoru.tar
ssh <guest> docker load < postgres.tar

# guest
mkdir -p /root/k   # compose.yaml, seed.sql, measure.sh を置く
cd /root/k && sh measure.sh /root/k 3 30
```

Mac 側では QEMU を、ssh の port を 18022、monitor の port を 18045 にして起動しました。

## 試していないこと

- iPad の実機での起動と応答の時間 (Issue #28)。
- Mac の上で、Kikitoru を emulate 無しで動かした場合の起動と応答の時間 (比較の基準としては測っていない)。
- 文字起こしと要約の経路、worker のジョブの処理、Google の認証。いずれも外のサービスへの接続が要る。
- `docker compose up -d --build` を guest の中でビルドする形。guest には Mac でビルドした image を読み込んだ。
- `kikitoru-backend:spike` の tar の読み込み時間 (上の通り、途中で止まって測れなかった)。
- 起動の時間の、poll 無しの値と、image が page cache に無い状態の値。
- 長時間の動作。起動して測り終えたら止めた。
- 起動の後の guest の自動の起動 (dockerd と compose は手で起動した)。

## 見つかった問題

- この検証の最中に、Mac の disk の空きが尽きて、QEMU が `io-error` で止まりました。QEMU の disk image と tar を置く場所に、数 GB の空きが要ります。
