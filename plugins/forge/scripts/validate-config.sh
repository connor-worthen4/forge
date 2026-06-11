#!/usr/bin/env bash
#
# validate-config.sh - validate a forge .forge/config.yaml against the
# project-config schema.
#
# Checks (errors fail the run, non-zero exit):
#   - required fields present (version, base_branch, vcs.host, commands.test)
#   - version == 1
#   - enum values: vcs.host, vcs.cli, autonomy.default_tier, task types in
#     autonomy.allow_unattended / require_gate, budget.models phase keys
#   - commands referenced by enabled task types exist (code-changing types need
#     a non-empty commands.test)
# Warnings (do NOT fail):
#   - budget.monthly_usd unset or >= the credit ceiling (default $100, override
#     with FORGE_CREDIT_CEILING_USD)
#   - 'build' enabled unattended but commands.build empty
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
CEILING="${FORGE_CREDIT_CEILING_USD:-100}"
CONFIG="${1:-.forge/config.yaml}"

if [ ! -f "$SCHEMA" ]; then
  echo "project-config schema not found: $SCHEMA" >&2
  exit 2
fi
if [ ! -f "$CONFIG" ]; then
  echo "config not found: $CONFIG" >&2
  exit 2
fi

python3 - "$SCHEMA" "$CONFIG" "$CEILING" <<'PY'
import sys, json, re

schema_path, config_path, ceiling_s = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    ceiling = float(ceiling_s)
except ValueError:
    ceiling = 100.0


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
READ_ONLY = {"audit", "investigate"}
code_changing = set(task_types) - READ_ONLY

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

# protected_branches
pb = cfg.get("protected_branches")
if pb is not None:
    if (not isinstance(pb, list) or not pb
            or not all(isinstance(x, str) and x.strip() for x in pb)):
        errors.append("protected_branches must be a non-empty list of strings")

# autonomy
autonomy = cfg.get("autonomy") or {}
auto_schema = props.get("autonomy", {}).get("properties", {})
def_unattended = auto_schema.get("allow_unattended", {}).get("default", ["fix", "audit", "refactor", "chore"])
def_gate = auto_schema.get("require_gate", {}).get("default", ["build"])

if "default_tier" in autonomy:
    tiers = auto_schema.get("default_tier", {}).get("enum", [0, 1, 2])
    if autonomy["default_tier"] not in tiers:
        errors.append("autonomy.default_tier must be one of %s (got %r)"
                      % (tiers, autonomy["default_tier"]))


def check_types(field):
    value = autonomy.get(field)
    if value is None:
        return
    if not isinstance(value, list):
        errors.append("autonomy.%s must be a list" % field)
        return
    for t in value:
        if t not in task_types:
            errors.append("autonomy.%s has invalid task type %r (allowed: %s)"
                          % (field, t, task_types))


check_types("allow_unattended")
check_types("require_gate")

unattended = autonomy.get("allow_unattended", def_unattended) or []
gate = autonomy.get("require_gate", def_gate) or []
enabled = set(unattended) | set(gate)


def cmd_empty(name):
    v = commands.get(name, "")
    return not (isinstance(v, str) and v.strip())


# commands referenced by enabled task types exist
if (enabled & code_changing) and cmd_empty("test"):
    errors.append("commands.test must be non-empty because code-changing task types are enabled (%s)"
                  % sorted(enabled & code_changing))
if "build" in set(unattended) and cmd_empty("build"):
    warnings.append("commands.build is empty but 'build' is in autonomy.allow_unattended "
                    "(unattended builds need a build command)")

# budget
budget = cfg.get("budget") or {}
models = budget.get("models") or {}
phases = list(props.get("budget", {}).get("properties", {})
              .get("models", {}).get("properties", {}).keys()) \
    or ["intake", "plan", "build", "verify", "review", "integrate"]
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

# budget ceiling
monthly = budget.get("monthly_usd")
if monthly is None:
    warnings.append("budget.monthly_usd is not set; set it below your account credit ceiling "
                    "(ceiling used for this check: $%.2f)" % ceiling)
else:
    try:
        mf = float(monthly)
        if mf >= ceiling:
            warnings.append("budget.monthly_usd ($%.2f) is at or above the credit ceiling ($%.2f); "
                            "set it BELOW the ceiling so forge throttles itself" % (mf, ceiling))
    except (TypeError, ValueError):
        errors.append("budget.monthly_usd must be a number")

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
