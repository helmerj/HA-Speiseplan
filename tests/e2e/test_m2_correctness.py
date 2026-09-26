from __future__ import annotations

import datetime
import shutil
from pathlib import Path

import pytest
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import MockConfigEntry, async_fire_time_changed

from custom_components.school_menu.const import DOMAIN, NO_MENU_STATE, SERVICE_IMPORT_PDF
from tests.conftest import FIXTURES

pytestmark = [pytest.mark.e2e, pytest.mark.m2]

TODAY = "sensor.school_menu_today"
TOMORROW = "sensor.school_menu_next_school_day"


def _stage(hass: HomeAssistant, name: str) -> Path:
    www = Path(hass.config.path("www"))
    www.mkdir(parents=True, exist_ok=True)
    target = www / name
    shutil.copyfile(FIXTURES / name, target)
    return target


def _write(hass: HomeAssistant, name: str, payload: bytes) -> Path:
    www = Path(hass.config.path("www"))
    www.mkdir(parents=True, exist_ok=True)
    target = www / name
    target.write_bytes(payload)
    return target


async def _setup(hass: HomeAssistant, entry: MockConfigEntry) -> None:
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()


async def _import(hass: HomeAssistant, path: Path) -> None:
    await hass.services.async_call(
        DOMAIN, SERVICE_IMPORT_PDF, {"file_path": str(path)}, blocking=True
    )
    await hass.async_block_till_done()


async def test_the_weekend_shows_monday_as_the_next_school_day(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-10-03 12:00:00+02:00")
    await _setup(hass, config_entry)
    await _import(hass, _stage(hass, "AHS Speiseplan 26-40.pdf"))

    today = hass.states.get(TODAY)
    assert today.state == NO_MENU_STATE
    assert today.attributes["reason"] == "weekend"

    tomorrow = hass.states.get(TOMORROW)
    assert tomorrow.attributes["date"] == "2026-10-05"
    assert tomorrow.attributes["weekday"] == "Montag"


async def test_midnight_rolls_today_over_without_a_reimport(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-29 12:00:00+02:00")
    await _setup(hass, config_entry)
    await _import(hass, _stage(hass, "AHS Speiseplan 26-40.pdf"))
    assert hass.states.get(TODAY).state == "Kartoffel Gratin"

    freezer.move_to("2026-09-30 00:00:01+02:00")
    async_fire_time_changed(hass, dt_util.now())
    await hass.async_block_till_done()

    assert hass.states.get(TODAY).state == "Chili sin Carne mit Sauer Sahne"
    assert hass.states.get(TOMORROW).state == "Blumenkohl-Brokkoli-Möhre mit Käse überbacken"


async def test_a_corrupt_pdf_leaves_every_sensor_untouched(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 12:00:00+02:00")
    await _setup(hass, config_entry)
    await _import(hass, _stage(hass, "AHS Speiseplan 26-40.pdf"))

    coordinator = hass.data[DOMAIN][config_entry.entry_id]
    before_weeks = {key: dict(value) for key, value in coordinator.store.weeks.items()}
    before_today = hass.states.get(TODAY).state
    before_last_import = hass.states.get("sensor.school_menu_last_import").state

    with pytest.raises(HomeAssistantError):
        await _import(hass, _write(hass, "broken.pdf", b"definitely not a pdf"))

    assert coordinator.store.weeks == before_weeks
    assert hass.states.get(TODAY).state == before_today
    assert hass.states.get("sensor.school_menu_last_import").state == before_last_import


async def test_last_import_reports_the_week_it_stored(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-28 09:00:00+02:00")
    await _setup(hass, config_entry)
    await _import(hass, _stage(hass, "AHS Speiseplan 26-40.pdf"))

    state = hass.states.get("sensor.school_menu_last_import")
    assert state.attributes["week"] == "2026-W40"
    assert state.attributes["source_file"] == "AHS Speiseplan 26-40.pdf"
    assert state.attributes["source"] == "manual"
    assert state.attributes["weeks_stored"] == 1
    assert dt_util.parse_datetime(state.state) is not None


async def test_an_unimported_school_day_reports_no_menu(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-10-07 12:00:00+02:00")
    await _setup(hass, config_entry)
    await _import(hass, _stage(hass, "AHS Speiseplan 26-40.pdf"))

    for entity in (TODAY, TOMORROW):
        state = hass.states.get(entity)
        assert state.state == NO_MENU_STATE
        assert state.attributes["reason"] == "no_menu"
        assert (
            state.attributes["date"]
            == datetime.date(2026, 10, 7 if entity == TODAY else 8).isoformat()
        )


async def test_the_midnight_listener_is_released_on_unload(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-29 12:00:00+02:00")
    await _setup(hass, config_entry)
    coordinator = hass.data[DOMAIN][config_entry.entry_id]

    fired: list[None] = []
    coordinator.async_update_listeners = lambda: fired.append(None)

    freezer.move_to("2026-09-30 00:00:01+02:00")
    async_fire_time_changed(hass, dt_util.now())
    await hass.async_block_till_done()
    assert fired

    assert await hass.config_entries.async_unload(config_entry.entry_id)
    await hass.async_block_till_done()
    fired.clear()

    freezer.move_to("2026-10-01 00:00:01+02:00")
    async_fire_time_changed(hass, dt_util.now())
    await hass.async_block_till_done()

    assert fired == []


async def test_last_import_tracks_the_most_recent_of_several_weeks(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-21 09:00:00+02:00")
    await _setup(hass, config_entry)
    await _import(hass, _stage(hass, "AHS Speiseplan 26-39.pdf"))
    first = hass.states.get("sensor.school_menu_last_import").state

    freezer.move_to("2026-09-27 18:30:00+02:00")
    await _import(hass, _stage(hass, "AHS Speiseplan 26-40.pdf"))

    state = hass.states.get("sensor.school_menu_last_import")
    assert state.state != first
    assert dt_util.parse_datetime(state.state) > dt_util.parse_datetime(first)
    assert state.attributes["week"] == "2026-W40"
    assert state.attributes["source_file"] == "AHS Speiseplan 26-40.pdf"
    assert state.attributes["weeks_stored"] == 2


async def _count_fires(hass: HomeAssistant, coordinator, freezer, start: str, hours: int) -> int:
    fired: list[None] = []
    coordinator.async_update_listeners = lambda: fired.append(None)
    moment = dt_util.parse_datetime(start)
    for _ in range(hours * 4):
        moment = moment + datetime.timedelta(minutes=15)
        freezer.move_to(moment)
        async_fire_time_changed(hass, dt_util.utcnow())
        await hass.async_block_till_done()
    return len(fired)


async def test_the_rollover_fires_exactly_once_per_day(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-28 12:00:00+02:00")
    await _setup(hass, config_entry)
    coordinator = hass.data[DOMAIN][config_entry.entry_id]

    fires = await _count_fires(hass, coordinator, freezer, "2026-09-28T12:00:00+02:00", 48)

    assert fires == 2


async def test_the_rollover_fires_once_per_local_day_across_spring_forward(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-03-28 12:00:00+01:00")
    await _setup(hass, config_entry)
    coordinator = hass.data[DOMAIN][config_entry.entry_id]

    fires = await _count_fires(hass, coordinator, freezer, "2026-03-28T12:00:00+01:00", 48)

    assert fires == 2


async def test_the_rollover_fires_once_per_local_day_across_fall_back(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-10-24 12:00:00+02:00")
    await _setup(hass, config_entry)
    coordinator = hass.data[DOMAIN][config_entry.entry_id]

    fires = await _count_fires(hass, coordinator, freezer, "2026-10-24T12:00:00+02:00", 48)

    assert fires == 2


async def test_the_displayed_day_advances_by_one_across_spring_forward(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-03-27 12:00:00+01:00")
    await _setup(hass, config_entry)
    assert hass.states.get(TODAY).attributes["date"] == "2026-03-27"

    freezer.move_to("2026-03-30 00:00:30+02:00")
    async_fire_time_changed(hass, dt_util.utcnow())
    await hass.async_block_till_done()

    assert hass.states.get(TODAY).attributes["date"] == "2026-03-30"
    assert hass.states.get(TODAY).attributes["weekday"] == "Montag"


async def test_a_timezone_change_refreshes_the_sensors_immediately(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-10-04 20:00:00+02:00")
    await _setup(hass, config_entry)
    assert hass.states.get(TODAY).attributes["date"] == "2026-10-04"
    assert hass.states.get(TODAY).attributes["reason"] == "weekend"

    await hass.config.async_update(time_zone="Pacific/Auckland")
    await hass.async_block_till_done()

    today = hass.states.get(TODAY)
    assert today.attributes["date"] == "2026-10-05"
    assert today.attributes["weekday"] == "Montag"
    assert today.attributes.get("reason") != "weekend"
