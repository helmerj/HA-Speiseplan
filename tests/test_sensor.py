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
    return _stage(hass, "Testplan 26-40.pdf")


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
        ("2026-09-28 10:00:00+02:00", "Spaghetti mit Kürbis-Salbei Sauce", "Montag"),
        ("2026-09-29 10:00:00+02:00", "Süßkartoffel Auflauf", "Dienstag"),
        ("2026-09-30 10:00:00+02:00", "Ananas-Chili mit Kidneybohnen", "Mittwoch"),
        (
            "2026-10-01 10:00:00+02:00",
            "Zucchini-Möhren Puffer mit Kräuterquark",
            "Donnerstag",
        ),
        ("2026-10-02 10:00:00+02:00", "Kürbis-Kokos Suppe", "Freitag"),
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
    assert attributes["dessert"] == "Feldsalat mit Kürbiskernen"


async def test_provenance_reaches_the_attributes(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-28 10:00:00+02:00")
    await _setup_with_week_40(hass, config_entry)

    attributes = hass.states.get(TODAY).attributes
    assert attributes["source_file"] == "Testplan 26-40.pdf"
    assert attributes["ingested_at"]
    assert attributes["date"] == datetime.date(2026, 9, 28).isoformat()


async def test_each_day_reports_its_own_weeks_provenance(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-25 08:00:00+02:00")
    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()

    for name in ("Testplan 26-39.pdf", "Testplan 26-40.pdf"):
        target = _stage(hass, name)
        await hass.services.async_call(
            DOMAIN, SERVICE_IMPORT_PDF, {"file_path": str(target)}, blocking=True
        )
    await hass.async_block_till_done()

    state = hass.states.get(TODAY)
    assert state.state == "Bohnen Eintopf"
    assert state.attributes["source_file"] == "Testplan 26-39.pdf"


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


async def test_last_import_is_a_diagnostic_timestamp_entity(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    from homeassistant.helpers import entity_registry as er
    from homeassistant.helpers.entity import EntityCategory

    freezer.move_to("2026-09-28 10:00:00+02:00")
    await _setup_with_week_40(hass, config_entry)

    entry = er.async_get(hass).async_get("sensor.school_menu_last_import")
    assert entry.entity_category is EntityCategory.DIAGNOSTIC
    assert hass.states.get("sensor.school_menu_last_import").attributes["device_class"] == (
        "timestamp"
    )


async def test_an_unchanged_reimport_does_not_move_last_import(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-28 09:00:00+02:00")
    await _setup_with_week_40(hass, config_entry)
    coordinator = hass.data[DOMAIN][config_entry.entry_id]
    before = coordinator.store.weeks["2026-W40"]["ingested_at"]
    week = coordinator.store.weeks["2026-W40"]

    freezer.move_to("2026-10-05 09:00:00+02:00")
    from custom_components.school_menu.models import DayMenu, ParsedWeek

    same_days = tuple(
        DayMenu(date=datetime.date.fromisoformat(iso), lines=tuple(payload["lines"]))
        for iso, payload in sorted(week["days"].items())
    )
    resaved = ParsedWeek(
        week_start=datetime.date(2026, 9, 28),
        days=same_days,
        source_file="resaved.pdf",
        content_hash="different-bytes",
    )
    assert await coordinator.async_import_week(resaved, source="manual") is False

    assert coordinator.store.weeks["2026-W40"]["ingested_at"] == before
    assert coordinator.store.weeks["2026-W40"]["source_file"] == "Testplan 26-40.pdf"
    assert coordinator.store.weeks["2026-W40"]["content_hashes"][-1] == "different-bytes"


async def test_the_second_menu_sensor_is_named_for_the_next_school_day(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    from homeassistant.helpers import entity_registry as er

    freezer.move_to("2026-09-26 12:00:00+02:00")
    await _setup_with_week_40(hass, config_entry)

    registry = er.async_get(hass)
    entity = registry.async_get("sensor.school_menu_next_school_day")
    assert entity.unique_id == f"{config_entry.entry_id}_next_school_day"
    state = hass.states.get("sensor.school_menu_next_school_day")
    assert state.attributes["friendly_name"] == "School menu Next school day"
    assert state.attributes["weekday"] == "Montag"
    assert (
        registry.async_get_entity_id("sensor", DOMAIN, f"{config_entry.entry_id}_tomorrow") is None
    )
    assert hass.states.get("sensor.school_menu_tomorrow") is None


async def test_entity_ids_stay_fixed_whatever_the_entry_is_called(
    hass: HomeAssistant, freezer
) -> None:
    from homeassistant.helpers import area_registry as ar
    from homeassistant.helpers import device_registry as dr

    from custom_components.school_menu.const import SINGLE_ENTRY_UNIQUE_ID

    freezer.move_to("2026-09-28 10:00:00+02:00")
    entry = MockConfigEntry(
        domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, title="AHS Speiseplan", data={}
    )
    await _setup_with_week_40(hass, entry)
    kitchen = ar.async_get(hass).async_create("Küche")
    devices = dr.async_get(hass)
    device = dr.async_entries_for_config_entry(devices, entry.entry_id)[0]
    devices.async_update_device(device.id, area_id=kitchen.id)

    ids = sorted(state.entity_id for state in hass.states.async_all("sensor"))

    assert ids == [
        "sensor.school_menu_last_import",
        "sensor.school_menu_next_school_day",
        "sensor.school_menu_today",
    ]
    assert hass.states.get("sensor.school_menu_today").state == (
        "Spaghetti mit Kürbis-Salbei Sauce"
    )


@pytest.mark.parametrize(
    ("now", "today_icon", "next_icon"),
    [
        ("2026-09-30 10:00:00+02:00", "mdi:chili-mild", "mdi:carrot"),
        ("2026-10-02 10:00:00+02:00", "mdi:pot-steam", "mdi:food"),
        ("2026-09-26 10:00:00+02:00", "mdi:food", "mdi:pasta"),
    ],
)
async def test_the_menu_sensors_show_an_icon_matching_the_dish(
    hass: HomeAssistant,
    config_entry: MockConfigEntry,
    freezer,
    now: str,
    today_icon: str,
    next_icon: str,
) -> None:
    freezer.move_to(now)
    await _setup_with_week_40(hass, config_entry)

    assert hass.states.get(TODAY).attributes["icon"] == today_icon
    assert hass.states.get("sensor.school_menu_next_school_day").attributes["icon"] == next_icon
