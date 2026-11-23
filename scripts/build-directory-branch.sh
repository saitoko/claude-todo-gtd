#!/usr/bin/env bash
# build-directory-branch.sh
#
# Build or update the local `directory` branch, the distribution branch that the
# Anthropic Directory tracks. It contains only the files the plugin needs:
#
#   .claude-plugin/plugin.json   <- from main
#   commands/todo.md             <- from main
#   LICENSE                      <- from main
#   README.md                    <- from plugin-dist/README.md on main
#   .claude-plugin/icon.png      <- from main (square PNG, 512-2048 px, < 2 MB)
#
# - First run creates an orphan branch; later runs add a new commit on top of the
#   existing branch. History is never rewritten (no force push is needed).
# - Content is taken from the committed HEAD of this repository, not the working
#   tree, so run it after the change is merged into main and checked out.
# - This script never pushes. It prints the push command at the end.
# - All work happens in a temporary worktree; the caller's checkout is untouched.
# - Any validation problem (including "could not read") exits non-zero, no commit.
#
# Usage: bash scripts/build-directory-branch.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="directory"
MAX_BYTES=262144
FORBIDDEN='GH_TOKEN|GITHUB_TOKEN|gh auth token|github-token|\.env'

# destination path in the distribution branch | source path in main
DIST_DEST=(".claude-plugin/plugin.json" "commands/todo.md" "LICENSE" "README.md" ".claude-plugin/icon.png")
DIST_SRC=(".claude-plugin/plugin.json" "commands/todo.md" "LICENSE" "plugin-dist/README.md" ".claude-plugin/icon.png")
ICON=".claude-plugin/icon.png"
MAX_ICON_BYTES=2097152

TMPBASE=""
WT=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [ -n "${WT}" ] && [ -d "${WT}" ]; then
    git -C "${REPO_ROOT}" worktree remove --force "${WT}" >/dev/null 2>&1 || true
  fi
  if [ -n "${TMPBASE}" ] && [ -d "${TMPBASE}" ]; then
    rm -rf "${TMPBASE}"
  fi
}
trap cleanup EXIT

# validate_icon <file>: PNG signature, square 512-2048 px, < 2 MB, no zip data.
validate_icon() {
  local f="$1" sig size w h
  sig="$(head -c 8 "${f}" | od -An -tx1 | tr -d ' \n')" || die "validate: cannot read ${ICON}"
  [ "${sig}" = "89504e470d0a1a0a" ] || die "validate: ${ICON} is not a PNG"
  size="$(wc -c < "${f}" | tr -d ' ')" || die "validate: cannot get size of ${ICON}"
  case "${size}" in ''|*[!0-9]*) die "validate: bad size for ${ICON}: '${size}'" ;; esac
  [ "${size}" -lt "${MAX_ICON_BYTES}" ] || die "validate: ${ICON} is ${size} bytes (limit ${MAX_ICON_BYTES})"
  # IHDR width/height are big-endian 32-bit integers at byte offsets 16 and 20.
  w="$(od -An -j16 -N4 -tu1 "${f}" | awk 'NF{print ($1*16777216)+($2*65536)+($3*256)+$4; exit}')" || die "validate: cannot read ${ICON} width"
  h="$(od -An -j20 -N4 -tu1 "${f}" | awk 'NF{print ($1*16777216)+($2*65536)+($3*256)+$4; exit}')" || die "validate: cannot read ${ICON} height"
  case "${w}${h}" in ''|*[!0-9]*) die "validate: bad dimensions for ${ICON}: '${w}x${h}'" ;; esac
  [ "${w}" = "${h}" ] || die "validate: ${ICON} is not square (${w}x${h})"
  [ "${w}" -ge 512 ] && [ "${w}" -le 2048 ] || die "validate: ${ICON} is ${w}px (allowed 512-2048)"
  if LC_ALL=C grep -q -a "$(printf 'PK\003\004')" "${f}"; then
    die "validate: ${ICON} looks like it holds a zip archive"
  fi
}

# validate_dir <dir>: every check fails closed (an unreadable result is a failure).
validate_dir() {
  local dir="$1" f rel expected actual size nul_free total head2 rc
  [ -d "${dir}" ] || die "validate: directory not found: ${dir}"

  # (a) exactly the expected files
  expected="$(printf '%s\n' "${DIST_DEST[@]}" | LC_ALL=C sort)"
  actual="$(cd "${dir}" && find . -type f -not -path './.git' -not -path './.git/*' | sed 's|^\./||' | LC_ALL=C sort)" \
    || die "validate: cannot list files"
  if [ "${expected}" != "${actual}" ]; then
    echo "expected:" >&2; echo "${expected}" >&2
    echo "actual:" >&2; echo "${actual}" >&2
    die "validate: file set differs from the allowed ${#DIST_DEST[@]} files"
  fi

  for rel in "${DIST_DEST[@]}"; do
    f="${dir}/${rel}"
    [ -f "${f}" ] && [ -r "${f}" ] || die "validate: cannot read ${rel}"

    if [ "${rel}" = "${ICON}" ]; then
      validate_icon "${f}"
      continue
    fi

    # (b) extension: .md / .json, or the file named LICENSE
    case "${rel}" in
      *.md|*.json|LICENSE) ;;
      *) die "validate: disallowed extension: ${rel}" ;;
    esac

    # (c) no shebang
    head2="$(head -c 2 "${f}")" || die "validate: cannot read head of ${rel}"
    [ "${head2}" != '#!' ] || die "validate: ${rel} starts with a shebang"

    # (d) size < 256 KiB
    size="$(wc -c < "${f}" | tr -d ' ')" || die "validate: cannot get size of ${rel}"
    case "${size}" in
      ''|*[!0-9]*) die "validate: bad size for ${rel}: '${size}'" ;;
    esac
    [ "${size}" -lt "${MAX_BYTES}" ] || die "validate: ${rel} is ${size} bytes (limit ${MAX_BYTES})"

    # (e) valid UTF-8 and no NUL bytes
    nul_free="$(LC_ALL=C tr -d '\000' < "${f}" | wc -c | tr -d ' ')" || die "validate: cannot scan ${rel} for NUL"
    total="${size}"
    [ "${nul_free}" = "${total}" ] || die "validate: ${rel} contains NUL bytes"
    iconv -f UTF-8 -t UTF-8 < "${f}" > /dev/null 2>&1 || die "validate: ${rel} is not valid UTF-8"

    # (f) no credential-related strings (grep: 0=match, 1=no match, other=error)
    rc=0
    LC_ALL=C grep -n -E -e "${FORBIDDEN}" "${f}" >&2 || rc=$?
    case "${rc}" in
      0) die "validate: ${rel} contains a forbidden pattern (${FORBIDDEN})" ;;
      1) ;;
      *) die "validate: grep failed on ${rel} (exit ${rc})" ;;
    esac
  done
}

main() {
  local src_sha src_branch i staged blob

  git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: ${REPO_ROOT}"
  src_sha="$(git -C "${REPO_ROOT}" rev-parse HEAD)" || die "cannot resolve HEAD"
  src_branch="$(git -C "${REPO_ROOT}" symbolic-ref --short -q HEAD || echo detached)"

  TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/directory-branch.XXXXXX")"
  TMPBASE="$(cd "${TMPBASE}" && pwd)"
  staged="${TMPBASE}/staged"
  WT="${TMPBASE}/wt"
  mkdir -p "${staged}"

  # Take committed content only; refuse if the working tree differs for those paths.
  for i in "${!DIST_DEST[@]}"; do
    blob="${DIST_SRC[${i}]}"
    git -C "${REPO_ROOT}" cat-file -e "HEAD:${blob}" 2>/dev/null || die "missing in HEAD: ${blob}"
    if [ -n "$(git -C "${REPO_ROOT}" status --porcelain -- "${blob}")" ]; then
      die "uncommitted changes in ${blob}; commit first"
    fi
    mkdir -p "$(dirname "${staged}/${DIST_DEST[${i}]}")"
    git -C "${REPO_ROOT}" show "HEAD:${blob}" > "${staged}/${DIST_DEST[${i}]}" || die "cannot read HEAD:${blob}"
  done

  echo "Validating staged files..."
  validate_dir "${staged}"
  echo "OK: staged files passed all checks."

  # Prepare a temporary worktree on the directory branch.
  if git -C "${REPO_ROOT}" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    git -C "${REPO_ROOT}" worktree add "${WT}" "${BRANCH}" >/dev/null 2>&1 || die "cannot add worktree for existing ${BRANCH}"
    echo "Updating existing branch '${BRANCH}'."
  elif git -C "${REPO_ROOT}" show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
    git -C "${REPO_ROOT}" worktree add -b "${BRANCH}" "${WT}" "origin/${BRANCH}" >/dev/null 2>&1 || die "cannot add worktree from origin/${BRANCH}"
    echo "Created '${BRANCH}' from origin/${BRANCH}."
  else
    git -C "${REPO_ROOT}" worktree add --detach "${WT}" HEAD >/dev/null 2>&1 || die "cannot add worktree"
    git -C "${WT}" checkout --orphan "${BRANCH}" >/dev/null 2>&1 || die "cannot create orphan branch"
    git -C "${WT}" rm -rf --quiet . >/dev/null 2>&1 || true
    echo "Creating new orphan branch '${BRANCH}'."
  fi

  # Replace the tree with the staged files.
  if [ -n "$(git -C "${WT}" ls-files)" ]; then
    git -C "${WT}" rm -rf --quiet -- . || die "cannot clear worktree"
  fi
  for i in "${!DIST_DEST[@]}"; do
    mkdir -p "$(dirname "${WT}/${DIST_DEST[${i}]}")"
    cp "${staged}/${DIST_DEST[${i}]}" "${WT}/${DIST_DEST[${i}]}"
    git -C "${WT}" add -- "${DIST_DEST[${i}]}"
  done

  # Validate what is about to be committed (the index, not just the staged copy).
  validate_dir "${WT}"
  if git -C "${WT}" diff --cached --quiet 2>/dev/null && git -C "${WT}" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    echo "No changes: '${BRANCH}' already matches ${src_sha}."
    echo "Local ${BRANCH} head: $(git -C "${REPO_ROOT}" rev-parse "${BRANCH}")"
    return 0
  fi

  git -C "${WT}" commit --quiet -m "dist: sync from ${src_branch} @ ${src_sha}

Distribution branch for the Anthropic Directory (plugin files only).
Source commit: ${src_sha}" || die "commit failed"

  echo
  echo "Done. Local '${BRANCH}' is at $(git -C "${REPO_ROOT}" rev-parse "${BRANCH}")"
  echo "Contents:"
  git -C "${REPO_ROOT}" ls-tree -r -l "${BRANCH}"
  echo
  echo "Not pushed. To publish (after review):"
  echo "  git -C ${REPO_ROOT} push origin ${BRANCH}"
}

main "$@"
