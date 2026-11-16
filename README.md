<p align="center">
  <img src="https://raw.githubusercontent.com/helmerj/HA-Speiseplan/main/custom_components/school_menu/brand/icon.png" alt="School Menu" width="128">
</p>

# School Menu — Home Assistant integration

Turns the weekly lunch-menu PDF from Annie-Heuser-Schule (catered by Organiced Kitchen) into Home
Assistant sensors, so today's lunch and the next school day's are on the dashboard with no manual steps.

| Entity | What it reports |
|---|---|
| `sensor.school_menu_today` | Today's main course; `none` with `reason: weekend \| holiday \| no_menu` when there is no lunch (`holiday` adds the attribute `holiday`, e.g. `Weihnachtsferien Berlin`) |
| `sensor.school_menu_next_school_day` | The next school day's main course — Fri, Sat and Sun all resolve to Monday; the `weekday` and `date` attributes say which day it is |
| `sensor.school_menu_last_import` | Timestamp of the most recent accepted import (diagnostic) |
| `button.school_menu_check_mail` | Checks the mailbox right away ("Check mail now" / "Speiseplan jetzt abrufen") |
| `update.school_menu_version` | `on` when a newer School Menu release is out; installs it through HACS |

Each menu sensor also exposes `main`, `side`, `dessert` (positional, not semantic), the full `lines`
list, `weekday`, `date`, `source_file` and `ingested_at`.

## Requirements

- Home Assistant **2026.9.3** or newer.
- Nothing else for the sensors. The PDF is parsed locally with `pypdf`; no cloud service is involved.
  The only outbound request is the release check against the GitHub API (see below).
- For the dashboard card: [Mushroom](https://github.com/piitaya/lovelace-mushroom) (HACS → Frontend).

## Installation (HACS)

1. HACS → Integrations → ⋮ → Custom repositories.
2. Add `https://github.com/helmerj/HA-Speiseplan` with category **Integration**.
3. Install "School Menu", restart Home Assistant.
4. Settings → Devices & Services → Add Integration → **School Menu**.

Only one entry is supported; a second attempt is refused by design.

The entity ids are always `sensor.school_menu_today`, `sensor.school_menu_next_school_day` and
`sensor.school_menu_last_import`, whatever you name the entry, so the card below works unedited.
(Entries created with version 0.1.0 before this fix may carry ids derived from the entry name; delete
and re-add the integration, or rename the three entities, to get the fixed ids.)

## Mailbox (automatic import)

School Menu → **Configure** asks for the IMAP host, port, SSL, username, password, folder, the
senders, the subject filter and the poll interval. A mail is imported when **all three** hold:

- it comes from a configured sender — by default **anyone at `@annie-heuser.schule`**; an entry can
  be a full address or `@domain`, and only the real address counts, never the display name;
- its subject contains the filter text — by default **`Speiseplan`**, in any case;
- it has a **PDF attachment**.

The mailbox is checked every **15 minutes** by default (5–1440, same form). For an immediate check,
press **Check mail now** (`button.school_menu_check_mail`, German: "Speiseplan jetzt abrufen") or
call the action `school_menu.check_mail`. It re-reads all school mails of the last 14 days, retries
attachments that were refused before, and still never imports a menu twice. If the mailbox can't be
reached, the button and the action report the error instead of pretending success. A second check
within a minute of a successful one, or while a check is running, is skipped with a short
message saying so. An attachment that is still unreadable is
reported again on every manual check.
Every successful manual check ends with a notification saying what it found: the week it imported
("Neuer Speiseplan importiert: KW 46 (5 Tage)."), the weeks that were already stored ("Kein neuer
Speiseplan. Bereits importiert: KW 46."), or that no menu mail was found. The scheduled checks stay
silent.

Installations from v0.1.0 that still have the old defaults (the two class teachers, `Speiseplan KW`)
are switched to the new defaults automatically on update; customised values are kept. A mail
whose `From` carries more than one address is never accepted.

**Downgrading to v0.1.0:** that version doesn't understand `@domain` senders and would ignore all
mail. Set *Senders* back to full addresses before you downgrade.

- The mailbox is opened **read-only**: messages are never marked read, moved or deleted.
- Another copy of the same week, from a second sender or resent, changes nothing — no second
  import, no new timestamp.
- A mail that would replace a stored week with fewer days is refused and reported once per Home
  Assistant start; import the file by hand (`school_menu.import_pdf`) if the shorter week is
  genuinely correct. An unreadable attachment is reported the same way.
- A wrong password opens Home Assistant's re-authentication prompt. Connection problems are reported
  only after three failed polls in a row.

There is no alarm when no menu arrives — school holidays look exactly like that. The `Stand:` line on
the card below shows when the last menu came in.

## School website (automatic fallback)

The school also publishes the menu at
<https://www.annie-heuser-schule.de/wp-content/uploads/AHS-Speiseplan.pdf>. School Menu checks that
file **every 2 hours from Sunday 18:00**, and only until the menu for the current school week is
stored, whether it came from the mailbox, the website or a manual import. On Saturdays, and once the
week is in, no request is made. It works with or without a mailbox.

- The website file takes the same path as a mail attachment: a week already stored is not imported
  again, and a file that would shrink a stored week is refused.
- The website often still shows last week's menu on Monday morning. That is expected; the next check
  two hours later tries again.
- An unreachable website only writes a warning to the log; there is no notification. A successful
  import shows up on `sensor.school_menu_last_import` with `source: web`.
- To use another address, or to turn the check off, change or clear *School website PDF* under
  **Settings → Devices & services → School Menu → Configure**.

## Dashboard card

Requires [Mushroom](https://github.com/piitaya/lovelace-mushroom) (HACS → Frontend → Mushroom).
Add a card → **Manual**, and paste:

```yaml
type: vertical-stack
cards:
  - type: custom:mushroom-title-card
    title: AHS Speiseplan
  - type: custom:mushroom-template-card
    entity: sensor.school_menu_today
    icon: "{{ state_attr('sensor.school_menu_today', 'icon') or 'mdi:food' }}"
    primary: |-
      {%- set e = 'sensor.school_menu_today' -%}
      {%- set d = state_attr(e, 'date') -%}
      {{ 'Heute · ' ~ state_attr(e, 'weekday') ~ ', ' ~ d[8:10] ~ '.' ~ d[5:7] ~ '.' if d else 'Heute' }}
    secondary: |-
      {%- set e = 'sensor.school_menu_today' -%}
      {%- set lines = state_attr(e, 'lines') or [] -%}
      {%- if states(e) in ['unavailable', 'unknown'] -%}
      Speiseplan nicht verfügbar
      {%- elif lines -%}
      {{ lines[0] }}
      {{ lines[1:] | join(' · ') }}
      {%- elif state_attr(e, 'reason') == 'holiday' -%}
      Keine Menüinformationen - Ferien
      {%- elif state_attr(e, 'reason') == 'no_menu' -%}
      Noch keine Menüinformationen vorhanden
      {%- else -%}
      Kein Mittagessen
      {%- endif -%}
    multiline_secondary: true
    tap_action:
      action: more-info
  - type: custom:mushroom-template-card
    entity: sensor.school_menu_next_school_day
    icon: "{{ state_attr('sensor.school_menu_next_school_day', 'icon') or 'mdi:food' }}"
    primary: |-
      {%- set e = 'sensor.school_menu_next_school_day' -%}
      {%- set d = state_attr(e, 'date') -%}
      {%- set label = state_attr(e, 'weekday') ~ ', ' ~ d[8:10] ~ '.' ~ d[5:7] ~ '.' if d else '' -%}
      {%- if not d -%}
      Morgen
      {%- elif d == (now().date() + timedelta(days=1)).isoformat() -%}
      Morgen · {{ label }}
      {%- else -%}
      {{ label }}
      {%- endif -%}
    secondary: |-
      {%- set e = 'sensor.school_menu_next_school_day' -%}
      {%- set lines = state_attr(e, 'lines') or [] -%}
      {%- set stand = as_datetime(states('sensor.school_menu_last_import'), None) -%}
      {%- if states(e) in ['unavailable', 'unknown'] -%}
      Speiseplan nicht verfügbar
      {%- else -%}
      {%- set empty = {'holiday': 'Keine Menüinformationen - Ferien', 'no_menu': 'Noch keine Menüinformationen vorhanden'} -%}
      {{ lines[0] if lines else empty.get(state_attr(e, 'reason'), 'Kein Mittagessen') }}
      {%- if lines[1:] %}
      {{ lines[1:] | join(' · ') }}
      {%- endif %}
      Stand: {{ as_local(stand).strftime('%d.%m.') if stand else 'noch kein Import' }}
      {%- endif -%}
    multiline_secondary: true
    tap_action:
      action: more-info
```

The card opens with the header **AHS Speiseplan**; change the `title:` line if you like. The same
YAML ships as `cards/mushroom-today-tomorrow.yaml`. It uses the fixed entity ids, so it needs no
editing, and theme variables only, so light and dark mode follow your theme.

| Tile | Title line | Text (wraps, so long dishes are never cut off) |
|---|---|---|
| Today | `Heute · Mittwoch, 30.09.` | the main course, then every further line of the day joined by ` · ` |
| Next school day | `Morgen · Donnerstag, 01.10.` — on Fri and Sat just `Montag, 05.10.` | its main course, then every further line joined by ` · `, then `Stand: <date of the last import>` |

Each tile's icon follows its main course: pasta, soup, chili, rice, fish, vegetables, salad and so
on (a keyword table in `custom_components/school_menu/icons.py`); anything unrecognised shows a
neutral plate.

When there is no menu, the text says why:

| Situation | Text |
|---|---|
| Ferien day or public holiday (needs the calendars below) | **Keine Menüinformationen - Ferien** |
| School day, menu not received yet | **Noch keine Menüinformationen vorhanden** |
| Today is Saturday or Sunday | **Kein Mittagessen** |
| The integration is not running | **Speiseplan nicht verfügbar** |

On the last days of the Ferien the next-school-day tile keeps the Ferien text until the first day
after the Ferien (usually the Sunday), even though the next Monday is a school day.

### Holidays

School Menu cannot know the Ferien on its own. Give it up to two Home Assistant calendars under
**Settings → Devices & services → School Menu → Configure**:

- **School holiday calendar** — any event means no school that day. For Berlin, add the Ferien
  subscription with the built-in **Remote Calendar** integration (Settings → Devices & services →
  Add integration → Remote Calendar), using the `https://` form of the `webcal://` link.
- **Working day calendar** (optional) — the calendar of the
  [Workday](https://www.home-assistant.io/integrations/workday/) integration. A weekday without an
  event there counts as a public holiday (*Feiertag*), which the Ferien calendar does not contain.

Without calendars every day without a menu reads "Noch keine Menüinformationen vorhanden". If a
calendar cannot be read, School Menu falls back to that as well, so a broken calendar never claims
there is no school. A menu that has arrived is always shown, even on a calendar holiday. Weeks that
are holidays from Monday to Friday are not checked on the school website.

## Updates

HACS checks a custom repository for new releases only when Home Assistant starts and every 48 hours.
School Menu therefore checks GitHub itself, every 6 hours:

- **`update.school_menu_version`** turns `on` when a newer release is out. It appears under
  **Settings → Updates**; *Install* hands the exact release over to HACS, then restart as HACS asks.
- **One notification per new version** ("School Menu"), with a link to the release notes. Once
  dismissed it does not come back for that version; it disappears by itself after the update.
- Pre-releases and drafts are ignored. If GitHub is unreachable or rate-limited, nothing is reported
  and the last known release is kept.
- To switch the check off, disable the entity (Settings → Entities → School Menu Version → Disable).

Once HACS's own 48-hour check catches up, Settings may list the same release twice, once from School
Menu and once from HACS; either one installs it.

To get a push message on your phone (Home Assistant Companion app), add this automation and replace
`notify.mobile_app_your_phone` with your own notify action:

```yaml
alias: School Menu update available
triggers:
  - trigger: state
    entity_id: update.school_menu_version
    to: "on"
actions:
  - action: notify.mobile_app_your_phone
    data:
      title: School Menu
      message: >-
        Version {{ state_attr('update.school_menu_version', 'latest_version') }} ist verfügbar.
```

## Status

Under active development, milestone by milestone:

| Milestone | Ships | State |
|---|---|---|
| M0 | Walking skeleton: installs, sets up, unloads; CI green | done |
| M1 | Import a PDF by hand → today's lunch on a sensor | done |
| M2 | Correct at every hour incl. weekends; corrupt PDF never destroys stored data | done |
| M3 | Weekly email ingestion with two senders and deduplication | done |
| M4 | Documented Mushroom dashboard card | done |

## Documentation

- `docs/0001-rfc.md` — why this exists and what was rejected.
- `docs/0002-design.md` — the binding technical design.
- `specs/HAS-school-menu/TDD_PLAN.md` — how it is being built.

Code files in this repository deliberately carry **no comments and no docstrings**; all rationale
lives in the documents above.
