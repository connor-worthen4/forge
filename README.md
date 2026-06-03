# Forge

Raw task in, tempered PR out — an agentic software factory for Claude Code, portable across any repo.

Forge is a portable Claude Code plugin. Tasks flow through an agent pipeline — intake, plan, build, verify, review, integrate — and land as a pull request into the `develop` branch. Forge never merges; a human always reviews and merges the PR.

The engine is generic and reusable across projects. Project-specific configuration lives in each target repository's `.claude/` directory, not in this repository.

## Status

Early scaffolding (v0.1.0). This repository currently contains the plugin skeleton and a single status command used to confirm the plugin installs and loads. Pipeline logic, agents, skills, and hook guardrails are not implemented yet.

## Repository layout

    .claude-plugin/
      marketplace.json        # marketplace catalog; lists the forge plugin
    plugins/
      forge/
        .claude-plugin/
          plugin.json         # plugin manifest
        commands/             # slash commands
        agents/               # subagents (empty for now)
        skills/               # skills (empty for now)
        hooks/                # hook configuration (empty for now)

The marketplace manifest sits at the repository root so additional plugins can be added under `plugins/` later without restructuring.

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

3. Confirm it loaded:

   ```
   /forge-status
   ```

## Develop loop

For live iteration without installing, load the plugin directory directly:

```
claude --plugin-dir /absolute/path/to/forge/plugins/forge
```

Changes to commands, agents, skills, and hooks are picked up on the next session.

Validate the manifests before committing:

```
claude plugin validate ./plugins/forge --strict
```

## Branches

- `main` — stable baseline.
- `develop` — integration target. The factory opens pull requests against `develop`; a human reviews and merges them.
