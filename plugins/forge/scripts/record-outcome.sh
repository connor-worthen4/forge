#!/usr/bin/env bash
#
# record-outcome.sh - persist one task's pipeline outcome to disk.
#
# The forge-run workflow runs in a sandbox and cannot write files, so after it
# returns, the launcher commands call this script once per task to stamp the
# durable state: the task's run record (.forge/runs/<id>/run.json) and its queue
# status (.forge/queue.json). The phase agents already wrote their own artifacts;
# this records the final state and maps the artifacts that exist.
#
# Usage:
#   record-outcome.sh <task-id> <final> [phase] [pr_url] [branch] [reason]
#     final : done | pr_open | plan_gate | blocked | failed
#     phase : the phase the run ended on (defaults from final)
#
# Deps: jq, python3, forge-lib.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

task_id="${1:?usage: record-outcome.sh <task-id> <final> [phase] [pr_url] [branch] [reason]}"
final="${2:?usage: record-outcome.sh <task-id> <final> [phase] [pr_url] [branch] [reason]}"
phase="${3:-}"
pr_url="${4:-}"
branch="${5:-}"
reason="${6:-}"

case "$final" in
  done|pr_open|plan_gate|blocked|failed) ;;
  *) echo "record-outcome: invalid final state '$final'" >&2; exit 2 ;;
esac

# Default current_phase from the final state when the caller did not pass one.
if [ -z "$phase" ]; then
  case "$final" in
    done) phase="report" ;;
    pr_open) phase="integrate" ;;
    plan_gate) phase="plan" ;;
    *) phase="build" ;;
  esac
fi

run_dir="$RUNS_DIR/$task_id"
mkdir -p "$run_dir"

# Build the run.json fragment (artifacts map, status, phase, branch, pr, error).
fragment="$(python3 - "$run_dir" "$final" "$phase" "$pr_url" "$branch" "$reason" <<'PY'
import sys, os, json
run_dir, final, phase, pr_url, branch, reason = sys.argv[1:7]
frag = {"status": final, "current_phase": phase}
frag["branch_name"] = branch or None
frag["pr_url"] = pr_url or None
if final in ("blocked", "failed") and reason:
    frag["error"] = {"message": reason, "phase": phase}
artifacts = {}
for key, fn in [("intake", "context-brief.md"), ("plan", "plan.md"),
                ("diff", "diff.patch"), ("verdict", "verify.md"),
                ("review", "review.md"), ("report", "report.md"),
                ("pr", "pr.json"), ("transcript", "transcript.log")]:
    fp = os.path.join(run_dir, fn)
    if os.path.exists(fp):
        artifacts[key] = fp
if artifacts:
    frag["artifacts"] = artifacts
print(json.dumps(frag))
PY
)"

run_update "$task_id" "$fragment"
queue_set_status "$task_id" "$final"

# A re-plan request (plan-feedback.md) is consumed once the task advances past
# the gate; clear it so it does not force another re-plan on the next run. It
# stays in place while the task is still parked at the gate.
if [ "$final" != "plan_gate" ] && [ -f "$run_dir/plan-feedback.md" ]; then
  rm -f "$run_dir/plan-feedback.md"
fi

echo "$task_id -> $final"
