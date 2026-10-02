# Feature plan — any school sender, "Speiseplan" subject, manual re-check

**Ticket:** HAS-1 (local) · **Branch:** `feature/HAS-1-school-domain-senders` off `origin/main`
(this repo has no `dev`; `main` has been the PR base since PR #1).
**Status:** draft, awaiting approval. Amends `docs/0002-design.md` §5.4, §5.5 and §10 R14 before any code.

## Description

A third school employee now sends the weekly menu PDF, from another `@annie-heuser.schule` address
and with a different subject line. Today the integration only accepts the two class teachers'
exact addresses and subjects containing `Speiseplan KW`, so that mail is silently ignored.

## User story

As a parent, I want every menu mail from the school, whoever sends it and however the subject is
worded, to update the sensors. I also want to trigger a mailbox check myself, so a late or resent
menu shows up without waiting for the next poll.

## Problem

- `imap_client.sender_allowed` compares full addresses against a fixed list (design §5.5 filter 1).
- `subject_filter` defaults to `Speiseplan KW` (§10 R14). A subject like "Speiseplan für nächste
  Woche" fails it.
- There is no way to poll on demand. The only trigger is the timer (default 15 min) or a restart.
- The poll interval is configurable already (`scan_interval_minutes`, 5–1440 min, School Menu →
  Configure), but it isn't documented in the README.

## Solution

1. **Domain senders.** An entry in `senders` that starts with `@` matches every address of that
   domain. Full addresses keep working. The new default is `["@annie-heuser.schule"]`.
   - IMAP search: `FROM "annie-heuser.schule"`, one search per entry as today.
   - Local re-check: on the parsed address part only. `x@evil.example` with display name
     `annie-heuser.schule` is rejected, as is `x@annie-heuser.schule.evil.example`. The match is
     exact on the domain after `@`.
2. **Subject.** The default `subject_filter` becomes `Speiseplan` (case-insensitive substring,
   unchanged semantics). The PDF-attachment requirement stays: a matching mail without a PDF is
   ignored. The `Speiseplan KW <n>` regex keeps serving as `fallback_week_start` when present.
3. **Migrating the existing entry.** A config-entry minor version bump (1.1 → 1.2) with
   `async_migrate_entry`:
   - `senders` exactly equal to the old two-address default → `["@annie-heuser.schule"]`;
   - `subject_filter == "Speiseplan KW"` → `"Speiseplan"`;
   - customised values are left untouched.
   The live install works after the update with no reconfiguration.
4. **Manual re-check.**
   - A `button.school_menu_check_mail` entity ("Speiseplan jetzt abrufen") and a
     `school_menu.check_mail` action, both calling one coordinator method.
   - That method clears the in-memory `seen_messages` and `rejected_hashes`, then runs a poll, so a
     forced check re-reads the whole 14-day window and retries previously refused attachments.
   - Three-layer dedup still prevents any duplicate import or `last_import` churn.
   - With no mailbox configured, the action raises `ServiceValidationError` and the button is
     unavailable.
5. **Poll interval.** Behaviour unchanged. The README documents it, and the options form describes
   it in both languages.

**Security note (accepted risk):** the `From` header can be forged. Domain matching widens who can
feed the sensors, from 2 addresses to the school domain. The mitigations are unchanged: only the
configured folder (`INBOX`) is read, so the provider's spam filtering and DMARC checks apply first,
and only PDFs that parse as a menu are stored. The design note will record this.

## Relevant files

| File | Change |
|---|---|
| `docs/0002-design.md` | amendment: §5.4 defaults, §5.5 filter 1 (domain), §10 R14 (subject), manual re-check |
| `custom_components/school_menu/const.py` | `DEFAULT_SENDERS = ("@annie-heuser.schule",)`, `DEFAULT_SUBJECT_FILTER = "Speiseplan"`, `SERVICE_CHECK_MAIL`, old-default constants for migration |
| `custom_components/school_menu/imap_client.py` | `search_criteria` (domain → bare domain term), `sender_allowed` (`@domain` entries) |
| `custom_components/school_menu/config_flow.py` | `MINOR_VERSION = 2`; sender validation accepts `@domain`; form descriptions |
| `custom_components/school_menu/__init__.py` | `async_migrate_entry`; `check_mail` action; `Platform.BUTTON` |
| `custom_components/school_menu/coordinator.py` | `async_check_mail_now()` |
| `custom_components/school_menu/button.py` | **new**, the check-mail button with a pinned `entity_id` |
| `services.yaml`, `strings.json`, `translations/{en,de}.json` | action, button name, field descriptions |
| `README.md` | mailbox section: domain senders, subject, interval, re-check |
| `tests/test_imap_domain.py` | **new**, domain search term and domain matching, including spoof and multi-address cases |
| `tests/test_config_flow.py` | `@domain` accepted, malformed domain rejected |
| `tests/test_migration.py` | **new**, migration of defaults; custom values kept |
| `tests/test_check_mail.py` | **new**, button and action: forced re-read, dedup holds, no mailbox → error |
| `tests/e2e/test_m5_any_school_sender.py` | **new** `@m5` acceptance |

## Implementation plan

- **Phase 1, foundation:** design amendment; constants; domain-aware `sender_allowed` and `search_criteria`.
- **Phase 2, core:** config-flow validation; entry migration; `async_check_mail_now`.
- **Phase 3, integration:** button platform and `check_mail` action; strings; README; e2e.

## Step by step tasks

1. **Amend `docs/0002-design.md`** (§5.4, §5.5, R14, the new action, the security note).
   *Done when:* the amendment is committed before any code change.
2. **RED, then GREEN: `sender_allowed` with `@domain` entries.** Accept `a.b@annie-heuser.schule`.
   Reject the spoofed display name, `@annie-heuser.schule.evil.example`, and `annie-heuser.schule@evil.example`.
   *Done when:* the tests pass and a mutant using `endswith` without the `@` is killed.
3. **RED, then GREEN: `search_criteria` for a domain entry** emits `FROM "annie-heuser.schule"`.
   *Done when:* the fake-server search test passes, and so does the real-socket protocol test.
4. **RED, then GREEN: new defaults** (`@annie-heuser.schule`, `Speiseplan`). A third-sender mail
   with subject "Speiseplan für nächste Woche" and a PDF is imported. The same mail without a PDF
   is ignored. *Done when:* tests pass.
5. **RED, then GREEN: options-flow validation** accepts `@annie-heuser.schule` and rejects `@`, `@foo`
   and `a@@b`. *Done when:* tests pass.
6. **RED, then GREEN: `async_migrate_entry` 1.1 → 1.2.** Old defaults are replaced. Custom senders, a
   custom subject and the credentials stay unchanged. *Done when:* tests pass on a `MockConfigEntry`
   with `minor_version=1`.
7. **RED, then GREEN: `coordinator.async_check_mail_now()`.** It clears both caches, polls, re-reads all
   UIDs, and still makes no duplicate import and no `last_import` bump.
   *Done when:* tests pass with `uid_validity` set.
8. **RED, then GREEN: `button.school_menu_check_mail` and the `school_menu.check_mail` action.**
   - The `entity_id` is pinned.
   - The button is unavailable when no mailbox is configured.
   - The action raises `ServiceValidationError` without a mailbox.
   - A press triggers exactly one poll.
   *Done when:* tests pass.
9. **Strings and translations (en, de), `services.yaml`, README.** *Done when:* hassfest passes,
   and the README YAML/JSON blocks parse.
10. **RED, then GREEN: e2e `@m5`.**
    - The mailbox holds a teacher's KW mail and a third-sender mail with another subject (same
      week, re-attached bytes), plus a non-school sender with "Speiseplan".
    - One poll gives exactly one import, no `\Seen`, and the stranger ignored.
    - A button press re-reads the mailbox without any state change.
    *Done when:* `pytest -m m5` passes.
11. **Run the validation commands.** *Done when:* all are green.

## Testing strategy

Unit tests for the pure matching (`sender_allowed`, `search_criteria`). Integration tests with the
fake IMAP server for polling, migration, button and action. The real-socket test checks the
domain `FROM` term on the wire. Every new branch gets a mutant run; the project norm is all killed.

## Acceptance criteria

- [ ] A mail from any `@annie-heuser.schule` address with "Speiseplan" in the subject and a PDF
      attachment updates the sensors within one poll.
- [ ] A mail with a forged display name, a look-alike domain, or no PDF is ignored.
- [ ] The existing live entry needs no reconfiguration after the update; customised values are kept.
- [ ] `button.school_menu_check_mail` and `school_menu.check_mail` trigger an immediate full re-check,
      without duplicate imports.
- [ ] The poll interval stays configurable (5–1440 min) and is documented.
- [ ] Zero regressions: all existing tests green, coverage ≥ 85 %, hassfest + HACS validation green.

## Validation commands

```bash
PATH="$PWD/.venv/bin:$PATH" scripts/gate.sh M4
```

```bash
.venv/bin/pytest -q -m m5
```

```bash
.venv/bin/ruff check . && .venv/bin/ruff format --check .
```

## Notes

- Release: `v0.2.0` after merge (minor, new feature + migration). HACS picks it up as an update.
- No new libraries.
- Open question for the operator: should the default subject be `Speiseplan`, or something narrower?
  `Speiseplan` also matches a reply like "AW: Frage zum Speiseplan", but without a menu PDF such a
  reply is ignored anyway.
