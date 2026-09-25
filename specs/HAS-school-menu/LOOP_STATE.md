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
