# Forge

Raw task in, tempered PR out — an agentic software factory for Claude Code, portable across any repo.

Forge is a portable Claude Code plugin. A task flows through an agent pipeline — intake, plan, build, verify, review, integrate — and lands as a pull request into your base branch. Forge never merges; a human always reviews and merges the PR.

The pipeline runs as a **Claude Code workflow** that you boot from your live session with a slash command. There is no daemon, no cron, and no separate API bill: forge runs inside Claude Code, governed by your plan. The engine is generic; project-specific configuration lives in each target repo's `.forge/config.yaml`, not in this repository.

## How it works

- A thin plugin layer (slash commands) reads your config and task specs, then launches the **`forge-run` workflow** (`workflows/forge-run.js`).
- The workflow is the pipeline state machine. For each task it spawns one **phase agent** per step (`agents/forge-*.md`), each running in an isolated context with a least-privilege tool set and returning a structured result.
- The agents do the disk work: they read the spec, config, and prior artifacts, and write their own artifact into `.forge/runs/<task-id>/`. After the workflow returns, the launcher stamps the run record and queue.
- A PreToolUse hook (`hooks/block-git-writes.sh`) blocks merges and pushes to protected branches throughout.

Works in two modes from the same agents: on an **existing repo** the phases gather real `path:line` context; on a **greenfield** project (or a raw prompt with no spec) they propose structure and scaffold from zero.

## How a task flows

1. A task is either a spec file (markdown + YAML frontmatter under `tasks/`) or a raw prompt passed to `/forge:run`.
2. The launcher derives the pipeline shape from the task type and tier:
   - `audit` / `investigate` — tier 0, read-only: intake, plan, report. No branch, no PR.
   - `fix` / `refactor` / `chore` — tier 1, linear: intake, plan, build, verify, review, integrate, ending at an open PR.
   - `build` — tier 2, gated: stops after plan for human approval. `/forge:approve <task-id>` resumes it into the build loop; `/forge:approve <task-id> changes: <feedback>` triggers a re-plan.
3. Each phase agent reads the prior phases' artifacts from `.forge/runs/<task-id>/` and files its own (context brief, plan, diff, verdicts, PR record).
4. A failing verify or review loops back to build, capped by `budget.max_attempts`.
5. Tier 1/2 ends at `pr_open`; a human reviews and merges. Tier 0 ends at `done` with a report.

## Repository layout

    .claude-plugin/
      marketplace.json        # marketplace catalog; lists the forge plugin
    plugins/
      forge/
        .claude-plugin/
          plugin.json         # plugin manifest
        commands/             # slash commands (/forge:draft, /forge:run, /forge:run-all, /forge:approve, /forge:status)
        workflows/            # forge-run.js — the pipeline orchestrator
        agents/               # one subagent per pipeline phase (forge-intake ... forge-report)
        scripts/              # launcher glue: config assembly, ingester, validators, outcome recorder
        schema/               # task-spec, run-record, project-config JSON schemas
        hooks/                # git-safety guardrail hook and its tests
        docs/                 # task-spec and project-config contracts
        examples/             # example task specs and project configs

Runtime state (`.forge/queue.json`, `.forge/runs/`) lives in the target repository and is gitignored.

## Requirements

- macOS or Linux with bash 3.2+
- [Claude Code](https://code.claude.com) (`claude`) — the pipeline runs as a workflow inside a Claude Code session
- `git`, `jq`, and `python3` (PyYAML recommended; a ruby fallback handles the YAML parsing otherwise)
- `gh` (GitHub CLI), or `glab` for GitLab, to open PRs/MRs

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

3. Confirm it loaded (plugin commands are namespaced under the plugin name):

   ```
   /forge:status
   ```

## Use it

In the repo where forge will work:

1. (Optional) Create `.forge/config.yaml` — see `plugins/forge/examples/config.minimal.yaml` for the smallest valid config and `config.full.yaml` for every option. Validate it with `plugins/forge/scripts/validate-config.sh .forge/config.yaml`. A brand-new project can skip this and run on the engine defaults.
2. Give forge work, any of these ways:
   - **Draft specs from a freeform ask (best for several tasks):** `/forge:draft "add retry to the HTTP client; fix the flaky auth test; audit the rate limiter"`. Forge grounds each item in the repo, writes validated `tasks/<id>.md` specs, and flags any tasks that touch the same files (wiring `depends_on`) so they do not collide on a later `/forge:run-all`. Review the specs it writes, edit if needed, then run them.
   - **A raw prompt for one task:** `/forge:run "add bounded retry with backoff to the HTTP client"`.
   - **A hand-written spec file:** write `tasks/<id>.md` (see `plugins/forge/examples/` and `plugins/forge/docs/task-spec.md`), validate it with `plugins/forge/scripts/validate-task.sh tasks/<id>.md`, then run `/forge:run <id>`.
3. Run the whole queue at once with `/forge:run-all`.
4. For a gated `build` task that parks at `plan_gate`, review the plan and run `/forge:approve <id>` (or `/forge:approve <id> changes: <feedback>` to send it back for a re-plan).

Each run reports the final state per task: an open PR (tier 1/2), a report at `.forge/runs/<id>/report.md` (tier 0), a parked plan gate, or a blocked/failed reason. Watch live progress in the workflow view.

## Develop loop

For live iteration without installing, load the plugin directory directly:

```
claude --plugin-dir /absolute/path/to/forge/plugins/forge
```

Changes to commands, agents, the workflow, and hooks are picked up on the next session.

Validate the manifest before committing:

```
claude plugin validate ./plugins/forge --strict
```

Run the test suites:

```
plugins/forge/hooks/test/run-tests.sh    # guardrail hook unit tests
plugins/forge/scripts/test/run-tests.sh  # config_get unit tests
```

## Branches

- `main` — stable baseline.
- `develop` — integration target. The factory opens pull requests against `develop`; a human reviews and merges them.

## License

MIT. See [LICENSE](LICENSE).
