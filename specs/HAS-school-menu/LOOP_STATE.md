# LOOP_STATE — school_menu (HAS)

Per-iteration journal. Newest milestone last.

## M0 — Walking skeleton + harness

Driven directly by the driver (bootstrap role). `SCAFFOLD_SKILL=''` — there is no scaffold skill for
a Home Assistant custom component, so M0 was generated rather than looped, per TDD_PLAN §5 M0.

| # | Stage | Result |
|---|-------|--------|
| 1 | Harness install (`install-harness.sh . pytest`) | 25 files, harness 1.8.9, selfcheck PASS |
| 2 | `loop.config` filled | SPEC_DIR, scopes, python skill ids, budgets, `DOC_LOC=0`, `CORRECTNESS_CRITICAL='M1 M2 M3'` |
| 3 | venv + deps | Python 3.14.7 (HA 2026.9.3 requires >=3.14.2), HA 2026.9.3, phcc 0.13.366, pypdf 6.19.0, ruff 0.16.9 |
| 4 | Skeleton generated | manifest/const/`__init__`/config_flow/diagnostics/strings/translations, hacs.json, pyproject, CI workflows |
| 5 | Tests | 3 e2e (`@m0`) + architecture + prose + setup + diagnostics → 6 passed, 4 skipped |
| 6 | `gate.sh M0` | **GATE: PASS** — build PASS, tests PASS, coverage 89% (floor 80), e2e(@m0) PASS |
| 7 | Review round 1 | one cold `python-services:review-agent`, report mode |

### Environment facts established

- HA 2026.9.3 requires **Python >= 3.14.2**. A 3.13 venv cannot resolve it.
- Every API in design §0 verified against the installed core: `ConfigFlowResult`,
  `OptionsFlowWithReload`, `AddConfigEntryEntitiesCallback`, `Store.__init__` signature.
- Gates need the venv on PATH: `export PATH="$PWD/.venv/bin:$PATH"`.
- `pythonpath = ["."]` in pyproject is required or `custom_components` is not importable by pytest.

### Harness defects found and fixed locally (both declared in `scripts/.upstream-exempt`)

1. **`gate_e2e` assumed Playwright.** `adapters/pytest.sh` required `e2e/playwright.config.ts`, so a
   pytest-marker e2e tier returned PENDING forever and no milestone could ever be green. Rewritten to
   `pytest -m "e2e and m<n>"`, preserving the zero-behind-the-tag → PENDING contract.
2. **`gate_build` could not fail.** Two independent causes, both silent:
   `compileall -q src` ran against a directory this repo does not have (compileall exits 0 on a
   missing dir), and `python3 -m ruff check .` **exits 0 while printing "Found N errors"** — only the
   `ruff` executable propagates the status. Proven by injecting an unused import and watching the gate
   report PASS. Now runs `compileall` over the real source dirs and shells out to `ruff check` +
   `ruff format --check`. Re-proven: injected import → `build FAIL`, clean tree → `build PASS`.

Both are generic to the pytest adapter, not to this repo — upstream candidates.

### Review round 1 — verdict `changes_requested` (2 blocker, 5 major, 3 minor), all blocker/major fixed

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | blocker | M0 unload acceptance was **vacuous** — deleting the body of `async_setup_entry` kept all 6 tests green, and a leaked bus + update listener also passed | Added the positive assertion (`entry_id in hass.data[DOMAIN]`) and a two-cycle listener invariant. **Both of the reviewer's mutants re-run and now FAIL the suite.** |
| 2 | blocker | `--cov-report=xml` in addopts let the unit-tier subset overwrite the gated artifact: real gated figure 89%, `config_flow.py` 64% against a declared bronze 100% | Added `--cov-fail-under=80` and moved config-flow coverage into the unit tier via `tests/test_config_flow.py`. Gated artifact now 98% overall, `config_flow.py` **100%**. |
| 3 | major | Prose detector blind to trailing comments and never scanned `tests/**`; R12's counter shares the bug | Rewrote on `tokenize.COMMENT`, scans both trees, plus two self-tests that prove the detector catches a pragma and a docstring. Added ruff `ERA`, `PGH`, `RUF100`. |
| 4 | major | Single-entry rule bypassable by an entry with `unique_id=None` (proven: 2 entries, both LOADED) | `"single_config_entry": true` in the manifest — HA enforces it in the flow manager, earlier and more completely than the unique-id abort. Reason becomes `single_instance_allowed`; the hand-rolled guard would have been unreachable so it was not kept. |
| 5 | major | `hacs.json` declared `render_readme` with no README in the repo | README.md written. `ignore: brands` set explicitly in the HACS workflow and recorded. |
| 6 | major | CI `latest` leg never installed latest HA — PHACC pins `homeassistant==` exactly, so both legs were byte-identical | Legs renamed `pinned` / `phacc-latest` (honest names) and a separate non-blocking `ha-latest` job added that installs HA `--no-deps` and runs with `-W error::DeprecationWarning`. |
| 7 | major | `PLATFORMS` unused; `async_unload_entry` returned `True` unconditionally — a silent M1 trap | Now forwards setups and returns `async_unload_platforms(...)`; `PLATFORMS: list[Platform]`. |
| 8 | major | `GATE: PASS` evaluated 6 of 11 declared gates; `coverage_floor(M0)` was **0** | Floor raised to 80 (gate now reads `coverage(98%)`). `hassfest`/`hacs`/`ci_matrix` marked **PENDING until the first push** in TDD_PLAN §5 M0 rather than claimed. |
| 9 | minor | `already_in_progress` abort had no string — user sees a raw key on a double-clicked dialog | Added to `strings.json` and both translations, with a test. |
| 10 | minor | Diagnostics test bypassed HA entirely | Now driven through `get_diagnostics_for_config_entry` over the real HTTP endpoint. |

Post-fix: **13 passed, 4 skipped, 98% coverage, `GATE: PASS`.**

## M1 — Manual import → today's lunch

Driven by the driver; test-first per step, single commit per operator instruction (which trades R6's
*mechanical* RED-before-GREEN proof for a procedural one — noted, not hidden).

| Step | Delivered |
|---|---|
| 1 | `extract_lines` (the only pypdf caller) against the real PDF |
| 2 | `parse_lines` header range: EN/EM/hyphen dashes, `%y`, offsets, non-Monday normalisation |
| 3 | Day anchors + 5 footer sentinels, name-based day→date mapping |
| 4 | `cleaning`: allergen groups stripped, `(vegan)`/`(scharf)` preserved, `/` spacing |
| 5 | `MenuStore`: ISO-week keys, `content_hashes` list, 4-week prune, per-day week lookup |
| 6 | `SchoolMenuCoordinator` + `sensor.school_menu_today` |
| 7 | `import_pdf` service with the `/config/www` + media_dirs allowlist |
| 8 | e2e `@m1` |

**Ground truth correction:** pypdf wraps 26-39's quote across two lines (`„Der Verstand … wir` /
`sen.“`), which `pdftotext` did not. The `„` sentinel fires on the first line so the continuation is
never reached — now pinned by `test_a_wrapped_quote_is_still_treated_as_footer`.

**Scope pulled forward from later milestones, deliberately and recorded:** `date_logic.target_date`'s
`tomorrow` branch (M2) and the three dedup layers (M3). Both were needed to make M1's sensor and
service coherent. Both now carry their own tests rather than shipping untested.

### Review round 1 — `changes_requested` (0 blocker, 4 major, 6 minor, 2 nit)

Full triage in `issues.md`. The reviewer confirmed **no bypass** of the path allowlist across 15
attack shapes, but proved the *test* of it was vacuous: deleting `.resolve()` left the whole suite
green, and `…/www/../secrets.yaml` was admitted because `PurePath` parents still contain `…/www`.

Nine mutants survived the suite at review time. After the fixes, **all nine are killed**:

| Mutant | Before | After |
|---|---|---|
| day mapping name-based → positional | survived | KILLED |
| footer: only the `„` sentinel | survived | KILLED |
| footer: drop the domain substring | survived | KILLED |
| remove the 5-line cap | survived | KILLED |
| `knows_hash` short-circuit disabled | survived | KILLED |
| `unchanged` branch disabled | survived | KILLED |
| duplicate-hash guard disabled | survived | KILLED |
| allowlist: drop `.resolve()` | survived | KILLED |
| sensor: ignore empty `lines` | survived | KILLED |

Two findings were resolved by **amending `docs/0002-design.md`** rather than the code: the
parse-failure notification must not echo file content (it would make `import_pdf` a partial
arbitrary-read oracle through the validate-then-open window), and `file_path` stays `required: true`
until `file_id` arrives in M2.

**Test-environment fix:** the harness defaults to US/Pacific, so a German wall-clock time landed on
the previous day. `tests/conftest.py` now pins HA to `Europe/Berlin`, which is what this integration
actually runs in.

Gate: build PASS, tests PASS (110 passed), coverage 97% (target 85), e2e(@m1) PASS, review PASS.

## M2 — Correct every hour, safe on bad input

Ships: the tomorrow sensor, the `last_import` diagnostic sensor, the midnight rollover timer, the
`file_id` upload path with an exactly-one-of rule, DST/year-boundary coverage, and parse-failure
data preservation asserted against the `.storage` file itself.

### Review round 1 — `changes_requested` (0 blocker, 5 major, 5 minor, 3 nit)

Full triage in `issues.md`. Three things worth carrying forward:

1. **A live wrong-day defect.** A runtime timezone change left both sensors on the old day for up to
   24 h — `today` reporting Monday as a weekend — because HA's time-change tracker only reschedules
   when it fires. Design §6 asserted the opposite; the code now listens for `EVENT_CORE_CONFIG_UPDATE`
   and **§6 has been amended** to record the real behaviour.
2. **Three timer mutants shipped green.** Hourly, per-minute and even a per-second midnight pattern
   all passed the suite, because both rollover tests fired once at `00:00:01` — any schedule that
   *includes* midnight passed. The e2e now counts fires across 48 h and requires exactly two.
3. **My own edit tooling produced a false record.** The M1 fix for "prune result reaches the caller"
   used a plain `str.replace` with no assertion; the pattern did not match, the edit silently did
   nothing, and `issues.md` recorded the finding as closed. The reviewer caught it as a nit. Every
   edit script now asserts its pattern matched before writing. **Lesson: an unasserted replace is a
   silent no-op, and a review record is only as true as the edit under it.**

Also fixed: `last_import` advanced for imports the coordinator had rejected (defeating the R15
staleness signal it exists to provide), an unknown `file_id` escaped as a raw `ValueError` on the
ordinary retry path, the upload notification named the ULID instead of the filename, and the only
upload test faked away both the delete-on-exit guarantee and the executor placement.

Sixteen mutants written across this milestone; all sixteen killed.

Gate: build PASS, tests PASS (144 passed), coverage 99% (target 85), e2e(@m2) PASS, review PASS.

## M3 — Email ingestion with two senders

Ships: the mailbox options flow (credentials in `entry.data`), a read-only IMAP poll
(`EXAMINE`, `BODY.PEEK`, header-first), the three-layer dedup, the subject-KW fallback and cross-check,
reauth on a bad password, and a failure notification after three consecutive transient failures.

**Inherited state.** The session found M3 half-built and uncommitted, with the gate red: the session
teardown was `finally: pass`, so a unit test failed and the real-socket suite hung forever in
`Server.wait_closed()`. The mailbox was also opened with `SELECT`, whose `CLOSE` expunges `\Deleted`
mail. Both are fixed before review; aioimaplib 2.0.1's `examine()` does not enter `SELECTED`, hence
`ReadOnlyIMAP4`.

### Review round 1 — `changes_requested` (0 blocker, 8 major, 12 minor, 4 nit)

Full triage in `issues.md`. Worth carrying forward:

1. **Dedup "no listener update" was false in production.** `DataUpdateCoordinator.always_update`
   defaults to True, so every duplicate-only poll fanned out to listeners. Only visible by counting
   listener calls; state-change events hide it because HA drops identical state writes.
2. **Per-sender fetch order let a stale forward overwrite a correction.** Fixed by ascending numeric
   UID order — and a string sort would pass every single-digit test, so one case uses 998/1002/1003.
3. **One malformed PDF silently blocked ingestion for the 14-day window**, because pypdf raises far
   more than `PdfReadError`. `extract_lines` is the pypdf seam, so it maps *any* exception.
4. **Operator decision (2026-09-26): the shrink guard stays for IMAP, manual wins.** Recorded in
   design §5.5.

### Review round 2 — `approved` (0 blocker, 0 major, 4 minor, 2 nit)

The four minors were surviving mutants (string UID sort, no `disconnect`, no teardown cap, no poll
deadline) — all closed with tests. **Learning:** `freezer` freezes the event loop's clock too, so a
test that relies on `asyncio.timeout` must not request it, or it hangs instead of failing.

Design amended first, per the standing rule: §5.4 (plain `OptionsFlow` + explicit reload, validation),
§5.5 (session shape, order, download volume, listener updates, shrink guard), §7 (IMAP parse failures,
notification dismissal).

Twenty-three mutants written across this milestone; all twenty-three killed.

Gate: build PASS, tests PASS (220 passed), coverage 98% (target 85), e2e(@m3) PASS, review PASS.

## M4 — It's on the dashboard

Ships: `cards/mushroom-today-tomorrow.yaml`, embedded verbatim in the README (a test enforces the two
stay identical), plus README sections for the mailbox and the card. The Lit card stays out of scope.

TDD: 17 RED tests written first against a card that did not exist; GREEN on the first card draft
except the README. Driver mutation on that draft exposed a vacuous kill: the README-equals-card test
fails on *any* card edit, so every mutant "died" until it was deselected. **Learning:** when one test
pins an artefact byte-for-byte, deselect it for mutation runs or the kill count means nothing.

### Review round 1 — `changes_requested` (0 blocker, 1 major, 9 minor, 5 nit)

The major was layout, not logic: Mushroom's `primary` is one ellipsised line, so the main moved into
the wrapping `secondary` and `primary` became the day label. Design §9 amended first. Eight of the
reviewer's eleven mutants had survived because assertions were substring checks — all now exact.
The harness also rendered non-strict; it now uses `async_render_to_info(strict=True)`, Mushroom's path.

### Review round 2 — `approved`

One README wording error closed; two nits accepted (see `issues.md`). Not verifiable offline: the
card rendered in a real Lovelace frontend at 400 px.

Gate: build PASS, tests PASS (246 passed), coverage 98% (target 85), e2e(@m4) PASS, review PASS.
