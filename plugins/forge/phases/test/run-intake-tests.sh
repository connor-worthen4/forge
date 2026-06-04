#!/usr/bin/env bash
#
# run-intake-tests.sh - exercise the real intake phase end to end.
#
# Drives run-phase.sh intake against fixture specs that point at REAL files in
# this repo, so intake's grounding (path:line citations) has something true to
# cite. Covers the four scenarios intake must get right:
#
#   fix-T1AAAA000001  well-formed tier-1 fix  -> ok, next_phase plan, brief cites path:line
#   build-T2BBBB000001 tier-2 build           -> ok, brief marks gate required
#   fix-VAGUE0000001  vague criteria          -> blocked, with an actionable reason
#   audit-T0CCCC000001 tier-0 audit           -> ok, next_phase plan
#
# In every case the structured result must validate against the runner's result
# schema (the same schema run-phase.sh enforces).
#
# Real mode (claude on PATH, FORGE_STUB unset) asserts the semantic outcomes
# above. Stub mode (no claude, or FORGE_STUB=1) only asserts the plumbing: every
# result validates and the artifact is context-brief.md (the stub cannot judge
# vagueness or gates, so those assertions are reported as skipped).
#
# The target repo is THIS repo (so the cited files exist). The shared queue is
# backed up and restored; run records land under the gitignored .forge/runs/.
#
# Usage: plugins/forge/phases/test/run-intake-tests.sh
# Deps: jq, python3, run-phase.sh (and claude for real mode).

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TEST_DIR/fixtures"
PLUGIN_DIR="$(cd "$TEST_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"

export FORGE_TARGET_REPO="$REPO_ROOT"
QUEUE="$REPO_ROOT/.forge/queue.json"
RUNS="$REPO_ROOT/.forge/runs"

if [ -n "${FORGE_STUB:-}" ] || ! command -v claude >/dev/null 2>&1; then
  MODE="stub"
else
  MODE="real"
fi

# The runner's result schema (kept in sync with run-phase.sh).
RESULT_SCHEMA='{"type":"object","additionalProperties":false,"required":["status"],"properties":{"status":{"enum":["ok","blocked","fail"]},"next_phase":{"type":["string","null"]},"artifacts":{"type":"array","items":{"type":"string"}},"blocked_reason":{"type":["string","null"]},"cost_usd":{"type":["number","null"]}}}'

PASS=0
FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  SKIP  %s (%s mode)\n' "$1" "$MODE"; }

# Validate one result object against the runner's schema (manual; jsonschema is
# optional in this environment). Prints nothing on success, the error on failure.
validate_schema() {
  python3 - "$RESULT_SCHEMA" "$1" <<'PY'
import sys, json
schema = json.loads(sys.argv[1])
try:
    obj = json.loads(sys.argv[2])
except Exception as exc:
    print("not JSON: %s" % exc); sys.exit(1)
if not isinstance(obj, dict):
    print("not an object"); sys.exit(1)
props = schema["properties"]
for k in obj:
    if k not in props:
        print("additional property not allowed: %s" % k); sys.exit(1)
for req in schema.get("required", []):
    if req not in obj:
        print("missing required: %s" % req); sys.exit(1)
if obj["status"] not in schema["properties"]["status"]["enum"]:
    print("status not in enum: %r" % obj["status"]); sys.exit(1)


def type_ok(val, spec):
    types = spec["type"] if isinstance(spec["type"], list) else [spec["type"]]
    for t in types:
        if t == "null" and val is None:
            return True
        if t == "string" and isinstance(val, str):
            return True
        if t == "number" and isinstance(val, (int, float)) and not isinstance(val, bool):
            return True
        if t == "array" and isinstance(val, list):
            return True
    return False


for key in ("next_phase", "blocked_reason", "cost_usd"):
    if key in obj and not type_ok(obj[key], props[key]):
        print("bad type for %s: %r" % (key, obj[key])); sys.exit(1)
if "artifacts" in obj:
    if not isinstance(obj["artifacts"], list) or not all(isinstance(x, str) for x in obj["artifacts"]):
        print("artifacts must be a list of strings"); sys.exit(1)
sys.exit(0)
PY
}

# --- seed a temp queue pointing at the fixtures, backing up any existing one ---
BACKUP=""
mkdir -p "$REPO_ROOT/.forge"
if [ -f "$QUEUE" ]; then
  BACKUP="$QUEUE.intaketest.bak"
  cp "$QUEUE" "$BACKUP"
fi
restore_queue() {
  if [ -n "$BACKUP" ]; then
    mv "$BACKUP" "$QUEUE"
  else
    printf '[]\n' > "$QUEUE"
  fi
}
trap restore_queue EXIT

python3 - "$QUEUE" "$FIXTURES" <<'PY'
import sys, json, os, glob
qpath, fixtures = sys.argv[1], sys.argv[2]
import re
entries = []
for path in sorted(glob.glob(os.path.join(fixtures, "*.md"))):
    txt = open(path, encoding="utf-8").read()
    m = re.search(r'^id:\s*(\S+)', txt, re.MULTILINE)
    pr = re.search(r'^priority:\s*(\S+)', txt, re.MULTILINE)
    if not m:
        continue
    entries.append({
        "task_id": m.group(1),
        "priority": pr.group(1) if pr else "P2",
        "status": "pending",
        "file": path,
    })
json.dump(entries, open(qpath, "w"), indent=2)
print("seeded %d fixtures into the queue" % len(entries))
PY

echo
echo "=== intake phase tests (mode: $MODE) ==="
echo

# run_intake <task_id> -> populates RESULT (json string) and BRIEF (path)
run_intake() {
  local id="$1"
  RESULT="$("$SCRIPTS/run-phase.sh" "$id" intake 2>/dev/null)"
  BRIEF="$RUNS/$id/context-brief.md"
}

# --- scenario 1: well-formed tier-1 fix -> ok + grounded brief --------------
echo "[1] well-formed tier-1 fix (fix-T1AAAA000001)"
run_intake fix-T1AAAA000001
err="$(validate_schema "$RESULT")" && ok "result validates against runner schema" || bad "schema: $err :: $RESULT"
status="$(printf '%s' "$RESULT" | jq -r '.status')"
[ "$status" = "ok" ] && ok "status ok" || bad "expected status ok, got '$status' ($RESULT)"
nph="$(printf '%s' "$RESULT" | jq -r '.next_phase // empty')"
arts="$(printf '%s' "$RESULT" | jq -r '.artifacts[]? // empty')"
if [ "$MODE" = "real" ]; then
  [ "$nph" = "plan" ] && ok "next_phase plan" || bad "expected next_phase plan, got '$nph'"
  printf '%s\n' "$arts" | grep -qx "context-brief.md" && ok "artifacts lists context-brief.md" || bad "artifacts missing context-brief.md"
  if [ -f "$BRIEF" ] && grep -Eq 'forge-lib\.sh:[0-9]+' "$BRIEF"; then
    ok "brief cites a real path:line (forge-lib.sh:NN)"
  else
    bad "brief is missing a forge-lib.sh:line citation"
  fi
else
  printf '%s\n' "$arts" | grep -qx "context-brief.md" && ok "artifacts lists context-brief.md" || bad "artifacts missing context-brief.md"
  skip "next_phase plan + grounded citation"
fi
echo

# --- scenario 2: tier-2 build -> ok + gate marked ---------------------------
echo "[2] tier-2 build (build-T2BBBB000001)"
run_intake build-T2BBBB000001
err="$(validate_schema "$RESULT")" && ok "result validates against runner schema" || bad "schema: $err :: $RESULT"
status="$(printf '%s' "$RESULT" | jq -r '.status')"
if [ "$MODE" = "real" ]; then
  [ "$status" = "ok" ] && ok "status ok" || bad "expected status ok, got '$status' ($RESULT)"
  if [ -f "$BRIEF" ] && grep -iEq 'gate[^a-z]*(required|needed)[^a-z]*:?[^a-z]*(yes|true)|requires?[^a-z]*(human|plan)[^a-z]*(approval|gate)|plan[_ -]?gate' "$BRIEF"; then
    ok "brief marks the plan gate as required"
    printf '        gate line: %s\n' "$(grep -iE 'gate' "$BRIEF" | head -1 | sed 's/^[[:space:]]*//')"
  else
    bad "brief does not mark the gate as required"
  fi
else
  [ "$status" = "ok" ] && ok "status ok" || bad "expected status ok, got '$status'"
  skip "gate-required marked in brief"
fi
echo

# --- scenario 3: vague spec -> blocked --------------------------------------
echo "[3] vague spec (fix-VAGUE0000001)"
run_intake fix-VAGUE0000001
err="$(validate_schema "$RESULT")" && ok "result validates against runner schema" || bad "schema: $err :: $RESULT"
status="$(printf '%s' "$RESULT" | jq -r '.status')"
reason="$(printf '%s' "$RESULT" | jq -r '.blocked_reason // empty')"
if [ "$MODE" = "real" ]; then
  [ "$status" = "blocked" ] && ok "status blocked" || bad "expected status blocked, got '$status' ($RESULT)"
  [ -n "$reason" ] && ok "blocked_reason is present and specific" || bad "blocked_reason is empty"
  [ -n "$reason" ] && printf '        reason: %s\n' "$reason"
else
  skip "blocked on vague criteria (stub always returns ok)"
fi
echo

# --- scenario 4: tier-0 audit -> ok routing to plan -------------------------
echo "[4] tier-0 audit (audit-T0CCCC000001)"
run_intake audit-T0CCCC000001
err="$(validate_schema "$RESULT")" && ok "result validates against runner schema" || bad "schema: $err :: $RESULT"
status="$(printf '%s' "$RESULT" | jq -r '.status')"
nph="$(printf '%s' "$RESULT" | jq -r '.next_phase // empty')"
if [ "$MODE" = "real" ]; then
  [ "$status" = "ok" ] && ok "status ok" || bad "expected status ok, got '$status' ($RESULT)"
  [ "$nph" = "plan" ] && ok "next_phase plan (plan drives the read-only path)" || bad "expected next_phase plan, got '$nph'"
else
  [ "$status" = "ok" ] && ok "status ok" || bad "expected status ok, got '$status'"
  skip "next_phase plan"
fi
echo

echo "=== summary: $PASS passed, $FAIL failed (mode: $MODE) ==="
[ "$FAIL" -eq 0 ]
