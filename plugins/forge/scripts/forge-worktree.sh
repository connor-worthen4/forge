#!/usr/bin/env bash
#
# forge-worktree.sh - manage the per-task git worktree a parallel run needs.
#
# Two tasks cannot both have a branch checked out in one working tree, so a run
# that works several tasks at once gives each its own worktree under
# .forge/worktrees/<task-id>. Tasks on different surfaces then build, test, and
# open PRs concurrently without any of them seeing another's edits, and the main
# checkout is never moved off whatever branch the human left it on.
#
# .forge/ is gitignored, so these worktrees never show up as untracked files and
# no worktree contains a copy of .forge/ itself - which is exactly why every
# forge script resolves state against the MAIN worktree (see forge-lib.sh).
#
# Usage:
#   forge-worktree.sh path <task-id>
#       Print where the worktree for <task-id> would live. No side effects.
#   forge-worktree.sh add <task-id> --branch <branch> [--base <ref>]
#       Create it (or reuse an existing one) with <branch> checked out, cutting
#       from <ref> when the branch does not exist yet. Prints the path.
#   forge-worktree.sh remove <task-id>
#       Remove the worktree. The branch and its commits are untouched.
#   forge-worktree.sh list
#       Print "<task-id> <path> <branch>" for every forge worktree.
#   forge-worktree.sh prune
#       Remove worktrees whose task has reached a terminal or parked state
#       (done, pr_open, merged, blocked, failed), then prune git's registry.
#
# Exit status: 0 on success | 1 on a git failure | 2 usage/environment error.
#
# Deps: git, jq, python3 (via forge-lib.sh).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

forge_require git || exit 2

# Statuses whose worktree has no further use: the work either landed or died.
# `blocked` is deliberately absent - it is a resumable pause, and its tree is
# where a human inspects the half-finished work and where the resumed run picks
# up. Removing a tree never touches its branch, so nothing is lost either way.
TERMINAL_STATUSES="done pr_open merged failed"

usage() {
  echo "usage: forge-worktree.sh path|add|remove|list|prune <task-id> [--branch <b>] [--base <ref>]" >&2
  exit 2
}

mode="${1:-}"
case "$mode" in
  path|add|remove|list|prune) shift ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) usage ;;
esac

task_id=""
branch=""
base=""
case "$mode" in
  list|prune) : ;;
  *) task_id="${1:-}"; [ -n "$task_id" ] || usage; shift ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch) branch="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    *) echo "forge-worktree: unexpected argument '$1'" >&2; usage ;;
  esac
done

if ! git -C "$FORGE_MAIN" rev-parse --git-dir >/dev/null 2>&1; then
  echo "forge-worktree: not a git repository: $FORGE_MAIN" >&2
  exit 2
fi

wt_path() { printf '%s/%s' "$WORKTREES_DIR" "$1"; }

# The branch currently checked out in a worktree, or empty.
wt_branch() {
  git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null
}

# remove_wt <path>: drop a worktree, falling back to a plain directory removal
# when git has already forgotten it (a half-removed tree must not wedge a run).
remove_wt() {
  local p="$1"
  [ -e "$p" ] || return 0
  git -C "$FORGE_MAIN" worktree remove --force "$p" >/dev/null 2>&1 || rm -rf "$p"
  git -C "$FORGE_MAIN" worktree prune >/dev/null 2>&1
}

case "$mode" in
  path)
    wt_path "$task_id"
    ;;

  list)
    if [ -d "$WORKTREES_DIR" ]; then
      for p in "$WORKTREES_DIR"/*; do
        [ -d "$p" ] || continue
        printf '%s %s %s\n' "$(basename "$p")" "$p" "$(wt_branch "$p")"
      done
    fi
    ;;

  prune)
    removed=0
    if [ -d "$WORKTREES_DIR" ]; then
      for p in "$WORKTREES_DIR"/*; do
        [ -d "$p" ] || continue
        id="$(basename "$p")"
        status="$(python3 -c '
import json, sys, os
p = os.path.join(sys.argv[1], sys.argv[2], "run.json")
try:
    print(json.load(open(p)).get("status", "") or "")
except Exception:
    print("")
' "$RUNS_DIR" "$id")"
        case " $TERMINAL_STATUSES " in
          *" $status "*)
            remove_wt "$p"
            echo "forge-worktree: removed $id ($status)"
            removed=$((removed + 1))
            ;;
        esac
      done
    fi
    git -C "$FORGE_MAIN" worktree prune >/dev/null 2>&1
    echo "forge-worktree: pruned $removed worktree(s)"
    ;;

  remove)
    remove_wt "$(wt_path "$task_id")"
    echo "forge-worktree: removed $(wt_path "$task_id")"
    ;;

  add)
    [ -n "$branch" ] || { echo "forge-worktree: --branch is required for add" >&2; exit 2; }
    path="$(wt_path "$task_id")"

    # Reuse an existing tree only when it already holds the branch we want. A
    # tree left on some other branch is stale (a re-run after the task's branch
    # was recomputed) and is safer to rebuild than to reconcile.
    if [ -d "$path" ]; then
      if [ "$(wt_branch "$path")" = "$branch" ]; then
        printf '%s\n' "$path"
        exit 0
      fi
      remove_wt "$path"
    fi

    mkdir -p "$WORKTREES_DIR"

    # Resolve the starting point: an explicit --base, else the configured base
    # branch. Prefer the remote-tracking ref so a stale local branch cannot seed
    # the tree with an out-of-date base.
    [ -n "$base" ] || base="$(config_get base_branch develop)"
    start=""
    if start_ref="$(cd "$FORGE_MAIN" && forge_resolve_ref "$base")" && [ -n "$start_ref" ]; then
      start="$start_ref"
    elif git -C "$FORGE_MAIN" rev-parse --verify --quiet "$base" >/dev/null; then
      start="$base"
    fi

    if git -C "$FORGE_MAIN" show-ref --verify --quiet "refs/heads/$branch"; then
      # The branch exists: check it out in the new tree as-is. Its commits are
      # the work of an earlier attempt and must not be discarded here.
      out="$(git -C "$FORGE_MAIN" worktree add "$path" "$branch" 2>&1)" || {
        echo "forge-worktree: could not add worktree for existing branch $branch: ${out##*$'\n'}" >&2
        exit 1
      }
    else
      [ -n "$start" ] || {
        echo "forge-worktree: base ref not found locally or on origin: $base" >&2
        exit 2
      }
      out="$(git -C "$FORGE_MAIN" worktree add -b "$branch" "$path" "$start" 2>&1)" || {
        echo "forge-worktree: could not add worktree for new branch $branch from $start: ${out##*$'\n'}" >&2
        exit 1
      }
    fi
    printf '%s\n' "$path"
    ;;
esac
