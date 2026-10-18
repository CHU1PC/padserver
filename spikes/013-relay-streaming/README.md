# relay で大きい応答, 大きい要求, 少しずつ出る応答を運ぶ

Issue #33, #34, #35 (M1-14, M1-15, M1-16) の検証です. 3 つは同じ試験用の relay と測定の道具を使うので, 1 つの spike にまとめました. iPad の実機は使っていません. iPad の代わりに, Mac の上の bun の client (`client/agent.ts`) が relay の Durable Object に WebSocket で繋ぎ, 来た要求を Mac の上の小さい HTTP サーバ (`client/origin.ts`) に転送します. 本文は WebSocket の上で小分けにして運びます.

試験用の Worker は, 所有者の Cloudflare の account (無料プラン) に配備して測り, 測定のあとに削除しました. 配備先の URL の account の部分は, 個人情報なので書きません (`<account>` と書きます).

## 結果の要約

| 確かめたこと | 結果 |
| --- | --- |
| 数百 MB の download を, 本文を小分けにした frame で運べる | 運べた. 100 MB, 300 MB, 500 MB を, 内容の一致を確かめながら全部完走した. 速さは 13.5 から 25 MiB/s (113 から 211 Mbit/s). この速さは Mac の回線で決まっていて, relay の上限は見えていない |
| Range の要求を通せる | 通った. 先頭, 途中, 末尾 (`bytes=-500`), 開始位置だけ (`bytes=N-`), 50 MB の範囲が `206` で正しい `Content-Range` と内容で返った. 範囲外は `416` が返った |
| 本文を溜めずに流せば, Worker の 128 MB の上限に当たらない | 当たらなかった. ただし, 受け手が遅いときに送り手を止める仕組み (window) が無いと, Durable Object が `Exceeded Memory Limit` で落ちた. window を付けると, 500 MB を 3 MB/s の遅い受け手へ 167 秒かけて 3 回完走し, Durable Object が溜めた本文は最大 4.4 MB だった. 背圧は要る |
| chunk の大きさ | 64 KiB から約 1 MiB まで, 速さに差は出なかった. ばらつきの方が大きい. 256 KiB を目安にする |
| upload (要求の本文) の上限 | 104,857,600 byte (100 MiB) までは通った. 1 byte 超えると, Cloudflare の edge が `413` を返す. Content-Length を付けた場合と, 付けない (chunked) 場合の両方で同じ. 大きい要求では, `413` の代わりに `502` が返ることもあった |
| 少しずつ出る応答 (SSE) | 溜められずに 1 件ずつ届いた. 1 件ごとの遅れは中央値で 26 から 30 ミリ秒, 最大でも 38 ミリ秒 (1 回だけ 137 ミリ秒). 140 秒の stream も切れなかった |

見つかった上限と注意は次の 3 つです.

- 100 MiB を超える要求の本文は, 今の形では relay を通せない. Kikitoru の 500 MB までの音声の upload は, 1 つの要求では運べない.
- 同じ Worker の上の Durable Object は, 本文を溜めると 128 MB の上限で落ちる. 受け手の ack で送り手を止める必要がある.
- 要求の本文を Durable Object が `request.body` から読むと, 1 回に約 4 KiB ずつしか届かない. そのまま frame にすると遅いので, chunk の大きさになるまで溜めてから送る.

## 作ったもの

```text
spikes/013-relay-streaming/
  shared/protocol.ts   frame の型と encode, decode (Worker と client で共有)
  shared/pattern.ts    offset から決まる byte 列 (内容の一致を確かめるための見本)
  worker/              Worker と Durable Object (wrangler.toml, src/index.ts)
  client/origin.ts     Mac の上の小さい HTTP サーバ (大きい本文, Range, SSE, upload の受け取り)
  client/agent.ts      iPad の代わりの client. relay に WebSocket で繋ぎ, 要求を origin に転送する
  scripts/measure.ts   download, Range, SSE, 遅い受け手, chunked の upload を測る
  scripts/upload.sh    curl で upload の大きさを測る (Content-Length の有り無しを選べる)
```

### frame

WebSocket の 1 message が 1 frame です. 先頭 5 byte が header で, 残りが payload です.

| 種類 | 値 | 向き | payload |
| --- | --- | --- | --- |
| `ReqHead` | 1 | relay から client | JSON (`method`, `path`, `headers`, `hasBody`) |
| `ReqBody` | 2 | relay から client | 要求の本文の chunk |
| `ReqEnd` | 3 | relay から client | 無し |
| `ResHead` | 4 | client から relay | JSON (`status`, `headers`) |
| `ResBody` | 5 | client から relay | 応答の本文の chunk |
| `ResEnd` | 6 | client から relay | 無し |
| `Cancel` | 7 | どちらからも | 無し. その要求を止める |
| `Ack` | 8 | 本文を受けた側から送った側 | 4 byte の整数. 受け取った本文の byte 数 |

header は, 1 byte の種類と, 4 byte (big endian) の要求の番号です. 要求の番号で, 1 本の WebSocket の上に複数の要求を重ねられます (この spike では, 同時に複数を流す測定はしていません).

背圧は, 受け手の ack と, 送り手の window で作りました. 送り手は, まだ ack されていない本文が window を超えたら, 次の chunk を送らずに待ちます.

- 応答の向き: Durable Object が, 本文を訪問者へ渡す (stream の `pull`) たびに `Ack` を返す. client は `WINDOW_BYTES` を超えると待つ. 0 にすると待たない.
- 要求の向き: client が, 本文を origin へ渡すたびに `Ack` を返す. Durable Object は, 要求の header `x-spike-up-window` (既定は 4 MiB, 0 で無し) を超えると待つ.

本文は, 受け取った Durable Object が, queue に入れて, 訪問者が読んだ分だけ stream へ渡します (`highWaterMark` は 0). queue にある byte 数の最大を, `/_stats` で読めるようにしました.

## 測り方

- 配備: `worker/` で `bunx wrangler deploy --var SPIKE_TOKEN:<token>` を実行した. Worker は, header `x-spike-token` が合わない要求に `403` を返す. token は repo に入れていない. 名前は `padserver-relay-spike-<ランダムな 6 文字>` にした.
- 回線: download では, 応答の本文が Mac から Cloudflare へ (client が送る), Cloudflare から Mac へ (訪問者が受ける) と, 同じ Mac の回線を往復する. 速さは Mac の回線に縛られる.
- 内容の確認: `shared/pattern.ts` の byte 列 (offset から決まる) を origin が作り, `measure.ts` が受け取った byte を offset ごとに照らして確かめた. 表の `content_ok` が `true` なら, 大きさと内容が一致している.
- 同時に複数は流していない. 1 つずつ流した.
- 実ファイルは作っていない. download は origin が生成した. upload は `head -c <N> /dev/zero` を curl に渡した.
- 落ちた原因を見るために, `bunx wrangler tail` の出力を使った.
- 測定の終わりに, `bunx wrangler delete` で Worker を削除した. 削除後に `bunx wrangler deployments list` を実行すると, `This Worker does not exist on your account. [code: 10007]` が返り, 公開 URL も `404` を返した.

再現の手順 (配備先の URL は `RELAY_URL` に入れる).

```text
bun client/origin.ts &
CHUNK_BYTES=262144 WINDOW_BYTES=4194304 RELAY_URL=... SPIKE_TOKEN=... bun client/agent.ts &
RELAY_URL=... SPIKE_TOKEN=... bun scripts/measure.ts download 500
RELAY_URL=... SPIKE_TOKEN=... bun scripts/measure.ts range
RELAY_URL=... SPIKE_TOKEN=... bun scripts/measure.ts sse 100 100
RELAY_URL=... SPIKE_TOKEN=... scripts/upload.sh 104857601 length
```

## 結果

### download の速さ

最終版 (chunk 256 KiB, window 4 MiB) の出力です. `MiB_per_s` は 1 MiB を 1,048,576 byte として計算した値です.

```text
DOWNLOAD size=100000000 status=200 received=100000000 seconds=4.75 MiB_per_s=20.07 Mbit_per_s=168.4 content_ok=true error=""
DOWNLOAD size=300000000 status=200 received=300000000 seconds=11.36 MiB_per_s=25.19 Mbit_per_s=211.3 content_ok=true error=""
DOWNLOAD size=500000000 status=200 received=500000000 seconds=35.19 MiB_per_s=13.55 Mbit_per_s=113.7 content_ok=true error=""
```

window を付けない版 (chunk 256 KiB) では, 各 2 回測った.

| 大きさ | 1 回目 (秒, MiB/s) | 2 回目 (秒, MiB/s) |
| --- | --- | --- |
| 100 MB | 5.97 秒, 15.97 | 5.26 秒, 18.12 |
| 300 MB | 17.19 秒, 16.64 | 16.39 秒, 17.45 |
| 500 MB | 32.53 秒, 14.66 | 28.47 秒, 16.75 |

全て `status=200`, `content_ok=true` で, 失敗は無かった. 同じ設定でも回ごとに大きくばらつく (100 MB で 12.7 から 20.1 MiB/s) ので, 最終版が速いとは言えない.

### chunk の大きさ

window を付けず, 100 MB を, 大きさを変えて 3 回ずつ交互に測った (MiB/s). origin が 1 回に作る塊は 1,048,573 byte にして, client が chunk の大きさに切って送った. 1 MiB の欄は, 1,048,573 byte の payload (frame は 1,048,578 byte) で, 1 MiB を超えた message も通った.

| chunk | 1 回目 | 2 回目 | 3 回目 | 平均 |
| --- | --- | --- | --- | --- |
| 64 KiB | 16.96 | 19.53 | 16.09 | 17.53 |
| 128 KiB | 18.48 | 16.23 | 14.67 | 16.46 |
| 256 KiB | 12.73 | 15.98 | 15.53 | 14.75 |
| 512 KiB | 17.76 | 13.07 | 16.06 | 15.63 |
| 約 1 MiB | 15.43 | 19.10 | 18.80 | 17.78 |

同じ大きさの 3 回の幅 (3 から 6 MiB/s) が, 大きさの間の差より大きいので, chunk の大きさで速さは決まらないと判断しました. 速さは Mac の回線で決まっています.

### Range

100 MB の資源に対する要求です. 出力のとおりです.

```text
RANGE first-100B header=bytes=0-99 status=206 content_range="bytes 0-99/100000000" received=100 expected=100 seconds=0.16 content_ok=true
RANGE middle-1MB header=bytes=1000000-1999999 status=206 content_range="bytes 1000000-1999999/100000000" received=1000000 expected=1000000 seconds=0.19 content_ok=true
RANGE suffix-500B header=bytes=-500 status=206 content_range="bytes 99999500-99999999/100000000" received=500 expected=500 seconds=0.08 content_ok=true
RANGE open-ended-tail-10MB header=bytes=90000000- status=206 content_range="bytes 90000000-99999999/100000000" received=10000000 expected=10000000 seconds=0.65 content_ok=true
RANGE middle-50MB header=bytes=10000000-59999999 status=206 content_range="bytes 10000000-59999999/100000000" received=50000000 expected=50000000 seconds=2.03 content_ok=true
RANGE unsatisfiable header=bytes=100000005- status=416 content_range="bytes */100000000"
```

Range の解釈は origin が行い, relay は `Range` の header と `206`, `416`, `Content-Range` をそのまま運んだだけです.

### 背圧は要るか

受け手を遅くして (3,000 KB/s で読む), 500 MB を流しました. 送り手の速さは約 15 から 20 MiB/s です.

| window | 結果 |
| --- | --- |
| 無し (`WINDOW_BYTES=0`) | 2 回とも落ちた. 訪問者は 148,993,521 byte と 155,621,678 byte を受け取ったところで止まった. agent の WebSocket は code 1006 で切れ, `/_stats` の記録は 0 に戻った (Durable Object が作り直された) |
| 4 MiB | 3 回とも完走した (167.40 秒, 167.62 秒, 167.53 秒. `complete=true`, `content_ok=true`). 下の修正のあとにも, 300 MB を 3,000 KB/s で 101.19 秒で完走した (直前に agent を `kill -9` で落として, 別の agent に繋ぎ直した状態で測った) |

落ちた回の `wrangler tail` の出力です.

```text
GET https://<host>/big?size=500000000 - Exceeded Memory Limit @ 10/18/2026, 9:28:20 PM
[ERROR] Error: Durable Object's isolate exceeded its memory limit and was reset.
```

window を付けない Durable Object は, 受け手が読むより速く本文が届くので, queue に溜めて 128 MB に当たります. `wrangler tail` を見た回では, WebSocket を張った 9:28:17 から 3 秒で落ちました. 受け手の側に残りの byte が届いているのは, Cloudflare の edge と回線に溜まっていた分です.

受け手が速くても, window が無いと queue は伸びます. window 無しの 500 MB の download 6 回の後で, queue の最大は 42,990,140 byte でした. 別の回 (client の chunk を 512 KiB にした 100 MB の download) では 91,349,726 byte (約 87 MiB) になりました (`/_stats` の `maxQueuedBytes`). 128 MB に近い値です. window 4 MiB では, 500 MB の流れを含めて, queue の最大は 4,456,412 byte でした.

結論として, 背圧は要ります. WebSocket には背圧が無く, 送り手は受け手の速さを知らないので, 受け手の ack で送り手を止める必要があります.

最初の window 付きの長い測定では, 2 回が途中で止まりました (430 MB で 480 秒後に timeout, 194 MB で 420 秒後に timeout). 原因は Durable Object の試験用のコードでした. 古い WebSocket が遅れて閉じたときに, 閉じた socket の要求だけでなく, 流れている全ての要求を失敗にしていました. 要求を socket ごとに持ち, 閉じた socket の要求だけを失敗にするよう直してから, 別の agent を起動し直した状態の測定で完走しました (上の 300 MB の 101.19 秒の測定). 表の 3 回の完走は, 直す前の版の結果です. その 3 回は, 古い socket が閉じるイベントが重ならなかったので失敗しなかった, というだけです. 取り決めでは, 失敗の範囲を socket ごとにする必要があります.

### upload (要求の本文)

`scripts/upload.sh <byte> length|chunked` の出力です. `length` は Content-Length を付け, `chunked` は付けません (curl が `Transfer-Encoding: chunked` で送る). 受け取りは origin で, 戻りの JSON の `bytes` で確かめました.

| 大きさ (byte) | 方式 | status | 備考 |
| --- | --- | --- | --- |
| 10,000,000 | length | 200 | 2.18 秒 |
| 50,000,000 | length | 200 | 12.13 秒 |
| 99,000,000 | length | 200 | 25.67 秒 |
| 100,000,000 | length | 200 | 26.98 秒 |
| 104,857,600 (100 MiB) | length | 200 | 24.98 秒. 戻りの `bytes` が 104857600 |
| 104,857,600 (100 MiB) | chunked | 200 | 26.08 秒. 最終版でも 20.73 秒で 200 |
| 99,000,000 | chunked | 200 | 23.03 秒 |
| 104,857,601 | length | 413 | `413 Payload Too Large`, `cloudflare`. 30 秒かかる回があり, curl が `(18) Transferred a partial file` を返す回もあった |
| 104,857,601 | chunked | 413 | 2.9 秒から 3.2 秒. 送れたのは 104,857,601 byte で, 戻りが `413` |
| 110,000,000 | length | 413 | 0.15 秒. 約 2.8 MB を送ったところで返った |
| 120,000,000 | chunked | 413 | 3.0 秒. 約 106 MB を送ったところで返った |
| 150,000,000 | length | 413 | 0.13 秒 |
| 200,000,000 | length | 413 | 30.18 秒 |
| 200,000,000 | chunked | 502 (1 回目), 413 (2 回目), 502 (3 回目) | 約 106 MB を送ったところで返った |
| 500,000,000 | length | 502 (1 回目), 413 (2 回目), 502 (3 回目) | 0.13 秒. 約 3 MB を送ったところで返った |

通せた最大の大きさは 104,857,600 byte (100 MiB) です. 無料プランの上限は 100 MB と言われますが, 実測では 100 MiB でした. 1 byte 超えると `413` です. 上限を大きく超える要求は, 同じ要求でも `413` と `502` のどちらかになりました (`502` の本文は `502 Bad Gateway`, `cloudflare`). どちらも Cloudflare の edge が返していて, Worker には届いていません. 取り決めでは, 上限を超えた要求は `413` と `502` の両方を「大きすぎる」と扱う必要があります.

上限は, 本文を relay が小分けにしても変わりません. Cloudflare が, Worker に渡す前に要求の本文の大きさを見ているためです.

upload の速さは, relay を通すと 4 から 8 MB/s で, edge だけで本文を数えて返す経路 (`/_sink`) の 11 から 15 MB/s より遅くなりました. 差の原因は調べていません.

| 経路 | 速さ (MB/s) |
| --- | --- |
| `/_sink` (Worker だけ) | 12.5, 14.6, 10.9, 15.5 |
| relay. Durable Object が 4 KiB のまま frame にした版 | 3.6 から 4.6 (window や chunk を変えても同じ) |
| relay. chunk の大きさまで溜めてから送る版 | 4.8 から 7.8 (窓 0, 1, 4, 16 MiB と chunk 64 KiB から 1 MiB を試した. 傾向は見えなかった) |

Durable Object の `request.body` は, 約 4 KiB ずつ届きました (50 MB で 12,211 frame. client で数えた). 溜めてから送るようにすると, 同じ 50 MB が 191 frame になり, 速さは 4.2 から約 6 MB/s に上がりました.

### 少しずつ出る応答 (SSE)

origin が `data: {"seq": N, "sent": <時刻>}` を一定の間隔で出し, `measure.ts` が届いた時刻との差を測りました. origin と `measure.ts` は同じ Mac なので, 時計の差はありません. 遅れは, Mac から Cloudflare を通って Mac へ戻る往復と, relay の中の時間です. 出力のとおりです.

```text
SSE status=200 events=100/100 interval_ms=100 first_byte_ms=124 latency_ms min=23 p50=26 p95=33 max=137 arrival_gap_ms min=0 p50=101 max=202
SSE status=200 events=30/30 interval_ms=1000 first_byte_ms=187 latency_ms min=23 p50=27 p95=36 max=40 arrival_gap_ms min=994 p50=1002 max=1034
SSE status=200 events=300/300 interval_ms=10 first_byte_ms=117 latency_ms min=23 p50=28 p95=33 max=39 arrival_gap_ms min=0 p50=11 max=27
SSE status=200 events=5/5 interval_ms=20000 first_byte_ms=170 latency_ms min=27 p50=30 p95=33 max=33 arrival_gap_ms min=19997 p50=19999 max=20006
SSE status=200 events=7/7 interval_ms=20000 first_byte_ms=157 latency_ms min=25 p50=28 p95=35 max=35 arrival_gap_ms min=19994 p50=20001 max=20011
SSE status=200 events=100/100 interval_ms=100 first_byte_ms=130 latency_ms min=23 p50=26 p95=32 max=38 arrival_gap_ms min=92 p50=101 max=112
```

最後の行は, 最終版の Worker での再測定です.

- 件数は全て揃い, 1 件ごとに届いた. 到着の間隔は, 送った間隔とほぼ同じで (100 ミリ秒の stream で中央値 101 ミリ秒), 溜まってからまとめて届くことは無かった. 10 ミリ秒の間隔で到着の間隔の最小が 0 になるのは, 受け手で 2 件が同じ瞬間に処理されたためで, 原因は調べていません.
- 1 件ごとの遅れは, 中央値で 26 から 30 ミリ秒, 最大で 40 ミリ秒でした. 1 回目の 100 件の測定だけ, 最大 137 ミリ秒の件が 1 つありました (到着の間隔が 202 ミリ秒の件と対応する).
- 7 件を 20 秒おきに出した 140 秒の stream も, 切れずに最後まで届きました. Cloudflare の edge で, 応答の間が空いても切れないことの確認になります (100 秒を超える stream を含みます).

## 判断

### chunk の大きさの目安

256 KiB を目安にします. 64 KiB から約 1 MiB の間で, 速さに差は出ませんでした. 小さいほど frame の数が増え, 大きいほど 1 つの frame の送出と, 遅い受け手への反応が粗くなります. 約 1 MiB の frame (1,048,578 byte) も, Durable Object と client の間で通りました. それより大きい frame は試していません.

### 背圧の要否

要ります. window を付けないと, 遅い受け手に対して Durable Object が 3 秒で 128 MB の上限に当たりました. 受け手が読んだ分だけ ack を返し, 送り手は ack されていない byte が window (4 MiB) を超えたら待つ形で, 500 MB を遅い受け手へ流しきれました. window を 1 MiB から 16 MiB に変えても, upload の速さには傾向が見えませんでした (download の速さは window 4 MiB でしか見比べていません).

### upload の上限

100 MiB (104,857,600 byte) です. relay を通す要求の本文は, これを超えられません. Kikitoru の音声は 500 MB まで受け取る作りなので, 次のどれかが要ります (所有者の判断です. この spike では選びません).

- 100 MiB を超える本文は, 公開の経路で運ばない (roadmap の V12 の「配れるファイルの大きさに上限を置く」).
- upload は, relay を通さない経路 (tailnet の中から直接など) に限る.
- 本文を 100 MiB 未満の複数の要求に分ける取り決めを, アプリと relay の外に作る.

### 取り決め (M3-1) への申し送り

- frame は, 種類 1 byte と要求の番号 4 byte の header と payload にする. 上の frame の種類で足りた. WebSocket の message の大きさは, 約 1 MiB まで通った.
- 本文の frame の byte 数に応じた ack と window を, 応答の向きと要求の向きの両方に置く. window の既定は 4 MiB, chunk は 256 KiB から始める.
- 要求の番号で, 1 本の WebSocket に複数の要求を重ねる設計にした. 同時に複数を流したときの公平さは, この spike では測っていない.
- 失敗の範囲は socket ごとにする. 古い socket が遅れて閉じても, 新しい socket の要求を失敗にしない.
- Durable Object は, `request.body` を 4 KiB ほどの小さい塊で読む. 要求の本文は, chunk の大きさまで溜めてから frame にする.
- 取り消し (`Cancel`) は, 訪問者が応答を読むのをやめたとき (stream の `cancel`) に client へ送る. 試験では, 訪問者が切ったときの `Canceled` を `wrangler tail` で見たが, client が origin の fetch を止めたかの確認はしていない.
- 上限を超えた要求は, `413` と `502` の両方が返る. エラーの扱いは, 両方を大きすぎるとして扱う.
- 応答の `content-length` は, origin が付けた値を訪問者へそのまま返せた. `content-encoding`, `transfer-encoding`, `connection`, `keep-alive` は外した.

## 確かめていないこと

- WebSocket を張ったまま Durable Object が hibernation に入るかと, 起きたときに本文の流れが続くか. 今回は, 要求が流れている間は Durable Object が起きたままで, hibernation を観測していない (`acceptWebSocket` は使っている). 繋ぎ直しは #36 の担当.
- iPad の実機の回線と, iPad の上のアプリでの速さ. 速さは Mac の回線の値で, iPad では変わる.
- Durable Object の実際のメモリ使用量. Cloudflare から直接は見えないので, 完走したこと, `Exceeded Memory Limit` が出なかったこと, queue の最大 byte 数 (`/_stats`) で代えた.
- 無料プランの Durable Object の使用量の上限 (request の数, 実行時間) に, 数百 MB の測定を重ねたときに当たるか. 今回の測定では, CPU 時間の上限のエラーは出なかった.
- 同時に複数の要求を流したときの速さと公平さ.
- 本文の frame が 1 MiB を超えたときの挙動.
- upload の遅さの原因 (上の表のとおり, relay を通すと `/_sink` より遅い).

## 依存

`package.json` に, `typescript` 5.9.3, `@types/bun` 1.4.3, `wrangler` 4.151.1 (いずれも `relay/` と同じ版) と, Worker の型のための `@cloudflare/workers-types` を入れました. 型の検査は `bun run typecheck` です.
