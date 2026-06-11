#!/usr/bin/env bash
#
# Unit tests for block-git-writes.sh. Pipes crafted PreToolUse JSON payloads
# through the hook and asserts the deny/allow verdict. Exits non-zero if any
# case fails.
#
# A verdict is DENY when the hook prints permissionDecision "deny" (exit 0) or
# hard-blocks (exit 2); otherwise it is ALLOW.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(cd "$HERE/.." && pwd)/block-git-writes.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to run these tests" >&2
  exit 1
fi
if [ ! -f "$HOOK" ]; then
  echo "hook not found: $HOOK" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a throwaway git repo whose HEAD is on $2.
mkrepo() {
  local dir="$1" branch="$2"
  git init -q "$dir"
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name "forge test"
  : > "$dir/seed"
  git -C "$dir" add seed
  git -C "$dir" commit -q -m "seed"
  git -C "$dir" branch -M main
  if [ "$branch" != "main" ]; then
    git -C "$dir" checkout -q -b "$branch"
  fi
}

REPO_FEAT="$TMP/feat"; mkrepo "$REPO_FEAT" "feature/work"
REPO_MAIN="$TMP/main"; mkrepo "$REPO_MAIN" "main"

PASS=0
FAIL=0

# run <DENY|ALLOW> <cwd> <command>
run() {
  local expect="$1" cwd="$2" cmd="$3"
  local json out rc verdict
  json="$(jq -n --arg c "$cmd" --arg d "$cwd" \
    '{tool_name:"Bash", hook_event_name:"PreToolUse", cwd:$d, tool_input:{command:$c}}')"
  out="$(printf '%s' "$json" | bash "$HOOK" 2>/dev/null)"
  rc=$?
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
    verdict="DENY"
  elif [ "$rc" -eq 2 ]; then
    verdict="DENY"
  else
    verdict="ALLOW"
  fi
  if [ "$verdict" = "$expect" ]; then
    printf '  PASS  %-5s  %s\n' "$expect" "$cmd"
    PASS=$((PASS+1))
  else
    printf '  FAIL  exp=%-5s got=%-5s  %s\n' "$expect" "$verdict" "$cmd"
    FAIL=$((FAIL+1))
  fi
}

echo "forge git-safety hook tests"
echo "hook: $HOOK"
echo
echo "Expected DENY:"
run DENY  "$REPO_FEAT" 'git merge feature'
run DENY  "$REPO_FEAT" 'git push origin main'
run DENY  "$REPO_FEAT" 'git push -f origin dev'
run DENY  "$REPO_FEAT" 'git push --force-with-lease'
run DENY  "$REPO_FEAT" 'gh pr merge 12'
run DENY  "$REPO_FEAT" 'gh pr create --base main'
run DENY  "$REPO_FEAT" 'git add . && git push origin main'
run DENY  "$REPO_MAIN" 'git commit -m "x"'
# Additional coverage beyond the required minimum.
run DENY  "$REPO_FEAT" 'git push origin :develop'
run DENY  "$REPO_FEAT" 'git push --delete origin master'
run DENY  "$REPO_FEAT" 'git push origin HEAD:main'
run DENY  "$REPO_FEAT" 'git branch -D main'
run DENY  "$REPO_MAIN" 'git reset --hard HEAD~1'
run DENY  "$REPO_FEAT" 'gh api -X PUT repos/o/r/pulls/1/merge'
run DENY  "$REPO_FEAT" 'echo hi ; git merge develop'

echo
echo "Expected ALLOW:"
run ALLOW "$REPO_FEAT" 'git status'
run ALLOW "$REPO_FEAT" 'git add .'
run ALLOW "$REPO_FEAT" 'git commit -m "x"'
run ALLOW "$REPO_FEAT" 'git push origin feature/x'
run ALLOW "$REPO_FEAT" 'git checkout -b feature/y'
run ALLOW "$REPO_FEAT" 'gh pr create --base develop'
# Additional coverage beyond the required minimum.
run ALLOW "$REPO_FEAT" 'git fetch origin'
run ALLOW "$REPO_FEAT" 'git log --oneline'
run ALLOW "$REPO_FEAT" 'git diff HEAD~1'
run ALLOW "$REPO_FEAT" 'git rebase develop'
run ALLOW "$REPO_FEAT" 'ls -la && git add -A'
run ALLOW "$REPO_FEAT" 'npm test'

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
