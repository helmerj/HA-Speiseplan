from __future__ import annotations

import datetime

from homeassistant.components.calendar import DATA_COMPONENT, CalendarEntity, CalendarEvent
from homeassistant.core import HomeAssistant
from homeassistant.setup import async_setup_component

FERIEN = "calendar.schulferien_berlin"
WORKDAY = "calendar.workday_sensor_kalender"


class FakeCalendar(CalendarEntity):
    def __init__(self, entity_id: str, events: list[CalendarEvent]) -> None:
        self.entity_id = entity_id
        self._attr_name = entity_id.split(".", 1)[1]
        self._attr_unique_id = entity_id
        self.events = events
        self.fail = False
        self.error: Exception | None = None

    @property
    def event(self) -> CalendarEvent | None:
        return None

    async def async_get_events(
        self, hass: HomeAssistant, start_date: datetime.datetime, end_date: datetime.datetime
    ) -> list[CalendarEvent]:
        if self.error is not None:
            raise self.error
        if self.fail:
            raise RuntimeError("calendar backend down")
        found = []
        for event in self.events:
            start = event.start_datetime_local
            end = event.end_datetime_local
            if start < end_date and end > start_date:
                found.append(event)
        return found


def all_day(summary: str, first: str, last_inclusive: str) -> CalendarEvent:
    start = datetime.date.fromisoformat(first)
    end = datetime.date.fromisoformat(last_inclusive) + datetime.timedelta(days=1)
    return CalendarEvent(start=start, end=end, summary=summary)


def workdays(first: str, last: str, *, except_days: tuple[str, ...] = ()) -> list[CalendarEvent]:
    day = datetime.date.fromisoformat(first)
    stop = datetime.date.fromisoformat(last)
    skipped = {datetime.date.fromisoformat(d) for d in except_days}
    events = []
    while day <= stop:
        if day.weekday() < 5 and day not in skipped:
            events.append(
                CalendarEvent(start=day, end=day + datetime.timedelta(days=1), summary="Workday")
            )
        day += datetime.timedelta(days=1)
    return events


async def add_calendars(hass: HomeAssistant, *calendars: FakeCalendar) -> None:
    assert await async_setup_component(hass, "calendar", {})
    await hass.data[DATA_COMPONENT].async_add_entities(list(calendars))
    await hass.async_block_till_done()


def ferien_calendar() -> FakeCalendar:
    return FakeCalendar(
        FERIEN,
        [
            all_day("Herbstferien Berlin", "2026-10-19", "2026-10-31"),
            all_day("Unterrichtsfreier Tag Berlin", "2026-11-13", "2026-11-13"),
            all_day("Weihnachtsferien Berlin", "2026-12-23", "2027-01-02"),
        ],
    )


def workday_calendar() -> FakeCalendar:
    return FakeCalendar(
        WORKDAY,
        workdays(
            "2026-09-01",
            "2027-01-31",
            except_days=("2026-10-03", "2026-12-25", "2026-12-26", "2027-01-01"),
        ),
    )
