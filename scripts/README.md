# TDD Loop Harness

Generic, bash-3.2/BSD-safe scaffold installed by `workflows:tdd-loop-run-recipe`. Every file here
except `loop.config` is stack-agnostic and copied verbatim — do not hand-edit the harness per project;
change behaviour in `loop.config`, or add a stack adapter. If you must extend a harness file, declare
it in `.upstream-exempt` (below) so the next install does not delete it.

| File | Role |
|------|------|
| `loop.config` | **The only per-project file.** SPEC_DIR, role scopes, skill ids, model/effort profile, breaker thresholds, `iteration_budget()`, `churn_budget()`, `MUTATION_TARGETS`. Generated from `loop.config.template`; never overwritten by a re-install. |
| `adapters/<STACK>.sh` | The only stack-specific harness file. Implements `gate_build`/`gate_unit`/`gate_integration`/`gate_coverage_pct`/`gate_e2e`, and optionally `gate_unit_affected`, `gate_mutation`(`_pct`), `churn_loc`, `it_parallel_args`. `gate.sh` sources the one named by `STACK`. |
| `lib/roles.sh` | Role→glob resolution from `loop.config`. |
| `lib/churn_loc.py` | R8's statement counter (see **Churn** below). Optional: used only where the adapter defines `churn_loc`. |
| `check-scope.sh` | Fails if a role's changed files fall outside its write-scope (R5/R6). |
| `gate.sh` | Runs the milestone gate table via the adapter; exits 0 only if every required gate is green. |
| `loop-iteration.sh` | Driver per-iteration step: scope + churn + gate + circuit breakers → appends LOOP_STATE, writes ESCALATION on trip. |
| `loop-driver.sh` | Sequences the roles, enforces the review budget and the model/effort profile, records spend. `steer <MS> <role> <path> <severity> "<text>"` writes a driver steer as a finding (see **Driver steers**). |
| `milestone-start.sh` | Branch a milestone off the integration branch; archive the previous milestone's artifacts. |
| `open-milestone-pr.sh` | Gate- and review-gated PR. Never merges, never pushes to the integration branch. |
| `upstream-report.sh` | Names the harness changes this milestone made that are **not** declared local — the upstream candidates. Runs at the close-out; reports, never gates. |
| `sync-progress.sh` | Milestone progress → managed `<!-- loop:progress -->` README block (idempotent). Jira/Notion sync = driver MCP steps, not this script. |
| `checkpoint.sh` | 60% context checkpoint → refresh `$SPEC_DIR/LOOP_CLAUDE.md` auto-state + ensure root `@import`; `clear-escalation` archives a cleared trip. |
| `review-workspace.sh` / `review-probe.sh` | Isolated worktree for the reviewer, and the falsification probe. |
| `worktree-track.sh` | Isolated worktree+branch for genuinely independent/file-disjoint parallel tracks. |
| `migrate-loop-claude.sh` | One-shot; only present when migrating a pre-split loop. |
| `harness-selfcheck.sh` | Proves the harness still BEHAVES. Run it after anything touches `scripts/`, and in CI if the repo has one. |
| `lib/knobs.manifest` | every loop.config knob → its reader; asserted by the self-check (an explicit list, not a scanner) |
| `lib/harness_sha.sh` | one hash over scripts/; `HARNESS_SHA` is stamped by the installer and checked before `run` spends. It hashes EVERY `scripts/*.sh`, so a project's own scripts live in a subfolder (`scripts/sf/`, `scripts/tools/`), never beside the harness - a stray `scripts/my-tool.sh` moves the hash and `run` refuses |
| `schemas/role-outcome.json` | the JSON schema every role's last message is held to (`--json-schema`): status done/no_work/blocked/refuted + message |
| `schemas/findings.json` / `schemas/verify.json` | the reviewer's and the verifier's last message (1.8.0): findings with path/severity/evidence, rendered by the driver under `r<round>-<dim>-<n>` ids; closures by id, evidence required |
| `lib/review_findings.py` | renders a reviewer's JSON into `review-results/`, applies a verifier's closures in the artifact that raised each finding, counts open findings and per-path recurrence (RA) |
| `.upstream-exempt` | Optional. What in `scripts/` is local BY DESIGN (see **Re-installing**). |

**Honesty rule:** when a tool or daemon is absent, a gate reports **PENDING**, never PASS. PENDING ≠ green.
Every "could not measure" branch is PENDING; FAIL means a number was actually taken and came in low.
The rule exists because this harness's signature failure is the opposite — a *declared* gate with no
executor, reporting PASS by being unmeasured. Two milestones of one driven loop passed a
`mutation_score_pct` gate that no code anywhere computed.

## Tiers

`gate.sh <milestone> [mid|step|full]`, cheapest first. A tier's contents are defined by its POSITION
in `gate.sh` — it is a straight-line script — and `harness-selfcheck.sh` asserts the line order.

| Tier | Runs | Verdict string |
|------|------|----------------|
| `fast` (loop-iteration only) | unit, affected tests where the adapter can select them | `fast[...]: PASS` |
| `mid` | build + unit + coverage | `GATE: MID-OK` |
| `step` | build + unit + **integration** + coverage — everything a ROLE's own work can be judged on | `GATE: STEP-OK` |
| `full` | the above + **mutation** + review + e2e — everything a MILESTONE needs to land | `GATE: PASS` |

Only `full` may print `GATE: PASS` (both `open-milestone-pr.sh` and `loop-iteration.sh` grep for that
string) and only `MODE=gate` sets `green_proven`. A cheaper tier must never buy a milestone unlimited
iterations, nor let it land on tiers that never ran.

## Models

Every spawn's tier comes from `loop.config` (`MODEL_*`), resolved by `loop-driver.sh model_for` and
printed in the invocation header before `--yes` spends. Three rules move a role off its floor:

- **`milestone_model <Mn> [<step>]`** prices the implementer per step: an explicit arm for the step
  (`M3:3c`), a milestone-wide arm (`M1:*`), or the `*)` fallback, which is the SAFE tier. No `--step`
  is the SAFE tier too; `run` derives the step from the plan when it can.
- **The mutation escalation.** On a milestone in `CORRECTNESS_CRITICAL` the implementer, the reviewer
  and the verifier are raised to `MODEL_ESCALATION_MUTATION` (never lowered: the higher rank wins).
  The header says `ESCALATED`.
- **An explicit per-step hint wins over the escalation for that step** (1.8.5). An arm written for
  exactly this step is the plan author's decision and the implementer runs at it on a mutation-gated
  milestone too; the escalation applies to the steps with no arm of their own, which includes the
  `*)` fallback and a milestone-wide `Mn:*`. The driver measures "explicit" by asking
  `milestone_model` for `no-such-step` on the same milestone: a different answer means the step had
  an arm. The reviewer and the verifier escalate regardless. The header says `STEP HINT`. Measured on
  TT-4348 M8, where `M8:7|M8:8 -> sonnet` lost to the escalation ($6.38 on opus) and the hint was dead
  text.
- **The delta tier.** Review rounds from 2 on run at `MODEL_REVIEWER_DELTA` unless the milestone is
  correctness-critical; the verifier runs at `MODEL_VERIFIER`.
- **The routine tier for the reviewer** (1.8.6). A milestone not in `CORRECTNESS_CRITICAL` reviews at
  `MODEL_REVIEWER_ROUTINE` (template: sonnet) on every round; a critical one keeps `MODEL_REVIEWER`
  and the escalation. Measured on TT-4348 M9: three sonnet rounds, $8.95, found the two production
  defects in round 1, against $37.02 for four opus rounds on M8. Empty = every round at
  `MODEL_REVIEWER`.

## Driver steers

A steer that names work is a finding, not prose (1.8.5). `loop-driver.sh steer <MS> <role> <path>
<severity> "<text>"` appends `s<round>-driver-<k>` to
`review-results/<branch>_<ms>_round<n>_driver_issues.md` in the schema the reviewers write, owner =
the role given (the path must be in that role's write-scope, because a finding is routed by its
path), and re-runs `consolidate`. From there the brief cap lists it as `[YOURS]`, the router
dispatches on it, a verifier closes it by id with evidence, and `review_mode` prefers a verify pass
by intent over a full round while every open finding is a steer or a `--role` steered fix at HEAD.
The artifact is a findings carrier, never a round: the round counters skip it and `driver` is a
reserved dimension name. A steer written only into `LOOP_CLAUDE.md` is seen by none of these; on
TT-4348 M8 that cost a full opus round to say "steer gap 1 absent".

## The gate over the row (1.8.6)

A landed implementer row is a done step only while the gate at that HEAD is not red. The verdict is
loop-iteration's journal entry for the implementer in the row's commit window, or the ledger's column
14 `gate` (stamped at collect from the journal or from the gate the lost-JSON path ran); a red row
leaves the step open, the test-author is asked again for the SAME step with the first failing test in
its brief, and the 1.8.3 no_work step still closes it. No journal and no stamp is no measurement and
the row counts as before (a hand-recorded row). A test-only landing is the step's RED only when it
says so: RED in a commit message or the role's note, a journal entry that says red, a new file under
the test scope, an assertion-shaped line, or a test marker; a fixture fix leaves the RED owed.
`record ... --no-step` (and the driver's own row for the formatting commit after a budget-capped role)
carries `nostep` in column 13, is never a step, and is not a row the sequencer routes from.
`steer` refuses while a role is in flight (`<git-dir>/tddloop-role.pid`), and check-scope never
attributes the driver's steer artifact to a role (root `issues.md` keeps its R6). A fixed id (a commit
after it was raised touched the lines it names, or named its id, with the gate green at HEAD) is
`FIXED, AWAITING VERIFIER` in a brief, never `[YOURS]`. Killed rows are no
rounds and no stalls, and a milestone whose only artifacts on disk are driver steers never reads converged. TT-4348
M9 paid for each of these; M9_RETRO §2 has the numbers.

## The step tier (1.8.7)

While the steps are being built the implementer's brief asks for `loop-iteration.sh ... step`: build,
unit, integration and coverage, and STOP - mutation, review and e2e are the milestone's proof and the
full tier's review clause cannot pass before a review round exists (root `issues.md` is not
`converged` yet). Post-review, with no step left, the brief names the full gate again and the
milestone lands on it. The step counter, `open_step_red` and the ledger's column 14 read the STEP's
verdict of a journal entry (`journal_step_verdict`): a `NOT GREEN` whose cause is `mutation`, `review`
or `e2e` alone is green for the step, because gate.sh writes the first failing tier in tier order and
those three come last. The in-flight marker (`<git-dir>/tddloop-role.pid`) now carries the driver's
pid too and holds until the post-hoc scope audit has run, so a steer cannot land in the gap between
the CLI's exit and the audit. `steer` refuses a text over `STEER_MAX_CHARS` (1000) rather than cutting
it. An error envelope from the CLI (`is_error: true`) with zero tokens and HEAD unmoved is an `api` row
- the role never ran - that no window counts, and the run stops with exit 5 and the CLI's words; relaunch when the limit or outage
has cleared. TT-4348 M10 paid for each of these; M10_RETRO §2 has the numbers.

## The step's budget and the reviewer that stopped (1.8.8)

`token_budget(role, step)` in loop.config: `$2` is the TDD_PLAN step id the brief named (the ledger's
column 15 carries it; empty post-review), so a step the plan knows is large carries its own ceiling
instead of tripping R13-LANDED on the default, and a hot-but-landed row after every step is built is a
note, not a stop. A steer raised before its path existed is FIXED, AWAITING VERIFIER once the path
exists at a green HEAD. gate.sh's cause line names the task or test that FAILED before any generic
error shape, and skips JSON log lines. An owner is not retired at its done HEAD while one of its
findings names a path that does not exist there. RV stands aside while every open blocker/major is
fixed and awaiting the verifier. A reviewer that answers `blocked` with no findings is an `owed` row:
the round arithmetic skips it, the dimension is re-run at the same round, and RO stops the run
(ack-able) when a dimension stops twice within one round - a reviewer that stops twice is a failure to fix by
hand, and the relaunch re-runs the still-owed dimension. TT-4348 M11 paid for each of these;
M11_RETRO §2 has the numbers.

## The step that was already green, and the run's own log (1.8.9)

A `refuted` answer to a landed RED counts as the step, as `no_work` does, and a test-author that landed
nothing leaves the step counter's red flag as it was. Killed reviewer rows and `owed` rows do not anchor
the next review's base, and a round being resumed reads from the base its finished dimensions read
from. `close <MS> <id> "<reason>"` closes a finding its owner refuted and the driver accepts as refuted
by design. The converged exit reads the gate at HEAD: a red row there asks the RED's owner next instead
of printing "complete". R1's budget is floored from `--steps` (`(2 * steps - 2)` pairs + 2 + 2 per
review round) on both sides of the loop (`LOOP_STEPS`). A role under the driver (`LOOP_DRIVER=1`)
journals its trip and writes no `ESCALATION.md`; `record ... ack --signature last` reads the journal
when no file exists. The run's log and every role's brief and result JSON live under `<worktree>/.loop/`
(the installer ignores it). A blocked writing role's uncommitted, in-scope work is landed as
`wip(<role>)` when the step tier is green on it. A role's gate entry one commit back (over the driver's own
`chore(loop)` commits), by the role whose scope the commit stays within, is the gate at HEAD (roles
journal before they commit). The readers
journal with `MODE=fast`; the post-review implementer stays on its `[YOURS]` findings. The gradle build
tier runs `checkstyle<Set>` for every source set when the build declares the plugin. TT-4348 M12, M13
and M14 paid for each of these; their retros (§2) have the numbers.

## Mutation

`MUTATION_TARGETS` (loop.config) is the scope; `MUTATION_FLOOR_PCT` is the floor; the adapter's
`gate_mutation` is the executor. **Empty scope → SKIP** (nothing declared, nothing owed) — so a repo
that wants no mutation tier does nothing.

- Coverage says a line was EXECUTED. Mutation says an assertion would have NOTICED it change. They
  diverge exactly where it matters: one core at 100% line coverage still leaked six mutants.
- Keep the scope SMALL and on correctness CORES — pure decisions, no clock, no config, no adapter.
  Over wiring code most mutants are unreachable or equivalent and the number stops meaning anything.
- The list GROWS at each close-out and never ROTATES. A scope that moves with the milestone
  unmeasures the previous one: one loop reported `mutation 99%` for a whole milestone, measured
  entirely over the *previous* milestone's modules.
- **Full tier only.** `mid` and `step` return before it; `fast` never reaches `gate.sh`.
- The survivor list at the end of `$LOGDIR/mutation.log` is the deliverable — it names the assertion
  nobody wrote. The percentage only says how long the list is.
- pytest/mutmut: the same list must also be `[tool.mutmut] only_mutate` in `pyproject.toml`. The
  adapter cross-checks the two and refuses to score while they disagree.

## Churn (R8)

R8 catches a LEAP — an iteration that rewrote more than a milestone step should. Three things make it
measure that rather than something else:

- **Base.** Measured from the previous *journalled* iteration, not from `HEAD`. `git diff HEAD` is the
  dirty tree, so an iteration journalled after its step was committed measures a clean tree and scores
  zero — three milestones of one loop recorded `0 files / 0 loc` at the step's own commit while the
  same commits measured 120–988 lines from their parents. Ancestor-guarded, so the first iteration
  after a squashed milestone falls back to `HEAD` instead of charging itself the whole milestone before.
- **Unit.** Executable lines, via `lib/churn_loc.py` (Python files; raw diff lines for everything
  else, and for any stack whose adapter defines no `churn_loc`). Counting diff lines measured how much
  was WRITTEN: one milestone's worst trip was 619 diff lines holding ~105 executable ones. The loop's
  own evidence — `$SPEC_DIR`, `review-results/`, `issues.md` — is excluded, because it is what the loop
  writes ABOUT itself. Both numbers reach the journal (`… code loc (raw diff …)`); disagreement is
  itself signal.
- **Budget.** Per role, via `churn_budget()` and `churn_files_budget()` in `loop.config`. Both are
  optional and fall back to the flat `CHURN_LOC`/`CHURN_FILES`. A RED module's size is set by the step
  it specifies, so one budget for every role is either loose enough to ignore the implementer or tight
  enough to fire on every RED step. The FILE budget needed the same split independently: a flat 15
  tripped a test-author at 27 files threading a newly-mandatory parameter through 49 call sites.

## Milestone vocabulary

Milestones are named by the plan, not by the harness: `M0..Mn`, `C0..Cn`, anything matching
`<letters><digits>`. `checkpoint.sh` reads the journal's header SHAPE, never an `M[0-9]+` pattern, and
`ESCALATION.md`'s owner is read from the structured `milestone:` line the harness itself writes.

## e2e acceptance tags

`E2E_TAG_TICKET_PREFIX` (loop.config, default `true`) → `@<ticket>-<milestone>`. The default guards
one-ticket-per-loop repos, where every loop calls its single milestone M1 and a bare `@m1` matches the
*previous* ticket's acceptance test. Set it `false` for an epic-per-loop repo, where one ticket owns
many milestones and every bare tag is already unique.

## Tier parallelism

`IT_PARALLEL_WORKERS` (loop.config, default 1 = serial) applies to the INTEGRATION tier only, and only
where the adapter implements `it_parallel_args`. Measured on a 14-core machine, same tests and the same
coverage figure in every row:

| Tier | Serial | Parallel | Why |
|------|--------|----------|-----|
| unit (2696 pure tests) | 8.8s | 10.3s at `-n 4`, 12.0s at `-n auto` | Nine seconds cannot amortise worker startup. Unit tiers pass **no** `-n`, deliberately. |
| integration (375, containers) | 7:27 | **3:36** at `-n 4 --dist loadfile` | The tier ran at **6% CPU** — it waits on empty consumer polls and broker rebalances rather than computing. |

`--dist loadfile` is load-bearing wherever container fixtures are session-scoped: xdist gives each
worker its own session, so grouping by file keeps a module's containers on one worker instead of every
worker starting every container type. The worker count is therefore a **container multiplier**, not a
CPU count — `auto` on a 14-core machine can mean fourteen full container sets. Set it to 1 first if the
tier ever flakes. The `fast` tier passes `--no-cov` for a correctness reason, not a speed one: where
`--cov-report` is in the project's addopts, a SUBSET run would otherwise overwrite the gated
`coverage.xml` with the coverage of whichever handful of tests it selected.

## Re-installing

`install-harness.sh` used to `cp` every file unconditionally. That is why the repo that FOUND most of
this harness's hardening could not take its own recipe back — a re-install would have deleted its local
extensions, so it stopped re-installing, and the two copies drifted for a month.

An install now **stops before writing a byte** if an installed file differs from the template and is
not declared local, listing each one. Per file: declare it, upstream it, or `--force`. `--dry-run`
reports the plan and writes nothing. `loop.config` is never touched either way.

**Keep your own scripts out of `scripts/` top level.** `lib/harness_sha.sh` hashes every
`scripts/*.sh` and every `lib/*` file into the `HARNESS_SHA` the installer stamps, and `run` checks it
before it spends. A project script dropped beside the harness (`scripts/my-smoke.sh`) moves the hash
and `run` refuses with "scripts/ does not match scripts/HARNESS_SHA" although no harness file changed.
Put project scripts in a subfolder (`scripts/sf/`, `scripts/tools/`): subfolders other than `lib/` are
not hashed. A harness file you edit on purpose is a different case - declare it in `.upstream-exempt`
below, or re-run the installer.

`scripts/.upstream-exempt` declares what is local BY DESIGN — one entry per line, `#` comments ignored:

```
# a PATH: this file is never overwritten
adapters/pytest.sh
# a SYMBOL: the file holding it is not overwritten WHILE upstream lacks it
gate_cross_channel
CROSS_CHANNEL_TAGS
```

Prefer a SYMBOL. A path entry freezes a file forever and silently, which is the same class of failure
as the unconditional `cp`; a symbol entry stops protecting the moment upstream carries it, and the file
resumes updating. Either way the incoming version is written beside the kept one as
`<file>.upstream-new` — merge it and delete it. `harness-selfcheck.sh` fails a manifest whose entries
no longer name anything, because an entry that protects nothing still reads as protection.

### Drift the other way

`harness-selfcheck.sh` catches the template regressing underneath you. It has nothing to say when
**you** improve on the template — and that is the direction that actually happened: the published
recipe sat behind one repo by six generic mechanisms, some for months, one of which shipped a
self-check that failed on first install to every repo that took it. Found by accident.

`upstream-report.sh` closes that half. At each close-out `open-milestone-pr.sh` runs it, and it names
every commit in the milestone's range that touched `scripts/`, with the files each touched, minus what
`.upstream-exempt` declares. Run it any time: `scripts/upstream-report.sh [--since <rev>]`.

- **Reports, never gates.** It exits 0 unconditionally and its call site adds `|| true` on top. A gate
  row failing on un-upstreamed changes would block your milestone on *another* repo's review process.
- **Range:** since this branch left `BASE_BRANCH` — the same commits the PR will carry. A tag is the
  fallback, not the default, because the harness tags a milestone *after* its merge, so the newest tag
  is always at least one milestone stale (measured: newest tag `m7` while closing `C6`, thirteen
  milestones later). No base branch and no tag → whole history, and it says so.
- **Empty is stated in one line**, never silence: a clean milestone and a reporter that never ran must
  not look alike.
- **Exclusion is per HUNK, not per file.** A commit that extends a declared local function *and* fixes
  something generic in the same file still surfaces the generic half, marked `partially declared —
  1 of 2 hunks are local`. File-level exclusion would swallow it, which is this report's own failure
  mode wearing a different hat.
- Symbols are matched as **substrings of changed lines**, so pick one that appears in every line of
  the local extension. Declaring `gate_cross_channel` covers the executor but not a `gate "cross(prior
  @tags)" SKIP:build-FAIL` row elsewhere in the same commit; `cross(prior` covers both.
- `scripts/loop.config` and `scripts/.upstream-exempt` are excluded by construction — neither can ever
  be an upstream candidate.

`.gitignore` should exclude `issues.md` and `review-results/` — local gate/review scratch, not branch
artifacts — and `.coverage.*`, which `install-harness.sh` appends: one per test worker, owned by no
role, and the scope audit reads untracked files.
