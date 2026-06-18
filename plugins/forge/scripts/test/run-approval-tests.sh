#!/usr/bin/env bash
#
# Stub-mode tests for the tier-2 plan gate lifecycle: park at plan_gate,
# approve into the build loop, and request changes back into planning. Runs
# entirely in a temp target repo with FORGE_STUB=1 (no model calls, no git).
# Exits non-zero if any case fails.
#
# Deps: jq, python3, run-task.sh, approve-plan.sh, select-next.sh.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
PLUGIN_DIR="$(cd "$SCRIPTS/.." && pwd)"
SPEC_SRC="$PLUGIN_DIR/phases/test/fixtures/build-T2BBBB000001.md"

if [ ! -f "$SPEC_SRC" ]; then
  echo "tier-2 fixture spec not found: $SPEC_SRC" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export FORGE_TARGET_REPO="$TMP"
export FORGE_STUB=1

TASK="build-T2BBBB000001"
RUN_JSON="$TMP/.forge/runs/$TASK/run.json"

seed() {  # fresh queue + no run record
  rm -rf "$TMP/.forge"
  mkdir -p "$TMP/.forge"
  python3 - "$TMP/.forge/queue.json" "$SPEC_SRC" "$TASK" <<'PY'
import sys, json
json.dump([{"task_id": sys.argv[3], "priority": "P0", "status": "pending",
            "file": sys.argv[2]}], open(sys.argv[1], "w"), indent=2)
PY
}

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

assert_eq() {  # assert_eq <label> <expected> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

run_field() { jq -r --arg k "$1" '.[$k] // ""' "$RUN_JSON" 2>/dev/null || echo ""; }
queue_status() { jq -r --arg id "$TASK" '.[] | select(.task_id == $id) | .status' "$TMP/.forge/queue.json"; }

echo "forge plan-gate approval tests (stub mode)"
echo

# --- scenario 1: tier-2 parks at plan_gate and is not selectable -------------
echo "[1] tier-2 run parks at plan_gate"
seed
out="$("$SCRIPTS/run-task.sh" "$TASK")"
assert_eq "run-task prints plan_gate" "plan_gate" "$out"
assert_eq "run.json status plan_gate" "plan_gate" "$(run_field status)"
assert_eq "queue status plan_gate" "plan_gate" "$(queue_status)"
assert_eq "select-next skips a gated task" "none" "$("$SCRIPTS/select-next.sh")"
echo

# --- scenario 2: approve -> resumes at build -> pr_open ----------------------
echo "[2] approve resumes the tier-1 loop to pr_open"
"$SCRIPTS/approve-plan.sh" "$TASK" >/dev/null 2>&1 && ok "approve-plan exits 0" || bad "approve-plan failed"
assert_eq "run.json status building" "building" "$(run_field status)"
assert_eq "run.json current_phase build" "build" "$(run_field current_phase)"
assert_eq "queue status back to pending" "pending" "$(queue_status)"
assert_eq "select-next picks the approved task" "$TASK" "$("$SCRIPTS/select-next.sh")"
out="$("$SCRIPTS/run-task.sh" "$TASK")"
assert_eq "resumed run reaches pr_open" "pr_open" "$out"
assert_eq "queue status pr_open" "pr_open" "$(queue_status)"

# The record the runner just produced must validate against the published
# run-record schema, so the contract and the implementation cannot drift.
schema_errs="$(python3 - "$PLUGIN_DIR/schema/run-record.schema.json" "$RUN_JSON" <<'PY'
import sys, json
schema = json.load(open(sys.argv[1]))
rec = json.load(open(sys.argv[2]))
errs = []
try:
    import jsonschema
    v = jsonschema.Draft202012Validator(schema)
    errs = ["%s: %s" % ("/".join(map(str, e.path)) or "<root>", e.message)
            for e in v.iter_errors(rec)]
except ImportError:
    # Minimal fallback: required keys, known keys, enum membership.
    props = schema["properties"]
    errs += ["missing required key: %s" % k
             for k in schema.get("required", []) if k not in rec]
    for k, v in rec.items():
        if k not in props:
            errs.append("unknown key: %s" % k)
        elif "enum" in props[k] and v not in props[k]["enum"]:
            errs.append("%s: %r not in %s" % (k, v, props[k]["enum"]))
print("; ".join(errs))
PY
)"
if [ -z "$schema_errs" ]; then
  ok "pr_open run.json validates against run-record.schema.json"
else
  bad "run.json violates the published schema: $schema_errs"
fi
echo

# --- scenario 3: request-changes -> re-plan -> parks at the gate again -------
echo "[3] request-changes re-plans and re-parks at the gate"
seed
"$SCRIPTS/run-task.sh" "$TASK" >/dev/null
"$SCRIPTS/approve-plan.sh" "$TASK" --request-changes "Split the change into two phases" >/dev/null 2>&1 \
  && ok "request-changes exits 0" || bad "request-changes failed"
assert_eq "run.json status planning" "planning" "$(run_field status)"
fb="$TMP/.forge/runs/$TASK/plan-feedback.md"
if [ -f "$fb" ] && grep -q "Split the change into two phases" "$fb"; then
  ok "feedback filed in plan-feedback.md"
else
  bad "plan-feedback.md missing or lacks the feedback text"
fi
out="$("$SCRIPTS/run-task.sh" "$TASK")"
assert_eq "re-planned run parks at plan_gate again" "plan_gate" "$out"
echo

# --- scenario 4: refuses tasks not at the gate -------------------------------
echo "[4] guards"
if "$SCRIPTS/approve-plan.sh" "$TASK" --request-changes "" >/dev/null 2>&1; then
  bad "empty feedback accepted"
else
  ok "empty feedback rejected"
fi
"$SCRIPTS/approve-plan.sh" "$TASK" >/dev/null 2>&1 && ok "approve at plan_gate (round 2) exits 0" || bad "second approve failed"
if "$SCRIPTS/approve-plan.sh" "$TASK" >/dev/null 2>&1; then
  bad "approve accepted a task not at plan_gate"
else
  ok "approve refused: task already past the gate"
fi
if "$SCRIPTS/approve-plan.sh" no-such-task >/dev/null 2>&1; then
  bad "approve accepted an unknown task id"
else
  ok "approve refused: unknown task id"
fi
echo

echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
