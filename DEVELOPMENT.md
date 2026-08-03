# todo スキル 開発ガイド

## ファイル構成

```
workspaces/skill-dev/todo/
├── todo.md              ← スキル本体（編集対象）
├── todo-templates.json  ← テンプレートストレージのサンプル
├── DEVELOPMENT.md       ← このファイル
├── scripts/
│   └── todo-engine.js   ← エンジン本体（編集対象）
└── tests/
    ├── scenarios.md     ← テストシナリオ一覧
    └── fixtures/
        └── sample-templates.json  ← テスト用テンプレートデータ
```

## 本番ファイルの場所

| ファイル | パス |
|---------|------|
| スキル本体 | `~/.claude/commands/todo.md` |
| エンジン | `~/.claude/todo-engine.js` |
| テンプレートDB | `~/.claude/todo-templates.json` |

## 開発フロー

1. `workspaces/skill-dev/todo/todo.md` または `workspaces/skill-dev/todo/scripts/todo-engine.js` を編集する
2. `tests/scenarios.md` のシナリオで動作確認する
3. レビュー完了後、本番パスにコピーして反映する

```bash
# 本番への反映
cp workspaces/skill-dev/todo/todo.md ~/.claude/commands/todo.md
cp workspaces/skill-dev/todo/scripts/todo-engine.js ~/.claude/todo-engine.js
```

## テスト

- テストランナー: `bash workspaces/skill-dev/todo/tests/run-tests.sh`
- 自動テスト総件数: **652件**（2026-07-13 時点。うち1件は本修正と無関係な既存FAILあり。詳細は「バグ修正履歴」参照）
- シナリオ一覧: `tests/scenarios.md`
- 全件 PASS が品質ゲートの必須条件
- 件数を更新する際は本ファイルの数値も合わせて更新する

## 改善アイデアの記録

改善案は GitHub Issue #51「todo.md を開発するためのプロジェクト」に登録する。

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

**対象ファイル:** `workspaces/skill-dev/todo/scripts/todo-engine.js`（`runDone()` および `nextDueCatchUp()`）

**既知の未解決事項（本修正のスコープ外）:** テストスイートに1件、本修正と無関係な既存FAIL（`§25 Report: 完了7件` — `assert_contains` の期待値パターン `**7件**` が BRE の repetition operator と衝突し `grep` がエラーを返す。`git stash` で本修正前のコードに戻しても再現するため、修正前から存在する既存バグ）。詳細は本作業のCOOへの報告を参照。

## 注意事項

- **本番ファイル（`~/.claude/` 配下）を直接編集しないこと**。必ず `workspaces/skill-dev/todo/` を編集し、レビュー後にデプロイする
- セキュリティルール（ファイル冒頭の7項目）は変更しないこと
- `python3` は使用不可（`node` を使うこと）
- `jq` は使用不可（`gh` の `-q` フラグか `node` を使うこと）
- GNU/BSD 両対応の日付処理を維持すること
