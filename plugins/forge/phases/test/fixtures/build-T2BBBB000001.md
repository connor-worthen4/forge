---
id: build-T2BBBB000001
title: Add a --json output mode to select-next.sh
type: build
autonomy_tier: 2
priority: P0
base_branch: develop
scope:
  - plugins/forge/scripts/select-next.sh
constraints:
  - Default (no-flag) behavior must stay byte-for-byte unchanged
  - Reuse the existing python selection logic; do not add a second selector
acceptance_criteria:
  - "Running select-next.sh --json prints the selected task as a JSON object with task_id and priority fields"
  - "Running select-next.sh with no flag still prints only the bare task_id (unchanged default)"
  - "When no task is selectable, select-next.sh --json prints {\"task_id\": null}"
  - The existing no-flag callers in forge-run.sh continue to work without modification
---

Operators want a machine-readable form of the next-task selection so other
tooling can consume priority alongside the id. Add a `--json` flag to
`select-next.sh` that emits a JSON object for the selected task, while leaving
the default bare-id output untouched for existing callers.

This is a tier-2 build: produce a plan and pause for human approval before
writing code. The plan should show exactly where the flag is parsed and how the
existing selection logic is reused rather than duplicated.
