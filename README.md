# Forge

Raw task in, tempered PR out — an agentic software factory for Claude Code, portable across any repo.

Forge is a portable Claude Code plugin. Tasks flow through an agent pipeline — intake, plan, build, verify, review, integrate — and land as a pull request into the `develop` branch. Forge never merges; a human always reviews and merges the PR.

The engine is generic and reusable across projects. Project-specific configuration lives in each target repository's `.forge/config.yaml`, not in this repository.

## Status

Working pipeline skeleton (pre-v1). Implemented so far:

- Task-spec contract: JSON schema, deterministic validator, status state machine, and example specs for each tier.
- Project-config contract: JSON schema, validator, and minimal/full example configs.
- Git-safety guardrail: a PreToolUse hook that blocks merges and pushes to protected branches, sourcing the protected list from the target repo's config.
- Runner: phase executor, pipeline state-machine driver, unattended loop (`forge-run.sh --all`), next-task selector, and PR-merge detection (`pr_open` to `done`).
- Phases: all seven phases (`intake`, `plan`, `build`, `verify`, `review`, `integrate`, `report`) have real prompts sharing the same discipline: grounded `path:line` evidence, a fixed artifact format per phase, and a common JSON result contract. Stub mode (canned results, no model calls) remains available for state-machine testing.
- Plan gate: tier-2 tasks park at `plan_gate`; `/forge-approve` (or `scripts/approve-plan.sh`) approves the plan into the build loop or sends feedback back into a re-plan.
- Commands: `/forge-status`, the interactive `/forge-fix` driver, and `/forge-approve`.
- Tests: unit suites for the guardrail hook, `config_get`, and the plan-gate lifecycle, plus an end-to-end harness for the intake phase (real and stub modes).

Next up: a first run against a fresh target repository.

## How a task flows

1. A task spec (markdown with YAML frontmatter) is validated and queued in the target repo's `.forge/queue.json`.
2. The runner picks the next task and derives the pipeline shape from its type:
   - `audit` / `investigate` — tier 0, read-only: intake, plan, report. No branch, no PR.
   - `fix` / `refactor` / `chore` — tier 1, linear: intake, plan, build, verify, review, integrate, ending at an open PR.
   - `build` — tier 2, gated: stops after plan for human approval before any code is written. `/forge-approve <task-id>` resumes it into the tier-1 loop; `/forge-approve <task-id> changes: <feedback>` triggers a re-plan.
3. Each phase runs in an isolated context, reads the prior phases' artifacts from `.forge/runs/<task-id>/`, and files its own artifact (context brief, plan, diff, verdicts, PR record).
4. Failed verify or review loops back to build, capped by the configured attempt budget.
5. The pipeline ends at `pr_open`. A human reviews and merges; the next sync flips the task to `done`.

## Repository layout

    .claude-plugin/
      marketplace.json        # marketplace catalog; lists the forge plugin
    plugins/
      forge/
        .claude-plugin/
          plugin.json         # plugin manifest
        commands/             # slash commands (/forge-status, /forge-fix)
        phases/               # one prompt per pipeline phase, plus the test harness
        scripts/              # runner, drivers, validators, ingester
        schema/               # task-spec, run-record, project-config JSON schemas
        hooks/                # git-safety guardrail hook and its tests
        docs/                 # task-spec and project-config contracts
        examples/             # example task specs and project configs
        agents/               # subagents (empty for now)
        skills/               # skills (empty for now)

Runtime state (`.forge/queue.json`, `.forge/runs/`, `.forge/spend.json`) lives in the target repository and is gitignored.

## Install

Forge is distributed as a local marketplace during development.

1. Add the marketplace, pointing it at this repository's absolute path:

   ```
   /plugin marketplace add /absolute/path/to/forge
   ```

2. Install the plugin from the marketplace:

   ```
   /plugin install forge@forge
   ```

3. Confirm it loaded:

   ```
   /forge-status
   ```

## Set up a target repository

In the repo where forge will work:

1. Create `.forge/config.yaml` (see `plugins/forge/examples/config.minimal.yaml` for the smallest valid config, `config.full.yaml` for every option).
2. Validate it: `plugins/forge/scripts/validate-config.sh .forge/config.yaml`
3. Write a task spec (see `plugins/forge/examples/` and `plugins/forge/docs/task-spec.md`), then validate it with `plugins/forge/scripts/validate-task.sh`.
4. Drive one task interactively with `/forge-fix next`, or run the queue unattended with `plugins/forge/scripts/forge-run.sh --all`.

## Develop loop

For live iteration without installing, load the plugin directory directly:

```
claude --plugin-dir /absolute/path/to/forge/plugins/forge
```

Changes to commands, agents, skills, and hooks are picked up on the next session.

Validate the manifests before committing:

```
claude plugin validate ./plugins/forge --strict
```

Run the test suites:

```
plugins/forge/hooks/test/run-tests.sh             # guardrail hook unit tests
plugins/forge/scripts/test/run-tests.sh           # config_get unit tests
plugins/forge/scripts/test/run-approval-tests.sh  # plan-gate lifecycle (stub mode)
plugins/forge/phases/test/run-intake-tests.sh     # intake phase end to end
```

## Branches

- `main` — stable baseline.
- `develop` — integration target. The factory opens pull requests against `develop`; a human reviews and merges them.
