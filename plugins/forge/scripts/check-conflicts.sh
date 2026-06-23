#!/usr/bin/env bash
#
# check-conflicts.sh - warn about sequential-merge collisions among open forge PRs.
#
# Forge cuts every task branch from the base independently, so two tasks that
# edit the same file open as PRs that each merge cleanly against the base on
# their own, yet conflict the instant one is merged before the other (a
# sequential-merge conflict). A host's per-PR "mergeable" flag never reports
# this: it only checks each PR against the current base, not against its
# siblings. This script simulates the pairwise three-way merges with
# `git merge-tree`, which writes nothing to the working tree or index, and
# reports which open forge PRs will collide and on which files - so a human can
# merge them in a deliberate order (or split the shared file into a
# registry/extension point) instead of discovering the conflict mid-merge.
#
# It also reports STACKED pairs: when one PR's branch was cut on top of another
# (so its history already contains the other's commits), the two never show as a
# file conflict, yet merge order is load-bearing - merging the descendant first
# silently pulls the contained PR in with it. File-overlap alone is blind to
# this; ancestry (`git merge-base --is-ancestor`) catches it.
#
# Usage:
#   check-conflicts.sh [base_branch]
#       Inspect every open PR whose head branch is under "forge/" and whose
#       base is base_branch, discovered via the configured VCS CLI (gh).
#   check-conflicts.sh --base <branch> --refs "<refA> <refB> ..."
#       Skip PR discovery and check the given git refs directly. Used by the
#       tests and as a fallback when no VCS CLI is available.
#
# base_branch resolves from: the argument, else config base_branch, else
# "develop". The exit status is 0 whenever the check runs (a collision is a
# warning, not a failure); it is non-zero only on a usage or environment error.
#
# Deps: git (>= 2.38 for `merge-tree --write-tree`), jq; gh for PR discovery.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

forge_require git || exit 2

base=""
refs_arg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) base="${2:-}"; shift 2 ;;
    --refs) refs_arg="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --*) echo "check-conflicts: unknown flag '$1'" >&2; exit 2 ;;
    *) [ -z "$base" ] && base="$1" && shift || { echo "check-conflicts: unexpected argument '$1'" >&2; exit 2; } ;;
  esac
done
[ -n "$base" ] || base="$(config_get base_branch develop)"

cd "$TARGET" || { echo "check-conflicts: cannot enter target repo: $TARGET" >&2; exit 2; }
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "check-conflicts: $TARGET is not a git repository" >&2
  exit 2
fi

refs=()
labels=()

if [ -n "$refs_arg" ]; then
  # Explicit refs: label each by its own name.
  for b in $refs_arg; do
    r="$(forge_resolve_ref "$b")"
    if [ -z "$r" ]; then
      echo "check-conflicts: ref not found, skipping: $b" >&2
      continue
    fi
    refs+=("$r")
    labels+=("$b")
  done
else
  # Discover open forge PRs through the VCS CLI. Only gh is supported for
  # discovery today; for any other host, fall back to scanning local forge/
  # branches that are ahead of the base.
  cli="$(config_get vcs.cli "")"
  [ -n "$cli" ] || cli="gh"
  if [ "$cli" = "gh" ] && command -v gh >/dev/null 2>&1; then
    git fetch --quiet origin >/dev/null 2>&1 || true
    prs_json="$(gh pr list --state open --base "$base" --json number,headRefName,title 2>/dev/null)" || prs_json="[]"
    while IFS=$'\t' read -r num head title; do
      [ -n "$head" ] || continue
      r="$(forge_resolve_ref "$head")"
      [ -n "$r" ] || continue
      refs+=("$r")
      labels+=("PR #$num ($title)")
    done < <(printf '%s' "$prs_json" | jq -r '.[] | select(.headRefName | startswith("forge/")) | [.number, .headRefName, .title] | @tsv')
  else
    echo "check-conflicts: PR discovery needs gh; scanning local forge/ branches instead." >&2
    while read -r b; do
      [ -n "$b" ] || continue
      git rev-parse --verify --quiet "$base" >/dev/null || continue
      [ -n "$(git log --oneline "$base..$b" 2>/dev/null)" ] || continue
      refs+=("$b")
      labels+=("$b")
    done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/forge/*')
  fi
fi

echo "forge: pre-merge conflict check (base: $base)"

n=${#refs[@]}
if [ "$n" -lt 2 ]; then
  echo "  fewer than two open forge PRs to compare; nothing to check."
  exit 0
fi

# Pairwise check. First test ancestry: a stacked pair (one branch contains the
# other) never conflicts on merge-tree, so report the stack and skip the merge
# sim for that pair. Otherwise simulate the three-way merge - merge-tree exits 0
# on a clean merge and 1 on conflicts; anything higher is a real error (e.g.
# unrelated histories).
collisions=0
stacks=0
i=0
while [ "$i" -lt "$n" ]; do
  j=$((i + 1))
  while [ "$j" -lt "$n" ]; do
    if git merge-base --is-ancestor "${refs[$i]}" "${refs[$j]}" 2>/dev/null; then
      stacks=$((stacks + 1))
      echo "  STACK     ${labels[$j]}  contains  ${labels[$i]}"
      echo "              merge ${labels[$i]} first; it is part of ${labels[$j]}'s history."
    elif git merge-base --is-ancestor "${refs[$j]}" "${refs[$i]}" 2>/dev/null; then
      stacks=$((stacks + 1))
      echo "  STACK     ${labels[$i]}  contains  ${labels[$j]}"
      echo "              merge ${labels[$j]} first; it is part of ${labels[$i]}'s history."
    else
      out="$(git merge-tree --write-tree --name-only "${refs[$i]}" "${refs[$j]}" 2>&1)"
      rc=$?
      if [ "$rc" -eq 1 ]; then
        collisions=$((collisions + 1))
        files="$(printf '%s\n' "$out" | awk 'NR==1{next} /^$/{exit} {print}')"
        echo "  CONFLICT  ${labels[$i]}  <->  ${labels[$j]}"
        if [ -n "$files" ]; then
          printf '%s\n' "$files" | sed 's/^/              /'
        else
          echo "              (shared files; run the merge to see them)"
        fi
      elif [ "$rc" -gt 1 ]; then
        echo "  SKIP      ${labels[$i]}  <->  ${labels[$j]}  (cannot compare: ${out%%$'\n'*})"
      fi
    fi
    j=$((j + 1))
  done
  i=$((i + 1))
done

echo
if [ "$collisions" -eq 0 ] && [ "$stacks" -eq 0 ]; then
  echo "  no overlaps: all $n open forge PRs merge cleanly and independently."
else
  if [ "$stacks" -gt 0 ]; then
    echo "  $stacks stacked pair(s): one PR's branch already contains another's commits."
    echo "  They never show as a file conflict, but merge order is load-bearing - merge"
    echo "  the contained PR first, or the later merge silently pulls it in. Treat a"
    echo "  stack as an ordered series, not independent PRs."
  fi
  if [ "$collisions" -gt 0 ]; then
    echo "  $collisions pair(s) will conflict on sequential merge. Merge one, then"
    echo "  rebase/resolve the rest in order - or move the shared file behind a"
    echo "  registry/extension point so the tasks stop co-editing it."
  fi
fi
exit 0
