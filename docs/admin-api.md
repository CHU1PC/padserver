# 管理 API

PadServer の管理 API は, tailnet 内の `padctl` からプロジェクトを配備し, 状態を操作し, ログを読むための HTTP API です. この文書は M2 の範囲を定めます.

## 1. 接続と認証

全 endpoint は管理用 port で受け付け, relay と公開用の待ち受けには接続しません. 接続元 IP が Tailscale の IPv4 範囲 `100.64.0.0/10` または IPv6 範囲 `fd7a:115c:a1e0::/48` に含まれ, token が有効な場合だけ要求を許可します.

認証には全要求で次の header を付けます.

```http
Authorization: Bearer <token>
```

token が無い場合と無効な場合は `401 Unauthorized` を返します. token が有効でも接続元 IP が tailnet の範囲外なら `403 Forbidden` を返します. 管理 API は TLS をここでは終端せず, tailnet の暗号化された経路で利用します.

## 2. 版と JSON

全 endpoint の path は `/v1` から始まります. 互換性のない変更は新しい版の path に追加し, `/v1` の意味は変えません. 未知の版の path は `404 Not Found` とします.

JSON のキーは lower camel case とし, domain 型の値と対応させます. 例では `ProjectName` は文字列, `ProjectKind` は `staticSite` または `compose`, `ReleaseID` は UUID 文字列, `ReleaseState` は `preparing`, `active`, `retired` のいずれかです. `ProjectManifest` は `name`, `root`, `routes` を持ち, 現在の `Codable` に合わせて route の `pathPrefix` は `path_prefix` として送ります. 日時の wire format は未確定で, #50 で通信型と一緒に固定します.

## 3. Endpoint 一覧

| Method | Path | 用途 |
| --- | --- | --- |
| `POST` | `/v1/projects/{name}/deployments/diff` | 配備対象と端末側の blob を照合し, 未受領の blob を返す |
| `PUT` | `/v1/blobs/{hash}` | blob を streaming で受け取る |
| `POST` | `/v1/projects/{name}/deployments` | blob が揃った配備を確定し, release を有効にする |
| `GET` | `/v1/projects` | プロジェクトと稼働状態の一覧を返す |
| `POST` | `/v1/projects/{name}/start` | プロジェクトを開始する |
| `POST` | `/v1/projects/{name}/stop` | プロジェクトを停止する |
| `GET` | `/v1/logs/stream` | 直近のログを返してから新しいログを streaming する |

`{name}` は `ProjectName` として検証します. 配備の M2 wire 例は静的サイトの `ProjectManifest` を使います. compose の manifest と配備ファイル一覧は M5 の仕様対象です.

## 4. 配備

配備は差分確認, blob 送信, 確定の順に行います. ファイル一覧は project-relative path と blob hash の組で表します. 同じ内容の blob は一度だけ送れます.

### 4.1 差分確認

`POST /v1/projects/{name}/deployments/diff` は次の JSON を受け取ります. path の `name` と `manifest.name` は同じ値にします.

```json
{
  "manifest": {
    "name": "example-site",
    "root": "dist",
    "routes": [
      {
        "host": "www.example.com",
        "path_prefix": "/"
      }
    ]
  },
  "files": [
    {
      "path": "dist/index.html",
      "hash": "<content-hash>"
    }
  ]
}
```

成功時は `200 OK` とし, 端末側に無い blob の参照を返します. 空配列なら送信対象はありません.

```json
{
  "missingBlobs": [
    {
      "path": "dist/index.html",
      "hash": "<content-hash>"
    }
  ]
}
```

### 4.2 blob の受領

`PUT /v1/blobs/{hash}` は `application/octet-stream` の request body を受け取ります. body は全体をメモリに読み込まず, 到着した順に streaming で保存します. body の終端で hash を検証し, 一致した blob だけを保存済みとして扱います. 不一致または中断した受信は部分データを blob として公開せず, 同じ hash で再送できます.

受領に成功したら `201 Created` を返します. すでに同じ hash の blob があれば `204 No Content` を返し, body は保存しません. 受信中にクライアントが接続を閉じた場合は保存を中断して一時データを破棄します. サーバーはその要求に応答を返せないため, クライアントは再接続後に差分確認を行います.

request body の上限は設けますが, 数値はまだ決まっていません. 上限超過は `413 Payload Too Large` とし, #73 の実装前に上限値を別途決めます. hash のアルゴリズム, 表記, 形式も未確定です.

### 4.3 配備の確定

`POST /v1/projects/{name}/deployments` は差分確認と同じ形の JSON を受け取ります. 全 blob が揃い, manifest とファイル一覧が検証できた場合にだけ release を作成し, 有効な release を原子的に切り替えます. 足りない blob がある場合は `409 Conflict` とし, 有効な release を変えません.

成功時は `201 Created` とし, 新しい release を返します.

```json
{
  "project": {
    "name": "example-site",
    "kind": "staticSite"
  },
  "release": {
    "id": "00000000-0000-4000-8000-000000000001",
    "project": "example-site",
    "state": "active"
  }
}
```

release の `state` は `ReleaseState` と一致します. 配備確定後にプロジェクトが開始状態になるか, 同時配備をどう扱うか, 再試行を同じ結果にするかは未確定です.

## 5. 状態と開始・停止

`GET /v1/projects` は `200 OK` とし, プロジェクトごとに `Project`, 有効な `Release` または `null`, `running` を返します. 稼働状態は release の状態とは別の値です.

```json
{
  "projects": [
    {
      "project": {
        "name": "example-site",
        "kind": "staticSite"
      },
      "activeRelease": {
        "id": "00000000-0000-4000-8000-000000000001",
        "project": "example-site",
        "state": "active"
      },
      "running": true
    }
  ]
}
```

`POST /v1/projects/{name}/start` と `POST /v1/projects/{name}/stop` は request body を持ちません. 成功時は `200 OK` とし, 更新後の同じ状態表現を返します.

```json
{
  "project": {
    "name": "example-site",
    "kind": "staticSite"
  },
  "activeRelease": {
    "id": "00000000-0000-4000-8000-000000000001",
    "project": "example-site",
    "state": "active"
  },
  "running": false
}
```

存在しないプロジェクトは `404 Not Found` とします. 有効な release が無いプロジェクトの開始, すでに同じ状態のプロジェクトへの再要求の扱いは未確定です.

## 6. ログ streaming

`GET /v1/logs/stream` は `200 OK` とし, `Content-Type: application/x-ndjson` で返します. 各行は `LogEntry` 1件の JSON で, JSON の終端に改行を付けます. 接続直後に直近1,000件を時刻順に送り, 続けて新しいログを到着順に送ります. ログ行の例は次の通りです.

```json
{"timestamp":"<date-time>","source":"web","level":"info","message":"Started"}
```

`LogEntry` の項目は `timestamp`, `source`, `level`, `message` です. `level` は `debug`, `info`, `warning`, `error` のいずれかです. 日時の wire format は #50 で固定します. 接続を閉じるとその購読を解除し, サーバー側のログ生成や他の購読者には影響しません. クライアントが切断した場合, サーバーは当該 stream の送信を止めて購読を終了します.

M2 ではログ stream に対する絞り込み, 再開 cursor, 過去ログの保持期間は定めません. 後続で絞り込みが必要な場合は, 通信型との整合を確認して追加します.

## 7. エラー応答

認証を通過した要求のエラーは `application/json` で返します. `code` は機械判定用の安定した文字列で, `message` は利用者向けです. token, request body の secret, stack trace は含めません.

```json
{
  "error": {
    "code": "project_not_found",
    "message": "Project was not found."
  }
}
```

| HTTP status | 用途 | code の例 |
| --- | --- | --- |
| `400 Bad Request` | JSON 不正, 入力値不正 | `invalid_request` |
| `401 Unauthorized` | token が無い, または無効 | `unauthorized` |
| `403 Forbidden` | 接続元 IP が tailnet の範囲外 | `forbidden` |
| `404 Not Found` | project または endpoint が無い | `project_not_found` |
| `409 Conflict` | 必要な blob が無い, 現在の状態で操作できない | `deployment_incomplete` |
| `413 Payload Too Large` | blob の上限を超えた | `payload_too_large` |
| `500 Internal Server Error` | 予期しないサーバーエラー | `internal_error` |

## 8. #50 以降で確定する項目

この文書は endpoint の境界と処理の約束を定めます. 通信型の実装に入る前に, 次の値と wire-level の細部を確定します.

- hash のアルゴリズムと文字列表現.
- blob の最大受信サイズ. 大きさは根拠なくこの文書で定めません.
- `Date` の JSON 表現とエラー `code` の正式な一覧.
- 同時配備, 配備の冪等性, 初回配備時の稼働状態.
- 直近1,000件の送信中に到着した新規ログとの順序保証と重複回避.
- compose 配備の manifest とファイル構成. M5 の範囲で定めます.
