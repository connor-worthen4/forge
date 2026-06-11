#!/usr/bin/env bash
#
# forge-lib.sh - shared helpers for the forge runner scripts. Source this file;
# do not execute it directly.
#
# Resolves the plugin dir (from this file's location) and the TARGET repo (the
# repo forge operates on: FORGE_TARGET_REPO, else the current working dir). All
# .forge/ state (config, queue, runs, spend) is read/written under TARGET.
#
# Deps: python3 (PyYAML; ruby fallback for YAML), jq, git.

FORGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$FORGE_LIB_DIR/.." && pwd)"
TARGET="${FORGE_TARGET_REPO:-$PWD}"
FORGE_DIR="$TARGET/.forge"
CONFIG="$FORGE_DIR/config.yaml"
QUEUE="$FORGE_DIR/queue.json"
SPEND="$FORGE_DIR/spend.json"
RUNS_DIR="$FORGE_DIR/runs"

# Fail fast with a clear message when a required command is missing.
#   forge_require <cmd>...
forge_require() {
  local c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      printf 'forge: required command not found: %s\n' "$c" >&2
      return 1
    fi
  done
}

# Every helper below shells out to python3 or jq; check once at source time so
# each runner script aborts with one clear line instead of a mid-pipeline
# command-not-found.
forge_require jq python3 || exit 2

# Read a dotted key from the project config. Scalars print as-is; objects/arrays
# print as JSON. Missing key prints the default. An empty-string value is
# deliberately coerced to the default too (a blank config line means "unset",
# never "override with nothing").
#   config_get <dotted.key> [default]
config_get() {
  local key="$1" def="${2:-}"
  [ -f "$CONFIG" ] || { printf '%s' "$def"; return 0; }
  python3 - "$CONFIG" "$key" "$def" <<'PY'
import sys, json
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    import yaml
    data = yaml.safe_load(open(path)) or {}
except Exception:
    print(default); sys.exit(0)
cur = data
for part in key.split('.'):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print(default); sys.exit(0)
print(json.dumps(cur) if isinstance(cur, (dict, list)) else (cur if cur != "" else default))
PY
}

# Read a field from a task spec's YAML frontmatter.
#   spec_field <spec-file> <key> [default]
spec_field() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import sys, re, json
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    import yaml
except ImportError:
    yaml = None
txt = open(path, encoding="utf-8").read()
m = re.match(r'^﻿?\s*---[ \t]*\r?\n(.*?)\r?\n---[ \t]*\r?\n?', txt, re.DOTALL)
data = {}
if m and yaml:
    try:
        data = yaml.safe_load(m.group(1)) or {}
    except Exception:
        data = {}
v = data.get(key, default)
print(json.dumps(v) if isinstance(v, (dict, list)) else (v if v is not None else default))
PY
}

# Resolve a task's spec file: the queue entry's `file` key when it points at an
# existing file, else the conventional tasks/<task-id>.md under the target repo.
# Prints the path; the caller checks existence.
#   spec_path <task_id>
spec_path() {
  local f
  f="$(queue_get "$1" file "")"
  if [ -z "$f" ] || [ ! -f "$f" ]; then f="$TARGET/tasks/$1.md"; fi
  printf '%s' "$f"
}

# Read a field from a queue entry.
#   queue_get <task_id> <field> [default]
queue_get() {
  [ -f "$QUEUE" ] || { printf '%s' "${3:-}"; return 0; }
  python3 - "$QUEUE" "$1" "$2" "${3:-}" <<'PY'
import sys, json
q = json.load(open(sys.argv[1]))
tasks = q if isinstance(q, list) else q.get("tasks", [])
for t in tasks:
    if t.get("task_id") == sys.argv[2]:
        v = t.get(sys.argv[3], sys.argv[4])
        print(json.dumps(v) if isinstance(v, (dict, list)) else (v if v is not None else sys.argv[4]))
        break
else:
    print(sys.argv[4])
PY
}

# Set a queue entry's status (no-op if the task or queue is absent).
#   queue_set_status <task_id> <status>
queue_set_status() {
  [ -f "$QUEUE" ] || return 0
  python3 - "$QUEUE" "$1" "$2" <<'PY'
import sys, json
p = sys.argv[1]
q = json.load(open(p))
tasks = q if isinstance(q, list) else q.get("tasks", [])
for t in tasks:
    if t.get("task_id") == sys.argv[2]:
        t["status"] = sys.argv[3]
json.dump(q, open(p, "w"), indent=2)
PY
}

# Merge a JSON fragment into a task's run record (run.json), stamping timestamps.
#   run_update <task_id> <json-object-fragment>
run_update() {
  local rd="$RUNS_DIR/$1"
  mkdir -p "$rd"
  python3 - "$rd/run.json" "$1" "$2" <<'PY'
import sys, json, os
from datetime import datetime, timezone
path, task_id, frag = sys.argv[1], sys.argv[2], sys.argv[3]
d = {}
if os.path.exists(path):
    try:
        d = json.load(open(path))
    except Exception:
        d = {}
now = datetime.now(timezone.utc).isoformat()
d.setdefault("task_id", task_id)
d.setdefault("attempt_n", 1)
d.setdefault("created_at", now)
try:
    f = json.loads(frag) if frag else {}
except Exception:
    f = {}
d.update(f)
d["updated_at"] = now
json.dump(d, open(path, "w"), indent=2)
PY
}

# Accumulate a phase cost into the durable spend ledger, resetting the night
# window on a new day and the month window on a new month. Prints the running
# night/month totals as JSON.
#   spend_add <task_id> <cost_usd>
spend_add() {
  local today month
  today="$(date +%F)"
  month="$(date +%Y-%m)"
  python3 - "$SPEND" "$1" "$2" "$today" "$month" <<'PY'
import sys, json, os
path, task_id, today, month = sys.argv[1], sys.argv[2], sys.argv[4], sys.argv[5]
try:
    cost = float(sys.argv[3])
except ValueError:
    cost = 0.0
d = {}
if os.path.exists(path):
    try:
        d = json.load(open(path)) or {}
    except Exception:
        d = {}
if d.get("window_date") != today:
    d["window_date"] = today
    d["night_usd_spent"] = 0.0
if d.get("month") != month:
    d["month"] = month
    d["month_usd_spent"] = 0.0
d["night_usd_spent"] = round(d.get("night_usd_spent", 0.0) + cost, 6)
d["month_usd_spent"] = round(d.get("month_usd_spent", 0.0) + cost, 6)
pt = d.setdefault("per_task", {})
pt[task_id] = round(pt.get(task_id, 0.0) + cost, 6)
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(d, open(path, "w"), indent=2)
print(json.dumps({"night_usd_spent": d["night_usd_spent"], "month_usd_spent": d["month_usd_spent"]}))
PY
}

# Print a spend total ("night" or "month"); 0 if no ledger yet.
spend_total() {
  [ -f "$SPEND" ] || { printf '0'; return 0; }
  local field="night_usd_spent"
  [ "$1" = "month" ] && field="month_usd_spent"
  python3 - "$SPEND" "$field" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1])) or {}
except Exception:
    d = {}
print(d.get(sys.argv[2], 0))
PY
}
