from __future__ import annotations

import datetime

import pytest
from homeassistant.core import HomeAssistant

from custom_components.school_menu.holidays import async_fetch_no_school_days
from tests.fake_calendar import (
    FERIEN,
    WORKDAY,
    FakeCalendar,
    add_calendars,
    all_day,
    ferien_calendar,
    workday_calendar,
)

D = datetime.date.fromisoformat


async def _fetch(hass: HomeAssistant, ferien: str | None, workday: str | None, start: str):
    return await async_fetch_no_school_days(hass, ferien, workday, D(start), 14)


async def test_a_ferien_event_marks_every_day_it_covers(hass: HomeAssistant) -> None:
    await add_calendars(hass, ferien_calendar())

    days = await _fetch(hass, FERIEN, None, "2026-12-21")

    assert D("2026-12-22") not in days
    assert days[D("2026-12-23")] == "Weihnachtsferien Berlin"
    assert days[D("2027-01-02")] == "Weihnachtsferien Berlin"
    assert D("2027-01-03") not in days
    assert D("2027-01-04") not in days


async def test_a_single_free_day_is_marked(hass: HomeAssistant) -> None:
    await add_calendars(hass, ferien_calendar())

    days = await _fetch(hass, FERIEN, None, "2026-11-09")

    assert days == {D("2026-11-13"): "Unterrichtsfreier Tag Berlin"}


async def test_a_weekday_without_a_workday_event_is_a_public_holiday(hass: HomeAssistant) -> None:
    await add_calendars(hass, workday_calendar())

    days = await _fetch(hass, None, WORKDAY, "2026-09-28")

    assert days == {}
    days = await _fetch(hass, None, WORKDAY, "2026-12-21")
    assert days[D("2026-12-25")] == "Feiertag"
    assert D("2026-12-26") not in days
    assert D("2026-12-27") not in days
    assert days[D("2027-01-01")] == "Feiertag"
    assert D("2026-12-24") not in days


async def test_the_ferien_label_wins_over_feiertag(hass: HomeAssistant) -> None:
    await add_calendars(hass, ferien_calendar(), workday_calendar())

    days = await _fetch(hass, FERIEN, WORKDAY, "2026-12-21")

    assert days[D("2026-12-25")] == "Weihnachtsferien Berlin"
    assert days[D("2026-12-23")] == "Weihnachtsferien Berlin"


async def test_both_calendars_are_combined(hass: HomeAssistant) -> None:
    await add_calendars(hass, ferien_calendar(), workday_calendar())

    days = await _fetch(hass, FERIEN, WORKDAY, "2026-10-12")

    assert days == {
        D("2026-10-19") + datetime.timedelta(days=offset): "Herbstferien Berlin"
        for offset in range(7)
    }


async def test_no_calendars_configured_marks_nothing(hass: HomeAssistant) -> None:
    assert await _fetch(hass, None, None, "2026-12-21") == {}


@pytest.mark.parametrize("which", ["ferien", "workday"])
async def test_a_missing_calendar_marks_nothing(hass: HomeAssistant, which: str, caplog) -> None:
    await add_calendars(hass, FakeCalendar("calendar.other", []))
    ferien, workday = (FERIEN, None) if which == "ferien" else (None, WORKDAY)

    assert await _fetch(hass, ferien, workday, "2026-12-21") == {}
    assert "Could not read calendar" in caplog.text


async def test_the_calendar_component_not_loaded_marks_nothing(hass: HomeAssistant, caplog) -> None:
    assert await _fetch(hass, FERIEN, WORKDAY, "2026-12-21") == {}
    assert "Could not read calendar" in caplog.text


async def test_a_failing_calendar_marks_nothing_but_the_other_still_counts(
    hass: HomeAssistant,
) -> None:
    ferien = ferien_calendar()
    ferien.fail = True
    await add_calendars(hass, ferien, workday_calendar())

    days = await _fetch(hass, FERIEN, WORKDAY, "2026-12-21")

    assert days == {D("2026-12-25"): "Feiertag", D("2027-01-01"): "Feiertag"}


async def test_an_empty_workday_calendar_is_not_read_as_all_holidays(
    hass: HomeAssistant, caplog
) -> None:
    await add_calendars(hass, FakeCalendar(WORKDAY, []))

    assert await _fetch(hass, None, WORKDAY, "2026-12-21") == {}
    assert "has no working day" in caplog.text


async def test_a_timed_event_marks_the_local_days_it_touches(hass: HomeAssistant) -> None:
    tz = datetime.timezone(datetime.timedelta(hours=1))
    from homeassistant.components.calendar import CalendarEvent

    await add_calendars(
        hass,
        FakeCalendar(
            FERIEN,
            [
                CalendarEvent(
                    start=datetime.datetime(2026, 11, 18, 8, 0, tzinfo=tz),
                    end=datetime.datetime(2026, 11, 19, 12, 0, tzinfo=tz),
                    summary="Projekttage",
                ),
                all_day("Ende", "2026-11-20", "2026-11-20"),
            ],
        ),
    )

    days = await _fetch(hass, FERIEN, None, "2026-11-16")

    assert days == {
        D("2026-11-18"): "Projekttage",
        D("2026-11-19"): "Projekttage",
        D("2026-11-20"): "Ende",
    }


async def test_an_unreadable_event_is_skipped(caplog) -> None:
    from custom_components.school_menu.holidays import _days_of

    days = _days_of(
        FERIEN,
        [
            {"start": "bogus", "end": "2026-12-24", "summary": "Broken"},
            {"summary": "No dates"},
            {"start": "2026-12-23", "end": "2026-12-24", "summary": "Ferien"},
        ],
        D("2026-12-21"),
        D("2027-01-04"),
    )

    assert days == {D("2026-12-23"): "Ferien"}
    assert caplog.text.count("Skipping an unreadable event") == 2


async def test_a_very_long_event_is_clamped_to_the_window(hass: HomeAssistant) -> None:
    await add_calendars(
        hass, FakeCalendar(FERIEN, [all_day("Schuljahr", "2020-01-01", "2099-12-31")])
    )

    days = await _fetch(hass, FERIEN, None, "2026-12-21")

    assert len(days) == 14
    assert min(days) == D("2026-12-21")
    assert max(days) == D("2027-01-03")


async def test_a_timeout_is_logged_with_its_name(hass: HomeAssistant, caplog) -> None:
    ferien = ferien_calendar()
    ferien.error = TimeoutError()
    await add_calendars(hass, ferien)

    assert await _fetch(hass, FERIEN, None, "2026-12-21") == {}

    assert f"Could not read calendar {FERIEN}: TimeoutError" in caplog.text
