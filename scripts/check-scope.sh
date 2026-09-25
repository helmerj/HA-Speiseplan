#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/loop.config"; source "$HERE/lib/roles.sh"
ROLE="${1:?usage: check-scope.sh <role> [base]}"; BASE="${2:-HEAD}"
CHANGED="$({ git diff --name-only "$BASE" 2>/dev/null||true; git diff --name-only --cached 2>/dev/null||true; git ls-files --others --exclude-standard 2>/dev/null||true; } | sort -u | grep -v -e '^$'||true)"
# loop-iteration.sh appends LOOP_STATE.md (and writes ESCALATION.md on a trip) itself, every iteration.
# Those are harness-written journal, not role output — left uncommitted they showed up here as changes
# outside every role's scope and tripped a false R6 on the next check. Excluded by exact path only:
# $SPEC_DIR/TDD_PLAN.md and the rest of SPEC_DIR stay driver-scoped as before.
CHANGED="$(printf '%s\n' "$CHANGED" | grep -v -x -e "$SPEC_DIR/LOOP_STATE.md" -e "$SPEC_DIR/ESCALATION.md" -e "$SPEC_DIR/LOOP_LEDGER.tsv" -e "$SPEC_DIR/RECOVERY.md" || true)"
# RECOVERY.md is the driver's own digest, rewritten on every breaker trip — at exactly the moment the
# next role is dispatched. Left in the audit it charged that role with a false R6 (TT-4348 M1, twice;
# M2 again). install-harness.sh gitignores it; this is the belt for a repo whose .gitignore predates that.
# LOOP_LEDGER.tsv is loop-driver.sh's journal — one row per role invocation — and it is load-bearing
# for the driver's post-hoc scope audit rather than cosmetic. Left uncommitted (the normal state
# mid-milestone) it is a change outside EVERY role's scope, so the audit would trip a false R6 on the
# NEXT role for the driver's own bookkeeping. Same defect milestone-start.sh's archive step already
# paid for. Harness-written journal, never role output.
# $SPEC_DIR/archive/ is milestone-start.sh's own bookkeeping (the previous milestone's issues.md and
# ESCALATION.md, moved aside). It commits them, so this is belt-and-braces for a repo that gitignores
# the commit or a driver that runs the archive step by hand — either way it is never role output.
CHANGED="$(printf '%s\n' "$CHANGED" | grep -v -e "^$SPEC_DIR/archive/" || true)"
# The driver's STEER ARTIFACT (harness 1.8.6). `loop-driver.sh steer` writes
# review-results/<branch>_<ms>_round<n>_driver_issues.md, and before 1.8.6 it could be written while a
# role was in flight: uncommitted at audit time, it was attributed to that role and R6 stopped the run
# on a clean src/test-only commit (TT-4348 M9 §2.3, $1.96, acked false). The driver writes this file
# and no role does; `steer` now also refuses while a role is in flight, and this is the belt for one
# already on disk. NOT root issues.md, $SPEC_DIR/ISSUES.md or LOOP_CLAUDE.md (narrowed in review of
# the 1.8.6 PR): issues.md is the authority review_converged and gate.sh read, and a role that
# rewrites it must still trip R6 - the in-flight refusal, not a blanket exclusion, is what answers the
# steer case for those.
CHANGED="$(printf '%s\n' "$CHANGED" | grep -v -E '^review-results/.*_driver_issues\.md$' || true)"
viol=""; n=0
while IFS= read -r f; do [ -z "$f" ] && continue; n=$((n+1))
  # Name the role that DOES own each offending path. A bare list of files cannot distinguish "the
  # implementer touched a test" (a real R6) from "the caller passed the wrong role for this step" or
  # "this artifact is in nobody's scope" (e.g. a bookkeeping file just un-gitignored) — three different
  # fixes that used to look identical at the console.
  if ! path_in_scope "$ROLE" "$f"; then
    own="$(owning_roles "$f")"
    viol="$viol  $f  → owned by: ${own:-NO ROLE (unscoped — add it to DRIVER_SCOPE or gitignore it)}
"
  fi
done <<EOF
$CHANGED
EOF
if [ -n "$viol" ]; then echo "SCOPE VIOLATION — role '$ROLE' outside write-scope:" >&2
  printf '%s' "$viol" >&2; echo "Allowed:" >&2; role_globs "$ROLE"|sed 's/^/  /' >&2
  echo "If the listed owner is another role, the STEP was committed under the wrong role — pass the role that AUTHORED the change; a step touching two scopes needs two commits (test first: RED before GREEN)." >&2
  exit 1; fi
echo "scope OK — '$ROLE': $n changed file(s), all in-scope"
