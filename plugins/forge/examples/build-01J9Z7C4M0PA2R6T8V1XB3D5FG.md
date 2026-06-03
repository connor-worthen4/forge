---
id: build-01J9Z7C4M0PA2R6T8V1XB3D5FG
title: Add OAuth2 device-code login flow to the CLI
type: build
autonomy_tier: 2
priority: P0
base_branch: develop
scope:
  - src/cli/auth/
  - src/cli/commands/login.ts
  - docs/auth.md
constraints:
  - Do not store refresh tokens in plaintext on disk
  - Reuse the existing token cache abstraction; do not add a second one
  - Public CLI flags must remain backward compatible
context_refs:
  - https://www.rfc-editor.org/rfc/rfc8628
  - docs/architecture/auth.md
  - https://github.com/example/app/pull/611
source:
  kind: notion
  ref: https://www.notion.so/example/Device-Code-Login-2f1c
acceptance_criteria:
  - "Running `app login` initiates the device-code flow and prints a verification URL and user code"
  - The CLI polls the token endpoint and stores the resulting token via the existing cache abstraction
  - Tokens at rest are encrypted, and a test asserts no plaintext token is written to disk
  - "`app login --help` documents the new flow and exits with code 0"
  - An integration test covers the full device-code happy path against a mock identity provider
---

Implement the OAuth2 device authorization grant (RFC 8628) as a new login mode
for the CLI, so users on headless machines can authenticate by visiting a URL on
another device.

Because this touches authentication and token storage, it is a tier-2 task:
produce a plan and pause for human approval before writing any code. The plan
should call out where tokens are encrypted, how the polling interval and timeout
are bounded, and how failures (expired code, denied consent) are surfaced to the
user.
