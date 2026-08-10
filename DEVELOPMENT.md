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
- 自動テスト総件数: **1,110件以上**（read-only系 + 書き込み系の合算。全件PASSが目安）
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

## 翻訳方針（i18n）

`todo-engine.js` の出力は `MESSAGES`/`t()`（`LANG_ENV=en` で英語、それ以外は日本語）で管理しているが、以下の2箇所は方針として `t()` 化せず英語固定とする。新しくコマンド・出力を追加する際はこの方針に従うこと。

- **`api` サブコマンド（`apiMain`）は英語固定**: JSON を他プログラムがパースする機械向けインターフェースのため。出力言語が実行環境の `LANG_ENV` で変わるとパース側の実装が壊れるため、`t()` を通さず常に英語文字列を返す
- **`Usage:` 文字列は常時英語で統一**: コマンド構文（`Usage: /todo add <title> ...` 等）は言語非依存の情報として扱い、日本語モードでもプレースホルダを含め英語表記（`<text>` 等）のまま表示する

## 注意事項

- **本番ファイル（`~/.claude/` 配下）を直接編集しないこと**。必ずこのリポジトリのファイルを編集し、動作確認後にコピーして反映する
- セキュリティルール（`todo.md` 冒頭の7項目）は変更しないこと
- `python3` は使用不可（`node` を使うこと）
- `jq` は使用不可（`gh` の `-q` フラグか `node` を使うこと）
- GNU/BSD 両対応の日付処理を維持すること
