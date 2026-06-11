#!/usr/bin/env bash
#
# run-task.sh <task_id> - the shared pipeline driver (state machine).
#
# Reads the task spec, derives the pipeline shape from its type/tier, and steps
# the state machine by calling run-phase.sh per phase. Honors the
# verify->build and review->build recovery loops, capped at budget.max_attempts.
#
#   fix / refactor / chore : linear tier-1 -> pr_open
#   audit / investigate    : tier-0 read-only -> report.md -> done
#   build (or require_gate) : gated tier-2 -> plan_gate (parked for approval)
#
# Status flow:
#   pending -> planning -> [plan_gate] -> building -> verifying -> reviewing
#           -> integrating -> pr_open      (done only when the PR merges; see
#                                           sync-merged.sh -- the runner never merges)
#
# Crash recovery: if the run record shows an in-progress/incomplete phase, the
# task resumes at that phase (re-running it; phases are idempotent). Terminal or
# parked states (done/pr_open/failed/plan_gate) are no-ops.
#
# Prints the final state (pr_open|done|plan_gate|blocked|failed) on stdout.
# Deps: jq, python3, forge-lib.sh, run-phase.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

task_id="${1:?usage: run-task.sh <task_id>}"
run_dir="$RUNS_DIR/$task_id"
mkdir -p "$run_dir"

RESULT_STATUS=""
RESULT_REASON=""

# --- small helpers ----------------------------------------------------------
json_str() { if [ -z "${1:-}" ]; then printf 'null'; else printf '%s' "$1" | jq -R .; fi; }

run_get() {
  [ -f "$run_dir/run.json" ] || { printf '%s' "${2:-}"; return; }
  jq -r --arg k "$1" --arg d "${2:-}" '(.[$k]) // $d' "$run_dir/run.json" 2>/dev/null || printf '%s' "${2:-}"
}

in_list() {  # in_list <json-array> <value> -> 0 if present
  printf '%s' "$1" | python3 -c '
import sys, json
try:
    a = json.load(sys.stdin)
except Exception:
    a = []
sys.exit(0 if sys.argv[1] in a else 1)' "$2"
}

branch_json() { if [ "$tier" = "0" ]; then printf 'null'; else json_str "$branch"; fi; }

set_state() {  # set_state <status> <current_phase>
  queue_set_status "$task_id" "$1"
  run_update "$task_id" "$(printf '{"status":%s,"current_phase":%s,"branch_name":%s}' \
    "$(json_str "$1")" "$(json_str "$2")" "$(branch_json)")"
}

finalize_artifacts() {
  python3 - "$run_dir" <<'PY'
import os, sys, json
from datetime import datetime, timezone
rd = sys.argv[1]
p = os.path.join(rd, "run.json")
d = json.load(open(p)) if os.path.exists(p) else {}
m = {}
for key, fn in [("intake", "context-brief.md"), ("plan", "plan.md"), ("diff", "diff.patch"),
                ("verdict", "verify.md"), ("review", "review.md"), ("report", "report.md"),
                ("pr", "pr.json"), ("transcript", "transcript.log")]:
    fp = os.path.join(rd, fn)
    if os.path.exists(fp):
        m[key] = fp
d["artifacts"] = m
d["updated_at"] = datetime.now(timezone.utc).isoformat()
json.dump(d, open(p, "w"), indent=2)
PY
}

run_one() {  # run_one <phase> ; sets RESULT_STATUS / RESULT_REASON
  local res
  res="$("$SCRIPT_DIR/run-phase.sh" "$task_id" "$1")" || true
  RESULT_STATUS="$(printf '%s' "$res" | jq -r '.status // "fail"' 2>/dev/null || echo fail)"
  RESULT_REASON="$(printf '%s' "$res" | jq -r '.blocked_reason // ""' 2>/dev/null || echo "")"
}

park_blocked() {  # park_blocked <reason>
  queue_set_status "$task_id" blocked
  run_update "$task_id" "$(printf '{"status":"blocked","error":{"message":%s,"phase":%s}}' \
    "$(json_str "$1")" "$(json_str "${current_phase:-}")")"
  finalize_artifacts
  echo "blocked"
}

mark_failed() {  # mark_failed <reason> <phase>
  queue_set_status "$task_id" failed
  run_update "$task_id" "$(printf '{"status":"failed","error":{"message":%s,"phase":%s}}' \
    "$(json_str "$1")" "$(json_str "$2")")"
  finalize_artifacts
  echo "failed"
}

# Run a non-looping phase; on non-ok park/fail and signal the driver to stop.
gate() {  # gate <phase> -> 0 ok, 1 stop
  current_phase="$1"
  case "$RESULT_STATUS" in
    ok) return 0 ;;
    blocked) park_blocked "${RESULT_REASON:-blocked at $1}" >/dev/null; echo "blocked"; return 1 ;;
    *) mark_failed "${RESULT_REASON:-failed at $1}" "$1" >/dev/null; echo "failed"; return 1 ;;
  esac
}

# Merge/rebase STUB. forge never merges; the runner ends at pr_open. Repo-standard
# merge/rebase logic slots in here, gated on config.merge_policy (currently unset
# -> no-op; adding it requires a project-config schema field).
maybe_merge() {
  local policy
  policy="$(config_get "merge_policy" "")"
  if [ -n "$policy" ]; then
    printf 'note: merge_policy=%s set but auto-merge is intentionally not implemented; PR left open for human review.\n' \
      "$policy" >> "$run_dir/transcript.log"
  fi
  return 0
}

# --- locate spec & derive shape --------------------------------------------
spec="$(queue_get "$task_id" file "")"
if [ -z "$spec" ] || [ ! -f "$spec" ]; then spec="$TARGET/tasks/$task_id.md"; fi
if [ ! -f "$spec" ]; then
  mark_failed "task spec not found" "intake"
  exit 1
fi

type="$(spec_field "$spec" type fix)"
spec_tier="$(spec_field "$spec" autonomy_tier "")"
title="$(spec_field "$spec" title "$task_id")"
base_branch="$(spec_field "$spec" base_branch "")"
[ -n "$base_branch" ] || base_branch="$(config_get base_branch develop)"
default_tier="$(config_get autonomy.default_tier 1)"
require_gate="$(config_get autonomy.require_gate '["build"]')"
max_attempts="$(config_get budget.max_attempts 2)"

# Effective tier.
case "$type" in
  audit|investigate) tier=0 ;;
  *)
    tier="${spec_tier:-$default_tier}"
    if in_list "$require_gate" "$type"; then tier=2; fi
    ;;
esac

slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-48)"
branch="forge/$type/$task_id-$slug"
current_phase="intake"

# --- resume point -----------------------------------------------------------
cur_status="$(run_get status "")"
cur_phase="$(run_get current_phase "")"
case "$cur_status" in
  done|pr_open|failed) echo "$cur_status"; exit 0 ;;
  plan_gate) echo "plan_gate"; exit 0 ;;
  ""|pending) start="intake" ;;
  *) start="${cur_phase:-intake}" ;;
esac

run_update "$task_id" "$(printf '{"task_id":%s,"branch_name":%s}' "$(json_str "$task_id")" "$(branch_json)")"

# --- tier 0: read-only -> report -> done ------------------------------------
drive_tier0() {
  case "$1" in
    plan)   ;;
    report) ;;
    *) set_state pending intake;  run_one intake;  gate intake  || return ;;
  esac
  case "$1" in
    report) ;;
    *) set_state planning plan;   run_one plan;    gate plan    || return ;;
  esac
  set_state planning report;      run_one report;  gate report  || return
  finalize_artifacts
  queue_set_status "$task_id" done
  run_update "$task_id" '{"status":"done","current_phase":"report"}'
  echo "done"
}

# --- tier 2: gated -> plan_gate (parked) ------------------------------------
drive_tier2() {
  case "$1" in
    plan) ;;
    *) set_state pending intake; run_one intake; gate intake || return ;;
  esac
  set_state planning plan; run_one plan; gate plan || return
  finalize_artifacts
  queue_set_status "$task_id" plan_gate
  run_update "$task_id" '{"status":"plan_gate","current_phase":"plan"}'
  echo "plan_gate"
}

# --- tier 1: linear with build/verify/review loop -> pr_open -----------------
drive_tier1() {
  local start="$1" entry="build" skip_loop=0
  case "$start" in
    intake) set_state pending intake; run_one intake; gate intake || return
            set_state planning plan;  run_one plan;   gate plan   || return ;;
    plan)   set_state planning plan;  run_one plan;   gate plan   || return ;;
    build)  entry="build" ;;
    verify) entry="verify" ;;
    review) entry="review" ;;
    integrate) skip_loop=1 ;;
    *) set_state pending intake; run_one intake; gate intake || return
       set_state planning plan;  run_one plan;   gate plan   || return ;;
  esac

  if [ "$skip_loop" = 0 ]; then
    local attempt=1
    while : ; do
      if [ "$entry" = "build" ]; then
        current_phase="build"; set_state building build; run_one build; gate build || return
      fi
      if [ "$entry" = "build" ] || [ "$entry" = "verify" ]; then
        current_phase="verify"; set_state verifying verify; run_one verify
        if [ "$RESULT_STATUS" = "blocked" ]; then park_blocked "${RESULT_REASON:-blocked at verify}"; return; fi
        if [ "$RESULT_STATUS" != "ok" ]; then
          attempt=$((attempt + 1))
          if [ "$attempt" -gt "$max_attempts" ]; then park_blocked "verify failed; max_attempts ($max_attempts) reached"; return; fi
          run_update "$task_id" "$(printf '{"attempt_n":%s}' "$attempt")"
          entry="build"; continue
        fi
      fi
      current_phase="review"; set_state reviewing review; run_one review
      if [ "$RESULT_STATUS" = "blocked" ]; then park_blocked "${RESULT_REASON:-blocked at review}"; return; fi
      if [ "$RESULT_STATUS" != "ok" ]; then
        attempt=$((attempt + 1))
        if [ "$attempt" -gt "$max_attempts" ]; then park_blocked "review failed; max_attempts ($max_attempts) reached"; return; fi
        run_update "$task_id" "$(printf '{"attempt_n":%s}' "$attempt")"
        entry="build"; continue
      fi
      break
    done
  fi

  current_phase="integrate"; set_state integrating integrate; run_one integrate; gate integrate || return
  local pr_url=""
  [ -f "$run_dir/pr.json" ] && pr_url="$(jq -r '.pr_url // empty' "$run_dir/pr.json" 2>/dev/null || true)"
  run_update "$task_id" "$(printf '{"pr_url":%s}' "$(json_str "$pr_url")")"
  maybe_merge
  finalize_artifacts
  queue_set_status "$task_id" pr_open
  run_update "$task_id" '{"status":"pr_open","current_phase":"integrate"}'
  echo "pr_open"
}

case "$tier" in
  0) drive_tier0 "$start" ;;
  2)
    # Once the human approves the plan (approve-plan.sh moves the task to
    # building), a tier-2 task runs the same loop as tier 1 from that point.
    case "$start" in
      build|verify|review|integrate) drive_tier1 "$start" ;;
      *) drive_tier2 "$start" ;;
    esac
    ;;
  *) drive_tier1 "$start" ;;
esac
