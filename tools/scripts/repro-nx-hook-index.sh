#!/bin/sh
# Reproduces Nx Git-index corruption from a pre-commit hook in a linked worktree.
# Runs entirely in a disposable clone under a fresh TMPDIR; never touches this checkout's index.
# Exit 1 = corruption reproduced, 0 = index intact.
set -eu

root=$(git rev-parse --show-toplevel)
tmp=$(mktemp -d)
repo="$tmp/repo"
wt="$tmp/nx-hook-repro"
echo "scratch: $tmp"

git clone -q "$root" "$repo"
git -C "$repo" worktree add -q -b nx-hook-repro "$wt"
ln -s "$root/node_modules" "$wt/node_modules"
chmod +x "$wt/.hooks/pre-commit"

# Fresh daemon, uncached nx-ai-agents-config clone (cache lives in os.tmpdir()).
# Daemon env drops TMPDIR, so also set TMP (Node's next tmpdir fallback).
export TMPDIR="$tmp/os-tmp" TMP="$tmp/os-tmp"
mkdir -p "$TMPDIR"
unset CI

export NX_USE_LOCAL="${NX_USE_LOCAL:-true}"
cd "$wt"
node_modules/.bin/nx daemon --stop >/dev/null 2>&1 || true

echo "Reproduction" >> README.md
git add README.md
git -c core.hooksPath=.hooks -c user.name=repro -c user.email=repro@example.com \
  commit -q -m "reproduce nx hook issue" || echo "commit failed"

# Daemon's AI status check runs in background; wait for its clone to land.
i=0
while [ ! -d "$TMPDIR/nx-ai-agents-config" ] && [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done
sleep 10

echo "--- git status --short"
status_ok=1
git status --short || status_ok=0
echo "--- index entries not in HEAD"
git ls-tree -r --name-only HEAD | sort > "$tmp/head"
extra=$(git ls-files | sort | comm -23 - "$tmp/head")
echo "${extra:-<none>}"
echo "--- git fsck --full --no-reflogs"
fsck_ok=1
git fsck --full --no-reflogs || fsck_ok=0
echo "--- daemon log: $wt/.nx/workspace-data/d/daemon.log"
grep -iE 'ai agents|clone|configure' "$wt/.nx/workspace-data/d/daemon.log" || true
node_modules/.bin/nx daemon --stop >/dev/null 2>&1 || true

if [ $status_ok -eq 0 ] || [ $fsck_ok -eq 0 ] || [ -n "$extra" ]; then
  echo "REPRODUCED: worktree index corrupted"
  exit 1
fi
echo "NOT REPRODUCED: index intact"
