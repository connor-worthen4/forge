#!/usr/bin/env bash
#
# forge-diff.sh - print a task branch's diff against the up-to-date base.
#
# Every code-aware phase (build files it, verify checks it is non-empty, review
# reads it) needs the same thing: the diff of the current branch against the
# base as the host will see it after merge. Computing that against the LOCAL
# base ref is a trap. A local base branch is not refreshed when sibling PRs
# merge into the remote, so `git merge-base <local-base> HEAD` resolves to an
# old commit and the diff drags in every file those siblings already landed -
# observed in the wild as a 485KB / 44-file diff that should have been 12 files,
# then fed (and re-read) by four agent passes.
#
# This script refreshes the remote-tracking refs and diffs against origin/<base>
# when it exists, falling back to the local base only when there is no remote
# (a greenfield repo). The merge-base against an up-to-date origin/<base>
# excludes any sibling work already merged there, so the diff is scoped to this
# task alone.
#
# Usage:
#   forge-diff.sh [base_branch]
#       base_branch resolves from: the argument, else config base_branch, else
#       "develop". Prints the unified diff to stdout (empty when the branch has
#       no changes against the base).
#
# Exit status: 0 on success (including an empty diff); 2 on an environment error
# (not a git repo, no merge-base with the base).
#
# Deps: git.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

forge_require git || exit 2

base=""
case "${1:-}" in
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) base="${1:-}" ;;
esac
[ -n "$base" ] || base="$(config_get base_branch develop)"

cd "$TARGET" || { echo "forge-diff: cannot enter target repo: $TARGET" >&2; exit 2; }
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "forge-diff: $TARGET is not a git repository" >&2
  exit 2
fi

# Refresh remote-tracking refs so origin/<base> reflects sibling PRs that merged
# since the last fetch. Best effort: an offline run or a repo with no remote
# falls through to the local base ref below.
git fetch --quiet origin >/dev/null 2>&1 || true

base_ref="$(forge_resolve_ref "$base")"
if [ -z "$base_ref" ]; then
  echo "forge-diff: base branch not found locally or on origin: $base" >&2
  exit 2
fi

merge_base="$(git merge-base "$base_ref" HEAD 2>/dev/null)"
if [ -z "$merge_base" ]; then
  echo "forge-diff: no common ancestor between $base_ref and HEAD" >&2
  exit 2
fi

git diff "$merge_base" HEAD
