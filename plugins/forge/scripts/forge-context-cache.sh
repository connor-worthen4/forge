#!/usr/bin/env bash
#
# forge-context-cache.sh - stamp and validate the cached context brief.
#
# Intake's context-brief.md is the map every later phase reads instead of
# re-deriving the codebase cold. Re-running intake on every attempt re-derives a
# map that usually has not changed, so the brief is cached across runs: intake
# stamps it once, and a later run reuses it as long as the files it cites still
# look the way they did.
#
# The cache is only as trustworthy as its invalidation, so freshness is decided
# by content, not by a timestamp. Stamping records `git hash-object` for every
# repo file the brief cites; checking re-hashes those paths and calls the brief
# stale the moment one differs, disappears, or the brief itself changes. A brief
# whose cited files moved under it is worse than no brief - it sends plan and
# build to path:line references that no longer hold.
#
# Cited paths are extracted from the brief mechanically (backticked spans and
# bare slash-bearing tokens, minus any :line suffix) and kept only when they
# resolve to a real file, so prose that merely looks path-shaped is ignored.
#
# Usage:
#   forge-context-cache.sh stamp --run-dir <dir> [--repo <path>]
#       Write <run-dir>/context-cache.json from <run-dir>/context-brief.md.
#   forge-context-cache.sh check --run-dir <dir> [--repo <path>]
#       Compare the recorded hashes against the working tree.
#
# Output: a one-line human summary, plus the JSON object on stdout for `check`
#   ({"fresh":bool,"reason":...,"changed":[...],"files":n}).
#
# Exit status: 0 fresh (or stamped) | 1 stale | 2 usage/environment error.
# A missing or unreadable cache is stale, never an error: the caller just runs
# intake, which is exactly the safe fallback.
#
# Deps: git, jq, python3 (via forge-lib.sh).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=forge-lib.sh
. "$SCRIPT_DIR/forge-lib.sh"

forge_require git || exit 2

BRIEF_NAME="context-brief.md"
CACHE_NAME="context-cache.json"

mode="${1:-}"
case "$mode" in
  stamp|check) shift ;;
  -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
  *) echo "usage: forge-context-cache.sh stamp|check --run-dir <dir> [--repo <path>]" >&2; exit 2 ;;
esac

run_dir=""
repo="$TARGET"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-dir) run_dir="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    *) echo "forge-context-cache: unexpected argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$run_dir" ] || { echo "forge-context-cache: --run-dir is required" >&2; exit 2; }

brief="$run_dir/$BRIEF_NAME"
cache="$run_dir/$CACHE_NAME"

if [ ! -d "$repo" ]; then
  echo "forge-context-cache: repo not found: $repo" >&2
  exit 2
fi

# A brief that was never written cannot be cached or trusted. For `check` that is
# an ordinary cache miss (run intake); for `stamp` it means the caller asked us to
# record something that does not exist.
if [ ! -f "$brief" ]; then
  if [ "$mode" = "check" ]; then
    jq -n '{fresh:false, reason:"no context brief has been written yet", changed:[], files:0}'
    echo "forge-context-cache: stale (no $BRIEF_NAME)" >&2
    exit 1
  fi
  echo "forge-context-cache: no brief to stamp at $brief" >&2
  exit 2
fi

python3 - "$mode" "$repo" "$brief" "$cache" <<'PY'
import sys, os, re, json, subprocess, hashlib

mode, repo, brief_path, cache_path = sys.argv[1:5]

# Candidate path tokens: anything inside backticks, plus bare tokens carrying a
# slash. Both are filtered against the filesystem below, so over-matching here is
# free - a token that is not a real file is simply dropped.
BACKTICKED = re.compile(r'`([^`\n]+)`')
BARE = re.compile(r'(?<![\w`])((?:\.{0,2}/)?[\w.-]+(?:/[\w.-]+)+)')
LINE_SUFFIX = re.compile(r':\d+(?:-\d+)?$')


def candidates(text):
    """Every path-shaped token in the brief, in first-seen order."""
    out = []
    for m in BACKTICKED.finditer(text):
        out.append(m.group(1))
    for m in BARE.finditer(text):
        out.append(m.group(1))
    return out


def normalize(tok):
    """Reduce a cited token to a repo-relative path, or '' if it is not one."""
    s = tok.strip().strip('*_"\'')
    s = s.rstrip('.,;:)]}')
    s = LINE_SUFFIX.sub('', s)
    if s.startswith('./'):
        s = s[2:]
    s = s.strip()
    # Absolute paths and parent escapes are not repo-relative citations.
    if not s or s.startswith('/') or s.startswith('..'):
        return ''
    return s


def cited_files(text):
    seen, files = set(), []
    for tok in candidates(text):
        rel = normalize(tok)
        if not rel or rel in seen:
            continue
        seen.add(rel)
        full = os.path.join(repo, rel)
        # Only real files are recorded. A directory or a prose phrase that merely
        # looks path-shaped carries no content to hash.
        if os.path.isfile(full):
            files.append(rel)
    return files


def hash_files(paths):
    """git hash-object for each path -> {path: blob}. Content-addressed, so it
    catches an edit that leaves mtime and size untouched."""
    if not paths:
        return {}
    proc = subprocess.run(
        ["git", "hash-object", "--stdin-paths"],
        cwd=repo, input="\n".join(paths) + "\n",
        capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    hashes = proc.stdout.split()
    if len(hashes) != len(paths):
        return None
    return dict(zip(paths, hashes))


with open(brief_path, encoding="utf-8") as fh:
    brief_text = fh.read()
# The brief itself is part of the cache key: an edited brief is a different map,
# whatever its cited files are doing.
brief_hash = hashlib.sha256(brief_text.encode("utf-8")).hexdigest()

if mode == "stamp":
    paths = cited_files(brief_text)
    hashes = hash_files(paths)
    if hashes is None:
        sys.stderr.write("forge-context-cache: git hash-object failed; not stamping\n")
        sys.exit(2)
    record = {
        "brief": os.path.basename(brief_path),
        "brief_sha256": brief_hash,
        "files": [{"path": p, "blob": hashes[p]} for p in paths],
    }
    with open(cache_path, "w", encoding="utf-8") as fh:
        json.dump(record, fh, indent=2)
        fh.write("\n")
    print("forge-context-cache: stamped %d cited file(s) (%s)"
          % (len(paths), cache_path))
    sys.exit(0)

# --- check ---------------------------------------------------------------
def stale(reason, changed=()):
    print(json.dumps({"fresh": False, "reason": reason,
                      "changed": list(changed), "files": 0}))
    sys.stderr.write("forge-context-cache: stale - %s\n" % reason)
    sys.exit(1)


if not os.path.exists(cache_path):
    stale("no context cache has been stamped for this task")
try:
    with open(cache_path, encoding="utf-8") as fh:
        record = json.load(fh)
except Exception as exc:
    stale("context cache is unreadable (%s)" % exc)

if record.get("brief_sha256") != brief_hash:
    stale("the context brief itself changed since it was stamped")

entries = record.get("files") or []
paths = [e.get("path") for e in entries if e.get("path")]
missing = [p for p in paths if not os.path.isfile(os.path.join(repo, p))]
if missing:
    stale("%d cited file(s) no longer exist" % len(missing), missing)

hashes = hash_files(paths)
if hashes is None:
    stale("could not re-hash the cited files")

changed = [e["path"] for e in entries
           if e.get("path") and hashes.get(e["path"]) != e.get("blob")]
if changed:
    stale("%d cited file(s) changed since the brief was written" % len(changed),
          changed)

print(json.dumps({"fresh": True, "reason": "all cited files unchanged",
                  "changed": [], "files": len(paths)}))
sys.stderr.write("forge-context-cache: fresh (%d cited file(s) unchanged)\n"
                 % len(paths))
sys.exit(0)
PY
