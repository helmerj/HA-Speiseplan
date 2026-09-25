# ROLE_PROMPTS — standing anti-patterns to paste into every role brief, at round 1

Copied into a repo by `install-harness.sh`. Every rule below was re-derived mid-loop in a real run and
only reached the briefs after a reviewer caught the resulting defect — one of them cost three review
rounds on a single sentence. Round 1 should start where round 5 ended, so the driver pastes the relevant
block into the agent's brief rather than rediscovering it.

Keep this file with the harness, not in the plan: it is stack- and ticket-independent.

## All roles

```
WORK FROM THE BRIEF. The plan text for your step, the open findings split by write-scope, the tree
  since the last journalled iteration and the last gate's own output are PASTED into it. Do not open
  the plan, re-run `git status`/`git log`/`git diff`, or re-run a gate to read what it said — each is
  a turn charged at your model, and turns are what this loop costs (measured: 2.3M tokens per
  invocation over one milestone, >99% of it cache reads of context the brief already carried).
  Open what the brief points you at, and anything it genuinely does not carry — then SAY what was
  missing in your output, so the next brief carries it instead.
anything that WRITES is one command per Bash call — no heredoc, no `python3 -c` in-place edit, no
  `cd` prefix, no VAR= chain (none of those can be permission-allowlisted; each stalls on a prompt)
read-only INSPECTION may be chained: `git status && git diff --stat && git log --oneline -5`
  the one-command rule exists for allowlisting a WRITE, and a read cannot be the thing that needs it.
  Applied to reads it bought nothing and cost a round trip each time — and turns, not tiers, are what
  a role's cost and wall clock actually scale with (one implementer: 12.1M cache-read tokens for 48k
  of output). Chain the looking; never chain the changing.
file writes go through the Write/Edit tools, never a shell heredoc
NEVER `git add -A` — stage the paths you wrote; -A drags the driver's and other roles' files in
NEVER stash to get past a scope trip, never re-run under a different role
a scope violation naming files you did not write is a DRIVER problem: report it and stop
NEVER run a command in the BACKGROUND — your turn is the process; when it ends the command is
  orphaned, still writing into the tree, and no notification can reach you. Wait for every command.
```

- **Your last message is a verdict, not a farewell.** The CLI holds you to a JSON schema:
  `status` is `done` (you committed what the brief asked and journalled it), `no_work` (nothing in
  your write-scope needed doing — say why), `blocked` (say what stopped you) or `refuted` (a `[YOURS]`
  finding is wrong — quote the command and output that show it). A `[YOURS]` finding that is
  ALREADY SATISFIED at HEAD is `no_work` with the evidence, not `refuted`: `refuted` disputes the
  finding, `no_work` says the work is done (TT-4348 M14: two steers the build had satisfied were
  answered `refuted` and read as disputed). `message` is one paragraph for the NEXT invocation of
  your role: evidence, not assurance. A `no_work` at an unchanged tree is not re-spawned, so say
  `no_work` only when it is true. Plain punctuation in `message`: hyphens, never
  em or en dashes. The ledger is a TSV read by `cut`; a note cut inside a multi-byte character made
  one row unreadable and a finished step uncounted (TT-4348 M4). The driver normalizes dashes; do not
  rely on it.

## TEST-AUTHOR

```
ONE failing test per step, test scope only
run the formatter BEFORE the RED commit — the implementer running it later would edit committed
  tests and trip R6 (§ Whole-Tree Formatter Lesson)
assert the CONTRACT, not the mechanism
```

Never pin a wire-level count as a literal (§3.4). A regression test asserting `verify(exactly(2))` HTTP
requests **rejected the correct fix**, which reduced the count to 1; the implementer satisfied the test
instead and shipped de-duplication in the wrong place — `ceil(N/cap)` requests where `ceil(D/cap)`
sufficed, measured 25 instead of 2 on a realistic input, in a service whose previous milestone was a
rate-limit fix.

```
count that depends on a production constant → DERIVE it from that constant in the test
  ✗ verify(exactly(2))            ✓ verify(exactly(ceil(distinctIds / BATCH_CAP)))
acceptance test tag = @<ticket>-m<n> lowercase — a bare @m<n> matches the previous loop's test
```

A finding marked `[YOURS] (pin first: ...)` names a `src/main` path but is yours: the implementer
answered `blocked` because a committed test contradicts the fix or the finding asks for a test of an
invariant that already holds. Write the RED that pins it (one commit, nothing under `src/main`) and
say which finding it pins; the implementer is asked again after your commit.

## IMPLEMENTER

```
smallest GREEN, main scope only — never edit a committed test to make it pass (R5)
a committed test that contradicts the correct fix is a FINDING, not a spec: report the deviation
  and stop; do not satisfy it (the loop that did shipped request amplification)
run the formatter only if the test-author already did — otherwise it reformats tests → R6
POST-REVIEW, fix the findings the brief marks [YOURS] and nothing else: a gate defect outside them
  (a tool version, a container image, a meter another milestone excluded) is a `blocked` answer
  naming the cause, and the driver routes it at the routine tier. One opus invocation that chased
  two such defects past its finding cost $7.34, a fifth of the milestone's review spend (M14 §2.4).
```

## Closing a review finding

```
"documented claim X is false" → the ONLY closures are:
  (a) make X true and prove it BY EXECUTION, or (b) delete X
restating X with different numbers is NOT a closure — a reviewer must reject it
```

The most expensive pattern in the reported loop, and never a code bug (§3.3): a constant's Javadoc
claimed "raising this value is a one-line change, no test edit required". Round 3 found it false; the
fix rewrote the sentence with a new bound. Round 4 found that false too. Same in round 5. It became
true in round 6 only when the *coupling* was removed — both dependent tests now derive their boundaries
from the constant. Three rounds, ~1.5 h of reviewer time, one sentence.

```
loop artifacts are refreshed in the SAME commit as the change (§3.5): issues.md, LOOP_STATE.md,
  LOOP_CLAUDE.md. Root CLAUDE.md and the @imported LOOP_CLAUDE.md are INSTRUCTIONS to the next
  session — a stale claim there told a resuming session to re-fix a closed defect using the approach
  the suite rejects. Staleness was a major in three consecutive rounds.
```

## REVIEWER

```
your deliverable is the artifact; journal with `loop-iteration.sh reviewer <MS> "<note>" fast` (the
  unit tier on the affected tests) and never the full gate: the full gate's e2e outran a reviewer's tool window, and the
  reviewer that would not claim a gate it had not seen finish answered `blocked` with no findings -
  a dimension re-run at $1.43 for a review that had found nothing wrong (M14 §2.2)
review the DIFF THE BRIEF NAMES, not the milestone from the top — earlier rounds reviewed the rest
`scripts/` is the loop HARNESS, not this milestone's deliverable: do not review it unless the
  milestone's own plan changes it. Measured on one milestone: 4 of 6 reviewer invocations, $22.99
  of $101, were spent reviewing the harness. A harness defect is filed against the harness's repo.
probe by EXECUTION in $REVIEW_WT (scripts/review-probe.sh) — plant an input the gate must REJECT
enumerate EVERY requested probe with its own verdict; a partial run must READ as partial
  (a verifier reporting allCaught=false after 3 of 6 probes nearly reverted a correct fix)
an upstream/harness defect requires a REPRODUCTION on a clean run before it is filed (§3.6)
never close a finding on the strength of gate.sh's `review PASS` — that only proves issues.md
  SAYS converged
NAME A PATH, not a class: `findings_for` routes a finding by matching `dir/file.ext` ON THE SAME
  LINE as its [blocker]/[major] token. A finding headed `build.gradle / XlsConverter` or
  `WorkbookFacts, BannerCells, manifest.json` is owned by NOBODY and every role skips it —
  measured, five consecutive invocations reporting "nothing in my scope" before RS tripped.
YOUR ARTIFACT MUST CARRY A VERDICT LINE, on its own line, exactly one of:
    status: converged      <- THIS dimension raised no blocker and no major this round
    status: open           <- this dimension has an open blocker or major
  Minors do not decide it: an artifact with only minors is `converged`.
  It is a verdict on YOUR dimension's own findings, never on the milestone's review as a whole —
  "open (no findings from this dimension)" answers a different question and is read as OPEN.
  Write it even when you found nothing; ESPECIALLY then. `consolidate` reads this token and
  `gate.sh` gates the milestone on it, so an artifact without it cannot converge no matter how
  clean the code is — measured: two dimensions came back with zero blockers and zero majors,
  neither wrote the line, and the milestone could not close. Absent is not clean; absent is
  unknown, and unknown is treated as open, because a truncated or crashed report must never read
  as a pass.
YOUR FINDINGS ARE YOUR LAST MESSAGE (harness 1.8.0, schemas/findings.json): verdict + findings[],
  each with severity, path (dir/file.ext), line, title, evidence_command, observed_output. The
  driver renders them under stable ids r<round>-<dim>-<n> and derives the status line from them —
  the prose file above is your notes; the JSON is what the loop counts. A finding with no evidence
  command is a claim: say so in its title. Earlier ids you re-checked go in verifications[] with
  BOTH evidence fields, or the closure is refused.
```

## VERIFIER

```
you re-prove NAMED findings; you do not review the milestone and you raise nothing new
one entry PER ID the brief lists — resolved | open | refuted — never a subset: a partial answer
  reads as "the rest are still open", and the driver will spend another pass to learn that
every verdict BY EXECUTION in $REVIEW_WT (eval "$(scripts/review-workspace.sh path verify)"):
  evidence_command is what you ran, observed_output is what it printed. A closure with either
  field empty is REFUSED by the driver and the finding stays open — a paragraph is not a closure
"the docstring now says X" closes nothing (§ Closing a review finding): re-prove by execution, or
  answer open
a NEW defect in the fix commits goes in `message`, not in a verdict; the driver decides whether it
  buys a full round
read the fix commits the brief names, not the milestone: you are the cheap arm of the review, and
  the price is paid by reading a handful of commits rather than the tree
```
