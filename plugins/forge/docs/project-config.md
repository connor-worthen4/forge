# Forge project config contract

forge is installed once, globally, and carries zero project knowledge. Everything
project-specific lives in a per-repo **`.forge/config.yaml`** that the forge-run
workflow and its phase agents read at runtime. This file is the engine-vs-project
seam: the engine stays generic, and each repo customizes it through this config.

The target repo supplies that knowledge through two channels: this declared config
(commands, branches, gating, models), and the standing conventions the phases read
at runtime — `CLAUDE.md`, repo-local skills and agents, contributing and design
docs, and linter rules. The config covers what forge must be told; it does not
restate conventions the repo already documents.

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
| `profile`            | enum            | no       | `standard`                   | Default pipeline shape for tasks that do not set their own `profile`. See [Profiles](#profiles). |
| `review_threshold_lines` | integer     | no       | `400`                        | Fast profile only: review is skipped when the diff changes fewer than this many lines. See [Profiles](#profiles). |
| `protected_branches` | list of strings | no       | `[main, master, develop]`    | Single source of truth for the git guardrail's protected list (see [Guardrail integration](#guardrail-integration)). |
| `integration_branch` | string          | no       | -                            | Opt-in. The one branch forge may **merge** into. See [The integration branch](#the-integration-branch). |
| `vcs`                | object          | yes      | -                            | VCS host and CLI. See below. |
| `commands`           | object          | yes      | -                            | How forge builds/checks this repo. See below. |
| `autonomy`           | object          | no       | see below                    | Default tier and which task types must pause for plan approval. |
| `surfaces`           | list of strings | no       | -                            | The areas of the system a task spec may declare as its `surface`. See [Surfaces](#surfaces). |
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
| `test`      | string | yes      | `""`    | Test command. The verify phase runs this (via `forge-checks.sh`, which records the exit code). Should be non-empty for any repo with code-changing tasks. |
| `lint`      | string | no       | `""`    | Lint command. |
| `typecheck` | string | no       | `""`    | Type-check command. |

### `autonomy`

| Field          | Type         | Default     | Meaning |
| -------------- | ------------ | ----------- | ------- |
| `default_tier` | integer enum | `1`         | `0` read-only, `1` branch+PR, `2` gated. Used when a task spec does not set its own `autonomy_tier`. |
| `require_gate` | list of types| `[build]`   | Task types forced to tier-2 plan approval regardless of their own tier. Such tasks park at `plan_gate` until `/forge:approve`. |

Task types are `fix`, `build`, `audit`, `refactor`, `investigate`, `chore` (same
enum as the task-spec contract).

### Profiles

`profile` sets the default pipeline shape for this repo. A task spec's own
`profile` field overrides it; with neither set, the default is `standard`.

| Profile    | Phases                                            | Use for |
| ---------- | ------------------------------------------------- | ------- |
| `fast`     | plan, build, verify (script), integrate (script)   | Small, well-specified greenfield work. |
| `standard` | intake, plan, build, verify, review, integrate     | The default. |
| `audit`    | intake, plan, report                               | Read-only investigation. No branch, no PR. |

Under `fast`, intake is skipped whenever the spec already states its
`acceptance_criteria`, and review is skipped when the branch diff changes fewer
than `review_threshold_lines` lines. That count comes from the `diff_lines`
field `forge-checks.sh` records in `checks.json`, so the threshold is compared
against a measured number; when the count is unavailable, review runs.

Set `review_threshold_lines` to `0` to keep review on every fast-profile task
regardless of diff size. Only fast-profile tasks consult it, but it is worth
setting on a `standard`-default repo too: individual specs can still ask for
`profile: fast`.

Profiles trim ceremony, not approval: a task type in `autonomy.require_gate`
still parks at `plan_gate` under `fast`. The `audit` profile forces tier 0 (no
branch, no PR), whatever the task's `autonomy_tier` says.

The full contract, including how profiles interact with autonomy tiers, is in
[task-spec.md](task-spec.md#profiles).

### Surfaces

The areas of this system a task spec may name in its `surface` field:

```yaml
surfaces: [schema, auth, api, ui-shell, profile, products]
```

Tasks sharing a surface run serially and stacked; tasks on different surfaces run
in parallel, each in its own git worktree. Declaring the list is what makes a
typo'd surface fail the run rather than silently becoming its own group - which
would look fine while quietly removing the collision protection the spec asked
for. Omit the key to allow any surface string.

The list constrains the *vocabulary*, not the truth of the label. Forge never
infers a surface or checks for file overlap before running: two tasks on
different surfaces run in parallel even if they turn out to edit the same file.
Keep the names coarse enough that tasks touching the same code share one.

The full contract is in [task-spec.md](task-spec.md#surfaces).

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

forge runs inside your Claude Code session rather than as a separate service, so
the `budget` block controls only the pipeline's behavior, not spending:

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

`gate` is the one exception to "unmapped inherits the session model": the
[artifact gate](task-spec.md#the-artifact-gate) runs a single script and returns
its JSON, so it defaults to `haiku` regardless of the session model. Map it
explicitly to override that.

`opus` is reserved for explicit tier-2 overrides and should rarely be a phase
default. `validate-config.sh` warns if any phase model is `opus`.

---

## The integration branch

By default forge never merges: every task opens its own PR and a human merges it.
Setting `integration_branch` trades that for one reviewable roll-up:

```yaml
integration_branch: forge/integration
```

With it set, the integrate phase pushes the task branch, **merges it into that
branch**, and keeps a single open PR from it into the base. Overnight tasks stack
up and compound there, conflicts get resolved against a branch that does not
matter, and in the morning there is one PR to review: `forge/integration -> develop`.
Such tasks finish at the `merged` state rather than `pr_open`, and the `pr_url`
they report is the shared roll-up PR.

A conflicting merge is **aborted and reported as blocked**, never guessed at. The
task's own branch is pushed and intact either way, so nothing is lost: a human
resolves the conflict on the integration branch.

Constraints, all enforced by `validate-config.sh`:

- It must not be `main` or `master`, and must not equal `base_branch` - forge
  merges into it unreviewed, so it has to be disposable.
- It must not appear in `protected_branches`. The protected list always wins, so
  a protected integration branch would just make every merge fail.

The guardrail's merge exception is scoped to exactly this: a `git merge` is
allowed only while the configured integration branch is the one checked out.
Everything else - merges on any other branch, `gh pr merge`, `gh api .../merges`,
force-pushes, pushes to protected branches - stays blocked. With no
`integration_branch` configured, every merge is blocked exactly as before.

Because parallel tasks cannot all check out the integration branch at once, the
merge runs in one dedicated worktree serialized by a lock file
(`.forge/integration.lock`). If a run is killed mid-merge, remove that directory.

## Guardrail integration

`protected_branches` in this config is the single source of truth for the git
guardrail. The guardrail hook (`hooks/block-git-writes.sh`) resolves its
protected list in priority order:

1. `protected_branches` from `.forge/config.yaml`.
2. The `FORGE_PROTECTED_BRANCHES` environment variable.
3. The hardcoded default `[main, master, develop]`.

An empty or absent config list falls through to the next source, so the default
always protects (fail safe). The config is read relative to the hook's cwd, and
when that cwd is a task worktree - which has no `.forge/` of its own - the hook
resolves the main checkout instead, so a scoped list still applies to every
parallel task.

Because every forge working branch is named `forge/<type>/<id>-<slug>`, it can
never equal a protected branch name, so the guardrail never blocks legitimate
forge work.

**Scoping the list is a real loosening, so do it deliberately.** A branch left
out of `protected_branches` becomes pushable and committable by forge agents. If
you narrow the list to `[main]`, agents can push `develop` directly. Narrow it
only where you want that, and keep GitHub branch protection as the backstop - it
is the authoritative control, and the hook is defense in depth in front of it.

---

## Validation

```
scripts/validate-config.sh .forge/config.yaml
```

Errors fail the run (non-zero exit): missing required fields, wrong `version`,
bad enum values (`profile`, `vcs.host`, `vcs.cli`, `autonomy.default_tier`, task
types in `require_gate`, model phase keys), a non-positive `budget.max_attempts`,
a negative `review_threshold_lines`, and malformed `protected_branches` or
`review_lenses`. Warnings are advisory and do not fail: an empty `commands.test`,
a phase model set to `opus`, an unrecognized model string, and `vcs.cli`
inconsistent with `host`. When the python `jsonschema` library is available, a
full Draft 2020-12 validation runs as well.
