# Forge examples

Copy-paste starting points for the two things you write by hand: a project
config (`.forge/config.yaml`) and task specs (`tasks/<id>.md`).

## Project configs

| File | What it shows |
| ---- | ------------- |
| [`config.minimal.yaml`](config.minimal.yaml) | The smallest valid config — only the required fields. Everything else falls back to the engine defaults. Start here. |
| [`config.full.yaml`](config.full.yaml) | Every option, annotated: protected branches, build/test/lint/typecheck commands, autonomy gating, review lenses, the retry cap, and per-phase model selection. |

Copy one to `.forge/config.yaml` in your repo and set the `commands` to match how
your project builds and tests. Validate it from the repo root with:

    plugins/forge/scripts/validate-config.sh .forge/config.yaml

## Task specs

Each spec is one markdown file: YAML frontmatter (the structured fields) plus a
free-form prose ask. The three here cover one task of each pipeline shape:

| File | Type | Tier | What it demonstrates |
| ---- | ---- | ---- | -------------------- |
| [`fix-01J9Z6Q9H7K3M2N5P8R4T6V0XA.md`](fix-01J9Z6Q9H7K3M2N5P8R4T6V0XA.md) | `fix` | 1 | The default path: branch → build → verify → review → PR. Scoped files, explicit constraints, and concrete acceptance criteria. |
| [`build-01J9Z7C4M0PA2R6T8V1XB3D5FG.md`](build-01J9Z7C4M0PA2R6T8V1XB3D5FG.md) | `build` | 2 | A gated feature: forge plans, then pauses at the plan gate for `/forge:approve` before writing any code. |
| [`audit-01J9Z71F2C8B6D4G0H3J5K7M9N.md`](audit-01J9Z71F2C8B6D4G0H3J5K7M9N.md) | `audit` | 0 | Read-only investigation: no branch, no PR — produces a `report.md` and stops. |

Drop specs into a `tasks/` directory in your repo, then run one with
`/forge:run <id>` or the whole queue with `/forge:run-all`. Validate a spec with:

    plugins/forge/scripts/validate-task.sh tasks/<id>.md

The full field reference is in [`../docs/task-spec.md`](../docs/task-spec.md); the
schema is [`../schema/task-spec.schema.json`](../schema/task-spec.schema.json).

> The ids here are illustrative ULIDs and the `src/...` paths point at a
> fictional app. Replace them with a real id (`/forge:draft` mints one for you)
> and real paths from your own repo before running.
