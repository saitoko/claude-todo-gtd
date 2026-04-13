# /todo — Claude Code GTD Task Management Skill

A GTD (Getting Things Done) task management slash command for Claude Code, powered by GitHub Issues as the backend.

Just type `/todo` to add, manage, and review tasks entirely from the terminal.

## Features

- **GTD methodology** — 6 categories: inbox / next / waiting / someday / project / reference
- **30+ commands** — Task CRUD, bulk operations, weekly review, templates, statistics
- **Multilingual** — Japanese (default) and English supported. Set `LANG_ENV=en` for English
- **Flexible date input** — `--due tomorrow`, `--due "next friday"`, `--due "in 3 days"` (Japanese dates also work regardless of language setting)
- **Context management** — `@PC` `@office` `@errands` for location/situation-based filtering
- **Priority levels** — p1 (urgent) / p2 (important) / p3 (normal)
- **Recurring tasks** — daily / weekly / monthly / weekdays
- **Security** — Shell injection and prompt injection protection with 8 rules
- **360+ tests** — Local unit tests + GitHub integration tests
- **No server required** — GitHub Issues API + local files only

## Installation

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated
- Node.js (used for date processing)

### Setup

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

5. Set the language to English:
```bash
export LANG_ENV=en
```

Or add to your CLAUDE.md:
```markdown
Environment variable: LANG_ENV=en
```

6. Type `/todo` in Claude Code to verify.

## Quick Start

```bash
# Add a task (goes to inbox)
/todo buy groceries

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

# Start a weekly review
/todo weekly-review
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

> **Note:** Japanese date patterns (e.g., `--due 明日`) also work regardless of language setting.

## Commands

### Create a task

```
/todo [GTD] <title> [@context...] [--due <date>] [--desc "<text>"]
      [--recur <pattern>] [--project <number>] [--priority <p1|p2|p3>]
```

### List & Search

| Command | Description |
|---------|-------------|
| `/todo list` | List all tasks by GTD category |
| `/todo list next` | Show next actions only |
| `/todo list @PC` | Filter by context |
| `/todo list p1` | Filter by priority |
| `/todo search <keyword>` | Search open tasks |
| `/todo stats` | Task statistics |
| `/todo dashboard` | Today's overview |
| `/todo report weekly` | Weekly productivity report |

### Status & Completion

| Command | Description |
|---------|-------------|
| `/todo move <#> <GTD>` | Change GTD category |
| `/todo done <#>` | Complete a task (recurring tasks auto-create next) |

### Edit

| Command | Description |
|---------|-------------|
| `/todo edit <#> [options]` | Update multiple fields at once |
| `/todo rename <#> <new title>` | Change title |
| `/todo due <#> <date>` | Change due date |
| `/todo desc <#> <text>` | Change description |
| `/todo recur <#> <pattern\|clear>` | Set/clear recurrence |
| `/todo priority <#> <p1\|p2\|p3\|clear>` | Set/clear priority |

### Context & Labels

| Command | Description |
|---------|-------------|
| `/todo tag <#> @ctx1 @ctx2` | Add context |
| `/todo untag <#> @ctx` | Remove context |
| `/todo label list` | List all context labels |

### Bulk Operations

| Command | Description |
|---------|-------------|
| `/todo bulk done <#> <#> ...` | Complete multiple tasks |
| `/todo bulk move <#> <#> ... <GTD>` | Move multiple tasks |

### Templates

| Command | Description |
|---------|-------------|
| `/todo template list` | List templates |
| `/todo template save <name> [options]` | Save a template |
| `/todo template use <name> [title]` | Create task from template |
| `/todo template delete <name>` | Delete a template |

### Reviews

| Command | Description |
|---------|-------------|
| `/todo weekly-review` | 6-step GTD weekly review |
| `/todo daily-review` | Morning planning / evening reflection |
| `/todo review` | Sort inbox items one by one |

## License

MIT
