---
id: audit-01J9Z71F2C8B6D4G0H3J5K7M9N
title: Audit dependency licenses for copyleft obligations
type: audit
autonomy_tier: 0
priority: P2
scope: unknown - investigate
context_refs:
  - package.json
  - docs/compliance.md
source:
  kind: cli
  ref: "forge: audit dependency licenses"
acceptance_criteria:
  - Every direct and transitive dependency is listed with its resolved SPDX license
  - All copyleft licenses (GPL, AGPL, LGPL, MPL) are flagged with the package that pulls them in
  - The report states whether any license conflicts with redistribution under the project license
  - No source files are modified (read-only audit)
---

Produce a report of all dependency licenses and flag any copyleft obligations
that could affect redistribution of the project. This is a read-only
investigation: do not change any code, only read the dependency manifests and
lockfiles and summarize findings.

Output the report as a markdown table grouped by license family, with a short
"action needed" section listing any packages that require legal review.
