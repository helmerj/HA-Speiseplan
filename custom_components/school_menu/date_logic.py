from __future__ import annotations

import datetime
import re
from typing import Literal

DATE_RANGE = re.compile(
    r"(\d{1,2})\.(\d{1,2})\.(\d{2}(?:\d{2})?)\s*[–—-]\s*(\d{1,2})\.(\d{1,2})\.(\d{2}(?:\d{2})?)"
)
WEEKDAY_COUNT = 5


def parse_header_range(line: str) -> datetime.date | None:
    match = DATE_RANGE.search(line)
    if match is None:
        return None
    day, month, year = int(match[1]), int(match[2]), int(match[3])
    if year < 100:
        year += 2000
    try:
        return datetime.date(year, month, day)
    except ValueError:
        return None


def monday_of(day: datetime.date) -> datetime.date:
    return day - datetime.timedelta(days=day.weekday())


def week_dates(week_start: datetime.date) -> tuple[datetime.date, ...]:
    return tuple(week_start + datetime.timedelta(days=offset) for offset in range(WEEKDAY_COUNT))


def iso_week_key(day: datetime.date) -> str:
    iso = day.isocalendar()
    return f"{iso.year}-W{iso.week:02d}"


def target_date(
    today: datetime.date, which: Literal["today", "next_school_day"]
) -> datetime.date | None:
    if which == "today":
        return today if today.weekday() < WEEKDAY_COUNT else None
    ahead = 1
    while True:
        candidate = today + datetime.timedelta(days=ahead)
        if candidate.weekday() < WEEKDAY_COUNT:
            return candidate
        ahead += 1
