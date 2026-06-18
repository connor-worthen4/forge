---
description: "Approve or reject a tier-2 plan parked at plan_gate, then run it. Usage: /forge:approve <task-id> | /forge:approve <task-id> changes: <feedback>"
argument-hint: "<task-id> [changes: <feedback>]"
allowed-tools: Bash, Read, Write, Workflow
---

You handle the human side of the forge plan gate. A tier-2 task ran intake and
plan, then parked at `plan_gate`; the user is now deciding. The forge plugin
lives at `${CLAUDE_PLUGIN_ROOT}`; the target repo is the current working
directory. Argument: `$ARGUMENTS`.

Do exactly the following, then STOP:

1. **Parse the argument.** The first token is the task id. If the remainder begins
   with `changes:`, everything after it is the feedback for a request-changes
   decision; otherwise this is an approval. With no argument at all: read
   `.forge/queue.json`, list the tasks whose status is `plan_gate` with each
   one's `title`, and STOP so the user can pick.

2. **Confirm and show what is being decided.** Read `.forge/runs/<task-id>/run.json`
   and confirm `status` is `plan_gate` (if not, report the actual status and
   STOP). Print a compact summary of `.forge/runs/<task-id>/plan.md`: the Goal, the
   Changes list, and the Verification map. The user is deciding on this plan; never
   decide for them.

3a. **On approval**, run the rest of the pipeline now:
   - `"${CLAUDE_PLUGIN_ROOT}/scripts/forge-context.sh" <task-id> --approved`
   - Call the `Workflow` tool with `scriptPath` =
     `${CLAUDE_PLUGIN_ROOT}/workflows/forge-run.js` and `args` = the JSON the
     script printed. It resumes at build and runs to `pr_open`.
   - For each entry in `results`, run
     `"${CLAUDE_PLUGIN_ROOT}/scripts/record-outcome.sh" <taskId> <final> <phase> "<prUrl or ''>" "<branch or ''>" "<reason or ''>"`.

3b. **On request-changes**, trigger a re-plan:
   - Write the feedback to `.forge/runs/<task-id>/plan-feedback.md`.
   - `"${CLAUDE_PLUGIN_ROOT}/scripts/forge-context.sh" <task-id>` (it detects the
     feedback file and re-plans rather than building).
   - Call the `Workflow` tool as above with the printed args. The plan phase
     addresses the feedback and the task parks at `plan_gate` again.
   - Record the outcome with `record-outcome.sh` as above.

4. **Report and STOP.** On approval: state the final state and the PR url (or the
   block reason). On request-changes: state that the task re-planned and is parked
   at `plan_gate` again for another `/forge:approve`. Do nothing else.
