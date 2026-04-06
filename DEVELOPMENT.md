# todo スキル 開発ガイド

## ファイル構成

```
todo-dev/
├── todo.md              ← スキル本体（編集対象）
├── todo-templates.json  ← テンプレートストレージのサンプル
├── DEVELOPMENT.md       ← このファイル
└── tests/
    ├── scenarios.md     ← テストシナリオ一覧
    └── fixtures/
        └── sample-templates.json  ← テスト用テンプレートデータ
```

## 本番ファイルの場所

| ファイル | パス |
|---------|------|
| スキル本体 | `~/.claude/commands/todo.md` |
| テンプレートDB | `~/.claude/todo-templates.json` |

## 開発フロー

1. `todo-dev/todo.md` を編集する
2. `tests/scenarios.md` のシナリオで動作確認する
3. 問題なければ `~/.claude/commands/todo.md` に上書きコピーして本番反映

```bash
# 本番への反映
cp todo-dev/todo.md ~/.claude/commands/todo.md
```

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

## 注意事項

- セキュリティルール（ファイル冒頭の7項目）は変更しないこと
- `python3` は使用不可（`node` を使うこと）
- `jq` は使用不可（`gh` の `-q` フラグか `node` を使うこと）
- GNU/BSD 両対応の日付処理を維持すること
