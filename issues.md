# Review — M1 (round 1)

status: converged

Loop: HAS-school-menu · Milestone: M1 · Reviewer: python-services:review-agent (opus, cold, report mode)
Round 1 verdict as delivered: `changes_requested` — 0 blocker, 4 major, 6 minor, 2 nit.
All blocker/major and all substantive minor findings are resolved below; each resolution was
re-proven by execution (mutation or a live-`hass` probe), not by inspection.

## Closed this round

- [x] [major] `custom_components/school_menu/sensor.py:96` — `source_file`/`ingested_at` reported the
      globally newest week, not the week owning the displayed day. → resolved: `MenuStore` now keeps
      `week_of_day`, the sensor reads `coordinator.record_for(day)`. Re-proven by execution:
      `tests/test_sensor.py::test_each_day_reports_its_own_weeks_provenance` (two weeks, distinct
      frozen import times) and `tests/test_store.py::test_each_day_resolves_to_its_own_weeks_record`.
- [x] [major] `tests/test_services.py:73` — the R9 path-allowlist invariant was asserted by a test
      that stayed green with `.resolve()` deleted. → resolved: both tests now assert
      `translation_key == "path_not_allowed"`, plus four new shapes (traversal to an existing file, a
      symlink out of `www`, a sibling directory sharing the `www` prefix, an absolute outside path).
      Re-proven: mutant "drop `.resolve()`" now **KILLED**.
- [x] [major] `custom_components/school_menu/parser.py` — day→date mapping and 4 of 5 footer
      sentinels untested; three mutants survived. → resolved: added a missing-anchor test, a
      parametrised test per footer sentinel, and a 5-line-cap test. Re-proven: mutants
      "name-based → positional mapping", "only the quote sentinel", "drop the domain substring" and
      "remove the 5-line cap" are all now **KILLED**.
- [x] [major] `coordinator.py` / `store.py` — the whole dedup path was untested; three mutants
      survived. → resolved: `tests/test_coordinator.py` exercises all three layers directly, and
      `test_known_bytes_are_skipped_before_any_store_write` pins that layer 1 performs no store write
      (the only externally observable difference between layers 1 and 2 on identical bytes).
      Re-proven: mutants "knows_hash disabled", "unchanged branch disabled" and "duplicate-hash guard
      disabled" are all now **KILLED**.
- [x] [minor] `__init__.py` — `Path.resolve()`/`is_file()` ran on the event loop; HA's `block_async_io`
      does not patch `stat`, so nothing warned. → resolved: path resolution, existence check and parse
      now share one `hass.async_add_executor_job` call.
- [x] [minor] `sensor.py` — a stored day with an empty `lines` list yielded state `none` with **no**
      `reason` attribute. → resolved: one predicate (`menu is None or not menu.lines`) in both
      properties. Re-proven: mutant **KILLED** by `test_a_stored_day_with_no_lines_reports_no_menu`.
- [x] [minor] `store.py` — importing a week older than the retention window reported success while
      storing nothing. → resolved: `async_save_week` returns whether the key survived the prune; the
      service notification now distinguishes imported / unchanged / not-stored. Re-proven: mutant
      "retention returns success regardless" **KILLED**.
- [x] [minor] re-importing known bytes reported "importiert". → resolved: distinct notification text.
- [x] [minor] no service translations — the HA dialog showed raw keys. → resolved: `name`/`description`
      in `services.yaml` and a `services` block in `strings.json` and both translations.
- [x] [minor] `target_date`'s `tomorrow` branch shipped with no test and a loose `str` parameter.
      → resolved: parametrised tests for all seven weekdays and the `Literal["today","tomorrow"]`
      annotation. Also added the impossible-header-date case (`31.02.26`).
- [x] [nit] missing return annotations (`_read_and_parse`, `_target`, `async_setup`'s `ConfigType`).
      → resolved.
- [x] [nit] `latest_record` re-parsed the incumbent timestamp on every iteration; `coordinator` read
      `payload["lines"]` where the store used `.get`. → resolved: parsed stamp carried in the loop,
      `.get("lines", [])` used consistently.

## Accepted as a design amendment rather than a code change

- [x] [minor] design §7 required the failure notification to carry "the first 200 chars of extracted
      text". The reviewer argued this converts `import_pdf` into a partial arbitrary-read oracle,
      because the allowlist validates the path and the file is opened moments later — a symlink swap
      by anyone who can write to `/config/www` lands in that window. **`docs/0002-design.md` §7 was
      amended** to specify reason + filename only, with the rationale recorded there.
- [x] [minor] `services.yaml` has `file_path: required: true` where design §5.3 says `required: false`
      (exactly-one-of with `file_id`). `file_id` is M2 work. **Design §5.3 amended** to record that
      the exactly-one-of rule applies from M2.

## Deferred, with a reason

- [ ] [nit] Enabling ruff `ANN` to enforce annotations mechanically. Not taken in M1: it would require
      annotating every existing test signature in the same change, which is churn unrelated to the
      milestone. Candidate for a chore.

## Not defects — verified and recorded so they are not re-reviewed

The reviewer attacked `_resolve_within_allowlist` with 15 shapes inside a live `hass` (symlinked file
and directory, `..` traversal, sibling prefix, uppercase on case-insensitive APFS, NFD/NFC, double and
trailing slashes, relative and empty paths, the root itself, `media_dirs`) and **found no bypass**.
`Path.resolve()` plus `root in candidate.parents` is true path-component containment; case-insensitivity
fails closed. Both real PDFs parse correctly, including the pypdf two-line quote wrap in 26-39. Project
rules 1–5 (zero prose, literal `none` state, positional accessors, lenient parsing, allergens discarded)
all hold, and the storage format matches design §4.2 exactly.
