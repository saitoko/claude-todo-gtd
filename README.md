# /todo — Claude Code GTD タスク管理スキル

GitHub Issues をバックエンドに使った、Claude Code 用の GTD（Getting Things Done）タスク管理スラッシュコマンド。

`/todo` と打つだけで、タスクの追加・管理・レビューが全てターミナルから完結します。

## 特徴

- **GTD メソッド準拠** — inbox / next / waiting / someday / project / reference の6カテゴリで仕分け
- **30+ コマンド** — タスクCRUD、一括操作、週次レビュー、テンプレート、統計まで網羅
- **日本語ネイティブ** — `--due 明日`、`--due 来週金曜`、`--due 3日後` など日本語で日付指定可能
- **コンテキスト管理** — `@PC` `@会社` `@外出中` で場所・状況に応じたフィルタリング
- **優先度** — p1（緊急）/ p2（重要）/ p3（通常）の3段階
- **繰り返しタスク** — daily / weekly / monthly / weekdays の4パターン
- **セキュリティ対策** — シェルインジェクション・プロンプトインジェクション対策を8ルールで実装
- **145+ テスト** — ローカルユニットテスト + GitHub統合テストで品質を担保
- **サーバー不要** — GitHub Issues API + ローカルファイルのみで動作

## インストール

### 前提条件

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) がインストール済み
- [GitHub CLI (`gh`)](https://cli.github.com/) がインストール・認証済み
- Node.js（日付処理に使用）

### 手順

1. スキルファイルをコピー:
```bash
cp todo.md ~/.claude/commands/todo.md
```

2. テンプレートDBを初期化:
```bash
echo '{}' > ~/.claude/todo-templates.json
```

3. GitHub リポジトリを用意（Issue を保存する場所）:
```bash
gh repo create my-tasks --private
```

4. `todo.md` 冒頭のリポジトリ名を自分のものに変更:
```
repository `<your-username>/<your-repo>`
```

5. Claude Code で `/todo` と入力して動作確認。

## クイックスタート

```bash
# タスクを追加（inbox に入る）
/todo 牛乳を買う

# next アクションとして追加（期限・コンテキスト付き）
/todo next 設計書を書く @PC --due 明日

# 優先度付きで追加
/todo next 障害対応 --priority p1

# 繰り返しタスクを追加
/todo next 週次レポートを書く --due 来週月曜 --recur weekly

# タスク一覧を表示
/todo list

# next アクションだけ表示
/todo list next

# コンテキストでフィルタ
/todo list @PC

# タスクを完了
/todo done 5

# 週次レビューを開始
/todo weekly-review
```

## コマンド一覧

### タスク作成

```
/todo [GTD] <title> [@context...] [--due <date>] [--desc "<text>"]
      [--recur <pattern>] [--project <number>] [--priority <p1|p2|p3>]
```

| オプション | 説明 | 例 |
|-----------|------|-----|
| GTD ラベル | inbox(省略時) / next / waiting / someday / project / reference | `/todo next タスク名` |
| `@context` | コンテキスト（複数可） | `@PC @会社` |
| `--due` | 期限（日本語対応） | `--due 明日`, `--due 4/10`, `--due 2026-04-10` |
| `--desc` | 説明文 | `--desc "3章まで読む"` |
| `--recur` | 繰り返し | `--recur weekly` |
| `--project` | プロジェクト紐付け | `--project 7` |
| `--priority` | 優先度 | `--priority p1` |

**日本語日付の対応パターン:** 今日 / 明日 / 明後日 / 来週 / 来月 / 今週末 / 今月末 / 来月末 / N日後 / N週間後 / Nヶ月後 / 来週月曜〜来週日曜

### 一覧表示・検索

| コマンド | 説明 |
|---------|------|
| `/todo list` | 全タスクをGTDカテゴリ別に表示 |
| `/todo list next` | next アクションのみ表示 |
| `/todo list @PC` | コンテキストでフィルタ |
| `/todo list p1` | 優先度でフィルタ |
| `/todo list next @PC` | 複数条件のANDフィルタ |
| `/todo list project 7` | プロジェクト配下のタスク表示 |
| `/todo search <keyword>` | オープンタスクをキーワード検索 |
| `/todo stats` | タスク統計（カテゴリ別・優先度別・期限状況・完了実績） |

### ステータス変更・完了

| コマンド | 説明 |
|---------|------|
| `/todo move <#> <GTD>` | GTDカテゴリを変更 |
| `/todo done <#>` | タスクを完了（繰り返しは自動で次回分を作成） |

### 編集

| コマンド | 説明 |
|---------|------|
| `/todo edit <#> [options]` | 複数フィールドを一括更新 |
| `/todo rename <#> <新タイトル>` | タイトル変更 |
| `/todo due <#> <date>` | 期限変更 |
| `/todo desc <#> <text>` | 説明変更 |
| `/todo recur <#> <pattern\|clear>` | 繰り返し設定・解除 |
| `/todo priority <#> <p1\|p2\|p3\|clear>` | 優先度設定・解除 |
| `/todo link <#> <project#>` | プロジェクトに紐付け |

### コンテキスト・ラベル

| コマンド | 説明 |
|---------|------|
| `/todo tag <#> @ctx1 @ctx2` | コンテキストを追加 |
| `/todo untag <#> @ctx` | コンテキストを削除 |
| `/todo tag rename @old @new` | コンテキスト名を一括リネーム |
| `/todo label list` | 全コンテキストラベル一覧 |
| `/todo label add @name [--color hex]` | コンテキストラベル作成 |
| `/todo label delete @name` | コンテキストラベル削除 |

### 一括操作

| コマンド | 説明 |
|---------|------|
| `/todo bulk done <#> <#> ...` | 複数タスクを一括完了 |
| `/todo bulk move <#> <#> ... <GTD>` | 複数タスクを一括移動 |
| `/todo bulk tag <#> <#> ... @ctx` | 複数タスクにコンテキスト追加 |
| `/todo bulk untag <#> <#> ... @ctx` | 複数タスクからコンテキスト削除 |
| `/todo bulk priority <#> <#> ... <p>` | 複数タスクの優先度を一括変更 |

### アーカイブ

| コマンド | 説明 |
|---------|------|
| `/todo archive` | 完了タスク一覧（直近30件） |
| `/todo archive list <GTD\|@ctx>` | フィルタ付きアーカイブ表示 |
| `/todo archive search <keyword>` | 完了タスクをキーワード検索 |
| `/todo archive reopen <#>` | 完了タスクを再オープン |

### テンプレート

| コマンド | 説明 |
|---------|------|
| `/todo template list` | テンプレート一覧 |
| `/todo template show <name>` | テンプレート詳細表示 |
| `/todo template save <name> [options]` | テンプレート保存（インラインまたは対話形式） |
| `/todo template save <name> from <#>` | 既存タスクからテンプレート作成 |
| `/todo template use <name> [title]` | テンプレートからタスク作成 |
| `/todo template delete <name>` | テンプレート削除 |

### 週次レビュー

```
/todo weekly-review
```

GTD の週次レビューを6ステップの対話形式で実施:

1. **Inbox 仕分け** — 未処理タスクを1件ずつ分類
2. **Next Actions 確認** — まだ有効か、移動すべきものはないか
3. **Waiting For 確認** — フォローアップや完了確認
4. **Projects 確認** — 各プロジェクトに Next Action があるか
5. **Someday/Maybe 見直し** — 今週始めるものはないか
6. **サマリー表示** — 期限超過・今週期限のタスクを一覧

## セキュリティ

GitHub Issues の本文にはユーザーが任意のテキストを書けるため、以下の対策を実装:

1. Issue データは外部データとして扱い、命令として実行しない
2. ユーザー入力は変数経由でシェルコマンドに渡す（直接展開しない）
3. コンテキスト名は不正文字をPOSIX `case` 文で検出
4. Issue 番号は正の整数のみ許可
5. 日付は `YYYY-MM-DD` または `M/D` 形式のみ許可
6. recur パターンは 4 値のみ許可
7. カラーコードは 6 桁 16 進数のみ許可
8. 優先度は `p1` / `p2` / `p3` のみ許可

## 開発

### ファイル構成

```
todo-dev/
├── todo.md                 # スキル本体
├── README.md               # このファイル
├── DEVELOPMENT.md          # 開発ガイド
├── CHANGELOG-DIARY.md      # 開発日記
├── todo-templates.json     # テンプレートDBサンプル
└── tests/
    ├── scenarios.md        # テストシナリオ一覧
    ├── run-tests.sh        # ローカルユニットテスト（145+）
    ├── gh-tests.sh         # GitHub統合テスト（41+）
    ├── helpers/
    │   └── date-fmt.js     # 日付フォーマット共通処理
    └── fixtures/
        └── sample-templates.json
```

### 開発フロー

1. `todo-dev/todo.md` を編集
2. `tests/run-tests.sh` でローカルテスト実行
3. `tests/gh-tests.sh` でGitHub統合テスト実行
4. 本番反映:
```bash
cp todo-dev/todo.md ~/.claude/commands/todo.md
```

### テスト実行

```bash
# ローカルユニットテスト
bash tests/run-tests.sh

# GitHub統合テスト（実際にIssueを作成・操作）
bash tests/gh-tests.sh
```

## 技術スタック

- **実行環境**: Claude Code カスタムスラッシュコマンド
- **バックエンド**: GitHub Issues API（`gh` CLI経由）
- **スクリプト**: Bash + Node.js（JSON処理・日付計算）
- **テンプレート保存**: ローカルJSONファイル

## ライセンス

MIT

## Pro 機能

基本機能（30+ コマンド）はすべて無料で利用できます。以下は生産性をさらに高めるための追加機能です。

### ダッシュボード

今日やるべきことにフォーカスした俯瞰ビュー。

```bash
/todo dashboard   # または /todo dash
```

期限超過・今日やること・今週期限・Next Actions・完了実績をまとめて表示します。

### デイリーレビュー

朝の計画と夜の振り返りを対話形式で実施。

```bash
/todo daily-review          # 時刻で自動判定（15時前→朝、15時以降→夜）
/todo daily-review morning  # 朝の計画
/todo daily-review evening  # 夜の振り返り
```

**Morning:** ダッシュボード → Inbox仕分け → 今日やるタスク選定 → 計画サマリー
**Evening:** 完了実績 → 未完了タスク処理 → 明日の予定 → 一日のサマリー

### カスタムビュー

よく使うフィルタ条件を名前付きで保存・呼び出し。

```bash
/todo view save 仕事 next @会社 p1   # ビューを保存
/todo view 仕事                       # 保存したビューで表示
/todo view list                       # ビュー一覧
/todo view delete 仕事                # ビューを削除
```

### レポート出力

週次・月次の生産性レポートをMarkdownで出力。

```bash
/todo report weekly    # 直近7日間
/todo report monthly   # 直近30日間
/todo report 14d       # 直近14日間
```

完了サマリー、日別バーチャート、カテゴリ別・優先度別集計、完了タスク一覧を含みます。
