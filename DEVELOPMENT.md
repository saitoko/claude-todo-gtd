# todo スキル 開発ガイド

`/todo` スキル本体（`todo.md` + `todo-engine.js`）にコントリビュートする方向けの開発ガイドです。
バグ修正・機能追加の Pull Request を送る前にお読みください。

## ファイル構成

このリポジトリを clone すると、次のような構成になっています。

```
claude-todo-gtd/
├── todo.md                 ← スキル本体（編集対象。`~/.claude/commands/` にコピーして使う）
├── todo-engine.js           ← エンジン本体（編集対象。`~/.claude/` にコピーして使う）
├── todo.sh                  ← 起動用ラッパースクリプト（`~/.claude/` にコピーして使う）
├── todo-manual.md            ← 詳細ユーザーマニュアル
├── todo-templates.json       ← テンプレートストレージのサンプル
├── DEVELOPMENT.md            ← このファイル
├── README.md / README.ja.md  ← README（英語 / 日本語）
└── tests/
    ├── scenarios.md         ← テストシナリオ一覧
    ├── run-tests.sh         ← ローカル単体テスト（GitHubには接続しない）
    ├── run-tests-write.sh   ← 書き込み系ハンドラのスタブベーステスト
    ├── gh-tests.sh          ← GitHub 実接続テスト（実 Issue を作成・削除する）
    └── fixtures/
        └── sample-templates.json  ← テスト用テンプレートデータ
```

## 本番ファイルの場所

| ファイル | パス |
|---------|------|
| スキル本体 | `~/.claude/commands/todo.md` |
| エンジン | `~/.claude/todo-engine.js` |
| ラッパースクリプト | `~/.claude/todo.sh` |
| テンプレートDB | `~/.claude/todo-templates.json` |

## 開発フロー

1. `todo.md` または `todo-engine.js` を編集する
2. `bash tests/run-tests.sh` でローカルテスト（GitHub API には接続しない）を実行し、全件 PASS を確認する
3. 実際の GitHub リポジトリで動作確認したい場合は、`.env` に自分の `TODO_REPO_OWNER`/`TODO_REPO_NAME` を設定した上で `bash tests/gh-tests.sh` を実行する（実 Issue を作成・クローズする点に注意）
4. 動作確認後、本番パスにコピーして反映する

```bash
# 本番への反映
cp todo.md ~/.claude/commands/todo.md
cp todo-engine.js ~/.claude/todo-engine.js
cp todo.sh ~/.claude/todo.sh
```

## テスト

- テストランナー: `bash tests/run-tests.sh`（+ 書き込み系は `bash tests/run-tests-write.sh` として個別実行も可能。通常は `run-tests.sh` から自動的に呼び出される）
- 自動テスト総件数: **1,914件**（read-only系 947 + 書き込み系 967。`bash tests/run-tests.sh` の最終行が出す実測値。2026-09-05 時点。全件PASSが目安）
- シナリオ一覧: `tests/scenarios.md`
- 全件 PASS が Pull Request マージの必須条件
- 件数を更新する際は README.md の記載も合わせて更新する

## 改善アイデアの記録

改善案・バグ報告は本リポジトリの GitHub Issues に登録してください。

## バグ修正履歴

### 2026-04-05: `template save` でコンテキストが保存されない

**症状:** `template save <名前> next @会社 @PC` を実行しても `context` フィールドが常に `[]` になる。

**原因:** Bash の仕様により、以下の形式では `CTX_LIST_ENV` がサブシェルに伝播しない。
```bash
# NG: CONTEXTS_JSON=(...) は代入式のため、プレフィックスが subshell に届かない
CTX_LIST_ENV="${CONTEXTS_LIST# }" CONTEXTS_JSON=$(node -e "...")
```

**修正:** `$()` の内側にプレフィックスを移動する。
```bash
# OK: node コマンドのプレフィックスとして正しく渡される
CONTEXTS_JSON=$(CTX_LIST_ENV="${CONTEXTS_LIST# }" node -e "...")
```

**対象ファイル:** `~/.claude/commands/todo.md`（「CONTEXTS_JSON を node で生成」セクション）

### 2026-07-13: リカレンスタスク完了時に再作成タスクの due が過去日付になる（#1564→#1584）

**症状:** リカレンス付きタスクが期限超過（due が過去）の状態で `/todo done` すると、再作成されたタスクの due が**過去日付**のまま生成される。実事故: #1564（weekly、due 超過）を 2026-07-11 に done → 再作成 #1584 が due **2026-06-13**（過去）で生成された。ユーザーが手動で 2026-07-18 に修正。

**原因:** `runDone()`（旧コード）が `nextDue(issue.recur, base)` を1回だけ適用していたため、`base`（= `issue.due`）が数週間〜数ヶ月前の日付だと、1周期進めるだけでは今日を超えられなかった。

```js
// NG: baseが過去だと1周期進めても過去日付のまま
const base = issue.due || today;
const nextDate = nextDue(issue.recur, base);
```

**修正:** cadence保持スキップ方式。`nextDue()` を1回適用した結果がまだ今日以前なら、曜日・周期を保持したまま今日より後になるまで繰り返し適用する `nextDueCatchUp(pattern, base, today)` を新設し、`runDone()` はこちらを使う（`nextDue()` 自体のシグネチャ・単体挙動は変更していない）。無限ループ防止のため `MAX_RECUR_CATCHUP_ITERATIONS`（3660回）で反復上限を設けている。

```js
// OK: 今日より後になるまでnextDue()を繰り返し適用
function nextDueCatchUp(pattern, base, today) {
  let date = nextDue(pattern, base);
  let skipped = false;
  let iterations = 0;
  while (date <= today && iterations < MAX_RECUR_CATCHUP_ITERATIONS) {
    date = nextDue(pattern, date);
    skipped = true;
    iterations++;
  }
  return { nextDate: date, skipped };
}
```

周期スキップが発生した場合、`done` の完了メッセージに `⏭ 期限超過のため過去の周期をスキップしました（due基準: ... → 再作成: ...）` を追記する。テスト用に CLI サブコマンド `next-due-catchup <pattern> <base> <today>` を追加（`tests/run-tests.sh` §33 参照）。

**対象ファイル:** `todo-engine.js`（`runDone()` および `nextDueCatchUp()`）

**既知の未解決事項（本修正のスコープ外）:** テストスイートに1件、本修正と無関係な既存FAIL（`§25 Report: 完了7件` — `assert_contains` の期待値パターン `**7件**` が BRE の repetition operator と衝突し `grep` がエラーを返す。`git stash` で本修正前のコードに戻しても再現するため、修正前から存在する既存バグ）。

### 2026-08-03: depends_on 昇格が完了 Issue 自身の project/dependsOn 有無でスキップされる（#1660）

**症状:** #1275（project も depends_on も本文になし）を完了しても、#1275 に依存する #1299（`depends_on: #1275`）が本来 next へ自動昇格するはずが、waiting のまま放置される。

**原因:** `postDoneProcessing()` の depends_on 昇格チェックが `if (issue.project || issue.dependsOn)`（完了する Issue **自身**の project/dependsOn の有無）でガードされていた。しかし depends_on 昇格は「他のオープン Issue がこの完了 Issue に依存しているか」を判定する処理であり、完了した Issue 自身が project/dependsOn を持つかどうかとは論理的に無関係。

```js
// NG: 完了Issue自身にproject/dependsOnがないとdepends_on昇格チェック自体がスキップされる
if (issue.project || issue.dependsOn) {
  const openIssues = await fetchAllOpen(...);
  // depends_on昇格処理...
}
```

**修正:** ガードを撤去し、project/dependsOn の有無に関わらず常に `fetchAllOpen` を実行して depends_on 昇格チェックを行うようにした（プロジェクト昇格候補ヒントは、完了した Issue 自身が project を持つ場合のみ表示する仕様のまま維持。こちらは論理的に妥当なガードのため変更していない）。

```js
// OK: 常にfetchAllOpenを実行し、依存関係を確認する
{
  const openIssues = await fetchAllOpen(...);
  // depends_on昇格処理...
}
```

**対象ファイル:** `todo-engine.js`（`postDoneProcessing()`）

### 2026-08-03: `#` 始まりのタイトルが丸ごとタグ扱いされ「タイトルが空です」エラーになる（#1660）

**症状:** `/todo add "#1299 depends-on強化について"` のように、タイトル全体が1トークンで `#` 始まりの場合、タグとして誤認識され「タイトルが空です」エラーになる。

**原因:** `parseArgs()` のタグ判定 `tok.startsWith('#') && !/^#\d+$/.test(tok)` に「空白を含まない」制約がなく、空白を含む1トークン全体（例: `#1299 depends-on強化について`）もタグとして拾われていた。

```js
// NG: 空白を含む文字列もタグ扱いされてしまう
} else if (tok.startsWith('#') && !/^#\d+$/.test(tok)) {
```

**修正:** タグ判定に `!tok.includes(' ')` を追加し、空白を含むトークンはタグ扱いしないようにした。

```js
// OK: 空白を含む場合はタグ扱いしない（#42のようなIssue番号単体は従来通り除外）
} else if (tok.startsWith('#') && !tok.includes(' ') && !/^#\d+$/.test(tok)) {
```

**対象ファイル:** `todo-engine.js`（`parseArgs()`）

### 2026-08-03: `resume_condition` フィールド追加 — activate/promote 自動昇格に再開条件ゲートを追加（Issue #1299由来の欠陥修正）

**症状:** `/todo promote`（`activate:` 日到来タスクを機械的に `next` へ昇格する処理）が、日付到来のみを判定基準にしており、Issue本文に書かれた実質的な再開条件（例: 「検索流入が回復したら」）を一切検証していなかった。実事故: #1299（検索流入回復を待って再開するはずのタスク）が、実測では検索流入が依然ゼロ（未回復）のまま、`activate:` 到来のみで `next` に機械的昇格した。

**原因:** `resume_condition:` という構造化フィールドが存在せず、本文の自由記述部分（`desc`）は `runPromote` から一切参照されていなかった。

**修正:** `due:`/`activate:` と同じ行プレフィックス方式で `resume_condition:` フィールドを新設。`runPromote` は `resume_condition` が設定されている Issue を検出すると機械的な自動昇格をスキップし、`⏸` の確認待ちメッセージを出力するのみに留める（実際の条件充足判定はエンジン側に持ち込まず、週次レビュー時にユーザー自身が確認してから昇格させる運用に委ねる設計。詳細な設計判断の経緯は開発側リポジトリで管理）。

**変更箇所:** `parseBodyObj`/`parseBody`/`buildBody`（body CRUD）、`parseArgs`（`--resume-condition` フラグ新設）、`validateResumeCondition`（新設・改行混入のみ禁止）、`runAdd`/`runEdit`（設定・クリア対応）、`runPromote`（本設計の核・スキップ分岐）、`issueToJsonObj`/`runSchema`/`runShow`（JSON出力・schema・人間可読表示）、`help()`。

**実装時の修正点（設計書との差分）:** 設計書は `'resume_condition: '.length === 19` としていたが、実際は **18**（`node -e "console.log('resume_condition: '.length)"` で確認）。19でスライスすると先頭1文字が欠落する（round-tripテストで検出）。`slice(18)` が正しい。また、設計書の `runAdd` 差分案では `resume_condition` バリデーションを `metaBody` 構築直前（ラベル作成処理より後）に置く例を示していたが、これだとバリデーションエラー時にラベル作成の副作用（`ensureLabel` API呼び出し）が先に発生してしまう。他フィールドのバリデーション（`due`/`recur`/`project`/`estimate`等）と同じ位置（ラベル作成ループより前）に移動した。

**対象ファイル:** `todo-engine.js`

**テスト:** `tests/run-tests.sh`（buildBody/parseBodyObj 単体テスト・round-trip）+ `tests/run-tests-write.sh` §W12（10ケース・スタブベースCLI振る舞いテスト。add/edit/クリア/改行バリデーション/promoteスキップ/リグレッション/混在ケース/JSON出力）+ `tests/scenarios.md` §36-16〜36-21（手動シナリオ）。全875件PASS。

### 2026-08-11: GTDルーティンの `cycles_overdue` 検知（Issue #1776 実装A）

`renderToday()`/`renderIssueList()` に GTDルーティンの周期遅延検知（`cycles_overdue`）を追加。テスト用に CLI サブコマンド `cycles-overdue <pattern> <due> <today>` を追加（`tests/run-tests.sh` §43 参照）。

### 2026-08-16: `weekly-project-audit` / `list project` が someday 格下げ済みの project を除外しない（Issue #1846）

**症状:** `/todo move <n> someday` で project を「休止中」にしても `weekly-project-audit` / `/todo list project` が引き続き対象に含めてしまい、next 欠落として毎週 ⚠️ 誤検知する。実測（2026-08-16）で `📁 project` ラベル21件中10件が `🌈 someday` を併せ持つ「休止中」project だった（一部だけを目視確認した際は4件と見えていたが、`gh issue list --label "📁 project"` で全件確認すると10件だった）。

**原因:** `execMoveGtd`（`move <n> someday` の実処理）は除去対象の旧GTDラベルを `GTD_LABELS`（`next`/`routine`/`inbox`/`waiting`/`someday`/`reference`）から探すが、`GTD_LABELS` は `project` を含まない。`project` は `move <n> project` が明示的に禁止されている（`promote-project` 専任）ように GTD 状態と直交する軸として設計されているため、`project` を持つ Issue に `move <n> someday` すると `someday` が追加されるだけで `project` は剥がれず、二重ラベルのまま残る。`weekly-project-audit`/`list project` はこの二重ラベル Issue を素通しして毎回拾ってしまう。

```js
// GTD_LABELS は project を含まないため、project を持つ Issue に move <n> someday しても
// project ラベルは対象外扱いで剥がれない
const oldGtdLabel = labelNames.find(l => GTD_LABELS.includes(normLabel(l)));
```

**修正方針:** `execMoveGtd`（move 側）は変更せず、消費側（`runWeeklyProjectAudit` / `listAll()` の `list project` パス）で `🌈 someday` を併せ持つ `📁 project` を「休止中」として棚卸し・一覧対象から除外する。除外は黙って件数を減らさず、除外件数を利用者に明示する（`audit.paused_excluded` / `list.excluded_someday_projects`）。`move <n> next` 等で someday が外れれば自動的に一覧・audit に復帰する。

**対象ファイル:** `todo-engine.js`（`runWeeklyProjectAudit()` / `listAll()`）

**テスト:** `tests/run-tests-write.sh` §W18（3ケース: weekly-project-audit の除外+件数明示、list project の除外+件数明示、list someday は従来どおり除外しないリグレッション）+ `tests/scenarios.md` §39 P-19。全1220件PASS。

**フォローアップ（同日、スコープ拡張・ユーザー承認済み）:** 上記修正時点で自己申告していた残り2箇所も #1846 のスコープ内として対応した。

1. **プレーンな `/todo list`（フィルタなし全体一覧）の Projects セクション**: `listAll()` の「フィルタなし → GTDカテゴリ別グルーピング」分岐が `grouped[PROJECT_LABEL]` をそのまま使っており、`list project` / `weekly-project-audit` と表示件数が食い違っていた。同じ除外ロジックを適用し、ヘッダの件数・除外件数表示・フッターサマリーの `project: N件` を全て「休止中除外後」の件数に揃えた。
2. **`list project --json`**: `runList()` の `jsonMode` 分岐は意図的に除外**しない**設計判断とした。理由: (a) JSON は機械可読インターフェースであり「表示しないか」は UI 側の関心事でデータを間引く理由にならない、(b) 各要素の `labels` フィールドに既に `project` と `someday` の両方が入っているため、消費側が `labels.includes('someday')` で休止中判定を自分で行える（新規フィールド不要）、(c) 既存消費者は見つからなかった（後方互換の実害なし）。なお `issueToJsonObj()` の `gtd` フィールドは `GTD_LABELS.find()` を先に評価する既存実装のため、project+someday の二重ラベル Issue は `gtd: "someday"` と出力される（`project` ではない）。これは本Issueとは独立の既存仕様であり今回変更していない。

**実測訂正:** 当初の目視サンプルでは一部件数のみの確認だったが、全件確認したところ想定より多い件数が該当していた。ラベル属性ベースの判定にしているため、サンプル数に関わらず該当する Issue を漏れなく除外できる。

**対象ファイル（追加分）:** `todo-engine.js`（`listAll()` の「フィルタなし」分岐 / `runList()` の `jsonMode` 分岐）

**テスト（追加分）:** `tests/run-tests-write.sh` §W18-4（プレーン list の除外+件数明示、修正前コードに戻すと4アサーションがFAILすることを確認済み）+ §W18-5（`list project --json` が除外しないことをロックインする回帰テスト。この項目は挙動変更なしのためbefore/after差分はなし）。全1231件PASS。

### 2026-08-29: `TODO_TIMING=1` 実行時間計測の追加（Issue #455）

`TODO_TIMING=1` を設定すると `run`/`api` サブコマンド実行後に `[timing] total <N>ms (github <N>ms / parse <N>ms)` を stderr へ出力する機能を追加した（詳細は上記「翻訳方針」および CHANGELOG 参照）。

**実装時に踏んだ落とし穴:** 当初 `apiMain(...).catch(...).finally(() => printTiming(...))` という Promise チェーンで実装したところ、`run done`（Issue番号なし）等のバリデーションエラーで `[timing]` 行が出力されないことが実機確認で判明した。原因は、多数のハンドラがバリデーションエラー時に `throw` ではなく `process.stderr.write(...); process.exit(1);` を直接呼んでいるため（本ファイル全体に既存の広く使われている流儀）。`process.exit()` は同期的に即座にプロセスを終了させるため、`.finally()` はスケジュールされる前にプロセスが終了してしまい実行されない。対処として、Promise チェーンではなく `process.on('exit', () => printTiming(startNs))` を使う方式へ切り替えた。`process.on('exit', ...)` のコールバックは同期処理のみが保証されるが、`printTiming()` は `hrtime.bigint()`／配列演算／`process.stderr.write()` のみで完結するためこの制約下でも動作する。正常終了・`.catch()` 経由のエラー・`process.exit()` 直接呼び出しのいずれの終了経路でも1回だけ出力されることを、`tests/run-tests-write.sh` §W25-5（バリデーションエラー経路）・§W25-6（Octokit呼び出し中の例外経路）で回帰テスト化した。

**教訓（今後同種の計測・後処理コードを追加する開発者向け）:** 本ファイルで「コマンド実行の前後を挟んで何かする」処理を書く場合、`.catch()`/`.finally()` だけでは `process.exit()` を直接呼ぶハンドラを取りこぼす。確実に実行したい後処理は `process.on('exit', ...)` を使うこと。

**実装時に踏んだ落とし穴2件目（レビューで発覚・実機で修正）:** `wrapOctokitTiming()` を当初 `obj[key] = async (...a) => orig(...a)` という素朴な関数再代入で実装したところ、スタブベースのテスト（1403件）は全件PASSしたにもかかわらず、**実 `@octokit/rest`・実トークンで `TODO_TIMING=1` を付けて `run list next` 等を実行するとコマンドが丸ごと失敗する**（`Error: Cannot read properties of undefined (reading 'parse')`、stdout が空になり `TODO_TIMING` の有無で出力が変わらないという既定要件も破る）不具合があった。原因は、実 `@octokit/rest` の各メソッド（`octokit.request` だけでなく `octokit.issues.get` 等も同様）が `.endpoint`（さらに `.parse` を持つ）/ `.defaults` という関数プロパティを own property として持ち、ライブラリ内部がこれらを参照するため。素朴な再代入は新しい関数オブジェクトに置き換わるだけでこれらのプロパティを引き継がない。スタブ（`tests/stubs/octokit-stub.js`）はプレーンオブジェクトの単純な関数のみで `.endpoint`/`.defaults` を持たなかったため、この不具合を構造的に検出できなかった（全件PASSしたのに実環境で機能停止するという、テストの死角の実例）。

**修正:** `wrapOctokitTiming()` を `Proxy` の `apply` トラップ方式に変更した。`new Proxy(orig, { apply(target, thisArg, argArray) { ... } })` は元の関数オブジェクトそのものをラップし呼び出しだけをフックするため、`.endpoint`/`.defaults` を含む全プロパティが透過的に保持される。`thisArg` も `Reflect.apply` でそのまま転送するため、呼び出し元のレシーバに依存する内部実装があっても壊れない。あわせて `tests/stubs/octokit-stub.js` の各メソッドにも実 Octokit と同形のダミー `.endpoint`/`.defaults` を生やし（`attachOctokitLikeProps()`）、スタブ経由でもこの種の不具合を構造的に検出できるようにした。新設 CLI 診断コマンド `check-octokit-wrap-props`（`OCTOKIT_STUB_ENV` の有無でスタブ/実 `@octokit/rest` を切り替え、ネットワーク接続なしでプロパティの有無だけを確認する）で `tests/run-tests-write.sh` §W25-10（スタブ、常時実行）と `tests/run-tests.sh` §50（実 `@octokit/rest`、モジュール未検出時は SKIP）の両方から検証する。修正前の実装に戻すと両テストとも「保持されていない」で確実に FAIL することを実機確認済み。

**教訓（2件目）:** ライブラリが返すオブジェクトのメソッドをラップする場合、素朴な関数再代入は「呼び出し可能」までしか保証しない。ライブラリ内部が呼び出し時以外にそのメソッドの他のプロパティ（`.endpoint`/`.defaults`/`.paginate` 等）を参照している可能性を疑い、`Proxy` の `apply` トラップ等プロパティを透過するラップ方式を優先すること。またスタブは実ライブラリの「呼べる」という表面だけでなく「呼び出し可能なオブジェクトが持つ付随プロパティ」まで模していないと、この種の不具合をすり抜ける。

**対象ファイル:** `todo-engine.js`（メインディスパッチャーの `case 'run':`/`case 'api':`、`initOctokit()`、新設 `wrapOctokitTiming()`/`computeGithubMs()`/`printTiming()`/`check-octokit-wrap-props`）、`tests/stubs/octokit-stub.js`（`__delayMs` オプション新設。並行呼び出しの区間統合ロジックを検証するための人工遅延 / `attachOctokitLikeProps()` で `.endpoint`/`.defaults` を模す）

**テスト:** `tests/run-tests.sh` §50（`computeGithubMs()` 単体テスト7件 + 実 `@octokit/rest` プロパティ保持テスト5件）+ `tests/run-tests-write.sh` §W25（スタブベース振る舞いテスト14件）。全1413件PASS。実トークン・実リポジトリでの動作確認（`run list next` / `run today` / `api list-issues` / `run list project <N>`（`octokit.request()` 経由）の4種）も実施し、`TODO_TIMING` の有無で stdout が完全一致すること・`github` が非ゼロの妥当な値になることを確認した。

### 2026-08-29: `comment` が `--body-file`/`--body` 未対応で、未知フラグを本文として黙って投稿していた（Issue #1919）

**症状:** `comment <#> --body-file <path>` を実行すると、`<path>` の中身ではなく「`--body-file`」という**文字列そのもの**が本文として投稿され、`<path>` は黙って失われていた（エラーなし・exit 0）。実運用で発生し、事後に `gh api -X PATCH` で修復した。

**原因:** `runComment()` はフラグ解析を一切行わず `tokens[1]` だけを本文として読み、`tokens[2]` 以降を無条件に捨てていた。`runAdd()` は既に `--body`/`--body-file`（`--body-file` 優先）に対応していたが、`comment` には同じ仕組みが実装されていなかった。

```js
// NG: tokens[1] だけを本文として読み、以降のトークンは全て無視される
const text = tokens[1] || '';
```

**修正（初版）:** `comment` にも `runAdd()` と同じ `--body`/`--body-file`（`--body-file` 優先）を追加した。あわせて、`--body`/`--body-file` 以外の `--` で始まるトークン（既知フラグの値欠落を含む）を検出したら、本文へ連結せず即エラー終了するようにした。これが今回の事故の再発防止の核心（未知フラグ `--boddy-file` を渡すテストで直接再現・検証）。

```js
// 初版: tok.startsWith('--') を丸ごとエラー扱い
for (let i = 0; i < rest.length; i++) {
  const tok = rest[i];
  if (tok === '--body' && i + 1 < rest.length) { bodyOpt = rest[i + 1]; i++; }
  else if (tok === '--body-file' && i + 1 < rest.length) { bodyFileOpt = rest[i + 1]; i++; }
  else if (tok.startsWith('--')) {
    process.stderr.write(`${usage}\nError: unknown flag: ${tok}\n`);
    process.exit(1);
  }
}
```

**追補で発覚した副作用（実測・同日）:** 初版の `tok.startsWith('--')` は「`--` で始まる文字列すべて」を未知フラグ扱いにしていたため、Markdown の水平線（`"--- 区切り線 ---"`）や「`--body` を説明する文章」のような**正当な本文まで拒否**していた（実測で exit 1）。エラーで落ちるため「静かな乖離」ではなかったが、機能として正当な入力を拒否している状態だった。

**追補修正:** 判定を「フラグの字面（`--` + 英字始まり + 英数字/ハイフンのみで構成される1語）」に絞り込んだ正規表現 `/^--[A-Za-z][A-Za-z0-9-]*$/` に変更した。

```js
// OK: フラグの字面（1語・英字始まり）だけを未知フラグとして扱う
const UNKNOWN_FLAG_RE = /^--[A-Za-z][A-Za-z0-9-]*$/;
for (let i = 0; i < rest.length; i++) {
  const tok = rest[i];
  if (tok === '--body' && i + 1 < rest.length) { bodyOpt = rest[i + 1]; i++; }
  else if (tok === '--body-file' && i + 1 < rest.length) { bodyFileOpt = rest[i + 1]; i++; }
  else if (UNKNOWN_FLAG_RE.test(tok)) {
    process.stderr.write(`${usage}\nError: unknown flag: ${tok}\n`);
    process.exit(1);
  }
}
```

この線引きにより、`--boddy-file`（タイポ）は引き続きエラーになる一方、`--` の直後がハイフン（Markdown水平線）や空白・非英字文字（`"--body を説明する文章"`）のトークンは本文として扱われる。「フラグは1語で英字始まり」という自明な性質を使った判定で、未知フラグ検出の実効性（元事故の再発防止）は維持したまま誤検知を解消した。

後方互換のため、フラグが一切ない場合は従来どおり `rest[0]`（第2トークン全体）を本文として使う。単一ハイフンで始まる本文（例: `"- 箇条書き"`）は正規表現が `--`（2文字）始まりのみを対象にしているため誤ってフラグ扱いされない。位置引数とフラグを同時指定した場合はフラグが優先され位置引数は無視される（意図した仕様として回帰テストで固定）。

**対象ファイル:** `todo-engine.js`（`runComment()`、`help.comment` ja/en）

**テスト:** `tests/run-tests-write.sh` §W26（32ケース: `--body-file` 実ファイル反映＋元事故の再現確認、`--body` 反映、併用時の優先順位、存在しないパスのエラー、未知フラグのエラー（直接再現）、値欠落フラグのエラー、位置引数の後方互換、単一ハイフン始まり本文の境界確認、テキスト省略時の既存挙動、Markdown水平線・「--body」で始まる本文が誤ってフラグ扱いされないことの回帰確認、位置引数+フラグ同時指定時の仕様固定）。全1445件PASS（書き込み系539/539）。実 GitHub API への書き込みは行わず、スタブ経由のみで検証した（本コマンドは本番 Issue へのコメント投稿という不可逆の副作用を持つため）。

### 2026-09-01: `add` が未知フラグを黙ってタイトルへ連結していた（Issue #1921 パターンA）

**症状:** `add next "設計書を書く" --boddy-file /tmp/body.txt` のようにフラグ名をタイプミスすると、エラーも警告も出ないまま `設計書を書く --boddy-file /tmp/body.txt` というタイトル・本文空の Issue が **exit 0** で作られていた。#1919（`comment`）とまったく同じ構造で、失われるもの（本文）・混入するもの（フラグ名とその値）・exit code（0）まで一致する。

**原因:** `parseArgs()` が解釈できなかったトークンは `result.extra` に落ちる。`runAdd()` はその `extra` をフィルタして空白区切りで連結したものをタイトルにしていたため、未知フラグがそのままタイトルの一部になっていた。

```js
// NG: extra に残った `--boddy-file` も `/tmp/body.txt` もタイトルへ素通りする
const parsed = parseArgs(tokens);
const titleTokens = parsed.extra.filter(s => s.trim());
const title = titleTokens.join(' ');
```

同じ経路で以下も混入していた（いずれも修正前コードで実測）。

| 入力 | 修正前の実測結果 |
|---|---|
| `add next "タイトル" --due`（値欠落。`parseArgs` の `i+1 < remaining.length` を満たさない） | exit 0 / title `タイトル --due` |
| `add next "タイトル" --p4`（`/^--p[123]$/` の境界外） | exit 0 / title `タイトル --p4` / priority は既定の p3 のまま |
| `add next " " --foo`（空白トークン + 未知フラグ） | exit 0 / title `--foo` |

**修正:** #1919 で `runComment()` に導入した判定を `findUnknownFlag(tokens, allowedFlags)` としてモジュールスコープへ切り出し、`runAdd()` が `parseArgs()` の直後に1回呼ぶようにした。未知フラグを検出したら Usage 行・エラー本文・ヒント行を stderr へ出して `exit 1` する。

```js
// OK: 未知フラグはタイトルにせず、API 副作用の前に落とす
const parsed = parseArgs(tokens);
const unknownFlag = findUnknownFlag(parsed.extra, []);
if (unknownFlag) {
  process.stderr.write(`${ADD_USAGE}\n`);
  process.stderr.write(tpl('error.unknown_flag', { flag: unknownFlag })+'\n');
  process.stderr.write(t('error.unknown_flag_hint')+'\n');
  process.exit(1);
}
```

**検査位置の制約（2点。どちらも満たさない配置は不可）:**

1. `error.title_empty`（タイトル空チェック）**より前**。`add next --boddy-file` のようにフラグしか渡されなかった場合、「タイトルが空です」より「不明なフラグです: --boddy-file」の方が原因に直結する。`titleTokens` が空になるのは extra が空か空白のみのときで、そのとき未知フラグは定義上存在しないため、この順序で `title_empty` が出なくなるケースは生じない（`add next " " --foo` で実測確認）
2. `ensureLabel()`（コンテキストラベル作成）**より前**。バリデーションを API 副作用より後に置くと、エラーで落ちる前にラベル作成の API 呼び出しが発生する（`resume_condition` 実装時と同じ教訓）。`parseArgs()` の直後に置けば自動的に満たされる

**`allowedFlags` 引数について:** パターンA（`runAdd`）では常に空配列を渡すが、シグネチャには最初から持たせてある。`runList()` のように `parseArgs()` の後で `extra` から `--group` / `--no-due` / `--no-estimate` を自前に読むハンドラがあり、許可リストなしで同じ検査を適用すると正常な入力が壊れるため。**許可リストは `parseArgs()` の内部ではなく呼び出し側に置くこと**（ハンドラごとに「extra に正当に残るフラグ」が異なる）。

**実装時に踏んだ落とし穴（Temporal Dead Zone）:** 判定用の正規表現定数 `UNKNOWN_FLAG_RE` を設計どおり `parseArgs()` の直前に `const` で置いたところ、診断サブコマンド `find-unknown-flag` を実行すると `ReferenceError: Cannot access 'UNKNOWN_FLAG_RE' before initialization` で落ちた。本ファイルはメインの `switch` ディスパッチャを**モジュール評価の途中**（`parseArgs()` の定義行より前）で実行するため、利用側の関数宣言は巻き上げられても `const` は初期化前（TDZ）だったのが原因。既存の診断サブコマンドで問題が表面化していなかったのは、参照先が関数宣言（巻き上げられる）か、あるいは `const` であってもファイル冒頭の定数ブロックに置かれていたため（例: `case 'gtd-label'` は冒頭の `GTD_DISPLAY` を直接参照している）。「参照先がすべて関数宣言だから安全」ではない。対処として `UNKNOWN_FLAG_RE` をファイル冒頭の定数ブロックへ移し、同所に「ここから動かさないこと」の理由をコメントで残した。

**教訓:** 本ファイルで**モジュールスコープの `const` を新設し、それを診断サブコマンド（トップレベル `switch` 内）から間接的にでも参照する**場合、宣言はファイル冒頭の定数ブロックに置くこと。関数宣言と違い `const`/`let` は巻き上げられても初期化されない。

**中間状態（意図したもの・次工程への申し送り）:** 本修正で `add` のエラーメッセージは ja/en 対応（`error.unknown_flag` / `error.unknown_flag_hint`）になったが、`comment`（#1919）は英語ハードコードのまま残している。既存テスト §W26-5 が日本語モードで `unknown flag: --boddy-file` をアサートしており、`comment` 側を i18n 化すると FAIL するため。文言の統一は、このアサーション更新と同一の変更でまとめて行うこと。→ **2026-09-02（下記の第2弾）で解消済み**。`runComment()` を `guardUnknownFlag()` へ寄せ、W26-5 のアサーションを ja 文言へ更新した。

**対象ファイル:** `todo-engine.js`（新設 `UNKNOWN_FLAG_RE` / `findUnknownFlag()` / `ADD_USAGE` / 診断サブコマンド `find-unknown-flag`、`runAdd()` への配線、`MESSAGES` ja/en 2キー、`help.add` ja/en、`runComment()` のローカル定数削除）、`todo.md`

**テスト:** `tests/run-tests.sh` §51（判定器の単体テスト20件: 正常系・許可リスト・入力文字パターン・境界値・500要素のパフォーマンス）+ `tests/run-tests-write.sh` §W27（`add` の振る舞いテスト71件: 正常系5・異常系・i18n・入力文字パターン・境界値・セキュリティ・200トークンのパフォーマンス）。全1536件PASS（書き込み系610/610）。追加したガードを一時的にコメントアウトして実行し、異常系ケース（未知フラグ・値欠落フラグ・存在しないフラグ・副作用ゼロ・メッセージ優先順位・境界値）が確実に FAIL することを実測で確認した。この確認過程で「ガードを外しても PASS したままのアサーション」が6件見つかったため（成功時の出力にもフラグ名の字面が現れるため、フラグ名の部分一致では検証にならなかった）、エラーメッセージ全文での判定に書き換えている。`runComment()` のローカル定数削除が無害であることは、§W26 全32件が無変更で PASS すること（削除前後で同数）を実測して確認した。GitHub への実書き込みは行わず、スタブ経由のみで検証した。

### 2026-09-02: 13コマンドが未知フラグを黙って捨てていた（Issue #1921 パターンB・C）

**症状:** #1921 パターンA（`add`）と同じ「静かな期待値乖離」が、`add` 以外の13コマンドに残っていた。症状は3種類に分かれる。

| 型 | 例 | 修正前の挙動 |
|---|---|---|
| (a) 指定した値が黙って捨てられる | `due 42 2026-09-10 --note "理由"` | exit 0。`--note` は無視され、コメントは投稿されない |
| (b) フィルタが黙って無視される | `list next --no-duee` | exit 0。タイプミスに気づけないまま全件表示される |
| (c) 自由記述へ混入する | `template use daily --boddy-file /tmp/x` | exit 0。タイトル「--boddy-file /tmp/x」のゴミ Issue が作られる |
| (c) 自由記述へ混入する | `rename 42 --boddy-file /tmp/x` | exit 0。**既存タイトルがフラグ名で上書きされて失われる** |
| (c) 自由記述へ混入する | `desc 42 --boddy-file /tmp/x` | exit 0。説明欄にフラグ名が追記される |

`rename` は `add` と違い**元の値が復旧できない**（`add` は新規 Issue なので消せばよい）ため、実害はパターンA より大きい。

**原因:** 引数の読み方が3系統に分かれており、どれも余りを捨てていた。

1. `parseArgs()` を呼ぶハンドラ（`list` / `done` / `move` / `edit` / `label add` / `template save` / `bulk done`）は `parsed.extra` を一切見ていなかった
2. `parseArgs()` を通らず固定インデックスで読むハンドラ（`due` / `recur` / `link` / `priority` / `label delete,rename` / `template list,show,save from,delete` / `bulk move,priority`）は `tokens.slice(2)` 以降を捨てていた
3. `tokens.slice(1).join(' ')` で自由記述を作るハンドラ（`rename` / `desc` / `template use`）は、フラグ字面をそのまま値にしていた

**修正:** #1921 パターンA で導入した `findUnknownFlag()` の上に、出力を1箇所に集約する薄いラッパを新設し、**26箇所へ新たに配線した**（`runAdd` / `runComment` の既存実装2箇所の置き換えを含めると、`guardUnknownFlag()` の呼び出しは**合計28箇所**。`grep -c 'guardUnknownFlag('` の実測値）。

```js
// 未知フラグを検出したら Usage・エラー本文・ヒント行を出して終了する
function guardUnknownFlag(tokens, allowedFlags, usage, hintKey) {
  const flag = findUnknownFlag(tokens, allowedFlags);
  if (!flag) return;
  if (usage) process.stderr.write(`${usage}\n`);
  process.stderr.write(tpl('error.unknown_flag', { flag })+'\n');
  process.stderr.write(t(hintKey)+'\n');
  process.exit(1);
}
```

**設計上の判断（4点。いずれも意図的で、変更するとテストが FAIL する）:**

1. **判定は「フラグ字面のトークンだけ」に保つ**。「余りが1つでもあればエラー」にしてはいけない。`list` は GTD 名・`p1`-`p3`・`project` + 番号が位置引数として `extra` に正当に残る唯一のハンドラで、これを壊す（テストで固定: §W28-4）。位置引数の余剰（`due 42 今週 金曜` 等）も従来どおり通す（§W28-19b）
2. **許可リストが空でないのは `list` の1ハンドラだけ**（`['--group','--no-due','--no-estimate']`）。ハンドラ本体の `if (tok === '--group')` 分岐と**同じ字面・同じ順序**に保つこと。`--json` は許可リストに入れない（`runList` が `parseArgs` より前に除去するので `extra` に届かない。入れても無害だが「なぜここだけ二重防御か」が読めなくなる）
3. **`bulk tag` / `bulk untag` には入れない**。`normalizeTagTokens()`（#1686）が既に `-` 始まりトークンを `error.option_like_token` で落としており、guard を足すとメッセージが変わる（§W28-27 で固定）
4. **ヒント行はコマンドの性質で3種類に分ける**。`error.unknown_flag_hint`（タイトル向け: `add` / `rename` / `template use`）/ `error.unknown_flag_hint_body`（本文向け: `comment` / `desc`）/ `error.unknown_flag_hint_options`（自由記述なし: その他）。`add` 向けのヒントは「タイトル」に言及しているため `move` や `due` に流用してはいけない（§W28-24 で誤配線を反証）

**サブコマンドを持つハンドラの注意:** `label` / `template` / `bulk` は「ハンドラ冒頭で1回呼べば足りる」構造では**ない**。サブコマンドごとに消費するトークン範囲が違う（`parseArgs` / 固定インデックス / `join(' ')` が同一ハンドラ内に混在する）ため、分岐ごとに配線する必要がある。許可リストは全サブコマンドで空。

**「位置1は既存バリデータが loud に落とす」という一般化はハンドラによって成立しない（レビュー指摘で判明）:** 設計時は `due` / `recur` / `link` / `priority` の4ハンドラで「位置1（`tokens[1]`）にフラグ字面が来ても `validateDue` / `validateRecur` / `parseInt` / `validatePriority` が既にエラーにする」ことを確認し、これを全ハンドラへ一般化していた。**`label` / `template` では成立しない**。ファイル冒頭の `FORBIDDEN_CHARS`（`` ;$`()"'\|&><{} ``）に**ハイフンが含まれない**ため、`validateCtx('--foo')` も `validateName('--foo')` も通ってしまう。実測（スタブ経由）で確認した抜け:

| 入力 | ガード追加前の挙動 |
|---|---|
| `label add --boddy-file` | exit 0。GitHub 上に `@--boddy-file` というゴミラベルを作る（手動削除が必要） |
| `label delete --foo` | exit 0。`issues.deleteLabel` に到達する |
| `label rename --foo new` / `label rename old --bar` | exit 0。**実在ラベルの削除 + ゴミラベルの作成**という不可逆な組み合わせ |
| `tag rename --foo new` / `tag rename old --bar` | 同上（`label rename` と同じ共通関数 `renameCtxLabel` を呼ぶ第2の入口。実害が同一） |
| `template save --foo next` | exit 0。ローカルの `todo-templates.json` に `--foo` エントリを書き込む |
| `template show --foo` / `template delete --foo` / `template use --foo` | exit 0（`use` は該当テンプレートが実在すればゴミ Issue を作る） |

このため `label add` / `template save` / `template use` は名前の位置を単独で検査し、`label delete` / `label rename` / `template show` / `template delete` は検査対象を `slice(2)`・`slice(3)` から **`slice(1)`** へ広げて名前の位置を含めている。**共通関数を複数のコマンドが呼ぶ場合は、ガードを呼び出し元ではなく共通関数側に置く**: `renameCtxLabel` は `label rename` と `tag rename` の2経路から呼ばれるため、`runLabel` 側だけを塞ぐと `tag rename` が素通りする。関数冒頭で `[raw1, raw2]` を検査して両経路を1箇所で塞いだうえで、`runLabel rename` 側の `slice(1)` ガードは**残している**（`renameCtxLabel` は raw1 / raw2 しか受け取らず、余剰トークンが見えないため。守備範囲が違うので両方必要）。**引数の位置ごとの挙動を表にするときは、確認したハンドラと未確認のハンドラを混ぜないこと**。今回の抜けは、4ハンドラでの確認結果を残り全部へ広げたことが原因だった。

**`runBulk done` の `parseArgs` 巻き上げ:** 従来 `parseArgs(rest)` は per-issue ループの**内側**で N 回呼ばれていた。`rest` はループ内で再代入されず、`parseArgs` は先頭で入力配列をコピーする純粋関数なので、ループ外へ移しても結果は同一（§W2 / §W16 の bulk 系が無変更で PASS することで実測確認）。巻き上げることで、未知フラグ検査を「1件目の API 呼び出しより前」かつ「`bulk.item_error` の集計ロジックの外」に置ける（per-item エラーとして握りつぶされない）。

**テスト:** `tests/run-tests.sh` §51 に2件追加（許可リストが**完全一致**判定であることの固定。将来 `indexOf` を前方一致へ書き換えると `--groupp` が通ってしまう）+ `tests/run-tests-write.sh` §W26 を更新（`comment` の i18n 統一に伴い W26-5 のアサーションを ja 文言へ。W26-5c/5d を追加）+ **§W28 を新設**（200アサーション）。全1,747件PASS（書き込み系819/819）。GitHub への実書き込みは行わず、スタブ経由のみで検証した。`label` / `template` 系のケースは**隔離 HOME**（`mktemp -d` した一時ディレクトリを `HOME` に差し替える）で実行しており、実 HOME の `~/.claude/todo-templates.json` には触れない。**このセクションのケースを手で再現するときも必ず隔離 HOME を使うこと**（`template save <name>` は実 HOME のテンプレートファイルを書き換える。レビュー時に実際に踏んで手動復旧が必要になった）。

**ガード除去による回帰検出で見つけた罠（テストを書く人向け）:** 追加した全ガードを一時的に無効化して実行し、異常系ケース全件が FAIL することを実測した。この過程で「ガードを外しても PASS したままのアサーション」が1件見つかり書き換えている（`edit 42 --priorityy p1` に対する `issues.addLabels` 0回の確認。`--priorityy` は `parseArgs` に消費されないので `parsed.priority` は null のままで、ガードの有無に関わらず `addLabels` は元々0回だった → API ログ全体が0行、で判定するよう修正）。同種の罠は3つある。

1. **成功時の出力にもフラグの字面が出る**: フラグ名の部分一致で assert すると、ガードを外して成功したときも PASS する。**必ずエラーメッセージ全文で判定する**
2. **スタブ応答不足で「別の理由で」失敗する**: 応答を用意せずに異常系だけ書くと、ガードの有無に関わらず例外で落ちて `assert_exit_fail` が常に PASS する。**対になる正常系で exit 0 を確認した応答を使い回す**こと（§W28 では `link` / `rename` / `desc` について、同じ応答でフラグなしなら exit 0 になることを W28-21b / 22c / 22e として明示的に固定している）
3. **副作用ゼロの確認を「特定メソッドの回数」で書く**: 上記の W28-12b がこれ。そのメソッドがそもそも呼ばれない入力だと検証にならない。**API ログ全体の行数が0であること**で判定するほうが壊れにくい。同じ罠は W28-31（`label add` の `issues.createLabel` が0回）でも踏みかけた。`ensureLabel()` は GET が 200（＝ラベル既存）を返すと `createLabel` に到達しないため、既存ラベルを返すスタブのままだと「0回」がガードの有無に関わらず成り立つ。GET が **404 を throw する**スタブ（`{"__throw":true,"status":404}`）へ差し替え、対になる正常系（W28-31b）で `createLabel` が実際に1回呼ばれることを確認したうえで「0回」を検証している

**アサーション粒度で残る例外（3件。意図的）:** ガード除去実験ではケース単位で見れば異常系は1件の例外もなく FAIL するが、**アサーション単位では W28-23 の `assert_no_japanese` と W28-24 の `assert_not_contains` ×2 が PASS したまま残る**（成功時の英語出力にも日本語は含まれず、成功時の出力にもタイトル向け・本文向けのヒント文言は現れないため）。この3つが見ているのは「ガードが存在すること」ではなく「ガードが発火したときの出力の i18n / ヒントキーの配線」という別の性質で、ガードの存在自体は同じケース内の `assert_exit_fail` と `assert_contains`（エラー全文）が担保している。**回帰検出器として読み替えないよう、テストコード側にも同趣旨の注記を置いてある**。§W26 側にも同型が4件ある（`runComment` はガードを外すと「本文が空」で別経路の exit 1 になるため）。

**対象ファイル:** `todo-engine.js`（新設 `guardUnknownFlag()`、`MESSAGES` ja/en 2キー、`help.unknown_flag_note` ja/en とその出力配線、`runAdd()` / `runComment()` の共通ヘルパーへの置き換え、`runList` / `runDone` / `runMove` / `runEdit` / `runDue` / `runDesc` / `runRecur` / `runLink` / `runRename` / `runPriority` / `runLabel`×5 / `runTemplate`×8 / `runBulk`×3 への配線、`runBulk done` の `parseArgs` 巻き上げ、`label` / `bulk` に残っていた旧 `Usage: run ...` 4本を各コマンドの Usage 定数へ差し替えて1コマンド1本に統一）、`todo.md`

### 2026-09-05: 8ハンドラが「別コマンドでは有効だが自分は読まないフラグ」を黙って捨てていた（Issue #1934 パート1）

**症状:** #1921 パターンB・C（上記）が塞いだのは「`parseArgs()` が解釈できなかったトークン（`parsed.extra`）」だけで、「`parseArgs()` は正しく消費したが、そのハンドラ自身が読まないフィールド」という**第3の型**は塞げていなかった。`parseArgs()` が消費する17種の値付きフラグ（`--due` / `--desc` / `--recur` / `--project` / `--priority` / `--estimate` / `--actual` / `--due-offset` / `--color` / `--activate` / `--before` / `--depends-on` / `--resume-condition` / `--note` / `--body` / `--body-file` / `--label`）のうち、各ハンドラは一部しか読まない。読まないフラグは `parsed.<field>` に値として残るが `extra` には現れないため、`findUnknownFlag()` の対象にならず、エラーも警告も出さずに値だけが消える（いずれも exit 0）。

| 入力 | 修正前の挙動 |
|---|---|
| `add next "テスト" --note "メモ"` | exit 0。`--note` は捨てられ、コメントは投稿されない |
| `add next "テスト" --actual 3h` / `--color FF0000` / `--due-offset 3` | exit 0。いずれも黙って無視される |
| `edit 42 --note "メモ"` | exit 0。`--note` は捨てられる |
| `list --due 2026-09-10` | exit 0。フィルタが効かず全件表示される |

**原因:** `parseArgs()` を呼ぶハンドラは8つ（`runAdd` / `runList` / `runDone` / `runMove` / `runEdit` / `runLabel`の`add`分岐 / `runTemplate`の`save`インライン分岐 / `runBulk`の`done`分岐）。各ハンドラは `parsed.<field>` のうち一部しか読まないコードになっており（例: `runList` は `parsed.contexts`/`parsed.tags` しか読まず17フラグは全滅、`runMove` は `parsed.note` しか読まない）、「読まれなかった残り」を検出する仕組みがなかった。

**修正:** ハンドラ単位で「実際に読むフィールド」を明示し、それ以外が指定されたらエラー化する `guardUnsupportedFlag()` を新設した。

```js
// フィールド名 → 代表フラグ表記（エラーメッセージ用）
const FLAG_FIELD_MAP = {
  due: '--due', desc: '--desc', /* ...17種... */ labels: '--label',
};
// フィールド名 → それを実際に読むコマンドの一覧（ヒント用）
const FLAG_SUPPORTED_BY = {
  note: ['done', 'move'], actual: ['done', 'bulk done'], /* ... */
};
// parsed のうち supportedFields に載っていないフィールドで値が設定されているものを探す（純粋関数）
function findUnsupportedFlagField(parsed, supportedFields) { /* ... */ }
// 検出したら Usage・エラー本文・ヒントを出して終了する
function guardUnsupportedFlag(parsed, supportedFields, usage) { /* ... */ }
```

各ハンドラで、既存の `guardUnknownFlag(...)` 呼び出しの**直後**に `guardUnsupportedFlag(parsed, [...], USAGE)` を1行追加した（呼び出し順序は「typo検出 → 対象外検出」に統一）。8ハンドラの `supportedFields` は配線直前に実装コードを再読して確定した（設計書の実測表と1件も食い違いなし）。

**設計上の判断（3点）:**

1. **`guardUnknownFlag()` の `allowedFlags`（トークン文字列の許可リスト）とは判定対象がまったく逆**。`guardUnsupportedFlag()` の `supportedFields` は `parsed` のフィールド名（`parseArgs()` が既に消費した側）を扱う。変数名で区別する（`*_ALLOWED_FLAGS` はトークン文字列配列、本設計の引数は `parsed` のキー名配列）
2. **エラー（exit 1）に倒す**。誤検知（本来使いたいのに拒否される）はほぼ発生しない（17フラグは全て正式な綴りで、拒否されるのは「そのハンドラでは元々効かなかった」場合のみ）。見逃し（黙って値が消える）の実害の方が大きい
3. **typo（`error.unknown_flag`）と対象外（新設 `error.flag_not_supported`）はメッセージキーを分離**。「`--note` は `add` にとって『不明』ではなく『対象外』」という区別を伝えるため

**実装時に見つけた設計書との差分（診断サブコマンドのバグ）:** 設計書のサンプルコード `find-unsupported-flag` は、指定しなかったフィールドを `dummyParsed[f]` に代入しないままにしていたため `undefined` となり、`findUnsupportedFlagField()` の `isSet` 判定（`val !== null`）が「`undefined !== null` は true」で常に検出してしまうバグがあった（§52 実測で発見。設計書のサンプルコードのままでは動かない）。`Object.keys(FLAG_FIELD_MAP)` で全フィールドを `null`（`labels` のみ `[]`）に初期化してから `setFields` の値で上書きするよう修正した。

**自己申告の実測結果（設計書「自信が持てない箇所」への回答）:**

- **`--due-offset` の `+` 単独入力**: `parseArgs()` 内部の `.replace(/^\+/, '')` により空文字列になる（実測: `'+'.replace(/^\+/, '') === ''`）。空文字列は `isSet` 判定で「指定された」とみなされるため、`add`（`--due-offset` 非サポート）に渡すと正しく検出される（W29-15b で固定）
- **サポート対象＋未サポート混在時の部分適用**: `edit 42 --due 2026-09-10 --note "x"` で実測。ガードは `parsed` 全体を検査してから `exit 1` する設計どおり、`--due` は適用されず（`issues.update` 0回）、エラーは `--note` のみを報告する（W29-14）

**テスト:** `tests/run-tests.sh` に判定器の単体テスト §52（15アサーション: 正常系・異常系・境界値・パフォーマンス）、`tests/run-tests-write.sh` に8ハンドラの振る舞いテスト §W29（64アサーション: 異常系11・境界値5（W29-15b含む）・i18n2・正常系8の26ケース、他はエラー全文・API呼び出し0回の確認）を新設した。追加した8箇所のガードを一時的に無効化して実行し、異常系14ケース（W29-1〜11・W29-13〜15）が全件確実に FAIL することを実測で確認した（§W28 と同型の回帰検出。W29-16 の `assert_no_japanese` のみ、ガード除去後の英語成功メッセージにも日本語が含まれないため PASS したまま残るが、これは同じケース内の `assert_exit_fail`/`assert_contains` が担保する範囲外の性質であり§W28-23と同型の既知の例外）。全1,826件PASS（書き込み系883/883）。GitHub への実書き込みは行わず、スタブ経由のみで検証した。

**対象ファイル:** `todo-engine.js`（新設 `FLAG_FIELD_MAP`/`FLAG_SUPPORTED_BY`/`findUnsupportedFlagField()`/`guardUnsupportedFlag()`/診断サブコマンド `find-unsupported-flag`、`MESSAGES` ja/en 2キー追加、`help.unknown_flag_note` 更新、`runAdd`/`runList`/`runDone`/`runMove`/`runEdit`/`runLabel`の`add`分岐/`runTemplate`の`save`インライン分岐/`runBulk`の`done`分岐への配線）、`todo.md`（共通注記・`add`行の更新）、`CHANGELOG.md`

### 2026-09-05: `@ctx` / `#tag` にも「読まれない位置トークンが黙って消える」同型問題が残っていた（Issue #1934 パート1.5）

**症状:** パート1（上記）が塞いだのは17種の値付きフラグのみで、`@ctx`/`#tag`（`parseArgs()` が消費する位置トークン。フラグではない）には同型の問題が残っていた。`done` / `move` / `edit` / `label add` / `bulk done` はいずれも `parsed.contexts`/`parsed.tags` を一切読んでおらず、`@ctx`/`#tag` を渡しても値が黙って消えていた（`add`/`list` は元から両方読んでいる）。

| 入力 | 修正前の挙動 |
|---|---|
| `done 42 @外出` | exit 0。`@外出` は無視される |
| `move 42 next #tag` | exit 0。`#tag` は無視される |
| `label add newctx @office` | exit 0。`@office` は無視される（名前 `newctx` のみでラベル作成） |
| `bulk done 41 42 @office` | exit 0。`@office` は無視される |

**原因・修正:** パート1と完全に同じ枠組みで対応した。`FLAG_FIELD_MAP` に `contexts`（代表表記 `@ctx`）/`tags`（代表表記 `#tag`）を追加し、`guardUnsupportedFlag()` の走査対象を17→19フィールドへ拡張した。8ハンドラの `supportedFields` へ配線する直前に実装コードを再確認したところ、以下の実測表になった（○=読む/✗=読まない）。

| フィールド | add | list | done | move | edit | label add | template save(inline) | bulk done |
|---|---|---|---|---|---|---|---|---|
| `contexts`（@ctx） | ○ | ○ | ✗ | ✗ | ✗ | ✗ | ○ | ✗ |
| `tags`（#tag） | ○ | ○ | ✗ | ✗ | ✗ | ✗ | **✗** | ✗ |

**実装時に見つけた非対称:** `runTemplate` の `save` インライン分岐は `const contexts = parsed.contexts;` で `contexts` を読んで `validateCtx` するが、`parsed.tags` はこの分岐のどこからも読まれていない（実装コードを直接確認して判明）。`runList` は `contexts`/`tags` の両方を3806-3807行で読んでいるため `supportedFields` に `['contexts','tags']` を追加した。この `template save` の非対称（`@ctx` は使えるが `#tag` は使えない）を tags 側の実装を直して解消するかはスコープ拡大の判断になるため実装せず、`contexts` のみを `supportedFields` に追加し `#tag` は引き続きエラーとする現状を維持した（`template save tmpl next #tag` は「黙って消える」から「使えませんエラー」に変わるだけで、実害が増える方向ではない）。

**後方互換:** 呼び出し元リポジトリ全体の grep 全数調査で `done`/`move`/`edit`/`label add`/`bulk done`/`template save` に `@ctx`/`#tag` を渡す実呼び出しは1件も見つからなかった。

**テスト:** `tests/run-tests.sh` §52 に4アサーション追加、`tests/run-tests-write.sh` §W29 パート1.5 に12ケース・37アサーションを新設した（異常系7: done/move/edit/label add/bulk done への `@ctx`・`#tag`、`template save` の `#tag` 非対称／境界値1: label add への `#tag`／i18n1: 英語モード／正常系3: add・list・template save の既存サポートが壊れていないことの回帰確認。合計12ケース。レビュー指摘によりパート1と同型の内訳計算不一致を修正: 2026-09-05）。追加したガード拡張（`FLAG_FIELD_MAP` の `contexts`/`tags` 追加）を一時的に無効化して実行し、異常系ケース全件（12ケース中の異常系・境界値部分）が確実に FAIL することを実測で確認した（正常系3件と `assert_no_japanese` 1件のみ、成功時の出力にも日本語やフラグ字面が現れないため無効化後もPASSしたまま残る。パート1の§W29-16と同型の既知の限界）。全1863件PASS（書き込み系916/916）。GitHub への実書き込みは行わず、スタブ経由のみで検証した。

**対象ファイル:** `todo-engine.js`（`FLAG_FIELD_MAP`/`FLAG_SUPPORTED_BY` に `contexts`/`tags` 追加、診断サブコマンド `find-unsupported-flag` のダミー初期化を配列フィールド対応に拡張、`runAdd`/`runList`/`runTemplate`の`save`インライン分岐の `supportedFields` 更新、`help.unknown_flag_note` ja/en 更新）、`todo.md`（共通注記更新）、`CHANGELOG.md`

### 2026-09-05: `runList` の `extra` ループにあった `@` 分岐を削除（`#` 分岐は削除せず）（Issue #1934 パート3）

**背景（Issueの記述と実測の差分）:** Issue #1934 の当初の記述は「`runList` の `extra` 走査ループにある `@` 始まり / `#` 始まり両方の分岐が到達不能なデッドコード」としていたが、実測の結果これは**半分だけ正しい**ことが判明した。

- **`@` 分岐: 到達不能（真のデッドコード）**。`parseArgs()` の `@` トークン消費条件（`tok.startsWith('@')`）には追加条件が一切なく、`@` で始まるトークンは無条件に `parsed.contexts` へ吸収されるため、`extra` ループへ到達すること自体が構造的に不可能。
- **`#` 分岐: 到達可能（デッドコードではない）**。`parseArgs()` の `#tag` 消費条件は `tok.startsWith('#') && !tok.includes(' ') && !/^#\d+$/.test(tok)` の3条件（`#1660` で追加された「空白を含まない」制約を含む）。一方 `runList` の `#` 分岐の条件は `tok.startsWith('#') && !/^#\d+$/.test(tok)` の2条件のみで「空白を含まない」制約がない。したがって**空白を含む `#` トークン**（例: `list "#1299 depends-on強化について"`）は `parseArgs()` に消費されず `extra` に残り、`runList` の `#` 分岐へ到達する。実測（`node todo-engine.js run list "#1299 depends-on強化について"`）で `エラー: タグ名に不正文字が含まれています`（`validateTag()` が空白を検出して exit 1）を確認した。Issueの「分岐側の条件でも除外されるため何もしない」という記述は、`#42` のような**純粋な数字トークン**（`#` 分岐自身の `!/^#\d+$/` 条件で除外され、実測でも exit 0・フィルタなし全件表示を確認）にのみ正しく、**空白入りトークンを見落としていた**。

**対応:** `@` 分岐のみを削除し、`#` 分岐は削除せず維持した（削除すると「空白入り `#` トークンでエラー終了する」という現在の挙動が「黙って無視される」に変わってしまうため。挙動変更はスコープ拡大の判断になるため今回は削除しない）。削除前後で `list @--`（parsed.contexts経由でのエラー）・`list @office`（正常フィルタ）・`list "#1299 ..."`（空白入りタグのエラー）・`list "#42"`（数字のみタグ、無視）の4パターンすべてが同一の挙動であることを実測で確認した。

**テスト:** `tests/run-tests-write.sh` に §W30（4ケース・5アサーション）を新設し、上記4パターンを回帰・固定した。全1869件PASS（書き込み系922/922）。

**対象ファイル:** `todo-engine.js`（`runList()` の `extra` ループから `@` 分岐を削除、削除理由と `#` 分岐を残す理由を説明するコメントを追加）

### 2026-09-05: 固定インデックス型ハンドラの位置引数の余剰・`search`/`archive search` のフラグ字面混入（Issue #1934 パート2・パート4、完了）

**症状（パート2）:** `due` / `recur` / `link` / `priority` は `tokens[0]=番号 / tokens[1]=値` の固定インデックスで読むため、値の直後に残った非フラグの位置引数（クォート漏れ・値の指定過多）は `guardUnknownFlag()`（フラグ字面のみを検査）の対象外で、従来黙って捨てられていた。

| 入力 | 修正前の挙動 |
|---|---|
| `due 42 2026-09-10 余剰トークン` | exit 0。「余剰トークン」は黙って捨てられ、期日は `2026-09-10` になる |
| `recur 42 weekly 予備` | exit 0。「予備」は無視される |
| `link 42 100 101` | exit 0。project番号は `100` のみ登録され「101」は無視される |
| `priority 42 p1 p2` | exit 0。優先度は `p1` のみ設定され「p2」は無視される |

**前提条件（Issue記載の着手条件）:** 上記を塞ぐには、日本語日付を未クォートで渡す運用（`due <#> 今週 金曜` のような複数トークン）が手順書に実在しないことが前提だった。2026-09-05 に確認したところ、呼び出し側の手順書にある `due <#> 今日` 等は単一トークンのため無関係、`due <新番号> <実施日 + 周期>` はコミット `3973ff99` で `"<実施日 + 周期>"` へクォート化済みであることが判明し、着手条件が満たされた。

**修正:** `guardUnknownFlag()` / `guardUnsupportedFlag()` に続く3つ目の guard として `guardExtraPositional(extraTokens, usage, hintKey, example)` を新設した。`guardUnknownFlag()` で既にフラグ字面が弾かれた後の残余トークンが1つでもあればエラーにする。

```js
function guardExtraPositional(extraTokens, usage, hintKey, example) {
  if (!extraTokens.length) return;
  const extra = extraTokens.join(' ');
  if (usage) process.stderr.write(`${usage}\n`);
  process.stderr.write(tpl('error.extra_positional', { extra }) + '\n');
  process.stderr.write(tpl(hintKey, { example }) + '\n');
  process.exit(1);
}
```

**設計上の判断（3点）:**

1. **ヒントメッセージを2種類に分ける**。`due`/`recur` は値が自然文（日付・パターン）で空白を含みうるため `error.extra_positional_hint_quote`（「クォートしてください」＋クォート済みの実行例）、`link`/`priority` は値が単一トークンでクォートの余地がないため `error.extra_positional_hint_single`（「値は1つだけ」＋余剰を単純に落とした実行例）を使う。いずれも `example` は静的文言ではなく、呼び出し側が実際のユーザー入力（`tokens[0]`・値・余剰トークン）から動的に組み立てる（パート1の `error.flag_not_supported_hint` の `{commands}` と同じ考え方）
2. **`recur` も対象に含めた**。Issue本文は `due`/`priority`/`link` の3つのみ挙げていたが、実装コードを確認すると `recur` も完全に同型（`tokens[0]=番号 / tokens[1]=パターン`）だったため一貫性のため含めた
3. **`runUnlink`（`tokens[0]=番号 / tokens.includes('--force')`）は対象外とした**。`due`/`recur`/`link`/`priority` と違い「第2の位置引数スロット」を持たず、`--force` は任意のフラグとして走査されるだけの構造のため、`guardExtraPositional` の対象（クォート漏れ・値の指定過多）に当てはまらない。`runUnlink` には `guardUnknownFlag` 自体も配線されておらず（`--forse` のようなtypoが静かに無視される）、これは本パートとは別の独立した既存ギャップである。今回は対象外とし、完了報告で別Issue化を検討するよう申し送った

**症状（パート4）:** `search` / `archive search` は `tokens.slice(1).join(' ')`（または `--json` 除去後の `join(' ')`）でキーワードを組み立てるが、`add`/`rename`/`template use` 等の同型ハンドラと異なり `guardUnknownFlag()` が配線されておらず、フラグ字面のtypo（例: `search --keywrd foo`）が黙って検索クエリの一部に混入していた（`is:issue is:open` 等と結合され、ほぼ確実にゼロ件かつエラーなしで返る「静かな期待値乖離」）。読み取り専用で副作用がないため実害は小さいが、Issueの一貫性のため他のjoin(' ')型ハンドラと同じ `guardUnknownFlag()` を配線した。

**テスト:** `tests/run-tests-write.sh` に §W31（パート2、13ケース）・§W32（パート4、5ケース）を新設した。既存 §W28-19b（「位置引数の余剰は従来どおり通る」という後方互換の仕様固定）は本パートで挙動が反転するため `exit 0 → exit 非0` へ更新した。追加した `guardExtraPositional` 呼び出し4箇所、`guardUnknownFlag` 呼び出し2箇所（search/archive search）をそれぞれ一時的に無効化して実行し、異常系ケース（W28-19b・W31の異常系・境界値・i18n、W32の異常系・i18n）が全件確実に FAIL することを実測で確認した（`assert_no_japanese` のみ、成功時の英語出力にも日本語が含まれないため無効化後もPASSしたまま残る。パート1の§W29-16と同型の既知の限界）。W32の実装時、ガード無効化状態でスタブ応答（`search.issuesAndPullRequests`）を用意していなかったため「別の理由（スタブの未対応呼び出しエラー）」で exit 非0 になり `assert_exit_fail` が誤ってPASSする罠を踏んだ（#1921第2弾の罠2と同型）。対になる正常系と同じ応答を追加して修正し、無効化後に正しく `exit 0` へ戻ることを確認してから再固定した。全1,914件PASS（書き込み系967/967）。GitHub への実書き込みは行わず、スタブ経由のみで検証した。

**対象ファイル:** `todo-engine.js`（新設 `guardExtraPositional()`、`MESSAGES` ja/en 3キー追加、`runDue`/`runRecur`/`runLink`/`runPriority` への配線、`runSearch`/`runArchive`の`search`分岐への `guardUnknownFlag()` 配線）、`todo.md`（共通注記・`due`/`recur`/`link`/`priority`/`search`/`archive search`行の更新）、`CHANGELOG.md`

**Issue #1934 は本パートで全パート完了。**

## 翻訳方針（i18n）

`todo-engine.js` の出力は `MESSAGES`/`t()`（`LANG_ENV=en` で英語、それ以外は日本語）で管理しているが、以下の3箇所は方針として `t()` 化せず英語固定とする。新しくコマンド・出力を追加する際はこの方針に従うこと。

- **`api` サブコマンド（`apiMain`）は英語固定**: JSON を他プログラムがパースする機械向けインターフェースのため。出力言語が実行環境の `LANG_ENV` で変わるとパース側の実装が壊れるため、`t()` を通さず常に英語文字列を返す
- **`Usage:` 文字列は常時英語で統一**: コマンド構文（`Usage: /todo add <title> ...` 等）は言語非依存の情報として扱い、日本語モードでもプレースホルダを含め英語表記（`<text>` 等）のまま表示する
- **`[timing]` 診断行（`TODO_TIMING=1` 時のみ stderr へ出力）は英語固定**: 開発者・デバッグ向けの診断出力であり、一般ユーザー向けの操作結果メッセージとは性質が異なる。出力フォーマット自体が `total`/`github`/`parse`/`ms` という英語の技術語彙のみで構成されており、翻訳しても単位・キー名だけ英語が残るため翻訳する動機が薄い（Issue #455）

## 注意事項

- **本番ファイル（`~/.claude/` 配下）を直接編集しないこと**。必ずこのリポジトリのファイルを編集し、動作確認後にコピーして反映する
- セキュリティルール（`todo.md` 冒頭の7項目）は変更しないこと
- `python3` は使用不可（`node` を使うこと）
- `jq` は使用不可（`gh` の `-q` フラグか `node` を使うこと）
- GNU/BSD 両対応の日付処理を維持すること
