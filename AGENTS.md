# エージェント向けの規則

PadServer の PR を merge する役と, Codex との連絡の規則です.
PR の作り方と, 本文の書き方は, [docs/pull-requests.md](docs/pull-requests.md) にあります. この文書では繰り返しません.
この文書は AGENTS.md と CLAUDE.md の両方に同じ内容を置きます. 片方を直したら, もう片方も同じに直します.

## 1. 役割

| 役 | 誰か | すること |
| --- | --- | --- |
| 所有者 | repo の所有者 | 方針を決める. merge 係を指名する |
| merge 係 | 所有者が指名した Claude のセッション | CI の完了を待つ. Issue と実装を突き合わせる. 合えば merge する |
| 実装者 | Codex | Issue を実装して, PR を作る |

- merge するのは, 所有者か, 所有者が指名した merge 係だけです. 実装者は merge しません.
- merge 係は, 指名されたセッションの間だけ merge できます. 指名が無いセッションは merge しません.

## 2. merge の手順

merge 係は, PR ごとに次の順で進めます. 途中で1つでも満たさなければ, merge しません.

| 順 | すること | 確かめること |
| --- | --- | --- |
| 1 | `gh pr list --state open` で PR を一覧する | draft でなく, 衝突していない |
| 2 | `gh pr checks <番号>` で CI を見る | 全部の check が pass. 実行中なら, 終わるまで待つ |
| 3 | PR の `Closes #<番号>` から Issue を読む | 「やること」「触る場所」「終わりの確認」「依存」の4つを控える |
| 4 | Issue の依存が閉じているか見る | 依存の Issue がすべて closed |
| 5 | `docs/roadmap.md` の6章で, Issue の ID の行を読む | Issue の中身と, roadmap の説明が食い違わない |
| 6 | `gh pr diff <番号>` を読む | 3章の観点を満たす |
| 7 | PR の branch を worktree に取り出して, `swift test --package-path Packages/PadServerCore` を実行する | 失敗が0件. 本文に貼られた出力と一致する |
| 8 | `gh pr merge <番号> --merge` で merge する | `gh pr view <番号> --json state` が `MERGED` |
| 9 | worktree と手元の branch を消す | `git worktree list` に残らない |

- CI が通った PR から先に検証します. 実行中の PR を待つあいだに, 通った PR を進めます.
- 検証用の worktree は, scratchpad に作ります. repo の中には作りません.
- merge の方法は merge commit です. 本文と commit のメッセージは, GitHub が付けたままにします.
- 他の PR が先に入って衝突したら, 自分で直さずに, 所有者に知らせます.

## 3. Issue との突き合わせ

diff を読んで, 次の観点を1つずつ確かめます. 「テストが通る」だけでは足りません.

| 観点 | 確かめること |
| --- | --- |
| やること | Issue が求める型, protocol, 関数, 振る舞いが, すべて実装にある |
| 触る場所 | Issue が示すファイルに置かれている. 目安から外れる場合は, 理由が本文にある |
| 終わりの確認 | Issue に書かれた確認 (例: 経路の無い設定が拒まれる) を, 試験が実際に検証している |
| 範囲 | Issue に無い変更が混ざっていない. 足りない変更も無い. 要件にない機能, 検証, 設定, 依存, 試験の追加 (過剰な実装) も混ざっていない |
| 依存 | 依存先の型や port を, 作り直さずに使っている |
| README | `README.md` が更新され, 「何ができるか」と, 画像か動画か何かしらの証跡が付いている (`docs/pull-requests.md` の 6.5) |
| 境界値 | 空, 重複, 範囲外, 親ディレクトリの指定などを, 試験が押さえている |

- 実装が Issue の一部しか満たしていないときは, 合わないものとして扱います.
- Issue の範囲の外で気づいたことは, merge を止める理由にしません. merge 後の報告に書きます.
- 要件にない過剰な実装は, 見つけたら merge しません. 4章の手順で, 取り除くよう Codex に頼みます.
- 過剰な実装を残したいときは, 先に Codex に Issue の本文を編集させます. 要件を変えてから merge します. 実装を黙って受け入れません.
- 1つの Issue は, 1つの目的だけを持ちます. 編集で目的が2つ以上になるなら, 新しい Issue を作らせます (4章).

## 4. Issue に合わないとき

1. merge しません.
2. PR に review コメントを付けます. 何が Issue のどの記述に合わないかを, 次の形で書きます. 署名は付けません.

    ```text
    gh pr review <番号> --comment --body-file <本文のファイル>
    ```

3. 同じ内容を, Codex の terminal に送ります (5章). コメントの URL も添えます.
4. 実装を残したい場合は, 実装を直す代わりに, Codex に Issue の本文を編集させます. 編集後の Issue を読み直して, 実装が要件に合うことを確かめます.
   - 編集すると, Issue が1つの目的から外れる場合は, 編集しません. 残したい実装を, 新しい Issue として Codex に作らせます. 新しい Issue は, 別の PR で実装します.
   - 残したい実装が新しい Issue に移るので, 今の PR からは取り除きます.
5. Codex が直して push したら, CI の完了を待って, 2章を最初からやり直します.

- 自分の PR には `--request-changes` を使えないので, `--comment` を使います.
- 合わない PR を, merge 係が直しません. 直すのは Codex です.
- 同じ指摘が2回続いたら, 所有者に知らせます.

## 5. Codex との連絡

連絡は, Orca の terminal を通して行います. 相手の terminal の handle は変わるので, 毎回引き直します.

```text
orca terminal list --json
```

- Codex の terminal は, `agentIdentity` が `codex` で, `worktreePath` が repo の main の worktree にあるものです.
- Claude の terminal は, `agentIdentity` が `claude` で, `worktreePath` が同じものです.
- worktree ごとに立った Codex の terminal (`padserver-issue-<番号>`) は, その Issue の作業だけを持ちます. 全体の連絡は, main の worktree の terminal に送ります.

### 5.1 merge 係から Codex へ

次の場合に, main の Codex の terminal へ送ります.

| 場面 | 送る内容 |
| --- | --- |
| PR を merge した | PR の番号と, 閉じた Issue の番号 |
| Issue に合わない PR を見つけた | PR の番号, 合わない点, review コメントの URL |
| 衝突や CI の失敗で止めた | PR の番号と, 止めた理由 |

### 5.2 Codex から merge 係へ

Codex は, PR を作ったら, 作った直後に merge 係の terminal へ送ります. 内容は PR の番号と, 閉じる Issue の番号です.

```text
orca terminal send --terminal <merge 係の handle> --text "PR #<番号> を作りました (Closes #<Issue の番号>)"
```

- 送ったあとに, 下書きが残っていないか `orca terminal read --terminal <handle> --screen` で確かめます.
- 送る内容は, 長くしません. 詳しい中身は, PR の本文に書いてあります.

### 5.3 送り方

`orca terminal send --terminal <handle> --text "<本文>"` で, 下書きを入れます. そのあとに Alt+Enter (`$'\x1b\r'`) を送って, すぐに入力します.

- 相手が作業中でも, queue に入れずに, すぐ入力します. queue に入れた連絡は, 読まれるまでに時間がかかるからです.
- Tab で queue に入れません.
- この環境では Enter が改行なので, `--enter` では送信されません.
- 送ったあとは, 画面を読んで, 下書きが残っていないか確かめます. 残っていたら, Alt+Enter をもう一度送ります.
- 相手の作業が止まったときは, 止まった作業を続けるよう, 連絡の本文に書きます.
- 返信が要らない連絡には, 本文の末尾に「返信は要りません」と書きます.

## 6. してはいけないこと

- CI が実行中や失敗のままの PR を merge しません.
- Issue と実装を突き合わせずに merge しません.
- README が更新されていない PR, または証跡が付いていない PR を merge しません.
- PR の本文とコメントに, Claude や Codex の署名を付けません. `Co-Authored-By` も付けません.
- main へ直接 push しません.
- merge 係が, 他人の PR の中身を書き換えません.
