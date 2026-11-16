from __future__ import annotations

import datetime

import pytest

from custom_components.school_menu.date_logic import web_check_week

BERLIN = datetime.timezone(datetime.timedelta(hours=1))


def _at(stamp: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(stamp).replace(tzinfo=BERLIN)


@pytest.mark.parametrize(
    ("now", "expected"),
    [
        ("2026-11-15 17:59:59", None),
        ("2026-11-15 18:00:00", datetime.date(2026, 11, 16)),
        ("2026-11-15 23:59:59", datetime.date(2026, 11, 16)),
        ("2026-11-16 00:00:00", datetime.date(2026, 11, 16)),
        ("2026-11-18 12:00:00", datetime.date(2026, 11, 16)),
        ("2026-11-20 23:59:59", datetime.date(2026, 11, 16)),
        ("2026-11-21 00:00:00", None),
        ("2026-11-21 20:00:00", None),
        ("2026-11-22 00:00:00", None),
        ("2026-12-27 18:00:00", datetime.date(2026, 12, 28)),
        ("2027-01-01 10:00:00", datetime.date(2026, 12, 28)),
    ],
)
def test_the_website_window_runs_from_sunday_evening_to_friday(
    now: str, expected: datetime.date | None
) -> None:
    assert web_check_week(_at(now), 18) == expected
