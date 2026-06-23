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
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
