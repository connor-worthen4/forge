#!/usr/bin/env bash
#
# ingest-files.sh - reference file ingester for forge.
#
# Reads task spec files (*.md) from a directory, validates each against the
# task-spec schema, and writes a queue index to .forge/queue.json as a list of
# {task_id, type, priority, status, depends_on, file} entries (status "pending",
# default priority "P2"), sorted by priority then task_id. This is the queue
# shape every consumer expects, so a queue built here is fully usable by
# forge-context.sh and the /forge-run command.
#
# This is the simplest possible source. Any other ingester (cli, issue, notion,
# ...) must satisfy the same contract documented in docs/task-spec.md: emit task
# specs that validate against schema/task-spec.schema.json and register them into
# .forge/queue.json with the same shape.
#
# Usage:
#   ingest-files.sh [TASKS_DIR] [--out QUEUE_PATH]
#     TASKS_DIR   directory of *.md task specs (default: tasks)
#     --out PATH  output queue path (default: .forge/queue.json)
#
# Deps: bash, jq, python3 (via validate-task.sh).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate-task.sh"

TASKS_DIR="tasks"
OUT=".forge/queue.json"

POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      OUT="${2:-}"; shift 2 ;;
    --out=*)
      OUT="${1#--out=}"; shift ;;
    -h|--help)
      echo "usage: ingest-files.sh [TASKS_DIR] [--out QUEUE_PATH]"; exit 0 ;;
    *)
      POSITIONAL+=("$1"); shift ;;
  esac
done
if [ "${#POSITIONAL[@]}" -ge 1 ]; then
  TASKS_DIR="${POSITIONAL[0]}"
fi

if [ -z "$OUT" ]; then
  echo "--out requires a path" >&2
  exit 2
fi
if [ ! -x "$VALIDATE" ]; then
  echo "validator not found or not executable: $VALIDATE" >&2
  exit 2
fi
if [ ! -d "$TASKS_DIR" ]; then
  echo "tasks directory not found: $TASKS_DIR" >&2
  exit 1
fi

shopt -s nullglob
files=()
for f in "$TASKS_DIR"/*.md; do
  files+=("$f")
done
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
  echo "no task files (*.md) found in $TASKS_DIR" >&2
  exit 1
fi

# Validate every spec and capture their frontmatter as JSON. Fail fast: if any
# spec is invalid, abort without writing a partial queue.
specs_json="$("$VALIDATE" --json "${files[@]}")" || {
  echo "ingest aborted: one or more task specs are invalid (see errors above)" >&2
  exit 1
}

queue_json="$(printf '%s' "$specs_json" | jq '
  map({task_id: .id, type: .type, priority: (.priority // "P2"), status: "pending",
       depends_on: (.depends_on // []), file: ._file})
  | sort_by(.priority, .task_id)
')"

mkdir -p "$(dirname "$OUT")"
printf '%s\n' "$queue_json" > "$OUT"

count="$(printf '%s' "$queue_json" | jq 'length')"
echo "ingested ${count} task(s) from ${TASKS_DIR} -> ${OUT}"
printf '%s\n' "$queue_json"
