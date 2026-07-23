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
rm -rf "$FINT" "$FBARE" "$FBIN" "$FNOR"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
