# HA-Speiseplan

`school_menu` — a Home Assistant custom integration that parses the school's weekly lunch PDF
(Waldorf Charlottenburg / Annie-Heuser-Schule, catered by Organiced Kitchen) into Home Assistant
sensors for today's and tomorrow's lunch.

- `docs/0001-rfc.md` — RFC, approved 2026-09-25.
- `docs/0002-design.md` — **the binding technical design** (v2). Implementation follows it; if a change
  is needed, amend the design first.
- `specs/HAS-school-menu/` — TDD loop plan and loop state.
- `sample file/` — the two real sample PDFs (move to `tests/fixtures/` in M0).

Working mode: gated phases. Stop for approval after every phase and every milestone.

<!-- LOOP:BEGIN (managed by scripts/checkpoint.sh — do not edit by hand) -->
@specs/HAS-school-menu/LOOP_CLAUDE.md
<!-- LOOP:END -->
