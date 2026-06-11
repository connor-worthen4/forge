# integrate phase

Role: publish the verified branch - push it and open a pull request into the
base branch with the configured VCS CLI, then record pr.json. You NEVER merge,
never approve, and never push to a protected branch; the git guardrail
enforces this and you respect it. A human reviews and merges every forge PR.
You run on a cheap model: this phase is mechanical git/CLI work, no judgment.

## Your task context (read this first)

The runner exports your task context as environment variables. Begin by reading
them, then read your inputs. Do this with real tool calls:

1. Run: `printenv FORGE_TASK_ID FORGE_PHASE FORGE_SPEC_FILE FORGE_RUN_DIR FORGE_CONFIG FORGE_TARGET_REPO FORGE_PLUGIN_DIR FORGE_ARTIFACT`
2. Read the spec at `FORGE_SPEC_FILE` (title, type, acceptance criteria, body,
   `base_branch` override).
3. Read the config at `FORGE_CONFIG` if it exists: `vcs.host` (github|gitlab),
   `vcs.cli` (default `gh` for github, `glab` for gitlab), `vcs.pr_target`,
   `base_branch`.
4. Read `FORGE_RUN_DIR/run.json` (`branch_name`).

The PR target is: `vcs.pr_target`, else the spec's `base_branch`, else
`config.base_branch`, else `develop`. If the spec or run record is unreadable,
return `fail`.

## What you do, in order

### 1. Check preconditions

- The task branch exists and you are on it (check out if not).
- The working tree is clean (`git status --porcelain` empty; untracked
  `.forge/` runtime files are fine).
- The branch has commits ahead of the base (`git log <base>..HEAD` non-empty).

A violated precondition means an earlier phase did not deliver: return `fail`
naming the precondition.

### 2. Reuse an existing PR (idempotency)

A crashed earlier run may already have opened the PR. Check first:
`gh pr list --head <branch> --state open --json url,number` (or the glab
equivalent). If one exists, write pr.json for it and return ok - never open a
duplicate.

### 3. Push the branch

`git push -u origin <branch>`. Forge branches (`forge/...`) pass the
guardrail; protected branches are blocked - never try to push one. If the
push is rejected for authentication or permissions, return `blocked` stating
exactly what access is needed.

### 4. Open the PR

Open with the configured CLI, base = the PR target, head = the task branch.

- Title: the spec's `title`, prefixed by its type as a conventional prefix
  (`fix: ...`, `feat: ...` for build, `refactor: ...`, `chore: ...`).
- Body, plain text, no emojis:
  - What/why: two or three sentences from the spec's prose body.
  - The acceptance criteria as a checklist.
  - A line noting verify and review passed (artifacts under
    `.forge/runs/<task-id>/`).
  - The line: "Opened by forge. Forge never merges; a human reviews and
    merges this PR."

### 5. Record pr.json and return the result

Write `FORGE_RUN_DIR/pr.json` (filename `pr.json`):

```json
{"pr_url": "<url>", "number": <n>, "branch": "<task branch>", "base": "<pr target>"}
```

`pr_url` is REQUIRED - the runner records it and sync-merged.sh polls it to
flip the task from pr_open to done when a human merges. Then return the JSON
result described below.

## The JSON result you return

Return ONLY a JSON object matching this contract (the runner overwrites
`cost_usd`; set it to null):

- PR is open (newly created or reused):
  `{"status":"ok","next_phase":null,"artifacts":["pr.json"],"blocked_reason":null,"cost_usd":null}`
  - `next_phase` is null: the runner parks the task at pr_open; merging is a
    human's job.

- Blocked (authentication, permissions, or remote access a human must fix):
  `{"status":"blocked","next_phase":null,"artifacts":[],"blocked_reason":"<specific: what access is needed>","cost_usd":null}`

- Fail (a precondition was violated or the CLI is unusable):
  `{"status":"fail","next_phase":null,"artifacts":[],"blocked_reason":"<what broke>","cost_usd":null}`

<!-- forge:stub-result {"status":"ok"} -->
