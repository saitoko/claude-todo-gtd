# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Added

- `recur` に曜日・日付固定サフィックスを追加（Issue #1676）。`weekly:<曜日>`（例: `weekly:sat` = 毎週土曜固定）と `monthly:<日>`（例: `monthly:15` = 毎月15日固定）の2種類の構文を、`add --recur` / `edit --recur` / `recur <#>` / 完了時の周期再作成（`postDoneProcessing`）すべてで使用可能にする。次回due計算は「厳密加算」方式（必ず最低1周期分の間隔を空けてから対象の曜日・日付に合わせる。例: 完了日が土曜でも `weekly:sat` の次回は7日後の次の土曜になり、当日には戻らない）。`monthly:<日>` でその月に存在しない日（2/30等）を指定した場合はその月の末日にクランプし、指定日そのものは保持し続けるためズレは蓄積しない（例: `monthly:31` は2月なら28日/29日、3月は31日に自動復帰）。サフィックスなしの既存 `daily`/`weekly`/`monthly`/`weekdays` の挙動は完全に維持（後方互換）

### Fixed

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
