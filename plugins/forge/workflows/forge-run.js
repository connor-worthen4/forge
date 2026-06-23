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
//     config: { base_branch, vcs:{host,cli,pr_target}, commands:{...},
//               autonomy:{default_tier, require_gate}, budget:{max_attempts, models:{...}},
//               review_lenses?:[...] },
//     tasks: [ { taskId, type, autonomy_tier|null, title, branch, specFile|null,
//                goal|null, runDir, mode:"existing"|"greenfield",
//                approved?, replanFeedback?, startPhase? } ]
//   }
// Returns: { results: [ { taskId, tier, final, prUrl, branch, reason } ] }
//   where final is one of: done | pr_open | plan_gate | blocked | failed.

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

// Phase agents are registered by this plugin, so their agent-type names are
// namespaced by the plugin name: agents/forge-intake.md -> "forge:forge-intake".
// Keep this prefix in sync with the plugin name in .claude-plugin/plugin.json.
const AGENT_NS = 'forge:'

const ok = (r) => r && r.status === 'ok'
const isBlocked = (r) => r && r.status === 'blocked'
const q = (v) => (v ? JSON.stringify(v) : '(unset)')

// audit/investigate are always read-only tier 0; require_gate forces tier 2;
// otherwise the spec's own tier, then the config default. Mirrors the rule the
// intake agent records in the brief.
function effectiveTier(task) {
  if (task.type === 'audit' || task.type === 'investigate') return 0
  if (requireGate.includes(task.type)) return 2
  return task.autonomy_tier != null ? task.autonomy_tier : defaultTier
}

// The per-task context every agent needs, in place of the old FORGE_* env vars.
// Paths are absolute so the agent can read the spec/config/prior artifacts and
// write its artifact without any ambiguity about where it is running.
function contextBlock(task, tier, attempt) {
  const cli = vcs.cli || (vcs.host === 'gitlab' ? 'glab' : 'gh')
  const lines = [
    `Task id: ${task.taskId}`,
    `Type: ${task.type}   Effective tier: ${tier}   Mode: ${task.mode}   Attempt: ${attempt}`,
    `Working directory (the target repo, your cwd): ${args.repoRoot}`,
    `Run dir (write your artifact here): ${task.runDir}`,
    `Forge plugin dir (its scripts/ live here): ${args.pluginRoot}`,
    `Base branch: ${baseBranch}`,
    `Working branch: ${task.branch || '(none - tier-0 read-only)'}`,
    `Commands: test=${q(commands.test)} build=${q(commands.build)} lint=${q(commands.lint)} typecheck=${q(commands.typecheck)}`,
    `VCS: host=${vcs.host || 'github'} cli=${cli} pr_target=${vcs.pr_target || baseBranch}`,
  ]
  if (task.specFile) lines.push(`Task spec file (read this in full first): ${task.specFile}`)
  if (task.goal) lines.push(`Goal (greenfield, no spec file - this prompt is the whole task): ${task.goal}`)
  if (task.replanFeedback) lines.push(`RE-PLAN: a human reviewed your previous plan and requires these changes: ${task.replanFeedback}`)
  return lines.join('\n')
}

function runPhase(phase, task, tier, attempt) {
  const opts = { label: `${phase}:${task.taskId}`, phase, agentType: `${AGENT_NS}forge-${phase}`, schema: RESULT }
  if (models[phase]) opts.model = models[phase]
  return agent(
    `You are the forge ${phase} phase. Your role, discipline, and output contract are in your ` +
      `agent instructions; follow them exactly. This task's context:\n\n${contextBlock(task, tier, attempt)}\n\n` +
      `Do your phase's work now, write your artifact into the run dir, and return the result object.`,
    opts,
  )
}

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
  const tier = effectiveTier(task)
  const out = { taskId: task.taskId, tier, final: null, phase: 'intake', prUrl: null, branch: tier === 0 ? null : task.branch, reason: null }
  const startPhase = task.startPhase || (task.approved ? 'build' : 'intake')

  // Tier 0: read-only investigation -> report -> done.
  if (tier === 0) {
    const i = await runPhase('intake', task, tier, 1)
    if (!ok(i)) return endNonOk(out, i, 'intake')
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

    const v = await runPhase('verify', task, tier, attempt)
    if (isBlocked(v)) return park(out, v, 'verify')
    if (!ok(v)) {
      if (++attempt > maxAttempts) return park(out, v, 'verify', `verify failed; max_attempts (${maxAttempts}) reached`)
      continue
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

const results = []
for (const task of tasks) {
  log(`forge: ${task.taskId} (${task.type}, ${task.mode}) starting`)
  let outcome
  try {
    outcome = await runTask(task)
  } catch (e) {
    outcome = {
      taskId: task.taskId,
      final: 'failed',
      phase: 'intake',
      prUrl: null,
      branch: null,
      reason: `workflow error: ${e && e.message ? e.message : e}`,
    }
  }
  results.push(outcome)
  log(`forge: ${task.taskId} -> ${outcome.final}${outcome.reason ? ' (' + outcome.reason + ')' : ''}`)
}

return { results }
