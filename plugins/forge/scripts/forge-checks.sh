#!/usr/bin/env bash
#
# forge-checks.sh - run the project's configured checks and record the evidence.
#
# This is the mechanical half of the verify phase, split out of the agent so the
# pass/fail of every command is written by a script, not asserted by a model. The
# verify agent invokes this once, treats the emitted checks.json as the
# authoritative record of what ran and how it exited, and spends its own reasoning
# only on grading the free-text acceptance criteria against that record. An agent
# cannot report "tests passed" without an exit code here to back it.
#
# For each configured command (test always, then build, lint, typecheck) it
# records {name, command, configured, ran, exit_code, excerpt}, where a command
# that exits 127 is treated as could-not-run (a missing tool - an environment
# problem for a human, not a failing grade). It also folds in the two mechanical
# preconditions verify checks today: a non-empty diff against the base (via
# forge-diff.sh) and that there is a branch with changes to grade. The diff's
# changed-line count is recorded as `diff_lines` - the fast profile compares it
# against review_threshold_lines to decide whether review is worth running.
#
# Usage:
#   forge-checks.sh [--run-dir <dir>] [--base <branch>]
#       --run-dir  write checks.json here (default: JSON to stdout only)
#       --base     base branch for the diff (default: config base_branch, else develop)
#
# Output: checks.json (when --run-dir is given) plus a human summary line.
#   overall is one of pass | fail | blocked | empty-diff.
#
# Exit status encodes overall so a caller can branch without parsing:
#   0 pass | 1 fail | 3 blocked | 4 empty-diff | 2 usage/environment error.
#
# blocked outranks fail: a command that could not run means the environment is
# not set up, so the whole run is unreliable until a human fixes it - any real
# failure resurfaces on the re-run.
#
# Deps: git, jq, python3 (via forge-lib.sh), forge-diff.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

forge_require git || exit 2

# Lines of a failing command's output to keep as its excerpt (the tail, where an
# assertion or stack trace usually lands) - enough to act on, not the whole log.
EXCERPT_LINES=40

run_dir=""
base=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-dir) run_dir="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    --*) echo "forge-checks: unknown flag '$1'" >&2; exit 2 ;;
    *) echo "forge-checks: unexpected argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$base" ] || base="$(config_get base_branch develop)"

cd "$TARGET" || { echo "forge-checks: cannot enter target repo: $TARGET" >&2; exit 2; }
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "forge-checks: $TARGET is not a git repository" >&2
  exit 2
fi

# Changed lines in the diff, set below. Recorded in checks.json so the fast
# profile's review-skip threshold is compared against a measured number rather
# than a model's estimate of how big the change was.
diff_lines=0

# emit <overall> <diff_empty-literal> [command-object-json...]
# Assembles checks.json from the per-command jq objects, writes it (or prints it),
# and reports a one-line summary.
emit() {
  local overall="$1" diff_empty="$2"; shift 2
  local json
  if [ "$#" -gt 0 ]; then
    json="$(printf '%s\n' "$@" | jq -s \
      --arg base "$base" --arg overall "$overall" --argjson diff_empty "$diff_empty" \
      --argjson diff_lines "$diff_lines" \
      '{base:$base, diff_empty:$diff_empty, diff_lines:$diff_lines, overall:$overall, commands:.}')"
  else
    json="$(jq -n --arg base "$base" --arg overall "$overall" --argjson diff_empty "$diff_empty" \
      --argjson diff_lines "$diff_lines" \
      '{base:$base, diff_empty:$diff_empty, diff_lines:$diff_lines, overall:$overall, commands:[]}')"
  fi
  if [ -n "$run_dir" ]; then
    mkdir -p "$run_dir"
    printf '%s\n' "$json" > "$run_dir/checks.json"
    echo "forge-checks: overall=$overall  ($run_dir/checks.json)"
  else
    printf '%s\n' "$json"
    echo "forge-checks: overall=$overall" >&2
  fi
}

# Precondition: a non-empty diff against the up-to-date base. forge-diff.sh exits
# non-zero only on an environment error (no repo, base ref missing); an empty diff
# is a clean exit with no output and means build delivered nothing to grade.
diff_out="$("$SCRIPT_DIR/forge-diff.sh" "$base")"
diff_rc=$?
if [ "$diff_rc" -ne 0 ]; then
  echo "forge-checks: cannot compute diff against '$base' (see forge-diff error above)" >&2
  exit 2
fi
if [ -z "$diff_out" ]; then
  emit "empty-diff" true
  exit 4
fi

# Count added/removed lines inside hunks only. Tracking the hunk boundary is what
# keeps the `---`/`+++` file headers out of the count: they can only appear
# between a `diff --git` line and the first `@@`.
diff_lines="$(printf '%s\n' "$diff_out" | awk '
  /^diff --git / { inhunk = 0; next }
  /^@@/          { inhunk = 1; next }
  inhunk && /^[+-]/ { n++ }
  END { print n + 0 }
')"

objs=()
any_fail=false
any_blocked=false

# run_one <name>: run the configured command for <name>, append its result object
# to objs, and flag failure/blocked. A command exiting 127 is a missing tool
# (could-not-run -> blocked); any other non-zero is a genuine failure.
run_one() {
  local name="$1" cmd out_file rc ran excerpt
  cmd="$(config_get "commands.$name" "")"
  if [ -z "$cmd" ]; then
    objs+=("$(jq -n --arg name "$name" \
      '{name:$name, command:"", configured:false, ran:false, exit_code:null, excerpt:""}')")
    return 0
  fi
  out_file="$(mktemp)"
  ( cd "$TARGET" && bash -c "$cmd" ) >"$out_file" 2>&1
  rc=$?
  excerpt=""
  if [ "$rc" -eq 127 ]; then
    ran=false
    any_blocked=true
    excerpt="$(tail -n "$EXCERPT_LINES" "$out_file")"
  elif [ "$rc" -ne 0 ]; then
    ran=true
    any_fail=true
    excerpt="$(tail -n "$EXCERPT_LINES" "$out_file")"
  else
    ran=true
  fi
  objs+=("$(jq -n --arg name "$name" --arg cmd "$cmd" --argjson ran "$ran" \
    --argjson exit "$rc" --arg excerpt "$excerpt" \
    '{name:$name, command:$cmd, configured:true, ran:$ran, exit_code:$exit, excerpt:$excerpt}')")
  rm -f "$out_file"
}

run_one test
run_one build
run_one lint
run_one typecheck

if [ "$any_blocked" = true ]; then
  emit "blocked" false "${objs[@]}"
  exit 3
elif [ "$any_fail" = true ]; then
  emit "fail" false "${objs[@]}"
  exit 1
else
  emit "pass" false "${objs[@]}"
  exit 0
fi
