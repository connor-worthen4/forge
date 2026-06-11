# verify phase (stub)

Role: run the project's checks (commands.test/build/lint/typecheck) and grade the change against the acceptance criteria; record a verdict.

This is a STUB. In normal operation the runner sends the prose in this file to
`claude -p` as the phase prompt; the real verify prompt is separate work and will
replace this body. In stub mode the runner uses the canned result below. To
exercise the verify->build recovery loop in tests, set FORGE_STUB_STATUS_verify=fail.

<!-- forge:stub-result {"status":"ok"} -->
