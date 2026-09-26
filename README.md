# School Menu — Home Assistant integration

Turns the weekly lunch-menu PDF from Annie-Heuser-Schule (catered by Organiced Kitchen) into Home
Assistant sensors, so today's and tomorrow's lunch are on the dashboard with no manual steps.

| Entity | What it reports |
|---|---|
| `sensor.school_menu_today` | Today's main course; `none` with `reason: weekend \| no_menu` when there is no lunch |
| `sensor.school_menu_tomorrow` | The next school day's main course (Fri, Sat and Sun all resolve to Monday) |
| `sensor.school_menu_last_import` | Timestamp of the most recent accepted import (diagnostic) |

Each menu sensor also exposes `main`, `side`, `dessert` (positional, not semantic), the full `lines`
list, `weekday`, `date`, `source_file` and `ingested_at`.

## Requirements

- Home Assistant **2026.9.3** or newer.
- Nothing else. The PDF is parsed locally with `pypdf`; no cloud service is involved.

## Installation (HACS)

1. HACS → Integrations → ⋮ → Custom repositories.
2. Add `https://github.com/helmerj/HA-Speiseplan` with category **Integration**.
3. Install "School Menu", restart Home Assistant.
4. Settings → Devices & Services → Add Integration → **School Menu**.

Only one entry is supported; a second attempt is refused by design.

## Status

Under active development, milestone by milestone:

| Milestone | Ships | State |
|---|---|---|
| M0 | Walking skeleton: installs, sets up, unloads; CI green | done |
| M1 | Import a PDF by hand → today's lunch on a sensor | done |
| M2 | Correct at every hour incl. weekends; corrupt PDF never destroys stored data | done |
| M3 | Weekly email ingestion with two senders and deduplication | done |
| M4 | Documented Mushroom dashboard card | next |

## Documentation

- `docs/0001-rfc.md` — why this exists and what was rejected.
- `docs/0002-design.md` — the binding technical design.
- `specs/HAS-school-menu/TDD_PLAN.md` — how it is being built.

Code files in this repository deliberately carry **no comments and no docstrings**; all rationale
lives in the documents above.
