# Review — M2 (round 1)

status: converged

Loop: HAS-school-menu · Milestone: M2 · Reviewer: python-services:review-agent (opus, cold, report mode)
Round 1 verdict as delivered: `changes_requested` — 0 blocker, 5 major, 5 minor, 3 nit.
All major and minor findings resolved; every fix re-proven by executing a mutant, not by inspection.
(The M1 record this file previously held is summarised in specs/HAS-school-menu/LOOP_STATE.md.)

## Closed this round

- [x] [major] `__init__.py:167` — the rollover's once-per-day cadence was unpinned: hourly, per-minute
      and **per-second** timer patterns all passed the 128-test suite. → resolved: the `@m2` e2e now
      fires on a 15-minute grid across a 48 h window and asserts the callback ran **exactly twice**.
      Re-proven: mutants "hourly" and "every minute" both **KILLED**.
- [x] [major] `tests/test_date_logic.py:91` — the test named for DST passed bare `date` values to a
      pure function, touching no clock and no timezone, and every weekday in it was already covered.
      → resolved: renamed to say what it actually does, and three clock-level `@m2` tests added that
      fire the real timer across spring-forward and fall-back in Europe/Berlin and assert the
      displayed date advances by exactly one day.
- [x] [major] `__init__.py:163` — **a runtime timezone change left both sensors on the wrong day for
      up to 24 h**, reporting Monday as a weekend. `_TrackUTCTimeChange` only reschedules when it
      fires and registers no core-config listener. Design §6 claimed the opposite. → resolved: the
      entry now listens for `EVENT_CORE_CONFIG_UPDATE` and refreshes immediately. Re-proven: mutant
      "tz listener removed" **KILLED**.
- [x] [major] `__init__.py:63` — an unknown or already-consumed `file_id` escaped as a bare
      `ValueError` traceback. Uploads are deleted on first use, so this is the ordinary retry path.
      → resolved: raised as `ServiceValidationError` with an `upload_not_found` key in all three
      translation files. Re-proven: mutant "unknown id escapes as ValueError" **KILLED**.
- [x] [major] `tests/test_services.py:246` — the only upload test faked `process_uploaded_file`
      entirely, so neither the delete-on-exit guarantee nor the executor placement was pinned.
      → resolved: `tests/test_upload.py` builds a real `FileUploadData` and asserts the week imported,
      the upload directory is gone, and a second call fails cleanly. Re-proven: mutants "skip the
      context manager teardown" and "parse on the event loop" both **KILLED**.
- [x] [minor] the upload failure notification named the ULID instead of the filename. → resolved: the
      filename is captured inside the context manager before the parse can fail.
- [x] [minor] `last_import`'s `device_class: timestamp` and `entity_category: diagnostic` were both
      deletable with the suite green. → resolved: asserted via the entity registry and state
      attributes. Both mutants **KILLED**.
- [x] [minor] **`last_import` advanced for an import the coordinator rejected** — the store
      overwrote `ingested_at`/`source_file` on the unchanged branch, so the staleness signal R15
      exists to protect silently reset at the next midnight. → resolved: `async_save_week` takes
      `keep_provenance` and the coordinator passes it. Mutant **KILLED**.
- [x] [minor] `test_every_parse_failure_preserves_stored_data` never used its `reason` parameter and
      compared the in-memory dict, not the gate's stated `.storage`. → resolved: the reason is now
      asserted and the `.storage` file bytes are compared before and after.
- [x] [minor] `file_id` was missing from the service field translations and the service description
      still said "from disk". → resolved in `services.yaml` and all three translation files.
- [x] [nit] **the prune return value never reached the caller**, so a backfill outside the retention
      window reported success and the not-stored notification branch was dead. `issues.md` recorded
      this closed in M1; it was not. Root cause: an edit script used a plain `str.replace` with no
      assertion, so a non-matching pattern was a silent no-op. → resolved: `async_import_week`
      rewritten explicitly, with a service-level test for the notification. Mutant **KILLED**.
      Process fix: every subsequent edit script asserts its pattern matched.
- [x] [nit] `>` tie-break on equal `ingested_at` favoured the oldest record — reachable under a frozen
      clock, which is exactly how the M3 dedup tests will run. → resolved: `>=` in all three readers.
- [x] [nit] `latest_week_key`'s unparseable-timestamp `continue` was uncovered. → resolved.

## Verified sound by the reviewer — recorded so M3 does not redo it

- **DST scheduling is correct.** HA's `find_next_time_expression_time` was replayed across both 2026
  transitions in Europe/Berlin: exactly one fire per local calendar date, 23 h apart in spring, 25 h
  in autumn. No skip, no double.
- **`file_id` cannot escape the upload area** — `process_uploaded_file` resolves only ids registered
  by the upload view; a traversal string is simply absent from the dict.
- **`last_import` never reports a pruned week** (verified with a 5-import backfill sequence).
- **Exactly-one-of holds against empty strings** for both `file_path` and `file_id`.
