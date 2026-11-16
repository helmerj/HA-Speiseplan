# Bug: "Install" on `update.school_menu_version` fails since HACS became the Marketplace

## Branching

- **Ticket:** HAS-9 (local key, no Jira)
- **Base:** `origin/main` · **Branch:** `fix/HAS-9-marketplace-install`

## Description

On Home Assistant 2026.11 HACS ships as the **Marketplace**. Pressing *Install* on
`update.school_menu_version` raises `install_needs_hacs` ("HACS is not installed…"), although the
Marketplace tracks School Menu.

## Problem

`SchoolMenuUpdate.async_install` (`update.py`) looks up the store's update entity only under platform
`hacs`. On the operator's instance (2026-11-16) that entity is `update.school_menu_update`, platform
`marketplace`, unique id `1389147095` (the GitHub repository id, unchanged).

## Solution

Look the entity up under `marketplace` first, then `hacs` (older installs). User-facing texts say
"Marketplace (HACS)". Errors from the store pass through `install_failed` unchanged, e.g. the
Marketplace's one-time "accept the warning first".

## Steps to Reproduce

1. HA 2026.11 with the Marketplace tracking `helmerj/HA-Speiseplan`, no `hacs` integration.
2. School Menu 0.3.0+ sees a newer release → `update.school_menu_version` is `on`.
3. Settings → Updates → School Menu → Install → error `install_needs_hacs`.

Test: `tests/test_update.py::test_install_hands_the_exact_tag_to_the_marketplace` (fails before the fix).

## Root Cause Analysis

`const.HACS_DOMAIN = "hacs"` is the only platform searched in the entity registry. The store renamed
its integration domain; the unique id scheme stayed the same.

## Relevant Files

- `custom_components/school_menu/const.py` — `STORE_PLATFORMS = ("marketplace", "hacs")`.
- `custom_components/school_menu/update.py` — search both platforms; notification text.
- `custom_components/school_menu/strings.json`, `translations/*.json` — texts.
- `tests/test_update.py` — marketplace, precedence, hacs still works.
- `docs/0002-design.md` — amendment 2026-11-16 (HAS-9).
- `README.md`, `manifest.json`, `pyproject.toml` — wording, version 0.6.1.

## Step by Step Tasks

1. Design amendment. **Done when:** written.
2. Red: marketplace test fails with `install_needs_hacs`. **Done when:** observed failing.
3. Green: lookup over `STORE_PLATFORMS`. **Done when:** new and old install tests pass.
4. Texts, README, version. **Done when:** strings consistent.
5. Run Validation Commands. **Done when:** all pass.

## Acceptance Criteria

- Install hands the exact tag to the Marketplace entity when it exists; HACS still works; with
  neither, the translated "install via Marketplace (HACS)" error.
- Bug no longer reproducible; zero regressions.

## Validation Commands

```bash
PATH="$PWD/.venv/bin:$PATH" pytest -q tests/test_update.py --no-cov
PATH="$PWD/.venv/bin:$PATH" pytest -q
PATH="$PWD/.venv/bin:$PATH" ruff check . && ruff format --check .
```

## Notes

- The Marketplace needs a one-time acceptance of its warning in its UI before it installs anything;
  that is the store's rule, surfaced via `install_failed`.
- The Marketplace's own check had not yet seen v0.5.0/v0.6.0 on 2026-11-16 (still listed v0.3.0);
  it accepts a specific version anyway.
