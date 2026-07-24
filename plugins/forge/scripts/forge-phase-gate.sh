#!/usr/bin/env bash
#
# forge-phase-gate.sh - confirm a finished phase actually filed its artifacts.
#
# Every forge phase reports its own outcome, including the artifacts it claims to
# have written. That self-report is the only thing the workflow used to have, and
# a claim is not a file: a write that was blocked by a tool guard, or simply never
# attempted, still comes back as `status: ok` with an `artifacts` list, and the
# pipeline advances on a map, plan, or report that is not on disk. This script is
# the part of the pipeline that actually looks.
#
# It also stamps the context cache after a successful intake. Stamping is what
# lets a later run reuse the brief instead of paying for intake again, and it was
# previously left to the intake agent to run for itself - a step a model can skip
# without any visible failure. Doing it here makes the stamp a property of the
# pipeline rather than of an agent's adherence.
#
# Usage:
#   forge-phase-gate.sh <phase> --run-dir <dir> [--repo <path>] [--artifacts a,b]
#
#   <phase>       intake | plan | build | verify | review | integrate | report
#   --run-dir     the task's run dir, where phase artifacts are filed
#   --repo        repo the context cache is stamped against (default: cwd)
#   --artifacts   comma/space separated override of the phase's expected artifacts
#
# An artifact counts as filed only when it exists and is non-empty: a zero-byte
# plan.md is a failed write, not a plan.
#
# Output: the JSON verdict on stdout, a one-line human summary on stderr.
#   {"phase":...,"ok":bool,"required":[...],"present":[...],"missing":[...],
#    "stamped":bool|null,"reason":...}
#
# Exit status: 0 all artifacts filed | 1 one or more missing | 2 usage error.
# A failed context stamp does NOT fail the gate: the cache is an optimization, and
# losing it only means the next run redoes intake.
#
# Deps: jq, git (via forge-context-cache.sh), forge-lib.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

usage() {
  echo "usage: forge-phase-gate.sh <phase> --run-dir <dir> [--repo <path>] [--artifacts a,b]" >&2
  exit 2
}

# The artifact each phase must leave behind. This table is the single source of
# truth for the pipeline's phase -> artifact contract: the workflow names only the
# phase, and the phase agents' documented `artifacts` lists mirror what is here.
default_artifacts() {
  case "$1" in
    intake)    printf 'context-brief.md' ;;
    plan)      printf 'plan.md' ;;
    build)     printf 'diff.patch' ;;
    verify)    printf 'checks.json verify.md' ;;
    review)    printf 'review.md' ;;
    integrate) printf 'pr.json' ;;
    report)    printf 'report.md' ;;
    *)         return 1 ;;
  esac
}

phase="${1:-}"
case "$phase" in
  -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
  ''|--*) usage ;;
esac
shift

run_dir=""
repo="$TARGET"
artifacts_override=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-dir) run_dir="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --artifacts) artifacts_override="${2:-}"; shift 2 ;;
    *) echo "forge-phase-gate: unexpected argument '$1'" >&2; usage ;;
  esac
done
[ -n "$run_dir" ] || { echo "forge-phase-gate: --run-dir is required" >&2; exit 2; }

if [ -n "$artifacts_override" ]; then
  artifacts="$(printf '%s' "$artifacts_override" | tr ',' ' ')"
elif ! artifacts="$(default_artifacts "$phase")"; then
  echo "forge-phase-gate: unknown phase '$phase'" >&2
  usage
fi

# Newline-delimited rather than bash arrays: an empty array under `set -u` is an
# error on the bash 3.2 that ships with macOS, and these lists are often empty.
present=""
missing=""
# $artifacts is a deliberate space-separated list; splitting it is the point.
# shellcheck disable=SC2086
for artifact in $artifacts; do
  if [ -s "$run_dir/$artifact" ]; then
    present="${present}${artifact}
"
  else
    missing="${missing}${artifact}
"
  fi
done

# Stamp only a complete intake: hashing the files a half-written brief cites would
# record an invalidation set that does not cover the map the next run reuses.
stamped="null"
note=""
if [ "$phase" = "intake" ] && [ -z "$missing" ]; then
  if stamp_out="$(bash "$SCRIPT_DIR/forge-context-cache.sh" stamp --run-dir "$run_dir" --repo "$repo" 2>&1)"; then
    stamped="true"
    note="$(printf '%s' "$stamp_out" | tr '\n' ' ')"
  else
    stamped="false"
    note="context cache not stamped (the next run will redo intake): $(printf '%s' "$stamp_out" | tr '\n' ' ')"
  fi
fi

if [ -z "$missing" ]; then
  ok="true"
  reason="all expected artifacts filed"
  status=0
else
  ok="false"
  reason="phase reported success but these artifacts are missing or empty in $run_dir"
  status=1
fi
[ -z "$note" ] || reason="$reason; $note"

jq -n \
  --arg phase "$phase" \
  --argjson ok "$ok" \
  --arg present "$present" \
  --arg missing "$missing" \
  --argjson stamped "$stamped" \
  --arg reason "$reason" \
  '{phase: $phase,
    ok: $ok,
    required: (($present + $missing) | split("\n") | map(select(length > 0)) | sort),
    present: ($present | split("\n") | map(select(length > 0))),
    missing: ($missing | split("\n") | map(select(length > 0))),
    stamped: $stamped,
    reason: $reason}'

if [ "$status" -eq 0 ]; then
  echo "forge-phase-gate: $phase ok - $reason" >&2
else
  echo "forge-phase-gate: $phase FAILED - $(printf '%s' "$missing" | tr '\n' ' ')missing in $run_dir" >&2
fi
exit "$status"
