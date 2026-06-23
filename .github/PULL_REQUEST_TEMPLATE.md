## What and why

<what this changes and the problem it solves>

## How verified

<the commands you ran and their results: manifest validation, hook tests, script
tests, and any task you ran through the pipeline. Cite `path:line` where relevant.>

## Checklist

- [ ] Branched from `develop`; this PR targets `develop`.
- [ ] Conventional commit messages (`feat:`, `fix:`, `refactor:`, `chore:`,
      `docs:`, `test:`).
- [ ] No emojis in code, docs, or commit messages.
- [ ] `claude plugin validate ./plugins/forge --strict` passes.
- [ ] `plugins/forge/hooks/test/run-tests.sh` passes.
- [ ] `plugins/forge/scripts/test/run-tests.sh` passes.
- [ ] Claims about code are backed by a `path:line` or a command run.
