#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/loop.config"; source "$HERE/adapters/$STACK.sh"
ROLE="${1:?role}"; MILESTONE="${2:?milestone}"; NOTE="${3:-}"; MODE="${4:-gate}"   # red|fast|mid|step|gate
# --verify: run every check and journal the result, but do NOT consume an R1 iteration. A driver that
# gates a step BEFORE committing and again after was recording the step twice: observed iterations
# 10/11, 12/13 and 15/16 each share one HEAD timestamp and differ only by a few dirty loc, so a
# 4-step milestone burned 8 of its 16 iterations on 4 steps. R1's budget counts TDD STEPS; a pre-commit
# check is the same step. Breakers R6/R7/R8/R12 still trip under --verify — those are real defects whether
# or not the run counts.
COUNT=1; for a in "$@"; do [ "$a" = --verify ] && COUNT=0; done
STATE="$ROOT/$SPEC_DIR/LOOP_STATE.md"; ESC="$ROOT/$SPEC_DIR/ESCALATION.md"; cd "$ROOT"
LOGDIR="${TMPDIR:-/tmp}/tddloop"; mkdir -p "$LOGDIR" "$ROOT/$SPEC_DIR"
# NOTE: this is the HEAD COMMIT's time, not the run's — which is exactly why two runs at one commit are
# indistinguishable by eye in the journal until you compare churn. The @sha below makes it explicit.
ts="$(git log -1 --format=%cI 2>/dev/null||echo unknown)"
head_sha="$(git rev-parse --short HEAD 2>/dev/null||echo none)"
# Count only real iteration headers: `verify` entries and the driver's prose headers ('## M7 review loop
# — converged') must not inflate the number that R1 reads.
n_prev="$(grep -c '^## .*  iter ' "$STATE" 2>/dev/null | tail -1)"; iter="$(( ${n_prev:-0} + 1 ))"
prev_sha="$(grep -E '^## .*(  iter |  verify )' "$STATE" 2>/dev/null | tail -1 | sed -n 's/.*@\([0-9a-f]\{4,\}\).*/\1/p')"
prev_fp="$(grep '^fingerprint:' "$STATE" 2>/dev/null | tail -1 | sed 's/^fingerprint:[[:space:]]*//')"
# ATTEMPTS is the backstop that makes the dedupe below safe to be wrong. It counts every call for this
# milestone — repeats, verifies and all — and never dedupes. R1 arms on iterations OR attempts, so no
# sequence of identical calls can hold the breaker off forever; a mis-deduped retry delays escalation,
# it can no longer prevent it. That is what removes the need for the driver to declare its intent.
att_prev="$(grep -c "^attempt: $MILESTONE " "$STATE" 2>/dev/null | tail -1)"
attempts="$(( ${att_prev:-0} + 1 ))"
# R1 counts THIS milestone, not the whole journal. `grep -c` on an EXISTING but EMPTY file prints "0"
# AND exits 1, so `$(grep -c … ||echo 0)` yielded the two-line value "0\n0" → "syntax error in
# expression", then `ms_iter: unbound variable`, exiting before any gate ran. Capture first, default
# second: correct for a missing, empty, and populated journal alike.
ms_iter_prev="$(grep -c "  $MILESTONE  iter " "$STATE" 2>/dev/null | tail -1)"
ms_iter="$(( ${ms_iter_prev:-0} + 1 ))"
git add -A -N >/dev/null 2>&1||true
# Iteration identity = HEAD + the work in the tree, with the loop's OWN artifacts excluded. Excluding
# $SPEC_DIR is the whole trick: the previous run appended to LOOP_STATE.md, so the naive "HEAD + dirty
# set" of a doubled call is NOT identical — the observed pairs read 1 file/194 loc then 2 files/202 loc,
# and the +1 file / +8 loc was this script's own journal entry. Excluding it makes a doubled call
# byte-identical while a genuine retry (the implementer changed source) is not, so R1 still burns budget
# for retries at an unchanged HEAD — the case that made a HEAD-only dedupe unsafe.
# cksum: POSIX, present on BSD and GNU alike; shasum/sha1sum are not both.
fp_paths="."; [ -n "${SPEC_DIR:-}" ] && fp_paths=". :(exclude)$SPEC_DIR"
# ROLE and MODE are part of the identity: without them a reviewer step straight after an implementer
# commit (clean tree, same HEAD) deduped against it, and a retry of a gate that failed on flaky
# infrastructure — same tree, same HEAD, deliberately re-run — consumed no iteration at all. R1 then
# never armed and the loop retried forever without paging anyone, which is the breaker's whole purpose.
fp="$ROLE:$MODE:$head_sha:$(git diff HEAD -- $fp_paths 2>/dev/null | cksum | tr -d ' ')"
dup=""; [ -n "$prev_fp" ] && [ "$prev_fp" = "$fp" ] && dup=1
# A repeat is the SAME iteration seen twice: journal it for audit, never count it. Reported as a repeat
# rather than dropped, because a silently ignored call looks to the driver like the gate never ran.
[ -n "$dup" ] && COUNT=0
# R8's BASE, and it is the whole breaker. `git diff HEAD` measures the DIRTY TREE, so an iteration
# journaled AFTER its step was committed measures a clean tree and scores zero. Read one driven loop's
# journal: three whole milestones recorded `0 files / 0 loc` at an `@sha` that is the step's own
# commit, while the same commits measured 120–988 code lines when scored from their parents. Only the
# one milestone that happened to gate before committing ever ran dirty — and that milestone is where
# every one of R8's trips came from. So a breaker that was declared, tuned twice, and given a
# statement counter and a per-role budget had been reporting OK by being unmeasured for three
# milestones: this harness's own signature failure, applied to a circuit breaker.
#
# Measuring from the PREVIOUS journalled iteration covers both workflows: the step's commits plus
# anything still dirty. It degrades exactly to the old behaviour when nothing has been committed since
# (base == HEAD), and falls back to HEAD whenever the recorded sha is unusable — a rebased branch, a
# squashed milestone, a fresh journal — because a base that does not resolve must not turn into a
# wrong number or a crash.
#
# The ancestor test is what keeps the FIRST iteration of a new milestone honest, and it is
# load-bearing rather than lucky: where each milestone lands on the integration branch as a SQUASH,
# the previous milestone's journalled sha is not an ancestor of the new HEAD and the base falls back.
# Measured on one such tree: base HEAD scores 56, the previous milestone's pre-squash sha scores 3738,
# and the guard chooses HEAD. Without it, every milestone would open by charging itself the whole of
# the one before.
churn_base=HEAD
if [ -n "$prev_sha" ] \
  && git cat-file -e "${prev_sha}^{commit}" 2>/dev/null \
  && git merge-base --is-ancestor "$prev_sha" HEAD 2>/dev/null; then churn_base="$prev_sha"; fi
read -r files loc < <(git diff --shortstat "$churn_base" 2>/dev/null | awk '{f=0;s=0;for(x=1;x<=NF;x++){if($x~/file/)f=$(x-1);if($x~/insertion|deletion/)s+=$(x-1)}print (f?f:0),s}'||echo "0 0")
files="${files:-0}"; loc="${loc:-0}"
# R8 counts STATEMENTS, not diff lines. The shortstat figure above is kept as `raw` for the journal
# and as the fallback the adapter returns to, because the two numbers DISAGREEING is itself worth
# seeing: a step that writes 600 lines of docstring over 100 of code is a documented step, not a leap,
# and R8 tripped on exactly that four times in one milestone without ever catching a real one. A stack
# whose adapter defines no `churn_loc` is unchanged.
raw="$loc"; prose=0
if command -v churn_loc >/dev/null 2>&1; then set -- $(churn_loc "$raw" "$churn_base"); loc="${1:-$raw}"; prose="${2:-0}"; fi
tc="$(grep -rsE --exclude-dir=node_modules --exclude-dir=build '@Test|\bit\(|\btest\(|def test_' src 2>/dev/null|wc -l|tr -d ' ')"; tc="${tc:-0}"
trip=""; reason=""
"$HERE/check-scope.sh" "$ROLE" >"$LOGDIR/scope.log" 2>&1 || { trip=R6; reason="$(cat "$LOGDIR/scope.log")"; }
# Both budgets are PER ROLE, and both are optional: a loop.config defining neither function keeps the
# flat CHURN_LOC/CHURN_FILES it has today. One number for every role means the breaker can only be
# loose enough to ignore the implementer or tight enough to fire on every RED step — a RED module's
# size is set by the step it specifies, while R8 exists to catch an IMPLEMENTER writing more than the
# step it was handed.
cbud="$CHURN_LOC"; command -v churn_budget >/dev/null 2>&1 && cbud="$(churn_budget "$ROLE")"
# The FILE budget is per-role for the same reason the line budget is, and it was proven separately: a
# flat 15 tripped a test-author at 27 files on a migration the plan itself asked for — threading a
# newly-mandatory parameter through 49 call sites across 19 test files. That work cannot be done in 15
# files, so the breaker was measuring the SHAPE of the work rather than a runaway role. The line
# budget was fine on the same iteration; only the file count fired.
fbud="$CHURN_FILES"; command -v churn_files_budget >/dev/null 2>&1 && fbud="$(churn_files_budget "$ROLE")"
[ -z "$trip" ] && { [ "$loc" -gt "$cbud" ]||[ "$files" -gt "$fbud" ]; } && { trip=R8; reason="churn $files/$loc code lines (raw diff $raw) > $fbud/$cbud for $ROLE"; }
# R12 is the number R8 deliberately stopped measuring. R8 counts statements because prose inflated a
# LEAP detector — four false trips in one milestone, no real ones — but nothing then measured the
# prose, so a step could write 300 lines of docstring for free. UNSET DOC_LOC = off, so an existing
# loop.config is unchanged until it opts in.
dbud=""; [ -n "${DOC_LOC:-}" ] && dbud="$DOC_LOC"
command -v doc_budget >/dev/null 2>&1 && dbud="$(doc_budget "$ROLE")"
[ -z "$trip" ] && [ -n "$dbud" ] && [ "$prose" -gt "$dbud" ] && { trip=R12; reason="prose $prose comment/docstring lines > $dbud for $ROLE (statements $loc) — rationale belongs in docs/rfcs, docs/adr or the commit message"; }
budget="$(iteration_budget "$MILESTONE")"
# Floored by the steps the driver was given (1.8.9, M14 §2.5; loop-driver.sh steps_budget): the
# plan's number predates the split rule and the review rounds' pairs.
if [ -n "${LOOP_STEPS:-}" ] && [ "$LOOP_STEPS" -gt 0 ] 2>/dev/null; then
  # The milestone's review budget as the driver resolves it (review_budget(), the correctness-
  # critical five), not the bare scalar (1.8.9 review pass 7, conformance major 1).
  rb="${REVIEW_BUDGET:-3}"; command -v review_budget >/dev/null 2>&1 && { r_="$(review_budget "$MILESTONE" 2>/dev/null)"; [ -n "$r_" ] && rb="$r_"; }
  sb=$(( 4 * LOOP_STEPS - 2 + 2 * rb )); [ "$sb" -gt "$budget" ] && budget="$sb"
fi
# MODE=red — the RED commit's journal entry. It runs NO gate, on purpose: R7 trips on "unit suite
# failing", which is exactly what a correct RED is, so gating the test-first commit stopped the run on
# every step. Journalling it is still necessary, and not merely bookkeeping: R8 measures churn from the
# last JOURNALLED iteration, so a RED that records nothing hands its own lines to the next
# implementer — measured here as 449 lines charged to an implementer whose commit was 120.
# R6 (scope), R8 (churn, at the test-author's own budget) and R12 are evaluated above and still trip.
if [ "$MODE" = red ]; then
  gline="red: RED commit journalled, no gate run (R7 cannot judge a suite that is red by design)"; rc=0
elif [ "$MODE" = fast ]; then
  # Adapter is sourced at the top, so gate_unit is a function in THIS shell. It previously ran
  # `./gradlew test` with a fallback that EXECUTED adapters/$STACK.sh as a process — which only
  # defines functions, leaving gate_unit undefined here. Every non-gradle stack therefore reported
  # fast: FAIL and tripped R7, making the cheap tier unusable exactly where it saves the most.
  export LOGDIR
  # Affected-tests first: on a one-class change this runs seconds instead of the whole suite. It is a
  # SIGNAL, not proof — it cannot see breakage in tests that don't reference the change, which is why
  # only MODE=gate sets green_proven. SKIP (selector matched nothing / stack can't select) → full suite,
  # so a narrowing that fails to narrow degrades to the old behaviour rather than to a false green.
  sel=SKIP
  command -v gate_unit_affected >/dev/null 2>&1 && sel="$(gate_unit_affected HEAD)"
  case "$sel" in
    PASS|FAIL|PENDING) u="$sel"; scope="affected";;
    *) u="$(gate_unit)"; scope="full";;
  esac
  case "$u" in PASS) gline="fast[$scope]: PASS"; rc=0;; PENDING) gline="fast[$scope]: PENDING"; rc=1;; *) gline="fast[$scope]: FAIL"; rc=1;; esac
  [ -z "$trip" ] && [ "$u" = FAIL ] && { trip=R7; reason="unit suite failing ($scope)"; }
elif [ "$MODE" = mid ]; then
  gout="$("$HERE/gate.sh" "$MILESTONE" mid 2>&1)"; rc=$?; echo "$gout"
  echo "$gout"|grep -q 'build  *FAIL' && [ -z "$trip" ] && { trip=R7; reason="build broken"; }
  gline="$(echo "$gout"|grep GATE: || echo 'GATE: ?')"
elif [ "$MODE" = step ]; then
  # The per-STEP tier: everything the milestone's own correctness rests on (build, unit, integration,
  # coverage) and nothing that only makes sense once the milestone is finished. Deliberately falls in
  # the same branch shape as `mid`, and for the same reason: it CANNOT set green_proven below, so a
  # milestone cannot iterate forever on it un-breakered, and gate.sh's step tier cannot print
  # "GATE: PASS", so nothing downstream can read it as landable.
  gout="$("$HERE/gate.sh" "$MILESTONE" step 2>&1)"; rc=$?; echo "$gout"
  echo "$gout"|grep -q 'build  *FAIL' && [ -z "$trip" ] && { trip=R7; reason="build broken"; }
  gline="$(echo "$gout"|grep GATE: || echo 'GATE: ?')"
else
  gout="$("$HERE/gate.sh" "$MILESTONE" 2>&1)"; rc=$?; echo "$gout"
  echo "$gout"|grep -q 'build  *FAIL' && [ -z "$trip" ] && { trip=R7; reason="build broken"; }
  gline="$(echo "$gout"|grep GATE: || echo 'GATE: ?')"
  [ "$rc" = 0 ] && green_proven=1
fi
# R1 (per circuit-breakers.md): iters_in_milestone > budget AND gates still red — a GREEN milestone may
# land on its budget-th turn. "Green" means the FULL gate proved it: fast/mid/step exit 0 on a cheap
# subset (unit only / no e2e+review), so treating their rc=0 as green let a milestone burn unlimited
# cheap iterations without ever arming R1. Only MODE=gate can set green_proven.
# Two arming conditions, both R1. The first is the budget proper and only a COUNTED call can trip it.
# The second is the backstop: attempts include repeats and --verify, so a loop that never advances the
# iteration count — the dedupe guessing wrong on a genuine retry, or a driver gating in a tight loop —
# still escalates instead of running forever. 2× leaves room for the pre/post-commit pairs --verify and
# the dedupe legitimately absorb, so a compliant loop never sees it.
att_cap="$(( budget * 2 ))"
if [ -z "$trip" ] && [ "${green_proven:-0}" != 1 ]; then
  if [ "$COUNT" = 1 ] && [ "$ms_iter" -gt "$budget" ]; then
    trip=R1; reason="$MILESTONE iter $ms_iter > budget $budget, full gate not proven green"
  elif [ "$attempts" -gt "$att_cap" ]; then
    trip=R1; reason="$MILESTONE attempt $attempts > $att_cap (2× budget $budget), full gate not proven green — counts repeats and --verify, so an un-counted loop still escalates"
  fi
fi
# ── THE CAUSE, AND ITS SIGNATURE ──────────────────────────────────────────────
# Every breaker above counts CONSECUTIVE events: rows that did not pass, invocations at one HEAD,
# iterations past a budget. None of them keys on WHAT failed, so the same failure recurring is
# indistinguishable from three different ones — measured on one loop: R8 tripped 19 times, all on one
# mechanism, each acked separately with a fresh diagnosis; `GATE: NOT GREEN` carried one coverage
# cause for 21 consecutive iterations and was read as normal every time. A cause has to be a VALUE
# before it can be counted. The cause is the breaker's reason when one tripped, else the gate's own
# `cause:` (gate.sh puts it on the verdict line), else the fast tier's verdict; the signature is
# `<breaker-or-gate>:<role>:<cksum>` over that text with every digit and every sha normalised away,
# so `iter 63 > budget 45` and `iter 64 > budget 45` are ONE cause and a percentage that moves is not
# a new one. cksum: POSIX, present on BSD and GNU alike.
cause=""
if [ -n "$trip" ]; then cause="$trip: $reason"
else cause="$(printf '%s' "$gline" | sed -n 's/.*cause: //p')"
  [ -n "$cause" ] || case "$gline" in *FAIL*|*PENDING*) cause="$gline";; esac; fi
# ONE LINE: a scope violation's reason is a file list, and a journal field that spans lines is a
# journal nothing can parse. The first 300 characters carry the tier, the id and the first path.
cause="$(printf '%s' "$cause" | tr '\n\t' '  ' | sed -E 's/[[:space:]]+/ /g' | python3 -c 'import sys; t=sys.stdin.read().replace("\u2014"," - ").replace("\u2013","-"); sys.stdout.write(t[:300])')"  # characters not bytes, no em dashes: see utf8_head in loop-driver.sh
sig=""
if [ -n "$cause" ]; then
  norm="$(printf '%s' "$cause" | sed -E 's/[0-9a-f]{7,}/H/g; s/[0-9]+/N/g; s/[[:space:]]+/ /g')"
  sig="${trip:-gate}:$ROLE:$(printf '%s' "$norm" | cksum | cut -d' ' -f1)"
fi
# How many of the milestone's PREVIOUS journal entries, counted back from the newest, carry this same
# signature (consecutive), and how many carry it anywhere in the milestone (ever). Both matter: the
# first is the stuck loop; the second is the cause that came back after an ack said it was fixed.
# `rep` = how many of the milestone's previous journal entries, counted back from the newest, carry
# this signature (the streak); `seen` = how many entries in the milestone carry it under a trip of
# the same breaker id (the recurrence). The journal keeps the GATE signature on an RC entry so the
# streak survives the trip; ESCALATION.md carries the RC signature the ack answers to.
sig_counts(){ awk -v ms="  $MILESTONE  " -v s="signature: $1" -v b="breaker: $2" '
    /^## / { inms = index($0, ms) > 0; if (inms) { n++; sigs[n] = ""; brk[n] = "" } next }
    inms && index($0, "signature: ") == 1 { sigs[n] = $0 }
    inms && index($0, "breaker: ") == 1 { brk[n] = $0 }
    END { c = 0; for (i = n; i >= 1; i--) { if (sigs[i] == s) c++; else break }
          e = 0; for (i = 1; i <= n; i++) if (sigs[i] == s && (b == "breaker: " || index(brk[i], b) == 1)) e++
          print c, e }' "$STATE" 2>/dev/null; }
rep=0; seen=0; jsig="$sig"
if [ -n "$sig" ] && [ -f "$STATE" ]; then
  read -r rep seen < <(sig_counts "$sig" "${trip:-}"); rep="${rep:-0}"; seen="${seen:-0}"
fi
[ "$rep" -ge 1 ] && echo "cause unchanged for $(( rep + 1 )) iterations — $cause" >&2
# RC — a gate FAILING on ONE cause for REPEAT_CAUSE_LIMIT consecutive iterations is not a loop making
# progress, whatever each role's outcome column says. Keyed on FAIL only: a PENDING tier repeats by
# design until its executor exists, and counting it would bring back the noise this exists to end.
[ -z "$trip" ] && case "$cause" in *FAIL*)
  if [ "$(( rep + 1 ))" -ge "${REPEAT_CAUSE_LIMIT:-3}" ]; then
    trip=RC; reason="gate cause unchanged for $(( rep + 1 )) iterations: $cause"; sig="RC:$ROLE:${sig#*:*:}"
    read -r _ seen < <(sig_counts "$jsig" RC); seen="${seen:-0}"
  fi;; esac
# ── GRADED, SUPPRESSED, REPEATED ──────────────────────────────────────────────
# Not every breaker deserves to stop the run. Measured on one milestone: 38 trips, 23 of them false —
# 19 × R8 on a churn counter that scored a data fixture, 4 × R6 on the driver's own dirty tree — and
# every one of them cost a human stop while the one real, repeating failure was never flagged. So a
# breaker has a GRADE. HARD stops the run as it always did: scope (R5/R6), spend (R13, RI, RI-ABS) and
# the three that mean "nothing left to dispatch" (RU, RD, RW). SOFT warns and continues ONCE; the same
# signature a second time is a hard stop, unless the driver has acked that signature as FALSE — then it
# is suppressed to a warning for the rest of the milestone, and the ack's own output names it as an
# upstream candidate, because a breaker that trips false twice is a harness defect, not a role's.
# RR: a signature the driver acked as TRUE ("fixed") coming back is the loudest stop of all — it quotes
# the ack, because the diagnosis it contradicts is the thing to re-read.
# BREAKER_GRADES=hard restores the old contract for every breaker.
LEDGER="$ROOT/$SPEC_DIR/LOOP_LEDGER.tsv"
breaker_grade(){ [ "${BREAKER_GRADES:-}" = hard ] && { echo hard; return; }
  case "$1" in R5|R6|R13|RI|RI-ABS|RU|RD|RW|RR|RA|RO) echo hard;; *) echo soft;; esac; }
# Only MEASUREMENT breakers can be suppressed by a false ack (see loop-driver.sh breaker_suppressible).
breaker_suppressible(){ case "$1" in R1|R7|R8|R12|RC|RV) return 0;; *) return 1;; esac; }
# Ack rows: col 5 `ack`, col 10 the signature, col 11 the verdict, col 12 the cause the driver typed.
ack_rows(){ [ -f "$LEDGER" ] && awk -F'\t' -v m="$MILESTONE" '$2==m && $5=="ack"' "$LEDGER" 2>/dev/null || true; }
sig_verdict(){ ack_rows | awk -F'\t' -v s="$1" '$10==s {v=$11; c=$12} END{print v "\t" c}'; }
# Two FALSE acks on one breaker ID in one milestone downgrade that whole breaker to warn-only here —
# the ack that did it printed the upstream line; the run does not stop a third time for it.
breaker_downgraded(){ [ "$(ack_rows | awk -F'\t' -v b="$1:" 'index($10,b)==1 && $11=="false"' | wc -l | tr -d ' ')" -ge 2 ]; }
grade_note=""
if [ -n "$trip" ]; then
  grade="$(breaker_grade "$trip")"; verdict=""; ackcause=""
  IFS=$'\t' read -r verdict ackcause <<EOF
$(sig_verdict "$sig")
EOF
  if [ "$verdict" = true ]; then
    trip=RR; reason="$sig recurred after the driver acked it as fixed (\"$ackcause\") — the earlier diagnosis is what to re-read: $cause"; grade=hard
  elif [ "$grade" = hard ]; then
    :   # a false ack on a HARD breaker clears the trip it answered and suppresses nothing (R6 acked
        # false must not switch role separation off for the milestone); the ack said so when written
  elif breaker_suppressible "$trip" && { [ "$verdict" = false ] || breaker_downgraded "${sig%%:*}"; }; then
    grade_note="(suppressed — acked false: \"${ackcause:-breaker downgraded}\")"
    echo "WARN $trip suppressed for $MILESTONE by the driver's ack — $reason" >&2; trip_soft=1
  elif [ "$grade" = soft ] && [ "$seen" -ge 1 ]; then
    reason="$reason [REPEAT #$(( seen + 1 )) of signature $sig — a soft breaker's second occurrence stops the run; ack it with --verdict false to suppress or true when the cause is fixed]"
  elif [ "$grade" = soft ]; then
    grade_note="(warn — first occurrence, run continues; a second occurrence stops)"
    echo "WARN $trip — $reason" >&2
    echo "     first occurrence of signature $sig; the run continues. Ack it: loop-driver.sh record $MILESTONE driver ack --signature $sig --verdict false|true --cause '<why>'" >&2
    trip_soft=1
  fi
fi
if [ "$COUNT" = 1 ]; then hdr="## $ts  $MILESTONE  iter $iter @$head_sha"; label="iter $iter"
elif [ -n "$dup" ]; then hdr="## $ts  $MILESTONE  repeat @$head_sha (not counted; identical to iter ${ms_iter_prev:-0})"; label="repeat"
else hdr="## $ts  $MILESTONE  verify @$head_sha (not counted; after iter ${ms_iter_prev:-0})"; label="verify"; fi
{ echo; echo "$hdr"; echo "role:    $ROLE"; echo "tests:   $tc"; echo "churn:   $files files / $loc code loc (raw diff $raw) since $churn_base"; echo "gates:   $gline"; echo "breaker: ${trip:-OK}${grade_note:+ $grade_note}"; [ -n "$cause" ] && echo "cause:   $cause"; [ -n "$jsig" ] && echo "signature: $jsig"; echo "fingerprint: $fp"; echo "attempt: $MILESTONE $attempts"; echo "note:    ${NOTE:-—}"; } >> "$STATE"
[ -n "$dup" ] && echo "note: identical to iter ${ms_iter_prev:-0} (same HEAD, same work outside \$SPEC_DIR) — journaled as a repeat, no R1 iteration consumed. One TDD step = ONE counted call." >&2
# ESCALATION.md IS A STOP'S RECORD (harness 1.8.9, TT-4348 M12 §2.7, M14 §2.5). Under the driver
# (LOOP_DRIVER=1 in the role's environment) a role's trip is advisory: the driver reads the journal
# entry, grades and acks breakers itself, and the run continued past every one of the four
# ESCALATION.md files roles wrote in M14 - each of them "open" on a tree the driver had moved on
# from, each removed by hand before the PR. The trip is journalled above and printed here; the file
# is written only when nothing is driving, where the file IS the stop.
if [ -n "$trip" ] && [ -z "${trip_soft:-}" ]; then
  if [ "${LOOP_DRIVER:-}" = 1 ]; then
    echo "CIRCUIT BREAKER $trip — journalled (signature $sig); the driver decides. Ack: loop-driver.sh record $MILESTONE driver ack --signature $sig --verdict true|false --cause '<what was found>'" >&2; exit 3; fi
  { echo "TRIP: $trip"; echo "milestone: $MILESTONE $label role: $ROLE"; echo "reason: $reason"; echo "gates: $gline"; echo "signature: $sig"
    echo "ack: loop-driver.sh record $MILESTONE driver ack --signature last --verdict true|false --cause '<what was found>'"; } > "$ESC"
  echo "CIRCUIT BREAKER $trip — wrote $ESC." >&2; exit 3; fi
echo "$label recorded."; [ "${rc:-0}" = 0 ] && exit 0 || exit 1
