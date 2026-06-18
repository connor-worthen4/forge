#!/usr/bin/env bash
#
# validate-config.sh - validate a forge .forge/config.yaml against the
# project-config schema.
#
# Checks (errors fail the run, non-zero exit):
#   - required fields present (version, base_branch, vcs.host, commands.test)
#   - version == 1
#   - enum values: vcs.host, vcs.cli, autonomy.default_tier, task types in
#     autonomy.require_gate, budget.models phase keys
#   - protected_branches, review_lenses well-formed when present
#   - budget.max_attempts a positive integer when present
# Warnings (do NOT fail):
#   - commands.test empty (verify needs it for any code-changing task)
#   - a phase model set to opus (reserved for explicit tier-2 overrides)
#   - vcs.cli inconsistent with host; unrecognized model strings
#
# If the python `jsonschema` library is installed, a full Draft 2020-12
# validation runs in addition.
#
# Usage: validate-config.sh [CONFIG]      (default: .forge/config.yaml)
# Deps:  python3 (PyYAML preferred; falls back to ruby for YAML parsing).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="${FORGE_CONFIG_SCHEMA:-$SCRIPT_DIR/../schema/project-config.schema.json}"
CONFIG="${1:-.forge/config.yaml}"

if [ ! -f "$SCHEMA" ]; then
  echo "project-config schema not found: $SCHEMA" >&2
  exit 2
fi
if [ ! -f "$CONFIG" ]; then
  echo "config not found: $CONFIG" >&2
  exit 2
fi

python3 - "$SCHEMA" "$CONFIG" <<'PY'
import sys, json, re

schema_path, config_path = sys.argv[1], sys.argv[2]


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
            raise RuntimeError("no YAML parser available (install PyYAML or ruby): "
                               + proc.stderr.strip())
        return json.loads(proc.stdout)


with open(schema_path) as fh:
    schema = json.load(fh)
with open(config_path, encoding="utf-8") as fh:
    text = fh.read()

errors = []
warnings = []

try:
    cfg = load_yaml(text)
except Exception as exc:
    print("FAIL %s" % config_path)
    print("  - [error] config is not valid YAML: %s" % exc)
    sys.exit(1)
if not isinstance(cfg, dict):
    print("FAIL %s" % config_path)
    print("  - [error] config must be a mapping")
    sys.exit(1)

props = schema.get("properties", {})
defs = schema.get("$defs", {})
task_types = defs.get("taskType", {}).get("enum",
                                          ["fix", "build", "audit", "refactor", "investigate", "chore"])

modelref = defs.get("modelRef", {})
aliases, model_pat = [], None
for sub in modelref.get("anyOf", []):
    if "enum" in sub:
        aliases = sub["enum"]
    if "pattern" in sub:
        model_pat = sub["pattern"]


def enum_at(*path):
    node = props
    for p in path[:-1]:
        node = node.get(p, {}).get("properties", {})
    return node.get(path[-1], {}).get("enum")


# version
if "version" not in cfg:
    errors.append("missing required field: version")
elif cfg["version"] != 1:
    errors.append("version must be 1 (got %r)" % cfg["version"])

# base_branch
if not cfg.get("base_branch"):
    errors.append("missing required field: base_branch")

# vcs
vcs = cfg.get("vcs")
if not isinstance(vcs, dict) or not vcs.get("host"):
    errors.append("missing required field: vcs.host")
    vcs = vcs if isinstance(vcs, dict) else {}
else:
    hosts = enum_at("vcs", "host") or ["github", "gitlab"]
    if vcs["host"] not in hosts:
        errors.append("vcs.host must be one of %s (got %r)" % (hosts, vcs["host"]))
    if "cli" in vcs:
        clis = enum_at("vcs", "cli") or ["gh", "glab"]
        if vcs["cli"] not in clis:
            errors.append("vcs.cli must be one of %s (got %r)" % (clis, vcs["cli"]))
        expect = {"github": "gh", "gitlab": "glab"}.get(vcs.get("host"))
        if expect and vcs.get("cli") != expect:
            warnings.append("vcs.cli %r is unusual for host %r (expected %r)"
                            % (vcs.get("cli"), vcs.get("host"), expect))

# commands
commands = cfg.get("commands")
if not isinstance(commands, dict) or "test" not in commands:
    errors.append("missing required field: commands.test")
    commands = commands if isinstance(commands, dict) else {}
else:
    tv = commands.get("test", "")
    if not (isinstance(tv, str) and tv.strip()):
        warnings.append("commands.test is empty; the verify phase needs it to grade any code-changing task")

# protected_branches
pb = cfg.get("protected_branches")
if pb is not None:
    if (not isinstance(pb, list) or not pb
            or not all(isinstance(x, str) and x.strip() for x in pb)):
        errors.append("protected_branches must be a non-empty list of strings")

# review_lenses
rl = cfg.get("review_lenses")
if rl is not None:
    if (not isinstance(rl, list) or not rl
            or not all(isinstance(x, str) and x.strip() for x in rl)):
        errors.append("review_lenses must be a non-empty list of strings")

# autonomy
autonomy = cfg.get("autonomy") or {}
auto_schema = props.get("autonomy", {}).get("properties", {})

if "default_tier" in autonomy:
    tiers = auto_schema.get("default_tier", {}).get("enum", [0, 1, 2])
    if autonomy["default_tier"] not in tiers:
        errors.append("autonomy.default_tier must be one of %s (got %r)"
                      % (tiers, autonomy["default_tier"]))

gate = autonomy.get("require_gate")
if gate is not None:
    if not isinstance(gate, list):
        errors.append("autonomy.require_gate must be a list")
    else:
        for t in gate:
            if t not in task_types:
                errors.append("autonomy.require_gate has invalid task type %r (allowed: %s)"
                              % (t, task_types))

# budget
budget = cfg.get("budget") or {}
if "max_attempts" in budget:
    ma = budget["max_attempts"]
    if not isinstance(ma, int) or isinstance(ma, bool) or ma < 1:
        errors.append("budget.max_attempts must be an integer >= 1 (got %r)" % ma)

models = budget.get("models") or {}
phases = list(props.get("budget", {}).get("properties", {})
              .get("models", {}).get("properties", {}).keys()) \
    or ["intake", "plan", "build", "verify", "review", "integrate", "report"]
if isinstance(models, dict):
    for ph, mv in models.items():
        if ph not in phases:
            errors.append("budget.models has unknown phase %r (allowed: %s)" % (ph, phases))
            continue
        if not isinstance(mv, str) or not mv:
            errors.append("budget.models.%s must be a non-empty model string" % ph)
            continue
        valid = (mv in aliases) or (model_pat and re.match(model_pat, mv))
        if not valid:
            warnings.append("budget.models.%s value %r is not a recognized alias or pinned model string"
                            % (ph, mv))
        if mv in ("opus", "opus[1m]", "best") or mv.startswith("claude-opus"):
            warnings.append("budget.models.%s uses opus; opus is reserved for explicit tier-2 overrides, "
                            "not a phase default at this budget" % ph)

# optional full schema validation
try:
    import jsonschema
    validator = jsonschema.Draft202012Validator(schema)
    for err in sorted(validator.iter_errors(cfg), key=lambda e: list(e.path)):
        loc = ".".join(str(x) for x in err.path) or "(root)"
        errors.append("schema: %s: %s" % (loc, err.message))
except ImportError:
    pass

if errors:
    print("FAIL %s" % config_path)
    for e in errors:
        print("  - [error] %s" % e)
    for w in warnings:
        print("  - [warn]  %s" % w)
    sys.exit(1)

print("PASS %s" % config_path)
for w in warnings:
    print("  - [warn]  %s" % w)
sys.exit(0)
PY
