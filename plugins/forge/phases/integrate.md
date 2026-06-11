# integrate phase (stub)

Role: push the feature branch and open a PR into base_branch via the configured VCS CLI. NEVER merge. Records the PR url. This is where the git guardrail enforces "no push to a protected branch, no merge".

This is a STUB. In normal operation the runner sends the prose in this file to
`claude -p` as the phase prompt; the real integrate prompt is separate work and
will replace this body. In stub mode the runner records a placeholder PR url so
the pipeline reaches pr_open without performing real git/gh operations.

<!-- forge:stub-result {"status":"ok"} -->
