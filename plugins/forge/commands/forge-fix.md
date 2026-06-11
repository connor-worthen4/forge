---
description: "Drive ONE task through the forge pipeline in your live session (subscription), then stop and wait. Usage: /forge-fix next | /forge-fix <task-id>"
argument-hint: "next | <task-id>"
allowed-tools: Bash, Read, Edit, Write, Task
---

You are the interactive driver for the forge pipeline. You run in the user's live
session (drawing their subscription), so you execute the pipeline IN-SESSION using
subagents for phase isolation. Do NOT launch headless `claude -p` sessions and do
NOT pass `--dangerously-skip-permissions`. You and the unattended runner
(`scripts/forge-run.sh --all`) share the same `select-next`, the same `.forge/queue.json`, and
the same `.forge/runs/<task_id>/` records, so you never redo each other's work.

The forge scripts live at `${CLAUDE_PLUGIN_ROOT}/scripts`. The target repo is the
current working directory (or `$FORGE_TARGET_REPO`). Argument: `$ARGUMENTS`.

Do exactly the following, then STOP and wait for the user:

1. **Reconcile merged PRs first.** Run `"${CLAUDE_PLUGIN_ROOT}/scripts/sync-merged.sh"`
   so anything merged overnight is flipped pr_open -> done and `next` skips it.

2. **Choose the task.**
   - If `$ARGUMENTS` is `next` or empty: run
     `"${CLAUDE_PLUGIN_ROOT}/scripts/select-next.sh"` and use the printed task_id.
     If it prints `none`, report that the queue has no selectable pending task
     (note any blocked/plan_gate items) and STOP.
   - Otherwise treat `$ARGUMENTS` as a task_id.

3. **Load the spec.** Read the task file (`.forge/queue.json` entry `file`, else
   `tasks/<task-id>.md`). Note its `type`, effective `autonomy_tier`, and
   `acceptance_criteria`. Derive the pipeline shape exactly as `run-task.sh` does:
   - `audit`/`investigate` -> tier 0: intake -> plan -> report.md -> done (read-only; no branch/PR).
   - `build` or any type in `autonomy.require_gate` -> tier 2: intake -> plan -> plan_gate (stop for the user's approval via /forge-approve). If the run record already shows the gate was passed (status `building` or later), continue the tier-1 path from that phase instead of re-planning.
   - otherwise -> tier 1: intake -> plan -> build -> verify -> review -> integrate -> pr_open.

4. **Execute the pipeline in-session, one phase at a time.** For each phase, read
   its role from `${CLAUDE_PLUGIN_ROOT}/phases/<phase>.md` and dispatch a subagent
   (Task tool) to do that phase's work in an isolated context. The **review** phase
   MUST run as a separate, isolated reviewer subagent (it must not see the builder's
   rationalizations). Honor the loops: if verify or review fails, loop back to build,
   capped at `budget.max_attempts` from `.forge/config.yaml`; when exhausted, mark
   the task `blocked` and stop. Work happens on the branch `forge/<type>/<id>-<slug>`.
   After each phase, update `.forge/runs/<task-id>/run.json` (status, current_phase,
   artifacts) and the task's status in `.forge/queue.json` so state stays consistent
   with the unattended runner. The git guardrail hook is active in this session and
   will block any merge or protected-branch push; respect it (open a PR into the base
   branch; never merge).

5. **Stop at the terminal state.** tier 1 ends at `pr_open` (PR opened into the base
   branch via `gh`, never merged). tier 0 ends at `done` with `report.md`. tier 2
   stops at `plan_gate` awaiting the user's approval.

6. **Report concisely and STOP.** Output: what you did, the resulting state, the PR
   url (if any), and the next pending item (run `select-next.sh` again and name it)
   so the user can simply say "next". Do not start the next task.
