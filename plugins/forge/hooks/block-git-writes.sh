#!/usr/bin/env bash
#
# forge git-safety guardrail (PreToolUse hook)
#
# Deterministically blocks git/gh operations that could merge code or mutate a
# protected branch. forge's contract: agents work on a feature branch and open a
# pull request into the integration branch (develop). They never merge, never
# push to a protected branch, never force-push, and never rewrite shared history.
#
# Mechanism: on a blocked operation the script prints a structured PreToolUse
# `permissionDecision: "deny"` to stdout and exits 0, so the decision is honored
# in every permission mode, including --dangerously-skip-permissions. The one
# known leak (a matching permissions.allow rule taking precedence) and the
# authoritative control (GitHub branch protection) are documented in README.md.
#
# Input:  PreToolUse JSON on stdin (tool_name, tool_input.command, cwd).
# Deps:   jq, grep, awk, git (POSIX bash; written to run under bash 3.2+).
# Speed:  no network; a single `git rev-parse` only when a decision needs the
#         current branch.

set -u

INTEGRATION_BRANCH="${FORGE_INTEGRATION_BRANCH:-develop}"
PROTECTED_CSV="${FORGE_PROTECTED_BRANCHES:-main,master,develop}"
PR_HINT="forge agents must open a PR into ${INTEGRATION_BRANCH} and let a human review and merge."

# --- jq guard ---------------------------------------------------------------
# Without jq the structured input cannot be parsed. Fail closed: scan the raw
# payload and hard-block (exit 2) anything that looks like a git/gh command.
if ! command -v jq >/dev/null 2>&1; then
  RAW="$(cat)"
  if printf '%s' "$RAW" | grep -Eq '(^|[^A-Za-z])(git|gh)([^A-Za-z]|$)'; then
    echo "forge git-safety: jq unavailable to parse hook input; blocking git/gh command as a precaution." >&2
    exit 2
  fi
  exit 0
fi

# --- helpers ----------------------------------------------------------------

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

unquote() {
  local s="$1"
  s="${s#[\"\']}"
  s="${s%[\"\']}"
  printf '%s' "$s"
}

is_protected() {
  local b
  b="$(unquote "$1")"
  b="${b#+}"             # drop a force-refspec marker
  b="${b#refs/heads/}"   # normalize a fully qualified ref
  local IFS=','
  local p
  for p in $PROTECTED_CSV; do
    p="$(trim "$p")"
    [ -n "$p" ] && [ "$b" = "$p" ] && return 0
  done
  return 1
}

# Emit a structured PreToolUse deny and exit. Exit 0 so the JSON decision on
# stdout is honored; the reason is also written to stderr for logs.
deny() {
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  printf 'forge git-safety: %s\n' "$reason" >&2
  exit 0
}

# Current branch for the command's -C path (else the hook cwd). Empty output
# means the branch could not be determined.
current_branch() {
  local dir="$1"
  [ -z "$dir" ] && dir="$CWD"
  git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null
}

# --- git push -------------------------------------------------------------
check_push() {
  local cdir="$1"; shift
  local -a t=("$@")
  local n=${#t[@]}
  local i=0
  local force=0 delete=0 allmir=0
  local -a pos=()

  while [ $i -lt $n ]; do
    local a="${t[$i]}"
    case "$a" in
      -f|--force) force=1 ;;
      --force-with-lease|--force-with-lease=*|--force-if-includes|--force-if-includes=*) force=1 ;;
      --delete) delete=1 ;;
      --all|--mirror) allmir=1 ;;
      --repo|-o|--push-option) i=$((i+1)) ;;   # consume the option value
      --*) : ;;
      -*)
        case "$a" in *f*) force=1 ;; esac
        case "$a" in *d*) delete=1 ;; esac
        ;;
      *) pos+=("$a") ;;
    esac
    i=$((i+1))
  done

  if [ $force -eq 1 ]; then
    deny "Blocked: force-push is never allowed (it rewrites shared history). ${PR_HINT}"
  fi
  if [ $allmir -eq 1 ]; then
    deny "Blocked: 'git push --all/--mirror' would push protected branches. ${PR_HINT}"
  fi

  # The first positional is the remote; the rest are refspecs.
  local -a refspecs=()
  if [ ${#pos[@]} -ge 2 ]; then
    refspecs=("${pos[@]:1}")
  fi

  if [ ${#refspecs[@]} -eq 0 ]; then
    # No explicit refspec: pushes the current branch.
    local cb; cb="$(current_branch "$cdir")"
    if [ -z "$cb" ]; then
      deny "Blocked: 'git push' with no explicit branch and the current branch could not be determined; failing closed. ${PR_HINT}"
    fi
    if is_protected "$cb"; then
      deny "Blocked: 'git push' would push the current protected branch '${cb}'. ${PR_HINT}"
    fi
    return 0
  fi

  local r src dst
  for r in "${refspecs[@]+"${refspecs[@]}"}"; do
    r="$(unquote "$r")"
    if [ "${r#*:}" != "$r" ]; then
      src="${r%%:*}"
      dst="${r#*:}"
    else
      src="$r"; dst="$r"
    fi
    [ -n "$dst" ] || continue
    if is_protected "$dst"; then
      if [ -z "$src" ] || [ $delete -eq 1 ]; then
        deny "Blocked: deleting protected branch '${dst}'. ${PR_HINT}"
      fi
      deny "Blocked: pushing to protected branch '${dst}'. ${PR_HINT}"
    fi
  done
  return 0
}

# --- git rebase -----------------------------------------------------------
check_rebase() {
  local cdir="$1"; shift
  local -a t=("$@")
  local n=${#t[@]}
  local a i=0
  local -a pos=()

  # In-progress rebase control is not a new history rewrite; allow it.
  for a in "${t[@]+"${t[@]}"}"; do
    case "$a" in
      --abort|--continue|--skip|--quit|--edit-todo|--show-current-patch) return 0 ;;
    esac
  done

  while [ $i -lt $n ]; do
    a="${t[$i]}"
    case "$a" in
      --onto|-s|--strategy|-x|--exec|-X|--strategy-option) i=$((i+1)) ;;  # consume value
      -*) : ;;
      *) pos+=("$a") ;;
    esac
    i=$((i+1))
  done

  local cb; cb="$(current_branch "$cdir")"
  if [ -z "$cb" ]; then
    deny "Blocked: 'git rebase' but the current branch could not be determined; failing closed (rebase rewrites history). ${PR_HINT}"
  fi
  if is_protected "$cb"; then
    deny "Blocked: 'git rebase' on protected branch '${cb}' (rewrites shared history). ${PR_HINT}"
  fi
  # `git rebase <upstream> <branch>`: a second positional is checked out and
  # rewritten. A single positional is only an upstream and is safe to rebase ONTO.
  if [ ${#pos[@]} -ge 2 ]; then
    local target="${pos[$((${#pos[@]}-1))]}"
    if is_protected "$target"; then
      deny "Blocked: 'git rebase' targeting protected branch '${target}' (rewrites it). ${PR_HINT}"
    fi
  fi
  return 0
}

# --- git --------------------------------------------------------------------
check_git() {
  local -a t=("$@")
  local n=${#t[@]}
  local i=1 cdir=""

  # Skip git global options to reach the subcommand; capture -C <path>.
  while [ $i -lt $n ]; do
    case "${t[$i]}" in
      -C) cdir="$(unquote "${t[$((i+1))]:-}")"; i=$((i+2)) ;;
      -c|--git-dir|--work-tree|--namespace) i=$((i+2)) ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--exec-path) i=$((i+1)) ;;
      -*) i=$((i+1)) ;;
      *) break ;;
    esac
  done

  [ $i -lt $n ] || return 0   # bare "git" with no subcommand
  local sub="${t[$i]}"
  local -a args=("${t[@]:$((i+1))}")

  case "$sub" in
    merge)
      deny "Blocked: 'git merge' is not allowed. ${PR_HINT}"
      ;;
    push)
      check_push "$cdir" "${args[@]+"${args[@]}"}"
      ;;
    reset)
      local a hard=0 prot_target=0
      for a in "${args[@]+"${args[@]}"}"; do
        case "$a" in
          --hard) hard=1 ;;
          -*) : ;;
          *) is_protected "$a" && prot_target=1 ;;
        esac
      done
      if [ $hard -eq 1 ]; then
        local cb; cb="$(current_branch "$cdir")"
        if [ -z "$cb" ]; then
          deny "Blocked: 'git reset --hard' but the current branch could not be determined; failing closed. ${PR_HINT}"
        fi
        if is_protected "$cb" || [ $prot_target -eq 1 ]; then
          deny "Blocked: 'git reset --hard' on or targeting a protected branch (current '${cb}'). ${PR_HINT}"
        fi
      fi
      ;;
    rebase)
      check_rebase "$cdir" "${args[@]+"${args[@]}"}"
      ;;
    branch)
      local a del=0
      local -a bpos=()
      for a in "${args[@]+"${args[@]}"}"; do
        case "$a" in
          --delete) del=1 ;;
          --*) : ;;
          -*) case "$a" in *[dD]*) del=1 ;; esac ;;   # short cluster containing d/D
          *) bpos+=("$a") ;;
        esac
      done
      if [ $del -eq 1 ]; then
        for a in "${bpos[@]+"${bpos[@]}"}"; do
          if is_protected "$a"; then
            deny "Blocked: deleting protected branch '${a}' with 'git branch'. ${PR_HINT}"
          fi
        done
      fi
      ;;
    commit)
      local cb; cb="$(current_branch "$cdir")"
      if [ -z "$cb" ]; then
        deny "Blocked: 'git commit' but the current branch could not be determined; failing closed. ${PR_HINT}"
      fi
      if is_protected "$cb"; then
        deny "Blocked: 'git commit' on protected branch '${cb}'. Switch to a feature branch first. ${PR_HINT}"
      fi
      ;;
    *)
      : ;;  # add, status, diff, log, fetch, checkout, switch, pull, stash, ... allowed
  esac
  return 0
}

# --- gh ---------------------------------------------------------------------
check_gh() {
  local -a t=("$@")
  local n=${#t[@]}
  [ $n -ge 2 ] || return 0
  local sub="${t[1]}"

  case "$sub" in
    pr)
      local action="${t[2]:-}"
      case "$action" in
        merge)
          deny "Blocked: 'gh pr merge' merges the PR and bypasses git-level checks. ${PR_HINT}"
          ;;
        create)
          local -a a=("${t[@]:3}")
          local m=${#a[@]} j=0 base=""
          while [ $j -lt $m ]; do
            case "${a[$j]}" in
              --base|-B) base="$(unquote "${a[$((j+1))]:-}")"; j=$((j+2)); continue ;;
              --base=*)  base="$(unquote "${a[$j]#--base=}")" ;;
              -B*)       base="$(unquote "${a[$j]#-B}")" ;;
            esac
            j=$((j+1))
          done
          if [ -n "$base" ] && is_protected "$base" && [ "$base" != "$INTEGRATION_BRANCH" ]; then
            deny "Blocked: 'gh pr create --base ${base}' targets a protected branch. PRs must target ${INTEGRATION_BRANCH}. ${PR_HINT}"
          fi
          ;;
      esac
      ;;
    api)
      local a
      for a in "${t[@]:2}"; do
        a="$(unquote "$a")"
        if printf '%s' "$a" | grep -Eq '/merges?($|[/?])'; then
          deny "Blocked: 'gh api' call to a merge endpoint ('${a}'). ${PR_HINT}"
        fi
      done
      ;;
  esac
  return 0
}

# --- one segment ------------------------------------------------------------
classify_segment() {
  local seg="$1"
  local -a W
  read -r -a W <<< "$seg"
  [ ${#W[@]} -ge 1 ] || return 0

  # Strip leading env-var assignments and common command wrappers.
  local k=0
  while [ $k -lt ${#W[@]} ]; do
    case "${W[$k]}" in
      sudo|command|nice|nohup|time|env) k=$((k+1)) ;;
      *=*) if [[ "${W[$k]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then k=$((k+1)); else break; fi ;;
      *) break ;;
    esac
  done
  W=("${W[@]:$k}")
  [ ${#W[@]} -ge 1 ] || return 0

  local p0 prog
  p0="$(unquote "${W[0]}")"
  prog="${p0##*/}"
  case "$prog" in
    git) check_git "${W[@]}" ;;
    gh)  check_gh "${W[@]}" ;;
    *) : ;;
  esac
  return 0
}

# --- main -------------------------------------------------------------------
INPUT="$(cat)"

# If the payload is not valid JSON, fail closed only when it clearly references
# a git/gh command; otherwise defer to normal flow.
if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  if printf '%s' "$INPUT" | grep -Eq '(^|[^A-Za-z])(git|gh)([^A-Za-z]|$)'; then
    deny "Unparseable hook payload that references git/gh; failing closed. ${PR_HINT}"
  fi
  exit 0
fi

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
[ "$TOOL_NAME" = "Bash" ] || exit 0   # only shell commands are inspected

COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
[ -n "$COMMAND" ] || exit 0

# Split chained commands on && || ; | and newlines so a blocked op cannot hide
# inside a chain. awk is used because BSD sed does not expand \n in replacements.
SEGMENTS="$(printf '%s' "$COMMAND" | awk '{
  gsub(/\|\|/, "\n"); gsub(/&&/, "\n"); gsub(/;/, "\n"); gsub(/\|/, "\n"); print
}')"

while IFS= read -r seg; do
  seg="$(trim "$seg")"
  [ -n "$seg" ] || continue
  classify_segment "$seg"
done <<< "$SEGMENTS"

exit 0
