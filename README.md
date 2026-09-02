# /todo — Claude Code GTD Task Management Skill

> 🌐 [日本語 README はこちら](README.ja.md)

A GTD (Getting Things Done) task management slash command for Claude Code, powered by GitHub Issues as the backend.

Just type `/todo` to add, manage, and review tasks entirely from the terminal.

## Features

- **GTD methodology** — 7 categories: inbox / next / routine / waiting / someday / project / reference
- **40+ commands** — Task CRUD, bulk operations, weekly review, templates, statistics, project audit, tickler file
- **Multilingual** — Japanese (default) and English supported. Set `LANG_ENV=en` for English
- **Flexible date input** — `--due tomorrow`, `--due "next friday"`, `--due "in 3 days"` (Japanese dates also work regardless of language setting)
- **Context management** — `@PC` `@office` `@errands` for location/situation-based filtering
- **Priority levels** — p1 (urgent) / p2 (important) / p3 (normal)
- **Recurring tasks** — daily / weekly / monthly / weekdays, tracked under the `routine` category with catch-up detection for missed occurrences
- **Security** — Shell injection and prompt injection protection with 8 rules
- **1,536+ tests** — Local unit tests + GitHub integration tests
- **No server required** — GitHub Issues API + local files only

## Installation

### Plugin install (recommended)

```bash
claude plugin install claude-todo-gtd@claude-community
```

After installing, create a private GitHub repository to store your tasks and set the environment variables below (see step 3–4 of the manual install).

### Manual install

#### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated
- Node.js (used for date processing)

#### Setup

1. Copy the files:
```bash
cp todo.md ~/.claude/commands/todo.md
cp todo-engine.js ~/.claude/todo-engine.js
cp todo.sh ~/.claude/todo.sh
```

2. Initialize the template database:
```bash
echo '{}' > ~/.claude/todo-templates.json
```

3. Prepare a GitHub repository (to store Issues):
```bash
gh repo create my-tasks --private
```

4. Configure environment variables (create `.env` in the project root):
```bash
cp .env.example .env
# Edit .env and set the following:
# GH_TOKEN=your_github_token_here  (get with: gh auth token)
# TODO_REPO_OWNER=your-github-username
# TODO_REPO_NAME=my-tasks
```

> **Note:** `@octokit/rest` (GitHub API client) is automatically installed on first run.

5. Type `/todo` in Claude Code to verify.

#### Language Configuration

The default language is Japanese. To use English, set the `LANG_ENV` environment variable:

```bash
# Add to ~/.bashrc or ~/.zshrc
export LANG_ENV=en
```

Or add it to your CLAUDE.md:
```markdown
Environment variable: LANG_ENV=en
```

> **Note:** Date input (`--due tomorrow` / `--due 明日`) always accepts both Japanese and English, regardless of the language setting.

## Quick Start

> **Note:** Titles starting with a Latin letter are treated as command lookups (to avoid accidentally creating "ghost" issues from typos), so use `add` explicitly when the title itself starts with an English word. Non-Latin titles (e.g. Japanese) can be captured directly without `add` for frictionless collection.

```bash
# Add a task (goes to inbox) — use "add" because the title starts with an English word
/todo add buy groceries

# Add as next action (with due date and context)
/todo next write design doc @PC --due tomorrow

# Add with priority
/todo next incident response --priority p1

# Add a recurring task
/todo next write weekly report --due "next monday" --recur weekly

# List all tasks
/todo list

# Show only next actions
/todo list next

# Filter by context
/todo list @PC

# Complete a task
/todo done 5

# Start a weekly review (not a /todo subcommand — see "Interactive Commands" in todo.md
# for how to invoke it in your environment)
```

## Date Input Patterns

**English patterns:**

| Input | Result |
|-------|--------|
| `today` | Today's date |
| `tomorrow` | +1 day |
| `day after tomorrow` | +2 days |
| `next week` | +7 days |
| `next month` | +1 month |
| `this weekend` | Next Saturday |
| `end of this month` | Last day of this month |
| `end of next month` | Last day of next month |
| `in N days` | +N days |
| `in N weeks` | +N weeks |
| `in N months` | +N months |
| `next Monday` ~ `next Sunday` | Next specified weekday |

**Japanese patterns:** 今日（today） / 明日（tomorrow） / 明後日（day after tomorrow） / 来週（next week） / 来月（next month） / 今週末（this weekend） / 今月末（end of this month） / 来月末（end of next month） / N日後（in N days） / N週間後（in N weeks） / Nヶ月後（in N months） / 来週月曜〜来週日曜（next Monday–Sunday）

> **Note:** Japanese date patterns (e.g., `--due 明日`) also work regardless of language setting.

## Commands

### Create a Task

```
/todo [GTD] <title> [@context...] [--due <date>] [--desc "<text>"]
      [--recur <pattern>] [--project <number>] [--priority <p1|p2|p3>]
```

| Option | Description | Example |
|--------|-------------|---------|
| GTD label | inbox (default) / next / waiting / someday / project / reference | `/todo next task name` |
| `@context` | Context (multiple allowed) | `@PC @office` |
| `--due` | Due date (Japanese also supported) | `--due tomorrow`, `--due 4/10`, `--due 2026-04-10` |
| `--desc` | Description | `--desc "Read through chapter 3"` |
| `--body` | Full issue body text (overrides the auto-generated body) | `--body "Detailed notes..."` |
| `--body-file` | Read the body from a file (takes priority over `--body`) | `--body-file notes.md` |
| `--recur` | Recurrence | `--recur weekly` |
| `--project` | Link to a project (also registers as a GitHub sub-issue) | `--project 7` |
| `--priority` | Priority | `--priority p1` |
| `--estimate` | Time estimate | `--estimate 2h`, `--estimate 30m` |
| `--activate` | Scheduled promotion date (auto-promotes to next on that date) | `--activate 2026-05-01` |
| `--before` | Auto-calculate `--activate` as N days before `--due` (requires `--due`) | `--before 14d` |
| `--depends-on` | Auto-promote to next when the dependency task is completed | `--depends-on 42` |
| `--resume-condition` | Records a resume condition as free text; while set, `/todo promote` won't auto-promote and reports it for review instead | `--resume-condition "USD/JPY drops below 110"` |
| `--actual` | (with `done`) Record actual time spent on completion | `/todo done 5 --actual 1h30m` |
| `--label` | Attach a general-purpose label, separate from `@context`/`#tag` (auto-created if it doesn't exist) | `--label follow-up` |
| `#tag` | Free-form tag, separate from `@context` (see "Context & Labels" below) | `#GW` |

### List & Search

| Command | Description |
|---------|-------------|
| `/todo list` | List all tasks by GTD category |
| `/todo list next` | Show next actions only |
| `/todo list @PC` | Filter by context |
| `/todo list p1` | Filter by priority |
| `/todo list next @PC` | AND filter with multiple conditions |
| `/todo list #tag` | Filter by tag |
| `/todo list project 7` | Show tasks under a project |
| `/todo list --group` | Group results by due date instead of GTD category (overdue / today / tomorrow / this week / later / no due) |
| `/todo list --no-due` | Show only tasks with no due date set (takes priority over `--group`) |
| `/todo list --no-estimate` | Show only tasks with no estimate set |
| `/todo search <keyword>` | Search open tasks by keyword |
| `/todo stats` | Task statistics (by category, priority, due status, completion record) |
| `/todo show <#> [--json]` | Show details for a single task |
| `/todo schema` | Show the field schema for `--json` output |

### Status & Completion

| Command | Description |
|---------|-------------|
| `/todo move <#> <GTD> [--note "text"]` | Change GTD category. `--note` appends a comment after the label change (e.g. reason for demotion) |
| `/todo done <#> [--note "text"]` | Complete a task (recurring tasks auto-create the next occurrence; project next-task hints are shown). `--note` appends a comment after closing (e.g. retrospective notes) |
| `/todo done <#> --actual <time>` | Record actual time spent when completing (e.g. `--actual 1h30m`); used by `report`'s estimate-vs-actual summary |

### Edit

| Command | Description |
|---------|-------------|
| `/todo edit <#> [options]` | Update multiple fields at once (`--due` / `--priority` / `--estimate` / `--activate` / `--before` etc.) |
| `/todo rename <#> <new title>` | Change title |
| `/todo due <#> <date>` | Change due date |
| `/todo desc <#> <text>` | Change description |
| `/todo recur <#> <pattern\|clear>` | Set/clear recurrence |
| `/todo priority <#> <p1\|p2\|p3\|clear>` | Set/clear priority |
| `/todo link <#> <project#>` | Link to a project (also registers as a GitHub sub-issue) |

### Context & Labels

`@context` and `#tag` are two separate labeling systems. `@context` answers "where / under what situation can I do this?" (e.g. `@PC`, `@errands`). `#tag` is a free-form classification axis not tied to location or situation (e.g. `#GW`, `#project-x`) — useful for grouping tasks by initiative or person across GTD categories. Both can be attached at creation time, or added/removed later with `tag`/`untag`. Tag names can't be numbers-only (to avoid colliding with `#42`-style issue references).

| Command | Description |
|---------|-------------|
| `/todo tag <#> @ctx1 @ctx2` | Add context |
| `/todo tag <#> #tag1 #tag2` | Add tag (can be mixed with `@ctx` in the same command) |
| `/todo untag <#> @ctx` | Remove context |
| `/todo untag <#> #tag` | Remove tag |
| `/todo tag rename @old @new` | Bulk-rename a context across all tasks |
| `/todo label list` | List all context labels |
| `/todo label add @name [--color hex]` | Create a context label |
| `/todo label delete @name` | Delete a context label |

> `/todo label list/add/delete` only manage `@context` labels. There's no separate management subcommand for `#tag` — add/remove it via `tag`/`untag`, or filter with `/todo list #tag`.

### Project Management

| Command | Description |
|---------|-------------|
| `/todo promote-project <#>` | Promote an existing issue to a project |
| `/todo unlink <#>` | Remove a child issue's project link |
| `/todo migrate sub-issue [--dry-run]` | Bulk-register issues with `project: #N` in the body as GitHub sub-issues (idempotent) |
| `/todo weekly-project-audit` | Audit all projects — auto-detect missing next actions and stalled projects |

### Tickler File & Someday Management

| Command | Description |
|---------|-------------|
| `/todo promote` | Bulk-promote tasks whose activate date has arrived to next (tasks with `--resume-condition` set are held and reported instead of auto-promoted) |
| `/todo activate <#> <date>` | Shorthand for `/todo edit <#> --activate <date>` |
| `/todo review-someday <#>` | Record a review date for a someday task (⚠️ shown after 30+ days without review) |

### Bulk Operations

| Command | Description |
|---------|-------------|
| `/todo bulk done <#> <#> ...` | Complete multiple tasks at once |
| `/todo bulk move <#> <#> ... <GTD>` | Move multiple tasks at once |
| `/todo bulk tag <#> <#> ... @ctx` | Add context to multiple tasks |
| `/todo bulk untag <#> <#> ... @ctx` | Remove context from multiple tasks |
| `/todo bulk priority <#> <#> ... <p>` | Change priority for multiple tasks at once |

### Archive

| Command | Description |
|---------|-------------|
| `/todo archive` | Show recently completed tasks (last 30) |
| `/todo archive list <GTD\|@ctx>` | Show archived tasks with a filter |
| `/todo archive search <keyword>` | Search completed tasks by keyword |
| `/todo archive reopen <#>` | Reopen a completed task |

### Templates

| Command | Description |
|---------|-------------|
| `/todo template list` | List templates |
| `/todo template show <name>` | Show template details |
| `/todo template save <name> [options]` | Save a template (inline or interactively). Template-only option: `--due-offset <N>` sets the due date to N days after the day the template is used (overrides `--due` if both are given) |
| `/todo template save <name> from <#>` | Create a template from an existing task |
| `/todo template use <name> [title]` | Create a task from a template |
| `/todo template delete <name>` | Delete a template |

## Weekly Review

> `weekly-review` is not a `/todo` subcommand. How you invoke it depends on your environment — see the "Interactive Commands" section in `todo.md` for details.

Runs the GTD weekly review as a 6-step interactive session:

1. **Inbox triage** — Classify unprocessed tasks one by one (includes a 2-minute-rule check)
2. **Next Actions check** — Confirm each is still valid, or should be moved elsewhere
3. **Waiting For check** — Follow up or confirm completion
4. **Projects audit** — Runs `weekly-project-audit`. Auto-detects missing next actions and stalled projects
5. **Someday review** — Highlights items unreviewed for 30+ days with ⚠️. Use `review-someday` to record a review
6. **Summary** — Lists overdue tasks and tasks due this week

> **Tip:** You can also process the inbox one item at a time outside of a weekly review with `/todo list inbox`.

## Security

GitHub Issue bodies can contain arbitrary user-supplied text, so the following protections are implemented:

1. Issue data is treated as external data, never executed as instructions
2. User input is passed to shell commands via variables (never expanded directly)
3. Context names are validated against invalid characters using POSIX `case` statements
4. Issue numbers must be positive integers
5. Dates must be in `YYYY-MM-DD` or `M/D` format, and must be a calendar-valid date (e.g. `2026-13-01` or `2/30` is rejected). `M/D` values are always normalized to a concrete year; if the result would be in the past relative to today, it rolls forward to next year
6. Recurrence patterns are limited to `daily` / `weekly` / `monthly` / `weekdays`, plus the suffixed forms `weekly:<day>` / `monthly:<date>`. Plain `monthly` (no suffix) clamps to the last day of the month when the target day doesn't exist next month (e.g. `1/31` → `2/28`), and does not drift back up in later months
7. Color codes must be 6-digit hex values
8. Priority must be one of `p1` / `p2` / `p3`

## Development

### File Structure

```
claude-todo-gtd/
├── todo.md                 # Skill body (copy to ~/.claude/commands/)
├── todo-engine.js          # Core engine (copy to ~/.claude/)
├── todo.sh                 # Launcher script (copy to ~/.claude/)
├── todo-manual.md          # Detailed user manual
├── todo-templates.json     # Sample template DB
├── README.md               # This file (English)
├── README.ja.md            # Japanese README
└── tests/
    ├── scenarios.md        # Test scenario list (40+ scenarios)
    ├── run-tests.sh        # Local unit tests (1,536+ assertions in total, incl. the write suite)
    ├── run-tests-write.sh  # Local unit tests for write operations
    ├── gh-tests.sh         # GitHub integration tests
    ├── helpers/
    │   └── date-fmt.js     # Shared date formatting helpers
    ├── fixtures/
    │   └── sample-templates.json
    └── stubs/
        └── octokit-stub.js # Stub for @octokit/rest, used to run unit tests without hitting the GitHub API
```

### Development Flow

1. Edit `todo.md` / `todo-engine.js`
2. Run local tests with `tests/run-tests.sh`
3. Run GitHub integration tests with `tests/gh-tests.sh`
4. Deploy to production:
```bash
cp todo.md ~/.claude/commands/todo.md
cp todo-engine.js ~/.claude/todo-engine.js
cp todo.sh ~/.claude/todo.sh
```

### Mobile Support (SH_MODE / MCP_MODE)

`todo.sh` auto-detects its execution environment:
- **SH_MODE** (default): Runs the local `todo-engine.js` with Node.js
- **MCP_MODE**: In environments where `~/.claude/todo.sh` doesn't exist (e.g. Claude Code on iOS), maps directly to the GitHub MCP

For calling the GitHub REST API directly from iOS Shortcuts, see scenario 40 in `tests/scenarios.md`.

### Running Tests

```bash
# Local unit tests
bash tests/run-tests.sh

# GitHub integration tests (creates/manipulates real issues)
bash tests/gh-tests.sh
```

## Tech Stack

- **Runtime**: Claude Code custom slash command
- **Backend**: GitHub Issues API (via `gh` CLI)
- **Scripting**: Bash + Node.js (JSON processing, date calculations)
- **Template storage**: Local JSON file

## License

MIT

## Pro Features

The core feature set (40+ commands) is entirely free. The following are additional features for boosting productivity further.

### Dashboard

An at-a-glance view focused on what to do today.

```bash
/todo dashboard   # or /todo dash
```

Shows overdue tasks, today's tasks, tasks due this week, next actions, and completion stats all in one view.

### Daily Review

An interactive morning-planning / evening-reflection routine (auto-detects morning/evening based on time — before 3pm → morning, after → evening; can also be specified explicitly). `daily-review` is not a `/todo` subcommand — how you invoke it depends on your environment, see the "Interactive Commands" section in `todo.md` for details.

**Morning:** Dashboard → Inbox triage → Pick today's tasks → Plan summary
**Evening:** Completion stats → Handle incomplete tasks → Tomorrow's plan → Daily summary

### Custom Views

Save and recall frequently-used filter combinations by name.

```bash
/todo view save work next @office p1   # Save a view
/todo view work                        # Show the saved view
/todo view list                        # List views
/todo view delete work                 # Delete a view
```

### Report Output

Weekly/monthly productivity reports in Markdown.

```bash
/todo report weekly    # Last 7 days
/todo report monthly   # Last 30 days
/todo report 14d       # Last 14 days
```

Includes a completion summary, a daily bar chart, breakdowns by category and priority, and a list of completed tasks.
