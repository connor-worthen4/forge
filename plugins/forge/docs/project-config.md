# Forge project config contract

forge is installed once, globally, and carries zero project knowledge. Everything
project-specific lives in a per-repo **`.forge/config.yaml`** that every pipeline
phase and the runner read at runtime. This file is the engine-vs-project seam: a
repo with only this config gets the generic factory; a repo that also supplies
agent/skill overrides gets a customized one.

This contract is project-agnostic. Nothing here is specific to any single target
repository.

- **Location:** `.forge/config.yaml` at the target repo root. It is committed to
  the target repo (it is configuration, not runtime state). Runtime state such as
  `.forge/spend.json` and `.forge/runs/` is gitignored.
- **Schema:** [`schema/project-config.schema.json`](../schema/project-config.schema.json) (JSON Schema, Draft 2020-12).
- **Examples:** [`examples/config.minimal.yaml`](../examples/config.minimal.yaml), [`examples/config.full.yaml`](../examples/config.full.yaml).
- **Validate:** `scripts/validate-config.sh [.forge/config.yaml]`.

---

## Fields

### Top level

| Field                | Type            | Required | Default                      | Meaning |
| -------------------- | --------------- | -------- | ---------------------------- | ------- |
| `version`            | integer         | yes      | `1`                          | Config schema version. Currently always `1`. |
| `base_branch`        | string          | yes      | `develop`                    | Default branch feature branches are cut from and PRs target. |
| `protected_branches` | list of strings | no       | `[main, master, develop]`    | Single source of truth for the git guardrail's protected list (see [Guardrail integration](#guardrail-integration)). |
| `vcs`                | object          | yes      | -                            | VCS host and CLI. See below. |
| `commands`           | object          | yes      | -                            | How forge builds/checks this repo. See below. |
| `overrides`          | object          | no       | see below                    | Optional project specialization. |
| `autonomy`           | object          | no       | see below                    | How much the runner may do without a human. |
| `budget`             | object          | no       | see below                    | Cost and concurrency controls. |

### `vcs`

| Field       | Type   | Required | Default                | Meaning |
| ----------- | ------ | -------- | ---------------------- | ------- |
| `host`      | enum   | yes      | -                      | `github` or `gitlab`. |
| `cli`       | enum   | no       | derived from `host`    | `gh` (github) or `glab` (gitlab). The integrate phase uses this CLI to open the PR/MR. |
| `pr_target` | string | no       | `develop`              | Base/target branch for PRs (GitHub) or MRs (GitLab). |

### `commands`

How forge builds and checks this repo. Phases shell these out; an empty string
means the phase skips that step.

| Field       | Type   | Required | Default | Meaning |
| ----------- | ------ | -------- | ------- | ------- |
| `build`     | string | no       | `""`    | Build/compile command. |
| `test`      | string | yes      | `""`    | Test command. The verify phase runs this. Must be non-empty when code-changing task types are enabled. |
| `lint`      | string | no       | `""`    | Lint command. |
| `typecheck` | string | no       | `""`    | Type-check command. |

### `overrides`

Optional. Phases fall back to the generic engine behavior when these directories
are absent.

| Field        | Type   | Default          | Meaning |
| ------------ | ------ | ---------------- | ------- |
| `agents_dir` | string | `.forge/agents`  | Project-specific agent overrides. |
| `skills_dir` | string | `.forge/skills`  | Project-specific skill overrides. |

### `autonomy`

| Field              | Type            | Default                          | Meaning |
| ------------------ | --------------- | -------------------------------- | ------- |
| `default_tier`     | integer enum    | `1`                              | `0` read-only, `1` branch+PR, `2` gated. Used when a task spec does not set its own `autonomy_tier`. |
| `allow_unattended` | list of types   | `[fix, audit, refactor, chore]`  | Task types the runner may process unattended (overnight). |
| `require_gate`     | list of types   | `[build]`                        | Task types forced to tier-2 plan approval regardless of their own tier. |

Task types are `fix`, `build`, `audit`, `refactor`, `investigate`, `chore` (same
enum as the task-spec contract).

### `budget`

| Field          | Type    | Default | Meaning |
| -------------- | ------- | ------- | ------- |
| `nightly_usd`  | number  | -       | Runner stops launching NEW tasks once cumulative night spend reaches this. |
| `monthly_usd`  | number  | -       | Soft monthly cap. Set BELOW your account credit ceiling. |
| `max_attempts` | integer | `2`     | Per (task, phase) retries before the task is blocked/failed. |
| `concurrency`  | integer | `1`     | Max parallel headless sessions. Git-touching work is ALWAYS serialized. |
| `models`       | object  | -       | Phase to model mapping. See [Models](#models). |

---

## Budget enforcement semantics

The future runner honors these so spend stays bounded and forge throttles itself
rather than getting cut off mid-build.

- **Durable ledger.** The runner reads each headless result's cost field and
  accumulates spend in `.forge/spend.json` (gitignored):
  `{ window_date, night_usd_spent, month_usd_spent, per_task: {...} }`.
- **Soft caps, checked before launch.** Before launching a new task, the runner
  compares `night_usd_spent` against `budget.nightly_usd` and `month_usd_spent`
  against `budget.monthly_usd`. If either is reached, it finishes any in-flight
  task and stops launching new ones. This is a graceful soft cap set BELOW
  Anthropic's hard credit limit, so forge throttles itself instead of failing
  mid-build.
- **Per-phase models.** `budget.models[phase]` is passed as `--model` to
  `claude -p` for that phase. See [Models](#models).
- **Retry cap.** `budget.max_attempts` caps the verify->build and review->build
  recovery loops per phase. Once exhausted, the task moves to `blocked` or
  `failed` rather than looping forever.

### Credit ceiling

`monthly_usd` should sit below your account's actual credit ceiling, which is
plan- and account-specific (configure your hard spend limit in the Anthropic
console). `validate-config.sh` warns when `monthly_usd` is unset or at/above a
reference ceiling (default `$100`, override with `FORGE_CREDIT_CEILING_USD`). The
warning is advisory and does not fail validation.

---

## Models

`budget.models[phase]` accepts a Claude Code model alias or a pinned full model
name. Valid aliases were verified against the official Claude Code model docs
(code.claude.com/docs/en/model-config) on 2026-06-03:

| Alias        | Resolves to (Anthropic API) |
| ------------ | --------------------------- |
| `default`    | account's recommended model (clears any override) |
| `best`       | most capable available, currently `opus` |
| `opus`       | latest Opus (currently Opus 4.8) |
| `sonnet`     | latest Sonnet (currently Sonnet 4.6) |
| `haiku`      | fast Haiku (currently Haiku 4.5) |
| `opus[1m]`   | Opus with 1M-token context |
| `sonnet[1m]` | Sonnet with 1M-token context |
| `opusplan`   | Opus in plan mode, Sonnet for execution |

Pinned full strings (verified from the models overview): `claude-opus-4-8`,
`claude-sonnet-4-6`, `claude-haiku-4-5-20251001` (alias `claude-haiku-4-5`); a
`[1m]` suffix may be appended to opus/sonnet. Approximate pricing per million
tokens (input/output): Opus $5/$25, Sonnet $3/$15, Haiku $1/$5.

Recommended defaults at a modest budget (cheap models for mechanical phases,
Sonnet for reasoning):

```
intake: haiku    plan: sonnet    build: sonnet
verify: haiku    review: sonnet  integrate: haiku
```

`opus` is reserved for explicit tier-2 overrides and should never be a phase
default at this budget. `validate-config.sh` warns if any phase model is `opus`.

---

## Guardrail integration

`protected_branches` in this config is the single source of truth for the git
guardrail. The guardrail hook (`hooks/block-git-writes.sh`) resolves its
protected list in priority order:

1. `protected_branches` from `.forge/config.yaml` (read relative to the cwd).
2. The `FORGE_PROTECTED_BRANCHES` environment variable.
3. The hardcoded default `[main, master, develop]`.

An empty or absent config list falls through to the next source, so the default
always protects (fail safe). Because every forge working branch is named
`forge/<type>/<id>-<slug>`, it can never equal a protected branch name, so the
guardrail never blocks legitimate forge work.

---

## Validation

```
scripts/validate-config.sh .forge/config.yaml
```

Errors fail the run (non-zero exit): missing required fields, wrong `version`,
bad enum values (`vcs.host`, `vcs.cli`, `autonomy.default_tier`, task types,
model phase keys), and a missing `commands.test` when code-changing task types
are enabled. Warnings are advisory and do not fail: `monthly_usd` unset or
at/above the credit ceiling, an unattended `build` with no build command, a phase
model set to `opus`, and `vcs.cli` inconsistent with `host`. When the python
`jsonschema` library is available, a full Draft 2020-12 validation runs as well.
