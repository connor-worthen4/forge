#!/usr/bin/env bash
#
# approve-plan.sh <task_id> [--request-changes "<feedback>"] - the human side
# of the tier-2 plan gate.
#
# A tier-2 task parks at plan_gate after the plan phase. This script records
# the human's decision:
#
#   approve (default)   plan_gate -> building. The run record resumes at the
#                       build phase and the queue entry goes back to pending,
#                       so the next runner pass (forge-run.sh or /forge-fix)
#                       picks it up and drives the tier-1 loop to a PR.
#
#   --request-changes   plan_gate -> planning. The feedback is written to
#                       .forge/runs/<task_id>/plan-feedback.md (overwriting any
#                       previous round); the plan phase reads it, revises the
#                       plan, and the task parks at plan_gate again.
#
# Refuses to act on a task that is not at plan_gate. Prints the resulting
# state. Deps: jq, python3, forge-lib.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

usage() {
  echo "usage: approve-plan.sh <task_id> [--request-changes \"<feedback>\"]" >&2
  exit 2
}

task_id="${1:-}"
[ -n "$task_id" ] || usage
shift

mode="approve"
feedback=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request-changes)
      mode="changes"
      feedback="${2:-}"
      [ -n "$feedback" ] || { echo "approve-plan: --request-changes needs a non-empty feedback string" >&2; exit 2; }
      shift 2
      ;;
    *) usage ;;
  esac
done

run_json="$RUNS_DIR/$task_id/run.json"
if [ ! -f "$run_json" ]; then
  echo "approve-plan: no run record for '$task_id' ($run_json)" >&2
  exit 1
fi

status="$(jq -r '.status // ""' "$run_json" 2>/dev/null || echo "")"
if [ "$status" != "plan_gate" ]; then
  echo "approve-plan: task '$task_id' is at '$status', not plan_gate; nothing to approve" >&2
  exit 1
fi

plan_file="$RUNS_DIR/$task_id/plan.md"
[ -f "$plan_file" ] || echo "approve-plan: warning: no plan.md found at $plan_file" >&2

if [ "$mode" = "approve" ]; then
  run_update "$task_id" '{"status":"building","current_phase":"build"}'
  queue_set_status "$task_id" pending
  echo "approved: $task_id will resume at build on the next runner pass"
else
  {
    printf '# Plan feedback: %s\n\n' "$task_id"
    printf 'A human reviewed plan.md at the plan gate and requested changes:\n\n'
    printf '%s\n' "$feedback"
  } > "$RUNS_DIR/$task_id/plan-feedback.md"
  run_update "$task_id" '{"status":"planning","current_phase":"plan"}'
  queue_set_status "$task_id" pending
  echo "changes requested: $task_id will re-plan on the next runner pass (feedback in plan-feedback.md)"
fi
