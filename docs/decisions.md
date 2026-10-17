# padserver の決定記録

iPad をローカルサーバーにするアプリについて, 決めたことを決めた順に残します.
調査で分かった事実は [ipad-server-feasibility.md](../ipad-server-feasibility.md) にあります.
「所有者」は, このリポジトリの持ち主を指します. 「本体」は, 所有者と会話している Claude のセッションを指します.

## 決定済み

| # | 項目 | 決定 | 補足 | 選ばなかった案 | 決定日 |
| --- | --- | --- | --- | --- | --- |
| 1 | 用途 | 静的サイトとファイルの配信, 固定の自作 API, コードの差し替え実行, ファイル置き場の4つ | 4つとも対象にします | 無し | 2026-10-08 |
| 2 | 時間軸 | 長く使う完成形 | 保守の状況と拡張のしやすさを重く見ます | まず動く最小版, 学習と実験が主目的 | 2026-10-08 |
| 3 | 公開の水準 | ソースを GitHub で公開し, 他人が自分の Apple ID でビルドして使える | Bundle ID や Team ID などの個人設定を外に出します | App Store での公開, ビルド済みの配布 | 2026-10-08 |
| 4 | 配信の範囲 | tailnet の中に加えて, インターネットにも公開する | iPad は自宅の NAT の内側にあるので, 公開の方式を別に決めます | 同じ Wi-Fi 内まで | 2026-10-08 |
| 5 | 公開する口と管理する口 | インターネットから届くのは配信 (静的サイトと API) だけ. アップロード, コードの差し替え, 設定の変更は tailnet の中からだけ受け付ける | 外から任意のコードを送り込む経路を無くすためです | 静的サイトだけ公開, 管理も外から行う | 2026-10-08 |
| 6 | 実行言語 (2026-10-09 に項目48で置き換えた) | JavaScript (JavaScriptCore), Node.js (nodejs-mobile), Python (CPython), WebAssembly の4つ | 1つのアプリに同居できるかは調査中です | 無し | 2026-10-08 |
| 7 | コードの形 (2026-10-09 に項目48で置き換えた) | handler 型を4つのランタイムの共通の土台にする. Node.js と Python は server 型も使える | handler 型は, リクエストを受けてレスポンスを返す関数として書く形です. server 型は, コード自身が localhost のポートで待ち受けて, アプリがそこへ転送する形です. JavaScriptCore と WebAssembly は自分で待ち受けられないので, server 型の対象外です | handler 型に統一, server 型だけ | 2026-10-08 |
| 8 | Mac からの送り方 | 専用の CLI | CLI を別に作って保守します | HTTP API を直接叩く, ブラウザの管理画面, iPad の画面で操作 | 2026-10-08 |
| 9 | 導入方法 | 無料の Apple ID | 7日で失効するので, 入れ直しの手段を別に決めます | Apple Developer Program への加入 | 2026-10-08 |
| 10 | 決定の記録先 | このファイル | 調査メモは事実の記録として, そのまま残します | 調査メモへの追記, 記録しない | 2026-10-08 |
| 11 | 公開の起点 | iPad から公開する | 公開の経路は iPad のアプリが自分で張ります | 別の常時稼働機で中継する | 2026-10-08 |
| 12 | 公開する URL | 独自ドメインを使う | PadServer は任意のドメインを relay に割り当てられるようにします. どのドメインを使い, Cloudflare にどう向けるかは, 項目84のとおり使う側が決めます | ts.net の名前だけで公開する | 2026-10-08 |
| 13 | 公開の方式 (2026-10-09 に項目42で置き換えた) | libtailscale をアプリに組み込んで Funnel で ts.net に公開し, 独自ドメインの Cloudflare Worker が ts.net へ取り次ぐ | iOS の実機で Funnel が通った実績が見つかっていないので, 最初に小さく検証します. 通らなければ, 自作の relay (Cloudflare の Worker と Durable Object に WebSocket で繋ぐ) に切り替えます. Worker にドメインを割り当てるには, ドメインを Cloudflare の zone として有効にする必要があります | 自作の relay を最初から選ぶ, SSH の reverse tunnel を有料サービスへ張る | 2026-10-08 |
| 14 | Node.js の版 (2026-10-09 に項目48で置き換えた) | Node.js を載せる段階で, 公式の nodejs-mobile (Node 18.20.4) とフォーク (fogtape/nodejs-mobile, Node 24) の両方を実機で試して決める | 公式は 2024-10 から更新が無く, フォークは 2026-09 に始まったばかりです. ランタイムを差し替えられる境界を先に作ります. Node.js は止めて起動し直せないので, `worker_threads` の中でコードを動かす回避策を, 最初に小さく検証します | 公式版に決める, フォークに決める, Node.js を外す | 2026-10-08 |
| 15 | WebAssembly のランタイム (2026-10-09 に項目48で置き換えた) | WasmKit | Swift 製で SwiftPM から入ります. iOS 18 以上が要ります. iOS は継続テストの対象外です | WAMR, Wasmtime (Pulley) | 2026-10-08 |
| 16 | Python の版 (2026-10-09 に項目48で置き換えた) | BeeWare が配る Python-Apple-support の 3.14 | ビルド済みの Python.xcframework を使います. サブインタプリタの標準ライブラリが入っています | BeeWare 配布の 3.13, 公式のソースから自分でビルド | 2026-10-08 |
| 17 | ランタイムを作る順番 (2026-10-09 に項目48で置き換えた) | JavaScriptCore, Python, WebAssembly, Node.js の順 | JavaScriptCore で handler 型の形を固めて, Python で server 型と転送を作ります | Node.js を最初に作る, Python を最初に作る | 2026-10-08 |
| 18 | HTTP サーバーの実装 | Hummingbird 2 | Node.js と Python の server 型へ流す転送を, streaming のまま書けます. 外部の依存が15個あり, 初回のビルドが長くなります. TLS は Funnel が終端するので, アプリ側では扱いません | FlyingFox, SwiftNIO で自作 | 2026-10-08 |
| 19 | プロジェクトの構成 | XcodeGen とローカルの Swift package | アプリの殻だけを `project.yml` から生成して, 中身は `Packages/PadServerCore` に置きます. Team ID と Bundle ID は, git に入れない `Config/Local.xcconfig` に出します. 生成した xcodeproj は git に入れません | 素の xcodeproj とローカルの Swift package, Tuist | 2026-10-08 |
| 20 | 対応する iPadOS の下限 | iPadOS 26 以上 | 手元の iPad で確かめられる範囲だけを対応として謳います | iPadOS 18 以上 | 2026-10-08 |
| 21 | CLI の言語 | Swift | アプリと同じ Swift package から, 通信の型を共有します. JavaScript をまとめる処理や wheel の取得は, 外部のコマンドを呼び出します | TypeScript (Bun), Python (uv), Rust または Go | 2026-10-08 |
| 22 | 7日の失効への対処 | CLI に, ビルドして iPad へ入れ直すコマンドを用意する | `xcodebuild` と `xcrun devicectl` を使います. Mac と iPad が同じ LAN にいるか, USB で繋がっている必要がある見込みです. 入れ直しでアプリのデータが保たれるかと, 失効の瞬間に起動中のアプリが止まるかは, 実機で確かめます | 定期実行も行う, SideStore の自動更新, Xcode から手で入れ直す | 2026-10-08 |
| 23 | 前面に固定する方法 | アクセスガイド | 端末を初期化せずに使えます. 端末が再起動したときは, 人がアプリを開き直します | Single App Mode, 両方に対応する | 2026-10-08 |
| 24 | 管理する口の認証 (2026-10-09 に項目43で置き換えた) | token と Tailscale の身元の両方 | アプリが発行した token を CLI が送り, 加えて, 接続元が自分の Tailscale ユーザーの端末かを確かめます. 身元の確認は libtailscale での検証が要ります | token だけ, Tailscale の身元だけ | 2026-10-08 |
| 25 | 公開側の URL の分け方 | サブドメインとパスの両方を, プロジェクトごとに設定で選べる | Worker が元のホスト名をアプリへ伝える仕組みが要ります | サブドメインだけ, パスだけ | 2026-10-08 |
| 26 | CLI の機能 | 基本機能 (配備, 状態の確認, 開始と停止, アプリの入れ直し, token の設定) に加えて, ログの追尾, ファイル置き場の操作, 依存の準備, 環境変数と secret の管理を入れる | 依存の準備は, JavaScript を1ファイルにまとめる, iOS 用の wheel を取得する, node_modules を同梱する, の3つです. iPad の中では pip も npm も動かせないためです. secret は iPad 側で Keychain に保存します | 無し | 2026-10-08 |
| 27 | iPad の画面 | 常時表示の dashboard | プロジェクトの一覧, リクエストの流れ, ログを常に出します. 決めた時点では iPad Pro (有機 EL の見込み) を前提に, 焼き付きの恐れがあるとしていました. 本番機は項目41で変わりました | 暗い待機画面と触れたときの状態表示, 最小限の状態表示だけ | 2026-10-08 |
| 28 | ファイル置き場の公開 | 期限付きの共有リンクを発行できる | ファイルごとに, 推測できない URL を期限付きで発行します. 発行と失効は管理する口から行います. 項目5の「インターネットから届くのは配信だけ」に, 共有リンクでの読み取りが加わります | tailnet の中だけ, フォルダ単位で公開を選べる | 2026-10-08 |
| 29 | ライセンス | MIT | 無し | Apache-2.0, 公開するときに決める | 2026-10-08 |
| 30 | 名前 | アプリは PadServer, CLI は padctl, package は PadServerCore | Bundle ID は, 各自が `Config/Local.xcconfig` で決めます | 別の名前 | 2026-10-08 |
| 31 | 作業の単位 | 計画を細かい Issue に分けて, GitHub Issues (`CHU1PC/padserver`) に置く | public のリポジトリなので, 端末名や tailnet の名前などの個人的な情報は書きません | Linear, リポジトリ内の Markdown | 2026-10-08 |
| 32 | 実装の担い手 (2026-10-13 に項目73で置き換えた) | Sonnet の implementer を, Issue ごとの worktree に並列に立てる | 本体が指示文を書き, 成果物を検証します | luna のワーカー, 所有者が Orca で Issue ごとにセッションを開く | 2026-10-08 |
| 33 | 並列の幅 | 依存が解けた Issue は, 全て同時に走らせる | iPad が1台なので, 実機での確認は1本ずつです | 3本まで, 2本まで | 2026-10-08 |
| 34 | main への入れ方 | Issue ごとに PR を作り, 所有者が merge する | 本体は, 検証の結果と reviewer の指摘を PR にまとめます | 検証が通れば本体が merge する, PR を作らずローカルで取り込む | 2026-10-08 |
| 35 | Swift の検査 (2026-10-13 に項目76で置き換えた) | SwiftLint (厳しめの設定), swift-format (Xcode 同梱), Periphery, 警告のエラー扱いの4つ | Swift 6 の language mode でビルドします. Periphery はビルドが要るので, CI で回します | 無し | 2026-10-08 |
| 36 | Swift 以外の検査 | Markdown と YAML (markdownlint-cli2, yamllint), GitHub Actions と shell (actionlint, zizmor, shellcheck, shfmt), secret の混入と綴り (gitleaks, typos) | 無し | Cloudflare Worker の TypeScript の検査 (Biome と `tsc --noEmit`) | 2026-10-08 |
| 37 | commit 時の検査 | pre-commit | commit 時は速い検査だけにして, ビルドと試験は CI に回します | lefthook, 素の git hook | 2026-10-08 |
| 38 | アーキテクチャ | クリーンアーキテクチャの4層 (PadDomain, PadApplication, PadInterface, PadInfrastructure) を, SwiftPM の target で分ける | 依存の向きを compile 時に強制します. 外部の framework を import できるのは PadInfrastructure だけです. App は組み立てだけを行います | 3層を target で分ける, 1つの target の中でフォルダで分ける | 2026-10-08 |
| 39 | 着手の順番 | 機能を作る前に, linter と pre-commit と GitHub Actions を入れる | 無し | 無し | 2026-10-08 |
| 40 | 計画の文書 | 全体像と計画表を `docs/roadmap.md` に書き, それを読んでから着手する | 無し | 無し | 2026-10-08 |
| 41 | 本番機 | サーバーとして常時動かすのは, iPad Pro 11インチ (第3世代, M1, iPadOS 27.0.1) にする | 調査メモと項目27は, iPad Pro 13インチ (M5) を前提に書いていました. 機種と OS の版は `devicectl` で確かめました. Apple の仕様では, 画面は液晶 (LED-backlit IPS) で, メモリは容量が 512GB 以下なら 8GB, 1TB 以上なら 16GB です. 本番機の容量は 256GB なので, メモリは 8GB の見込みです. Mac の Xcode は 26.6 なので, iPadOS 27 の端末へ入れられるかを確かめます | iPad Pro 13インチ (M5) を本番機にする | 2026-10-09 |
| 42 | 公開の方式 (項目13を置き換える) | 自作の relay で公開する. Cloudflare の Worker と Durable Object を relay にして, iPad のアプリから WebSocket を張りっぱなしにする | 本番機で両方を同じ測り方で比べた結果で決めました. 1回の要求は, Funnel が平均で約3.2秒, relay が平均で0.36秒でした. relay は起動してすぐに通り, iPad の側に追加の依存が要らず, 独自ドメインを Worker にそのまま割り当てられます. 大きいファイルと streaming は未検証なので, 土台を作る前に確かめます. 繋いだまま待つ時間を無料枠から外すために, Durable Object は hibernation を使う形にします | Funnel のままにする, 大きいファイルを確かめてから決める, 両方を使い分ける | 2026-10-09 |
| 43 | 管理する口の認証 (項目24を置き換える) | libtailscale をアプリに組み込まない. 管理は iPad の Tailscale アプリ経由で受けて, token と, 接続元が tailnet の IP かどうかの確認で守る | 項目42で公開が relay になり, libtailscale が要るのは身元の確認だけになったためです. 管理の経路は, 本番機で確認できた形だけで成り立ちます. ビルドに Go が要らなくなります. token が漏れると, tailnet の中の端末なら管理できてしまうので, 繋げる端末を自分のものだけに絞る設定を Tailscale のアクセス制御で行い, その手順を手順書に書きます | libtailscale を残して身元も確かめる, まず外して作り後から足せる形にする | 2026-10-09 |
| 44 | compile が要る Python パッケージの入手先 (2026-10-09 に項目48で置き換えた) | BeeWare と Flet が配る iOS 用のビルドを使う. 取得元と hash を記録して固定する | この2か所のビルドで, 本番機の上で FastAPI が動くことを確かめました. パッケージの作者ではなく, 第三者がビルドした binary を信頼することになります. 後から自分のビルドに替えられる形にします | 自分でビルドする | 2026-10-09 |
| 45 | DB の扱い (2026-10-09 に項目49で置き換えた) | 今は計画の対象にしない | Postgres は, iPad の上では起動できません. SQLite と, 外に置いた Postgres への接続は使える見込みですが, PadServer の機能としては今は扱いません | SQLite を標準にして外の Postgres にも繋げる, SQLite だけにする, Postgres を iPad の中に組み込む道も調べる | 2026-10-09 |
| 46 | Kikitoru を計画の到達点にするか (2026-10-09 に項目49で置き換えた) | 入れない. Python の段階の確認は, 検証用の小さな FastAPI のアプリで行う | Kikitoru の backend は, lock 済みの依存のうち psycopg-binary にだけ iOS 用のビルドがありません. 載せるには Kikitoru の側の手入れが要ります. 載せるかどうかは, PadServer ができてから考えます | 到達点に入れる | 2026-10-09 |
| 47 | QEMU を組み込むアプリのライセンスと配り方 | PadServer のコードは MIT のままにする. QEMU (GPLv2) はリポジトリに入れず, 使う人が自分でビルドして組み込む | QEMU のコードは script で取得します. ビルド済みのアプリは配りません. 配ると, アプリの全体に GPL の条件が掛かるためです. 検証に使った公開プロジェクトの tctiSH も, 本体は MIT で, QEMU は別のリポジトリから取得する形です | PadServer 全体を GPL にする | 2026-10-09 |
| 48 | コードを動かす方法 (項目6, 7, 14, 15, 16, 17, 44を置き換える) | container だけにする. 配信するものは, container と静的サイトの2つにする. アプリに組み込むランタイム (JavaScriptCore, Python, WebAssembly, Node.js) は作らない | 本番機の上で, Docker の container が動くことを確かめたためです. container の中の計算は約100倍遅くなりますが, 動かす方法を1つに絞って計画を小さくします. 組み込みの Python は本番機で動きましたが, 作りません. 項目1の「固定の自作 API」と「コードの差し替え実行」は, container の配備で実現します. 項目26の「依存の準備」は要らなくなり, 代わりに image を送る機能が要ります | container を主役にして組み込みの Python を残す, 4つのランタイムを全部残して container を足す | 2026-10-09 |
| 49 | 計画の到達点 (項目45, 46を置き換える) | Kikitoru を, docker compose の構成のまま iPad の上で動かす | Kikitoru の compose は, Postgres 18, migrate, backend, worker の4つの service でできています. DB は container として動かします. Postgres 18 の container は, 本番機で動きました. Kikitoru の backend そのものは, まだ本番機で動かしていません. 土台を作り込む前に確かめます. 音声は 500MB まで受け取る作りなので, relay を通せるかも確かめます. Kikitoru の側に変更が要るときは, Kikitoru のリポジトリの別の branch で行います | 検証用の小さな構成で確認する | 2026-10-09 |
| 50 | GitHub Actions の中身 (2026-10-13 に項目77で置き換えた) | job を4つ置く. lint (pre-commit の全 hook), build と test (`swift test` と iOS Simulator 向けの `xcodebuild build`), Periphery, gitleaks (履歴の全体). Dependabot で, Actions と Swift の依存の更新を受け取る. QEMU のビルドは CI では行わない | 手元の pre-commit と同じ検査を CI でも回して, hook を入れていない人の PR も守ります. QEMU のビルドは時間がかかり, nix も要るためです | Dependabot は入れない, QEMU のビルドも CI で回す | 2026-10-11 |
| 51 | main の保護 | main への直接の push を禁じて, PR と CI の成功を必須にする | 最初の commit だけは, 保護を掛ける前に直接 push します | PR だけ必須にする, 保護しない | 2026-10-11 |
| 52 | QEMU を包むコードの置き場所 | 別の package (PadGuest) に出す | QEMU の binary が無い Mac や CI でも, 他の部分の `swift test` が回ります. 並列の実装で触るファイルも分かれます | PadInfrastructure の中に置く | 2026-10-11 |
| 53 | 検証に使ったコードの扱い | `spikes/` に, 結果の README と一緒にコードごと残す. lint と CI の対象から外す | 他人が同じ検証をやり直せます. 取得した tctiSH と QEMU のコード, ビルドの成果物, 鍵と token, 端末の ID は入れません | README だけ残す, リポジトリに入れない | 2026-10-11 |
| 54 | 土台の型と protocol を書く人 (2026-10-17 に項目83で置き換えた) | PadDomain の型, PadApplication の port, 通信の型は, 本体が書く | 全ての Issue がこの形に依存するためです. ここがぶれると, 並列の実装がやり直しになります | 実装者に任せる | 2026-10-11 |
| 55 | commit と push の扱い | feature branch への commit, push, PR の作成は本体が行う. main への merge は所有者が行う | 項目34を補います | commit のたびに確認する, PR の作成も所有者が行う | 2026-10-11 |
| 56 | QEMU の入手元 | tctiSH が使っている QEMU の fork を, commit を固定して取得する | 検証で動いた組み合わせをそのまま使います. JIT 無しで速く動かす仕組みは, この fork にしかありません. script が取得してビルドします. ビルドには nix が要ります. 取得元のリポジトリが消えると, ビルドできなくなります | 自分の GitHub に写しを置く | 2026-10-11 |
| 57 | guest の Linux の作り方 | tctiSH の guest (Alpine Linux) を土台にして, kernel と起動の処理を直す. 起動時に Docker を自動で立ち上げる | tctiSH の guest のままでは, Docker の既定のネットワークと `docker exec` が動きませんでした. 直して動くかは, 検証で確かめます | 一から自分で組む | 2026-10-11 |
| 58 | アプリから guest の Docker を操作する方法 | Docker の API を直接呼ぶ. API の口には認証を掛けて, 鍵は端末ごとに作る | 状態やログを, 構造のあるデータで受け取れます. tctiSH に付いている公開の鍵は使いません | SSH で入ってコマンドを叩く | 2026-10-11 |
| 59 | image の届け方 | Mac でビルドして, `padctl` で tailnet 経由で iPad へ送る. 公開の image は, iPad が直接取得する | 外のサービスに image を置かずに済みます. 送って読み込めるかは, 検証で確かめます | registry を経由する, iPad の上でビルドする | 2026-10-11 |
| 60 | JIT | 使わない | 有効にするには専用の VPN が要り, Tailscale と同時に使えない恐れがあります. JIT 無しで動くことは, 本番機で確かめました. 計算が約100倍遅いことは, 受け入れます | 後で試す検証を足す | 2026-10-11 |
| 61 | guest の CPU の種類 | x86_64 で作る. arm64 の guest が動くかを確かめる検証を, 1つ足す | arm64 が動けば, Mac でそのままビルドした image が使えます. tctiSH の QEMU が arm64 の guest に対応しているかは, まだ分かっていません. 結果が良ければ, 切り替えるかを改めて決めます | 検証を足さずに x86_64 のままにする | 2026-10-11 |
| 62 | プロジェクトの設定ファイル | 設定は `padserver.toml` に書く. container は compose のファイルをそのまま使い, 公開する経路だけを `padserver.toml` に書く | compose のファイルを書き換えずに載せられます. 静的サイトも `padserver.toml` に書きます | compose の label に書く | 2026-10-11 |
| 63 | container の port の届く範囲 | `padserver.toml` に経路を書いた port だけを, 配信の入口に繋ぐ. 書いていない port は, インターネットからも tailnet からも届かない | compose の `ports` は, 公開の指示として扱いません. Postgres のような内部の service を, 誤って外に出さないためです | compose の `ports` を tailnet にだけ出す | 2026-10-11 |
| 64 | relay の配り方 | relay のコードをこのリポジトリの `relay/` に置き, 使う人が自分の Cloudflare のアカウントへ配備する | 配備は script 1つで済むようにして, 無料プランの範囲で動く形にします | 別のリポジトリに分ける | 2026-10-11 |
| 65 | 常時表示の画面への手当て | 表示の側では手当てをしない. 明るさを下げる手順だけを, 運用の手順書に書く | 本番機の画面は液晶です | 時間が経つと暗くする機能を作る | 2026-10-11 |
| 66 | Issue の粒度 | 全ての段階を, 1つの Issue が1つの責務になるまで細かく分ける | 目安は, 実装のファイルが1つか2つと, その試験です. container の部分は, 検証の結果で書き直すことがあります | 近い段階だけ細かく分ける, 粗い一覧のままにする | 2026-10-11 |
| 67 | Issue の言語 | タイトルも本文も日本語で書く | コマンドとファイルの名前は, 英語のままです | タイトルは英語で本文は日本語, 全部英語 | 2026-10-11 |
| 68 | 段階と Issue の分け方 | roadmap の6章の通りにする. Issue は GitHub に作る | 8つの段階と199件の Issue です. 済んだ検証は, Issue にしません. 最初の push は, Issue を作った後に所有者が行います | 近い段階だけ先に作る, 一覧を直してから作る | 2026-10-11 |
| 69 | 公開する文書と Issue での呼び方 | 個人の名前を書かずに「所有者」と書く | 項目31の「個人的な情報は書かない」に合わせます. public のリポジトリでは, GitHub のアカウントの名前と結びついて見えるためです | 名前をそのまま書く | 2026-10-11 |
| 70 | commit の名義 | 普段の git の設定のままにする | 名義のメールアドレスは, 公開の履歴に残ります. 一度は GitHub の noreply のアドレスを選びましたが, push の前に取り消しました | GitHub の noreply のアドレスを使う | 2026-10-11 |
| 71 | PR の規則 (2026-10-14 に項目79で置き換えた) | [pull-requests.md](pull-requests.md) の通りにする | 1つの Issue に1つの PR を作ります. 本文には, 変更ごとに「何を変えたか」と「何のための変更か」を書きます. API の変更も同じ形で書きます. 画面のある実装と, 動かして見せられる実装は, スクリーンショットを PR のコメントに載せます. merge は rebase and merge です | 本文とコメントに署名を付ける, 変えたファイルを並べるだけにする | 2026-10-13 |
| 72 | 実装の規則 | [implementation-rules.md](implementation-rules.md) の通りにする | 型, 設計, エラーと並行処理, 試験, コメントの決まりです. 所有者の普段のレビューの基準を, Swift に置き換えました. 試験は Swift Testing で, 実装より先に書きます | 無し | 2026-10-13 |
| 73 | 実装とレビューの担い手 (項目32を置き換え, 2026-10-17 に項目83で置き換えた) | 実装もレビューも, Codex (gpt-6-luna) のワーカーが行う. Issue ごとの worktree に並列に立てる | 所有者の判断です. 本体が指示文を書き, 成果物を検証します. レビューは Issue ごとに1回で, 指摘は選別せずに全件を PR に載せます. 土台の型と port は, 引き続き本体が書きます (項目54) | Sonnet の implementer と reviewer, 土台の型と port も Codex が書く | 2026-10-13 |
| 74 | push と PR の作成を行う人 (2026-10-17 に項目83で置き換えた) | 本体が, 成果物を確かめてから行う. 所有者の確認は待たない. 実装者と reviewer は, commit も push もしない | 項目55を確かめ直しました. 所有者の普段の決まり (push と PR の作成は本人が行う) は, このリポジトリの feature branch に限って外します. public のリポジトリなので, push の前の検査 (lint, 試験, secret, 個人的な情報) を本体に残します. main への push と merge は, 所有者だけが行います | Codex のワーカーが PR まで作る, 所有者が push する | 2026-10-13 |
| 75 | 規則の文書の入れ方 | Issue を1件足して (M0-20), PR で main に入れる | Issue は200件になりました. PR の本文の形を, 並列の実装を始める前に実物で1回確かめられます | main に直接入れる, PR の template の Issue (M0-16) と同じ PR に入れる | 2026-10-13 |
| 76 | Swift の検査 (項目35を置き換える) | SwiftLint (厳しめの設定), swift-format (Xcode 同梱), SwiftLint の analyzer (`unused_declaration` と `unused_import`), 警告のエラー扱いの4つ | 未使用のコードの検出を, Periphery から SwiftLint の analyzer に替えました. Periphery の上流のリポジトリは archive されて, 商用の製品 (Periphery Pro) に移りました. 公開されている版の更新は, 3.8.0 (2026-07-25) で止まっています. Homebrew の formula も, 2027-08-12 に無効になります. SwiftLint は既に使っている道具なので, 依存が増えません. analyzer はビルドの記録が要るので, CI で回します. 既定では, public な宣言を調べません. Swift 6 の language mode でビルドする点は, 項目35のままです | Periphery 3.8.0 を使い続ける, Periphery Pro を使う, 有志の fork (Infomaniak) を使う | 2026-10-13 |
| 77 | GitHub Actions の中身 (項目50を置き換える) | job を4つ置く. lint (pre-commit の全 hook), build と test (`swift test` と iOS Simulator 向けの `xcodebuild build`), 未使用のコードの検出 (SwiftLint の analyzer), gitleaks (履歴の全体). Dependabot で, Actions と Swift の依存の更新を受け取る. QEMU のビルドは CI では行わない | 項目76に合わせて, Periphery の job を, SwiftLint の analyzer の job に替えました. 他は項目50のままです. 手元の pre-commit と同じ検査を CI でも回して, hook を入れていない人の PR も守ります. QEMU のビルドは時間がかかり, nix も要るためです | Dependabot は入れない, QEMU のビルドも CI で回す | 2026-10-13 |
| 78 | `padctl` の TOML の parser | TOMLDecoder (dduan/TOMLDecoder) | ライセンスは MIT です. 最新の版は 0.4.5 (2026-07-11) で, 比べた3つの中で一番新しいものでした. TOML を `Codable` の型に読み込みます. 0.x の版なので, 依存の範囲は次の minor までに絞ります. Swift 6 でビルドできるかは, CLI の殻 (M0-10) で確かめます | swift-toml (mattt/swift-toml), TOMLKit (LebJe/TOMLKit), 見本で比べてから決める | 2026-10-14 |
| 79 | PR の規則 (項目71を置き換える) | [pull-requests.md](pull-requests.md) の通りにする. merge の方法は, merge commit にする | 最初の8件の PR は, merge commit で main に入りました. その後に, 規則の方を合わせると決めました. PR の commit は, 番号を変えずに main に入ります. PR の表に書いた commit の番号を, main でそのまま辿れます. PR ごとに, merge 用の commit が1つできます. 他の決まりは, 項目71のままです | rebase and merge に戻して GitHub の設定で固定する, 設定は main の保護 (M0-17) まで待って手で rebase and merge を選ぶ, 本文とコメントに署名を付ける, 変えたファイルを並べるだけにする | 2026-10-14 |
| 80 | swift-distributed-tracing の版の固定 | PadServerCore の `Package.swift` で, swift-distributed-tracing を 1.6.0 未満に固定する. 固定を外す時期を追う Issue を1件足す (M0-21) | Hummingbird 2.27.1 が, swift-distributed-tracing 1.6.0 と一緒にはビルドできなかったためです. この行は, 骨組みの Issue (M0-8) には無い変更でした. 上流は, 2026-10-13 に出た Hummingbird 2.28.0 で直しました. 固定は M0-21 で外します | 受け入れずに, 上流の修正を待つ | 2026-10-13 |
| 81 | 配列の末尾のカンマ | swift-format に合わせる. SwiftLint の `trailing_comma` は止めて, swift-format だけが決める | 2つの道具の指示が逆で, 両方を通るファイルが書けなかったためです. swift-format は, 要素が複数あって複数行にまたがる配列の最後に, カンマを付けます. SwiftLint の側を「必須」にする案は, 要素が1つで複数行にまたがる配列で食い違うので, 規則を止めました (M0-22) | SwiftLint に合わせて, swift-format がカンマを付けない設定にする | 2026-10-14 |
| 82 | レビューの指摘の扱いと, 本体の検証 | reviewer の指摘は, 所有者に聞かずに, 本体が直してから PR を出す. 本体は, ビルドや動作を自分で確かめ直さない. 成果物が動くことは, reviewer が確かめる | 所有者の判断です. PR のたびに直す指摘を選ぶのが, 手間だったためです. 所有者の操作は merge だけになります. push の前の検査 (lint, secret, 個人的な情報) は, 本体に残します (項目74). 並列に作った PR を重ねた状態の lint も, 本体が続けます. 直さなかった指摘は, 理由を付けて PR に残します | 指摘を選ぶ手間だけを無くす, 本体の検証だけを無くす | 2026-10-14 |
| 83 | 型と port も実装者が書く (項目54, 73, 74を置き換える) | コードやファイルを書く Issue は, 型と port も含めて Codex の実装者が担当する. Codex が検証, commit, push, PR の作成まで行う. merge は所有者か指名された merge 係が行う | 所有者の指示です. 旧計画で本体に割り当てたコードを書く Issue も, 着手時に担当を実装者へ直します | 型と port を本体が書く, 本体だけが PR を作る | 2026-10-17 |
| 84 | ドメインの扱いは範囲外 | どのドメインをどう Cloudflare に向けるかは, PadServer の範囲外とする | サーバーを使う側の事情で決めます. PadServer は任意のドメインを relay に割り当てる一般的な手順を示します (M3-20). 所有者の決定です | PadServer の開発中に特定のドメインの扱いを決める | 2026-10-17 |
| 85 | README は最後に1回だけ書く | PR では `README.md` を変えない. 何ができるかと証跡は PR の本文に書き, README は Issue #193 で最後に書く | 全ての PR が README の末尾に節を足すと, 1件 merge するたびに他の全ての PR が衝突して, CI をやり直します. 並列の実装の速さが落ちるためです. 所有者の決定です | 全ての PR で README を更新する (2026-10-17 に docs/pull-requests.md の 6.5 に書いたもの) | 2026-10-17 |

## 未決定

未決定の項目は, 提案を添えて [roadmap.md](roadmap.md) の5章にまとめています.

| 項目 | 状況 |
| --- | --- |
| Kikitoru の大きい音声の upload の経路 | 未着手. relay を通せる大きさが分かってから決める |
| compose の動かし方と, 対応する機能の範囲 | 未着手. guest の作り直しの検証の後に決める |
| guest を arm64 に切り替えるか | 未着手. arm64 の guest が動くかの検証の後に決める |
| relay で大きいファイルと streaming を運ぶ取り決め | 公開の部分を作る前に, 小さく検証して決める |

2026-10-11 に, 提案のうち16件を1つずつ確認して, 項目50から65にしました.
feature branch の push と PR の作成を誰が行うかは, 2026-10-13 に項目74で決めました.

次の3つは, 項目48で決着したので, 表から外しました.

- container を iPad の上で動かす方法. QEMU をアプリに組み込む方式で, 本番機の上で動くことを確かめました. 組み込み方の細目は, 上の表に分けています.
- Python のプロジェクトどうしの分け方. 組み込みの Python を作らないので, 要らなくなりました.
- 同じ process の中の worker の扱い. worker は container として動かせるので, 要らなくなりました.

## 未確認の前提

| 前提 | 確かめ方 | 状況 |
| --- | --- | --- |
| Tailscale 経由で, iPad 上のアプリのポートに TCP が届く | iPad の a-Shell で `python -m http.server 8080` を動かし, Mac から `curl` する | 確認済み (2026-10-09). 本番機の a-Shell で待ち受けて, Mac から tailnet の IP 宛てに `curl` すると `HTTP/1.0 200 OK` が返った. 経路は同じ LAN の中の直接接続で, 中継を挟む経路では試していない |
| iOS の実機で, libtailscale の Funnel が通る | 最小のアプリで `tailscale_enable_funnel_to_localhost_plaintext_http1` を呼び, 外から HTTPS で叩く | 確認済み (2026-10-09). 通るが遅い. 公開の入口から本番機のアプリへ `HTTP 200` が返った. 1回の HTTPS の要求に平均で約3秒かかった (24回, 2.1秒から6.3秒). Mac のノードでも同じ遅さだった. tailnet の中から直接叩くと約0.03秒だった. 起動の直後は, 2つある入口の片方が1分半以上通らなかった. 遅さの原因は調べていない. この結果を受けて, 項目42で公開の方式を変えた |
| 自作の relay (Cloudflare の Worker と Durable Object) を通して, 公開の URL から本番機のアプリへ届く | 最小の relay を配備して, 本番機のアプリから WebSocket で繋ぎ, 外から HTTPS で叩く | 確認済み (2026-10-09). 24回とも `HTTP 200` が返り, 1回の要求は平均で 0.36 秒だった (0.29秒から0.40秒). 同じ測り方で Funnel は約3.2秒だった. 起動してすぐに通った. 大きいファイル, streaming, 切れた後の繋ぎ直しは試していない |
| アプリ内のノードで, 接続元の Tailscale 上の身元を問い合わせられる | tailnet 側の待ち受けに繋いで, 接続元の IP を LocalAPI の `whois` に渡す | 確認済み (2026-10-09). 接続元の IP が取れて, `whois` がノード名と利用者の ID を返した |
| Node.js のコードを, `worker_threads` の中で止めて起動し直せる | 最小のアプリで, 待ち受けるコードを worker の中で動かして入れ替える | 取りやめ (2026-10-09). 項目48で, Node.js を載せないことにした |
| 入れ直しでアプリのデータが保たれる | Documents にファイルを置いて, `devicectl` で入れ直した前後を比べる | 確認済み (2026-10-09). 同じ Bundle ID で上書きして入れ直した後も, Documents のファイルが残った. 署名が失効した後に新しい profile で入れ直す場合は, まだ試していない |
| 無料の Apple ID の署名が失効した瞬間に, 起動中のアプリが止まるか | 失効の時刻をまたいで動かし続ける | 未実施 |
| Xcode 26.6 から, iPadOS 27.0.1 の本番機へ自作のアプリを入れられる | 本番機を Mac に繋いで, 最小のアプリを入れる | 確認済み (2026-10-09). Xcode 26.6 から iPadOS 27.0.1 の本番機へ, ビルド, 無料の Apple ID での署名, インストール, 起動が通った. 自作のアプリが 8080 番で待ち受けて, Mac から tailnet 経由の `curl` に `HTTP/1.1 200 OK` を返した. 事前に, Xcode への iOS 26.5 の platform の取得と, iPad での開発元の信頼の操作が要った |
| 本番機のメモリで, 4つのランタイムを同時に載せられる | 各ランタイムの通しの確認で, メモリの使用量を測る | 取りやめ (2026-10-09). 項目48で, 組み込みのランタイムを作らないことにした. 手がかりとして, 端末のメモリは 7.9GB で, 最小のアプリの起動直後に使える残りは 5.35GB だった. Python と FastAPI を動かしたアプリでは 5.27GB だった (2026-10-09) |
| 自作のアプリに組み込んだ Python で, compile が要るパッケージを使う FastAPI のアプリが動く | BeeWare の Python 3.14 を最小のアプリに埋め込み, iOS 向けに取得したパッケージで FastAPI を動かして, Mac から `curl` する | 確認済み (2026-10-09). FastAPI 0.143.0, pydantic-core 2.46.4, orjson, cryptography, greenlet 付きの SQLAlchemy の非同期接続, psycopg2 が動いた. 初期化は0.15秒, import は1.1秒だった. 接続を使い回した1,000回の応答は, 中央値が 12.8 ms だった. 同時の50本も全て成功した. 別のプログラムの起動は `ios does not support processes` で失敗した. PyPI に iOS 用のビルドが無いパッケージは, BeeWare と Flet の配布場所から取った. Postgres への実際の接続は試していない |
| Python のコードを, アプリを入れ直さずに差し替えられる | 動いている FastAPI のコードを, 3つのやり方 (初期化のやり直し, コードだけの入れ替え, subinterpreter) で差し替える | 確認済み (2026-10-09). コードだけの入れ替えは通った. 切り替えは約0.15秒で, 30回くり返してもメモリは増えなかった. 壊れたコードは, 直前の release に自動で戻せた. 待ち受けの socket を host が持ち続けると, 切り替えの間に落ちる要求は0本だった. 初期化のやり直しは, 2回目の import で pydantic-core の中から `SIGSEGV` が出て, アプリごと落ちた. subinterpreter は, pydantic-core, orjson, greenlet, psycopg2, cryptography を読み込めなかった. uvicorn は起動の失敗で `sys.exit` を呼ぶので, 受け止める必要がある |
| iPad の上で, 本物の Docker の container が動く | QEMU をアプリに組み込んで Linux を emulate する tctiSH を本番機に入れ, guest の中に Docker を入れて, Mac から tailnet 経由で叩く | 確認済み (2026-10-09). JIT 無しで, 無料の Apple ID の署名で動いた. アプリの起動から guest の SSH が通るまで約15秒だった. `nginx:alpine` の応答は中央値 5.7 ms, FastAPI の container は中央値 19.5 ms だった (どちらも tailnet 越し, 接続を使い回した場合). `postgres:18-alpine` は初期化に約38秒かかり, 主キーでの1行の取得は約6 ms, 1行の insert と commit は約19 ms だった. container の中の Python の計算は, Mac でそのまま動かす場合の約140倍から160倍の時間がかかった. Mac の上の同じ構成で比べると, 約90倍から150倍だった. `Extended Virtual Addressing` の権限は無料の Apple ID では使えず, 外した. Docker の既定のネットワークと `docker exec` は, そのままでは動かなかった. 動かしたのは約12分で, 何日も動かし続けたときの挙動は試していない |
| tctiSH の設定を変えずに kernel を再ビルドし, Mac の QEMU で guest を起動できる | Linux x86_64 で tctiSH の `assets/build_kernel.sh` を実行し, 生成した `bzImage` を Mac の QEMU fork で起動して `uname -a` を見る | 確認済み (2026-10-17). `Linux tctiSH 6.18.53tctish #1 SMP Tue Jan  1 00:00:00 UTC 1980 x86_64 Linux` が返った. 入力の固定値と手順は [検証記録](../spikes/007-guest-rebuild/README.md) に残した |
| Kikitoru の backend と worker の image が, guest の Docker の上で, 実用になる時間で起動して応答する | Kikitoru の image を linux/amd64 でビルドして, Postgres と一緒に動かす. Mac の上の同じ QEMU で試してから, 本番機で試す | 未実施. 本番機で動かしたのは, 小さな FastAPI のアプリだけである |
| guest の Linux を作り直すと, Docker の既定のネットワーク, `docker exec`, `docker compose` が動く | kernel に netfilter, bridge, veth を入れ, 起動の処理が root を切り替える方法を直して, Mac の上の同じ QEMU で試す | 未実施 |
| Mac でビルドした linux/amd64 の image を, iPad の Docker へ送って読み込める | Mac で `--platform linux/amd64` を付けてビルドし, 送って読み込む時間を測る | 未実施 |
| container を動かしたまま, 何日も動かし続けられる | container を3つ動かしたまま丸1日以上置いて, 応答, メモリ, 発熱を見る | 未実施. 動かしたのは約12分である |
| アプリが背景に回った後と, 前面に戻った後に, guest と container が動き続ける | アクセスガイドの有り無しで, 背景に回す, 画面をロックする, 通知を受ける, の3つを試す | 未実施. tctiSH は, 背景に回ると状態を保存して, 動いていたプログラムを失うと書いている |
| 無料の Apple ID の権限で, guest に必要なだけのメモリを与えられる | guest のメモリを 2GB, 3GB, 4GB にして起動し, container を増やしてアプリが落ちないかを見る | 未実施. 手がかりとして, アプリの既定では guest のメモリは 1GB で, container を3つ動かした状態の使用は 169MB だった |
| relay で, 大きいファイルと streaming を運べる | 本文を小分けにして送る取り決めを最小の形で作り, 数百 MB のファイルと Range の要求を通す. upload の大きさの上限も確かめる | 未実施 |
| relay への WebSocket が切れた後と, アプリが前面に戻った後に, 自動で繋ぎ直せる | 回線を切る, アプリを背景に回す, relay を配備し直す, の3つで繋ぎ直しを見る | 未実施 |
| tctiSH の QEMU で, arm64 の guest が JIT 無しで動く | arm64 の Alpine と Docker を Mac の上の QEMU で動かして, x86_64 と速さを比べる | 確認済み, ただし Mac の上だけ (2026-10-18). tctiSH の fork の source から `aarch64-softmmu` を TCTI でビルドして, arm64 の Alpine 3.24.2 が起動し, Docker 29.8.2 で arm64 の `python:3-alpine` が動いた. 同じ source の x86_64 用 QEMU と比べて (4 CPU, 各5回の中央値), Python の loop, md5, zlib の所要時間の比 (arm64 / x86_64) は 0.93 から 1.09 だった. 実機では試していない. 実機の app の QEMU は x86_64 用なので, app の build の変更が要る. 比べた x86_64 の guest は Alpine の `virt` kernel で, tctiSH の自前の kernel ではない. 手順と数字は [検証記録](../spikes/011-arm64-guest/README.md) に残した |
