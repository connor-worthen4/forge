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

# Repo with a .forge/config.yaml (block-list form) overriding the protected list
# to [release, main] -- note: develop is intentionally NOT in this list.
REPO_CFG="$TMP/cfg"; mkrepo "$REPO_CFG" "feature/work"
mkdir -p "$REPO_CFG/.forge"
cat > "$REPO_CFG/.forge/config.yaml" <<'YAML'
version: 1
base_branch: develop
protected_branches:
  - release
  - main
vcs:
  host: github
commands:
  test: "true"
YAML

# Repo with a .forge/config.yaml (inline flow form) protecting [staging].
REPO_CFG2="$TMP/cfg2"; mkrepo "$REPO_CFG2" "feature/work"
mkdir -p "$REPO_CFG2/.forge"
cat > "$REPO_CFG2/.forge/config.yaml" <<'YAML'
version: 1
base_branch: develop
protected_branches: [staging]
vcs:
  host: github
commands:
  test: "true"
YAML

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

# run_env <ENV_KV> <DENY|ALLOW> <cwd> <command>  (ENV_KV like "NAME=value")
run_env() {
  local env_kv="$1" expect="$2" cwd="$3" cmd="$4"
  local json out rc verdict
  json="$(jq -n --arg c "$cmd" --arg d "$cwd" \
    '{tool_name:"Bash", hook_event_name:"PreToolUse", cwd:$d, tool_input:{command:$c}}')"
  out="$(printf '%s' "$json" | env "$env_kv" bash "$HOOK" 2>/dev/null)"
  rc=$?
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
    verdict="DENY"
  elif [ "$rc" -eq 2 ]; then
    verdict="DENY"
  else
    verdict="ALLOW"
  fi
  if [ "$verdict" = "$expect" ]; then
    printf '  PASS  %-5s  [%s]  %s\n' "$expect" "$env_kv" "$cmd"
    PASS=$((PASS+1))
  else
    printf '  FAIL  exp=%-5s got=%-5s  [%s]  %s\n' "$expect" "$verdict" "$env_kv" "$cmd"
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
# Splitter and wrapper bypasses: background jobs, subshells, command
# substitution, shell re-invocation, env flags, and force refspecs.
run DENY  "$REPO_FEAT" 'true & git push origin main'
run DENY  "$REPO_FEAT" '(git merge feature)'
run DENY  "$REPO_FEAT" 'echo "$(git merge feature)"'
run DENY  "$REPO_FEAT" 'bash -c "git merge feature"'
run DENY  "$REPO_FEAT" 'sh -c "git push origin main"'
run DENY  "$REPO_FEAT" 'env -i git merge feature'
run DENY  "$REPO_FEAT" 'git push origin +main'
run DENY  "$REPO_FEAT" 'git push origin +feature/x'   # any +refspec is a force push

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
# The aggressive splitter must not over-block ordinary commands.
run ALLOW "$REPO_FEAT" 'git push origin feature/x 2>&1'
run ALLOW "$REPO_FEAT" 'git commit -m "feat(scope): x"'
run ALLOW "$REPO_FEAT" 'python3 -c "print(1)"'
run ALLOW "$REPO_FEAT" 'echo "a & b"'

echo
echo "Config sourcing (.forge/config.yaml protected_branches):"
# REPO_CFG protects [release, main] via a block list.
run DENY  "$REPO_CFG"  'git push origin release'   # in config list
run DENY  "$REPO_CFG"  'git push origin main'      # in config list
run ALLOW "$REPO_CFG"  'git push origin develop'   # NOT in config list -> allowed
# REPO_CFG2 protects [staging] via an inline flow list.
run DENY  "$REPO_CFG2" 'git push origin staging'   # in config list
run ALLOW "$REPO_CFG2" 'git push origin main'      # NOT in config list -> allowed

echo
echo "Source precedence (config > env > default):"
# No config in REPO_FEAT: the env var is honored over the default.
run_env "FORGE_PROTECTED_BRANCHES=staging" DENY  "$REPO_FEAT" 'git push origin staging'
run_env "FORGE_PROTECTED_BRANCHES=staging" ALLOW "$REPO_FEAT" 'git push origin develop'
# Config present in REPO_CFG: config wins over the env var.
run_env "FORGE_PROTECTED_BRANCHES=staging" DENY  "$REPO_CFG"  'git push origin release'
run_env "FORGE_PROTECTED_BRANCHES=staging" ALLOW "$REPO_CFG"  'git push origin staging'

echo
echo "Integration branch: the one merge exception, and only where it applies:"
# A repo configured with integration_branch, sitting ON that branch.
REPO_INT="$TMP/int"; mkrepo "$REPO_INT" "forge/integration"
mkdir -p "$REPO_INT/.forge"
cat > "$REPO_INT/.forge/config.yaml" <<'YAML'
version: 1
base_branch: develop
protected_branches: [main]
integration_branch: forge/integration
vcs:
  host: github
commands:
  test: "true"
YAML
# The same config, but checked out on a task branch instead.
REPO_INT_FEAT="$TMP/intfeat"; mkrepo "$REPO_INT_FEAT" "forge/fix/thing"
mkdir -p "$REPO_INT_FEAT/.forge"
cp "$REPO_INT/.forge/config.yaml" "$REPO_INT_FEAT/.forge/config.yaml"
# A misconfiguration: the integration branch is also in protected_branches.
REPO_INT_PROT="$TMP/intprot"; mkrepo "$REPO_INT_PROT" "forge/integration"
mkdir -p "$REPO_INT_PROT/.forge"
cat > "$REPO_INT_PROT/.forge/config.yaml" <<'YAML'
version: 1
base_branch: develop
protected_branches: [main, forge/integration]
integration_branch: forge/integration
vcs:
  host: github
commands:
  test: "true"
YAML

run ALLOW "$REPO_INT"      'git merge forge/fix/thing'         # on the integration branch
run ALLOW "$REPO_INT"      'git merge --no-ff forge/fix/thing' # same, explicit merge commit
run ALLOW "$REPO_INT"      'git push origin forge/integration' # not protected -> pushable
run DENY  "$REPO_INT"      'git push origin main'              # still protected
run DENY  "$REPO_INT"      'git push -f origin forge/integration'  # force is never allowed
run DENY  "$REPO_INT_FEAT" 'git merge forge/fix/other'         # not ON the integration branch
run DENY  "$REPO_INT_PROT" 'git merge forge/fix/thing'         # protected wins over the exception
run DENY  "$REPO_CFG"      'git merge feature'                 # no integration_branch configured
run DENY  "$REPO_INT"      'gh pr merge 12'                    # the exception is git merge only
run DENY  "$REPO_INT"      'git merge forge/fix/thing && git push origin main'  # chained push still blocks
# Scoping protected_branches is a real loosening, so pin the consequence: a base
# branch left OUT of the list is pushable. Narrow the list deliberately, not by
# accident - GitHub branch protection remains the backstop either way.
run ALLOW "$REPO_INT"      'git push origin develop'           # develop not in [main] -> allowed

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
