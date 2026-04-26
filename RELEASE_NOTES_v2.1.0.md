# v2.1.0 Release Notes

## What's new since v2

v2.1.0 is a significant feature expansion built on the three-layer architecture established in v2.
The engine (`todo-engine.js`) grew by 894 lines, and 40 new test scenarios were added — while the existing command interface is 100% backward compatible.

## Highlights

### 1. GitHub Sub-issue Integration
`--project N` now automatically calls the GitHub sub-issue REST API in addition to writing `project: #N` to the issue body.
Use `/todo migrate sub-issue` to retroactively register existing linked issues (idempotent).

### 2. Project Audit
`/todo weekly-project-audit` scans all projects and flags those missing a next action or inactive for 30+ days.
Weekly review Step 4 now runs this automatically.

### 3. Tickler File (Activate / Promote)
Set a future date with `--activate 2026-05-01` and the task surfaces in next when that date arrives.
`/todo promote` handles the promotion (called automatically by `daily-review`).
Use `--before 14d` to auto-calculate activate as 14 days before the due date.

### 4. Someday Review Tracking
`/todo review-someday <#>` records today's date in the issue body.
Tasks unreviewed for 30+ days show a ⚠️ marker at the top of `/todo list someday`.

### 5. Estimation & Dependency
`--estimate 2h` records work estimates; `--depends-on <#>` auto-promotes a task when its dependency is completed.
`/todo report` now includes an estimate vs. actual analysis.

### 6. Mobile Support
`todo.sh` auto-detects SH_MODE (local Node.js) vs. MCP_MODE (GitHub MCP, for iOS Claude Code).
See `tests/scenarios.md` Scenario 40 for iOS Shortcuts integration details.

### 7. Daily / Weekly Review Enhancements
- Daily review: previous-day action follow-up (Step 0), no-due top 3 (Step 3.5), no-estimate top 3 with split suggestion (Step 3.7), inbox 2-minute rule
- Weekly review: project audit replaces manual Step 4; Someday ⚠️ priority display

---

## Upgrade from v2

```bash
# 1. Clone or pull the latest
git clone https://github.com/saitoko/claude-todo-gtd.git
# or: cd claude-todo-gtd && git pull

# 2. Copy files to your Claude installation
cp todo.md ~/.claude/commands/todo.md
cp todo-engine.js ~/.claude/todo-engine.js
cp todo.sh ~/.claude/todo.sh

# 3. Verify
bash ~/.claude/todo.sh help
```

No data migration is required. All existing GitHub Issues remain intact.
The `activate` and `reviewed_at` fields are stored in the issue body and are read lazily — issues without these fields behave exactly as before.

If you previously had `project: #N` links but hadn't registered them as GitHub sub-issues, run:
```bash
/todo migrate sub-issue --dry-run   # preview
/todo migrate sub-issue             # apply
```

---

## File size changes

| File | v2 | v2.1.0 | Delta |
|------|----|--------|-------|
| `todo.md` | 176 lines | 283 lines | +107 |
| `todo-engine.js` | 2,673 lines | 3,567 lines | +894 |
| `todo.sh` | 33 lines | 44 lines | +11 |
| `tests/run-tests.sh` assertions | 383 | 423 | +40 |
| `tests/scenarios.md` | 850 lines | 1,348 lines | +498 |
