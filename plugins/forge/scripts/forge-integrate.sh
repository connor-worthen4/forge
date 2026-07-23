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
# the acceptance criteria as a checklist, a line noting verify and review passed,
# and the standard "Opened by forge" footer.
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
#   "base":...,"reason":...}. reason is null unless blocked/fail.
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

# write_pr_json <url> <number>: record the durable PR artifact the workflow maps.
write_pr_json() {
  local url="$1" num="$2"
  mkdir -p "$run_dir"
  jq -n --arg url "$url" --arg number "$num" --arg branch "$branch" --arg base "$base" \
    '{pr_url:$url,
      number:(if ($number|length)>0 then ($number|tonumber) else null end),
      branch:$branch, base:$base}' \
    > "$run_dir/pr.json"
}

# result <status> <exit-code> <pr_url|""> <number|""> <reason|"">: print the
# structured outcome the agent parses, then exit.
result() {
  local status="$1" code="$2" pr_url="$3" number="$4" reason="$5"
  jq -n --arg status "$status" --arg pr_url "$pr_url" --arg number "$number" \
    --arg branch "$branch" --arg base "$base" --arg reason "$reason" \
    '{status:$status,
      pr_url:(if ($pr_url|length)>0 then $pr_url else null end),
      number:(if ($number|length)>0 then ($number|tonumber) else null end),
      branch:(if ($branch|length)>0 then $branch else null end),
      base:(if ($base|length)>0 then $base else null end),
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

# Idempotency: reuse an open PR a crashed earlier run may have already created.
existing_url=""
existing_num=""
case "$cli" in
  gh)
    found="$(gh pr list --head "$branch" --state open --json url,number 2>/dev/null)" || found="[]"
    existing_url="$(printf '%s' "$found" | jq -r '.[0].url // empty' 2>/dev/null)"
    existing_num="$(printf '%s' "$found" | jq -r '.[0].number // empty' 2>/dev/null)"
    ;;
  glab)
    found="$(glab mr list --source-branch "$branch" 2>/dev/null)" || found=""
    existing_url="$(printf '%s' "$found" | grep -Eo 'https?://[^ ]+' | head -n1)"
    ;;
esac
if [ -n "$existing_url" ]; then
  write_pr_json "$existing_url" "$existing_num"
  result ok 0 "$existing_url" "$existing_num" ""
fi

# Push the branch. Auth/permission rejections are recoverable by a human (blocked);
# any other push failure is a real error (fail).
push_err="$(git push -u origin "$branch" 2>&1)"
if [ "$?" -ne 0 ]; then
  if printf '%s' "$push_err" | grep -Eqi 'denied|permission|authentication|not authorized|403|401'; then
    result blocked 3 "" "" "push rejected (authentication/permissions): ${push_err##*$'\n'}"
  fi
  result fail 1 "" "" "git push failed: ${push_err##*$'\n'}"
fi

# Build the PR title: the spec title with a conventional prefix by task type.
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
  echo "verify and review passed (artifacts under .forge/runs/$task_id/)."
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
