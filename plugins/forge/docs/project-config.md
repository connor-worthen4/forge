# Forge project config contract

forge is installed once, globally, and carries zero project knowledge. Everything
project-specific lives in a per-repo **`.forge/config.yaml`** that the forge-run
workflow and its phase agents read at runtime. This file is the engine-vs-project
seam: the engine stays generic, and each repo customizes it through this config.

This contract is project-agnostic. Nothing here is specific to any single target
repository.

- **Location:** `.forge/config.yaml` at the target repo root. It is committed to
  the target repo (it is configuration, not runtime state). Runtime state such as
  `.forge/runs/` and `.forge/queue.json` is gitignored.
- **Schema:** [`schema/project-config.schema.json`](../schema/project-config.schema.json) (JSON Schema, Draft 2020-12).
- **Examples:** [`examples/config.minimal.yaml`](../examples/config.minimal.yaml), [`examples/config.full.yaml`](../examples/config.full.yaml).
- **Validate:** `scripts/validate-config.sh [.forge/config.yaml]`.

A config file is optional for a brand-new project: with no `.forge/config.yaml`,
the launcher falls back to the engine defaults documented below.

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
| `autonomy`           | object          | no       | see below                    | Default tier and which task types must pause for plan approval. |
| `review_lenses`      | list of strings | no       | -                            | When set, the review phase fans out one reviewer per lens. See below. |
| `budget`             | object          | no       | see below                    | Retry cap and per-phase model selection. |

### `vcs`

| Field       | Type   | Required | Default                | Meaning |
| ----------- | ------ | -------- | ---------------------- | ------- |
| `host`      | enum   | yes      | -                      | `github` or `gitlab`. |
| `cli`       | enum   | no       | derived from `host`    | `gh` (github) or `glab` (gitlab). The integrate phase uses this CLI to open the PR/MR. |
| `pr_target` | string | no       | `develop`              | Base/target branch for PRs (GitHub) or MRs (GitLab). |

### `commands`

How forge builds and checks this repo. Phase agents shell these out; an empty
string means the phase skips that step.

| Field       | Type   | Required | Default | Meaning |
| ----------- | ------ | -------- | ------- | ------- |
| `build`     | string | no       | `""`    | Build/compile command. |
| `test`      | string | yes      | `""`    | Test command. The verify phase runs this. Should be non-empty for any repo with code-changing tasks. |
| `lint`      | string | no       | `""`    | Lint command. |
| `typecheck` | string | no       | `""`    | Type-check command. |

### `autonomy`

| Field          | Type         | Default     | Meaning |
| -------------- | ------------ | ----------- | ------- |
| `default_tier` | integer enum | `1`         | `0` read-only, `1` branch+PR, `2` gated. Used when a task spec does not set its own `autonomy_tier`. |
| `require_gate` | list of types| `[build]`   | Task types forced to tier-2 plan approval regardless of their own tier. Such tasks park at `plan_gate` until `/forge:approve`. |

Task types are `fix`, `build`, `audit`, `refactor`, `investigate`, `chore` (same
enum as the task-spec contract).

### `review_lenses`

Optional list of lens names (for example `[correctness, security, tests, scope]`).
When present, the review phase runs one parallel reviewer per lens, each blind to
the others, and a synth pass consolidates and de-duplicates their findings into
`review.md`. Omit the key entirely for a single review agent (the default).

### `budget`

| Field          | Type    | Default | Meaning |
| -------------- | ------- | ------- | ------- |
| `max_attempts` | integer | `2`     | Attempts per task across the combined verify->build and review->build recovery loops. Once exhausted the task parks `blocked`. |
| `models`       | object  | -       | Phase to model mapping. See [Models](#models). |

---

## Budget semantics

forge runs inside your live Claude Code session, so there is no separate API bill
to cap; usage is governed by your Claude Code plan. The `budget` block therefore
controls only the pipeline's behavior, not money:

- **Retry cap.** `budget.max_attempts` caps the combined verify->build and
  review->build recovery loops per task. Once exhausted, the task parks `blocked`
  rather than looping forever.
- **Per-phase models.** `budget.models[phase]` overrides the model that phase's
  agent runs on. An unmapped phase inherits the session model. See
  [Models](#models).

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
`[1m]` suffix may be appended to opus/sonnet.

A reasonable mapping uses cheap models for mechanical phases and Sonnet for the
reasoning ones; an unmapped phase inherits the session model:

```
intake: haiku    plan: sonnet    build: sonnet    verify: haiku
review: sonnet   integrate: haiku                 report: haiku
```

`opus` is reserved for explicit tier-2 overrides and should rarely be a phase
default. `validate-config.sh` warns if any phase model is `opus`.

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
bad enum values (`vcs.host`, `vcs.cli`, `autonomy.default_tier`, task types in
`require_gate`, model phase keys), a non-positive `budget.max_attempts`, and
malformed `protected_branches` or `review_lenses`. Warnings are advisory and do
not fail: an empty `commands.test`, a phase model set to `opus`, an unrecognized
model string, and `vcs.cli` inconsistent with `host`. When the python
`jsonschema` library is available, a full Draft 2020-12 validation runs as well.
