# Security Policy

## Supported versions

Forge is distributed as a Claude Code plugin and versioned in
`plugins/forge/.claude-plugin/plugin.json`. Security fixes target the latest
release on the `main` branch; older versions are not maintained.

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/connor-worthen4/forge/security/advisories/new)
(the **Security** tab, then **Report a vulnerability**). Include:

- a description of the issue and its impact,
- steps to reproduce or a proof of concept,
- the affected files or commands, and any suggested remediation.

Expect an initial response within a few days. Once a fix is available we will
coordinate disclosure with you.

## Scope and design notes

Forge runs entirely inside your Claude Code session and operates on your local
repository. Two safeguards are central to its threat model, and reports that
bypass them are especially valuable:

- A PreToolUse guardrail hook (`plugins/forge/hooks/block-git-writes.sh`) blocks
  merges and pushes to protected branches.
- Forge opens pull requests and stops; it never merges. A human reviews and
  merges every change.

Forge stores no credentials; it shells out to your already-authenticated `git`,
`gh`/`glab`, and test tooling. Findings that could cause forge to write to a
protected branch, push without review, exfiltrate repository contents, or run
unintended commands are in scope.
