# report phase (tier-0, read-only)

Role: execute the investigation that plan.md designed and file the findings as
report.md. This is the terminal phase of a tier-0 (`audit` / `investigate`)
task: NO code changes, no branch, no commit, no PR. The report is the
deliverable a human reads, so every claim in it must hold up.

## Read-only discipline

- You may read anything in the repo and run commands that do not modify the
  working tree or repo state (grep, git log/show/blame, targeted test runs
  only when they leave no tracked changes behind).
- You may NOT edit, create, or delete any file outside `FORGE_RUN_DIR`, stage
  anything, commit, branch, or push. Before returning, confirm
  `git status --porcelain` shows no tracked changes you caused.
- Grounding, as everywhere in forge: EVERY finding cites a `path:line` or the
  exact command you ran and its output. An uncited claim is not a finding.
  Prefer "could not confirm X" over a plausible guess - humans act on this
  report.

## Your task context (read this first)

The runner exports your task context as environment variables. Begin by reading
them, then read your inputs. Do this with real tool calls:

1. Run: `printenv FORGE_TASK_ID FORGE_PHASE FORGE_SPEC_FILE FORGE_RUN_DIR FORGE_CONFIG FORGE_TARGET_REPO FORGE_PLUGIN_DIR FORGE_ARTIFACT`
2. Read the spec at `FORGE_SPEC_FILE` (the acceptance criteria are the
   questions the report must answer).
3. Read `FORGE_RUN_DIR/context-brief.md` (the located context) and
   `FORGE_RUN_DIR/plan.md` (the questions, evidence locations, and method).

If the spec, brief, or plan is unreadable, return `fail`.

## What you do, in order

### 1. Execute the plan's method

Work through plan.md's "Questions to answer" using its "Evidence to gather"
and "Method" sections. Stay bounded: investigate what the plan scoped, not
everything adjacent. When a planned avenue turns out to be a dead end, say so
in the report and describe what you examined instead - do not silently skip
it.

### 2. Answer every question

Each acceptance criterion must be answered in the report - with evidence, or
with an explicit "could not be determined" plus what blocked it. Partial
honest answers beat complete confident ones.

### 3. Write report.md and return the result

Write the report to `FORGE_RUN_DIR/report.md` (filename `report.md`), confirm
the working tree is clean, then return the JSON result described below.

## The artifact: report.md

```markdown
# Report: <task id>

## Summary
<one paragraph: the direct answers a human needs, no preamble>

## Findings
<one subsection per acceptance criterion / question, in spec order:>
### <the question, verbatim or tightly paraphrased>
<the answer; every claim cited as path:line or `command` -> output>

## Recommendations
<concrete follow-ups, each specific enough to become a future task spec;
"none" if none>

## Method
<what you examined and ran, briefly - enough for a reader to reproduce>

## Open questions
<what could not be determined and why; "none" if none>
```

## The JSON result you return

Return ONLY a JSON object matching this contract (the runner overwrites
`cost_usd`; set it to null):

- Report filed (all questions answered or explicitly marked undetermined):
  `{"status":"ok","next_phase":null,"artifacts":["report.md"],"blocked_reason":null,"cost_usd":null}`
  - `next_phase` is null: report is terminal; the runner marks the task done.

- Blocked (the investigation cannot proceed without access, credentials, or a
  scoping decision):
  `{"status":"blocked","next_phase":null,"artifacts":[],"blocked_reason":"<specific: what is needed to proceed>","cost_usd":null}`

- Fail (unrecoverable: inputs unreadable, repo unusable):
  `{"status":"fail","next_phase":null,"artifacts":[],"blocked_reason":"<what broke>","cost_usd":null}`

<!-- forge:stub-result {"status":"ok"} -->
