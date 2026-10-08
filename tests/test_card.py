from __future__ import annotations

import datetime
import re
from pathlib import Path

import pytest
import yaml
from homeassistant.core import HomeAssistant
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import DOMAIN
from custom_components.school_menu.models import DayMenu, ParsedWeek
from tests.card_render import (
    CARD,
    card_text,
    load_card,
    render_card,
    render_icons,
    template_cards,
)

TODAY = "sensor.school_menu_today"
TOMORROW = "sensor.school_menu_next_school_day"
README = Path(__file__).parents[1] / "README.md"
WEEK = {
    "2026-09-28": ("Spaghetti mit Kürbis-Salbei Sauce", "Blattsalat", "Obst"),
    "2026-09-29": ("Süßkartoffel Auflauf", "Rotkohl-Birnen Rohkost", "Vanille Joghurt"),
    "2026-09-30": ("Ananas-Chili mit Kidneybohnen", "Reis", "Blattsalat"),
    "2026-10-01": ("Zucchini-Möhren Puffer mit Kräuterquark", "Kartoffeln", "Obst"),
    "2026-10-02": ("Kürbis-Kokos Suppe", "Brot", "Haferkekse"),
}


def _week(overrides: dict[str, tuple[str, ...]] | None = None) -> ParsedWeek:
    days = {**WEEK, **(overrides or {})}
    return ParsedWeek(
        week_start=datetime.date(2026, 9, 28),
        days=tuple(
            DayMenu(date=datetime.date.fromisoformat(iso), lines=lines)
            for iso, lines in sorted(days.items())
        ),
        source_file="Testplan 26-40.pdf",
        content_hash=f"hash-{sorted((overrides or {}).items())}",
    )


async def _loaded(
    hass: HomeAssistant, entry: MockConfigEntry, week: ParsedWeek | None = None
) -> None:
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    if week is not None:
        coordinator = hass.data[DOMAIN][entry.entry_id]
        assert await coordinator.async_import_week(week, source="manual")
        await hass.async_block_till_done()


def _bare_none(text: str) -> bool:
    return re.search(r"(?<![\w-])none(?![\w-])", text, re.IGNORECASE) is not None


def _readme_blocks() -> list[str]:
    return re.findall(r"```yaml\n(.*?)```", README.read_text(), re.DOTALL)


def test_the_card_is_two_mushroom_template_cards_for_today_and_the_next_school_day() -> None:
    tiles = template_cards(load_card())

    assert [tile["entity"] for tile in tiles] == [TODAY, TOMORROW]
    assert all(tile.get("multiline_secondary") is True for tile in tiles)


def test_the_card_opens_with_the_school_header() -> None:
    first = load_card()["cards"][0]

    assert first == {"type": "custom:mushroom-title-card", "title": "AHS Speiseplan"}


def test_the_card_follows_the_theme() -> None:
    source = CARD.read_text()

    assert not re.search(r"#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(", source)
    assert not re.search(r"^\s*(icon_)?colou?r\s*:", source, re.MULTILINE)
    assert "card_mod" not in source
    assert "style" not in source


def test_every_yaml_block_in_the_readme_parses() -> None:
    blocks = _readme_blocks()

    assert blocks
    for block in blocks:
        yaml.safe_load(block)


def test_the_readme_documents_exactly_the_shipped_card() -> None:
    assert yaml.safe_load(CARD.read_text()) in [yaml.safe_load(b) for b in _readme_blocks()]


async def test_a_school_day(hass: HomeAssistant, config_entry: MockConfigEntry, freezer) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    await _loaded(hass, config_entry, _week())

    assert render_card(hass) == {
        TODAY: {
            "primary": "Heute · Mittwoch, 30.09.",
            "secondary": "Ananas-Chili mit Kidneybohnen\nReis · Blattsalat",
        },
        TOMORROW: {
            "primary": "Morgen · Donnerstag, 01.10.",
            "secondary": (
                "Zucchini-Möhren Puffer mit Kräuterquark\nKartoffeln · Obst\nStand: 30.09."
            ),
        },
    }


async def test_on_friday_the_next_school_day_is_not_called_tomorrow(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-25 13:00:00+02:00")
    await _loaded(hass, config_entry, _week())

    assert render_card(hass)[TOMORROW] == {
        "primary": "Montag, 28.09.",
        "secondary": "Spaghetti mit Kürbis-Salbei Sauce\nBlattsalat · Obst\nStand: 25.09.",
    }


async def test_on_sunday_monday_is_tomorrow(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-27 18:00:00+02:00")
    await _loaded(hass, config_entry, _week())

    assert render_card(hass) == {
        TODAY: {"primary": "Heute · Sonntag, 27.09.", "secondary": "Kein Mittagessen"},
        TOMORROW: {
            "primary": "Morgen · Montag, 28.09.",
            "secondary": "Spaghetti mit Kürbis-Salbei Sauce\nBlattsalat · Obst\nStand: 27.09.",
        },
    }


async def test_a_weekend_with_no_following_week_says_kein_mittagessen_twice(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-10-03 12:00:00+02:00")
    await _loaded(hass, config_entry, _week())
    assert hass.states.get(TODAY).attributes["reason"] == "weekend"

    assert render_card(hass) == {
        TODAY: {"primary": "Heute · Samstag, 03.10.", "secondary": "Kein Mittagessen"},
        TOMORROW: {
            "primary": "Montag, 05.10.",
            "secondary": "Kein Mittagessen\nStand: 03.10.",
        },
    }
    assert not _bare_none(card_text(hass))


async def test_a_holiday_school_day_says_kein_mittagessen_and_keeps_the_stand_line(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    await _loaded(hass, config_entry, _week())
    freezer.move_to("2026-10-07 09:00:00+02:00")
    hass.data[DOMAIN][config_entry.entry_id].async_update_listeners()
    await hass.async_block_till_done()
    assert hass.states.get(TODAY).attributes["reason"] == "no_menu"

    assert render_card(hass) == {
        TODAY: {"primary": "Heute · Mittwoch, 07.10.", "secondary": "Kein Mittagessen"},
        TOMORROW: {
            "primary": "Morgen · Donnerstag, 08.10.",
            "secondary": "Kein Mittagessen\nStand: 30.09.",
        },
    }
    assert not _bare_none(card_text(hass))


@pytest.mark.parametrize(
    "lines",
    [
        ("Chili sin Carne", "Reis", "Blattsalat", "Obst vom Markt"),
        ("Chili sin Carne", "Reis", "Blattsalat", "Obst vom Markt", "Tee"),
    ],
    ids=["four-lines", "five-lines"],
)
async def test_every_line_of_a_long_day_is_shown(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer, lines: tuple[str, ...]
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    await _loaded(hass, config_entry, _week({"2026-09-30": lines}))

    assert render_card(hass)[TODAY]["secondary"] == f"{lines[0]}\n{' · '.join(lines[1:])}"


async def test_a_one_line_day_renders_no_empty_line(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    await _loaded(hass, config_entry, _week({"2026-09-30": ("Suppe",)}))

    assert render_card(hass)[TODAY]["secondary"] == "Suppe"


async def test_a_main_longer_than_the_state_limit_renders_in_full(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    long_main = ("Eintopf " + "mit Gemüse " * 30).strip()
    await _loaded(hass, config_entry, _week({"2026-09-30": (long_main, "Brot")}))
    assert len(hass.states.get(TODAY).state) == 255

    assert render_card(hass)[TODAY]["secondary"] == f"{long_main}\nBrot"


async def test_the_stand_line_uses_the_local_date(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-28 01:30:00+02:00")
    await _loaded(hass, config_entry, _week())

    assert render_card(hass)[TOMORROW]["secondary"] == (
        "Süßkartoffel Auflauf\nRotkohl-Birnen Rohkost · Vanille Joghurt\nStand: 28.09."
    )


async def test_before_any_import_the_stand_line_says_so(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    await _loaded(hass, config_entry)

    assert render_card(hass) == {
        TODAY: {"primary": "Heute · Mittwoch, 30.09.", "secondary": "Kein Mittagessen"},
        TOMORROW: {
            "primary": "Morgen · Donnerstag, 01.10.",
            "secondary": "Kein Mittagessen\nStand: noch kein Import",
        },
    }


@pytest.mark.parametrize("state", ["unavailable", "unknown", None])
async def test_a_missing_integration_is_not_mistaken_for_no_lunch(
    hass: HomeAssistant, state: str | None
) -> None:
    if state is not None:
        for entity_id in (TODAY, TOMORROW, "sensor.school_menu_last_import"):
            hass.states.async_set(entity_id, state, {})

    rendered = render_card(hass)

    assert rendered == {
        TODAY: {"primary": "Heute", "secondary": "Speiseplan nicht verfügbar"},
        TOMORROW: {"primary": "Morgen", "secondary": "Speiseplan nicht verfügbar"},
    }
    assert "Kein Mittagessen" not in card_text(hass)
    assert "Stand:" not in card_text(hass)


@pytest.mark.parametrize("day", range(27, 34))
async def test_the_one_line_titles_stay_short_enough_for_a_400px_tile(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer, day: int
) -> None:
    moment = datetime.date(2026, 9, 1) + datetime.timedelta(days=day - 1)
    freezer.move_to(f"{moment.isoformat()} 12:00:00+02:00")
    await _loaded(hass, config_entry, _week())

    for tile in render_card(hass).values():
        assert len(tile["primary"]) <= 28, tile["primary"]


async def test_a_one_line_next_school_day_renders_no_empty_line(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    await _loaded(hass, config_entry, _week({"2026-10-01": ("Suppe",)}))

    assert render_card(hass)[TOMORROW]["secondary"] == "Suppe\nStand: 30.09."


async def test_every_line_of_the_next_school_day_is_shown(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    five = ("Eintopf", "Brot", "Salat", "Obst", "Tee")
    await _loaded(hass, config_entry, _week({"2026-10-01": five}))

    assert render_card(hass)[TOMORROW]["secondary"] == (
        "Eintopf\nBrot · Salat · Obst · Tee\nStand: 30.09."
    )


async def test_each_tile_shows_the_icon_of_its_dish(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    await _loaded(hass, config_entry, _week())

    assert render_icons(hass) == {TODAY: "mdi:chili-mild", TOMORROW: "mdi:carrot"}


async def test_a_day_without_lunch_keeps_the_neutral_icon(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-26 12:00:00+02:00")
    await _loaded(hass, config_entry, _week())

    assert render_icons(hass) == {TODAY: "mdi:food", TOMORROW: "mdi:pasta"}


@pytest.mark.parametrize("state", ["unavailable", None])
async def test_a_missing_integration_still_renders_an_icon(
    hass: HomeAssistant, state: str | None
) -> None:
    if state is not None:
        for entity_id in (TODAY, TOMORROW):
            hass.states.async_set(entity_id, state, {})

    assert render_icons(hass) == {TODAY: "mdi:food", TOMORROW: "mdi:food"}
