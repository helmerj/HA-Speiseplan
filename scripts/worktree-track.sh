#!/usr/bin/env bash
# DRIVER: isolated worktree+branch for a PARALLEL track (SKILL "Parallelization"): independent
# tracks (SDKs/docs/observability) or a contract-first fan-out of file-disjoint steps.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
SLUG="${1:?usage: worktree-track.sh <track-slug> [base-ref]}"; BASE="${2:-$(git rev-parse --abbrev-ref HEAD)}"
REPO="$(basename "$ROOT")"; BRANCH="track/${SLUG}"; WT="../${REPO}-${SLUG}"
[ -e "$WT" ] && { echo "refuse: '$WT' exists" >&2; exit 2; }
git show-ref --verify --quiet "refs/heads/${BRANCH}" && { echo "refuse: branch '${BRANCH}' exists" >&2; exit 2; }
git worktree add "$WT" -b "$BRANCH" "$BASE"
echo "track worktree: $WT (branch '$BRANCH' off '$BASE'). Integrate: git merge $BRANCH then FULL gate+review. Remove: git worktree remove $WT."
