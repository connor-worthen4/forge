---
description: "Drain every runnable queued task through the forge pipeline in this session, via the forge-run workflow. Usage: /forge:run-all"
argument-hint: ""
allowed-tools: Bash, Read, Workflow
---

You run the whole forge queue: every runnable task spec under `tasks/` goes
through the pipeline (intake -> plan -> build -> verify -> review -> integrate) in
one forge-run workflow, then you report and stop. The forge plugin lives at
`${CLAUDE_PLUGIN_ROOT}`; the target repo is the current working directory.

Tasks already parked or finished are skipped: `plan_gate` items need
`/forge:approve`, and `pr_open`/`done`/`blocked`/`failed` are not re-run here.

Do exactly the following, then STOP:

1. **Validate config if present.** If `.forge/config.yaml` exists, run
   `"${CLAUDE_PLUGIN_ROOT}/scripts/validate-config.sh" .forge/config.yaml`; if it
   prints `FAIL`, report the errors and STOP. If it does not exist, continue with
   engine defaults.

2. **Refresh the queue.** Run
   `"${CLAUDE_PLUGIN_ROOT}/scripts/ingest-files.sh" tasks` so newly added specs
   are registered in `.forge/queue.json` (existing statuses are preserved). If
   there are no task specs, report that and STOP.

3. **Assemble the workflow args.** Run
   `"${CLAUDE_PLUGIN_ROOT}/scripts/forge-context.sh" --all`. It prints a JSON
   object whose `tasks` array holds every runnable task. If `tasks` is empty,
   report that there is nothing runnable (note any `plan_gate` items needing
   approval) and STOP.

4. **Run the workflow.** Call the `Workflow` tool with `scriptPath` set to
   `${CLAUDE_PLUGIN_ROOT}/workflows/forge-run.js` and `args` set to the exact JSON
   object the script printed (parse it; do not re-type it). It returns
   `{ results: [ { taskId, tier, final, phase, prUrl, branch, reason } ] }`.

5. **Record outcomes.** For each entry in `results`, run
   `"${CLAUDE_PLUGIN_ROOT}/scripts/record-outcome.sh" <taskId> <final> <phase> "<prUrl or ''>" "<branch or ''>" "<reason or ''>"`.

6. **Report and STOP.** Print a compact summary: each task and its final state,
   the PR urls for `pr_open` tasks, and which tasks parked at `plan_gate` (needing
   `/forge:approve`) or `blocked`/`failed` (with reasons).
