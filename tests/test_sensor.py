from __future__ import annotations

import datetime
import shutil
from pathlib import Path

import pytest
from homeassistant.core import HomeAssistant
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import DOMAIN, NO_MENU_STATE, SERVICE_IMPORT_PDF
from tests.conftest import FIXTURES


def _stage(hass: HomeAssistant, name: str) -> Path:
    www = Path(hass.config.path("www"))
    www.mkdir(parents=True, exist_ok=True)
    target = www / name
    shutil.copyfile(FIXTURES / name, target)
    return target


def _stage_week_40(hass: HomeAssistant) -> Path:
    return _stage(hass, "AHS Speiseplan 26-40.pdf")


TODAY = "sensor.school_menu_today"


async def _setup_with_week_40(hass: HomeAssistant, entry: MockConfigEntry) -> None:
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    target = _stage_week_40(hass)
    await hass.services.async_call(
        DOMAIN, SERVICE_IMPORT_PDF, {"file_path": str(target)}, blocking=True
    )
    await hass.async_block_till_done()


@pytest.mark.parametrize(
    ("now", "expected_main", "expected_weekday"),
    [
        ("2026-09-28 10:00:00+02:00", "Pasta mit Tomaten Sauce dazu Parmesan", "Montag"),
        ("2026-09-29 10:00:00+02:00", "Kartoffel Gratin", "Dienstag"),
        ("2026-09-30 10:00:00+02:00", "Chili sin Carne mit Sauer Sahne", "Mittwoch"),
        (
            "2026-10-01 10:00:00+02:00",
            "Blumenkohl-Brokkoli-Möhre mit Käse überbacken",
            "Donnerstag",
        ),
        ("2026-10-02 10:00:00+02:00", "Lauch-Kartoffel Suppe", "Freitag"),
    ],
)
async def test_every_school_day_reports_its_main(
    hass: HomeAssistant,
    config_entry: MockConfigEntry,
    freezer,
    now,
    expected_main,
    expected_weekday,
) -> None:
    freezer.move_to(now)
    await _setup_with_week_40(hass, config_entry)

    state = hass.states.get(TODAY)
    assert state.state == expected_main
    assert state.attributes["weekday"] == expected_weekday
    assert state.attributes["main"] == expected_main
    assert state.attributes["lines"][0] == expected_main


async def test_a_weekend_reports_none_with_a_reason(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-10-03 10:00:00+02:00")
    await _setup_with_week_40(hass, config_entry)

    state = hass.states.get(TODAY)
    assert state.state == NO_MENU_STATE
    assert state.attributes["reason"] == "weekend"
    assert state.attributes["weekday"] == "Samstag"
    assert "main" not in state.attributes


async def test_a_day_with_no_data_reports_no_menu(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-10-07 10:00:00+02:00")
    await _setup_with_week_40(hass, config_entry)

    state = hass.states.get(TODAY)
    assert state.state == NO_MENU_STATE
    assert state.attributes["reason"] == "no_menu"


async def test_the_side_and_dessert_are_positional(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 10:00:00+02:00")
    await _setup_with_week_40(hass, config_entry)

    attributes = hass.states.get(TODAY).attributes
    assert attributes["side"] == "Reis"
    assert attributes["dessert"] == "Blattsalat mit gerösteten Kernen"


async def test_provenance_reaches_the_attributes(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-28 10:00:00+02:00")
    await _setup_with_week_40(hass, config_entry)

    attributes = hass.states.get(TODAY).attributes
    assert attributes["source_file"] == "AHS Speiseplan 26-40.pdf"
    assert attributes["ingested_at"]
    assert attributes["date"] == datetime.date(2026, 9, 28).isoformat()


async def test_each_day_reports_its_own_weeks_provenance(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-25 08:00:00+02:00")
    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()

    for name in ("AHS Speiseplan 26-39.pdf", "AHS Speiseplan 26-40.pdf"):
        target = _stage(hass, name)
        await hass.services.async_call(
            DOMAIN, SERVICE_IMPORT_PDF, {"file_path": str(target)}, blocking=True
        )
    await hass.async_block_till_done()

    state = hass.states.get(TODAY)
    assert state.state == "Linsen Eintopf"
    assert state.attributes["source_file"] == "AHS Speiseplan 26-39.pdf"


async def test_a_stored_day_with_no_lines_reports_no_menu(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-28 10:00:00+02:00")
    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()

    coordinator = hass.data[DOMAIN][config_entry.entry_id]
    coordinator.store.weeks["2026-W40"] = {
        "week_start": "2026-09-28",
        "source_file": "x.pdf",
        "content_hashes": ["h"],
        "ingested_at": "2026-09-28T08:00:00+02:00",
        "source": "manual",
        "days": {"2026-09-28": {"lines": []}},
    }
    coordinator.store._rebuild_index()
    coordinator.async_set_updated_data(None)
    await hass.async_block_till_done()

    state = hass.states.get(TODAY)
    assert state.state == NO_MENU_STATE
    assert state.attributes["reason"] == "no_menu"
