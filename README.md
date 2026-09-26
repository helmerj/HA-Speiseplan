# School Menu — Home Assistant integration

Turns the weekly lunch-menu PDF from Annie-Heuser-Schule (catered by Organiced Kitchen) into Home
Assistant sensors, so today's lunch and the next school day's are on the dashboard with no manual steps.

| Entity | What it reports |
|---|---|
| `sensor.school_menu_today` | Today's main course; `none` with `reason: weekend \| no_menu` when there is no lunch |
| `sensor.school_menu_next_school_day` | The next school day's main course — Fri, Sat and Sun all resolve to Monday; the `weekday` and `date` attributes say which day it is |
| `sensor.school_menu_last_import` | Timestamp of the most recent accepted import (diagnostic) |

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
sender addresses (both class teachers by default), the subject filter (`Speiseplan KW`) and the poll
interval (15 min, minimum 5). A mail is imported only when **both** a configured sender and the
subject filter match.

- The mailbox is opened **read-only**: messages are never marked read, moved or deleted.
- The second teacher's copy of the same week changes nothing — no second import, no new timestamp.
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
  - type: custom:mushroom-template-card
    entity: sensor.school_menu_today
    icon: mdi:food
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
    icon: mdi:food-fork-drink
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
      {%- set main = state_attr(e, 'main') -%}
      {%- set stand = as_datetime(states('sensor.school_menu_last_import'), None) -%}
      {%- if states(e) in ['unavailable', 'unknown'] -%}
      Speiseplan nicht verfügbar
      {%- else -%}
      {{ main if main else 'Kein Mittagessen' }}
      Stand: {{ as_local(stand).strftime('%d.%m.') if stand else 'noch kein Import' }}
      {%- endif -%}
    multiline_secondary: true
    tap_action:
      action: more-info
```

The same YAML ships as `cards/mushroom-today-tomorrow.yaml`. It uses the fixed entity ids, so it needs
no editing, and theme variables only, so light and dark mode follow your theme.

| Tile | Title line | Text (wraps, so long dishes are never cut off) |
|---|---|---|
| Today | `Heute · Mittwoch, 30.09.` | the main course, then every further line of the day joined by ` · ` |
| Next school day | `Morgen · Donnerstag, 01.10.` — on Fri and Sat just `Montag, 05.10.` | its main course, then `Stand: <date of the last import>` |

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
