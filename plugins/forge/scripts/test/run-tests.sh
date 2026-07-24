#!/usr/bin/env bash
#
# Unit tests for config_get in forge-lib.sh. Exercises the absent-key and
# empty-string-value fallback cases. Exits non-zero if any case fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)/forge-lib.sh"

if [ ! -f "$LIB" ]; then
  echo "forge-lib.sh not found: $LIB" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fixture config: one key set to empty string, no other keys.
mkdir -p "$TMP/.forge"
cat > "$TMP/.forge/config.yaml" <<'YAML'
version: 1
empty_key: ""
YAML

# Source the lib with TARGET pointing at the temp fixture dir.
FORGE_TARGET_REPO="$TMP"
# shellcheck source=/dev/null
. "$LIB"

PASS=0
FAIL=0

# assert_eq <expected> <got> <label>
assert_eq() {
  local expected="$1" got="$2" label="$3"
  if [ "$got" = "$expected" ]; then
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s  expected=%q  got=%q\n' "$label" "$expected" "$got"
    FAIL=$((FAIL + 1))
  fi
}

echo "config_get fallback tests"
echo "fixture: $TMP/.forge/config.yaml"
echo

echo "Absent key falls back to default:"
result="$(config_get missing.key SENTINEL)"
assert_eq "SENTINEL" "$result" "absent key -> default"

echo
echo "Empty-string value falls back to default:"
result="$(config_get empty_key SENTINEL)"
assert_eq "SENTINEL" "$result" "empty-string value -> default"

SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
EX="$(cd "$SCRIPTS_DIR/.." && pwd)/examples"

echo
echo "branch_name builds forge/<type>/<id> with no doubled prefix:"
BTMP="$(mktemp -d)"
mkdir -p "$BTMP/tasks"
cp "$EX/fix-01J9Z6Q9H7K3M2N5P8R4T6V0XA.md" "$EX/build-01J9Z7C4M0PA2R6T8V1XB3D5FG.md" "$BTMP/tasks/"
got="$(FORGE_TARGET_REPO="$BTMP" bash "$SCRIPTS_DIR/forge-context.sh" fix-01J9Z6Q9H7K3M2N5P8R4T6V0XA 2>/dev/null \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["tasks"][0]["branch"])')"
assert_eq "forge/fix/01J9Z6Q9H7K3M2N5P8R4T6V0XA" "$got" "fix task -> forge/fix/<id>"
got="$(FORGE_TARGET_REPO="$BTMP" bash "$SCRIPTS_DIR/forge-context.sh" build-01J9Z7C4M0PA2R6T8V1XB3D5FG 2>/dev/null \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["tasks"][0]["branch"])')"
assert_eq "forge/build/01J9Z7C4M0PA2R6T8V1XB3D5FG" "$got" "build task -> forge/build/<id>"
rm -rf "$BTMP"

echo
echo "check-conflicts flags overlapping forge PRs and clears disjoint ones:"
CTMP="$(mktemp -d)"
git -C "$CTMP" init -q -b main >/dev/null 2>&1
git -C "$CTMP" config user.email tester@forge.test
git -C "$CTMP" config user.name "forge tester"
printf 'a\nb\nc\n' > "$CTMP/shared.txt"
printf 'x\n' > "$CTMP/other.txt"
git -C "$CTMP" add -A && git -C "$CTMP" commit -qm base
git -C "$CTMP" checkout -q -b feat-a && printf 'A\nb\nc\n' > "$CTMP/shared.txt" && git -C "$CTMP" commit -qam a
git -C "$CTMP" checkout -q main && git -C "$CTMP" checkout -q -b feat-b && printf 'B\nb\nc\n' > "$CTMP/shared.txt" && git -C "$CTMP" commit -qam b
git -C "$CTMP" checkout -q main && git -C "$CTMP" checkout -q -b feat-c && printf 'y\n' > "$CTMP/other.txt" && git -C "$CTMP" commit -qam c
git -C "$CTMP" checkout -q main
cc_out="$(FORGE_TARGET_REPO="$CTMP" bash "$SCRIPTS_DIR/check-conflicts.sh" --base main --refs "feat-a feat-b feat-c" 2>&1)"
case "$cc_out" in *shared.txt*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "reports conflict on the co-edited file"
case "$cc_out" in *other.txt*) got=yes ;; *) got=no ;; esac
assert_eq "no" "$got" "no false conflict on a file only one branch touched"
rm -rf "$CTMP"

echo
echo "run-all defers a task until its depends_on has merged into base:"
GTMP="$(mktemp -d)"
mkdir -p "$GTMP/tasks"
git -C "$GTMP" init -q -b develop
git -C "$GTMP" config user.email tester@forge.test
git -C "$GTMP" config user.name "forge tester"
printf 'seed\n' > "$GTMP/seed.txt"
git -C "$GTMP" add -A && git -C "$GTMP" commit -qm base
cat > "$GTMP/tasks/fix-aaaaaa1111.md" <<'SPEC'
---
id: fix-aaaaaa1111
title: Task A
type: fix
autonomy_tier: 1
acceptance_criteria:
  - does a thing
---
Body A.
SPEC
cat > "$GTMP/tasks/fix-bbbbbb2222.md" <<'SPEC'
---
id: fix-bbbbbb2222
title: Task B
type: fix
autonomy_tier: 1
depends_on:
  - fix-aaaaaa1111
acceptance_criteria:
  - does another thing
---
Body B.
SPEC
has_task() { python3 -c 'import sys,json;d=json.load(sys.stdin);print(any(t["taskId"]==sys.argv[1] for t in d["tasks"]))' "$1"; }
is_deferred() { python3 -c 'import sys,json;d=json.load(sys.stdin);print(any(x["taskId"]==sys.argv[1] for x in d["deferred"]))' "$1"; }

# Case 1: A is unmerged, so A is runnable but B (depends on A) is held back.
out1="$(FORGE_TARGET_REPO="$GTMP" bash "$SCRIPTS_DIR/forge-context.sh" --all 2>/dev/null)"
assert_eq "True" "$(printf '%s' "$out1" | has_task fix-aaaaaa1111)" "A (no deps) is runnable"
assert_eq "True" "$(printf '%s' "$out1" | is_deferred fix-bbbbbb2222)" "B is deferred while A is unmerged"
assert_eq "False" "$(printf '%s' "$out1" | has_task fix-bbbbbb2222)" "B is not in the runnable set while deferred"

# Case 2: A parks at pr_open and its branch merges into base -> B becomes runnable.
mkdir -p "$GTMP/.forge/runs/fix-aaaaaa1111"
printf '{"status":"pr_open"}' > "$GTMP/.forge/runs/fix-aaaaaa1111/run.json"
git -C "$GTMP" checkout -q -b forge/fix/aaaaaa1111
printf 'A change\n' > "$GTMP/a.txt"
git -C "$GTMP" add -A && git -C "$GTMP" commit -qm "task A"
git -C "$GTMP" checkout -q develop
git -C "$GTMP" merge -q --no-ff -m "merge A" forge/fix/aaaaaa1111
out2="$(FORGE_TARGET_REPO="$GTMP" bash "$SCRIPTS_DIR/forge-context.sh" --all 2>/dev/null)"
assert_eq "True" "$(printf '%s' "$out2" | has_task fix-bbbbbb2222)" "B is runnable once A is merged into base"
assert_eq "False" "$(printf '%s' "$out2" | is_deferred fix-bbbbbb2222)" "B is no longer deferred once A is merged"
rm -rf "$GTMP"

echo
echo "check-conflicts flags a stacked pair (one branch's history contains another):"
STMP="$(mktemp -d)"
git -C "$STMP" init -q -b main
git -C "$STMP" config user.email tester@forge.test
git -C "$STMP" config user.name "forge tester"
printf 'seed\n' > "$STMP/seed.txt"
git -C "$STMP" add -A && git -C "$STMP" commit -qm base
git -C "$STMP" checkout -q -b feat-x && printf 'x\n' > "$STMP/x.txt" && git -C "$STMP" add -A && git -C "$STMP" commit -qm x
git -C "$STMP" checkout -q -b feat-y && printf 'y\n' > "$STMP/y.txt" && git -C "$STMP" add -A && git -C "$STMP" commit -qm y
git -C "$STMP" checkout -q main
sc_out="$(FORGE_TARGET_REPO="$STMP" bash "$SCRIPTS_DIR/check-conflicts.sh" --base main --refs "feat-x feat-y" 2>&1)"
case "$sc_out" in *STACK*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "reports a stack when one branch contains the other"
case "$sc_out" in *contains*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "names the containment relationship"
case "$sc_out" in *CONFLICT*) got=yes ;; *) got=no ;; esac
assert_eq "no" "$got" "a pure stack is not mis-reported as a file conflict"
rm -rf "$STMP"

echo
echo "forge-diff scopes the diff to the task, excluding already-merged sibling work:"
DTMP="$(mktemp -d)"
DBARE="$(mktemp -d)"
git init -q --bare -b develop "$DBARE" >/dev/null 2>&1
git -C "$DTMP" init -q -b develop
git -C "$DTMP" config user.email tester@forge.test
git -C "$DTMP" config user.name "forge tester"
git -C "$DTMP" remote add origin "$DBARE"
printf 'seed\n' > "$DTMP/seed.txt"
git -C "$DTMP" add -A && git -C "$DTMP" commit -qm base
seed_sha="$(git -C "$DTMP" rev-parse HEAD)"
git -C "$DTMP" push -q origin develop
# Sibling task A lands on the remote base: branch, commit, merge, push.
git -C "$DTMP" checkout -q -b forge/fix/aaa && printf 'A\n' > "$DTMP/sibling.txt"
git -C "$DTMP" add -A && git -C "$DTMP" commit -qm "task A: sibling.txt"
git -C "$DTMP" checkout -q develop && git -C "$DTMP" merge -q --no-ff -m "merge A" forge/fix/aaa
git -C "$DTMP" push -q origin develop
# Make the LOCAL base stale (origin/develop keeps A); stack task B on A's branch.
git -C "$DTMP" reset -q --hard "$seed_sha"
git -C "$DTMP" checkout -q -b forge/fix/bbb forge/fix/aaa && printf 'B\n' > "$DTMP/mine.txt"
git -C "$DTMP" add -A && git -C "$DTMP" commit -qm "task B: mine.txt"
# The stale-local-base diff (the original bug) drags the merged sibling file in.
stale_diff="$(git -C "$DTMP" diff "$(git -C "$DTMP" merge-base develop HEAD)" HEAD --name-only)"
case "$stale_diff" in *sibling.txt*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "stale local base diff drags in the merged sibling file (the bug)"
# forge-diff resolves the up-to-date origin base and scopes to task B only.
fd_out="$(FORGE_TARGET_REPO="$DTMP" bash "$SCRIPTS_DIR/forge-diff.sh" develop 2>/dev/null)"
case "$fd_out" in *mine.txt*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "forge-diff includes this task's file"
case "$fd_out" in *sibling.txt*) got=yes ;; *) got=no ;; esac
assert_eq "no" "$got" "forge-diff excludes the already-merged sibling file"
rm -rf "$DTMP" "$DBARE"

echo
echo "forge-checks records command evidence and classifies the overall result:"
FCHK="$(mktemp -d)"
git -C "$FCHK" init -q -b develop
git -C "$FCHK" config user.email tester@forge.test
git -C "$FCHK" config user.name "forge tester"
printf 'seed\n' > "$FCHK/seed.txt"
git -C "$FCHK" add -A && git -C "$FCHK" commit -qm base
git -C "$FCHK" checkout -q -b forge/fix/checks && printf 'change\n' > "$FCHK/f.txt"
git -C "$FCHK" add -A && git -C "$FCHK" commit -qm change
mkdir -p "$FCHK/.forge"

# run_checks <test-command>: run forge-checks against a config whose test command
# is <test-command>, leaving CHK_OVERALL (from checks.json) and CHK_RC set.
run_checks() {
  cat > "$FCHK/.forge/config.yaml" <<YAML
version: 1
base_branch: develop
commands:
  test: "$1"
YAML
  local rd="$FCHK/.forge/runs/rd"
  rm -rf "$rd"
  FORGE_TARGET_REPO="$FCHK" bash "$SCRIPTS_DIR/forge-checks.sh" --run-dir "$rd" --base develop >/dev/null 2>&1
  CHK_RC=$?
  CHK_OVERALL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["overall"])' "$rd/checks.json" 2>/dev/null)"
}

run_checks "exit 0"
assert_eq "pass" "$CHK_OVERALL" "all commands exit 0 -> overall pass"
assert_eq "0" "$CHK_RC" "pass -> exit code 0"
run_checks "exit 1"
assert_eq "fail" "$CHK_OVERALL" "a command exiting non-zero -> overall fail"
assert_eq "1" "$CHK_RC" "fail -> exit code 1"
run_checks "forge_missing_tool_zzz"
assert_eq "blocked" "$CHK_OVERALL" "a missing tool (exit 127) -> overall blocked"
assert_eq "3" "$CHK_RC" "blocked -> exit code 3"
# On the base branch there is no diff, so build delivered nothing to grade.
git -C "$FCHK" checkout -q develop
rm -rf "$FCHK/.forge/runs/rd"
FORGE_TARGET_REPO="$FCHK" bash "$SCRIPTS_DIR/forge-checks.sh" --run-dir "$FCHK/.forge/runs/rd" --base develop >/dev/null 2>&1
assert_eq "4" "$?" "empty diff -> exit code 4"
assert_eq "empty-diff" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["overall"])' "$FCHK/.forge/runs/rd/checks.json")" "empty diff -> overall empty-diff"
rm -rf "$FCHK"

echo
echo "task profiles resolve from the spec, then the repo config, then standard:"
PTMP="$(mktemp -d)"
mkdir -p "$PTMP/tasks" "$PTMP/.forge"
# profile_of <task-id>: the resolved profile forge-context assembled for the task.
profile_of() {
  FORGE_TARGET_REPO="$PTMP" bash "$SCRIPTS_DIR/forge-context.sh" "$1" 2>/dev/null \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["tasks"][0]["profile"])'
}
# task_field <task-id> <key>: any other resolved field, JSON-encoded.
task_field() {
  FORGE_TARGET_REPO="$PTMP" bash "$SCRIPTS_DIR/forge-context.sh" "$1" 2>/dev/null \
    | python3 -c 'import sys, json; print(json.dumps(json.load(sys.stdin)["tasks"][0][sys.argv[1]]))' "$2"
}
write_spec() {  # write_spec <id> <profile-line>
  cat > "$PTMP/tasks/$1.md" <<SPEC
---
id: $1
title: Profile fixture
type: fix
autonomy_tier: 1
$2
acceptance_criteria:
  - does a thing
---
Body.
SPEC
}
write_spec fix-prof000001 ""
write_spec fix-prof000002 "profile: fast"
write_spec fix-prof000003 "profile: audit"

assert_eq "standard" "$(profile_of fix-prof000001)" "no spec profile, no config -> standard"
assert_eq "fast" "$(profile_of fix-prof000002)" "spec profile wins when set"

printf 'version: 1\nprofile: fast\n' > "$PTMP/.forge/config.yaml"
assert_eq "fast" "$(profile_of fix-prof000001)" "config profile applies when the spec omits one"
assert_eq "audit" "$(profile_of fix-prof000003)" "spec profile overrides the config profile"
assert_eq "null" "$(task_field fix-prof000003 branch)" "audit profile gets no working branch"
assert_eq '"forge/fix/prof000002"' "$(task_field fix-prof000002 branch)" "fast profile still gets a branch"
assert_eq "true" "$(task_field fix-prof000002 hasAcceptanceCriteria)" "spec criteria are surfaced to the workflow"

got="$(FORGE_TARGET_REPO="$PTMP" bash "$SCRIPTS_DIR/forge-context.sh" --goal "build a thing" 2>/dev/null \
  | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d["tasks"][0]["hasAcceptanceCriteria"])')"
assert_eq "False" "$got" "a goal prompt has no criteria, so fast still runs intake"

printf 'version: 1\nprofile: fast\nreview_threshold_lines: 250\n' > "$PTMP/.forge/config.yaml"
got="$(FORGE_TARGET_REPO="$PTMP" bash "$SCRIPTS_DIR/forge-context.sh" fix-prof000001 2>/dev/null \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["config"]["review_threshold_lines"])')"
assert_eq "250" "$got" "review_threshold_lines is passed through to the workflow"
printf 'version: 1\n' > "$PTMP/.forge/config.yaml"
got="$(FORGE_TARGET_REPO="$PTMP" bash "$SCRIPTS_DIR/forge-context.sh" fix-prof000001 2>/dev/null \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["config"]["review_threshold_lines"])')"
assert_eq "400" "$got" "review_threshold_lines defaults to 400"

echo
echo "the validators accept valid profiles and reject invalid ones:"
write_spec fix-prof000004 "profile: turbo"
FORGE_TARGET_REPO="$PTMP" bash "$SCRIPTS_DIR/validate-task.sh" "$PTMP/tasks/fix-prof000002.md" >/dev/null 2>&1
assert_eq "0" "$?" "validate-task accepts profile: fast"
vt_out="$(FORGE_TARGET_REPO="$PTMP" bash "$SCRIPTS_DIR/validate-task.sh" "$PTMP/tasks/fix-prof000004.md" 2>&1)"
assert_eq "1" "$?" "validate-task rejects an unknown profile"
case "$vt_out" in *profile*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "the rejection names the profile field"

vc() {  # vc <config-body>: run validate-config against a fixture, print PASS/FAIL line
  printf '%s\n' "$1" > "$PTMP/.forge/config.yaml"
  bash "$SCRIPTS_DIR/validate-config.sh" "$PTMP/.forge/config.yaml" 2>&1
}
VALID_BASE='version: 1
base_branch: develop
vcs:
  host: github
commands:
  test: "npm test"'
case "$(vc "$VALID_BASE
profile: fast
review_threshold_lines: 400")" in PASS*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "validate-config accepts profile: fast with a threshold"
case "$(vc "$VALID_BASE
profile: turbo")" in FAIL*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "validate-config rejects an unknown profile"
case "$(vc "$VALID_BASE
profile: fast
review_threshold_lines: -1")" in FAIL*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "validate-config rejects a negative review_threshold_lines"
case "$(vc "$VALID_BASE
review_threshold_lines: 400")" in PASS*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "a threshold on a standard-default repo is valid (specs may still ask for fast)"
rm -rf "$PTMP"

echo
echo "surfaces group tasks: same surface stacks serially, different ones run in parallel:"
SUR="$(mktemp -d)"
git -C "$SUR" init -q -b develop
git -C "$SUR" config user.email tester@forge.test
git -C "$SUR" config user.name "forge tester"
mkdir -p "$SUR/tasks" "$SUR/.forge"
printf 'seed\n' > "$SUR/seed.txt"
git -C "$SUR" add -A && git -C "$SUR" commit -qm base
# write_sur <id> <priority> <surface-line> <depends-block>
write_sur() {
  cat > "$SUR/tasks/$1.md" <<SPEC
---
id: $1
title: Surface fixture $1
type: fix
autonomy_tier: 1
priority: $2
$3
$4
acceptance_criteria:
  - does a thing
---
Body.
SPEC
}
write_sur fix-api000001 P2 "surface: api" ""
write_sur fix-api000002 P1 "surface: api" ""
write_sur fix-ui0000001 P2 "surface: ui-shell" ""

sur_field() {  # sur_field <jq-ish python expr over tasks>
  FORGE_TARGET_REPO="$SUR" bash "$SCRIPTS_DIR/forge-context.sh" --all 2>/dev/null \
    | python3 -c "import sys, json; d=json.load(sys.stdin); print($1)"
}
assert_eq "api api ui-shell" "$(sur_field '" ".join(t["surface"] for t in d["tasks"])')" \
  "tasks are emitted group-major, one surface at a time"
assert_eq "fix-api000002 fix-api000001" \
  "$(sur_field '" ".join(t["taskId"] for t in d["tasks"] if t["surface"]=="api")')" \
  "within a surface, higher priority is stacked first"
assert_eq "True" "$(sur_field 'all(t["worktree"] for t in d["tasks"])')" \
  "a multi-surface run allocates a worktree per task"

# depends_on inside one surface is satisfied by stacking, so it must not defer.
write_sur fix-api000003 P0 "surface: api" "depends_on: [fix-api000001]"
assert_eq "True" "$(sur_field 'any(t["taskId"]=="fix-api000003" for t in d["tasks"])')" \
  "a same-surface dependency does not defer the dependent"
assert_eq "fix-api000002 fix-api000001 fix-api000003" \
  "$(sur_field '" ".join(t["taskId"] for t in d["tasks"] if t["surface"]=="api")')" \
  "depends_on outranks priority when ordering a stack"
rm "$SUR/tasks/fix-api000003.md"

# A cross-surface dependency still waits for a real merge, as before.
write_sur fix-ui0000002 P2 "surface: ui-shell" "depends_on: [fix-api000001]"
assert_eq "True" \
  "$(sur_field 'any(x["taskId"]=="fix-ui0000002" for x in d["deferred"])')" \
  "a cross-surface dependency still defers until it merges"
rm "$SUR/tasks/fix-ui0000002.md"

# One surface only: nothing to run beside it, so no worktrees are allocated.
rm "$SUR/tasks/fix-ui0000001.md"
assert_eq "True" "$(sur_field 'all(t["worktree"] is None for t in d["tasks"])')" \
  "a single-group run works in the main checkout, no worktree"

# A declared surfaces list turns a typo into a run-time error.
printf 'version: 1\nsurfaces: [api, ui-shell]\n' > "$SUR/.forge/config.yaml"
write_sur fix-typo000001 P2 "surface: aip" ""
FORGE_TARGET_REPO="$SUR" bash "$SCRIPTS_DIR/forge-context.sh" --all >/dev/null 2>&1
assert_eq "1" "$?" "an undeclared surface fails the run"
serr="$(FORGE_TARGET_REPO="$SUR" bash "$SCRIPTS_DIR/forge-context.sh" --all 2>&1 >/dev/null)"
case "$serr" in *aip*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "the error names the offending surface"
rm "$SUR/tasks/fix-typo000001.md"
FORGE_TARGET_REPO="$SUR" bash "$SCRIPTS_DIR/forge-context.sh" --all >/dev/null 2>&1
assert_eq "0" "$?" "declared surfaces still pass"
rm -rf "$SUR"

echo
echo "forge-worktree isolates parallel tasks and never disturbs the main checkout:"
WT="$(mktemp -d)"
git -C "$WT" init -q -b develop
git -C "$WT" config user.email tester@forge.test
git -C "$WT" config user.name "forge tester"
printf 'seed\n' > "$WT/seed.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm base
mkdir -p "$WT/.forge"
printf 'version: 1\nbase_branch: develop\n' > "$WT/.forge/config.yaml"
wt() { FORGE_TARGET_REPO="$WT" bash "$SCRIPTS_DIR/forge-worktree.sh" "$@"; }

wt path fix-wt000001 >/dev/null
assert_eq "no" "$([ -d "$WT/.forge/worktrees/fix-wt000001" ] && echo yes || echo no)" \
  "path is side-effect free"
WP1="$(wt add fix-wt000001 --branch forge/fix/wt1 --base develop)"
WP2="$(wt add fix-wt000002 --branch forge/fix/wt2 --base develop)"
assert_eq "forge/fix/wt1" "$(git -C "$WP1" rev-parse --abbrev-ref HEAD)" "each tree holds its own branch"
assert_eq "develop" "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" "the main checkout never moves"

printf 'A\n' > "$WP1/a.txt"; git -C "$WP1" add -A; git -C "$WP1" commit -qm "task A"
printf 'B\n' > "$WP2/b.txt"; git -C "$WP2" add -A; git -C "$WP2" commit -qm "task B"
assert_eq "no" "$([ -f "$WP1/b.txt" ] && echo yes || echo no)" "concurrent tasks cannot see each other's edits"

# A stacked task cuts from the predecessor's branch and inherits its commits.
WP3="$(wt add fix-wt000003 --branch forge/fix/wt3 --base forge/fix/wt1)"
assert_eq "yes" "$([ -f "$WP3/a.txt" ] && echo yes || echo no)" "a stacked tree contains its predecessor's work"
assert_eq "no" "$([ -f "$WP3/b.txt" ] && echo yes || echo no)" "and not an unrelated surface's work"

WP1B="$(wt add fix-wt000001 --branch forge/fix/wt1 --base develop)"
assert_eq "$WP1" "$WP1B" "add is idempotent: an existing tree is reused"
assert_eq "yes" "$([ -f "$WP1/a.txt" ] && echo yes || echo no)" "reuse preserves the work already committed"

# Forge state resolves to the MAIN worktree even when invoked from inside one.
mkdir -p "$WT/.forge/runs/fix-wt000001" "$WT/.forge/runs/fix-wt000002"
printf '{"status":"pr_open"}' > "$WT/.forge/runs/fix-wt000001/run.json"
printf '{"status":"blocked"}' > "$WT/.forge/runs/fix-wt000002/run.json"
got="$(cd "$WP1" && FORGE_TARGET_REPO="$WP1" bash "$SCRIPTS_DIR/forge-worktree.sh" list | wc -l | tr -d ' ')"
assert_eq "3" "$got" "state resolves to the main worktree from inside a linked one"

wt prune >/dev/null 2>&1
assert_eq "no" "$([ -d "$WP1" ] && echo yes || echo no)" "prune reclaims a finished task's tree"
assert_eq "yes" "$([ -d "$WP2" ] && echo yes || echo no)" "prune keeps a blocked task's tree for a human"
assert_eq "yes" "$(git -C "$WT" show-ref --verify --quiet refs/heads/forge/fix/wt1 && echo yes || echo no)" \
  "pruning a tree never deletes its branch"
rm -rf "$WT"

echo
echo "the context brief is cached and invalidated by the files it cites:"
CTX="$(mktemp -d)"
git -C "$CTX" init -q -b develop
git -C "$CTX" config user.email tester@forge.test
git -C "$CTX" config user.name "forge tester"
mkdir -p "$CTX/src" "$CTX/tasks" "$CTX/.forge/runs/fix-ctx0000001"
printf 'export const a = 1\n' > "$CTX/src/api.ts"
printf 'helper\n' > "$CTX/src/util.ts"
git -C "$CTX" add -A && git -C "$CTX" commit -qm base
CRUN="$CTX/.forge/runs/fix-ctx0000001"
cat > "$CRUN/context-brief.md" <<'BRIEF'
# Context brief: fix-ctx0000001

## Context map
- `src/api.ts:1` - the entry point in play
- src/util.ts - shared helper
- `src/absent.ts:9` - cited but does not exist
- prose that is not a path at all

## Repo context sources
- none found
BRIEF
cat > "$CTX/tasks/fix-ctx0000001.md" <<'SPEC'
---
id: fix-ctx0000001
title: Cached brief fixture
type: fix
autonomy_tier: 1
acceptance_criteria:
  - does a thing
---
Body.
SPEC
CCACHE="$SCRIPTS_DIR/forge-context-cache.sh"
FORGE_TARGET_REPO="$CTX" bash "$CCACHE" stamp --run-dir "$CRUN" --repo "$CTX" >/dev/null 2>&1
assert_eq "0" "$?" "stamping an existing brief succeeds"
assert_eq '["src/api.ts","src/util.ts"]' \
  "$(jq -c '[.files[].path]' "$CRUN/context-cache.json")" \
  "records only the cited paths that resolve to real files"

# cache_fresh: 1 when the launcher would reuse the brief, 0 when it re-runs intake.
cache_fresh() {
  FORGE_TARGET_REPO="$CTX" bash "$CCACHE" check --run-dir "$CRUN" --repo "$CTX" >/dev/null 2>&1 \
    && echo 1 || echo 0
}
assert_eq "1" "$(cache_fresh)" "an untouched tree keeps the brief fresh"

printf 'export const a = 2\n' > "$CTX/src/api.ts"
assert_eq "0" "$(cache_fresh)" "editing a cited file invalidates the brief"
got="$(FORGE_TARGET_REPO="$CTX" bash "$CCACHE" check --run-dir "$CRUN" --repo "$CTX" 2>/dev/null | jq -c .changed)"
assert_eq '["src/api.ts"]' "$got" "the check names which cited file changed"

git -C "$CTX" checkout -q -- src/api.ts
assert_eq "1" "$(cache_fresh)" "reverting the file makes it fresh again"
mv "$CTX/src/util.ts" "$CTX/src/util-renamed.ts"
assert_eq "0" "$(cache_fresh)" "a cited file disappearing invalidates the brief"
mv "$CTX/src/util-renamed.ts" "$CTX/src/util.ts"

cp "$CRUN/context-brief.md" "$CTX/brief.orig"
printf 'appended\n' >> "$CRUN/context-brief.md"
assert_eq "0" "$(cache_fresh)" "editing the brief itself invalidates it"
cp "$CTX/brief.orig" "$CRUN/context-brief.md"
assert_eq "1" "$(cache_fresh)" "restoring the brief makes it fresh again"

# The launcher surfaces freshness to the sandboxed workflow as contextCacheFresh.
ctx_flag() {
  FORGE_TARGET_REPO="$CTX" bash "$SCRIPTS_DIR/forge-context.sh" fix-ctx0000001 2>/dev/null \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["tasks"][0]["contextCacheFresh"])'
}
assert_eq "True" "$(ctx_flag)" "the launcher reports a fresh cache to the workflow"
rm "$CRUN/context-cache.json"
assert_eq "False" "$(ctx_flag)" "an unstamped task reports a stale cache"
assert_eq "0" "$(cache_fresh)" "a missing cache is stale, never an error"
rm -rf "$CTX"

echo
echo "the phase gate checks artifacts actually landed and stamps the context cache:"
GTMPD="$(mktemp -d)"
git -C "$GTMPD" init -q -b develop
git -C "$GTMPD" config user.email tester@forge.test
git -C "$GTMPD" config user.name "forge tester"
mkdir -p "$GTMPD/src" "$GTMPD/tasks" "$GTMPD/.forge/runs/fix-gate000001"
printf 'export const a = 1\n' > "$GTMPD/src/api.ts"
git -C "$GTMPD" add -A && git -C "$GTMPD" commit -qm base
GATE="$SCRIPTS_DIR/forge-phase-gate.sh"
GRUN="$GTMPD/.forge/runs/fix-gate000001"
GOUT="$GTMPD/gate.json"
cat > "$GTMPD/tasks/fix-gate000001.md" <<'SPEC'
---
id: fix-gate000001
title: Phase gate fixture
type: fix
autonomy_tier: 1
acceptance_criteria:
  - does a thing
---
Body.
SPEC

# gate <phase> [extra args...] -> writes the JSON verdict to $GOUT, returns its
# exit status. The verdict cannot come back on stdout: a command substitution
# would run it in a subshell and its exit status is the whole point here.
gate() {
  local phase="$1"; shift
  FORGE_TARGET_REPO="$GTMPD" bash "$GATE" "$phase" \
    --run-dir "$GRUN" --repo "$GTMPD" "$@" > "$GOUT" 2>/dev/null
}

# A phase that claims success but filed nothing is caught, not believed.
gate intake; st=$?
assert_eq "1" "$st" "a missing artifact fails the gate"
assert_eq "false" "$(jq -r .ok "$GOUT")" "the verdict says not ok"
assert_eq '["context-brief.md"]' "$(jq -c .missing "$GOUT")" "the verdict names the missing artifact"

# A zero-byte file is a failed write, not an artifact.
: > "$GRUN/context-brief.md"
gate intake; st=$?
assert_eq "1" "$st" "an empty artifact still fails the gate"

# A real brief passes and gets stamped by the gate, with no agent involved.
printf '# Context brief\n\n- `src/api.ts:1` - the entry point\n' > "$GRUN/context-brief.md"
gate intake; st=$?
assert_eq "0" "$st" "a filed artifact passes the gate"
assert_eq "true" "$(jq -r .ok "$GOUT")" "the verdict says ok"
assert_eq "true" "$(jq -r .stamped "$GOUT")" "the gate stamps the context cache after intake"
assert_eq '["src/api.ts"]' "$(jq -c '[.files[].path]' "$GRUN/context-cache.json")" \
  "the stamp records the brief's cited files"
assert_eq "True" \
  "$(FORGE_TARGET_REPO="$GTMPD" bash "$SCRIPTS_DIR/forge-context.sh" fix-gate000001 2>/dev/null \
     | python3 -c 'import sys, json; print(json.load(sys.stdin)["tasks"][0]["contextCacheFresh"])')" \
  "the gate's stamp is what makes the next run reuse the brief"

# Only intake stamps; a multi-artifact phase reports exactly what is absent.
printf '{}\n' > "$GRUN/checks.json"
gate verify; st=$?
assert_eq "1" "$st" "a partially filed phase fails the gate"
assert_eq '["verify.md"]' "$(jq -c .missing "$GOUT")" "only the absent artifact is reported"
assert_eq '["checks.json"]' "$(jq -c .present "$GOUT")" "the filed artifact is reported present"
assert_eq "null" "$(jq -r .stamped "$GOUT")" "only intake stamps the context cache"

# The cache is an optimization: failing to stamp must not fail the gate.
gate intake --repo "$GTMPD/not-a-directory"; st=$?
assert_eq "0" "$st" "a failed stamp does not fail the gate"
assert_eq "false" "$(jq -r .stamped "$GOUT")" "the failed stamp is reported, not hidden"

# An unknown phase is a usage error, never a silent pass.
FORGE_TARGET_REPO="$GTMPD" bash "$GATE" bogus --run-dir "$GRUN" >/dev/null 2>&1
assert_eq "2" "$?" "an unknown phase is a usage error"
FORGE_TARGET_REPO="$GTMPD" bash "$GATE" intake >/dev/null 2>&1
assert_eq "2" "$?" "a missing --run-dir is a usage error"
rm -rf "$GTMPD"

echo
echo "forge-checks records the diff size the fast profile's review skip depends on:"
DLTMP="$(mktemp -d)"
git -C "$DLTMP" init -q -b develop
git -C "$DLTMP" config user.email tester@forge.test
git -C "$DLTMP" config user.name "forge tester"
printf 'seed\n' > "$DLTMP/seed.txt"
git -C "$DLTMP" add -A && git -C "$DLTMP" commit -qm base
git -C "$DLTMP" checkout -q -b forge/fix/lines
# 7 added lines across two files, one of which also removes a line.
printf 'l1\nl2\nl3\nl4\nl5\n' > "$DLTMP/added.txt"
printf 'replaced\ntail\n' > "$DLTMP/seed.txt"
git -C "$DLTMP" add -A && git -C "$DLTMP" commit -qm change
mkdir -p "$DLTMP/.forge"
printf 'version: 1\nbase_branch: develop\ncommands:\n  test: "exit 0"\n' > "$DLTMP/.forge/config.yaml"
FORGE_TARGET_REPO="$DLTMP" bash "$SCRIPTS_DIR/forge-checks.sh" --run-dir "$DLTMP/.forge/runs/rd" --base develop >/dev/null 2>&1
# 5 added (added.txt) + 2 added + 1 removed (seed.txt) = 8 changed lines; the
# ---/+++ file headers must not be counted.
assert_eq "8" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["diff_lines"])' "$DLTMP/.forge/runs/rd/checks.json")" "counts changed lines, excluding diff file headers"
rm -rf "$DLTMP"

echo
echo "forge-integrate pushes the branch, templates the PR body, and is idempotent:"
FINT="$(mktemp -d)"; FBARE="$(mktemp -d)"; FBIN="$(mktemp -d)"
# A gh shim: `pr list` returns $GH_EXISTING (default none); `pr create` records
# the title and body it was given and prints a canned PR url.
cat > "$FBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") echo "${GH_EXISTING:-[]}"; exit 0 ;;
  "pr create")
    shift 2; title=""; body_file=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --body-file) body_file="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    { echo "TITLE: $title"; echo "BODY:"; [ -n "$body_file" ] && cat "$body_file"; } > "${GH_RECORD:-/dev/null}"
    echo "https://github.com/x/y/pull/42"; exit 0 ;;
esac
echo "gh shim: unhandled: $*" >&2; exit 1
SH
chmod +x "$FBIN/gh"
git init -q --bare -b develop "$FBARE" >/dev/null 2>&1
git -C "$FINT" init -q -b develop
git -C "$FINT" config user.email tester@forge.test
git -C "$FINT" config user.name "forge tester"
git -C "$FINT" remote add origin "$FBARE"
mkdir -p "$FINT/.forge" "$FINT/tasks"
# Real repos gitignore .forge/ (forge's own repo and every target repo do). Left
# tracked, forge's config would be reverted by any branch switch mid-run, and the
# per-task worktrees would be committed as embedded gitlinks.
printf '.forge/\n' > "$FINT/.gitignore"
cat > "$FINT/.forge/config.yaml" <<'YAML'
version: 1
base_branch: develop
vcs:
  host: github
  cli: gh
YAML
cat > "$FINT/tasks/fix-intg000001.md" <<'SPEC'
---
id: fix-intg000001
title: Retry transient 503s
type: fix
autonomy_tier: 1
acceptance_criteria:
  - Requests that receive a 503 are retried
  - Retries stop on a 2xx
---
The client surfaces transient 503s to callers. Add bounded retry.
SPEC
printf 'seed\n' > "$FINT/seed.txt"
git -C "$FINT" add -A && git -C "$FINT" commit -qm base
git -C "$FINT" push -q origin develop
git -C "$FINT" checkout -q -b forge/fix/int && printf 'change\n' > "$FINT/f.txt"
git -C "$FINT" add -A && git -C "$FINT" commit -qm "task change"

IRUN="$FINT/.forge/runs/fix-intg000001"
# Record files live outside the repo so the gh shim's writes never dirty the
# working tree (real gh does not write into the repo either).
REC="$FBIN/gh_new.txt"
iout="$(PATH="$FBIN:$PATH" GH_RECORD="$REC" FORGE_TARGET_REPO="$FINT" bash "$SCRIPTS_DIR/forge-integrate.sh" \
  --task-id fix-intg000001 --run-dir "$IRUN" --spec "$FINT/tasks/fix-intg000001.md" 2>/dev/null)"
assert_eq "ok" "$(printf '%s' "$iout" | jq -r .status)" "new PR -> status ok"
assert_eq "https://github.com/x/y/pull/42" "$(printf '%s' "$iout" | jq -r .pr_url)" "returns the created PR url"
assert_eq "https://github.com/x/y/pull/42" "$(jq -r .pr_url "$IRUN/pr.json" 2>/dev/null)" "writes pr.json with the url"
got="$(git -C "$FINT" ls-remote origin forge/fix/int | wc -l | tr -d ' ')"
assert_eq "1" "$got" "the branch was pushed to origin"
case "$(cat "$REC")" in *"fix: Retry transient 503s"*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "PR title carries the conventional prefix from the task type"
case "$(cat "$REC")" in *"- [ ] Requests that receive a 503 are retried"*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "PR body templates the acceptance criteria as a checklist"
case "$(cat "$REC")" in *"Opened by forge."*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "PR body carries the forge footer"
case "$(cat "$REC")" in *"review was not run"*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "PR body does not claim a review that produced no artifact"

# With a review.md in the run dir (the standard profile, or a fast task whose
# diff cleared the threshold), the body reports both gates.
REC3="$FBIN/gh_review.txt"
printf '# Review\n\nverdict: PASS\n' > "$IRUN/review.md"
PATH="$FBIN:$PATH" GH_RECORD="$REC3" FORGE_TARGET_REPO="$FINT" bash "$SCRIPTS_DIR/forge-integrate.sh" \
  --task-id fix-intg000001 --run-dir "$IRUN" --spec "$FINT/tasks/fix-intg000001.md" >/dev/null 2>&1
case "$(cat "$REC3")" in *"verify and review passed"*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "PR body reports both gates when review.md exists"
rm -f "$IRUN/review.md"

# Idempotency: an already-open PR is reused, and create is never called again.
REC2="$FBIN/gh_dup.txt"
iout2="$(PATH="$FBIN:$PATH" GH_RECORD="$REC2" GH_EXISTING='[{"url":"https://github.com/x/y/pull/7","number":7}]' \
  FORGE_TARGET_REPO="$FINT" bash "$SCRIPTS_DIR/forge-integrate.sh" \
  --task-id fix-intg000001 --run-dir "$IRUN" --spec "$FINT/tasks/fix-intg000001.md" 2>/dev/null)"
assert_eq "ok" "$(printf '%s' "$iout2" | jq -r .status)" "existing PR -> status ok"
assert_eq "https://github.com/x/y/pull/7" "$(printf '%s' "$iout2" | jq -r .pr_url)" "reuses the existing PR url"
[ -f "$REC2" ] && got=yes || got=no
assert_eq "no" "$got" "does not call pr create when a PR already exists"

# A repo with no remote is a human's job (blocked), not a failure.
FNOR="$(mktemp -d)"
git -C "$FNOR" init -q -b develop
git -C "$FNOR" config user.email tester@forge.test
git -C "$FNOR" config user.name "forge tester"
mkdir -p "$FNOR/.forge" "$FNOR/tasks"
cp "$FINT/.forge/config.yaml" "$FNOR/.forge/config.yaml"
cp "$FINT/tasks/fix-intg000001.md" "$FNOR/tasks/"
printf 'seed\n' > "$FNOR/seed.txt"
git -C "$FNOR" add -A && git -C "$FNOR" commit -qm base
git -C "$FNOR" checkout -q -b forge/fix/nor && printf 'change\n' > "$FNOR/f.txt"
git -C "$FNOR" add -A && git -C "$FNOR" commit -qm change
nout="$(PATH="$FBIN:$PATH" FORGE_TARGET_REPO="$FNOR" bash "$SCRIPTS_DIR/forge-integrate.sh" \
  --task-id fix-intg000001 --run-dir "$FNOR/.forge/runs/fix-intg000001" --spec "$FNOR/tasks/fix-intg000001.md" 2>/dev/null)"
assert_eq "blocked" "$(printf '%s' "$nout" | jq -r .status)" "no remote -> status blocked"
case "$(printf '%s' "$nout" | jq -r .reason)" in *remote*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "blocked reason names the missing remote"
echo
echo "integration mode merges into the integration branch and keeps ONE PR out:"
# Same repo and shim, now with integration_branch configured.
cat > "$FINT/.forge/config.yaml" <<'YAML'
version: 1
base_branch: develop
protected_branches: [main]
integration_branch: forge/integration
vcs:
  host: github
  cli: gh
YAML
git -C "$FINT" checkout -q forge/fix/int
IREC="$FBIN/gh_integration.txt"
iout3="$(PATH="$FBIN:$PATH" GH_RECORD="$IREC" FORGE_TARGET_REPO="$FINT" bash "$SCRIPTS_DIR/forge-integrate.sh" \
  --task-id fix-intg000001 --run-dir "$IRUN" --spec "$FINT/tasks/fix-intg000001.md" 2>/dev/null)"
assert_eq "ok" "$(printf '%s' "$iout3" | jq -r .status)" "integration mode -> status ok"
assert_eq "forge/integration" "$(printf '%s' "$iout3" | jq -r .merged_into)" "reports the branch it merged into"
assert_eq "forge/integration" "$(jq -r .merged_into "$IRUN/pr.json")" "pr.json records the merge target"
got="$(git -C "$FINT" log --oneline "forge/integration" 2>/dev/null | grep -c "merge fix-intg000001")"
assert_eq "1" "$got" "the task branch is merged into the integration branch"
assert_eq "1" "$(git -C "$FINT" ls-remote origin forge/integration | wc -l | tr -d ' ')" \
  "the integration branch is pushed"
case "$(cat "$IREC")" in *"forge: integration -> develop"*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "the PR opened is the roll-up integration -> base"
# The integration merge happens in its own worktree, so the task tree is untouched.
assert_eq "forge/fix/int" "$(git -C "$FINT" rev-parse --abbrev-ref HEAD)" \
  "the merge runs in a separate worktree, not the task's checkout"

# A second task reuses the one open PR instead of opening another.
git -C "$FINT" checkout -q -b forge/fix/int2 develop
printf 'second\n' > "$FINT/g.txt"
git -C "$FINT" add -A && git -C "$FINT" commit -qm "second task"
IREC2="$FBIN/gh_integration2.txt"
IRUN2="$FINT/.forge/runs/fix-intg000002"
iout4="$(PATH="$FBIN:$PATH" GH_RECORD="$IREC2" \
  GH_EXISTING='[{"url":"https://github.com/x/y/pull/99","number":99}]' \
  FORGE_TARGET_REPO="$FINT" bash "$SCRIPTS_DIR/forge-integrate.sh" \
  --task-id fix-intg000002 --run-dir "$IRUN2" --branch forge/fix/int2 2>/dev/null)"
assert_eq "ok" "$(printf '%s' "$iout4" | jq -r .status)" "a second task also integrates ok"
assert_eq "https://github.com/x/y/pull/99" "$(printf '%s' "$iout4" | jq -r .pr_url)" \
  "the second task reuses the single integration PR"
assert_eq "no" "$([ -f "$IREC2" ] && echo yes || echo no)" "no second PR is created"
got="$(git -C "$FINT" log --oneline forge/integration | grep -c "forge: merge")"
assert_eq "2" "$got" "both tasks are stacked up on the integration branch"

# A conflicting merge blocks instead of guessing, and leaves nothing half-merged.
git -C "$FINT" checkout -q -b forge/fix/conflict develop
printf 'conflicting\n' > "$FINT/f.txt"
git -C "$FINT" add -A && git -C "$FINT" commit -qm "conflicting change"
IRUN3="$FINT/.forge/runs/fix-intg000003"
iout5="$(PATH="$FBIN:$PATH" FORGE_TARGET_REPO="$FINT" bash "$SCRIPTS_DIR/forge-integrate.sh" \
  --task-id fix-intg000003 --run-dir "$IRUN3" --branch forge/fix/conflict 2>/dev/null)"
assert_eq "blocked" "$(printf '%s' "$iout5" | jq -r .status)" "a conflicting merge is blocked, not guessed at"
case "$(printf '%s' "$iout5" | jq -r .reason)" in *f.txt*) got=yes ;; *) got=no ;; esac
assert_eq "yes" "$got" "the blocked reason names the conflicting file"
IWT="$FINT/.forge/worktrees/__integration"
assert_eq "" "$(git -C "$IWT" diff --name-only --diff-filter=U 2>/dev/null)" \
  "the aborted merge leaves no conflicted state behind"
assert_eq "1" "$(git -C "$FINT" ls-remote origin forge/fix/conflict | wc -l | tr -d ' ')" \
  "the conflicting task's own branch is still pushed and safe"
assert_eq "no" "$([ -d "$FINT/.forge/integration.lock" ] && echo yes || echo no)" \
  "the integration lock is released even on a blocked merge"

rm -rf "$FINT" "$FBARE" "$FBIN" "$FNOR"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
