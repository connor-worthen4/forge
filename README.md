# Forge

[![CI](https://github.com/connor-worthen4/forge/actions/workflows/ci.yml/badge.svg)](https://github.com/connor-worthen4/forge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A portable Claude Code plugin that takes a task — or a whole queue of them — and runs each through a multi-agent pipeline: intake, plan, build, verify, review, integrate. Every task lands as a pull request against your base branch. Forge never merges; a human reviews and merges the PR.

Forge sits on top of your repository and runs inside your Claude Code session, so every phase already has your code, history, and tooling in context. There is no daemon, no cron, and no separate service to run. The engine is generic; everything project-specific lives in each target repo's `.forge/config.yaml`, not in this repository.

## Why Forge instead of one big prompt?

Forge is a thin wrapper around Claude Code, not a separate service. Instead of one long conversation that drifts as it grows, each step is a fresh, single-purpose agent with a least-privilege tool set that reads the previous step's filed artifact and writes its own. That buys what a single prompt does not:

- **Grounded, not plausible.** Intake and plan must back every claim about your code with a real `path:line` or a command they ran — never an assertion from memory — and they file a context brief and a plan before any code is written. Build then implements that plan as the smallest diff, in your actual repository.
- **Tuned to your repo, not generic.** Forge carries no conventions of its own — your repository supplies them. Intake inventories the standing guidance the repo already provides (`CLAUDE.md`, repo-local skills and agents, contributing and design docs, linter rules) and records what bears on the task in the context brief; plan and build then default to those documented standards — invoking your repo's skills to do the work its way — and fall back to your existing code only where no standard applies. The standards govern *how* a change is made; what the code *is* stays proven by `path:line`.
- **Checked against criteria you set.** Verify runs your real `test` command and grades the result against the spec's explicit `acceptance_criteria`; review is a separate adversarial pass. A failing verify or review loops back to build, capped by `budget.max_attempts`, instead of declaring success.
- **Bounded and inspectable.** Every phase leaves an artifact under `.forge/runs/<id>/` — brief, plan, diff, verdicts, PR record — that you can read. Risky `build` work pauses at a human plan gate before any code is written.
- **Safe by construction.** The whole run executes in your Claude Code session, with a PreToolUse hook that blocks merges and pushes to protected branches. Forge opens a PR and stops; it never merges. A human reviews and merges.

## How it works

- A thin plugin layer (slash commands) reads your config and task specs, then launches the **`forge-run` workflow** (`workflows/forge-run.js`).
- The workflow is the pipeline state machine. For each task it spawns one **phase agent** per step (`agents/forge-*.md`), each running in an isolated context with a least-privilege tool set and returning a structured result.
- The agents do the disk work: they read the spec, config, and prior artifacts, and write their own artifact into `.forge/runs/<task-id>/`. After the workflow returns, the launcher stamps the run record and queue.
- A PreToolUse hook (`hooks/block-git-writes.sh`) blocks merges and pushes to protected branches throughout.

Works in two modes from the same agents: on an **existing repo** the phases gather real `path:line` context and adopt the conventions the repo documents; on a **greenfield** project (or a raw prompt with no spec) they propose structure and scaffold from zero.

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
        examples/             # example task specs and project configs (start at examples/README.md)

Runtime state (`.forge/queue.json`, `.forge/runs/`) lives in the target repository and is gitignored.

## Requirements

- macOS or Linux with bash 3.2+
- [Claude Code](https://code.claude.com) (`claude`) — forge runs inside a Claude Code session
- `git`, `jq`, and `python3` (PyYAML recommended; a ruby fallback handles the YAML parsing otherwise)
- `gh` (GitHub CLI), or `glab` for GitLab, to open PRs/MRs

## Install

1. Add the marketplace from this repository:

   ```
   /plugin marketplace add connor-worthen4/forge
   ```

   Claude Code clones the repo and reads its root `marketplace.json`. For local
   development against a checkout, point it at the path instead:
   `/plugin marketplace add /absolute/path/to/forge`.

2. Install the plugin from the marketplace:

   ```
   /plugin install forge@forge
   ```

3. Confirm it loaded (plugin commands are namespaced under the plugin name):

   ```
   /forge:status
   ```

## Project setup

Forge keeps no project knowledge in this repo; it adapts to whatever repository you point it at. A repo is compatible once it meets a few prerequisites:

- **A git repo with a remote on a supported host.** Forge opens real pull requests, so the target must be a git repository whose remote is on GitHub or GitLab, with the matching CLI installed and authenticated — `gh auth login` for GitHub, `glab auth login` for GitLab.
- **A base branch that already exists.** Forge cuts every working branch from your base branch and targets its PRs there, so that branch must exist before the first run. The default is `develop`; if your repo integrates into `main` (or anything else), set `base_branch` and `vcs.pr_target` in the config rather than creating a branch you do not use.
- **Build and test commands forge can run.** The verify phase shells out to your real `test` command and grades the result, so any repo with code-changing tasks needs at least a working test command declared in the config.

With those in place, everything project-specific lives in two places in the target repo (`.forge/` and `tasks/`), and the split between what you commit and what you ignore matters:

    your-repo/
      .forge/
        config.yaml      # you write   - how forge builds, tests, and lints THIS repo. COMMIT it.
        runs/            # forge writes - per-run artifacts (briefs, plans, diffs, PR records). GITIGNORE.
        queue.json       # forge writes - the task queue index. GITIGNORE.
      tasks/
        fix-<id>.md      # task specs you write (or /forge:draft writes). Commit or ignore - your call.

- **`.forge/config.yaml` is committed.** It is configuration, not runtime state: your build/test/lint commands, base branch, protected branches, autonomy gating, and per-phase models. Copy [`plugins/forge/examples/config.minimal.yaml`](plugins/forge/examples/config.minimal.yaml) to `.forge/config.yaml` and set the `commands` to match your project; validate it with `plugins/forge/scripts/validate-config.sh .forge/config.yaml`. A brand-new project can skip this entirely and run on the engine defaults.
- **`.forge/runs/` and `.forge/queue.json` are regenerated every run** — gitignore them. Add to your repo's `.gitignore`:

      # Forge runtime state (keep .forge/config.yaml tracked)
      .forge/runs/
      .forge/queue.json

- **`tasks/*.md` is your choice.** Task specs are plain markdown that read like issues-as-code. Commit them to keep the request-of-record in history, or add `tasks/` to `.gitignore` if you treat them as scratch. Either way `/forge:run-all` ingests whatever is in `tasks/` at run time.

The annotated [`examples/`](plugins/forge/examples/) directory has a ready config and one spec of each shape; [`docs/`](plugins/forge/docs/) holds the full config and task-spec contracts.

## Use it

With the repo set up, give forge work in any of these ways:

- **Draft specs from a freeform ask (best for several tasks):** `/forge:draft "add retry to the HTTP client; fix the flaky auth test; audit the rate limiter"`. Forge grounds each item in the repo, writes validated `tasks/<id>.md` specs, and flags any tasks that touch the same files (wiring `depends_on`) so they do not collide on a later `/forge:run-all`. Review the specs it writes, edit if needed, then run them.
- **A raw prompt for one task:** `/forge:run "add bounded retry with backoff to the HTTP client"`. Forge derives a spec inline and runs it.
- **A hand-written spec file:** write `tasks/<id>.md` (start from [`plugins/forge/examples/`](plugins/forge/examples/); the field reference is [`plugins/forge/docs/task-spec.md`](plugins/forge/docs/task-spec.md)), validate it with `plugins/forge/scripts/validate-task.sh tasks/<id>.md`, then run it.

Run a single spec with `/forge:run <id>`, or drain the whole `tasks/` queue with `/forge:run-all`. For a gated `build` task that parks at `plan_gate`, review the plan and run `/forge:approve <id>` (or `/forge:approve <id> changes: <feedback>` to send it back for a re-plan).

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
- `develop` — integration target. Forge opens pull requests against `develop`; a human reviews and merges them.

## License

MIT. See [LICENSE](LICENSE).
