#!/usr/bin/env bash
# Loop state → $SPEC_DIR/LOOP_CLAUDE.md (NOT root CLAUDE.md). Root gets one managed
# @import block so the loop file auto-loads without clobbering the repo's own CLAUDE.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"; ROOTCLAUDE="$ROOT/CLAUDE.md"
source "$ROOT/scripts/loop.config"
LOOP="$SPEC_DIR/LOOP_CLAUDE.md"
# Milestone: read it from the LAST SECTION HEADER that names one, never from the whole file.
# loop-iteration.sh writes '## <ts>  M7  iter 12' and the driver writes prose headers like
# '## M7 review loop — converged', so headers are authoritative. The journal BODY mentions
# milestones constantly ("regression since M3", "carried from M5"), so the previous whole-file
# `grep -oE 'M[0-9]+' | tail -1` reported whichever milestone prose mentioned last rather than the
# one in flight — observed reporting M12 for the duration of an M17 milestone, with the driver
# hand-correcting the line after every checkpoint. Take the last matching header, then its FIRST id.
# The trailing `|| true` is load-bearing under `set -e`: on an EXISTING but EMPTY journal the inner
# greps match nothing and exit non-zero, which aborted the whole script inside the command
# substitution below — no output, no root @import added, non-zero exit, silently.
# The milestone VOCABULARY is the plan's, not the harness's. The old pattern was `M[0-9]+`, which
# assumes every milestone is named M<n>; a loop whose milestones are C0..C5 — a second phase in a repo
# whose journal still holds the first phase's M0..M7 headers — matched an OLD M-header, `tail -1`'d
# it, and reported `Milestone: C-nothing, M1` while five live `C3  iter` headers sat below it unseen.
# Wrong in the worst direction: the auto-state a RESUMING session reads named a milestone finished
# weeks earlier, and a cleared C3 breaker would have been archived as `cleared-m1.md`.
#
# Match the journal's header SHAPE — `## <ts>  <MILESTONE>  iter|verify|repeat …`, exactly what
# loop-iteration.sh writes — rather than a name pattern. Any milestone vocabulary then works, and
# prose in a driver-written header ('## M7 review loop — converged') can never be mistaken for one.
detect_milestone(){ { grep -E '^## .+  [A-Za-z][A-Za-z0-9]*  (iter|verify|repeat) ' "$SPEC_DIR/LOOP_STATE.md" 2>/dev/null \
  | tail -1 | sed -nE 's/^## .+  ([A-Za-z][A-Za-z0-9]*)  (iter|verify|repeat) .*/\1/p' | head -1; } || true; }
# `clear-escalation`: the driver used to do this by hand as
#   rm -f $SPEC_DIR/ESCALATION.md && git add … && git status --porcelain
# An `&&` chain matches NO permission rule even when `rm -f`, `git add` and `git status` are each
# allowlisted, so the loop's own bookkeeping stopped for a prompt. Ownership is unchanged — the DRIVER
# still decides the cause is fixed — but it is now one allowlistable call. Archived, never deleted:
# a cleared trip must stay auditable, same as milestone-start.sh does at a milestone boundary.
if [ "${1:-}" = clear-escalation ]; then
  ms="$(detect_milestone)"; ms="${ms:-M0}"; msl="$(printf '%s' "$ms"|tr 'A-Z' 'a-z')"
  ESCF="$SPEC_DIR/ESCALATION.md"
  [ -f "$ESCF" ] || { echo "checkpoint: no $ESCF to clear"; exit 0; }
  ARCHIVE="$SPEC_DIR/archive"; mkdir -p "$ARCHIVE"; DEST="$ARCHIVE/ESCALATION.cleared-$msl.md"
  # One archive name per MILESTONE meant the SECOND trip in a milestone silently overwrote the
  # first. Measured on a live milestone: clearing an R6 replaced the R8 cleared hours earlier, and
  # that one survived only because it had been committed in between. Two trips between two commits
  # and the first is gone with nothing saying so. "The trip stays auditable" is the whole reason
  # this archives instead of deleting, and a fixed filename quietly undid it for every milestone
  # that trips more than once — which is the normal case: that milestone tripped RF, RI, RV, R8, R6
  # and RS. Suffix on collision.
  if [ -e "$DEST" ]; then n=2
    while [ -e "$ARCHIVE/ESCALATION.cleared-$msl-$n.md" ]; do n=$((n+1)); done
    DEST="$ARCHIVE/ESCALATION.cleared-$msl-$n.md"
  fi
  mv "$ESCF" "$DEST"; git add -A "$SPEC_DIR" 2>/dev/null || true
  echo "checkpoint: cleared escalation → $DEST (archived + staged; the trip stays auditable)"
  git status --porcelain; exit 0
fi
# ${MS:-M0} is load-bearing: the old `tail -1 || echo M0` fallback could never fire, because tail
# succeeds on empty input — a journal whose headers name no milestone wrote an empty Milestone line.
MS="${1:-$(detect_milestone)}"; MS="${MS:-M0}"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null||echo '?')"; head="$(git rev-parse --short HEAD 2>/dev/null||echo '?')"
dirty="$([ -n "$(git status --porcelain)" ] && echo DIRTY || echo clean)"
# Escalation ownership: the DRIVER clears ESCALATION.md once the tripped breaker's cause is fixed;
# milestone-start.sh archives any leftover when a new milestone begins. The harness never deletes it
# mid-milestone — that would hide a live trip. Report which milestone it belongs to so a leftover from
# an earlier milestone is visibly stale instead of reading as 'OPEN' forever.
if [ -f "$SPEC_DIR/ESCALATION.md" ]; then
  # Read the STRUCTURED line loop-iteration.sh writes (`milestone: <MS> <label> role: <role>`), not a
  # name pattern over the whole file. The pattern version was `\bM[0-9]+\b`, which is wrong twice: it
  # cannot see a milestone named C3, and in a repo that has them the first thing it matched in a real
  # escalation was a FINDING ID — `C3-R3-M1` contains a word-bounded `M1` — so a LIVE C3 trip was
  # reported as "STALE (from M1)", i.e. a breaker that had just fired read as safely ignorable.
  esc_ms="$(sed -nE 's/^milestone:[[:space:]]+([A-Za-z][A-Za-z0-9]*)[[:space:]].*/\1/p' "$SPEC_DIR/ESCALATION.md" 2>/dev/null | head -1 || true)"
  # Hand-written escalation with no `milestone:` line: fall back to the CURRENT milestone's own
  # vocabulary (the prefix of $MS) rather than to a hardcoded `M`. Still a guess, but one that can
  # only ever match this loop's naming — and an empty result reports OPEN with no milestone, which is
  # honest, instead of naming the wrong one.
  if [ -z "$esc_ms" ]; then
    pfx="$(printf '%s' "$MS" | sed -nE 's/^([A-Za-z]+)[0-9]+$/\1/p')"
    [ -n "$pfx" ] && esc_ms="$(grep -oE "\\b${pfx}[0-9]+\\b" "$SPEC_DIR/ESCALATION.md" 2>/dev/null | head -1 || true)"
  fi
  esc="OPEN${esc_ms:+ (from ${esc_ms})}"
  [ -n "$esc_ms" ] && [ "$esc_ms" != "$MS" ] && esc="STALE (from $esc_ms, now $MS — driver must clear it)"
else esc=none; fi
last="$(grep '^## ' "$SPEC_DIR/LOOP_STATE.md" 2>/dev/null|tail -3|sed 's/^## /- /'||true)"
# Ensure root CLAUDE.md imports the loop file (idempotent: add block only if absent).
# Root should already exist (seed step runs codebase-analysis:onboarding-repository-recipe
# when absent). Safety net only: warn if missing rather than silently seeding a bare stub.
[ -f "$ROOTCLAUDE" ] || echo "warn: root CLAUDE.md missing — run codebase-analysis:onboarding-repository-recipe" >&2
grep -q "@$SPEC_DIR/LOOP_CLAUDE.md" "$ROOTCLAUDE" 2>/dev/null || {
  { echo "<!-- BEGIN tdd-loop (managed by scripts/checkpoint.sh — do not hand-edit) -->"
    echo "@$SPEC_DIR/LOOP_CLAUDE.md"
    echo "<!-- END tdd-loop -->"; } >> "$ROOTCLAUDE"; }
grep -q 'BEGIN auto-state' "$LOOP" || { echo "$LOOP missing auto-state markers" >&2; exit 1; }
blk="$(mktemp)"; { echo "<!-- BEGIN auto-state (scripts/checkpoint.sh — do not hand-edit) -->"; echo "- Branch: \`$branch\` @ \`$head\` ($dirty)"; echo "- Milestone: $MS"; echo "- Escalation: $esc"; echo "- Recent:"; echo "$last"; echo "<!-- END auto-state -->"; } > "$blk"
awk -v f="$blk" '/<!-- BEGIN auto-state/{while((getline l<f)>0)print l;close(f);s=1;next}/<!-- END auto-state -->/{s=0;next}!s' "$LOOP" > "$LOOP.tmp" && mv "$LOOP.tmp" "$LOOP"; rm -f "$blk"
echo "checkpoint: $LOOP auto-state refreshed ($branch, $MS). Now hand-update Learnings/Decisions/State/Next steps + commit."
