---
id: fix-T1AAAA000001
title: Make config_get fall back to the default on empty-string values
type: fix
autonomy_tier: 1
priority: P1
base_branch: develop
scope:
  - plugins/forge/scripts/forge-lib.sh
constraints:
  - Minimal diff
  - Do not change the config_get signature or its callers
acceptance_criteria:
  - config_get prints the provided default when the requested dotted key is absent from config.yaml
  - config_get prints the provided default when the key exists but resolves to an empty string
  - A test invokes config_get against a fixture config.yaml and asserts both fallback cases
---

The shared `config_get` helper in `forge-lib.sh` is used by every runner script
to read project configuration with a fallback default. Today a key that is
present but set to an empty string prints the empty value instead of the
default, which surprises callers that pass a non-empty default. Make an
empty-string value fall back to the supplied default, exactly as an absent key
does. Keep the change minimal and the function's signature unchanged.
