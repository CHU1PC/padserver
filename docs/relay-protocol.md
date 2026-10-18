# relay の取り決め

PadServer のアプリ (iPad) と relay (Cloudflare の Worker と Durable Object) のやり取りを定めます. 版は 1 です (`padserver-relay.v1`).

この文書は M3 の実装の元になります. 読み手と使う所は次のとおりです.

| 実装 | 使う章 |
| --- | --- |
| M3-2 (Swift の frame), M3-4 (TypeScript の frame) | 4章, 付録, `relay/test-vectors/` |
| M3-5 (接続を受ける) | 3章, 9章 |
| M3-6 (公開の要求を運ぶ), M3-7 (大きい本文と取り消し) | 5章, 6章, 7章, 8章, 11章 |
| M3-8 (繋がっていないとき) | 9章, 12章 |
| M3-9 (配備の script) | 3.2 |
| M3-11 から M3-14 (アプリの接続, 繋ぎ直し, 要求の受け渡し) | 3章, 5章, 6章, 7章 |
| M3-17 (元のホスト名), M3-18 (公開と管理の分離の試験) | 8章, 13章 |

根拠は, M1 の検証の記録 ([013](../spikes/013-relay-streaming/README.md), [014](../spikes/014-relay-reconnect/README.md)) です. 「測った」と書いたものは, この 2 つの記録の実測を指します. 測っていない値は「暫定」と書き, 14章の表に理由を残しました.

## 1. 目的と前提

- iPad は自宅の NAT の内側にあり, 外からの接続を待ち受けません (決定 11, 42).
- アプリが relay へ WebSocket を 1 本張り, 張りっぱなしにします.
- 訪問者の HTTP の要求は relay が受けます. relay は要求を frame に小分けして, その WebSocket でアプリへ運びます. アプリは応答も frame に小分けして返します.
- relay は要求の中身を解釈しません. Range の解釈, 経路の解決, 認可は, アプリの側です.
- relay を通せるのは, 公開の要求 (配信の入口に届く要求) だけです. 管理 API は運びません (13章).
- WebSocket には背圧が無いので, 本文の frame には window と ack を付けます (6章). 付けないと, 遅い受け手に対して Durable Object が 3 秒で `Exceeded Memory Limit` になりました.

## 2. 用語

| 用語 | 意味 |
| --- | --- |
| 訪問者 | 公開の URL に HTTP の要求を送る側 |
| relay | Worker と Durable Object. 訪問者の要求を受けて, アプリへ運ぶ |
| アプリ | iPad の PadServer. relay へ WebSocket を張る |
| tunnel | アプリが relay へ張る WebSocket |
| frame | tunnel の 1 つの binary message |
| 要求の番号 | 1 つの訪問者の要求と, その応答を結ぶ 4 byte の整数 |
| chunk | 本文を小分けにした 1 つの塊 |
| window | 送り手が, ack を待たずに送ってよい本文の byte 数 |
| ack | 受け手が, 本文を何 byte 受け取ったかを送り手へ知らせる frame |

この文書の byte の数は, 特に断らない限り 10 進数です. 1 KiB は 1,024 byte, 1 MiB は 1,048,576 byte です. 複数 byte の整数は, すべて big endian (上位の byte が先) で書きます.

## 3. 接続

### 3.1 tunnel の確立

アプリは次の要求で WebSocket を開きます.

```http
GET /_padserver/tunnel HTTP/1.1
Host: <relay の host>
Upgrade: websocket
Connection: Upgrade
Authorization: Bearer <token>
Sec-WebSocket-Protocol: padserver-relay.v1
```

- 接続先の host は, 訪問者が使う host (workers.dev の名前, または割り当てた独自ドメイン) と同じです.
- path の `/_padserver/` で始まる要求は, relay が自分で処理します. アプリへは運びません. 訪問者の要求が `/_padserver/` で始まる場合, tunnel の確立を除いて `404` (`not found`) を返します. 試験用の spike の `/_ws` は, 訪問者の path と衝突するので使いません.
- relay は, token の検証の後に WebSocket を受け付けます (3.2). 検証の前に `acceptWebSocket` を呼びません.
- WebSocket は, Durable Object の hibernation の API (`acceptWebSocket`) で受けます (決定 42).
- アプリが繋がっていなければ, 訪問者の要求は `503` になります (9章).

### 3.2 認証

アプリが relay に繋ぐときの認証は, bearer token です (暫定. 14章の表を参照).

| 項目 | 決めたこと |
| --- | --- |
| 渡し方 | upgrade の要求の `Authorization: Bearer <token>`. query には載せない |
| 検証する所 | relay. WebSocket を受け付ける前 |
| token の形 | 32 byte の乱数 (暗号用の乱数生成器) を, base64url (padding 無し) で書いた 43 文字 |
| relay が持つもの | token の SHA-256 (小文字の 16 進, 64 文字). Worker の secret `TOKEN_SHA256` に置く. token そのものは持たない |
| 比べ方 | 受け取った token の SHA-256 を, 定数時間で比べる |
| 生成と配備 | 配備の script (M3-9) が, 配備のたびではなく, 初回の配備のときに token を作る. SHA-256 だけを secret に設定する. token は, 配備した人の端末に1度だけ表示する. file にもログにも残さない |
| アプリが持つもの | token を, Keychain に持つ (M3-15). 画面で入力する (M3-16) |
| 失敗 | `401` (本文 `unauthorized`). token が無い場合と, 合わない場合で同じ応答にする |

理由は次のとおりです.

- header に載せると, URL にも access log にも token が残りません. spike の `x-spike-token` は試験用の暫定の形です. 管理 API も `Authorization: Bearer` を使うので (admin-api の1章), 同じ書き方に揃えました. relay の token と管理 API の token は別のものです. 片方の漏れが, もう片方に及びません.
- relay に hash だけを置くと, Cloudflare の画面や secret の一覧から relay の設定が読まれても, 繋ぐための token は取り出せません. token は十分に長い乱数なので, 遅い hash (bcrypt など) は要らず, SHA-256 で足ります.
- iOS の WebSocket (`URLSessionWebSocketTask`) が, request の header を付けられることと, relay の Worker が upgrade の要求の `Authorization` を読めることは, 実機で確かめていません (15章).

token の更新 (差し替え) と, 失敗のくり返しへの制限は決めていません (14章の未決定).

### 3.3 1 つのアプリに 1 本の tunnel

- 同時に有効な tunnel は 1 本です. 新しく認証を通った接続が来たら, relay は古い接続を追い出します.
- 追い出すとき, relay は古い接続を close code 4000 (reason `replaced`) で閉じます. 古い接続に流れていた要求は, 閉じた事を待たずに, その場で失敗にします (`502`. 9章).
- 追い出された側 (code 4000 を受けたアプリ) は, 繋ぎ直しません. 繋ぎ直すと, 2 つのアプリが互いに追い出し合います.
- 追い出した接続は, close が相手に届くまで `readyState` が CLOSING のまま残ります. relay は, 追い出した接続に印を付けて (`serializeAttachment` の `replaced`), 要求を流しません. 要求を流す接続は, `readyState` が OPEN で, 印が無く, 接続の時刻が最後のものです. 接続の時刻も `serializeAttachment` に持ちます (hibernation をまたぐため).
- 古い接続の close が, 新しい接続の後に遅れて届いても, 新しい接続の要求を失敗にしません (11章の失敗の範囲).

### 3.4 keepalive

- アプリは, 文字列の message `ping` を 20 秒おきに送ります. relay は `setWebSocketAutoResponse` で `pong` を自動で返します. Durable Object は起きず, 無料枠の時間を使いません. 20 秒おきで 300 秒の間, 切れませんでした (測った).
- `ping` と `pong` は text の message です. frame ではありません. アプリと relay は, それ以外の text の message を無視します.
- アプリは, 繋がった直後にも `ping` を 1 回送ります.
- アプリは, `ping` を送って 10 秒たっても何も届かなければ, 接続を捨てて繋ぎ直します (半開きの検出). 止めた process を戻した場合に, この処理で繋ぎ直した (測った). 本物の半開き (パケットが落ちる場合) では, 試していません.
- relay は, 新しい要求を流す前に, 最後の `ping` の時刻 (`getWebSocketAutoResponseTimestamp`. 無ければ接続の時刻) を見ます. 60 秒より古ければ, アプリが止まっていると見なして `503` (`agent stale`) を返します. 返さないと, 要求は止まったアプリへ流れて, 戻りません (測った. 45 秒止めた間, 要求は全て待ち続けた).
- 20 秒, 10 秒, 60 秒は暫定です. 測ったのは ping 2 秒と, 閾値 8 秒 (10.4 秒で検出) と, ping 20 秒の無切断です. iPad が背景に回ったときの挙動 (#422) を見て決め直します.

### 3.5 繋ぎ直し

アプリは, tunnel が閉じたら, 次の表のとおりに繋ぎ直します.

| 閉じ方 | 繋ぎ直すか | 理由 |
| --- | --- | --- |
| close code 4000 (`replaced`) | 繋ぎ直さない | 別のアプリに追い出された. 繋ぎ直すと追い出し合う |
| upgrade が `401` | 繋ぎ直さない | token が合わない. 画面に出して, 設定の直しを待つ |
| upgrade が `400` (版が合わない) | 30 秒おきに繋ぎ直す | 配備の途中で, 古い Durable Object と新しいアプリの組み合わせになることがある. 配備が済めば直る |
| 1006, 1001, 1011, close code 4001, upgrade が 5xx, 回線のエラー, pong の timeout | 繋ぎ直す | 一時的な切断. 理由の分からない 1006 が 2 回あった (測った) ので, 必須 |

- 待ち時間は, `base = min(30 秒, 0.5 秒 × 2^回数)` を計算して, `base × (0.5 から 1.0 の乱数)` にします. 回数は 0 から数えます. 最初の待ちは 0.25 秒から 0.5 秒です. 測ったのは jitter 無しの 0.5 秒で, 切断から 0.69 から 0.98 秒で繋がりました. jitter は, 配備し直しで多数のアプリが同時に切れても, 同時に繋がないために付けます. 多数のアプリでの効果は見ていません.
- 回数を 0 に戻すのは, 接続が 10 秒以上開いていたときです. 開いた直後に切れることをくり返す場合に, 待ちが短いまま戻らないようにします (試していない).
- アプリが前面に戻ったときは, 待ちを飛ばして, 回数を 0 にして, すぐ繋ぎます. 繋がっているときは `ping` を送って, 10 秒以内に `pong` が無ければ捨てて繋ぎ直します. 背景での挙動は #422 で確かめます.
- tunnel が閉じたら, アプリは, その tunnel の上で処理していた要求を全て取り消します. 繋ぎ直した tunnel では, 要求の番号が 1 から数え直されるので, 古い要求の状態を持ち越しません.
- 配備し直すと, 要求が流れている Durable Object は約 5 分古い code のまま動き, その後に WebSocket が 1006 で切れます (測った. 切れた後, 0.7 から 0.8 秒で繋ぎ直った). 配備の通知は要りません. アプリは, 切れたら繋ぎ直すだけです.

### 3.6 版

- 版は整数です. WebSocket の subprotocol `padserver-relay.v<版>` で表します.
- アプリは, 話せる版を全て `Sec-WebSocket-Protocol` に並べます (`padserver-relay.v1, padserver-relay.v2` など). relay は, 共通の版のうち最も大きいものを, 応答の `Sec-WebSocket-Protocol` に 1 つ返します. 共通の版が無ければ `400` (`unsupported protocol version`) を返します.
- 新しい版を作るのは, 古い版の実装が読めなくなる変更のときです (frame の種類の追加, header の形の変更, byte の並びの変更). JSON の head に field を足す変更は, 版を上げません. 受け手は未知の field を無視します.
- 配備では, Worker の本体が新しい版で, Durable Object が古い版の組み合わせが約 5 分続きます. frame の形を変える変更では, 古い版と新しい版の両方を受けられる期間を置きます.
- subprotocol の交渉が Cloudflare の Durable Object で期待どおりに動くことは, 実機で確かめていません (15章).

## 4. frame

WebSocket の 1 つの binary message が, 1 つの frame です. 先頭の 5 byte が header で, 残りが payload です. 1 つの message に, 複数の frame を入れません.

### 4.1 header

| 位置 (byte) | 大きさ | 意味 |
| --- | --- | --- |
| 0 | 1 | 種類 (4.2) |
| 1 から 4 | 4 | 要求の番号. big endian の符号無し整数 |
| 5 から | 0 以上 | payload |

要求の番号は, relay が付けます. 次の規則です.

- 1 から始めて, 要求ごとに 1 ずつ増やします. 0 は割り当てません (将来, 接続全体に関わる frame のために空けてあります).
- relay の Durable Object が生きている間は, 同じ番号を再利用しません. Durable Object が作り直されたときは 1 に戻りますが, そのときは tunnel も閉じて, 古い要求は全て無くなっています.
- 番号が 0xFFFFFFFF を超える場合は 1 に戻し, 処理中の番号を飛ばします. 実際には起きません.
- アプリは, 要求の番号を, tunnel ごとに数えます. 古い tunnel の番号と, 新しい tunnel の番号を結び付けません.

### 4.2 種類

| 種類 | 値 | 向き | payload |
| --- | --- | --- | --- |
| `ReqHead` | 1 | relay からアプリ | JSON (4.3) |
| `ReqBody` | 2 | relay からアプリ | 要求の本文の chunk. byte 列 |
| `ReqEnd` | 3 | relay からアプリ | 無し |
| `ResHead` | 4 | アプリから relay | JSON (4.4) |
| `ResBody` | 5 | アプリから relay | 応答の本文の chunk. byte 列 |
| `ResEnd` | 6 | アプリから relay | 無し |
| `Cancel` | 7 | どちらからも | 無し |
| `Ack` | 8 | 本文を受けた側から, 送った側へ | 4 byte の符号無し整数 (big endian). 受け取った本文の byte 数 |

この値は spike の `protocol.ts` と同じです. header の形 (種類 1 byte, 要求の番号 4 byte, big endian) も同じです. spike の frame の byte 列は, この取り決めの frame として読めます (`ReqHead` の JSON に `host` が無い点を除く. 16章).

### 4.3 `ReqHead` の payload

UTF-8 の JSON です. 形は次のとおりです.

```json
{"method":"POST","path":"/upload?name=a%20b","host":"www.example.com","headers":[["content-type","text/plain"]],"hasBody":true}
```

| field | 型 | 意味 |
| --- | --- | --- |
| `method` | 文字列 | 大文字の HTTP method |
| `path` | 文字列 | `/` で始まる. 訪問者が送った path と query を, percent-encoding を変えずに, そのまま入れる |
| `host` | 文字列 | 訪問者が使った host. 8章 |
| `headers` | `[名前, 値]` の配列 | 11章の規則で選んだ header. 名前は小文字. 同じ名前を複数持てる. 並びは, 訪問者が送った順 |
| `hasBody` | 真偽値 | 本文が続くか (5章) |

全て必須です. 値は UTF-8 の文字列として運びます. header の値に日本語の文字があっても, JSON の中で `\u` に escape せず, UTF-8 の byte のまま書きます (見本: `req-head-utf8-header`).

### 4.4 `ResHead` の payload

UTF-8 の JSON です. 形は次のとおりです.

```json
{"status":200,"headers":[["content-type","text/plain; charset=utf-8"],["content-length","13"]]}
```

| field | 型 | 意味 |
| --- | --- | --- |
| `status` | 整数 | 200 から 599. 100 番台 (途中経過の応答) は運ばない |
| `headers` | `[名前, 値]` の配列 | 名前は小文字. `set-cookie` のように, 同じ名前を複数持てる |

### 4.5 JSON の書き方

- 書き手は, 空白を入れない 1 行の JSON で, field を上の表の順に並べます. 非 ASCII の文字は escape しません. 見本の byte 列は, この形です.
- 読み手は, field の順にも空白にも依らずに読み, 未知の field を無視します.
- JSON の payload は, byte の比較ではなく, 読んだ値の比較で試験します (付録). Swift の `JSONEncoder` と TypeScript の `JSON.stringify` で, field の順や `/` の escape が揃わないためです.

### 4.6 読むときの規則と, 不正な frame

不正な frame の扱いは, 3 つの層に分けます.

| 層 | 不正の中身 | 受け手がすること |
| --- | --- | --- |
| decode | message が 5 byte に満たない. 種類が 1 から 8 以外 | tunnel を close code 4001 (reason は `protocol error`) で閉じる |
| connection | `Ack` の payload が 4 byte でない. `ReqBody` と `ResBody` の payload が 1 MiB (1,048,576 byte) を超える | tunnel を close code 4001 で閉じる |
| request | `ReqHead` と `ResHead` の JSON が読めない, 必須の field が無い, 型が違う, `status` が範囲外, `path` が `/` で始まらない, header が組になっていない | その要求だけを失敗にする (relay は `502`, アプリは `Cancel`) |

- decode の層は, `decodeFrame` が返すか投げるかで決まります. 要求の番号は, 値を調べません. 0 でも受け付けます.
- 知らない要求の番号の frame は, 無視します. 取り消し (7章) のあとに, 相手の frame が遅れて届くのは普通のことです.
- `ReqEnd`, `ResEnd`, `Cancel` に余分な payload が付いていても, 無視します. 書き手は付けません.
- payload が 0 byte の `ReqBody` と `ResBody` は, 何もせずに受け取ります (`Ack` も返しません). 書き手は送りません.
- 1 MiB の上限は, 約 1 MiB の frame が通ったという実測 (frame 1,048,578 byte) に合わせた値です. これより大きい frame は試していません (15章).
- close code 4001 を受けたアプリは, 3.5 のとおり繋ぎ直します.

## 5. 要求と応答の流れ

### 5.1 1 つの要求の frame の順

relay からアプリへ:

```text
ReqHead  [ReqBody ...  ReqEnd]      (hasBody が true のときだけ, 角括弧の部分が続く)
```

アプリから relay へ:

```text
ResHead  [ResBody ...]  ResEnd
```

- `hasBody` が false の要求には, `ReqBody` も `ReqEnd` も続きません.
- `hasBody` が true の要求には, 0 個以上の `ReqBody` と, 1 つの `ReqEnd` が続きます. 本文が空 (0 byte) でも, `hasBody` が true なら `ReqEnd` を送ります.
- 応答は, 本文が無くても (HEAD, 204, 304, 本文が空の応答), `ResHead` の後に `ResEnd` が必ず続きます. それらの応答に `ResBody` を送らず, 届いても relay は捨てます.
- アプリは, 要求の本文が終わる前に, `ResHead` を返してかまいません (早い応答). 応答が先に終わった場合は 7章.
- 複数の要求は, 要求の番号で 1 本の tunnel に重ねます. frame の送出の順は, 準備ができた順です. 同時に複数の要求を流したときの公平さは測っていません (15章).

### 5.2 本文の小分け

| 向き | 規則 |
| --- | --- |
| 応答 (アプリから relay) | アプリは, 本文が手に入りしだい送ります. 溜めて大きくしません. 1 つの chunk は 256 KiB (262,144 byte) 以下を目安にして, 1 MiB (1,048,576 byte) を超えません |
| 要求 (relay からアプリ) | relay は, 訪問者の本文を 256 KiB になるまで溜めてから送ります. 本文が終わったら, 残りを送ります. 1 MiB を超えません |

- 要求の向きで溜めるのは, Durable Object が `request.body` を約 4 KiB ずつしか読めないためです. そのまま frame にすると, 50 MB で 12,211 個の frame になり遅くなりました. 溜めると 191 個になり, 4.2 から約 6 MB/s に上がりました.
- 応答の向きで溜めないのは, 少しずつ出る応答 (SSE) を, 溜めずに 1 件ずつ届けるためです. 遅れは, 中央値で 26 から 30 ミリ秒でした (測った).
- 256 KiB は, 64 KiB から約 1 MiB の間で速さに差が出なかったので, 選んだ目安です. 差は, 同じ大きさの回ごとのばらつきより小さく, 速さは Mac の回線で決まっていました.
- 要求の向きで, 本文が途中で止まった場合 (遅い送信者) の, 溜めた分を送る時間の上限は決めていません (14章).
- 本文の byte 数の上限は, 10章です.

## 6. 流量の制御

window と ack で, 送り手が, 受け手の処理より速く本文を送らないようにします.

| 項目 | 値 |
| --- | --- |
| window | 向きごと, 要求ごとに 4 MiB (4,194,304 byte). 取り決めで固定し, 交渉しません |
| 数える物 | `ReqBody` と `ResBody` の payload の byte 数. head と end と ack は数えません |
| ack の送り手 | 本文を受け取った側 |
| ack の中身 | 今回受け取った byte 数. 前の ack からの増分. 通算ではありません |

送り手の規則は次のとおりです.

- 送り手は, 要求ごと, 向きごとに「送った byte 数 - ack された byte 数」(inflight) を持ちます.
- 本文の chunk を送る前に, inflight が 4 MiB 以上なら, ack が来るまで送らずに待ちます. 待つのは, その要求の, その向きだけです. 他の要求は止めません.
- chunk を送る時点では, inflight が 4 MiB 未満なら送ってかまいません. そのため inflight は, 最大で 4 MiB + 1 MiB に近い値になります.
- 受け取った ack を, inflight から引きます. inflight が 0 未満になる場合は, 0 にします.

受け手の規則は次のとおりです.

- 応答の向き: relay は, chunk を訪問者の stream へ渡した (stream が `pull` した) ときに, その byte 数の `Ack` を返します. 訪問者が遅ければ, `pull` が遅れ, ack が遅れて, アプリが待ちます. relay が溜める本文は window の範囲に収まります.
- 要求の向き: アプリは, chunk を配信の入口へ渡したときに, その byte 数の `Ack` を返します.
- ack は, chunk ごとに 1 つ返します. まとめてもかまいませんが, 返していない byte 数が 256 KiB を超える前に返します. window (4 MiB) に対して, 1 chunk 分の遅れは, 送り手を止めません.
- 取り消した要求に対する ack は, 返しません. 届いたら, 知らない要求として無視します.

根拠の数字は次のとおりです (測った).

| 条件 | 結果 |
| --- | --- |
| window 無し. 500 MB を, 3,000 KB/s の遅い受け手へ流す | 2 回とも落ちた. 受け手が 149 MB と 156 MB を受けたところで止まり, WebSocket が 1006 で切れ, Durable Object が作り直された. `Exceeded Memory Limit` が出た. 張ってから 3 秒 |
| window 無し. 速い受け手 | 溜めた本文の最大が 43 MB から 87 MB (上限は 128 MB) |
| window 4 MiB. 同じ条件 | 3 回とも完走した (約 167 秒). 溜めた本文の最大は 4,456,412 byte |

window を 1 MiB から 16 MiB に変えても, upload の速さに傾向は見えませんでした. download の速さは, window 4 MiB でしか比べていません.

同時に流す要求の数の上限は, 暫定で 16 です. 1 つの応答で relay が溜める本文は, 最大で約 5 MiB (4 MiB + 1 MiB) なので, 16 本で約 80 MiB となり, Durable Object の上限 128 MB に収まります. 同時に複数の要求を流す試験はしていません. 16 を超える要求は, `503` (`relay busy`) です (9章).

## 7. 取り消しと終わり

### 7.1 `Cancel`

`Cancel` は, その要求を止めます. どちらの向きからも送れます. 送った側は, その要求の frame を, もう送りません. 受けた側は, その要求の処理を止めて, 状態を捨てます.

| 場面 | 送る側 | 受けた側がすること |
| --- | --- | --- |
| 訪問者が, 応答を読むのをやめた (stream の `cancel`), または接続を切った. `ResHead` の前も後も | relay | アプリは, 配信の入口の処理を止める. 本文の読み書きも止める |
| アプリが, 応答を続けられない (配信の入口の失敗, 要求を処理できない) | アプリ | relay は, `ResHead` の前なら `502` (`agent cancelled`) を返す. 後なら, 訪問者への stream を異常で終える |
| `ResEnd` が先に届いたのに, 要求の本文がまだ続いている (アプリの早い応答) | relay | アプリは, 要求の本文の受け取りを止める |
| 要求の head や本文の frame が不正 (request の層) | アプリ または relay | その要求だけを失敗にする |

- 訪問者が先に切った要求は, head を待っている間でも, relay の処理中の一覧から消します. spike では, head が届く前に切られた要求が一覧に残り続けました (測った). 一覧に残すと, 要求の番号の状態が溜まります.
- 取り消した要求の番号は, 再利用しません (4.1). 取り消しの後にアプリから届く frame は, 知らない番号として無視されるので, 別の要求の frame と取り違えません.
- relay は, 訪問者が切ったことを `Cancel` で伝えます. アプリが配信の入口の処理を止めたことの確認は, spike では取れていません (013 の申し送り). アプリ側の実装 (M3-14) の試験で確かめます.

### 7.2 要求が終わる条件

次のどれかで, その要求の状態を捨てます.

- 要求の側が終わり (`hasBody` が false, または `ReqEnd` を送った) かつ, 応答が終わった (`ResEnd` を送った, または受けた).
- `Cancel` を送った, または受けた.
- 要求が割り当てられた tunnel が閉じた (11章).

## 8. 元のホスト名の受け渡し

アプリは, 訪問者が使った host (サブドメインのプロジェクトの経路を選ぶために使います. 決定 25) を知る必要があります. 公開の要求は, Cloudflare を経て, relay が受けます. host は, 要求の header の `host` ではなく, `ReqHead` の `host` field に載せます.

- relay は, 訪問者の要求の URL の host (`new URL(request.url).host`. 小文字で, 既定の port を含まない) を, `host` に入れます.
- relay は, 訪問者が送った `host` header を, `headers` に入れません (11章). 訪問者が, 別の host を `host` field に紛れ込ませる経路を作りません.
- 訪問者が送った `x-forwarded-host`, `forwarded`, `x-forwarded-*`, `x-real-ip` も, `headers` に入れません.
- アプリは, tunnel から届いた `ReqHead` の `host` field だけを, 元のホスト名として信じます (M3-17). tailnet から直接届いた要求には, この field がありません. その要求の host に関わる header (`x-forwarded-host` など) を, 元のホスト名として読みません.
- アプリは, 大文字と小文字を区別せずに host を比べます.

## 9. 繋がっていないときと, エラー

### 9.1 エラーの一覧

relay が自分で作る応答です. 本文は短い英語の文字列 (改行無し) で, `content-type: text/plain; charset=utf-8` と `cache-control: no-store` を付けます. 表の `Retry-After` の欄に値があるものには, その秒数の `Retry-After` を付けます.

| status | 本文 | いつ | `Retry-After` |
| --- | --- | --- | --- |
| 400 | `unsupported protocol version` | tunnel の確立で, 共通の版が無い (3.6) | 無し |
| 401 | `unauthorized` | tunnel の確立で, token が無い, または合わない (3.2) | 無し |
| 404 | `not found` | 訪問者の要求の path が `/_padserver/` で始まる (tunnel の確立を除く) | 無し |
| 413 | `request body too large` | 要求の本文が 100 MiB を超えた (10章) | 無し |
| 501 | `websocket not supported` | 訪問者が WebSocket への upgrade を求めた | 無し |
| 502 | `agent disconnected` | 要求を処理していた tunnel が閉じた, または切れた | 無し |
| 502 | `agent replaced` | 要求を処理していた tunnel が追い出された (3.3) | 無し |
| 502 | `agent cancelled` | アプリが `ResHead` の前に `Cancel` を送った (7.1) | 無し |
| 502 | `invalid agent response` | `ResHead` が不正 (4.6 の request の層) | 無し |
| 503 | `agent not connected` | `readyState` が OPEN で, 印の無い tunnel が 1 本も無い | 5 |
| 503 | `agent stale` | 最後の `ping` が 60 秒より古い (3.4) | 5 |
| 503 | `relay busy` | 処理中の要求が 16 件ある (6章) | 1 |
| 504 | `agent timeout` | アプリからの応答が 60 秒来ない (12章) | 無し |

- 「繋がっていない」は `503` です. 即座に (約 0.15 秒で) 返します. 繋がった後は, 要求が通ります (測った). 要求を待たせて, 繋がり直したら流す案は, 試していないので取りません (14章).
- 「流れている最中に切れた」は `502` です. 訪問者は再試行できます. 切れる瞬間の要求が `502` になることを, アプリも訪問者も前提にします (測った).
- `Retry-After` の 5 秒は, 暫定です. 測った繋ぎ直しは 1 秒前後でしたが, 繋ぎ直しが失敗した場合の待ちは, 最大 30 秒まで伸びます. その間の目安として 5 秒にしました.
- `ResHead` を訪問者へ返した後は, status を変えられません. 後からの失敗 (tunnel の切断, `Cancel`, 12章の timeout) では, relay が訪問者への stream を異常で終えます. 訪問者は, 途中で切れた応答を受けます.
- 配備の script (M3-9) は, アプリが繋がる前でも, 公開の URL への `GET /` が `503` と `agent not connected` を返すことで, relay が動いていることを確かめられます.

### 9.2 エラーの範囲

- tunnel が閉じたとき, relay は, その tunnel に割り当てた要求だけを失敗にします. 他の tunnel の要求は失敗にしません.
- relay は, 要求を, 割り当てた tunnel (WebSocket) の参照と一緒に持ちます. frame は, 割り当てた tunnel から来たものだけを受け付けます.
- spike では, 古い socket が遅れて閉じたとき, 閉じた socket の要求だけでなく, 流れている全ての要求を失敗にして, 新しい socket の長い転送を失敗させました. 失敗の範囲を socket ごとにしたら, 再発しませんでした (測った).
- 追い出した tunnel の要求は, 追い出した時点で失敗にします (3.3). spike では, 相手が応答するまで, 止まったアプリだと無限に待ちました.

## 10. 要求の大きさの上限

- 要求の本文は, 104,857,600 byte (100 MiB) までです. 通った最大の大きさで, 1 byte 超えると, Cloudflare の edge が `413` を返しました. Content-Length を付けた場合と, 付けない (chunked) 場合で同じです (測った).
- 上限は, Cloudflare の edge が, Worker に渡す前に数えます. relay が本文を小分けにしても変わりません. 無料プランの実測の値です. プランによって上限が違う場合があります. 取り決めは, どのプランでも通る 100 MiB を上限にします.
- 上限を大きく超える要求では, `413` の代わりに `502` が返ることがありました (本文は `502 Bad Gateway`). どちらも edge が返し, Worker には届きません. この取り決めの上で動く道具と試験は, 本文が 100 MiB を超える要求への `413` と `502` の両方を, 「大きすぎる」として扱います. `502` は, relay の `502` (9章) とは, 本文で見分けます.
- relay も, 本文を数えて, 100 MiB を超えたら要求を止めて `413` を返します. edge が先に返す場合が大半なので, 防御の位置づけです.
- 応答の本文には, 上限を置きません. 500 MB の download を通しました (測った).
- Kikitoru の 500 MB までの音声の upload は, 1 つの要求では relay を通せません. 取り決めは 100 MiB までと定め, 経路は所有者が決めます (14章). 候補は, spike の記録の判断に書いてあります (公開の経路で運ぶ大きさに上限を置く, upload を relay を通さない経路に限る, 本文を 100 MiB 未満の複数の要求に分ける).

## 11. header の扱い

| 向き | 外す header | 通す header |
| --- | --- | --- |
| 要求 (relay が `ReqHead` を作るとき) | `host` (`host` field に移す), `connection`, `keep-alive`, `transfer-encoding`, `upgrade`, `forwarded`, `x-forwarded-*`, `x-real-ip`, `cf-*` | 上以外の全て. `content-length`, `range`, `authorization`, `cookie`, `accept-encoding` を含む |
| 応答 (relay が訪問者へ返すとき) | `transfer-encoding`, `connection`, `keep-alive`, `content-encoding` | 上以外の全て. `content-length`, `content-range`, `set-cookie` を含む |

- `content-length` は, そのまま通します. origin が付けた値を訪問者へそのまま返せました (測った). 要求の `content-length` は, アプリが大きさを先に知るための情報です. 本文の終わりは `ReqEnd` で決まります.
- 応答の `content-encoding` を外すのは, アプリが本文を圧縮しない前提のためです. 取り決めの版 1 では, アプリは, 応答を圧縮せず, `content-encoding` を付けません. 付いていても relay が外します. spike でも外していました. 理由は, spike の client が, 本文を既に展開して渡していたためです. Cloudflare の edge が, relay の応答を圧縮するかは, 確かめていません (15章).
- Range の解釈は, アプリがします. relay は, `range` の header と, `206`, `416`, `content-range` をそのまま運びます (測った).
- 要求の `cf-*` を外すと, 訪問者の IP がアプリに伝わりません. 伝えるかは未決定です (14章).
- `authorization` は, 訪問者が配信先 (Kikitoru の API など) に向けて送るものとして, そのまま通します. relay の tunnel の token ではありません.

## 12. 待ち時間の上限

試験用の relay には, relay の側の待ち時間の上限がありませんでした. 止まったアプリへ流れた要求は, 無限に待ちました (測った). 次の上限を置きます (暫定).

| 名前 | 値 | 数える間 | 超えたとき |
| --- | --- | --- | --- |
| 無通信の上限 | 60 秒 | relay が, 次にアプリからの frame を待っている間. `ReqHead` を送った後 `ResHead` を待つ間 (要求の本文を送っている間は, `Ack` が来るたびに数え直す) と, 応答の本文が途切れ, 訪問者が続きを読もうとしている間 | `ResHead` の前なら `504` (`agent timeout`). 後なら, stream を異常で終える. どちらも, アプリへ `Cancel` を送る |

- 訪問者が遅くて, relay が待たせている間 (window が埋まった間) は, 数えません. アプリが待たせる側ではないためです.
- 数えるのは, 1 つの要求の, アプリからの frame の間隔だけです. 全体の長さに上限は置きません. 140 秒の SSE が切れずに届きました (測った).
- 60 秒より長く何も出さない応答 (長い待ちの API, 間隔の空く SSE) は, 切れます. SSE は, 60 秒より短い間隔で何かを送る必要があります. 20 秒おきの SSE は届きました (測った). 値は暫定で, Kikitoru の API の待ちを見て決め直します (14章).
- tunnel の死活は, 3.4 の `ping` で見ます. この上限は, tunnel が生きていてアプリが応答しない場合の最後の備えです.

## 13. 公開と管理の分離

決定 5 と 43 のとおり, インターネットから届くのは配信だけで, 管理は tailnet の中からだけです. relay は, 次の形でそれを守ります (M3-18 の試験の前提).

- tunnel は, 訪問者の HTTP の要求と, その応答だけを運びます. 管理のための frame も field も, 取り決めにありません.
- relay が運ぶ要求は, 公開の host に届いた, 訪問者の要求だけです. relay は管理 API の path を知りませんし, 特別な扱いもしません.
- アプリは, tunnel から届いた要求を, 配信の入口 (公開の経路の解決) にだけ渡します. 管理 API の待ち受けには渡しません. 管理 API の path は `/v1` で始まりますが, tunnel から `/v1/...` の path が届いても, 配信の入口の経路として解決されます (経路が無ければ `404`). 管理の処理は動きません.
- tunnel から届いた要求に `Authorization: Bearer` が付いていても, 管理 API の認証には使いません. 訪問者の `authorization` は, 配信先のアプリへ向けたものです (11章).
- relay の token は, tunnel の認証だけに使います. 管理 API の token とは別です (3.2).

M3-18 の試験で固定する性質は, 次のとおりです. 管理 API の全 endpoint の path と method を `ReqHead` に入れても (`host` と header は任意), 管理の処理が一つも動かず, 配信の入口の応答 (`404` か, その path に割り当てた経路の応答) が返ります.

## 14. 決めたことと未決定

### 14.1 決めたこと

| 項目 | 決めたこと | 根拠 |
| --- | --- | --- |
| tunnel の形 | アプリが relay へ WebSocket を 1 本張り, 公開の要求を frame に小分けして運ぶ | 決定 42 |
| frame の header | 種類 1 byte, 要求の番号 4 byte (big endian). 種類は 8 つ (4.2) | spike 013 (frame の種類で足りた) |
| 要求の重ね方 | 要求の番号で, 1 本の tunnel に複数の要求を重ねる | spike 013 の申し送り |
| chunk の大きさ | 256 KiB を目安. 1 MiB を超えない | spike 013 (64 KiB から約 1 MiB で速さに差が無い. 約 1 MiB の frame が通った) |
| 要求の向きの溜め方 | 256 KiB まで溜めてから frame にする | spike 013 (`request.body` が約 4 KiB ずつ) |
| 背圧 | window 4 MiB と ack を, 両方向に置く | spike 013 (無いと 3 秒で `Exceeded Memory Limit`) |
| 要求の大きさ | 100 MiB (104,857,600 byte). `413` と `502` の両方を「大きすぎる」と扱う | spike 013 (edge の上限) |
| 失敗の範囲 | tunnel (socket) ごと. 追い出した tunnel の要求は, その場で失敗にする | spike 013 と 014 |
| 追い出し | 新しい認証済みの接続が, 古い接続を code 4000 で追い出す. 追い出された側は繋ぎ直さない | spike 014 |
| 要求を流す tunnel | `readyState` が OPEN で, 追い出しの印が無く, 接続の時刻が最後のもの | spike 014 (`getWebSockets` の順序は保証されない) |
| 繋がっていないとき | `503` (`agent not connected`). 最中に切れたら `502` | spike 014 |
| 止まったアプリ | 最後の `ping` が古ければ `503` (`agent stale`) | spike 014 (10.4 秒で検出した) |
| keepalive の方式 | text の `ping` と `pong` の自動応答 | spike 014 (Durable Object が起きない) |
| 繋ぎ直しの形 | 0.5 秒から 30 秒の指数の backoff に jitter を付ける. 認証の失敗と追い出しでは繋ぎ直さない | spike 014 |
| header の扱い | `content-length` は通す. `content-encoding`, `transfer-encoding`, `connection`, `keep-alive` は外す | spike 013 |
| 元のホスト名 | `ReqHead` の `host` field. アプリは tunnel 経由の要求のときだけ信じる | 決定 25 |
| 認証の形 | `Authorization: Bearer`. relay は token の SHA-256 を持つ. token は Keychain に持つ | 3.2. 決定 87 |
| 版の表し方 | WebSocket の subprotocol `padserver-relay.v<整数>` | 3.6. 決定 87 |
| tunnel の path | `/_padserver/tunnel`. `/_padserver/` で始まる path は relay が自分で処理する | 3.1. 決定 87 |
| 公開と管理の分離 | tunnel は公開の要求だけを運び, アプリは配信の入口にだけ渡す | 決定 5 と 43 |

### 14.2 未決定

| 項目 | 暫定の選択 | 暫定にした理由 | 決める人と時期 |
| --- | --- | --- | --- |
| Kikitoru の 500 MB の upload の経路 | 取り決めは 100 MiB まで. 経路は決めない | 100 MiB の上限は Cloudflare の edge の値で, 取り決めでは越えられない. 選択肢 (10章) は, 運用の形を変える | 所有者. M6-2 の前 (roadmap の U18) |
| ping の間隔 (20 秒), pong の待ち (10 秒), stale の閾値 (60 秒) | 左の値 | 測ったのは, ping 2 秒と, ping 20 秒の無切断だけ. iPad の背景での挙動が分からない | 本体. #422 の後 |
| 無通信の上限 (60 秒) | 60 秒 | 試験用の relay に上限が無く, 値の実測が無い. 20 秒おきの SSE は届いた | 本体. Kikitoru の API を通した後 |
| 同時に流す要求の上限 | 16 | window から計算した値で, 同時に複数を流す試験をしていない | 本体. M3-7 の試験の後 |
| `Retry-After` の値 | 5 秒 (`relay busy` は 1 秒) | 繋ぎ直しが失敗したときの待ちの長さの目安 | 本体 |
| token の更新 | 更新は, 新しい token を作って, SHA-256 の secret を置き換える. 既に繋がっている tunnel は, 次に切れるまで有効 | 強制的に切る手段が, 今は無い | 所有者 |
| 認証の失敗への制限 | 設けない | token が 256 bit の乱数で, 当てられない | 本体 |
| 訪問者の IP の受け渡し | 運ばない (`cf-*` と `x-forwarded-*` を外す) | 要る配信先が, まだ無い. 個人情報を含む | 所有者 |
| 訪問者の WebSocket の中継 | 運ばない (`501`) | 要る配信先が, まだ無い. 試験もしていない | 所有者 |
| 繋がっていない間の要求を待たせる案 | 待たせず `503` | 試していない. 待たせるなら, 時間の上限が要る | 本体 |
| 要求の向きの溜めの上限時間 | 無し | 遅い送信者で, 256 KiB に満たない本文が, 溜まったまま止まる. 本文の終わりか 256 KiB で送る | 本体 |
| 取り決めの版の上げ方の細目 | 3.6 のとおり | 版 2 を作る事態が, まだ無い | 本体 |

### 14.3 決定の記録

この文書で決めたことのうち, 取り決めの版と frame の形 (項目87), 認証と tunnel の path (項目88) を, [decisions.md](decisions.md) に記録しました.

## 15. 確かめていないこと

- iPad の実機の回線と, アプリでの速さ. 値は, Mac の上の client の測定です.
- iPad が背景に回ったとき, 前面に戻ったときの接続 (#422).
- 長い待ちの間の hibernation. 30 秒おきの要求では, hibernation に入っても WebSocket は切れず, 遅れも変わりませんでした. 要求が流れている間は, Durable Object は起きたままでした.
- 同時に複数の要求を流したときの速さと公平さ.
- 1 MiB を超える frame の挙動.
- 本物の半開き (パケットが落ちる場合).
- 無通信 213 秒後に 1006 で切れた原因と, 配備の 77.5 秒後に 1006 で切れた原因. どちらも, client と relay は切っていません. 繋ぎ直しで備えます.
- 切れた socket が `readyState` 1 のまま残り, 要求が戻らなくなった状態 (1 回観測. 再現していない). 無通信の上限 (12章) と `ping` (3.4) で備えます.
- 訪問者が先に切った要求の, 繋ぎ直しへの影響.
- iOS の `URLSessionWebSocketTask` で `Authorization` を付けること. Durable Object が subprotocol を返す形.
- Cloudflare の edge が, 応答を圧縮するか.
- 多数のアプリが同時に切れたときの jitter の効果.
- Durable Object の実際のメモリ使用量. 完走したことと, 溜めた本文の最大 byte 数で代えました.
- 無料プランの使用量の上限に, 数百 MB の転送と繋ぎ直しと `ping` が与える影響.
- 上限を超える `502` が返る条件.
- upload が, relay を通すと `/_sink` (Worker だけ) より遅い原因.

## 16. spike との差

spike の `protocol.ts` は暫定の取り決めです. この文書は, 次の点で異なります.

| 点 | spike | この取り決め | 理由 |
| --- | --- | --- | --- |
| `ReqHead` の `host` | 無し. 訪問者の `host` header を捨てていた | 必須の field | 元のホスト名をアプリが知るため (8章) |
| tunnel の path | `/_ws` | `/_padserver/tunnel` | 訪問者の path と衝突させないため |
| 認証 | `x-spike-token` header (全ての要求に) | tunnel の確立で `Authorization: Bearer` | 本番の形 (3.2) |
| 追い出しの close code | 013 は 1000, 014 は 4000 | 4000 | アプリが繋ぎ直さない印にするため |
| 追い出した tunnel の要求 | 応答まで待つ | その場で `502` | 止まったアプリで無限に待つため |
| window | 要求の向きは訪問者の header で変えられる | 4 MiB に固定 | 取り決めを単純にするため |
| 不正な frame | decode だけ (短い, 未知の種類) | 3 層 (4.6) | 受け手ごとの扱いの差を無くすため |
| 版 | 無し | subprotocol | 配備の途中で, 古い版と新しい版が混ざるため |

frame の包み方 (header と payload の並び) は同じです. 付録の見本のうち, 大きさの境界を表す繰り返しの 2 つ (`res-body-256kib`, `res-body-1mib`) を除く全ての frame が, spike の `decodeFrame` で同じ種類, 同じ番号, 同じ payload に読め, `encodeFrame` で同じ byte 列になります. 違うのは, `ReqHead` の JSON の中身 (`host`) だけです.

## 付録 試験用の byte 列の見本

`relay/test-vectors/` に, frame の byte 列の見本があります. M3-2 (Swift) と M3-4 (TypeScript) は, この見本で試験します. 形式と使い方は, [relay/test-vectors/README.md](../relay/test-vectors/README.md) に書きました.
