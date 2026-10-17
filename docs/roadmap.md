# padserver の全体像と計画

iPad を, 前面に固定したアプリ1つで動くサーバーにします.
この文書は, 何を作るか, 何を決めたか, どの順に作るかを1か所で読めるようにまとめたものです.

| 文書 | 役割 |
| --- | --- |
| この文書 | 全体像, 決定の要約, 計画表 |
| [decisions.md](decisions.md) | 決定を決めた順に並べた記録. 選ばなかった案も全て載せています |
| [pull-requests.md](pull-requests.md) | PR の規則. 誰がどう作って, どう merge するか |
| [implementation-rules.md](implementation-rules.md) | 実装の規則. コードを書くときに守ること |
| [ipad-server-feasibility.md](../ipad-server-feasibility.md) | iPadOS の制約についての調査メモ. container が動くと分かる前に書いたものです |

本文に出てくる `#42` のような番号は, decisions.md の決定の番号です.
決定は85件あります. このうち18件は, 後の決定で置き換えました. 対応は 3.9 にあります.
3章には, 今有効な決定のうち, 文書の置き場所についての2件 (#10 と #40) を除く63件を載せています. その2件の中身は, 上の表の通りです.

この文書では, 確かさを3つの言葉で書き分けます.

| 言葉 | 意味 |
| --- | --- |
| 決定済み | 所有者が選んだもの. 3章にあります |
| 未確認 | 実機で確かめていない前提. 4章にあります |
| 提案 | Claude の案で, まだ承認されていないもの. 5章にあります |

「所有者」は, このリポジトリの持ち主を指します. 「本体」は, 所有者と会話している Claude のセッションを指します. コードやファイルを書く Issue は, 型と port も Codex の実装者が担当します (#83).

## 1. 一言でいうと

- iPad の PadServer アプリが, 静的サイトと, Docker の container で動くサービスを配信します. ファイル置き場もあります.
- container は, アプリの中で Linux を丸ごと動かして, その中の Docker で動かします. Docker Hub の image が, 手を加えずに動きます.
- インターネットからは独自ドメインで見られます. 管理は, tailnet の中の Mac から CLI (`padctl`) で行います.
- 到達点は, Kikitoru を docker compose の構成のまま, iPad の上で動かすことです (#49).
- 現在は, 危ない前提を本番機で確かめ終えて, 本格的な開発に入る段階です. 本体のコードはまだ1行もありません.

作らないと決めたものは次の通りです.

| 作らないもの | 理由 |
| --- | --- |
| アプリに組み込むランタイム (JavaScriptCore, Python, WebAssembly, Node.js) | container で何でも動くので, 動かす方法を container に絞りました (#48). 組み込みの Python は実機で動きましたが, 作りません |
| 別のマシンで動くサービスへ, iPad から要求を流す機能 | container を iPad の上で動かす方を選びました |

## 2. 全体像

### 2.1 通信の経路

経路は2本あります. 公開の経路と管理の経路は, 入口が別です.

```text
[公開の経路]  誰でも通れる. 読むだけ.

  訪問者のブラウザ
      |  HTTPS   blog.example.com
      v
  relay                      Cloudflare の Worker と Durable Object.
      |                      独自ドメインを受けて, TLS をここで終える
      |
      |  WebSocket           iPad の側から張って, 繋いだままにする
      v
  PadServer (iPad)
      |
      +-- 静的サイト
      +-- container           アプリの中の Linux で動く. 登録した経路だけを転送する
      +-- 共有リンク          期限付きで, ファイルを1つ渡す


[管理の経路]  tailnet の中の端末だけが通れる. 書き換えられる.

  Mac の padctl
      |  tailnet (暗号化済み)   iPad の Tailscale アプリが受ける
      v
  PadServer (iPad) の管理用のポート
      |  検査1: token
      |  検査2: 接続元が tailnet の IP か
      v
  管理 API
      +-- 配備 (静的サイトと, container の構成)
      +-- image の送信
      +-- 状態の確認, 開始, 停止
      +-- ログの追尾
      +-- ファイル置き場の操作, 共有リンクの発行
      +-- 環境変数と secret
```

この分け方の狙いは1つです.
インターネットの側から, コードや image を送り込む入口に届く道を作りません.
relay から届いた要求は, 配信の入口にしか渡しません. 管理 API は relay の経路に繋がっていないので, 外からは届きません.
iPad は外からの接続を待ち受けず, 自分から relay へ繋ぎに行きます.

### 2.2 アプリの中の構成

アプリは1つの process です. その中で, Swift で書いた部分と, Linux を動かす部分が並んで動きます.
iPadOS は別のプログラムの起動も仮想化も許さないので, Linux は, QEMU が CPU の命令を解釈する形で動かします. JIT は使いません.

```text
  PadServer (iPad の上の1つの process)
  |
  +-- Swift の部分
  |     配信の入口      relay と tailnet から来た要求を受ける
  |     管理 API        padctl からの操作を受ける
  |     静的サイトの配信, ファイル置き場, dashboard
  |
  +-- QEMU (アプリに組み込んだ library)
        |
        +-- guest (アプリの中で動かす Linux, x86_64)
              +-- Docker
                    +-- container   例: FastAPI, Postgres, nginx

  配信の入口 --(アプリの中の loopback)--> QEMU の port の転送 --> container の port
```

container の速さの目安です. 本番機で測りました (V15).

| 動かしたもの | 結果 |
| --- | --- |
| アプリの起動から, Linux が使えるまで | 約15秒 |
| Docker の起動 | 約10秒 |
| nginx の container | 応答の中央値は 5.7 ms |
| FastAPI の container | 応答の中央値は 19.5 ms. 起動に27秒 |
| Postgres 18 の container | 主キーでの1行の取得は約 6 ms. 1行の insert と commit は約 19 ms. 初期化に約38秒 |
| container の中での計算 | 遅い. Mac の上の同じ構成で比べると, そのまま動かす場合の約90倍から150倍の時間がかかった. 本番機では, そこからさらに1.1倍から1.7倍かかった |
| メモリ | container を3つ動かして, Linux の側の使用は 169MB |

応答の時間は, Mac から tailnet 越しに, 接続を使い回して測った値です.
待つことが中心の処理は実用になる速さで, 計算が中心の処理は遅い, という性質があります.

### 2.3 アプリの中の層

クリーンアーキテクチャの4層を, SwiftPM の target として分けます (#38).
内側の層は外側の層を import できません. 違反するとビルドが落ちます.

```text
  外側                                                    内側
  App  --->  PadInfrastructure  --->  PadApplication  --->  PadDomain
       --->  PadInterface       --->  PadApplication  --->  PadDomain
```

| 層 | 置くもの | 例 |
| --- | --- | --- |
| PadDomain | entity と値. 何にも依存しません | プロジェクト (静的サイトか container か), release, 経路, 共有リンク, 要求と応答の形 |
| PadApplication | use case と port (外の世界との境界を表す protocol) | 「配備する」「経路を解決する」「管理を認可する」. 保存先と guest は protocol として持ちます |
| PadInterface | controller, 通信の型, 画面用の変換 | 管理 API の入出力の型. CLI もこの型を共有します |
| PadInfrastructure | port の実装. 外部の framework を使えるのはここだけです | Hummingbird, ファイルへの保存, Keychain, QEMU と Docker の操作, relay への接続 |
| App | 組み立てだけを行います | 実装を選んで use case に渡す. 画面 (SwiftUI) もここです |

### 2.4 リポジトリの構成

```text
padserver/
  project.yml                 XcodeGen の定義
  Config/
    Shared.xcconfig           既定値
    Local.xcconfig            Team ID と Bundle ID. git に入れない
    Local.xcconfig.example
  App/                        アプリの殻. 組み立てと画面
  Packages/
    PadServerCore/
      Sources/
        PadDomain/
        PadApplication/
        PadInterface/
        PadInfrastructure/    HTTP, 保存, ログ, relay への接続
      Tests/                  Mac の上で swift test が回る
    PadGuest/                 QEMU を包む. guest の起動と Docker の操作
  guest/                      guest の Linux を作る定義と script
  cli/                        padctl
  relay/                      Cloudflare に置く relay. Worker と Durable Object
  scripts/                    道具の導入, QEMU の取得とビルド
  examples/                   見本のプロジェクト
  spikes/                     実機での検証に使った最小のコード
  docs/
  .github/workflows/
  .pre-commit-config.yaml
```

QEMU のコードは, リポジトリに入れません (#47). 使う人がビルドのときに取得します.

## 3. 決めたこと

領域ごとにまとめ直しています. 決めた順の記録は decisions.md にあります.

### 3.1 何を作るか

| 番号 | 決めたこと | 補足 | 選ばなかった案 |
| --- | --- | --- | --- |
| #1 | 用途は4つ. 静的サイトとファイルの配信, 固定の自作 API, コードの差し替え実行, ファイル置き場 | 自作の API とコードの差し替えは, container の配備で実現します (#48) | 無し |
| #2 | 長く使う完成形として作る | 保守の状況と拡張のしやすさを重く見て選びます | まず動く最小版, 学習が主目的 |
| #3 | ソースを GitHub で公開し, 他人が自分の Apple ID でビルドして使える | 個人の設定 (Team ID など) を外に出します | App Store での公開, ビルド済みの配布 |
| #20 | 対応は iPadOS 26 以上 | 手元の iPad で確かめられる範囲だけを謳います. 本番機は iPadOS 27.0.1 です | iPadOS 18 以上 |
| #29 | ライセンスは MIT | 無し | Apache-2.0 |
| #47 | PadServer のコードは MIT のまま. QEMU (GPLv2) は, 使う人が自分でビルドして組み込む | QEMU のコードはリポジトリに入れず, script で取得します. ビルド済みのアプリは配りません. 検証に使った公開プロジェクトの tctiSH も, 本体は MIT で, QEMU は別のリポジトリから取得する形です | PadServer 全体を GPL にする |
| #30 | 名前は PadServer (アプリ), padctl (CLI), PadServerCore (package) | 無し | 無し |

### 3.2 インターネットへの公開

| 番号 | 決めたこと | 補足 | 選ばなかった案 |
| --- | --- | --- | --- |
| #4 | tailnet の中に加えて, インターネットにも公開する | 無し | 同じ Wi-Fi 内まで |
| #11 | 公開の経路は, iPad が自分で張る | 別の常時稼働機を間に置きません | 別のマシンで中継する |
| #12 | 独自ドメインで公開する | 任意のドメインを relay に割り当てられるようにします. どのドメインをどう Cloudflare に向けるかは, PadServer の範囲外です (決定項目84) | ts.net の名前だけ |
| #42 | 公開は自作の relay で行う. Cloudflare の Worker と Durable Object を relay にして, iPad のアプリから WebSocket を張ったままにする | 本番機で測ると, 1回の要求に Funnel は平均で約3.2秒, relay は平均で0.36秒でした. 大きいファイルと streaming は未確認です (V12) | Funnel のままにする, 両方を使い分ける |
| #25 | 複数のサイトは, サブドメインでもパスでも分けられる | プロジェクトごとに設定で選びます. relay が, 元のホスト名をアプリへ伝えます | どちらか片方だけ |
| #64 | relay のコードは, このリポジトリの `relay/` に置く. 使う人が, 自分の Cloudflare のアカウントへ配備する | 配備は script 1つで済むようにして, 無料プランの範囲で動く形にします | 別のリポジトリに分ける |

### 3.3 管理する口

| 番号 | 決めたこと | 補足 | 選ばなかった案 |
| --- | --- | --- | --- |
| #5 | インターネットから届くのは配信だけ. 管理は tailnet の中からだけ | 外からコードや image を送り込む経路を無くすためです | 管理も外から行う |
| #43 | 管理の認証は, token と, 接続元が tailnet の IP かどうかの確認 | 繋げる端末を自分のものだけに絞るのは, Tailscale のアクセス制御で行います | libtailscale を残して身元も確かめる |
| #8 | Mac からの操作は専用の CLI で行う | 無し | ブラウザの管理画面, iPad の画面で操作 |
| #21 | CLI は Swift で書く | アプリと通信の型を共有します | TypeScript, Python, Rust, Go |
| #78 | CLI が使う TOML の parser は TOMLDecoder | ライセンスは MIT です. Swift 6 でビルドできるかは, CLI の殻 (M0-10) で確かめます | swift-toml, TOMLKit |
| #26 | CLI の機能は, 配備, 状態, 開始と停止, 入れ直し, token の設定, ログの追尾, ファイル置き場の操作, 依存の準備, 環境変数と secret | 「依存の準備」は, 組み込みのランタイムのための機能でした. #48 で要らなくなり, 代わりに image を送る機能が要ります (#59) | 無し |
| #28 | ファイル置き場は, 期限付きの共有リンクで外に渡せる | 発行と失効は管理の口から行います. 公開の経路に載るのは, リンクでの読み取りだけです | tailnet の中だけ, フォルダ単位で公開 |

### 3.4 コードの動かし方

| 番号 | 決めたこと | 補足 | 選ばなかった案 |
| --- | --- | --- | --- |
| #48 | コードを動かす方法は, container だけにする. 配信するものは, container と静的サイトの2つ | 本番機の上で, Docker の container が動くことを確かめました (V15). 計算が中心の処理は約100倍遅くなりますが, 動かす方法を1つに絞って計画を小さくします | container を主役にして組み込みの Python を残す, 4つのランタイムを全部残して container を足す |
| #49 | 到達点は, Kikitoru を docker compose の構成のまま iPad で動かすこと | Kikitoru は, backend, worker, migrate, Postgres の4つの service でできています. DB も container で動かします. Kikitoru の backend そのものは, まだ本番機で動かしていません (V21). Kikitoru の側に変更が要るときは, Kikitoru のリポジトリの別の branch で行います | 検証用の小さな構成で確認する |
| #62 | プロジェクトの設定は `padserver.toml` に書く. container は compose のファイルをそのまま使い, 公開する経路だけを `padserver.toml` に書く | compose のファイルを書き換えずに載せられます. 対応する compose の機能の範囲は, M5-1 で決めます | compose の label に書く |
| #63 | container の port は, `padserver.toml` に経路を書いたものだけを配信の入口に繋ぐ | 経路を書いていない port は, インターネットからも tailnet からも届きません. compose の `ports` は, 公開の指示として扱いません. Postgres のような内部の service を, 誤って外に出さないためです | compose の `ports` を tailnet にだけ出す |
| #59 | image は, Mac でビルドして, `padctl` で tailnet 経由で iPad へ送る | Docker Hub などの公開の image は, iPad が直接取得します. iPad の上でのビルドは, 小さな image でも約4分かかりました. 送って読み込めるかは, V18 で確かめます | registry を経由する, iPad の上でビルドする |

### 3.5 Linux と Docker の動かし方

| 番号 | 決めたこと | 補足 | 選ばなかった案 |
| --- | --- | --- | --- |
| #56 | QEMU は, tctiSH が使っている fork を, commit を固定して取得する | 検証で動いた組み合わせをそのまま使います. JIT 無しで速く動かす仕組みは, この fork にしかありません. ビルドには nix が要ります. 取得元のリポジトリが消えると, ビルドできなくなります | 自分の GitHub に写しを置く |
| #57 | guest の Linux は, tctiSH の guest (Alpine Linux) を土台にして, kernel と起動の処理を直す | 起動時に Docker を自動で立ち上げます. これで Docker の既定のネットワークと `docker exec` が動くかは, V17 で確かめます | 一から自分で組む |
| #58 | アプリからは, guest の中の Docker の API を直接呼ぶ | API の口には認証を掛けて, 鍵は端末ごとに作ります. tctiSH に付いている公開の鍵は使いません | SSH で入ってコマンドを叩く |
| #60 | JIT は使わない | 有効にするには専用の VPN が要り, Tailscale と同時に使えない恐れがあります. 計算が約100倍遅いことは, 受け入れます | 後で試す検証を足す |
| #61 | guest の CPU は x86_64 で作る. arm64 の guest が動くかを確かめる検証を, 1つ足す | Mac で image をビルドするときは, `--platform linux/amd64` を付けます. arm64 が動けば, Mac でそのままビルドした image が使えます (V22). 結果が良ければ, 切り替えるかを改めて決めます | 検証を足さずに x86_64 のままにする |

### 3.6 アプリの土台

| 番号 | 決めたこと | 補足 | 選ばなかった案 |
| --- | --- | --- | --- |
| #18 | HTTP サーバーは Hummingbird 2 | container の port への転送を, streaming のまま書けます. TLS は Cloudflare が終えるので, アプリでは扱いません | FlyingFox, SwiftNIO で自作 |
| #80 | swift-distributed-tracing を, 1.6.0 未満に固定する | Hummingbird 2.27.1 が, 1.6.0 と一緒にはビルドできなかったためです. 上流は Hummingbird 2.28.0 で直したので, M0-21 で外します | 受け入れずに, 上流の修正を待つ |
| #38 | クリーンアーキテクチャの4層を, SwiftPM の target で分ける | 2.3 の通りです | 3層, フォルダだけで分ける |
| #19 | プロジェクトは XcodeGen で生成し, 中身はローカルの Swift package に置く | 生成した xcodeproj は git に入れません | 素の xcodeproj, Tuist |
| #52 | QEMU を包むコードは, 別の package (PadGuest) に出す | QEMU の binary が無い Mac や CI でも, 他の部分の `swift test` が回ります | PadInfrastructure の中に置く |

### 3.7 運用

| 番号 | 決めたこと | 補足 | 選ばなかった案 |
| --- | --- | --- | --- |
| #41 | 本番機は, iPad Pro 11インチ (第3世代, M1, iPadOS 27.0.1) にする | 画面は液晶です. 容量は 256GB で, メモリは 8GB です | iPad Pro 13インチ (M5) を本番機にする |
| #9 | 導入は無料の Apple ID で行う | 署名が7日で失効します. QEMU を組み込んだアプリも, 無料の Apple ID で署名できました (V15) | Apple Developer Program |
| #22 | 7日の失効には, CLI の入れ直しコマンドで対処する | Mac から `xcodebuild` と `devicectl` で入れ直します. 上書きの入れ直しでデータが残ることは確かめました (V6) | 定期実行, SideStore, 手作業 |
| #23 | 前面への固定は, アクセスガイドで行う | 端末を初期化せずに使えます. 再起動の後は, 人がアプリを開き直します | Single App Mode |
| #27 | iPad の画面は, 常時表示の dashboard | 本番機の画面は液晶なので, 焼き付きの恐れは小さいです | 暗い待機画面, 最小限の表示 |
| #65 | 常時表示の画面に, 特別な手当ては入れない | 明るさを下げる手順だけを, 運用の手順書に書きます | 時間が経つと暗くする機能を作る |

### 3.8 開発の進め方

| 番号 | 決めたこと | 補足 | 選ばなかった案 |
| --- | --- | --- | --- |
| #39 | 機能を作る前に, linter と pre-commit と GitHub Actions を入れる | 無し | 無し |
| #76 | Swift の検査は4つ. SwiftLint (厳しめ), swift-format, SwiftLint の analyzer (未使用のコードと import の検出), 警告のエラー扱い | Swift 6 の language mode でビルドします. analyzer はビルドの記録が要るので, CI で回します | Periphery を使い続ける, Periphery Pro, 有志の fork |
| #81 | 配列の末尾のカンマは, swift-format に合わせる. SwiftLint の `trailing_comma` は止める | 2つの道具の指示が逆で, 両方を通るファイルが書けなかったためです | SwiftLint に合わせる |
| #36 | Swift 以外の検査は, Markdown と YAML, GitHub Actions と shell, secret の混入と綴り | 道具は markdownlint-cli2, yamllint, actionlint, zizmor, shellcheck, shfmt, gitleaks, typos です | Worker の TypeScript の検査 |
| #37 | commit 時の検査は pre-commit で動かす | commit 時は速い検査だけ. ビルドと試験は CI です | lefthook, 素の git hook |
| #77 | GitHub Actions では, lint, build と test, 未使用のコードの検出, gitleaks の4つの job を回す. Dependabot で, 依存の更新を受け取る | QEMU のビルドは時間がかかり, nix も要るので, CI では行いません | Dependabot は入れない, QEMU のビルドも CI で回す |
| #51 | main への直接の push を禁じて, PR と CI の成功を必須にする | 最初の commit だけは, 保護を掛ける前に直接 push します | PR だけ必須にする, 保護しない |
| #31 | 作業は細かい Issue に分けて, GitHub Issues に置く | public なので, 個人的な情報は書きません | Linear, Markdown |
| #83 | コードやファイルを書く Issue は, 型と port も Codex の実装者が担当する | Codex が検証, commit, push, PR の作成まで行います. merge は所有者か指名された merge 係です | 型と port は本体が書く |
| #33 | 依存が解けた Issue は, 全て同時に走らせる | 実機での確認は1本ずつです | 3本まで, 2本まで |
| #34 | Issue ごとに PR を作り, 所有者が merge する | 無し | 本体が merge する, PR を作らない |
| #79 | PR の作り方は, [pull-requests.md](pull-requests.md) の通りにする | 本文には, 変更ごとに「何を変えたか」と「何のための変更か」を書きます. 画面のある実装と, 動かして見せられる実装は, スクリーンショットを載せます. merge は merge commit です | rebase and merge, 本文に署名を付ける, 変えたファイルを並べるだけにする |
| #72 | コードの書き方は, [implementation-rules.md](implementation-rules.md) の通りにする | 型, 設計, エラーと並行処理, 試験, コメントの決まりです. 試験は Swift Testing で, 実装より先に書きます | 無し |
| #55 | feature branch への commit, push, PR の作成は, 本体が行う | main への merge は, 所有者が行います (#34) | commit のたびに確認する, PR の作成も所有者が行う |
| #82 | reviewer の指摘は, 所有者に聞かずに本体が直してから PR を出す. 本体は, ビルドや動作を自分で確かめ直さない | 所有者の操作は merge だけになります. push の前の検査は, 本体に残します | 指摘を選ぶ手間だけを無くす, 本体の検証だけを無くす |
| #53 | 検証に使ったコードは, `spikes/` に README と一緒に残す | lint と CI の対象から外します. 取得した tctiSH と QEMU のコード, ビルドの成果物, 鍵と token, 端末の ID は入れません | README だけ残す, リポジトリに入れない |
| #66 | Issue は, 全ての段階を, 1つが1つの責務になるまで細かく分ける | container の部分 (M4 から M6) は, 検証の結果で書き直すことがあります | 近い段階だけ細かく分ける, 粗い一覧のままにする |
| #67 | Issue のタイトルと本文は, 日本語で書く | コマンドとファイルの名前は, 英語のままです | タイトルだけ英語にする, 全部英語にする |
| #68 | 段階と Issue の分け方は, 6章の通りにする. Issue は GitHub に作る | 8つの段階と199件の Issue を, 2026-10-11 に承認しました | 近い段階だけ先に作る, 一覧を直してから作る |
| #75 | 規則の文書は, Issue を1件足して (M0-20), PR で main に入れる | Issue は200件になりました | main に直接入れる, PR の template と同じ PR に入れる |
| #69 | 公開する文書と Issue では, 個人の名前を書かずに「所有者」と書く | #31 の「個人的な情報は書かない」に合わせます | 名前をそのまま書く |
| #70 | commit の名義は, 普段の git の設定のままにする | 名義のメールアドレスは, 公開の履歴に残ります. 一度は GitHub の noreply のアドレスを選びましたが, push の前に取り消しました | GitHub の noreply のアドレスを使う |

項目55と82の「本体」は, 項目83より前の担当を示します. コードやファイルを書く Issue の現在の担当は, 項目83に従います.

### 3.9 置き換えた決定

後の決定で置き換えたものです. #54, #73, #74 は所有者が担当を変えたため, #83 で置き換えました. 元の中身は decisions.md に残しています.

| 元の決定 | 中身 | 置き換えた決定 | 理由 |
| --- | --- | --- | --- |
| #13 | 公開は libtailscale の Funnel で行う | #42 | Funnel は, 1回の要求に約3.2秒かかった |
| #24 | 管理の認証で, Tailscale 上の身元も確かめる | #43 | 公開が relay になり, libtailscale を組み込む理由が無くなった |
| #6, #7, #14, #15, #16, #17, #44 | 4つのランタイム (JavaScriptCore, Python, WebAssembly, Node.js) と, その作り方 | #48 | container が本番機で動いたので, 動かす方法を container に絞った |
| #45, #46 | DB は対象外にする. Kikitoru は到達点に入れない | #49 | Postgres が container で動いたので, Kikitoru を compose のまま動かすことを到達点にした |
| #32 | 実装は, Sonnet の implementer を Issue ごとの worktree に並列に立てる | #73 | 所有者の判断で, 実装もレビューも Codex のワーカーに変えた |
| #35, #50 | 未使用のコードの検出に Periphery を使い, CI の job にする | #76, #77 | Periphery の上流が archive されて, 商用の製品に移った. SwiftLint の analyzer に替えた |
| #71 | merge は rebase and merge で行う | #79 | 最初の8件の PR が merge commit で入ったので, 規則の方を合わせた |
| #54, #73, #74 | 型と port は本体が書き, 本体が PR を作る | #83 | 所有者の指示で, コードやファイルを書く Issue を Codex が担当することに変えた |

## 4. 実機で確かめること

実機で試さないと分からない前提です. 外れると決定の見直しが要るので, 関わる部分を作る前に確かめます.

### 4.1 確認が済んだもの

2026-10-09 に, 本番機で確かめました.

| 番号 | 確かめたこと | 結果 | 残っている点 |
| --- | --- | --- | --- |
| V8 | Tailscale のアプリ経由で, iPad 上のアプリのポートに TCP が届く | 届きました. a-Shell でも自作のアプリでも, Mac からの `curl` に 200 が返りました. 管理の経路 (#43) の土台になります | 経路は同じ LAN の中の直接接続でした. 中継を挟む経路では試していません |
| V9 | Xcode 26.6 から, iPadOS 27.0.1 の本番機へ自作のアプリを入れられる | 入れられました. ビルド, 無料の Apple ID での署名, インストール, 起動が通りました. Xcode 27 は要りません | 無し |
| V6 | 入れ直しても, アプリのデータが保たれる | 保たれました. 同じ Bundle ID で上書きした後も, Documents のファイルが残りました | 署名が失効した後に, 新しい profile で入れ直す場合は試していません |
| V11 | 自作の relay を通して, 公開の URL から本番機のアプリへ届く | 届きました. 1回の要求は平均で0.36秒でした (24回, 0.29秒から0.40秒). 起動してすぐに通りました. 同時に20本投げても, 全て成功しました | 小さな応答だけで測りました. 残りは V12 と V13 です |
| V15 | iPad の上で, 本物の Docker の container が動く | 動きました. QEMU をアプリに組み込んで Linux を動かす公開プロジェクト (tctiSH) を本番機に入れて, その中で Docker 29.8.2 を動かしました. JIT は使わず, 無料の Apple ID で署名しました. `docker pull`, `docker run`, `docker build` が通り, nginx, Postgres 18, FastAPI の container が動きました. 速さは 2.2 の表の通りです | `docker exec` と, Docker の既定のネットワークは動きませんでした (V17). 動かしたのは約12分です (V16). `Extended Virtual Addressing` の権限は, 無料の Apple ID では使えませんでした (V20) |

使わないことにした検証の結果も, 記録として残します.

| 番号 | 確かめたこと | 結果 | 使わない理由 |
| --- | --- | --- | --- |
| V1 | libtailscale の Funnel で, 公開の入口から本番機のアプリへ届く | 届きましたが, 1回の要求に平均で約3.2秒かかりました | 公開の方式を relay に変えました (#42) |
| V2 | libtailscale で, 接続元の Tailscale 上の身元を問い合わせられる | 問い合わせられました | libtailscale を組み込まないことにしました (#43) |
| V14 | 自作のアプリに組み込んだ Python 3.14 で, compile が要るパッケージを使う FastAPI のアプリが動く | 動きました. 接続を使い回すと, 応答の中央値は 12.8 ms でした | 組み込みのランタイムを作らないことにしました (#48) |
| V4 | 組み込んだ Python のコードを, アプリを入れ直さずに差し替えられる | インタプリタを動かしたまま, コードだけを入れ替える形が通りました. 初期化のやり直しと subinterpreter は使えませんでした | 同上 |

### 4.2 これから確かめるもの

| 番号 | 前提 | 外れたときの影響 | 確かめ方 | Issue |
| --- | --- | --- | --- | --- |
| V21 | Kikitoru の backend と worker の image が, guest の Docker の上で, 実用になる時間で起動して応答する | 到達点 (#49) が成り立たない. Kikitoru の側を軽くするか, 到達点を見直す | Kikitoru の image を linux/amd64 でビルドして, Postgres と一緒に動かす. Mac の上の同じ QEMU で試してから, 本番機で試す. 起動の時間, 応答の時間, メモリを測る | M1-8, M1-9 |
| V17 | guest の Linux を作り直すと, Docker の既定のネットワーク, `docker exec`, `docker compose` が動く | compose の構成をそのままは動かせない. container を1つのネットワークに並べる形に書き換える必要が出る | kernel に netfilter, bridge, veth を入れ, 起動の処理が root を切り替える方法を直して, Mac の上の同じ QEMU で試す. その後に本番機で試す | M1-1 から M1-5 |
| V18 | Mac でビルドした linux/amd64 の image を, iPad の Docker へ送って読み込める | image を iPad の上でビルドするか, registry から取る形に限られる. iPad の上でのビルドは遅い | Mac で `--platform linux/amd64` を付けてビルドし, 送って読み込む時間を測る | M1-6, M1-7 |
| V16 | container を動かしたまま, 何日も動かし続けられる | 定期的にアプリを起動し直す運用にするか, 動かす container を絞る | container を3つ動かしたまま丸1日以上置いて, 応答, メモリ, 発熱を見る | M1-10 |
| V19 | アプリが背景に回った後と, 前面に戻った後に, guest と container が動き続ける | 前面に戻るたびに, container を起動し直す処理が要る | アクセスガイドの有り無しで, 背景に回す, 画面をロックする, 通知を受ける, の3つを試す | M1-11 |
| V20 | 無料の Apple ID の権限で, guest に必要なだけのメモリを与えられる | 同時に動かす container を絞る | guest のメモリを 2GB, 3GB, 4GB にして起動し, container を増やしてアプリが落ちないかを見る | M1-12 |
| V22 | tctiSH の QEMU で, arm64 の guest が JIT 無しで動く | 影響は小さい. x86_64 のまま作る (#61) | arm64 の Alpine と Docker を Mac の上の QEMU で動かして, x86_64 と速さを比べる | M1-13 |
| V12 | relay で, 大きいファイルと streaming を運べる | 公開の経路で配れるファイルの大きさに上限を置く. それで足りなければ, #42 を見直す | 本文を小分けにして送る取り決めを最小の形で作り, 数百 MB のファイルと Range の要求を通す. upload の大きさの上限も確かめる | M1-14 から M1-16 |
| V13 | relay への WebSocket が切れた後と, アプリが前面に戻った後に, 自動で繋ぎ直せる | 切れるたびに, 人がアプリを開き直す運用になる | 回線を切る, アプリを背景に回す, relay を配備し直す, の3つで繋ぎ直しを見る | M1-17 |
| V7 | 署名が失効した瞬間に, 起動中のアプリが止まるか | 止まるなら, 失効の前に必ず入れ直す運用にする | 失効の時刻をまたいで動かし続ける | M1-18 |

V21 は, 到達点そのものが成り立つかを確かめるものです. 本番機で動かしたのは小さな FastAPI のアプリだけで, Kikitoru の backend はそれより多くのライブラリを読み込みます. 土台を作り込む前に確かめます.
V17 と V18 は, container の配備の形を決める前提です. これも先に確かめます.

## 5. まだ決めていないこと

2026-10-11 に, 提案のうち16件を1つずつ確認して, decisions.md の項目50から項目65にしました.
feature branch の push と PR の作成を誰が行うかは, 2026-10-13 に決めました (#74).
残っているのは, 検証の結果を待ってから決めるものです.

| 番号 | 項目 | 今の考え | 決める時期 |
| --- | --- | --- | --- |
| U18 | Kikitoru の大きい音声の upload | Kikitoru は 500MB までの音声を受け取ります. relay を通せる大きさは, V12 で確かめるまで分かりません. 通せない場合は, 音声を保存先 (S3) へ直接送る形に変える案があります | M6-2 |
| U19 | compose の動かし方と, 対応する機能の範囲 | compose の CLI を guest の中で動かして, 経路は上書き用の compose で出す見込みです | M5-1 |
| U20 | guest を arm64 に切り替えるか | x86_64 で作ります (#61). arm64 が動いて, 速さが同じくらいなら, 切り替える案があります | V22 の結果が出た後 |
| U21 | relay の取り決めの細目 | 本文を小分けにして, WebSocket で運ぶ形です | M3-1 |

## 6. 計画表

段階の分け方と Issue の一覧は, 2026-10-11 に承認されました (#68). Issue は GitHub に作ってあります.
2026-10-13 に, 開発の規則の文書を入れる Issue を1件足しました (#75).
その後に, 依存の固定を外す Issue (M0-21), Swift の lint の食い違いを直す Issue (M0-22), 決定の記録を更新する Issue (M0-23) を足しました.
2026-10-14 に, PR の規則を書き直す Issue (M0-24) と, 道具の導入を手直しする Issue (M0-25) を足しました.

### 6.1 段階の一覧

| 段階 | 作るもの | 終わりの確認 | Issue の数 |
| --- | --- | --- | --- |
| M0 開発基盤 | lint, pre-commit, GitHub Actions, 4層の空の骨組み, 開発の規則の文書 | 空の骨組みが, 手元の hook と CI の両方を通る | 25 |
| M1 実機での検証 | 4章の前提を確かめる最小のコード | それぞれの結果を decisions.md に書く. 外れたものは決定を見直す | 18 |
| M2 土台 | 型と protocol, 保存, 配信と管理の2つの入口, 静的サイトの配信, 管理 API, CLI の基本, dashboard | Mac から静的サイトを配備して, tailnet 経由で表示できる | 54 |
| M3 公開 | relay (Cloudflare の Worker と Durable Object), アプリからの接続, 独自ドメインの割り当て | 独自ドメインの URL を tailnet の外から開ける. 管理 API は外から届かない | 21 |
| M4 Linux と Docker | QEMU のビルド, guest の Linux, アプリからの起動と停止, Docker の操作, port の転送 | アプリを起動すると Linux と Docker が立ち上がり, container を動かして表示できる | 27 |
| M5 container の配備 | compose の構成の配備, image の送信, 経路, 環境変数と secret, ログ, 再起動への備え | FastAPI と Postgres の2つの container を配備して, 独自ドメインから開ける | 29 |
| M6 Kikitoru | Kikitoru の frontend と, compose の構成の配備 | 独自ドメインでログインして, 音声を1本送り, 議事録ができる | 11 |
| M7 仕上げ | ファイル置き場, 共有リンク, 手順書 | 手順書だけを見て, まっさらな状態からビルドできる | 20 |

Issue は, 全部で205件です.

### 6.2 段階の依存

```text
  M0 開発基盤 ----+
                  +--> M2 土台 --+--> M3 公開 ----------+
                  |              |                      +--> M5 container の配備 --> M6 Kikitoru --+
  M1 実機での検証 -+ (結果を反映) +--> M4 Linux と Docker +                                         +--> M7 仕上げ
                                 +--> M7 のうち, ファイル置き場と共有リンク -----------------------+
```

- M0 と M1 は同時に進められます. M1 のコードは `spikes/` の中で閉じていて, 他と触るファイルが重なりません.
- M3 と M4 は互いに独立なので, M2 が終われば同時に進められます.
- M4 の guest の部分は V17, M5 は V17 と V18, M3 は V12 と V13 の結果を待ちます.
- V21 が外れると到達点の見直しが要るので, M1-8 と M1-9 は, M2 の実装と並べて早めに行います.
- M7 のうち, ファイル置き場と共有リンクは, M2 が終われば進められます. 手順書は最後に書きます.

### 6.3 Issue の一覧

Issue は, 1つが1つの責務だけを持ち, 1つの PR で終わる大きさに分けています (#66).
目安は, 実装のファイルが1つか2つと, その試験です.
GitHub の欄は, GitHub の Issue の番号です. 決定の番号 (`#42` の形) とは別のものです.

担当の欄は, 2026-10-11 に計画した時点の割り当てです. コードやファイルを書く Issue の「本体」は, 着手時に Issue の本文とラベルを「実装者」に直し, Codex が担当します (#83).

| 担当 | 意味 |
| --- | --- |
| 実装者 | Codex (gpt-6-luna) のワーカーが worktree で実装する |
| 本体 | この会話の Claude が直接行う |
| 実機 | 本体と所有者が, iPad を使って確かめる |
| 所有者 | 所有者の操作か判断が要る |

#### M0 開発基盤

| ID | GitHub | Issue | 依存 | 担当 |
| --- | --- | --- | --- | --- |
| M0-1 | 1 | リポジトリの初期化. `.gitignore`, `LICENSE` (MIT), `README.md` の骨子を置く. `docs/` と調査メモを含めて, 最初の commit を main に push する | 無し | 本体 |
| M0-2 | 2 | Swift の lint の設定. SwiftLint の厳しめの設定 (opt-in の規則を含む) と, swift-format の設定を置く | M0-1 | 実装者 |
| M0-3 | 3 | Markdown と YAML の lint の設定. markdownlint-cli2 と yamllint の設定を置く | M0-1 | 実装者 |
| M0-4 | 4 | shell と GitHub Actions の lint の設定. shellcheck, shfmt, actionlint, zizmor の設定を置く | M0-1 | 実装者 |
| M0-5 | 5 | secret と綴りの検査の設定. gitleaks と typos の設定を置く | M0-1 | 実装者 |
| M0-6 | 6 | 道具を入れる script. 開発に要る道具 (SwiftLint, XcodeGen, pre-commit, 各 linter) を, 1つのコマンドで入れられるようにする | M0-1 | 実装者 |
| M0-7 | 7 | pre-commit の設定. 全ての hook を1つの設定に束ねる. commit 時に動かすのは速い検査だけにする | M0-2, M0-3, M0-4, M0-5, M0-6, M0-22 | 実装者 |
| M0-8 | 8 | PadServerCore の骨組み. 4層の空の target と, 試験の target, 試験用の共有の target (PadTestSupport) を作る. Swift 6 の language mode と, 警告のエラー扱いを設定する. Hummingbird を PadInfrastructure の依存に宣言する | M0-1 | 実装者 |
| M0-9 | 9 | アプリの殻. XcodeGen の定義と xcconfig と, 最小の SwiftUI のアプリを置く. Team ID と Bundle ID は `Config/Local.xcconfig` から読む | M0-8 | 実装者 |
| M0-10 | 10 | CLI の殻. `padctl` の package を作る. PadServerCore の PadInterface に依存する. swift-argument-parser と TOML の parser (TOMLDecoder) を依存に宣言する | M0-8 | 実装者 |
| M0-11 | 11 | CI: lint. pre-commit の全ての hook を回す workflow を置く. action は commit の hash で固定する | M0-7 | 実装者 |
| M0-12 | 12 | CI: build と test. `swift test` (PadServerCore), `swift build` (cli), iOS Simulator 向けの `xcodebuild build` を回す workflow を置く | M0-9, M0-10 | 実装者 |
| M0-13 | 13 | CI: 未使用のコードの検出. 未使用のコードと import を検出する workflow を置く. SwiftLint の analyzer (`unused_declaration` と `unused_import`) を, xcodebuild のビルドの記録を渡して動かす | M0-12 | 実装者 |
| M0-14 | 14 | CI: gitleaks. 履歴の全体を調べる workflow を置く | M0-5 | 実装者 |
| M0-15 | 15 | Dependabot の設定. GitHub Actions と Swift の依存の更新を受け取る | M0-11 | 実装者 |
| M0-16 | 16 | PR の template. `docs/pull-requests.md` の6章の形に合わせて, 対応する Issue, 実装内容, 変更点, API の変更, 画面と動作, 検証, レビューの指摘を書く欄を置く | M0-1 | 実装者 |
| M0-17 | 17 | main の保護. main への直接の push を禁じて, PR と CI (lint, build, 未使用のコードの検出, gitleaks) の成功を必須にする | M0-11, M0-12, M0-13, M0-14 | 本体, 所有者 |
| M0-18 | 18 | 検証のコードを移す (001 から 005). 作業用の場所にある検証のコードと README を `spikes/` に移す. 個人的な情報 (端末の ID, IP, tailnet の名前, Team ID), token, ビルドの成果物, 取得した framework を除く. `spikes/` を lint と CI の対象から外す | M0-7 | 本体 |
| M0-19 | 19 | 検証のコードを移す (006). tctiSH を使った検証の README と起動の script を移す. tctiSH に当てた変更は patch にして残す. tctiSH と QEMU のコード, 鍵, disk の image は入れない | M0-18 | 本体 |
| M0-20 | 200 | 開発の規則の文書. PR の規則 (`docs/pull-requests.md`) と, 実装の規則 (`docs/implementation-rules.md`) を置く. 2つの規則と, 実装とレビューの担い手の変更を, 決定の記録と roadmap に反映する | M0-1 | 本体 |
| M0-21 | 209 | swift-distributed-tracing の固定を外す. M0-8 で入れた swift-distributed-tracing の版の固定 (1.6.0 未満) を外す. 上流の Hummingbird の issue 922 が直って, 修正を含む版が出てから行う. 固定の行が出す SwiftPM の warning (`dependency 'swift-distributed-tracing' is not used by any target`) も, これで消える | M0-8 | 実装者 |
| M0-22 | 210 | Swift の lint の食い違いを直す. SwiftLint と swift-format を, 同じファイルが両方を通れるように揃える. 複数行の配列の末尾のカンマは swift-format に任せて, SwiftLint の `trailing_comma` を止める. `file_header` は, SwiftPM に要る `// swift-tools-version:` の行だけを許す. `Packages/PadServerCore/Package.swift` を swift-format で整形する | M0-2, M0-8 | 実装者 |
| M0-23 | 211 | 決定の記録の更新 (未使用のコードの検出, merge の方法, TOML の parser). 所有者が 2026-10-13 と 2026-10-14 に決めた3つを, 決定の記録と roadmap と PR の規則に反映する. 未使用のコードの検出を, Periphery から SwiftLint の analyzer に替える. merge の方法を, rebase and merge から merge commit に替える. `padctl` の TOML の parser を TOMLDecoder にする. M0-22 とこの Issue を, roadmap の一覧に足す | M0-20 | 本体 |
| M0-24 | 219 | PR の規則を, Codex のレビューに任せる流れに書き直す. 所有者が 2026-10-14 に決めた流れを, PR の規則と決定の記録と roadmap に反映する. reviewer の指摘は, 所有者に聞かずに本体が直してから PR を出す. 本体が自分でビルドや動作を確かめ直す手順は省く. push の前の検査は残す. M0-24 と M0-25 を, roadmap の一覧に足す | M0-23 | 本体 |
| M0-25 | 220 | 道具の導入の手直し (hook の有効化と swift-format). `scripts/bootstrap.sh` で `pre-commit install` を実行して, clone した直後から hook が動くようにする. README に手順を1行書く. Brewfile から, hook が使っていない Homebrew の `swift-format` を外す | M0-6, M0-7 | 実装者 |

#### M1 実機での検証

済んだ検証は 4.1 にあります. Issue にするのは, 残っている検証だけです. どの Issue も, 結果を `spikes/` の README と decisions.md に書いて終わります.

| ID | GitHub | Issue | 依存 | 担当 |
| --- | --- | --- | --- | --- |
| M1-1 | 20 | guest の kernel を自分でビルドする (V17). tctiSH の kernel の config とビルドの手順を調べて, 何も変えずにビルドし, Mac の QEMU で起動する. ビルドは Linux の機械で行う | 無し | 本体 |
| M1-2 | 21 | kernel にネットワークの機能を足す (V17). netfilter, bridge, veth を有効にして, Docker を既定のネットワークのまま起動する | M1-1 | 本体 |
| M1-3 | 22 | guest の起動の処理を直す (V17). root を chroot で切り替える処理をやめて, `docker exec` と, Docker の既定の置き場が使えるようにする | M1-1 | 本体 |
| M1-4 | 23 | docker compose を動かす (V17). compose を guest に入れて, FastAPI と Postgres の2つの service の構成を動かす. compose の CLI を container として動かす形も試す | M1-2, M1-3 | 本体 |
| M1-5 | 24 | 作り直した guest を本番機で動かす (V17). 作り直した kernel と initrd を検証用のアプリに入れて, 本番機で M1-4 と同じ確認をする | M1-4 | 本体, 実機 |
| M1-6 | 25 | image を送って読み込む: Mac (V18). Mac で `--platform linux/amd64` を付けてビルドした image を書き出して, Mac の QEMU の guest の Docker に流し込む | 無し | 本体 |
| M1-7 | 26 | image を送って読み込む: 本番機 (V18). 同じことを, 本番機に対して tailnet 越しに行う | M1-6 | 本体, 実機 |
| M1-8 | 27 | Kikitoru を guest で動かす: Mac (V21). Kikitoru の backend と worker の image を linux/amd64 でビルドして, Mac の QEMU の guest で, Postgres と migrate と一緒に起動する. 外のサービスの鍵は見本の値にする | M1-6 | 本体 |
| M1-9 | 28 | Kikitoru を guest で動かす: 本番機 (V21). 同じ構成を本番機で動かして測る | M1-7, M1-8 | 本体, 実機 |
| M1-10 | 29 | 丸1日以上動かし続ける (V16). container を3つ動かしたまま, 本番機で丸1日以上置く. 1分ごとに応答を記録して, メモリと発熱を見る | 無し | 実機 |
| M1-11 | 30 | 背景と前面の行き来 (V19). アクセスガイドの有り無しで, 背景に回す, 画面をロックする, 通知を受ける, の3つを試す. guest の時計のずれも見る | 無し | 実機 |
| M1-12 | 31 | guest のメモリの上限 (V20). guest のメモリを 2GB, 3GB, 4GB にして起動し, container を増やしてアプリが落ちないかを見る | 無し | 実機 |
| M1-13 | 32 | arm64 の guest を試す (V22). tctiSH の QEMU が, arm64 の guest を JIT 無しで動かせるかを調べる. 動くなら, Mac の QEMU で arm64 の Alpine と Docker を動かして, x86_64 と速さを比べる | 無し | 本体 |
| M1-14 | 33 | relay: 大きい応答を運ぶ (V12). 応答の本文を小分けにして WebSocket で運ぶ取り決めを, 最小の形で作る. 数百 MB の download と, Range の要求を通す | 無し | 本体, 実機 |
| M1-15 | 34 | relay: 大きい要求を運ぶ (V12). upload の向きを確かめる. Cloudflare が受け付ける要求の本文の上限を実測する | M1-14 | 本体, 実機 |
| M1-16 | 35 | relay: 少しずつ出る応答を運ぶ (V12). 少しずつ出る応答 (Server-Sent Events) が, 途中で溜められずに届くかを確かめる | M1-14 | 本体, 実機 |
| M1-17 | 36 | relay: 繋ぎ直し (V13). 回線を切る, アプリを背景に回す, relay を配備し直す, の3つで, 自動で繋ぎ直せるかを見る | 無し | 本体, 実機 |
| M1-18 | 37 | 署名の失効をまたぐ (V7). 無料の Apple ID の署名が失効する時刻をまたいで, アプリを動かし続ける | 無し | 実機 |

#### M2 土台

| ID | GitHub | Issue | 依存 | 担当 |
| --- | --- | --- | --- | --- |
| M2-1 | 38 | 型: プロジェクト. プロジェクト, 名前 (使える文字の検証), 種類 (静的サイトか compose か) の型を書く | M0-8 | 本体 |
| M2-2 | 39 | 型: release. release, その ID, 状態 (準備中, 有効, 退役) の型を書く | M2-1 | 本体 |
| M2-3 | 40 | 型: 経路. 経路 (host とパスの prefix) と, 向き先 (静的サイトか, container の service と port か) の型を書く. host とパスの正規化を含む | M2-1 | 本体 |
| M2-4 | 41 | 型: 要求と応答. 配信の入口, relay, container への転送で共有する, 要求と応答の head の形と, 本文の stream の抽象を書く | M0-8 | 本体 |
| M2-5 | 42 | 型: 共有リンク. 共有リンクと, 期限の判定を書く | M0-8 | 本体 |
| M2-6 | 43 | 型: 管理の認証. 管理の token, 接続元の住所, tailnet の範囲 (100.64.0.0/10 と fd7a:115c:a1e0::/48) の判定を書く | M0-8 | 本体 |
| M2-7 | 44 | 型: ログ. ログの1件 (時刻, 出所, level, 本文) の型を書く | M0-8 | 本体 |
| M2-8 | 45 | 型: 設定ファイル. `padserver.toml` を表す型と, 検証の規則を書く. 静的サイトの分だけを扱う | M2-1, M2-3 | 本体 |
| M2-9 | 46 | port: 保存. プロジェクトの一覧, release, ファイルの中身 (blob) を保存する protocol を書く | M2-2, M2-3 | 本体 |
| M2-10 | 47 | port: secret と token. secret と token を保存する protocol を書く | M2-6 | 本体 |
| M2-11 | 48 | port: ログと時計. ログの bus, 時計, ID の生成の protocol を書く | M2-7 | 本体 |
| M2-12 | 49 | 管理 API の仕様. endpoint の一覧, 認証の header, エラーの形, 版の付け方を文書にする. 範囲は, 配備, 状態, 開始と停止, ログ | M2-8 | 本体 |
| M2-13 | 50 | 通信の型. 管理 API の入出力の型を書く. 配備, 状態, 開始と停止, ログの1件, エラー. JSON の形を試験で固定する | M2-12 | 本体 |
| M2-14 | 51 | 試験用の実装. port の in-memory の実装 (保存, secret, ログ, 時計) を, 試験から共有できる target に置く | M2-9, M2-10, M2-11 | 実装者 |
| M2-15 | 52 | use case: 配備の差分. 送る側が出したファイルの一覧 (パスと hash) から, iPad に無いものを答える | M2-9, M2-14 | 実装者 |
| M2-16 | 53 | use case: 配備の確定. 揃ったファイルから release を作って, 有効な release を切り替える. 足りないファイルがあれば, 切り替えない | M2-9, M2-14 | 実装者 |
| M2-17 | 54 | use case: 古い release の掃除. 直近の3つを残して, 古い release と, どの release からも参照されない blob を消す | M2-16 | 実装者 |
| M2-18 | 55 | use case: 経路の解決. host とパスから, プロジェクトと向き先を引く. サブドメインとパスの両方に対応する. 長い prefix を優先する | M2-3, M2-9, M2-14 | 実装者 |
| M2-19 | 56 | use case: 管理の認可. token を定数時間で照合して, 接続元が tailnet の IP かを確かめる. 両方が通ったときだけ許す | M2-6, M2-10, M2-14 | 実装者 |
| M2-20 | 57 | use case: token の発行. 推測できない token を作って保存する. 作り直すと, 古い token は無効になる | M2-10, M2-14 | 実装者 |
| M2-21 | 58 | use case: プロジェクトの一覧と状態. プロジェクトごとに, 種類, 有効な release, 動いているかを返す | M2-9, M2-14 | 実装者 |
| M2-22 | 59 | use case: プロジェクトの開始と停止. プロジェクトを止めると, その経路は解決されなくなる. 始めると戻る | M2-9, M2-14 | 実装者 |
| M2-23 | 60 | 保存: プロジェクトの一覧. プロジェクトの一覧を JSON のファイルに持つ. 書き換えは, 一時ファイルと rename で原子的に行う | M2-9 | 実装者 |
| M2-24 | 61 | 保存: blob. ファイルの中身を, hash の名前で持つ. 同じ中身は1つだけ持つ. 受け取りは streaming で書いて, hash が合わなければ捨てる | M2-9 | 実装者 |
| M2-25 | 62 | 保存: release. release の manifest (パスと hash の対応) を持つ. 有効な release の切り替えを原子的に行う | M2-9 | 実装者 |
| M2-26 | 63 | 保存: Keychain. token と secret を Keychain に持つ実装を書く | M2-10 | 実装者 |
| M2-27 | 64 | ログの bus. 複数の購読者にログを流す. 直近の1,000件を保持して, 後から繋いだ購読者に渡す | M2-11 | 実装者 |
| M2-28 | 65 | 配信の入口. Hummingbird で loopback だけに待ち受けて, 経路の解決を呼んで振り分ける. 当たらなければ 404, 停止中は 503 を返す | M2-4, M2-18 | 実装者 |
| M2-29 | 66 | 静的ファイルの応答. 有効な release のファイルを返す. Content-Type, ETag, If-None-Match, index.html に対応する. 置き場の外に出るパスを拒む | M2-25, M2-28 | 実装者 |
| M2-30 | 67 | Range の応答. Range の要求に 206 と 416 を返す. 複数の範囲は扱わない | M2-29 | 実装者 |
| M2-31 | 68 | 要求の記録. 配信の入口が, 要求ごとに, 時刻, host, パス, status, かかった時間をログの bus に流す | M2-27, M2-28 | 実装者 |
| M2-32 | 69 | 管理用の待ち受け. 配信とは別の port で待ち受けて, 接続元の IP を取り出して要求に付ける | M2-6 | 実装者 |
| M2-33 | 70 | 認証の middleware. token の header を読んで, 管理の認可の use case を呼ぶ. 通らなければ 401 か 403 を返す | M2-19, M2-32 | 実装者 |
| M2-34 | 71 | エラーの応答. use case のエラーを, 仕様のエラーの形に変える | M2-13, M2-32 | 実装者 |
| M2-35 | 72 | 管理 API: 配備の問い合わせと確定. 配備の差分を答える endpoint と, 配備を確定する endpoint を書く | M2-13, M2-15, M2-16, M2-33 | 実装者 |
| M2-36 | 73 | 管理 API: ファイルの受け取り. 送られた本文を, streaming のまま blob の保存に流す. 大きさの上限を設ける | M2-13, M2-24, M2-33 | 実装者 |
| M2-37 | 74 | 管理 API: 状態, 開始, 停止. プロジェクトの一覧と状態, 開始, 停止の endpoint を書く | M2-13, M2-21, M2-22, M2-33 | 実装者 |
| M2-38 | 75 | 管理 API: ログの streaming. 直近のログを返した後, 繋いだまま新しいログを流す | M2-13, M2-27, M2-33 | 実装者 |
| M2-39 | 76 | CLI: 接続先と token. `padctl login` を書く. 接続先を設定のファイルに, token を Mac の Keychain に保存する | M0-10 | 実装者 |
| M2-40 | 77 | CLI: 管理 API の client. 認証の header を付けて管理 API を呼ぶ. エラーを読める文に変える. streaming の応答を受け取れる | M2-13, M2-39 | 実装者 |
| M2-41 | 78 | CLI: `padctl status`. プロジェクトの一覧と状態を表示する | M2-37, M2-40 | 実装者 |
| M2-42 | 79 | CLI: 設定ファイルの読み取り. `padserver.toml` を読んで, 設定の型にする. 誤りは, 行の番号と一緒に示す | M0-10, M2-8 | 実装者 |
| M2-43 | 80 | CLI: `padctl deploy` (静的サイト). フォルダを走査して hash を計算し, 足りないファイルだけを送って, 配備を確定する | M2-35, M2-36, M2-40, M2-42 | 実装者 |
| M2-44 | 81 | CLI: `padctl start` と `padctl stop`. プロジェクトを始める, 止める | M2-37, M2-40 | 実装者 |
| M2-45 | 82 | CLI: `padctl logs`. ログを追尾して表示する. Ctrl-C で止まる | M2-38, M2-40 | 実装者 |
| M2-46 | 83 | CLI: `padctl reinstall`. `xcodegen`, `xcodebuild`, `devicectl` を呼んで, ビルドして iPad へ入れ直す. 端末の ID は設定から読む | M0-9, M2-39 | 実装者 |
| M2-47 | 84 | App: 組み立て. 実装を選んで use case に渡し, 配信と管理の2つの待ち受けを起動する | M2-23, M2-24, M2-25, M2-26, M2-29, M2-31, M2-33, M2-34, M2-35, M2-36, M2-37, M2-38 | 実装者 |
| M2-48 | 85 | App: lifecycle. 前面に戻ったときに, 待ち受けを確かめて再開する. 自動ロックを止める | M2-47 | 実装者 |
| M2-49 | 86 | App: 初回の設定の画面. token の表示と作り直し, 管理の接続先の表示を行う画面を書く | M2-20, M2-47 | 実装者 |
| M2-50 | 87 | dashboard: プロジェクトの一覧. プロジェクトの一覧と状態を出す画面と, 画面用の変換を書く | M2-21, M2-47 | 実装者 |
| M2-51 | 88 | dashboard: 要求の流れ. 直近の要求を, 新しい順に出す画面を書く | M2-31, M2-47 | 実装者 |
| M2-52 | 89 | dashboard: ログ. ログを追尾して出す画面を書く | M2-27, M2-47 | 実装者 |
| M2-53 | 90 | 見本の静的サイト. 通しの確認と手順書で使う, 最小の静的サイトを置く | M2-8 | 実装者 |
| M2-54 | 91 | 通しの確認: 静的サイト. Mac から見本の静的サイトを配備して, tailnet 経由で表示する. token の無い要求が拒まれることも確かめる. `padctl reinstall` で入れ直せることも確かめる | M2-43, M2-46, M2-48, M2-49, M2-53 | 実機 |

#### M3 公開

| ID | GitHub | Issue | 依存 | 担当 |
| --- | --- | --- | --- | --- |
| M3-1 | 92 | relay の取り決め. アプリと relay のやり取りを文書にする. frame の形, 要求と応答の小分け, 流量の制御, 取り消し, 接続の認証, 元のホスト名の受け渡し. 試験用の byte 列の見本も作る | M1-14, M1-15, M1-16, M1-17 | 本体 |
| M3-2 | 93 | 取り決めの frame: Swift. frame の型と, encode と decode を書く | M3-1 | 実装者 |
| M3-3 | 94 | relay の骨組み. wrangler の設定, TypeScript の設定, 試験の土台を置く. パッケージの管理は bun で行う | M0-1 | 実装者 |
| M3-4 | 95 | 取り決めの frame: TypeScript. frame の型と, encode と decode を書く | M3-1, M3-3 | 実装者 |
| M3-5 | 96 | relay: iPad からの接続を受ける. Durable Object が WebSocket を受けて, token で認証する. hibernation を使う. 同時に繋げるのは1本だけにする | M3-4 | 実装者 |
| M3-6 | 97 | relay: 公開の要求を運ぶ. Worker が要求を Durable Object に渡して, 小分けの応答を stream で返す. 元のホスト名を伝える | M3-5 | 実装者 |
| M3-7 | 98 | relay: 大きい本文と取り消し. 流量を制御する. 訪問者が接続を切ったら, iPad に取り消しを伝える | M3-6 | 実装者 |
| M3-8 | 99 | relay: 繋がっていないとき. iPad が繋がっていないときは, 503 と Retry-After を返す. 応答が来ないときは timeout にする | M3-6 | 実装者 |
| M3-9 | 100 | relay: 配備の script. token の secret を設定して, 使う人の Cloudflare のアカウントへ配備する. 無料プランの範囲で動く設定にする | M3-6 | 実装者 |
| M3-10 | 101 | CI: relay の試験. relay の試験を回す job を足す | M0-12, M3-3 | 実装者 |
| M3-11 | 102 | 型と port: relay の接続. relay の設定の型, 接続の状態の型, 接続の port を書く | M2-9, M3-1 | 本体 |
| M3-12 | 103 | アプリ: relay への接続. WebSocket で relay に繋いで, token で認証する | M3-2, M3-11 | 実装者 |
| M3-13 | 104 | アプリ: 繋ぎ直し. 切れたら, 間隔を広げながら繋ぎ直す. 前面に戻ったときにも確かめる. 定期的に ping を送る | M3-12 | 実装者 |
| M3-14 | 105 | アプリ: 要求の受け渡し. relay から届いた要求を配信の入口へ渡して, 応答を小分けにして返す. 取り消しに従う | M2-28, M3-12 | 実装者 |
| M3-15 | 106 | relay の設定の保存. relay の URL と token を保存する use case を書く. token は Keychain に持つ | M2-14, M2-26, M3-11 | 実装者 |
| M3-16 | 107 | App: relay を登録する画面. URL と token を入力する画面と, 接続の状態の表示を書く. 組み立てに relay を足す | M2-49, M3-13, M3-14, M3-15 | 実装者 |
| M3-17 | 108 | 元のホスト名での経路の解決. relay が伝えた元のホスト名を, relay 経由の要求のときだけ信じて, サブドメインの経路を解決する | M2-18, M3-14 | 実装者 |
| M3-18 | 109 | 公開と管理の分離の試験. relay から届いた要求が, 管理 API のどの endpoint にも届かないことを, 試験で固定する | M2-33, M3-14 | 実装者 |
| M3-19 | 110 | ドメインの扱いを決める. PadServer の範囲外として, 対応しないことにした (決定項目84) | 無し | 所有者 |
| M3-20 | 111 | 手順書: ドメインの割り当て. 任意のドメインを Cloudflare の zone にして, relay に割り当てる一般的な手順を書く | M3-9 | 本体 |
| M3-21 | 112 | 通しの確認: 公開. 独自ドメインの URL を, tailnet の外から開く. 管理 API が外から届かないことも確かめる | M2-54, M3-9, M3-16, M3-17, M3-18, M3-20 | 実機 |

#### M4 Linux と Docker

guest の作り方 (M4-10 から M4-12) は, M1-1 から M1-5 の結果で形が変わります.

| ID | GitHub | Issue | 依存 | 担当 |
| --- | --- | --- | --- | --- |
| M4-1 | 113 | QEMU を取得する script. tctiSH と QEMU の fork を, commit を固定して取得する. 取得先は git に入れない | M0-1 | 実装者 |
| M4-2 | 114 | QEMU に当てる変更の管理. 検証で当てた変更 (無料の Apple ID で使えない権限を外す, ビルドの flag を足す) を patch にして, 取得の後に当てる | M0-19, M4-1 | 実装者 |
| M4-3 | 115 | QEMU を iPad 用にビルドする script. nix を使ってビルドする. 成果物は `build/` に置いて, git に入れない | M4-2 | 実装者 |
| M4-4 | 116 | QEMU を Mac 用にビルドする script. 開発と試験のために, 同じ QEMU を Mac で動かせるようにする | M4-2 | 実装者 |
| M4-5 | 117 | PadGuest の骨組み. QEMU を包む package を作る. QEMU の binary が無くても, ビルドと試験が通る形にする | M0-8 | 実装者 |
| M4-6 | 118 | 型と port: guest. guest の状態 (停止, 起動中, 準備完了, 失敗) の型と, guest を操作する port を書く | M2-9 | 本体 |
| M4-7 | 119 | QEMU の起動の引数. メモリ, CPU, kernel, initrd, disk, network の設定から, QEMU の引数を組み立てる | M4-5 | 実装者 |
| M4-8 | 120 | QEMU の読み込みと起動. QEMU を library として読み込んで, 専用の thread で起動する | M4-3, M4-4, M4-7 | 実装者 |
| M4-9 | 121 | QEMU の monitor の client. QEMU の monitor に繋いで, 状態の取得, 停止, port の転送の追加と削除を行う | M4-5 | 実装者 |
| M4-10 | 122 | guest の kernel を作る script. M1-2 で決まった構成で, kernel をビルドする | M0-1, M1-2 | 実装者 |
| M4-11 | 123 | guest の rootfs を作る script. Alpine Linux に Docker と compose を入れた rootfs と, M1-3 で決まった起動の処理を作る | M1-3, M1-4 | 実装者 |
| M4-12 | 124 | guest: Docker の自動起動. guest の起動時に Docker を立ち上げて, API の口を認証付きで開ける | M4-11 | 実装者 |
| M4-13 | 125 | guest の成果物の同梱. kernel と initrd を, アプリの resource に入れる | M0-9, M4-10, M4-11 | 実装者 |
| M4-14 | 126 | guest の disk. 初回に空の disk を作る. 置き場は, バックアップの対象から外す. 大きさは設定で決める | M4-5 | 実装者 |
| M4-15 | 127 | 端末ごとの鍵. Docker の API の認証に使う鍵を端末ごとに作って, Keychain に持つ. guest には起動のたびに渡す | M2-26, M4-8 | 実装者 |
| M4-16 | 128 | guest の起動と停止. guest を操作する port の実装を書く. Docker の API が応答するまで待つ. 時間内に応答しなければ, 失敗にする | M4-6, M4-8, M4-9, M4-12, M4-14 | 実装者 |
| M4-17 | 129 | Docker の client: 接続. 転送した port 経由で, 認証を付けて Docker の API に繋ぐ. 版の取得と ping を行う | M4-15 | 実装者 |
| M4-18 | 130 | Docker の client: container. container の一覧, 作成, 開始, 停止, 削除, 終了待ちを行う | M4-17 | 実装者 |
| M4-19 | 131 | Docker の client: image. image の一覧, 取得, 読み込み (stream), 削除を行う | M4-17 | 実装者 |
| M4-20 | 132 | Docker の client: ログ. container のログを追尾する. stdout と stderr を分ける | M4-17 | 実装者 |
| M4-21 | 133 | Docker の client: ファイルの送り込み. container の中へ, ファイルの束 (tar) を送る | M4-18 | 実装者 |
| M4-22 | 134 | port の転送. guest の port を, アプリの中の loopback の空いた port に出す. 外すこともできる | M4-6, M4-9 | 実装者 |
| M4-23 | 135 | App: guest の組み立て. 組み立てに guest を足して, アプリの起動時に guest を起動する. 失敗は dashboard に出す | M2-47, M4-16 | 実装者 |
| M4-24 | 136 | dashboard: Linux と Docker. guest の状態と, メモリと disk の使用を出す画面を書く | M2-50, M4-16 | 実装者 |
| M4-25 | 137 | 状態に guest を足す. 状態の API と `padctl status` に, guest と Docker の状態を足す | M2-37, M2-41, M4-16 | 実装者 |
| M4-26 | 138 | PadGuest の結合試験. Mac の QEMU で guest を起動して, nginx の container を動かし, 転送した port から 200 が返ることを試験にする | M4-4, M4-16, M4-18, M4-19, M4-22 | 実装者 |
| M4-27 | 139 | 通しの確認: Linux と Docker. 本番機でアプリを起動すると, Linux と Docker が立ち上がって, dashboard に準備完了と出る. 結合試験と同じ確認を, 本番機で行う | M4-13, M4-23, M4-24, M4-26 | 実機 |

#### M5 container の配備

M5-1 で配備の形を決めます. 下の分け方は, 今の見込み (compose の CLI を guest の中で動かす. 経路は上書き用の compose で出す) で書いています. M5-1 の結果で, 書き直すことがあります.

| ID | GitHub | Issue | 依存 | 担当 |
| --- | --- | --- | --- | --- |
| M5-1 | 140 | 配備の形を決める. compose の動かし方, 経路の出し方, 環境変数と secret の渡し方, image の送り方, 対応する compose の機能の範囲を文書にする | M1-5, M1-7 | 本体 |
| M5-2 | 141 | 型: compose のプロジェクト. 設定ファイルの compose の分 (compose のファイルの名前, 経路の service と port) と, image の参照の型を書く | M2-8, M5-1 | 本体 |
| M5-3 | 142 | port: compose と image. compose を動かす port と, image を扱う port を書く | M4-6, M5-2 | 本体 |
| M5-4 | 143 | 管理 API の仕様と通信の型: container. image の一覧と送信, compose の配備, service ごとの状態を, 仕様と型に足す | M2-13, M5-1 | 本体 |
| M5-5 | 144 | CLI: compose の設定の検証. 経路に書いた service が, compose のファイルにあるかを確かめる | M2-42, M5-2 | 実装者 |
| M5-6 | 145 | CLI: image の洗い出し. `docker compose config` を呼んで, 使う image と, ビルドが要る service を取り出す | M5-5 | 実装者 |
| M5-7 | 146 | CLI: image のビルドと書き出し. linux/amd64 でビルドして, 送れる形に書き出す | M5-6 | 実装者 |
| M5-8 | 147 | 管理 API: image の一覧. iPad にある image の ID の一覧を返す | M2-33, M4-19, M5-3, M5-4 | 実装者 |
| M5-9 | 148 | 管理 API: image の受け取り. 送られた本文を, streaming のまま Docker の読み込みに流す | M2-33, M4-19, M5-3, M5-4 | 実装者 |
| M5-10 | 149 | CLI: image の送信. iPad に無い image だけを送る. 進み具合を表示する | M2-40, M5-7, M5-8, M5-9 | 実装者 |
| M5-11 | 150 | 上書き用の compose の生成. 経路に書いた service の port を guest の port に出す, 上書き用の compose を作る. 元の compose のファイルは変えない | M5-2 | 実装者 |
| M5-12 | 151 | compose の実行. compose のファイルを guest に置いて, compose を動かす (起動, 停止, 削除, 状態の取得) | M4-18, M4-21, M5-3 | 実装者 |
| M5-13 | 152 | use case: container の配備. ファイルを置いて, 上書き用の compose を作り, 起動して, 経路を登録する. 起動に失敗したら, 前の構成に戻す | M2-16, M5-11, M5-12 | 実装者 |
| M5-14 | 153 | use case: container の開始, 停止, 状態. プロジェクトを始める, 止める. service ごとの状態を返す | M2-22, M5-12 | 実装者 |
| M5-15 | 154 | 管理 API: container の配備. compose のプロジェクトを配備する endpoint を書く | M2-33, M5-4, M5-13 | 実装者 |
| M5-16 | 155 | CLI: `padctl deploy` (compose). 設定の種類が compose のとき, image を送ってから配備を確定する | M5-10, M5-15 | 実装者 |
| M5-17 | 156 | container への転送. 配信の入口から, 転送した loopback の port へ, 要求を streaming のまま流す. 転送用の header を付ける | M2-28, M4-22 | 実装者 |
| M5-18 | 157 | 経路の登録と解除. 配備, 開始, 停止に合わせて, port の転送と経路の表を更新する | M5-13, M5-14, M5-17 | 実装者 |
| M5-19 | 158 | use case: 環境変数と secret. プロジェクトごとに, 値の設定, 名前の一覧, 削除を行う. 一覧は値を返さない | M2-10, M2-14 | 実装者 |
| M5-20 | 159 | 管理 API: 環境変数と secret. 設定, 一覧, 削除の endpoint を書く | M2-33, M5-4, M5-19 | 実装者 |
| M5-21 | 160 | CLI: `padctl secret`. `set`, `list`, `rm` を書く. 値は標準入力からも読める | M2-40, M5-20 | 実装者 |
| M5-22 | 161 | secret を container に渡す. 配備のときに, 環境変数のファイルを作って compose に渡す. guest の disk に残さない | M5-12, M5-19 | 実装者 |
| M5-23 | 162 | container のログ. container のログを, プロジェクトと service の名前を付けて, ログの bus に流す | M2-27, M4-20, M5-14 | 実装者 |
| M5-24 | 163 | CLI: `padctl logs` の絞り込み. プロジェクトと service で絞る | M2-45, M5-23 | 実装者 |
| M5-25 | 164 | 再起動への備え. 動かしていたプロジェクトを保存する. アプリの起動時に, guest の準備完了を待って戻す | M4-16, M5-14 | 実装者 |
| M5-26 | 165 | image の掃除. 配備の後, どのプロジェクトも使っていない image を消す | M4-19, M5-13 | 実装者 |
| M5-27 | 166 | dashboard: container. service ごとの状態を出す画面を書く | M2-50, M5-14 | 実装者 |
| M5-28 | 167 | 見本の compose. 通しの確認と手順書で使う, FastAPI と Postgres の構成を置く | M5-2 | 実装者 |
| M5-29 | 168 | 通しの確認: container. 見本の compose を配備して, 独自ドメインから開く. Postgres の port が, 外からも tailnet からも届かないことを確かめる. アプリを起動し直した後に, 元に戻ることも確かめる | M3-21, M4-27, M5-16, M5-18, M5-22, M5-23, M5-25, M5-28 | 実機 |

#### M6 Kikitoru

Kikitoru の側の変更は, Kikitoru のリポジトリの別の branch で行います. M6-1 の結果で, 書き直すことがあります.

| ID | GitHub | Issue | 依存 | 担当 |
| --- | --- | --- | --- | --- |
| M6-1 | 169 | Kikitoru の差分を調べる. Kikitoru を iPad で動かすために要る変更を調べて, 文書にする. image の platform, 環境変数, OAuth の戻り先, 音声の大きさ, frontend が呼ぶ API の向き先, 少しずつ出る応答を使うか, 外のサービスへの接続 | M1-9, M5-1 | 本体 |
| M6-2 | 170 | 大きい音声の upload の経路を決める. relay を通せる大きさ (M1-15 の結果) を見て, 音声を relay 経由で受けるか, 保存先へ直接送る形に変えるかを決める | M1-15, M6-1 | 所有者, 本体 |
| M6-3 | 171 | Kikitoru: backend 用の設定. Kikitoru のリポジトリの別の branch に, compose 用の `padserver.toml` を置く | M5-2, M6-1 | 本体 |
| M6-4 | 172 | Kikitoru: frontend 用の設定. API の向き先を独自ドメインにしたビルドの設定と, 静的サイト用の `padserver.toml` を置く | M6-1 | 本体 |
| M6-5 | 173 | upload の経路の実装. M6-2 で決めた形を実装する | M6-2 | 本体 |
| M6-6 | 174 | OAuth の戻り先の登録. Google の設定に, 独自ドメインの戻り先を足す | M3-21, M6-1 | 所有者 |
| M6-7 | 175 | secret の登録. Kikitoru が使う環境変数と secret を, `padctl secret set` で iPad に登録する | M5-21, M6-1 | 所有者 |
| M6-8 | 176 | frontend の配備. Kikitoru の frontend を, 静的サイトとして配備する | M3-21, M6-4 | 実機 |
| M6-9 | 177 | compose の配備. Postgres, migrate, backend, worker の構成を配備する | M5-29, M6-3, M6-7 | 実機 |
| M6-10 | 178 | 通しの確認: Kikitoru. 独自ドメインでログインして, 音声を1本送り, 議事録ができることを確かめる | M6-5, M6-6, M6-8, M6-9 | 実機 |
| M6-11 | 179 | 結果の記録. かかった時間, メモリ, つまずいた点を文書に足す | M6-10 | 本体 |

#### M7 仕上げ

| ID | GitHub | Issue | 依存 | 担当 |
| --- | --- | --- | --- | --- |
| M7-1 | 180 | 型と port: ファイル置き場. 置いたファイルの型と, ファイルと共有リンクを保存する port を書く | M2-5, M2-9 | 本体 |
| M7-2 | 181 | 管理 API の仕様と通信の型: ファイル置き場. ファイルの送信, 取得, 一覧, 削除と, 共有リンクの発行, 一覧, 失効を, 仕様と型に足す | M2-13 | 本体 |
| M7-3 | 182 | use case: ファイルの保存と取得. 名前を検証して保存する. 取得は stream で返す | M2-14, M7-1 | 実装者 |
| M7-4 | 183 | use case: ファイルの一覧と削除. 削除すると, そのファイルの共有リンクも失効する | M2-14, M7-1 | 実装者 |
| M7-5 | 184 | 保存: ファイル置き場. ファイルを置き場の下に持つ. 置き場の外に出る名前を拒む | M7-1 | 実装者 |
| M7-6 | 185 | 管理 API: ファイルの送信と取得. streaming で受け取り, streaming で返す | M2-33, M7-2, M7-3, M7-5 | 実装者 |
| M7-7 | 186 | 管理 API: ファイルの一覧と削除. 一覧と削除の endpoint を書く | M2-33, M7-2, M7-4, M7-5 | 実装者 |
| M7-8 | 187 | CLI: `padctl files`. `put`, `get`, `ls`, `rm` を書く | M2-40, M7-6, M7-7 | 実装者 |
| M7-9 | 188 | use case: 共有リンクの発行と失効. ファイルごとに, 推測できない URL を期限付きで発行する. 失効させられる | M2-14, M7-1 | 実装者 |
| M7-10 | 189 | 保存: 共有リンク. 共有リンクを保存する. URL の秘密の部分は, hash にして持つ | M7-1 | 実装者 |
| M7-11 | 190 | 配信: 共有リンクでの読み取り. 公開の経路で, リンクの URL からファイルを返す. 期限切れと失効は 404 にする. Range に対応する | M2-30, M7-9, M7-10 | 実装者 |
| M7-12 | 191 | 管理 API と CLI: 共有リンク. 発行, 一覧, 失効の endpoint と, `padctl share` を書く | M2-33, M2-40, M7-2, M7-9, M7-10 | 実装者 |
| M7-13 | 192 | 通しの確認: ファイル置き場. Mac からファイルを送って, 共有リンクを独自ドメインから開く. 失効させた後は開けないことを確かめる | M3-21, M7-8, M7-11, M7-12 | 実機 |
| M7-14 | 193 | README. 何ができるか, 構成の図, 必要なもの, 制約 (速さ, 前面への固定, 7日の署名) を書く | M5-29 | 本体 |
| M7-15 | 194 | ビルドの手順. nix の導入, QEMU と guest のビルド, Xcode の設定, iPad へ入れるまでを書く | M4-27 | 本体 |
| M7-16 | 195 | 使い方. `padctl` の全てのコマンドと, `padserver.toml` の書き方を書く | M5-29, M7-8, M7-12 | 本体 |
| M7-17 | 196 | 運用の手順書. アクセスガイド, 充電の上限, 入れ直し, 画面の明るさ, 発熱への備えを書く | M1-10, M1-18, M2-54 | 本体 |
| M7-18 | 197 | Tailscale のアクセス制御の手順. 管理の port へ繋げる端末を, 自分のものだけに絞る設定を書く | M2-54 | 本体 |
| M7-19 | 198 | 第三者のコードの一覧. QEMU (GPLv2) を各自がビルドして組み込むことと, 使っている第三者のコードとライセンスを書く | M4-3 | 本体 |
| M7-20 | 199 | まっさらな状態からのビルドの確認. 手順書だけを見て, 取得からビルド, iPad へ入れるまでを通す | M7-15 | 実機 |

### 6.4 Issue の進め方

1つの Issue は, 次の流れで進めます.

1. 本体が, Issue の内容を指示文にする. 触ってよいファイルと, 実行して貼るべきコマンドの出力を書く.
2. 実装者 (Codex のワーカー) が, その Issue 専用の worktree で実装する. commit はしない.
3. reviewer (Codex のワーカー) が1回レビューする. 終わりの確認のコマンドを, 自分で実行し直す.
4. 本体が, reviewer の指摘を直す. 所有者には聞かない (#82). 再レビューはしない. 指摘は, 選別せずに全件を PR に載せる.
5. 本体が, 検査を通して commit して push し, PR を作る. 所有者の確認は待たない (#74).
6. 所有者が merge する.

PR の細かい決まりは [pull-requests.md](pull-requests.md) に, コードの書き方は [implementation-rules.md](implementation-rules.md) にあります.

守ることは次の通りです.

- 同じファイルを触る Issue は, 同時に走らせません.
- 1つの Issue が, 3つ以上のファイルか2つ以上の責務にまたがるときは, 着手の前にさらに分けます.
- 実機での確認は, iPad が1台なので1本ずつ行います.
- Mac の CPU を長く使うビルド (QEMU, guest の kernel) は, 始める前に所有者に伝えます.
- commit のメッセージは `<type>: <説明>` の1行にします.

### 6.5 GitHub への置き方

Issue は, 次の形で GitHub に作ってあります. 済んだ検証は, Issue にしていません.

| 項目 | 形 |
| --- | --- |
| タイトル | 先頭に 6.3 の ID を付ける. 例は `[M2-15] use case: 配備の差分` |
| 本文 | やること, 触る場所の目安, 終わりの確認, 依存, 担当の5つを書く |
| 段階 | GitHub の milestone にする |
| 担当 | label にする. `owner:implementer`, `owner:agent`, `owner:device`, `owner:maintainer` の4つ |
| 依存 | 本文に, 依存する Issue の番号を書く |

## 7. 着手までに要るもの

所有者の操作が要るものです. その段階に入るときに, 手順を書きます.

- 最初の commit を main に push する (M0-1).
- Google の OAuth の設定に, 独自ドメインの戻り先を足す (M6-6).
- Kikitoru が使う secret を, iPad に登録する (M6-7).
- Tailscale のアクセス制御で, 管理のポートへ繋げる端末を自分のものだけに絞る (M7-18).

開発に使う Mac に要るものです.

| 道具 | 状態 | 使う場面 |
| --- | --- | --- |
| Xcode 26.6 と iOS 26.5 の platform | 導入済み | アプリのビルド |
| Xcode の Metal Toolchain | 導入済み (2026-10-09) | アプリのビルド |
| nix 2.35.2 | 導入済み (2026-10-09) | QEMU のビルド |
| guest の Linux をビルドする道具 | 未導入. M1-1 で選ぶ. kernel のビルドは重いので, Mac ではなく Linux の機械で行う案を先に検討する | guest の kernel と起動の処理の作り直し |
