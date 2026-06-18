---
description: "Run ONE task through the forge pipeline in this session, via the forge-run workflow. Usage: /forge <task-id> | /forge \"<goal prompt>\""
argument-hint: "<task-id> | \"<goal prompt>\""
allowed-tools: Bash, Read, Workflow
---

You drive a single forge task through its pipeline (intake -> plan -> build ->
verify -> review -> integrate) using the forge-run workflow, then report and stop.
The forge plugin lives at `${CLAUDE_PLUGIN_ROOT}`; its scripts are in
`${CLAUDE_PLUGIN_ROOT}/scripts`. The target repo is the current working directory.
Argument: `$ARGUMENTS`.

Do exactly the following, then STOP:

1. **Validate config if present.** If `.forge/config.yaml` exists, run
   `"${CLAUDE_PLUGIN_ROOT}/scripts/validate-config.sh" .forge/config.yaml`. If it
   prints `FAIL`, report the errors and STOP - do not run with a broken config.
   If the file does not exist, continue (the engine defaults apply; this is normal
   for a brand-new project).

2. **Assemble the workflow args.** Decide what `$ARGUMENTS` is:
   - If it is a single token matching a task id (`fix-`, `build-`, `audit-`,
     `refactor-`, `investigate-`, or `chore-` followed by 6-26 alphanumerics),
     run `"${CLAUDE_PLUGIN_ROOT}/scripts/forge-context.sh" "$ARGUMENTS"`.
   - Otherwise treat the whole argument as a greenfield goal prompt and run
     `"${CLAUDE_PLUGIN_ROOT}/scripts/forge-context.sh" --goal "$ARGUMENTS"`.
   The script prints a JSON object. If it exits non-zero, report its stderr and
   STOP.

3. **Run the workflow.** Call the `Workflow` tool with `scriptPath` set to
   `${CLAUDE_PLUGIN_ROOT}/workflows/forge-run.js` and `args` set to the exact JSON
   object the script printed (parse it; do not re-type it). The workflow runs the
   pipeline and returns `{ results: [ { taskId, tier, final, phase, prUrl, branch,
   reason } ] }`.

4. **Record the outcome.** For each entry in `results`, run
   `"${CLAUDE_PLUGIN_ROOT}/scripts/record-outcome.sh" <taskId> <final> <phase> "<prUrl or ''>" "<branch or ''>" "<reason or ''>"`
   to stamp `.forge/runs/<id>/run.json` and `.forge/queue.json`.

5. **Report and STOP.** State the final state for the task: `pr_open` (give the PR
   url), `done` (tier-0 report at `.forge/runs/<id>/report.md`), `plan_gate`
   (review the plan and run `/forge-approve <id>`), or `blocked`/`failed` (give the
   reason). Do not start another task.
