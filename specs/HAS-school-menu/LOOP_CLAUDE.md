# LOOP_CLAUDE.md — school_menu (HAS)

Resume file for the TDD loop. Root `CLAUDE.md` `@import`s this in a managed block. Keep it small —
the per-iteration journal belongs in `LOOP_STATE.md`.

## Orientation

- **What** — `school_menu`, a Home Assistant custom integration that turns the school's weekly lunch
  PDF into `sensor.school_menu_today` / `_tomorrow` / `_last_import`.
- **Specs** — `docs/0001-rfc.md` (approved), `docs/0002-design.md` (v2, the binding technical design),
  `specs/HAS-school-menu/TDD_PLAN.md` (this loop).
- **Stack** — Python, pytest + `pytest-homeassistant-custom-component`, HA core floor **2026.9.3**,
  `pypdf==6.19.0`. Repo → `github.com/helmerj/HA-Speiseplan`.
- **Ticket scheme** — local key `HAS`. No Jira, no transitions.

## Decisions that are already settled (do not re-litigate)

- No-menu sensor state is the **literal string `none`** with `reason: weekend|no_menu`.
- **Exactly one config entry**, fixed unique id; `services.yaml` has **no** `config_entry_id`.
- `tomorrow` is the **next weekday** — Fri, Sat and Sun all resolve to Monday.
- Allergen codes are **stripped and discarded**; no `allergens` attribute, no `*_raw`.
- Parsing is **lenient**: 1–5 lines per day; >3 keeps all and warns; a 0-line day is omitted and warns.
- Parser has two seams: `extract_lines(bytes)` (only pypdf caller) and `parse_lines(lines)`.
  Edge cases are **string lists**, never synthetic PDF fixtures.
- Two senders (`Maximilian.Stollberg@`, `Lena.Putzmann@annie-heuser.schule`) send the same week every
  week → **three-layer dedup** (byte identity → content identity → genuine update) in §5.5 of the design.
- IMAP is **read-only**: `SINCE`+`FROM` search, `BODY.PEEK[]`, `\Seen` never set.
- Success notification on **manual imports only**; IMAP success is an INFO log plus `last_import`.
- Staleness is surfaced by `sensor.school_menu_last_import`, never by an alarm (holidays = no data).
- Card empty state is German: `Kein Mittagessen`.

Full rationale: `docs/0002-design.md` §10 (R1–R15). If implementation needs to diverge from the design,
**update `docs/0002-design.md` first** — that is a standing rule for this project, not a suggestion.

## Current state

Loop not started. Repo contains `docs/`, `sample file/` (two real PDFs, to be moved to
`tests/fixtures/` in M0) and `specs/HAS-school-menu/`. **Not yet a git repository.**

## Next steps

1. M0 — generate the skeleton per TDD_PLAN §5 M0 (one step), then `scripts/gate.sh M0`.
2. One review round over the generated tree, then the PR.
3. M1 starts the loop proper at TDD_PLAN §5 M1 step 1 (`extract_lines`).

## Learnings

_(append as the loop runs)_
