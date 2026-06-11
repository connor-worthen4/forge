#!/usr/bin/env bash
#
# forge-run.sh [run] [--all|--once] [--max N] - the unattended runner loop.
# Entry point for `forge run --all`.
#
# Drains the shared queue via headless sessions:
#   1. sync merged PRs (pr_open -> done) so done work isn't reprocessed
#   2. refresh queue.json from tasks/ (pick up newly added specs; preserve statuses)
#   3. check budget (night vs budget.nightly_usd, month vs budget.monthly_usd)
#   4. select-next -> run-task -> repeat
# Stops when: no selectable pending task, budget reached (finishes any in-flight
# task first; this reference loop is sequential so there is none), or all
# remaining are blocked/parked. Writes a summary and fires a Discord webhook if
# configured. Concurrency from config (default 1); git-touching work is always
# serialized.
#
# Deps: jq, python3, forge-lib.sh, select-next.sh, run-task.sh, sync-merged.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

mode="all"
max=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    run) shift ;;                 # `forge run --all` -> ignore the verb
    --all) mode="all"; shift ;;
    --once) mode="once"; shift ;;
    --max) max="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$FORGE_DIR"

refresh_queue() {
  shopt -s nullglob
  local files=("$TARGET/tasks/"*.md)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    [ -f "$QUEUE" ] || echo "[]" > "$QUEUE"
    return 0
  fi
  local specs
  specs="$("$PLUGIN_DIR/scripts/validate-task.sh" --json "${files[@]}")" || return 1
  python3 - "$QUEUE" "$specs" <<'PY'
import sys, json, os
qpath = sys.argv[1]
specs = json.loads(sys.argv[2])
existing = {}
if os.path.exists(qpath):
    try:
        q = json.load(open(qpath))
        for t in (q if isinstance(q, list) else q.get("tasks", [])):
            existing[t.get("task_id")] = t
    except Exception:
        existing = {}
out, seen = [], set()
for s in specs:
    tid = s.get("id")
    if not tid or tid in seen:
        continue
    seen.add(tid)
    prev = existing.get(tid, {})
    out.append({
        "task_id": tid,
        "type": s.get("type"),
        "priority": s.get("priority", "P2"),
        "status": prev.get("status", "pending"),
        "depends_on": s.get("depends_on", []),
        "file": s.get("_file"),
    })
json.dump(out, open(qpath, "w"), indent=2)
PY
}

budget_ok() {
  local nightly monthly night month
  nightly="$(config_get budget.nightly_usd "")"
  monthly="$(config_get budget.monthly_usd "")"
  night="$(spend_total night)"
  month="$(spend_total month)"
  python3 -c '
import sys
def f(x):
    try: return float(x)
    except Exception: return None
nightly, monthly, night, month = (f(a) for a in sys.argv[1:5])
if nightly is not None and night is not None and night >= nightly: sys.exit(1)
if monthly is not None and month is not None and month >= monthly: sys.exit(1)
sys.exit(0)' "$nightly" "$monthly" "$night" "$month"
}

print_summary() {
  python3 - "$QUEUE" "$SPEND" "$RUNS_DIR" <<'PY'
import sys, json, os
from collections import Counter
q = json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1]) else []
tasks = q if isinstance(q, list) else q.get("tasks", [])
c = Counter(t.get("status", "pending") for t in tasks)
print("Queue summary:")
for st in ["pending", "planning", "plan_gate", "building", "verifying", "reviewing",
           "integrating", "pr_open", "done", "blocked", "failed"]:
    if c.get(st):
        print("  %-11s %d" % (st, c[st]))
prs = []
for t in tasks:
    if t.get("status") in ("pr_open", "done"):
        rp = os.path.join(sys.argv[3], t["task_id"], "run.json")
        if os.path.exists(rp):
            try:
                u = json.load(open(rp)).get("pr_url")
                if u:
                    prs.append((t["task_id"], t.get("status"), u))
            except Exception:
                pass
if prs:
    print("PRs:")
    for tid, st, u in prs:
        print("  %s [%s] %s" % (tid, st, u))
sp = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
print("Spend: night $%.2f  month $%.2f" % (sp.get("night_usd_spent", 0.0), sp.get("month_usd_spent", 0.0)))
PY
}

notify_discord() {
  local hook
  hook="$(config_get notifications.discord_webhook "")"
  [ -n "$hook" ] || hook="${FORGE_DISCORD_WEBHOOK:-}"
  [ -n "$hook" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local body
  body="$(print_summary)"
  local payload
  payload="$(python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()}))' <<<"$body")"
  curl -fsS -H 'Content-Type: application/json' -X POST -d "$payload" "$hook" >/dev/null 2>&1 || true
}

conc="$(config_get budget.concurrency 1)"
if printf '%s' "$conc" | grep -Eq '^[0-9]+$' && [ "$conc" -gt 1 ]; then
  echo "note: concurrency=$conc requested; this reference loop runs sequentially (git-touching work is always serialized). Parallel non-git phases are a future enhancement."
fi

echo "forge run: target=$TARGET mode=$mode"

# Detect overnight merges before doing anything, so done work isn't reprocessed.
"$SCRIPT_DIR/sync-merged.sh" || true

stop_reason="queue drained"
iter=0
while : ; do
  if [ -n "$max" ] && [ "$iter" -ge "$max" ]; then
    stop_reason="--max $max"
    break
  fi
  if ! refresh_queue; then
    stop_reason="queue refresh failed (invalid task spec?)"
    break
  fi
  if ! budget_ok; then
    stop_reason="budget reached"
    break
  fi
  next="$("$SCRIPT_DIR/select-next.sh")"
  if [ "$next" = "none" ]; then
    stop_reason="no selectable pending tasks"
    break
  fi
  echo ">> $next"
  outcome="$("$SCRIPT_DIR/run-task.sh" "$next" 2>/dev/null)" || true
  echo "   -> ${outcome:-error}"
  iter=$((iter + 1))
  [ "$mode" = "once" ] && { stop_reason="--once"; break; }
done

echo
echo "forge run stopped: $stop_reason"
print_summary
notify_discord
