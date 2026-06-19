#!/usr/bin/env bash
#
# validate-task.sh - validate forge task spec file(s) against the task-spec schema.
#
# Parses the YAML frontmatter of each file and checks it against
# schema/task-spec.schema.json: required fields present, enum values valid,
# id format correct (and its prefix matches `type`), acceptance_criteria a
# non-empty list, and no unknown fields. If the python `jsonschema` library is
# installed it additionally runs a full Draft 2020-12 validation.
#
# Usage:
#   validate-task.sh FILE [FILE...]          human-readable PASS/FAIL; non-zero exit on any failure
#   validate-task.sh --json FILE [FILE...]   on success, print a JSON array of the validated
#                                            frontmatter objects (each with an added _file key);
#                                            validation messages go to stderr
#
# Deps: python3 (PyYAML preferred; falls back to `ruby` for YAML parsing).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="${FORGE_TASK_SCHEMA:-$SCRIPT_DIR/../schema/task-spec.schema.json}"

JSON=0
if [ "${1:-}" = "--json" ]; then
  JSON=1
  shift
fi

if [ "$#" -lt 1 ]; then
  echo "usage: validate-task.sh [--json] FILE [FILE...]" >&2
  exit 2
fi

if [ ! -f "$SCHEMA" ]; then
  echo "task-spec schema not found: $SCHEMA" >&2
  exit 2
fi

python3 - "$JSON" "$SCHEMA" "$@" <<'PY'
import sys, json, re

emit_json = sys.argv[1] == "1"
schema_path = sys.argv[2]
files = sys.argv[3:]


def load_yaml(text):
    """Parse YAML using PyYAML, falling back to ruby's stdlib YAML."""
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
            raise RuntimeError(
                "no YAML parser available (install PyYAML or ruby): "
                + proc.stderr.strip())
        return json.loads(proc.stdout)


with open(schema_path) as fh:
    schema = json.load(fh)

required = schema.get("required", [])
props = schema.get("properties", {})
allowed = set(props.keys())
no_extra = schema.get("additionalProperties", True) is False

FRONTMATTER = re.compile(r'^﻿?\s*---[ \t]*\r?\n(.*?)\r?\n---[ \t]*\r?\n?',
                         re.DOTALL)


def enum_of(name):
    return props.get(name, {}).get("enum")


def empty(value):
    return value is None or value == "" or value == [] or value == {}


def validate(path):
    errors = []
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        return None, ["cannot read file: %s" % exc]

    match = FRONTMATTER.match(text)
    if not match:
        return None, ["no YAML frontmatter found (file must start with a '---' fenced block)"]

    try:
        data = load_yaml(match.group(1))
    except Exception as exc:
        return None, ["frontmatter is not valid YAML: %s" % exc]
    if not isinstance(data, dict):
        return None, ["frontmatter must be a mapping of fields"]

    for key in required:
        if key not in data or empty(data[key]):
            errors.append("missing required field: %s" % key)

    if no_extra:
        for key in data:
            if key not in allowed:
                errors.append("unknown field not allowed by schema: %s" % key)

    for key in ("type", "priority"):
        values = enum_of(key)
        if values and key in data and data[key] not in values:
            errors.append("%s must be one of %s (got %r)" % (key, values, data[key]))

    if "autonomy_tier" in data:
        tiers = enum_of("autonomy_tier") or [0, 1, 2]
        if data["autonomy_tier"] not in tiers:
            errors.append("autonomy_tier must be one of %s (got %r)"
                          % (tiers, data["autonomy_tier"]))

    pattern = props.get("id", {}).get("pattern")
    if "id" in data and isinstance(data["id"], str):
        if pattern and not re.match(pattern, data["id"]):
            errors.append("id %r does not match required format %s" % (data["id"], pattern))
        if isinstance(data.get("type"), str) and not data["id"].startswith(data["type"] + "-"):
            errors.append("id %r prefix must match type %r (expected '%s-...')"
                          % (data["id"], data["type"], data["type"]))

    if "title" in data and (not isinstance(data["title"], str) or not data["title"].strip()):
        errors.append("title must be a non-empty string")

    criteria = data.get("acceptance_criteria")
    if criteria is not None:
        if not isinstance(criteria, list) or len(criteria) == 0:
            errors.append("acceptance_criteria must be a non-empty list")
        else:
            for i, item in enumerate(criteria):
                if not isinstance(item, str) or not item.strip():
                    errors.append("acceptance_criteria[%d] must be a non-empty string" % i)

    if "source" in data and data["source"] is not None:
        src = data["source"]
        if not isinstance(src, dict):
            errors.append("source must be a mapping with 'kind' and 'ref'")
        else:
            for key in ("kind", "ref"):
                if key not in src or empty(src.get(key)):
                    errors.append("source.%s is required when source is present" % key)
            kinds = props.get("source", {}).get("properties", {}).get("kind", {}).get("enum")
            if kinds and src.get("kind") not in kinds:
                errors.append("source.kind must be one of %s (got %r)" % (kinds, src.get("kind")))

    try:
        import jsonschema
        validator = jsonschema.Draft202012Validator(schema)
        for err in sorted(validator.iter_errors(data), key=lambda e: list(e.path)):
            errors.append("schema: %s" % err.message)
    except ImportError:
        pass

    if errors:
        return None, errors
    data["_file"] = path
    return data, []


results = []
all_ok = True
valid = []
for path in files:
    obj, errs = validate(path)
    if errs:
        all_ok = False
        results.append((path, False, errs))
    else:
        valid.append(obj)
        results.append((path, True, []))

if emit_json:
    if not all_ok:
        for path, ok, errs in results:
            if not ok:
                sys.stderr.write("FAIL %s\n" % path)
                for e in errs:
                    sys.stderr.write("  - %s\n" % e)
        sys.exit(1)
    sys.stdout.write(json.dumps(valid, indent=2) + "\n")
    sys.exit(0)

for path, ok, errs in results:
    if ok:
        print("PASS %s" % path)
    else:
        print("FAIL %s" % path)
        for e in errs:
            print("  - %s" % e)
sys.exit(0 if all_ok else 1)
PY
