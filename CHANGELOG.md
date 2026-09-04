# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Added

- `TODO_TIMING=1` を設定すると、`run` / `api` サブコマンドの実行後に実行時間の内訳を stderr へ1行出力するようになった（Issue #455）。既定（未設定時）は挙動・出力とも一切変化しない（オプトイン方式）。出力例: `[timing] total 842ms (github 780ms / parse 12ms)`。`github` は GitHub API 呼び出しに実際に費やされた壁時計時間で、並行呼び出し（`Promise.all` を使う `dashboard`/`today`/`report` 等）は重複区間を1回分に統合して数えるため、値が実時間の合計より水増しされたり `parse`（`total - github`）が負値になったりしない。診断出力のため他の固定英語出力（`api` サブコマンドの JSON・`Usage:` 文字列）と同様、言語設定に関わらず常に英語固定とする。実装上の注意点として、多くのバリデーションエラーは Promise チェーンではなく `process.exit()` を直接呼んで即終了するため、`.finally()` ではこれらの終了経路を捕捉できない（実機確認）。`process.on('exit', ...)` を使うことで、正常終了・エラー終了（`.catch()` 経由）・`process.exit()` 直接呼び出しのいずれの経路でも1回だけ出力されるようにしている。GitHub API 呼び出しの計測は Octokit インスタンスの各メソッドを `Proxy` の `apply` トラップで包む方式で行う（`.endpoint`/`.defaults` という Octokit 内部が参照する関数プロパティを保持するため。単純な関数再代入によるラップはこれらを失わせ、`TODO_TIMING=1` を付けた途端に実 GitHub API 呼び出しそのものが機能停止する不具合があったため、この方式に修正した。詳細は DEVELOPMENT.md 参照）
- `routine` ラベルとチクラーファイル（tickler file）の説明を `todo.md` / `todo-manual.md` / `README.md` / `README.ja.md` に新設した（Issue #1883）。いずれも実装は存在するのに文書での説明が実質ゼロだった。(1) `routine` は `GTD_LABELS` で `next` / `waiting` / `someday` / `reference` と同格の一級カテゴリとして定義され、`today` / `dashboard` の専用表示区分・`list` の遅延マーカー・ステータスラインのカウントという専用ロジックを持つが、`todo.md` の frontmatter に列挙されるのみで本文の説明が4文書とも存在しなかった。`todo-manual.md` の「引き出しの種類」を5つから6つへ構成変更し、「6. 応用機能」に `today` / `dashboard` の3段階表示（今日のルーティン / ルーティン未実施 / 要確認）と判定基準を説明する節を新設した。あわせて `README.md` / `README.ja.md` の Features が `routine` を欠いたまま「6 categories」と件数を断言していた誤りを 7 に訂正した。(2) チクラーファイルは `--activate` / `--before` / `--depends-on` / `--resume-condition` / `review-someday` が個別コマンドとしてバラバラに並ぶだけで、「これらが1つの GTD プラクティスの実装であり、予約の実行役が `promote` である」ことに文書から到達できなかった。`todo-manual.md` に統合説明の節を新設し、`todo.md` には要点のみを置いた。個別の未掲載オプション（`tag rename` / `--before` / `--depends-on` / `--resume-condition` / `activate` 簡略形 / `promote` 単体行）も各文書へ補った

- 個別フラグ6件（`--actual` / `--due-offset` / `--group` / `--label` / `--no-due` / `--no-estimate`）の説明を、掲載が漏れていた文書へ補った（Issue #1884）。実装が持つフラグ20件を `todo.md` / `todo-manual.md` / `README.md` / `README.ja.md` の4文書と突き合わせ、欠落していた17箇所を埋めたもの。`--label`（`add` に任意の汎用ラベルを付与する。存在しなければ色 `EDEDED` で自動作成される）は4文書とも未掲載だった。あわせて実装から確認した2点を注記した: `--label` で作成したラベルは `/todo label list` に現れない（`label list` は `@` で始まるコンテキストラベルのみを対象とするため。確認は `/todo show` または GitHub 側のラベル一覧で行う）、`--no-due` は `--group` と同時指定した場合に優先される
- `#tag`（ハッシュタグ形式のラベル）の説明を4文書に新設した（Issue #1884）。`@ctx` が「どこで・何があるときにできるか」という場所・状況の軸であるのに対し、`#tag` は案件や人物など自由な分類軸を表すもう一系統のラベルで、`add` 時のトークン指定・`tag` / `untag`・`list #タグ名` でのフィルタの4経路から使える。実装は以前から存在し `help` にも `@ctx/#tag` と出ていたが、4文書での言及は0件だった。タグ名を数字のみにできない制約（`#42` のような Issue 番号参照との衝突を避けるため）と、`@` も `#` も付けないトークンが後方互換でコンテキスト扱いになる挙動もあわせて記載した

### Changed

- `/todo comment` の未知フラグエラーが、日本語モードで日本語表示になった（Issue #1921）。`comment` は #1919 の修正時に `Error: unknown flag: --xxx` を英語ハードコードで出しており、日本語モードでも英語のまま表示されていた。他コマンドと文言を揃えるため `add` と同じメッセージ定義（`エラー: 不明なフラグです: --xxx`）へ寄せ、あわせて「本文全体を1つの引数としてクォートしてください」というヒント行を1行追加した。**ユーザーから見える出力が変わる唯一の後方非互換な変更**のため `Fixed` ではなくここに記載する。英語モード（`LANG_ENV=en`）の本文は従来と完全に一致する（ヒント行が1行増えるのみ）。エラーになる条件・exit code・API を呼ばないことは変わらない
- `listSubIssues()` を `fetchAllOpen()` と同型のページング実装に変更した（Issue #1881）。**これは現時点で挙動の変わらない防御的な変更である**。GitHub の sub-issue は現行仕様で「親1つにつき最大100件」（公式ドキュメント "Adding sub-issues" に明記。2026-08-23 確認）のため、従来の `per_page: 100` の単発リクエストでも常に全件を取得できており、欠落は発生していなかった。この上限が将来引き上げられた場合に黙って欠落しないよう、あらかじめページングに寄せておくもの。無限ループ防止用の上限として `MAX_SUB_ISSUES_LIMIT`（500件）を新設し、到達時は `warn.sub_issue_list_limit` で警告する（ja/en）。この結果は4箇所が使うため、仮に欠落するとどれも静かに誤動作する: (1) `addSubIssue()` の422判別（既登録の子を「未登録」と誤判定し `error` に計上）、(2) `/todo list project <N>`（子一覧から欠落）、(3) `/todo unlink`（食い違いと誤判定し `--force` を要求）、(4) `weekly-project-audit`（棚卸しの走査対象から漏れる）。取得失敗時に `[]` を返す既存仕様（成功と失敗を区別しない）は本Issueのスコープ外として維持した

### Fixed

- `/todo comment` が `--body-file` / `--body` に対応しておらず、しかも未知の `--` フラグを黙って本文として投稿していた不具合を修正した（Issue #1919）。従来の `runComment()` は `tokens[1]` だけを本文として読み `tokens[2]` 以降を無条件に捨てていたため、`comment <#> --body-file <path>` を実行すると「--body-file」という**文字列そのもの**が本文として投稿され、`<path>` の指す実ファイルの中身は黙って失われていた（エラーなし・exit 0）。実際にこの経路で誤ったコメントが投稿され、`gh api -X PATCH` での事後修復が必要になった。修正後は `runAdd()` と同じ `--body`（文字列）/ `--body-file`（ファイルパス、優先）に対応しつつ、`--body`/`--body-file` 以外の `--` で始まる引数（既知フラグの値欠落を含む）は本文へ連結せずエラー終了するようにした。既存の位置引数形式（`comment <#> <テキスト>`）は後方互換のためそのまま動作し、単一ハイフンで始まる本文（例: `"- 箇条書き"`）は誤ってフラグ扱いしない。`help.comment` を ja/en とも更新した。回帰テストとして `tests/run-tests-write.sh` に §W26 を新設し、修正前コードでは body が `"--body-file"` というリテラル文字列になることを直接反証する形で検証している。**追補（同日）**: 初版は `--` で始まるトークンを一律未知フラグ扱いにしたため、Markdown水平線（`"--- 区切り線 ---"`）や「`--body` を説明する文章」のような正当な本文まで拒否する副作用があった（実測: exit 1）。判定を `^--[A-Za-z][A-Za-z0-9-]*$`（フラグの字面＝1語・英字始まりのみ）に絞り込み、`--boddy-file` のようなタイポは引き続き検出しつつ、`--` の直後がハイフンや空白・非英字のトークンは本文として扱うよう修正した。位置引数とフラグを同時指定した場合はフラグが優先され位置引数は無視される仕様も回帰テストで固定した。全1445件PASS（書き込み系539/539）
- `/todo add`（および GTD ラベル省略記法・日本語タイトルの暗黙 add 経路）が、引数パーサの解釈できなかった `--` 始まりのトークンを黙ってタイトルへ連結していた不具合を修正した（Issue #1921）。`add next "設計書を書く" --boddy-file /tmp/body.txt` のようにフラグ名をタイプミスすると、エラーも警告も出ないまま「設計書を書く --boddy-file /tmp/body.txt」というタイトル・本文空の Issue が exit 0 で作成されていた（実測で再現確認）。`comment` で修正した #1919 とまったく同じ構造の問題で、値を書き忘れた既知フラグ（末尾の `--due` 等。引数パーサが「次のトークンが存在する」条件を満たさず読み飛ばすもの）や、`--p4` のように似ているが存在しないフラグでも同じ経路をたどる。修正後は、未知のフラグを検出した時点で Usage 行・エラー本文・ヒント行を stderr へ出して終了し、GitHub API を1回も呼ばない（コンテキストラベルの作成より前に検査するため、`@ctx` を併用しても副作用はゼロ）。エラーメッセージは ja/en 両対応で、`--dry-run` のような語をタイトルに含めたい場合の脱出口（タイトル全体を1つの引数としてクォートする）を案内する。判定は #1919 で確定した「フラグの字面＝`--` + 英字始まり + 英数字/ハイフンのみで構成される1語」の線引きをそのまま使うため、Markdown 水平線（`--- 区切り線 ---`）・「`--body` を説明する文章」・単一ハイフン始まり・全角ダッシュ始まりのタイトルは従来どおり通る。実装では判定を `findUnknownFlag(tokens, allowedFlags)` として共通化し、`comment` 側の同一実装もこれを参照するよう統一した（挙動・出力は不変）。回帰テストとして、判定器の単体テスト `tests/run-tests.sh` §51（20アサーション。入力文字パターン・境界値・500要素のパフォーマンス）と、`add` の振る舞いテスト `tests/run-tests-write.sh` §W27（71アサーション。修正前コードでは汚染タイトルでの Issue 作成が起きることを直接反証する形式）を新設した。追加したガードを一時的に外すと §W27 の異常系が確実に FAIL することも実測で確認済み。全1536件PASS（書き込み系610/610）。GitHub への実書き込みは行わず、スタブ経由のみで検証した
- 上記と同じ「引数を黙って捨てる／自由記述へ混入させる」問題が、`add` 以外の13コマンドにも残っていたのを一括で塞いだ（Issue #1921）。症状は3種類ある。**(a) 指定した値が黙って捨てられる**: `due 42 2026-09-10 --note "理由"` の `--note` は効かず、エラーも警告も出ない（`recur` / `link` / `priority` / `bulk move` / `bulk priority` / `label delete` / `label rename` / `template list` / `template show` / `template save from` / `template delete` も同じ構造で、固定位置の引数だけを読んで残りを捨てていた）。**(b) フィルタが黙って無視される**: `list next --no-duee` はタイプミスに気づけないまま全件を表示していた（`done` / `move` / `edit` / `label add` / `template save` / `bulk done` も同様に、引数パーサが解釈できなかったフラグを捨てていた）。**(c) 自由記述へ混入する**: `template use daily --boddy-file /tmp/x` はタイトル「--boddy-file /tmp/x」のゴミ Issue を exit 0 で作り（`add` を経由せず自前で Issue を作るため #1921 の初回修正の網にかかっていなかった）、`rename 42 --boddy-file /tmp/x` は**既存タイトルをフラグ名で上書きして消し**、`desc 42 --boddy-file /tmp/x` は説明欄にフラグ名を追記していた。修正後はいずれも Usage 行・エラー本文・ヒント行を stderr へ出して `exit 1` し、GitHub API を1回も呼ばない（ラベル作成・Issue 取得・一覧取得のいずれにも到達しない）。ヒント行はコマンドの性質で3種類に出し分ける（タイトルを持つ `add` / `rename` / `template use`、本文を持つ `comment` / `desc`、自由記述を持たないその他）。**サブコマンドの「名前の位置」も対象**: `label add --boddy-file` は `@--boddy-file` というゴミラベルを GitHub 上に作り（手動削除が必要）、`label rename --foo new` / `label rename old --bar` は実在ラベルの削除とゴミラベルの作成を同時に行い、`template save --foo next` はローカルの `todo-templates.json` に `--foo` エントリを書き込んでいた。名前を検証する既存バリデータはシェル注入対策の文字集合しか見ておらず、ハイフンを禁止していないためフラグ字面がそのまま通っていた。`label` の `add` / `delete` / `rename`（old / new の両方）と `template` の `show` / `save` / `use` / `delete` について、名前の位置にフラグ字面が来た場合もエラー終了するようにした。**`tag rename` も同じ扱いにした**: `tag rename` は `label rename` とまったく同じ共通関数（`renameCtxLabel`）を呼ぶ第2の入口で、実害も同一（`tag rename old --bar` が `@--bar` を作ったうえで実在の `@old` を削除する）。ガードは呼び出し元ではなく共通関数の冒頭に置き、両経路を1箇所で塞いでいる。**互換性のために意図的に残した3点**: (1) `list` の `--group` / `--no-due` / `--no-estimate` は `list` が自前で解釈するフラグとして許可リストで通す（`--json` は引数パーサより前に除去されるため他フラグと併用でき、`list next --json --group` のような複合形も従来どおり通る）、(2) フラグではない位置引数の余剰（`due 42 今週 金曜` / `priority 42 p1 p2` 等）は従来どおり通す（本件の主題はフラグの取りこぼしであり、位置引数の余剰は別軸のため）、(3) `bulk tag` / `bulk untag` の `-` 始まりトークンは既存の「オプション指定に見えます」エラーのまま変更しない。判定は #1919 で確定した「フラグの字面＝`--` + 英字始まり + 英数字/ハイフンのみで構成される1語」をそのまま使うため、Markdown 水平線や日本語を含む自由記述は誤検知しない。回帰テストとして `tests/run-tests-write.sh` に §W28（200アサーション）を新設し、`tests/run-tests.sh` §51 に許可リストの完全一致判定を固定する2件を追加した。`list --group` を実際に実行する end-to-end テストは本変更が最初となる。追加した全ガードを一時的に無効化して実行し、異常系ケース全件が確実に FAIL することも実測で確認済み（この過程で「ガードを外しても PASS したままのアサーション」を1件見つけて書き換えた）。全1747件PASS（書き込み系819/819）。GitHub への実書き込みは行わず、スタブ経由のみで検証した。あわせて、`label` / `bulk` に残っていた旧 `Usage: run ...` 形式の4本を各コマンドの Usage 文言へ差し替え、同じコマンドから2種類の Usage が出る状態を解消した。`todo.md` と `/todo help` の注記は、**未知フラグをエラーにするコマンドを列挙する**形に改めた（対象外のコマンドと、「別のコマンドでは有効だがそのコマンドが読まないフラグは今も黙って捨てられる」ことを明記）。同時に、実装済みで表に載っていなかった `list` の `--json` と `add` / `edit` / `template save` の `--p1` / `--p2` / `--p3` を引数欄へ追記した
- `/todo unlink` が sub-issue 一覧の取得に失敗したとき、`--force` 指定時に body の `project: #N` 行だけを削除してしまう経路を塞いだ（Issue #1885）。`listSubIssues()` は GET 失敗を catch して `[]` を返す仕様のため、`runUnlink()` から見ると「取得に失敗した」と「本当に子0件（=未登録）」が区別できなかった。`--force` 指定時はこれを「GitHub 側に解除すべき関係が元々ない」と解釈して `removeSubIssue()` を呼ばずに body を更新するため、実際には親子関係が残っているのに body 上は解除済みになる。#1880 で修正したデータ喪失と同型の結果であり、発火にはネットワークエラー等での GET 失敗と `--force` の同時成立が必要なため確率は低いが、経路としては開いていた。`listSubIssues()` に `{ throwOnError: true }` オプションを追加し（省略時は従来どおり `[]` を返す）、`runUnlink()` だけがこれを使って GET 失敗を例外として捕捉、`--force` の有無にかかわらず body を一切更新せずエラー終了するようにした。他の3呼び出し元（`addSubIssue()` の422判別 / `/todo list project <N>` / `weekly-project-audit`）は「失敗時は空扱い」で実害がない設計のため、シグネチャ・呼び出し形とも変更していない。回帰テストとして `tests/run-tests-write.sh` に §W24 を新設し、GET 失敗 + `--force` で `issues.update` が呼ばれないことを直接アサートする（GET 成功・子0件・`--force` の対照ケースが従来どおり body のみ解除されることも併せて確認する）
- `help()` に、実装済みなのに出力されていなかった3件を追加した（Issue #1906）。(1) `help.routine_hint`（`routine` ラベルは `--recur` と併用する旨のヒント）はロケール定義が ja/en 両方に存在するのに `help()` から一度も呼ばれておらず、出力されていなかった。v2.9.0 で修正した `--depends-on` の配線漏れとまったく同型。(2) `/todo activate <#> <date>`（`/todo edit <#> --activate <date>` の簡略形）は dispatcher に実体があるのにコマンド行がなかった。`help` の出力中に `activate` という文字列は複数回現れるが、いずれも `--activate` オプションや説明文の一部で、コマンド形としては一度も現れていなかった。(3) `/todo add <title>` は、GTD ラベルを伴わない英字始まりのタイトルにおいて誤入力ガードを回避する唯一の明示形であるにもかかわらず、コマンド形で掲載されていなかった（`add` の文字列自体は `/todo label list/add/delete` の行に現れるため、単純な文字列検索では欠落として検出されない）
- `tests/run-tests.sh` に、`runMain` の dispatcher にあるコマンドがすべて `help()` の出力にコマンド形で現れることを日英両モードで検証するテストを新設した（Issue #1884）。従来の同期テストは dispatcher とタイトル誤爆ガードの2点しか対象にしておらず、`help()` はどの自動テストからも検証されていなかった。v2.9.0 で修正した「7コマンドが `help` に載っていない」はその穴から出たもの。実装はロケール定義を解析せず、実際にレンダリングされた `help` 出力に対して `/todo <コマンド名>` というコマンド形の有無を確認する（上記 (2) のように、ロケールキーは存在するのにコマンド形では現れないケースを部分一致では検知できないため）。掲載を省く対象は `close` と `dash` の2件のみで、いずれも `done` / `dashboard` へ委譲する別名であることを dispatcher の実装で確認している
- `tests/run-tests.sh` の §11（テンプレートファイル操作）で稀に template 系12件がまとめて FAIL する事象（Issue #1882）の根本原因を特定し修正した。原因は macOS(BSD) の `mktemp` が「`XXXXXX` の後に拡張子など固定文字列が続くテンプレートでは `XXXXXX` を展開せずリテラルな固定ファイル名を返す」挙動で、`TEMP_TFILE=$(mktemp /tmp/todo-test-templates-XXXXXX.json)` は実行のたびに同じ固定パスを返していた。BSD の `mktemp` は `O_EXCL` でファイルを作るため、同名が既に存在すると `mkstemp failed on ...: File exists` で失敗する。したがって同一テストが並行実行されると、2つ目のプロセスの `mktemp` が失敗して `TEMP_TFILE` が空文字列になり、`set -uo pipefail`（`-e` なし）のため処理が続行して、`TEMP_TFILE` を共有する §11 の12件がまとめて FAIL する。単独実行では起きないため「再実行では再現しない」という形でしか症状が見えていなかった。修正前のコードを2部同時に走らせる再現実験で3回中3回この経路を観測し（`mkstemp failed ... File exists` を実際に確認）、修正後の同実験では `mkstemp failed` も template 系 FAIL も0件になることを確認した。裏付けとして、固定名の残骸ファイル `/tmp/todo-test-templates-en-XXXXXX.json` が #1882 発見当日（2026-08-23）のタイムスタンプで実在していた。修正は `tests/run-tests.sh`（16箇所）・`tests/run-tests-write.sh`（89箇所）・`tests/gh-tests.sh`（1箇所）の計106箇所で `mktemp` テンプレートの拡張子を落とし `XXXXXX` を末尾に置く形へ統一した（例: `.../XXXXXX.json)` → `.../XXXXXX)`）。既に末尾が `XXXXXX` で正しくランダム化されていた `mktemp -d` の2箇所（`run-tests-write.sh` の `W3_FAKE_HOME` / `run-tests.sh` の `FAKE_HOME`）は変更対象外。直前の対応で追加した `mktemp` 直後の存在検証・§11 開始時の再検証・FAIL 時の診断フックは、ディスク容量不足など別要因による `mktemp` 失敗への防御として維持した（今回の再現実験でも当該検証が実際に発火し、12件の FAIL ではなく原因が一目で分かる形で停止した）。あわせて、対になる cleanup が無く実行のたび `/tmp` に残り続けていた `TEMP_TFILE_EN` の後始末も追加した。修正後、`run-tests.sh` / `run-tests-write.sh` とも全件 PASS（1374/1374、うち書き込み系480/480）を確認した

---

## [v2.9.0] - 2026-08-23

### Changed

- タイトルに丸括弧 `()` 等の記号が使えない制約を緩和（Issue #1825）。従来、Issue タイトル（`/todo add` / `/todo rename` / `/todo promote-project --outcome`）はシェル注入対策の `validateName`（`; $ \` ( ) " ' \ | & > < { }` を禁止）を経由していたが、タイトルは Octokit 経由の HTTP API にのみ渡りシェル展開を一切経由しないため、この禁止は過剰だった（grep実測: `todo-engine.js` 内で `execSync`/`spawnSync`/`execFileSync`/`child_process` は0ヒット）。タイトル専用の `validateTitle` を新設し、改行等の制御文字（Unicode `Cc` カテゴリ）のみを禁止するよう緩和した。テンプレート名・ビュー名（`process.env.TNAME_ENV`/`VNAME_ENV` 経由でシェル変数として扱われうる）は引き続き `validateName` を使用し、シェル危険文字を禁止し続ける
- `todo.sh` の `--remind`（macOS Reminders 連携）で、AppleScript ヒアドキュメントへ埋め込む前にタイトルをエスケープするよう変更（Issue #1825）。上記のタイトル許可緩和により `"` や `\` を含むタイトルが通るようになったため、エスケープなしでは AppleScript の文字列リテラルが破損する。Reminders 登録完了メッセージ（stdout）にはエスケープ前の元タイトルを表示する

### Fixed

- `help()` に実装済みだが出力されていなかった7コマンド（`promote-project` / `unlink` / `review-someday` / `weekly-project-audit` / `migrate` / `comment` / `api`）を追加し、`--depends-on` オプション（ロケール文字列は定義済みだが `help()` から一度も呼ばれていなかった配線漏れ）も表示されるようにした（Issue #1655）。あわせて、`runMain` の switch に実体が存在しない `/todo review` / `/todo daily-review` / `/todo weekly-review` が `help()` と `docs/todo-manual.md`・`README.md`・`README.ja.md` に「動く現役コマンド」として案内されていた不整合を修正した。これら3つは実行すると `error.unknown_command` で `exit 1` になる（`todo.md` 自身は既に移行注記を持っていたが、他の文書・`help()` が追従していなかった）。`help()` からは削除し、代わりに正しい移行先（review → `/gtd-collect`、daily-review → `/daily-review`、weekly-review → `/weekly-review`）への誘導メッセージを新設の「統合済みコマンド」セクションに追加した。`--body`/`--body-file`（プロジェクトルート `CLAUDE.md` のグローバルルールが使用を義務付けているが4文書とも未掲載だった）と `schema`/`show`（4文書とも未掲載だった）も `todo.md`/`README.md`/`README.ja.md`/`docs/todo-manual.md` に追記した
- `runPriority`/`runEdit`（`priority`変更）と `runDone`（recur再作成）の2箇所で、状態整合性の順序が「破壊 → 検証/確認」になっており、途中で失敗すると中途半端な状態のまま終了する問題を修正（Issue #1652）。(1) `runPriority`/`runEdit` は、旧priorityラベルを `removeLabel` で削除した「後」に `validatePriority()` を呼んでいたため、`p9` のような不正値を指定すると旧ラベルだけが削除された状態でエラー終了していた。`validatePriority()` をラベル削除より前に呼ぶ validate-before-mutate の順序へ統一した（`runBulk` の `priority` サブコマンドは元から正しい順序だったため対象外）。(2) `runDone`（および `runBulk done`・`api done-issue` の計3呼び出し経路）は、Issueを `close` した「後」に `postDoneProcessing()` 内で次周期のIssueを `create` していたため、`create` が失敗すると繰り返しタスクの次周期が永久に失われていた。`postDoneProcessing()` から次周期作成部分を `createRecurIssue()` として分離し、`close` より前に呼ぶ create-before-close の順序へ変更した。`postDoneProcessing()` に残した depends_on昇格・project昇格ヒントは意図的に `close` の「後」のまま維持している（`close` 前に呼ぶと、`fetchAllOpen()` が完了直後でまだ `open` のままの自分自身を次タスク候補に混入させてしまうため）。`create` 成功後に `close` が失敗した場合、同じタスクのオープンなIssueが2件（元Issueと新規作成Issue）残る可能性があるため、エラーメッセージに作成済みの新Issue番号を含めるようにした（`error.close_failed_after_recur`、ja/en両対応）
- `migrate sub-issue` が1件も sub-issue を登録できないのに、サマリーは `0件登録 / N件スキップ / 0件エラー` と正常に見える問題を修正（Issue #1879）。2つの欠陥が重なっていた。(1) `fetchAllOpen()` が返す Issue オブジェクトに `id`（database ID）が含まれておらず、`runMigrateSubIssue` から `addSubIssue(..., issue.id)` を呼ぶと `sub_issue_id: undefined` で POST され、GitHub が 422 を返していた（同じ `addSubIssue` を呼ぶ `link` コマンドが正しく動いていたのは、`fetchAndParseIssue()` 経由で `id` を持っていたため）。(2) `addSubIssue()` が 422 を無条件に「既登録」と解釈して `skipped` を返していた。GitHub の 422 は汎用の Unprocessable Entity で、「既に同じ親へ登録済み」のほか「子が別の親に登録済み」「`sub_issue_id` が不正」でも返るため、実際の失敗がスキップ件数に紛れて `0件エラー` になっていた。(1) は `fetchAllOpen()` の map に `id` を追加して修正した（`issueToJsonObj()` は明示ホワイトリストでフィールドを組み立てるため、`list --json` 等の出力には現れない）。(2) は 422 を受けたときに `listSubIssues()` で親の sub-issue 一覧を取得し直し、子が実際に含まれるかで「既登録（冪等スキップ）」と「それ以外のエラー」を判別するよう変更した。エラー側では GitHub の元メッセージをそのまま出力する。GitHub のエラー文言は仕様として保証されないため、`e.message` の文字列一致では判定していない
- `/todo list` の見積もり表示（`⏱`）が、`estimate:` に時間単位（`h`）が付いた値（例: `2h`）を正しく解釈できず、`2h` が `⏱2m` のように60〜120倍誤って表示される問題を修正（Issue #1854）。原因は、単位付き文字列を分へ変換する `parseTime()` が既に存在するのに、表示側の各所（`list` / `today` / `dashboard` / `report` の集計、`--json` の `estimateFormatted` を含む）が値抽出とパースの両方で `parseInt()` ベースの経路（正規表現 `/^estimate: (\d+)/m` で先頭の数字だけを切り出す）を使っていたため。抽出を `\S+`（値全体）に広げた上で `parseTime()` に統一し、「数値のみ」「`Nh`」「`Nm`」「`NhMm`」のいずれの保存形式でも正しく分へ変換されるようにした。`actual:` フィールドの集計（`report` コマンドの見積 vs 実績）にも同型の問題があったため合わせて修正した。`parseTime()` が解釈できない不正な形式（例: `estimate: abc`）は、従来 `⏱0m` と黙って表示されていたのを、`⏱⚠️abc` のように生値付きの警告表示に変更した（`show`（非JSON）は「（形式不正）」を添えて表示、`--json` の `estimateFormatted` は `null` を返す）
- `/todo unlink` が sub-issue 解除（GitHub 側の親子関係の DELETE）に失敗しても、body の `project: #N` 行を無条件に削除してしまい、GitHub 上の親子関係は残ったまま紐付け情報だけが消えるデータ喪失を修正（Issue #1880）。実事故あり: body が `project: #1640` を指す Issue に対し `unlink` を実行したところ、実際の GitHub 上の親は `#1133` で DELETE 対象が存在せず `Not Found` を返したが、warning は stderr に出るだけで直後に成功メッセージが表示され、body の行だけが削除された。原因は2つ。(1) 対になる `addSubIssue()`（`'registered'`/`'skipped'`/`'error'` を返す）と非対称に、`removeSubIssue()` が戻り値を返さず、呼び出し側の `runUnlink()` が成否を判定できなかった。(2) `runUnlink()` は body の `project: #N` を「実際の親」と無条件に仮定して DELETE を試みており、body と GitHub の実態が食い違うケース（`migrate sub-issue` の登録失敗やプロジェクト付け替え時の body 直書き換え等で発生しうる）を検知していなかった。修正は次の3点。(1) `removeSubIssue()` を `addSubIssue()` と対称に `'removed'`/`'error'` を返す設計に変更し、`'removed'` 以外では body を更新せずエラー終了するようにした。(2) `runUnlink()` は DELETE を試みる前に `listSubIssues()` で親の実際の sub-issue 一覧を取得し、body が指す子が実際に含まれるか事前確認する。含まれない場合は黙って body を消さず、食い違いを明示してエラー終了する。(3) 食い違いを認識した上で body のみ解除したい場合の明示的な手段として `--force` フラグを新設した（GitHub 側に解除すべき関係が元々ないため `removeSubIssue()` は呼ばれない）。GraphQL の `issue.parent` を使えば実際の親を直接特定できるが、`todo-engine.js` は REST のみで構成されており（GraphQL呼び出しは0件）、新規導入は依存追加になるため見送った。「body と GitHub の親子関係の食い違いを検出する専用コマンド」は本Issueのスコープ外とした

---

## [v2.8.1] - 2026-08-11

### Fixed

- `activate`（NEXT自動昇格日）にカレンダー上実在しない日付（`2026-13-01`、`2026-02-30`、非うるう年の `2/29` 等）を指定しても検証されず保存できてしまう問題を修正（Issue #1803）。`normalizeDue` は正規化のみで実在性を判定しないため、`due` は #1650 で `validateDue` 経由の検証が入っていたが `activate` には同等の検証が抜けていた。`add --activate` / `edit --activate` の2箇所の呼び出し経路に、YYYY-MM-DD形式チェックに加え `isValidCalendarDate` による実在日付チェックを追加した共通関数 `validateActivateFormat` を通すようにした。`--before` 指定経由（`addDays` で due から逆算する経路）は JS Date の日数加算で常に実在する日付が生成されるため対象外（影響なしを確認済み）
- `isValidCalendarDate` が西暦0000〜0099年の日付を誤って INVALID 判定していた問題を修正（Issue #1804）。原因は `new Date(y, mo-1, da)` コンストラクタが年 0〜99 を 1900+年 とみなす歴史的仕様（例: `new Date(99, 4, 1)` は `1999-05-01` になる）で、逆変換一致チェックの前提が崩れていたため。`Date.prototype.setFullYear()`（この2桁年吸収が発生しない）経由に変更して回避した。実害はほぼゼロだが、#1803 で `activate` 側にも本関数の適用範囲が広がるため同時に修正した

---

## [v2.8.0] - 2026-08-11

### Added

- GTDルーティンの周期遅延検知を追加（Issue #1776）。`recur` 付きの routine タスクについて、期日から今日まで何周期分「進めずに」経過したか（`cycles_overdue`）を計算し、`/todo today` に新設の「🕰 要確認（推定サイクル遅延）」セクションを設ける。従来の「ルーティン未実施」（1周期分の遅延=通常運用の範囲）と、2周期以上遅延した「実施はしたが done を打ち忘れている可能性が高い」ものを別枠に分離して表示する。`/todo list` の `routine`/`next`/`waiting` 表示にも 🕰 マーカーを追加した。routine は cycles_overdue が2以上（`recur` が欠落している routine は代わりに `updated_at` が30日以上前かで判定）、next/waiting は `updated_at` が30日以上前の場合にマーカーが付く。**検知のみを行い、タスクの状態やラベルを自動で変更することはない**（副作用ゼロ。今回追加した計算関数はいずれも読み取り専用で、`done` コマンド等の既存の書き込みパスには一切変更を加えていない）

### Fixed

- 日付処理のバグ3件を修正（Issue #1650、親 project #1640）
  - `normalizeDue` の M/D 形式（例: `1/5`）が常に「今年」の日付に変換され、today より過去の日付になっても繰り上げられず過去日として登録されていた問題を修正。変換結果が today より過去になる場合は自動で翌年に繰り上げる（例: today=2026-12-20 に `1/5` を指定すると `2027-01-05`）。副作用として、M/D 形式で過去日を意図的に指定する用途は使えなくなった（`YYYY-MM-DD` 形式で代替可能）。`2/29` のような閏日指定は、繰り上げ先の年がうるう年でない場合、実在するうるう年まで繰り上げる
  - `validateDue` が `YYYY-MM-DD` / `M/D` の両形式でカレンダー妥当性（実在する月日か）を検証していなかった問題を修正。`2026-13-01`（存在しない月）や `2026-02-30`（2月に30日は存在しない）、非うるう年の `2/29` 等が検証を通過し、`recur` と組み合わせると `NaN-NaN-NaN` の due が生成されるケースがあった。逆変換一致チェック（`isValidCalendarDate`）を追加し、`YYYY-MM-DD` と `M/D` の両形式に適用した。うるう年の `2/29`（例: `2028-02-29`）は引き続き許可される
  - サフィックスなしの `recur: monthly`（`monthly:<日>` は対象外）で、次回 due が月末を超過する場合に `addMonth()` の JS Date 自動繰り上げがそのまま使われ、対象月をスキップして数日先に飛び、以降ズレが蓄積する問題を修正（例: `1/31` の次回が `3/3` になり2月をスキップ、以降3日ずつドリフトしていた）。次回 due は月末にクランプするようになった（`1/31 → 2/28`、以降は `2/28 → 3/28 → ...` とクランプ後の日を基準に進むためドリフトしない。`3/31` への復帰はしない。復帰が必要な場合は `monthly:<日>`（Issue #1676）を使う）。`add-month` サブコマンド・自然言語の「来月」「Nヶ月後」（`addMonths()` 経由）は本修正の対象外で、従来の（クランプなしの）挙動のまま

---

## [v2.7.0] - 2026-08-09

### Added

- README を英語化し、英語版を `README.md`、日本語版を `README.ja.md` として提供するようにした（Issue #1636、OSS展開 #1634 の一環）。英語版に日本語版限定だったセクション（セキュリティ、開発、技術スタック、Pro機能、アーカイブコマンド群、言語設定）をすべて追加し、逆に日本語版に英語版限定だったセクション（プラグインインストール手順、日付入力パターン表）を追加して双方向のパリティを取った。あわせて README 内のローカルテスト件数表記を陳腐化した「423+ アサーション」から実測値「1,110+」に更新した
- `show` が closed Issue に対して完了状態と完了日を表示するようになった（Issue #1746）。人間可読表示に `- 状態: ✅ 完了（YYYY-MM-DD）` を追加し、JSON 出力（`show --json`）・`schema` にも `state` / `closedAt` フィールドを追加した
- `recur` に曜日・日付固定サフィックスを追加（Issue #1676）。`weekly:<曜日>`（例: `weekly:sat` = 毎週土曜固定）と `monthly:<日>`（例: `monthly:15` = 毎月15日固定）の2種類の構文を、`add --recur` / `edit --recur` / `recur <#>` / 完了時の周期再作成（`postDoneProcessing`）すべてで使用可能にする。次回due計算は「厳密加算」方式（基準日＝前回の期日（未設定なら完了日）に最低1周期分を加えてから、対象の曜日・日付に合わせる。基準日が土曜でも `weekly:sat` の次回は7日後の次の土曜になり当日には戻らない。逆に予定より早く完了した場合は直近の該当日を飛ばす。例: 期日が木曜のタスクは2日後の土曜ではなく9日後の土曜になる）。`monthly:<日>` でその月に存在しない日（2/30等）を指定した場合はその月の末日にクランプし、指定日そのものは保持し続けるためズレは蓄積しない（例: `monthly:31` は2月なら28日/29日、3月は31日に自動復帰）。サフィックスなしの既存 `daily`/`weekly`/`monthly`/`weekdays` の挙動は完全に維持（後方互換）

### Fixed

- `LANG_ENV=en` で実行しても成功メッセージ・エラーメッセージの多くが日本語のまま出力されていた問題を修正（Issue #1653、OSS展開 #1634 の前提作業）。`runAdd`/`runDone`/`runMove`/`runEdit`/`runDue`/`runDesc`/`runRecur`/`runLink`/`runRename`/`runPriority`/`runTag`/`runUntag`/`runLabel`/`renameCtxLabel`/`runSearch`/`runArchive`/`runBulk`/`runReviewSomeday`/`runPromoteProject`/`runUnlink`/`runWeeklyProjectAudit`/`runMigrateSubIssue`/`runSchema`/`runShow`/`runView`/`postDoneProcessing`/`ensureLabel` の呼び出し元・`fetchAllOpen`・`addSubIssue`/`listSubIssues`/`removeSubIssue`・未知コマンド/予約語ガードのエラーメッセージなど、出力関数に直書きされていた日本語リテラルを `MESSAGES`/`t()`/`tpl()` 経由に置き換えた（新規キー157件、ja/en 両方）。日付キーワードの日本語入力パース（`今日`/`明日`/`来週`等、`normalizeDue`）は言語設定と独立という既存設計のため対象外（`LANG_ENV=en` でも引き続き解釈される）
- GitHub API が返す UTC の `closed_at`/`updated_at` を `.slice(0,10)` でそのまま日付化していたため、JST 0〜9時台に完了・更新したタスクが前日扱いになっていた問題を修正（Issue #1748）。`toJstDateStr()` ヘルパーを新設し、`done-count` / 週次集計 / stale 判定 / 完了一覧表示など日付化する全箇所をこのヘルパー経由に統一した
- Web セッション等 `.env` が使えない環境で `TODO_REPO_OWNER`/`TODO_REPO_NAME` が未設定のまま実行すると、原因不明の `Not Found` エラーとして露出していた問題を修正（Issue #1695）。`runMain()` の入口で未設定を検知し、環境変数の設定例と GitHub MCP ツールによる手動フォールバック手順（ラベル・body 書式）を案内するようにした（`help`/`schema` は GitHub API を使わないため対象外）。あわせて GitHub REST API が 401（認証拒否）を返すケースも検知し、`Bad credentials` 等の生メッセージではなく再設定手順・フォールバック手順を案内する（`run` サブコマンド・`api` サブコマンドの両方）
- `tag` / `bulk tag` で不正なラベル名が検証なく GitHub 上に新規作成される問題を修正。`bulk tag <nums...> -- @ctx` のように `--` を渡すと、`normalizeTagTokens` が `@`/`#` の付かないトークンをコンテキスト扱いして `@--` に正規化し、`validateCtx` はシェル危険文字（`FORBIDDEN_CHARS`）しか見ないため `-` が通過して `@--` ラベルが作成・付与されていた。出力は通常の成功メッセージと区別がつかず、静かに永続的な副作用が残っていた
- `list` 系表示（`renderIssueList`）で `recur: weekly:sat` のようなコロン付き値が `weekly` に切り詰められて表示されるバグを修正。正規表現 `/^recur: (\w+)/m` はコロンにマッチしないため発生していた（`\S+` に変更。曜日・日付固定サフィックス機能の実装時に発見）

### Changed

- `validateCtx` / `validateTag` に「文字または数字を1文字以上含むこと」の検証を追加。記号のみ・空文字のラベル名を拒否する
- `normalizeTagTokens` が `-` 始まりのトークンをコンテキストへ正規化せず、オプション指定の誤りとしてエラーにするようになった
- `ensureLabel` が「新規作成したか」を戻り値（boolean）で返すようになった。`tag` / `bulk tag` は未登録ラベルを作成したとき `🆕 新規ラベル <name> を作成しました` を出力する。打ち間違いによる新ラベル化を呼び出し側が出力で気づけるようにするため（TOCTOU 競合で 422 になった場合は既存扱いとし通知しない）

---

## [v2.6.0] - 2026-08-04

### Added

- `resume_condition` フィールドを新設（`due:`/`activate:` と同じ行プレフィックス方式）。`edit --resume-condition <テキスト>`（`clear` でクリア）・`add --resume-condition <テキスト>` に対応。`promote` は activate 到来かつ resume_condition 設定済みの Issue を機械的に自動昇格せず、`⏸` の確認待ちメッセージを出力するのみに留める（resume_condition なしの既存挙動は完全維持）。JSON出力（`show`/`list`/`search --json`）・`schema` にも `resumeCondition` フィールドを追加。実際の条件充足判定はエンジン側に持ち込まず、週次レビュー時にユーザー自身が確認してから `promote` させる運用に委ねる設計（背景: activate 到来のみで機械的に next 昇格したタスクが、実質的な再開条件を満たさないまま昇格していた実例があった）

### Known limitations

- CLI `build-body` サブコマンド（後方互換のための固定位置引数API、10個）は `resume_condition` を受け取る引数を持たない。`buildBody`側はデフォルト空文字のため実害はないが、このAPI経由で`resume_condition`を設定することはできない（`edit --resume-condition`を使うこと）
- リカレンスタスク完了時の再作成（`postDoneProcessing`）で `resume_condition` は次回分に引き継がれない（due/recur/project等の他フィールドと異なる挙動のため要注意）

---

## [v2.5.0] - 2026-08-03

### Added

- `api done-issue <number>` を新設。Web版 `GitHubIssueRepository.done()` は旧実装で `api close-issue` を呼ぶだけで、CLIの `runDone` が呼ぶ `postDoneProcessing`（recur再作成 + depends_on昇格）を一切経由しないため、Web版で繰り返しタスクを完了すると周期チェーンが無言で途切れていた。`done-issue` は Issue を close した後に `postDoneProcessing` を呼び、`{ok, recurLine, otherLines, newIssueNumber}` の JSON を返す（Issue #1669）

### Fixed

- `postDoneProcessing()`: depends_on 昇格チェックが `if (issue.project || issue.dependsOn)`（完了する Issue **自身**の project/dependsOn の有無）でガードされ、完了 Issue 自身がどちらも持たない場合は他の Issue からの依存関係チェックごとスキップされていたバグを修正。depends_on 昇格は「他のオープン Issue がこの完了 Issue に依存しているか」を調べる処理であり、完了した Issue 自身の project/dependsOn 有無とは論理的に無関係なため、ガードを撤去し常に `fetchAllOpen` を実行するようにした（実例: #1275 完了後に #1299 が waiting のまま昇格しなかった不具合。プロジェクト昇格候補ヒントの表示条件は変更なし）（Issue #1660）
- `parseArgs()`: `#` 始まりトークンのタグ判定に「空白を含まない」制約がなく、タイトル全体が1トークンで `#` 始まりの場合（例: `#1299 depends-on強化について`）に丸ごとタグ扱いされ「タイトルが空です」エラーになるバグを修正。タグ判定に `!tok.includes(' ')` を追加（Issue #1660）
- `runView`: `view save` で複数の `@ctx` を同時指定した場合に無言で握りつぶしていたのを、明示的なエラー（`エラー: view save では @ctx は1つのみ指定できます`）で終了するように修正。エラー時はビューが保存されない（Issue #1675）

---

## [v2.4.0] - 2026-08-03

### Added

- `todo-engine.js` の `initOctokit()` に環境変数トリガー方式の Octokit 注入シームを追加（`OCTOKIT_STUB_ENV`/`OCTOKIT_STUB_LOG_ENV`/`OCTOKIT_STUB_RESPONSES_ENV`）。記録型スタブ Octokit（`tests/stubs/octokit-stub.js`、JSONL記録 + キュー式応答解決 + `__throw`によるエラーシミュレーション）を経由し、書き込み系ハンドラ（`runAdd`/`runDone`/`runEdit`/`runBulk`/`runView`/`runPriority`/`runTag`）を GitHub 接続・トークンなしでCLI直叩きテストできるようにした。テスト基盤として `tests/run-tests-write.sh` を新設し、優先6ハンドラに正常系・異常系（副作用の過不足検証込み）の振る舞いテストを追加。`runPriority`/`runEdit` の validate-before-mutate 順序バグは修正せず、現状挙動を記録する characterization テストとして固定（修正は別Issue）。実行口は `bash tests/run-tests.sh` の1コマンドのまま変わらない（Issue #1648）

### Changed

- `apiMain()` 冒頭のトークン取得・Octokit構築の重複コードを `initOctokit()` 呼び出しに統合（DRYリファクタ、Octokit注入シームの恩恵が `api` サブコマンド系にも自動的に適用されるようになった）。挙動・エラーメッセージ文言に変更なし
- テスト資産の一部をスタブベースの振る舞いテストに置換: §24 View CRUD（`node -e` コピー実装）、Issue #1643 回帰テスト（実HOMEのnode_modulesシンボリックリンク+スキップ分岐）、`POSTDONE_USES_CATCHUP`/`DONE_CALLS_POSTDONE`/`BULK_CALLS_POSTDONE`/`TAG_RENAME_DELEGATES`（いずれもソースgrep型で実行結果非検証）を `tests/run-tests-write.sh` の実CLI直叩きテストへ置換・削除。`run` 系テストの `GH_TOKEN=dummy`（実 `@octokit/rest` の実インストールに暗黙依存）をバリデーションのみで完結するものから順次 `OCTOKIT_STUB_ENV` に置換（Issue #1648）

---

## [v2.3.0] - 2026-08-03

### Added

- 予約語タイトル誤爆ガード: `/todo <GTDラベル> <タイトル>`（`project` 含む暗黙add経路）でタイトルが単一トークンかつ `list`/`help`/`done`/`project`/`counts` 等の既知コマンド名と完全一致する場合、ゴミ Issue を作らずエラー終了し `/todo list <ラベル>` または `/todo add <ラベル> <タイトル>` を提案するようにした。`add` を明示した経路には影響しない（Issue #1646）

### Fixed

- `runBulk`（`bulk done`）がリカレンス再作成・`depends_on` 昇格処理を一切行わず、繰り返しタスクを一括完了すると周期チェーンが無言で途切れるデータ損失バグを修正。`runDone` の完了後処理（recur再作成 + depends_on昇格 + プロジェクト昇格候補ヒント）を共通関数 `postDoneProcessing` に抽出し、`runDone` と `runBulk`（`done`）の両方から呼び出すように統一。`bulk done` のサマリーに再作成件数を表示（例: `✅ 3件完了（うち繰り返し再作成: 1件）`）（Issue #1642）

---

## [v2.2.1] - 2026-08-03

### Fixed

- `runView`: `view delete <name>` が「名前扱いフォールバック」（`sub === 'use' || !sub.startsWith('-')`）に吸われ、削除機能がCLI経路から到達不能だったバグを修正。`delete` サブコマンドの判定をフォールバックより前に移動（Issue #1643）
- `runMain`: `run` プレフィックス経由（`todo.sh` は常にこの経路）で `api` サブコマンドが「未知のコマンド」エラーになり、`api list-comments` 等のドキュメント記載の使用例が実行不能だったバグを修正。`runMain` に `case 'api'` を追加し `apiMain` へ委譲するようにした（Issue #1644）
- `tag rename <old> <new>` を実装。`label rename` と同一のコンテキストラベル一括リネーム処理を共通関数 `renameCtxLabel` に切り出し、両コマンドから呼び出す形に統一（ドキュメント記載のみで未実装だった機能。Issue #1644）
- `README_EN.md` Quick Start の先頭例が英字ガードで即エラーになっていたのを `/todo add buy groceries` に修正し、英字タイトルは `add` を明示する旨を追記（Issue #1644）

---

## [v2.2.0] - 2026-08-03

### Added

- `/todo due <#> clear` — 期日を削除する（`recur clear` と同一命名規則）(Issue #1473)
- `/todo edit <#> --due clear` — `edit` コマンドでも期日削除が可能
- `/todo edit <#> --due ""` — 空文字指定でも期日削除として扱う
- `MAX_OPEN_ISSUES_LIMIT = 200` 定数を追加。`fetchAllOpen` が上限に達したとき stderr に警告を出力するようになった

### Fixed

- リカレンスタスク完了時、期限超過タスクで再作成 due が過去日付になるバグを修正。`nextDueCatchUp` で曜日・周期を保持したまま「今日より後」になるまで周期を進める方式（`MAX_RECUR_CATCHUP_ITERATIONS = 3660` ガード付き）。周期スキップが発生した場合は完了メッセージに表示する (2026-07-13)
- `runArchive`: `sub === 'list' || sub === 'list'` の重複条件をシングル条件に修正（コードクローンバグ, 🔴-1）
- `runArchive search`: グローバル変数 `REPO_OWNER`/`REPO_NAME` を引数 `owner`/`repo` に修正（🔴-2）
- `runLabel add/delete/rename`: 引数なし呼び出しで TypeError クラッシュしていたのを、Usage メッセージ + `exit 1` で適切にガードするよう修正（🔴-3）
- `runView`: 引数なしで呼んだとき `undefined.startsWith` で TypeError クラッシュしていたのを、Usage メッセージ + `exit 1` で修正（🔴-4）
- `runMain` default 分岐: 英字タイトルによるエラー時のメッセージに「コマンドと混同を避けるため英字タイトルは add 明示必須」の根拠を追記（🟡-9）

### Changed

- `todo.md`: `add` コマンドの説明に「英字タイトルを add なしで渡すとエラー」の挙動を明示（🟡-9）

### Refactored

- **Phase 3 — コードレビュー指摘 🟡-2〜🟡-7 対応（2026-05-19）**:

  **🟡-2: `parseBody` を `parseBodyObj` のラッパーに変更**
  - `parseBodyObj`（オブジェクト返却版）を `parseBody` の前に移動し、`parseBody` をそのラッパーとして実装。フィールド追加時の二重修正を防止。`dependsOn` フィールドが `parseBody` でも拾われるようになった（以前は `parseBodyObj` にのみ存在）。出力フォーマット（`KEY=VALUE\n...`）は後方互換のため不変。

  **🟡-3: `removeLabelIfPresent` ヘルパを新設**
  - 12 箇所に散在していた `try { removeLabel } catch(e) { if (e.status !== 404) throw e }` パターンを `removeLabelIfPresent(octokit, owner, repo, issue_number, name)` ヘルパへ統合。`execRemoveLabels` もヘルパのループ呼び出しで実装。

  **🟡-4: M/D 正規化を `normalizeDue` に吸収**
  - `M/D` → `YYYY-MM-DD` 変換ロジックが 5 箇所にコピペされていたのを `normalizeDue` 内に吸収。呼び出し側のコピペを全削除。`validateDue` は引き続き `M/D` 形式を許容し、`normalizeDue` 通過後は `YYYY-MM-DD` に統一される。

  **🟡-5: `todo.sh` の `counts` ロジックを `_todo_fetch_counts` 関数に共通化**
  - `counts` サブコマンドと自動キャッシュ更新で重複していた gh issue list + jq クエリを `_todo_fetch_counts` bash 関数に抽出。GTD ラベル名を `_GTD_LABELS` 変数に一元化。

  **🟡-6: 集計関数 `today()` を `renderToday()` にリネーム**
  - ローカル変数 `today`（YYYY-MM-DD 文字列）との名前衝突を解消。ラッパー関数 `today_fn()` を削除。`runToday` および内部 CLI ディスパッチャーを直接 `renderToday()` 呼び出しに変更。

  **🟡-7: `execMoveGtd` のエラー throw を `apiErr` 経由に統一**
  - `execMoveGtd` の `throw new Error(...)` を `throw apiErr(...)` に変更（`_msgWritten` フラグにより `runMain.catch` での二重表示を防止）。`runMove` の無用な try/catch + exit(1) ラッパーを削除し、エラーを上位に伝播させるシンプルな設計に変更。

  - 10 件の新規テスト追加（Phase 3 検証）。既存 615/628 PASS → 625/638 PASS（+10 件、既知 13 失敗は変化なし）

- **Phase 2 — `buildBody` をオブジェクト引数化（🟡-1, 最大保守性負債解消）**: 10 引数 positional API（`buildBody(due, recur, project, estimate, actual, desc, activate, before, reviewedAt, dependsOn)`）をオブジェクト引数 + デフォルト値分割代入の形式（`buildBody({ due, recur, ..., dependsOn })`）に変更。`parseBodyObj` の戻り値と完全対称になり、`buildBody({ ...issue, desc: newDesc })` のような差分更新が自然に書けるようになった。
  - 内部 12 箇所の呼び出しを差分更新パターンに統一: `runAdd` / `runDone`（actual 更新・recur 再作成）/ `runEdit` / `runDue`（clear・通常）/ `runDesc` / `runRecur` / `runLink` / `runTemplate` / `runBulk done` / `runReviewSomeday` / `weekly-project-audit`
  - `issue.xxx || ''` の OR 連鎖を全箇所で除去（`fetchAndParseIssue` が常に空文字を返すため冗長だった）
  - `runTemplate` の引数欠落バグ（9 引数しか渡しておらず `dependsOn` が undefined だった）を併せて修正
  - CLI `build-body` サブコマンドの positional 引数 API は後方互換のため維持（内部で新形式に変換）
  - 47 件の新規テスト追加（buildBody/parseBodyObj 対称性・round-trip・差分更新・デフォルト値・CLI 互換）
  - 効果: 今後 body メタフィールドを追加する際の修正箇所が 12 箇所 → 1 箇所に縮約。位置ずれ事故リスクも消失

---

## [v2.1.0] - 2026-04-26

### Added

#### GitHub Sub-issue Integration
- `--project N` now automatically registers the created issue as a GitHub sub-issue via the REST API (`POST /repos/.../issues/N/sub_issues`)
- `/todo link X N` also registers the sub-issue relationship in addition to writing `project: #N` to the body
- `/todo migrate sub-issue [--dry-run]` — bulk-register existing `project: #N` issues as GitHub sub-issues (idempotent; 422 already-registered issues are skipped)

#### Project Management
- `/todo promote-project <#>` — promote an existing issue to a project (removes GTD labels, adds `📁 project`)
- `/todo unlink <#>` — remove sub-issue relationship and `project: #N` body line from a child issue
- `/todo weekly-project-audit` — scan all projects, detect missing next actions and stale (30+ day) projects, auto-write `reviewed_at` to stale project bodies
- `/todo list` project section now shows `reviewed_at` age ("最終レビュー: N日前") and ⚠️ badges for next-missing or stale projects
- `project` label is now managed separately from `GTD_LABELS`

#### Tickler File (Activate / Before / Promote)
- `--activate <date>` option on `add` and `edit` — set a future date on which the issue is automatically promoted from inbox to next
- `--before <Nd>` option on `add` and `edit` — automatically calculate activate as N days before `--due`
- When both `--activate` and `--before` are given, the earlier date wins
- `/todo promote` — elevate all issues whose activate date has arrived to next
- `daily-review` now calls `promote` automatically

#### Someday Review Management
- `/todo review-someday <#>` — record today as `reviewed_at` in the issue body for a someday task
- `/todo list someday` — issues with `reviewed_at` older than 30 days (or unset) are shown with ⚠️ at the top of the list
- Weekly review Step 5 shows ⚠️-flagged issues first and prompts `review-someday` recording

#### Waiting Activation
- `/todo edit <#> --activate <date>` and `/todo activate <#> <date>` — set the date when a waiting issue should automatically be promoted to next
- Waiting issues with an activate date are promoted to next on `daily-review`

#### Estimation
- `--estimate <time>` option on `add` and `edit` — record estimated work time (e.g., `2h`, `1h30m`, `30m`)
- `/todo list` shows `⏱Nh` next to estimated issues
- `/todo list --no-estimate` — filter to show only issues without estimates
- `/todo stats` shows estimated total and count for next tasks
- `/todo dashboard` shows today's total estimated time
- `/todo report` includes estimate vs. actual analysis section

#### Task Dependencies
- `--depends-on <#>` option — when the specified issue is completed with `/todo done`, the dependent issue is automatically promoted to next

#### List Filters
- `--no-due` filter — show only issues without a due date
- `--no-estimate` filter — show only issues without an estimate

#### Mobile Support (SH_MODE / MCP_MODE)
- `todo.sh` now auto-detects the execution environment
- **SH_MODE** (default): runs `todo-engine.js` locally via Node.js
- **MCP_MODE**: when `~/.claude/todo.sh` is absent (e.g., iOS Claude Code), maps commands directly to GitHub MCP

### Changed

#### Daily Review Enhancements
- **Step 0 (new)**: shows the previous day's "1 action" and asks for a follow-up
- **Step 3.5 (new)**: shows the top 3 next actions without a due date
- **Step 3.7 (new)**: shows the top 3 next actions without an estimate, with a split suggestion for large tasks
- **Inbox 2-minute rule**: for each inbox item, asks "Can you do this in 2 minutes? (y/n/skip)" — answering `y` marks it as done immediately

#### Weekly Review Enhancements
- **Step 4** replaced with `weekly-project-audit` (full project scan instead of manual review)
- **Step 5 (Someday)**: ⚠️-flagged items shown first; prompts `review-someday` recording

#### done Command
- After completing a project's child task, the command now shows candidate next tasks for the same project

### Internal

- `todo.md`: 176 → 283 lines (+107)
- `todo-engine.js`: 2,673 → 3,567 lines (+894)
- `todo.sh`: 33 → 44 lines (+11; Windows Git Bash TZ compatibility + TODO_TZ env var support)
- `tests/run-tests.sh`: 383 → 423 assertions (+40)
- `tests/scenarios.md`: 850 → 1,348 lines (+498; covers activate/before/promote, someday reviewed_at, sub-issue phase 1/3, mobile scenarios 36–40)

---

## [v2.0.0] - 2026-04-15

Initial public release. Three-layer architecture: `todo.md` (Claude slash command) + `todo-engine.js` (Node.js core engine) + `todo.sh` (launcher).

Core features: GTD 6-category management, 30+ commands, priority/context/recurrence, bulk operations, templates, weekly review, dashboard, reports, security rules (8 protections).
