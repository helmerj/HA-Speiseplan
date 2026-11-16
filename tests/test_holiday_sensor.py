from __future__ import annotations

import datetime
from unittest.mock import AsyncMock

import pytest
from homeassistant.core import HomeAssistant
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import MockConfigEntry, async_fire_time_changed

from custom_components.school_menu.const import DOMAIN, SINGLE_ENTRY_UNIQUE_ID, SOURCE_MANUAL
from custom_components.school_menu.models import DayMenu, ParsedWeek
from tests.fake_calendar import (
    FERIEN,
    WORKDAY,
    add_calendars,
    ferien_calendar,
    workday_calendar,
)

pytestmark = pytest.mark.m8

TODAY = "sensor.school_menu_today"
NEXT = "sensor.school_menu_next_school_day"
BOTH = {"holiday_calendar": FERIEN, "workday_calendar": WORKDAY}


def _entry(data: dict) -> MockConfigEntry:
    return MockConfigEntry(domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data=data)


async def _setup(hass: HomeAssistant, data: dict = BOTH, *, calendars: bool = True):
    if calendars:
        await add_calendars(hass, ferien_calendar(), workday_calendar())
    entry = _entry(data)
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done(wait_background_tasks=True)
    return hass.data[DOMAIN][entry.entry_id]


async def _tick(hass: HomeAssistant, freezer, stamp: str) -> None:
    freezer.move_to(stamp)
    async_fire_time_changed(hass, dt_util.utcnow())
    await hass.async_block_till_done(wait_background_tasks=True)


def _reason(hass: HomeAssistant, entity_id: str) -> tuple[str, str | None, str | None]:
    state = hass.states.get(entity_id)
    return state.state, state.attributes.get("reason"), state.attributes.get("holiday")


async def test_a_school_day_without_a_menu_is_not_a_holiday(hass: HomeAssistant, freezer) -> None:
    freezer.move_to("2026-11-16 09:00:00+01:00")
    await _setup(hass)

    assert _reason(hass, TODAY) == ("none", "no_menu", None)
    assert _reason(hass, NEXT) == ("none", "no_menu", None)


async def test_a_ferien_day_is_a_holiday(hass: HomeAssistant, freezer) -> None:
    freezer.move_to("2026-12-23 09:00:00+01:00")
    await _setup(hass)

    assert _reason(hass, TODAY) == ("none", "holiday", "Weihnachtsferien Berlin")
    assert _reason(hass, NEXT) == ("none", "holiday", "Weihnachtsferien Berlin")


async def test_a_public_holiday_comes_from_the_workday_calendar(
    hass: HomeAssistant, freezer
) -> None:
    freezer.move_to("2026-12-24 09:00:00+01:00")
    await _setup(hass, {"workday_calendar": WORKDAY})

    assert _reason(hass, TODAY) == ("none", "no_menu", None)
    assert _reason(hass, NEXT) == ("none", "holiday", "Feiertag")


async def test_a_stored_menu_wins_over_the_calendar(hass: HomeAssistant, freezer) -> None:
    freezer.move_to("2026-12-23 09:00:00+01:00")
    coordinator = await _setup(hass)
    day = datetime.date(2026, 12, 23)
    week = ParsedWeek(
        week_start=datetime.date(2026, 12, 21),
        days=(DayMenu(date=day, lines=("Notbetreuung Pasta",)),),
        source_file="plan.pdf",
        content_hash="h52",
    )
    await coordinator.async_import_week(week, source=SOURCE_MANUAL)
    await hass.async_block_till_done()

    state = hass.states.get(TODAY)
    assert state.state == "Notbetreuung Pasta"
    assert "reason" not in state.attributes


@pytest.mark.parametrize(
    ("stamp", "today", "next_school_day"),
    [
        (
            "2027-01-01 09:00:00+01:00",
            ("none", "holiday", "Weihnachtsferien Berlin"),
            ("none", "holiday", "Weihnachtsferien Berlin"),
        ),
        (
            "2027-01-02 09:00:00+01:00",
            ("none", "weekend", None),
            ("none", "holiday", "Weihnachtsferien Berlin"),
        ),
        (
            "2027-01-03 09:00:00+01:00",
            ("none", "weekend", None),
            ("none", "no_menu", None),
        ),
        (
            "2027-01-04 09:00:00+01:00",
            ("none", "no_menu", None),
            ("none", "no_menu", None),
        ),
    ],
)
async def test_the_end_of_the_ferien(
    hass: HomeAssistant, freezer, stamp: str, today: tuple, next_school_day: tuple
) -> None:
    freezer.move_to(stamp)
    await _setup(hass)

    assert _reason(hass, TODAY) == today
    assert _reason(hass, NEXT) == next_school_day


async def test_a_friday_before_the_ferien_points_at_them(hass: HomeAssistant, freezer) -> None:
    freezer.move_to("2026-10-16 09:00:00+02:00")
    await _setup(hass)

    assert _reason(hass, TODAY) == ("none", "no_menu", None)
    assert _reason(hass, NEXT) == ("none", "holiday", "Herbstferien Berlin")


async def test_without_calendars_nothing_changes(hass: HomeAssistant, freezer) -> None:
    freezer.move_to("2026-12-23 09:00:00+01:00")
    await _setup(hass, {})

    assert _reason(hass, TODAY) == ("none", "no_menu", None)
    assert _reason(hass, NEXT) == ("none", "no_menu", None)


async def test_midnight_moves_the_window(hass: HomeAssistant, freezer) -> None:
    freezer.move_to("2026-12-09 12:00:00+01:00")
    coordinator = await _setup(hass)
    assert datetime.date(2026, 12, 23) not in coordinator.no_school

    for day in range(10, 24):
        await _tick(hass, freezer, f"2026-12-{day:02d} 00:00:00+01:00")

    assert _reason(hass, TODAY) == ("none", "holiday", "Weihnachtsferien Berlin")


async def test_a_calendar_that_loads_later_is_picked_up(hass: HomeAssistant, freezer) -> None:
    freezer.move_to("2026-12-23 09:00:00+01:00")
    await _setup(hass, calendars=False)
    assert _reason(hass, TODAY) == ("none", "no_menu", None)

    await add_calendars(hass, ferien_calendar(), workday_calendar())
    await hass.async_block_till_done(wait_background_tasks=True)

    assert _reason(hass, TODAY) == ("none", "holiday", "Weihnachtsferien Berlin")


async def test_an_unchanged_calendar_notifies_no_listener(hass: HomeAssistant, freezer) -> None:
    freezer.move_to("2026-12-23 09:00:00+01:00")
    coordinator = await _setup(hass)
    calls: list[None] = []
    coordinator.async_add_listener(lambda: calls.append(None))

    await coordinator.async_refresh_no_school()

    assert calls == []


async def test_a_holiday_week_makes_no_website_request(
    hass: HomeAssistant, freezer, web_fetch: AsyncMock
) -> None:
    freezer.move_to("2026-12-28 09:00:00+01:00")
    coordinator = await _setup(hass)

    await coordinator.async_check_website()

    web_fetch.assert_not_awaited()


async def test_a_week_with_one_school_day_is_still_checked(
    hass: HomeAssistant, freezer, web_fetch: AsyncMock
) -> None:
    freezer.move_to("2026-12-20 20:00:00+01:00")
    coordinator = await _setup(hass)
    web_fetch.reset_mock()

    await coordinator.async_check_website()

    web_fetch.assert_awaited_once()


async def test_a_holiday_week_is_skipped_from_its_tuesday_on(
    hass: HomeAssistant, freezer, web_fetch: AsyncMock
) -> None:
    freezer.move_to("2026-12-29 09:00:00+01:00")
    coordinator = await _setup(hass)

    await coordinator.async_check_website()

    web_fetch.assert_not_awaited()


async def test_a_week_whose_rest_has_school_is_still_checked(
    hass: HomeAssistant, freezer, web_fetch: AsyncMock
) -> None:
    freezer.move_to("2026-12-22 09:00:00+01:00")
    await _setup(hass)

    web_fetch.assert_awaited_once()


async def test_a_weekday_public_holiday_does_not_hide_a_missing_menu(
    hass: HomeAssistant, freezer
) -> None:
    from tests.fake_calendar import FakeCalendar, workdays

    freezer.move_to("2026-11-16 09:00:00+01:00")
    await add_calendars(
        hass,
        FakeCalendar(WORKDAY, workdays("2026-11-01", "2026-12-15", except_days=("2026-11-16",))),
    )
    await _setup(hass, {"workday_calendar": WORKDAY}, calendars=False)

    assert _reason(hass, TODAY) == ("none", "holiday", "Feiertag")
    assert _reason(hass, NEXT) == ("none", "no_menu", None)


async def test_overlapping_refreshes_end_with_the_newest_data(hass: HomeAssistant, freezer) -> None:
    import asyncio
    from unittest.mock import patch

    from custom_components.school_menu.holidays import NoSchoolLookup

    freezer.move_to("2026-12-23 09:00:00+01:00")
    coordinator = await _setup(hass)
    release = asyncio.Event()
    stale = NoSchoolLookup(ferien={}, feiertage={})
    fresh = NoSchoolLookup(ferien={datetime.date(2026, 12, 23): "Neu"}, feiertage={})
    answers = iter([stale, fresh])

    async def _lookup(*_args, **_kwargs):
        answer = next(answers)
        if answer is stale:
            await release.wait()
        return answer

    with patch(
        "custom_components.school_menu.coordinator.async_lookup_no_school",
        side_effect=_lookup,
    ) as lookup:
        first = hass.async_create_task(coordinator.async_refresh_no_school())
        await asyncio.sleep(0)
        second = hass.async_create_task(coordinator.async_refresh_no_school())
        await asyncio.sleep(0)
        await coordinator.async_refresh_no_school()
        release.set()
        await first
        await second

    assert lookup.call_count == 2
    assert coordinator.no_school == {datetime.date(2026, 12, 23): "Neu"}


async def test_a_failed_lookup_keeps_the_last_days_and_retries(
    hass: HomeAssistant, freezer
) -> None:
    from homeassistant.components.calendar import DATA_COMPONENT

    freezer.move_to("2026-12-23 09:00:00+01:00")
    coordinator = await _setup(hass)
    ferien = hass.data[DATA_COMPONENT].get_entity(FERIEN)
    ferien.fail = True

    await coordinator.async_refresh_no_school()

    assert coordinator.no_school[datetime.date(2026, 12, 23)] == "Weihnachtsferien Berlin"

    ferien.fail = False
    ferien.events[2] = ferien.events[2].__class__(
        start=datetime.date(2026, 12, 23),
        end=datetime.date(2027, 1, 3),
        summary="Weihnachtsferien (neu)",
    )
    await _tick(hass, freezer, "2026-12-23 09:16:00+01:00")

    assert coordinator.no_school[datetime.date(2026, 12, 23)] == "Weihnachtsferien (neu)"


async def test_a_calendar_error_does_not_cancel_the_first_website_check(
    hass: HomeAssistant, freezer, web_fetch: AsyncMock, caplog
) -> None:
    from unittest.mock import patch

    freezer.move_to("2026-11-16 09:00:00+01:00")
    with patch(
        "custom_components.school_menu.coordinator.SchoolMenuCoordinator.async_refresh_no_school",
        side_effect=ValueError("bad event"),
    ):
        await _setup(hass)

    web_fetch.assert_awaited_once()
    assert "Could not read the holiday calendars" in caplog.text


async def test_attribute_only_calendar_writes_do_not_refresh(hass: HomeAssistant, freezer) -> None:
    from unittest.mock import patch

    freezer.move_to("2026-11-16 09:00:00+01:00")
    await _setup(hass)
    current = hass.states.get(FERIEN)

    with patch(
        "custom_components.school_menu.coordinator.SchoolMenuCoordinator.async_refresh_no_school"
    ) as refresh:
        hass.states.async_set(FERIEN, current.state, {**current.attributes, "x": 1})
        await hass.async_block_till_done()
        assert refresh.call_count == 0
        hass.states.async_set(FERIEN, "on", current.attributes)
        await hass.async_block_till_done()
        assert refresh.call_count == 1


async def test_a_time_zone_change_refreshes_the_holidays(hass: HomeAssistant, freezer) -> None:
    from unittest.mock import patch

    freezer.move_to("2026-11-16 09:00:00+01:00")
    await _setup(hass)

    with patch(
        "custom_components.school_menu.coordinator.SchoolMenuCoordinator.async_refresh_no_school"
    ) as refresh:
        await hass.config.async_update(time_zone="Europe/London")
        await hass.async_block_till_done()

    assert refresh.call_count == 1
