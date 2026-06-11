#!/usr/bin/env bash
#
# run-phase.sh <task_id> <phase> - the shared phase executor.
#
# Launches ONE headless session for a single phase and returns its structured
# result on stdout. The phase prompt body is the file phases/<phase>.md. The
# result is forced to the schema:
#   { status: ok|blocked|fail, next_phase, artifacts:[], blocked_reason, cost_usd }
#
# Real mode (claude available, FORGE_STUB unset), run with cwd = TARGET repo:
#   claude -p "<prompt>" --output-format json --json-schema '<schema>' \
#          --model <config.budget.models[phase]> --dangerously-skip-permissions
# (No --bare: the forge guardrail hook must stay active during the run.)
# Before launching, the phase's task context is exported as environment vars
# (FORGE_TASK_ID, FORGE_PHASE, FORGE_SPEC_FILE, FORGE_RUN_DIR, FORGE_CONFIG,
# FORGE_TARGET_REPO, FORGE_PLUGIN_DIR, FORGE_ARTIFACT) so the self-contained
# prompt can locate the spec/config/repo it must ground itself in.
# The structured result is read from `.structured_output` and the cost from
# `.total_cost_usd` (verified flag/field names from the Claude Code docs).
#
# Stub mode (FORGE_STUB set, or claude not installed): no model is called; the
# phase's canned result (the forge:stub-result marker in phases/<phase>.md) is
# used so the runner is end-to-end testable. Override per phase for loop tests
# with FORGE_STUB_STATUS_<phase>=fail|blocked, or globally with FORGE_STUB_STATUS.
# Stub cost per phase is FORGE_STUB_COST (default 0.10).
#
# Writes phase artifacts into TARGET/.forge/runs/<task_id>/ and accumulates the
# cost into TARGET/.forge/spend.json. Idempotent: safe to re-run a phase.
#
# Deps: jq, python3, forge-lib.sh, and claude (real mode only).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

task_id="${1:?usage: run-phase.sh <task_id> <phase>}"
phase="${2:?usage: run-phase.sh <task_id> <phase>}"

run_dir="$RUNS_DIR/$task_id"
mkdir -p "$run_dir"

prompt_file="$PLUGIN_DIR/phases/$phase.md"
if [ ! -f "$prompt_file" ]; then
  echo "run-phase: unknown phase '$phase' (no $prompt_file)" >&2
  exit 2
fi

# Model for this phase, falling back to a cheap default.
model="$(config_get "budget.models.$phase" "")"
[ -n "$model" ] || model="${FORGE_DEFAULT_MODEL:-haiku}"

# Artifact file name per phase.
case "$phase" in
  intake)    artifact="context-brief.md" ;;
  plan)      artifact="plan.md" ;;
  build)     artifact="diff.patch" ;;
  verify)    artifact="verify.md" ;;
  review)    artifact="review.md" ;;
  integrate) artifact="pr.json" ;;
  report)    artifact="report.md" ;;
  *)         artifact="$phase.out" ;;
esac

# Structured-result schema enforced via --json-schema.
result_schema='{"type":"object","additionalProperties":false,"required":["status","next_phase","artifacts","blocked_reason","cost_usd"],"properties":{"status":{"enum":["ok","blocked","fail"]},"next_phase":{"type":["string","null"]},"artifacts":{"type":"array","items":{"type":"string"}},"blocked_reason":{"type":["string","null"]},"cost_usd":{"type":["number","null"]}}}'

cost=0
result=""

if [ -n "${FORGE_STUB:-}" ] || ! command -v claude >/dev/null 2>&1; then
  # ---- stub mode ----
  role="$(grep -m1 '^Role:' "$prompt_file" 2>/dev/null || true)"

  # Status: per-phase env override > global env > marker default > ok.
  ov_var="FORGE_STUB_STATUS_$phase"
  marker_json="$(sed -n 's/.*forge:stub-result[[:space:]]*\(.*\)[[:space:]]*-->.*/\1/p' "$prompt_file" 2>/dev/null | head -1)"
  marker_status="$(printf '%s' "$marker_json" | python3 -c 'import sys, json
try:
    print(json.loads(sys.stdin.read()).get("status", "ok"))
except Exception:
    print("ok")' 2>/dev/null || echo ok)"
  [ -n "$marker_status" ] || marker_status="ok"
  status="${!ov_var:-${FORGE_STUB_STATUS:-$marker_status}}"
  [ -n "$status" ] || status="ok"

  case "$status" in
    blocked) reason="stub: blocked by phase $phase" ;;
    fail)    reason="stub: failure in phase $phase" ;;
    *)       reason="" ;;
  esac

  cost="${FORGE_STUB_COST:-0.10}"

  # Write the phase artifact (echo the role).
  if [ "$phase" = "integrate" ]; then
    short="$(printf '%s' "$task_id" | cksum | cut -d' ' -f1)"
    # "${short: -4}" is the last four digits; the space before -4 is required
    # to distinguish the negative offset from the ${var:-default} form.
    printf '{"pr_url": "https://github.com/example/repo/pull/%s"}\n' "${short: -4}" > "$run_dir/$artifact"
  else
    printf '[stub %s] %s\n' "$phase" "${role:-Role: (none)}" > "$run_dir/$artifact"
  fi
  printf 'stub phase %s for %s -> %s\n' "$phase" "$task_id" "$status" >> "$run_dir/transcript.log"

  result="$(python3 -c '
import json, sys
print(json.dumps({
    "status": sys.argv[1],
    "next_phase": None,
    "artifacts": [sys.argv[2]],
    "blocked_reason": (sys.argv[3] or None),
    "cost_usd": float(sys.argv[4]),
}))' "$status" "$artifact" "$reason" "$cost")"
else
  # ---- real mode ----
  # Resolve the task spec (same rule the driver uses) and export the phase's
  # task context so the self-contained prompt can ground itself in the real
  # spec/config/repo. claude inherits these in the cd subshell below.
  spec_file="$(spec_path "$task_id")"
  export FORGE_TASK_ID="$task_id"
  export FORGE_PHASE="$phase"
  export FORGE_SPEC_FILE="$spec_file"
  export FORGE_RUN_DIR="$run_dir"
  export FORGE_CONFIG="$CONFIG"
  export FORGE_TARGET_REPO="$TARGET"
  export FORGE_PLUGIN_DIR="$PLUGIN_DIR"
  export FORGE_ARTIFACT="$artifact"

  prompt="$(cat "$prompt_file")"
  raw="$(cd "$TARGET" && claude -p "$prompt" \
      --output-format json \
      --json-schema "$result_schema" \
      --model "$model" \
      --dangerously-skip-permissions 2>"$run_dir/$phase.stderr.log")" || true
  printf '%s\n' "$raw" > "$run_dir/$phase.transcript.json"
  cost="$(printf '%s' "$raw" | jq -r '(.total_cost_usd // 0)' 2>/dev/null || echo 0)"
  result="$(printf '%s' "$raw" | jq -c '(.structured_output // {"status":"fail","next_phase":null,"artifacts":[],"blocked_reason":"no structured_output in claude result","cost_usd":null})' 2>/dev/null || echo '{"status":"fail","next_phase":null,"artifacts":[],"blocked_reason":"unparseable claude result","cost_usd":null}')"
fi

# Accumulate spend.
spend_add "$task_id" "$cost" >/dev/null

# Emit the result with the actual cost stamped in.
printf '%s' "$result" | jq -c --argjson c "${cost:-0}" '. + {cost_usd: $c}'
