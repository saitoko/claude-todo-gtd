#!/usr/bin/env bash
# todo.sh — /todo スキルのラッパースクリプト
# Usage: bash ~/.claude/todo.sh <command> [args...]
#        bash workspaces/todo-dev/scripts/todo.sh <command> [args...]

# プロジェクトルートの .env があれば読み込む（CoWork対応）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for envfile in "$SCRIPT_DIR/../../../.env" "$SCRIPT_DIR/../../.env" ".env"; do
  [ -f "$envfile" ] && . "$envfile" && break
done

# Octokit セットアップ（初回のみ）
[ ! -d "$HOME/.claude/node_modules/@octokit/rest" ] && npm install --prefix "$HOME/.claude" @octokit/rest >/dev/null 2>&1

# エンジンパス解決（~/.claude/ 優先、なければスクリプト隣接）
if [ -f "$HOME/.claude/todo-engine.js" ]; then
  ENGINE="$HOME/.claude/todo-engine.js"
elif [ -f "$SCRIPT_DIR/todo-engine.js" ]; then
  ENGINE="$SCRIPT_DIR/todo-engine.js"
else
  ENGINE=$(node -e "const p=require('path'),o=require('os'); process.stdout.write(p.join(o.homedir(),'.claude','todo-engine.js'));")
fi

LANG_ENV="${LANG_ENV:-ja}"
GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null || cat "$HOME/.claude/github-token" 2>/dev/null || echo '')}"
TODAY=$(TZ="${TZ:-Asia/Tokyo}" date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)

if [ -z "$GH_TOKEN" ]; then
  echo "エラー: GH_TOKEN未設定。.env に GH_TOKEN=ghp_... を設定するか、gh auth token > ~/.claude/github-token を実行してください。" >&2
  exit 1
fi

LANG_ENV="$LANG_ENV" GH_TOKEN="$GH_TOKEN" TODAY="$TODAY" TODO_REPO_OWNER="$TODO_REPO_OWNER" TODO_REPO_NAME="$TODO_REPO_NAME" node "$ENGINE" run "$@"
