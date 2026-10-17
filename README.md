# PadServer

iPad を, 前面に固定したアプリ1つで動くサーバーにします.
静的サイトと, Docker の container で動くサービスを, 独自ドメインで配信します.

部品を実装中です. iPad への配備から公開までの通しの動作には, まだ対応していません.

clone 後に `scripts/bootstrap.sh` を1回実行すると, 開発用ツールが入り, commit hook が有効になります.

## QEMU のソースの取得

`scripts/fetch-qemu.sh` は, tctiSH とその QEMU fork を固定した commit で `build/sources/` に取得します.
同じ script を再実行すると, 取得済みの commit と取得元を確認します. `build/` は git の管理対象から外しています.
QEMU のビルドは, 後続の作業で行います.

2回続けて実行し, commit と git の除外設定を確認した出力です.

```text
$ ./scripts/fetch-qemu.sh
tctiSH 76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4
qemu ded0cff5a2a6d3b0a5261ab570518719b42ae2e6
$ ./scripts/fetch-qemu.sh
tctiSH 76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4
qemu ded0cff5a2a6d3b0a5261ab570518719b42ae2e6
$ git check-ignore build/sources/tctiSH build/sources/qemu
build/sources/tctiSH
build/sources/qemu
```

## 管理 token の発行

内部部品の `IssueToken` は, システムの暗号的乱数から32バイトの管理 token を生成して保存します.
再発行すると保存済みの token を置き換えるため, 古い token は照合先ではなくなります.
通常の試験では生成値を固定し, 実 Keychain や乱数に依存せず保存と置換を確認します.

`swift test --package-path Packages/PadServerCore` の実行結果から, 実行時間を省いて掲載します.

```text
✔ Test issueTokenSavesAndReturnsGeneratedToken() passed
✔ Test issueTokenReplacesPreviouslyStoredToken() passed
✔ Test run with 92 tests in 2 suites passed
```

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

## 配備の差分確認

内部の `PlanDeployment` は, 送信予定のファイル一覧を保存済み blob と照合し, 未保存のファイル参照を返します.
同じ hash は最初の参照だけを返し, 全て保存済みの場合や空入力では空の一覧を返します.

`swift test --package-path Packages/PadServerCore` の出力から, 対象の試験を抜粋しています. 各試験の実行時間は省いています.

```text
✔ Test planDeploymentOmitsStoredBlobs() passed
✔ Test planDeploymentReturnsEmptyWhenAllBlobsAreStored() passed
✔ Test planDeploymentReturnsEmptyForNoFiles() passed
✔ Test planDeploymentDeduplicatesByBlobAndPreservesFirstReferenceOrder() passed
✔ Test run with 87 tests in 2 suites passed after 0.032 seconds.
```

## 管理の認可

内部部品の `AuthorizeAdmin` は, 接続元が tailnet の IP であり, 保存済みの管理 token と一致する場合だけ許可します.
tailnet の IPv4 と IPv6 に対応し, token が正しくても tailnet 外からは拒否します.
token の内容は `timingsafe_bcmp` で比較し, 長さが違う token と, token が未設定の場合も拒否します.

`swift test --package-path Packages/PadServerCore` の実行結果から, 実行時間を省いて掲載します.

```text
✔ Test authorizeAdminRequiresTailnetAddressEvenWithCorrectToken() passed
✔ Test authorizeAdminRejectsMismatchedTokens(supplied:) with 7 test cases passed
✔ Test authorizeAdminRejectsUnconfiguredToken() passed
✔ Test run with 93 tests in 2 suites passed
```

## 文書

| 文書 | 内容 |
| --- | --- |
| [docs/roadmap.md](docs/roadmap.md) | 全体像, 決めたこと, 計画表 |
| [docs/decisions.md](docs/decisions.md) | 決定を決めた順に並べた記録 |
| [ipad-server-feasibility.md](ipad-server-feasibility.md) | iPadOS の制約についての調査メモ |
| [docs/pull-requests.md](docs/pull-requests.md) | PR の作り方と, merge の規則. 全ての PR で README を更新する |
| [AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md) | merge 係の手順と, Codex との連絡の規則 (同じ内容) |

## プロジェクトの一覧と状態

内部部品の `ListProjects` は, プロジェクトごとに種類, 有効な release, 動いているかを返します.
preparing と retired の release を有効な release として返さず, release が無い場合は `nil` を返します.
静的サイトと container の種類を保ち, 開始状態と停止状態も区別します.

`swift test --package-path Packages/PadServerCore` の実行結果から, 実行時間を省いて掲載します.

```text
✔ Test listProjectsReturnsEmptyListWhenNoProjectsExist() passed
✔ Test listProjectsReturnsKindActiveReleaseAndRunningStatePerProject() passed
✔ Test run with 92 tests in 2 suites passed
```

## blob の保存

内部部品の `FileBlobStore` は, body を小分けに一時ファイルへ書き, CryptoKit の SHA-256 で照合します.
hash は小文字16進64桁とし, 一致した内容だけを hash の名前で公開します.
不一致や受信中断の一時データを破棄し, 同じ内容は1つだけ保存します.
読み出しも小分けに行い, 繰り返し開いた stream はそれぞれ独立して読み進められます.
hash 名のシンボリックリンクを拒否し, 最初の読み出し前にリンクへ差し替えられても追跡しません.

`swift test --package-path Packages/PadServerCore --filter fileBlobStore` の実行結果から, 実行時間を省いて掲載します.

```text
✔ Test fileBlobStoreDiscardsMismatchedContentAndTemporaryFile() passed
✔ Test fileBlobStoreRejectsHashNamedSymbolicLink() passed
✔ Test fileBlobStoreWritesStreamingBodyUnderItsSHA256Name() passed
✔ Test fileBlobStoreAcceptsEmptyBlobAndStreamsEndImmediately() passed
✔ Test fileBlobStoreReadsLargeBlobInBoundedChunks() passed
✔ Test fileBlobStoreDoesNotDuplicateExistingContent() passed
✔ Test fileBlobStoreDiscardsInterruptedReceiveAndAllowsRetry() passed
✔ Test fileBlobStoreRejectsLinkReplacementBeforeFirstPull() passed
✔ Test fileBlobStoreOpensIndependentStreamsAndListsAndRemovesBlob() passed
✔ Test run with 9 tests in 0 suites passed
```

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

## プロジェクトの開始と停止

内部部品の `SetProjectState` は, プロジェクトの開始状態と停止状態を保存します.
停止すると `ResolveRoute` は配信先を返さず停止中として扱い, 再開すると元の経路が解決されます.
保存先が返すエラーは呼び出し側へ伝え, 別のプロジェクトの状態を変更しません.

`swift test --package-path Packages/PadServerCore` の実行結果から, 実行時間を省いて掲載します.

```text
✔ Test setProjectStateStopsRouteResolutionAndRestoresItOnStart() passed
✔ Test setProjectStatePropagatesUnknownProjectFailureWithoutChangingOtherProjects() passed
✔ Test run with 108 tests in 2 suites passed
```

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

## 古い release の掃除

内部部品の `PruneReleases` は, プロジェクトごとに保存順で直近3つの release を残します.
有効な release は, 直近3つより古くても必ず残します.
残す release の manifest を全プロジェクトについて確認し, どこからも参照されない blob を削除します.
別プロジェクトと共有する blob は残ります.

`swift test --package-path Packages/PadServerCore` の実行結果から, 実行時間を省いて掲載します.

```text
✔ Test pruneReleasesKeepsLatestThreeForEachProjectInStorageOrder() passed
✔ Test pruneReleasesAlwaysKeepsActiveReleaseOutsideLatestThree() passed
✔ Test pruneReleasesRemovesOnlyBlobsUnreferencedByRetainedReleases() passed
✔ Test pruneReleasesHandlesEmptyStorageAndFewerThanThreeReleases() passed
✔ Test run with 101 tests in 2 suites passed
```

## プロジェクト一覧の保存

内部部品の `FileProjectRepository` は, プロジェクト一覧を JSON ファイルに保存して読み込みます.
保存時は同じディレクトリの一時ファイルを完成させてから rename するため, 書き込みの途中や rename の失敗時にも, 保存済みの一覧を読み取れます.
通常の試験は一時ディレクトリ内のファイルだけを使い, JSON の読み書きと, 書き込み中断および rename 失敗後に既存の一覧が保たれることを確認します.

`swift test --package-path Packages/PadServerCore --filter FileProjectRepositoryTests` の実行結果です.

```text
✔ Test preservesExistingProjectsWhenRenameFails() passed
✔ Test rejectsCorruptJSON() passed
✔ Test preservesExistingProjectsWhenTemporaryWriteStopsEarly() passed
✔ Test readsEmptyListWhenFileDoesNotExistAndPersistsProjects() passed
✔ Test run with 4 tests in 0 suites passed after 0.010 seconds.
```

## 配備の確定

内部部品の `CommitDeployment` は, manifest にある全 blob を確認して release を保存し, active release を切り替えます.
blob が欠けている場合や release の保存が失敗した場合は, それまでの active release を保ちます.
成功時は新しい release が active になり, 以前の release は retired になります.

`swift test --package-path Packages/PadServerCore` の実行結果から, 実行時間を省いて掲載します.

```text
✔ Test commitDeploymentActivatesNewReleaseAndRetiresOldRelease() passed
✔ Test commitDeploymentRejectsMissingBlobWithoutChangingActiveRelease() passed
✔ Test commitDeploymentPropagatesReleaseSaveFailureWithoutChangingActiveRelease() passed
✔ Test run with 90 tests in 2 suites passed
```

## 経路の解決

内部部品の `ResolveRoute` は, host とパスからプロジェクトと配信先を返します.
サブドメインとパスによる振り分けに対応し, 一致するパスの prefix が最も長い経路を選びます.
停止中のプロジェクトと, 該当する経路が無い場合を区別します.
停止した経路に一致した要求を, 短い prefix の別プロジェクトに振り替えません.
同じ host で最長の prefix の経路が複数ある場合は, どれにも解決せず拒否します.

`swift test --package-path Packages/PadServerCore` の実行結果から, 実行時間を省いて掲載します.

```text
✔ Test resolveRouteMatchesSubdomainAndPreservesTarget() passed
✔ Test resolveRouteChoosesLongestPathPrefix() passed
✔ Test resolveRouteDistinguishesStoppedProjectFromUnmatchedRoute() passed
✔ Test resolveRouteReturnsNotFoundForUnmatchedPathAndEmptyRoutes() passed
✔ Test resolveRouteRejectsAmbiguousLongestPrefixWithoutBlockingMoreSpecificRoute() passed
✔ Test run with 102 tests in 2 suites passed
```

### release と manifest のファイル保存

`FileReleaseStore` は release と manifest を保存し、再起動後も読み出せます。
同じプロジェクトの旧 active を retired にする変更と、新しい active への変更を、
一つの JSON の原子的置換で保存します。保存に失敗した場合、旧 active が残ります。
保存した順序を保ち、release の削除では対応する manifest も削除します。
project と blob の存在確認は、ProjectStorage の組み立て側が担当します。

確認には、一時ディレクトリでの保存と再読み込み、プロジェクト別の切り替え、
保存エラー時の状態維持を含む試験を使います。

```text
$ swift test --package-path Packages/PadServerCore --filter fileReleaseStore
✔ Test run with 6 tests in 0 suites passed after 0.017 seconds.
```

### CLI の接続先と token の保存

`padctl login <server-url>` で、管理 API の接続先と token を保存できます。
token は端末で非表示の入力を受け付け、Mac の Keychain に保存します。
`~/.config/padctl/config.json` に保存するのは `serverURL` だけです。
URL に埋め込んだ認証情報は拒否します。保存が失敗した場合、以前の設定と token に戻します。

```sh
swift run --package-path cli padctl login https://pad.example.com
```

新しく追加したコマンドなので、変更前の画面はありません。
次の画面は `padctl login --help` を実際の端末で実行したものです。

![padctl login のヘルプ](docs/media/padctl-login-help.png)

通常の試験は実 Keychain に触れません。結合試験は専用の一時項目で、保存と更新、
設定ファイルに token が入らないことを確認し、作成した項目を削除します。

```text
$ PADCTL_KEYCHAIN_INTEGRATION=1 swift test --package-path cli
✔ Test run with 19 tests in 0 suites passed after 0.079 seconds.
```

### loopback の配信入口

`ServingServer` は Hummingbird を `127.0.0.1` だけで待ち受けるよう構成します。
要求の authority とパスを `ResolveRoute` に渡し、一致した経路と要求をハンドラーへ渡します。
最長の経路が停止中なら 503 を返し、一致しない経路と曖昧な経路には 404 を返します。
入口では本文を読み込みません。静的ファイルの応答と container への転送は、後続の実装で接続します。

待ち受け設定と、ネットワークを使わない Hummingbird の試験で動作を確認しています。
試験では、経路の境界、停止中の経路、authority の正規化、要求本文の受け渡しも確認します。

```text
$ swift test --package-path Packages/PadServerCore --filter servingServer
✔ Test run with 7 tests in 0 suites passed after 0.006 seconds.
```

### 有効な release の静的ファイル応答

`StaticFileResponder` は経路に対応する有効な release の manifest からファイルを探し、
blob を読みながら応答します。公開ルートからの相対 path を使い、`/` は `index.html` に対応します。
`Content-Type` と `ETag` を返し、一致する `If-None-Match` には 304 を返します。
親ディレクトリへ出る path と見つからないファイルには 404 を返します。

経路の prefix、条件付き応答、親ディレクトリを指定する path を試験で確認しました。

```text
$ swift test --package-path Packages/PadServerCore --filter staticFileResponder
✔ Test staticFileResponderRejectsParentSegments(path:) with 4 test cases passed after 0.004 seconds.
✔ Test staticFileResponderUsesRoutePrefixAndManifestRelativePath() passed after 0.004 seconds.
✔ Test staticFileResponderServesActiveRootIndexAndConditionalResponse() passed after 0.004 seconds.
✔ Test run with 4 tests in 0 suites passed after 0.004 seconds.
```

### 配信要求の記録

配信入口は要求ごとに、時刻、host、パス、応答 status、所要時間をログ bus に流します。
一致した経路の応答と、経路が見つからない 404 の両方を記録します。
ハンドラーが失敗して 500 を返す場合も記録します。

実際の配信入口を通す試験で、ログの内容を確認しました。

```text
$ swift test --package-path Packages/PadServerCore --filter requestLogMiddleware
✔ Test requestLogMiddlewarePublishesResponseAndMissingRoute() passed after 0.004 seconds.
✔ Test requestLogMiddlewarePublishesFailedRequestStatus() passed after 0.004 seconds.
✔ Test run with 2 tests in 0 suites passed after 0.004 seconds.
```
