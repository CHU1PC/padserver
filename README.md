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

## ログの配信

内部部品の `InMemoryLogBus` は, 複数の購読者にログを流します.
後から接続した購読者には直近1,000件を先に渡し, その後のログも渡します.
購読者ごとの未読ログも最大1,000件とし, 遅い購読者の古い未読ログを捨てることで, 他の購読者を止めません.

`swift test --package-path Packages/PadServerCore` で確認した出力から, 実行時間を省いて掲載します.

```text
✔ Test replaysOnlyTheLatestThousandEntriesInPublishOrder() passed
✔ Test publishesEachEntryToMultipleSubscribers() passed
✔ Test slowSubscriberDropsOldBufferedEntriesWithoutBlockingAnotherSubscriber() passed
✔ Test cancellationUnregistersTheSubscriber() passed
✔ Test publishAtTheReplayBoundaryIsDeliveredExactlyOnceAndInOrder() passed
```

## ライセンス

MIT です. [LICENSE](LICENSE) にあります.
