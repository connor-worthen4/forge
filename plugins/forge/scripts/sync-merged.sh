#!/usr/bin/env bash
#
# sync-merged.sh - flip pr_open tasks to done once their PR has merged.
#
# The runner ENDS at pr_open and never merges. This separate pass is how pr_open
# becomes done: for each task in pr_open it reads the PR url from the run record
# and asks gh whether the PR is MERGED; if so it sets status done. Run it at the
# start of the unattended loop and on demand (the daytime /forge-fix command runs
# it too, so `next` skips anything merged overnight).
#
# Testing/mock: set FORGE_FAKE_MERGED="id1,id2" to treat those task ids as merged
# without calling gh. FORGE_SYNC_STUB=1 disables gh queries entirely.
#
# Deps: jq, python3, forge-lib.sh, gh (real mode only).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

[ -f "$QUEUE" ] || { echo "sync-merged: no queue"; exit 0; }

ids="$(python3 -c '
import sys, json
q = json.load(open(sys.argv[1]))
tasks = q if isinstance(q, list) else q.get("tasks", [])
print("\n".join(t["task_id"] for t in tasks if t.get("status") == "pr_open"))' "$QUEUE")"

fake=",${FORGE_FAKE_MERGED:-},"
changed=0

while IFS= read -r id; do
  [ -n "$id" ] || continue
  merged=0
  if printf '%s' "$fake" | grep -q ",$id,"; then
    merged=1
  elif [ -z "${FORGE_SYNC_STUB:-}" ] && command -v gh >/dev/null 2>&1; then
    pr_url="$(jq -r '.pr_url // empty' "$RUNS_DIR/$id/run.json" 2>/dev/null || true)"
    if [ -n "$pr_url" ]; then
      state="$(cd "$TARGET" && gh pr view "$pr_url" --json state -q .state 2>/dev/null || echo "")"
      [ "$state" = "MERGED" ] && merged=1
    fi
  fi
  if [ "$merged" = 1 ]; then
    queue_set_status "$id" done
    run_update "$id" '{"status":"done"}'
    echo "merged: $id -> done"
    changed=$((changed + 1))
  fi
done <<< "$ids"

[ "$changed" = 0 ] && echo "sync-merged: no pr_open tasks newly merged"
exit 0
