# Review — M3 (rounds 1–2)

status: converged

Loop: HAS-school-menu · Milestone: M3 · Reviewer: python-services:review-agent (cold, report mode)
Round 1: `changes_requested` — 0 blocker, 8 major, 12 minor, 4 nit.
Round 2: `approved` — 0 blocker, 0 major, 4 minor (test gaps), 2 nit. All four minors then closed.
Every fix is re-proven by an executed mutant: 23 written this milestone, 23 killed.
(The M2 record this file previously held is summarised in specs/HAS-school-menu/LOOP_STATE.md.)

## Found before review (the working tree as inherited)

- [x] [blocker] `imap_client.py` — `async_fetch_candidates` ended in `finally: pass`: the session
      was never closed. `test_the_session_is_always_closed` failed and the real-socket suite hung
      forever in `Server.wait_closed()`. → teardown now runs in the `finally`.
- [x] [major] the mailbox was opened with `SELECT`; `CLOSE` after a read-write `SELECT` expunges
      `\Deleted` messages — a mailbox mutation R5 forbids. → `EXAMINE`. aioimaplib 2.0.1's
      `examine()` never enters `SELECTED`, so `ReadOnlyIMAP4`/`ReadOnlyIMAP4SSL` fix the transition.

## Closed — round 1

- [x] [major] `coordinator.py` — every poll notified listeners, even for pure duplicates (HA's
      `always_update` defaults to True). → `always_update=False`. Mutant **KILLED**.
- [x] [major] `imap_client.py` — UIDs processed in per-sender order let teacher B's stale forward
      overwrite teacher A's later correction. → ascending numeric UID order. Mutants "reversed" and
      "string sort" **KILLED** (the latter needs UIDs 998/1002/1003).
- [x] [major] one malformed PDF (pypdf `KeyError`, `LimitReachedError`, …) aborted the whole poll
      for 14 days, silently. → `extract_lines` maps any exception to `MenuParseError`; rejection is
      per attachment, notified once, hash remembered. Mutants **KILLED**.
- [x] [major] an undocumented "refuse a week with fewer days" rule. → **operator decision
      2026-09-26:** kept for IMAP only, refusal notified once and remembered; a manual import always
      overwrites. Design §5.5 amended. Mutants "guard for manual too" and "guard removed" **KILLED**.
- [x] [major] `ssl.create_default_context()` on the event loop every poll. →
      `homeassistant.util.ssl.client_context()`; factory now unit-tested.
- [x] [major] every poll re-downloaded 14 days of mail in full. → header-first fetch, then an
      in-memory `(UIDVALIDITY, UID)` cache, keyed only after ingest. Four mutants **KILLED**.
- [x] [major] the `@m3` e2e lacked three of its five required assertions. → rewritten: mail arrives
      after setup, two time-driven poll cycles, exactly one state change per sensor, no `\Seen`, no
      notification, no credential in caplog or diagnostics; identical and re-attached bytes.
- [x] [major] layer 2 was never tested through a poll; "skipped before parsing" never asserted. →
      `tests/test_imap_dedup.py`.
- [x] [minor] no explicit timeouts; a refused connect surfaced as an empty `TimeoutError` after 10 s
      plus "Task exception was never retrieved"; transport never closed. → 30 s/command, 120 s/poll,
      5 s/teardown step, `_client_task` awaited, `disconnect()` closes the transport.
- [x] [minor] first poll blocked setup → background task. [minor] IMAP parse failure raised no
      notification → it does (§7). [minor] `BAD` / `NO [UNAVAILABLE]` started reauth → transient.
      [minor] failure notification never dismissed → dismissed on success. [minor] blank host,
      non-address senders, empty subject filter accepted → rejected. [minor] design said
      `OptionsFlowWithReload` → §5.4 amended. [minor] password/username in `ImapSettings` repr →
      `repr=False`. [minor] aioimaplib debug-log masking → documented §5.5. [minor] reauth test never
      saw a flow start → asserted. [minor] missing tests → added. [minor] 580-line test module →
      split into `test_imap.py`, `test_imap_dedup.py`, `test_imap_failures.py`.

## Closed — round 2 (test gaps; code was already correct)

- [x] [minor] string UID sort survived → multi-digit UID case. **KILLED**.
- [x] [minor] removing `disconnect` survived; [minor] removing the teardown cap survived → a
      real-socket server that ignores `LOGOUT`, asserting prompt disconnect. Both **KILLED**.
- [x] [minor] removing the 120 s poll deadline survived → stalled-session test. **KILLED**.

## Accepted, not changed

- [nit] `rejected_hashes` / `seen_messages` are per HA run: after a restart or reload the 14-day
      window is downloaded once more and a still-rejected attachment notifies once more. As designed.
- [nit] a non-parse exception during ingest (e.g. a storage write error) surfaces as HA's
      "Unexpected error" and does not count towards the 3-failure notification.
