#!/usr/bin/env bash
#
# forge-context.sh - assemble the `args` payload for the forge-run workflow.
#
# The forge-run.js workflow runs in a sandbox with no filesystem access, so the
# launcher commands (/forge:run, /forge:run-all, /forge:approve) call this script to do
# all the deterministic, disk-touching work up front: resolve the project config,
# pick the task(s), detect greenfield-vs-existing mode, resolve each task's
# profile (spec over repo default) and whether its spec already states acceptance
# criteria, compute branch names, and read each task's run record for
# approval/re-plan state. It prints a single JSON object on stdout, ready to pass
# straight into Workflow({scriptPath, args}).
#
# Usage:
#   forge-context.sh <task-id> [--approved]      single task by id
#   forge-context.sh --all                       every runnable queued task
#   forge-context.sh --goal "<prompt>"           ad-hoc greenfield task (no spec)
#
# --approved marks a tier-2 task whose plan the human accepted (skips to build).
# A plan-feedback.md in the run dir (written by /forge:approve ... changes:)
# triggers a re-plan instead.
#
# Deps: jq, python3 (PyYAML or ruby), git, forge-lib.sh, validate-task.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

usage() {
  echo "usage: forge-context.sh <task-id> [--approved] | --all | --goal \"<prompt>\"" >&2
  exit 2
}

selector=""
goal=""
approved=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) selector="--all"; shift ;;
    --goal) selector="--goal"; goal="${2:-}"; [ -n "$goal" ] || usage; shift 2 ;;
    --approved) approved=1; shift ;;
    -h|--help) usage ;;
    --*) echo "forge-context: unknown flag '$1'" >&2; usage ;;
    *) [ -z "$selector" ] && selector="$1" || usage; shift ;;
  esac
done
[ -n "$selector" ] || usage

# Greenfield when the target is not yet a git repo or has no commit; otherwise
# there is existing context for intake to gather. Mode is a property of the repo,
# not the task.
mode="existing"
if ! git -C "$TARGET" rev-parse --verify HEAD >/dev/null 2>&1; then
  mode="greenfield"
fi

# Collect the task specs as JSON (each is validated frontmatter plus _file).
specs_json="[]"
case "$selector" in
  --all)
    shopt -s nullglob
    files=("$TARGET/tasks/"*.md)
    shopt -u nullglob
    if [ "${#files[@]}" -eq 0 ]; then
      echo "forge-context: no task specs in $TARGET/tasks/" >&2
      exit 1
    fi
    specs_json="$("$PLUGIN_DIR/scripts/validate-task.sh" --json "${files[@]}")" || {
      echo "forge-context: one or more task specs are invalid (see errors above)" >&2
      exit 1
    }
    ;;
  --goal)
    : # synthesized below; no spec file
    ;;
  *)
    spec="$(spec_path "$selector")"
    if [ ! -f "$spec" ]; then
      echo "forge-context: no spec for task '$selector' (looked for $spec)" >&2
      exit 1
    fi
    specs_json="$("$PLUGIN_DIR/scripts/validate-task.sh" --json "$spec")" || {
      echo "forge-context: task spec '$selector' is invalid (see errors above)" >&2
      exit 1
    }
    ;;
esac

# Generate a schema-valid id for an ad-hoc goal (build-adhoc<timestamp>).
adhoc_id="build-adhoc$(date +%Y%m%d%H%M%S)"

python3 - "$selector" "$goal" "$adhoc_id" "$approved" "$mode" "$specs_json" \
         "$CONFIG" "$PLUGIN_DIR" "$TARGET" "$RUNS_DIR" <<'PY'
import sys, os, re, json, subprocess, shutil

(selector, goal, adhoc_id, approved_s, mode, specs_s,
 config_path, plugin_dir, target, runs_dir) = sys.argv[1:11]
approved_flag = approved_s == "1"


def load_yaml(text):
    try:
        import yaml
        return yaml.safe_load(text)
    except ImportError:
        import subprocess
        proc = subprocess.run(
            ["ruby", "-ryaml", "-rjson", "-e",
             "print YAML.safe_load(STDIN.read).to_json"],
            input=text, capture_output=True, text=True)
        if proc.returncode != 0:
            return {}
        return json.loads(proc.stdout or "null")


raw = {}
if os.path.exists(config_path):
    try:
        with open(config_path, encoding="utf-8") as fh:
            raw = load_yaml(fh.read()) or {}
    except Exception:
        raw = {}
if not isinstance(raw, dict):
    raw = {}

vcs = raw.get("vcs") or {}
host = vcs.get("host", "github")
commands = raw.get("commands") or {}
autonomy = raw.get("autonomy") or {}
budget = raw.get("budget") or {}

PROFILES = ("fast", "standard", "audit")

# Resolve only the fields the workflow needs, applying engine defaults.
config = {
    "base_branch": raw.get("base_branch", "develop"),
    "profile": raw.get("profile") if raw.get("profile") in PROFILES else "standard",
    "review_threshold_lines": raw.get("review_threshold_lines", 400),
    "surfaces": raw.get("surfaces") if isinstance(raw.get("surfaces"), list) else None,
    "vcs": {
        "host": host,
        "cli": vcs.get("cli", "glab" if host == "gitlab" else "gh"),
        "pr_target": vcs.get("pr_target", raw.get("base_branch", "develop")),
    },
    "commands": {
        "build": commands.get("build", ""),
        "test": commands.get("test", ""),
        "lint": commands.get("lint", ""),
        "typecheck": commands.get("typecheck", ""),
    },
    "autonomy": {
        "default_tier": autonomy.get("default_tier", 1),
        "require_gate": autonomy.get("require_gate", ["build"]),
    },
    "budget": {
        "max_attempts": budget.get("max_attempts", 2),
        "models": budget.get("models") or {},
    },
}
review_lenses = raw.get("review_lenses")
if isinstance(review_lenses, list) and review_lenses:
    config["review_lenses"] = review_lenses

# Statuses that are terminal or parked: --all skips them (plan_gate needs
# /forge:approve; the rest are finished or need a human).
SKIP_FOR_ALL = {"plan_gate", "pr_open", "merged", "done", "blocked", "failed"}
GATE_PASSED = {"building", "verifying", "reviewing", "integrating"}


def branch_name(ttype, task_id):
    """Compose the work-branch name as ``forge/<type>/<id>``.

    The task id already carries the mnemonic, so the branch is that id under the
    type namespace; the human-readable title lives on the PR, not the branch. A
    redundant leading ``<type>-`` on the id is stripped, so a ``build`` task with
    id ``build-foo`` becomes ``forge/build/foo`` rather than the doubled-up
    ``forge/build/build-foo``. The id is sanitized to the characters git allows
    in a ref, falling back to the raw id if that leaves nothing.
    """
    name = task_id
    prefix = ttype + "-"
    if name.startswith(prefix):
        name = name[len(prefix):]
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or task_id
    return "forge/%s/%s" % (ttype, name)


def read_run_status(task_id):
    p = os.path.join(runs_dir, task_id, "run.json")
    if not os.path.exists(p):
        return ""
    try:
        return json.load(open(p)).get("status", "") or ""
    except Exception:
        return ""


def feedback_for(task_id):
    p = os.path.join(runs_dir, task_id, "plan-feedback.md")
    if os.path.exists(p):
        try:
            return open(p, encoding="utf-8").read().strip()
        except Exception:
            return None
    return None


def context_cache_fresh(task_id):
    """True when this task's cached context brief still matches the working tree.

    forge-context-cache.sh re-hashes every file the brief cites and exits 0 only
    when all of them are unchanged. Any other outcome - no cache, an edited file,
    a deleted file, a broken script - is treated as stale, so the failure mode is
    always "run intake again" rather than "trust a map that may have rotted".
    """
    run_dir = os.path.join(runs_dir, task_id)
    if not os.path.exists(os.path.join(run_dir, "context-cache.json")):
        return False
    try:
        # Invoked through bash rather than relying on the exec bit: a checkout
        # that dropped file modes would otherwise turn every cache hit into a
        # silent miss, which is expensive but invisible.
        proc = subprocess.run(
            ["bash", os.path.join(plugin_dir, "scripts", "forge-context-cache.sh"),
             "check", "--run-dir", run_dir, "--repo", target],
            cwd=target, capture_output=True, text=True)
    except Exception:
        return False
    return proc.returncode == 0


# --- depends_on merge gate (run-all only) ---------------------------------
#
# A task is deferred from a /forge:run-all until every id in its `depends_on`
# has landed in the base branch. This is the only way two tasks that edit the
# same file avoid colliding without stacking: the dependent is held back until
# the dependency is MERGED, then it cuts from a base that already contains the
# dependency's work. Pure within-run ordering would not help - both would still
# branch from the same unchanged base.

_git_fetched = [False]


def _run(args):
    try:
        return subprocess.run(args, cwd=target, capture_output=True, text=True)
    except Exception:
        return None


def _ensure_fetch():
    # Refresh remote-tracking refs once, so "merged into base" reflects the host.
    # Best effort: a missing remote or offline run just falls back to local refs.
    if _git_fetched[0]:
        return
    _git_fetched[0] = True
    _run(["git", "fetch", "--quiet", "origin"])


def _resolve_ref(branch):
    for cand in ("origin/%s" % branch, branch):
        r = _run(["git", "rev-parse", "--verify", "--quiet", cand])
        if r is not None and r.returncode == 0:
            return cand
    return None


def _merged_into_base(branch):
    # True when `branch`'s commits are already an ancestor of the base branch,
    # i.e. it was merged (fast-forward or merge commit). Squash merges rewrite
    # history and are caught by the PR-state check instead.
    base_ref = _resolve_ref(config["base_branch"])
    branch_ref = _resolve_ref(branch)
    if not base_ref or not branch_ref:
        return False
    r = _run(["git", "merge-base", "--is-ancestor", branch_ref, base_ref])
    return r is not None and r.returncode == 0


def _pr_merged(dep_id):
    # True when the dependency's recorded PR is merged on the host. Covers squash
    # merges and deleted branches that the git-ancestry check cannot see. Needs
    # the gh CLI; absent it, this path is simply skipped.
    p = os.path.join(runs_dir, dep_id, "pr.json")
    if not os.path.exists(p):
        return False
    try:
        number = json.load(open(p)).get("number")
    except Exception:
        return False
    if not number or config["vcs"]["cli"] != "gh" or shutil.which("gh") is None:
        return False
    r = _run(["gh", "pr", "view", str(number), "--json", "state", "-q", ".state"])
    return r is not None and r.returncode == 0 and r.stdout.strip() == "MERGED"


def dep_satisfied(dep_id):
    """A dependency is satisfied once its work is in the base branch."""
    if read_run_status(dep_id) == "done":
        return True
    _ensure_fetch()
    dep_type = dep_id.split("-", 1)[0]
    if _merged_into_base(branch_name(dep_type, dep_id)):
        return True
    return _pr_merged(dep_id)


def make_task(task_id, ttype, autonomy_tier, title, spec_file, goal_text,
              profile=None, criteria=None, surface=None, priority=None,
              depends_on=None):
    status = read_run_status(task_id)
    feedback = feedback_for(task_id)
    if approved_flag or status in GATE_PASSED:
        approved, start, replan = True, "build", None
    elif feedback:
        approved, start, replan = False, "plan", feedback
    else:
        approved, start, replan = False, "intake", None
    # The spec's own profile wins over the repo default; an unknown value falls
    # back rather than failing the run (validate-task.sh is where it is rejected).
    task_profile = profile if profile in PROFILES else config["profile"]
    # The audit profile is read-only, so it never gets a working branch - same
    # rule the audit/investigate task types already carry.
    branch = None
    if task_profile != "audit" and ttype not in ("audit", "investigate"):
        branch = branch_name(ttype, task_id)
    return {
        "taskId": task_id,
        "type": ttype,
        "autonomy_tier": autonomy_tier,
        "profile": task_profile,
        # The area of the system this task changes. Tasks sharing a surface are
        # stacked serially; different surfaces run in parallel worktrees.
        "surface": surface or None,
        "priority": priority or None,
        "dependsOn": list(depends_on or []),
        # Filled in below, once the shape of the whole run is known.
        "worktree": None,
        "stackBase": None,
        # Whether the spec already states its acceptance criteria. The workflow
        # runs in a sandbox and cannot read the spec, so this disk fact is
        # resolved here; the fast profile uses it to skip intake.
        "hasAcceptanceCriteria": bool(criteria),
        # Whether a previous run's context brief is still valid for this working
        # tree. Also a disk fact the sandboxed workflow cannot check itself.
        "contextCacheFresh": context_cache_fresh(task_id),
        "title": title or task_id,
        "branch": branch,
        "specFile": spec_file,
        "goal": goal_text,
        "runDir": os.path.join(runs_dir, task_id),
        "mode": mode,
        "approved": approved,
        "startPhase": start,
        "replanFeedback": replan,
    }


def spec_task(s):
    return make_task(s.get("id"), s.get("type", "fix"),
                     s.get("autonomy_tier"), s.get("title"),
                     s.get("_file"), None,
                     s.get("profile"), s.get("acceptance_criteria"),
                     s.get("surface"), s.get("priority"), s.get("depends_on"))


PRIORITY_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}


def surface_key(task):
    """The group a task runs in. Tasks without a surface are each their own
    group, so an unlabeled task never blocks or is blocked by anything."""
    return task["surface"] or "\0solo:" + task["taskId"]


def order_group(group):
    """Order one surface's tasks into the sequence they will be stacked in:
    declared depends_on first (restricted to this group), then priority, then id.

    A dependency cycle cannot stall the run - when nothing is ready, the next
    task is chosen by the priority/id tiebreak and the cycle is simply flattened.
    """
    ids = {t["taskId"] for t in group}
    deps = {t["taskId"]: [d for d in t["dependsOn"] if d in ids] for t in group}
    placed, ordered = set(), []
    rank = lambda t: (PRIORITY_RANK.get(t["priority"], 9), t["taskId"])
    while len(ordered) < len(group):
        remaining = [t for t in group if t["taskId"] not in placed]
        ready = [t for t in remaining if all(d in placed for d in deps[t["taskId"]])]
        nxt = sorted(ready or remaining, key=rank)[0]
        ordered.append(nxt)
        placed.add(nxt["taskId"])
    return ordered


tasks = []
deferred = []
if selector == "--goal":
    tasks.append(make_task(adhoc_id, "build", None, goal[:72], None, goal))
else:
    specs = json.loads(specs_s) if specs_s.strip() else []
    declared = config["surfaces"]
    if declared:
        for s in specs:
            sur = s.get("surface")
            if sur and sur not in declared:
                sys.stderr.write(
                    "forge-context: task %s declares surface %r, which is not in the "
                    "project config's surfaces list %s\n" % (s.get("id"), sur, declared))
                sys.exit(1)

    candidates = [spec_task(s) for s in specs if s.get("id")]
    if selector == "--all":
        candidates = [t for t in candidates
                      if read_run_status(t["taskId"]) not in SKIP_FOR_ALL]

        # A dependency inside the same surface needs no merge gate: the two tasks
        # are stacked in this very run, so the dependent branches off the
        # dependency's branch and already contains its work. Only cross-surface
        # dependencies (or ones not running at all) still wait for a real merge.
        # Deferring can cascade - dropping a task may strand a same-surface
        # dependent - so this runs to a fixed point rather than in one pass.
        while True:
            running = {t["taskId"]: t for t in candidates}
            newly_deferred = []
            for t in candidates:
                unmet = []
                for d in t["dependsOn"]:
                    peer = running.get(d)
                    if peer is not None and surface_key(peer) == surface_key(t):
                        continue          # satisfied by stacking, not by merging
                    if not dep_satisfied(d):
                        unmet.append(d)
                if unmet:
                    newly_deferred.append((t, unmet))
            if not newly_deferred:
                break
            for t, unmet in newly_deferred:
                deferred.append({"taskId": t["taskId"], "waitingOn": unmet})
            dropped = {t["taskId"] for t, _ in newly_deferred}
            candidates = [t for t in candidates if t["taskId"] not in dropped]

    # Emit group-major: every surface's tasks contiguous and in stack order, so
    # the workflow can group by surface without re-deriving any ordering.
    groups, group_order = {}, []
    for t in candidates:
        k = surface_key(t)
        if k not in groups:
            groups[k] = []
            group_order.append(k)
        groups[k].append(t)
    for k in group_order:
        tasks.extend(order_group(groups[k]))

# Worktrees exist to let groups run at the same time, so they are allocated only
# when there is more than one group in flight. A single-task or single-surface
# run keeps working directly in the main checkout, exactly as before.
worktrees_dir = os.path.join(os.path.dirname(runs_dir), "worktrees")
group_count = len({surface_key(t) for t in tasks})
if group_count > 1:
    for t in tasks:
        if t["branch"]:      # tier-0 read-only tasks never get a tree
            t["worktree"] = os.path.join(worktrees_dir, t["taskId"])

out = {
    "pluginRoot": plugin_dir,
    "repoRoot": target,
    "config": config,
    "tasks": tasks,
    "deferred": deferred,
}

print(json.dumps(out, indent=2))
PY
