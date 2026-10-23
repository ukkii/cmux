#!/usr/bin/env bash
# Merge upstream manaflow-ai/cmux into this fork without bringing back removed features.
#
# Usage: scripts/merge-upstream.sh [--ref <upstream-ref>] [--base <fork-branch>] [--branch <name>]
#
# 1. Creates a sync branch from the fork base (default: main).
# 2. Merges the upstream ref (default: upstream/main) without committing.
# 3. Drops every upstream change or addition under a path listed in
#    .strip/removed-paths.txt, which resolves "deleted here, modified upstream" conflicts.
#    Keeps the fork's version of files in .strip/fork-owned-paths.txt.
# 4. Reports the remaining conflicts and any added lines that match
#    .strip/forbidden-patterns.txt (removed SDKs, modules or endpoints).
# The merge is left uncommitted so it can be reviewed, built and committed by hand.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UPSTREAM_URL="https://github.com/manaflow-ai/cmux.git"
REF="upstream/main"
BASE="main"
BRANCH="upstream-sync/$(date +%Y-%m-%d)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | grep '^#'; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "error: working tree has uncommitted changes; commit or stash them first" >&2
  exit 1
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "$UPSTREAM_URL"
fi
git fetch upstream --no-tags

git switch -c "$BRANCH" "$BASE"

echo "==> Merging $REF into $BRANCH (no commit)"
set +e
git merge --no-ff --no-commit "$REF"
merge_status=$?
set -e
if [[ $merge_status -ne 0 ]] && ! git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  echo "error: merge did not start" >&2
  exit 1
fi

echo "==> Dropping upstream changes under removed paths"
python3 - "$ROOT/.strip/removed-paths.txt" "$ROOT/.strip/fork-owned-paths.txt" <<'PY'
import fnmatch
import subprocess
import sys

rules = []
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    negate = line.startswith("!")
    rules.append((negate, line[1:] if negate else line))

def removed(path):
    hit = False
    for negate, pattern in rules:
        if pattern.endswith("/"):
            match = path.startswith(pattern)
        elif any(ch in pattern for ch in "*?["):
            match = fnmatch.fnmatchcase(path, pattern)
        else:
            match = path == pattern or path.startswith(pattern + "/")
        if match:
            hit = not negate
    return hit

def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout

# Everything the merge touched: staged changes against HEAD plus unmerged paths.
touched = set(git("diff", "--cached", "--name-only", "HEAD").split())
touched |= set(git("diff", "--name-only", "--diff-filter=U").split())
dropped = sorted(p for p in touched if removed(p))
for path in dropped:
    in_head = subprocess.run(["git", "cat-file", "-e", f"HEAD:{path}"], capture_output=True).returncode == 0
    if in_head:
        # The fork still has this file (e.g. an allowed workflow); keep the fork's version.
        subprocess.run(["git", "checkout", "HEAD", "--", path], check=True)
    else:
        subprocess.run(["git", "rm", "-rf", "--quiet", "--ignore-unmatch", "--", path], check=True)
print(f"dropped {len(dropped)} path(s) under removed areas")

# Fork-owned files: always keep the fork's version.
owned = []
for raw in open(sys.argv[2], encoding="utf-8"):
    line = raw.strip()
    if line and not line.startswith("#"):
        owned.append(line)
kept = sorted(p for p in touched
              if any(p == o or (o.endswith("/") and p.startswith(o)) for o in owned))
for path in kept:
    in_head = subprocess.run(["git", "cat-file", "-e", f"HEAD:{path}"], capture_output=True).returncode == 0
    if in_head:
        subprocess.run(["git", "checkout", "HEAD", "--", path], check=True)
    else:
        subprocess.run(["git", "rm", "-rf", "--quiet", "--ignore-unmatch", "--", path], check=True)
if kept:
    print("kept the fork's version of: " + ", ".join(kept))
PY

echo "==> Auto-resolving list-only conflicts (pbxproj, test registry)"
python3 - <<'PY'
import os
import re
import subprocess

CONFLICT = re.compile(r"^<<<<<<< [^\n]*\n(.*?)^=======\n(.*?)^>>>>>>> [^\n]*\n", re.S | re.M)

def union(text):
    # Both sides appended entries to the same list; keep ours, then theirs.
    return CONFLICT.sub(lambda m: m.group(1) + m.group(2), text)

def prune_missing_tests(text):
    # Drop [[test]] entries whose test file does not exist in the fork.
    blocks = re.split(r"(?m)^(?=\[\[test\]\]\n)", text)
    kept = []
    for block in blocks:
        m = re.search(r'(?m)^path = "([^"]+)"', block)
        if block.startswith("[[test]]") and m and not os.path.exists(m.group(1)):
            continue
        kept.append(block)
    return "".join(kept)

unmerged = subprocess.run(["git", "diff", "--name-only", "--diff-filter=U"],
                          check=True, capture_output=True, text=True).stdout.split()
for path in unmerged:
    if path == "cmux.xcodeproj/project.pbxproj":
        fix = union
    elif path == "tests/test-execution.toml":
        fix = lambda t: prune_missing_tests(union(t))
    else:
        continue
    with open(path, encoding="utf-8") as f:
        text = f.read()
    fixed = fix(text)
    if "<<<<<<< " in fixed:
        continue
    with open(path, "w", encoding="utf-8") as f:
        f.write(fixed)
    subprocess.run(["git", "add", "--", path], check=True)
    print(f"resolved {path} by union")
PY
if [[ -x scripts/sync-test-wiring ]]; then
  # Re-derive cmuxTests wiring so entries for dropped test files disappear.
  scripts/sync-test-wiring >/dev/null && git add cmux.xcodeproj/project.pbxproj || true
fi
if ! plutil -lint cmux.xcodeproj/project.pbxproj >/dev/null; then
  echo "warning: project.pbxproj does not parse after the union; resolve it by hand"
fi

echo "==> Checking added lines for removed SDKs, modules and endpoints"
pattern_file="$ROOT/.strip/forbidden-patterns.txt"
forbidden="$(grep -vE '^\s*(#|$)' "$pattern_file" | paste -sd'|' -)"
hits="$(git diff --cached HEAD -U0 -- Sources CLI Packages Resources daemon \
  | grep -E '^\+[^+]' | grep -nE "$forbidden" || true)"
if [[ -n "$hits" ]]; then
  echo "warning: upstream added lines that reference removed functionality:"
  echo "$hits" | head -50
fi

conflicts="$(git diff --name-only --diff-filter=U)"
if [[ -n "$conflicts" ]]; then
  echo "==> Remaining conflicts to resolve by hand:"
  echo "$conflicts"
fi

cat <<EOF

Next steps:
  1. Resolve the conflicts above (cmux.xcodeproj/project.pbxproj usually needs
     scripts/normalize-pbxproj.py and removal of entries for dropped files).
  2. Build: PATH=~/.cargo/bin:\$PATH CMUX_DEV_BACKEND_MODE=local CMUX_GHOSTTYKIT_PREPROVISIONED=1 \\
       CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag sync --build-only
  3. Commit the merge, push $BRANCH to ukkii/cmux and open a PR against $BASE.
  If upstream added a new feature that talks to cmux services, remove it and add its
  paths to .strip/removed-paths.txt and a note to REMOVED.md.
EOF
