# Roadmap

Forge brings no project knowledge of its own; the target repository provides it.
The pipeline gathers that context progressively: intake inventories the repo's
standing guidance (CLAUDE.md, repo-local skills and agents, contributing and design
docs, linter rules) and records the task-relevant pieces as pointers in the context
brief, then plan and build invoke the repo's skills to do the work the way the repo
prescribes.

The items below extend that model. They are not yet implemented; this file records
the intent so it survives across contributors.

## Declarative repo context sources in config

Today intake discovers standing context heuristically. A repo that wants
determinism has no way to tell forge "always read these first."

Add an optional `context:` block to `.forge/config.yaml`, for example:

    context:
      read_first:            # authoritative docs every phase should consult
        - docs/architecture.md
        - CONTRIBUTING.md
      skills:                # repo skills that govern how changes are made
        - db-migration
        - component-scaffold

The config schema is currently closed (`additionalProperties: false`), so this
needs a schema addition in `plugins/forge/schema/project-config.schema.json`,
matching docs in `plugins/forge/docs/project-config.md`, and intake honoring the
declared sources alongside (and ahead of) its heuristic inventory. Discovery stays
the fallback for repos that declare nothing.

## Repo-based detection of commands and lint rules

Build, test, lint, and typecheck come only from the config `commands` block. If a
field is empty the verify phase runs nothing for it, and coding style is inferred
from surrounding code rather than from the repo's actual rule files.

Add a detection fallback so a repo with no (or partial) `commands` config still
gets sensible behavior:

- Detect commands from `package.json` scripts, `Makefile`, `pyproject.toml`,
  `Cargo.toml`, or CI config when the corresponding `commands` field is empty.
- Read the repo's linter/formatter rule files (`.eslintrc*`, `ruff.toml`,
  `.editorconfig`, `.prettierrc`) so build writes and review judges against the
  real rules instead of inferring them from nearby code.

Detected values belong in the context brief as pointers (what was found and
where), and must never silently override an explicit config value: config always
wins, detection only fills gaps.

## Principle that governs all of the above

Standing context, whether declared or detected, is a pointer to verify against the
code, never ground truth. Every phase keeps its grounding discipline: a claim about
the codebase is backed by a `path:line` or a command that was run. A convention doc
or skill shapes how work is done; it does not replace reading the code.
