---
description: "Approve or reject a tier-2 plan parked at plan_gate. Usage: /forge-approve <task-id> | /forge-approve <task-id> changes: <feedback>"
argument-hint: "<task-id> [changes: <feedback>]"
allowed-tools: Bash, Read
---

You are handling the human side of the forge plan gate. A tier-2 task ran
intake and plan, then parked at `plan_gate`; the user is now deciding. The
forge scripts live at `${CLAUDE_PLUGIN_ROOT}/scripts`. The target repo is the
current working directory (or `$FORGE_TARGET_REPO`). Argument: `$ARGUMENTS`.

Do exactly the following, then STOP and wait for the user:

1. **Parse the argument.** The first token is the task id. If the remainder
   begins with `changes:`, everything after it is the feedback for a
   request-changes decision; otherwise this is an approval.
   With no argument at all: list tasks currently at `plan_gate` (read
   `.forge/queue.json`), show each one's `title` from its spec, and STOP so
   the user can pick.

2. **Show what is being decided.** Read `.forge/runs/<task-id>/run.json` and
   confirm the status is `plan_gate` (if not, report the actual status and
   STOP). Print a compact summary of `.forge/runs/<task-id>/plan.md`: the
   Goal, the Changes list, and the Verification map. The user is deciding on
   this plan; never decide for them.

3. **Record the decision** with the shared script:
   - Approve: `"${CLAUDE_PLUGIN_ROOT}/scripts/approve-plan.sh" <task-id>`
   - Changes: `"${CLAUDE_PLUGIN_ROOT}/scripts/approve-plan.sh" <task-id> --request-changes "<feedback>"`

4. **Report and STOP.** State the task's new position (approved: resumes at
   build; changes: will re-plan with the feedback) and that `/forge-fix
   <task-id>` continues it interactively now, or the unattended runner picks
   it up on its next pass. Do not start the pipeline yourself.
