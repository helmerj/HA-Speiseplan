#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"; cd "$ROOT"
source "$HERE/loop.config"
MN="${1:?Mn}"; mnl="$(printf '%s' "$MN"|tr 'A-Z' 'a-z')"
BASE="${BASE_BRANCH:-main}"        # a repo whose trunk is `dev` set BASE_BRANCH; hardcoding main targeted the wrong trunk
git remote get-url origin >/dev/null 2>&1 || { echo "refuse: no 'origin' remote — configure a GitHub remote before opening PRs" >&2; exit 2; }
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
# Loop branch = LOOP_BRANCH when the repo has its own convention ({type}/{TICKET}-{kebab}), else the
# harness default milestone/*. Anything else is refused exactly as before.
case "$BRANCH" in
  "${LOOP_BRANCH:-milestone/__none__}"|milestone/*) :;;
  *) echo "refuse: not on ${LOOP_BRANCH:-milestone/*} ($BRANCH)" >&2; exit 2;;
esac
[ -z "$(git status --porcelain)" ] || { echo "refuse: tree dirty" >&2; exit 2; }
gout="$("$HERE/gate.sh" "$MN" 2>&1)"; echo "$gout"
echo "$gout"|grep -q 'GATE: PASS' || { echo "refuse: $MN gate not green" >&2; exit 1; }
# The review record is checked ONCE, by gate.sh, which this script has just required to print
# GATE: PASS — status verdict, loop identity, milestone identity and open blocker/major count included.
# A second implementation here drifted from that one the moment gate.sh learned the review-loop header
# schema (`updated <iso> · iteration N · status converged`): the gate accepted it, this guard's
# colon-requiring `status:` regex did not, and a fully green milestone could not open a PR. Two readers
# of one file is the defect; keep exactly one, and extend gate.sh's review_scan when the schema grows.
# Harness changes this milestone made that are not declared local — the upstream candidates. REPORTS,
# NEVER GATES: `|| true` on top of a script that already exits 0 unconditionally, because a milestone
# must never be blocked on another repo's review process. Printed BEFORE the push so the operator sees
# it even if the push or `gh` step fails, and so it is adjacent to the gate output it belongs with.
[ -x "$HERE/upstream-report.sh" ] && { "$HERE/upstream-report.sh" || true; }
# The other half of upstreaming: code goes back to templates/, and what the milestone TAUGHT goes back
# to the recipe's LEARNINGS.md. Each repo used to keep its own list, so the next project rediscovered
# the same defects at the same price — a learning that lives in one repo is one the estate pays for
# twice. Printed, never enforced: a milestone must not be blocked on someone writing prose.
echo "── learnings: append anything generic this milestone taught to the recipe's LEARNINGS.md"
echo "   (claudes-kitchen: plugins/workflows/skills/tdd-loop-run-recipe/LEARNINGS.md — dated, with what it cost)"
git push -u origin "$BRANCH"
body="$(printf '## %s\n\nLands %s via PR (TDD_PLAN §1; no direct push to %s).\n\n```\n%s\n```\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)' "$MN" "$MN" "$BASE" "$gout")"
gh pr create --base "$BASE" --head "$BRANCH" --title "$MN: ${BRANCH#milestone/${mnl}-}" --body "$body"
echo "PR opened; review+merge manually; tag m${MN#M} post-merge."
