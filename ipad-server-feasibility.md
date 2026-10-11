# iPad をローカルサーバーにできるか

調査日は 2026-10-08 です。実装はしていません。
Apple と各プロジェクトの公式文書、それに手元の Mac での実測をもとに判定しました。

この文書は、調査した時点の記録です。2026-10-09 の実機での検証で、Docker の container と FastAPI についての結論が変わりました。今の計画は [docs/roadmap.md](docs/roadmap.md) にあります。

## 結論

できます。ただし、条件が2つ付きます。

- サーバーのアプリを、画面の前面に出したままにする必要があります。iPad をサーバー専用にするなら、この条件は満たせます。
- 「任意のコード」は、アプリに組み込んだインタプリタで動く言語に限られます。Docker や Linux のプログラムを、そのまま動かすことはできません。

未確定の点が1つ残っています。Tailscale 経由で、iPad 上のアプリのポートに TCP が届くかどうかです。
Mac から iPad への ping は通りました。残りは、無料のアプリを使えばコードを書かずに確かめられます。

## 判定の一覧

| やりたいこと | 判定 | 条件や理由 |
| --- | --- | --- |
| 静的サイトとファイルの配信 | できる | アプリ内で HTTP サーバーを待ち受けられる |
| 自作の API | できる | アプリのコードとして書く分には制約が無い |
| JavaScript のコードを差し替えて動かす | 条件付きでできる | iOS 内蔵の JavaScriptCore で動く。Node.js の機能は無い |
| Node.js のプロジェクトを動かす | 条件付きでできる | nodejs-mobile を使う。Node 18 止まりで、子プロセスを使うものは動かない |
| Python のコードを動かす | 条件付きでできる | 公式の iOS 対応がある。C 拡張を含むパッケージは一部しか入らない |
| Rust や C のコードを動かす | 条件付きでできる | WebAssembly にして動かす。通信はアプリ側の橋渡しが要る |
| Docker、Linux コンテナ、任意のバイナリ | できない | iPadOS に仕組みが無い |
| Tailscale 経由のアクセス | 未確定 | ping は通った。アプリのポートへの TCP は未実測 |
| 24時間の稼働（アプリを前面に固定） | 条件付きでできる | 前面にある間は動く。24時間続いた実績は見つかっていない |
| 画面を消したまま、または他のアプリを使いながらの稼働 | できない | iPadOS が背景のアプリを止める |
| Mac からのアップロード | できる | HTTP で受け取る口を自作すれば済む |
| 自分の iPad への導入 | できる | 無料の Apple ID では、7日ごとに入れ直しが要る |
| App Store での公開 | 難しい | 外から入れたコードの実行が、審査の規則に触れる |
| 再起動後の自動起動 | 不明 | 自動で起動する仕組みは無い。ショートカットで補えるかは未確認 |

## 一番大きい制約は「前面に出している間しか動かない」こと

iPadOS は、背景に回ったアプリのコードを止めます。
止まっている間は着信を処理できず、待ち受けそのものが失われることもあります。
これは Apple の Technical Note に書かれている仕様で、自作しても外せません。

| 状態 | 動くか | 補足 |
| --- | --- | --- |
| アプリが前面にある | 動く | 自動ロックは、アプリの側から止められる |
| アプリが背景にある | 動かない | 音声や位置情報の機能で延命する手法はあるが、本来の用途から外れる |
| 画面がロックされている | 動かない | 背景と同じ扱いになる |

iPadOS 26 で増えた背景実行の仕組み（`BGContinuedProcessingTask`）も調べました。
これは利用者の操作で始める一時的な処理のためのもので、待ち受け続けるサーバーには使えません。

前面に固定する運用については、次のことが分かっています。

- アクセスガイド（iPadOS の機能で、1つのアプリに画面を固定するもの）は、端末だけで設定できます。
- 手元の iPad（`iPad17,3`）は、二次情報では iPad Pro 13インチ（M5）です。この世代は、充電を 80% で止める設定に対応しています。
- 前面に固定したまま24時間待ち受けが保たれた、という一次情報は見つかりませんでした。実機で一晩試す必要があります。

## 任意のコードはどこまで動くか

まず、iPadOS のアプリでは次のことができません。

| できないこと | 理由 |
| --- | --- |
| 別のプロセスを起動する | iOS のアプリは子プロセスを作れない |
| JIT（実行中に機械語を作って速くする仕組み） | 許可を持つのは Safari など Apple 自身のプロセスだけ |
| Docker、Linux コンテナ、仮想マシン | 仮想化の仕組みが macOS 専用で、iPadOS には無い |

1つ目の制約は影響が大きいです。
Vite や Next.js の開発サーバーのように、内部で別のプログラムを起動するものは動かない可能性が高いです。

動かせる手段は4つあります。どれも、インタプリタをアプリに組み込む形です。

| 手段 | 動かせるもの | 主な制約 | 保守の状況 |
| --- | --- | --- | --- |
| JavaScriptCore | 素の JavaScript | ES modules を読み込む公開 API が無い。`setTimeout` と `fetch` は自分で足す。暴走したコードを止める公開 API が無い | iPadOS の一部 |
| nodejs-mobile | Node.js のコードと、JavaScript だけで書かれた npm パッケージ | Node 18 止まり。アプリ1つにつき1インスタンス。ネイティブアドオンは別途ビルドが要る | 最後のリリースは 2024-10。止まってはいないが更新は遅い |
| CPython | Python のコードと、Python だけで書かれたパッケージ | `subprocess` と `multiprocessing` が使えない。C 拡張は iOS 用のビルドがあるものだけ | 公式対応だが、保証が最も弱い段階（Tier 3）。配布物は 2026-09 にも更新あり |
| WebAssembly | Rust や C を WebAssembly にしたもの | WASI の socket が未対応で、通信はアプリ側が橋渡しする | WasmKit は 2026-09 に更新あり。iOS は「動くはず」という扱い |

補足が3つあります。

- 速さについて。JIT が無い JavaScriptCore は、JIT がある場合の数分の1から10分の1ほどの速さだという報告があります。2019年から2020年の二次情報なので、今の iPad での数字は実機で測る必要があります。
- Python について。numpy には iOS 用のビルドがあります。pydantic-core には無いので、FastAPI をそのまま動かすのは難しいです。
- JavaScriptCore について。手元の iOS SDK で公開ヘッダを確かめました。スクリプトを評価する API は `evaluateScript` の2種類だけで、モジュール用の API は公開されていません。

## Tailscale 経由で届くか

| 確かめたこと | 結果 | 出どころ |
| --- | --- | --- |
| Mac から iPad への ping（3種類） | すべて応答があった（4ms から 99ms） | この Mac での実測 |
| TCP の待ち受けに、ローカルネットワークの許可が要るか | 要らない | Apple の TN3179 |
| VPN の経路は、ローカルネットワークの規制の対象か | 対象外 | Apple の TN3179 |
| Tailscale が切れたときに戻るか | 再起動やクラッシュの後も保つ設定が、自動で入る | Tailscale の公式文書 |
| iPad 上のアプリのポートへの TCP | 未実測 | 待ち受けるアプリがまだ無い |

状況証拠は「届く」方向に揃っています。ただし、Tailscale の公式文書には、iOS 上の別のアプリのポートへ届くと明記した箇所が見つかりませんでした。

気になる報告が1件あります。iPadOS 26.3.1 で、iPad から外へ出る TCP が Tailscale を通らない、という issue です。
今回の用途とは向きが逆で、報告者は1人だけ、開発元の返信も付いていません。

## 作らずに確かめる方法

iPad でサーバーを立てられるアプリは、既にいくつかあります。

| アプリ | できること | 背景での動作 | 価格 |
| --- | --- | --- | --- |
| a-Shell | Python の `http.server` などを動かせる | 前面にある間だけ | 無料 |
| iSH | Alpine Linux が動く。x86 を解釈実行するので遅い | 位置情報を使って延命する手段がある | 無料 |
| Code App | Node.js 18、Python、PHP の開発サーバー | 前面にある間だけ | 6.99 米ドル |
| Pythonista 3 | Python 3.10 | 背景では30秒ほどで止まりうる | 9.99 米ドル |
| WorldWideWeb | 静的ファイルの配信 | 不明 | 無料 |

ここから言えることは2つあります。

- どのアプリも「前面にある間だけ」という制約を抱えています。この制約は iPadOS によるもので、自作しても変わりません。
- 自作する意味は、常時稼働のための制御、Mac からのアップロード、API の差し替えを、1つのアプリにまとめられる点にあります。

未確定の1点は、a-Shell を使えば次の手順で確かめられます。

1. iPad に a-Shell を入れて、`python -m http.server 8080` を実行する。
2. Mac から `curl http://<iPad の tailnet の IP>:8080/` を実行する。
3. 応答が返れば、Tailscale 経由で iPad 上のアプリに TCP が届くと確定する。

そのまま一晩置けば、前面に固定した状態で待ち受けが保たれるかも分かります。

## 導入と公開

| 方法 | 判定 | 条件 |
| --- | --- | --- |
| 無料の Apple ID で自分の iPad に入れる | できる | 7日で失効して、入れ直しが要る。App ID は10個まで、1台に入れられるアプリは3つまで |
| Apple Developer Program に入る | できる | 年額 99 米ドル。期限は一般に1年とされるが、今回は Apple の文書で確かめられていない |
| App Store で公開する | 難しい | 審査の規則 2.5.2 が、機能を変えるコードを外から入れて実行することを禁じている |

24時間動かす用途では、7日ごとの入れ直しが運用の負担になります。

## まだ分からないこと

| 分からない点 | 確かめ方 |
| --- | --- |
| iPad 上のアプリのポートへ、Tailscale 経由で TCP が届くか | a-Shell で試す |
| 前面に固定した状態で、待ち受けが24時間保たれるか | a-Shell を一晩置いて、朝に Mac から叩く |
| 画面を点けたままの発熱と電池への影響 | 同じく一晩置いて確かめる |
| 再起動の後に、ショートカットでアプリを自動で開けるか | ショートカットのオートメーションを組んで試す |
| JIT が無い状態での実際の速さ | 実機で計測する |

## 出典

Apple の文書です。

- [TN2277: Networking and Multitasking](https://developer.apple.com/library/archive/technotes/tn2277/_index.html)（背景に回ったアプリと待ち受けの扱い）
- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)（待ち受けの許可と、VPN の扱い）
- [isIdleTimerDisabled](https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled)（自動ロックの停止）
- [BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)（iPadOS 26 の背景実行）
- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)（2.5.2 と 2.5.4）
- [メンバーシップの比較](https://developer.apple.com/support/compare-memberships/)（無料の Apple ID の制限）
- [Apple Platform Security](https://support.apple.com/guide/security/sec15bfe098e/web)（JIT が使えるプロセスの制限）
- [iPad の充電上限](https://support.apple.com/en-us/118418)（80% の設定に対応する機種）
- [アクセスガイド](https://support.apple.com/en-us/111795)

Tailscale の文書と issue です。

- [VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand)
- [tailscale/tailscale の issue 19496](https://github.com/tailscale/tailscale/issues/19496)（iPadOS 26.3.1 で、iPad から出る TCP が通らないという報告）

コードを動かす手段の文書です。

- [nodejs-mobile の FAQ](https://github.com/nodejs-mobile/nodejs-mobile/blob/main/doc_mobile/FAQ.md)
- [Python の iOS 対応（公式文書）](https://docs.python.org/3/using/ios.html)
- [PEP 11](https://peps.python.org/pep-0011/)（対応の段階）と [PEP 730](https://peps.python.org/pep-0730/)（iOS 対応）
- [pydantic の issue 12739](https://github.com/pydantic/pydantic/issues/12739)（iOS 用のビルドの要望）
- [WasmKit](https://github.com/swiftwasm/WasmKit)
- [FlyingFox](https://github.com/swhitty/FlyingFox)（Swift 製の HTTP サーバーライブラリ）

既存のアプリの文書です。

- [a-Shell の issue 418](https://github.com/holzschu/a-shell/issues/418)（背景では動かせないという作者の回答）
- [iSH の wiki](https://github.com/ish-app/ish/wiki/Running-in-background)（位置情報による延命）
- [Code App の issue 346](https://github.com/thebaselab/codeapp/issues/346)（背景では動かないという作者の回答）
- [Pythonista の FAQ](https://omz-software.com/pythonista/docs-3.4/py3/ios/faq.html)
- [WorldWideWeb](https://apps.apple.com/app/id1623006812)

手元で確かめたものは次の通りです。

- Mac から iPad への Tailscale の ping（2026-10-08）
- iOS SDK 26.5 の JavaScriptCore の公開ヘッダ
- iOS SDK 26.5 に、仮想化の framework が含まれないこと
