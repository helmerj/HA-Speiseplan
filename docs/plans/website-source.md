# Feature: the school website PDF as a second, time-boxed source

## Branching

- **Ticket:** HAS-7 (local key, no Jira)
- **Base:** `origin/main` (this repo has no `dev`; `main` is the PR base, verified via `git branch -a`)
- **Branch:** `feature/HAS-7-website-source`
- **Order:** HAS-6 (`feature/HAS-6-check-mail-feedback`) is still uncommitted and edits the same
  `coordinator.py` and `docs/0002-design.md`. HAS-7 branches off `main` **after HAS-6 is merged**.

**Status:** approved 2026-11-16, implemented. The design amendment (task 1) is applied on the HAS-7 branch
before any code, per the standing rule.

## Feature Description

The school publishes the current week's menu at a fixed public URL:
`https://www.annie-heuser-schule.de/wp-content/uploads/AHS-Speiseplan.pdf`.
It becomes a second source next to the IMAP mailbox. It is polled every 2 hours, but only from
Sunday 18:00 until the current school week is stored, so it fills the gap when the teachers' mail is
late or missing and costs nothing in the rest of the week.

Verified on 2026-11-16: the file is a 2-page, 108 kB PDF with a text layer; `extract_lines` +
`parse_lines` read it unchanged (`WOCHENPLAN`, `09.11.2026 – 13.11.2026`, `MONTAG` …). The server sends
`ETag`, `Last-Modified: Sun, 08 Nov 2026 19:27:33 GMT` and `Cache-Control: max-age=31536000` — on
Monday of KW 47 it still served KW 46, so a stale file is the normal case, not an error.

Success: a week that arrives only on the website is stored within 2 hours of being uploaded, and no
request is made once the week is present.

## User Story

As a parent
I want the integration to pick up the menu from the school website when no mail has brought it
So that the card shows this week's lunch even when the mail is late or never comes

## Problem Statement

The mailbox is the only automatic source. When neither teacher forwards the PDF, the sensors show
`none` all week although the school has published the menu publicly.

## Solution Statement

1. **Window (pure, `date_logic.py`).** `web_check_week(now) -> datetime.date | None` returns the
   Monday of the week to look for, or `None` outside the window:
   - Sunday from 18:00 local → next Monday's week.
   - Monday 00:00 – Friday 23:59 → this week's Monday.
   - Saturday, and Sunday before 18:00 → `None`.
2. **Gate.** A check runs only when the window yields a Monday **and** the store holds no record for
   that ISO week (`MenuStore.has_week(key)`). Once the week is stored — from mail, website or a
   manual import — checks stop until next Sunday 18:00.
3. **Timer.** `async_track_time_change(hour=range(0, 24, 2), minute=0, second=0)` — every even hour,
   Sunday 18:00, 20:00, 22:00, Monday 00:00, … Plus one background check at entry setup, so an HA
   restart does not wait up to 2 hours.
4. **Fetch (`web_client.py`).** `async_get_clientsession(hass)`, GET with `Cache-Control: no-cache`
   (the server announces a one-year cache), conditional on the last `ETag` / `Last-Modified` seen in
   this HA run. 30 s timeout, 10 MB cap. `304` → nothing to do. Any other non-`200`, timeout or
   network error → `WARNING` log, no notification (the mailbox stays primary; a renamed file is the
   same silent stop as a changed mail subject, §10 R15).
5. **Ingest — the IMAP path, unchanged rules.** The bytes go through the same three-layer dedup and
   the shrink guard as a mail attachment, with `source = "web"`. `source_file` is
   `AHS-Speiseplan.pdf`. A stale file (last week) hits layer 1 or imports an older week, which is
   harmless; the gate keeps polling because the target week is still missing. A parse failure takes
   the existing per-attachment path: one `school_menu_import_error` notification per HA run, hash
   remembered.
6. **Unattended sources.** `async_import_week`'s IMAP-only branches (hash short-circuit, shrink guard)
   apply to `UNATTENDED_SOURCES = {SOURCE_IMAP, SOURCE_WEB}`. Manual import is unchanged.
7. **Serialisation.** The web check has its own lock (overlapping checks fetch once). It does not
   take `poll_lock`, so a running website fetch never makes a manual mail check report "skipped".
8. **Configuration.** New key `web_url`, default the school URL, read as
   `entry.data.get(CONF_WEB_URL, DEFAULT_WEB_URL)` — existing installs get it without a migration.
   The options form gains one optional field; clearing it disables the source. Works with or without
   a mailbox configured.
9. **No success notification** (§10 R8 extends to the web source); `INFO` log and
   `sensor.school_menu_last_import` (`source: web`) carry it.

## Relevant Files

### Existing Files to Modify

- `docs/0002-design.md` — amendment 2026-11-16 (HAS-7): §1 component diagram, new §5.6 "Website
  source", §7 rows for web failures, §10 R8/R15 notes.
- `custom_components/school_menu/const.py` — `SOURCE_WEB`, `UNATTENDED_SOURCES`, `CONF_WEB_URL`,
  `DEFAULT_WEB_URL`, `WEB_CHECK_HOURS`, `WEB_WINDOW_START_HOUR = 18`, `WEB_TIMEOUT_SECONDS = 30`,
  `WEB_MAX_BYTES`.
- `custom_components/school_menu/date_logic.py` — `web_check_week(now)`.
- `custom_components/school_menu/store.py` — `MenuStore.has_week(week_key)`.
- `custom_components/school_menu/coordinator.py` — `_async_ingest` takes payload, filename and source
  instead of a `MailAttachment` (IMAP call site adapts); `UNATTENDED_SOURCES` in `async_import_week`;
  `async_check_website()`.
- `custom_components/school_menu/__init__.py` — even-hour timer and setup check, both via
  `entry.async_on_unload` / `entry.async_create_background_task`.
- `custom_components/school_menu/config_flow.py` — optional `web_url` field in the options form;
  validation: empty or `https://` URL.
- `custom_components/school_menu/strings.json`, `translations/*.json` — label and error text.
- `custom_components/school_menu/diagnostics.py` — `web_url` and last fetch status (no secrets).
- `README.md` — the second source, its window, how to disable it.
- `pyproject.toml` — marker `m7: website source (HAS-7) acceptance`; version 0.5.0.
- `custom_components/school_menu/manifest.json` — version 0.5.0.

### New Files to Create

- `custom_components/school_menu/web_client.py` — `async_fetch_menu_pdf(session, url, validators)
  -> WebFetchResult` (bytes or not-modified, new validators). The only HTTP caller.
- `tests/test_web_window.py` — pure window table.
- `tests/test_web_client.py` — fetch behaviour against `aioclient_mock`.
- `tests/test_web_source.py` — coordinator + timer behaviour, `@pytest.mark.m7` acceptance.

## Implementation Plan

### Phase 1: Foundation

Design amendment, constants, the pure window, `MenuStore.has_week`.

### Phase 2: Core

`web_client.py`, generalised ingest, `async_check_website`.

### Phase 3: Integration

Timer and setup check, options field, diagnostics, README, version.

## Execution Topology

Single lane, sequential: every task after 3 touches `coordinator.py` or depends on it. No parallel
units.

```
1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10
```

## Step by Step Tasks

Each code task is contract → red → green → verify: the test is written and fails first.

1. **Design amendment.** Add amendment 2026-11-16 (HAS-7) to `docs/0002-design.md` with the solution
   above. **Done when:** the operator has approved the amended design.
2. **Window.** `tests/test_web_window.py`: parametrised table — Sun 17:59 → `None`; Sun 18:00 → next
   Mon; Mon 00:00 → same Mon; Fri 23:59 → that Mon; Sat 12:00 → `None`; Sun 18:00 on 2026-12-27 →
   2026-12-28 (`2026-W53`). Implement `date_logic.web_check_week`. **Done when:** table green.
3. **Store lookup.** `tests/test_store.py`: `has_week` true for a saved week, false for an unknown
   one and after pruning. Implement `MenuStore.has_week`. **Done when:** tests green.
4. **Fetch.** `tests/test_web_client.py` with `aioclient_mock`: 200 returns bytes and validators;
   request carries `Cache-Control: no-cache` and `If-None-Match` when an ETag is known; 304 →
   not-modified; 404/500, timeout and `ClientError` → `WebFetchError`; body over the cap →
   `WebFetchError` without reading it all. Implement `web_client.py`. **Done when:** tests green.
5. **Generalised ingest.** Existing IMAP tests stay green after `_async_ingest` takes
   `(payload, filename, *, source, fallback_week_start, expected_week)`. New tests: shrink guard and
   hash short-circuit apply to `source="web"`; manual import still overwrites. **Done when:** full
   suite green.
6. **Website check.** `tests/test_web_source.py`: inside the window with the week missing → one GET,
   week stored with `source: web`, listeners updated, no notification; week already stored → no GET;
   outside the window → no GET; stale PDF (previous week) → previous week stored or skipped, target
   still missing, next tick fetches again; 304 → no ingest; fetch error → `WARNING`, no notification,
   store untouched; unparseable PDF → one `school_menu_import_error` per run; overlapping checks
   fetch once. Implement `SchoolMenuCoordinator.async_check_website`.
   **Done when:** tests green.
7. **Timer and setup.** Tests with `freezer` + `async_fire_time_changed` (no `asyncio.timeout` in
   these tests — LOOP learning): Sunday 16:00 → 18:00 → 20:00 makes GETs at 18:00 and 20:00 only;
   after the week is stored, 22:00 makes none; setup inside the window checks once; unload cancels
   the timer; `web_url` empty → no GET ever. **Done when:** tests green.
8. **Options.** `tests/test_config_flow.py`: options form shows `web_url` with the default; empty
   saves and disables; `http://` or garbage → error `invalid_url`; mailbox fields unchanged.
   Implement in `config_flow.py`, `strings.json`, translations. **Done when:** tests green.
9. **Diagnostics, README, version.** Diagnostics test covers `web_url`; README section; version 0.5.0
   in `manifest.json` and `pyproject.toml`; marker `m7`. **Done when:** diagnostics test green,
   hassfest-relevant files consistent.
10. **Run Validation Commands.** **Done when:** every command below passes.

## Testing Strategy

### Unit Tests

Window table (pure), `has_week`, `web_client` against `aioclient_mock`, the ingest source rules.

### Integration Tests

Coordinator + timer through HA's test harness: time-driven GETs, gate stops after import, stale file,
errors, options flow. No real network: `aioclient_mock` only.

### Edge Cases

- Website still serves last week on Monday (observed 2026-11-16).
- Same week from mail and website with different bytes → layer 2, no listener update.
- Website copy has fewer days than the mailed one → shrink guard refuses it.
- Holiday week: nothing published → 12 conditional GETs a day Mon–Fri, no alarm.
- Week 53 / New Year.
- HA restart on Monday morning → setup check runs immediately.
- No mailbox configured → website source still works.

## Acceptance Criteria

- From Sunday 18:00 to Friday 23:59, while the target week is not stored, exactly one GET per even
  hour plus one at setup; no GET otherwise.
- A valid PDF for the target week is stored with `source: web` and updates both menu sensors.
- No GET after the target week is stored, whichever source stored it.
- Network/HTTP failures produce a `WARNING` log and no notification; parse failures produce one
  `school_menu_import_error` notification per HA run.
- Clearing `web_url` in options stops all requests.
- Zero regressions: the full existing suite stays green; coverage ≥ 85% (currently 98%).

## Validation Commands

```bash
PATH="$PWD/.venv/bin:$PATH" pytest -q
PATH="$PWD/.venv/bin:$PATH" pytest -q -m m7
PATH="$PWD/.venv/bin:$PATH" pytest -q --cov=custom_components/school_menu --cov-fail-under=85
PATH="$PWD/.venv/bin:$PATH" ruff check . && ruff format --check .
```

## Verification Plan

- Per unit: red → green per task above.
- Pre-PR: `/code-review` on the branch diff.
- PR stage: CI (hassfest, HACS, pytest matrix 2026.9.3 + latest).

## Notes

- **Defaults chosen, confirm at approval:** window starts Sunday 18:00 and ends Friday 23:59
  (Saturday never polls); the source is on by default; failures are log-only.
- No new library: HA's shared `aiohttp` session.
- `manifest.json` `iot_class` is already `cloud_polling`.
- Out of scope: making `button.school_menu_check_mail` also fetch the website. Possible follow-up.
- `claude/sync.json` is absent in this repo → no context delta recorded.
