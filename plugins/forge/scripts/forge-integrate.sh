#!/usr/bin/env bash
#
# forge-integrate.sh - publish a verified forge branch: push it and open a PR.
#
# This is the mechanical half of the integrate phase, split out of the agent so
# the git/CLI operations run one tested path instead of being reconstructed by a
# model each time. The integrate agent invokes this, reads the structured JSON it
# prints, and translates the outcome into the phase result. The script NEVER
# merges, never approves, and never pushes a protected branch (the
# block-git-writes hook enforces that independently); a human reviews and merges
# every forge PR.
#
# It is idempotent: a crashed earlier run that already opened the PR is detected
# and reused rather than duplicated. The PR body is templated here (no model): a
# conventional-prefixed title from the spec type+title, the spec body verbatim,
# the acceptance criteria as a checklist, a line naming the gates that actually
# ran (review is absent when the fast profile skipped it), and the standard
# "Opened by forge" footer.
#
# Two modes, chosen by config:
#
#   PR mode (default). Opens a PR from the task branch into the base and stops.
#     forge never merges; a human reviews and merges every PR.
#
#   Integration mode, when .forge/config.yaml sets `integration_branch`. The task
#     branch is merged into that branch instead, and a SINGLE open PR is kept
#     from it into the base. Overnight tasks then compound on one branch and any
#     conflict is resolved somewhere disposable, leaving one PR to review in the
#     morning. A conflicting merge is aborted and reported as blocked rather than
#     guessed at - the task branch is already pushed, so nothing is lost.
#
# Usage:
#   forge-integrate.sh --task-id <id> [--run-dir <dir>] [--base <pr-target>]
#                      [--branch <branch>] [--spec <spec-file>]
#
# Resolution when a flag is omitted:
#   run-dir  .forge/runs/<task-id>
#   branch   the current branch (git rev-parse --abbrev-ref HEAD)
#   base     spec base_branch > config vcs.pr_target > config base_branch > develop
#   spec     the queue entry's file, else tasks/<task-id>.md (optional; templating
#            degrades gracefully when absent)
#
# Output: pr.json in the run dir on success, plus a structured JSON object on
#   stdout: {"status":"ok|blocked|fail","pr_url":...,"number":...,"branch":...,
#   "base":...,"merged_into":...,"reason":...}. reason is null unless
#   blocked/fail; merged_into is null in PR mode.
#
# Exit status: 0 ok | 1 fail | 3 blocked | 2 usage/environment error.
#
# Deps: git, jq, python3 (via forge-lib.sh); gh (GitHub) or glab (GitLab).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

forge_require git || exit 2

task_id=""
run_dir=""
base=""
branch=""
spec=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task-id) task_id="${2:-}"; shift 2 ;;
    --run-dir) run_dir="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;;
    --spec) spec="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    --*) echo "forge-integrate: unknown flag '$1'" >&2; exit 2 ;;
    *) echo "forge-integrate: unexpected argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$task_id" ] || { echo "forge-integrate: --task-id is required" >&2; exit 2; }
[ -n "$run_dir" ] || run_dir="$RUNS_DIR/$task_id"

cd "$TARGET" || { echo "forge-integrate: cannot enter target repo: $TARGET" >&2; exit 2; }
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "forge-integrate: $TARGET is not a git repository" >&2
  exit 2
fi

# Set once the task branch has been merged into the integration branch.
merged_into=""

# write_pr_json <url> <number>: record the durable PR artifact the workflow maps.
write_pr_json() {
  local url="$1" num="$2"
  mkdir -p "$run_dir"
  jq -n --arg url "$url" --arg number "$num" --arg branch "$branch" --arg base "$base" \
    --arg merged_into "$merged_into" \
    '{pr_url:$url,
      number:(if ($number|length)>0 then ($number|tonumber) else null end),
      branch:$branch, base:$base,
      merged_into:(if ($merged_into|length)>0 then $merged_into else null end)}' \
    > "$run_dir/pr.json"
}

# result <status> <exit-code> <pr_url|""> <number|""> <reason|"">: print the
# structured outcome the agent parses, then exit.
result() {
  local status="$1" code="$2" pr_url="$3" number="$4" reason="$5"
  jq -n --arg status "$status" --arg pr_url "$pr_url" --arg number "$number" \
    --arg branch "$branch" --arg base "$base" --arg reason "$reason" \
    --arg merged_into "$merged_into" \
    '{status:$status,
      pr_url:(if ($pr_url|length)>0 then $pr_url else null end),
      number:(if ($number|length)>0 then ($number|tonumber) else null end),
      branch:(if ($branch|length)>0 then $branch else null end),
      base:(if ($base|length)>0 then $base else null end),
      merged_into:(if ($merged_into|length)>0 then $merged_into else null end),
      reason:(if ($reason|length)>0 then $reason else null end)}'
  exit "$code"
}

# Resolve the working branch (default: current) and confirm we are on it.
[ -n "$branch" ] || branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
  result fail 1 "" "" "cannot determine the working branch (detached HEAD?)"
fi
if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$branch" ]; then
  git checkout "$branch" >/dev/null 2>&1 || result fail 1 "" "" "branch not found: $branch"
fi

# Resolve the spec file (optional) and the PR target base.
[ -n "$spec" ] || spec="$(spec_path "$task_id")"
[ -f "$spec" ] || spec=""
if [ -z "$base" ] && [ -n "$spec" ]; then base="$(spec_field "$spec" base_branch "")"; fi
[ -n "$base" ] || base="$(config_get vcs.pr_target "")"
[ -n "$base" ] || base="$(config_get base_branch develop)"

# Precondition: clean working tree, ignoring forge's own runtime files under
# .forge/ (a run in progress writes artifacts there).
if [ -n "$(git status --porcelain -- . ':(exclude).forge' 2>/dev/null)" ]; then
  result fail 1 "" "" "working tree not clean; an earlier phase left uncommitted changes"
fi

# Precondition: commits ahead of the base. Skip only when the base ref does not
# resolve yet (a greenfield repo) - the push below is the real gate there.
base_ref="$(forge_resolve_ref "$base")"
if [ -n "$base_ref" ] && [ -z "$(git log "$base_ref"..HEAD --oneline 2>/dev/null)" ]; then
  result fail 1 "" "" "branch $branch has no commits ahead of $base"
fi

# A missing remote is a human's job, not a failure - the work is ready locally.
if ! git remote get-url origin >/dev/null 2>&1; then
  result blocked 3 "" "" "no git remote 'origin' configured; add one (git remote add origin <url>) and re-run. The branch and commits are ready locally."
fi

cli="$(config_get vcs.cli "")"
if [ -z "$cli" ]; then
  [ "$(config_get vcs.host github)" = "gitlab" ] && cli="glab" || cli="gh"
fi
command -v "$cli" >/dev/null 2>&1 || result fail 1 "" "" "VCS CLI not found: $cli"

# find_open_pr <head-branch>: set FOUND_URL/FOUND_NUM to an already-open PR for
# that head, or empty. Used both for PR-mode idempotency (a crashed run may have
# opened the PR already) and to keep integration mode at exactly one open PR.
FOUND_URL=""
FOUND_NUM=""
find_open_pr() {
  local head="$1" found=""
  FOUND_URL=""; FOUND_NUM=""
  case "$cli" in
    gh)
      found="$(gh pr list --head "$head" --state open --json url,number 2>/dev/null)" || found="[]"
      FOUND_URL="$(printf '%s' "$found" | jq -r '.[0].url // empty' 2>/dev/null)"
      FOUND_NUM="$(printf '%s' "$found" | jq -r '.[0].number // empty' 2>/dev/null)"
      ;;
    glab)
      found="$(glab mr list --source-branch "$head" 2>/dev/null)" || found=""
      FOUND_URL="$(printf '%s' "$found" | grep -Eo 'https?://[^ ]+' | head -n1)"
      ;;
  esac
}

# The task branch is pushed in BOTH modes: in PR mode it is the PR's head, and in
# integration mode it is the durable record of the task's own work, so the merge
# into the integration branch is never the only copy of it.
push_err="$(git push -u origin "$branch" 2>&1)"
if [ "$?" -ne 0 ]; then
  if printf '%s' "$push_err" | grep -Eqi 'denied|permission|authentication|not authorized|403|401'; then
    result blocked 3 "" "" "push rejected (authentication/permissions): ${push_err##*$'\n'}"
  fi
  result fail 1 "" "" "git push failed: ${push_err##*$'\n'}"
fi

# The task's human-readable title, used for the PR title in PR mode and the merge
# commit subject in integration mode.
title_raw=""
type_raw=""
if [ -n "$spec" ]; then
  title_raw="$(spec_field "$spec" title "")"
  type_raw="$(spec_field "$spec" type "")"
fi
[ -n "$title_raw" ] || title_raw="$task_id"
case "$type_raw" in
  fix) title="fix: $title_raw" ;;
  build) title="feat: $title_raw" ;;
  refactor) title="refactor: $title_raw" ;;
  chore) title="chore: $title_raw" ;;
  *) title="$title_raw" ;;
esac

integration_branch="$(config_get integration_branch "")"

if [ -n "$integration_branch" ]; then
  # ---- Integration mode --------------------------------------------------
  #
  # The merge cannot happen in the task's own tree: it would have to leave the
  # task branch, and git refuses to check out one branch in two worktrees at
  # once, which is exactly what parallel tasks would attempt. So every task
  # merges in ONE dedicated worktree holding the integration branch, serialized
  # by a lock. Concurrency here would interleave two merges on one ref.
  lock_dir="$FORGE_DIR/integration.lock"
  LOCK_HELD=0
  release_lock() { [ "$LOCK_HELD" = "1" ] && rmdir "$lock_dir" 2>/dev/null; LOCK_HELD=0; }
  trap release_lock EXIT

  mkdir -p "$FORGE_DIR"
  waited=0
  # mkdir is atomic, so it is the lock. A stale lock from a killed run is the
  # one failure mode; it surfaces as a clear blocked message rather than a hang.
  until mkdir "$lock_dir" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge 300 ]; then
      result blocked 3 "" "" "timed out after ${waited}s waiting for the integration-branch lock ($lock_dir). If no other forge run is active, remove that directory and re-run."
    fi
  done
  LOCK_HELD=1

  int_wt="$("$SCRIPT_DIR/forge-worktree.sh" add __integration \
    --branch "$integration_branch" --base "$base" 2>/dev/null)"
  if [ -z "$int_wt" ] || [ ! -d "$int_wt" ]; then
    result fail 1 "" "" "could not prepare a worktree for integration branch $integration_branch"
  fi

  # Start from what the remote already has, so tasks merged by an earlier run
  # (or another machine) are present and this merge lands on top of them.
  git -C "$int_wt" fetch --quiet origin >/dev/null 2>&1 || true
  if git -C "$int_wt" rev-parse --verify --quiet "origin/$integration_branch" >/dev/null; then
    git -C "$int_wt" merge --ff-only "origin/$integration_branch" >/dev/null 2>&1 || true
  fi

  merge_msg="forge: merge $task_id${title_raw:+ ($title_raw)}"
  merge_err="$(git -C "$int_wt" merge --no-ff -m "$merge_msg" "$branch" 2>&1)"
  if [ "$?" -ne 0 ]; then
    conflicts="$(git -C "$int_wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
    git -C "$int_wt" merge --abort >/dev/null 2>&1
    # Never guess at a resolution. The task branch is pushed and intact, so the
    # work is safe; a human resolves this on the integration branch, which is
    # precisely the disposable place to do it.
    if [ -n "$conflicts" ]; then
      result blocked 3 "" "" "merging $branch into $integration_branch conflicts in: ${conflicts%% }. The task branch is pushed and intact; resolve on $integration_branch and re-run."
    fi
    result blocked 3 "" "" "merging $branch into $integration_branch failed: ${merge_err##*$'\n'}"
  fi

  push_err="$(git -C "$int_wt" push origin "$integration_branch" 2>&1)"
  if [ "$?" -ne 0 ]; then
    if printf '%s' "$push_err" | grep -Eqi 'denied|permission|authentication|not authorized|403|401'; then
      result blocked 3 "" "" "push of $integration_branch rejected (authentication/permissions): ${push_err##*$'\n'}"
    fi
    result fail 1 "" "" "pushing $integration_branch failed: ${push_err##*$'\n'}"
  fi
  merged_into="$integration_branch"

  # Exactly one PR out of the integration branch, reused across every task.
  find_open_pr "$integration_branch"
  if [ -n "$FOUND_URL" ]; then
    write_pr_json "$FOUND_URL" "$FOUND_NUM"
    release_lock
    result ok 0 "$FOUND_URL" "$FOUND_NUM" ""
  fi

  int_body="$(mktemp)"
  {
    echo "Rolled-up forge work merged into \`$integration_branch\`."
    echo
    echo "Each task was verified (and reviewed, unless its profile skipped review) on its"
    echo "own branch before being merged here. Per-task artifacts are under .forge/runs/."
    echo
    echo "Review this branch as a whole and merge it into \`$base\` when it looks right."
    echo
    echo "Opened by forge. Forge merges only into $integration_branch, never into $base."
  } > "$int_body"
  case "$cli" in
    gh)
      pr_out="$(gh pr create --base "$base" --head "$integration_branch" \
        --title "forge: integration -> $base" --body-file "$int_body" 2>&1)"
      pr_rc=$?
      ;;
    glab)
      pr_out="$(glab mr create --source-branch "$integration_branch" --target-branch "$base" \
        --title "forge: integration -> $base" --description "$(cat "$int_body")" --yes 2>&1)"
      pr_rc=$?
      ;;
  esac
  rm -f "$int_body"
  if [ "$pr_rc" -ne 0 ]; then
    # The merge already landed and is pushed, so this is not a failure of the
    # task - only of opening the roll-up PR, which a human can do by hand.
    result blocked 3 "" "" "merged into $integration_branch, but opening the PR into $base failed: ${pr_out##*$'\n'}"
  fi
  pr_url="$(printf '%s' "$pr_out" | grep -Eo 'https?://[^ ]+' | tail -n1)"
  pr_num="$(printf '%s' "$pr_url" | grep -Eo '[0-9]+$' || true)"
  write_pr_json "$pr_url" "$pr_num"
  release_lock
  result ok 0 "$pr_url" "$pr_num" ""
fi

# ---- PR mode (default) ---------------------------------------------------
# Idempotency: reuse an open PR a crashed earlier run may have already created.
find_open_pr "$branch"
if [ -n "$FOUND_URL" ]; then
  write_pr_json "$FOUND_URL" "$FOUND_NUM"
  result ok 0 "$FOUND_URL" "$FOUND_NUM" ""
fi

# Build the PR body: spec body verbatim, criteria checklist, status line, footer.
body_file="$(mktemp)"
{
  if [ -n "$spec" ]; then
    python3 - "$spec" <<'PY'
import sys, re
txt = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r'^﻿?\s*---[ \t]*\r?\n.*?\r?\n---[ \t]*\r?\n?', txt, re.DOTALL)
print((txt[m.end():] if m else txt).strip())
PY
  else
    printf 'Automated change produced by forge for task %s.' "$task_id"
  fi
  echo
  echo
  echo "Acceptance criteria:"
  if [ -n "$spec" ]; then
    spec_field "$spec" acceptance_criteria "[]" | jq -r '.[]? | "- [ ] " + .' 2>/dev/null
  fi
  echo
  # Report only the gates that actually ran: the fast profile skips review for a
  # small diff, and a PR must never claim a pass that nothing produced.
  if [ -f "$run_dir/review.md" ]; then
    echo "verify and review passed (artifacts under .forge/runs/$task_id/)."
  else
    echo "verify passed; review was not run for this task (artifacts under .forge/runs/$task_id/)."
  fi
  echo
  echo "Opened by forge. Forge never merges; a human reviews and merges this PR."
} > "$body_file"

case "$cli" in
  gh)
    pr_out="$(gh pr create --base "$base" --head "$branch" --title "$title" --body-file "$body_file" 2>&1)"
    pr_rc=$?
    ;;
  glab)
    pr_out="$(glab mr create --source-branch "$branch" --target-branch "$base" --title "$title" --description "$(cat "$body_file")" --yes 2>&1)"
    pr_rc=$?
    ;;
esac
rm -f "$body_file"

if [ "$pr_rc" -ne 0 ]; then
  if printf '%s' "$pr_out" | grep -Eqi 'denied|permission|authentication|not authorized|403|401'; then
    result blocked 3 "" "" "PR creation rejected (authentication/permissions): ${pr_out##*$'\n'}"
  fi
  result fail 1 "" "" "$cli PR creation failed: ${pr_out##*$'\n'}"
fi

# The CLI prints the PR/MR URL; take the last URL it emitted and derive the number
# from the trailing path segment when numeric.
pr_url="$(printf '%s' "$pr_out" | grep -Eo 'https?://[^ ]+' | tail -n1)"
[ -n "$pr_url" ] || result fail 1 "" "" "PR opened but no URL was returned by $cli"
pr_num="$(printf '%s' "$pr_url" | grep -Eo '[0-9]+$' || true)"

write_pr_json "$pr_url" "$pr_num"
result ok 0 "$pr_url" "$pr_num" ""
