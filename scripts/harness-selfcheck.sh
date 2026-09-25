#!/usr/bin/env bash
# harness-selfcheck.sh — prove the installed harness still BEHAVES, not that it still reads well.
#
# WHY
# ---
# `install-harness.sh` cp's every script unconditionally, and the templates have regressed once
# already: #78 landed a set of hardening fixes, was reverted wholesale, and #85 re-landed an OLDER
# branch point — shipping a recipe whose gate scores an open blocker as zero. A repo that reinstalled
# in that window was silently downgraded, and nothing anywhere would have said so.
#
# A grep for a comment cannot catch that: the regressed copies carry the same prose. So every check
# below drives the real function over a fixture and asserts the ANSWER, and every extraction asserts
# it actually extracted something first — a pattern that silently matches nothing is the same false
# green these checks exist to prevent.
#
# Run it after any change to scripts/, and in CI if the repo has one.
#   scripts/harness-selfcheck.sh     exit 0 = intact, 1 = drifted
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fails=0
ok(){  printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad(){ printf '  \033[31m✗\033[0m %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }
echo "── loop harness self-check ──"

# ── 1. gate.sh review_scan reads BOTH facts positionally ─────────────────────
# The regressed form scans for "status" anywhere on a line and evaluates a heading against ITSELF,
# so a finding titled "…not fixed for DST" exempts itself and a `## Status` heading whose value is
# on the next line reads as an empty verdict. It fails a converged review shut AND scores an open
# blocker as zero — both directions wrong, in one function.
scan="$WORK/scan.sh"
sed -n '/^review_scan(){/,/^'"'"' "\$1"; }/p' "$HERE/gate.sh" > "$scan"
if ! grep -q '^review_scan(){' "$scan" || ! bash -n "$scan" 2>/dev/null; then
  bad "review_scan could not be extracted from gate.sh" "its shape changed — update this check rather than deleting it"
else
  printf '# Review — TICKET-1 M1\n## Status\nCONVERGED\n### [blocker] Timezone offset not fixed for DST\n' > "$WORK/a.md"
  printf '# Review — TICKET-1 M1\nStatus: NOT CONVERGED\n### [blocker] something real\n'                    > "$WORK/b.md"
  printf '# Review — TICKET-1 M1\nupdated 2026-01-01 · iteration 3 · status converged\nblocker: none\n'      > "$WORK/c.md"
  # shellcheck disable=SC1090
  . "$scan"
  ra="$(review_scan "$WORK/a.md")"; rb="$(review_scan "$WORK/b.md")"; rc="$(review_scan "$WORK/c.md")"
  [ "$ra" = "converged 1" ]    && ok "review_scan: heading status + self-exempting finding → $ra" \
    || bad "review_scan: heading status + self-exempting finding" "expected 'converged 1', got '$ra'"
  [ "$rb" = "notconverged 1" ] && ok "review_scan: 'NOT CONVERGED' → $rb" \
    || bad "review_scan: negated status" "expected 'notconverged 1', got '$rb'"
  [ "$rc" = "converged 0" ]    && ok "review_scan: review-loop header schema → $rc" \
    || bad "review_scan: review-loop header schema" "expected 'converged 0', got '$rc'"
fi

# ── 2. exactly ONE reader of issues.md ───────────────────────────────────────
# The regressed open-milestone-pr.sh re-implements the review check with `status:.*\bconverged\b`,
# which MATCHES "Status: NOT CONVERGED", and with finding nets anchored to `- [ ]` list items while
# reviewers write findings as headings. All three of its guards pass on a NOT-CONVERGED summary
# carrying an open blocker.
if grep -q 'GATE: PASS' "$HERE/open-milestone-pr.sh" \
   && ! grep -qE '^[^#]*grep .*status:.*converged' "$HERE/open-milestone-pr.sh"; then
  ok "open-milestone-pr.sh: the review verdict comes from gate.sh alone"
else
  bad "open-milestone-pr.sh re-implements the review check" "its status regex accepts 'NOT CONVERGED'; keep exactly one reader"
fi

# ── 3. R1 identity and its backstop ──────────────────────────────────────────
grep -q '^fp="\$ROLE:\$MODE:\$head_sha' "$HERE/loop-iteration.sh" \
  && ok "loop-iteration.sh: fingerprint is ROLE:MODE:HEAD:tree" \
  || bad "loop-iteration.sh: fingerprint dropped ROLE/MODE" "a role change at one HEAD dedupes to a repeat and R1 never arms"
grep -q 'att_cap=' "$HERE/loop-iteration.sh" \
  && ok "loop-iteration.sh: attempts backstop present (R1 arms on iterations OR attempts)" \
  || bad "loop-iteration.sh: attempts backstop removed" "a mis-deduped retry can hold R1 off indefinitely"

# ── 4. milestone-start is idempotent and commits its own bookkeeping ─────────
grep -q 'git checkout -b .* || git checkout' "$HERE/milestone-start.sh" \
  && ok "milestone-start.sh: reuses an existing LOOP_BRANCH instead of exiting 128" \
  || bad "milestone-start.sh: bare 'checkout -b'" "every milestone after the first strands the tree on \$BASE and skips archiving"
grep -q 'archive previous milestone' "$HERE/milestone-start.sh" \
  && ok "milestone-start.sh: commits the archive move" \
  || bad "milestone-start.sh: leaves the archive uncommitted" "the milestone's first check-scope reports R6 for the harness's own bookkeeping"
grep -q 'SPEC_DIR/archive' "$HERE/check-scope.sh" \
  && ok "check-scope.sh: archive/ is not role output" \
  || bad "check-scope.sh: archive/ counts as a scope violation" "R6 before any gate runs"

# ── 5. the review workspace is clean when it is reused ───────────────────────
grep -q 'reset -q --hard' "$HERE/review-workspace.sh" \
  && ok "review-workspace.sh: a reused worktree is reset to HEAD" \
  || bad "review-workspace.sh: reuses a dirty worktree" "a mutation from a crashed probe survives and the reviewer blames the implementer"

# ── 6. the driver, and every knob it must read ───────────────────────────────
# REVIEW_BUDGET, STALL_ITERATIONS, REPEAT_FAILURE_LIMIT and the whole MODEL_* profile were declared
# in loop.config and read by NOTHING until loop-driver.sh existed. A declared limit with no reader
# reports compliance by being unmeasured — one repo ran five review rounds against a budget of 3.
if [ ! -x "$HERE/loop-driver.sh" ]; then
  bad "loop-driver.sh is missing" "role sequencing, review-round limits and model selection fall back to prose"
else
  miss=""
  for k in REVIEW_BUDGET STALL_ITERATIONS REPEAT_FAILURE_LIMIT MODEL_TEST_AUTHOR MODEL_IMPLEMENTER MODEL_REVIEWER; do
    grep -qE '\$\{?'"$k"'\b' "$HERE/loop-driver.sh" || miss="$miss $k"
  done
  # Label names the SIX knobs actually checked. It used to read "every stop-condition and model knob
  # in loop.config", which was broader than the list below and therefore false: FLAKE_RERUN_COUNT
  # (R10) and COVERAGE_DROP_TOLERANCE_PCT (R5's coverage clause) are declared in loop.config and have
  # NO reader anywhere in scripts/. Neither is added here, because a check that fails on day one is
  # not a check — they need executors first. A self-check whose label is wider than its body is the
  # same defect it exists to catch, one level up.
  [ -z "$miss" ] && ok "loop-driver.sh reads the six stop-condition + model knobs it enforces" \
    || bad "loop-driver.sh ignores loop.config knobs:$miss" "a declared limit with no reader is decoration"
  grep -q 'milestone_model' "$HERE/loop-driver.sh" \
    && ok "loop-driver.sh honours milestone_model() for the implementer" \
    || bad "loop-driver.sh ignores milestone_model()" "loop.config documents it as the implementer spawn's model override"
  grep -q 'DRY=1' "$HERE/loop-driver.sh" && grep -q -- '--yes' "$HERE/loop-driver.sh" \
    && ok "loop-driver.sh: run is a DRY RUN unless --yes is typed" \
    || bad "loop-driver.sh spawns by default" "an autonomous driver must make spending explicit"
  # Effort must be RESOLVED and PASSED, not merely declared. TT-3175's AC says both `model` and
  # `effort` overrides reach the spawn; the effort half was declared in loop.config.template,
  # documented in harness-scripts.md and exported from kitchen.env while the driver never mentioned
  # it. Both halves are asserted, because either alone is the defect: a resolver nothing calls, or a
  # flag built from a variable nothing sets.
  # 1.8.0 split the spawn into brief → launch → collect; the flag is built in spawn_brief (S_EFF) and
  # passed by spawn_launch, which is the one line every role — and every dimension of a parallel
  # round — goes through.
  grep -q '^effort_for()' "$HERE/loop-driver.sh" && grep -q 'S_EFF="--effort \$eff"' "$HERE/loop-driver.sh" \
    && grep -q 'claude -p --model "\$S_MODEL" \$S_EFF' "$HERE/loop-driver.sh" \
    && ok "loop-driver.sh: effort is resolved per role AND passed on the spawn" \
    || bad "effort is declared but never reaches a spawn" "the fourth knob in this harness to be documented and read by nothing"
  # next_role must RE-RUN a role that did not pass, for BOTH TDD roles. The implementer branch always
  # did; the test-author branch advanced unconditionally, so an `r6` test-author with its RED
  # staged-but-uncommitted handed that file to the implementer and scored a second, false R6 against
  # the wrong role. Checked per-role because the asymmetry is exactly what hid it.
  ta="$(sed -n 's/^ *test-author) *\(.*\);;/\1/p' "$HERE/loop-driver.sh")"
  im="$(sed -n 's/^ *implementer) *\(.*\);;/\1/p' "$HERE/loop-driver.sh")"
  case "$ta$im" in
    *last_outcome*last_outcome*) ok "next_role: a non-passing test-author AND implementer are both re-run, not advanced past";;
    *) bad "next_role advances past a role that did not pass" "the step is dropped ungated, and its uncommitted work is audited against the NEXT role";;
  esac
  # A role that backgrounds its gate has not been gated: under `claude -p` the turn is the process,
  # so the gate is orphaned, the iteration never journals, and whatever it writes lands mid-audit.
  # Matched on the EMITTED line, not on the word: falsifying an earlier version of this check by
  # removing FOREGROUND from the `echo` left it GREEN, because the comment above it explaining why
  # still contained the word. A self-check satisfied by its own rationale measures nothing.
  grep -qE '^ *echo "Run it in the FOREGROUND' "$HERE/loop-driver.sh" \
    && grep -qi 'never run a command in the background' "$HERE/ROLE_PROMPTS.md" 2>/dev/null \
    && ok "role brief: the gate is required to run in the foreground, in the brief and in ROLE_PROMPTS" \
    || bad "role brief does not forbid backgrounding the gate" "an abandoned gate reports nothing and its writes trip the driver's scope audit"
fi

# ── 7. the `step` tier is defined by its POSITION, not by its name ───────────
# gate.sh is a straight-line script, so "the step tier skips the long tiers" is a claim about LINE
# ORDER and nothing else. Asserted that way: integration ABOVE the exit, review and e2e BELOW it.
# Moving the block down past a tier re-enables that tier for every step and no wording would change.
# The verdict string is checked too — a cheap tier that could print "GATE: PASS" would let a milestone
# land on tiers that never ran, which is the one thing a cheap tier must never buy.
ln_it="$(grep -n '^gate it ' "$HERE/gate.sh" | head -1 | cut -d: -f1)"
ln_step="$(grep -n '^if \[ "\$TIER" = step \]' "$HERE/gate.sh" | head -1 | cut -d: -f1)"
ln_rev="$(grep -n '^if \[ -f issues.md \]' "$HERE/gate.sh" | head -1 | cut -d: -f1)"
ln_e2e="$(grep -n '^e2e_res="\$(gate_e2e' "$HERE/gate.sh" | head -1 | cut -d: -f1)"
if [ -z "$ln_step" ]; then
  bad "gate.sh has no 'step' tier" "loop-iteration.sh MODE=step calls it; without the block the full tier runs on every step"
elif [ -z "$ln_it" ] || [ -z "$ln_rev" ] || [ -z "$ln_e2e" ]; then
  bad "gate.sh: could not locate the integration/review/e2e tiers" "their shape changed — update this check rather than deleting it"
else
  [ "$ln_it" -lt "$ln_step" ] && [ "$ln_step" -lt "$ln_rev" ] && [ "$ln_rev" -lt "$ln_e2e" ] \
    && ok "gate.sh: step tier sits AFTER integration (line $ln_it) and BEFORE review/e2e ($ln_rev/$ln_e2e)" \
    || bad "gate.sh: the step tier is in the wrong place (it=$ln_it step=$ln_step review=$ln_rev e2e=$ln_e2e)" \
           "a step exit below a tier means that tier runs on every step; above integration means the step tier proves less than it claims"
  sed -n "${ln_step},$(( ln_step + 8 ))p" "$HERE/gate.sh" | grep -q 'GATE: STEP-OK' \
    && ! sed -n "${ln_step},$(( ln_step + 8 ))p" "$HERE/gate.sh" | grep -q 'GATE: PASS' \
    && ok "gate.sh: the step tier prints STEP-OK and can never print GATE: PASS" \
    || bad "gate.sh: the step tier's verdict string is wrong" "open-milestone-pr.sh greps 'GATE: PASS' — a cheap tier printing it lands a milestone on tiers that never ran"
fi
# MODE=step must not arm green_proven either — the same rule one artifact along.
if grep -q 'MODE" = step' "$HERE/loop-iteration.sh"; then
  gp="$(grep -n 'green_proven=1' "$HERE/loop-iteration.sh" | wc -l | tr -d ' ')"
  ln_mstep="$(grep -n 'MODE" = step' "$HERE/loop-iteration.sh" | head -1 | cut -d: -f1)"
  ln_gp="$(grep -n 'green_proven=1' "$HERE/loop-iteration.sh" | head -1 | cut -d: -f1)"
  [ "$gp" = 1 ] && [ "$ln_mstep" -lt "$ln_gp" ] \
    && ok "loop-iteration.sh: MODE=step runs before the only green_proven assignment (the full-gate branch)" \
    || bad "loop-iteration.sh: MODE=step can set green_proven" "a cheap tier that proves green buys the milestone unlimited iterations un-breakered"
else
  bad "loop-iteration.sh has no MODE=step" "the step tier exists in gate.sh with no caller — a tier nothing invokes saves nothing"
fi

# ── 8. the heartbeat, driven — not grepped ───────────────────────────────────
# Asserted by EXECUTION over a real child process, because the two ways this can be wrong are both
# invisible to a grep: a beat that never fires, and a wait that loses the child's exit status. The
# second would silently turn every failing role into a pass.
hb="$WORK/hb.sh"
sed -n '/^file_mtime(){/,/^  wait "\$pid"; rc=\$?; return \$rc; }/p' "$HERE/loop-driver.sh" > "$hb"
if ! grep -q '^wait_with_heartbeat(){' "$hb" || ! bash -n "$hb" 2>/dev/null; then
  bad "the heartbeat could not be extracted from loop-driver.sh" "a role that prints nothing until it exits is indistinguishable from a hung one — that is how four invocations were killed mid-flight in one milestone"
else
  # shellcheck disable=SC1090
  LOGDIR="$WORK" HEARTBEAT_SECS=1 . "$hb"
  LOGDIR="$WORK"; HEARTBEAT_SECS=1
  sleep 3 & p1=$!
  wait_with_heartbeat "$p1" test-author "$(date +%s)" > "$WORK/beat.txt" 2>&1; hrc=$?
  beats="$(grep -c 'elapsed' "$WORK/beat.txt" || true)"
  [ "$hrc" = 0 ] && [ "${beats:-0}" -ge 1 ] \
    && ok "heartbeat: $beats beat(s) while a 3s role ran, naming elapsed/HEAD/newest artifact" \
    || bad "heartbeat: did not beat while a role ran (beats=${beats:-0}, rc=$hrc)" "the operator's only signal that a long role is alive"
  ( sleep 1; exit 7 ) & p2=$!
  wait_with_heartbeat "$p2" implementer "$(date +%s)" > /dev/null 2>&1; hrc2=$?
  [ "$hrc2" = 7 ] \
    && ok "heartbeat: the role's exit status survives the wait (7 in, 7 out)" \
    || bad "heartbeat: the role's exit status is lost (expected 7, got $hrc2)" "every failing role would be recorded as a pass"
fi
# Anchored to a NON-COMMENT line, because the driver's own header explains why it does not use
# stream-json — and the first version of this check read that explanation as the offence.
grep -qE '^[^#]*--output-format[[:space:]]+json' "$HERE/loop-driver.sh" \
  && ! grep -qE '^[^#]*--output-format[[:space:]]+stream-json' "$HERE/loop-driver.sh" \
  && ok "loop-driver.sh: the spend record stays parseable (json, not stream-json)" \
  || bad "loop-driver.sh: switched to stream-json" "cosmetic progress bought at the cost of usage/total_cost_usd — the ledger and the cost report both read them"

# ── 9. --step reaches milestone_model, and no --step is SAFE ─────────────────
# Two halves, deliberately separated. The PASS-THROUGH is the frozen harness's job and is proven
# against a stub, so it holds whatever a project's loop.config says. The CONTRACT — no step yields the
# safe model — belongs to loop.config, which is the one per-project file, and is proven against the
# real one: a config still on the old one-argument shape answers a missing --step with the CHEAP
# model, which is the failure this flag exists to make impossible.
# Extracted from `model_rank` rather than from `model_for`, because model_for now delegates to
# base_model_for/correctness_critical/escalate_to — a range starting at model_for sources a function
# whose helpers are undefined, and this check would fail for a reason that has nothing to do with
# --step. Widened when escalation landed; caught by running it, not by reading it.
mf="$WORK/mf.sh"; sed -n '/^model_rank(){/,/MODEL_SEARCH:-haiku}";; esac; }/p' "$HERE/loop-driver.sh" > "$mf"
if ! grep -q '^model_for(){' "$mf" || ! bash -n "$mf" 2>/dev/null; then
  bad "model_for could not be extracted from loop-driver.sh" "its shape changed — update this check rather than deleting it"
else
  got="$( MS=M3 STEP=3c
    milestone_model(){ printf 'stub:%s:%s' "$1" "${2:-NOSTEP}"; }
    # shellcheck disable=SC1090
    . "$mf"; model_for implementer )"
  [ "$got" = "stub:M3:3c" ] \
    && ok "loop-driver.sh: --step is passed to milestone_model as its second argument ($got)" \
    || bad "loop-driver.sh: --step never reaches milestone_model (got '$got')" "the flag would be accepted, printed, and ignored — the fifth knob in this harness to be declared and read by nothing"
fi
if [ -f "$HERE/loop.config" ]; then
  # shellcheck disable=SC1090
  safe="$( . "$HERE/loop.config" >/dev/null 2>&1
           command -v milestone_model >/dev/null 2>&1 || { echo NOFUNC; exit 0; }
           printf '%s|%s' "$(milestone_model M3)" "${MODEL_IMPLEMENTER:-}" )"
  case "$safe" in
    NOFUNC) ok "loop.config defines no milestone_model — the flat MODEL_IMPLEMENTER applies (nothing to check)";;
    *) [ "${safe%%|*}" = "${safe##*|}" ] \
         && ok "loop.config: milestone_model with no step yields the SAFE model (${safe%%|*})" \
         || bad "loop.config: no --step yields '${safe%%|*}', not the safe '${safe##*|}'" \
                "forgetting --step must cost money, never correctness — take the two-argument milestone_model() from loop.config.template";;
  esac
fi

# ── 10. the brief is PRECOMPUTED, and the reviewer is scoped ─────────────────
# Cost and wall-clock scale with TURNS × CONTEXT (one implementer: 12.1M cache-read tokens for 48k of
# output), so discovery the driver could have done is the most expensive kind of work a role does.
# plan_section is driven over a fixture rather than grepped, because its failure mode is a silently
# EMPTY excerpt — the same shape as the `tr` bug that shipped briefs with no role rules at all.
ps="$WORK/ps.sh"; sed -n '/^plan_section(){/,/^  '"'"' "\$PLAN"; }/p' "$HERE/loop-driver.sh" > "$ps"
if ! grep -q '^plan_section(){' "$ps" || ! bash -n "$ps" 2>/dev/null; then
  bad "plan_section could not be extracted from loop-driver.sh" "without it every role re-discovers its own plan text, at the role's model, in the role's context"
else
  printf '# Plan\n## M1 — first\nm1 body\n### Step 1a\nstep body\n## M10 — tenth\nm10 body\n' > "$WORK/plan.md"
  # shellcheck disable=SC1090
  . "$ps"
  sec="$(PLAN="$WORK/plan.md" plan_section M1)"
  grep -q 'm1 body' <<< "$sec" && grep -q 'step body' <<< "$sec" \
    && ! grep -q 'm10 body' <<< "$sec" \
    && ok "plan_section: M1's block (incl. its steps) is extracted and M10's is not" \
    || bad "plan_section: wrong block (got: $(printf '%s' "$sec" | tr '\n' '/'))" "an empty or over-wide excerpt is worse than none — the role trusts it instead of the file"
fi
# The LAST section of ROLE_PROMPTS.md is the reviewer's, and the extraction that feeds every brief used
# to eat its closing ``` fence — leaving an unterminated code block that swallowed the "When you are
# done" instructions, the foreground-gate rule among them. Driven over the real file, on the real last
# section, because that is the only section that can expose it.
so="$WORK/so.sh"; sed -n '/^section_of(){/p' "$HERE/loop-driver.sh" > "$so"
if ! grep -q '^section_of(){' "$so"; then
  bad "section_of could not be extracted from loop-driver.sh" "the brief's role-rules extraction changed shape — update this check rather than deleting it"
else
  # shellcheck disable=SC1090
  ( HERE="$HERE"; . "$so"
    lastsec="$(grep '^## [A-Z]' "$HERE/ROLE_PROMPTS.md" | tail -1)"
    body="$(section_of "$lastsec")"
    fences="$(printf '%s\n' "$body" | grep -c '^```' || true)"
    [ "$(( fences % 2 ))" = 0 ] && [ "$fences" -gt 0 ] ) \
    && ok "section_of: the LAST ROLE_PROMPTS section keeps its closing fence (balanced)" \
    || bad "section_of: the last section's trailing line is eaten" "the reviewer brief ends in an unterminated code block and the 'When you are done' rules are swallowed into it"
fi
grep -q 'findings_for "\$role"' "$HERE/loop-driver.sh" \
  && ok "loop-driver.sh: review findings reach the brief split by write-scope" \
  || bad "loop-driver.sh: the brief no longer pastes scoped findings" "the role re-reads issues.md and works out its own scope, which is the discovery this change removed"
# Matched on the EMITTED lines, never on the rationale above them: falsifying an earlier check of this
# shape by deleting its `echo` left it green, because the comment explaining it still had the words.
grep -qE '^ *echo "\\`scripts/\\` is the LOOP HARNESS' "$HERE/loop-driver.sh" \
  && grep -q 'git diff \$(review_base)..HEAD' "$HERE/loop-driver.sh" \
  && ok "reviewer brief: scoped to the diff since the last round, and told scripts/ is harness" \
  || bad "reviewer brief: unscoped" "4 of 6 reviewer invocations in one milestone — \$22.99 — were spent re-reviewing the harness and work an earlier round had already passed"
grep -qi 'read-only inspection may be chained' "$HERE/ROLE_PROMPTS.md" 2>/dev/null \
  && grep -qi 'anything that WRITES is one command per Bash call' "$HERE/ROLE_PROMPTS.md" 2>/dev/null \
  && ok "ROLE_PROMPTS: reads may be chained, writes stay one-command-per-call" \
  || bad "ROLE_PROMPTS: the chaining rule is missing or applies to reads too" "the rule exists for permission allowlisting a WRITE; applied to reads it buys nothing and costs a round trip each time"

# ── 11. a killed role is not entered as free ─────────────────────────────────
# `record` wrote SEVEN fields into a NINE-column ledger, always with 0 seconds. Every hand-recorded
# row — which is every killed role — was therefore unmeasured, and `cost` summed it as $0.
rec="$(sed -n '/^record)/,/^consolidate)/p' "$HERE/loop-driver.sh")"
nfields="$(printf '%s' "$rec" | grep -o '%s\\t' | wc -l | tr -d ' ')"
grep -q 'usage_tokens "\$FROM"' <<< "$rec" && [ "${nfields:-0}" -ge 8 ] \
  && ok "record: writes all 9 ledger columns and can read a killed role's spend from its result file" \
  || bad "record: a hand-recorded row is short or free (fields=${nfields:-0})" "a killed role entered as \$0 makes the ledger — the only artifact that says what the loop cost — wrong in the direction that hides it"
grep -q 'role="\$ROLE_ONCE"; ROLE_ONCE=""' "$HERE/loop-driver.sh" \
  && ok "loop-driver.sh: --role steers ONE spawn and then clears" \
  || bad "loop-driver.sh: --role does not clear after one invocation" "a sticky override pins every remaining spawn to one role and silently stops sequencing"

# ── 12. the mutation tier has an EXECUTOR, and the step tier exits before it ─
# `MUTATION_FLOOR_PCT` sat in loop.config with no reader anywhere while TDD_PLANs declared
# `mutation_score_pct` per milestone: two consecutive milestones of one driven loop recorded a gate
# PASS naming a tier that did not exist. Both ends are asserted, because either alone is the defect —
# an adapter function nothing calls, or a gate row computed from a floor nothing measures.
ln_mut="$(grep -n '^  mut="\$(gate_mutation ' "$HERE/gate.sh" | head -1 | cut -d: -f1)"
if [ -z "$ln_mut" ]; then
  bad "gate.sh never calls gate_mutation" "MUTATION_FLOOR_PCT and MUTATION_TARGETS become numbers nothing reads — a declared gate reports PASS by being unmeasured"
else
  grep -q 'gate_mutation_pct' "$HERE/gate.sh" \
    && ok "gate.sh: the mutation tier is wired (verdict + percentage)" \
    || bad "gate.sh calls gate_mutation but never reads a score" "the row would report PASS/FAIL with no number behind it"
  # Position, like the step tier itself: gate.sh is a straight-line script, so "the step tier skips
  # mutation" is a claim about LINE ORDER and nothing else. A mutation run on a tree that has just had
  # a FAILING test added measures nothing and costs a full re-run of the covering suite per mutant.
  if [ -n "${ln_step:-}" ] && [ -n "${ln_rev:-}" ]; then
    [ "$ln_step" -lt "$ln_mut" ] && [ "$ln_mut" -lt "$ln_rev" ] \
      && ok "gate.sh: mutation runs after the step exit (line $ln_step) and before review ($ln_rev)" \
      || bad "gate.sh: the mutation tier is on the wrong side of the step exit (step=$ln_step mutation=$ln_mut review=$ln_rev)" \
             "above the exit, every role pays mutmut on every iteration — including test-authors whose gate is RED by construction"
  fi
fi
# The score itself, DRIVEN. Two ways a mutation gate lies, both invisible to a grep: counting timeouts
# or `suspicious` as kills (rounds in its own favour), and reporting the 0% of a run whose BASELINE
# died as though every mutant had survived — one loop quoted that 0 into three documents.
# THE ADAPTER gate.sh SOURCES, not the first one `ls` lists. gate.sh reads `adapters/$STACK.sh` with
# STACK from loop.config; the installer never removes a previous stack's adapter, so after a
# `--force` reinstall to another stack the directory holds two. Driven: a pytest repo reinstalled as
# gradle kept STACK=pytest — gate.sh ran pytest.sh while `ls | head -1` handed these checks gradle.sh,
# which they asserted and passed. The inverse is a SKIP: any alphabetically-earlier stale adapter
# (cargo.sh beside gradle.sh) silently dropped the gradle token assertion check 19 exists for.
# `ls` remains the fallback only for a repo with no loop.config at all.
installed_adapter(){
  local st=""
  # shellcheck disable=SC1090
  [ -f "$HERE/loop.config" ] && st="$( . "$HERE/loop.config" >/dev/null 2>&1; printf '%s' "${STACK:-}" )"
  if [ -n "$st" ] && [ -f "$HERE/adapters/$st.sh" ]; then printf '%s' "$HERE/adapters/$st.sh"
  else ls "$HERE/adapters/"*.sh 2>/dev/null | head -1; fi; }
ad="$(installed_adapter)"
# The pairing, asserted BEFORE the driven check below — otherwise deleting the mechanism would make
# that check disappear instead of fail, which is the exact shape of false green these checks exist to
# catch. An adapter may legitimately carry no mutation tier at all; it may not carry half of one.
if [ -n "$ad" ] && grep -qE '^gate_mutation(_pct)?\(\)' "$ad"; then
  grep -q '^gate_mutation()' "$ad" && grep -q '^gate_mutation_pct()' "$ad" \
    && ok "$(basename "$ad"): the mutation tier has both halves (verdict + score)" \
    || bad "$(basename "$ad") defines half a mutation tier" "gate.sh reports a row it cannot put a number behind, or computes a number nothing gates on"
fi
# And the pairing one artifact along: a repo that DECLARES a scope must have something able to measure
# it. `mutation_score_pct` declared in a plan with no executor anywhere is how two milestones of one
# driven loop recorded gate PASS on a tier that did not exist.
if [ -f "$HERE/loop.config" ]; then
  # shellcheck disable=SC1090
  mt="$( . "$HERE/loop.config" >/dev/null 2>&1; printf '%s' "${MUTATION_TARGETS:-}" | tr -d '[:space:]' )"
  if [ -n "$mt" ]; then
    [ -n "$ad" ] && grep -q '^gate_mutation()' "$ad" \
      && ok "mutation tier: declared in loop.config AND executed by the adapter" \
      || bad "loop.config declares MUTATION_TARGETS and no adapter can measure them" "the floor and the scope are decoration — the gate reports on a tier that has no executor"
  fi
fi
if [ -n "$ad" ] && grep -q '^gate_mutation_pct()' "$ad"; then
  mp="$WORK/mp.sh"; sed -n '/^gate_mutation_pct(){/,/^gate_mutation()/p' "$ad" | sed '$d' > "$mp"
  if ! grep -q '^gate_mutation_pct(){' "$mp" || ! bash -n "$mp" 2>/dev/null; then
    bad "gate_mutation_pct could not be extracted from $(basename "$ad")" "its shape changed — update this check rather than deleting it"
  else
    # shellcheck disable=SC1090
    . "$mp"
    # COMPACT json on purpose. The first version of this function split on `[:,]` and took field 2 of
    # any line naming a key — so on a single-line stats file every key read the same number and the
    # score came out empty. A fixture that is only ever pretty-printed cannot see that.
    printf '{"killed": 80, "survived": 10, "timeout": 5, "suspicious": 5, "skipped": 0, "total": 100}\n' > "$WORK/mutation-stats.json"
    p1="$(LOGDIR="$WORK" gate_mutation_pct)"
    printf '{"killed": 0, "survived": 0, "timeout": 0, "suspicious": 0, "skipped": 0, "total": 116}\n' > "$WORK/mutation-stats.json"
    p2="$(LOGDIR="$WORK" gate_mutation_pct)"
    [ "$p1" = 80 ] && ok "gate_mutation_pct: killed-only numerator — 80 killed of 100 scores 80%, timeouts and suspicious do NOT round it up" \
      || bad "gate_mutation_pct scores '$p1', not 80" "counting a timeout or a suspicious mutant as killed can only push the score UP — a gate that rounds in its own favour is not a gate"
    [ -z "$p2" ] && ok "gate_mutation_pct: a run that tested NO mutants scores nothing (→ PENDING), not 0%" \
      || bad "gate_mutation_pct returns '$p2' for a baseline that died" "'measured over nothing' and 'every mutant lived' are different claims and this reports the first as the second"
  fi
fi

# ── 13. R8 measures STATEMENTS, from the right base, against per-role budgets ─
# Three separate defects, one breaker. Each is checked on its own because each shipped alone.
grep -q 'churn_base=HEAD' "$HERE/loop-iteration.sh" \
  && grep -q 'git diff --shortstat "\$churn_base"' "$HERE/loop-iteration.sh" \
  && grep -q 'merge-base --is-ancestor' "$HERE/loop-iteration.sh" \
  && ok "R8: churn is measured from the last journalled iteration (ancestor-guarded), not from the dirty tree" \
  || bad "R8 measures \`git diff HEAD\`" "an iteration journalled AFTER its step was committed measures a CLEAN tree and scores zero — three milestones of one loop recorded 0 files / 0 loc while the same commits measured 120–988 lines from their parents"
grep -q 'command -v churn_loc' "$HERE/loop-iteration.sh" \
  && ok "R8: statement counting is used when the adapter provides it (raw diff otherwise)" \
  || bad "R8 counts raw diff lines only" "it then measures how much was WRITTEN, not what was done — one milestone tripped it four times on docstrings and caught no real leap"
grep -q 'churn_budget "\$ROLE"' "$HERE/loop-iteration.sh" \
  && grep -q 'churn_files_budget "\$ROLE"' "$HERE/loop-iteration.sh" \
  && ok "R8: BOTH budgets (lines and files) are resolved per role" \
  || bad "R8 uses a flat budget" "one number for every role is either loose enough to ignore the implementer or tight enough to fire on every RED step — and the flat FILE budget tripped a test-author at 27 files on a migration the plan itself asked for"
# An adapter that offers `churn_loc` must ship the helper it delegates to. Asserted separately, and
# before the driven check below, because the adapter FAILS OPEN to the raw diff count when the helper
# is missing — so deleting lib/churn_loc.py silently returns R8 to counting docstrings, and a check
# guarded on the file's existence would vanish rather than go red.
if [ -n "${ad:-}" ] && grep -q '^churn_loc()' "$ad"; then
  [ -f "$HERE/lib/churn_loc.py" ] \
    && ok "lib/churn_loc.py is present for the adapter that delegates to it" \
    || bad "the adapter defines churn_loc but lib/churn_loc.py is missing" "it fails OPEN to the raw diff count, so R8 goes back to measuring prose and says nothing about it"
fi
# The counter, driven over a real repository, because its whole claim is that 400 lines of docstring
# and 400 lines of logic are different numbers — and nothing in a grep can tell whether that is true.
if command -v python3 >/dev/null 2>&1 && [ -f "$HERE/lib/churn_loc.py" ]; then
  ( set -e; cd "$WORK"; mkdir -p cl; cd cl; git init -q .
    git config user.email h@h; git config user.name h
    # --no-verify: the fixture must not run the OPERATOR's commit hooks. A repo whose pre-commit hook
    # scans, lints or simply fails would turn this check red for a reason that has nothing to do with
    # what it measures.
    printf 'x = 1\n' > m.py; git add -A; git commit -qm base --no-verify
    { printf '"""\n'; i=0; while [ "$i" -lt 40 ]; do echo "prose line $i"; i=$((i+1)); done; printf '"""\n'
      printf 'x = 1\ny = 2\n'; } > m.py
    set -- $(python3 "$HERE/lib/churn_loc.py" HEAD)
    [ "${1:-99}" -le 4 ] && [ "${2:-0}" -ge 38 ] ) \
    && ok "churn_loc.py: a 40-line docstring plus one statement scores as one statement AND 40 prose" \
    || bad "churn_loc.py does not report both halves" "R8's budget then measures documentation (four false trips in one milestone, no real leap), or R12 has no number to read and prose is free again"
fi
# R12 is wired at BOTH ends or at neither: the adapter reporting prose with nothing reading it is the
# state this breaker was added to leave.
grep -q 'trip=R12' "$HERE/loop-iteration.sh" \
  && grep -q 'doc_budget' "$HERE/loop-iteration.sh" \
  && ok "R12: the prose count is read and budgeted per role" \
  || bad "R12 is not wired into loop-iteration.sh" "churn_loc.py measures prose and nothing trips on it — a step can write 300 lines of docstring for free, which is how one service reached 40% docstrings in src"
if [ -f "$HERE/loop.config" ]; then
  # shellcheck disable=SC1090
  db="$( . "$HERE/loop.config" >/dev/null 2>&1; command -v doc_budget >/dev/null 2>&1 && doc_budget implementer )"
  [ -n "$db" ] \
    && ok "loop.config: R12 armed (implementer prose budget $db)" \
    || ok "loop.config leaves DOC_LOC unset — R12 is off, which is the shipped default"
  # shellcheck disable=SC1090
  cb="$( . "$HERE/loop.config" >/dev/null 2>&1
         command -v churn_budget >/dev/null 2>&1 && command -v churn_files_budget >/dev/null 2>&1 \
           && printf '%s/%s' "$(churn_budget test-author)" "$(churn_files_budget test-author)" )"
  [ -n "$cb" ] \
    && ok "loop.config: per-role churn budgets declared (test-author → $cb)" \
    || ok "loop.config declares no per-role churn budget — the flat CHURN_LOC/CHURN_FILES apply (a deliberate, supported choice)"
fi

# ── 14. the milestone vocabulary is the PLAN's, not the harness's ────────────
# `M[0-9]+` assumes every milestone is named M<n>. In a repo whose milestones are C0..C5 — and whose
# journal still holds a finished phase's M0..M7 headers — it matched an OLD M-header, and the
# auto-state a RESUMING session reads named a milestone finished weeks earlier.
det="$WORK/det.sh"; sed -n '/^detect_milestone(){/,/|| true; }$/p' "$HERE/checkpoint.sh" > "$det"
if ! grep -q 'detect_milestone(){' "$det" || ! bash -n "$det" 2>/dev/null; then
  bad "detect_milestone could not be extracted from checkpoint.sh" "its shape changed — update this check rather than deleting it"
else
  mkdir -p "$WORK/spec"
  { echo "## 2026-01-01T00:00:00+01:00  M1  iter 1 @aaaaaaa"
    echo "## M7 review loop — converged"
    echo "## 2026-02-01T00:00:00+01:00  C4  iter 5 @bbbbbbb"
    echo "note: regression since M3, carried from M5"; } > "$WORK/spec/LOOP_STATE.md"
  got="$( SPEC_DIR="$WORK/spec"; . "$det"; detect_milestone )"
  [ "$got" = C4 ] \
    && ok "checkpoint.sh: detect_milestone reads C4 past older M-headers and past prose" \
    || bad "checkpoint.sh: detect_milestone answered '$got', not C4" "a resuming session is told the wrong milestone, and a cleared breaker is archived under it"
fi

# ── 15. the e2e tag prefix is an OPT-OUT, not a law ──────────────────────────
# Prefixing is right for one-ticket-per-loop (a bare @m1 matches the PREVIOUS ticket's acceptance
# test) and WRONG for epic-per-loop, where one ticket owns thirteen milestones and every bare tag is
# already unique. Both directions are driven — a knob that only ever answers one way is not a knob.
tag="$WORK/tag.sh"; sed -n '/^e2e_tag(){/,/^  printf .*\$ml"; }$/p' "$HERE/gate.sh" > "$tag"
if ! grep -q '^e2e_tag(){' "$tag" || ! bash -n "$tag" 2>/dev/null; then
  bad "e2e_tag could not be extracted from gate.sh" "its shape changed — update this check rather than deleting it"
else
  on="$(  SPEC_DIR='specs/TT-3651-thing'; E2E_TAG_TICKET_PREFIX=true;  . "$tag"; e2e_tag C4 )"
  off="$( SPEC_DIR='specs/TT-3651-thing'; E2E_TAG_TICKET_PREFIX=false; . "$tag"; e2e_tag C4 )"
  [ "$on" = tt-3651-c4 ] && [ "$off" = c4 ] \
    && ok "gate.sh: E2E_TAG_TICKET_PREFIX true → @$on, false → @$off" \
    || bad "gate.sh: E2E_TAG_TICKET_PREFIX is not honoured (true → '$on', false → '$off')" "an epic-per-loop repo must either retag every shipped spec or run its acceptance gate against a tag that does not exist"
fi

# ── 16. the local-extension manifest is not stale ────────────────────────────
# scripts/.upstream-exempt is what stops install-harness.sh deleting a deliberate local extension. An
# entry that names a file or a symbol that is no longer there protects NOTHING while still reading as
# protection — the same false green as a declared gate with no executor, one artifact along. Absent
# manifest is the normal case and is not a finding.
if [ -f "$HERE/.upstream-exempt" ]; then
  stale=""
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in
      */*|*.sh|*.py|*.md|*.json|*.config|*.template) [ -f "$HERE/${e#scripts/}" ] || stale="$stale $e";;
      # --exclude the manifest itself, or every entry finds its own declaration and nothing is ever
      # stale — a check that can only pass. Caught by falsifying it with an entry naming nothing.
      *) grep -rq --exclude=.upstream-exempt -- "$e" "$HERE" 2>/dev/null || stale="$stale $e";;
    esac
  done <<EOF
$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$HERE/.upstream-exempt" | grep -v '^$' || true)
EOF
  [ -z "$stale" ] \
    && ok "manifest: every .upstream-exempt entry still names something in scripts/" \
    || bad "manifest: stale .upstream-exempt entries:$stale" "they protect nothing while reading as protection — delete them, or restore what they name"
fi

# ── 17. drift is reported in BOTH directions ─────────────────────────────────
# These checks catch the template regressing underneath a repo. Nothing caught the repo IMPROVING on
# the template: the published recipe sat behind one repo by six generic mechanisms, some for months,
# and one of them shipped a self-check that FAILED on first install to every repo that took it — found
# by accident. upstream-report.sh is the other direction, and it must REPORT, never gate.
if [ ! -x "$HERE/upstream-report.sh" ]; then
  bad "upstream-report.sh is missing" "a harness fix made here reaches the recipe only if someone remembers — which is the arrangement that let six mechanisms sit unpublished"
else
  grep -q 'upstream-report.sh' "$HERE/open-milestone-pr.sh" \
    && ok "open-milestone-pr.sh runs the upstream report at the close-out" \
    || bad "upstream-report.sh has no caller" "a reporter nobody invokes reports nothing — the same defect as a declared gate with no executor"
  # It must be impossible for this to fail a close-out. Both halves: the call site tolerates failure,
  # and the script itself exits 0. Either alone is not enough — a `set -e` script calling a reporter
  # that exits 1 would abort the milestone's PR over a REPORT.
  grep -q 'upstream-report.sh" || true' "$HERE/open-milestone-pr.sh" \
    && ok "open-milestone-pr.sh: the report cannot fail the close-out" \
    || bad "the upstream report is called without || true" "a report that can abort a PR is a gate, and this one must never gate — it would block a milestone on another repo's review process"
  # DRIVEN over a real repository, because the manifest logic is the half that can be silently wrong:
  # a reporter that lists everything is noise nobody reads, and one that lists nothing looks exactly
  # like a clean milestone.
  if ( set -e; cd "$WORK"; mkdir -p ur/scripts; cd ur; git init -q .
       git config user.email h@h; git config user.name h
       cp "$HERE/upstream-report.sh" scripts/; echo base > scripts/gate.sh
       git add -A; git commit -qm base --no-verify
       base="$(git rev-parse HEAD)"
       printf 'gate_cross_channel(){ echo SKIP; }\n' >> scripts/gate.sh
       git commit -qam "local extension only" --no-verify
       printf 'generic_fix=1\n' > scripts/loop-iteration.sh
       git add -A; git commit -qm "generic harness fix" --no-verify
       printf 'gate_cross_channel\n' > scripts/.upstream-exempt
       git add -A; git commit -qm "manifest bookkeeping" --no-verify
       bash scripts/upstream-report.sh --since "$base" > out.txt 2>&1
       bash scripts/upstream-report.sh --since HEAD > empty.txt 2>&1
       grep -q 'generic harness fix' out.txt \
         && ! grep -q 'local extension only' out.txt \
         && ! grep -q 'manifest bookkeeping' out.txt \
         && grep -qi 'upstream candidates: none' empty.txt ); then
    ok "upstream-report: names the generic commit, drops the declared-symbol one, and says 'none' out loud when there is nothing"
  else
    bad "upstream-report does not honour the manifest (or hides an empty result)" \
        "listing a repo's declared local extensions every close-out makes the report noise nobody reads; printing nothing makes a clean milestone indistinguishable from a reporter that never ran"
  fi
fi

# ── 18. escalation raises, never lowers, and a trip is diagnosed ─────────────
# Escalation is the safety valve that makes every cheaper default tier defensible, so the two ways it
# can be wrong are both fatal to that argument: it can fail to fire on the milestones that need it,
# and it can LOWER a gate when someone configures a cheaper escalation tier than the role already had.
# Both are driven against the real functions rather than grepped.
esc="$WORK/esc.sh"
sed -n '/^model_rank(){/,/^model_for(){/p' "$HERE/loop-driver.sh" | sed '$d' > "$esc"
if ! grep -q '^escalate_to(){' "$esc" || ! bash -n "$esc" 2>/dev/null; then
  bad "the escalation helpers could not be extracted from loop-driver.sh" "their shape changed — update this check rather than deleting it"
else
  # shellcheck disable=SC1090
  . "$esc"
  up="$(escalate_to sonnet opus)"; down="$(escalate_to opus sonnet)"; same="$(escalate_to opus opus)"
  typo="$(escalate_to opus nonesuch)"; none="$(escalate_to opus '')"
  [ "$up" = opus ] \
    && ok "escalate_to: a cheaper role tier is RAISED to the escalation tier (sonnet → opus)" \
    || bad "escalate_to does not raise (sonnet+opus → '$up')" "the escalation tier would be declared and never applied — the fifth knob in this harness to be read by nothing"
  [ "$down" = opus ] && [ "$same" = opus ] \
    && ok "escalate_to: a LOWER escalation tier is inert (opus stays opus), so escalation cannot downgrade a gate" \
    || bad "escalate_to can LOWER a role's tier (opus+sonnet → '$down')" "a loop.config with a cheap escalation tier would silently downgrade the reviewer — the last gate before a milestone lands, and the exact opposite of what escalation is for"
  [ "$typo" = opus ] && [ "$none" = opus ] \
    && ok "escalate_to: an unrecognised or empty escalation id changes nothing (a typo costs money, never correctness)" \
    || bad "escalate_to mishandles an unknown id (got '$typo' / '$none')" "an id nobody recognises must not become a role's model"
  # The MARKER is the plan's, and whole-word: M1 must never match M12.
  cc="$( MS=M1; CORRECTNESS_CRITICAL='M12 M3'
         . "$esc" 2>/dev/null; correctness_critical && echo yes || echo no )" 2>/dev/null
  cc2="$( MS=M3; CORRECTNESS_CRITICAL='M12 M3'
          . "$esc" 2>/dev/null; correctness_critical && echo yes || echo no )" 2>/dev/null
  [ "$cc" = no ] && [ "$cc2" = yes ] \
    && ok "correctness_critical: matches whole milestone ids (M3 yes, M1 not matched by M12)" \
    || bad "correctness_critical mismatches (M1→$cc, M3→$cc2)" "a substring match escalates milestones nobody marked, or misses ones that were"
fi
# Both roles escalate, and only on a marked milestone. Driven through the REAL model_for over a stub
# loop.config, because "the reviewer escalates too" is the half most easily lost: milestone_model
# already existed for the implementer, so an implementer-only escalation looks finished.
mf2="$WORK/mf2.sh"
sed -n '/^model_rank(){/,/MODEL_SEARCH:-haiku}";; esac; }/p' "$HERE/loop-driver.sh" > "$mf2"
if ! grep -q '^model_for(){' "$mf2" || ! bash -n "$mf2" 2>/dev/null; then
  bad "model_for could not be extracted with its escalation arms" "its shape changed — update this check rather than deleting it"
else
  # All three tiers on one line so the annotation can sit on it: kitchen-gate §3 reads physical lines,
  # and while the literal had to END the line these two were invisible to it — the continuation is how
  # this repo actually spells a tier. They stay literals rather than `${KITCHEN_MODEL_*:-…}` reads
  # because they are the assertion's INPUT: the claim is "sonnet/sonnet becomes opus/opus on a marked
  # milestone and stays sonnet/sonnet off it". Sourced from the environment, a caller already running
  # at opus makes `opus/opus` the expected answer for free and the escalation assertion says nothing,
  # while the unmarked case goes red on a harness that is working.
  got="$( MS=M3 STEP="" CORRECTNESS_CRITICAL='M3' MODEL_IMPLEMENTER=sonnet MODEL_REVIEWER=sonnet MODEL_ESCALATION_MUTATION=opus   # kitchen-gate:allow — fixture input, not a configured tier
          . "$mf2"; printf '%s/%s' "$(model_for implementer)" "$(model_for reviewer)" )"
  off="$( MS=M2 STEP="" CORRECTNESS_CRITICAL='M3' MODEL_IMPLEMENTER=sonnet MODEL_REVIEWER=sonnet MODEL_ESCALATION_MUTATION=opus   # kitchen-gate:allow — fixture input, not a configured tier
          . "$mf2"; printf '%s/%s' "$(model_for implementer)" "$(model_for reviewer)" )"
  [ "$got" = "opus/opus" ] \
    && ok "model_for: a mutation-gated milestone escalates BOTH the implementer and the reviewer ($got)" \
    || bad "model_for does not escalate both roles on a mutation-gated milestone (got $got)" "the reviewer is the last gate before that work lands; escalating only the implementer leaves it judged at the cheaper tier"
  [ "$off" = "sonnet/sonnet" ] \
    && ok "model_for: an unmarked milestone is untouched ($off) — escalation is not a blanket raise" \
    || bad "model_for escalates a milestone the plan did not mark (got $off)" "every milestone would run at the escalation tier and the marker would mean nothing"
  # The routine tier for the reviewer (1.8.6): MODEL_REVIEWER_ROUTINE on an unmarked milestone, MODEL_REVIEWER
  # raised by the escalation on a marked one, and an empty knob is the pre-1.8.6 answer.
  rt="$( MS=M2 STEP="" CORRECTNESS_CRITICAL='M3' MODEL_REVIEWER=opus MODEL_REVIEWER_ROUTINE=sonnet MODEL_ESCALATION_MUTATION=opus   # kitchen-gate:allow - fixture input, not a configured tier
          . "$mf2"; printf '%s/%s' "$(model_for reviewer)" "$(base_model_for reviewer)" )"
  rc="$( MS=M3 STEP="" CORRECTNESS_CRITICAL='M3' MODEL_REVIEWER=opus MODEL_REVIEWER_ROUTINE=sonnet MODEL_ESCALATION_MUTATION=opus   # kitchen-gate:allow - fixture input, not a configured tier
          . "$mf2"; model_for reviewer )"
  re="$( MS=M2 STEP="" CORRECTNESS_CRITICAL='M3' MODEL_REVIEWER=opus MODEL_REVIEWER_ROUTINE= MODEL_ESCALATION_MUTATION=opus   # kitchen-gate:allow - fixture input, not a configured tier
          . "$mf2"; model_for reviewer )"
  [ "$rt" = "sonnet/sonnet" ] && [ "$rc" = opus ] && [ "$re" = opus ] \
    && ok "model_for: the reviewer takes MODEL_REVIEWER_ROUTINE on an unmarked milestone (base tier, so no false ESCALATED), MODEL_REVIEWER on a marked one, and an empty knob keeps MODEL_REVIEWER ($rt, $rc, $re)" \
    || bad "model_for: the routine reviewer tier is wrong (unmarked $rt, marked $rc, empty knob $re)" "a routine milestone would review at the critical tier, or a critical one at the routine tier"
fi
# A breaker trip must produce a DIAGNOSIS, not just a file on disk — and must not be able to act.
if ! grep -q '^breaker_agent(){' "$HERE/loop-driver.sh"; then
  bad "loop-driver.sh has no breaker escalation agent" "a trip leaves ESCALATION.md and nothing else; the operator reconstructs the cause with the least context, from an unattended run"
else
  # Counted ANYWHERE on a line, not just at line start: two of the three call sites live inside an
  # `&& { … ; }` group after `escalate`, so a line-anchored count read 2 and reported a missing stop
  # path that was there. The definition itself is `breaker_agent(){` and cannot match.
  n_calls="$(grep -o 'breaker_agent "' "$HERE/loop-driver.sh" | wc -l | tr -d ' ')"
  [ "${n_calls:-0}" -ge 3 ] \
    && ok "loop-driver.sh: every stop path in run runs the escalation agent ($n_calls call sites)" \
    || bad "only ${n_calls:-0} stop path(s) escalate" "a trip on the path that was missed ends the run silently, which is the behaviour this replaced"
  grep -q 'ESCALATION_FLAGS=.*--allowedTools Read Grep Glob' "$HERE/loop-driver.sh" \
    && ! grep -q 'ESCALATION_FLAGS=.*\(Edit\|Write\|Bash\)' "$HERE/loop-driver.sh" \
    && ok "the escalation agent is read-only (Read/Grep/Glob — it cannot edit, commit, or re-run the loop)" \
    || bad "the escalation agent can WRITE" "it is advisory by contract; an agent that can act on its own diagnosis is a second driver with no ledger and no scope audit"
  # It must not change the verdict. The run stopped; the agent explains it.
  awk '/breaker_agent "/{found=1} found && /exit 3/{print "ok"; exit}' "$HERE/loop-driver.sh" | grep -q ok \
    && ok "loop-driver.sh: the run still exits 3 after the escalation agent — a diagnosed stop is still a stop" \
    || bad "the escalation agent's stop path no longer exits 3" "a breaker that returns 0 after being explained has been deleted, not handled"
fi

# ── 19. capability discovery survives a MISSING candidate path ───────────────
# Every discovery names candidates that are normally not all present (build.gradle OR
# build.gradle.kts). `grep -qs PAT a b` answers that question wrongly under ugrep, which exits 2 when
# any NAMED path is missing even though another matched — so spotlessCheck, the project's coverage
# rules, integration and e2e were all silently dropped on any machine with ugrep first on PATH. The
# fix is declares(), which searches only paths that exist.
#
# A GNU-grep CI box cannot observe that on its own, so this check SHIMS the failure: a `grep` earlier
# on PATH that reproduces ugrep's exit-2-on-missing-path. The shim is proven faithful first — if the
# old idiom still succeeds under it, the shim is wrong and the check says so instead of passing.
#
# THE INSTALLED ADAPTER, NOT `adapters/gradle.sh`. `install-harness.sh` writes exactly ONE adapter —
# the stack it was given — so naming gradle here made this check fail on every other stack, on a
# FRESH INSTALL, for a repo that had done nothing wrong. Measured: `install-harness.sh . <stack>`
# then `harness-selfcheck.sh` → gradle PASS, pytest FAILED, npm FAILED; maven, go and cargo define
# no `declares()` at all, so they failed on the extraction too. Five of the six shipped stacks.
# That is this file's own recurring defect — a check that cannot pass on correct code — and the
# self-check is the one thing an installed repo runs to find out whether it is healthy.
#
# `declares()` is OPTIONAL by adapter: gradle, npm and pytest define it; maven, go and cargo have no
# multi-candidate discovery to protect. Absent is SKIP, not FAIL — the same "empty or absent is the
# old behaviour" contract the fan-out and the config functions already make. Resolved through
# installed_adapter() above — loop.config's STACK, the file gate.sh actually sources — not by name
# and not by `ls` order.
dec="$WORK/dec.sh"
adp="$(installed_adapter)"
sed -n '/^declares(){/,/return 1; }$/p' "${adp:-/dev/null}" > "$dec"
if [ -z "$adp" ]; then
  bad "no adapter in scripts/adapters/" "install-harness.sh writes exactly one; without it no tier can run"
elif ! grep -q '^declares(){' "$dec"; then
  ok "$(basename "$adp") declares no declares() — it has no multi-candidate discovery to protect (SKIP)"
elif ! bash -n "$dec" 2>/dev/null; then
  bad "declares() in $(basename "$adp") does not parse" "its shape changed — update this check rather than deleting it"
else
  mkdir -p "$WORK/proj" "$WORK/bin"
  printf "tasks.named('jacocoTestCoverageVerification', JacocoCoverageVerification) {}\n" > "$WORK/proj/build.gradle"
  # ugrep in miniature: any NAMED path that does not exist → exit 2, whatever the other paths matched.
  cat > "$WORK/bin/grep" <<'SHIM'
#!/usr/bin/env bash
seen_pat=0
for a in "$@"; do
  case "$a" in -*) continue;; esac
  if [ "$seen_pat" = 0 ]; then seen_pat=1; continue; fi
  [ -e "$a" ] || exit 2
done
exec /usr/bin/grep "$@"
SHIM
  chmod +x "$WORK/bin/grep"
  if ( cd "$WORK/proj" && PATH="$WORK/bin:$PATH" grep -rqs jacocoTestCoverageVerification build.gradle build.gradle.kts ); then
    bad "the ugrep shim does not reproduce exit-2-on-missing-path" "check 19 would pass vacuously — fix the shim, do not delete the check"
  elif ( cd "$WORK/proj" && PATH="$WORK/bin:$PATH" bash -c ". '$dec'; declares jacocoTestCoverageVerification build.gradle build.gradle.kts" ); then
    ok "declares(): a matching build.gradle is found even when build.gradle.kts is absent"
  else
    bad "declares() answers 'not declared' when a candidate path is missing" "the discovery family is disarmed again — spotless, coverage rules, integration and e2e all silently drop"
  fi
  # And the call sites actually use it: a helper nothing routes through fixes nothing.
  # The TOKEN LIST is gradle's own vocabulary — spotless and jacoco mean nothing to pytest or npm —
  # so this half is asserted only for the gradle adapter. Asserting it against whatever adapter
  # happened to be installed is what would turn a correct pytest repo red for missing a Gradle task.
  # CODE ONLY: the adapters' header comments discuss `declares` at length, so an unanchored grep
  # over the whole file is satisfied by prose — a call removed with its comment left behind would
  # still read as "routes through declares()". Comments are stripped first; the call must then
  # stand as a word (`declares <arg>`), which the definition line `declares(){` does not.
  calls="$WORK/dec-calls.sh"
  sed 's/#.*$//' "$adp" | grep -E '(^|[^[:alnum:]_])declares ' > "$calls"
  case "$(basename "$adp")" in
    gradle.sh)
      miss=""
      for tok in spotless jacocoTestCoverageVerification integrationTest e2eTest; do
        grep -q "declares $tok" "$calls" || miss="$miss $tok"
      done
      [ -z "$miss" ] \
        && ok "gradle adapter routes every multi-candidate discovery through declares()" \
        || bad "these discoveries bypass declares():$miss" "they answer 'not declared' under ugrep, exactly as before" ;;
    *)
      [ -s "$calls" ] \
        && ok "$(basename "$adp") routes its multi-candidate discovery through declares()" \
        || bad "$(basename "$adp") defines declares() and never calls it" "a helper nothing routes through fixes nothing — a comment mentioning it is not a call" ;;
  esac
fi

# ── build artifacts must not be left in nobody's scope ───────────────────────
# `.coverage` alone does NOT match `.coverage.<host>.<pid>.<rand>`, which is what a parallelised
# pytest writes one-per-worker. Untracked and owned by no role, three of them stopped a live run:
# check-scope.sh reads `git ls-files --others --exclude-standard`, so any build artifact in nobody's
# write-scope is indistinguishable from a role writing where it should not. install-harness.sh
# appends the rule; this check is what notices when someone tidies it away again.
ROOT="$(cd "$HERE/.." && pwd)"
if [ ! -f "$ROOT/.gitignore" ]; then
  bad "no .gitignore at the repo root" "build artifacts in nobody's write-scope trip R6 on whichever role happens to be running"
elif grep -qx '\.coverage\.\*' "$ROOT/.gitignore"; then
  ok "gitignore: parallel coverage data files (.coverage.*) cannot reach the scope audit"
else
  bad "gitignore does not cover .coverage.*" "one per test worker, owned by no role — they trip R6 on whichever role happens to be running"
fi

# ── the knobs that have shipped DEAD, each with a reader now ─────────────────
# The most repeated defect in this harness, four instances in one milestone: MUTATION_TARGETS (a
# declared scope with no executor), REVIEW_BUDGET_CRITICAL (five rounds granted, three given),
# REVIEW_DIMENSIONS (a documented fan-out nothing read — one reviewer ran), COVERAGE_TARGET_PCT (an
# 80% floor gated at 70). The last of the four survived two PRs that fixed the other three, and was
# carried here for a while as a NAMED EXCLUSION rather than an assertion, on the grounds that a block
# headed "each with a reader now" must not list a knob that has none. That was the honest way to ship
# it unfixed; it is not a substitute for fixing it.
#
# THE CHECK IS THE CALL SITE AND THE DEFINITION, NOT THE NAME. A first version grepped gate.sh for the
# string "coverage_floor" — which its own `coverage_floor_for` DEFINITION satisfies unconditionally, so
# it printed ✓ while the template shipped the function commented out and the knob was as dead as
# before. A knob-with-no-reader detector that reports green on a knob with no reader is the defect it
# was written to catch, wearing the check's own badge. Both halves are required now: something must
# CALL the resolver, and the shipped template must DEFINE the function it resolves through.
#
# THE LIST IS DECLARED ONCE, HERE. install-harness.sh reads REQUIRED_CONFIG_FN out of this file when
# it keeps an existing loop.config, so the installer's migration notice and this assertion cannot
# name different sets — the same "read membership from a list you already keep" the config itself
# applies to CORRECTNESS_CRITICAL. Keep the assignment on one line and quoted; that is the shape the
# installer greps for.
REQUIRED_CONFIG_FN="coverage_floor review_budget"
# AND THE CONTRACT IS ASSERTED, not just stated. The line above declared its own format in prose and
# nothing enforced it, so the coupling failed OPEN: `install-harness.sh` extracts the list with
# `sed -n 's/^REQUIRED_CONFIG_FN="\([^"]*\)".*/\1/p'`, and a `sed` that matches nothing produces no
# output rather than an error. Reproduced by reformatting the assignment across two lines in a copy
# of the templates and re-installing over a pre-1.6.0 config: the migration notice vanished
# silently, no `loop.config.upstream-additions` was written, and the self-check still failed on both
# functions — precisely the "required a new function and named no fix" state the migration exists to
# remove, reachable by an edit the file did not defend against.
#
# The installer is not copied into a loop repo, so its parser cannot be sourced; it is re-stated
# here instead, which is a duplication that GOES RED when the format breaks rather than one that
# hides it. Equality, not just non-emptiness — a quoting change that truncated the list would parse
# and be wrong.
req_parsed="$(sed -n 's/^REQUIRED_CONFIG_FN="\([^"]*\)".*/\1/p' "$HERE/harness-selfcheck.sh" | head -1)"
if [ -n "$req_parsed" ] && [ "$req_parsed" = "$REQUIRED_CONFIG_FN" ]; then
  ok "install-harness.sh's own parser reads REQUIRED_CONFIG_FN out of this file as '$req_parsed'"
else
  bad "install-harness.sh cannot parse REQUIRED_CONFIG_FN out of harness-selfcheck.sh (it got '$req_parsed')" \
      "keep the assignment on ONE line and double-quoted. The installer greps it with sed; a sed that matches nothing prints nothing, so the config-migration notice disappears with no error while this file goes on requiring the functions"
fi
cfg_tpl="$HERE/loop.config.template"; [ -f "$cfg_tpl" ] || cfg_tpl="$HERE/loop.config"
gate_src="$(sed 's/#.*//' "$HERE/gate.sh" 2>/dev/null || true)"
if grep -q 'coverage_floor_for "\$MILESTONE"' <<< "$gate_src"; then
  ok "gate.sh RESOLVES the coverage floor per milestone at its call sites"
else
  bad "gate.sh does not call coverage_floor_for at its coverage clauses" \
      "the resolver existing is not the same as the clauses using it — COVERAGE_TARGET_PCT stays dead either way"
fi
if grep -q 'floor="\$COVERAGE_FLOOR_PCT"' <<< "$gate_src"; then
  bad "a coverage clause in gate.sh still reads the scalar COVERAGE_FLOOR_PCT directly" \
      "two floors then disagree, and the lower one is on the path that gates the PR"
else
  ok "no coverage clause bypasses the resolver with the bare scalar"
fi
#
# THE FAILURE IS AN UPGRADE, NOT A FRESH INSTALL, and the message has to say so. loop.config is the
# one file install-harness.sh never writes over, so every repo that was set up before these functions
# existed keeps a config without them and lands here — where the first version of this message said
# "unread on a fresh install", the one case it cannot be. A check that fires only on upgrades and
# explains only fresh installs sends the operator looking for the wrong thing.
#
# NO PIPE. `sed 's/#.*//' <config> | grep -q "^$fn()"` is the SIGPIPE trap this file documents two
# functions above and `loop-driver.sh` documents again at `owns_open_finding`, re-introduced in the
# same diff: `grep -q` exits at its first match, `sed` takes SIGPIPE on the bytes after it, and
# pipefail reports 141 — so the answer is FALSE exactly when it should be true. Measured on this
# machine by padding a real loop.config with local assignments and running the pipeline under the
# installer's own `set -euo pipefail`: 0/20 failures at 195 KB of comment-stripped config, 9/20 at
# 291 KB, 20/20 at 387 KB. Size-dependent, which is what makes it a time bomb rather than a bug.
# It fails in the bad direction — this check goes RED on a config that DEFINES the function, and
# install-harness.sh then writes `loop.config.upstream-additions` telling the operator to append
# definitions that are already there, which shadows the project's tuned coverage_floor() with the
# template default, silently.
#
# The strip is not needed at all once the pipe is gone: `^` anchors at column 0 and a comment line
# starts with `#`, so `^$fn()` cannot match inside one. grep reads the file itself and has no
# producer to race.
for fn in $REQUIRED_CONFIG_FN; do
  if grep -q "^$fn()" "$cfg_tpl" 2>/dev/null; then
    ok "the shipped config DEFINES $fn() — a reader that arrives commented out is not a reader"
  else
    bad "$fn() is not defined in $(basename "$cfg_tpl")" \
        "gate.sh/loop-driver.sh then fall back to the scalar and the knob it resolves is unread. This is the pre-$(cat "$HERE/HARNESS_VERSION" 2>/dev/null || echo current) config: copy $fn() out of the recipe's templates/scripts/loop.config.template into scripts/loop.config — re-running install-harness.sh lists the missing definitions and will not write this file for you"
  fi
done

# REVIEW_DIMENSIONS, the fourth. Both halves again: the driver must ENUMERATE the knob, and the round
# must actually fan out over it — a `review_dims()` nothing loops over is the same dead knob with an
# extra function in front of it.
# NO PIPELINE, for the reason the routing check two functions below re-derives every time it is
# touched: `grep -q` exits on its FIRST match and under `set -o pipefail` the pipeline then reports
# the producer's SIGPIPE as the pipeline's status, so the check goes red on correct code. It is
# size-dependent, which is what makes it a time bomb rather than a bug: measured on this machine the
# producer SIGPIPEs above the 65,536-byte pipe buffer, and `loop-driver.sh` with comments stripped is
# 42,463 bytes today after this branch alone added ~280 lines to it. A shell `case` has no second
# process and cannot be raced. Patterns are single-quoted, so `$(...)` inside one is literal text.
drv_src="$(sed 's/#.*//' "$HERE/loop-driver.sh" 2>/dev/null || true)"
if case "$drv_src" in *'REVIEW_DIMENSIONS'*) true;; *) false;; esac; then
  ok "loop-driver.sh reads REVIEW_DIMENSIONS"
else
  bad "REVIEW_DIMENSIONS is declared and loop-driver.sh never reads it" \
      "the recipe calls the three-way review fan-out 'the default, not an option' and one reviewer runs"
fi
# `dims_to_run` since 1.8.3: review_dims on an ordinary round, only the owed dimensions when a round
# that stopped mid-fan-out is being resumed. Either spelling satisfies the claim this makes - that the
# round LOOPS over the dimension list rather than spawning one reviewer.
if case "$drv_src" in *'for DIM in $(review_dims)'*|*'for DIM in $(dims_to_run)'*) true;; *) false;; esac; then
  ok "and a reviewer round FANS OUT over it — one cold reviewer per dimension"
else
  bad "loop-driver.sh has the dimension list but no round loops over it" \
      "enumerating a knob is not reading it: the round still spawns one reviewer, which is the defect"
fi
if case "$drv_src" in *'revspawns + revdims - 1'*) true;; *) false;; esac; then
  ok "RV counts ROUNDS, not reviewer rows (a fan-out of N is one round, per loop.config's own words)"
else
  bad "RV still counts reviewer invocations against REVIEW_BUDGET" \
      "with a fan-out of N that trips the round budget after a single round"
fi

# ── next_role routes findings to their owner instead of re-reviewing ─────────
# Greps the CURRENT symbol. The first version looked for `findings_for test-author .*YOURS` — the
# literal pipeline the very next commit replaced with `owns_open_finding`, because that pipeline
# SIGPIPEs. So the check went red on the FIXED code, and would have shipped a harness whose
# self-check reports the routing broken precisely because it works. A check pinned to an
# implementation detail fails on its own repair; pin it to the behaviour's entry point.
if grep -q 'owns_open_finding test-author' "$HERE/loop-driver.sh" 2>/dev/null \
   && grep -q 'echo driver; return' "$HERE/loop-driver.sh" 2>/dev/null; then
  ok "next_role: a non-converged round routes to the finding's OWNER, not to another reviewer"
else
  bad "next_role returns 'reviewer' unconditionally once the steps are done" \
      "the phase machine then has no arm that reaches a writing role, so every post-review pass re-reviews an unchanged tree and stops on RU"
fi

# ── the review scope cap has BOTH readers ────────────────────────────────────
# REVIEW_SRC_ONLY_AFTER_ROUND is declared in loop.config and has two readers that must both exist:
# the reviewer BRIEF prints the cap (guidance, before the round is paid for) and `consolidate`
# REFUSES a doc-only blocker/major past it (enforcement, after). Either alone is the bug — a brief
# nothing enforces is a suggestion, and a refusal the reviewer was never warned about burns a full
# fan-out before anyone learns the rule. Asserted by what each reader DOES, not by the knob's name
# appearing somewhere: a knob with no reader is this harness's most-repeated defect, and it has now
# shipped four of them (REVIEW_BUDGET, STALL_ITERATIONS, REPEAT_FAILURE_LIMIT, FLAKE_RERUN_COUNT).
# FULL-LINE COMMENTS DROPPED FIRST, then matched. This is 662f8d3's lesson one check along, and it
# took three tries to get right here. A grep for a STRING cannot tell code from prose about code, and
# picking a more code-shaped string does not fix it: `refusing to consolidate — doc-only` was
# satisfied by a comment restating the message, and `$(_doc_only_findings "` — a command substitution,
# which I argued no comment would plausibly carry — was satisfied by a comment I then wrote myself
# while probing it. Both probes were mutations that DELETED the reader and left prose naming it,
# which is precisely how a reader gets removed in practice.
#
# NOT `sed 's/#.*//'`, which 662f8d3 uses correctly on an adapter but would be wrong on this file: it
# strips from the first `#` anywhere, eating `echo "## SCOPE CAP …"` — a legitimate line whose
# markdown heading lives inside the string. Dropping only lines whose FIRST non-space character is `#`
# removes the prose and keeps the code.
#
# WHAT THIS STILL CANNOT SEE, stated rather than discovered: a reader neutered IN PLACE on a line that
# keeps executable text and carries the pattern in a TRAILING comment (`: # ... $(_doc_only_findings
# "$_cap" $sel) ...`) is not detected — stripping trailing comments from shell needs quote awareness,
# which is more machinery than this check is worth. It catches what actually happens: the file being
# REPLACED by an upstream copy that has no local readers, where the prose leaves with the code.
# BEHAVIOUR is covered where behaviour can be: harness-tests.sh §18 drives `consolidate` against real
# artifacts and asserts the refusal fires, does not fire at the cap, and stays off when the knob is
# absent. This is a drift smoke check, and that is all it claims.
drv_code="$(grep -v '^[[:space:]]*#' "$HERE/loop-driver.sh" 2>/dev/null || true)"
# HERE-STRINGS, not `printf | grep -q`: under pipefail grep -q exits on its first match and the
# producer takes SIGPIPE, so the pipeline reports 141 exactly when the answer is yes — size- and
# timing-dependent. It passed on every macOS run and failed on ubuntu CI for a different stack each
# push from 1.7.0 on (the driver had grown past the pipe buffer). LEARNINGS: "grep -q in a pipefail
# pipeline is SIZE-DEPENDENT". Seven sites in this file, all converted.
_cap_brief=$(printf '%s\n' "$drv_code" | grep -cF 'echo "## SCOPE CAP' || true)
_cap_cons=$(printf '%s\n' "$drv_code" | grep -cF '$(_doc_only_findings "' || true)
if [ "${_cap_brief:-0}" -ge 1 ] && [ "${_cap_cons:-0}" -ge 1 ]; then
  ok "review scope cap: both readers present (the reviewer brief warns, consolidate refuses)"
else
  bad "REVIEW_SRC_ONLY_AFTER_ROUND has lost a reader (brief=$_cap_brief consolidate=$_cap_cons)" \
      "the review lane is uncapped again: one measured milestone spent six of seventeen rounds on findings whose only evidence was prose"
fi
# And the refusal uses the SAME finding vocabulary gate.sh counts by. A detector looking for a shape
# the reviewers do not write is a refusal that can never fire — which is exactly what porting this
# from its origin repo verbatim would have produced, since that repo's artifacts use `## F<n>`. The
# pattern is the compiled regex, which no prose about severities can satisfy.
if grep -qF '(?:blocker|major)' <<< "$drv_code"; then
  ok "the doc-only refusal matches on blocker/major, the severities review_scan counts"
else
  bad "the doc-only refusal does not look for blocker/major" \
      "it then matches nothing the reviewers actually write, and the cap is decorative"
fi

# ── the reviewer is told an output path CONSOLIDATE CAN FIND ─────────────────
# RUN, not grepped. Both previous versions of this check were literal matches on source text the same
# commit had just typed — first `_round$(( $(count_role reviewer) + 1 ))_`, then
# `_round$(review_round_now)` — so each went red on its own repair and neither could see what the path
# actually came out as. It is one function now (`review_artifact_path`), so the check sources the
# driver's resolvers and asks it.
#
# AND IT IS FED A LEDGER, because without one it could not see the round-number half of what it
# claimed to catch. The eval sliced from `review_dims()`, and `review_round_state()` calls
# `ledger_rows()`, which is defined ABOVE that slice: the probe errored `ledger_rows: command not
# found`, the `2>/dev/null` on this assignment swallowed it, and the answer was `round1` for EVERY
# formula — reverting `review_round_now()` to the 1.5.0 `count_role reviewer + 1` left the self-check
# green. The milestone half did fire, so the check was not inert, only half-earned: this is the
# LEARNINGS entry "an author's own reject probe is not a probe", one level up — the probe was fixed
# to resolve the path instead of grepping a literal and the comment kept a claim the new form did
# not.
#
# So the slice starts at `ledger_rows()` (real `count_role`, real `role_rows`, real everything the
# formula walks) and LEDGER points at three seeded reviewer rows — ONE complete round of a 3-way
# fan-out, so the next artifact must be `_round2_`. REVIEW_DIMENSIONS is pinned rather than read from
# the project's config: this asserts the DRIVER's formula, and a repo that had tuned the width to 2
# would otherwise change the expected answer. `review_rounds()` is still stubbed to 0 — the disk
# OFFSET is a separate input with its own fixture in harness-tests.sh (a milestone whose rounds exist
# only on disk); stubbing it is what keeps this probe's answer a function of the ledger alone.
rap="$( cd "$ROOT" 2>/dev/null || cd "$HERE/.."
  led="${TMPDIR:-/tmp}/harness-selfcheck-ledger.$$.tsv"
  for _i in 1 2 3; do printf '2026-01-01T00:00:00Z\tM1\treviewer\topus\tpass\tdeadbee\t0\t0\t0\n'; done > "$led"
  MS=M1 DIM=correctness LEDGER="$led" bash -c '
    source "'"$HERE"'/loop.config" 2>/dev/null
    REVIEW_DIMENSIONS=$'"'"'correctness\nconformance\ncrossartifact'"'"'
    eval "$(sed -n "/^ledger_rows()/,/^review_converged()/p" "'"$HERE"'/loop-driver.sh" | sed "\$d")"
    review_rounds(){ echo 0; }
    review_artifact_path' 2>/dev/null
  rm -f "$led" )"
case "$rap" in
  review-results/*_m1_round2_correctness_issues.md)
    ok "the reviewer brief names review-results/<branch>_<ms>_roundN_<dim>_issues.md — the round number RV counts by AND the milestone consolidate selects on" ;;
  '') bad "review_artifact_path() could not be resolved from loop-driver.sh" \
          "the brief's output path is then whatever the reviewer picks, which is how every round reported round 1 for a year" ;;
  *_m1_round[0-9]*_issues.md)
    bad "the reviewer's output path is '$rap' — ONE complete 3-way round is in the ledger, so the next artifact must be _round2_" \
        "the round number is then not a round counter. Too low and dimension 1 of round 2 overwrites round 1's artifact, which is consolidate's 'accumulate and mark, never drop' defeated by the driver; too high and it advances under its own fan-out, putting dimensions 2..N on the delta tier" ;;
  *_round[0-9]*_issues.md)
    bad "the reviewer's output path is '$rap' — it does not carry the milestone" \
        "review_rounds() and consolidate both select a milestone's artifacts by grepping its id against the FILENAME; without it the whole review feature works only when the BRANCH name happens to contain the milestone" ;;
  *)  bad "the reviewer's output path is '$rap' — no _roundN_ in it" \
          "review_rounds() parses _round([0-9]+)_ and falls back to 1 — with no writer of that name every round reports 1 and RV can never fire" ;;
esac

# ── 20. every knob has a READER, and this is the harness that was installed ──
# Five knobs shipped declared and read by nothing (MUTATION_TARGETS, REVIEW_BUDGET_CRITICAL,
# REVIEW_DIMENSIONS, COVERAGE_TARGET_PCT, EFFORT_*), each found by a milestone paying for it. A
# general scanner was tried and dropped — it failed open and shipped two bugs of its own — so this is
# an EXPLICIT list, lib/knobs.manifest: knob → reader. `script:` readers are grepped for the knob on
# the installed copy; `config:` functions must be defined in loop.config; `recipe:` knobs are the
# driving session's and are asserted kitchen-side against SKILL.md. A knob in loop.config that the
# manifest does not list is reported, not failed: the operator's file may carry local knobs.
if [ ! -f "$HERE/lib/knobs.manifest" ]; then
  bad "lib/knobs.manifest is missing" "nothing asserts that a declared knob is read by anything"
else
  kmiss=""; kn=0
  while read -r knob reader; do
    case "$knob" in ''|\#*) continue;; esac; kn=$((kn+1))
    case "$reader" in
      script:*) f="$HERE/${reader#script:}"
                # Only the installed stack's adapter exists here; a knob read by another stack's
                # adapter is asserted kitchen-side, where every adapter is present.
                case "$reader" in script:adapters/*) [ -f "$f" ] || continue;; esac
                [ -f "$f" ] || { kmiss="$kmiss $knob(no ${reader#script:})"; continue; }
                grep -qE '\$\{?'"$knob"'\b' "$f" || kmiss="$kmiss $knob";;
      config:*) grep -q "^${reader#config:}()" "$HERE/loop.config" || kmiss="$kmiss $knob(no ${reader#config:}() in loop.config)";;
      recipe:*) :;;
      *) kmiss="$kmiss $knob(unknown reader kind '$reader')";;
    esac
  done < "$HERE/lib/knobs.manifest"
  [ -z "$kmiss" ] && ok "lib/knobs.manifest: every one of the $kn listed knobs has its reader" \
    || bad "knobs declared with a reader that does not read them:$kmiss" "a declared limit with no reader is decoration"
  unlisted="$(grep -oE '^[A-Z][A-Z0-9_]*=' "$HERE/loop.config" | tr -d = | sort -u | while read -r k; do
    grep -qE "^$k[[:space:]]" "$HERE/lib/knobs.manifest" || printf ' %s' "$k"; done)"
  [ -n "$unlisted" ] && printf '  \033[33m~\033[0m loop.config knobs not in lib/knobs.manifest (local, or new — give each a reader entry):%s\n' "$unlisted"
fi
# THE HASH. Two worktrees of one repo ran drivers 248 lines apart that both said 1.6.0; a version
# string is a claim, this is a measurement. A mismatch here is an undeclared local edit — declared
# ones (scripts/.upstream-exempt) are reported, not failed.
if [ ! -f "$HERE/lib/harness_sha.sh" ] || [ ! -f "$HERE/HARNESS_SHA" ]; then
  bad "scripts/HARNESS_SHA or lib/harness_sha.sh is missing" "loop-driver.sh cannot tell an installed harness from an edited one; re-run install-harness.sh"
else
  # shellcheck disable=SC1090
  . "$HERE/lib/harness_sha.sh"
  want="$(cat "$HERE/HARNESS_SHA")"; have="$(harness_sha "$HERE")"
  if [ "$want" = "$have" ]; then ok "scripts/ hashes to the HARNESS_SHA the installer stamped ($have)"
  elif [ -f "$HERE/.upstream-exempt" ]; then printf '  \033[33m~\033[0m scripts/ differs from HARNESS_SHA (%s vs %s) — declared local in .upstream-exempt\n' "$have" "$want"
  else bad "scripts/ does not match HARNESS_SHA ($have vs stamped $want)" "an undeclared edit; re-install, or declare it in scripts/.upstream-exempt"; fi
fi
[ -f "$HERE/schemas/role-outcome.json" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$HERE/schemas/role-outcome.json" 2>/dev/null \
  && ok "schemas/role-outcome.json is present and parses — every role's last message is held to it" \
  || bad "schemas/role-outcome.json is missing or invalid" "roles fall back to prose last words, and no_work/refuted cannot be read by the sequencer"
for sch in findings verify; do
  [ -f "$HERE/schemas/$sch.json" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$HERE/schemas/$sch.json" 2>/dev/null \
    && ok "schemas/$sch.json is present and parses (harness 1.8.0 review contract)" \
    || bad "schemas/$sch.json is missing or invalid" "the reviewer/verifier falls back to prose artifacts; verify mode and RA cannot read ids"
done
# The two CLI flags the spawn now relies on. Only asserted when a real CLI answers --help; a fixture's
# stub is not the CLI and a host without it has nothing to check.
if command -v claude >/dev/null 2>&1 && claude --help 2>/dev/null | grep -q -- '--print'; then
  claude --help 2>/dev/null | grep -q -- '--json-schema' && claude --help 2>/dev/null | grep -q -- '--max-budget-usd' \
    && ok "claude CLI: --json-schema and --max-budget-usd are present" \
    || bad "claude CLI lacks --json-schema or --max-budget-usd" "the structured outcome and the pre-hoc spend cap are passed on every spawn; this CLI will reject them"
fi

echo
if [ "$fails" = 0 ]; then echo "harness self-check: PASS"; exit 0; fi
echo "harness self-check: $fails check(s) FAILED — scripts/ has drifted."
echo "If this followed a re-run of install-harness.sh, check the recipe version before reinstalling:"
echo "the published templates regressed once already, and a reinstall is not always an upgrade."
exit 1
