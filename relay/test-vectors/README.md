# relay の frame の見本

[docs/relay-protocol.md](../../docs/relay-protocol.md) の 4章の frame の, 試験用の byte 列です. M3-2 (Swift) と M3-4 (TypeScript) が, 同じ見本で encode と decode を試験します.

byte 列は, 文書の規則だけから計算しました. spike の `protocol.ts` (`spikes/013-relay-streaming/shared/protocol.ts`) の `decodeFrame` と `encodeFrame` でも, 繰り返しの 2 つを除く全ての見本が一致することを確かめました.

## ファイル

| ファイル | 中身 |
| --- | --- |
| `frames.json` | 正しい frame の見本. encode と decode の両方で使う |
| `invalid-frames.json` | 不正な frame の見本と, 受け手の扱い (4.6) |

## `frames.json`

最上位は `protocol` (版の名前) と `frames` (見本の配列) です. 見本 1 つの field は次のとおりです.

| field | 意味 |
| --- | --- |
| `name` | 見本の名前. 試験の名前に使う |
| `description` | 何を確かめる見本か |
| `frame.type` | 種類の名前 (`ReqHead` など) |
| `frame.typeValue` | 種類の値 (1 から 8) |
| `frame.id` | 要求の番号 |
| `frame.payload` | payload の論理的な内容. 次の表のどれか 1 つ |
| `hex` | frame 全体の byte 列. 小文字の 16 進で, 区切りは無い |
| `headerHex`, `totalLength` | `hex` の代わりに, 大きい見本で使う. frame の先頭 5 byte と, frame 全体の byte 数 |
| `decodeOnly` | `true` なら, decode だけを試験する. 書き手は, この形を作らない |

`frame.payload` の形です.

| 形 | 意味 |
| --- | --- |
| `{"json": <値>}` | JSON の payload. 値は読んだ後の形 |
| `{"utf8": "文字列"}` | 文字列を UTF-8 にした byte 列 |
| `{"hex": "00ff"}` | byte 列そのもの. 空の payload は `""` |
| `{"ackBytes": 262144}` | `Ack` の payload. 4 byte の符号無し整数 (big endian) |
| `{"repeat": {"byteHex": "61", "count": 262144}}` | 1 byte を `count` 回くり返した byte 列. 大きさの境界を表す見本で使う |

### 試験のやり方

- decode: `hex` を `decodeFrame` に渡して, 種類, 要求の番号, payload が `frame` と一致することを確かめます. `json` の payload は, 読んだ値を比べます. `decodeOnly` の見本も, ここで使います.
- encode: `decodeOnly` でない見本について, `frame` から作った frame が `hex` と一致することを確かめます. `json` の payload は byte では比べず, encode した frame を decode して, 値が一致することを確かめます (4.5. 言語によって JSON の field の順と escape が揃わないため). `json` 以外の payload は, byte 列が一致します.
- 大きい見本 (`repeat`): frame を作って, 先頭 5 byte が `headerHex`, 全体の大きさが `totalLength` に一致することを確かめます. decode は, 同じ大きさの byte 列で行います.

見本の JSON の byte 列は, 空白の無い 1 行で, field が表の順 (`ReqHead` は `method`, `path`, `host`, `headers`, `hasBody`) で, 非 ASCII の文字を escape しない形です. 書き手は, この形に揃えることを勧めますが, 試験では求めません.

## `invalid-frames.json`

最上位は `protocol` と `invalidFrames` です. 見本 1 つの field は次のとおりです.

| field | 意味 |
| --- | --- |
| `name`, `description` | `frames.json` と同じ |
| `hex` | frame 全体の byte 列. 大きい見本では `headerHex`, `payload.repeat`, `totalLength` を使う |
| `expect.level` | `decode`, `connection`, `request` のどれか (4.6) |
| `expect.reason` | 理由の目安 (試験で文字列を比べる必要はありません) |

| `expect.level` | 試験で確かめること |
| --- | --- |
| `decode` | `decodeFrame` が失敗する |
| `connection` | `decodeFrame` は成功する. その後の検査 (`Ack` の大きさ, 本文の chunk の大きさ) が失敗して, tunnel を閉じる扱いになる |
| `request` | `decodeFrame` は成功する. head の JSON の検査が失敗して, その要求だけが失敗になる |

## 再現

見本は, 次の手順で作りました. 手で計算した byte 列を, 別の手順 (struct を使わない組み立て) で組み直した byte 列と照らして, 全て一致することを確かめました.

- frame: 1 byte の種類, 4 byte の要求の番号 (big endian), payload の順に並べる.
- JSON の payload: 空白の無い 1 行の JSON で, 非 ASCII の文字を escape せず, UTF-8 にする.
- `Ack` の payload: 受け取った byte 数を, 4 byte の符号無し整数 (big endian) にする.
