# PadServer

iPad を, 前面に固定したアプリ1つで動くサーバーにします.
静的サイトと, Docker の container で動くサービスを, 独自ドメインで配信します.

開発を始めたところで, まだ動くものはありません.

clone 後に `scripts/bootstrap.sh` を1回実行すると, 開発用ツールが入り, commit hook が有効になります.

## 文書

| 文書 | 内容 |
| --- | --- |
| [docs/roadmap.md](docs/roadmap.md) | 全体像, 決めたこと, 計画表 |
| [docs/decisions.md](docs/decisions.md) | 決定を決めた順に並べた記録 |
| [ipad-server-feasibility.md](ipad-server-feasibility.md) | iPadOS の制約についての調査メモ |
| [docs/pull-requests.md](docs/pull-requests.md) | PR の作り方と, merge の規則. 全ての PR で README を更新する |
| [AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md) | merge 係の手順と, Codex との連絡の規則 (同じ内容) |

## ライセンス

MIT です. [LICENSE](LICENSE) にあります.

## Keychain への保存

内部部品の `KeychainSecretStore` が, 管理 token とプロジェクト別の secret を Mac と iOS の Keychain に保存します.
通常の試験はメモリ内の代替実装を使い, 実 Keychain に触れません.

Mac で実 Keychain を確認する結合試験は, 明示して実行します.
この試験は一意な project 名の一時項目を作り, 保存, 取得, 更新, 一覧, 削除を確認して片付けます.
既存の管理 token は使いません.

```sh
PADSERVER_KEYCHAIN_INTEGRATION=1 swift test --package-path Packages/PadServerCore --filter KeychainSecretStoreIntegrationTests
```

実際の実行結果です.

```text
✔ Test storesReadsUpdatesListsAndDeletesInRealKeychain() passed after 0.072 seconds.
✔ Suite KeychainSecretStoreIntegrationTests passed after 0.072 seconds.
✔ Test run with 1 test in 1 suite passed after 0.072 seconds.
```
