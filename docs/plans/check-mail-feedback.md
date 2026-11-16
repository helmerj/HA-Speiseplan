# Feature plan — a manual mail check reports what it found

**Ticket:** HAS-6 (local) · **Branch:** `feature/HAS-6-check-mail-feedback` off `origin/main`
(this repo has no `dev`; `main` is the PR base).
**Status:** draft, awaiting approval. Design amended first: `docs/0002-design.md`, amendment
2026-11-05 (HAS-6), §7 and §10 R8.

## Description

`button.school_menu_check_mail` and `school_menu.check_mail` re-read the mailbox but say nothing when
every menu found is already stored. On 2026-11-05 the KW 46 mail (16:01) was imported by the 16:15
poll; the 16:41 button press found it again, recorded nothing and stayed silent, which read as
"the import misses the mail".

## User story

As a parent, I want a manual mail check to tell me what it found, so that I can tell "already
imported" apart from "no mail found" without reading debug logs.

## Problem

- `SchoolMenuCoordinator.async_check_mail_now` (`coordinator.py`) returns silently on success.
- `_async_ingest` skips known hashes with a DEBUG log; `async_import_week` returns `False` for an
  unchanged week with a DEBUG log. Neither outcome reaches the caller.
- `MenuStore` (`store.py`) can say *whether* a hash is known (`knows_hash`), not *which week* holds it.

## Solution

1. `MenuStore.week_key_for_hash(content_hash) -> str | None` — the ISO week key whose record lists
   the hash.
2. A small frozen outcome record in the coordinator (`imported`, `already_stored`, `refused`,
   `found`), active only while a forced check runs (`self._report is not None`). `_async_ingest`,
   `_reject` and `async_import_week` record into it; scheduled polls leave it `None` and behave
   exactly as today.
3. After a successful forced check, `async_check_mail_now` builds the German message (precedence:
   imported → already stored → no mail; refused count appended) and posts it with
   `notification_id=NOTIFICATION_OK_ID`. Skipped/failed checks raise as today, no notification.
4. Week labels: `KW <iso week>` (e.g. `KW 46`), distinct, ascending.

## Relevant files

- `custom_components/school_menu/store.py` — `week_key_for_hash`.
- `custom_components/school_menu/coordinator.py` — outcome record, recording, message, notification.
- `tests/test_store.py` — hash lookup.
- `tests/test_check_mail.py` — the three outcomes, refused suffix, scheduled poll stays silent,
  failed/skipped check posts nothing.
- `pyproject.toml` — marker `m6: manual mail check outcome (HAS-6) acceptance`.
- `README.md` — one sentence on the check-mail notification.
- `custom_components/school_menu/manifest.json`, `pyproject.toml` — version 0.4.0.

## Implementation plan

- **Phase 1 Foundation:** store lookup.
- **Phase 2 Core:** outcome recording and message building in the coordinator.
- **Phase 3 Integration:** notification on the button and the action; docs and version.

## Step by step tasks

1. **Red — store lookup.** Test in `tests/test_store.py`: a saved week's hash maps to its key; an
   unknown hash maps to `None`. Implement `MenuStore.week_key_for_hash`.
   **Done when:** the new store tests pass.
2. **Red — outcomes.** Tests in `tests/test_check_mail.py` (marker `m6`), using `FakeImapServer`:
   - new KW 40 mail → `Neuer Speiseplan importiert: KW 40 (5 Tage).`
   - same mail checked again (after the 60 s cooldown) → `Kein neuer Speiseplan. Bereits importiert: KW 40.`
   - two teachers' copies of the same week → one `KW 40`, not two.
   - no matching mail → `Keine Speiseplan-Mail in den letzten 14 Tagen gefunden.`
   - unreadable PDF next to an already stored one → suffix `1 Anhang/Anhänge nicht übernommen, …`
     and the `school_menu_import_error` notification still appears.
   - a scheduled `async_refresh` posts no `school_menu_import_ok` notification.
   - a failed forced check (transport error) and a skipped one (cooldown) post none.
   **Done when:** the tests fail for the missing notification only.
3. **Green — coordinator.** Implement the outcome record and recording in `_async_ingest`,
   `_reject`, `async_import_week`; message building and notification in `async_check_mail_now`.
   **Done when:** all task 2 tests pass, and every existing test passes unchanged.
4. **Docs and version.** README sentence; version 0.4.0 in `manifest.json` and `pyproject.toml`.
   **Done when:** the README byte-for-byte artefact test still passes.
5. **Run Validation Commands.**
   **Done when:** every command below exits 0.

## Testing strategy

Integration tests through the real button and action with `FakeImapServer`, as in the HAS-1 tests.
Assertions read `persistent_notification` contents by id. Mind the learning in `LOOP_CLAUDE.md`:
`freezer` freezes the event loop clock; the cooldown test moves the frozen time explicitly.

## Acceptance criteria

- A forced check that imports a week posts `school_menu_import_ok` naming that week and its day count.
- A forced check that finds only stored menus posts `Kein neuer Speiseplan. Bereits importiert: KW nn.`
- A forced check that finds no matching mail posts the "keine Speiseplan-Mail" text.
- Refused attachments are counted in the text and still raise their own error notification.
- Scheduled polls post no success notification (§10 R8 for the timer unchanged).
- Skipped and failed forced checks post no outcome notification and still raise.
- Zero regressions: full test suite green, coverage ≥ 98 %.

## Validation commands

```bash
PATH="$PWD/.venv/bin:$PATH" scripts/gate.sh M4
```

```bash
.venv/bin/pytest -q -m m6
```

```bash
.venv/bin/ruff check . && .venv/bin/ruff format --check .
```

## Notes

- Release: `v0.4.0` after merge (minor, new user-visible behaviour). HACS / `update.school_menu_version`
  announce it.
- No new libraries, no config-entry migration, no new translation keys (notification texts are German
  literals, matching the existing notifications).
- Not covered: the KW 45 gap of 2026-11-05 — no KW 45 mail was sent (operator confirmed).
