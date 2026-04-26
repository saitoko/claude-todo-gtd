# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
