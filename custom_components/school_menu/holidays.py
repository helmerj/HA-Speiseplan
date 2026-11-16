from __future__ import annotations

import asyncio
import datetime
import logging
from dataclasses import dataclass
from typing import Any

from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.util import dt as dt_util

from .const import HOLIDAY_LOOKUP_TIMEOUT_SECONDS, PUBLIC_HOLIDAY_LABEL
from .date_logic import WEEKDAY_COUNT

_LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class NoSchoolLookup:
    ferien: dict[datetime.date, str] | None
    feiertage: dict[datetime.date, str] | None

    @property
    def failed(self) -> bool:
        return self.ferien is None or self.feiertage is None


def merge(ferien: dict[datetime.date, str], feiertage: dict[datetime.date, str]) -> dict:
    return {**feiertage, **ferien}


def _as_local_date(value: str, *, is_end: bool) -> datetime.date:
    stamp = dt_util.parse_datetime(value)
    if stamp is None:
        day = datetime.date.fromisoformat(value)
        return day - datetime.timedelta(days=1) if is_end else day
    local = dt_util.as_local(stamp)
    if is_end and local.time() == datetime.time.min:
        return local.date() - datetime.timedelta(days=1)
    return local.date()


def _event_days(
    event: dict[str, Any], start: datetime.date, end: datetime.date
) -> list[datetime.date]:
    first = max(_as_local_date(str(event["start"]), is_end=False), start)
    last = min(_as_local_date(str(event["end"]), is_end=True), end - datetime.timedelta(days=1))
    span = (last - first).days
    return [first + datetime.timedelta(days=offset) for offset in range(span + 1)]


def _days_of(
    entity_id: str, events: list[dict[str, Any]], start: datetime.date, end: datetime.date
) -> dict[datetime.date, str]:
    days: dict[datetime.date, str] = {}
    for event in events:
        try:
            covered = _event_days(event, start, end)
        except (KeyError, TypeError, ValueError) as err:
            _LOGGER.warning("Skipping an unreadable event in %s: %r", entity_id, err)
            continue
        label = str(event.get("summary") or "Ferien")
        for day in covered:
            days[day] = label
    return days


async def _async_events(
    hass: HomeAssistant, entity_id: str, start: datetime.date, end: datetime.date
) -> list[dict[str, Any]] | None:
    try:
        async with asyncio.timeout(HOLIDAY_LOOKUP_TIMEOUT_SECONDS):
            response = await hass.services.async_call(
                "calendar",
                "get_events",
                {
                    "entity_id": entity_id,
                    "start_date_time": dt_util.start_of_local_day(start),
                    "end_date_time": dt_util.start_of_local_day(end),
                },
                blocking=True,
                return_response=True,
            )
    except (HomeAssistantError, TimeoutError, RuntimeError) as err:
        _LOGGER.warning("Could not read calendar %s: %s", entity_id, str(err) or type(err).__name__)
        return None
    if not isinstance(response, dict) or not isinstance(response.get(entity_id), dict):
        _LOGGER.warning("Could not read calendar %s: no answer", entity_id)
        return None
    return list(response[entity_id].get("events", []))


async def _async_ferien(
    hass: HomeAssistant, entity_id: str | None, start: datetime.date, end: datetime.date
) -> dict[datetime.date, str] | None:
    if not entity_id:
        return {}
    events = await _async_events(hass, entity_id, start, end)
    return None if events is None else _days_of(entity_id, events, start, end)


async def _async_feiertage(
    hass: HomeAssistant, entity_id: str | None, start: datetime.date, end: datetime.date
) -> dict[datetime.date, str] | None:
    if not entity_id:
        return {}
    events = await _async_events(hass, entity_id, start, end)
    if events is None:
        return None
    working = set(_days_of(entity_id, events, start, end))
    if not working:
        _LOGGER.warning(
            "Calendar %s has no working day in the next %d days; ignoring it",
            entity_id,
            (end - start).days,
        )
        return None
    days = (end - start).days
    window = (start + datetime.timedelta(days=offset) for offset in range(days))
    return {
        day: PUBLIC_HOLIDAY_LABEL
        for day in window
        if day.weekday() < WEEKDAY_COUNT and day not in working
    }


async def async_lookup_no_school(
    hass: HomeAssistant,
    holiday_calendar: str | None,
    workday_calendar: str | None,
    start: datetime.date,
    days: int,
) -> NoSchoolLookup:
    end = start + datetime.timedelta(days=days)
    ferien, feiertage = await asyncio.gather(
        _async_ferien(hass, holiday_calendar, start, end),
        _async_feiertage(hass, workday_calendar, start, end),
    )
    return NoSchoolLookup(ferien=ferien, feiertage=feiertage)


async def async_fetch_no_school_days(
    hass: HomeAssistant,
    holiday_calendar: str | None,
    workday_calendar: str | None,
    start: datetime.date,
    days: int,
) -> dict[datetime.date, str]:
    lookup = await async_lookup_no_school(hass, holiday_calendar, workday_calendar, start, days)
    return merge(lookup.ferien or {}, lookup.feiertage or {})
