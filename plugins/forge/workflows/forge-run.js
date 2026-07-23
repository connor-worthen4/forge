// forge-run.js - the forge per-task pipeline as a Claude Code Workflow.
//
// This is the pipeline orchestrator. It is launched from a live Claude Code
// session by the /forge:run and /forge:run-all slash commands, which read the
// project config and task specs, then invoke this script with
// Workflow({scriptPath, args}).
//
// The script runs in a sandbox: no filesystem, no clock, no randomness. It
// owns control flow only. Everything that touches disk is done by the phase
// AGENTS it spawns (they have real tools): they read the spec/config/prior
// artifacts and write their own artifact into the run dir. After this workflow
// returns, the launcher stamps queue.json / run.json from the returned results.
//
// args shape (assembled by the launcher):
//   {
//     pluginRoot, repoRoot,
//     config: { base_branch, profile, review_threshold_lines, surfaces?:[...],
//               vcs:{host,cli,pr_target}, commands:{...},
//               autonomy:{default_tier, require_gate}, budget:{max_attempts, models:{...}},
//               review_lenses?:[...] },
//     tasks: [ { taskId, type, autonomy_tier|null, profile|null, hasAcceptanceCriteria,
//                contextCacheFresh, surface|null, worktree|null, title, branch,
//                specFile|null, goal|null, runDir, mode:"existing"|"greenfield",
//                approved?, replanFeedback?, startPhase? } ]
//   }
// Returns: { results: [ { taskId, profile, surface, tier, final, prUrl, branch,
//                         stackedOn, reason } ] }
//   where final is one of: done | pr_open | plan_gate | blocked | failed.
//
// Surfaces decide the run's concurrency. Tasks declaring the same `surface`
// touch the same area of the system, so they run serially and STACKED - each
// cuts its branch from the previous one's, keeping their diffs linear instead of
// letting two branches edit the same files beside each other and collide the
// moment one merges. Tasks on different surfaces cannot collide by construction,
// so their groups run in parallel, each task in its own git worktree (the
// launcher allocates one whenever a run has more than one group).

export const meta = {
  name: 'forge-run',
  description: 'Run forge tasks through intake -> plan -> build -> verify -> review -> integrate',
  phases: [
    { title: 'intake' }, { title: 'plan' }, { title: 'build' },
    { title: 'verify' }, { title: 'review' }, { title: 'integrate' }, { title: 'report' },
  ],
}

// The structured result every phase agent returns. Validated at the tool layer,
// so an agent that returns the wrong shape is retried automatically.
const RESULT = {
  type: 'object',
  additionalProperties: false,
  required: ['status', 'next_phase', 'artifacts', 'blocked_reason'],
  properties: {
    status: { enum: ['ok', 'blocked', 'fail'] },
    next_phase: { type: ['string', 'null'] },
    artifacts: { type: 'array', items: { type: 'string' } },
    blocked_reason: { type: ['string', 'null'] },
    pr_url: { type: ['string', 'null'] },
    // Changed lines in the branch diff, copied by verify out of the checks.json
    // that forge-checks.sh wrote. The fast profile's review-skip decision reads
    // it; a script measured it, so no model is estimating diff size.
    diff_lines: { type: ['integer', 'null'] },
  },
}

// Findings contract for review lens agents (used only when review_lenses is set).
const FINDINGS = {
  type: 'object',
  additionalProperties: false,
  required: ['lens', 'findings'],
  properties: {
    lens: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['severity', 'location', 'issue'],
        properties: {
          severity: { enum: ['blocker', 'major', 'minor'] },
          location: { type: 'string' },
          issue: { type: 'string' },
          fix: { type: ['string', 'null'] },
        },
      },
    },
  },
}

// The Workflow harness may hand the script its args as a JSON string rather
// than a parsed object. Normalize up front so every args.* read below works
// whether the launcher passed an object or a serialized string.
if (typeof args === 'string') {
  try { args = JSON.parse(args) } catch (e) { args = {} }
}

const cfg = args.config || {}
const budget = cfg.budget || {}
const models = budget.models || {}
const maxAttempts = budget.max_attempts || 2
const autonomy = cfg.autonomy || {}
const requireGate = Array.isArray(autonomy.require_gate) ? autonomy.require_gate : ['build']
const defaultTier = autonomy.default_tier != null ? autonomy.default_tier : 1
const baseBranch = cfg.base_branch || 'develop'
const commands = cfg.commands || {}
const vcs = cfg.vcs || {}
const reviewLenses = Array.isArray(cfg.review_lenses) && cfg.review_lenses.length ? cfg.review_lenses : null

// Profiles are the pipeline SHAPE, orthogonal to the autonomy tier (which is
// about human approval). standard is the full pipeline; fast trims the ceremony
// a small, well-specified task does not need; audit is the read-only path.
const PROFILES = ['fast', 'standard', 'audit']
const defaultProfile = PROFILES.includes(cfg.profile) ? cfg.profile : 'standard'
const reviewThresholdLines =
  Number.isInteger(cfg.review_threshold_lines) && cfg.review_threshold_lines >= 0
    ? cfg.review_threshold_lines
    : 400

// Phase agents are registered by this plugin, so their agent-type names are
// namespaced by the plugin name: agents/forge-intake.md -> "forge:forge-intake".
// Keep this prefix in sync with the plugin name in .claude-plugin/plugin.json.
const AGENT_NS = 'forge:'

const ok = (r) => r && r.status === 'ok'
const isBlocked = (r) => r && r.status === 'blocked'
const q = (v) => (v ? JSON.stringify(v) : '(unset)')

// The spec's own profile wins over the repo default; an unrecognized value falls
// back to standard rather than failing the run (validate-task.sh rejects it at
// the door). The launcher resolves this too - re-resolving here keeps the
// workflow correct when args arrive from an older launcher.
function effectiveProfile(task) {
  if (PROFILES.includes(task.profile)) return task.profile
  return defaultProfile
}

// The audit profile and the audit/investigate task types are both read-only
// tier 0; require_gate still forces tier 2 even under fast, because that gate is
// an explicit human-approval policy and profiles only trim ceremony, never
// approval. Otherwise the spec's own tier, then the config default. Mirrors the
// rule the intake agent records in the brief.
function effectiveTier(task, profile) {
  if (profile === 'audit') return 0
  if (task.type === 'audit' || task.type === 'investigate') return 0
  if (requireGate.includes(task.type)) return 2
  return task.autonomy_tier != null ? task.autonomy_tier : defaultTier
}

// The per-task context every agent needs, in place of the old FORGE_* env vars.
// Paths are absolute so the agent can read the spec/config/prior artifacts and
// write its artifact without any ambiguity about where it is running.
function contextBlock(task, tier, attempt) {
  const cli = vcs.cli || (vcs.host === 'gitlab' ? 'glab' : 'gh')
  // A stacked task cuts from its predecessor's branch instead of the project
  // base, so its branch already contains that work and the two can never
  // collide. Everything downstream - the diff, the PR target - follows from it.
  const effectiveBase = task.stackBase || baseBranch
  const lines = [
    `Task id: ${task.taskId}`,
    `Type: ${task.type}   Effective tier: ${tier}   Profile: ${effectiveProfile(task)}   Mode: ${task.mode}   Attempt: ${attempt}`,
    `Working directory (the target repo, your cwd): ${task.worktree || args.repoRoot}`,
    `Run dir (write your artifact here): ${task.runDir}`,
    `Forge plugin dir (its scripts/ live here): ${args.pluginRoot}`,
    `Base branch: ${effectiveBase}`,
    `Working branch: ${task.branch || '(none - tier-0 read-only)'}`,
    `Surface: ${task.surface || '(none - this task runs on its own)'}`,
    `Commands: test=${q(commands.test)} build=${q(commands.build)} lint=${q(commands.lint)} typecheck=${q(commands.typecheck)}`,
    `VCS: host=${vcs.host || 'github'} cli=${cli} pr_target=${vcs.pr_target || baseBranch}`,
  ]
  if (task.worktree) {
    lines.push(
      `WORKTREE: other tasks are running at the same time, so this task works in its own ` +
        `git worktree instead of the main checkout. Before anything else, run:\n` +
        `  bash "${args.pluginRoot}/scripts/forge-worktree.sh" add ${task.taskId} ` +
        `--branch ${task.branch} --base ${effectiveBase}\n` +
        `then cd into the path it prints and do ALL of your work there. The command is ` +
        `idempotent - it reuses the tree if an earlier phase already created it, so run it ` +
        `regardless of which phase you are. Never work in the main checkout: another task ` +
        `has its own branch checked out there.`,
    )
  }
  if (task.stackBase) {
    lines.push(
      `STACKED: this task shares surface "${task.surface}" with an earlier task in this run, ` +
        `so it is stacked on ${task.stackBase}. That branch is your authoritative base - cut ` +
        `from it and target it, overriding the usual base resolution. Its commits are part of ` +
        `your starting point: build on top of them rather than reimplementing or reverting them.`,
    )
  }
  if (task.specFile) lines.push(`Task spec file (read this in full first): ${task.specFile}`)
  if (task.goal) lines.push(`Goal (greenfield, no spec file - this prompt is the whole task): ${task.goal}`)
  if (task.replanFeedback) lines.push(`RE-PLAN: a human reviewed your previous plan and requires these changes: ${task.replanFeedback}`)
  return lines.join('\n')
}

function runPhase(phase, task, tier, attempt, note) {
  const opts = { label: `${phase}:${task.taskId}`, phase, agentType: `${AGENT_NS}forge-${phase}`, schema: RESULT }
  if (models[phase]) opts.model = models[phase]
  return agent(
    `You are the forge ${phase} phase. Your role, discipline, and output contract are in your ` +
      `agent instructions; follow them exactly. This task's context:\n\n${contextBlock(task, tier, attempt)}\n\n` +
      (note ? `${note}\n\n` : '') +
      `Do your phase's work now, write your artifact into the run dir, and return the result object.`,
    opts,
  )
}

// Under the fast profile verify is the script's verdict, not a model's:
// forge-checks.sh runs the configured commands and its `overall` maps straight
// through. The per-criterion grading pass is exactly the ceremony this profile
// trades away, on the premise that fast work is small and well specified.
const SCRIPT_VERIFY_NOTE =
  'Run in SCRIPT mode (fast profile). forge-checks.sh IS the verdict: run it once, write a ' +
  'compact verify.md summarizing the checks.json it produced, and map its `overall` field ' +
  'straight through (pass -> ok, fail or empty-diff -> fail, blocked -> blocked). Do NOT grade ' +
  'the acceptance criteria one by one. Still report checks.json\'s `diff_lines` in your result.'

// Review either as a single skeptical agent (default) or, when config sets
// review_lenses, as parallel lens reviewers whose findings a synth agent
// consolidates into review.md. The fan-out is the Workflow payoff: independent
// lenses run concurrently and cannot see each other's rationalizations.
async function runReview(task, tier, attempt) {
  if (!reviewLenses) return runPhase('review', task, tier, attempt)
  const lensFindings = (
    await parallel(
      reviewLenses.map((lens) => () =>
        agent(
          `You are the forge review phase in LENS mode for the "${lens}" lens ONLY. ` +
            `Context:\n\n${contextBlock(task, tier, attempt)}\n\n` +
            `Take the branch diff yourself and review it through the ${lens} lens only. ` +
            `Do NOT write review.md. Return the findings object (lens + findings array).`,
          { label: `review:${lens}:${task.taskId}`, phase: 'review', agentType: `${AGENT_NS}forge-review`, schema: FINDINGS },
        ),
      ),
    )
  ).filter(Boolean)
  return agent(
    `You are the forge review phase in SYNTH mode. Context:\n\n${contextBlock(task, tier, attempt)}\n\n` +
      `Independent lens reviewers produced these findings:\n${JSON.stringify(lensFindings)}\n\n` +
      `Consolidate and de-duplicate them, confirm every blocker/major against the diff yourself, ` +
      `write review.md into the run dir, and return the result object. PASS only if no blocker or major survives.`,
    { label: `review:synth:${task.taskId}`, phase: 'review', agentType: `${AGENT_NS}forge-review`, schema: RESULT },
  )
}

function endNonOk(out, r, phase) {
  out.final = isBlocked(r) ? 'blocked' : 'failed'
  out.phase = phase
  out.reason = (r && r.blocked_reason) || `${out.final} at ${phase}`
  return out
}

function park(out, r, phase, reason) {
  out.final = 'blocked'
  out.phase = phase
  out.reason = reason || (r && r.blocked_reason) || `blocked at ${phase}`
  return out
}

async function runTask(task) {
  const profile = effectiveProfile(task)
  const tier = effectiveTier(task, profile)
  const out = { taskId: task.taskId, profile, tier, final: null, phase: 'intake', prUrl: null, branch: tier === 0 ? null : task.branch, reason: null }

  // The fast profile skips intake when the spec already states its acceptance
  // criteria: pinning down exactly that is intake's job, so there is nothing
  // left for it to establish. A greenfield goal prompt carries no criteria and
  // still runs intake.
  let startPhase = task.startPhase || (task.approved ? 'build' : 'intake')
  if (startPhase === 'intake' && profile === 'fast' && task.hasAcceptanceCriteria) {
    log(`forge: ${task.taskId} fast profile - skipping intake (spec already states acceptance criteria)`)
    startPhase = 'plan'
  } else if (startPhase === 'intake' && task.contextCacheFresh) {
    // A previous run already mapped this task and every file that map cites is
    // byte-identical, so re-deriving it would produce the same brief. The
    // launcher re-hashed those files just now; anything less than a clean match
    // falls through to a full intake.
    log(`forge: ${task.taskId} reusing the cached context brief - skipping intake`)
    startPhase = 'plan'
  }

  // Tier 0 (the audit profile and the audit/investigate types): read-only
  // investigation -> report -> done.
  if (tier === 0) {
    if (startPhase === 'intake') {
      const i = await runPhase('intake', task, tier, 1)
      if (!ok(i)) return endNonOk(out, i, 'intake')
    }
    const p = await runPhase('plan', task, tier, 1)
    if (!ok(p)) return endNonOk(out, p, 'plan')
    const r = await runPhase('report', task, tier, 1)
    if (!ok(r)) return endNonOk(out, r, 'report')
    out.final = 'done'
    out.phase = 'report'
    return out
  }

  // Tier 1 and approved tier 2 share the build/verify/review loop. A fresh
  // tier-2 task parks at the plan gate after plan and waits for /forge:approve.
  if (startPhase === 'intake' || startPhase === 'plan') {
    if (startPhase === 'intake') {
      const i = await runPhase('intake', task, tier, 1)
      if (!ok(i)) return endNonOk(out, i, 'intake')
    }
    const p = await runPhase('plan', task, tier, 1)
    if (!ok(p)) return endNonOk(out, p, 'plan')
    if (tier === 2 && !task.approved) {
      out.final = 'plan_gate'
      out.phase = 'plan'
      return out
    }
  }

  let attempt = 1
  while (true) {
    const b = await runPhase('build', task, tier, attempt)
    if (!ok(b)) return endNonOk(out, b, 'build')

    const v = await runPhase('verify', task, tier, attempt, profile === 'fast' ? SCRIPT_VERIFY_NOTE : null)
    if (isBlocked(v)) return park(out, v, 'verify')
    if (!ok(v)) {
      if (++attempt > maxAttempts) return park(out, v, 'verify', `verify failed; max_attempts (${maxAttempts}) reached`)
      continue
    }

    // The fast profile skips review under the configured line threshold: a small
    // diff has too little surface for an adversarial pass to earn its cost. The
    // count is the one forge-checks.sh measured, not a model's estimate, and a
    // missing count falls through to a full review rather than silently skipping.
    const diffLines = v && typeof v.diff_lines === 'number' ? v.diff_lines : null
    if (profile === 'fast' && diffLines !== null && diffLines < reviewThresholdLines) {
      log(`forge: ${task.taskId} fast profile - skipping review (${diffLines} changed lines < review_threshold_lines ${reviewThresholdLines})`)
      break
    }

    const r = await runReview(task, tier, attempt)
    if (isBlocked(r)) return park(out, r, 'review')
    if (!ok(r)) {
      if (++attempt > maxAttempts) return park(out, r, 'review', `review failed; max_attempts (${maxAttempts}) reached`)
      continue
    }
    break
  }

  const g = await runPhase('integrate', task, tier, attempt)
  if (!ok(g)) return endNonOk(out, g, 'integrate')
  out.final = 'pr_open'
  out.phase = 'integrate'
  out.prUrl = (g && g.pr_url) || null
  return out
}

const tasks = Array.isArray(args.tasks) ? args.tasks : []
if (!tasks.length) {
  log('forge-run: no tasks provided in args.tasks')
  return { results: [] }
}

// A predecessor is only worth stacking on when its branch actually holds
// finished work. A task that died mid-build leaves a branch with half a change
// on it (or none at all); stacking on that would fold unreviewed or broken work
// into the next task's diff, so the successor falls back to the project base.
const STACKABLE = ['pr_open', 'merged']

async function runTaskSafely(task) {
  log(
    `forge: ${task.taskId} (${task.type}, ${effectiveProfile(task)} profile, ${task.mode}` +
      `${task.surface ? `, surface ${task.surface}` : ''}) starting`,
  )
  let outcome
  try {
    outcome = await runTask(task)
  } catch (e) {
    outcome = {
      taskId: task.taskId,
      profile: effectiveProfile(task),
      surface: task.surface || null,
      final: 'failed',
      phase: 'intake',
      prUrl: null,
      branch: null,
      reason: `workflow error: ${e && e.message ? e.message : e}`,
    }
  }
  outcome.surface = task.surface || null
  outcome.stackedOn = task.stackBase || null
  log(`forge: ${task.taskId} -> ${outcome.final}${outcome.reason ? ' (' + outcome.reason + ')' : ''}`)
  return outcome
}

// One surface's tasks, in the stack order the launcher already resolved. They
// run SERIALLY on purpose: each cuts from the previous one's branch, which does
// not exist until that task is done. This is the whole conflict-avoidance
// mechanism - two tasks editing the same area never branch beside each other.
async function runGroup(group) {
  const outcomes = []
  let stackBase = null
  for (const task of group.tasks) {
    if (stackBase) task.stackBase = stackBase
    const outcome = await runTaskSafely(task)
    outcomes.push(outcome)
    if (STACKABLE.includes(outcome.final) && outcome.branch) {
      stackBase = outcome.branch
    } else if (group.tasks.length > 1) {
      // Keep the chain moving on the base rather than stacking on a branch whose
      // task did not finish. Losing the stack is a smaller problem than building
      // on top of work nobody accepted.
      log(
        `forge: ${task.taskId} did not land (${outcome.final}); later "${group.surface}" tasks ` +
          `fall back to ${baseBranch} instead of stacking on it`,
      )
      stackBase = null
    }
  }
  return outcomes
}

// Group by surface, preserving the launcher's order. Tasks without a surface are
// each their own group, so an unlabeled task never waits on anything.
const groupOrder = []
const groupsBySurface = new Map()
for (const task of tasks) {
  const key = task.surface || ` solo:${task.taskId}`
  if (!groupsBySurface.has(key)) {
    groupsBySurface.set(key, { surface: task.surface || null, tasks: [] })
    groupOrder.push(key)
  }
  groupsBySurface.get(key).tasks.push(task)
}
const groups = groupOrder.map((k) => groupsBySurface.get(k))

if (groups.length > 1) {
  log(
    `forge: ${tasks.length} task(s) across ${groups.length} surface group(s) - ` +
      `groups run in parallel, each task in its own worktree`,
  )
}

// Different surfaces cannot collide by construction, so they run concurrently.
// This is the one barrier in the pipeline: every group must finish before the
// launcher can record outcomes and check the results as a set.
const grouped = await parallel(groups.map((g) => () => runGroup(g)))
const results = grouped.filter(Boolean).flat()

return { results }
