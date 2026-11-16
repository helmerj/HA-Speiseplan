# Feature: tell "no lunch — holidays" apart from "menu not in yet"

## Branching

- **Ticket:** HAS-8 (local key, no Jira)
- **Base:** `origin/main` (no `dev` in this repo; `main` is the PR base)
- **Branch:** `feature/HAS-8-holiday-aware-empty-state`

**Status:** approved 2026-11-16. The design amendment (task 1) goes into `docs/0002-design.md`
before any code. It reverses the settled rule "holidays = absence of data only" (§4.3, §10 R15) for
the menu sensors; the staleness rule for `last_import` is unchanged.

## Feature Description

Today a school day without a stored menu and a day in the Ferien look identical: state `none`,
`reason: no_menu`, card text `Kein Mittagessen`. Because PDF delivery is unreliable, a parent cannot
tell "there is lunch, the plan just has not arrived" from "there is no lunch". With two Home Assistant
calendars the integration can tell them apart:

- **Ferien calendar** — `calendar.schulferien_berlin` (Remote Calendar, set up 2026-11-16 from the
  calovo Berlin Ferien ICS). Any all-day event = no school. Covers Ferien and "Unterrichtsfreier Tag
  Berlin"; it has **no** public holidays.
- **Workday calendar** — `calendar.workday_sensor_kalender` (existing Workday integration). It has one
  event per working day; a weekday **without** an event is a public holiday (verified: no event on
  2026-12-25 and 2026-12-26).

Card texts (operator's wording):

| Situation | `reason` | Card text |
|---|---|---|
| Menu stored for the day | — | the menu (unchanged) |
| Saturday/Sunday (only `today`) | `weekend` | `Kein Mittagessen` (unchanged) |
| Ferien day or public holiday | `holiday` | `Keine Menüinformationen - Ferien` |
| School day, no menu stored | `no_menu` | `Noch keine Menüinformationen vorhanden` |

## User Story

As a parent
I want the card to say whether there is no lunch because of the holidays or because the menu has not
come in yet
So that I know when a missing menu means a real gap rather than a day off

## Problem Statement

`SchoolMenuSensor` (`sensor.py`) has only `weekend` and `no_menu`. Holidays are invisible to the
integration, so the website source (HAS-7) also polls through whole Ferien weeks.

## Solution Statement

1. **Calendar lookup (`holidays.py`, new).** `async_fetch_no_school_days(hass, ferien, workday, start,
   end) -> dict[date, str]` calls `calendar.get_events` (`return_response=True`) for the configured
   calendars. A date is no-school when a Ferien event covers it (label = event summary, e.g.
   `Weihnachtsferien Berlin`) or, for weekdays, when the Workday calendar has no event that day
   (label `Feiertag`). A calendar that is not configured, unavailable or errors contributes nothing
   (`WARNING` log once per failure streak) — the day falls back to `no_menu`, today's behaviour.
2. **Cache in the coordinator.** `coordinator.no_school: dict[date, str]` for today … today + 14 days.
   Refreshed at entry setup, in the existing midnight callback, and when a configured calendar's
   state changes (covers calendars that load after this integration). A refresh that changes the
   cache calls `async_update_listeners()`.
3. **Sensor precedence.** Stored menu → menu. Else weekend (`today` only) → `weekend`. Else date in
   `no_school` → `reason: holiday`, extra attribute `holiday: <label>`. Else `no_menu`. State stays the
   literal `none` (§10 R1). `next_school_day` keeps its R3 meaning (next weekday), so during Ferien it
   shows `holiday` too. **End of Ferien:** while *today* is a no-school day (incl. a Ferien
   Saturday), `next_school_day` without a menu reports `holiday` with today's label even when its
   own date is a school day; from the first day that is not no-school (usually the Sunday before
   school) it reports `no_menu`.
4. **Card.** The README's Mushroom card (and its byte-identical test copy) picks the text from
   `reason`.
5. **Website source.** `async_check_website` also returns without a request when all five weekdays
   of the target week are in `no_school`.
6. **Options.** Two optional entity selectors (domain `calendar`): `holiday_calendar`,
   `workday_calendar`. Empty = feature off, exactly today's behaviour. Same options form as the
   mailbox (it requires a mailbox host — known limitation, see HAS-7).

## Relevant Files

### Existing Files to Modify

- `docs/0002-design.md` — amendment 2026-11-16 (HAS-8): §4.3 reason table, §7, §10 R1/R15 notes.
- `custom_components/school_menu/const.py` — `REASON_HOLIDAY`, `ATTR_HOLIDAY`,
  `CONF_HOLIDAY_CALENDAR`, `CONF_WORKDAY_CALENDAR`, `HOLIDAY_LOOKAHEAD_DAYS = 14`,
  `PUBLIC_HOLIDAY_LABEL = "Feiertag"`.
- `custom_components/school_menu/coordinator.py` — `no_school` cache, `async_refresh_no_school()`,
  holiday-week skip in `async_check_website`.
- `custom_components/school_menu/__init__.py` — refresh at setup and midnight; state listener on the
  configured calendars.
- `custom_components/school_menu/sensor.py` — `holiday` reason and attribute.
- `custom_components/school_menu/config_flow.py`, `strings.json`, `translations/*.json` — two fields.
- `custom_components/school_menu/manifest.json` — `"after_dependencies": ["calendar"]`; version 0.6.0.
- `README.md` — card template, entity table, a "Holidays" section.
- `pyproject.toml` — marker `m8`; version 0.6.0.

### New Files to Create

- `custom_components/school_menu/holidays.py` — the calendar lookup (only `calendar.get_events` caller).
- `tests/test_holidays.py` — lookup against real `local_calendar`/mocked service responses.
- `tests/test_holiday_sensor.py` — sensor reasons, cache refresh, website skip (`@pytest.mark.m8`).

## Implementation Plan

### Phase 1: Foundation

Design amendment, constants, `holidays.py`.

### Phase 2: Core

Coordinator cache and refresh triggers, sensor precedence, website skip.

### Phase 3: Integration

Options fields, card, README, version.

## Execution Topology

Single lane, sequential (tasks 3–6 all touch `coordinator.py` / `sensor.py`).

```
1 → 2 → 3 → 4 → 5 → 6 → 7 → 8
```

## Step by Step Tasks

Each code task: contract → red → green → verify.

1. **Design amendment** as above. **Done when:** approved.
2. **Lookup.** `tests/test_holidays.py`: a Ferien event spanning 23.12.–02.01. marks those days with
   its summary; a weekday missing from the Workday calendar is `Feiertag`; a weekend day missing from
   it is not marked; unconfigured or unavailable calendar → nothing marked, no exception; both
   calendars → union, Ferien label wins. Implement `holidays.py`. **Done when:** green.
3. **Cache.** Setup fills `no_school`; midnight refresh moves the window; a calendar state change
   refreshes; a changed cache notifies listeners once, an unchanged one not at all. **Done when:** green.
4. **Sensors.** Table of (day, stored menu?, calendar) → (state, reason, holiday attribute) for
   `today` and `next_school_day`, incl. Fri before Ferien, last Ferien Friday, menu stored on a
   holiday (menu wins), last Ferien Friday and Ferien Saturday → `next_school_day` `holiday`,
   Sunday before school → `no_menu`, calendars off (unchanged behaviour). **Done when:** green, existing sensor
   tests unchanged.
5. **Website skip.** Whole target week in `no_school` → no GET; one school day in it → GET.
   **Done when:** green, HAS-7 tests unchanged.
6. **Options.** Form shows both selectors, empty by default; values saved; reload picks them up.
   **Done when:** green.
7. **Card + README.** Card renders the three texts (`tests/test_card.py` via `card_render`);
   README == card copy test stays green; entity table lists `holiday`. Version 0.6.0, marker `m8`.
   **Done when:** green.
8. **Run Validation Commands.** **Done when:** all pass.

## Testing Strategy

### Unit Tests

`holidays.py` against `calendar.get_events` responses (real `local_calendar` entities where possible).

### Integration Tests

Sensors, cache refresh with `freezer` + `async_fire_time_changed`, website skip, options flow, card
rendering.

### Edge Cases

- Event end dates are exclusive (`DTEND` 2027-01-03 → last Ferien day 2027-01-02).
- Single "Unterrichtsfreier Tag".
- Workday calendar present, Ferien calendar absent (public holidays only) and vice versa.
- Calendar entity loads after this integration (state listener).
- Ferien starting mid-week: the website check still runs for the school days.

## Acceptance Criteria

- On a Ferien day or public holiday with no menu stored: state `none`, `reason: holiday`,
  `holiday: <label>`, card `Keine Menüinformationen - Ferien`.
- On a school day with no menu stored: `reason: no_menu`, card `Noch keine Menüinformationen vorhanden`.
- A stored menu is always shown, even on a calendar holiday.
- No website request during a week that is entirely no-school.
- Calendars not configured or failing → behaviour identical to 0.5.0.
- Zero regressions; coverage ≥ 85%.

## Validation Commands

```bash
PATH="$PWD/.venv/bin:$PATH" pytest -q
PATH="$PWD/.venv/bin:$PATH" pytest -q -m m8 --no-cov
PATH="$PWD/.venv/bin:$PATH" ruff check . && ruff format --check .
PATH="$PWD/.venv/bin:$PATH" scripts/gate.sh M4
```

## Verification Plan

- Per unit: red → green.
- Pre-PR: `/code-review` on the branch diff.
- PR stage: CI (hassfest, HACS, pytest).
- Operator: after installing 0.6.0, pick the two calendars in the options and look at the card.

## Notes

- Operator decisions 2026-11-16: public holidays via the Workday calendar; skip the website check in
  all-holiday weeks.
- HA side already done: Remote Calendar entry "Schulferien Berlin" → `calendar.schulferien_berlin`
  (events verified: Weihnachts-, Winter-, Osterferien 2026/27).
- Card wording confirmed 2026-11-16: "Menüinformationen" with umlaut.
- End-of-Ferien rule confirmed 2026-11-16: Ferien text for `next_school_day` while today is Ferien.
- Follow-up (operator, 2026-11-16): move website URL and calendars out of the mailbox options form
  into their own "Kalender & Website" options step.
- 24.12. is a working day in the Workday calendar and falls inside Weihnachtsferien anyway.
- `claude/sync.json` absent → no context delta.
