#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"; cd "$ROOT"
source "$HERE/loop.config"
MN="${1:?Mn}"; SLUG="${2:?slug}"; mnl="$(printf '%s' "$MN"|tr 'A-Z' 'a-z')"
BASE="${BASE_BRANCH:-main}"
git checkout "$BASE"; git pull --ff-only origin "$BASE" 2>/dev/null||echo "(local $BASE)"
# LOOP_BRANCH is ONE branch for the whole loop, so every milestone after the first finds it already
# there. `checkout -b` alone exited 128 under `set -e` on M2, stranding the tree on $BASE with M1's work
# off-HEAD and skipping the archiving below — leaving M1's stale `Status: CONVERGED` to clear M2's gate.
BR="${LOOP_BRANCH:-milestone/${mnl}-${SLUG}}"
git checkout -b "$BR" 2>/dev/null || git checkout "$BR"

# A new milestone starts from a clean slate. Two files otherwise leak across milestones:
#
# 1. ESCALATION.md — nothing cleared it, so checkpoint.sh reported "Escalation: OPEN" forever after any
#    breaker trip. Ownership: the DRIVER clears it when the tripped breaker's cause is fixed; this
#    archives whatever is still lying around at the next milestone boundary. The harness never deletes
#    it mid-milestone, which would hide a live trip.
# 2. root issues.md — the review gate reads it BY PATH, so a previous milestone's stale
#    `Status: CONVERGED` made a fresh milestone's review gate report PASS before any review of it
#    existed. Archived here, and gate.sh additionally requires the file to name the current milestone.
ARCHIVE="$SPEC_DIR/archive"
if [ -f "$SPEC_DIR/ESCALATION.md" ]; then
  mkdir -p "$ARCHIVE"; mv "$SPEC_DIR/ESCALATION.md" "$ARCHIVE/ESCALATION.pre-$mnl.md"
  echo "archived a leftover ESCALATION.md → $ARCHIVE/ESCALATION.pre-$mnl.md (verify its cause was actually fixed)"
  archived=1
fi
if [ -f issues.md ]; then
  mkdir -p "$ARCHIVE"; mv issues.md "$ARCHIVE/issues.pre-$mnl.md"
  echo "archived the previous review summary → $ARCHIVE/issues.pre-$mnl.md (this milestone's review gate now starts PENDING)"
  archived=1
fi
# Commit the archive move. Left uncommitted it is a deleted root issues.md plus an untracked
# $SPEC_DIR/archive/ file, both driver-scoped — so the milestone's FIRST check-scope.sh under any other
# role reported an R6 scope violation for bookkeeping the harness itself had just created, and
# loop-iteration.sh escalated and exited 3 before a single gate ran.
if [ -n "${archived:-}" ]; then
  # One pathspec at a time: `git add -A a b c` fails ENTIRELY when any one of them matches nothing (the
  # common case — only one of the two files is usually present), which staged nothing and left the
  # deletion uncommitted, i.e. exactly the R6 this commit exists to prevent.
  for p in "$ARCHIVE" issues.md "$SPEC_DIR/ESCALATION.md"; do
    git add -A -- "$p" >/dev/null 2>&1 || true
  done
  git diff --cached --quiet \
    || git commit -q -m "chore($MN): archive previous milestone's review state" >/dev/null 2>&1 \
    || echo "warn: could not commit the archive — commit it before the first gate or check-scope trips R6" >&2
fi
echo "started $MN on $(git rev-parse --abbrev-ref HEAD)"
