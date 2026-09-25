# school_menu — TDD & Loop-Implementation Plan

Companion to `docs/0002-design.md` (v2, amended 2026-09-25) and `docs/0001-rfc.md` (approved 2026-09-25).
Test-first, milestone-by-milestone build an autonomous (or human) loop executes. Each milestone is
independently shippable, has machine-checkable gates, lands via PR, and the circuit breaker halts the
loop on stall/regression.

> Read order: §1 protocol → §1.1 roles → §2 breakers → §3 tests → current milestone in §5.

**Work item:** `HAS` — local key, **no Jira**. The Jira instance in `config/kitchen.env`
(`impetusde.atlassian.net`, project `TT`) is the Andercore work backlog; this is a personal repo, so
no Epic and no Stories exist and the driver performs **no** status transitions at PR boundaries.
LOOP_STATE.md and the merged PRs are the progress record.

**Deviations from `workflows:tdd-loop-plan-recipe`, stated up front:**

| Deviation | Why |
|---|---|
| No Jira ticket, no per-milestone Stories, no transitions | Personal repo; work Jira is the wrong home (operator decision). `<TICKET>` = `HAS`. |
| `skills.scaffold` is `none`; M0 is hand-generated | `python-services:scaffold` emits a FastAPI/SQLAlchemy hexagonal app. A HA custom component shares none of that layout. M0 is still ONE generated step + gate + one review round — it is not looped. |
| `correctness_critical: [M1, M2, M3]` with **no** mutation gate | Operator dropped the mutation tool. The designation is kept because it also drives the opus implementer/reviewer tier and `review_budget: 5`; the proof obligation those milestones carry is an 85% coverage floor plus named invariant gates instead of a mutation score. |
| `python-services:production-code-recipe` / `test-code-recipe` apply with an override | Where they conflict with Home Assistant integration conventions (entity/coordinator base classes, `async_setup_entry` signatures, `hass` fixtures), **hassfest and the HA developer docs win**. The recipes still govern type hints, no mutable defaults, no broad `except`, PEP 604, naming and test structure. |
| Root `CLAUDE.md` written directly, `codebase-analysis:onboarding-repository-recipe` skipped | The recipe calls for onboarding when the root file is absent. There is no code to onboard — the repo holds `docs/` and two PDFs. A minimal root file plus the managed `@import` block is written instead; run the onboarding recipe after M0 if the generated tree warrants it. |
| Coverage floor 80 (not 70) | The pure modules are trivially coverable and `config_flow.py` must be **100%** for the HA bronze tier anyway. |

## 1. Loop protocol

```
for milestone in MILESTONES:
    assert all previous milestones still green        # R3
    git checkout -b milestone/<id>-<slug> main        # DRIVER
    while not gates_all_green():
        check_circuit_breaker()                        # §2 → may HALT
        # RED  (TEST-AUTHOR — test paths only; runs formatter before commit)
        write_failing_test(step); assert FAILS for the right reason
        # GREEN (IMPLEMENTER — main paths only; cannot touch tests)
        implement_minimum(step); run(fast_suite); assert GREEN
        refactor(); record_iteration_metrics()
    review_loop(max=review_budget)                     # REVIEWER (read-only); R11
    run(full_gate_suite)                               # incl. e2e + review_clean
    open_milestone_pr(id)                              # DRIVER: PR→main; never push main / auto-merge
    # no Jira transition — local ticket scheme
    # post-merge: tag m<id> on main
```

Rules: test-first (R6) · one test/step (incremental) · smallest green · never weaken a test (R5) ·
implementer never edits tests · land via PR · append LOOP_STATE.md each iter.

## 1.1 Roles & separation of duties

| Role | Write scope | Does | May NOT | Lifetime |
|------|-------------|------|---------|----------|
| test-author | `tests/**` | RED: one failing test/step; owns tests; runs `ruff format` over the whole tree before the RED commit | touch `custom_components/**` | **warm** per milestone (SendMessage per step) |
| implementer | `custom_components/**` | GREEN: smallest pass; refactor prod | touch `tests/**`; sign off | **warm** per milestone |
| reviewer | review notes only | independent review (`python-services:review-loop`) | edit any code | **cold every review iteration** |
| driver | `scripts/**`, branches, `specs/HAS-school-menu/**` | gates, branch, PR, breakers, checkpoint | write feature or test code | session |

`test-author ≠ implementer ≠ reviewer`. Boundaries are path-scoped and tooling-enforced by
`running-tdd-loop-run-recipe` (`check-scope.sh` per role, RED-before-GREEN commit ordering).

```
warm (spawn once per Mn, SendMessage per step) → orientation cost paid once; steps still ONE at a time
reviewer cold → a reviewer holding its own prior judgements stops being an independent gate (R11)
separation comes from path scopes + RED-before-GREEN commit order, NOT from context freshness
```

Before driving: `unset CLAUDE_CODE_SUBAGENT_MODEL`. If it is exported, it silently overrides every
per-role model this plan declares, including the escalation tier, and nothing in the harness can detect it.

## 1.2 Code style: zero prose in code files

**Every file under `custom_components/school_menu/**` and `tests/**` carries zero comments and zero
docstrings.** No module docstrings, no function docstrings, no `#` comments, no commented-out code.
Enforced mechanically by `doc_loc: 0` (R12) — a single prose line trips the breaker on that iteration.

Where the words go instead:

| What | Where |
|---|---|
| Why a decision was made | `docs/0002-design.md` (§10 R1–R15) — the design is the record |
| Why a change diverged from the design | amend `docs/0002-design.md` first, then the commit message |
| What a test proves | the test **function name** and the assertion message — not a comment above it |
| What a module does | the module name and its public function signatures |
| Loop rationale, review history | `LOOP_STATE.md`, `LOOP_CLAUDE.md`, the PR body |

Consequences the roles must accept:
- Names and type hints carry the whole explanatory load. A line that needs a comment to be understood
  is a line that needs renaming or extracting.
- Regexes get a named constant (`ALLERGEN_GROUP`, `SUBJECT_KW`) rather than an explanatory comment.
- **Lint pragmas are prose too.** `# noqa`, `# type: ignore`, `# pragma: no cover` all count against
  R12. If a gate genuinely cannot pass without one, **stop and surface it** — do not add it silently
  and do not raise `doc_loc` to buy the green.
- Non-code files are unaffected: `README.md`, `docs/**`, `services.yaml`, `strings.json`,
  `hacs.json`, `manifest.json` and the GitHub workflows may carry whatever prose they need.

## 2. Circuit breaker

| ID | Trips when | Why |
|----|-----------|-----|
| R1 Iteration cap | `iters_in_milestone > budget[Mn]` with gates red | bounded effort |
| R2 Stall | 3 consecutive iters, no net-new passing tests, no gate moving green | spinning |
| R3 Regression | any previously-green milestone gate goes red | forward progress can't break shipped value |
| R4 Repeat failure | same failing test signature 3× with non-trivial diff between | wrong approach |
| R5 Test gaming | test count ↓, assertion count ↓, coverage ↓ >tol, `@pytest.mark.skip`/`xfail` added, OR implementer turn edits `tests/**` | can't buy green by weakening tests |
| R6 TDD violation | prod diff with no preceding test-author RED commit for the step, OR any turn edits outside its role scope | test-first + role separation |
| R7 Build broken | `ruff check` / import of the integration fails after an iter meant to fix it | hard stop |
| R8 Churn budget | > `churn_loc` LOC or > `churn_files` files in one iter (incl. new files) | unreviewable leaps |
| R9 Invariant breach | a declared invariant gate fails (path allowlist, data preservation, mailbox read-only, credential redaction) | non-negotiable |
| R10 Flake | a gate spec flips pass↔fail across reruns with no code change | untrustworthy signal |
| R11 Review not converging | `python-services:review-loop` still reports open blocker/major after `review_budget` iters | independent gate unmet |
| R12 Prose budget | **any** comment or docstring line in one iter (`doc_loc: 0`) | operator rule: code files carry zero prose — see §1.2 |

```yaml
circuit_breaker:
  churn_loc: 400
  churn_files: 15
  stall_iterations: 3
  repeat_failure_limit: 3
  coverage_drop_tolerance_pct: 2
  flake_rerun_count: 2
  review_budget: 3              # per-milestone override below: 5 on M1–M3
  doc_loc: 0                    # R12 at ZERO — every comment/docstring line trips it (§1.2).
                                # 0 is enforcing; EMPTY would mean off. Do not blank this.
review:
  recipe: python-services:review-loop
  blocking_severities: [blocker, major]
  reviewer_context: fresh
iteration_budget:               # (2 × steps − 2) + 2 + (2 × review_budget), harness 1.8.9 floor
  M0: 6                         # 2 steps (generate, e2e), review_budget 1 → 2 + 2 + 2
                                # recipe's nominal M0:4 assumes a scaffold skill that also writes
                                # the smoke test; none exists for a HA component, so the e2e is a
                                # real second step. Budgeted up front — a mid-flight raise is what R1 exists to prevent.
  M1: 26                        # 8 steps, review_budget 5 → 14 + 2 + 10
  M2: 24                        # 7 steps, review_budget 5 → 12 + 2 + 10
  M3: 24                        # 7 steps, review_budget 5 → 12 + 2 + 10
  M4: 14                        # 4 steps, review_budget 3 → 6 + 2 + 6
review_budget_override:
  M1: 5                         # correctness_critical — each round's fixes re-proven by execution
  M2: 5                         # before the next round starts
  M3: 5
```

Step counts above are sized **after** the split rules in `milestone-rules.md` were applied (see M1 note).
Gates are AND-ed. `PENDING` (infra absent) ≠ PASS. Never lower a threshold to go green.

## 3. Test architecture

| Layer | Tool | Runs | Gate at |
|-------|------|------|---------|
| unit (pure logic) | `pytest`, no `hass` fixture | every micro-cycle | every Mn |
| architecture (boundaries) | `tests/test_architecture.py` — asserts `parser/cleaning/models/date_logic` import nothing from `homeassistant.*` | every micro-cycle | every Mn |
| integration (HA runtime) | `pytest-homeassistant-custom-component`, `hass` fixture | milestone gate | M0–M4 |
| e2e (black-box through HA's public surface) | same, marked `@pytest.mark.m<n>` | milestone gate | every Mn |
| independent review | `python-services:review-loop` | milestone gate | every Mn (R11) |

There is no deployable artifact to probe over HTTP, so **e2e here means "through Home Assistant's public
surface only"**: set the entry up via the config flow, call `school_menu.import_pdf` (or drive the fake
IMAP server), then assert on `hass.states` and `persistent_notification` — never on internal objects.
That is the black-box equivalent and it is what each milestone's last numbered step owns.

Tag convention: **`@pytest.mark.m<n>`** plus `@pytest.mark.e2e`, registered in `pyproject.toml`
`[tool.pytest.ini_options] markers`. `loop.config` sets `E2E_TAG_TICKET_PREFIX=false`: this is an
epic-per-loop repo (one work item owns M0–M4) and no other loop exists here, which is the documented
case for the bare tag. `gate.sh`'s `e2e_tag` would in any case derive an empty ticket id from
`HAS-school-menu` — its regex wants `[A-Za-z]+-[0-9]+`.

Fakes and fixtures:
- **PDFs** — the two real files (`AHS Speiseplan 26-39.pdf`, `26-40.pdf`) move from `sample file/` to
  `tests/fixtures/`. **No synthetic PDFs**: every parser edge case is a `list[str]` fed to `parse_lines`.
- **Clock** — `freezegun` for pure `date_logic`; `async_fire_time_changed` for the midnight rollover.
- **IMAP** — an in-process fake `aioimaplib` server double that records the commands it received, so
  "`\Seen` was never set" and "`SINCE` + `FROM` were used" are assertions, not hopes.
- **Store** — `pytest-homeassistant-custom-component`'s `hass_storage` fixture.

## 4. Milestone map

Work item: `HAS` (local). No Jira Stories; the Story column is intentionally `n/a`.

| ID | Milestone | Shipped value | Story | Origin |
|----|-----------|---------------|-------|--------|
| M0 | Walking skeleton + harness | The integration installs, sets up and unloads in HA; hassfest, HACS and pytest are green in CI | n/a (local) | n/a |
| M1 | Manual import → today's lunch | You paste a PDF path and `sensor.school_menu_today` shows today's main course | n/a (local) | n/a |
| M2 | Correct every hour, safe on bad input | `tomorrow` works incl. weekends, midnight rolls over, a corrupt PDF never destroys the stored week | n/a (local) | n/a |
| M3 | Email ingestion with two senders | The weekly mail updates the sensors with no manual step, and the second teacher's copy changes nothing | n/a (local) | n/a |
| M4 | It's on the dashboard | A documented Mushroom card renders today and tomorrow, including the German empty state | n/a (local) | n/a |

Dependency spine is **strictly sequential** — M1 needs M0's harness, M2 needs M1's store and sensors,
M3 feeds M1's import path, M4 renders M2's attributes. Nothing here is honestly parallelisable, so no
worktree-per-track is declared.

## 5. Milestones in detail

### M0 — Walking skeleton + harness

**Value:** the integration can be installed and set up in Home Assistant, and the loop has an objective
signal to measure every later RED against.
**Entry:** none. Repo currently holds only `docs/` and the two sample PDFs, and is not a git repo.
**Parallel:** chained (everything depends on it).

**GENERATED, NOT LOOPED — one step.** There is no scaffold skill for a HA custom component, so the
driver writes this tree directly rather than paying test-author and implementer turns for boilerplate.

TDD steps:
1. Generate the skeleton, then run `scripts/gate.sh M0`:
   - `git init`, `.gitignore` (Python + HA + `.DS_Store`), initial commit of `docs/` and the sample PDFs
   - `custom_components/school_menu/`: `manifest.json` (`requirements: ["pypdf==6.19.0"]`,
     `dependencies: ["file_upload"]`, `config_flow: true`, `iot_class: local_polling`,
     `version`, `documentation`/`issue_tracker` → `https://github.com/helmerj/HA-Speiseplan`),
     `const.py`, `__init__.py` (`async_setup`, `async_setup_entry`, `async_unload_entry`),
     `config_flow.py` (single step, fixed unique id, `_abort_if_unique_id_configured`),
     `strings.json`, `translations/{en,de}.json`, `diagnostics.py` stub
   - `hacs.json` (`"homeassistant": "2026.9.3"`), `README.md`, `pyproject.toml`
     (ruff, pytest markers, coverage config)
   - `tests/conftest.py` (`pytest-homeassistant-custom-component` pinned to core 2026.9.3,
     `enable_custom_integrations`), `tests/fixtures/` with the two real PDFs moved out of `sample file/`
   - `tests/test_architecture.py` — the pure-module import boundary (empty modules pass it trivially now,
     and it fails the moment M1 puts a `homeassistant` import in `parser.py`)
   - `.github/workflows/{hassfest,hacs,tests}.yml`, matrix `{2026.9.3, latest stable}`
   - `scripts/gate.sh`, `scripts/check-scope.sh`, `scripts/loop-iteration.sh`, `scripts/checkpoint.sh`
2. RED the e2e acceptance (`@pytest.mark.m0`) → GREEN the generated tree passes it.

**e2e acceptance (`@m0`):** a config entry created through `async_step_user` reaches
`ConfigEntryState.LOADED`; a second attempt aborts with `already_configured`; unloading leaves no
lingering listeners (`hass.data[DOMAIN]` empty).

```yaml
success_gates:
  build: "ruff check . && ruff format --check . exit 0"
  unit_it: "pytest -q all green"
  coverage_line_pct: 80
  config_flow_coverage_pct: 100          # HA bronze tier
  hassfest: "PENDING until the first push — hassfest ships in the HA source tree, not the wheel, so
            `python -m script.hassfest` is not runnable locally; .github/workflows/hassfest.yml is
            the only executor. PENDING is not PASS."
  hacs: "PENDING until the first push — hacs/action runs in CI only. `ignore: brands` is set
        deliberately: school_menu is not registered in home-assistant/brands."
  ci_matrix: "PENDING until the first push. NOTE: the matrix legs are `pinned` and `phacc-latest`,
             NOT {2026.9.3, latest}. pytest-homeassistant-custom-component pins homeassistant
             exactly, so a leg that upgrades both still resolves HA to the plugin's pin. The real
             forward-compat probe is the non-blocking `ha-latest` job."
  e2e: "pytest -m m0 green"
  single_entry: "second config flow aborts already_configured"
  prose: "zero comment/docstring lines in custom_components/** and tests/** (R12 doc_loc 0)"
  review_clean: "review-loop → no open blocker/major"
```

### M1 — Manual import → today's lunch

**Value:** you call `school_menu.import_pdf` with a path under `/config/www` and
`sensor.school_menu_today` shows today's main course, surviving a restart.
**Entry:** M0 green.
**Parallel:** chained.
**Correctness-critical** (the parser is the part most likely to be silently wrong).

Step 1 is split per the opening-aggregate rule: the pure extraction seam lands before any HA wiring, so
the first implementer turn does not carry parser + store + coordinator + sensor + service at once.
Any integration-test module the steps will grow past ~400 lines is TWO modules from the start.

TDD steps:
1. RED `extract_lines()` over `26-40.pdf` returns the exact 34-line sequence (EN DASH intact, umlauts
   intact) → GREEN the pypdf call. This is the only function that may import pypdf.
2. RED `parse_lines()` derives `week_start` from the header range `28.09.26 – 02.10.26`, `%y` → 2026,
   and derives days 2–5 by offset; a non-Monday start normalises back → GREEN header parsing.
3. RED day anchors produce five `DayMenu`s and the FREITAG block stops at the `„` quote sentinel, not
   at the contact footer → GREEN anchor scan + footer sentinels.
4. RED `strip_allergen_codes` removes `(1a, 3)`, `(4)`, `(3, 7)` and preserves `(vegan)`/`(scharf)`;
   `Soja geschnetzeltes /Frische Kräuter` normalises to ` / ` → GREEN `cleaning.py`.
5. RED `MenuStore` round-trips a `ParsedWeek` through `Store` under the ISO-week key `2026-W40`,
   re-importing the same week overwrites rather than appends, `content_hashes` is a list → GREEN store.
6. RED the coordinator flattens the store into `dict[date, DayMenu]` and
   `sensor.school_menu_today` reports the cleaned main with `main`/`side`/`dessert`/`lines`/`date`/
   `weekday`/`source_file`/`ingested_at` attributes → GREEN coordinator + today sensor.
7. RED `school_menu.import_pdf(file_path=…)` imports a file under `/config/www`, **and**
   `/config/www/../../etc/passwd` raises `ServiceValidationError` after `Path.resolve()` → GREEN the
   handler and its allowlist. Absence of `config_entry_id` from the schema is asserted here.
8. RED the e2e acceptance (`@pytest.mark.m1`) → GREEN the integration passes it.

**e2e acceptance (`@m1`):** through HA's public surface only — set the entry up, call
`school_menu.import_pdf` with `26-40.pdf`, freeze the clock to Wed 2026-09-30, assert
`sensor.school_menu_today` state is `Chili sin Carne mit Sauer Sahne` with `side: Reis`,
`dessert: Blattsalat mit gerösteten Kernen`; reload the entry and assert the state survives.

```yaml
success_gates:
  build: "ruff check . && ruff format --check . exit 0"
  unit_it: "pytest -q all green"
  coverage_line_pct: 85
  architecture: "parser/cleaning/models/date_logic import no homeassistant.* — test_architecture green"
  path_allowlist: "traversal + outside-allowlist both raise ServiceValidationError"   # R9 invariant
  parse_fidelity: "both real PDFs parse to the expected ParsedWeek, allergen codes absent"
  e2e: "pytest -m m1 green"
  prose: "zero comment/docstring lines in custom_components/** and tests/** (R12 doc_loc 0)"
  review_clean: "review-loop → no open blocker/major"
```

### M2 — Correct every hour, safe on bad input

**Value:** the sensors are right at every hour of every day including weekends and midnight, and a
malformed PDF can never destroy the week you already have.
**Entry:** M1 green.
**Parallel:** chained.
**Correctness-critical** (date arithmetic and the data-preservation guarantee).

Any test module the steps will grow past ~400 lines is TWO modules from the start.

TDD steps:
1. RED `target_date()` for all seven weekdays: Mon–Thu `+1`; **Fri, Sat and Sun all resolve to Monday**;
   `today` is `None` on Sat/Sun; a DST-transition date and `2026-12-28` → `2026-W53` → GREEN `date_logic`.
2. RED `sensor.school_menu_tomorrow`, plus the literal string `none` with `reason: weekend` on a
   Saturday `today` and `reason: no_menu` on an unimported date → GREEN the tomorrow sensor.
3. RED the midnight rollover flips `today` without a re-import (fire `async_track_time_change` directly,
   assert no store read) and the listener is torn down on unload → GREEN the timer.
4. RED lenient line counts against `parse_lines`: a 2-line day yields `dessert is None`; a 4-line day
   keeps all four in `lines` with a WARNING and unchanged positional accessors; a day anchor with zero
   lines is omitted with a WARNING and produces no empty-day record → GREEN.
5. RED a PDF with no text layer, a week with no day anchors, and out-of-order anchors each raise the
   right `MenuParseError` reason; the service raises `HomeAssistantError`, a
   `persistent_notification` with id `school_menu_import_error` appears, **and the previously stored
   week is byte-identical afterwards** → GREEN error handling.
6. RED `sensor.school_menu_last_import` (timestamp, diagnostic category, `week`/`source_file`/`source`/
   `weeks_stored` attributes), the `file_id` upload path through `process_uploaded_file`, and the
   4-week prune keeping the newest four → GREEN.
7. RED the e2e acceptance (`@pytest.mark.m2`) → GREEN.

**e2e acceptance (`@m2`):** import `26-40.pdf`, freeze to Sat 2026-10-03 and assert `today` is
`none`/`weekend` while `tomorrow` shows Monday's main; then import a garbage PDF and assert both sensor
states are unchanged, the error notification exists, and the success notification does not.

```yaml
success_gates:
  build: "ruff check . && ruff format --check . exit 0"
  unit_it: "pytest -q all green"
  coverage_line_pct: 85
  data_preservation: "every MenuParseError path leaves .storage byte-identical"      # R9 invariant
  no_error_on_empty: "weekend + unknown date never raise and never log above debug"
  e2e: "pytest -m m2 green"
  prose: "zero comment/docstring lines in custom_components/** and tests/** (R12 doc_loc 0)"
  review_clean: "review-loop → no open blocker/major"
```

### M3 — Email ingestion with two senders

**Value:** the Sunday/Monday email updates the sensors within 15 minutes with no manual step, and the
second class teacher's copy of the same week causes no second import and no `last_import` churn.
**Entry:** M2 green.
**Parallel:** chained.
**Correctness-critical** (three-layer dedup ordering and credential handling).

Any test module the steps will grow past ~400 lines is TWO modules from the start.

TDD steps:
1. RED the options flow (`OptionsFlowWithReload`) accepts host/port/ssl/username/password/folder, a
   **two-element** `senders` list, `subject_filter` and `scan_interval_minutes` (min 5); credentials
   land in `entry.data`, never `entry.options`; `diagnostics.py` redacts both → GREEN.
2. RED the client issues `SEARCH SINCE <today-14d> FROM "<sender>"` **once per sender** and unions the
   UIDs, and fetches with `BODY.PEEK[]`; the fake server asserts `\Seen` was never set on any message
   → GREEN `imap_client.py`.
3. RED subject matching: RFC 2047-encoded `=?utf-8?…?=` subjects decode, matching is
   case-insensitive substring, `Fwd: Speiseplan KW40` matches, a non-matching subject and a
   non-matching sender are both ignored → GREEN.
4. RED `Speiseplan\s*KW\s*(\d{1,2})` yields the week; it serves as `fallback_week_start` when the PDF
   header is unreadable, and a KW that disagrees with the parsed header logs a WARNING while the
   **header wins** → GREEN.
5. RED dedup layers 1 and 2: the identical attachment from the second teacher is skipped before parsing;
   a byte-different but content-identical attachment appends to `content_hashes` and triggers
   **no** listener update and **no** `last_import` change → GREEN the dedup decision.
6. RED dedup layer 3 plus failure modes: a genuinely corrected menu for the same week overwrites and
   updates listeners; a bad password raises `ConfigEntryAuthFailed` and starts the reauth flow; a
   transient error raises `UpdateFailed` and notifies only after three consecutive failures → GREEN.
7. RED the e2e acceptance (`@pytest.mark.m3`) → GREEN.

**e2e acceptance (`@m3`):** seed the fake mailbox with both teachers' mails carrying the same
`26-40.pdf` and subject `Speiseplan KW40`; run one poll cycle; assert the sensors updated exactly once,
`sensor.school_menu_last_import` moved exactly once, no message was flagged `\Seen`, no notification was
raised, and no credential string appears in the log capture or in the diagnostics dump.

```yaml
success_gates:
  build: "ruff check . && ruff format --check . exit 0"
  unit_it: "pytest -q all green"
  coverage_line_pct: 85
  mailbox_read_only: "fake IMAP server records zero STORE/\\Seen commands"            # R9 invariant
  dedup_no_churn: "two mails, same week → 1 import, 1 last_import bump, 1 listener update"  # R9 invariant
  no_credential_leak: "password/username absent from caplog, attributes and diagnostics"     # R9 invariant
  e2e: "pytest -m m3 green"
  prose: "zero comment/docstring lines in custom_components/** and tests/** (R12 doc_loc 0)"
  review_clean: "review-loop → no open blocker/major"
```

### M4 — It's on the dashboard

**Value:** a documented Mushroom card that renders today and tomorrow, and says `Kein Mittagessen`
rather than the word `none` when there is no lunch.
**Entry:** M3 green.
**Parallel:** chained.
**Scope note:** Mushroom YAML only. The optional Lit card from RFC D4 is **out of this loop** — it would
add a second toolchain (Rollup/TS/vitest) to a plan whose stack profile can declare one adapter.

Any test module the steps will grow past ~400 lines is TWO modules from the start.

TDD steps:
1. RED the card's Jinja templates, rendered through
   `homeassistant.helpers.template.Template(...).async_render()` against real sensor states, produce the
   weekday, the date, the main, the side and the dessert → GREEN `cards/mushroom-today-tomorrow.yaml`.
2. RED the empty state renders exactly `Kein Mittagessen` for both `reason: weekend` and
   `reason: no_menu`, and never renders the literal string `none` → GREEN.
3. RED a 4-line day renders without dropping content, a 255-char truncated state still renders, and the
   `Stand: <last_import>` line formats as a German short date → GREEN.
4. RED the e2e acceptance (`@pytest.mark.m4`) → GREEN.

**e2e acceptance (`@m4`):** with `26-40.pdf` imported and the clock frozen to Wed 2026-09-30, render
the complete documented card YAML against the live `hass` and assert the output contains Wednesday's
three lines, tomorrow's main, and the `Stand:` line; re-freeze to Sunday and assert `Kein Mittagessen`
appears for `today` while `tomorrow` still renders Monday's menu.

```yaml
success_gates:
  build: "ruff check . && ruff format --check . exit 0"
  unit_it: "pytest -q all green"
  coverage_line_pct: 85
  yaml_valid: "every YAML block in README.md and cards/ parses"
  empty_state_de: "rendered output contains 'Kein Mittagessen' and never the bare token 'none'"
  e2e: "pytest -m m4 green"
  prose: "zero comment/docstring lines in custom_components/** and tests/** (R12 doc_loc 0)"
  review_clean: "review-loop → no open blocker/major"
```

## 6. Loop state & artifacts

In `specs/HAS-school-menu/`: `LOOP_STATE.md` (per-iteration journal) · `ESCALATION.md` (written on a
breaker trip) · `LOOP_CLAUDE.md` (resume file, 60% rule). Root `CLAUDE.md` `@import`s `LOOP_CLAUDE.md`
in a managed block; the rest of the root file stays the repo description.

```
context ~60% → scripts/checkpoint.sh refreshes LOOP_CLAUDE.md auto-state (ensures the root @import)
            → hand-update Learnings / Decisions / Current state / Next steps
            → commit LOOP_CLAUDE.md → reset context
resume → root CLAUDE.md @imports LOOP_CLAUDE.md → verify (git branch/status + scripts/gate.sh) → execute Next steps
```

`LOOP_CLAUDE.md` stays small (orientation, decisions, current state, next steps); the detailed journal
lives in `LOOP_STATE.md`.

## 7. Definition of Done

All milestone gates green · prior milestones still green · coverage ≥ 85 (80 at M0) ·
`config_flow.py` at 100% · every declared invariant proven by an executing test · every milestone
reviewed with no open blocker/major · `hassfest` and HACS validation green on the CI matrix ·
no open `ESCALATION.md` · the integration installs from `helmerj/HA-Speiseplan` as a HACS custom
repository and sets up through the UI with no YAML.

## 8. Stack profile (consumed by running-tdd-loop-run-recipe)

```yaml
stack:
  adapter: pytest
  paths:
    main: "custom_components/school_menu/**"
    test: "tests/**"
    e2e:  "tests/e2e/**"
  skills:
    reviewer: python-services:review-loop
    scaffold: none            # no HA-custom-component scaffold exists; M0 is hand-generated (see §5 M0)
    prod: python-services:production-code-recipe   # HA conventions + hassfest win on conflict
    test: python-services:test-code-recipe
  coverage_floor_pct: 80      # 85 from M1 onward; config_flow.py 100 (HA bronze)
  models: { planning: fable, driver: opus, test_author: sonnet,
            implementer: opus, implementer_routine: sonnet,
            reviewer: opus, search: haiku }
  efforts: { test_author: high, implementer: high, reviewer: high,
             scaffold: medium, jira_ops: low, search: low }
  correctness_critical: [M1, M2, M3]
  # No mutation gate in this plan (operator decision). The list is kept because it has two other
  # consumers: milestone_model() → the `implementer` (opus) tier, and ESCALATION → raises implementer
  # AND reviewer to the escalation tier. M1–M3 carry an 85% coverage floor plus the named R9 invariant
  # gates in place of a mutation score. M4 is routine.
  jira: none                  # local ticket scheme HAS — driver performs no transitions
```
