# Review — M4 (rounds 1–2)

status: converged

Loop: HAS-school-menu · Milestone: M4 · Reviewer: python-services:review-agent (cold, report mode)
Round 1: `changes_requested` — 0 blocker, 1 major, 9 minor, 5 nit.
Round 2: `approved` — 0 blocker, 0 major, 1 minor (closed), 2 nit (accepted).
18 card mutants written by the driver, all killed; the reviewer's 15 independent mutants: 14 killed,
1 equivalent (`d == now+1` → `d <= now+1`; the tomorrow sensor's date is always after today, R3).
(The M3 record this file previously held is summarised in specs/HAS-school-menu/LOOP_STATE.md.)

## Closed — round 1

- [x] [major] `cards/mushroom-today-tomorrow.yaml` — the main course sat in Mushroom's one-line,
      ellipsised `primary`; a 46-character main does not fit a 400 px tile. → layout restructured:
      `primary` is the short day label (≤ 28 chars, tested across a week), the main and further lines
      live in the wrapping `secondary`. Design §9 amended first.
- [x] [minor] `Stand:` never asserted on weekend/no_menu days, where it matters (R15). → exact.
- [x] [minor] substring assertions let separator changes pass (`join(' ')`, `MorgenDonnerstag`).
      → every render asserted as an exact string.
- [x] [minor] 5-line day untested (`[1:4]` survived). → parametrized 4 and 5 lines.
- [x] [minor] `Stand:` format by substring (`%d.%m.%Y` survived). → exact.
- [x] [minor] the harness rendered non-strict with `parse_result=False`, unlike Mushroom's websocket
      path. → `async_render_to_info(strict=True)` with `entity`/`config`/`user` variables.
- [x] [minor] "Morgen" was literally wrong on Fri and Sat. → only when the date is the next
      calendar day; otherwise the bare weekday and date.
- [x] [minor] an unloaded integration read as "Kein Mittagessen / noch kein Import". → unavailable,
      unknown or missing sensors show `Speiseplan nicht verfügbar` and no `Stand:` line.
- [x] [minor] README said a refused mail is reported "once"; it is once per HA start. → reworded.
- [x] [nit] README requirements now name Mushroom; M4 marked done; misnamed test renamed; theme test
      tightened (no colour keys, `card_mod`, `style`); the e2e is one live Sunday→Wednesday
      sequence through the real midnight timer.

## Closed — round 2

- [x] [minor] README claimed the Sunday title omits "Morgen"; Monday *is* the next calendar day on
      Sunday. → "on Fri and Sat just `Montag, 05.10.`".

## Accepted, not changed

- [nit] a disabled `sensor.school_menu_last_import` (diagnostic, so disable-able) makes the card read
  `Stand: noch kein Import`. Disabling the staleness sensor is the operator's choice.
- [nit] Mushroom is not in the repo, so `multiline_secondary` wrapping and `\n` line breaks are
  inferred from its documented behaviour, not rendered. **Open for the operator:** one look at the
  card at 400 px with the 46-character main.
