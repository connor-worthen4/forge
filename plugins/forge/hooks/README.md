# forge hooks: git-safety guardrail

`block-git-writes.sh` is a `PreToolUse` hook that deterministically blocks
git/gh operations which could merge code or mutate a protected branch. It
enforces forge's contract mechanically: agents work on a feature branch and open
a pull request into `develop`; they never merge, never push to a protected
branch, never force-push, and never rewrite shared history.

## What it does

- Inspects only `Bash` tool calls (`tool_input.command`); everything else passes.
- Splits chained commands (`&&`, `||`, `;`, `|`, `&`, newlines) and
  subshell/command-substitution groupings (`(...)`, `$(...)`) so a blocked op
  cannot hide inside a chain, background job, or grouping; strips leading
  env assignments and wrappers (`sudo`, `env`, `nice`, `xargs`, `bash -c`,
  `sh -c`, ...); and understands `git -C <path>` and arbitrary remote names.
- On a blocked op it returns a structured deny:
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}`
  and exits 0, so the decision is honored in every permission mode, including
  `--dangerously-skip-permissions`.
- Fails closed: a clear git/gh write whose safety cannot be determined (e.g. the
  current branch is unknowable, or jq cannot parse the payload) is denied, not
  allowed. Non-git commands always pass.

### Configuration

The protected-branch list resolves in priority order (highest first); an empty
or absent source falls through to the next, so the default always protects:

| Source                                       | Default                | Purpose                                            |
| -------------------------------------------- | ---------------------- | -------------------------------------------------- |
| `protected_branches` in `.forge/config.yaml` | -                      | The single source of truth, read relative to the hook cwd (same field `validate-config.sh` checks). |
| `FORGE_PROTECTED_BRANCHES` env var           | -                      | Comma-separated fallback when no config file is present. |
| Hardcoded default                            | `main,master,develop`  | Fail-safe floor.                                   |

`FORGE_INTEGRATION_BRANCH` (default `develop`) names the only protected branch
a PR may target.

### Blocked vs allowed (summary)

Blocked: `git merge`; push to a protected branch (any remote/refspec, incl.
`HEAD:main` and `:branch` deletes); `git push --force/-f/--force-with-lease`
and `+refspec` force pushes (`git push origin +branch`);
`git push --all/--mirror`; `git branch -d/-D <protected>`; `git reset --hard` and
`git rebase` on or targeting a protected branch; `git commit`/`git push` while on
a protected branch; `gh pr merge`; `gh pr create --base main|master`;
`gh api .../merge[s]`.

Allowed: `add`, `status`, `diff`, `log`, `fetch`, `checkout`/`switch`, branch
creation, `pull`, `rebase <upstream>` from a feature branch, commit/push on a
feature branch, and `gh pr create --base develop`.

## Testing

Unit tests pipe crafted JSON through the hook and assert the verdict:

```
bash plugins/forge/hooks/test/run-tests.sh
```

It prints a pass/fail table and exits non-zero if any case fails.

## Two known gaps (read before relying on this)

### Gap 1 - the allow-list can override the deny

A `PreToolUse` deny can be **ignored** if a matching `permissions.allow` rule
already approves the tool call. If a project (or user/global) settings file
contains a blanket `"Bash"` allow (or a broad `"Bash(git *)"` allow), Claude Code
may short-circuit to that allow and never honor this hook's deny.

What forge users must do:

- **Do not blanket-allow `Bash`.** Never add `"Bash"` or `"Bash(git *)"` /
  `"Bash(gh *)"` to `permissions.allow` in any settings scope (project
  `.claude/settings.json`, user, or managed). Allow narrower, non-git commands
  instead (for example `"Bash(npm test)"`, `"Bash(ls *)"`).
- **Verify the hook actually fires inside Claude Code** (the unit test only
  exercises the script in isolation, not the permission pipeline):
  1. Install/enable forge, then run `/hooks` and confirm `block-git-writes.sh`
     is listed under `PreToolUse` with matcher `Bash`.
  2. In a feature-branch worktree, ask Claude to run `git push origin main`.
     It must be blocked with the forge reason, not executed.
  3. Repeat with `claude --dangerously-skip-permissions` to confirm the block
     still fires in bypass mode.
  4. Run `claude --debug` and watch for the hook invocation in the debug log if
     a block does not appear.

### Gap 2 - this is a guardrail, not a security boundary

This hook is a fast, local, best-effort guardrail. It runs only inside Claude
Code, only for the `Bash` tool, and only against command strings it can parse. A
process outside Claude Code, a different tool, or a sufficiently obfuscated
command is out of its reach. Parsing is lexical and pre-execution: checks that
depend on repository state (the current branch for `git commit` or
`git reset --hard`) are evaluated against the state *before* the command runs,
so a chain like `git checkout main && git commit -m x` is judged while HEAD is
still the feature branch. **The authoritative enforcement of "nothing merges
without review" is GitHub branch protection on the remote**, which the hook
cannot bypass.

Enable these branch-protection (or repository ruleset) settings on **`main` and
`develop`**:

- **Require a pull request before merging** (no direct pushes to the branch).
  - Require at least **1 approving review**.
  - **Dismiss stale approvals** when new commits are pushed.
  - Require **review from Code Owners** (if a `CODEOWNERS` file is used).
- **Require status checks to pass before merging**, and **require branches to be
  up to date** before merging.
- **Require conversation resolution before merging.**
- **Block force pushes** to the branch.
- **Restrict deletions** of the branch.
- **Require linear history** (optional; blocks merge commits if you want
  squash/rebase only).
- **Do not allow bypassing the above** - leave "allow specified actors to bypass
  required pull requests" unchecked, and apply the rules to administrators
  (GitHub: "Include administrators" / in rulesets, no bypass actors).
- Restrict who can push to these branches to the smallest possible set (ideally
  only the merge automation, never the forge agent identity).

With branch protection in place, even a missed case in this hook cannot result in
an unreviewed merge: the remote rejects it.
