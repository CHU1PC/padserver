# PadServer

iPad を, 前面に固定したアプリ1つで動くサーバーにします.
静的サイトと, Docker の container で動くサービスを, 独自ドメインで配信します.

部品を実装中です. iPad への配備から公開までの通しの動作には, まだ対応していません.

clone 後に `scripts/bootstrap.sh` を1回実行すると, 開発用ツールが入り, commit hook が有効になります.

## 設定ファイルの読み取り

CLI 内部の `ManifestLoader` が `padserver.toml` の内容を読み取り, 既存の `ProjectManifest` に変換します.
構文や値に誤りがある場合は, 行番号を含むエラーを返します. 配備コマンドへの接続は後続の実装で行います.

`swift test --package-path cli` では, 正常な設定の変換と, 構文, root, 経路, 空の routes のエラー行を確認しています.

```text
✔ Test decodesManifestAndNormalizesRouteValues() passed
✔ Test reportsSyntaxErrorLine() passed
✔ Test reportsInvalidRootAtItsSourceLine() passed
✔ Test reportsInvalidRouteAtItsSourceLine() passed
✔ Test reportsInvalidPathPrefixAtItsSourceLine() passed
✔ Test reportsTopLevelEmptyRoutesAtItsSourceLine() passed
✔ Test run with 6 tests in 0 suites passed
```

上記は試験出力から実行時間を省いたものです.

## 共有の試験用 port

`PadTestSupport` は, ProjectStorage と SecretStore のメモリ内実装を提供します.
release の準備保存, 検証後の active 切替, project の run state と route の保持, blob の pull stream を試験から共有できます.
secret と管理 token もメモリ内で扱い, 固定の時刻と ID を注入できます.
同じ target の `InMemoryLogBus` は直近 1,000 件を再生し, 購読中の stream に新しいログを配信します.

`swift test --package-path Packages/PadServerCore` で実行した共有 port の試験出力です.

```text
✔ Test sharedSecretStoreSupportsProjectSecretsAndAdminToken() passed after 0.003 seconds.
✔ Test sharedReleaseActivationPreservesOtherProjectsActiveRelease() passed after 0.003 seconds.
✔ Test sharedStorageKeepsProjectsAndRunStatesIndependent() passed after 0.003 seconds.
✔ Test sharedSecretsWithTheSameNameStaySeparateAcrossProjects() passed after 0.003 seconds.
✔ Test sharedProjectStorageStoresProjectsReleasesAndBlobStreams() passed after 0.003 seconds.
✔ Test sharedBlobStreamKeepsIndependentPullCursors() passed after 0.003 seconds.
✔ Test sharedProjectStorageActivatesReleasesOnlyAfterValidation() passed after 0.003 seconds.
✔ Test sharedLogCancellationDoesNotStopOtherSubscribers() passed after 0.004 seconds.
✔ Test sharedRuntimePortsProvideFixedValuesAndReplayThenDeliverLogs() passed after 0.005 seconds.
✔ Test run with 79 tests in 2 suites passed after 0.006 seconds.
```

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
✔ Test cancelledSubscriberDoesNotBlockOtherSubscribers() passed
✔ Test publishAtTheReplayBoundaryIsDeliveredExactlyOnceAndInOrder() passed
```

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
