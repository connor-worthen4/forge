---
description: Report that the forge plugin is installed and loaded, print its version, and list which component directories are present.
allowed-tools: Bash, Read
---

You are running the forge plugin's install health check. This is a status report only: do not perform any other work, do not modify files, and do not run any pipeline.

The plugin's installed directory is available in the environment variable `CLAUDE_PLUGIN_ROOT`.

Do exactly the following, then stop:

1. Confirm that the forge plugin is installed and loaded.
2. Read `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` and report the plugin's `name` and `version` fields exactly as found.
3. Check which of these component directories exist directly under `${CLAUDE_PLUGIN_ROOT}`, and report each as present or missing: `commands/`, `agents/`, `skills/`, `hooks/`.
4. Print a short summary in exactly this shape and nothing else:

   ```
   forge plugin: loaded
   version: <version>
   components: commands [present|missing], agents [present|missing], skills [present|missing], hooks [present|missing]
   ```

Report only the facts above. Add no further commentary.
