# Contributing to Forge

Thanks for your interest. Forge is a portable Claude Code plugin; this repository
is the engine, and everything project-specific lives in each target repo. Read the
[README](README.md) for the architecture before contributing.

## Ground rules

- No emojis anywhere: code, comments, docs, commit messages, or PR text.
- Stay grounded: claims about code are backed by a real `path:line` or a command
  you ran, never asserted from memory. This is the discipline the pipeline itself
  enforces, and the repo holds itself to it.
- Keep changes to the smallest diff that does the job, and match the surrounding
  style.
- Add error handling with meaningful messages; never leave debug output behind.

## Development loop

Load the plugin directly from a checkout, no install required:

```
claude --plugin-dir /absolute/path/to/forge/plugins/forge
```

Changes to commands, agents, the workflow, and hooks are picked up on the next
session.

## Before you open a PR

Run the manifest validation and both test suites; all must pass:

```
claude plugin validate ./plugins/forge --strict
plugins/forge/hooks/test/run-tests.sh      # guardrail hook unit tests
plugins/forge/scripts/test/run-tests.sh    # launcher script unit tests
```

CI runs the test suites and manifest checks on every pull request.

## Branches and commits

- Cut a branch from `develop`: `feature/<short-description>` or
  `fix/<short-description>`.
- Use conventional commit messages: `feat:`, `fix:`, `refactor:`, `chore:`,
  `docs:`, `test:`.
- Open the PR against `develop` (the integration branch). A maintainer merges
  `develop` into `main`.
- Describe what changed, why, and how you verified it.

## Reporting bugs and proposing features

Use the issue templates. For security issues, follow the
[Security Policy](SECURITY.md) rather than opening a public issue.
