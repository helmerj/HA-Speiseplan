#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/loop.config"; source "$HERE/adapters/$STACK.sh"
MILESTONE="${1:?usage: gate.sh <Mn> [mid|step|full]}"; TIER="${2:-full}"
ML="$(printf '%s' "$MILESTONE"|tr 'A-Z' 'a-z')"
cd "$ROOT"; export LOGDIR="${TMPDIR:-/tmp}/tddloop"; mkdir -p "$LOGDIR"
REPORT=""; fail=0
# Fallback only: every adapter defines declares() (see adapters/gradle.sh for why the raw
# `grep -qs PAT a b` idiom answers "no" under ugrep when a candidate path is missing). A LOCAL adapter
# written against an older template will not have it, and gate.sh calls it below — so define it here
# when the sourced adapter did not, rather than losing the migration disclosure to a "command not
# found" that set -uo pipefail does not catch.
command -v declares >/dev/null 2>&1 || declares(){ ge=""; [ "$1" = -E ] && { ge="-E"; shift; }; pat="$1"; shift
  for f in "$@"; do [ -e "$f" ] && grep $ge -rqs "$pat" "$f" && return 0; done; return 1; }
# THE CAUSE, ON THE VERDICT LINE. `GATE: NOT GREEN` was one string for every failure, and one driven
# loop read it as normal for 21 consecutive iterations while the tier table above it said
# `coverage(0%<50)` every time — a real, diagnosable failure that a role with no write access to the
# build file eventually named. A verdict that does not say WHY is a verdict the reader stops reading.
# So the first failing tier and the first diagnostic line of its log ride on the verdict itself, and
# loop-iteration.sh hashes that text into a SIGNATURE so a cause that repeats is counted, not re-read.
# FAIL outranks PENDING: a tier with no executor repeats by design (a mutation scope with no classes
# yet), and a repeat counter keyed on it would be noise, which is the thing this line exists to end.
CAUSE=""; CAUSE_PENDING=""
gate_cause_log(){ case "$1" in build*) echo build.log;; tests*) echo unit.log;; it*) echo it.log;;
  e2e*) echo e2e.log;; mutation*) echo mutation.log;; *) echo;; esac; }
# THE FAILURE BEFORE THE NOISE (harness 1.8.8, TT-4348 M11 §2.3). One grep over six alternations took
# the FIRST match in file order, and a test JVM logs before it fails: the CloudWatch registry's JSON
# line `{"timestamp":...,"message":"error sending metric data."}` matched `[Ee]rror:` two thousand
# lines before `jacocoTestCoverageVerification FAILED`, the verdict said `tests FAIL - {"timestamp"...`,
# and the test-author read the whole log to learn that no test had failed. Two passes now: the lines
# that NAME a failure (`> Task :x FAILED`, `Foo > bar() FAILED`, `BUILD FAILED`, a coverage `Rule
# violated`) first, the generic exception/error shapes only when none of those exists - and a JSON
# log line (`{"` at the start) is never a cause on either pass, it is a log entry.
gate_cause(){ local lf line="" f; lf="$(gate_cause_log "$1")"
  if [ -n "$lf" ] && [ -f "$LOGDIR/$lf" ]; then f="$LOGDIR/$lf"
    line="$(grep -vE '^[[:space:]]*\{"' "$f" 2>/dev/null | grep -m1 -E 'Rule violated|BUILD FAILED|FAILED([^A-Za-z]|$)' | tr -d '\t' | head -c 160)"
    [ -n "$line" ] || line="$(grep -vE '^[[:space:]]*\{"' "$f" 2>/dev/null | grep -m1 -E 'AssertionError|Exception|[Ee]rror:' | tr -d '\t' | head -c 160)"
  fi
  printf '%s %s%s' "$1" "$2" "${line:+ — $line}"; }
gate(){ REPORT="$REPORT$(printf '  %-26s %s' "$1" "$2")
"; case "$2" in
     FAIL)    fail=1; [ -n "$CAUSE" ] || CAUSE="$(gate_cause "$1" "$2")";;
     PENDING) fail=1; [ -n "$CAUSE_PENDING" ] || CAUSE_PENDING="$(gate_cause "$1" "$2")";;
   esac; }
# ...AND THE STEP TIER BEHIND IT (harness 1.8.7). FAIL outranks PENDING, so a pending step tier
# (build, tests, it, coverage) is invisible on this line whenever a milestone tier (mutation, review,
# e2e) failed - which, pre-review, the review tier always does. loop-driver's step readers take a
# milestone-tier cause as "every step tier passed"; with a step tier PENDING that read counted a step
# done over a tree whose step gate was NOT GREEN. The journal carries only this line, so the pending
# step tier travels on it: `cause: review FAIL; step: it PENDING`.
not_green(){ local sfx=""
  case "${CAUSE%% *}" in mutation*|review*|e2e*)
    case "${CAUSE_PENDING%% *}" in build*|tests*|it*|coverage*) sfx="; step: ${CAUSE_PENDING%% *} PENDING";; esac;; esac
  echo "GATE: NOT GREEN — cause: ${CAUSE:-${CAUSE_PENDING:-unknown}}$sfx"; }
b="$(gate_build)"; gate build "$b"
# Fail-fast: a red build makes integration/e2e incapable of producing signal, so running them burns a
# Docker start + a Playwright run to learn nothing. SKIP:build-FAIL is NOT a pass — build FAIL already
# set fail=1, and the status is outside the PASS vocabulary, so no downstream grep can read it as green.
if [ "$b" = FAIL ]; then
  gate tests SKIP:build-FAIL; gate it SKIP:build-FAIL; gate coverage SKIP:build-FAIL
  gate mutation SKIP:build-FAIL
  gate review SKIP:build-FAIL; gate "e2e(@$ML)" SKIP:build-FAIL
  echo "── gate: $MILESTONE ($TIER) ──"; printf '%s' "$REPORT"
  not_green; exit 1
fi
# The coverage floor, PER MILESTONE — the same optional-function shape as iteration_budget() and
# milestone_usd_ceiling(). Both coverage clauses below used the scalar COVERAGE_FLOOR_PCT, so
# COVERAGE_TARGET_PCT had NO READER ANYWHERE: a plan declaring `coverage_line_pct: 80` from M1 onward
# was gated at 70, and a milestone sitting at 71% would have reported coverage PASS against a floor of
# 80 it never met. Third knob found this way after MUTATION_TARGETS and REVIEW_BUDGET_CRITICAL.
#
# M0 keeps its floor of 0: a scaffold has almost no logic to cover, and that exemption was already
# hard-coded here rather than declared. It is now declared in loop.config with the rest.
coverage_floor_for(){ local f=""
  command -v coverage_floor >/dev/null 2>&1 && f="$(coverage_floor "$1" 2>/dev/null)"
  [ -n "$f" ] || { f="$COVERAGE_FLOOR_PCT"; [ "$1" = M0 ] && f=0; }
  printf '%s' "$f"; }

gate tests "$(gate_unit)"
# TIER=mid → build + unit + coverage only; skips the container/browser gates for mid-loop feedback.
# It can NEVER print "GATE: PASS": open-milestone-pr.sh and loop-iteration.sh both grep that string,
# so a mid tier claiming it would let a milestone land without integration/e2e/review ever running.
if [ "$TIER" = mid ]; then
  pct="$(gate_coverage_pct)"; floor="$(coverage_floor_for "$MILESTONE")"
  if [ -n "$pct" ]; then [ "$pct" -ge "$floor" ] && gate "coverage(${pct}%)" PASS || gate "coverage(${pct}%<${floor})" FAIL
  elif [ "$MILESTONE" = M0 ]; then gate coverage SKIP; else gate coverage PENDING; fi
  echo "── gate: $MILESTONE (mid) ──"; printf '%s' "$REPORT"
  [ "$fail" = 0 ] && echo "GATE: MID-OK (it/e2e/review NOT run — full tier required to land)" \
                  || not_green
  exit "$fail"
fi
gate it      "$(gate_integration)"
pct="$(gate_coverage_pct)"; floor="$(coverage_floor_for "$MILESTONE")"
if [ -n "$pct" ]; then [ "$pct" -ge "$floor" ] && gate "coverage(${pct}%)" PASS || gate "coverage(${pct}%<${floor})" FAIL
elif [ "$MILESTONE" = M0 ]; then gate coverage SKIP; else gate coverage PENDING; fi
# TIER=step → build + unit + integration + coverage, and STOP HERE. Everything below this line —
# review, e2e, and whatever longer tier a repo adds after them (mutation, cross-channel) — is
# per-MILESTONE proof, not per-STEP feedback.
#
# JUSTIFIED ON CORRECTNESS, NOT SPEED. Measured on one milestone of a driven loop: mutation +
# cross-channel + e2e together were 17 SECONDS, because mutmut caches its generated mutants and an
# unchanged target set returns almost immediately. (The story this tier came from originally asserted
# ~20 minutes for mutation alone — wrong by three orders of magnitude, and it had reached a commit
# message, a role brief and a Jira ticket before anyone timed it.) So the saving is not the point.
# The point is that a mutation score taken mid-step — on a suite that has just had a FAILING test
# added — is not a low score, it is a meaningless one, and publishing it invites the next reader to
# treat it as signal. A tier that cannot produce signal should not run and should not print a number.
#
# This block's POSITION is the whole mechanism: gate.sh is a straight-line script, so "the step tier
# skips mutation" is a claim about LINE ORDER, and harness-selfcheck.sh asserts it that way — `gate it`
# above this exit, `gate_e2e` below it. Moving this block down past a tier silently re-enables that
# tier for every step; no wording anywhere would change.
#
# It can NEVER print "GATE: PASS" (open-milestone-pr.sh and loop-iteration.sh both grep that string)
# and MODE=step never sets green_proven — a cheaper tier must not buy a milestone unlimited iterations,
# nor let it land on tiers that never ran. Same contract as `mid`, one tier further along.
if [ "$TIER" = step ]; then
  echo "── gate: $MILESTONE (step) ──"; printf '%s' "$REPORT"
  [ "$fail" = 0 ] && echo "GATE: STEP-OK (mutation/review/e2e NOT run — full tier required to land)" \
                  || not_green
  exit "$fail"
fi
# Mutation tier — FULL ONLY, and the tier check above is what enforces it: `mid` has already exited,
# `step` has just exited, and `fast` never reaches gate.sh. It re-runs the covering tests once per
# mutant, so a mid-loop tier carrying it would tax every iteration of the edit/run cycle those tiers
# exist to keep cheap — and a score taken on a suite that has just had a FAILING test added is not a
# low score, it is a meaningless one. TDD_PLANs declare `mutation_score_pct` per milestone and
# `MUTATION_FLOOR_PCT` sat in loop.config with no consumer at all, so a driven loop recorded gate PASS
# on a tier that had no executor. Floor and scope both live in loop.config; the executor is the
# adapter's `gate_mutation` (pytest ships one; a stack without one reports the adapter's own verdict).
#
# Placed AFTER the coverage read on purpose: a mutation runner typically runs the suite inside a COPY
# of the project, and coverage is a GATED number, so the ordering removes any question of the mutation
# run perturbing the figure the lines above just took — without depending on a `--no-cov` flag in some
# other file staying where it is.
if command -v gate_mutation >/dev/null 2>&1; then
  mut="$(gate_mutation "${MUTATION_FLOOR_PCT:-0}")"
  mutpct="$(command -v gate_mutation_pct >/dev/null 2>&1 && gate_mutation_pct)"
  case "$mut" in
    PASS) gate "mutation(${mutpct}%)" PASS;;
    FAIL) gate "mutation(${mutpct}%<${MUTATION_FLOOR_PCT:-0})" FAIL;;
    *)    gate mutation "$mut";;
  esac
  # A survivor list is worth more than the percentage — it names the assertion nobody wrote. Point at
  # it on FAIL rather than leaving a number the reader has to go and re-derive.
  [ "$mut" = FAIL ] && echo "  ↳ mutation: $mutpct% < ${MUTATION_FLOOR_PCT:-0}% over \$MUTATION_TARGETS — surviving mutants are listed at the end of $LOGDIR/mutation.log" >&2
fi
# review gate reads root issues.md = the driver-curated convergence summary; `<lang>-services:review-loop`
# writes review-results/<branch>_issues.md, so the driver refreshes root issues.md after it converges (see SKILL.md).
# Convergence must be STATED, not inferred from the absence of a pattern. The check has now failed
# SHAPE-DEPENDENTLY twice, in both of its halves, and both failures let a milestone through:
#
#   1. denylist era: `grep -qiE '^\s*-?\s*(blocker|major)\b'` matched only a finding written as a list
#      item, so findings written as '## Majors' or '**J1** …' matched nothing and the gate reported
#      review PASS over a summary opening with "2 blockers · 12 majors".
#   2. allowlist era: `status:.*\bconverged\b` matched `converged` ANYWHERE after `status:`, so
#      `Status: NOT CONVERGED` satisfied a check whose entire purpose is to require convergence.
#      Verified by execution: `review PASS` / `GATE: PASS` over a summary listing four open majors.
#      Its two residual nets were still anchored to `- [ ]` list items while the reviewers write
#      findings as `###` headings — so they were inert too, and the gate rested on the broken token.
#
# review_scan therefore reads BOTH facts positionally instead of by pattern shape:
#   status → the token IMMEDIATELY after `status[:]` must BE `converged`, so `not converged`,
#            `exhausted` and `stuck` cannot pass. Accepts both emitted shapes: `Status: CONVERGED`
#            (driver-curated root file) and `updated <iso> · iteration N · status converged`
#            (review-loop schema, no colon).
#   open   → ANY line carrying `[blocker]`/`[major]` counts, heading or list item alike. Three
#            exemptions, none of them a shape guess: a checked box `- [x]`, any line under a heading
#            whose title says resolved/closed/fixed, and an explicit `blocker: none` / `major: 0`
#            (that last one is why an unanchored denylist was wrong — it refused "blocker: none").
# e2e acceptance tag, keyed on the TICKET and not just the milestone.
#
# Under one-ticket-per-loop every loop calls its single milestone M1, so `-Pe2eTag=m1` matched ANY
# `@Tag("m1")` in the tree — including the previous ticket's. Verified: `gate.sh M1` reported
# `e2e(@m1) PASS` for a milestone that had NO acceptance test at all, because the only `@Tag("m1")`
# test in the repo belonged to the previous loop. Same shape as the stale-issues.md trap, and the
# existing ">=1 executed test" guard cannot catch it: it counts executions without asking whose.
#
# Self-contained (derives the ticket from SPEC_DIR) so a fixture can source just this function.
#
# OPT-OUT via `E2E_TAG_TICKET_PREFIX=false` in loop.config, because the reasoning above assumes
# one-ticket-per-loop and INVERTS on an epic-per-loop repo. Where a single ticket owns thirteen
# milestones — m0..m7 then c0..c5 — every bare tag is already globally unique and there is no
# "previous ticket" whose `@c3` could be matched; prefixing would force retagging every shipped spec
# and contradict the plan's own cross-milestone e2e gate for no safety gain. Unset or `true` keeps the
# stock behaviour, so every one-ticket-per-loop repo is unaffected.
e2e_tag(){ ml="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "${E2E_TAG_TICKET_PREFIX:-true}" in false|no|0) printf '%s' "$ml"; return;; esac
  tid="$(basename "${SPEC_DIR:-}" 2>/dev/null | sed -nE 's/^([A-Za-z]+-[0-9]+).*/\1/p' | tr 'A-Z' 'a-z')"
  printf '%s' "${tid:+$tid-}$ml"; }
review_scan(){ awk '
  # `cur` is the section IN EFFECT for this record; `sect` becomes the section for the records that
  # FOLLOW. Evaluating a heading against itself made a finding exempt itself: "### [blocker] Timezone
  # offset not fixed for DST" matched the /fixed/ exemption and the file scored 0 open.
  { l = tolower($0); cur = sect }
  /^#+[[:space:]]/ { sect = tolower($0) }
  # `## Status` on its own line is a heading whose VALUE is the next non-empty line. Latching the
  # heading itself read an empty verdict and failed a genuinely converged review shut.
  want && !seen && l ~ /[^[:space:]]/ {
    s = l; gsub(/[*_`]/, "", s); sub(/^[[:space:]]*[-#>[:space:]]*/, "", s)
    st = s; seen = 1; want = 0
  }
  # The verdict is a line — or a `·`-separated field, the review-loop header schema — that BEGINS with
  # `status`. Matching the word ANYWHERE let prose ("the /status endpoint returned 500") decide it.
  !seen {
    t = l; gsub(/[*_`]/, "", t); gsub("·", ";", t)
    n = split(t, seg, /[;|]/)
    for (i = 1; i <= n && !seen && !want; i++) {
      s = seg[i]
      sub(/^[[:space:]]*/, "", s); sub(/^#+[[:space:]]*/, "", s); sub(/^-[[:space:]]*/, "", s)
      if (s ~ /^status([[:space:]]*:|[[:space:]]|$)/) {
        sub(/^status[[:space:]]*:?[[:space:]]*/, "", s)
        if (s ~ /[^[:space:]]/) { st = s; seen = 1 } else want = 1
      }
    }
  }
  {
    # Third alternative: a bare `Blocker: <text>` line. The denylist this replaced caught it; the first
    # allowlist did not, so a finding written without a dash or brackets scored 0 open.
    if (l ~ /\[(blocker|major)\]/ ||
        l ~ /^[[:space:]]*-[[:space:]]+(blocker|major)[^a-z]/ ||
        l ~ /^[[:space:]]*[#>*_-]*[[:space:]]*(blocker|major)[[:space:]]*:/) {
      # Word-anchored so "unresolved" is not "resolved", and negated headings never exempt: a finding
      # under "## Unresolved" or "## Not yet fixed" is OPEN.
      if (cur ~ /(^|[^a-z])(resolved|closed|fixed)([^a-z]|$)/ &&
          cur !~ /(^|[^a-z])(not|never|yet|open|outstanding|pending)([^a-z]|$)/) next
      if (l ~ /^[[:space:]]*-[[:space:]]*\[[[:space:]]*x[[:space:]]*\]/) next
      if (l ~ /(blocker|major)[[:space:]]*:[[:space:]]*(none|0)([^0-9]|$)/) next
      open++
    }
  }
  END { printf "%s %d\n", (seen ? (st ~ /^converged/ ? "converged" : "notconverged") : "nostatus"), open+0 }
' "$1"; }
#
# The summary must belong to THIS loop AND this milestone: a new loop in a reused repo inherits the
# previous loop's issues.md, whose stale `Status: CONVERGED` satisfied the gate before any review of the
# current work existed.
#
# Checking the milestone id ALONE is not enough, and this is the common case rather than the exotic one:
# under one-ticket-per-loop every loop calls its single milestone M1, so a stale M1 summary from the
# previous ticket passes an M1 check unchanged. The loop identity is the TICKET, taken from SPEC_DIR
# (specs/<TICKET>-<name>), so require BOTH — the ticket catches a foreign loop, the milestone catches a
# foreign milestone inside the same loop.
LOOP_ID="$(basename "${SPEC_DIR:-}" 2>/dev/null | sed -nE 's/^([A-Za-z]+-[0-9]+).*/\1/p')"
#
# Landability of the review RECORD is checked separately below (see review(record)). A repo may
# deliberately gitignore root issues.md — gates read it from DISK — but then the tracked deliverable
# ($SPEC_DIR/ISSUES.md) is the only copy anyone else can see, so its absence means the record exists
# nowhere in git. Disclose the local-only case, FAIL only when neither copy is landable.
if [ -f issues.md ]; then
  rscan="$(review_scan issues.md)"; rstatus="${rscan%% *}"; ropen="${rscan##* }"
  if [ "$rstatus" != converged ]; then
    gate review FAIL
    echo "  ↳ review: issues.md status reads '$rstatus' — the token after 'status' must BE 'converged' (a negated or absent status is not convergence)." >&2
  elif [ -n "$LOOP_ID" ] && ! grep -qF "$LOOP_ID" issues.md; then gate review FAIL   # summary from another loop
  elif ! grep -qE "\b$MILESTONE\b" issues.md; then gate review FAIL                  # summary from another milestone
  elif [ "$ropen" != 0 ]; then
    gate review FAIL
    echo "  ↳ review: $ropen open blocker/major finding(s) in issues.md — shape-independent count (heading or list item alike)." >&2
  else gate review PASS; fi
  # SPEC_DIR carrying no <TICKET>-<name> shape leaves only the milestone check, which cannot separate
  # two loops that both call their milestone M1. Say so rather than implying full coverage.
  [ -z "$LOOP_ID" ] && REPORT="$REPORT$(printf '  %-26s %s' "review(scope)" "milestone-only — no ticket in SPEC_DIR")
"
  # Where the review record LANDS. issues.md is read from disk, so ignoring it does not change how the
  # loop runs — but then nobody reading the PR can see a review happened. Ignoring root issues.md is a
  # legitimate choice (harness + journal local-only) PROVIDED the tracked deliverable exists; if neither
  # copy is in git, gate PASS would be evidence of nothing.
  DELIV="${SPEC_DIR:-}/ISSUES.md"
  if ! git check-ignore -q issues.md 2>/dev/null; then :   # tracked in place — nothing to disclose
  elif [ -f "$DELIV" ] && ! git check-ignore -q "$DELIV" 2>/dev/null; then
    REPORT="$REPORT$(printf '  %-26s %s' "review(record)" "local-only — issues.md gitignored; tracked: $DELIV")
"
  else
    gate "review(record)" FAIL
    echo "  ↳ the review record is in git NOWHERE: issues.md is gitignored and $DELIV is missing or also ignored. Track one of them (anchor the ignore to '/issues.md' and keep $DELIV tracked — a bare 'issues.md' pattern also hides it, case-insensitively on macOS)." >&2
  fi
elif [ "$MILESTONE" = M0 ]; then gate review SKIP; else gate review PENDING; fi
# e2e runs against a LIVE app at BASE_URL — the driver brings it up first (app + its DB). Launch the
# BUILT ARTIFACT (e.g. `java -jar build/libs/*.jar`), not the build tool's run task, so it holds no
# build daemon while the gate's build/test steps run; ensure the runtime matches the build toolchain.
ETAG="$(e2e_tag "$MILESTONE")"
e2e_res="$(gate_e2e "$ETAG")"
# Migration disclosure: a repo whose acceptance tests still carry the bare `@Tag("m<n>")` now finds
# nothing under the ticket-scoped tag, which is correctly PENDING (acceptance for THIS milestone has not
# been written) — but "not written" and "written under the old tag" deserve different sentences, and
# neither may be green. Never upgrades the verdict; only names the rename.
if [ "$e2e_res" = PENDING ] && [ "$ETAG" != "$ML" ] \
   && declares -E "Tag\(\"$ML\"\)|@$ML\b" src e2e; then
  REPORT="$REPORT$(printf '  %-26s %s' "e2e(tag)" "found bare @$ML — retag this milestone's acceptance as @$ETAG")
"
fi
gate "e2e(@$ETAG)" "$e2e_res"
echo "── gate: $MILESTONE ──"; printf '%s' "$REPORT"
[ "$fail" = 0 ] && echo "GATE: PASS" || not_green; exit "$fail"
