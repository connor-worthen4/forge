#!/usr/bin/env bash
#
# select-next.sh - the shared next-task selector (used by both drivers).
#
# Reads .forge/queue.json and prints the task_id of the highest-priority
# selectable task, or "none". Selectable means: status is `pending`, and every
# id in its depends_on (if any) has status `done`. Ordering is by priority
# (P0..P3) then FIFO within a priority (queue insertion order). Tasks in
# blocked / plan_gate / pr_open / done / failed are skipped.
#
# Deps: python3, forge-lib.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

if [ ! -f "$QUEUE" ]; then
  echo "none"
  exit 0
fi

python3 - "$QUEUE" <<'PY'
import sys, json
q = json.load(open(sys.argv[1]))
tasks = q if isinstance(q, list) else q.get("tasks", [])
by_id = {t.get("task_id"): t for t in tasks}
rank = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}


def deps_done(t):
    for dep in t.get("depends_on") or []:
        d = by_id.get(dep)
        if d is None or d.get("status") != "done":
            return False
    return True


candidates = [
    (i, t) for i, t in enumerate(tasks)
    if t.get("status", "pending") == "pending" and deps_done(t)
]
if not candidates:
    print("none")
else:
    candidates.sort(key=lambda it: (rank.get(it[1].get("priority", "P2"), 2), it[0]))
    print(candidates[0][1].get("task_id", "none"))
PY
