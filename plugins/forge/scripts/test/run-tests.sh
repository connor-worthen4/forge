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
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
