---
id: fix-01J9Z6Q9H7K3M2N5P8R4T6V0XA
title: Retry transient HTTP 503s in the API client
type: fix
autonomy_tier: 1
priority: P1
base_branch: develop
scope:
  - src/api/client.ts
  - src/api/retry.ts
constraints:
  - Keep the public client interface unchanged
  - No new third-party dependencies
  - Minimal diff
context_refs:
  - https://github.com/example/app/issues/482
  - src/api/README.md
source:
  kind: issue
  ref: https://github.com/example/app/issues/482
acceptance_criteria:
  - GET and POST requests that receive a 503 are retried up to 3 times with exponential backoff
  - Retries stop immediately on any 2xx or 4xx response
  - A unit test covers the 503-then-200 path and asserts exactly two retries occurred
  - The existing API client test suite still passes
---

The API client surfaces transient 503s from the upstream gateway directly to
callers, causing intermittent failures during deploys when the gateway briefly
sheds load. Add bounded retry with exponential backoff for idempotent requests,
without changing the client's public surface.

Backoff should be jittered to avoid synchronized retry storms across clients.
Non-idempotent requests must not be retried automatically.
