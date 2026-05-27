# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Added

- `/todo due <#> clear` — 期日を削除する（`recur clear` と同一命名規則）(Issue #1473)
- `/todo edit <#> --due clear` — `edit` コマンドでも期日削除が可能
- `/todo edit <#> --due ""` — 空文字指定でも期日削除として扱う
- `MAX_OPEN_ISSUES_LIMIT = 200` 定数を追加。`fetchAllOpen` が上限に達したとき stderr に警告を出力するようになった

### Fixed

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
