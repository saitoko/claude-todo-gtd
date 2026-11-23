# claude-todo-gtd

A GTD (Getting Things Done) task manager for Claude Code and Claude, using GitHub Issues as the storage backend. Type `/todo` and manage your inbox, next actions, waiting-for items, someday/maybe lists, projects, and weekly reviews in natural language. No server is required: your tasks live as Issues in a private GitHub repository that you own.

## What this plugin contains

This branch carries only the files the plugin needs: `commands/todo.md` (the `/todo` command definition), the plugin manifest, the license, and this README. The command engine, the shell wrapper, the test suite, and the full manual are kept on the `main` branch.

## Setup

### 1. Connect the GitHub MCP server (the `github` connector)

The plugin operates on Issues through the `github` connector. Connect it in Claude and approve access to the repository you will use for tasks.

- In the Claude app: open the connectors screen, add the GitHub connector, and complete the sign-in flow in your browser.
- In Claude Code: add a GitHub MCP server with the `/mcp` command, then confirm that its tools appear as `github`.

Authorization is handled by the connector itself. This plugin never asks you to paste a secret into a file or a prompt.

### 2. Create a repository for your tasks

Create a private GitHub repository to hold the Issues, for example `my-tasks`, and grant the connector access to it.

### 3. Tell the plugin which repository to use

`commands/todo.md` reads two plain settings that identify the repository. They are names, not secrets:

- `TODO_REPO_OWNER`: the GitHub user or organization that owns the repository (for example `your-name`)
- `TODO_REPO_NAME`: the repository name (for example `my-tasks`)

Set both in the environment where Claude runs, then start with `/todo` or `/todo add <title>`.

## Using the CLI version

If you prefer the shell-based version (a wrapper script plus a Node.js engine, with faster bulk operations and a much larger command set), follow the manual install instructions on the main branch: https://github.com/saitoko/claude-todo-gtd#manual-install

## License

MIT. See the LICENSE file.
