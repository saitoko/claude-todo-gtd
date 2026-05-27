#!/usr/bin/env bash
# todo.sh — /todo スキルのラッパースクリプト
# Usage: bash ~/.claude/todo.sh <command> [args...]
#        bash workspaces/todo-dev/scripts/todo.sh <command> [args...]

# プロジェクトルートの .env があれば読み込む（CoWork対応）
# TODO_DOTENV 環境変数で .env パスを明示指定可能（カレントディレクトリ非依存）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for envfile in "${TODO_DOTENV:-}" "$SCRIPT_DIR/../../../.env" "$SCRIPT_DIR/../../.env" ".env"; do
  [ -n "$envfile" ] && [ -f "$envfile" ] && . "$envfile" && break
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

# --help / -h は GH_TOKEN 不要。help コマンドに変換してショートサーキット
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  shift
  set -- "help" "$@"
fi

GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null || cat "$HOME/.claude/github-token" 2>/dev/null || echo '')}"

# TZ設定: TODO_TZ 環境変数で上書き可能（デフォルト: Asia/Tokyo）
# Git Bash (MSYS2) では TZ=Asia/Tokyo が効かないため、ファイルパス直接指定で対応
# Mac/Linux では TZ=Asia/Tokyo が有効なのでそのまま使用
if [ -n "${TODO_TZ:-}" ]; then
  _TZ_TOKYO="$TODO_TZ"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
  _TZ_TOKYO=":/mingw64/share/zoneinfo/Asia/Tokyo"
else
  _TZ_TOKYO="Asia/Tokyo"
fi
TODAY=$(TZ="$_TZ_TOKYO" date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)

if [ -z "$GH_TOKEN" ]; then
  echo "エラー: GH_TOKEN未設定。.env に GH_TOKEN=ghp_... を設定するか、gh auth token > ~/.claude/github-token を実行してください。" >&2
  exit 1
fi

# GTD 7カテゴリのラベル名（jq クエリと一元化。変更時はここのみ修正する）
# POSIX sh 互換のため配列不使用 → スペース区切り文字列で管理
_GTD_LABELS="inbox next waiting someday routine project reference"

# _todo_fetch_counts: GTD 7カテゴリの件数を "cat:N cat:N ..." 形式で stdout に出力
# 失敗時は空文字を返して exit 0（呼び出し側でサイレント失敗）
_todo_fetch_counts() {
  local issues
  issues=$(GH_TOKEN="$GH_TOKEN" gh issue list \
    --repo "$TODO_REPO_OWNER/$TODO_REPO_NAME" \
    --state open \
    --json labels \
    --limit 500 2>/dev/null) || return 0
  [ -z "$issues" ] && return 0
  printf '%s' "$issues" | jq -r '
    [
      "inbox:\([ .[] | select(any(.labels[]; .name | contains("inbox"))) ] | length)",
      "next:\([ .[] | select(any(.labels[]; .name | contains("next"))) ] | length)",
      "waiting:\([ .[] | select(any(.labels[]; .name | contains("waiting"))) ] | length)",
      "someday:\([ .[] | select(any(.labels[]; .name | contains("someday"))) ] | length)",
      "routine:\([ .[] | select(any(.labels[]; .name | contains("routine"))) ] | length)",
      "project:\([ .[] | select(any(.labels[]; .name | contains("project"))) ] | length)",
      "reference:\([ .[] | select(any(.labels[]; .name | contains("reference"))) ] | length)"
    ] | join(" ")
  ' 2>/dev/null || true
}

# counts コマンド: GTD 7カテゴリの件数を一括取得して出力（読み取り専用）
if [ "$1" = "counts" ]; then
  if [ -z "$TODO_REPO_OWNER" ] || [ -z "$TODO_REPO_NAME" ]; then
    echo "エラー: TODO_REPO_OWNER / TODO_REPO_NAME が未設定です。.env に設定してください。" >&2
    exit 1
  fi
  _COUNTS=$(_todo_fetch_counts)
  if [ -z "$_COUNTS" ]; then
    echo "エラー: GitHub Issue一覧の取得に失敗しました。" >&2
    exit 1
  fi
  echo "$_COUNTS"
  exit 0
fi

# --remind フラグをエンジンに渡す前に抽出・除去（macOS Reminders連携専用）
# 形式: --remind HH:MM（例: --remind 15:00）
_REMIND_TIME="" _ENGINE_ARGS=()
_SKIP_NEXT=0
for _arg in "$@"; do
  if [[ $_SKIP_NEXT -eq 1 ]]; then
    _REMIND_TIME="$_arg"; _SKIP_NEXT=0; continue
  fi
  if [[ "$_arg" == "--remind" ]]; then _SKIP_NEXT=1; continue; fi
  _ENGINE_ARGS+=("$_arg")
done

LANG_ENV="$LANG_ENV" GH_TOKEN="$GH_TOKEN" TODAY="$TODAY" TODO_REPO_OWNER="$TODO_REPO_OWNER" TODO_REPO_NAME="$TODO_REPO_NAME" node "$ENGINE" run "${_ENGINE_ARGS[@]}"
_TODO_EXIT=$?

# macOS Reminders連携（add コマンドで --remind 指定がある場合のみ）
if [[ "$OSTYPE" == "darwin"* ]] && [[ $_TODO_EXIT -eq 0 ]] && [[ "${1:-}" == "add" ]] && [[ -n "$_REMIND_TIME" ]]; then
  # --due の値を取得（エンジン渡し済みの _ENGINE_ARGS から）
  _DUE_VAL="" _PREV_ARG=""
  for _arg in "${_ENGINE_ARGS[@]}"; do
    [[ "$_PREV_ARG" == "--due" ]] && _DUE_VAL="$_arg"
    _PREV_ARG="$_arg"
  done
  # タイトルを抽出（GTDカテゴリとフラグを除いた最初の非フラグ引数）
  _REMINDER_TITLE="" _SKIP2=0
  for _arg in "${_ENGINE_ARGS[@]}"; do
    [[ $_SKIP2 -eq 1 ]] && _SKIP2=0 && continue
    [[ "$_arg" == "--"* ]] && _SKIP2=1 && continue
    [[ "$_arg" == "add" ]] && continue
    [[ " inbox next waiting someday routine project reference " == *" $_arg "* ]] && continue
    _REMINDER_TITLE="$_arg" && break
  done
  # 日付＋時刻を AppleScript 用にフォーマット（例: 05/23/2026 15:00:00）
  _DUE_DATE="${_DUE_VAL:-$TODAY}"
  _DUE_DATE_STR=$(date -j -f "%Y-%m-%d %H:%M" "$_DUE_DATE $_REMIND_TIME" "+%m/%d/%Y %H:%M:%S" 2>/dev/null)
  if [[ -n "$_REMINDER_TITLE" ]] && [[ -n "$_DUE_DATE_STR" ]]; then
    osascript <<APPLESCRIPT 2>/dev/null
tell application "Reminders"
  set dueDate to date "$_DUE_DATE_STR"
  set newReminder to make new reminder at end of default list
  set name of newReminder to "$_REMINDER_TITLE"
  set due date of newReminder to dueDate
  set remind me date of newReminder to dueDate
end tell
APPLESCRIPT
    echo "🔔 Reminders に登録: $_REMINDER_TITLE ($_DUE_DATE $_REMIND_TIME)"
  fi
fi

# Inbox・Next件数キャッシュ更新（ステータスライン用）
# _todo_fetch_counts で1回の API コールで7カテゴリを一括更新する
# コマンド成功・失敗にかかわらず更新（件数は常に最新状態を反映）
# エラー時はサイレントに失敗してステータスラインに影響させない
if [ -n "$TODO_REPO_OWNER" ] && [ -n "$TODO_REPO_NAME" ]; then
  _COUNTS=$(_todo_fetch_counts)
  if [ -n "$_COUNTS" ]; then
    for _PAIR in $_COUNTS; do
      _CAT="${_PAIR%%:*}"
      _CNT="${_PAIR##*:}"
      case "$_CAT" in
        inbox)     printf '%s' "$_CNT" > "$HOME/.claude/inbox-count"     2>/dev/null || true ;;
        next)      printf '%s' "$_CNT" > "$HOME/.claude/next-count"      2>/dev/null || true ;;
        waiting)   printf '%s' "$_CNT" > "$HOME/.claude/waiting-count"   2>/dev/null || true ;;
        someday)   printf '%s' "$_CNT" > "$HOME/.claude/someday-count"   2>/dev/null || true ;;
        routine)   printf '%s' "$_CNT" > "$HOME/.claude/routine-count"   2>/dev/null || true ;;
        project)   printf '%s' "$_CNT" > "$HOME/.claude/projects-count"  2>/dev/null || true ;;
        reference) printf '%s' "$_CNT" > "$HOME/.claude/reference-count" 2>/dev/null || true ;;
      esac
    done
  fi
fi

exit $_TODO_EXIT
