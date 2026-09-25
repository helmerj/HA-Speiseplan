#!/usr/bin/env bash
# loop-driver.sh — the driver the harness has always described and never had.
#
# WHAT WAS MISSING
# ----------------
# `scripts/` contained twelve scripts and none of them drove the loop. `loop-iteration.sh` is a
# per-call RECORDER with four breakers; role sequencing, review rounds, model selection and every
# other stop condition lived in prose that an agent had to remember. Measured on this repo:
#
#   * TDD_PLAN names R1..R11; only R1/R6/R7/R8 existed in code.
#   * REVIEW_BUDGET, STALL_ITERATIONS, REPEAT_FAILURE_LIMIT and FLAKE_RERUN_COUNT had NO reader.
#   * MODEL_DRIVER/TEST_AUTHOR/IMPLEMENTER/REVIEWER/SEARCH had no reader either, so every role ran
#     on whatever model the session happened to be — the declared haiku-for-search saving had never
#     once happened.
#   * R1 counts TDD iterations, which were IN budget (C3 10/11, C4 5/12). The expensive thing —
#     C3's twelve review artifacts across five rounds — was counted by nothing.
#
# So this driver counts ROLE INVOCATIONS and REVIEW ROUNDS, which is where the money goes, and it
# refuses to continue when a declared limit is reached instead of asking an agent to notice.
#
# It is deliberately stack- and ticket-independent: everything project-specific comes from
# loop.config. It is an upstream candidate for workflows:tdd-loop-run-recipe.
#
# USAGE
#   loop-driver.sh status <MS>                     counters + how close each stop condition is
#   loop-driver.sh next   <MS>                     which role runs next, at which model, and why
#   loop-driver.sh run    <MS> --steps N [--yes]   autonomous: spawn roles until done or stopped
#   loop-driver.sh record <MS> <role> <outcome> [secs [tokens [cost]]] [--no-step]
#                                                  append a ledger line (for a hand-run or KILLED role);
#                                                  --no-step (1.8.6) marks a hand commit that is NOT a
#                                                  step (a formatting pass, a journal fix) so the step
#                                                  counter skips the row
#   loop-driver.sh consolidate <MS>                review-results/*_issues.md -> root issues.md,
#                                                  which is what review_converged() and gate.sh read
#   loop-driver.sh close  <MS> <id> "<reason>"       close a finding its owner refuted and the driver
#                                                  accepts as refuted by design (1.8.9); the reason
#                                                  goes on the line, the status line follows
#   loop-driver.sh steer <MS> <role> <path> <severity> "<text>"
#                                                  a driver steer AS A FINDING (1.8.5): appends
#                                                  s<round>-driver-<k> to review-results/<branch>_<ms>_
#                                                  round<n>_driver_issues.md, owner = <role> (the path
#                                                  must be in that role's write-scope), re-consolidates.
#                                                  The brief cap, the router, the verifier and
#                                                  review_mode all see it; prose in LOOP_CLAUDE.md is
#                                                  seen by none of them.
#
#   --dry-run       print the exact `claude` command instead of running it (default for `run`)
#   --yes           actually spawn. Without it `run` is a dry run, on purpose: this thing can
#                   spend money unattended, so spending must be typed, never defaulted.
#   --max-wall-min  wall-clock cap for `run` (default 120)
#   --step <id>     TDD_PLAN §5 step id (e.g. 3c). Selects the implementer model via
#                   milestone_model() and narrows the brief to that step's plan text. UNSET yields
#                   the SAFE model, so forgetting it costs money and never correctness.
#   --role <name>   steer the NEXT spawn to this role, for ONE invocation, then clear. The supported
#                   way to resume after a role was killed mid-flight — the alternative was recording
#                   a ledger row that never happened.
#   --from <file>   `record`: read tokens + cost from a `claude -p --output-format json` result file
#                   (the file the CLI wrote before the role was killed), so the spend is not lost.
#   --model-*       override a role's model for this run only
#
# WHILE A ROLE RUNS the driver prints a HEARTBEAT every $HEARTBEAT_SECS naming elapsed time, HEAD and
# the newest gate artifact. Roles emitted nothing until exit, so a 99-minute role and a hung one were
# indistinguishable; four invocations were killed mid-flight in one measured milestone, two of them
# after committing but before their gate. Deliberately NOT `--output-format stream-json`: that trades
# the parseable per-invocation spend record this ledger is built on for a cosmetic one.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"; cd "$ROOT"
source "$HERE/loop.config"
# Role globs, so the brief can tell a role WHICH findings are its own instead of making it work that
# out. Same file check-scope.sh enforces with, so the brief's answer and the breaker's answer are
# the same answer.
source "$HERE/lib/roles.sh"
# "Is this the harness that was installed" — one hash over scripts/, checked before `run` spends.
# Guarded: a repo installed before the helper existed keeps running; it simply cannot be checked.
[ -f "$HERE/lib/harness_sha.sh" ] && source "$HERE/lib/harness_sha.sh"

CMD="${1:?usage: loop-driver.sh status|next|run|record <MILESTONE> [...]}"; shift
MS="${1:?milestone}"; shift || true

LEDGER="$SPEC_DIR/LOOP_LEDGER.tsv"
ESC="$SPEC_DIR/ESCALATION.md"
STATE="$SPEC_DIR/LOOP_STATE.md"
LOGDIR="${TMPDIR:-/tmp}/tddloop"; mkdir -p "$LOGDIR" "$SPEC_DIR"
DRY=1; YES=0; STEPS=""; MAXWALL=120; STEP=""; ROLE_ONCE=""; FROM=""; NOSTEP=""
# An ack names what it acknowledges: the SIGNATURE of the trip (or `last`, the one in ESCALATION.md),
# a VERDICT (true = the cause was found and fixed; false = the breaker was wrong), and the CAUSE in
# words. A bare ack was a way to buy another round; this one is a diagnosis the next trip is read
# against — a `true` signature that recurs stops as RR, a `false` one is suppressed for the milestone.
SIG=""; VERDICT=""; CAUSE_TXT=""
# The review dimension THIS spawn covers, set by the fan-out in `run` and read by `spawn`. Not a flag:
# the operator never picks a dimension, the fan-out covers all of them. Empty = the unnamed single
# reviewer, which is what a config with no REVIEW_DIMENSIONS still gets.
DIM=""
# The `*)` arm used to reject ANY non-flag argument, and it ran after CMD and MS were shifted off —
# so every remaining positional hit it. `record <MS> <role> <outcome>`, documented in USAGE since the
# driver was written, could therefore never be called: `record C6 driver ack` died on
# "unknown option driver". It was the documented escape hatch for a hand-run role, and it had never
# once worked. Unknown FLAGS are still rejected; positionals are collected and restored for the
# subcommand, which is what `record` reads.
POS=""
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY=1;; --yes) YES=1; DRY=0;;
  --steps) STEPS="${2:?}"; shift;; --max-wall-min) MAXWALL="${2:?}"; shift;;
  # `--step` (singular) is the TDD_PLAN §5 step id; `--steps` (plural) is how many steps the milestone
  # has. Two flags one letter apart, so the mistyped one must not silently mean the other: both take a
  # required value and neither has a default that could absorb the other's.
  --step) STEP="${2:?--step needs a TDD_PLAN §5 step id, e.g. --step 3c}"; shift;;
  --role) ROLE_ONCE="${2:?--role needs a role name}"; shift;;
  --from) FROM="${2:?--from needs a claude -p --output-format json result file}"; shift;;
  --no-step) NOSTEP=1;;
  --signature) SIG="${2:?--signature needs the signature of the trip, or last for the one in ESCALATION.md}"; shift;;
  --verdict) VERDICT="${2:?--verdict needs true = cause fixed, or false = the breaker was wrong}"; shift;;
  --cause) CAUSE_TXT="${2:?--cause needs the diagnosis in words}"; shift;;
  --*) echo "loop-driver: unknown option $1" >&2; exit 2;;
  *) POS="$POS $1";; esac; shift; done
# `set -f` around the restore (1.8.5): `steer`'s last positional is free text, and a `*` or a `?` in
# it would otherwise be glob-expanded against the working tree on its way back into $@. Word
# splitting still applies - the text is re-joined with single spaces by the subcommand - and no
# other subcommand's positionals carry anything a glob could touch.
# shellcheck disable=SC2086
set -f; set -- $POS; set +f

# ── the ledger ───────────────────────────────────────────────────────────────
# One line per ROLE INVOCATION. This is the artifact that did not exist: LOOP_STATE.md records gate
# calls, so a review round — the most expensive thing the loop does — left no trace anywhere. Tab
# separated so it stays greppable by the same shell tools as the rest of the harness.
#   ts  milestone  role  model  outcome  sha  seconds  tokens  cost_usd  signature  status  note
# Columns 10-12 are APPENDED (harness 1.7.0): every reader of 1..9 is unchanged by them, and a ledger
# written before they existed reads back with them empty. `signature` is the cause a breaker tripped
# on (or, for a role that did not finish, the findings it was handed), `status` is the role's own
# verdict from its structured last message (done|no_work|blocked|refuted) or an ack's true|false,
# `note` is the role's last words or the ack's cause — the two things nothing recorded before.
# Column 13 `steer` is APPENDED the same way (harness 1.8.5): `steered` on a row `run --role` spawned,
# `intent` on a verifier row review_mode chose BY INTENT (every open id a driver finding or a steered
# fix at HEAD), empty otherwise. review_mode reads it to tell a steered fix cycle from a routed one.
# `nostep` in the same column (1.8.6): a `record --no-step` row, or the driver's own row for the
# formatting commit after a budget-capped role - a hand commit that is not a step, and
# done_steps_count skips it. Column 14 `gate` (1.8.6): the gate verdict the driver could read for a
# writing role's row at collect - `green` or `red` from loop-iteration's journal entry at that HEAD,
# or from the gate.sh run the lost-JSON path made; empty when nothing measured. done_steps_count reads
# it before the journal: a landed implementer row whose gate is red is not a done step (M9 §2.1).
# `owed` on a REVIEWER row (1.8.8): the reviewer answered blocked with no findings, the round
# arithmetic skips the row and round_missing_dims owes its dimension (M11 §2.7).
# Column 15 `step` (1.8.8): the TDD_PLAN step id the brief named (derived or --step), empty
# post-review; token_budget(role, step) reads it so a declared large step can carry its own ceiling.
[ -f "$LEDGER" ] || printf '# ts\tmilestone\trole\tmodel\toutcome\tsha\tseconds\ttokens\tcost_usd\tsignature\tstatus\tnote\tsteer\tgate\tstep\n' > "$LEDGER"

# Flags every spawned role gets. MEASURED, not assumed (2026-08-12, one-word haiku reply, so the
# whole figure is envelope and none of it is work):
#   session default, all MCP servers loaded   24,725 tok  $0.0233
#   --strict-mcp-config with no servers       21,913 tok  $0.0177   <- 11% off, and a loop role has
#                                                                      no use for Slack/Notion/Jira
#   + a tool allowlist                        23,074 tok  $0.0213   <- NO saving; --allowedTools is
#                                                                      a permission filter, not a
#                                                                      schema filter. Kept anyway,
#                                                                      for blast radius, not tokens.
# The remaining ~22k is system prompt + tool schemas + skills and is not reducible from the CLI.
# The big win was elsewhere: splitting LOOP_CLAUDE.md took ~26,900 tokens off every invocation.
CLAUDE_FLAGS="--permission-mode acceptEdits --output-format json --strict-mcp-config --mcp-config {\"mcpServers\":{}} --allowedTools Read Edit Write Bash Grep Glob"
ledger_rows(){ grep -v '^#' "$LEDGER" 2>/dev/null | awk -F'\t' -v m="$MS" '$2==m' || true; }
# count_role reads ROLE rows (1.8.7 review, minor): an `api` or `killed` row is not an invocation of
# the role - post_review_step keyed on `count_role reviewer > 0`, and three refused reviewers priced
# the fix cycle as post-review before any review ran. count_all stays over every row: it numbers the
# brief and result FILES, and a refused spawn's result file must not be overwritten by the next.
count_role(){ role_rows | awk -F'\t' -v r="$1" '$3==r && $5!="killed"' | wc -l | tr -d ' '; }
count_all(){  ledger_rows | wc -l | tr -d ' '; }
last_field(){ ledger_rows | tail -1 | cut -f"$1"; }
# Rows after the driver's most recent `ack`. An ack is an APPEND stating that a tripped breaker's
# cause was diagnosed and fixed — the same ownership `checkpoint.sh clear-escalation` already has for
# ESCALATION.md, and for the same reason: the trip stays auditable. With no ack present this is every
# row, so nothing changes for a milestone that has never tripped.
# ...AND AN `api` ROW IS NEITHER (1.8.7, M10 §2.5): the CLI answered an error before the role ran -
# zero tokens, HEAD unmoved (the spend limit, an outage). Nothing was done and nothing was spent, so it
# is not a failure the RF window may count, not an invocation the sequencer routes from, and not a
# stall: three of them in M10 read as "last 3 invocations did not pass" twice, both acked false.
rows_since_ack(){ ledger_rows | awk -F'\t' '{r[NR]=$0; if($5=="ack") a=NR} END{for(i=(a?a+1:1);i<=NR;i++) print r[i]}' | awk -F'\t' '$5!="warn" && $5!="api"'; }
# Rows that are ROLE INVOCATIONS — what the sequencer and the stall breaker reason about. The ledger
# deliberately mixes three things: role invocations, driver bookkeeping (`ack`) and mechanism tests
# (`smoke`). Only the first is a step of the milestone. Kept as one file on purpose — the ack has to
# sit in the same evidence trail as the failures it acknowledges — so the filter lives here instead.
# CHARACTERS, NOT BYTES. `head -c 200` cut a note in the middle of a multi-byte character (an em dash,
# 3 bytes, cut after 2), and the ledger row it wrote was no longer valid UTF-8. BSD `cut -f` then
# refused the WHOLE row ("Illegal byte sequence"), so every reader that goes through `cut` — the step
# counter first — silently skipped it: the step-8 GREEN row of TT-4348 M4 vanished, done_steps read
# 7 of 8, and the sequencer re-derived a finished step until RS stopped the run (three no_work rows,
# $1.38). A note is text; truncate it as text. And the READERS are made byte-safe too: `cut` below
# runs in the C locale, so one bad byte in one column can never hide a row again.
# NO EM DASHES IN THE LEDGER (Jürgen, 2026-09-12): dashes of every width become a plain hyphen before
# the cut, so a note is ASCII-safe punctuation whatever the role typed. ROLE_PROMPTS.md asks the roles
# for the same; this is the guarantee.
utf8_head(){ python3 -c 'import sys; n=int(sys.argv[1]); t=sys.stdin.read().replace("\u2014"," - ").replace("\u2013","-").replace("\u2012","-").replace("\u2015"," - "); sys.stdout.write(t[:n])' "$1"; }
# ...AND `cut` IS NOT THE ONLY READER. 1.8.2 forced the C locale here and stopped, because BSD tools
# hid the rest: `ledger_rows` reaches every row through `grep -v` and `awk -F'\t'`, and GNU awk under
# a UTF-8 locale drops or refuses a record carrying an invalid byte just as BSD `cut` did. The same
# planted-bad-byte fixture that passes on macOS therefore failed on Linux CI, with the step counter
# reading 0 of 1 - the exact defect 1.8.2 was written to close, surviving in the reader one layer up.
# Every ledger reader runs in the C locale, where a byte is a byte.
cut(){  LC_ALL=C command cut  "$@"; }
awk(){  LC_ALL=C command awk  "$@"; }
grep(){ LC_ALL=C command grep "$@"; }
# ...AND THE LAST READER IS BASH ITSELF. `read` is where this finally bit: in a UTF-8 locale bash
# hands an invalid byte to the multibyte decoder, which consumes the newline that follows it, so two
# ledger rows arrive as ONE and the second is never seen. Measured in a Linux container on a
# three-line file with two bad bytes in line 2: the loop iterates twice, and iteration 2 is lines 2
# and 3 concatenated. macOS bash does not do this, which is why six green local suite runs said
# nothing and Linux CI failed the fixture 1.8.2 wrote for exactly this hazard.
#
# `local LC_ALL=C` in the parsing function, never `export` at the top of the file: the driver spawns
# python3 (review_findings.py prints findings that carry non-ASCII) and the `claude` CLI, and a C
# locale inherited by those turns a UnicodeEncodeError into the next defect. Scoped to the function,
# restored on return, and no child of these functions cares.
byte_locale(){ :; }   # documentation anchor for the `local LC_ALL=C` lines below
role_rows(){ ledger_rows | awk -F'\t' '$5!="ack" && $5!="warn" && $5!="api" && $3!="smoke"'; }
# ...AND THE ROWS THE SEQUENCER ROUTES FROM ARE NARROWER STILL (1.8.6). `role_rows` is the spend and
# window view: every invocation, the driver's own bookkeeping included, so the sha of the row BEFORE a
# role's row stays the HEAD that role started from. The SEQUENCER asks a different question - "which
# role ran last, and what did it answer" - and a `driver` row or a `nostep` row is neither. Found in
# review of the 1.8.6 PR: the formatting row this version appends after a budget-capped role became
# the last role row, `next_role` fell through `case` to `*)` and answered `test-author` over a landed
# RED, and `open_step_red`/`last_landing_not_red` (both `| tail -1`) bailed because the row was
# neither role - so the two rules written for exactly the budget-cap case were off in it.
sequencer_rows(){ role_rows | awk -F'\t' '$3!="driver" && $3!="escalation" && $13!="nostep"'; }
role_rows_since_ack(){ rows_since_ack | awk -F'\t' '$5!="ack" && $5!="warn" && $5!="api" && $3!="smoke"'; }
# A `warn` row is a soft breaker's first occurrence, written by stop_decision so the second one can be
# told from the first. Bookkeeping like `ack`: never a step, never a spend.

# TDD iterations for THIS milestone, read the same way R1 reads them — per milestone, never the
# global `iter N` in the header. That header number is global, and reading it as the milestone's is
# how a written escalation once claimed "iteration 26 of a budget of 11" for a milestone on its 10th.
ms_iters(){ grep -c "  $MS  iter " "$STATE" 2>/dev/null | tail -1; }
# ...FLOORED BY THE STEPS THE RUN WAS GIVEN (1.8.9, TT-4348 M14 §2.5). The plan's iteration_budget()
# is written before the opening-step split and the e2e-as-a-step rule are applied, and the review
# rounds' RED/GREEN pairs come on top: M14's 26 was sized for six steps, the run had eight, and R1
# tripped at 29, 34 and 40 with the ceiling never near - three stops, two acks at $0, no defect.
# The arithmetic TDD_PLAN §2 of TT-4348 wrote per milestone ("6 steps -> 10 pairs = 20, + 2, + (2 x 2)")
# from --steps: (2 * steps - 2) pairs, + 2, + 2 per review round; the plan recipe's own table
# (circuit-breakers.md) counts fewer and names this floor as the driver's. The larger of the two
# numbers is the budget; the roles read the same floor through LOOP_STEPS, with the milestone's
# review_budget() resolved on both sides.
steps_budget(){ [ -n "${1:-}" ] && [ "$1" -gt 0 ] 2>/dev/null || { echo 0; return; }
  echo $(( 4 * $1 - 2 + 2 * ${REVIEW_BUDGET:-3} )); }
budget(){ local b d; b="$(iteration_budget "$MS")"; d="$(steps_budget "${STEPS:-}")"
  [ "$d" -gt "$b" ] 2>/dev/null && b="$d"; echo "$b"; }

# R11's budget, PER MILESTONE — the same optional-function shape as milestone_usd_ceiling() and
# churn_budget(). REVIEW_BUDGET is read at six sites as `${REVIEW_BUDGET:-3}`, every one of them
# BELOW this line, so re-resolving the scalar once here reaches all six without six edits. A
# milestone the function has no case for yields the empty string and keeps the scalar, which is the
# shipped behaviour.
#
# Found by the same probe that catches a declared floor with no executor: a plan had carried
# `REVIEW_BUDGET_CRITICAL=5` in its loop.config for two milestones with NO READER ANYWHERE. Its
# TDD_PLAN said correctness-critical milestones get five rounds because each round's fixes are
# re-proven by execution before the next starts; the driver gave them three, silently, and the
# difference would first have been paid on the first mutation-gated milestone.
if command -v review_budget >/dev/null 2>&1; then
  _rb="$(review_budget "$MS" 2>/dev/null)"; [ -n "${_rb:-}" ] && REVIEW_BUDGET="$_rb"; unset _rb
fi

# THIS MILESTONE'S ARTIFACT FILENAMES, matched on a WORD BOUNDARY, and the ONLY selector — the three
# readers below and `consolidate` all go through it. Each of them used to spell `grep -i "$ml"` for
# itself, as a bare substring, and `m1` is a substring of `m10`. That was harmless while the filename
# carried no milestone; putting `_<ms>_` into every name (the fix for a reviewer artifact `consolidate`
# could not find) is what made the collision structural. Reproduced on a fresh install with nine M10
# artifacts and no M1 work at all: `status M1` reported 3/3 rounds and RV had already tripped, and
# `consolidate M1` wrote M10's findings into the file gate.sh and review_converged() read — so M1 had
# never been reviewed, could not be reviewed (RV clears only on an operator ack, which does not remove
# the files) and its issues.md carried another milestone's open blockers. One-directional: `M10` never
# absorbs `M1`, so the longer id silently poisons the shorter one.
#
# The boundary is the rule this repo already applies to milestone ids in `plan_section` and in
# `correctness_critical` ("M3 yes, M1 not matched by M12"); these were the selectors that depended on
# the id and did not use it. It still matches an id that appears in the BRANCH half of the name, which
# is the pre-existing behaviour and the reason the milestone was put in the filename in the first
# place — narrowing to `_<ms>_` would also stop matching the `*_verification.md` artifacts, whose
# names the prose loop chooses and this driver does not write.
ms_artifacts(){ ls review-results/ 2>/dev/null \
  | grep -iE "(^|[^a-z0-9])$(printf '%s' "$MS" | tr 'A-Z' 'a-z')([^a-z0-9]|$)" || true; }

# Review ROUNDS, per loop.config's own definition: "counts review ROUNDS, not reviewers: one fan-out
# of N dimension reviewers = ONE round". Taken from the artifacts on disk, so rounds run before this
# driver existed still count.
#
# A ROUND emits `*_issues.md` (one per dimension). A VERIFICATION pass emits `*_verification.md` —
# a single agent re-checking named findings, not a fan-out — and is NOT a round. Counting the two
# together was this function's first bug: it read a milestone with one round and two verifications
# as 3/3 and tripped R11 on a loop that was inside its budget. Measured while writing it: one
# milestone's twelve artifacts are 3 rounds x 3 dimensions plus 2 verifications, i.e. exactly
# REVIEW_BUDGET — the prose-driven loop had been complying with the knob nothing read.
#
# NOT THE DRIVER'S ARTIFACT (1.8.5). `steer` writes `_round<n>_driver_issues.md`: a findings carrier
# for the routing, the brief cap and the verifier, never a round. Counted here it would advance the
# round under the next fan-out (a steer before round 1 would make the first fan-out round 2) and owe
# every dimension of a round nobody ran (round_missing_dims). `driver_artifact` is the one filter.
driver_artifact(){ case "$1" in *_driver_issues.md) return 0;; *) return 1;; esac; }
round_artifacts(){ ms_artifacts | grep '_issues\.md$' | grep -v '_driver_issues\.md$' || true; }
# ONLY the driver's artifact on disk (1.8.6, M9 §2.5): steers were raised and no round has run. The
# consolidated line over that alone is not a review verdict; round 1 is owed. A milestone with NO
# artifact at all (issues.md written by hand, a loop from before the driver rendered rounds) is not
# this case - its token stands as it always did.
only_driver_artifacts(){ [ -z "$(round_artifacts)" ] && [ -n "$(ms_artifacts | grep '_driver_issues\.md$')" ]; }
review_rounds(){ local f n
  f="$(round_artifacts)"
  [ -n "$f" ] || { echo 0; return; }
  n="$(printf '%s\n' "$f" | sed -nE 's/.*_round([0-9]+)_.*/\1/p' | sort -n | tail -1)"
  echo "${n:-1}"; }
# Informational only — never a breaker. A verification pass is cheap and targeted; charging it
# against the round budget is what stops a milestone from confirming its own last fix.
review_verifications(){ ms_artifacts | grep -c '_verification\.md$'; }
# A ROUND THAT DID NOT FINISH IS STILL THAT ROUND. An R6 in dimension 2 of 3, a reviewer that
# exited non-zero, a wall-clock cap mid-fan-out: the round stops, and on the next `run` the ledger
# arithmetic rounded the rows UP to a whole round, `review_round_now` moved on, and the missing
# dimension never read the tree at all - TT-4348 M5 round 1 had no crossartifact view of the first
# S3RecordStore; round 2's delta reviewer over the fix diff is what found the missing test. The
# dimensions of the highest round on disk that wrote no `_issues.md` are OWED, and are spawned as
# that round before anything else is routed. Empty for a config with no REVIEW_DIMENSIONS, for a
# milestone with no round yet, and for artifacts from before rounds carried a number.
# ...AND A DIMENSION WHOSE REVIEWER DID NOT FINISH (1.8.8, TT-4348 M11 §2.7): an artifact rendered
# from a `blocked` (or no_work/refuted, read as blocked) reviewer with NO findings is not a review
# of the diff, it is a reviewer that stopped - M11's round 2 conformance reviewer backgrounded its
# gate call, reported blocked with an empty artifact, and the round "converged" on two dimensions.
# review_findings.py render stamps the reviewer's status on the artifact; a blocked status over no
# finding lines is the dimension owed, and the resume arm re-runs it at the same round.
round_missing_dims(){ local n f d a
  [ -n "$(review_dims)" ] || return 0
  n="$(review_rounds)"; [ "${n:-0}" -ge 1 ] || return 0
  f="$(round_artifacts | grep "_round${n}_")"; [ -n "$f" ] || return 0
  for d in $(review_dims); do
    a="$(printf '%s\n' "$f" | grep "_round${n}_${d}_issues\.md$" | head -1)"
    if [ -z "$a" ]; then echo "$d"
    elif artifact_unfinished "review-results/$a"; then echo "$d"; fi
  done; }
# The render's status stamp says blocked and the artifact carries no finding line. Owed for as long
# as that is what is on disk; RO (stop_reason) bounds how often the loop pays for the re-run.
artifact_unfinished(){ [ -f "$1" ] || return 1
  grep -qE '^Reviewer status: `(blocked|no_work|refuted)`$' "$1" 2>/dev/null || return 1
  ! grep -qE '^[[:space:]]*- \[[ xX]\] ' "$1" 2>/dev/null; }
# The dimensions THIS fan-out spawns: the owed ones when a round is being resumed, all of them otherwise.
RESUME_DIMS=""; RND_FORCE=""
dims_to_run(){ if [ -n "$RESUME_DIMS" ]; then printf '%s\n' $RESUME_DIMS; else review_dims; fi; }
# ── the review fan-out: REVIEW_DIMENSIONS, finally read ──────────────────────
# The knob has been in loop.config since the harness existed, the recipe calls the three-way fan-out
# "the default, not an option", and review-workspace.sh's own header describes a round that "fans out
# N dimension reviewers CONCURRENTLY" and exists to stop them colliding. Nothing enumerated it: ONE
# reviewer ran, and the fourth of the four dead knobs found in one milestone stayed dead through two
# PRs that fixed the other three.
#
# EMPTY OR ABSENT IS THE OLD BEHAVIOUR, deliberately: one unnamed reviewer, artifact path unchanged.
# A config written before this existed keeps working and keeps its costs.
review_dims(){ printf '%s\n' "${REVIEW_DIMENSIONS:-}" | tr -d ' \t' | grep -v '^$' || true; }
# Names land in a FILENAME and in a worktree path (review-workspace.sh rejects anything else), so a
# bad one is caught here, loudly, rather than producing an artifact `consolidate` will not find.
assert_review_dims(){ local d
  for d in $(review_dims); do
    case "$d" in *[!a-z0-9-]*)
      echo "loop-driver: REVIEW_DIMENSIONS entry '$d' is not a usable name (allowed: a-z 0-9 -)" >&2
      echo "             it becomes part of review-results/<branch>_<ms>_roundN_<dim>_issues.md and of the" >&2
      echo "             review-workspace worktree path, and consolidate reads that filename." >&2
      exit 2;;
      # `driver` names the steer artifact (1.8.5): a dimension of that name would be read as it.
      driver)
      echo "loop-driver: REVIEW_DIMENSIONS entry 'driver' is reserved for the steer artifact (_round<n>_driver_issues.md)" >&2
      exit 2;; esac
  done; }
review_dim_count(){ local n; n="$(review_dims | wc -l | tr -d ' ')"
  [ "${n:-0}" -ge 1 ] && echo "$n" || echo 1; }
# The multiplier the RI cap gives the review budget: the fan-out width, FLOORED AT THE PRE-FAN-OUT 2.
# The cap used to be a flat `2 x REVIEW_BUDGET` and scaling it with the width is what keeps a three-way
# fan-out inside a breaker it would otherwise trip. But `review_dim_count()` answers 1 for a config with
# no REVIEW_DIMENSIONS, so the unfloored multiplier made the cap TIGHTER for exactly the configs this
# change promised not to touch — measured, 24 -> 21 invocations, and RI-ABS 72 -> 63, on a breaker that
# needs an operator `ack` to clear. "EMPTY OR ABSENT IS THE OLD BEHAVIOUR" is a compatibility claim this
# file makes twice and loop.config.template repeats; the floor is what makes it true.
ri_review_mult(){ local d; d="$(review_dim_count)"; [ "$d" -lt 2 ] && d=2; echo "$d"; }
# The round the NEXT reviewer invocation belongs to. Reviewer ROWS divided by the fan-out width, so
# the N invocations of one round all name the same round — in their artifact filename, which is what
# `consolidate` groups by and `review_rounds()` counts. Milestone-total, not since-ack: an ack must
# not reset the filename numbering, or round 2 after an ack overwrites round 2 before it.
#
# AND THE ARTIFACTS ON DISK, because the ledger alone does not know about rounds this driver did not
# drive. `review_rounds()` says so in its own comment — "rounds run before this driver existed still
# count" — and the two answers disagreed: two rounds on disk with no reviewer rows made `status` print
# "2 rounds done, next round is 1", and the next reviewer was then told to write OVER round 1's file.
# `consolidate`'s own rule is "Accumulate and mark, never drop"; the driver was dropping a round by
# dictating a filename that already existed.
#
# So the disk contributes an OFFSET, not a maximum. A plain max() would break the fan-out: dimension 1
# writes `_roundN_` DURING the round, so on a branch whose name carries the milestone the artifact is
# already on disk when dimension 2 computes its path, and max() would advance the round under its own
# fan-out — the exact defect this function was written to remove. Rounds the ledger accounts for
# (started, including the one in flight) are subtracted out first, so only rounds the ledger cannot
# explain move the number, and they keep moving it for the whole of the round in flight.
#
# AND THE LEDGER'S OWN ROUNDS ARE READ AS RUNS, NOT AS A DIVISION. `reviewer rows / fan-out width`
# assumes every round contributed exactly N rows. A round that stopped early does not — an R6 in
# dimension 2 stops the rest of the round, deliberately — and the division then shifts the phase of
# every round after it. Measured on a real drive with one aborted round: the next round's three
# dimensions were told round 3, round 4 and round 5, which is the mid-fan-out advance this whole
# function exists to prevent, arriving by a different door. A round is instead a maximal RUN of
# consecutive reviewer rows, capped at the width; ANY other row closes the run, `ack` included — which
# is exactly what the operator must record to clear the breaker that aborted the round.
# ...AND A KILLED ROW IS NO ROW (1.8.6). TT-4348 M9 §2.5: a reviewer the driver killed at spawn
# (`record M9 reviewer killed`, $0) made this read round 1 as complete, and the first real round was
# priced as a DELTA round 2 over two commits. A `killed` outcome is the driver's spend record for a
# role that never ran; it is skipped here, in rounds_at_last_ack and in review_rounds_since_ack, and
# it neither opens a run of reviewer rows nor closes one.
# ...AND `api` (1.8.7 review, blocker): a reviewer the API refused is the same class as a killed one -
# nothing ran - and counted here it closed round 1 with no artifact, so the FIRST real round ran as
# "round 2 · DELTA" at the delta tier, and RU tripped on the relaunch the api message asks for.
# ...AND A REVIEWER THAT DID NOT REVIEW (1.8.8, M11 §2.7): a `blocked` reviewer row with no
# findings carries `owed` in column 14 (spawn_collect), the dimension is re-run at the same round
# (round_missing_dims), and counted here the row closed the round early and shifted every round
# after it by one dimension. Skipped in all three counters, like killed and api - the 1.8.8 review
# found this file's own class of defect re-shipped (LEARNINGS "the third counter"): the first cut
# taught only rounds_at_last_ack, and one owed re-run made RV fire a round early.
# ...AND AN ACK ROW IS NOT A ROUND BOUNDARY (1.8.8 review pass 4, correctness minor): the RO recovery
# puts `ack` between a round's rows and the resumed dimension's row, and counted as a boundary the
# resumed row opened a round of its own - the next real round was numbered one too high, with no
# artifact for the number it skipped. Same in rounds_at_last_ack, which reads the ack for its number.
# NOR A WARN ROW (pass 7): any soft breaker can warn between an owed round and its re-run, and the
# driver's rows are not the round's; only a ROLE's row closes a reviewer run.
review_round_state(){ ledger_rows | awk -F'\t' -v d="$(review_dim_count)" '
  $5=="killed" || $5=="api" || $14=="owed" || $5=="ack" || $5=="warn" { next }
  $3=="reviewer" { if (prev!="reviewer" || run>=d) { rounds++; run=1 } else { run++ }; prev="reviewer"; next }
  { prev=$3; run=0 }
  END { print rounds+0, ((prev=="reviewer" && run<d) ? run : 0) }'; }
# ROUNDS SINCE THE LAST ACK — the number RV gates on, and the ONE writer of that arithmetic. It lived
# inline in `stop_reason` while `escalate()` counted reviewer ROWS for the same line, so a single
# 3-way fan-out wrote "review rounds: 3" into ESCALATION.md while `status` printed 1 — the two
# disagreeing by the fan-out width, in the file an operator reads at the moment the loop has stopped
# and has least context. `status`'s own comment names that failure and fixes `status`; this is the
# other reader.
#
# ROWS -> ROUNDS, rounded UP, so a round interrupted part-way still counts as the round it was.
# Falls back to the artifacts on disk when the ledger has no reviewer rows at all — a milestone
# reviewed before this driver drove it.
review_rounds_since_ack(){ local revspawns revdims disk
  revspawns="$(role_rows_since_ack | awk -F'\t' '$3=="reviewer" && $5!="killed" && $14!="owed"' | wc -l | tr -d ' ')"
  revdims="$(review_dim_count)"
  if [ "$(role_rows | awk -F'\t' '$3=="reviewer" && $5!="killed" && $14!="owed"' | wc -l | tr -d ' ')" -gt 0 ]; then echo $(( (revspawns + revdims - 1) / revdims ))
  else disk="$(review_rounds)"; echo "${disk:-0}"; fi; }
review_round_now(){ local st started owed current disk offset
  [ -n "$RND_FORCE" ] && { echo "$RND_FORCE"; return; }
  st="$(review_round_state)"; started="${st%% *}"; owed="${st##* }"
  # owed > 0 means a round is IN FLIGHT and this spawn is one of its dimensions, so the number does
  # not move. At a round boundary the next round is the one after the last.
  if [ "${owed:-0}" -gt 0 ]; then current="$started"; else current=$(( ${started:-0} + 1 )); fi
  disk="$(review_rounds)"; disk="${disk:-0}"
  offset=$(( disk - ${started:-0} )); [ "$offset" -lt 0 ] && offset=0
  echo $(( current + offset )); }
# THE ARTIFACT PATH THE BRIEF DICTATES, and the MILESTONE is in it. `review_rounds()` and
# `consolidate` both select a milestone's artifacts by grepping its id against the FILENAME, and the
# filename the driver dictated carried the branch, the round and the dimension — but no milestone. It
# worked only where the branch name happened to contain the milestone. Reproduced on `loop/tt-99` (the
# house `{type}/{TICKET}-{kebab}` shape, and what `milestone-start.sh` calls "ONE branch for the whole
# loop"): the reviewer writes exactly the three paths it was given, `consolidate M1` answers "no review
# artifacts for M1", root issues.md is never written, `review_converged()` is false for ever and the
# milestone cannot land. Whether the whole feature worked came down to the branch's name.
#
# One writer for the path, so the brief cannot dictate a name the selector does not accept.
review_artifact_path(){ local br ml
  br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')"
  ml="$(printf '%s' "$MS" | tr 'A-Z' 'a-z')"
  printf 'review-results/%s_%s_round%s%s_issues.md' "$br" "$ml" "$(review_round_now)" "${DIM:+_$DIM}"; }
# THE FIRST status line, which is the consolidated verdict `consolidate` writes at the top — the same
# line gate.sh's review_scan latches. It used to match ANY line, and issues.md embeds every round's
# artifact verbatim, each carrying its own `status:` line: one dimension's `status: converged` under a
# header saying NOT CONVERGED read as converged, `next_role` answered `done`, and the landing step then
# died on the gate. Found by the 1.8.0 fixtures, where a mixed round is the normal case rather than
# the rare one.
# ...AND NEVER OVER THE DRIVER'S ARTIFACT ALONE (1.8.6). M9 §2.5: with no round run at all, issues.md
# read `converged` over the steer artifact alone (0 open steers), RU tripped on a verifier row at
# HEAD, and the sequencer had nothing to route. Steers on disk and no dimension artifact is a
# milestone nobody has reviewed, whatever the consolidated line says; round 1 is owed.
review_converged(){ [ -f issues.md ] || return 1
  only_driver_artifacts && return 1
  grep -iE '^[[:space:]]*(#+[[:space:]]*)?\**status\**[[:space:]]*:' issues.md | head -1 \
    | grep -qiE 'status\**[[:space:]]*:?[[:space:]]*converged'; }

# ── verify mode (harness 1.8.0) ──────────────────────────────────────────────
# A review of code that has not changed cannot change its verdict, and a review of the milestone
# from the top cannot be cheap. Round 1 is always a full fan-out. From round 2 on the driver MEASURES
# before it spends: the diff in MAIN_SCOPE + TEST_SCOPE since the last review of ANY kind is EMPTY →
# nothing is spawned and the run stops (RU); since the HEAD the last FULL round reviewed it is over
# REVIEW_FULL_ROUND_DIFF_LINES → another full round; under it → ONE verifier that re-proves the open
# findings BY ID, by execution, and raises nothing new. Measured (TT-4348 M2): rounds 5-8 were full
# fan-outs at $2.70-$3.70 each that produced one major between them, every one re-reading a diff a
# previous round had read the front of, and four of them patching one mechanism.
#
# The verifier is its OWN ROLE (ledger column 3 = `verifier`), not a reviewer with a flag, because
# review_round_state counts a round as a run of consecutive reviewer rows capped at the width: a
# verifier row inside that run would shift the phase of every round after it — the aborted-round
# defect by another door. A verifier row CLOSES the run, as any other role's row does, and a verify
# pass is therefore not a round: R11 counts fan-outs, `review_verifications()` counts these, and RI,
# R13 and RA bound them. Its write-scope is the reviewer's (lib/roles.sh), its tier MODEL_VERIFIER.
budget_role(){ case "$1" in verifier) echo reviewer;; *) echo "$1";; esac; }
# A sha the repository can still resolve: not empty, not the ledger's `none`, and a commit.
sha_resolves(){ [ -n "$1" ] && [ "$1" != none ] && git rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1; }
# The most recent row of the named roles whose sha is NOT HEAD — "the tree as a review last saw it"
# can never be the tree in front of this one. $1 is a space-padded role list, e.g. " reviewer ".
last_review_row_not_at_head(){ local s r head roles="$1" skip=" ${2:-} " LC_ALL=C   # see byte_locale; $2 = shas to skip
  head="$(git rev-parse HEAD 2>/dev/null || true)"
  while IFS= read -r s; do
    [ -n "$s" ] && [ "$s" != none ] || continue
    case "$skip" in *" $s "*) continue;; esac
    r="$(git rev-parse -q --verify "$s^{commit}" 2>/dev/null)" || continue
    [ -n "$r" ] && [ "$r" != "$head" ] || continue
    printf '%s' "$s"; return 0
  done <<EOF
$(role_rows | awk -F'\t' -v rs="$roles" 'index(rs, " " $3 " ") && $5!="killed" {print $6}' | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}')
EOF
  return 1; }
# ...skipping KILLED rows (1.8.9). A reviewer killed at spawn and recorded anchored the next
# round's base at its sha: round 1 reviewed one file, the e2e RED, and steps 1-7 went unread ($3.4
# spent before the scope was noticed; TT-4348 M13 §2.3). A reviewer that answered `blocked` with no
# findings (`owed`, 1.8.8) is handled by review_base's resume skip below: while its dimension is
# owed, the whole round's rows are skipped (M14 §2.3), and once it is re-run the re-run's row is the
# newer one. (An `owed` filter here had no fixture that failed without it; pass 10, minor.)
# The shas of the round being resumed: the trailing run of reviewer rows after the last writing or
# verifier row (a round is one fan-out, nothing lands between its dimensions; pass 7, minor: one
# shared sha was the assumption, and a re-run row at a later sha broke it).
current_round_shas(){ role_rows | awk -F'\t' '$3=="test-author"||$3=="implementer"||$3=="verifier" {n=0; delete a} $3=="reviewer" && $5!="killed" {a[++n]=$6} END{for(i=1;i<=n;i++) print a[i]}' | sort -u | tr '\n' ' '; }
# The base a VERIFY pass reads from: the last review of any kind, so a second verify of an unchanged
# tree is refused rather than bought. (review_base() below is the last FULL round's, for the fan-out.)
verify_base(){ last_review_row_not_at_head " reviewer verifier " || fork_point; }
# Added + deleted lines since $1 in the WRITING roles' scopes only — scripts/, specs/ and the loop's
# own artifacts move HEAD without changing a line a reviewer would read. Binary files score 0.
code_diff_lines(){ local a d f n=0
  while IFS=$'\t' read -r a d f; do [ -n "$f" ] || continue
    { path_in_scope implementer "$f" || path_in_scope test-author "$f"; } 2>/dev/null || continue
    case "$a" in ''|-) a=0;; esac; case "$d" in ''|-) d=0;; esac
    n=$(( n + a + d ))
  done <<EOF
$(git diff --numstat "$1"..HEAD 2>/dev/null)
EOF
  echo "$n"; }
# The rendered artifacts' reader: `id<TAB>file<TAB>line` per OPEN blocker/major, id empty for prose.
open_findings(){ [ -f "$HERE/lib/review_findings.py" ] || return 0
  python3 "$HERE/lib/review_findings.py" open ${1:-} $(ms_artifacts | grep '_issues\.md$' | sed 's|^|review-results/|') 2>/dev/null; }
open_ids(){ open_findings | awk -F'\t' '$1!=""{print $1}' | sort -u; }
# WHAT THE NEXT REVIEW IS: `full`, `full:<why>`, `verify:<why>` or `none:<why>`. Read-only; `next`
# prints it, `run` acts on it. Round 1 is full by definition; a config without REVIEW_VERIFY_MODE=1 —
# every config from before 1.8.0 — is full on every round, which is the behaviour it had.
# THE TREE AS A REVIEW LAST SAW IT: the sha of the last reviewer or verifier row whose outcome is
# `pass`. A `fail` row (the CLI exited non-zero - a rate limit, a killed role) or an `r6` row read
# nothing the loop may stand on: with a fail row counted, a converged milestone whose steered GREEN
# was followed by a failed review at HEAD printed "complete" over a tree no reviewer read (the case
# converged_at_head exists to close), and review_mode refused a second review of a tree the first
# never reviewed. One reader for every "since the last review" question below.
last_review_sha(){ role_rows | awk -F'\t' '($3=="reviewer"||$3=="verifier") && $5=="pass"{h=$6} END{print h}'; }
# Did anything land in MAIN/TEST scope since the last reviewer or verifier row (at HEAD or not — the
# question RU and review_mode ask)? True when there is no review row yet, or when the tree moved.
tree_moved_since_last_review(){ local vbase
  vbase="$(last_review_sha)"
  [ -n "$vbase" ] || return 0
  landed_between "$vbase" "$(git rev-parse --short HEAD 2>/dev/null)" any; }
# Converged, AND the last reviewer or verifier row is the tree's last MAIN/TEST landing (1.8.4). The
# question `next_role` asks before it calls a milestone done: the token in issues.md is a verdict over
# the HEAD the review read, and a steered spawn after convergence moves HEAD past it. With no review
# row at all the token is the only evidence there is (a milestone reviewed before the ledger carried
# reviewer rows), and it stands as it always did.
converged_at_head(){ local v
  review_converged || return 1
  v="$(last_review_sha)"; [ -n "$v" ] || return 0
  # A sha that no longer resolves (a rebase, squash or amend after convergence; the ledger's `none`)
  # is not evidence that the tree moved. landed_between fails OPEN on it - "landed" - and that sent
  # a converged, rebased milestone back through a full priced round; 1.8.3 answered done here, and
  # the token stands as it does with no review row at all.
  sha_resolves "$v" || return 0
  ! landed_between "$v" "$(git rev-parse --short HEAD 2>/dev/null)" any; }
# ── verify BY INTENT (harness 1.8.5) ─────────────────────────────────────────
# A steered fix cycle asks one question of its review: did the steer's items land? TT-4348 M8 round
# 3 answered it with a full opus fan-out ($8.00) that raised nine majors, every one of the form "steer
# gap N absent" or "landed GREEN unpinned" - the reviewers did what the steer asked them to check, at
# round prices. review_mode chose verify by DIFF SIZE alone; a steered cycle is chosen by intent:
# when every open blocker/major is either a driver finding (`s<n>-driver-<k>`, written by `steer`)
# that no verify pass has re-proved yet, or a reviewer finding whose owner's last row is a steered
# spawn (`run --role`) that reported done with a commit still at HEAD, the next review is ONE verifier
# over those ids, whatever the diff measures. A full round FOLLOWS that verify if anything stays open:
# the verifier row carries `intent` in the ledger's steer column, and the next review_mode over a
# moved tree with open ids answers `full` instead of measuring again. The other case keeps the size
# rule below. Round 1 is a full fan-out as it always was; REVIEW_VERIFY_MODE=0 disables this too.
last_review_row(){ role_rows | awk -F'\t' '($3=="reviewer"||$3=="verifier") && $5=="pass"{r=$0} END{print r}'; }
# The role's done_at_head row was a steered spawn: column 13 says so.
steered_done_at_head(){ local row
  done_at_head "$1" || return 1
  row="$(role_rows_since_ack | awk -F'\t' -v r="$1" '$3==r' | tail -1)"
  [ "$(printf '%s\n' "$row" | cut -f13)" = steered ]; }
# A driver finding no verify pass has left open: its line in the steer artifact carries no
# `still open (verify k)` suffix. Read from the artifact, not from open_findings' 160-char cut.
driver_id_fresh(){ local f
  for f in $(ms_artifacts | grep '_driver_issues\.md$'); do
    grep -F -- "] $1 [" "review-results/$f" 2>/dev/null | grep -q 'still open (' && return 1
  done; return 0; }
# Prints the count of open ids it would hand the verifier; false when any open finding is outside the
# rule (a prose finding, an id no steer or steered fix accounts for, a driver id already re-proved).
verify_by_intent(){ local n=0 id f line p own ok
  [ "${REVIEW_VERIFY_MODE:-0}" = 1 ] || return 1
  while IFS=$'\t' read -r id f line; do
    [ -n "$f" ] || continue
    [ -n "$id" ] || return 1
    case "$id" in
      s[0-9]*-driver-*) driver_id_fresh "$id" || return 1; n=$(( n + 1 )); continue;;
    esac
    p="$(printf '%s' "$line" | first_finding_path)"; [ -n "$p" ] || return 1
    ok=0; for own in test-author implementer; do
      path_in_scope "$own" "$p" 2>/dev/null && steered_done_at_head "$own" && ok=1
    done
    [ "$ok" = 1 ] || return 1
    n=$(( n + 1 ))
  done <<EOF
$(open_findings)
EOF
  [ "$n" -gt 0 ] || return 1
  echo "$n"; }
# The last passed review row is a by-intent verifier: what it left open goes to a full round.
last_verify_by_intent(){ local row; row="$(last_review_row)"; [ -n "$row" ] || return 1
  [ "$(printf '%s\n' "$row" | cut -f3)" = verifier ] && [ "$(printf '%s\n' "$row" | cut -f13)" = intent ]; }
review_mode(){ local rnd base vbase lines vlines noid nint
  rnd="$(review_round_now)"
  [ "$rnd" -ge 2 ] || { echo full; return; }
  [ "${REVIEW_VERIFY_MODE:-0}" = 1 ] || { echo "full:REVIEW_VERIFY_MODE is not 1 — every round is a fan-out"; return; }
  # THE LAST REVIEW ROW, at HEAD or not — the same question RU asks. verify_base() skips rows at HEAD
  # (a verifier commits nothing, so its row IS HEAD) and would fall through to an older review whose
  # diff to HEAD is the fix it already verified: a second verify of an unchanged tree, bought.
  vbase="$(last_review_sha)"
  if [ -n "$vbase" ] && ! landed_between "$vbase" "$(git rev-parse --short HEAD 2>/dev/null)" any; then
    echo "none:no line of MAIN_SCOPE or TEST_SCOPE has changed since the last review at $vbase"; return; fi
  # BY INTENT (1.8.5), before the size rule: a steered fix cycle's review is a verify pass over the
  # steer's ids, whatever the diff measures; and the pass after a by-intent verify that left ids open
  # is a full round, whatever the diff measures.
  if nint="$(verify_by_intent)"; then
    echo "verify:by intent - every open finding is a driver steer (s<n>-driver-<k>) or a steered fix at HEAD, $nint id(s), the diff size is not measured; open: $(open_ids | tr '\n' ' ')"; return; fi
  if last_verify_by_intent && [ -n "$(open_ids)" ]; then
    echo "full:the by-intent verify pass at $vbase left $(open_ids | wc -l | tr -d ' ') id(s) open - a full round follows a steered cycle's verify"; return; fi
  base="$(review_base)"; lines="$(code_diff_lines "$base")"
  [ "$lines" -le "${REVIEW_FULL_ROUND_DIFF_LINES:-200}" ] \
    || { echo "full:$lines code lines since the last full round at $(git rev-parse --short "$base" 2>/dev/null) > REVIEW_FULL_ROUND_DIFF_LINES=${REVIEW_FULL_ROUND_DIFF_LINES:-200}"; return; }
  noid="$(open_findings | awk -F'\t' '$1==""' | wc -l | tr -d ' ')"
  [ "${noid:-0}" = 0 ] || { echo "full:$noid open finding(s) carry no id (prose artifacts) — a verifier addresses findings by id"; return; }
  [ -n "$(open_ids)" ] || { echo "full:no open finding carries an id"; return; }
  echo "verify:$lines code lines in MAIN/TEST scope since the last full round at $(git rev-parse --short "$base" 2>/dev/null); open: $(open_ids | tr '\n' ' ')"; }
# The record a verify pass leaves: `_round<N>_verify<k>_verification.md`, N = the last full round on
# disk, k = one past the verifications so far. Matches `review_verifications()` (informational) and
# none of the `_issues\.md$` selectors, so a verify pass is never mistaken for a round.
verification_artifact_path(){ local br ml
  br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')"
  ml="$(printf '%s' "$MS" | tr 'A-Z' 'a-z')"
  printf 'review-results/%s_%s_round%s_verify%s_verification.md' "$br" "$ml" "$(review_rounds)" "$(( $(review_verifications) + 1 ))"; }
# ── RA: area recurrence ──────────────────────────────────────────────────────
# The rounds the ledger had started when the driver last acked, so RA counts findings raised SINCE
# the ack: an ack --verdict true says the abstraction was fixed, and the findings that led there are
# not evidence against the fix. Same run-of-rows arithmetic as review_round_state, same disk offset as
# review_round_now, so the number lines up with the `_roundN_` in the filenames.
rounds_at_last_ack(){ local st started disk offset a
  a="$(ledger_rows | awk -F'\t' -v d="$(review_dim_count)" '
    $5=="killed" || $5=="api" || $14=="owed" { next }
    $5=="ack" { a=rounds; next }
    $5=="warn" { next }
    $3=="reviewer" { if (prev!="reviewer" || run>=d) { rounds++; run=1 } else { run++ }; prev="reviewer"; next }
    { prev=$3; run=0 }
    END { print a+0 }')"
  st="$(review_round_state)"; started="${st%% *}"; disk="$(review_rounds)"; disk="${disk:-0}"
  offset=$(( disk - ${started:-0} )); [ "$offset" -lt 0 ] && offset=0
  [ "${a:-0}" -gt 0 ] && echo $(( a + offset )) || echo 0; }
# `path<TAB>count<TAB>rounds<TAB>details` for the worst path at or over AREA_RECURRENCE_LIMIT, else
# nothing. Open or resolved both count — the measured pattern was four findings each CLOSED by a patch
# that revealed the next; refuted ones do not, a wrong finding is not a defect in the area.
area_recurrence(){ local lim; lim="${AREA_RECURRENCE_LIMIT:-}"
  [ -n "$lim" ] && [ -f "$HERE/lib/review_findings.py" ] || return 0
  # Over the ROUNDS' artifacts: a steer is the driver naming work, not a defect a review found, and
  # three steers on one path would otherwise read as the area recurring (1.8.5).
  python3 "$HERE/lib/review_findings.py" recurrence "$lim" "$(rounds_at_last_ack)" \
    $(round_artifacts | sed 's|^|review-results/|') 2>/dev/null; }
# ── the parallel fan-out ─────────────────────────────────────────────────────
# `1` when this round may run its dimensions concurrently, else `0:<why>`. Sequential is what lets
# the cost breakers be re-checked BETWEEN dimensions (see stop_reason_cost); a parallel round can
# overshoot MILESTONE_USD_CEILING by up to width-1 invocations, so a round whose PROJECTED spend —
# width × the milestone's mean reviewer cost so far, or the spawn cap when no reviewer has run — would
# cross the ceiling runs sequentially and says so. RI is projected the same way.
review_parallel_ok(){ local w n_since cap b ceiling spent est proj over
  [ "${REVIEW_PARALLEL:-0}" = 1 ] || { echo "0:REVIEW_PARALLEL is not 1"; return; }
  # THE WIDTH THIS FAN-OUT ACTUALLY SPAWNS, which on a resumed round is only the owed dimensions
  # (1.8.3): projecting the full width there would price two reviewers nobody is going to buy and
  # could force a one-dimension resume sequential against a ceiling it never approaches.
  w="$(dims_to_run | wc -l | tr -d ' ')"; [ "${w:-0}" -ge 1 ] || w="$(review_dim_count)"
  [ "$w" -ge 2 ] || { echo "0:one dimension"; return; }
  b="$(budget)"; cap=$(( b * 3 + ${REVIEW_BUDGET:-3} * $(ri_review_mult) ))
  n_since="$(role_rows_since_ack | wc -l | tr -d ' ')"
  [ $(( n_since + w )) -le "$cap" ] || { echo "0:$n_since invocations since the last ack + $w would pass the RI cap $cap — sequential, so RI is checked between dimensions"; return; }
  ceiling=""; command -v milestone_usd_ceiling >/dev/null 2>&1 && ceiling="$(milestone_usd_ceiling "$MS" 2>/dev/null)"
  [ -n "$ceiling" ] || ceiling="${MILESTONE_USD_CEILING:-}"
  if [ -n "$ceiling" ]; then
    spent="$(role_rows | awk -F'\t' '{s+=$9} END{printf "%.2f", s+0}')"
    est="$(role_rows | awk -F'\t' '$3=="reviewer"{s+=$9; n++} END{if(n) printf "%.4f", s/n}')"
    [ -n "$est" ] || est="$(spawn_usd_cap reviewer "$(model_for reviewer)")"; [ -n "$est" ] || est=0
    proj="$(awk -v s="$spent" -v e="$est" -v w="$w" 'BEGIN{printf "%.2f", s + e * w}')"
    over="$(awk -v a="$proj" -v b="$ceiling" 'BEGIN{print (a+0>b+0)?1:0}')"
    [ "$over" = 0 ] || { echo "0:a parallel round projects \$$proj (spent \$$spent + $w × \$$est) against MILESTONE_USD_CEILING \$$ceiling — sequential, so the ceiling is checked between dimensions"; return; }
  fi
  echo 1; }
# Waits for EVERY pid, beating every HEARTBEAT_SECS; polls at 1s so a short round is not rounded up
# to the poll. Reaps nothing — each pid's status is still there for a later `wait <pid>`.
wait_group_with_heartbeat(){ local label="$1" t0="$2" hb next now p alive; shift 2
  hb="${HEARTBEAT_SECS:-60}"; now="$(date +%s)"; next=$(( now + hb ))
  while :; do
    alive=0; for p in "$@"; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ "$alive" = 1 ] || break
    sleep "${SPAWN_POLL_SECS:-1}"; now="$(date +%s)"
    if [ "$hb" -gt 0 ] && [ "$now" -ge "$next" ]; then heartbeat "$label" "$(( now - t0 ))"; next=$(( now + hb )); fi
  done; }

# `milestone_model()` is loop.config's per-milestone override for the IMPLEMENTER only — correctness-
# critical Mn on opus, routine Mn on sonnet, same acceptance bar either way. It had NO reader: the
# template declared it, harness-selfcheck.sh asserted the driver honoured it, and the driver never
# mentioned it — so the published harness shipped a self-check that failed on the first install, and
# the documented saving had never once happened. Exactly the defect this file's header describes for
# REVIEW_BUDGET and the MODEL_* profile, still live in the one knob the fix did not reach.
#
# Guarded by `command -v`, so a loop.config that defines no `milestone_model` keeps the flat
# MODEL_IMPLEMENTER and nothing changes for it. The override applies to the implementer alone —
# widening it to the reviewer would cheapen the acceptance bar, which is the opposite of the point.
#
# `--step` is PASSED THROUGH to milestone_model as its second argument, and an unset --step is passed
# as the empty string — which loop.config's own contract answers with the SAFE model. So the driver
# does not decide the tier and does not guess the step: forgetting the flag costs money, never
# correctness. Deriving the step here instead was considered and rejected — the only counter available
# is the implementer invocation count, and one measured milestone spent 7 of those on 4 steps, so a
# derived "step 7" would have picked the model for a step that does not exist.
# ── escalation (TT-3176) ─────────────────────────────────────────────────────
# Escalation is what makes every cheaper default in this file safe: the two situations where a
# cheaper agent has already failed BY DEFINITION get the strongest tier mechanically, rather than
# because someone remembered in the moment.
#
# THE RANK IS THE WHOLE SAFETY PROPERTY. "Escalation never lowers a gate" cannot be a promise in a
# comment — a loop.config setting MODEL_ESCALATION_MUTATION=sonnet against an opus reviewer would
# otherwise DOWNGRADE the last gate before a milestone lands, which is the exact opposite of what
# this mechanism is for. So escalate_to takes the HIGHER-ranked of the two, and an unrecognised id
# ranks 0 and therefore changes nothing: a typo costs money at worst, never correctness.
model_rank(){ case "$1" in haiku) echo 1;; sonnet) echo 2;; opus) echo 3;; fable) echo 4;; *) echo 0;; esac; }
escalate_to(){ local cur="$1" esc="$2"
  [ -n "$esc" ] || { echo "$cur"; return; }
  [ "$(model_rank "$esc")" -gt "$(model_rank "$cur")" ] && { echo "$esc"; return; }
  echo "$cur"; }
# The MARKER, and it is the plan's, not the driver's: TDD_PLAN §8 `correctness_critical:` lists the
# mutation-gated Mn, loop.config carries it as CORRECTNESS_CRITICAL, and this reads it. Whole-word
# match so `M1` never matches `M12`. No list → nothing is correctness-critical, which is the correct
# reading of a plan that declared none.
correctness_critical(){ case " ${CORRECTNESS_CRITICAL:-} " in *" $MS "*) return 0;; *) return 1;; esac; }

# The tier a role would run at with NO escalation. Split out so `model_for` and the run loop's
# ESCALATED marker cannot disagree about what the baseline was — the marker is only honest if it is
# derived from the same function the decision is.
base_model_for(){ case "$1" in
  # THE POST-REVIEW STEP (1.8.3). Once the steps are built there is no `--step` to derive, and
  # `milestone_model` answers SAFE for an empty step - so on a routine milestone every fix-cycle
  # implementer ran at the expensive tier the milestone had been priced NOT to use (TT-4348 M5: five
  # rows, $6.05, 41 % of the review side; M4 §2.6 is the same shape one step earlier). The step id
  # `post-review` is passed instead, so the CONFIG decides as it does for every other step.
  # post_review_step() is defined BELOW model_for, outside the range harness-selfcheck.sh extracts
  # and sources to drive the escalation arms on their own; the guard makes it a no-op there, and a
  # snippet with no ledger and no STEPS then answers exactly what it answered before.
  implementer) local m="" st="$STEP"
               [ -n "$st" ] || { command -v post_review_step >/dev/null 2>&1 && post_review_step && st=post-review; }
               if command -v milestone_model >/dev/null 2>&1; then m="$(milestone_model "$MS" "$st" 2>/dev/null)"; fi
               [ -n "$m" ] || m="${MODEL_IMPLEMENTER:-opus}"
               echo "$m";;
  # THE ROUTINE TIER FOR THE REVIEWER (1.8.6). TT-4348 M9 §3.1: three sonnet rounds cost $8.95
  # against M8's $37.02 for four opus rounds and found the two production defects in round 1; the
  # opus round 1 on a routine milestone was a habit from the correctness-critical ones. A milestone
  # NOT in CORRECTNESS_CRITICAL reviews at MODEL_REVIEWER_ROUTINE when the knob is set; a critical one
  # keeps MODEL_REVIEWER and the mutation escalation in model_for raises it as before. Decided HERE,
  # in the base tier, so the run header cannot print a false ESCALATED for the routine pick. EMPTY or
  # absent is the 1.8.5 behaviour: every round at MODEL_REVIEWER.
  reviewer)    if [ -n "${MODEL_REVIEWER_ROUTINE:-}" ] && ! correctness_critical; then echo "$MODEL_REVIEWER_ROUTINE"
               else echo "${MODEL_REVIEWER:-opus}"; fi;;
  verifier)    echo "${MODEL_VERIFIER:-sonnet}";;
  *)           echo "";; esac; }

# True when this spawn is a FOLLOW-UP review round on a milestone with no mutation gate — the one
# case where the reviewer reads a diff that a previous round has already read the front of.
delta_review(){ [ "$1" = reviewer ] || return 1
  [ -n "${MODEL_REVIEWER_DELTA:-}" ] || return 1
  correctness_critical && return 1
  # THE ROUND, not the invocation count. With a fan-out of N, `count_role reviewer >= 1` is true from
  # the SECOND DIMENSION OF ROUND 1 onward — so dimensions 2..N of the first round would have read the
  # full milestone at the delta tier, which is the one thing this is fenced against.
  [ "$(review_round_now)" -ge 2 ]; }

model_for(){ case "$1" in
  test-author) echo "${MODEL_TEST_AUTHOR:-opus}";;
  # Implementer and reviewer BOTH escalate on a mutation-gated milestone, for different reasons: the
  # implementer because that work's defects are the kind a passing suite does not notice, the reviewer
  # because it is the last gate before that work lands. Applied AFTER milestone_model, so a
  # routine-tier STEP of a correctness-critical MILESTONE still comes back up — milestone_model
  # chooses per step, escalation is a property of the milestone's gate.
  implementer|reviewer)
               local m; m="$(base_model_for "$1")"
               # DELTA REVIEW. Round 1 reads the whole milestone; every later round reads the diff
               # since the last reviewer row (review_base()), which is a fraction of it — and in the
               # measured milestone rounds 5-8 produced one major and nine minors between them while
               # costing the same $2.70-$3.70 a round as round 1. So later rounds run at
               # MODEL_REVIEWER_DELTA.
               #
               # This LOWERS a tier, which nothing else in this file does, so it is fenced three ways:
               # never on round 1, never on a correctness_critical milestone (the escalation below
               # would raise it back anyway), and never when the knob is empty. The reviewer is still
               # an independent role reading an independent diff; what changes is the tier it reads at.
               delta_review "$1" && m="${MODEL_REVIEWER_DELTA}"
               # ...UNLESS THE PLAN LOOKED AT THIS STEP (1.8.5). An EXPLICIT per-step arm of
               # milestone_model that names a tier for the implementer's step wins over the
               # mutation escalation; the escalation applies to a step with no arm of its own (the
               # `*)` fallback, or a milestone-wide `Mn:*`). step_hint is defined BELOW model_for, as
               # post_review_step is, outside the range harness-selfcheck.sh extracts; absent, the
               # escalation applies as it did in 1.8.4. The reviewer always escalates: it is the
               # last gate before the work lands, and no step hint prices it.
               if correctness_critical; then
                 if [ "$1" = implementer ] && command -v step_hint >/dev/null 2>&1 && [ -n "$(step_hint)" ]; then :
                 else m="$(escalate_to "$m" "${MODEL_ESCALATION_MUTATION:-}")"; fi
               fi
               echo "$m";;
  # The VERIFIER (1.8.0) reads a handful of fix commits and re-proves named findings; the delta tier
  # is its price. It escalates with the reviewer on a mutation-gated milestone — it is the last gate
  # there too — and never lowers below MODEL_VERIFIER.
  verifier)    local v; v="$(base_model_for verifier)"
               correctness_critical && v="$(escalate_to "$v" "${MODEL_ESCALATION_MUTATION:-}")"
               echo "$v";;
  driver)      echo "${MODEL_DRIVER:-opus}";;
  # The breaker-escalation agent. Not a spawnable role and deliberately not in next_role's rotation:
  # it runs once, after the loop has already stopped.
  escalation)  echo "$(escalate_to "${MODEL_DRIVER:-opus}" "${MODEL_ESCALATION_BREAKER:-}")";;
  *)           echo "${MODEL_SEARCH:-haiku}";; esac; }

# Reasoning effort, resolved per role and passed on the spawn beside the model. TT-3175's third AC
# says "both `model` and `effort` overrides are passed"; the model half was wired and this half was
# not. `EFFORT_*` was declared in loop.config.template, documented in harness-scripts.md, exported
# from kitchen.env — and the string `effort` appeared ZERO times in this file, so the override had
# never once reached a spawn. That is the fourth knob in this harness to be declared, documented and
# read by nothing: REVIEW_BUDGET, the MODEL_* profile and milestone_model() were the first three, and
# this file's own header describes the pattern.
#
# `--effort <level>` is a real CLI flag, verified against the binary rather than inferred from the
# ticket — worth stating, because an AC of this shape can otherwise be "met" by passing a flag that
# does not exist.
#
# A role with no entry yields the empty string and the flag is omitted entirely, so a loop.config
# predating this change spawns exactly as it did before.
# An open blocker in the consolidated summary - the one case a post-review fix is not routine work.
open_blocker(){ grep -qE '^[[:space:]]*- \[ \] .*\[blocker\]' issues.md 2>/dev/null; }
# True once the milestone's steps are built and a review has run, with no open blocker: the fix-cycle
# implementer base_model_for() prices as `post-review` rather than as an unset step. See the comment
# on the implementer arm above.
post_review_step(){ [ -n "${STEPS:-}" ] && [ "$(count_role reviewer)" -gt 0 ] \
  && [ "$(done_steps_count)" -ge "$STEPS" ] && ! open_blocker; }
# THE EXPLICIT PER-STEP HINT (1.8.5). TT-4348 M8 §2.4: loop.config said `M8:7|M8:8 -> sonnet`, the
# milestone was correctness-critical, and `escalate_to MODEL_ESCALATION_MUTATION` raised both steps
# to opus ($6.38) - the hint was dead text as long as it lost. Decided in the template: a per-step
# arm the plan author wrote for THIS step wins for this step; the escalation covers the steps the
# author did not price. "Explicit" is measured, not parsed: milestone_model's answer for the step
# differs from its answer for a step id no plan carries (`no-such-step`) on the same milestone. So
# the `*)` fallback and a milestone-wide `Mn:*` arm are NOT explicit (they answer the probe the same
# way) and keep the escalation; an arm naming the SAFE tier is indistinguishable from the fallback
# and the escalation over it changes nothing. Prints the hinted tier, or nothing.
step_hint(){ local st="$STEP" m p
  [ -n "$st" ] || { post_review_step && st=post-review; }
  [ -n "$st" ] || return 1
  command -v milestone_model >/dev/null 2>&1 || return 1
  m="$(milestone_model "$MS" "$st" 2>/dev/null)"; p="$(milestone_model "$MS" "no-such-step" 2>/dev/null)"
  [ -n "$m" ] && [ "$m" != "$p" ] || return 1
  printf '%s' "$m"; }
effort_for(){ case "$1" in
  test-author) echo "${EFFORT_TEST_AUTHOR:-}";;
  implementer) echo "${EFFORT_IMPLEMENTER:-}";;
  reviewer)    echo "${EFFORT_REVIEWER:-}";;
  verifier)    echo "${EFFORT_VERIFIER:-}";;
  driver)      echo "${EFFORT_DRIVER:-}";;
  *)           echo "${EFFORT_SEARCH:-}";; esac; }

# ── reading a result file ────────────────────────────────────────────────────
# `claude -p --output-format json` writes `usage` + `total_cost_usd`. ONE reader, two callers: the
# spawn that finished normally, and `record --from` for a role that was KILLED after the CLI had
# already written its file. A killed role used to be entered as free — the ledger is the only artifact
# that says what the loop cost, and a zero in it is a lie rather than a gap.
usage_tokens(){ [ -f "$1" ] || { echo 0; return; }
  python3 -c "import json,sys;u=json.load(open(sys.argv[1])).get('usage',{});print(u.get('cache_creation_input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('input_tokens',0)+u.get('output_tokens',0))" "$1" 2>/dev/null || echo 0; }
usage_cost(){ [ -f "$1" ] || { echo 0; return; }
  python3 -c "import json,sys;print(round(json.load(open(sys.argv[1])).get('total_cost_usd',0),4))" "$1" 2>/dev/null || echo 0; }

# ── the heartbeat ────────────────────────────────────────────────────────────
# The cheapest change in this file and the one that mattered most. A role printed NOTHING until it
# exited, so a 99-minute invocation and a hung one were indistinguishable from outside; four
# invocations were killed mid-flight in one measured milestone, two of them AFTER committing and
# BEFORE their gate, which leaves an ungated commit and no ledger row to repair by hand.
#
# Three facts, chosen because they are what separates "working" from "stuck":
#   elapsed   — measured against the operator's own expectation for this role
#   HEAD      — a role that has committed has done real work whatever it prints later
#   artifact  — the newest gate log, its age and its size: a growing it.log is a container suite in
#               flight; one that has not moved in ten minutes of a sixty-minute role is a hang
#
# NOT `--output-format stream-json`. That shows turns going by and costs the parseable
# `usage`/`total_cost_usd` object every ledger row and the `cost` report are built on. A progress bar
# is not worth the spend record.
# BSD `stat -f %m` and GNU `stat -c %Y` are different flags and neither is present everywhere.
file_mtime(){ stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || date +%s; }
newest_artifact(){ local f
  f="$(ls -t "$LOGDIR"/*.log 2>/dev/null | head -1)"
  [ -n "$f" ] || { printf 'none yet'; return; }
  printf '%s (%ss since last write, %s lines)' "$(basename "$f")" \
    "$(( $(date +%s) - $(file_mtime "$f") ))" "$(wc -l < "$f" | tr -d ' ')"; }
heartbeat(){ printf '  ⋯ %s · %dm%02ds elapsed · HEAD %s · newest gate artifact: %s\n' \
    "$1" "$(( $2 / 60 ))" "$(( $2 % 60 ))" \
    "$(git rev-parse --short HEAD 2>/dev/null || echo none)" "$(newest_artifact)"; }
# Waits for the spawned CLI, beating every $HEARTBEAT_SECS, and returns ITS exit status — the caller's
# `rc` must keep meaning what it meant when the call was in the foreground. `kill -0` does not reap, so
# the `wait` afterwards still yields the child's status. HEARTBEAT_SECS=0 disables the beat and this
# degrades to a plain wait.
# THE POLL (1.8.7): `sleep 2` here was the floor under every spawn - a stub that exits in 50 ms still
# cost 2 s to notice, several hundred times per suite run (measured: 20.7 -> 17.4 min on the
# harness-tests.sh suite, 16 %). SPAWN_POLL_SECS (loop.config, default 1) is the interval; the suite sets 0.1.
wait_with_heartbeat(){ local pid="$1" role="$2" t0="$3" hb next now rc
  hb="${HEARTBEAT_SECS:-60}"; now="$(date +%s)"; next=$(( now + hb ))
  while kill -0 "$pid" 2>/dev/null; do
    sleep "${SPAWN_POLL_SECS:-1}"
    now="$(date +%s)"
    if [ "$hb" -gt 0 ] && [ "$now" -ge "$next" ]; then
      heartbeat "$role" "$(( now - t0 ))"; next=$(( now + hb ))
    fi
  done
  wait "$pid"; rc=$?; return $rc; }

# ── stop conditions, all enforced HERE, none of them prose ───────────────────
# Each returns a reason string on stdout when it trips, and nothing when it does not. They are
# checked in cost order: the cheapest, most certain limit first.
#
# SPLIT IN TWO, and the split is the fan-out's. `stop_reason` is evaluated once per pass of `run`'s
# while-loop; a reviewer round is now N spawns INSIDE one pass, so before this split every breaker was
# checked once, before the first of them. Measured: with MILESTONE_USD_CEILING=$0.60 and a role costing
# $0.50, invocation 4 was already over the ceiling and invocation 5 was spawned anyway ($1.50 charged
# against $0.60); with --max-wall-min 1 and a 35s role, the third dimension started 13s AFTER the cap.
# The overshoot used to be one invocation because a pass spawned one role; it is now N-1, at the
# fan-out width, on the breakers whose entire job is bounding spend and wall clock.
#
# Only the COST breakers can be re-evaluated mid-round, and this is not a shortcut — it is the reason
# the split exists. RU/RV/RS/RF are PROGRESS breakers and every one of them is true by construction in
# the middle of a fan-out: a reviewer commits nothing, so after dimension 1 the tree is unchanged and
# a reviewer row sits at HEAD, which is precisely RU's trigger. Re-checking the whole of `stop_reason`
# inside the loop therefore stops every round after its FIRST dimension — verified by running it —
# which deletes the feature instead of bounding it. Spend and invocation count are monotone and mean
# the same thing at any point in a round, so those are what the round is allowed to be interrupted by.
stop_reason_cost(){
  local n b cap
  b="$(budget)"

  # RI — role invocations. Two caps, because one was both too weak and too strong (review V-M1).
  #
  # TOO WEAK: it counted every ledger row, including `ack` bookkeeping and `smoke` mechanism tests,
  # neither of which is a step of the milestone. TOO STRONG: it was un-resettable on purpose, and
  # H-B1 guaranteed the reviewer loop would eat the whole allowance at one unchanged commit —
  # measured by the reviewer, 37 of C6's 42 invocations spent on reviewer spawns with HEAD never
  # moving and eight of nine TDD steps unwritten. After that trip there was no supported way
  # forward: `ack` explicitly did not clear RI, and every subcommand exited 3, so the only exit was
  # editing LOOP_LEDGER.tsv by hand — the one artifact the loop trusts, in a repo whose journal rule
  # is "evidence — never edit to fix a count". A backstop with no recovery is not a backstop, it is
  # a milestone-ender.
  #
  # So: RI is per-ack and recoverable, RI-ABS is absolute and is not. An operator who acks
  # repeatedly still cannot run past the absolute ceiling, and one who fixed a real cause can carry
  # on. My earlier reasoning ("RI must survive any number of acknowledgements") was right about the
  # property and wrong to get it from a single un-resettable counter.
  # 2x review budget was written when a round was ONE invocation. A round is now N — one reviewer per
  # REVIEW_DIMENSIONS entry — so the allowance has to scale with the fan-out or RI trips on a loop that
  # is inside every budget it declares.
  cap=$(( b * 3 + ${REVIEW_BUDGET:-3} * $(ri_review_mult) ))
  n="$(role_rows | wc -l | tr -d ' ')"
  local n_since; n_since="$(role_rows_since_ack | wc -l | tr -d ' ')"
  [ "$n" -ge "$(( cap * 3 ))" ] \
    && { echo "RI-ABS: $n role invocations for $MS >= absolute cap $(( cap * 3 )) — NO ack clears this; the milestone needs re-planning, not another round"; return; }
  [ "$n_since" -ge "$cap" ] \
    && { echo "RI: $n_since role invocations since the last ack >= cap $cap (3x budget $b + $(ri_review_mult)x review budget ${REVIEW_BUDGET:-3}); total $n — fix the cause, then \`loop-driver.sh record $MS driver ack\`"; return; }

  # R13 — SPEND, the one quantity the ledger has always recorded and no breaker read. Two shapes,
  # because they fail differently: a MILESTONE that is quietly costing four times its plan, and a
  # single INVOCATION that has stopped converging and is re-reading the world. Both are read from
  # LOOP_LEDGER.tsv, so neither can be argued with by the thing it bounds.
  #
  # Measured on the milestone that motivated this: $60.45 and 82.6M tokens for a walking skeleton,
  # inside every existing breaker for the whole run.
  #
  # The ceiling is per-milestone and unset by default (loop.config: it belongs to the plan, not the
  # harness). Cumulative spend is counted for the MILESTONE, not since the last ack: money already
  # spent is not undone by acknowledging why it was spent.
  local ceiling spent over
  # Per-milestone first, scalar second — the same optional-function shape as churn_budget() and
  # doc_budget(). A scaffold milestone and a redaction milestone do not deserve the same number, and
  # the plan is where that difference is decided: TDD_PLAN §2 carries it beside iteration_budget().
  # A milestone the function has no case for yields the empty string and falls back to the scalar;
  # both empty is OFF, which is the shipped default.
  ceiling=""
  command -v milestone_usd_ceiling >/dev/null 2>&1 && ceiling="$(milestone_usd_ceiling "$MS" 2>/dev/null)"
  [ -n "$ceiling" ] || ceiling="${MILESTONE_USD_CEILING:-}"
  if [ -n "$ceiling" ]; then
    spent="$(role_rows | awk -F'\t' '{s+=$9} END{printf "%.2f", s+0}')"
    over="$(awk -v a="$spent" -v b="$ceiling" 'BEGIN{print (a+0>b+0)?1:0}')"
    [ "$over" = 1 ] && { echo "R13: $MS has spent \$$spent against MILESTONE_USD_CEILING \$$ceiling — the milestone is over budget, which is a re-planning decision, not another round. Raise the ceiling in loop.config WITH the reason, or split the milestone."; return; }
  fi
  # The per-invocation ceiling reads the LAST role row only: the trip belongs to the run that caused
  # it, and a role that ran hot once and then converged is not a reason to stop the next milestone.
  #
  # READ FROM `role_rows_since_ack`, NOT `role_rows` — the same defect the RI arm above documents
  # fixing for itself, left standing in this one. `role_rows` EXCLUDES ack rows, so `tail -1` stays
  # pinned to the offending invocation for ever: no role row can displace it, because this function
  # blocks every spawn while it trips. Measured (TT-4348 M2): a test-author read 60 real workbooks
  # for 17.3M tokens, this arm fired, and `record <MS> driver ack` — the recovery THIS BREAKER'S OWN
  # MESSAGE prints — left it tripped. The only exit was hand-editing LOOP_LEDGER.tsv, the one
  # artifact the journal rule calls evidence and forbids editing to fix a count. A backstop with no
  # recovery is not a backstop. Since-ack restores the documented contract: an ack clears it, the
  # next role row re-arms it, and no threshold moves.
  local lastrole lasttok tb lastout lastsha prevsha laststep
  lastrole="$(role_rows_since_ack | tail -1 | cut -f3)"; lasttok="$(role_rows_since_ack | tail -1 | cut -f8)"
  # THE BUDGET KNOWS THE STEP (1.8.8, TT-4348 M11 §2.5): `token_budget(role, step)`, the step from the
  # row's column 15 (the id the brief named; empty post-review and on rows from before 1.8.8, which
  # a loop.config that ignores `$2` prices as it always did). M11's step 6 was two thirds of the
  # milestone's classes; its implementer (12.0 M) and test-author (12.9 M) each warned R13-LANDED,
  # and step 7's implementer stopped the run 0.5 % over with the build phase complete.
  laststep="$(role_rows_since_ack | tail -1 | cut -f15)"
  if [ -n "$lastrole" ] && command -v token_budget >/dev/null 2>&1; then
    tb="$(token_budget "$(budget_role "$lastrole")" "$laststep")"
    if [ -n "$tb" ] && [ -n "$lasttok" ] && [ "$lasttok" -gt "$tb" ] 2>/dev/null; then
      # ...UNLESS THE ROW IT JUDGES LANDED ITS WORK AND PASSED (1.8.4). The arm exists for a role that
      # re-derives the repository and commits nothing; a role that read a lot, committed in its scope
      # and passed its gate finished the brief it was given, and stopping AFTER that row is recorded
      # buys an ack and a relaunch and nothing else (TT-4348 M6: six minors across eight files in one
      # green commit, 10.63 M tokens against 10 M). The run is told, on the pass this row is the last
      # one - the next role row moves the arm on by itself - and the size of the brief is the
      # operator's to split. A hot row that committed nothing is the stop it always was. `pass` is
      # the harness's word for "exited 0, in scope, its own gate green" (see done_steps_count).
      lastout="$(role_rows_since_ack | tail -1 | cut -f5)"; lastsha="$(role_rows_since_ack | tail -1 | cut -f6)"
      # The row BEFORE it, among role rows - and the step counter's seed when there is none. The
      # first version indexed the filtered ledger by raw NR, so the first role row of a milestone
      # (and any row whose ledger predecessor was a smoke row) got an empty prevsha, landed_between
      # read '' as "nothing landed", and the hard stop fired on the very row this arm lets through.
      prevsha="$(role_rows | awk -F'\t' '{p=c; c=$6} END{print p}')"
      [ -n "$prevsha" ] || prevsha="$(git rev-parse --short "$(step_counter_seed)" 2>/dev/null)"
      # ...AS A SOFT BREAKER WITH ITS OWN ID, not an echo. The first cut printed a WARN and returned no
      # reason: no warn row, no signature, nothing to ack, and no stop on repetition - a role over
      # budget on every step that commits each time was never stopped by R13 again. R13-LANDED is
      # graded soft (breaker_grade): stop_decision warns once, records the warn row, and the same
      # role hot-but-landed a second time is a recorded stop with the ack path every breaker has.
      if [ "$lastout" = pass ] && landed_between "$prevsha" "$lastsha" "$lastrole"; then
        # ...AND NOT ONCE EVERY STEP IS BUILT (1.8.8, M11 §2.5). The stop on a repeat exists so a
        # plan whose steps are all too big is split before the next one is paid for; with no step
        # left to split, the stop bought a three-minute ack and said so. A hot-but-landed row after
        # the build phase is noted, not tripped.
        if [ -n "${STEPS:-}" ] && [ "$(done_steps_count)" -ge "$STEPS" ]; then
          echo "  (R13-LANDED would warn: the last $lastrole invocation used $lasttok tokens > token_budget $tb, but every step is built and the row landed and passed - no stop, nothing to split)" >&2
          return 0
        fi
        # The step is NOT in this text: sig_of normalises digits, not `2a`, and a step id in the
        # reason gave every step its own signature - the second occurrence never came (M12, live).
        echo "R13-LANDED: the last $lastrole invocation used $lasttok tokens > token_budget $tb, but it landed its commit ($prevsha..$lastsha) and passed - the run continues once; a brief this size is one to split (or price it: token_budget(role, step) in loop.config), and the same role hot-but-landed again stops"; return
      else
        echo "R13: the last $lastrole invocation used $lasttok tokens > token_budget $tb - a role that needs this much context is re-deriving the repository, not working from its brief. Hand it the diff, its own open findings and the step text, then \`loop-driver.sh record $MS driver ack\`"; return
      fi
    fi
  fi
  return 0
}

# Every stop condition: the cost breakers above, then the progress ones. Checked in cost order — the
# cheapest, most certain limit first — which is why the cost group is the one that got split out.
stop_reason(){
  local rounds same
  local cost_stop; cost_stop="$(stop_reason_cost)"
  [ -n "$cost_stop" ] && { printf '%s\n' "$cost_stop"; return; }

  # RU — an unchanged tree cannot produce a different review verdict. M0 spent three reviewer
  # invocations ($3.30) on ONE commit: every open finding sat in DRIVER-owned files (build.gradle,
  # config/checkstyle/*), the next-role table answers `reviewer` whenever the steps are done and the
  # review has not converged, and there is no branch that routes a finding to the role that owns its
  # path. Rounds 2 and 3 both said so in their own summaries and were re-spawned anyway. Stopping
  # here costs one round; the alternative burns the whole review budget on a tree nobody touched.
  local lastrev_head
  # A KILLED review row is no review of HEAD (1.8.6, M9 §2.5): the role never ran; read past it.
  lastrev_head="$(role_rows_since_ack | awk -F'\t' '($3=="reviewer"||$3=="verifier") && $5!="killed"{h=$6} END{print h}')"
  # ...AND NOTHING A WRITING ROLE COULD FIX. `stop_reason` runs BEFORE `next_role` in both `run` and
  # `next`, so while RU tripped on "reviewer ran at this HEAD and nothing landed" alone it fired on
  # every pass immediately after a non-converged round — a reviewer commits nothing, so that condition
  # is true by construction — and the routing arm added to next_role could never be reached. The loop
  # still stopped for a human `ack` once per round, which is the exact cost the routing was written to
  # remove. RU's purpose is to catch a loop that CANNOT make progress; an open finding owned by the
  # test-author or the implementer is progress waiting to be dispatched, so it is not RU's case.
  # "Nothing has landed" is about the WRITING roles' scopes, not HEAD: the driver's own
  # `chore(loop): …` commits move HEAD without changing a line a reviewer would read.
  # ...AND A ROUND HAS RUN (1.8.6, M9 §2.5): a review row at HEAD over the driver's steer artifact
  # alone is not a review of HEAD; round 1 is owed and next_role fans it out.
  # ...AND NO DIMENSION OF THE ROUND IS OWED (1.8.7 review, blocker): a round the API refused a
  # dimension of has progress waiting to be dispatched - next_role's resume arm - and RU on the
  # relaunch demanded an ack the api message had just said was not owed.
  if [ -n "$lastrev_head" ] && ! landed_between "$lastrev_head" "$(git rev-parse --short HEAD 2>/dev/null)" any \
     && ! review_converged && ! only_driver_artifacts && [ -z "$(round_missing_dims)" ] \
     && ! owns_open_finding test-author && ! owns_open_finding implementer; then
    echo "RU: the reviewer already ran at HEAD $lastrev_head and nothing has landed since — a re-review of an unchanged tree cannot converge. Route every open finding to the role that OWNS its path (scripts/check-scope.sh globs; a finding in DRIVER_SCOPE is the driver's own to fix), land the fix, then \`loop-driver.sh record $MS driver ack\`"
    return
  fi

  # RO — A REVIEWER THAT DID NOT REVIEW, TWICE (1.8.8, M11 §2.7). An `owed` row (blocked, no
  # findings) has its dimension re-run at the same round by the resume arm; the first cut stamped a
  # second such answer `again` and let the round stand - and the 1.8.8 review showed the milestone
  # then printing `complete: review converged` over a dimension whose own artifact said UNREVIEWED,
  # M11 §2.7 re-shipped for the second occurrence. A reviewer that stops twice is a role or
  # environment failure (the brief says FOREGROUND), not a finding to route: the run stops, the
  # operator fixes the cause and acks, and the relaunch's resume arm re-runs the dimension - still
  # owed, because the artifact on disk still says so. REVIEW_OWED_LIMIT (2) owed rows since the ack.
  # ...PER DIMENSION, AS NEAR AS THE LEDGER CAN TELL (1.8.8 review pass 2, major): a reviewer row does
  # not carry its dimension, and the first cut counted owed rows alone - two dimensions of one
  # concurrent fan-out blocked ONCE each (the common shape of an environment fault) tripped RO before
  # either was re-run, with a message saying a re-run had happened. More owed rows than dimensions
  # still owed on disk, while at least one IS still owed, means some dimension was owed more than
  # once: that is the stop. With nothing owed on disk the re-runs reviewed, and the rows are history.
  # ...AND WITHIN THE CURRENT REVIEWER RUN (1.8.8 review pass 4, both dimensions' major): counted
  # since the ack, an owed row from round 1 (re-run, reviewed) plus one from round 2 read as one
  # dimension stopped twice, and RO stopped a run in which no dimension had. A re-run of an owed
  # dimension is contiguous with its round's reviewer rows; any non-reviewer row is a new round.
  local owed missing
  owed="$(role_rows_since_ack | awk -F'\t' '$3!="reviewer" { n=0; next } $14=="owed" { n++ } END { print n+0 }')"
  missing="$(round_missing_dims | grep -c . | tr -d ' ')"
  [ "${missing:-0}" -ge 1 ] && [ "${owed:-0}" -ge "${REVIEW_OWED_LIMIT:-2}" ] && [ "${owed:-0}" -gt "${missing:-0}" ] \
    && { echo "RO: $owed reviewer rows in this round's reviewer run answered blocked with no findings for ${missing:-0} dimension(s) still owed ($(round_missing_dims | tr '\n' ' ')) - a dimension was re-run and stopped again. Read the last owed row's note (a backgrounded gate call, a missing tool), fix the cause, then \`loop-driver.sh record $MS driver ack\` and relaunch: the resume arm re-runs the dimension"; return; }

  # RV — review rounds. C3 ran five against a declared REVIEW_BUDGET of 3, because nothing read it.
  # Counted BOTH ways since C6, and the ledger is the authority. `review_rounds()` reads `_roundN_`
  # out of filenames the REVIEWER chooses, so three consecutive spawns that all name their artifact
  # without a round suffix count as one round — which is exactly how C6 spawned four reviewers on a
  # budget of three (H-B1). A breaker whose counter is supplied by the thing it is meant to bound is
  # not a bound at all. Ledger rows are the driver's own evidence and cannot be renamed away.
  # The LEDGER is the authority whenever it has reviewer rows; filename rounds are the fallback for
  # milestones reviewed before this driver existed. Taking max() of the two — the first version of
  # this fix, minutes old — made the un-resettable counter dominate: `_round3_` is a filename on disk
  # for ever, so RV stayed tripped through an ack that had fixed every one of its causes, and C6
  # could not restart. That is the third time in one evening the same shape has appeared (RF, RI,
  # now RV): a breaker whose count cannot be reset is not strict, it is terminal.
  # ROWS -> ROUNDS. loop.config has always defined this budget as "review ROUNDS, not reviewers: one
  # fan-out of N dimension reviewers = ONE round", and while the driver ran one reviewer the two were
  # the same number. They are not any more: counting rows would trip RV after a single round of a
  # three-way fan-out. The arithmetic is `review_rounds_since_ack()`, shared with `escalate()` — the
  # two spelled it differently and the escalation file disagreed with `status` by the fan-out width.
  # ...AND STANDS ASIDE WHILE EVERY OPEN BLOCKER/MAJOR IS FIXED, AWAITING THE VERIFIER (1.8.8,
  # TT-4348 M11 §2.6). Three rounds at $11.73 found one real blocker each; RV warned on round 3 and
  # stopped the run on the next pass, one verifier ($0.31) short of converged. The budget counts
  # rounds because a round was three opus reviewers when it was written; a verify pass over ids
  # the driver can already see fixed (fixed_awaiting_ids) is not another round of the kind the
  # budget bounds - the same exemption RU has for a round with a dimension owed.
  # ...AND WHILE A DIMENSION IS STILL OWED (1.8.8 review pass 7, correctness major): the owed round's
  # two real rows count as a round and its artifact says open, so RV fired on a round no reviewer had
  # finished, spent the milestone's one soft occurrence, and its warn row split the round (below).
  rounds="$(review_rounds_since_ack)"
  [ "$rounds" -ge "${REVIEW_BUDGET:-3}" ] && ! review_converged && ! all_open_fixed_awaiting && [ -z "$(round_missing_dims)" ] \
    && { echo "RV: review round $rounds >= REVIEW_BUDGET ${REVIEW_BUDGET:-3} and issues.md has not converged"; return; }

  # RA — AREA RECURRENCE (1.8.0). One path drawing AREA_RECURRENCE_LIMIT blocker/major findings across
  # the rounds since the last ack is the same defect wearing different hats: four rounds of one
  # milestone produced four patches to one mechanism, each closing the shape just reported and
  # revealing the adjacent one, at a round's cost each, and a human reading all four together fixed
  # the class in one commit. HARD, because the next action is a re-plan, not a dispatch: every finding
  # on the path is named here so that reading is what happens next.
  local ra rapath racount rarounds radetail
  ra="$(area_recurrence)"
  if [ -n "$ra" ]; then
    IFS=$'\t' read -r rapath racount rarounds radetail <<EOF
$ra
EOF
    echo "RA: $rapath has drawn $racount blocker/major findings across review round(s) $rarounds ($radetail) — fix the abstraction, not the case: read every finding on that path together, re-plan the area, land it, then \`loop-driver.sh record $MS driver ack --signature last --verdict true --cause '<what the abstraction was>'\`"
    return
  fi

  # RS — stall. STALL_ITERATIONS consecutive invocations at the SAME HEAD means the loop is turning
  # without the tree moving. A role that legitimately produces no commit (a reviewer) is exempt.
  #
  # READ FROM `role_rows_since_ack`, NOT `ledger_rows`. Two defects in one line, and the second was
  # caused by the fix for the first:
  #
  # 1. `ledger_rows` is EVERY row, including the driver's own `ack`. `record <MS> driver ack` stamps
  #    the CURRENT HEAD, and an ack is written while the tree is by definition not moving — so the
  #    acknowledgement that exists to CLEAR a trip became a third row at the stalled sha and re-armed
  #    it. Acking RS made RS worse, deterministically. `role_rows` already excludes `ack` and `smoke`
  #    and its own comment says it is "what the sequencer and the stall breaker reason about"; the
  #    stall breaker was the one caller that did not use it.
  # 2. RS was not ack-resettable, so the run stopped BEFORE spawning anything — and nothing could
  #    move the tree, because moving the tree required a spawn. A terminal deadlock whose only exit
  #    was hand-editing LOOP_LEDGER.tsv, the one artifact the loop tells you never to edit. Same
  #    shape this file already documents for RI and RV: "a breaker whose count cannot be reset is
  #    not strict, it is terminal."
  #
  # Measured on a live milestone: two roles died to the machine sleeping, both honestly recorded
  # `fail` at one HEAD, RS tripped correctly — and then could not be cleared by any supported action.
  # ...NOR DRIVER ROWS, NOR KILLED ONES (1.8.6). M9 §2.5: the driver rows written for three kills at
  # spawn tripped RS twice ("last 3 non-review invocations all at HEAD"), each acked false. A driver
  # row is bookkeeping at whatever HEAD the driver stood on, and a killed role moved nothing because
  # it never ran; neither is the loop turning without the tree moving.
  same="$(role_rows_since_ack | awk -F'\t' '$3!="reviewer" && $3!="verifier" && $3!="driver" && $5!="killed"' | tail -"${STALL_ITERATIONS:-3}" | cut -f6 | sort -u | wc -l | tr -d ' ')"
  local ncheck; ncheck="$(role_rows_since_ack | awk -F'\t' '$3!="reviewer" && $3!="verifier" && $3!="driver" && $5!="killed"' | wc -l | tr -d ' ')"
  [ "$ncheck" -ge "${STALL_ITERATIONS:-3}" ] && [ "$same" = 1 ] \
    && { echo "RS: last ${STALL_ITERATIONS:-3} non-review invocations all at HEAD $(last_field 6) — the tree is not moving"; return; }

  # RF — repeat failure. REPEAT_FAILURE_LIMIT consecutive invocations that did not PASS is not
  # progress. Tested as "not pass", NOT as "== fail": the literal-string version was disarmed the
  # moment a second failure outcome existed. Measured on C6 — a ledger of `r6, fail, fail` is three
  # bad invocations in a row and RF stayed silent, because `sort -u` saw two values instead of one.
  # A breaker that only fires when every failure spells itself the same way is a breaker that stops
  # working the first time somebody adds a failure mode.
  # Counted since the driver's last `ack` row, because RF had NO RESET and therefore deadlocked:
  # it trips on the last N non-passing invocations, and the only thing that can clear it is a
  # passing invocation, which it is refusing to allow. Found on C6 the moment RF started working —
  # three bad invocations, three defects diagnosed and fixed, and the loop still would not restart.
  # `loop-driver.sh record <MS> driver ack` APPENDS the acknowledgement, so the failures stay in the
  # evidence and are not edited away; recording a fake `pass` to get moving would falsify the ledger,
  # which is the one artifact the whole loop trusts. RI is deliberately NOT reset by an ack — it is
  # the total-spend backstop and must survive any number of acknowledgements.
  local rows nonpass
  rows="$(rows_since_ack | wc -l | tr -d ' ')"
  nonpass="$(rows_since_ack | tail -"${REPEAT_FAILURE_LIMIT:-3}" | cut -f5 | grep -cvx pass || true)"
  [ "$rows" -ge "${REPEAT_FAILURE_LIMIT:-3}" ] && [ "$nonpass" -ge "${REPEAT_FAILURE_LIMIT:-3}" ] \
    && { echo "RF: last ${REPEAT_FAILURE_LIMIT:-3} invocations did not pass ($(rows_since_ack | tail -"${REPEAT_FAILURE_LIMIT:-3}" | cut -f5 | tr '\n' ' ')) — fix the cause, then \`loop-driver.sh record $MS driver ack\`"; return; }

  # R1 is NOT re-implemented here — loop-iteration.sh owns it and exits 3 on trip. Two readers of one
  # rule is the defect open-milestone-pr.sh already paid for; the driver reads that exit code.
  return 0
}

# ── grades, signatures, acks ─────────────────────────────────────────────────
# Every breaker above counts CONSECUTIVE events. None keys on WHAT tripped, so the same cause coming
# back three times reads exactly like three different causes — measured: one milestone tripped 38
# times, 23 of them false (19 × R8 on one churn defect, 4 × R6 on the driver's own dirty tree), each
# a human stop with a fresh diagnosis, while the one failure that repeated for 21 iterations was never
# flagged. A cause has to be a VALUE before it can be counted, so a trip has a SIGNATURE:
# `<breaker>:driver:<cksum>` over its reason with digits and shas normalised away. loop-iteration.sh
# does the same for the breakers it owns, with the role in the middle.
sig_of(){ printf '%s:driver:%s' "${1%%:*}" \
  "$(printf '%s' "$1" | sed -E 's/[0-9a-f]{7,}/H/g; s/[0-9]+/N/g; s/[[:space:]]+/ /g' | cksum | cut -d' ' -f1)"; }
# HARD stops the run as every breaker always did: scope (R5, R6), spend (R13, RI, RI-ABS) and the
# three that mean nothing is left to dispatch (RU, RD, RW). SOFT warns and continues ONCE — a `warn`
# row records that it did — and stops on the SAME signature's second occurrence, unless the driver
# acked that signature false, which suppresses it for the milestone. BREAKER_GRADES=hard is the old
# contract for every breaker.
# R13-LANDED (a hot row that landed its commit and passed) is R13's SOFT twin, so it falls to `soft`.
breaker_grade(){ [ "${BREAKER_GRADES:-}" = hard ] && { echo hard; return; }
  case "$1" in R5|R6|R13|RI|RI-ABS|RU|RD|RW|RR|RA|RO) echo hard;; *) echo soft;; esac; }
# Which SOFT breakers a false ack may SUPPRESS for the milestone: the ones that MEASURE something a
# counter can get wrong (churn, prose, a repeating gate cause, a budget). A stall (RS) or a run of
# failures (RF) is not a measurement — three invocations at one HEAD is three invocations at one HEAD
# — and suppressing it removes the only thing between a spinning loop and the spend ceiling.
# Measured on a fixture: a false-acked RS let a stub loop run to the wall cap. A false ack on RS/RF
# clears the trip it answered (since-ack) and nothing more.
breaker_suppressible(){ case "$1" in R1|R7|R8|R12|RC|RV|R13-LANDED) return 0;; *) return 1;; esac; }
ack_rows(){ ledger_rows | awk -F'\t' '$5=="ack"'; }
sig_verdict(){ ack_rows | awk -F'\t' -v s="$1" '$10==s {v=$11; c=$12} END{print v "\t" c}'; }
# Two FALSE acks on one breaker ID in one milestone downgrade that breaker to warn-only for the rest of
# it. The second ack prints the upstream line: a breaker that trips false twice is a harness defect.
breaker_downgraded(){ [ "$(ack_rows | awk -F'\t' -v b="$1:" 'index($10,b)==1 && $11=="false"' | wc -l | tr -d ' ')" -ge 2 ]; }
sig_warned(){ ledger_rows | awk -F'\t' -v s="$1" '$5=="warn" && $10==s {f=1} END{exit !f}'; }
# $1 = the reason stop_reason answered (may be empty); $2 = 1 to record a first occurrence as a `warn`
# row (`run`), 0 to only report (`next`, `status` — queries must not write). Prints the reason to STOP
# with, or nothing when the run may continue.
stop_decision(){ local reason="$1" write="${2:-0}" id sig grade verdict ackcause
  [ -n "$reason" ] || return 0
  id="${reason%%:*}"; sig="$(sig_of "$reason")"; grade="$(breaker_grade "$id")"
  IFS=$'\t' read -r verdict ackcause <<EOF
$(sig_verdict "$sig")
EOF
  # RR — the loudest stop there is: the driver said this cause was FIXED, and here it is again. The
  # ack's own words are quoted because the diagnosis they contradict is the thing to re-read.
  if [ "$verdict" = true ]; then
    printf 'RR: %s recurred after the driver acked it as fixed ("%s") — re-read that diagnosis before anything else. %s\n' "$sig" "$ackcause" "$reason"; return; fi
  [ "$grade" = hard ] && { printf '%s\n' "$reason"; return; }
  if breaker_suppressible "$id" && { [ "$verdict" = false ] || breaker_downgraded "$id"; }; then
    echo "  WARN $id suppressed for $MS by the driver's ack (\"${ackcause:-breaker downgraded}\") — ${reason#*: }" >&2; return 0; fi
  if sig_warned "$sig"; then
    printf '%s [REPEAT of signature %s — a soft breaker'"'"'s second occurrence stops the run; ack it with --verdict false to suppress it for this milestone, or true once the cause is fixed]\n' "$reason" "$sig"; return; fi
  echo "  WARN $id — first occurrence of signature $sig; the run continues, a second occurrence stops. ${reason#*: }" >&2
  [ "$write" = 1 ] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$MS" driver - warn \
    "$(git rev-parse --short HEAD 2>/dev/null||echo none)" 0 0 0 "$sig" warn "$(printf '%s' "${reason#*: }" | utf8_head 200)" >> "$LEDGER"
  return 0; }

escalate(){ { echo "TRIP: driver"; echo "milestone: $MS"; echo "reason: $1"
  echo "signature: $(sig_of "$1")"
  echo "ack: loop-driver.sh record $MS driver ack --signature last --verdict true|false --cause '<what was found>'"
  echo "ledger: $LEDGER ($(count_all) invocations: $(count_role test-author) test-author, $(count_role implementer) implementer, $(count_role reviewer) reviewer)"
  # THE SAME TWO NUMBERS `status` PRINTS, from the same two functions. This line counted reviewer
  # ROWS for both — 3 for a single 3-way fan-out against `status`'s 1, and `count_role reviewer` for
  # the milestone total — so the escalation file over-reported by the fan-out width where `status`
  # had once under-reported by it. An operator reading a stopped loop must not have to work out
  # which of two files is lying.
  echo "review rounds: $(review_rounds_since_ack) / ${REVIEW_BUDGET:-3} since the last ack (next round is $(review_round_now) in this milestone) · converged: $(review_converged && echo yes || echo no)"
  } > "$ESC"; echo "STOPPED — $1" >&2; echo "wrote $ESC" >&2; }

# ── the breaker escalation agent (TT-3176) ───────────────────────────────────
# A breaker trip used to end the run with a file on disk and nothing else. The operator came back to
# `ESCALATION.md` saying R1 or R6 and had to reconstruct, from the journal and the ledger, what had
# actually gone wrong — at the exact moment they had the least context, because the run had been
# unattended. This spawns ONE agent, at the strongest configured tier, whose only job is to read that
# wreckage and propose a recovery.
#
# ADVISORY, and enforced rather than asked for: the tool list is Read/Grep/Glob, so it cannot edit,
# cannot commit, and cannot run anything — including this driver. `--permission-mode acceptEdits` is
# deliberately dropped for the same reason. The DRIVER still decides; this only means the human is
# handed a diagnosis instead of a filename.
#
# ONE-SHOT by construction: every call site exits 3 immediately after, so there is no path on which
# this can loop. It never changes the exit code either — a stopped loop stays stopped, which is the
# "does not silently continue" half of the requirement.
ESCALATION_FLAGS="--output-format json --strict-mcp-config --mcp-config {\"mcpServers\":{}} --allowedTools Read Grep Glob"
breaker_agent(){
  local reason="$1" m out prompt t0 t1 rc
  # THE DRIVER WRITES IT ITSELF, unless asked otherwise. Seven escalation spawns in one milestone cost
  # $6.96 — 12% of that milestone — to restate what ESCALATION.md, LOOP_STATE.md and the ledger
  # already say, in a file the operator reads next to those three. An agent earns its tier when it can
  # see something the artifacts cannot; a breaker trip is not that case.
  #
  # ESCALATION_AGENT=1 restores the spawn for a loop that wants the reading rather than the digest.
  if [ "${ESCALATION_AGENT:-0}" != 1 ]; then
    echo "── circuit breaker → recovery digest (driver-written; set ESCALATION_AGENT=1 to spawn an agent) ──" >&2
    { echo "# Recovery digest — $MS"
      echo
      echo "Written by \`loop-driver.sh\` from evidence already on disk, after a circuit-breaker trip."
      echo "No agent was spawned and nothing was charged to the ledger for this file."
      echo "ADVISORY: the driver decides. Delete this file once the cause is fixed."
      echo
      echo "## What tripped"
      echo
      echo '```'
      printf '%s\n' "$reason"
      echo '```'
      echo
      echo "## The breaker's own record — $ESC"
      echo
      echo '```'
      cat "$ESC" 2>/dev/null || echo "(no $ESC written)"
      echo '```'
      echo
      echo "## The last journalled iteration — $SPEC_DIR/LOOP_STATE.md"
      echo
      echo '```'
      last_journal 2>/dev/null || echo "(none)"
      echo '```'
      echo
      echo "## The last five role invocations — $LEDGER"
      echo
      echo '```'
      { head -1 "$LEDGER" 2>/dev/null; role_rows 2>/dev/null | tail -5; } \
        | awk -F'\t' '{printf "%-22s %-4s %-12s %-7s %-6s %-9s %6s %12s %8s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9}'
      echo '```'
      echo
      echo "## Spend so far on $MS"
      echo
      printf '  $%s across %s role invocations\n' \
        "$(role_rows 2>/dev/null | awk -F'\t' '{s+=$9} END{printf "%.2f", s+0}')" \
        "$(role_rows 2>/dev/null | wc -l | tr -d ' ')"
      echo
      echo "## What clears it"
      echo
      echo "Fix the CAUSE named above, land the fix, then \`loop-driver.sh record $MS driver ack\`."
      echo "An ack states that a cause was fixed; it is not a way to buy another round. RI-ABS and the"
      echo "R13 milestone ceiling are deliberately not cleared by one."
    } > "$SPEC_DIR/RECOVERY.md"
    echo "  → wrote $SPEC_DIR/RECOVERY.md (advisory; the driver decides)" >&2
    return 0
  fi
  m="$(model_for escalation)"
  echo "── circuit breaker → escalation agent · model $m ──" >&2
  if [ "$DRY" = 1 ]; then echo "  DRY RUN — would spawn the escalation agent at $m (read-only)" >&2; return 0; fi
  command -v claude >/dev/null 2>&1 || {
    echo "  claude CLI not on PATH — no escalation agent. Read $ESC and the journal by hand." >&2; return 0; }
  prompt="$LOGDIR/escalation-$MS.prompt"; out="$LOGDIR/escalation-$MS-$(count_all).json"
  { echo "You are the ESCALATION agent for a TDD loop that has just STOPPED on a circuit breaker."
    echo "You are ADVISORY and read-only: do not edit, commit, or run anything. Propose, do not act."
    echo
    echo "Answer exactly these, briefly, in this order:"
    echo "  1. WHAT TRIPPED, in one sentence, in terms of the work rather than the rule id."
    echo "  2. THE CAUSE you believe is underneath it, and the evidence you are reading it from."
    echo "  3. THE SMALLEST RECOVERY that addresses that cause — a concrete next command or edit."
    echo "  4. WHETHER AN ACK IS APPROPRIATE, and say NO if the cause is not fixed. A breaker acked"
    echo "     without a fix is a breaker deleted."
    echo "  5. WHAT WOULD HAVE CAUGHT THIS EARLIER, if anything. One line, or 'nothing'."
    echo
    echo "STOP REASON: $reason"
    echo "MILESTONE:   $MS   (budget $(budget), iterations $(ms_iters))"
    echo
    echo "--- ESCALATION.md ---"; [ -f "$ESC" ] && cat "$ESC"
    echo
    echo "--- last journal entries ---"; tail -60 "$SPEC_DIR/LOOP_STATE.md" 2>/dev/null
    echo
    echo "--- ledger (this milestone) ---"; ledger_rows 2>/dev/null | tail -20
  } > "$prompt"
  t0=$(date +%s)
  # shellcheck disable=SC2086
  claude -p --model "$m" $ESCALATION_FLAGS < "$prompt" > "$out" 2>&1; rc=$?
  t1=$(date +%s)
  # The proposal is written where the NEXT session will look — beside the escalation it explains —
  # and printed, because an operator who is standing there should not have to go and open a file.
  if python3 - "$out" "$SPEC_DIR/RECOVERY.md" "$MS" "$m" <<'PY'
import json, sys, pathlib
try: d = json.load(open(sys.argv[1]))
except Exception: raise SystemExit(1)
text = d.get("result") or ""
if not text.strip(): raise SystemExit(1)
pathlib.Path(sys.argv[2]).write_text(
    f"# Recovery proposal — {sys.argv[3]}\n\n"
    f"Written by `loop-driver.sh` after a circuit-breaker trip, by a read-only agent on `{sys.argv[4]}`.\n"
    f"ADVISORY: the driver decides. Delete this file once the cause is fixed.\n\n{text}\n")
print(text)
PY
  then echo "  → wrote $SPEC_DIR/RECOVERY.md (advisory; the driver decides)" >&2
  else echo "  escalation agent produced no readable proposal — see $out" >&2; fi
  # Recorded like any other spend. A breaker agent entered as free is the same lie as a killed role
  # entered as free, and this one runs at the most expensive tier in the profile.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t\t\n' "$(date -u +%FT%TZ)" "$MS" escalation "$m" \
    "$([ $rc = 0 ] && echo pass || echo fail)" "$(git rev-parse --short HEAD 2>/dev/null||echo none)" \
    "$((t1-t0))" "$(usage_tokens "$out")" "$(usage_cost "$out")" >> "$LEDGER"
  return 0; }

# ── the phase machine ────────────────────────────────────────────────────────
# Deliberately simple and declared rather than inferred. Inferring "is this TDD step finished" from
# the tree is guesswork, and a driver that guesses wrong spends money confidently. So: red/green
# pairs until --steps are done, then review rounds, then STOP and hand back. It never opens the PR
# and never merges — landing stays a human decision, exactly as open-milestone-pr.sh assumes.
next_role(){
  local last done_steps last_outcome
  # Sequenced from ROLE INVOCATIONS only. The ledger also carries driver bookkeeping — an `ack` row
  # written by `record <MS> driver ack` — and mechanism tests (`smoke`), neither of which is a step
  # of the milestone. Reading the raw last row made an ack look like a role called "driver", which
  # fell through `case` to `*)` and answered `test-author` on a milestone whose next role was the
  # reviewer. The sequencer would have re-run a TDD step that was already done, and the acknowledgement
  # that exists to let the loop RESUME would have silently sent it backwards.
  last="$(sequencer_rows | tail -1 | cut -f3)"
  last_outcome="$(sequencer_rows | tail -1 | cut -f5)"
  # A STEP is done when an implementer landed a GREEN — i.e. an implementer row whose HEAD differs
  # from the one before it. Counting implementer INVOCATIONS instead counted retries, no-ops and the
  # rows a `repeat` produces: M0 carried a no-op implementer `pass` at an unchanged HEAD, which padded
  # the count to 6, so the driver believed all six steps were done, skipped the implementer after the
  # step-6 RED and routed to the reviewer — twice, the second time caught only by RU, at $4.40 a round.
  # Distinct SHAs are the honest measure: a role that committed nothing advanced no step, whatever the
  # ledger's outcome column says.
  #
  # ...and the first implementation of that idea compared an implementer row to the PREVIOUS
  # IMPLEMENTER ROW, which cannot detect the thing it was written to detect. The sha column is HEAD
  # when the invocation ENDED, so a no-op implementer inherits whatever the test-author committed
  # just before it — and in an alternating RED/GREEN loop a RED always lands in between. Consecutive
  # implementer rows therefore differ whether or not the implementer wrote a line. Measured here on
  # M1: six implementer rows, six distinct shas, two of which committed nothing; the driver read six
  # steps done, skipped steps 5 and 6 entirely and routed to the reviewer, which then cost a $3.08
  # round-1 review of a milestone that was two thirds built.
  #
  # The honest comparison is against the HEAD the implementer STARTED from — the sha on the row
  # immediately before it, whatever role wrote that row. Seeded with the milestone's fork point so
  # the first row has something real to differ from.
  done_steps="$(done_steps_count)"
  if [ -n "$STEPS" ] && [ "$done_steps" -ge "$STEPS" ]; then
    # CONVERGED, AND STILL CONVERGED AT HEAD (1.8.4). `review_converged` reads root issues.md, which
    # says what the last review found on the tree IT read; it says nothing about a tree a steered
    # spawn has since moved. `run` used to answer done on the token alone, so after `--role
    # test-author` landed a RED on a converged milestone the run printed "complete" and exited on a
    # red tree, and after `--role implementer` landed a GREEN it exited on a tree no reviewer had
    # seen (TT-4348 M7: three hours of idle driver, one relaunch per steered spawn). Converged is a
    # verdict over a HEAD: while MAIN/TEST scope has moved since the last reviewer or verifier row,
    # the loop goes on as it does inside a milestone - the RED wants its GREEN, the GREEN wants its
    # review, and review_mode prices that review - until a review has run at HEAD and the token
    # still reads converged. A steered spawn that landed nothing leaves the tree where the review
    # left it, and the milestone is complete as before.
    # A round with a dimension owed is not a round that converged (1.8.8, M11 §2.7): the render stamps
    # the owed artifact `status: open`, so review_converged is false here and the guard below spawns
    # the missing dimension before the token on the other two is read as the milestone's verdict.
    if review_converged; then
      # ...AND THE GATE AT HEAD IS NOT RED (1.8.9, TT-4348 M14 §2.1). Convergence is the verifier's
      # verdict over the findings; the gate is the tree's. A post-review implementer landed its fix
      # with a red e2e (column 14 `red`), the verifier closed every id, and `run` printed "complete"
      # over a tree open-milestone-pr.sh would refuse. A red row at HEAD asks the other writing role
      # next, with the cause, exactly as the step counter does inside the milestone.
      converged_at_head && { post_review_gate_red_owner || { echo "done"; return; }; return; }
      case "$last" in
        test-author) if [ "$last_outcome" = pass ]; then echo implementer; else echo test-author; fi;;
        implementer) if [ "$last_outcome" = pass ]; then echo reviewer; else echo implementer; fi;;
        *)           echo reviewer;;
      esac; return
    fi
    # A round that stopped mid-fan-out owes its missing dimensions first (round_missing_dims).
    [ -n "$(round_missing_dims)" ] && { echo reviewer; return; }
    # Only the driver's steers on disk (1.8.6, M9 §2.5): no round has run, whatever a steered verifier
    # row says - round 1 is owed before anything is routed, and RU stands aside for it.
    only_driver_artifacts && { echo reviewer; return; }
    # A round that did NOT converge leaves FINDINGS, and the next role is whoever OWNS them — not
    # another reviewer. Returning `reviewer` unconditionally here is the whole reason RU exists: the
    # phase machine had no arm that could route work back to a writing role once the steps were done,
    # so every post-review pass answered `reviewer`, re-reviewed an unchanged tree, and stopped on RU
    # for the driver to steer by hand. Measured on one milestone: FOUR RU trips, one of them after a
    # full $5.37 round against a tree nothing had touched since the previous one.
    #
    # Ownership comes from findings_for(), which already splits issues.md by the SAME role globs
    # check-scope.sh enforces with — so the routing answer and the breaker's answer cannot disagree.
    # Test scope first: R6 wants the RED before the GREEN, and a round whose fixes span both is two
    # commits in that order anyway.
    # Drain BOTH writing roles before paying for another round: `last = reviewer` alone sent the
    # loop back to the reviewer as soon as the test-author had committed, even with implementer-owned
    # findings still open, buying a review round in the middle of one round's fixes.
    if [ "$last" = reviewer ] || [ "$last" = verifier ] || owns_open_finding test-author || owns_open_finding implementer; then
      # OWNERSHIP *AND* PROGRESS. Ownership says whose finding it is; progress says whether that role
      # can still do anything about it. Ownership alone re-dispatches for ever, because the fixing
      # role is not allowed to close the finding it fixed (see role_can_progress).
      # ...AND NOT ALREADY TOLD "NOTHING TO DO" HERE. A role whose last row said `no_work` (or
      # `refuted`) at THIS HEAD against THESE findings is not asked again: measured, five consecutive
      # invocations each correctly reported nothing in their scope before RS noticed the tree. The
      # role's own verdict is a value now (ledger column 11, signature over its findings in 10).
      # ...NOR AT THE HEAD WHERE IT REPORTED DONE WITH A COMMIT (done_at_head, 1.8.4): the role has
      # said it finished; the review over that HEAD is what is owed, and re-asking bought a no_work
      # row per fix cycle (TT-4348 M6, five rows, $1.78).
      owns_open_finding test-author && role_can_progress test-author && ! no_work_at_head test-author && ! done_at_head test-author && { echo test-author; return; }
      owns_open_finding implementer && role_can_progress implementer && ! no_work_at_head implementer && ! done_at_head implementer && { echo implementer; return; }
      # Both writing roles are spent — either they own nothing here, or they own something and have
      # stopped committing against it. Whether the fixes worked is the REVIEWER's call, never theirs,
      # so a round that still has open findings goes back for another read rather than stalling.
      if owns_open_finding test-author || owns_open_finding implementer; then
        # ...unless the owning role has ANSWERED: a `no_work` or `refuted` at this HEAD against these
        # findings is a verdict, and a re-review of an unchanged tree cannot overrule it. That is the
        # driver's call — which is what `driver` means below.
        # ...and "unchanged tree" is the premise, so it is CHECKED. A fix cycle ends with exactly this
        # shape: the fix landed, the owner was re-asked once and answered no_work because nothing is
        # left to write, and the finding is still open because only a verifier or a round may close
        # it. Answering `driver` here stopped the run with RD three times across two milestones
        # (TT-4348 M3 once, M4 twice) while review_mode in the same tree said `verify:` or `full:` —
        # each cleared by an ack and a steered --role. A no_work verdict overrules a re-review only of
        # the tree it was given; when MAIN/TEST scope moved since the last review row, the review is
        # owed, and review_mode (not this arm) decides whether it is a verify pass or a fan-out.
        if ! tree_moved_since_last_review; then
          # ...AND A VERIFIER HAS LOOKED AT THIS HEAD (1.8.4). An unmoved tree with owners answering
          # no_work is RD's case only once the open ids have been re-proved HERE and found open. A
          # round's reviewers read a diff and close the ids inside it; a round at HEAD leaves every
          # earlier id open, unread (TT-4348 M6: round 3 converged with zero new findings, 15 earlier
          # ids open, owners no_work, RD - the `--role verifier` that cleared it closed 7 of them).
          # So while no verifier row sits at HEAD, the answer is the verifier, before RD is weighed:
          # it needs ids to close (a prose finding has none; that is RD's diagnosis) and the verify
          # mode a config predating 1.8.0 does not have. A verifier that ran at HEAD and left them
          # open makes the no_work a verdict, and RD stands (fixture 11h's terminal case).
          if { { owns_open_finding test-author && no_work_at_head test-author; } || { owns_open_finding implementer && no_work_at_head implementer; }; } \
             && [ "${REVIEW_VERIFY_MODE:-0}" = 1 ] && ! verified_at_head && [ -n "$(open_ids)" ]; then
            echo verifier; return; fi
          { owns_open_finding test-author && no_work_at_head test-author; } && { echo driver; return; }
          { owns_open_finding implementer && no_work_at_head implementer; } && { echo driver; return; }
        fi
        echo reviewer; return; fi
      # Nothing open in a writing role's scope, yet not converged: the findings are the DRIVER's own
      # (scripts/, build files, the plan) or carry no path at all. Spawning anyone would burn an
      # invocation to discover that, so say it and stop.
      # ...UNLESS THEY ARE FIXED AND WAITING FOR THE VERIFIER (1.8.6, M9 §2.4): an id whose path moved
      # after it was raised, with the gate green at HEAD, is nobody's [YOURS]; it is the review's.
      [ -n "$(fixed_awaiting_ids)" ] && { echo reviewer; return; }
      echo driver; return
    fi
    echo reviewer; return
  fi
  # A role that did not PASS is re-run, never advanced past. The implementer line below has always
  # said so; the test-author line did not, and the asymmetry was invisible until a live run ended a
  # test-author `r6` with its RED written, staged and UNCOMMITTED. The sequencer answered
  # `implementer`: the next role would have been spawned on top of a staged `test/*` file it does not
  # own, and the driver's audit — which reads `git diff --cached` as well as commits — would have
  # named the IMPLEMENTER for the test-author's work. A false R6 caused by the harness's own recovery
  # from a false R6, and the second one would have looked exactly like a real role-separation
  # violation. Advancing on a non-pass also silently drops the step: nothing re-verifies the RED that
  # never got gated.
  # THE RED, NOT THE LANDING (1.8.6, M9 §2.2): a test-author that landed a fixture fix and no RED
  # (last_landing_not_red) while no RED is pending for the step (step_red_pending) is asked again for
  # the RED; the implementer is not dispatched against nothing. With the step's RED already landed
  # (the open-step re-ask above, a steer against the RED), the fix is the implementer's turn.
  # THE GATE, NOT THE EXIT (1.8.6, M9 §2.1): an implementer that landed src/main with a red gate at
  # that HEAD (open_step_red) leaves the step open, and the RED's owner is asked first - on M9 every
  # such red was a test-side defect the gate exposed after the GREEN had landed. The step derivation
  # reads the same counter, so it is the SAME step, and the brief names the first failing test.
  case "$last" in
    ""|reviewer|verifier) echo test-author;;
    test-author)   if [ "$last_outcome" = pass ] && { ! last_landing_not_red || step_red_pending; }; then echo implementer; else echo test-author; fi;;
    implementer)   if [ "$last_outcome" = pass ] || open_step_red >/dev/null; then echo test-author; else echo implementer; fi;;
    *)             echo test-author;;
  esac; }

# Steps done = implementer rows whose HEAD differs from the row before them (whatever role wrote it),
# seeded with the fork point. Extracted from next_role so the step DERIVATION below reads the same
# number the sequencer does.
# DID ANYTHING LAND IN A ROLE'S SCOPE between two shas. "HEAD moved" stopped meaning "the role wrote
# something" the moment the driver started committing its own bookkeeping (`chore(loop): …`) between
# spawns: a no-op implementer after such a commit sat at a new sha and counted as a step; RU saw a
# changed tree and re-bought a round. The question every counter here asks is about the role's
# WRITE-SCOPE, so that is what is diffed. `any` = test-author or implementer.
landed_between(){ local a="$1" b="$2" role="$3" f
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] || return 1
  git cat-file -e "${a}^{commit}" 2>/dev/null && git cat-file -e "${b}^{commit}" 2>/dev/null || return 0
  while IFS= read -r f; do [ -z "$f" ] && continue
    case "$role" in
      any) { path_in_scope test-author "$f" || path_in_scope implementer "$f"; } 2>/dev/null && return 0;;
      *)   path_in_scope "$role" "$f" 2>/dev/null && return 0;;
    esac
  done <<EOF
$(git diff --name-only "$a" "$b" 2>/dev/null)
EOF
  return 1; }
# ...AND A STEP WHOSE GREEN IS TEST-ONLY. A RED that is green as written ("prove the invariant", a
# retag, an exhaustiveness test over code that already exists) needs no src/main change: the
# implementer answers `no_work` with a green gate and the step is done. Counting only src/main
# landings read that as "not done" and re-derived the step until RS stopped the run - TT-4348 M3
# step 8 (escaped, the re-asked test-author found a missing e2e), M5 step 4 (five re-asks, $1.61,
# two RS trips, a relaunch with `--steps N-1` to lie the counter past it). The honest reading: a
# test-author row that landed src/test, followed by an implementer row at that HEAD whose gate
# PASSED and whose verdict is `no_work`, is one step. The gate is the fence - a no_work over a red
# suite is `fail` in column 5 and does not count.
# ...AND THE GATE OVER THE ROW (1.8.6). TT-4348 M9 §2.1: a landed implementer row counted whatever
# the gate said at that HEAD - step 2's GREEN was red on one IT, step 3's on compileTestJava, step 5's
# on four ITs, step 6's on six - and the sequencer derived the next step over a red tree each time
# (four kills at $0, eight steers, 40 minutes of driver time). The verdict is read where it was
# written: column 14 when spawn_collect stamped one, else loop-iteration's journal entry for the
# implementer in the row's window. `red` leaves the step open and the red flag as it was; the
# sequencer then re-asks the RED's owner for the same step (next_role, open_step_red). No entry and no
# stamp is NO MEASUREMENT and the row counts as it always did: a hand-recorded row, a row from before
# 1.8.6 and this suite's seed rows carry no journal, and "unmeasured" is not "red". A `nostep` row
# (`record --no-step`, the driver's formatting row) is never a step.
# ...AND THE RED OVER THE LANDING (1.8.6, M9 §2.2): a test-author row sets the red flag only when its
# landing IS a RED (red_landing); a fixture fix leaves the flag where it was.
steps_scan(){ local prev n=0 row sha role out st c13 c14 g red=0 LC_ALL=C   # see byte_locale
  prev="$(git rev-parse --short "$(step_counter_seed)" 2>/dev/null)"
  while IFS= read -r row; do [ -z "$row" ] && continue
    sha="$(printf '%s\n' "$row" | cut -f6)"; [ -n "$sha" ] && [ "$sha" != none ] || continue
    role="$(printf '%s\n' "$row" | cut -f3)"; out="$(printf '%s\n' "$row" | cut -f5)"; st="$(printf '%s\n' "$row" | cut -f11)"
    c13="$(printf '%s\n' "$row" | cut -f13)"; c14="$(printf '%s\n' "$row" | cut -f14)"
    case "$role" in
      implementer)
        if [ "$c13" = nostep ]; then :
        elif landed_between "$prev" "$sha" implementer; then
          g="$c14"; [ -n "$g" ] || g="$(journal_step_gate_in_window implementer "$prev" "$sha")"
          if [ "$g" != red ]; then n=$((n+1)); red=0; fi
        # A `refuted` answer to a landed RED counts as the step exactly as `no_work` does (1.8.9,
        # TT-4348 M13 §2.1): the RED was green already, there is no src/main gap - the implementer
        # said so in either word, and the step never counted, the sequencer asked step 7 twice more,
        # and RS stopped a correct tree ($0.86, 25 minutes).
        # ...and not a `refuted` over a red step tier (pass 10, minor): a turn spent refuting a
        # steer while the RED is pending is not the step's GREEN.
        elif [ "$red" = 1 ] && [ "$out" = pass ] && [ "$st" = no_work ]; then n=$((n+1)); red=0
        elif [ "$red" = 1 ] && [ "$out" = pass ] && [ "$st" = refuted ] && [ "$c14" != red ]; then n=$((n+1)); red=0; fi;;
      test-author)
        # `nostep` leaves the flag exactly as it was: the row is a hand commit, not the step's RED
        # and not an answer to one (1.8.6 review, minor 5).
        if [ "$c13" = nostep ]; then :
        elif landed_between "$prev" "$sha" test-author; then red_landing "$prev" "$sha" "$(printf '%s\n' "$row" | cut -f12)" && red=1
        # A test-author that landed nothing (no_work/refuted) leaves the flag as it was too (1.8.9,
        # M13 §2.1): its agreement that the RED is already green is not a new landing, and clearing
        # the flag on it was the other half of the step that never counted.
        elif [ "$st" = no_work ] || [ "$st" = refuted ]; then :
        else red=0; fi;;
    esac
    prev="$sha"
  done <<EOF
$(role_rows)
EOF
  echo "$n $red"; }
done_steps_count(){ steps_scan | cut -d' ' -f1; }
# Are the milestone's steps still being built? `run` derives $STEP for a writing role exactly while
# done < STEPS (see next_step_id); a caller without --steps has no count and answers no, which is
# the full gate - the direction a missing flag is allowed to fail in (1.8.7, M10 §2.1).
build_phase(){ [ -n "${STEP:-}" ] && return 0; [ -n "${STEPS:-}" ] && [ "$(done_steps_count)" -lt "$STEPS" ]; }
# Is a RED landed and not yet answered by a counted GREEN? The flag the scan ends on.
step_red_pending(){ [ "$(steps_scan | cut -d' ' -f2)" = 1 ]; }
# The row BEFORE the last role row - the HEAD the last role started from (seeded as the counter is).
prev_role_sha(){ local p; p="$(role_rows | awk -F'\t' '{p=c; c=$6} END{print p}')"
  [ -n "$p" ] || p="$(git rev-parse --short "$(step_counter_seed)" 2>/dev/null)"; printf '%s' "$p"; }
# THE OPEN STEP (1.8.6, M9 §2.1): the last role row is an implementer that landed src/main and whose
# gate at that HEAD is red. Prints the journal's `gates:` and `cause:` lines and the row's note - the
# first failing test, for the test-author's brief - or nothing.
open_step_red(){ local row sha prev g e note
  row="$(sequencer_rows | tail -1)"; [ -n "$row" ] || return 1
  [ "$(printf '%s\n' "$row" | cut -f3)" = implementer ] || return 1
  [ "$(printf '%s\n' "$row" | cut -f13)" != nostep ] || return 1
  sha="$(printf '%s\n' "$row" | cut -f6)"; prev="$(prev_role_sha)"
  landed_between "$prev" "$sha" implementer || return 1
  e="$(journal_entry_in_window implementer "$prev" "$sha")"
  g="$(printf '%s\n' "$row" | cut -f14)"; [ -n "$g" ] || g="$(journal_step_verdict "$e")"
  [ "$g" = red ] || return 1
  printf '%s\n' "$e" | grep -E '^(gates|cause|breaker):' | sed 's/^/  /'
  note="$(printf '%s\n' "$row" | cut -f12)"; [ -n "$note" ] && printf '  implementer (%s): %s\n' "$(printf '%s\n' "$row" | cut -f11)" "$note"
  return 0; }
# The newest writing-role row at HEAD that MEASURED the tree carries a RED gate: prints the role to
# ask next - the other writing role, the RED's owner as spawn_collect announces it - or fails when
# the gate at HEAD is not known red (1.8.9, M14 §2.1). The FULL verdict (journal_verdict over the
# role's entry at its sha), because the hand-off is to open-milestone-pr.sh's full gate: the step
# verdict reads an e2e-only red as green, which is the tier M14 tripped on (1.8.9 review pass 7,
# correctness major 1). Column 14 stands in only when the role journalled nothing. A `no_work` or
# `refuted` row that measured nothing is skipped, as steps_scan skips it: the other writing role
# answering no_work at the same HEAD does not un-red the tree (pass 7, correctness major 2).
post_review_gate_red_owner(){ local row role sha e g head
  head="$(git rev-parse --short HEAD 2>/dev/null)"
  while IFS= read -r row; do [ -n "$row" ] || continue
    role="$(printf '%s\n' "$row" | cut -f3)"; sha="$(printf '%s\n' "$row" | cut -f6)"
    sha_resolves "$sha" || continue
    landed_between "$sha" "$head" any && return 1
    e="$(journal_entry_at "$role" "$sha")"
    # ...or one commit back, when the row's commit stays in the role's scope: the journal-then-commit
    # order puts the entry at the fix commit's parent (pass 10, correctness major 1; the same rule
    # journal_gate_at_head_any applies).
    [ -n "$e" ] || { commit_within_scope "$role" "$sha" 2>/dev/null && e="$(journal_entry_at "$role" "$(git rev-parse --short "$sha^" 2>/dev/null)")"; }
    if [ -n "$e" ] && printf '%s\n' "$e" | grep -q '^gates:'; then g="$(journal_verdict "$e")"
    # No journal: column 14 of a PASS row only. A `fail` row's column 14 is the lost-JSON path's own
    # measurement, and that path writes `red` for a PENDING tier too (a stack the gate cannot
    # measure) - not a verdict the hand-off may stand on (fixture 24b2 converges on such a row).
    elif [ "$(printf '%s\n' "$row" | cut -f5)" = pass ]; then g="$(printf '%s\n' "$row" | cut -f14)"
    else g=""; fi
    [ -n "$g" ] || continue
    [ "$g" = red ] || return 1
    # The other writing role, unless it is the newest writing row at HEAD and answered no_work or
    # refuted (it measured nothing and handed the turn back): then the red row's own role is re-asked,
    # as next_role alternates inside the milestone (pass 8, correctness minor: the same owner was
    # re-asked over a red it did not write until RS).
    local other newest
    case "$role" in implementer) other=test-author;; *) other=implementer;; esac
    newest="$(sequencer_rows | awk -F'\t' '$3=="test-author"||$3=="implementer"' | tail -1)"
    if [ "$(printf '%s\n' "$newest" | cut -f3)" = "$other" ]; then
      case "$(printf '%s\n' "$newest" | cut -f11)" in no_work|refuted|blocked) echo "$role"; return 0;; esac; fi
    echo "$other"; return 0
  done <<EOF
$(sequencer_rows | awk -F'\t' '$3=="test-author"||$3=="implementer"' | tail -6 | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}')
EOF
  return 1; }
# The last role row is a test-author landing that is NOT a RED (1.8.6, M9 §2.2).
last_landing_not_red(){ local row sha prev
  row="$(sequencer_rows | tail -1)"; [ -n "$row" ] || return 1
  [ "$(printf '%s\n' "$row" | cut -f3)" = test-author ] || return 1
  # ...AND A `nostep` ROW NEVER MOVES THE RED FLAG (1.8.6 review, minor 5): `record <MS> test-author
  # pass --no-step` is a hand commit in the test scope that is not the step's RED and not its answer.
  [ "$(printf '%s\n' "$row" | cut -f13)" != nostep ] || return 1
  sha="$(printf '%s\n' "$row" | cut -f6)"; prev="$(prev_role_sha)"
  landed_between "$prev" "$sha" test-author || return 1
  ! red_landing "$prev" "$sha" "$(printf '%s\n' "$row" | cut -f12)"; }
# THE STEP, DERIVED. loop.config's contract was "the step is PASSED, never derived", and the reason
# it gave was right at the time: the only counter was the implementer INVOCATION count, and one
# milestone spent seven invocations on four steps. That counter is gone — done_steps_count reads
# COMMITS — and `run` never passed --step at all, so every routine milestone silently bought the SAFE
# model for every step (measured: implementer 24/24 rows on opus in a milestone loop.config had
# priced at sonnet; LEARNINGS "a ceiling that prices a tier the driver never uses"). The (done+1)-th
# numbered item of the milestone's TDD_PLAN section is the next step; nothing numbered → empty →
# the SAFE model, the direction a miss is allowed to fail in. An explicit --step still wins.
next_step_id(){ local want; want="$(( $(done_steps_count) + 1 ))"
  plan_section "$MS" | awk -v want="$want" '
    /^[[:space:]]*[0-9]+[a-z]?[.)][[:space:]]/ {
      match($0, /^[[:space:]]*/); ind = RLENGTH
      if (first < 0 || first == "") first = ind
      if (ind != first) next
      k++; if (k == want) { s = $0; sub(/^[[:space:]]*/, "", s); match(s, /^[0-9]+[a-z]?/); print substr(s, RSTART, RLENGTH); exit } }
    BEGIN { first = -1 }'; }
# THE SIGNATURE OVER A ROLE'S FINDINGS, as the ledger's column 10 carries it (spawn_collect writes it,
# no_work_at_head compares it). The verifier's `· still open (verify N): <note>` suffix is stripped
# first: a verify pass that leaves an id open rewrites the finding's line, and with the suffix in the
# sum the owner's no_work at the same HEAD over the same ids read as "different findings", and each
# owning role was bought once more before RD (TT-4348 M6's terminal case, one paid no_work per owner).
findings_sig(){ findings_for "$1" 2>/dev/null | sed -E 's/ · still open \([^)]*\):.*$//' | cksum | cut -d' ' -f1; }
# The last same-role row since the ack said no_work/refuted, at THIS HEAD, over THESE findings.
# "At HEAD" is "nothing in MAIN/TEST scope landed since" (as done_at_head reads it), not sha
# equality: the driver's own chore(loop) commit after a verify pass moved HEAD past the no_work row,
# and the row stopped counting on the very pass RD was to stand on.
no_work_at_head(){ local row st
  row="$(role_rows_since_ack | awk -F'\t' -v r="$1" '$3==r' | tail -1)"; [ -n "$row" ] || return 1
  st="$(printf '%s\n' "$row" | cut -f11)"; case "$st" in no_work|refuted) :;; *) return 1;; esac
  landed_between "$(printf '%s\n' "$row" | cut -f6)" "$(git rev-parse --short HEAD 2>/dev/null)" any && return 1
  [ "$(printf '%s\n' "$row" | cut -f10)" = "$st:$1:$(findings_sig "$1")" ]; }
# THE OWNER'S OWN DONE HEAD (1.8.4). The role's last row since the ack said `done`, sits at THIS HEAD,
# LANDED something in its scope, and no reviewer or verifier has looked since. The finding it fixed is
# still open - only a review may close it - so the ownership arm asked the role again at the HEAD it
# had just reported done at, and it re-read the tree to answer no_work: five rows, $1.78, on TT-4348
# M6, one per fix cycle. A `done` with a commit is the role saying it finished its brief; what is owed
# next is the review over that HEAD, which review_mode prices. A `done` that committed nothing is not
# this case (role_can_progress already retires it), and a review row after the done gives the role
# its fresh turn as before.
done_at_head(){ local rows row prev
  rows="$(role_rows_since_ack | awk -F'\t' -v r="$1" '$3==r || $3=="reviewer" || $3=="verifier"')"
  row="$(printf '%s\n' "$rows" | tail -1)"; [ -n "$row" ] || return 1
  [ "$(printf '%s\n' "$row" | cut -f3)" = "$1" ] || return 1
  [ "$(printf '%s\n' "$row" | cut -f11)" = done ] || return 1
  # ...AND PASSED. Outcome (column 5) and status (column 11) are written independently: a role that
  # committed, said done and then exited non-zero is a `fail done` row, and role_can_progress owes
  # it the "previous attempt ended fail" re-brief - this retirement must not pre-empt that.
  [ "$(printf '%s\n' "$row" | cut -f5)" = pass ] || return 1
  # "At HEAD" is "nothing in THIS ROLE'S scope landed since", not sha equality: the driver's own
  # bookkeeping commit (loop artifacts before a spawn) moves HEAD past every role row, and so does
  # the OTHER writing role's fix - with `any` here the implementer's GREEN re-opened the test-author's
  # done and re-asked it against the finding it had already fixed (a paid no_work in every two-owner
  # fix cycle). The rows filter above already guarantees no review row has looked since.
  landed_between "$(printf '%s\n' "$row" | cut -f6)" "$(git rev-parse --short HEAD 2>/dev/null)" "$1" && return 1
  # ...AND ONLY FOR THE IDS WHOSE PATH EXISTS AT THAT HEAD (1.8.8, TT-4348 M11 §2.4). Test-author 35
  # fixed a coverage gap, reported `done` at HEAD, and its own e2e blocker (`s1-driver-4`) was still
  # open with NO FILE at the path it named: the retirement sent the cycle to a three-reviewer round
  # ($4.06, zero findings) and an RV count before the test-author was asked for the e2e. A blocker
  # whose path is absent is work the owner has not started, whatever its last message said, and the
  # owner is asked again at this HEAD with that finding in its brief.
  owns_unstarted_finding "$1" && return 1
  prev="$(role_rows_since_ack | awk -F'\t' -v r="$1" '$3==r{print p} {p=$6}' | tail -1)"
  landed_between "$prev" "$(printf '%s\n' "$row" | cut -f6)" "$1"; }
# One of the role's own open blocker/major findings names a path that does not exist at HEAD -
# and did not exist when the finding was raised either (1.8.8 review pass 2): a finding on a file
# that EXISTED at its raise and is absent now was satisfied by deleting it ("remove the dead
# adapter"), and re-asking its owner at that done HEAD is the paid no_work 1.8.4 removed.
owns_unstarted_finding(){ local line p id at LC_ALL=C   # see byte_locale
  while IFS= read -r line; do
    case "$line" in *'[YOURS]'*) :;; *) continue;; esac
    p="$(printf '%s' "$line" | first_finding_path)"; [ -n "$p" ] || continue
    git cat-file -e "HEAD:$p" 2>/dev/null && continue
    id="$(printf '%s' "$line" | sed -nE 's/.*- \[ \] ([rs][0-9]+-[a-z0-9-]+-[0-9]+) \[.*/\1/p')"
    at="$([ -n "$id" ] && id_raised_at "$id")"
    [ -n "$at" ] && git cat-file -e "$at:$p" 2>/dev/null && continue
    return 0
  done <<EOF
$(findings_for "$1" 2>/dev/null)
EOF
  return 1; }
# Has a VERIFIER re-proved the open ids at this HEAD? A passed verifier row at this HEAD - from the
# WHOLE ledger, as tree_moved_since_last_review and review_mode's "no second verify of an unchanged
# tree" fence read it. Since-ack hid the verifier row that made RD stand whenever the ack landed
# nothing: the loop bought one more verifier over the same ids at the same HEAD before RD again.
# The question next_role asks before it lets RD stand on an unmoved tree (1.8.4): a round's reviewers
# read a diff and close only the ids inside it, so a round at HEAD can leave earlier ids open that
# nobody has re-proved there; a verifier is the role that does, and a no_work from the owner is a
# verdict RD may act on only once that verifier has looked and left them open.
# "At HEAD" as above: the last verifier row's sha, with nothing in MAIN/TEST scope landed since.
verified_at_head(){ local v
  v="$(role_rows | awk -F'\t' '$3=="verifier" && $5=="pass"{h=$6} END{print h}')"; [ -n "$v" ] || return 1
  ! landed_between "$v" "$(git rev-parse --short HEAD 2>/dev/null)" any; }

# ── precomputed brief material ───────────────────────────────────────────────
# COST AND WALL-CLOCK SCALE WITH TURNS × CONTEXT, not with tiers and not with code written. Measured
# on one milestone: $101 across 28 invocations; one test-author 5,929s and $15.00, of which ~4,400s was
# the role's own turns and 1,224s the integration tier. Cache READS are >99% of a role's token bill —
# one implementer read 12.1M cached tokens to emit 48k of output, 250:1. Every turn re-reads the
# accumulated context, so the cheapest possible saving is a turn the role never has to take.
#
# The brief used to name TDD_PLAN.md and issues.md and let the role go and find its own material:
# open the plan, scroll to the milestone, find the step, open issues.md, work out which findings are
# in its write-scope. Four to six tool calls of DISCOVERY, charged to the role at the role's model, in
# the role's growing context, before a line of work. The driver already knows all of it and is one
# `awk` away from having it. So it is pasted in, and the pointers stay for anything not pasted.
#
# Precomputation is never a substitute for the file: every block below says which file it came from,
# so a role that needs more can still open it.
PLAN="$SPEC_DIR/TDD_PLAN.md"
PLAN_EXCERPT_MAX="${PLAN_EXCERPT_MAX:-160}"
# The block under the heading that names $1, up to the next heading of the SAME OR SHALLOWER level.
# Matched on a word boundary, so `M1` does not match `M10` and step `3c` does not match `3cd`. Prints
# nothing when the id has no heading — the caller must SAY so rather than shipping a silent empty
# section, which is exactly how a `tr` bug once shipped briefs with no role rules at all.
plan_section(){ [ -f "$PLAN" ] || return 0
  awk -v id="$1" '
    function hashes(s,  n){ n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    { l = tolower($0) }
    /^#+[[:space:]]/ {
      h = hashes($0)
      if (!inb) {
        if (l ~ ("(^|[^a-z0-9])" tolower(id) "([^a-z0-9]|$)")) { inb = 1; lvl = h; print; next }
      } else if (h <= lvl) { inb = 0 }
    }
    inb { print }
  ' "$PLAN"; }
# A TDD_PLAN §5 step id is a LIST ITEM inside its milestone's section ("  1. RED `WorkingDaysTest` …",
# "  3c. …") far more often than it is a heading. plan_section() searches HEADINGS across the whole
# file, so `--step 1` matched `## 1. Loop protocol` — the first heading in the plan containing a bare
# 1 — and pasted the loop protocol under the label "Your step: 1". A wrong section under a confident
# label is worse than no section: the role is being TOLD that is its step, and the honest
# "no heading names this step" fallback below it never got the chance to fire.
#
# Scoped to the milestone by construction, which is also the semantic truth — a step belongs to its
# milestone — so no id in one milestone can ever resolve to text in another, or to §1.
#
# AND NR > 1 ON THE HEADING ARM, because the first line `plan_section` emits is the MILESTONE'S OWN
# heading and the arm was evaluated on it. `tdd-plan-template.md` MANDATES the shape
# `### M<n> — <name> (<TICKET>-<story>)`, so for step id `2` on story `TT-92-2` the head regex matched
# the `-2)` of `(TT-92-2)`, set ind = -1, and printed to the next heading. Driven on the real spawn
# path against exactly that plan: ids `1`, `3c` and `4` resolved correctly and `2` handed the
# implementer all four steps under the label "Your step: 2", with the same text duplicated verbatim by
# the `## Milestone M1` block below it. It is the defect in this function's own header narrowed from
# the whole file to the whole milestone — a wrong section under a confident label, and the honest
# "Nothing in M1's section names step 2" fallback still never fired. The story number guarantees a
# collision for whichever step id it happens to equal, so it is not a rare shape.
step_section(){ local ms="$1" id="$2"
  plan_section "$ms" | awk -v id="$id" '
    function esc(s){ gsub(/[.[\]()*+?^$|\\{}]/, "\\\\&", s); return s }
    BEGIN { item = "^([[:space:]]*)" esc(id) "[.)][[:space:]]"
            head = "^#+[[:space:]].*(^|[^a-zA-Z0-9])" esc(id) "([^a-zA-Z0-9]|$)" }
    !inb && $0 ~ item { inb = 1; match($0, /^[[:space:]]*/); ind = RLENGTH; print; next }
    !inb && NR > 1 && $0 ~ head { inb = 1; ind = -1; print; next }
    inb {
      if ($0 ~ /^#+[[:space:]]/) exit
      if (ind >= 0 && $0 ~ /^[[:space:]]*[0-9a-zA-Z]+[.)][[:space:]]/) {
        match($0, /^[[:space:]]*/); if (RLENGTH <= ind) exit
      }
      print
    }'; }

# Does this role own an OPEN finding? Capture first, match second — `findings_for` is a while-read
# loop over issues.md and `grep -q` exits on its first match, closing the pipe under it; with
# pipefail the pipeline then reports the producer's SIGPIPE (141) instead of grep's success, so the
# answer is FALSE exactly when it should be true. Reviewed and measured on a real issues.md at rc=141
# with two open findings. The pipeline form was written INTO the same PR that documented this trap in
# harness-selfcheck.sh, one function away — which is why it is a named function now and not a pipeline
# repeated at two call sites.
# NO PIPELINE AT ALL. "Capture first, match second" was the right instinct and the wrong depth: the
# capture removed `findings_for` from the pipe and then put `printf` in it, and `grep -q` still exits
# on its first match and still SIGPIPEs whatever is upstream of it. Same bug, one process along, and
# still size-dependent — which is how it survived a review that was specifically hunting it. A shell
# `case` runs no second process and cannot be raced.
owns_open_finding(){ local out; out="$(findings_for "$1" 2>/dev/null || true)"
  case "$out" in *'[YOURS]'*) return 0;; *) return 1;; esac; }

# THE TEST-FIRST ARM. A src/main finding whose fix needs a test change first has no owner the router
# can name: the path is the implementer's, the work is the test-author's. The implementer refuses,
# correctly (R5: a committed test pins the behaviour, or the finding asks for a test of an invariant
# that already holds), answers `blocked` and names the test - and the test-author's [YOURS] list
# never carried the finding, so the run stopped on RS or RU for a human to steer `--role test-author`
# with a LOOP_CLAUDE block naming the order. Three milestones in a row (TT-4348 M3, M4, M5).
#
# True while the LAST writing-role row since the ack is an implementer `blocked` at HEAD whose note
# mentions a test or R5. findings_for then hands the implementer-scoped findings to the test-author
# as `[YOURS] (pin first)`, so the ordinary ownership arm dispatches it with no new arm in next_role:
# it commits its RED, HEAD moves, the condition clears, and the implementer is asked again against a
# test it can now satisfy. A test-author that answers no_work here is a verdict like any other
# (no_work_at_head), and the routing falls through to what it did before.
implementer_deferred_to_tests(){ local row
  row="$(role_rows_since_ack | awk -F'\t' '$3=="implementer"||$3=="test-author"' | tail -1)"; [ -n "$row" ] || return 1
  [ "$(printf '%s\n' "$row" | cut -f3)" = implementer ] || return 1
  [ "$(printf '%s\n' "$row" | cut -f11)" = blocked ] || return 1
  [ "$(printf '%s\n' "$row" | cut -f6)" = "$(git rev-parse --short HEAD 2>/dev/null)" ] || return 1
  printf '%s\n' "$row" | cut -f12 | grep -qiE 'R5|test'; }

# Can this role still make progress on the findings it owns?
#
# Ownership alone cannot answer that, and routing on ownership alone is a live defect: root
# `issues.md` is DRIVER_SCOPE and `review-results/*` is REVIEW_SCOPE, so the implementer that FIXES a
# finding may not mark it resolved. `owns_open_finding` therefore stays true across the fix, and the
# arm dispatches the same role against the same finding until it stops committing and RS trips with a
# reason ("the tree is not moving") that describes the symptom and not the cause.
#
# The missing half is who is entitled to say a finding is CLOSED. Not the role that fixed it — that is
# the author certifying their own work, which is the one thing this loop exists to prevent. It is the
# next round's cold reviewer. So the rule here is not "is it fixed" but "can this role still move":
#
#   no row since the last reviewer row   -> yes, it has not had its turn in this round
#   its last row did NOT PASS            -> yes, it never got its turn; a crash is not a decision
#   its last row COMMITTED               -> yes, it is working; it may have more to do
#   its last row committed NOTHING       -> no, it has done what it can; hand to the reviewer
#
# Each re-dispatch therefore costs a commit, and the first barren one ends it — bounded above by
# REVIEW_BUDGET. The price is one review round to confirm a fix, which is exactly what not letting the
# fixer self-certify costs, and what the loop already pays by design.
#
# THE OUTCOME COLUMN IS PART OF THE QUESTION. The first version read column 6 (sha) alone, so `fail`
# and `pass` were the same input and a role that was killed, timed out or failed its gate — which by
# definition commits nothing — was classified "spent" and retired to the reviewer on its FIRST turn of
# the round. That contradicts the rule `next_role` states above the pre-review `case`, and has always
# enforced there: "A role that did not PASS is re-run, never advanced past." It is
# not hypothetical here — `loop-driver.sh` already records the case: "two roles died to the machine
# sleeping, both honestly recorded `fail` at one HEAD". Retiring them bought a full review fan-out of
# a tree nothing had touched, which is the $5.37 defect this routing exists to remove, restored one
# indirection out. A crash is not a decision to stop.
#
# READ SINCE THE ACK, not the whole ledger. `record <MS> driver ack` is the operator saying the cause
# was diagnosed and fixed; every other reader that reasons about "has this role stopped moving" (RS,
# RU, RF, RV) was moved to the since-ack view for the reason this file states three times — "a breaker
# whose count cannot be reset is not strict, it is terminal." Reading `role_rows` here left the
# pre-ack barren row as the role's last row for ever, so the ack could not put the role back to work:
# measured as an ack plus a human fix commit still answering `reviewer`. With no ack in the ledger the
# two views are the same rows, so nothing changes for a milestone that never tripped.
#
# The pipelines below are NOT the `grep -q` hazard documented above `owns_open_finding`: `awk` and
# `tail` both read their input to EOF, so neither closes the pipe early and neither can SIGPIPE
# `role_rows_since_ack`. The trap is a consumer that exits on first match, not a pipeline as such.
role_can_progress(){ local rows n last_out last_sha prev_sha
  rows="$(role_rows_since_ack | awk -F'\t' -v r="$1" '$3==r || $3=="reviewer" || $3=="verifier"')"
  # Rows for this role since the last reviewer (or verifier — a verify pass that left findings open
  # gives the owner a fresh turn) row. None -> it has not had its turn this round.
  n="$(printf '%s\n' "$rows" | awk -F'\t' '$3=="reviewer"||$3=="verifier"{c=0;next} {c++} END{print c+0}')"
  [ "${n:-0}" -eq 0 ] && return 0
  # It ran, but did it get its turn? A non-pass row is a role that was interrupted, not one that
  # finished with nothing left to do, and the sequencer re-runs it rather than advancing past it.
  last_out="$(role_rows_since_ack | awk -F'\t' -v r="$1" '$3==r{o=$5} END{print o}')"
  [ "$last_out" = pass ] || return 0
  # It ran and passed. Did its LAST run commit? Same sha comparison done_steps uses: the row before it
  # is the HEAD it started from, whatever role wrote that row.
  last_sha="$(role_rows_since_ack | awk -F'\t' -v r="$1" '$3==r{h=$6} END{print h}')"
  prev_sha="$(role_rows_since_ack | awk -F'\t' -v r="$1" '$3==r{print p} {p=$6}' | tail -1)"
  [ -n "$last_sha" ] || return 0
  landed_between "$prev_sha" "$last_sha" "$1"; }

# Open blocker/major lines from issues.md, split by whether the path they name is in THIS role's
# write-scope. The gate remains the authority on convergence — this is orientation, not a verdict, and
# says so in the brief. Re-implementing review_scan here would give the harness two readers of one
# rule, which is the defect open-milestone-pr.sh already paid for.
first_finding_path(){ grep -oE '(^|[^A-Za-z0-9_./-])[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' | head -1 \
  | sed -E 's/^[^A-Za-z0-9_./-]//'; }
# ...AND AT MOST BRIEF_FINDINGS_CAP OF THEM ARE `[YOURS]` IN ONE BRIEF (1.8.4). A brief carrying seven
# findings overran the 10 M token budget twice on TT-4348 M7 and the implementer landed a subset each
# time (two of nine, then five of seven, R13). The rest of the role's findings are counted, not
# listed: they stay open in issues.md, the router keeps routing on them, and after the review at HEAD
# has closed the landed ones the next invocation of the role gets the next four. Issues.md order,
# earlier rounds first. 0 = no cap.
# ── fixed, awaiting the verifier (harness 1.8.6) ─────────────────────────────
# TT-4348 M9 §2.4: `BRIEF_FINDINGS_CAP=4` listed `s1-driver-1..4`, every one fixed and gate-proven but
# open because no verifier had run, and held `s1-driver-5/6` back - the two ids that kept the step 5
# gate red never reached the step 6 test-author. 14 of M9's 22 closures were then made by hand with
# commit and gate evidence. An id whose OWN LINES were touched by a commit AFTER the commit that first
# carried the id in review-results/ (`git log -S` on the id's line, so a steer counts from the driver's
# chore(loop) commit and a reviewer finding from the round's render), or whose id a commit message
# names, while the milestone's newest journal entry is green and nothing in MAIN/TEST scope landed
# after it, is fixed as far as the driver can tell. Per FINDING, never per file (see
# id_fixed_after_raise): findings cluster in one file, and a per-file rule retires the four in
# Foo.java that nobody fixed along with the one that was.
# It is not `[YOURS]` and not counted against the cap: the brief lists it once under
# `FIXED, AWAITING VERIFIER:`, the router does not own it, and the verifier - whose list is
# `review_findings.py open --all`, unchanged - closes it by id with evidence, as only a review may.
# ...IN THIS MILESTONE'S ARTIFACTS ONLY (1.8.8, found driving TT-4348 M12 on it). Ids recur per
# milestone - every round 1 has an `r1-correctness-1`, every steered milestone an `s1-driver-1` - and
# review-results/ keeps every milestone's artifacts, so the unscoped search answered the FIRST
# milestone that ever raised the id (M12's `s1-driver-1` resolved to M9's commit, 2026-09-14), and the
# evidence range `at..HEAD` then spanned six milestones of commits, any of which touching the hunk or
# naming the id in its message would have classed a fresh finding as fixed. The artifact name carries
# the milestone (`_<ms>_`, review_artifact_path), so the pathspec does too.
id_raised_at(){ local ml; ml="$(printf '%s' "$MS" | tr 'A-Z' 'a-z')"
  git log --format=%h --reverse -S"] $1 [" -- "review-results/*_${ml}_*" 2>/dev/null | head -1; }
# THE EVIDENCE IS PER FINDING, NOT PER FILE (1.8.6 review, major 4). The first cut asked only whether
# ANY commit after the id was raised had touched the path - and findings cluster in one file: an
# implementer that fixes two of four findings in Foo.java and lands green would have had all four
# (and every held-back id on that file) classed fixed, dropped from both roles' [YOURS] lists, and
# next_role would have answered `reviewer` on every pass until the round budget ran out. So a commit
# is evidence for THIS id only when its diff touches the hunk the finding names, or when its message
# names the id. A finding with no line number cannot be told either way and stays [YOURS]: the safe
# direction is the behaviour of every version before this one.
# The slack is the distance a fix may move from the line a reviewer quoted (a guard clause inserted
# above it, a renamed variable a line down). Five lines, deliberately small: too wide and this is the
# per-file rule again.
FINDING_HUNK_SLACK="${FINDING_HUNK_SLACK:-5}"
# ...EXCEPT THE STEER RAISED BEFORE ITS PATH EXISTED (1.8.8, TT-4348 M11 §2.2). A pre-spawn steer
# names the file the step is about to create (`PublicationService.java`, no line: there is no line
# yet), and the rule above can never see a commit touch a hunk of a file that had no hunks when the
# id was raised. M11's `s1-driver-1` was satisfied at step 1 and re-verified by nineteen roles over
# four hours (~$2) until a verifier closed it. So a line-less id whose path was ABSENT at the commit
# that raised it and is PRESENT at HEAD is fixed as far as the driver can tell: the file the steer
# asked for exists, and the gate is green there (the caller checks that first). A line-less finding
# on a file that already existed stays its owner's, as before.
id_fixed_after_raise(){ local id="$1" p="$2" ln="$3" at c
  at="$(id_raised_at "$id")"; [ -n "$at" ] || return 1
  if [ -z "$ln" ]; then
    git cat-file -e "$at:$p" 2>/dev/null && return 1
    git cat-file -e "HEAD:$p" 2>/dev/null && return 0
    return 1
  fi
  git log --format=%h "$at..HEAD" --grep="$id" 2>/dev/null | grep -q . && return 0
  for c in $(git log --format=%h "$at..HEAD" -- "$p" 2>/dev/null); do
    # -U0 so the hunk ranges are the CHANGED lines, not their context; `git show --format=` for a
    # commit whose parent may not exist. Both sides are compared: the finding names a line as the
    # file was when it was raised, and a later commit may have moved it.
    git show -U0 --format= "$c" -- "$p" 2>/dev/null | awk -v ln="$ln" -v sl="$FINDING_HUNK_SLACK" '
      /^@@/ {
        # @@ -<os>[,<oc>] +<ns>[,<nc>] @@
        os = $2; ns = $3; sub(/^-/, "", os); sub(/^\+/, "", ns)
        oc = 1; nc = 1
        if (index(os, ",")) { oc = substr(os, index(os, ",") + 1); os = substr(os, 1, index(os, ",") - 1) }
        if (index(ns, ",")) { nc = substr(ns, index(ns, ",") + 1); ns = substr(ns, 1, index(ns, ",") - 1) }
        if ((ln >= os - sl && ln <= os + oc + sl) || (ln >= ns - sl && ln <= ns + nc + sl)) { found = 1; exit }
      }
      END { exit !found }' && return 0
  done
  return 1; }
# Every open id (blocker/major, from the rendered artifacts) that is fixed and awaiting the verifier.
# MEMOISED, because this is history scanning and every caller calls it through findings_for (1.8.6
# review, minor 7): `owns_open_finding` asks for both writing roles, `findings_sig` asks again, and
# `next_role` does all of that several times in one pass - twenty open findings were well over a
# hundred `git log` scans per pass. The cache is a FILE, not a variable: findings_for is called in
# command substitution, so a variable set inside it dies with the subshell. The key is everything the
# answer depends on - HEAD, the consolidated findings and the ledger's size - so it invalidates
# itself the moment a commit, a consolidation or a row lands.
fixed_awaiting_ids(){ local key f
  key="$(git rev-parse --short HEAD 2>/dev/null || echo none)-$( (cksum < issues.md 2>/dev/null || echo 0) | cut -d' ' -f1)-$(wc -c < "$LEDGER" 2>/dev/null | tr -d ' ')"
  f="$LOGDIR/fixed-awaiting-$MS-$key"
  [ -f "$f" ] && { cat "$f"; return 0; }
  _fixed_awaiting_ids > "$f.$$" 2>/dev/null && mv "$f.$$" "$f" 2>/dev/null
  cat "$f" 2>/dev/null; return 0; }
_fixed_awaiting_ids(){ local id f line p ln
  [ "$(journal_gate_at_head_any)" = green ] || return 0
  while IFS=$'\t' read -r id f line; do
    [ -n "$id" ] && [ -n "$line" ] || continue
    p="$(printf '%s' "$line" | first_finding_path)"; [ -n "$p" ] || continue
    # The line the finding names, read straight after its own path (`<path>:<line>`), the shape the
    # rendered artifact dictates. No line - a prose finding, a path with no position - is not
    # evidence of anything and the id stays its owner's, unless the path did not exist when the id
    # was raised and does now (id_fixed_after_raise, 1.8.8).
    ln="$(printf '%s' "$line" | awk -v p="$p" '{ i = index($0, p ":"); if (i) { s = substr($0, i + length(p) + 1); if (match(s, /^[0-9]+/)) print substr(s, 1, RLENGTH) } }')"
    id_fixed_after_raise "$id" "$p" "$ln" && printf '%s\n' "$id"
  done <<EOF
$(open_findings)
EOF
  return 0; }
# Every open blocker/major has an id AND is fixed, awaiting the verifier (1.8.8): what RV stands
# aside for. A prose finding (no id) cannot be told fixed, so it keeps RV armed; no open finding at
# all is "converged", which is not this question.
all_open_fixed_awaiting(){ local ids fixed id
  ids="$(open_findings)"; [ -n "$ids" ] || return 1
  printf '%s\n' "$ids" | awk -F'\t' '$1==""{f=1} END{exit f}' || return 1
  fixed=" $(fixed_awaiting_ids | tr '\n' ' ')"
  for id in $(printf '%s\n' "$ids" | cut -f1 | sort -u); do case "$fixed" in *" $id "*) :;; *) return 1;; esac; done
  return 0; }
findings_for(){ local role="$1" line p own n=0 pin=0 yours=0 held=0 cap id fixed="" fixed_out="" LC_ALL=C   # see byte_locale
  [ -f issues.md ] || return 0
  [ "$role" = test-author ] && implementer_deferred_to_tests && pin=1
  cap="${BRIEF_FINDINGS_CAP:-4}"
  fixed=" $(fixed_awaiting_ids | tr '\n' ' ')"
  while IFS= read -r line; do
    case "$line" in *'- [x]'*|*'- [X]'*) continue;; esac
    n=$(( n + 1 )); [ "$n" -gt 40 ] && { echo "  … more in issues.md (truncated at 40)"; break; }
    id="$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*- \[ \] ([rs][0-9]+-[a-z0-9-]+-[0-9]+) \[.*/\1/p')"
    # Fixed and awaiting the verifier (1.8.6): listed once below, never [YOURS], never against the cap.
    if [ -n "$id" ]; then case "$fixed" in *" $id "*) fixed_out="$fixed_out $id"; continue;; esac; fi
    # THE FIRST PATH ON THE LINE, NOT THE LAST. The greedy `.*` before the capture matched the LAST
    # dir/file.ext on the line, and since 1.8.0 a finding's line also carries the verifier's evidence
    # (`still open (verify 1): git -C $REVIEW_WT diff ... $REVIEW_WT/src/main/...`) — so an open
    # major at src/main/.../PofeLookup.java resolved to `REVIEW_WT/src/main/...`, no role's scope, and
    # the sequencer skipped the implementer that owned it and bought a full review round on a tree
    # that did not compile (TT-4348 M3, round 2, killed at $0). The dictated artifact puts the path
    # first (`- [ ] <id> [<sev>] <path>:<line> — ...`); the first match is the finding's own path.
    p="$(printf '%s' "$line" | first_finding_path)"
    # `[?]` IS A DEFECT REPORT, NOT A LABEL. Ownership is resolved by matching a dir/file.ext
    # pattern on the finding's own line, so a reviewer that names CLASSES instead of paths produces
    # a finding no role will ever claim — and nothing escalated that. Measured (TT-4348 M2): one
    # round's conformance and crossartifact dimensions wrote `build.gradle / XlsConverter` and
    # `WorkbookFacts, BannerCells, manifest.json`; six findings scored `[?]`, and five consecutive
    # invocations across both writing roles each correctly reported "nothing in my scope" before RS
    # finally tripped on the stalled tree. Every role was right; the routing could not express the
    # work, and from outside an unroutable finding is indistinguishable from a stuck loop.
    if [ -z "$p" ]; then
      printf '  [?] UNROUTABLE — names no dir/file.ext, so no role owns it. If it is yours, say so\n'
      printf '      in your note and fix it; if not, the DRIVER must add the owning path to the\n'
      printf '      finding in its artifact. Do NOT silently skip it: %s\n' "$line"
    elif path_in_scope "$role" "$p" 2>/dev/null; then
      yours=$(( yours + 1 )); if [ "$cap" -gt 0 ] && [ "$yours" -gt "$cap" ]; then held=$(( held + 1 )); continue; fi
      printf '  [YOURS] %s\n' "$line"
    elif [ "$pin" = 1 ] && path_in_scope implementer "$p" 2>/dev/null; then
      yours=$(( yours + 1 )); if [ "$cap" -gt 0 ] && [ "$yours" -gt "$cap" ]; then held=$(( held + 1 )); continue; fi
      printf '  [YOURS] (pin first: the implementer answered `blocked` on a missing or contradicting test - write the RED that pins the finding, nothing under src/main) %s\n' "$line"
    else own="$(owning_roles "$p" 2>/dev/null)"; printf '  [owner: %s] %s\n' "${own:-unscoped}" "$line"; fi
  done <<EOF
$(grep -E '\[(blocker|major)\]|^[[:space:]]*[#>*_-]*[[:space:]]*(blocker|major)[[:space:]]*:' issues.md 2>/dev/null | grep -viE '(blocker|major)[[:space:]]*:[[:space:]]*(none|0)([^0-9]|$)' || true)
EOF
  [ "$held" -gt 0 ] && printf '  HELD BACK: %s more finding(s) in your scope are NOT in this brief (BRIEF_FINDINGS_CAP=%s). Land the %s above and stop; they stay open in issues.md and your next invocation, after the review at HEAD, gets them. Do not go looking for them.\n' "$held" "$cap" "$cap"
  [ -n "$fixed_out" ] && printf '  FIXED, AWAITING VERIFIER:%s - a commit after each id was raised touched the lines it names (or named its id), or its path, absent when it was raised, now exists, and the gate is green at HEAD; the verifier closes them by id, not you. Do not re-work them.\n' "$fixed_out"
  return 0; }
# One `## SECTION` of ROLE_PROMPTS.md, up to (but not including) the next one.
#
# The old form was `sed -n '/^## X/,/^## [A-Z]/p' | sed '$d'`, and `$d` deletes the last line
# UNCONDITIONALLY — correct only when a next heading was actually found. For the LAST section in the
# file, which is the reviewer's, the range runs to end-of-file and `$d` ate its closing ``` fence: every
# reviewer brief carried an unterminated code block, and the "When you are done" instructions —
# including the run-it-in-the-FOREGROUND rule that exists because a role once abandoned its gate — were
# swallowed into it. Found by reading a brief this driver actually produced, not by reading the code.
# awk stops BEFORE the next heading rather than consuming it and deleting it again: the same answer at
# a section boundary, the right one at end-of-file.
section_of(){ awk -v h="$1" 'index($0,h)==1 && !f { f=1; print; next } f && /^## [A-Z]/ { exit } f { print }' "$HERE/ROLE_PROMPTS.md"; }

# What a reviewer is asked to look at. Round ≥2 re-reading the WHOLE milestone diff is how 4 of 6
# reviewer invocations in one milestone — $22.99 of $101 — were spent re-reviewing work that had not
# changed, and re-reviewing `scripts/` on top of it. The base is the HEAD recorded on the last reviewer
# row of this milestone's ledger, so it is the driver's own evidence and not a filename convention;
# with no such row it is the fork point, i.e. the whole milestone, which is correct for round 1.
#
# THE BASE IS THE ROUND'S, NOT THE ROW'S. A reviewer commits nothing, so the sha on a reviewer row IS
# HEAD — and a fan-out appends one such row per dimension inside a single round. Reading "the last
# reviewer row" therefore handed dimension 2 the row dimension 1 had just written, at the same HEAD,
# i.e. `git diff <HEAD>..HEAD`: an EMPTY diff, at the full reviewer tier, charged to the round.
# Reproduced on a real --yes drive of the shipped three dimensions: dimension 1 got the fork point,
# dimensions 2 and 3 got `9b822d6..HEAD` where 9b822d6 was HEAD. The fan-out cost 3x and reviewed once.
#
# So: the last reviewer row THAT IS NOT AT HEAD. One rule, and it is the definition rather than a
# repair of one — "the tree as a reviewer last saw it" cannot be the tree in front of this reviewer.
# It is what makes the fan-out coherent: dimensions 2..N skip the rows their own round just wrote (a
# reviewer commits nothing, so those rows are AT HEAD by construction) and land on the same base
# dimension 1 got, whatever order or number of dimensions ran. It is also the same rejection
# `fork_point()` already makes one level down and for the reason stated there — "a review scope
# narrowed to nothing is the silent failure, and a window too wide is merely expensive".
#
# Deliberately NOT counted (`drop the last rows/width rows`) and deliberately not cached for the
# duration of one `run`. Counting assumes every round contributed exactly N rows, which an aborted
# round breaks; a cache is empty whenever the round is spread over more than one driver invocation
# (`--role reviewer`, a round resumed after a kill). With REVIEW_DIMENSIONS empty this is the old
# behaviour in every case where the old behaviour produced a non-empty window.
# REVIEWER rows only, deliberately: a verify pass (1.8.0) re-proves findings, it does not read the
# diff, so the next FULL round still reads from the last full round. verify_base() is the other one.
# A ROUND BEING RESUMED reads from the base its finished dimensions read from (1.8.9, TT-4348 M14
# §2.3): the rows of one fan-out share a sha, and with that sha as the anchor the re-run of the owed
# dimension reviewed the consolidation commits after it - 100 lines of loop artifacts, "converged"
# on nothing. The last round's rows are skipped while any of its dimensions is still owed.
review_base(){ local skip=""
  [ -n "$(round_missing_dims)" ] && skip="$(current_round_shas)"
  last_review_row_not_at_head " reviewer " "$skip" || fork_point; }

# The milestone's fork point. `git merge-base HEAD "$BASE_BRANCH"` alone reads the LOCAL branch of
# that name, and a local base branch is routinely stale: in the clone this was found in, local `dev`
# sat 52 commits behind `origin/dev`, so the merge-base landed on a months-old ancestor. Everything
# downstream inherits that — the reviewer's round-1 scope, the brief's "commits since base", and R8's
# churn window — which is precisely the "spent re-reviewing work that had not changed" failure the
# comment above exists to prevent, except silently and at full milestone scale.
#
# The step counter's seed, and NOTHING else. Deliberately not fork_point(), and deliberately no
# longer named `milestone_base` — it does not return the milestone's base and never did. It returns
# the merge-base with the base branch (the BRANCH's fork, shared by every milestone on that branch),
# and on a repo with no distinct base it returns HEAD. A name that claims more than that invites the
# next reader to use it as a milestone boundary, which it cannot be.
#
# What it returns is sufficient because of what the seed is FOR. `next_role` walks the ledger
# comparing each implementer row's sha to the row before it, and the seed is only ever compared
# against the FIRST row — so it has to be a sha no first row can equal, not a meaningful base.
# Anything at or before the milestone's first commit satisfies that.
#
# It is a separate function from fork_point() because the two want opposite things from one
# merge-base. A review window of zero commits is useless, so fork_point() rejects a candidate whose
# merge-base IS HEAD; the seed has no such problem and that rejection actively hurt it. Making the
# seed share it dropped the seed to the ROOT commit, where the first implementer row matched it and
# went uncounted — measured as done_steps 1 against a ledger holding two distinct-sha implementer
# rows, which routes a finished milestone back to the test-author. A fixture caught it; inspection
# did not.
#
# ONE PIECE OF fork_point's REJECTION IS SHARED, AND ONLY ONE: a merge-base equal to HEAD. Everything
# above says the seed needs "a sha no first row can equal" — and `git merge-base HEAD main` IS HEAD
# when the branch is `main`, which is the degenerate "loop running ON its own base branch" the
# neighbouring comment already calls out and BASE_BRANCH defaults to. The seed then equals the sha on
# the first row, that row goes uncounted, and done_steps under-counts by one. Reproduced on a fresh
# install on `main` with one commit and one implementer row at it: done_steps 0 against one
# distinct-sha implementer row, so `next` answered test-author and the milestone was never seen as
# complete — one wasted invocation per occurrence. The rest of fork_point's chain stays out: sharing
# the WHOLE of it is what dropped this seed to the root commit before, and the root commit is the
# fallback this function still wants when no candidate survives.
step_counter_seed(){ local mb hd
  hd="$(git rev-parse HEAD 2>/dev/null)" || hd=""
  mb="$(git merge-base HEAD "origin/${BASE_BRANCH:-main}" 2>/dev/null)" || mb=""
  [ -n "$mb" ] && [ "$mb" != "$hd" ] && { printf '%s' "$mb"; return; }
  mb="$(git merge-base HEAD "${BASE_BRANCH:-main}" 2>/dev/null)" || mb=""
  [ -n "$mb" ] && [ "$mb" != "$hd" ] && { printf '%s' "$mb"; return; }
  printf '%s' "$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)"; }

fork_point(){ local best="" mb ref up
  # NOT the branch's own tracking ref. `open-milestone-pr.sh` runs `git push -u origin "$BRANCH"`, so
  # from the first PR onward `@{upstream}` IS this branch's own remote head — and `merge-base HEAD
  # origin/<self>` is HEAD, i.e. a window of ZERO. With one loop branch reused across milestones
  # (milestone-start.sh), every later milestone's round-1 reviewer would receive an empty diff and R8
  # would measure churn against nothing.
  #
  # The comment this replaces claimed "adding a candidate can only ever narrow the window, never widen
  # it" AS A SAFETY PROPERTY. That has the direction backwards: a review scope narrowed to nothing is
  # the silent failure, and a window too wide is merely expensive. Candidates that collapse the window
  # to HEAD are rejected below for that reason.
  up="$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  case "$up" in */"$(git rev-parse --abbrev-ref HEAD 2>/dev/null)") up="";; esac
  for ref in "$up" "origin/${BASE_BRANCH:-main}" "${BASE_BRANCH:-main}"; do
    [ -n "$ref" ] || continue
    git rev-parse --verify -q "$ref" >/dev/null 2>&1 || continue
    mb="$(git merge-base HEAD "$ref" 2>/dev/null)" || continue
    [ -n "$mb" ] || continue
    # A candidate whose merge-base IS HEAD contributes a zero-length window — an empty review scope
    # and an empty churn window, both of which read as "nothing to look at" rather than as an error.
    [ "$mb" = "$(git rev-parse HEAD 2>/dev/null)" ] && continue
    if [ -z "$best" ] || git merge-base --is-ancestor "$best" "$mb" 2>/dev/null; then best="$mb"; fi
  done
  [ -n "$best" ] && { printf '%s' "$best"; return; }
  # NO CANDIDATE SURVIVED — every ref either does not exist or collapses the window to HEAD. That is
  # the loop running ON its own base branch, or a repo with no remote and no distinct base.
  #
  # The root commit is the wrong answer here, and was the shipped one: the round-1 reviewer is handed
  # the ENTIRE history as its diff, and R8 measures churn from the first commit, so the breaker that
  # exists to catch an oversized change trips on every change. Rejecting the zero-length window above
  # made this path reachable for the first time — which is how a fix for an empty review scope
  # produced an unbounded one, overshooting in the other direction.
  #
  # So: bounded. REVIEW_FALLBACK_COMMITS back from HEAD when that many exist, the root commit when
  # they do not. Wrong either way — there is no correct base to find on a branch with no base — but
  # wrong by a declared amount, which a reviewer can read and a churn budget can survive.
  local n fb; n="${REVIEW_FALLBACK_COMMITS:-200}"
  fb="$(git rev-parse --verify -q "HEAD~$n" 2>/dev/null || true)"
  [ -n "$fb" ] || fb="$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)"
  printf '%s' "$fb"; }

# ── the working set: what the tree looks like, precomputed ────────────────────
# The brief already carries the plan text and the open findings. What it did NOT carry is the state
# of the tree the role is about to change, so every spawn opened with the same four to six discovery
# calls — `git status`, `git log`, `git diff --stat`, `git diff`, often an `ls` — at the role's own
# model, in the role's growing context, before any work. Measured across one milestone: 2.3M tokens
# per invocation against ~1,500 lines of product; cache reads are >99% of a role's bill, and every
# turn re-reads everything before it. The driver is one `git` call away from all of it.
#
# The base is the LAST JOURNALLED ITERATION's sha — the same definition R8 charges churn from
# (loop-iteration.sh: prev_sha when it is an ancestor of HEAD, else HEAD). One definition, so the
# brief's "since" and the breaker's "since" cannot drift into two different claims.
BRIEF_DIFF_MAX="${BRIEF_DIFF_MAX:-400}"
work_base(){ local prev
  prev="$(grep -E '^## .*(  iter |  verify )' "$SPEC_DIR/LOOP_STATE.md" 2>/dev/null \
          | grep -E "  $MS  " | tail -1 | sed -n 's/.*@\([0-9a-f]\{4,\}\).*/\1/p')"
  if [ -n "$prev" ] && git cat-file -e "${prev}^{commit}" 2>/dev/null \
     && git merge-base --is-ancestor "$prev" HEAD 2>/dev/null; then printf '%s' "$prev"; return; fi
  # Short-form, like the journalled sha above: the brief prints this, and one line carrying a 40-char
  # sha where the next carries a 7-char one reads as two different kinds of thing.
  git rev-parse --short "$(review_base)" 2>/dev/null || review_base; }

# Pasted, not commanded: a `git diff` the role is TOLD to run is still a turn it pays for. Small
# diffs go in whole because a patch under the cap is cheaper pasted than fetched; a large one degrades
# to its stat plus the command, since a brief that swallows a 4,000-line patch has moved the cost
# rather than removed it.
tree_summary(){ local base="$1" n
  echo "HEAD:  $(git log -1 --format='%h %s' 2>/dev/null || echo none)"
  echo "Base:  $base   (the last journalled iteration for $MS, or the milestone fork point)"
  echo
  echo "Commits since base:"
  git log --oneline "$base"..HEAD 2>/dev/null | sed 's/^/  /' | head -30
  [ -n "$(git log --oneline "$base"..HEAD 2>/dev/null)" ] || echo "  (none — HEAD is the base)"
  echo
  echo "Files changed since base:"
  git diff --stat "$base"..HEAD 2>/dev/null | sed 's/^/  /' | head -40
  [ -n "$(git diff --stat "$base"..HEAD 2>/dev/null)" ] || echo "  (none)"
  echo
  echo "Uncommitted right now:"
  if [ -n "$(git status --short 2>/dev/null)" ]; then git status --short 2>/dev/null | sed 's/^/  /' | head -30
  else echo "  (clean)"; fi
  n="$(git diff "$base"..HEAD 2>/dev/null | wc -l | tr -d ' ')"
  echo
  if [ "${n:-0}" -eq 0 ]; then echo "No committed diff since the base."
  elif [ "${n:-0}" -le "$BRIEF_DIFF_MAX" ]; then
    echo "The diff itself ($n lines):"; echo; git diff "$base"..HEAD 2>/dev/null
  else
    echo "The diff is $n lines, over BRIEF_DIFF_MAX=$BRIEF_DIFF_MAX — read what you need with"
    echo "\`git diff $base..HEAD -- <path>\` rather than opening the whole tree."
  fi; }

# The last journal entry for this milestone: tests, churn, gate tiers, breaker, note. The role after a
# gate had to re-run it or go and find LOOP_STATE.md to learn what the gate said — and a role that
# re-runs a gate to read it has paid for the same measurement twice.
#
# The LAST entry, not the first: each matching header replaces the buffer, so what survives to END is
# the most recent one. (The first version exited at the second header and shipped the OLDEST entry —
# a stale gate reads exactly like a current one, which is worse than pasting nothing.)
# The signature of this milestone's last journal entry whose breaker is not OK (1.8.9; the ack's
# `--signature last` when no ESCALATION.md was written).
journal_last_trip_sig(){ [ -f "$SPEC_DIR/LOOP_STATE.md" ] || return 0
  awk -v ms="  $MS  " '/^## / { inms = index($0, ms) > 0; if (inms) { sig = ""; brk = "" } next }
    inms && index($0, "signature: ") == 1 { sig = substr($0, 12) }
    inms && index($0, "breaker: ") == 1 { brk = substr($0, 10) }
    inms && index($0, "note:") == 1 { if (brk != "" && brk !~ /^OK/ && brk !~ /^R[A-Z0-9-]* \(warn/ && brk !~ /\(suppressed/) {
        # An RC entry keeps the GATE signature so the cause streak survives the trip; the ack wants
        # the RC one loop-iteration.sh printed (pass 11, major 2).
        if (brk ~ /^RC/) sub(/^[^:]*:/, "RC:", sig); last = sig } }
    END { print last }' "$SPEC_DIR/LOOP_STATE.md" 2>/dev/null; }
last_journal(){ [ -f "$SPEC_DIR/LOOP_STATE.md" ] || return 0
  awk -v ms="  $MS  " '
    /^## / { if (index($0, ms)) { keep = 1; buf = $0 } else { keep = 0 }; next }
    keep { buf = buf "\n" $0 }
    END { if (buf != "") print buf }
  ' "$SPEC_DIR/LOOP_STATE.md" 2>/dev/null | tail -20; }

# ── spawning ─────────────────────────────────────────────────────────────────
# The role brief is assembled to a FILE and the file is what gets passed, so every invocation is
# auditable after the fact — an agent prompt built inline in a pipeline is unreviewable.
# The paths the LOOP writes that no role commits: the consolidated summary, the reviewers' artifacts
# (a reviewer commits nothing, by principle) and the spec dir's journal, ledger and escalation files.
# These are what the driver commits before spawning; anything else dirty in DRIVER_SCOPE (scripts/,
# build files, the plan) is a human's unfinished edit and is never swept into a commit by a script.
# `review-results/*.prose.md` by name (1.8.4): the prose a reviewer wrote at the dictated path, kept
# beside the rendered artifact by review_findings.py. The template's REVIEW_SCOPE (`review-results/*`)
# covers it; a config that narrows the scope to `*_issues.md` would leave the prose untracked, and the
# next spawn would refuse on "dirty outside the role's scope" for a file the driver itself renamed.
loop_artifact(){ case "$1" in issues.md|"$SPEC_DIR"/ISSUES.md|"$SPEC_DIR"/LOOP_CLAUDE.md|review-results/*.prose.md) return 0;; esac; path_in_scope reviewer "$1" 2>/dev/null; }
# The harness's own journals: check-scope.sh never blames a role for them, and the driver never sweeps
# them into a commit before a spawn either — they are committed at checkpoints, as they always were.
harness_journal(){ case "$1" in "$SPEC_DIR"/LOOP_STATE.md|"$SPEC_DIR"/ESCALATION.md|"$SPEC_DIR"/LOOP_LEDGER.tsv|"$SPEC_DIR"/RECOVERY.md|"$SPEC_DIR"/archive/*) return 0;; *) return 1;; esac; }
# `--untracked-files=all`, or an untracked DIRECTORY collapses to `specs/` and matches nothing: the
# driver's own brand-new ledger then refused the first spawn of every fresh milestone.
dirty_paths(){ git status --porcelain --untracked-files=all 2>/dev/null | sed -E 's/^.{3}//; s/.* -> //' | grep -v '^$' || true; }
# `chore(loop): …` — the driver's own bookkeeping, committed by the driver, so it is never audited
# against the role that runs next. DRIVER_AUTOCOMMIT=0 turns this into a refusal at spawn instead.
# ...AND SAYS WHEN THE COMMIT WAS REFUSED (1.8.4). The commit runs under the repository's own hooks,
# and a hook that rejects it (gitleaks on a review phrase that reads as an API key, a signing rule)
# used to fail into `>/dev/null 2>&1`: the artifacts stayed dirty, the next spawn refused on "changes
# outside the role's scope", and the operator was told to clean a tree the driver had just failed to
# commit, with no word of why (TT-4348 M7: gitleaks' generic-api-key rule on `IdempotencyKey,
# CollectionTransitions` in a rendered artifact; the fix was a `.gitleaks.toml` allowlist, found by
# committing by hand). The hook's last lines are kept in LOOP_COMMIT_REFUSAL for the refusal to print.
LOOP_COMMIT_REFUSAL=""
commit_loop_artifacts(){ LOOP_COMMIT_REFUSAL=""; [ "${DRIVER_AUTOCOMMIT:-1}" = 1 ] || return 0
  local p paths="" out
  while IFS= read -r p; do [ -n "$p" ] && loop_artifact "$p" && paths="$paths
$p"; done <<EOF
$(dirty_paths)
EOF
  [ -n "$paths" ] || return 0
  printf '%s\n' "$paths" | grep -v '^$' | xargs git add -- 2>/dev/null || return 1
  if out="$(git commit -q -m "chore(loop): $1" 2>&1)"; then
    LOOP_COMMIT_REFUSAL=""; echo "  (committed loop artifacts —$(printf '%s' "$paths" | tr '\n' ' '))"
  else
    LOOP_COMMIT_REFUSAL="$(printf '%s\n' "$out" | grep -v '^$' | tail -4)"
    echo "  WARN the loop's own artifact commit (chore(loop): $1) was REFUSED by the repository's commit hook - the artifacts stay uncommitted:" >&2
    printf '%s\n' "$LOOP_COMMIT_REFUSAL" | sed 's/^/    /' >&2
    return 1
  fi; }
# The journals, committed by the driver at a checkpoint it names — the converged hand-off is one.
commit_harness_journals(){ [ "${DRIVER_AUTOCOMMIT:-1}" = 1 ] || return 0
  local p paths=""
  while IFS= read -r p; do [ -n "$p" ] && harness_journal "$p" && paths="$paths
$p"; done <<EOF
$(dirty_paths)
EOF
  [ -n "$paths" ] || return 0
  printf '%s\n' "$paths" | grep -v '^$' | xargs git add -- 2>/dev/null \
    && git commit -q -m "chore(loop): $1" >/dev/null 2>&1 \
    && echo "  (committed the harness journals —$(printf '%s' "$paths" | tr '\n' ' '))"; }
# The pre-hoc arm of R13: `--max-budget-usd` on the spawn itself, so a role that is re-reading the
# world is cut off while it happens rather than diagnosed from the ledger afterwards. Derived from the
# same token_budget() the post-hoc arm reads, priced per model, doubled for headroom; SPAWN_USD_CAP
# overrides (0 = off). Empty output = no cap, which is what a loop.config without token_budget() gets.
spawn_usd_cap(){ local tb rate
  case "${SPAWN_USD_CAP:-}" in 0) return 0;; ?*) printf '%s' "$SPAWN_USD_CAP"; return;; esac
  command -v token_budget >/dev/null 2>&1 || return 0
  # The step the brief names rides along (1.8.8): a loop.config may price a declared large step.
  tb="$(token_budget "$(budget_role "$1")" "${STEP:-}")"; [ -n "$tb" ] || return 0
  case "$2" in opus) rate=0.75;; sonnet) rate=0.30;; haiku) rate=0.15;; fable) rate=1.50;; *) rate=0.75;; esac
  awk -v t="$tb" -v r="$rate" 'BEGIN{printf "%.2f", t / 1000000 * r * 2}'; }
# The schema every role's last message is held to (`--json-schema`; the CLI validates it and returns
# it as `structured_output`). Minified WITHOUT its descriptions, because the flag rides through the
# same unquoted word-split as CLAUDE_FLAGS and a description has spaces; the descriptions are for the
# reader of schemas/role-outcome.json and are restated in ROLE_PROMPTS.md.
# reviewer → findings.json (its findings ARE its last message), verifier → verify.json (closures by
# id, evidence required), everyone else → role-outcome.json. A missing schema file falls back to the
# role outcome, then to nothing, so a repo installed before a schema existed keeps spawning.
schema_for(){ case "$1" in reviewer) echo findings;; verifier) echo verify;; *) echo role-outcome;; esac; }
schema_flag(){ local f="$HERE/schemas/$(schema_for "${1:-}").json"
  [ -f "$f" ] || f="$HERE/schemas/role-outcome.json"; [ -f "$f" ] || return 0
  printf -- '--json-schema %s' "$(python3 -c '
import json, sys
def strip(o):
    if isinstance(o, dict): return {k: strip(v) for k, v in o.items() if k != "description"}
    if isinstance(o, list): return [strip(x) for x in o]
    return o
print(json.dumps(strip(json.load(open(sys.argv[1]))), separators=(",", ":")))' "$f" 2>/dev/null)"; }
result_field(){ [ -f "$1" ] || return 0
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1])); s = d.get("structured_output")
if not isinstance(s, dict):
    try: s = json.loads(d.get("result") or "")
    except Exception: s = {}
v = (s or {}).get(sys.argv[2], "")
print(v if isinstance(v, str) else json.dumps(v))' "$1" "$2" 2>/dev/null; }
# A TOP-LEVEL field of the result file (`subtype`, `is_error`), as the CLI wrote it - the envelope,
# not the role's structured output. Booleans print as json (`true`/`false`).
result_top(){ [ -f "$1" ] || return 0
  python3 -c '
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
v = d.get(sys.argv[2], "") if isinstance(d, dict) else ""
print(v if isinstance(v, str) else json.dumps(v))' "$1" "$2" 2>/dev/null; }
# ── the tree over the wrapper (harness 1.8.5) ────────────────────────────────
# TT-4348 M8 §2.1: step 2's implementer committed two GREENs, gate green, and the CLI exited non-zero
# with `subtype: error_max_structured_output_retries` and an empty message - its LAST MESSAGE failed
# the schema's retries, after the work had landed. The row said `fail` (5.3 M tokens, $4.29), and
# the sequencer re-asked an opus implementer that answered no_work ($0.48). Cousin of R13 after landed
# work: judge the tree, not the wrapper. A writing role whose exit code or envelope says error, but
# whose scope MOVED between the spawn's HEAD and now AND whose own gate at HEAD is green, is `pass`,
# status `done`, note "result JSON lost: <subtype>". HEAD unmoved keeps `fail` - nothing landed, so
# nothing is judged. Green at HEAD is read from the journal loop-iteration.sh wrote for this role at
# this HEAD (`gates:` PASS / STEP-OK / MID-OK, or a RED entry for the test-author, `breaker: OK`);
# with no such entry the driver runs `gate.sh <MS> step` itself and takes STEP-OK or PASS.
# ── the gate over the row (harness 1.8.6) ────────────────────────────────────
# ONE READER of loop-iteration's journal for "what did the gate say at that commit". 1.8.5 read it at
# HEAD only, for the lost-JSON path; TT-4348 M9 §2.1 needed the same read for every implementer row
# the step counter judges: four times the sequencer derived the next step over a landed GREEN whose
# gate was red on an IT, because column 5 is the role's exit and the gate never entered the count.
# The LAST journal entry for this milestone at @<sha> (the header's short sha; the first 7 characters
# are compared, so a repository whose abbreviation grew still matches), for one role or, with an
# empty role, for any. Printed whole; nothing when there is none.
journal_entry_at(){ local role="${1:-}" sha="$2" r
  [ -f "$SPEC_DIR/LOOP_STATE.md" ] && [ -n "$sha" ] && [ "$sha" != none ] || return 1
  r="$role"; [ -n "$r" ] || r='[a-z-]+'
  awk -v ms="  $MS  " -v h="@$(printf '%s' "$sha" | cut -c1-7)" -v r="^role:[ \t]*$r\$" '
    /^## / { if (keep && ok) last = cur; keep = (index($0, ms) && index($0, h)); cur = $0; ok = 0; next }
    keep { cur = cur "\n" $0; if ($0 ~ r) ok = 1 }
    END { if (keep && ok) last = cur; if (last != "") print last }' "$SPEC_DIR/LOOP_STATE.md" 2>/dev/null; }
# The verdict of an entry, from its `gates:` line: `green` (GATE: PASS / STEP-OK / MID-OK, or a fast
# tier PASS), `redcommit` (a MODE=red entry: the RED was journalled and no gate ran), `red` (anything
# else the gate wrote: NOT GREEN, a FAIL or PENDING fast tier, `GATE: ?`), nothing for no entry.
journal_verdict(){ local e="$1" g; [ -n "$e" ] || return 0
  g="$(printf '%s\n' "$e" | grep -E '^gates:' | tail -1)"
  if printf '%s\n' "$g" | grep -qE 'GATE: (PASS|STEP-OK|MID-OK)|fast\[[^]]*\]: PASS'; then echo green
  elif printf '%s\n' "$g" | grep -qE '^gates:[[:space:]]*red:'; then echo redcommit
  else echo red; fi; }
# THE STEP'S VERDICT (1.8.7, M10 §2.1/§2.2). journal_verdict answers the FULL gate: any `GATE: NOT
# GREEN` is red, whatever tier caused it. The step counter, open_step_red and the ledger's column 14
# ask a narrower question - did the tiers a STEP is measured on pass - and gate.sh's own contract
# says which those are: build, unit, integration and coverage are per-step feedback; mutation, review
# and e2e are per-MILESTONE proof that the step tier skips (`TIER=step` exits above them). Measured
# on TT-4348 M10: five implementer rows in a row journalled `GATE: NOT GREEN - cause: review FAIL`
# over a green step, because the full tier's review clause reads root issues.md for `converged` and
# no review round exists before the steps are built. open_step_red read `red`, re-asked the
# test-author for a RED already written, the tree stopped at one HEAD and RS tripped; six kills at
# spawn and eight `no_work` rows ($3.08) followed. gate.sh puts the FIRST failing tier on the verdict
# line in tier order, so a cause naming mutation, review or e2e means every step tier before it
# passed: green for the step, whatever the milestone still owes. A red with no cause stays red.
# ...UNLESS A STEP TIER IS PENDING BEHIND IT (1.8.7 review, major). gate.sh's rule is FAIL outranks
# PENDING: the verdict line names the first FAIL, and a PENDING build/tests/it/coverage is invisible
# behind a milestone-tier FAIL - which pre-review is every full gate. So gate.sh now appends
# `; step: <tier> PENDING` when the cause is a milestone tier and a step tier is pending, and that
# clause is red here: a step whose own tiers did not measure is not done.
journal_step_verdict(){ local e="$1" v g c
  v="$(journal_verdict "$e")"; [ "$v" = red ] || { printf '%s' "$v"; return 0; }
  g="$(printf '%s\n' "$e" | grep -E '^gates:' | tail -1)"
  case "$g" in *'; step: '*) echo red; return 0;; esac
  c="$(printf '%s\n' "$g" | sed -n 's/.*cause: *//p' | sed -E 's/[( ].*//')"
  case "$c" in mutation|review|e2e) echo green;; *) echo red;; esac; }
journal_gate_at(){ journal_verdict "$(journal_entry_at "$1" "$2")"; }
journal_step_gate_at(){ journal_step_verdict "$(journal_entry_at "$1" "$2")"; }
# The role's newest journal entry at any commit of a ledger row's window (the row before it .. the row
# itself, newest first): the implementer commits, then journals at that HEAD; a driver bookkeeping
# commit or a second commit after the gate would otherwise hide the entry from a HEAD-only read.
journal_entry_in_window(){ local role="$1" a="$2" b="$3" s e
  [ -n "$a" ] && [ -n "$b" ] || return 1
  for s in $(git rev-list --abbrev-commit "$a..$b" 2>/dev/null); do
    e="$(journal_entry_at "$role" "$s")"; [ -n "$e" ] && { printf '%s\n' "$e"; return 0; }
  done; return 1; }
journal_gate_in_window(){ journal_verdict "$(journal_entry_in_window "$1" "$2" "$3")"; }
journal_step_gate_in_window(){ journal_step_verdict "$(journal_entry_in_window "$1" "$2" "$3")"; }
# The milestone's newest journal entry, whatever role wrote it, when nothing in MAIN/TEST scope
# landed after it: its verdict. Nothing when there is no entry, or the tree moved past it (the
# driver's own chore(loop) commits do not count as moving it). The read `findings_for` makes
# before it calls an id fixed (M9 §2.4): "the gate is green at HEAD" is this, not sha equality,
# because the driver commits the loop artifacts before every spawn and HEAD is past the gate by then.
journal_gate_at_head_any(){ local sha e role
  [ -f "$SPEC_DIR/LOOP_STATE.md" ] || return 0
  # THE WRITING ROLES' ENTRIES ONLY (1.8.9 review pass 9, correctness major): the readers journal
  # `fast[...]: PASS` at the driver's HEAD after every round and verify pass - a signal over the
  # affected unit tests, never proof - and the milestone's last header, any role, read that as the
  # gate green at HEAD over a writing role's red full gate one commit back.
  sha="$(awk -v ms="  $MS  " '/^## / { inms = index($0, ms) > 0; hdr = $0; next }
    inms && /^role:[ \t]*(test-author|implementer)[ \t]*$/ { s = hdr }
    END { sub(/.*@/, "", s); sub(/[^0-9a-f].*/, "", s); print s }' "$SPEC_DIR/LOOP_STATE.md" 2>/dev/null)"
  [ -n "$sha" ] && sha_resolves "$sha" || return 0
  if landed_between "$sha" "$(git rev-parse --short HEAD 2>/dev/null)" any; then
    # THE ROLE'S OWN COMMIT RIGHT AFTER ITS JOURNAL (1.8.9, TT-4348 M12 §2.2/§4.4): roles journal
    # BEFORE they commit, so the entry sits at HEAD's parent and this read answered "unknown" at
    # the role's every HEAD - FIXED-AWAITING flickered off and s1-driver-1 was re-verified in every
    # implementer brief after a RED. When HEAD is exactly one commit past the entry and that commit
    # touches only the entry's role's scope, the entry describes the tree the commit made.
    # ...walking back over the driver's own commits first (pass 7, minor): commit_loop_artifacts
    # lands `chore(loop)` before every spawn, and a commit that touches only journals and loop
    # artifacts is not a tree the role's gate did not measure.
    # ...bounded at the root and at eight commits (pass 9, minor: an off-chain entry sha over a
    # bookkeeping-only chain walked forever, before any spawn).
    local top n; top=HEAD; n=0
    while [ "$n" -lt 8 ] && git rev-parse -q --verify "$top^" >/dev/null 2>&1 && commit_within_scope "" "$top" 2>/dev/null \
          && [ "$(git rev-parse --short "$top" 2>/dev/null | cut -c1-7)" != "$(printf '%s' "$sha" | cut -c1-7)" ]; do top="$top^"; n=$((n+1)); done
    [ "$(git rev-parse --short "$top^" 2>/dev/null | cut -c1-7)" = "$(printf '%s' "$sha" | cut -c1-7)" ] || return 0
    e="$(journal_entry_at "(test-author|implementer)" "$sha")"; [ -n "$e" ] || return 0
    role="$(printf '%s\n' "$e" | sed -n 's/^role:[[:space:]]*//p' | head -1)"
    case "$role" in test-author|implementer) :;; *) return 0;; esac
    commit_within_scope "$role" "$top" || return 0
    journal_verdict "$e"; return 0
  fi
  # The writing role's entry at that sha - a reader journals `fast[...]: PASS` at the same HEAD after
  # a blocked or no_work writing role, and the last entry there is the reader's (pass 10, major 2).
  journal_verdict "$(journal_entry_at "(test-author|implementer)" "$sha")"; }
# Every path of commit $2 is in role $1's write-scope (the harness journals and the loop's own
# artifacts aside: a role that `git add -A`s sweeps its journal entry into the same commit).
commit_within_scope(){ local p   # $1 empty = journals and loop artifacts only
  # A merge commit brings in everything its second parent had; diff-tree prints nothing for it
  # without -m, and "nothing" is not "journals only" (pass 11, minor).
  [ "$(git rev-list --parents -n1 "$2" 2>/dev/null | wc -w | tr -d ' ')" -le 2 ] || return 1
  while IFS= read -r p; do [ -z "$p" ] && continue
    harness_journal "$p" && continue; loop_artifact "$p" && continue
    [ -n "$1" ] || return 1
    path_in_scope "$1" "$p" 2>/dev/null || return 1
  done <<EOF
$(git diff-tree --no-commit-id --name-only -r "$2" 2>/dev/null)
EOF
  return 0; }
# The 1.8.5 read, unchanged in what it accepts: the role's own entry at HEAD, breaker OK, a green gate
# or a journalled RED.
journal_green_at_head(){ local e v
  e="$(journal_entry_at "$1" "$(git rev-parse --short HEAD 2>/dev/null)")"; [ -n "$e" ] || return 1
  printf '%s\n' "$e" | grep -q '^breaker:[[:space:]]*OK' || return 1
  v="$(journal_step_verdict "$e")"; [ "$v" = green ] || [ "$v" = redcommit ]; }
# LOST_JSON_GATE (1.8.6): the verdict this run measured, for the ledger's column 14.
LOST_JSON_GATE=""
gate_green_at_head(){ local g
  g="$("$HERE/gate.sh" "$MS" step 2>&1)" || true
  if printf '%s\n' "$g" | grep -qE '^GATE: (PASS|STEP-OK)'; then LOST_JSON_GATE=green; return 0; fi
  LOST_JSON_GATE=red; return 1; }
lost_json_green(){ local role="$1" head0="$2"
  case "$role" in test-author|implementer) :;; *) return 1;; esac
  landed_between "$head0" "$(git rev-parse HEAD 2>/dev/null)" "$role" || return 1
  if journal_green_at_head "$role"; then LOST_JSON_WHY="journalled green at HEAD by $role"; LOST_JSON_GATE=green; return 0; fi
  gate_green_at_head && { LOST_JSON_WHY="gate.sh $MS step at HEAD: green"; return 0; }
  return 1; }
# ── a test-only landing that IS the step's RED (harness 1.8.6) ───────────────
# TT-4348 M9 §2.2: the test-author steered for `s1-driver-1` fixed a fixture and stopped, as told;
# the step counter's red flag and the sequencer both read "src/test moved" as the step's RED, and the
# step 2 implementer was dispatched against no RED (killed at $0). A landing in the test scope is the
# step's RED when the cheapest honest signal says so: a commit message in the row's window or the
# role's own note names RED (the house shape is `test(Mn): RED ...`), a NEW file under the test scope,
# or an added test marker (@Test, def test_, it(/test(/describe(, func Test, #[test]). A fix to an
# existing fixture with none of those is not a RED, and leaves the red flag where it was. Shas the
# repository cannot resolve fail the old way (a RED), as landed_between does.
# THE SIGNALS, cheapest and most framework-free first. The marker list came last on purpose (1.8.6
# review, major 3): a RED that tightens an ASSERTION inside an existing test method adds no marker
# and creates no file, and enumerating frameworks will always miss one - `@TestFactory`, `it.each(`,
# a table-driven Go subtest, a pytest test class. So:
#   1. the role's own note, or a commit subject in the window, names RED (the house shape is
#      `test(Mn): RED ...`, and ROLE_PROMPTS asks the test-author to say so)
#   2. the JOURNAL for the test-author in that window says red - a MODE=red entry ("RED commit
#      journalled, no gate run") or a gate that failed there. Framework-free, and the loop already
#      writes it on every RED: this is the signal, the rest are the fallbacks for a role that
#      committed without journalling
#   3. a NEW file under the test scope
#   4. an added ASSERTION-shaped line - the thing a test does, whatever names the framework gives it
#   5. an added test marker, the widest list worth keeping
red_landing(){ local a="$1" b="$2" note="${3:-}" f added
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] || return 1
  git cat-file -e "${a}^{commit}" 2>/dev/null && git cat-file -e "${b}^{commit}" 2>/dev/null || return 0
  printf '%s' "$note" | grep -qiE '(^|[^a-z])red([^a-z]|$)' && return 0
  git log --format=%s "$a..$b" 2>/dev/null | grep -qiE '(^|[^a-z])red([^a-z]|$)' && return 0
  case "$(journal_step_gate_in_window test-author "$a" "$b")" in redcommit|red) return 0;; esac
  while IFS= read -r f; do [ -n "$f" ] && path_in_scope test-author "$f" 2>/dev/null && return 0; done <<EOF
$(git diff --name-only --diff-filter=A "$a" "$b" 2>/dev/null)
EOF
  while IFS= read -r f; do [ -n "$f" ] || continue
    path_in_scope test-author "$f" 2>/dev/null || continue
    added="$(git diff "$a" "$b" -- "$f" 2>/dev/null | grep -E '^\+[^+]' || true)"
    # An assertion: the call shapes every xUnit, hamcrest, jest, pytest, gtest, XCTest and rust
    # dialect shares, plus python's bare `assert` statement and the jest/chai matcher suffixes.
    printf '%s\n' "$added" | grep -qE '(^|[^A-Za-z0-9_.])(assert[A-Za-z_]*|expect|verify|require|should[A-Za-z_]*|EXPECT_[A-Z_]+|ASSERT_[A-Z_]+|XCTAssert[A-Za-z]*)[[:space:]]*\(|^\+[[:space:]]*assert[[:space:]]|\.(toBe|toEqual|toThrow|toContain|toHaveBeenCalled|isEqualTo|isTrue|isFalse|hasSize|containsExactly|shouldBe)\b' && return 0
    printf '%s\n' "$added" | grep -qE '@Test|@TestFactory|@ParameterizedTest|@RepeatedTest|\[Fact\]|\[Theory\]|def test_|class Test[A-Z]|(^\+[[:space:]]*|[^A-Za-z0-9_.])(it|test|describe|context)(\.(each|only|skip))?\(|func Test[A-Z]|t\.Run\(|#\[(tokio::)?test\]' && return 0
  done <<EOF
$(git diff --name-only "$a" "$b" 2>/dev/null)
EOF
  return 1; }

# ── a role in flight (harness 1.8.6) ─────────────────────────────────────────
# TT-4348 M9 §2.3: a steer written while the step 3 test-author ran was an uncommitted loop artifact
# when the role's scope audit read the tree, and R6 stopped the run on a clean src/test commit ($1.96,
# acked false). The driver now marks every spawn in `<git-dir>/tddloop-role.pid` (pid, role,
# milestone, time - inside .git so no scope reader ever sees it; per worktree, as a run is), clears it
# at collect and in the kill trap, and `steer` refuses while a marked pid is alive. A marker whose
# pids are all gone is a driver that died, and is dropped.
inflight_file(){ printf '%s/tddloop-role.pid' "$(git rev-parse --git-dir 2>/dev/null || echo .git)"; }
# ...AND IN FLIGHT UNTIL COLLECTED (1.8.7, M10 §2.4). 1.8.6 keyed the marker on the ROLE's pid and
# cleared it before spawn_collect, so the moment the CLI exited a polling `steer` was accepted - and
# the post-hoc scope audit inside spawn_collect ran two seconds later over the steer's uncommitted
# issues.md: R6 on an implementer that had touched only src/main (TT-4348 M10, 09:57 UTC, acked
# false). The role is in flight until the driver has JUDGED it, so the marker also carries the
# driver's pid and a line is live while either pid is; `spawn` clears it after collect. A driver that
# died mid-collect leaves two dead pids, and the marker is dropped as before.
# `.loop/` is usable when git ignores it: an unignored directory would be a dirty tree to every
# scope audit and every pre-spawn commit. Created on first use; the answer is cached per process.
LOOP_DIR_OK=""
loop_dir_ok(){ [ -n "$LOOP_DIR_OK" ] || {
    if git check-ignore -q "$ROOT/.loop/x" 2>/dev/null; then mkdir -p "$ROOT/.loop" 2>/dev/null && LOOP_DIR_OK=1 || LOOP_DIR_OK=0
    else LOOP_DIR_OK=0; echo "  (.loop/ is not gitignored - the run's log and the roles' result JSONs stay under $LOGDIR; the installer adds the ignore line)" >&2; fi; }
  [ "$LOOP_DIR_OK" = 1 ]; }
# A role's brief and result JSON, kept beside the run's log (1.8.9): the two files a kill or a retro
# reads, and the two files a reboot of the machine erased from $TMPDIR in M12.
loop_keep(){ loop_dir_ok || return 0; local f; for f in "$@"; do [ -f "$f" ] && cp -f "$f" "$ROOT/.loop/" 2>/dev/null; done; return 0; }
inflight_mark(){ printf '%s %s %s %s %s\n' "$1" "$2" "$MS" "$(date -u +%FT%TZ)" "$$" >> "$(inflight_file)" 2>/dev/null || true; }
inflight_clear(){ rm -f "$(inflight_file)" 2>/dev/null || true; }
# "<role> (pid N, <ms>, since <ts>)" per live role, nothing (and the marker dropped) when none is alive.
# A 1.8.6 marker has no fifth field and is read as before: live while the role's pid is.
inflight_role(){ local f p r m t d live=""; f="$(inflight_file)"; [ -f "$f" ] || return 1
  while read -r p r m t d; do [ -n "$p" ] || continue
    if kill -0 "$p" 2>/dev/null; then live="$live$r (pid $p, $m, since $t); "
    elif [ -n "$d" ] && kill -0 "$d" 2>/dev/null; then live="$live$r (pid $p exited, driver $d collecting, $m, since $t); "; fi
  done < "$f"
  [ -n "$live" ] || { rm -f "$f"; return 1; }
  printf '%s' "${live%; }"; }
# ── the adapter's formatter (harness 1.8.6) ──────────────────────────────────
# M9 §2.6: the CLI's per-invocation cap ended step 7's implementer after its GREEN and before spotless
# or the gate, and the driver formatted, committed and gated by hand. An adapter MAY define
# `gate_format_check` (0 = formatted) and `gate_format_apply`; the driver reads them in a subshell so
# the adapter's namespace never enters this file. Absent, the check answers 0 and nothing happens.
adapter_format_check(){ ( [ -f "$HERE/adapters/${STACK:-none}.sh" ] || exit 0
  # shellcheck disable=SC1090
  . "$HERE/adapters/${STACK}.sh" 2>/dev/null || exit 0
  command -v gate_format_check >/dev/null 2>&1 || exit 0; export LOGDIR; gate_format_check ); }
adapter_format_apply(){ ( [ -f "$HERE/adapters/${STACK:-none}.sh" ] || exit 1
  # shellcheck disable=SC1090
  . "$HERE/adapters/${STACK}.sh" 2>/dev/null || exit 1
  command -v gate_format_apply >/dev/null 2>&1 || exit 1; export LOGDIR; gate_format_apply ); }
# After a budget-capped writing role that moved HEAD: format when the formatter refuses the tree, and
# commit what the FORMATTER touched, wherever it landed.
#
# THE COMMIT IS THE DRIVER'S, NOT THE ROLE'S (1.8.6 review, major 2). The first cut staged only dirty
# paths inside the capped role's write-scope, and a project-wide `spotlessApply` reformats whatever
# the project declares - which is precisely the case here, since the role never reached the formatter.
# Anything it touched outside that scope stayed dirty, the next `spawn_brief` refused ("the tree
# carries changes outside its write-scope"), `run` exited 4, and the operator was told to clean a tree
# the driver had just dirtied. The driver is not a role and DRIVER_SCOPE is not the fence a formatter
# has to respect, so the formatter's own output is committed whatever its scope; the role's
# uncommitted work is still only taken from the role's scope, so a violation the audit let through is
# not laundered into the driver's commit.
#
# AND THE COMMIT IS THE THING THE GATE THEN MEASURES. `gate.sh` reads the WORKING TREE, so a
# formatter output left uncommitted would be gated and then stamped into column 14 as the verdict for
# a commit that is not what was gated. FORMAT_DIRTY says so, and spawn_collect stamps nothing.
# wip_commit <role> <note>: the blocked role's dirty in-scope paths, committed when the step tier
# is green on them. Sets LOST_JSON_GATE (column 14) and WIP_ROW; returns 1 with the tree untouched
# when nothing is dirty, a path is outside the role's scope, or the tier is red.
WIP_ROW=""
wip_commit(){ local role="$1" note="$2" p paths="" g
  while IFS= read -r p; do [ -z "$p" ] && continue
    harness_journal "$p" && continue; loop_artifact "$p" && continue
    path_in_scope "$role" "$p" 2>/dev/null || return 1
    paths="$paths $p"; done <<EOF
$(dirty_paths)
EOF
  [ -n "$paths" ] || return 1
  if gate_green_at_head; then
    # UNDER THE REPOSITORY'S HOOKS, refusal shown (1.8.9 review pass 7, conformance major 2): this is
    # the one driver commit that lands the role's SOURCE, where a secret scan matters most, and the
    # 1.8.4 rule for the driver's commits is that a rejecting hook is seen, never swallowed.
    local cout
    # shellcheck disable=SC2086
    if ! cout="$(git add -- $paths 2>&1 && git commit -q -m "wip($role): $MS - $(printf '%s' "${note:-blocked with in-scope work}" | utf8_head 72)" 2>&1)"; then
      git reset -q -- $paths 2>/dev/null || true
      # The working-tree measurement is not HEAD's (pass 12, major): the stamp goes with the files.
      LOST_JSON_GATE=""
      echo "  the wip($role) commit was REFUSED by the repository's commit hook; the files stay uncommitted (the next spawn refuses on them). Its last lines:" >&2
      printf '%s\n' "$cout" | tail -5 | sed 's/^/    /' >&2; return 1; fi
    WIP_ROW="wip($role): committed$paths after a blocked answer - the step tier was green on them ($(git rev-parse --short HEAD 2>/dev/null))"
    echo "  wip($role): committed$paths - the role answered blocked over a green step tier (M12 §2.3)"; return 0
  fi
  echo "  ($role answered blocked and left$paths uncommitted; the step tier on them is RED, so they stay as left - the next spawn refuses on them until they are committed or cleaned)" >&2
  LOST_JSON_GATE=""; return 1; }
FORMAT_ROW=""; FORMAT_DIRTY=""
budget_capped_format(){ local role="$1" p before paths="" left=""
  FORMAT_ROW=""; FORMAT_DIRTY=""
  adapter_format_check >/dev/null 2>&1 && return 0
  echo "  (the $role ended at the budget cap with HEAD moved and the formatter refuses the tree - formatting it, then the gate)"
  # The dirty set BEFORE the formatter runs, as a membership string (bash 3.2 has no associative
  # arrays): a path dirty then is the role's own uncommitted work; one dirty only after is the
  # formatter's. A path cannot contain ':' + newline, so ":<path>:" is an unambiguous key.
  before=":$(dirty_paths | tr '\n' ':')"
  adapter_format_apply >/dev/null 2>&1 || {
    echo "  WARN the adapter's format-apply failed - the tree stays as the $role left it, and no gate verdict is recorded for this row" >&2
    FORMAT_DIRTY=1; return 1; }
  while IFS= read -r p; do [ -n "$p" ] || continue
    # Dirty before the formatter ran: the role's, and only inside its scope.
    case "$before" in *":$p:"*) path_in_scope "$role" "$p" 2>/dev/null || continue;; esac
    paths="$paths
$p"
  done <<EOF
$(dirty_paths)
EOF
  [ -n "$(printf '%s' "$paths" | tr -d '[:space:]')" ] || return 0
  if printf '%s\n' "$paths" | grep -v '^$' | xargs git add -- 2>/dev/null \
     && git commit -q -m "style($MS): format after the budget-capped $role" >/dev/null 2>&1; then
    FORMAT_ROW="format after the budget-capped $role: $(git rev-parse --short HEAD 2>/dev/null) style($MS)"
    echo "  (committed $(git rev-parse --short HEAD 2>/dev/null): style($MS): format after the budget-capped $role$(printf '%s' "$paths" | tr '\n' ' ' | sed 's/  */ /g;s/^/ -/'))"
  else
    echo "  WARN the driver could not commit the formatter's output - it stays in the tree, and no gate verdict is recorded for this row" >&2
    FORMAT_DIRTY=1; return 1
  fi
  # Anything the FORMATTER touched that is still dirty (a path the commit could not take) makes the
  # gate below a measurement of something other than HEAD.
  while IFS= read -r p; do [ -n "$p" ] || continue
    case "$before" in *":$p:"*) continue;; esac
    left="$left $p"
  done <<EOF
$(dirty_paths)
EOF
  [ -n "$left" ] && { echo "  WARN the formatter also left$left uncommitted - no gate verdict is recorded for this row" >&2; FORMAT_DIRTY=1; return 1; }
  return 0; }

# SPLIT IN THREE (1.8.0): `spawn_brief` writes the brief and refuses a dirty tree, `spawn_launch`
# starts the CLI, `spawn_collect` audits scope, appends the ledger row and renders a review role's
# structured output. `spawn` is the three in a row, unchanged in behaviour; the parallel fan-out in
# `run` writes every dimension's brief first, launches them all, waits once, and collects in
# dimension order — so the ledger rows land in the order the round was declared, whatever order the
# reviewers finished in. State between the three travels in S_* globals (bash 3.2: no return values).
spawn_brief(){ local role="$1" model="$2" brief sect step_sect
  S_BRIEF="$LOGDIR/brief-$MS-$role${DIM:+-$DIM}-$(count_all).md"; brief="$S_BRIEF"; S_ART=""; S_OUT=""
  # ── A CLEAN TREE, OR NO SPAWN ───────────────────────────────────────────────
  # The post-hoc audit below blames the ROLE for everything between head0 and HEAD — and it cannot
  # tell a role's write from a file the driver left dirty before the spawn. Measured (TT-4348 M2):
  # 6 R6 trips, 4 false, 3 of them the driver's own consolidate output. "Consolidate, commit, THEN
  # spawn" was a rule in two learnings files and was broken three times in one milestone; a rule the
  # driver has to remember is not a mechanism. So the loop's own artifacts are committed here and
  # anything else outside the role's scope refuses the spawn — no ledger row, no breaker, no ack.
  # Never between the dimensions of a round: a commit there moves HEAD under the fan-out, and
  # dimension 2 would read a different base from dimension 1. `run` commits once, before the round.
  # stdout only: the WARN a refused commit prints goes to stderr, and `2>&1` here was what ate it.
  [ "$DRY" = 1 ] || [ -n "$DIM" ] || commit_loop_artifacts "artifacts before $role" >/dev/null || true
  local p dirty=""
  while IFS= read -r p; do [ -z "$p" ] && continue
    path_in_scope "$role" "$p" 2>/dev/null && continue
    harness_journal "$p" && continue
    [ "$DRY" = 1 ] && loop_artifact "$p" && continue   # a live run would have committed it just above
    dirty="$dirty    $p
"; done <<EOF
$(dirty_paths)
EOF
  if [ -n "$dirty" ]; then
    # A dry run is a rehearsal: it says what the live run would refuse, and still writes the brief the
    # operator is about to read, because nothing is spawned either way.
    if [ "$DRY" = 1 ]; then
      echo "  WARN a live run would REFUSE this spawn — dirty outside $role's write-scope:" >&2; printf '%s' "$dirty" >&2
    else
      echo "REFUSED to spawn $role: the tree carries changes outside its write-scope, and the scope audit would blame the role for them:" >&2
      printf '%s' "$dirty" >&2
      echo "  Commit or clean them first. (The loop's own artifacts — issues.md, review-results/, $SPEC_DIR/ISSUES.md, LOOP_CLAUDE.md — are committed for you when DRIVER_AUTOCOMMIT=1.) No ledger row was written." >&2
      # The driver tried, and the repository's hook said no (1.8.4): the cause, not only the symptom.
      [ -n "$LOOP_COMMIT_REFUSAL" ] && { echo "  The driver's own commit of the loop artifacts was REFUSED by the repository's commit hook (gitleaks, signing, ...). Its last lines:" >&2
        printf '%s\n' "$LOOP_COMMIT_REFUSAL" | sed 's/^/    /' >&2
        echo "  Satisfy the hook (e.g. a .gitleaks.toml allowlist for a review phrase that reads as a key), commit the artifacts, then re-run." >&2; }
      return 4
    fi
  fi
  local cap; cap="$(spawn_usd_cap "$role" "$model")"; S_CAP="$cap"
  { echo "# Role: $role — milestone $MS"
    echo
    echo "You are the **$role** for milestone $MS of the TDD loop in this repository."
    # ...AND THE ROOM FOR THE GATE (1.8.6, M9 §2.6): two sonnet implementers reached the cap at ~20 M
    # tokens, one before spotless and its gate had run. The turn the cap ends is the role's; the mark
    # to have committed, formatted and journalled by is 85 % of it, said here in dollars.
    [ -n "$cap" ] && echo "This invocation is capped at \$$cap of API spend; the CLI ends your turn at the cap. Commit and journal as soon as something is worth keeping, and have committed, run the formatter and run your gate (loop-iteration.sh) by \$$(awk -v c="$cap" 'BEGIN{printf "%.2f", c * 0.85}') (85 % of the cap): a turn the cap ends before the gate leaves an ungated commit that the driver has to format and gate for you."
    echo "Read \`$SPEC_DIR/LOOP_CLAUDE.md\` first. Everything else you need to START is PASTED BELOW —"
    echo "the plan text for your step, the findings against this milestone, the state of the tree since"
    echo "the last journalled iteration, and what the last gate said. Re-deriving any of it is a turn"
    echo "you are paying for, and turns are what this loop costs. Open a file when the brief points you"
    echo "at one or when you need something it does not carry — and say which, so the next brief can."
    # PRECOMPUTED PLAN TEXT. See § precomputed brief material: the discovery a role used to do
    # (open plan → find milestone → find step) is 4-6 tool calls at the role's model, and the driver
    # already knows the answer. Pasted with its provenance so anything not pasted can still be opened.
    if [ -f "$PLAN" ]; then
      sect="$(plan_section "$MS")"
      step_sect=""; [ -n "$STEP" ] && step_sect="$(step_section "$MS" "$STEP")"
      echo
      if [ -n "$STEP" ]; then
        echo "## Your step: $STEP — verbatim from \`$PLAN\`"
        if [ -n "$step_sect" ]; then printf '%s\n' "$step_sect" | head -n "$PLAN_EXCERPT_MAX"
        else
          echo "_Nothing in \`$MS\`'s section of \`$PLAN\` names step \`$STEP\`._ The milestone section is below instead;"
          echo "find step \`$STEP\` in it. (Said explicitly rather than pasting nothing: a silently"
          echo "empty section reads as 'there is no plan for this step', which is a different claim.)"
        fi
        echo
      fi
      echo "## Milestone $MS — verbatim from \`$PLAN\`"
      if [ -n "$sect" ]; then printf '%s\n' "$sect" | head -n "$PLAN_EXCERPT_MAX"
        [ "$(printf '%s\n' "$sect" | wc -l | tr -d ' ')" -gt "$PLAN_EXCERPT_MAX" ] \
          && echo "_(truncated at $PLAN_EXCERPT_MAX lines — the rest is in \`$PLAN\`)_"
      else echo "_No heading in \`$PLAN\` names \`$MS\` — open the file and orient yourself._"; fi
    else
      echo "Read the \`$MS\` section of \`$SPEC_DIR/TDD_PLAN.md\` (this driver could not find that file)."
    fi
    # The review's findings must REACH the next role, and until now they did not. The brief named
    # LOOP_CLAUDE and TDD_PLAN and nothing else, so a role spawned after a review round had no idea a
    # review had happened: the reviewer wrote blockers, the driver consolidated them, and the next
    # role was briefed as though the file did not exist. A review nobody is told about is a review
    # that changes nothing — the same shape as a gate with no executor, one artifact along.
    #
    # Now the findings are pasted AND split by write-scope, because "the ones in your own scope" was a
    # judgement the role had to make by reading globs it does not carry. The driver enforces those
    # globs; it can label them.
    if [ -f issues.md ] && grep -qE "\b$MS\b" issues.md 2>/dev/null; then
      echo
      echo "## Findings already raised against $MS — from \`issues.md\`, marked by write-scope"
      echo
      echo '```'
      findings_for "$role"
      echo '```'
      echo
      echo "**\`[YOURS]\` findings are the FIRST work of this invocation**, ahead of the next TDD step."
      echo "A finding you believe is wrong is answered in writing, in your output, with the evidence"
      echo "that refutes it; it is never silently skipped. Findings marked with another role belong to"
      echo "that role: name them and leave them. \`issues.md\` remains the authority — the lines above"
      echo "are its blocker/major lines, split by scope, not a verdict on convergence."
    fi
    # THE OPEN STEP (1.8.6, M9 §2.1): the implementer landed its GREEN and the gate refused it at
    # that HEAD; the step counter did not advance, the sequencer answered the RED's owner, and the
    # first failing test rides on the brief so the role does not re-run a gate to learn what it said.
    local osr; osr=""; [ "$role" = test-author ] && osr="$(open_step_red 2>/dev/null || true)"
    if [ -n "$osr" ]; then
      echo
      echo "## The step is OPEN - the implementer's gate at HEAD is RED"
      echo
      echo "The implementer landed its GREEN for this step and the gate refused it. The driver read the gate,"
      echo "not the exit: the step is NOT done, and you are asked first because on every such red so far the"
      echo "cause was on the test side (a fixture, a double, an IT wiring) rather than in the landed code."
      echo
      echo '```'
      printf '%s\n' "$osr"
      echo '```'
      echo
      echo "Make the first failing test above pass against the landed code by fixing the TEST side, commit,"
      echo "and journal it (MODE=red is wrong here - this is not a new RED; run the step gate). If the failure"
      echo "is the implementation's, do not touch src/main: answer \`blocked\` naming the test and the line,"
      echo "and stop; the implementer is asked again with your words."
    fi
    # YOUR PREVIOUS ATTEMPT. Nothing told a role why the last invocation of the same role ended the
    # way it did — not its outcome, not the breaker it tripped, not its own last words. Measured: three
    # implementers in a row refuted the same wrong blocker from scratch ($8.01), and five invocations
    # each re-discovered that nothing in their scope needed doing. Shown only when there is something
    # to learn from: the last same-role row did not pass, or passed and committed nothing.
    local prow pout psha ppsha pstat pnote
    prow="$(role_rows | awk -F'\t' -v r="$role" '$3==r' | tail -1)"
    if [ -n "$prow" ]; then
      pout="$(printf '%s\n' "$prow" | cut -f5)"; psha="$(printf '%s\n' "$prow" | cut -f6)"
      pstat="$(printf '%s\n' "$prow" | cut -f11)"; pnote="$(printf '%s\n' "$prow" | cut -f12)"
      ppsha="$(role_rows | awk -F'\t' -v r="$role" '$3==r {p=prev} {prev=$6} END{print p}')"
      local planded=0; landed_between "$ppsha" "$psha" "$role" && planded=1
      case "$pstat" in no_work|blocked|refuted) :;; *) [ "$pout" != pass ] || [ "$planded" = 0 ] || pstat="";; esac
      if [ "$pout" != pass ] || [ "$planded" = 0 ] || [ -n "$pstat" ]; then
        echo
        echo "## Your previous attempt — the last $role invocation for $MS"
        echo
        echo "It ended \`$pout\`${pstat:+ (its own status: \`$pstat\`)} at HEAD \`$psha\`$([ "$planded" = 0 ] && echo ', having committed nothing in your scope')."
        awk -v ms="  $MS  " -v r="role:    $role" '
          /^## / { if (index($0, ms)) { keep = 1; buf = $0 } else { keep = 0 }; next }
          keep { buf = buf "\n" $0 }
          keep && /^note:/ { if (index(buf, r)) last = buf }
          END { if (last != "") print last }' "$SPEC_DIR/LOOP_STATE.md" 2>/dev/null \
          | grep -E '^(breaker|cause|gates):' | sed 's/^/  /'
        [ -n "$pnote" ] && { echo; echo "Its last words: $pnote"; }
        echo
        echo "Do not repeat it. If the same obstacle is still there, say so in your message — with the"
        echo "command that shows it — and stop; a second identical attempt is what the loop is trying not to buy."
      fi
    fi
    # THE WORKING SET. Every role gets it; the reviewer additionally gets its own range below.
    local wbase; wbase="$(work_base)"
    echo
    echo "## The tree you are working in — precomputed, from \`git\`"
    echo
    echo '```'
    tree_summary "$wbase"
    echo '```'

    local jrn; jrn="$(last_journal)"
    echo
    echo "## The last gate for $MS — verbatim from \`$SPEC_DIR/LOOP_STATE.md\`"
    echo
    if [ -n "$jrn" ]; then
      echo '```'
      printf '%s\n' "$jrn"
      echo '```'
      echo
      echo "That is the measurement that already exists. Do not re-run a gate to find out what it said;"
      echo "run one when you have changed something it measures."
    else
      echo "_No journalled iteration for $MS yet — you are the first role in this milestone._"
    fi

    if [ "$role" = reviewer ]; then
      # SCOPED REVIEW. Two facts, both measured on one milestone: 4 of 6 reviewer invocations ($22.99)
      # were spent on the harness rather than the deliverable, and round ≥2 re-read a diff whose
      # earlier half had not changed since the round that already reviewed it.
      echo
      if [ -n "$DIM" ]; then
        # ONE DIMENSION, AND ONLY IT. The point of the fan-out is N reviewers with COLD, independent
        # context — three passes inside one context is one reviewer with three headings, which is what
        # the harness already had. Saying "only this one" is what makes the invocation worth its cost.
        echo
        echo "## Your dimension: **$DIM**"
        echo
        echo "This round fans out one reviewer per dimension ($(review_dims | tr '\n' ' ')), each with its"
        echo "own context and its own artifact. **Review \`$DIM\` and nothing else.** A defect outside your"
        echo "dimension is another reviewer's this same round: do not report it, and do not widen your"
        echo "scope to cover for them. The rules for your role are below; read them AS \`$DIM\`."
        echo
        echo "Probe in your OWN workspace so the concurrent dimensions do not collide:"
        echo
        echo "\`\`\`"
        echo "eval \"\$(scripts/review-workspace.sh path $DIM)\""
        echo "\`\`\`"
      fi
      echo
      echo "## What you are reviewing"
      echo
      echo "\`\`\`"
      echo "git diff $(review_base)..HEAD"
      echo "\`\`\`"
      echo
      echo "That range is your scope. Earlier work in this milestone was reviewed in a previous round;"
      echo "re-open it only where this diff changes its meaning, and say so when you do."
      echo "\`scripts/\` is the LOOP HARNESS, not this milestone's deliverable. Do not review it unless"
      echo "the milestone's own plan changes it — a finding about the harness belongs in the harness's"
      echo "own repository, not in this milestone's review, and reviewing it has already cost one loop"
      echo "four of its six reviewer invocations."
      # THE OUTPUT PATH, NAMED BY THE DRIVER. Left to itself the review skill writes
      # `review-results/<branch>_issues.md` — no round, no dimension — and review_rounds() reads the
      # round number OUT OF THE FILENAME, falling back to 1 when it finds none. Since nothing ever
      # wrote a `_roundN_` name, that fallback was the only branch ever taken: every round reported
      # "1", `status` printed `1 / 5` on round five, and RV could not fire however many rounds ran.
      # One milestone ran FIVE rounds against a budget of five and the breaker never saw past the
      # first. The driver knows the round; it just never said so.
      echo
      echo "## Where to write your findings"
      echo
      echo "\`\`\`"
      S_ART="$(review_artifact_path)"
      echo "$S_ART"
      echo "\`\`\`"
      echo
      echo "Write that EXACT path — the round number in it is what the loop counts rounds by, and a"
      echo "file without one is read as round 1 for ever. Do not also write the unnumbered"
      echo "\`<branch>_issues.md\`; the driver consolidates every round's file into root \`issues.md\`."
      [ -n "$DIM" ] && echo "The dimension is in the path too, so this round's $(review_dim_count) reviewers do not overwrite each other."
      # THE FINDINGS ARE THE LAST MESSAGE (1.8.0). A prose artifact is a shape the gate has to guess
      # at; a JSON finding has a path, a severity and an evidence command or it does not parse. The
      # driver renders it under a stable id, so a later verify pass can close it BY NAME.
      if [ -f "$HERE/schemas/findings.json" ]; then
        echo
        echo "## Your findings are your LAST MESSAGE — \`schemas/findings.json\`"
        echo
        echo "The CLI holds your final message to that schema: \`verdict\` (\`converged\` | \`open\` — THIS dimension's"
        echo "own blocker/major findings; minors never decide it) and \`findings[]\`, one entry per defect:"
        echo "\`severity\` (blocker | major | minor), \`path\` (a dir/file.ext PATH — never a class or module name;"
        echo "the path is what routes the finding to the role that owns it), \`line\`, \`title\`, \`evidence_command\`"
        echo "and \`observed_output\`. The DRIVER renders them to the path above under stable ids"
        echo "\`r$(review_round_now)-${DIM:-review}-<n>\` and derives the status line from the findings themselves — a"
        echo "\`converged\` verdict over an open major is reported, and the findings decide. Prose you write at that"
        echo "path is kept beside the rendered artifact as \`…_issues.prose.md\`, uncounted: the JSON is the"
        echo "verdict, the prose is your notes. A finding without an evidence command is a claim — say in its"
        echo "title that you could not reproduce it. An earlier finding you re-checked (its id is on its line in"
        echo "the findings pasted above) goes in \`verifications[]\` with BOTH evidence fields, or the closure is"
        echo "refused and the finding stays open."
      fi
    elif [ "$role" = verifier ]; then
      # THE VERIFY PASS (1.8.0): named findings, the commits that claim to fix them, and an answer per id
      # by execution. Nothing new is raised here — a new defect goes in the message and the driver
      # decides whether it is worth a full round.
      S_ART="$(verification_artifact_path)"
      local vb; vb="$(verify_base)"
      echo
      echo "## Verify pass $(( $(review_verifications) + 1 )) — re-prove the OPEN findings, by id"
      echo
      echo "You are not reviewing the milestone and you are not looking for new defects. Every finding below"
      echo "is open in \`issues.md\`; the commits since the last review are its claimed fix. For EVERY id answer"
      echo "resolved, open or refuted — by EXECUTION in your own workspace, never by reading a diff:"
      echo
      echo "\`\`\`"
      echo 'eval "$(scripts/review-workspace.sh path verify)"'
      echo "\`\`\`"
      echo
      echo "\`\`\`"
      # MINORS TOO. Convergence counts blocker/major only, so `open_findings` filters to those - and a
      # verifier briefed from it never saw the minors fixed along the way: two stood open after
      # convergence for a hand flip with the evidence in the commit (TT-4348 M5). A minor with an id
      # costs the same to re-prove as a major, so the verifier gets every open id.
      open_findings --all | awk -F'\t' '{print $3}'
      echo "\`\`\`"
      echo
      echo "## The fix commits — what changed since the last review"
      echo
      echo "\`\`\`"
      echo "git diff $vb..HEAD"
      git log --oneline "$vb"..HEAD 2>/dev/null | sed 's/^/  /' | head -20
      git diff --stat "$vb"..HEAD 2>/dev/null | sed 's/^/  /' | head -30
      echo "\`\`\`"
      echo
      echo "## Your verdict is your LAST MESSAGE — \`schemas/verify.json\`"
      echo
      echo "\`verifications[]\`: one entry PER ID above — \`id\`, \`verdict\` (resolved | open | refuted),"
      echo "\`evidence_command\` (what you ran in \$REVIEW_WT) and \`observed_output\` (what it printed). The driver"
      echo "applies a closure ONLY when both evidence fields are non-empty; a bare \`resolved\` is refused and the"
      echo "finding stays open — a paragraph is not a closure. A defect you notice in the fix commits that is"
      echo "not one of these ids goes in \`message\`, never in a verdict. Your write-scope is \`review-results/\`;"
      echo "notes are optional, at:"
      echo
      echo "\`\`\`"
      echo "$S_ART"
      echo "\`\`\`"
    fi
    echo
    echo "Your write scope is enforced by \`scripts/check-scope.sh $role\` — anything outside it trips R6."
    # READER 1 of REVIEW_SRC_ONLY_AFTER_ROUND. Told to the reviewer BEFORE it reads, because the
    # alternative is `consolidate` refusing the round afterwards and the whole fan-out being paid for
    # twice. `consolidate` still refuses — a brief is guidance and the gate is enforcement — but a
    # reviewer that was told the rule and kept to it never reaches that arm.
    if [ "$role" = reviewer ]; then
      # ABSENT OR EMPTY IS OFF, deliberately. A config written before this knob existed must not
      # silently acquire a cap on upgrade — the refusal below would start failing a consolidation
      # that succeeded yesterday, mid-milestone. Same contract REVIEW_DIMENSIONS and milestone_model
      # make, and loop.config.template ships `=5` so a NEW install gets the behaviour by default.
      _rr="$(review_rounds)"; _rr="${_rr:-0}"; _cap="${REVIEW_SRC_ONLY_AFTER_ROUND:-}"
      if [ -n "$_cap" ] && [ "$_rr" -ge "$_cap" ]; then
        echo
        echo "## SCOPE CAP — this is round $(( _rr + 1 )), past REVIEW_SRC_ONLY_AFTER_ROUND=$_cap"
        echo
        echo "Raise blocker/major findings ONLY against EXECUTABLE artifacts — source, tests, scripts,"
        echo "build files, CI config. A defect whose only evidence is a DOCUMENT (\`docs/\`, \`specs/\`,"
        echo "any bare \`*.md\`) is recorded as ONE line under a \`## Deferred to ticket\` heading in"
        echo "your artifact — severity, file, one sentence — and is NOT a blocker or major, so it"
        echo "cannot hold the gate or buy another round. \`consolidate\` REFUSES a doc-only"
        echo "blocker/major past this round and will name it."
        echo
        echo "This is not a licence to stop reading documents: a document that CONTRADICTS the code"
        echo "is a finding about the code it misdescribes, and stays in scope at full severity."
      fi
    fi
    echo
    echo "## Standing rules for every role"
    section_of '## All roles'
    echo
    echo "## Rules for your role"
    # `tr 'a-z' 'A-Z'` and NOT `tr 'a-z-' 'A-Z_'` (fixed 2026-08-12, on C6's first real drive).
    # The old set also mapped `-` → `_`, so `test-author` became `TEST_AUTHOR` while the heading in
    # ROLE_PROMPTS.md is `## TEST-AUTHOR`. The sed range matched nothing and the brief shipped with an
    # EMPTY "Rules for your role" section — silently, since an empty range is not an error. Only the
    # hyphenated role was affected, which is the test-author: the one role whose rules are the TDD
    # discipline itself (write RED, never implement). implementer and reviewer have no hyphen and were
    # always fine, which is exactly why "the mechanism is proven" was wrong — it was proven on the two
    # roles that could not expose the bug.
    section_of "## $(printf '%s' "$role" | tr 'a-z' 'A-Z')"
    echo
    echo "## When you are done"
    # R7 trips on "unit suite failing", which is what a correct RED commit IS. Routing the test-author
    # through loop-iteration.sh therefore stopped the run on every test-first step — the recipe's own
    # "Never Gate a RED Commit" section, which this line contradicted for every stack. The RED stage is
    # gated by check-scope.sh alone (R6 still enforced, and the driver re-audits scope post-hoc anyway);
    # gating starts at GREEN, where a red suite is a real defect. Upstream candidate.
    # THE STEP TIER WHILE THE STEPS ARE BUILT (1.8.7, M10 §2.1). This line named no mode, so every
    # implementer took loop-iteration's default and ran the FULL gate, whose review clause reads root
    # issues.md for `converged` - and no review round exists before the steps are done, so the tier
    # could not pass. Five M10 implementer rows journalled `GATE: NOT GREEN - cause: review FAIL` over
    # a green step. gate.sh's `step` tier (build, unit, integration, coverage; "STEP-OK", never
    # "PASS") exists for exactly this and the driver's own lost-JSON path already used it; the brief
    # is what did not. Post-review (no step left to derive) the full gate is still the right one: the
    # milestone lands on it. The test-author re-asked for an OPEN step is told the same tier, because
    # the section above says "run the step gate" and this line used to say `red`.
    if [ "$role" = test-author ] && [ -n "$osr" ]; then
      echo "Run: \`scripts/check-scope.sh $role\`, report its output verbatim, commit your fix, then run"
      echo "\`scripts/loop-iteration.sh $role $MS \"<one-line note>\" step\` and report ITS output verbatim."
      echo "MODE=step runs the step tier (build, unit, integration, coverage): the fix is not a RED, and the"
      echo "milestone tiers (mutation, review, e2e) are not the step's to pass."
    elif [ "$role" = test-author ]; then
      echo "Run: \`scripts/check-scope.sh $role\`, report its output verbatim, commit your RED, then run"
      echo "\`scripts/loop-iteration.sh $role $MS \"<one-line note>\" red\` and report ITS output verbatim."
      echo "MODE=red journals the RED and runs no gate: R7 trips on a failing unit suite, which is what"
      echo "your RED commit IS, and an unjournalled RED hands its own churn to the next implementer."
    elif [ "$role" = implementer ] && build_phase; then
      echo "Run: \`scripts/loop-iteration.sh $role $MS \"<one-line note>\" step\` and report its output verbatim."
      echo "MODE=step runs the tiers a step is measured on (build, unit, integration, coverage) and stops:"
      echo "mutation, review and e2e are the MILESTONE's proof and run once the steps are built. The full"
      echo "tier's review clause cannot pass before a review round exists, so a full gate here says"
      echo "\"NOT GREEN - cause: review FAIL\" over a green step and teaches nobody anything."
    elif [ "$role" = reviewer ] || [ "$role" = verifier ]; then
      # THE FAST TIER FOR THE READERS (1.8.9, M14 §2.2): a reviewer's deliverable is its artifact,
      # and the full gate's e2e (~9 minutes on TT-4348) outran the CLI's foreground tool window; the
      # reviewer that would not claim a gate it had not seen finish answered blocked with no
      # findings, and the dimension was re-run. What the tree proves is the writing roles' to
      # journal; the reader journals that it ran.
      echo "Run: \`scripts/loop-iteration.sh $role $MS \"<one-line note>\" fast\` and report its output verbatim."
      echo "MODE=fast runs the unit tier on the affected tests only: your deliverable is the artifact, and the"
      echo "milestone's own gate is the writing roles' to prove - a full gate here outruns your tool window."
    else
      echo "Run: \`scripts/loop-iteration.sh $role $MS \"<one-line note>\"\` and report its output verbatim."
      # POST-REVIEW, THE FINDINGS AND NOTHING ELSE (1.8.9, M14 §2.4).
      [ "$role" = implementer ] && {
        echo "The full gate is the milestone's; a tier it fails for a cause OUTSIDE your [YOURS] findings"
        echo "(a tool version, a container image, a meter another milestone excluded) is a \`blocked\` answer"
        echo "naming the cause, not yours to chase - the driver routes it."; }
    fi
    # IN THE FOREGROUND, said explicitly because a live test-author did the other thing: it
    # backgrounded this call and ended its turn with "I'll wait for its completion notification
    # before reporting the final output." Under `claude -p` that notification can never arrive — the
    # turn IS the process. The gate kept running after the role was gone, its integration tier wrote
    # `.coverage.<host>.<pid>.<rand>` into the tree, and the driver's post-hoc audit read those as a
    # scope violation. Cost: 485s and $3.36 of finished, in-scope work left uncommitted, plus a false
    # R6 that stopped the run.
    #
    # Gitignoring that artifact (install-harness.sh writes the rule) removes THAT file from the race.
    # It does not remove the race: a role that exits while its own gate runs has not been gated at
    # all, so its journal entry, its breaker evaluation and its RED verification simply never happen.
    # This line is the fix for that, and it is worth more than the artifact one.
    echo "Run it in the FOREGROUND and wait for it. Do NOT background it and do NOT end your turn"
    echo "while it runs: under \`claude -p\` your turn is the process, so a backgrounded gate is an"
    echo "ABANDONED gate — it keeps writing into the tree after you are gone, nothing journals the"
    echo "iteration, and the driver's scope audit fails on whatever it wrote."
  } > "$brief"

  S_OUT="$LOGDIR/role-$MS-$role${DIM:+-$DIM}-$(count_all).json"
  # Resolved BEFORE the dry-run branch so the rehearsal prints the command that would actually run.
  # A dry run that omits a flag the real path adds is a rehearsal of a different command, and this
  # driver's entire spend guard rests on the operator reading that line before typing --yes.
  local eff; eff="$(effort_for "$role")"; S_EFF=""; [ -n "$eff" ] && S_EFF="--effort $eff"
  S_CAPFLAG=""; [ -n "$cap" ] && S_CAPFLAG="--max-budget-usd $cap"; S_SCH="$(schema_flag "$role")"; S_MODEL="$model"
  if [ "$DRY" = 1 ]; then
    echo "  DRY RUN — would spawn:"
    echo "    cat $brief | claude -p --model $model $S_EFF $S_CAPFLAG ${S_SCH:+--json-schema <schemas/$(schema_for "$role").json>} $CLAUDE_FLAGS"
  fi
  return 0; }
# PROMPT ON STDIN, never as a positional argument. `--mcp-config` and `--allowedTools` are
# VARIADIC, so a trailing positional prompt is swallowed as another value — observed live:
# "MCP config file not found: <the prompt text>". stdin cannot be eaten by a preceding flag.
# BACKGROUNDED so the driver can beat while it waits (and, in a parallel round, launch the next
# dimension); the caller's `wait` yields the CLI's own exit status, so `rc` means what it always did.
spawn_launch(){
  # shellcheck disable=SC2086
  LOOP_DRIVER=1 LOOP_STEPS="${STEPS:-}" claude -p --model "$S_MODEL" $S_EFF $S_CAPFLAG $S_SCH $CLAUDE_FLAGS < "$S_BRIEF" > "$S_OUT" 2>&1 &
  S_PID=$!; }
spawn(){ local role="$1" model="$2" t0 t1 rc head0 cpid out
  spawn_brief "$role" "$model" || return $?
  [ "$DRY" = 1 ] && return 0
  t0=$(date +%s)
  # HEAD before the role runs — the base for the post-hoc scope audit below. Without it there is
  # nothing to diff against, because the role commits its own work.
  head0="$(git rev-parse HEAD 2>/dev/null || echo HEAD)"
  spawn_launch; cpid="$S_PID"; out="$S_OUT"; inflight_mark "$cpid" "$role"
  # The trap forwards INT/TERM to the role, because a driver that dies while its role keeps writing
  # into the same tree is how an ungated commit gets attributed to whoever runs next. Two honest
  # limits, both verified rather than assumed: it kills the CLI process, not anything the role itself
  # started (an orphaned gate is still possible — that is why the brief forbids backgrounding one),
  # and a driver launched as a BACKGROUND job of a non-interactive shell inherits SIGINT as SIG_IGN,
  # so `kill -INT` on it does nothing. Ctrl-C at a terminal and `kill -TERM` both work; verified by
  # execution against a stub CLI, after a first test "proved" the opposite through that SIG_IGN rule.
  # The message names the result file and the exact `record --from` line, so the spend of a role you
  # just killed lands in the ledger instead of being lost.
  trap 'kill '"$cpid"' 2>/dev/null; inflight_clear; echo "  killed role pid '"$cpid"' — its result file is '"$out"'; record it with: loop-driver.sh record '"$MS $role"' fail <secs> --from '"$out"'" >&2; exit 130' INT TERM
  wait_with_heartbeat "$cpid" "$role" "$t0"; rc=$?
  trap - INT TERM
  t1=$(date +%s)
  # Collected, THEN cleared: the scope audit is inside spawn_collect (1.8.7, M10 §2.4).
  spawn_collect "$role" "$model" "$rc" "$t0" "$t1" "$out" "$head0"; rc=$?
  loop_keep "$S_BRIEF" "$out"
  inflight_clear
  return $rc; }
# What a finished review role's structured output becomes on disk (1.8.0): a reviewer's findings are
# RENDERED to the artifact its brief dictated (S_ART) under r<round>-<dim>-<n> ids, its optional
# verifications and a verifier's verdicts are applied IN PLACE to the artifacts that raised the
# findings, and a verifier leaves an informational `_verification.md` record. lib/review_findings.py
# does the writing; absent (a repo installed before it existed) nothing is rendered and the prose
# artifact the role wrote is what `consolidate` reads, as before.
# ...READ THROUGH THE ONE READER (1.8.8 review pass 6, correctness major): a third parse of the result
# envelope stopped at `structured_output` while result_field and review_findings.py fall back to the
# `result` string. A blocked reviewer in that shape was owed on disk and never `owed` in the ledger, so
# RO could not fire and the dimension was re-run without bound (six spawns, RV warning over one round).
reviewed_nothing(){ [ "$(result_field "$1" findings)" = "[]" ]; }
render_role_output(){ local role="$1" out="$2" art="${S_ART:-}" arts rnd lbl
  [ -f "$HERE/lib/review_findings.py" ] && [ -n "$art" ] || return 0
  case "$role" in
    reviewer)
      rnd="$(round_of "$art")"
      python3 "$HERE/lib/review_findings.py" render "$out" "$art" "$MS" "$rnd" "${DIM:-}" 2>&1
      arts="$(ms_artifacts | grep '_issues\.md$' | sed 's|^|review-results/|')"
      # shellcheck disable=SC2086
      python3 "$HERE/lib/review_findings.py" apply "$out" "round $rnd" $arts 2>&1;;
    verifier)
      lbl="verify $(printf '%s' "$art" | sed -nE 's/.*_verify([0-9]+)_.*/\1/p')"
      arts="$(ms_artifacts | grep '_issues\.md$' | sed 's|^|review-results/|')"
      # shellcheck disable=SC2086
      python3 "$HERE/lib/review_findings.py" apply "$out" "$lbl" $arts 2>&1
      python3 "$HERE/lib/review_findings.py" verification "$out" "$art" "$MS" "$lbl" 2>&1;;
  esac; return 0; }
# $8/$9: an audit already run for a whole parallel round (its rc and output), so every dimension's
# row reads the same verdict. Absent, the audit runs here, against this role alone.
spawn_collect(){ local role="$1" model="$2" rc="$3" t0="$4" t1="$5" out="$6" head0="$7" audit_rc="${8:-}" scope_out="${9:-}"
  # ── POST-HOC SCOPE AUDIT (added 2026-08-12, on C6's first real drive) ──────────────────────
  # R6 was SELF-REPORTED and therefore not a breaker at all. `check-scope.sh` only ran inside
  # `loop-iteration.sh`, which the ROLE invokes when it decides it is done, against the tree AT THAT
  # MOMENT. Observed live on C6 step 1: the test-author committed its RED, ran loop-iteration.sh
  # (which passed, correctly — it was in scope at that instant), then kept going and committed
  # `src/cis/communication_event/domain/owner.py`. One ledger row, two commits, the second of them
  # production code written by the role forbidden to write it, and nothing recorded a violation.
  # Role separation was the main argument for driving a security milestone through this loop; on
  # that evidence it was advisory.
  #
  # The audit belongs to the DRIVER, runs after the subprocess is gone, and covers everything the
  # role did between $head0 and now — commits included, not just the dirty tree. check-scope.sh
  # already takes a base ref as $2, so this is the existing breaker finally given the right base
  # rather than new logic. It runs BEFORE the ledger append below, so the driver's own ledger write
  # is never attributed to the role it is recording.
  local outcome
  if [ -z "$audit_rc" ]; then
    if scope_out="$("$HERE/check-scope.sh" "$role" "$head0" 2>&1)"; then audit_rc=0; else audit_rc=1; fi
  fi
  if [ "$audit_rc" = 0 ]; then outcome="$([ "$rc" = 0 ] && echo pass || echo fail)"; else outcome=r6; fi
  # Cost and tokens are recorded because they were the one thing nothing measured. LOOP_STATE
  # counted gate calls; the review rounds that actually spend the money left no trace anywhere.
  local tok cost status note rsig="" lost="" subtype steer_col="" gate_col="" v
  tok="$(usage_tokens "$out")"; cost="$(usage_cost "$out")"
  # THE BUDGET-CAPPED ROLE (1.8.6, M9 §2.6): the CLI ended the turn at `--max-budget-usd` after the
  # role had moved HEAD. Its formatter may not have run (step 7: two spotless hunks, a hand commit);
  # the driver runs the adapter's format check now, formats and commits when it refuses, so the gate
  # the lost-JSON path runs below - and every reviewer after it - reads a formatted tree. The driver
  # row for that commit is appended AFTER the role's row, with `nostep` in column 13.
  FORMAT_ROW=""; FORMAT_DIRTY=""; LOST_JSON_GATE=""
  subtype="$(result_top "$out" subtype)"
  if [ "$subtype" = error_max_budget_usd ] && [ "$audit_rc" = 0 ] \
     && [ "$(git rev-parse HEAD 2>/dev/null)" != "$(git rev-parse "$head0" 2>/dev/null)" ]; then
    case "$role" in test-author|implementer) budget_capped_format "$role" || true;; esac
  fi
  # The role's OWN verdict and last words (structured_output), into columns 11 and 12. A role that did
  # not finish gets a signature over the findings it was handed, so "the same role, the same findings,
  # the same HEAD, and still nothing to do" is a value the sequencer can refuse to re-buy.
  status="$(result_field "$out" status)"; note="$(result_field "$out" message | tr '\t\n\r' '   ' | utf8_head 200)"
  # THE CLI THAT NEVER RAN THE ROLE (1.8.7, M10 §2.5). An error envelope (`is_error: true`) with ZERO
  # tokens and HEAD where the spawn left it is not the role failing: the API refused the request - the
  # account's spend limit ("You have hit your individual spend limit ... resets 2pm"), an outage, an
  # `api_error` terminal reason. M10 wrote three `fail` rows for one such stop, RF fired twice on them,
  # and the driver acked both by hand. The row is `api`, every window skips it (rows_since_ack,
  # role_rows), and the run STOPS with the CLI's own words: a limit does not clear by retrying, and
  # the two M10 retries that proved it cost two seconds each and a breaker trip. A partial run that hit
  # the limit AFTER spending (tokens > 0) stays `fail`: it did consume, and its tree may have moved.
  API_REFUSED=""
  # ...AND ONLY AN ERROR ENVELOPE (1.8.7 review, minor): the CLI wrote `is_error: true`. A crash
  # with no JSON at all - `command not found`, a signal - is the `fail` it always was, re-asked by
  # the sequencer; "relaunch when the limit clears" would be the wrong advice for it.
  if [ "$audit_rc" = 0 ] && [ "$(result_top "$out" is_error)" = true ] && [ "${tok:-0}" = 0 ] \
     && [ "$(git rev-parse HEAD 2>/dev/null)" = "$(git rev-parse "$head0" 2>/dev/null)" ]; then
    outcome=api; status=""; API_REFUSED=1
    note="$(result_top "$out" result | tr '\t\n\r' '   ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | utf8_head 200)"
    case "$note" in *[![:space:]]*) :;; *) note="$(result_top "$out" subtype)";; esac
    case "$note" in *[![:space:]]*) :;; *) note="the CLI exited $3 with an error envelope and no result text";; esac
    note="$(printf 'API refused the invocation (0 tokens, HEAD unmoved): %s' "$note" | utf8_head 200)"
  fi
  # THE TREE OVER THE WRAPPER (1.8.5, see lost_json_green): an error exit or envelope over a landed,
  # green HEAD is a pass whose result JSON was lost, and the row says so. HEAD unmoved stays fail.
  if [ -z "$API_REFUSED" ] && { [ "$outcome" = fail ] || [ "$(result_top "$out" is_error)" = true ]; }; then
    if [ "$audit_rc" = 0 ] && lost_json_green "$role" "$head0"; then
      outcome=pass; status=done; rc=0
      lost="result JSON lost: ${subtype:-exit $3}; $(git rev-parse --short "$head0" 2>/dev/null)..$(git rev-parse --short HEAD 2>/dev/null) landed in the $role scope and $LOST_JSON_WHY - judged from the tree"
      case "$note" in *[![:space:]]*) note="$lost; $note";; *) note="$lost";; esac; note="$(printf '%s' "$note" | utf8_head 200)"
    fi
  fi
  # A BLOCKED WRITING ROLE'S UNCOMMITTED, IN-SCOPE, GREEN WORK IS LANDED AS wip(<role>) (1.8.9,
  # TT-4348 M12 §2.3/2.4). The step 5 implementer answered blocked with a passing src/main left in
  # the tree; the next spawn refused on the dirty tree (exit 4), the work had no row, and the step
  # counter could not see it until it was committed and recorded by hand. The audit already says
  # the files are the role's; the STEP tier decides whether they are worth keeping: green, the
  # driver commits them and the row carries the verdict; red, they stay where the role left them
  # and the next spawn refuses as before (a red tree is the operator's to read).
  WIP_ROW=""
  if [ "$status" = blocked ] && [ "$audit_rc" = 0 ] && [ -z "$API_REFUSED" ]; then
    case "$role" in test-author|implementer) wip_commit "$role" "$note" || true;; esac
  fi
  [ -n "$status" ] && [ "$status" != done ] && rsig="$status:$role:$(findings_sig "$role")"
  # Column 13 (1.8.5): how this spawn was chosen. `steered` = `run --role`; `intent` = a verifier
  # review_mode picked by intent (a steered cycle's verify). review_mode reads both.
  if [ "${steered:-}" = 1 ]; then steer_col=steered
  else case "$role:${rmode:-}" in verifier:"verify:by intent"*) steer_col=intent;; esac; fi
  # Column 14 (1.8.6): the gate verdict the driver could read for a writing role's row - the gate.sh
  # run the lost-JSON path made, else the role's own journal entry at HEAD. Empty = nothing measured.
  # The STEP's verdict (1.8.7): a red on mutation, review or e2e alone is green here, because those
  # are milestone tiers the step is not measured on (journal_step_verdict).
  # ...AND NEVER OVER A TREE THE COMMIT DOES NOT DESCRIBE (1.8.6 review, major 2): with the
  # formatter's output left in the tree, gate.sh measured the working tree and the stamp would claim
  # that verdict for HEAD. Unmeasured is the honest answer, and the step counter reads it as before.
  case "$role" in test-author|implementer)
    if [ -n "$FORMAT_DIRTY" ]; then gate_col=""
    elif [ -n "$LOST_JSON_GATE" ]; then gate_col="$LOST_JSON_GATE"
    else v="$(journal_step_gate_at "$role" "$(git rev-parse --short HEAD 2>/dev/null)")"; case "$v" in green|red) gate_col="$v";; esac; fi;;
    # `owed` for a reviewer that answered blocked (or no_work/refuted, read as blocked) with an EMPTY
    # findings[] (1.8.8, M11 §2.7): it did not review, the round arithmetic skips the row and
    # round_missing_dims owes its dimension. A blocked reviewer WITH findings reviewed something and
    # is a row like any other; a result with no findings[] at all is the legacy prose shape.
    reviewer) case "$status" in blocked|no_work|refuted) reviewed_nothing "$out" && gate_col=owed;; esac;; esac
  # Column 15 (1.8.8): the step the brief named, so token_budget(role, step) can price the row.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$MS" "$role" "$model" \
    "$outcome" "$(git rev-parse --short HEAD 2>/dev/null||echo none)" \
    "$((t1-t0))" "$tok" "$cost" "$rsig" "$status" "$note" "$steer_col" "$gate_col" "${STEP:-}" >> "$LEDGER"
  echo "  → $((t1-t0))s · ${tok} tok · \$${cost}${status:+ · $status}${gate_col:+ · gate $gate_col} · log $out"
  [ -n "$lost" ] && echo "  ($lost; recorded as pass)"
  [ "$gate_col" = red ] && [ "$outcome" = pass ] && echo "  (the gate at HEAD is RED: the row is not a done step; the RED's owner is asked next, with the cause)"
  # The driver's own row for the wip commit (1.8.9): the landing is the ROLE's (its row's sha is
  # the wip commit, so the step counter sees it); this row only says who typed `git commit`.
  [ -n "$WIP_ROW" ] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$MS" driver - pass \
    "$(git rev-parse --short HEAD 2>/dev/null||echo none)" 0 0 0 "" "" "$WIP_ROW" nostep "" >> "$LEDGER"
  # The driver's own row for the formatting commit (1.8.6): a hand commit, never a step.
  [ -n "$FORMAT_ROW" ] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$MS" driver - pass \
    "$(git rev-parse --short HEAD 2>/dev/null||echo none)" 0 0 0 "" "" "$FORMAT_ROW" nostep "" >> "$LEDGER"
  [ -n "$note" ] && echo "  ↳ $role: $note"
  if [ -n "$API_REFUSED" ]; then
    echo "  ✗ the API refused this invocation before the role ran: the row is \`api\` and counts in no window (not a failure, not a stall, not a round); the run stops here - relaunch once the limit or the outage has cleared. No ack is owed." >&2
    return 5
  fi
  render_role_output "$role" "$out"
  # A scope violation stops the run and is NOT downgraded by a zero exit code from the role: a role
  # that wrote outside its scope and reported success is exactly the case this exists to catch. The
  # ledger records `r6` rather than pass/fail, so the violation survives in the evidence and not
  # only on stdout.
  if [ "$outcome" = r6 ]; then
    printf '%s\n' "$scope_out" >&2
    echo "  ✗ R6: '$role' wrote outside its write-scope between $head0 and HEAD — run stops." >&2
    # ATTRIBUTION, printed rather than assumed. The audit diffs $head0..HEAD, so it reports whatever
    # landed in that window — including commits made OUTSIDE the loop while the role was running.
    # That is not hypothetical: on C6 a human committed driver-owned files mid-run and the audit
    # named the REVIEWER for all four, a false R6 on work it never touched. The window's commits are
    # listed here so the reader attributes in one glance instead of trusting the role name in the
    # heading. Narrowing the audit to dodge this is NOT the fix — the implementer's real violation
    # that same day was a driver-owned path (`alembic/*`), so any rule that excused those would have
    # excused the true positive too.
    echo "    commits in this window (a role's own work should be ALL of them):" >&2
    git log --oneline "$head0..HEAD" 2>/dev/null | sed 's/^/      /' >&2 || true
    echo "    Do not commit by hand while a role is in flight — it corrupts this attribution." >&2
    echo "    Revert what the ROLE committed outside its scope, then re-run the OWNING role." >&2
    return 6
  fi
  return $rc; }

# ── the parallel round (1.8.0) ───────────────────────────────────────────────
# Every brief first, then every launch, ONE wait, then every collect in dimension order. Briefs
# before launches, because `spawn_brief`'s dirty-tree refusal reads the tree and a reviewer already
# running would be writing into it. One scope audit for the round, after the last reviewer exits:
# three reviewers write into one tree, so a stray path cannot be attributed to a dimension from the
# diff, and every row of the round records the same verdict — the paths are printed either way.
# Rows are appended in the order the round was DECLARED, whatever order the reviewers finished in,
# so `review_round_state` and `review_base` read the round exactly as a sequential one.
fanout_parallel(){ local rnd="$1" esc_note="$2" d n=0 i rc t0 t1 head0 audit_rc scope_out src=0 p m
  P_PID=(); P_OUT=(); P_DIM=(); P_ART=(); P_BRIEF=(); P_MODEL=()
  # THE MODEL IS RESOLVED ONCE, AT BRIEF TIME, and travels with the dimension: the brief's cap and
  # its "capped at $N" line were priced for it. A second `model_for reviewer` in the launch loop
  # answered the DELTA tier as soon as an earlier dimension's reviewer had written its artifact -
  # review_round_now moved on under the loop - so a later dimension launched at the delta model with
  # a brief priced for the full tier, and header and ledger disagreed with the brief.
  for DIM in $(dims_to_run); do
    m="$(model_for reviewer)"
    spawn_brief reviewer "$m" || { rc=$?; DIM=""; return $rc; }
    P_DIM[$n]="$DIM"; P_ART[$n]="$S_ART"; P_BRIEF[$n]="$S_BRIEF"; P_OUT[$n]="$S_OUT"; P_MODEL[$n]="$m"; n=$(( n + 1 ))
  done
  t0=$(date +%s); head0="$(git rev-parse HEAD 2>/dev/null || echo HEAD)"
  i=0; while [ "$i" -lt "$n" ]; do
    DIM="${P_DIM[$i]}"; S_BRIEF="${P_BRIEF[$i]}"; S_OUT="${P_OUT[$i]}"; S_MODEL="${P_MODEL[$i]}"
    spawn_launch; P_PID[$i]=$S_PID; inflight_mark "$S_PID" "reviewer[$DIM]"
    echo "── $MS · invocation $(( $(count_all) + i + 1 )) · reviewer[$DIM] · $S_MODEL · round $rnd$esc_note · pid $S_PID ──"
    i=$(( i + 1 ))
  done
  DIM=""
  trap 'for p in "${P_PID[@]}"; do kill "$p" 2>/dev/null; done; inflight_clear; echo "  killed the round'"'"'s reviewers — result files: ${P_OUT[*]}; record each with: loop-driver.sh record '"$MS"' reviewer fail <secs> --from <file>" >&2; exit 130' INT TERM
  wait_group_with_heartbeat "reviewer×$n" "$t0" "${P_PID[@]}"
  trap - INT TERM
  t1=$(date +%s)
  # The round's audit runs here, before the marker clears below (1.8.7, M10 §2.4).
  if scope_out="$("$HERE/check-scope.sh" reviewer "$head0" 2>&1)"; then audit_rc=0; else audit_rc=1; fi
  inflight_clear
  i=0; while [ "$i" -lt "$n" ]; do
    DIM="${P_DIM[$i]}"; S_ART="${P_ART[$i]}"
    wait "${P_PID[$i]}"; rc=$?
    loop_keep "${P_BRIEF[$i]}" "${P_OUT[$i]}"
    echo "──   $DIM · round $rnd · collected ──"
    # THE MODEL IT WAS SPAWNED WITH, not `model_for` again. By the first collect every reviewer's prose
    # artifact is on disk and no row of the round is in the ledger yet, so review_round_now reads the
    # round as done and model_for prices the NEXT round's delta tier: round 1's first row said sonnet
    # while its header and its result file said opus (TT-4348 M6, one row wrong in every cost-by-model
    # read of the ledger). The row records what was launched (1.8.4).
    spawn_collect reviewer "${P_MODEL[$i]}" "$rc" "$t0" "$t1" "${P_OUT[$i]}" "$head0" "$audit_rc" "$scope_out"; rc=$?
    [ "$rc" = 6 ] && src=6
    [ "$rc" = 5 ] && [ "$src" != 6 ] && src=5
    [ "$rc" = 0 ] || [ "$rc" = 6 ] || [ "$rc" = 5 ] || echo "  (reviewer[$DIM] exited non-zero — recorded as fail)"
    i=$(( i + 1 ))
  done
  DIM=""; S_ART=""
  [ "$src" = 6 ] && echo "  (R6 in the round — every dimension's row records it; the paths are above)"
  return $src; }

# ── consolidate: the round's artifacts -> root issues.md ─────────────────────
# A FUNCTION, because `run` has to call it between rounds and the subcommand is not reachable from
# there. See the `run` loop for what that cost while this body lived only under `consolidate)`.
round_of(){ local n; n="$(printf '%s' "$1" | sed -nE 's/.*_round([0-9]+)_.*/\1/p')"; echo "${n:-1}"; }
# A FUNCTION, not a heredoc inside `$(...)`. Bash's command-substitution parser does not honour
# the quoted heredoc delimiter inside `$( )`: a single apostrophe in the Python below — in a
# COMMENT — opens a quote bash never closes, and the whole script dies with "unexpected EOF
# while looking for matching '". The loop this was ported from had the heredoc inline and
# parsed only because its Python happened to contain no apostrophe. At function level the
# heredoc is parsed normally and the Python can say whatever it likes.
_doc_only_findings(){ python3 - "$@" <<'PYEOF'
import re, sys
cap = int(sys.argv[1]); bad = []
FIND = re.compile(r"\[(?:blocker|major)\]"
                  r"|^\s*-\s+(?:blocker|major)[^a-z]"
                  r"|^\s*[#>*_\-]*\s*(?:blocker|major)\s*:", re.I)
DONE = re.compile(r"^\s*-\s*\[\s*x\s*\]", re.I)
NONE = re.compile(r"(?:blocker|major)\s*:\s*(?:none|0)(?:[^0-9]|$)", re.I)
HEAD = re.compile(r"^#+\s")
CLOSED = re.compile(r"(^|[^a-z])(resolved|closed|fixed)([^a-z]|$)", re.I)
NEGATED = re.compile(r"(^|[^a-z])(not|never|yet|open|outstanding|pending)([^a-z]|$)", re.I)
PATH = re.compile(r"[A-Za-z0-9_./-]+\.(?:py|ts|tsx|js|jsx|java|kt|go|rs|rb|sh|bash|yml|yaml|toml|"
                  r"json|xml|gradle|cfg|ini|sql|md|txt|rst)")
DOC = re.compile(r"^(?:docs/|doc/|specs/|spec/|review-results/|[^/]*\.(?:md|txt|rst)$)")
for name in sys.argv[2:]:
    m = re.search(r"_round(\d+)_", name)
    if not m or int(m.group(1)) <= cap:
        continue
    try:
        lines = open("review-results/" + name, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    sect = ""
    for i, line in enumerate(lines):
        cur = sect
        if HEAD.match(line):
            sect = line
        if not FIND.search(line) or DONE.match(line) or NONE.search(line):
            continue
        if CLOSED.search(cur) and not NEGATED.search(cur):
            continue
        # The finding's own line plus its block, to the next finding or heading.
        block = [line]
        for nxt in lines[i + 1:]:
            if HEAD.match(nxt) or FIND.search(nxt):
                break
            block.append(nxt)
        paths = set(PATH.findall(" ".join(block)))
        if paths and all(DOC.match(p) for p in paths):
            bad.append((name, line.strip()[:110]))
for name, head in bad:
    print(f"{name}\t{head}")
PYEOF
}
consolidate_ms(){
  # THE MISSING STEP. The reviewer writes `review-results/*_issues.md` (its whole write-scope), while
  # `review_converged()` and `gate.sh`'s review gate BOTH read root `issues.md` — which is
  # DRIVER_SCOPE, so no reviewer can ever create it. Nothing in the harness bridged the two, so the
  # review could never converge, RV exhausted its budget every time, and the review gate stayed
  # PENDING for ever. Measured on C6: four reviewer spawns, $17.32, ending on RV with no verdict any
  # gate could read. In the prose-driven loop a human wrote this file by hand.
  #
  # EVERY ROUND, and this reverses the "latest round only" rule the first version of this subcommand
  # shipped with an hour earlier. That rule was wrong, and C6 showed it immediately: round 1's F1-F5
  # — two of them blockers, all in `src/` — landed in a "superseded" section and stopped reaching the
  # gate, while round 3 only referred to them as "untouched". The gate would have scored a clean
  # review over a milestone with two open blockers against it. A consolidation rule whose failure
  # mode is a FALSE GREEN is not a trade-off, it is the bug.
  #
  # The reasoning behind the old rule — "a round-1 artifact keeps its blockers written as blockers
  # for ever, so the count can never reach zero" — was a misreading of `review_scan`. It already has
  # the affordance: a finding marked `- [x]`, or moved under a heading that reads resolved/closed/
  # fixed, is not counted. Convergence is therefore reached by RESOLVING findings in place, in the
  # artifact that raised them, which also leaves the record of what was fixed where it was reported.
  # Accumulate and mark, never drop.
  local arts maxr sel r f verdict s
  arts="$(ms_artifacts | grep '_issues\.md$' || true)"
  [ -n "$arts" ] || { echo "loop-driver: no review artifacts for $MS in review-results/" >&2; return 1; }
  maxr=0; for f in $arts; do r="$(round_of "$f")"; [ "$r" -gt "$maxr" ] && maxr="$r"; done
  # Ordered by round so the file reads chronologically; every artifact is included.
  sel=""; r=1
  while [ "$r" -le "$maxr" ]; do
    for f in $arts; do [ "$(round_of "$f")" = "$r" ] && sel="$sel $f"; done
    r=$(( r + 1 ))
  done
  # Converged only if every artifact OF THE LATEST ROUND says so in its own words. The driver
  # aggregates; it does not judge — `gate.sh` independently counts the open findings in what is
  # written here, so a wrong aggregation cannot manufacture a green review.
  #
  # THE LATEST ROUND, NOT EVERY ROUND, and the difference decides whether a milestone can ever close.
  # Judging every round made convergence UNREACHABLE the moment artifact filenames carried the round
  # number: a round that genuinely found defects writes "open" when it is written, that sentence
  # stays true for ever, and no later work changes what round 1 honestly recorded at the time.
  # Measured (TT-4348 M2): twelve artifacts over four rounds, every finding resolved or refuted,
  # `review_scan` counting 0 open — and the aggregate still read NOT CONVERGED, with no route to
  # green that did not involve rewriting nine reviewers' verdicts by hand. Loops that wrote ONE
  # artifact per milestone and overwrote it each round never hit this, because "every artifact" and
  # "the latest round" were the same set.
  #
  # The safety property does not rest on this loop: `review_scan` counts open blocker/major lines
  # across the WHOLE consolidated file — every round of it — and `gate.sh` requires that count to be
  # zero independently of the token below. A stale round-1 blocker still fails the gate while round 5
  # says converged. This fixes only the verdict token, which asks "has the most recent review come
  # back clean" — a question only the most recent review could ever answer.
  # THE ROUNDS' ARTIFACTS JUDGE (1.8.5): a `_driver_issues.md` steer artifact is included in $sel
  # (its findings count, and reach the brief) but is not a dimension's report - it never carries a
  # verdict of its own, and it may sit at a round that has not run yet. With no round on disk at all
  # the verdict is NOT CONVERGED: a steer is not a review.
  local latest missing d dims_expected quorum_short maxrr
  maxrr=0; for f in $arts; do driver_artifact "$f" && continue; r="$(round_of "$f")"; [ "$r" -gt "$maxrr" ] && maxrr="$r"; done
  latest=""; for f in $arts; do driver_artifact "$f" && continue; [ "$(round_of "$f")" = "$maxrr" ] && latest="$latest $f"; done
  # QUORUM. A round converges only if EVERY declared dimension actually reported. Without this the
  # verdict is computed over whatever artifacts happen to exist, and two ways of producing none are
  # indistinguishable from outside: a reviewer writes its report into its own $REVIEW_WT worktree and
  # it never comes back, or a reviewer decides it has nothing to say and writes nothing at all.
  # Measured (TT-4348 M2, round 7): two of three dimensions left their reports in
  # tddloop-review-wt-<ms>-<dim>/review-results/ and neither reached the tree; consolidate read the
  # ONE artifact that returned and reported the whole round CONVERGED. It was right by luck — both
  # stranded files said converged — but a blocker in either would have gated the milestone green with
  # an unread blocker against it, which is the exact false green this clause exists to prevent.
  dims_expected="$(printf '%s\n' "${REVIEW_DIMENSIONS:-}" | grep -c '[^[:space:]]' 2>/dev/null || echo 0)"
  if [ "${dims_expected:-0}" -gt 1 ]; then
    missing=""
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      printf '%s\n' $latest | grep -q "_${d}_issues\.md$" || missing="$missing $d"
    done <<EOF
$(printf '%s\n' "$REVIEW_DIMENSIONS")
EOF
    [ -n "$missing" ] && {
      echo "loop-driver: round $maxrr is missing a report from:$missing - NOT CONVERGED." >&2
      echo "  A reviewer that wrote nothing and one whose artifact never left \$REVIEW_WT look the same" >&2
      echo "  from here. Check tddloop-review-wt-<ms>-<dim>/review-results/ before re-running the round." >&2
      quorum_short=1
    }
  fi
  verdict=CONVERGED
  [ -n "${quorum_short:-}" ] && verdict="NOT CONVERGED"
  [ -n "$latest" ] || { verdict="NOT CONVERGED"; echo "loop-driver: no review round on disk for $MS, only the driver's steer artifact - NOT CONVERGED until a round has run." >&2; }
  for f in $latest; do
    s="$(grep -iE '^[[:space:]]*(#+[[:space:]]*)?\**status\**[[:space:]]*:' "review-results/$f" | head -1 | tr 'A-Z' 'a-z')"
    # Negated forms FIRST, so "not converged" and "not yet closed" can never reach the positive arm.
    case "$s" in
      *"not converged"*|*notconverged*|*"not closed"*|*"not clean"*|*"not yet"*) verdict="NOT CONVERGED";;
      # A reviewer with nothing to report writes it several ways — measured: "converged" and
      # "closed". Both are a verdict on that dimension's own findings. NOT accepted: "open (no
      # findings from this dimension)", which answers a different question (is the MILESTONE's review
      # open) and is also what a reviewer writes while its own findings stand.
      *converged*|*closed*|*clean*) : ;;
      *) verdict="NOT CONVERGED";;
    esac
  done
  # VERDICT FROM DATA (1.8.0). The latest round can read clean while an EARLIER round's finding is
  # still open. `gate.sh` fails that summary anyway — review_scan counts every round — but
  # `review_converged()` read only the token, so `next_role` answered `done` and the landing step
  # then died on the gate. The same shapes review_scan counts, over every artifact included here.
  local stale
  # shellcheck disable=SC2046
  stale="$(python3 "$HERE/lib/review_findings.py" open $(printf 'review-results/%s\n' $sel) 2>/dev/null | awk -F'\t' '{print ($1!="" ? $1 : "prose:" $2)}' | head -5 | tr '\n' ' ')"
  # `${stale}...`, never `$stale…` (1.8.5): bash 3.2 reads the first byte of a multibyte character
  # after a variable name as part of the name, so `$stale…` was "stale\xe2: unbound variable" under
  # `set -u` - inside `run`'s `$(consolidate_ms)` the subshell died before issues.md was written,
  # and the verdict stayed whatever the previous consolidation said. Found by the steer fixture.
  if [ "$verdict" = CONVERGED ] && [ -n "$stale" ]; then
    verdict="NOT CONVERGED"
    echo "loop-driver: round $maxrr reads clean, but blocker/major finding(s) from earlier rounds or the driver's steers are still open (${stale}...) - NOT CONVERGED. Close them in the artifact that raised them (a verify pass does this by id)." >&2
  fi
  # READER 2 of REVIEW_SRC_ONLY_AFTER_ROUND, and the retirement of the deferral-register genre.
  # `return 1`, never `exit` — this is a function, called from `run` after every reviewer round, and
  # an exit here would end the whole drive over a refusal meant to stop one consolidation.
  #
  # A DEFERRAL REGISTER is refused by name. That genre — a hand-written artifact listing what the
  # milestone carries out — restated issues.md from memory and was wrong within a day of being
  # written, naming five findings as open that the previous round had closed. One source of truth:
  # the artifacts the reviewer wrote, consolidated here. What leaves the milestone lives in the
  # TICKET, not in a second register that drifts from the first.
  # ABSENT OR EMPTY IS OFF — see the reviewer brief's copy of this guard. An upgrade must not refuse
  # a consolidation that succeeded before it.
  local _cap _viol
  _cap="${REVIEW_SRC_ONLY_AFTER_ROUND:-}"
  for f in $sel; do
    case "$f" in *_deferrals_issues.md)
      echo "loop-driver: refusing \`$f\`. A deferral register restates issues.md from memory and goes" >&2
      echo "  stale against it. Put what the milestone carries out in its follow-up ticket, and leave" >&2
      echo "  findings marked in the artifacts that raised them. Delete the file and re-run." >&2
      return 1;; esac
  done
  # THE SAME THREE FINDING SHAPES `review_scan` COUNTS, deliberately, and not the ones the loop this
  # came from used. Ported verbatim it looked for `## F<n> — SEVERITY` sections, which is one repo's
  # artifact convention and matches nothing here — a refusal that can never fire, which is the defect
  # class this harness keeps paying for. So: `[blocker]`/`[major]` anywhere, a `- blocker` list item,
  # or a `blocker:` line; minus review_scan's own exemptions (`- [x]`, a resolved/closed/fixed heading
  # that is not negated, and `blocker: none`). If those two ever disagree, a finding gate.sh counts as
  # open is one this arm does not see.
  #
  # ONLY findings whose cited paths are ALL documents are refused. A finding citing no path at all is
  # left alone — it may be about behaviour, and guessing would refuse real work.
  _viol=""
  [ -n "$_cap" ] && _viol="$(_doc_only_findings "$_cap" $sel)" || true
  if [ -n "$_viol" ]; then
    echo "loop-driver: refusing to consolidate — doc-only blocker/major past round $_cap" >&2
    printf '%s\n' "$_viol" | sed 's/^/  /' >&2
    echo "  REVIEW_SRC_ONLY_AFTER_ROUND=$_cap: past that round a finding whose only evidence is a" >&2
    echo "  document is one line under \`## Deferred to ticket\`, not a blocker. Re-file it at that" >&2
    echo "  severity and re-run. A finding about CODE that a document merely describes is not this —" >&2
    echo "  cite the code." >&2
    echo "  A closed milestone whose rounds predate this rule cannot comply and its evidence is not to" >&2
    echo "  be rewritten: re-run once as REVIEW_SRC_ONLY_AFTER_ROUND=99 and say so in the commit." >&2
    return 1
  fi
  { echo "# $MS — consolidated review summary"
    echo
    # The LOOP ID (the ticket, from SPEC_DIR) is REQUIRED, not decoration. `gate.sh`'s review clause
    # fails a summary that does not carry it — "summary from another loop" — because a reused repo
    # inherits the previous loop's issues.md and its stale `Status: CONVERGED`. But `consolidate` is
    # the ONLY writer of this file and never emitted the id, so the gate structurally rejected every
    # summary this driver produced, and `open-milestone-pr.sh` died at `set -e` before printing
    # anything. A landing step that can never succeed, failing silently. Measured on a real
    # milestone: issues.md carried the milestone 97 times and the ticket zero.
    echo "Loop: **$(basename "${SPEC_DIR:-}" | sed -nE 's/^([A-Za-z]+-[0-9]+).*/\1/p')** · Milestone: **$MS** · branch \`$(git rev-parse --abbrev-ref HEAD 2>/dev/null)\` · HEAD \`$(git rev-parse --short HEAD 2>/dev/null)\`"
    echo "Consolidated from \`review-results/\` by \`loop-driver.sh consolidate\` — not written by hand."
    echo
    echo "Status: $verdict"
    echo
    echo "Included — ALL rounds 1..$maxr, every finding still counted until it is marked resolved"
    echo "in the artifact that raised it (\`- [x]\`, or moved under a resolved/closed/fixed heading):"
    for f in $sel; do echo "- \`review-results/$f\`"; done
    for f in $sel; do echo; echo "---"; echo; echo "<!-- verbatim: review-results/$f -->"; cat "review-results/$f"; done
  } > issues.md
  echo "consolidated $MS → issues.md  ($(echo $sel | wc -w | tr -d " ") artifact(s), rounds 1..$maxr) — Status: $verdict"
  return 0; }

case "$CMD" in
status)
  b="$(budget)"; it="$(ms_iters)"; it="${it:-0}"; r="$(review_rounds)"; r="${r:-0}"
  echo "── loop-driver: $MS ──"
  printf '  TDD iterations      %s / %s   (R1, per-milestone — NOT the global number in the journal header)\n' "$it" "$b"
  printf '  role invocations    %s / %s   (RI cap = 3x budget + %sx review budget — the fan-out width %s, floored at the pre-fan-out 2)\n' \
    "$(count_all)" "$(( b * 3 + ${REVIEW_BUDGET:-3} * $(ri_review_mult) ))" "$(ri_review_mult)" "$(review_dim_count)"
  printf '    test-author %s · implementer %s · reviewer %s · verifier %s\n' "$(count_role test-author)" "$(count_role implementer)" "$(count_role reviewer)" "$(count_role verifier)"
  # BOTH numbers, because they answer different questions and printing only the first one made the
  # escalation file report "review rounds: 1" for a milestone whose own review artifact said round 7.
  # Since-ack is what RV gates on (an ack states a cause was fixed, so the rounds before it were not
  # spinning); the milestone total is what a reader needs to judge whether a review is converging at
  # all. A breaker that resets can be right and still be unreadable.
  # `last ack at round N` is rounds_at_last_ack, RA's window start - printed so it is readable (and
  # fixtured: 1.8.8 review pass 4 found its `owed` skip guarded by nothing).
  printf '  review rounds       %s / %s since the last ack   (R11; next round is %s in this milestone; last ack at round %s)\n  verifications       %s       (informational; NOT charged against the round budget)\n' \
    "$r" "${REVIEW_BUDGET:-3}" "$(review_round_now)" "$(rounds_at_last_ack)" "$(review_verifications)"
  printf '  review converged    %s\n' "$(review_converged && echo yes || echo NO)"
  review_converged || printf '  next review         %s\n' "$(review_mode)"
  printf '  models              test-author=%s implementer=%s reviewer=%s search=%s\n' \
    "$(model_for test-author)" "$(model_for implementer)" "$(model_for reviewer)" "$(model_for search)"
  printf '  step                %s\n' "${STEP:-(none) — implementer resolves to the SAFE model; pass --step <id> for the per-step tier}"
  printf '  heartbeat           %ss   (0 = off; a role that prints nothing is indistinguishable from a hung one)\n' "${HEARTBEAT_SECS:-60}"
  s="$(stop_decision "$(stop_reason)" 0)"; [ -n "$s" ] && { echo "  STOP CONDITION MET: $s"; exit 3; }
  echo "  no stop condition met"; exit 0;;

next)
  # REPORTS a stop condition; does not WRITE one. `next` is a query — the driver and the human both
  # run it to ask what happens next — and it used to call `escalate`, which rewrites ESCALATION.md.
  # So asking the question re-created a trip that had just been cleared, and the file's mtime then
  # described the last person who asked rather than the last thing that broke. `run` still escalates,
  # because `run` is the thing that would otherwise proceed.
  s="$(stop_decision "$(stop_reason)" 0)"; [ -n "$s" ] && { echo "STOP CONDITION MET: $s" >&2; exit 3; }
  # With `--role`, answers what THAT invocation would be — the point of asking `next --role x --step y`
  # is to see the model before typing --yes, so it must resolve the same way `run` will.
  if [ -n "$ROLE_ONCE" ]; then r="$ROLE_ONCE"; else r="$(next_role)"; fi
  [ "$r" = done ] && { echo "done — gate and review both green; hand to open-milestone-pr.sh"; exit 0; }
  # `${STEP:+…}${STEP:-…}` looks like an if/else and is not: `:-` substitutes the VALUE when set, so
  # the first live run of this line printed "step 3c3c". Written out, because a two-branch expression
  # that is really one branch plus an echo is the kind of thing that reads correct for ever.
  if [ -n "$STEP" ]; then note=", step $STEP"; else note=", no --step → the SAFE model"; fi
  # A reviewer answer says WHICH review it would be (1.8.0): a full fan-out, a verify pass at the
  # verifier's tier, or nothing at all — the operator reads this before typing --yes.
  if [ "$r" = reviewer ]; then rm="$(review_mode)"; case "$rm" in
    verify:*) note="$note; VERIFY pass at model $(model_for verifier) — ${rm#verify:}";;
    none:*)   note="$note; NO SPAWN — ${rm#none:}";;
    full:*)   note="$note; full round — ${rm#full:}";; esac; fi
  # A verifier answered by the sequencer itself (1.8.4): the owners have answered at HEAD and the
  # open ids have not been re-proved there - the case that used to stop as RD.
  [ "$r" = verifier ] && [ -z "$ROLE_ONCE" ] && note="$note; VERIFY pass - the owners answered no_work at HEAD and no verify pass has re-proved the open ids there (open: $(open_ids | tr '\n' ' '))"
  # Converged, but not at HEAD (1.8.4): the tree moved after the review that converged it.
  review_converged && ! converged_at_head && note="$note; the review converged at $(last_review_sha) but MAIN/TEST scope moved since - the milestone is complete again only after a review at HEAD"
  echo "$r  (model $(model_for "$r")$note${ROLE_ONCE:+, steered by --role})"; exit 0;;

close)
  # `close <MS> <id> "<reason>"` (1.8.9, TT-4348 M13 §2.4): the driver closes a finding its owner
  # refuted and the driver accepts as refuted by design. The rendered artifact says "do not edit by
  # hand", the verifier re-proves fixes and does not adjudicate a refutation, and RD had stopped the
  # run on the one finding nobody could close: the hand edit that followed forgot the status line,
  # and consolidate still read NOT CONVERGED. The reason is appended to the line; the status follows.
  id="${1:?finding id}"; why="${2:?reason}"
  python3 "$HERE/lib/review_findings.py" close "$id" "$why" $(ms_artifacts | grep '_issues\.md$' | sed 's|^|review-results/|') || exit 1
  consolidate_ms; exit $?;;

record)
  # `record <MS> <role> <outcome> [seconds [tokens [cost]]]`, plus `--from <result.json>`.
  #
  # It wrote SEVEN fields into a NINE-column ledger, and always a zero for seconds: every hand-recorded
  # row — which is every KILLED role, the case that matters most — entered the loop's own spend record
  # as free and unmeasured, and `cost` summed it as $0. A killed role is the expensive kind: one
  # measured milestone lost four invocations mid-flight, and the CLI had already written their result
  # files. `--from` reads those files with the SAME reader the spawn path uses, so a killed role's
  # spend lands in the ledger whenever the CLI got as far as writing it.
  #
  # Nothing here invents a number: an unsupplied field stays `0`, which the `cost` report already
  # labels as unmeasured rather than free.
  role="${1:?role}"; outcome="${2:-pass}"; secs="${3:-0}"; tok="${4:-0}"; cost="${5:-0}"
  if [ -n "$FROM" ]; then
    [ -f "$FROM" ] || { echo "loop-driver: --from '$FROM' does not exist" >&2; exit 2; }
    tok="$(usage_tokens "$FROM")"; cost="$(usage_cost "$FROM")"
  fi
  # AN ACK NAMES WHAT IT ACKNOWLEDGES. A bare `record <MS> driver ack` cleared every per-ack breaker
  # and recorded nothing about why — twelve acks in one milestone's ledger, and the same R8 cause
  # acked three separate times with three separate diagnoses written into the journal by hand. Now
  # the signature (from ESCALATION.md, `last`), a verdict and the cause are the row itself, and the
  # breakers read them: a `true` signature that recurs stops as RR quoting this cause; a `false` one
  # is suppressed for the milestone, and two false acks on one breaker id downgrade it to warn-only
  # and print the upstream line — a breaker that trips false twice is a harness defect, not a role's.
  if [ "$outcome" = ack ]; then
    [ -n "$SIG" ] && [ -n "$VERDICT" ] && [ -n "$CAUSE_TXT" ] || {
      echo "loop-driver: an ack names what it acknowledges:" >&2
      echo "  record $MS driver ack --signature <sig|last> --verdict true|false --cause '<what was found>'" >&2
      echo "  --signature last reads the trip's signature from $ESC; true = the cause is fixed; false = the breaker was wrong" >&2; exit 2; }
    if [ "$SIG" = last ]; then
      SIG="$(sed -n 's/^signature: //p' "$ESC" 2>/dev/null | head -1)"
      # The journal's last TRIPPED entry when no file exists, OR when the file's signature already
      # has an ack row (1.8.9; review pass 7, conformance major 3): the driver's `escalate` writes
      # the file on every driver stop and nothing removes it, so after one acked driver stop a
      # role's journalled trip would be acked under the driver's old signature - the trip stays
      # open and the driver's breaker collects a second false ack.
      if [ -n "$SIG" ] && [ -n "$(ack_rows | awk -F'\t' -v s="$SIG" '$10==s')" ]; then
        jsig="$(journal_last_trip_sig)"; [ -n "$jsig" ] && [ "$jsig" != "$SIG" ] && SIG="$jsig"; fi
      [ -n "$SIG" ] || SIG="$(journal_last_trip_sig)"
      [ -n "$SIG" ] || { echo "loop-driver: neither $ESC nor the journal carries a tripped signature for $MS — pass --signature explicitly" >&2; exit 2; }
    fi
    case "$VERDICT" in true|false) :;; *) echo "loop-driver: --verdict is true (cause found and fixed) or false (the breaker was wrong), not '$VERDICT'" >&2; exit 2;; esac
    if [ "$VERDICT" = false ]; then
      id="${SIG%%:*}"; nfalse="$(( $(ack_rows | awk -F'\t' -v b="$id:" 'index($10,b)==1 && $11=="false"' | wc -l | tr -d ' ') + 1 ))"
      if [ "$(breaker_grade "$id")" = hard ] || ! breaker_suppressible "$id"; then
        echo "  note: $id is $([ "$(breaker_grade "$id")" = hard ] && echo 'a HARD breaker' || echo 'a progress breaker (a stall is never a measurement error)') — this ack clears the trip and suppresses nothing" >&2
      elif [ "$nfalse" -ge 2 ]; then
        echo "  $id has now been acked false ${nfalse}× in $MS → warn-only for the rest of this milestone." >&2
        echo "  UPSTREAM CANDIDATE: a breaker that trips false twice is a harness defect. Record it in the recipe's LEARNINGS.md and fix the counter, not the ack (scripts/upstream-report.sh names the change)." >&2
      else
        echo "  $id signature $SIG suppressed for $MS (warn-only). A second false ack on $id downgrades the whole breaker." >&2
      fi
    fi
  fi
  # `--no-step` (1.8.6, M9 §2.6): a hand commit recorded so the scope window stays honest - a
  # formatting pass, a journal fix - is not a step; `nostep` in column 13 keeps it out of the counter.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$MS" "$role" "$(model_for "$role")" \
    "$outcome" "$(git rev-parse --short HEAD 2>/dev/null||echo none)" "$secs" "$tok" "$cost" \
    "$SIG" "$VERDICT" "$(printf '%s' "$CAUSE_TXT" | tr '\t\n\r' '   ' | utf8_head 300)" "${NOSTEP:+nostep}" >> "$LEDGER"
  echo "recorded: $MS $role $outcome  (${secs}s · ${tok} tok · \$${cost})${SIG:+ · $SIG $VERDICT}${NOSTEP:+ · no-step}"; exit 0;;

consolidate)
  consolidate_ms; exit $?;;

steer)
  # A DRIVER STEER AS A FINDING (harness 1.8.5). TT-4348 M8 §2.2: the RA steer named three gaps in
  # LOOP_CLAUDE prose; the brief cap listed four `[YOURS]` ids of gaps 2 and 3, gap 1 was named by no
  # open id, neither writing role worked it, and round 3 raised nine majors saying so ($8.00 for the
  # round, $5.18 for the fix pair). The cap was right; the steer was not a finding. Now it is one:
  # `steer <MS> <role> <path> <severity> "<text>"` appends `s<n>-driver-<k>` (n = the round on disk,
  # k = running) to `review-results/<branch>_<ms>_round<n>_driver_issues.md` in the rendered schema,
  # so `consolidate`, `findings_for` (the brief, the cap, `[YOURS]`), `owns_open_finding`, the
  # verifier (closure by id, evidence required) and review_mode (verify by intent) all see it. The
  # owner is the role given, and the path must be in that role's write-scope - a finding is routed
  # by its path, so a path outside the scope would route it to someone else. The artifact is a
  # findings carrier, not a round: review_rounds and round_missing_dims skip it (driver_artifact).
  # NOT WHILE A ROLE IS IN FLIGHT (1.8.6, M9 §2.3): the artifact this writes is uncommitted until the
  # next spawn, and a role running now would be blamed for it by its own scope audit.
  if s_live="$(inflight_role)"; then
    echo "loop-driver: steer refused: $s_live is in flight - a steer written now is an uncommitted loop artifact the role's scope audit would attribute to it (R6). Wait for its row, or kill it and record it, then steer." >&2; exit 2; fi
  s_role="${1:-}"; s_path="${2:-}"; s_sev="${3:-}"; shift 3 2>/dev/null || true; s_text="$*"
  [ -n "$s_role" ] && [ -n "$s_path" ] && [ -n "$s_sev" ] && [ -n "$s_text" ] || {
    echo "loop-driver: steer <MS> <role> <path> <severity> \"<text>\"" >&2
    echo "  role = test-author | implementer (the owner); path = a dir/file.ext in that role's write-scope;" >&2
    echo "  severity = blocker | major | minor; text = what must land, in one line" >&2; exit 2; }
  case "$s_role" in test-author|implementer) :;;
    *) echo "loop-driver: steer: '$s_role' is not a writing role (test-author | implementer)" >&2; exit 2;; esac
  case "$s_sev" in blocker|major|minor) :;;
    *) echo "loop-driver: steer: severity '$s_sev' is not blocker | major | minor" >&2; exit 2;; esac
  case "$s_path" in */*.*) :;;
    *) echo "loop-driver: steer: '$s_path' is not a dir/file.ext path - the path is what routes the finding" >&2; exit 2;; esac
  path_in_scope "$s_role" "$s_path" 2>/dev/null || {
    echo "loop-driver: steer: '$s_path' is not in the $s_role write-scope (owner: $(owning_roles "$s_path" 2>/dev/null || echo unscoped)) - a finding is routed by its path, so name a path the role may write" >&2; exit 2; }
  # ONE LINE, WHOLE (1.8.7, M10 §2.3). This cap was `utf8_head 300` and it cut s1-driver-3 inside a
  # word ("...ReviewRecordClient.creat"); the implementer handed it spent a full invocation proving
  # the truncation was in the artifact (hexdump), answered `blocked`, and tripped R6 for the driver's
  # steer on top. A steer that cannot be read is a steer that costs an invocation to un-read, so a
  # long one is REFUSED and said so, never silently shortened. 1000 characters: the longest real steer
  # measured so far (s1-driver-3 in full) is under half of that, and a finding longer than this is a
  # document - put it in the plan or the RFC and steer the role to the path. Checked BEFORE the
  # artifact exists (1.8.7 review, minor): a refused steer used to leave an empty header file behind.
  s_text="$(printf '%s' "$s_text" | tr '\t\n\r' '   ' | sed -E 's/\[(blocker|major|minor)\]/(\1)/g; s/[[:space:]]+/ /g' | utf8_head 100000)"
  s_len="$(printf '%s' "$s_text" | python3 -c 'import sys; print(len(sys.stdin.read()))')"
  [ "$s_len" -le "${STEER_MAX_CHARS:-1000}" ] || {
    echo "loop-driver: steer refused: $s_len characters > ${STEER_MAX_CHARS:-1000} - a steer is one finding on one line, and a cut one costs the role an invocation to decode (M10 s1-driver-3). Shorten it, or write the text into the plan and steer the role to that path." >&2; exit 2; }
  s_rnd="$(review_rounds)"; [ "${s_rnd:-0}" -ge 1 ] || s_rnd=1
  s_br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')"; s_ml="$(printf '%s' "$MS" | tr 'A-Z' 'a-z')"
  s_art="review-results/${s_br}_${s_ml}_round${s_rnd}_driver_issues.md"
  mkdir -p review-results
  if [ ! -f "$s_art" ]; then
    { echo "# $MS - review round $s_rnd · driver"
      echo "<!-- rendered by loop-driver.sh steer (harness $(cat "$HERE/HARNESS_VERSION" 2>/dev/null || echo unstamped)). Ids are stable; the status line is derived from the findings on every write. Do not edit by hand. -->"
      echo; echo "status: open"; echo
      echo "Driver steers as findings: each line is work the driver named, owned by the role that may write its path. Closed by a verifier or a reviewer BY ID with evidence, like any other finding."
      echo; echo "## Findings"; echo; } > "$s_art"
  fi
  s_k="$(( $(grep -cE "^- \[[ xX]\] s${s_rnd}-driver-[0-9]+ " "$s_art" 2>/dev/null | tail -1) + 1 ))"
  s_id="s${s_rnd}-driver-${s_k}"
  { printf -- '- [ ] %s [%s] %s - %s\n' "$s_id" "$s_sev" "$s_path" "$s_text"
    printf '      evidence: driver steer (loop-driver.sh steer, %s, owner %s) - a claim by the driver; the verifier closes it by execution\n' "$(date -u +%FT%TZ)" "$s_role"; } >> "$s_art"
  echo "steer: $s_id [$s_sev] $s_path -> $s_role, in $s_art"
  cm="$(consolidate_ms 2>&1)" || true; printf '%s\n' "$cm" | tail -1 | sed 's/^/  /'
  exit 0;;

run)
  [ -n "$STEPS" ] || { echo "loop-driver: run needs --steps N (how many TDD steps this milestone has)" >&2; exit 2; }
  [ "$YES" = 1 ] || echo "── DRY RUN (no --yes): nothing will be spawned ──"
  # IS THIS THE HARNESS THAT WAS INSTALLED. Two worktrees of one repo ran drivers 248 lines apart
  # under one version string. The installer wrote the hash; a mismatch here is an undeclared local
  # edit, and money is about to be spent on it. Declared edits (scripts/.upstream-exempt) and
  # HARNESS_SHA_CHECK=0 opt out; a repo installed before the stamp existed has nothing to check.
  if [ "${HARNESS_SHA_CHECK:-1}" = 1 ] && [ -f "$HERE/HARNESS_SHA" ] && [ ! -f "$HERE/.upstream-exempt" ] \
     && command -v harness_sha >/dev/null 2>&1; then
    want="$(cat "$HERE/HARNESS_SHA")"; have="$(harness_sha "$HERE")"
    [ "$want" = "$have" ] || { echo "loop-driver: scripts/ does not match scripts/HARNESS_SHA ($have, stamped $want) — this is not the harness install-harness.sh wrote. Re-run the installer, declare the edit in scripts/.upstream-exempt, or set HARNESS_SHA_CHECK=0." >&2; exit 2; }
  fi
  # THE CEILING THIS RUN HOLDS. loop.config is sourced once, at start; an edit while a role is in
  # flight reaches the next `run`, never this one (TT-4348 M5: the ceiling was raised mid-round and
  # the running driver kept the old number). Printed so the operator reading the log knows which.
  run_ceiling=""; command -v milestone_usd_ceiling >/dev/null 2>&1 && run_ceiling="$(milestone_usd_ceiling "$MS" 2>/dev/null)"
  [ -n "$run_ceiling" ] || run_ceiling="${MILESTONE_USD_CEILING:-}"
  # THE RUN'S OWN LOG, UNDER THE WORKTREE (1.8.9, TT-4348 M12 §3.3, M14). `run` wrote to whatever the
  # caller redirected to - a session scratchpad, /private/tmp - and a machine reboot took every
  # driver log of a milestone with it, the role result JSONs beside them. `.loop/` under the repo
  # (gitignored by the installer; a repo that does not ignore it gets the old behaviour and a note)
  # keeps the run's log and, per role, its brief and result JSON: what a retro or a kill needs.
  loop_dir_ok && { LOOP_LOG="$ROOT/.loop/driver-$MS-$(date -u +%Y%m%dT%H%M%SZ).log"
    exec > >(tee -a "$LOOP_LOG") 2>&1; echo "  (log: ${LOOP_LOG#$ROOT/})"; }
  echo "── $MS · run · steps $STEPS · ceiling \$${run_ceiling:-none} · wall cap ${MAXWALL}m (loop.config as read at start; an edit needs a relaunch) ──"
  deadline=$(( $(date +%s) + MAXWALL * 60 ))
  while :; do
    # Every stop path runs the escalation agent, and every one still exits 3. The agent is the
    # difference between "the loop stopped" and "the loop stopped, and here is why and what to do" —
    # it never continues the run and never changes the exit code.
    [ "$(date +%s)" -ge "$deadline" ] && { escalate "RW: wall-clock cap ${MAXWALL}m reached"
      breaker_agent "RW: wall-clock cap ${MAXWALL}m reached"; exit 3; }
    # GRADED: a soft breaker's first occurrence is a WARN line and a `warn` row, and the run goes on;
    # its second is a stop; a hard one stops as it always did. See stop_decision.
    s="$(stop_decision "$(stop_reason)" "$YES")"; [ -n "$s" ] && { escalate "$s"; breaker_agent "$s"; exit 3; }
    # `--role <name>` STEERS ONE SPAWN, then clears. The case it exists for is a role killed
    # mid-flight: the sequencer reads the ledger, the killed role never wrote a row, and the loop
    # answers with the role BEFORE it. Until now the only way to correct that was to `record` a row
    # for an invocation that never happened — falsifying the one artifact the whole loop trusts, to
    # move a pointer.
    #
    # It MUST clear after one use. A sticky override silently pins every remaining spawn to one role
    # and stops sequencing altogether, which looks like a working run right up until the milestone has
    # eight implementer invocations and no tests. Cleared before the spawn, not after, so a spawn that
    # exits non-zero cannot leave it armed for the next pass of this loop either.
    if [ -n "$ROLE_ONCE" ]; then
      case "$ROLE_ONCE" in
        test-author|implementer|reviewer|verifier) :;;
        *) echo "loop-driver: --role '$ROLE_ONCE' is not a spawnable role (test-author|implementer|reviewer|verifier)" >&2; exit 2;;
      esac
      role="$ROLE_ONCE"; ROLE_ONCE=""; steered=1
      echo "── --role steered THIS invocation to '$role'; the override is now cleared ──"
    else
      role="$(next_role)"; steered=""
      # CONVERGED, NOT AT HEAD (1.8.4): a steered spawn moved the tree after the review that converged
      # it, so the run goes on (RED, GREEN, the review at HEAD) instead of printing "complete" over a
      # tree the review never read. Said on every pass it applies to, so the log reads as it routes.
      [ "$role" != done ] && review_converged && ! converged_at_head \
        && echo "  (the review converged at $(last_review_sha) but MAIN/TEST scope moved since - continuing until a review has run at HEAD)"
    fi
    # THE HAND-OFF COMMITS THE JOURNALS. The ledger and LOOP_STATE.md are harness journals — never
    # swept into a pre-spawn commit, committed at checkpoints — and the last consolidation of a
    # converged milestone writes to both AFTER the last spawn. `run` then exited 0 on top of them, and
    # open-milestone-pr.sh's first act is `refuse: tree dirty` (TT-4348 M4: one hand commit, and the
    # full gate ran twice, ~12 minutes). There is no next spawn to audit against, so the journals are
    # committed here, once, as the milestone's own closing bookkeeping.
    [ "$role" != done ] && review_converged && converged_at_head && post_review_gate_red_owner >/dev/null \
      && echo "  (the review converged at HEAD but the gate there is RED - not complete; the RED's owner is asked next, with the cause)"
    [ "$role" = done ] && {
      commit_loop_artifacts "$MS closing artifacts" || true
      commit_harness_journals "$MS ledger and journal through convergence" || true
      echo "── $MS complete: review converged. Hand to open-milestone-pr.sh ──"; exit 0; }
    # next_role answers `driver` when the open findings belong to no writing role. That is a STOP with
    # a diagnosis, not a role to spawn — spawning anyone would pay an invocation to be told the same.
    [ "$role" = driver ] && {
      # A role that answered `refuted` or `no_work` is why the routing ran out; its own words are the
      # diagnosis, so they ride on the stop instead of being left in column 12 for someone to find.
      rnote="$(role_rows_since_ack | awk -F'\t' '$11=="refuted" || $11=="no_work" {n=$3 ": " $12} END{print n}')"
      escalate "RD: review has not converged and every open finding is in DRIVER scope (scripts/, build files, the plan), names no path at all, or was answered no_work/refuted by the role that owns it${rnote:+ — $rnote} — no test-author or implementer can close them. Fix or close them yourself, land it, then \`loop-driver.sh record $MS driver ack --signature last --verdict true --cause '<what>'\`"
      breaker_agent "RD: open findings are all driver-owned or refuted"
      exit 3; }
    # The escalation marker is printed, not inferred. A tier that silently raises is as hard to audit
    # as one that silently lowers, and the operator reading this line before typing --yes is the whole
    # spend guard — an unexplained jump from sonnet to opus must say why it happened.
    # THE REVIEW MODE (1.8.0), decided before the tier note because a verify pass is another role:
    # `none` is a stop with nothing spawned — the tree in front of the reviewer is the tree it already
    # judged; `verify` re-labels the spawn; `full` is the fan-out below. `--role verifier` skips the
    # measurement and forces a verify pass; `--role reviewer` forces a FULL round the same way — a steer
    # is the operator's resume after a killed round, and the measurement would refuse it on the very
    # tree the killed round was reviewing.
    rmode=""; RESUME_DIMS=""; RND_FORCE=""
    if [ "$role" = reviewer ] && [ -z "$steered" ] && [ -n "$(round_missing_dims)" ]; then
      RESUME_DIMS="$(round_missing_dims | tr '\n' ' ')"; RND_FORCE="$(review_rounds)"
      # Owed, not "no artifact" (1.8.8 review pass 6, minor): a dimension whose reviewer answered
      # blocked with no findings HAS an artifact on disk, stamped blocked - the round did not stop
      # before it ran, it ran and reviewed nothing.
      echo "  (resuming review round $RND_FORCE: owed by $RESUME_DIMS- no finished artifact on disk for the dimension: the round stopped before it ran, or its reviewer answered blocked with no findings)"
    elif [ "$role" = reviewer ] && [ -z "$steered" ]; then
      rmode="$(review_mode)"
      case "$rmode" in
        none:*)
          s="RU: ${rmode#none:} — a review of an unchanged tree cannot close a finding, so nothing was spawned. Land the fix for every open finding (owners in issues.md), then \`loop-driver.sh record $MS driver ack --signature last --verdict true --cause '<what>'\`"
          escalate "$s"; breaker_agent "$s"; exit 3;;
        verify:*) role=verifier;;
      esac
    fi
    esc_note=""
    if delta_review "$role"; then
      esc_note=" · DELTA (review round $(review_round_now); scope is the diff since the last round)"
    elif [ "$(model_for "$role")" != "$(base_model_for "$role")" ] && [ -n "$(base_model_for "$role")" ]; then
      esc_note=" · ESCALATED ($MS is mutation-gated)"
    # The hint that won (1.8.5) is printed as the escalation is: an operator reading sonnet on a
    # mutation-gated milestone must see that the plan priced the step, not that the escalation broke.
    elif [ "$role" = implementer ] && correctness_critical && [ -n "$(step_hint)" ]; then
      esc_note=" · STEP HINT ($MS is mutation-gated; milestone_model names $(step_hint) for step ${STEP:-post-review} and an explicit per-step hint wins over the escalation)"
    fi
    # `|| echo` swallowed EVERY non-zero return, including the R6 refusal — so the audit printed
    # "run stops", returned 6, and the loop carried straight on to the next role. Measured on C6:
    # after the implementer's R6 it spawned two more reviewers, $5.67 and 2.4 hours of wall clock,
    # and only the RW wall-clock cap ended it. A refusal the caller discards is worse than no
    # refusal, because the log claims a stop that did not happen. 6 is now distinguished from an
    # ordinary non-zero exit; everything else keeps the old "a role may fail, keep going" contract.
    #
    # THE FAN-OUT. A reviewer round is N cold reviewers, one per REVIEW_DIMENSIONS entry, each with
    # its own context, its own workspace and its own artifact — the shape loop.config's round budget
    # has always described ("one fan-out of N dimension reviewers = ONE round") and review-workspace.sh
    # was written to support. The driver ran one reviewer and called it a round.
    #
    # SEQUENTIAL, not concurrent, though the reviewers are independent: `spawn` appends to the ledger
    # and runs the post-hoc scope audit against a single HEAD, and two spawns interleaving there would
    # attribute one role's writes to the other. The workspaces are per-dimension so a later concurrent
    # driver does not have to move; the ledger is the thing that would need to change first.
    #
    # An R6 STOPS THE ROUND. A reviewer that wrote outside its scope has already broken the separation
    # the remaining dimensions are being paid to verify, and paying for them first would only add cost
    # to a run that is about to stop anyway.
    if [ "$role" = verifier ]; then
      if [ -n "$rmode" ]; then vnote="${rmode#verify:}"
      elif [ -n "$steered" ]; then vnote="steered by --role"
      else vnote="the owners answered no_work at HEAD and no verify pass has re-proved the open ids there; open: $(open_ids | tr '\n' ' ')"; fi
      echo "── $MS · invocation $(( $(count_all) + 1 )) · verifier · $(model_for verifier) · verify pass $(( $(review_verifications) + 1 )) ($vnote)$esc_note ──"
      fanned=""
      spawn verifier "$(model_for verifier)"; src=$?
    elif [ "$role" = reviewer ] && [ -n "$(review_dims)" ]; then
      assert_review_dims
      rnd="$(review_round_now)"
      # The round's artifacts are committed ONCE, here, so every dimension reads the same HEAD.
      [ "$DRY" = 1 ] || commit_loop_artifacts "artifacts before review round $rnd" >/dev/null || true
      case "$rmode" in full:*) echo "  (full round: ${rmode#full:})";; esac
      # CONCURRENT when the config allows it and the projected spend fits (review_parallel_ok); a dry
      # run rehearses sequentially, one DRY RUN line per dimension, as it always did.
      par="$(review_parallel_ok)"; [ "$DRY" = 1 ] && par="0:dry run"
      echo "── $MS · review round $rnd · fan-out of $(dims_to_run | wc -l | tr -d ' '): $(dims_to_run | tr '\n' ' ')· $([ "$par" = 1 ] && echo concurrent || echo "sequential (${par#0:})") ──"
      src=0; fanned=1
      if [ "$par" = 1 ]; then fanout_parallel "$rnd" "$esc_note"; src=$?; fi
      [ "$par" = 1 ] || for DIM in $(dims_to_run); do
        # ROLE THEN MODEL, in that order, exactly as the single-spawn line below it. The operator reads
        # this line before typing --yes and the tests read it too; putting the round between the two
        # would make the reviewer the one role whose header is shaped differently from the rest.
        echo "── $MS · invocation $(( $(count_all) + 1 )) · reviewer[$DIM] · $(model_for reviewer) · round $rnd$esc_note ──"
        spawn reviewer "$(model_for reviewer)"; src=$?
        [ "$src" = 6 ] && { echo "  (R6 in the $DIM reviewer — the rest of the round is not spawned)"; break; }
        # THE API SAID NO (1.8.7 review, blocker): the sequential branch broke only on R6, so after an
        # `api` reviewer row it spawned the remaining dimensions into the same refusal, announced the
        # row as fail, and the last dimension's rc hid the 5 from `run`. Same stop as the parallel round.
        [ "$src" = 5 ] && { echo "  (the API refused the $DIM reviewer - the rest of the round is not spawned)"; break; }
        [ "$src" = 0 ] || echo "  (reviewer[$DIM] exited non-zero — recorded as fail)"
        # AND THE COST BREAKERS, BETWEEN THE SPAWNS. See stop_reason_cost(): the outer `while` checks
        # once per pass and a round is N spawns inside one pass, so without this the overshoot is N-1
        # invocations on exactly the breakers that bound spend and wall clock. Only the cost group is
        # re-checked — the progress breakers are true by construction mid-fan-out and would stop every
        # round after its first dimension. The `break` hands the stop to the outer loop, which escalates
        # and exits 3 on its next pass, so there is still ONE escalation path and one exit code.
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "  (RW: wall-clock cap ${MAXWALL}m reached mid-round — the rest of the round is not spawned)"; break
        fi
        # Through stop_decision, as the outer loop's check is: a soft cost breaker (R13-LANDED) warns
        # once here too instead of cutting the round on its first occurrence.
        cstop="$(stop_decision "$(stop_reason_cost)" "$YES")"
        [ -n "$cstop" ] && { echo "  (${cstop%%:*} tripped mid-round — the rest of the round is not spawned)"; break; }
      done
      DIM=""; RESUME_DIMS=""; RND_FORCE=""
    else
      # THE STEP, derived when not passed (see next_step_id): the plan text for exactly this step goes
      # into the brief and the implementer's tier comes from milestone_model(). Only while steps are
      # still being built — a post-review fix round has no "next step".
      if [ -z "$STEP" ] && [ "$(done_steps_count)" -lt "$STEPS" ]; then
        case "$role" in test-author|implementer) STEP="$(next_step_id)";; esac
        [ -n "$STEP" ] && echo "  (step $STEP derived: $(done_steps_count) of $STEPS done)"
      fi
      echo "── $MS · invocation $(( $(count_all) + 1 )) · $role · $(model_for "$role")${STEP:+ · step $STEP}$esc_note ──"
      fanned=""
      spawn "$role" "$(model_for "$role")"; src=$?
    fi
    # A REFUSAL is not a breaker: the tree was dirty outside the role's scope, nothing was spawned,
    # no ledger row was written, and no ack is owed. Clean it and run again.
    [ "$src" = 4 ] && { echo "── run stopped before spawning: clean the tree (see above), then re-run — no breaker tripped ──"; exit 4; }
    # `--step` clears with the invocation it labelled, for the same reason `--role` does: it names ONE
    # step of TDD_PLAN §5, and a run that keeps applying it to every later spawn would pick step 3c's
    # model for step 4 and paste step 3c's plan text into step 4's brief. Cleared, the next spawn falls
    # back to the SAFE model — the direction a forgotten flag is allowed to fail in.
    [ -n "$STEP" ] && { echo "  (--step $STEP applied to that invocation and is now cleared)"; STEP=""; }
    if [ "$src" = 6 ]; then
      escalate "R6: '$role' wrote outside its write-scope — the run stopped rather than continuing"
      breaker_agent "R6: '$role' wrote outside its write-scope"
      exit 3
    fi
    # NOT A BREAKER (1.8.7, M10 §2.5): nothing ran, nothing spent, no cause in the loop to diagnose,
    # so no escalation agent and no ack. Exit 5 is its own code so a watcher can tell "the API said
    # no" from "the loop stopped itself" (3) and "the tree was dirty" (4).
    [ "$src" = 5 ] && { echo "── run stopped: the API refused the last invocation (see the \`api\` row) - relaunch when the limit or outage has cleared; no breaker tripped, no ack owed ──"; exit 5; }
    # GATED ON THE FAN-OUT HAVING RUN, not on the role being the reviewer. The exemption existed to
    # stop this line double-printing after the fan-out's own per-dimension message — but the `else`
    # branch above ALSO spawns a reviewer (a config with no REVIEW_DIMENSIONS), and that one printed
    # nothing at all: measured with a stub exiting 3, the row said `fail` and only the ledger knew.
    [ "$src" = 0 ] || [ -n "${fanned:-}" ] || echo "  (role exited non-zero — recorded as fail)"
    # AND THE ROUND'S FINDINGS ARE MERGED BEFORE THE NEXT PASS READS THEM. `owns_open_finding`,
    # `review_converged` and RU all read ROOT issues.md, which only `consolidate` writes — and
    # nothing called it: `grep -rn consolidate templates/scripts/` found the subcommand, two briefs
    # naming it and no caller. So the whole routing this loop was rebuilt for was unreachable in an
    # autonomous run. Driven for real on a fresh install with a stub CLI: three dimensions wrote
    # three artifacts full of open findings, root issues.md was still ABSENT, and the loop stopped
    # on RU for a human at exit 3 — one stop per round, which is the exact cost the routing exists
    # to remove. Worse on later rounds than on the first: a STALE issues.md is not absent, so RU is
    # skipped and the driver routes on the PREVIOUS round's findings.
    #
    # A FUNCTION CALL, not `"$0" consolidate "$MS"`: a re-exec inherits this run's argv and env, and
    # the driver's own flag parser has already been the cause of one subcommand that could never be
    # invoked. Failure is not fatal — a round the breakers cut short before dimension 1 wrote
    # anything has no artifacts to merge, and the next pass's own stop_reason is the thing that must
    # decide what happens then, not this line.
    # BELOW THE DRY-RUN EXIT, so a run without --yes still writes NOTHING. A dry run spawns nobody, so
    # there is no new artifact to merge — but `consolidate` writes root issues.md unconditionally from
    # whatever is already on disk, and "print the command instead of running it" must not mutate the
    # tree it is describing. Placed above this line first, and a dry `run --role reviewer` then
    # rewrote issues.md in a repo where nothing had been spawned.
    #
    # Keyed on the ROLE, so the single-reviewer `else` branch (a config with no REVIEW_DIMENSIONS)
    # gets the same refresh the fan-out does — the exemption that once silenced that branch's own
    # failure message is the shape this line must not repeat.
    [ "$DRY" = 1 ] && { echo "── dry run stops after one step; re-run with --yes to drive ──"; exit 0; }
    # ...AND COMMITTED, so the next role is not audited for them. Consolidate, commit, then spawn —
    # the rule two learnings files carried and one driver broke three times in a milestone.
    case "$role" in reviewer|verifier)
      cm="$(consolidate_ms 2>&1)" || true; printf '%s\n' "$cm" | tail -1 | sed 's/^/  /'
      commit_loop_artifacts "review round $(review_rounds) artifacts" || true;; esac
  done;;

smoke)
  # Proves the SPAWN PATH end to end — CLI reachable, `--model` honoured, output captured, ledger
  # row written with real timings — without touching the repo, the journal, or a milestone's
  # counters. Deliberately the cheapest model and a read-only prompt: a mechanism test must not be
  # able to change the tree it is being run in. Run it as `loop-driver.sh smoke SMOKE --yes`.
  m="$(model_for search)"
  echo "── spawn smoke test · model $m ──"
  if [ "$DRY" = 1 ]; then echo "  DRY RUN — pass --yes to actually spawn"; exit 0; fi
  sm="$LOGDIR/smoke.json"; t0=$(date +%s)
  # Same stdin + flag path the real roles take, so a green smoke proves THAT path and not another.
  # shellcheck disable=SC2086
  printf 'Reply with exactly READY and nothing else. Do not use any tools.' \
    | claude -p --model "$m" $CLAUDE_FLAGS > "$sm" 2>&1; rc=$?
  t1=$(date +%s)
  python3 - "$sm" "$m" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception as e: print(f"  UNPARSEABLE OUTPUT: {e}"); raise SystemExit(1)
u = d.get("usage", {})
tok = sum(u.get(k, 0) for k in ("input_tokens","cache_creation_input_tokens","cache_read_input_tokens","output_tokens"))
mu = ", ".join(d.get("modelUsage", {})) or "?"
print(f"  result:   {d.get('result')!r}")
print(f"  model:    {mu}   (asked for {sys.argv[2]} — these must agree, or --model is not honoured)")
print(f"  envelope: {tok:,} tokens · ${d.get('total_cost_usd',0):.4f} for a call that does no work")
PY
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t\t\n' "$(date -u +%FT%TZ)" "$MS" smoke "$m" \
    "$([ $rc = 0 ] && echo pass || echo fail)" "$(git rev-parse --short HEAD 2>/dev/null||echo none)" \
    "$((t1-t0))" "-" "-" >> "$LEDGER"
  exit $rc;;

cost)
  echo "── spend for $MS ──"
  ledger_rows | awk -F'\t' '{r[$3]++; t[$3]+=$8; c[$3]+=$9; T+=$8; C+=$9}
    END{ for (k in r) printf "  %-14s %3d invocations  %10d tok  $%.4f\n", k, r[k], t[k], c[k]
         printf "  %-14s %3s               %10d tok  $%.4f\n", "TOTAL", "", T, C }'
  echo "  (rows written before per-invocation accounting existed show 0 — they are not free, only unmeasured)"
  exit 0;;

*) echo "loop-driver: unknown command $CMD" >&2; exit 2;;
esac
