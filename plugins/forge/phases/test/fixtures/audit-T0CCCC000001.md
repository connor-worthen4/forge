---
id: audit-T0CCCC000001
title: Inventory the forge runner scripts and their external command dependencies
type: audit
autonomy_tier: 0
priority: P2
scope:
  - plugins/forge/scripts/
context_refs:
  - plugins/forge/scripts/forge-lib.sh
acceptance_criteria:
  - Every .sh file under plugins/forge/scripts/ is listed with a one-line description of its purpose
  - For each script, the external commands it shells out to (for example jq, python3, git, claude, gh) are listed
  - The report flags any script that depends on a command not declared in its header comment
  - No source files are modified (read-only audit)
---

Produce a read-only inventory of the runner scripts under
`plugins/forge/scripts/` and the external commands each one depends on, so we can
reason about portability. Do not change any code; only read the scripts and
summarize. Output a markdown table of script -> purpose -> dependencies plus a
short list of any undeclared dependencies.
