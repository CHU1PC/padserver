# relay の繋ぎ直し (回線の断, 配備し直し)

Issue #36 (M1-17) の検証です. 「回線を切る」と「relay を配備し直す」の 2 つを, Mac の上の client で測りました. 「アプリを背景に回す」は iPad の実機が要るので, #422 に分けました. この spike では測っていません.

構成は [013](../013-relay-streaming/README.md) の Worker, Durable Object, client を元にしています (013 は書き換えていません). 013 の本文の小分けと背圧は外し, 繋ぎ直しに要る部分だけにしました. iPad の代わりに, Mac の上の bun の client (`client/agent.ts`) が relay の Durable Object に WebSocket で繋ぎ, 来た要求を Mac の上の小さい HTTP サーバ (`client/origin.ts`) に転送します.

試験用の Worker は, 所有者の Cloudflare の account (無料プラン) に配備して測り, 測定のあとに削除しました. 配備先の URL の account の部分は, 個人情報なので書きません (`<account>` と書きます).

## 結果の要約

| 確かめたこと | 結果 |
| --- | --- |
| 回線の断 (socket を close frame 無しで破棄) の後に, 自動で繋ぎ直せる | 繋ぎ直せた (5 回とも). 切ってから WebSocket が開くまで 0.69 から 0.98 秒 (backoff の 0.5 秒と, 接続の確立の 0.18 から 0.47 秒). 公開の要求が再び 200 を返すまでは 0.92 から 1.22 秒 |
| client の process が突然死んで, 新しい process が繋ぎ直す | 5 回とも 0.20 から 0.43 秒で新しい接続が開いた (process の起動を含む). 古い socket が残っても, 新しい socket の要求は失敗しなかった |
| 半開き (process が止まって応答しないが, TCP は生きている) を relay が検出できる | relay の側は socket を閉じない. 45 秒から 60 秒止めても, socket は `readyState` 1 のまま残った. 検出の手がかりは, client の ping の最終時刻だけ (`getWebSocketAutoResponseTimestamp`) |
| 止まった client への要求 | 何も返らずに待ち続ける. 5 秒で打ち切る client が, 全部 timeout した. 「ping が 8 秒来ていなければ 503 を返す」を足すと, 止めてから 10.4 秒で `503 agent stale` が返った (3 回) |
| 繋がっていない間の要求 | `503` で本文 `agent not connected` が, 即座に (約 0.15 秒) 返った. 繋がった後は 200 に戻った. 切れる瞬間に流れていた要求は `502` (`relay failure: agent disconnected`) になった |
| `wrangler deploy` で WebSocket が切れる | 配備した直後には切れない. Worker の本体は 3 から 5 秒で新しい版に変わるが, 要求が流れ続けている Durable Object は古い code のまま動き続け, 配備の開始から 304.1, 304.2, 304.4 秒後に WebSocket が code 1006 で切れた (3 回). client は 0.7 から 0.8 秒で繋ぎ直した |
| 要求が流れていない (hibernation 中の) Durable Object への配備 | WebSocket は切れなかった (3 回). 次に起きたときに, 新しい code で作り直された |
| 配備をまたぐ stream (SSE, 60 秒) | 4 回とも最後まで届いた (600 件) |
| hibernation | 入った. 30 秒おきの要求のたびに Durable Object が作り直された (`bootedAgoMs` が 0.3 秒ほどに戻る). それでも WebSocket は切れず, 要求の遅れは 253 から 308 ミリ秒で, 起きていないときと変わらなかった. ping の自動応答では Durable Object は起きない |

見つかった注意は次のとおりです.

- 理由が分からない 1006 の切断が 2 回あった (下の「分からないこと」). 配備や回線の操作とは関係なく起きるので, 繋ぎ直しは必須です.
- 切れた socket が `readyState` 1 のまま残り, 要求がそこへ流れて戻らなくなる状態を 1 回観測した (再現はしていない).
- 訪問者が先に切った要求は, relay の `pending` に残り続けた (試験用の code が, head が届く前に切られた要求を片付けないため).

## 作ったもの

```text
spikes/014-relay-reconnect/
  shared/protocol.ts   frame の型 (013 のコピー)
  worker/              Worker と Durable Object (wrangler.toml, src/index.ts)
  client/origin.ts     Mac の上の小さい HTTP サーバ (/ping と /sse)
  client/agent.ts      iPad の代わりの client. 切れたら指数の backoff で繋ぎ直す
  scripts/measure.ts   各場合を測り, 時系列を出す
```

### Worker (013 からの変更)

- `setWebSocketAutoResponse(ping, pong)` で, 文字列 `ping` に `pong` を自動で返す. Durable Object は起きない.
- `/_ws` で新しい socket を受けると, 古い socket を code 4000 (`replaced`) で閉じる.
- 要求は, `readyState` が OPEN の socket のうち最後のものへ流す. 無ければ `503 agent not connected`.
- 要求の header `x-spike-stale-ms` が正で, ping の最終時刻がそれより古ければ `503 agent stale`.
- `/_status` に socket の `readyState` と ping の経過, 処理中の要求の数, Durable Object を作った後の経過 (`bootedAgoMs`) を出す. `/_version` は Worker の本体の版を返す.
- 失敗の範囲は 013 の申し送りのとおり socket ごと (閉じた socket の要求だけを失敗にする).

### client

- 切れたら, `min(30 秒, 0.5 秒 × 2^回数)` だけ待って繋ぎ直す. 開けたら回数を 0 に戻す. jitter は付けていない.
- `PING_MS` ごとに `ping` を送る. `PING_MS + PONG_TIMEOUT_MS` (既定 10 秒) の間に何も届かなければ, socket を破棄して繋ぎ直す.
- code 4000 で閉じられたら, 繋ぎ直さずに終わる (`RECONNECT_AFTER_REPLACED=1` で繋ぎ直す).
- SIGUSR2 を受けると, `ws.terminate()` で socket を破棄する.

## 測り方

- 配備: `worker/` で `bunx wrangler deploy --var SPIKE_TOKEN:<token> --var DEPLOY_N:<数>` を実行した. token が合わない要求は `403`. token は repo に入れていない. 名前は `padserver-relay-spike-<ランダムな 6 文字>`. Mac の上で `client/origin.ts` と `client/agent.ts` を動かした.
- 公開の要求: `scripts/measure.ts` が, 0.1 秒おきに順に `/ping` (client 経由で origin の `ok`), `/_status`, `/_version` を別々の loop で叩く. 1 回の要求が約 0.3 秒かかるので, 標本の間隔は約 0.4 秒. 時刻は同じ Mac の `Date.now()` で, 表の時刻は操作の時点 (t0) からの差.
- 回線の断: 実際のネットワークは落としていない. `SIGUSR2` で client が `ws.terminate()` を呼ぶ (close frame 無しの破棄). client の process の突然死は `kill -9` の後に新しい client を起動した. 半開きは `kill -STOP` で client を止め (kernel は TCP の ACK を返し続ける), `kill -CONT` で戻した. これは本物の半開き (パケットが落ちる) ではない. Wi-Fi と pf は触っていない.
- 配備: 測定の道具が `wrangler deploy` を実行した. 配備ごとに `--var DEPLOY_N` を変え, code を変える場合は `CODE_REV` の定数を書き換えた (配備の後に元に戻す). `/_status` と `/_version` の `rev` で, 動いているのが新しい版かを見分けた.
- 同じ測定を 3 回以上くり返した (長い測定は 3 回, 回線の断と process の死は 5 回).
- 注意: Bun の `proc.kill("SIGSTOP")` と `kill("SIGUSR2")` は macOS で別の signal に変わる (SIGSTOP が SIGCONT に, SIGUSR1 が SIGBUS になった). `kill` コマンドを使った.
- 測定の終わりに, `bunx wrangler delete --force` で Worker を削除した. 削除後に `bunx wrangler deployments list` を実行すると `This Worker does not exist on your account. [code: 10007]` が返り, 公開 URL も `404` を返した. 背景の process は全部止めた.

再現の手順 (`RELAY_URL` と `SPIKE_TOKEN` は環境変数).

```text
bun client/origin.ts &
bun scripts/measure.ts terminate 1
bun scripts/measure.ts kill 1
PING_MS=2000 bun scripts/measure.ts freeze 1 45
STALE_MS=8000 PING_MS=2000 bun scripts/measure.ts freeze 1 30
PING_MS=2000 bun scripts/measure.ts takeover 1
BUMP_CODE=1 PROBE_INTERVAL_MS=1000 DEPLOY_WAIT_MS=420000 bun scripts/measure.ts deploy 1
BUMP_CODE=1 bun scripts/measure.ts deploy-idle 1
bun scripts/measure.ts idle 1 600 0
```

## 結果

### (a) 回線の断: socket の破棄 (`terminate`)

client の `ws.terminate()` を, 接続が開いて約 3.5 秒後に呼んだ. 5 回の結果です (秒は切った時点から).

| 回 | relay が切れを見た (`sockets: []`) | 503 | client が `connecting` | WebSocket が開いた | 公開の要求が 200 に戻った |
| --- | --- | --- | --- | --- | --- |
| 1 | +0.14 | +0.11 | +0.51 | +0.94 | +1.22 |
| 2 | +0.14 | +0.11 | +0.51 | +0.98 | +1.22 |
| 3 | +0.02 | +0.23 | +0.51 | +0.69 | +0.98 |
| 4 | +0.14 | +0.22 (直前に 502) | +0.50 | +0.70 | +0.96 |
| 5 | +0.23 | +0.01 | +0.51 | +0.74 | +0.92 |

- 「relay が切れを見た」は, `/_status` の標本で最初に socket が 0 個になった時刻 (標本の間隔 0.4 秒に縛られる). 切れた socket が `getWebSockets` に残り続けることは無かった.
- client の `close` は `code=1006 reason=Connection ended`. 待ち時間は 0.5 秒 (backoff の最初の値) で, 開くまでに 0.18 から 0.47 秒かかった.
- 4 回目は, 切る直前に流れていた要求が `502 relay failure: agent disconnected` になった.

1 回の出力 (回 1) です.

```text
  +0.000s mark send SIGUSR2 (socket terminate)
  +0.010s A terminate-signal {}
  +0.011s A close {"code":1006,"reason":"Connection ended"}
  +0.011s A retry {"attempt":0,"delayMs":500}
  +0.512s A connecting {"attempt":1}
  +0.938s A open {"attempt":1}
  +0.112s public 503 agent not connected (took 158ms)
  +0.891s public 200 ok (took 324ms)
  +0.139s status 200 {"sockets":[],"pending":0,"bootedAgoMs":38329} (took 157ms)
  +0.916s status 200 {"sockets":[{"readyState":1,"pingAgeMs":null}],"pending":1,"bootedAgoMs":39122} (took 175ms)
```

### (a) 回線の断: client の process の突然死 (`kill -9`)

`kill -9` の直後に, 新しい client を起動した. 5 回とも, 新しい接続が開くまで 0.20 から 0.43 秒 (0.432, 0.257, 0.237, 0.231, 0.201). 起動と接続の合計です.

- 見えた失敗は, 回 1 と 3 で `503 agent not connected` が 1 標本, 回 2 で切れた瞬間の要求の `502 relay failure: agent disconnected` が 1 標本. 回 4 と 5 は標本の間に収まり, 失敗は見えなかった.
- 新しい socket が先に開き, 古い socket の close が後から届く順になっても, 新しい socket の要求は失敗しなかった (failAll が socket ごとのため). 013 の落とし穴は, 繋ぎ直しでは再発しなかった.

### (a) 半開き: client を止める (`kill -STOP`)

kernel が TCP を生かしたまま, process だけを止めた. ping は 2 秒おき.

| 設定 | 結果 |
| --- | --- |
| 45 秒止める (3 回) | relay は socket を閉じない. `pingAgeMs` は 1.7 秒から 42 秒まで伸びた (出力の下). 公開の要求は全部 5 秒の timeout. `pending` が 1 から 8 まで増えた. 戻すと, 溜まっていた要求が 0.13 から 0.15 秒で処理され, 接続は繋がったままだった |
| 30 秒止める, `x-spike-stale-ms: 8000` (3 回) | 止めて 10.43, 10.37, 10.41 秒で `503 agent stale` が返り始めた (最後の ping から 8 秒を超えた時点). 戻すと client の pong timeout が 0.01 から 0.08 秒で動き, 繋ぎ直した (0.69 から 0.76 秒) |
| 60 秒止める, ping 5 秒 (3 回) | relay は閉じない. 要求は全部 timeout. 戻した後は, 1 回は pong timeout で繋ぎ直し (0.7 秒), 2 回は繋がったまま処理された |

```text
  +0.2s status_sample 200 {"sockets":[{"readyState":1,"pingAgeMs":1706}],"pending":1,...}
  +10.3s status_sample 200 {"sockets":[{"readyState":1,"pingAgeMs":11905}],"pending":3,...}
  +40.6s status_sample 200 {"sockets":[{"readyState":1,"pingAgeMs":42154}],"pending":8,...}
```

- 戻した直後は, client の pong timeout の timer と, 溜まっていた message の処理のどちらが先かで, 繋ぎ直す場合と繋がったままの場合に分かれた. どちらでも動くが, 繋がったままの場合は, 止まっていた間の要求が遅れて処理される.
- 本物の半開き (パケットが落ちる) は試していない. client が自分で見つける時間は, `PING_MS + PONG_TIMEOUT_MS` 以内という設計の値で, 測っていない (止めた process では測れないため).

### (a) 古い socket が残る場合 (`takeover`)

client A を止め, client B を新しく繋いだ (3 回).

- B の接続は 0.20 から 0.27 秒で開いた. 公開の要求は B へ流れ, 200 が続いた.
- A の socket は `readyState` 2 (CLOSING) で, 8 秒の間 `getWebSockets` に残った (A が戻って close を返すまで).
- 013 の落とし穴 (死んだ socket が `getWebSockets` に残る) は, ここでも起きた. `readyState` が OPEN の socket だけに流す形で避けられた.
- A を戻すと, A は code 4000 `replaced` を受けて, 繋ぎ直さずに終わった (3 回). 繋ぎ直す設計だと, 2 つの client が互いに追い出し合う. 追い出された側は繋ぎ直さない取り決めが要る.
- 止める瞬間に A へ流れていた要求は, 1 回 (回 2) 5 秒の timeout になった. relay は, A の close が届くまで, その要求を失敗にしない.

```text
  +0.213s B open {"attempt":1}
  +8.022s A close {"code":4000,"reason":"replaced"}
  +8.022s A giving-up {"reason":"replaced"}
  +0.153s status 200 {"sockets":[{"readyState":1,"pingAgeMs":null},{"readyState":2,"pingAgeMs":1320}],"pending":24,...}
  +8.161s status 200 {"sockets":[{"readyState":1,"pingAgeMs":1970}],"pending":24,...}
```

### (b) relay の配備し直し (`wrangler deploy`)

client が繋がっていて, 0.1 秒おきに要求が流れている間に配備した (code を変えた回). `wrangler deploy` は 3.8 から 5.5 秒で終わった.

| 測定 | Worker の本体が新しい版になった | WebSocket が切れた | 繋ぎ直し |
| --- | --- | --- | --- |
| 変数だけ変更, 3 回 (40 秒見た) と, 1 回 (120 秒見た) | 配備の開始から約 3 から 5 秒 | 切れなかった (120 秒の間) | 不要 |
| code 変更, 3 回 (40 秒見た) | +3.1, +4.7, +5.6 秒 | 切れなかった (40 秒の間) | 不要 |
| code 変更, 3 回 (300 秒以上見た) | 約 4 秒 | +304.1, +304.2, +304.4 秒 (code 1006) | 開くまで 0.72, 0.77, 0.79 秒 (retry 0.5 秒, 接続 0.22, 0.27, 0.28 秒) |

- 切れるまで, Durable Object は古い code で動いた. 出力の `rev` が `r1792332323307/...` (古い) のまま, Worker の `/_version` だけが新しい版になった. 300 秒ほどたって Durable Object が作り直されると, 新しい版 (`bootedAgoMs` が 0) になって, 同時に WebSocket が切れた.
- 切れた時刻の前後 (1 秒おきの標本) で, 失敗した要求は見えなかった. 標本の間に収まった可能性がある.
- 同じ 3 回のうち 1 回 (回 9) は, 配備の 77.5 秒後にも, 配備と関係なく 1006 で切れた (下の「分からないこと」). このとき公開の要求は 3 秒の timeout が 1 標本, その後 4 秒で 200 に戻った.
- 配備の最中に流れていた stream (SSE, 600 件, 60 秒) は, 切れずに最後まで届いた (配備した 4 回すべて. 61 秒前後).
- 要求が流れていない Durable Object (30 秒の idle で hibernation に入っていた) に配備した 3 回は, WebSocket が切れなかった. 次に要求が来たとき, 新しい code で作り直された (`rev` が新しい版. `bootedAgoMs` が 0). client の `close` の記録は無し.

```text
SCENARIO deploy run=9
  +0.000s mark wrangler deploy start
  +4.602s mark wrangler deploy end exit=0
  +304.125s A close {"code":1006,"reason":"Connection ended"}
  +304.626s A connecting {"attempt":1}
  +304.848s A open {"attempt":1}
  +304.321s status 200 {"rev":"r1792332375307/1792332375307","sockets":[],"pending":0,"bootedAgoMs":0}
  +4.082s worker_version 200 r1792332375307/1792332375307
```

(上は読みやすさのために, 同じ出力から要点の行を抜いた. 実際の出力の `rev` は, 古い版から新しい版に変わる.)

### 無通信 (keepalive 無し) の接続

`PING_MS=0` で client を繋ぎ, 30 秒おきに要求を送った (1 回だけの測定です).

- 最初の 183 秒は 200 が続いた (253 から 303 ミリ秒). Durable Object は, 要求のたびに作り直されていた (hibernation).
- 213.5 秒に, client が 1006 で切れ, 0.7 秒で繋ぎ直した. 原因は分からない (client も relay も切っていない).
- その後, `/_status` に socket が 2 つ見え (`readyState` 2 と 1, しばらくして 1 と 1), 要求が 20 秒の timeout になり続けた (+264 秒の 1 回を除いて, 以降の観測すべて). `pending` は 1 から 12 まで増えた. client は繋ぎ直した 1 本しか持たないので, もう 1 本は client の側に無い socket だった. 新しい socket でなく, この socket に要求が流れたと考えられる (確かめていない).
- `PING_MS=20000` の 300 秒の測定では, 切れず, 200 が続いた (10 回).

## 判断

### backoff の値の目安

0.5 秒から始めて倍にし, 30 秒で止める形で足ります. 回線の断では, 最初の 0.5 秒で繋がるので, 2 回目以降の待ちは今回の測定には出ていません. 実際の回線の断 (数十秒続く) の挙動は未確認です. 次の 3 つを足します.

- jitter を付ける (配備し直しで多数の client が同時に切れても, 同時に繋がない). 今回の試験は client が 1 つなので効果は見ていない.
- 繋がったら回数を 0 に戻す. ただし, 開いた直後に切れることがくり返されたら, 戻さない (今回は試していない).
- code 4000 (`replaced`) で閉じられたら, 繋ぎ直さない. 繋ぎ直すと, 2 つの client が追い出し合う.

### keepalive の間隔

- 文字列の `ping` と `pong` の自動応答にします. Durable Object は起きず, 無料枠の時間を使いません. 20 秒の間隔で, 300 秒の間切れなかった.
- relay が `getWebSocketAutoResponseTimestamp` で最後の ping の時刻を読めるので, client が応答しなくなったことを relay の側で見つけられる. 今回は, 閾値 8 秒 (ping 2 秒の 4 倍) で, 止めてから 10.4 秒で検出した. 検出までの時間は, 閾値に最後の ping からの経過を足した値になる. ping の間隔と閾値の値は, iPad の背景の挙動 (#422) を見て決めます.
- client の側は, `ping` を送って `pong` が `PING_MS + PONG_TIMEOUT_MS` 以内に来なければ socket を捨てて繋ぎ直す. 止めた process を戻したときに, この処理が動いて繋ぎ直した. 本物の半開きでは, 試していません.
- ping を止めた (無通信) 場合に, 切れた socket が残って要求が戻らなくなる状態を 1 回観測した. ping があれば `pong` が返らないので, client は早く気づく.

### 繋がっていないときの応答

`503` で, 本文に `agent not connected` が返ります. 即座 (約 0.15 秒) に返り, 待たせません. 繋がった後は 200 に戻りました. 取り決めでは, 次の 3 つを区別します.

- 繋がっていない: `503`.
- 繋がっているが ping が古い (止まっている): `503` (試験では `agent stale`). 返さないと, 要求は無限に待つ.
- 流れている最中に切れた: `502`. 訪問者は再試行できる.

要求を待たせて, 繋がり直したら流す案は試していません. 配備し直しは 1 秒以内に繋がり直すので, 短く待つ価値はありますが, 待たせる時間の上限が要ります.

### 取り決め (M3-1, M3-13) への申し送り

- 新しい接続が来たら, 古い接続は追い出す (code 4000). 追い出された側は繋ぎ直さない.
- 要求を流す socket は, 接続した順で選ぶ. 今回は `readyState` が OPEN のものの最後を取ったが, `getWebSockets` の順序は保証されていない. 接続の時刻を `serializeAttachment` に入れ, 追い出した socket には印を付ける形にする (hibernation をまたぐ).
- 失敗の範囲は socket ごと (013 と同じ). 繋ぎ直しでも, 古い socket の close が遅れて届く順で, 新しい socket の要求は失敗しなかった.
- 追い出した socket の要求は, 追い出した時点で失敗にする. 今回は, 相手が応答するまで (止まった client だと無限に) 要求が待った.
- 流れている要求に, relay の側の待ち時間の上限を置く. 訪問者が先に切った要求の `pending` を片付ける (stream の `cancel` と, head を待っている間の切断).
- 配備では, Durable Object は約 5 分古い code のまま動く場合がある. Worker の本体が新しい版で, Durable Object が古い版の組み合わせが 5 分ほど続くので, frame の形を変える配備は, 古い版と新しい版の両方を受けられるようにする.
- 配備による切断は, 要求が流れている場合に約 5 分後に起きる. 切れた後の繋ぎ直しは 0.7 から 0.8 秒だった. 取り決めに, 配備の通知は要らない (client は切れたら繋ぎ直すだけで足りる).
- client は, 切れる瞬間に流れていた要求が失敗すること (`502`) を前提にする.
- app の前面に戻ったときに, すぐ繋ぎ直す処理 (M3-13) は, この spike の `connect` をそのまま呼べる形にしておく (背景の挙動は #422).

## 分からないこと

- 理由が分からない 1006 の切断が 2 回あった. 配備の 77.5 秒後 (ping 20 秒の client. 要求は 1 秒おき) と, 無通信の client の 213.5 秒後. どちらも client と relay は切っていない. Cloudflare の edge が切ったのかは, `wrangler tail` を見ておらず, 確かめていない.
- 無通信の測定で, `readyState` 1 の socket が client の側に無い状態で残り, 要求がそこへ流れたと考えているが, `takeover` と `ghost` (追い出した socket が hibernation をまたいでも `readyState` 2 のまま残ることを 3 回確認) では再現しなかった. 原因を特定していない.
- 配備後の「約 5 分」が, 要求の量, hibernation の有無, 無料プランと有料プランの違いで変わるか.

## 確かめていないこと

- アプリを背景に回す場合. iPad の実機が要るので #422 で行う.
- 本物の半開き (パケットが落ちる). `pf` や Wi-Fi の操作は Mac の他の作業に影響するので, 使っていない.
- 回線が数十秒から数分戻らない場合の backoff の伸び (30 秒の上限に届くまで).
- 多数の client が同時に切れた場合. client は 1 つだけだった.
- 繋ぎ直しの間に来た要求を待たせて, 繋がり直した後に流す案.
- 訪問者が先に切った要求が, 繋ぎ直しにどう影響するか (`pending` が残ることは観測した).
- 無料プランの Durable Object の使用量の上限に, 繋ぎ直しと ping が与える影響.

## 依存

`package.json` は 013 と同じ (`typescript` 5.9.3, `@types/bun` 1.4.3, `wrangler` 4.151.1, `@cloudflare/workers-types`). 型の検査は `bun run typecheck` です.
