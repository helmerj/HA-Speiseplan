# School Menu — Home Assistant integration

Turns the weekly lunch-menu PDF from Annie-Heuser-Schule (catered by Organiced Kitchen) into Home
Assistant sensors, so today's lunch and the next school day's are on the dashboard with no manual steps.

| Entity | What it reports |
|---|---|
| `sensor.school_menu_today` | Today's main course; `none` with `reason: weekend \| no_menu` when there is no lunch |
| `sensor.school_menu_next_school_day` | The next school day's main course — Fri, Sat and Sun all resolve to Monday; the `weekday` and `date` attributes say which day it is |
| `sensor.school_menu_last_import` | Timestamp of the most recent accepted import (diagnostic) |
| `button.school_menu_check_mail` | Checks the mailbox right away ("Check mail now" / "Speiseplan jetzt abrufen") |

Each menu sensor also exposes `main`, `side`, `dessert` (positional, not semantic), the full `lines`
list, `weekday`, `date`, `source_file` and `ingested_at`.

## Requirements

- Home Assistant **2026.9.3** or newer.
- Nothing else for the sensors. The PDF is parsed locally with `pypdf`; no cloud service is involved.
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
attachments that were refused before, and still never imports a menu twice.

Installations from v0.1.0 that still have the old defaults (the two class teachers, `Speiseplan KW`)
are switched to the new defaults automatically on update; customised values are kept.

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
      {{ lines[0] if lines else 'Kein Mittagessen' }}
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

On weekends, holidays and days without a menu the text reads **Kein Mittagessen**. If the
integration itself is not running, it reads **Speiseplan nicht verfügbar** instead, so a broken
setup is never mistaken for a day without lunch.

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
