from __future__ import annotations

import datetime

import pytest

from custom_components.school_menu.date_logic import (
    iso_week_key,
    monday_of,
    parse_header_range,
    target_date,
    week_dates,
)


def test_header_range_with_en_dash_and_two_digit_years() -> None:
    assert parse_header_range("28.09.26 – 02.10.26") == datetime.date(2026, 9, 28)


@pytest.mark.parametrize("dash", ["–", "—", "-"])
def test_every_dash_variant_is_accepted(dash: str) -> None:
    assert parse_header_range(f"28.09.26 {dash} 02.10.26") == datetime.date(2026, 9, 28)


def test_four_digit_years_are_accepted() -> None:
    assert parse_header_range("28.09.2026 – 02.10.2026") == datetime.date(2026, 9, 28)


def test_a_line_without_a_range_yields_none() -> None:
    assert parse_header_range("WOCHENPLAN") is None


def test_a_non_monday_start_normalises_back_to_monday() -> None:
    assert monday_of(datetime.date(2026, 9, 30)) == datetime.date(2026, 9, 28)


def test_week_dates_are_five_consecutive_weekdays() -> None:
    assert week_dates(datetime.date(2026, 9, 28)) == (
        datetime.date(2026, 9, 28),
        datetime.date(2026, 9, 29),
        datetime.date(2026, 9, 30),
        datetime.date(2026, 10, 1),
        datetime.date(2026, 10, 2),
    )


def test_a_week_crossing_new_year_derives_from_the_start_date_alone() -> None:
    assert week_dates(datetime.date(2026, 12, 28))[4] == datetime.date(2027, 1, 1)


@pytest.mark.parametrize(
    ("day", "expected"),
    [
        (datetime.date(2026, 9, 21), "2026-W39"),
        (datetime.date(2026, 9, 28), "2026-W40"),
        (datetime.date(2026, 12, 28), "2026-W53"),
        (datetime.date(2027, 1, 1), "2026-W53"),
    ],
)
def test_iso_week_key_matches_the_filename_convention(day: datetime.date, expected: str) -> None:
    assert iso_week_key(day) == expected


@pytest.mark.parametrize(
    ("today", "expected"),
    [
        (datetime.date(2026, 9, 28), datetime.date(2026, 9, 28)),
        (datetime.date(2026, 10, 2), datetime.date(2026, 10, 2)),
        (datetime.date(2026, 10, 3), None),
        (datetime.date(2026, 10, 4), None),
    ],
)
def test_today_is_none_at_the_weekend(today: datetime.date, expected) -> None:
    assert target_date(today, "today") == expected


@pytest.mark.parametrize(
    ("today", "expected"),
    [
        (datetime.date(2026, 9, 28), datetime.date(2026, 9, 29)),
        (datetime.date(2026, 10, 1), datetime.date(2026, 10, 2)),
        (datetime.date(2026, 10, 2), datetime.date(2026, 10, 5)),
        (datetime.date(2026, 10, 3), datetime.date(2026, 10, 5)),
        (datetime.date(2026, 10, 4), datetime.date(2026, 10, 5)),
    ],
)
def test_the_next_school_day_is_always_the_next_weekday(today: datetime.date, expected) -> None:
    assert target_date(today, "next_school_day") == expected


@pytest.mark.parametrize(
    ("today", "expected"),
    [
        (datetime.date(2026, 3, 29), datetime.date(2026, 3, 30)),
        (datetime.date(2026, 3, 27), datetime.date(2026, 3, 30)),
        (datetime.date(2026, 10, 24), datetime.date(2026, 10, 26)),
        (datetime.date(2026, 10, 23), datetime.date(2026, 10, 26)),
    ],
)
def test_the_next_weekday_around_the_dst_dates_is_pure_date_arithmetic(
    today: datetime.date, expected: datetime.date
) -> None:
    assert target_date(today, "next_school_day") == expected


@pytest.mark.parametrize(
    ("today", "expected"),
    [
        (datetime.date(2026, 12, 31), datetime.date(2027, 1, 1)),
        (datetime.date(2027, 1, 1), datetime.date(2027, 1, 4)),
    ],
)
def test_the_next_weekday_across_the_year_boundary(
    today: datetime.date, expected: datetime.date
) -> None:
    assert target_date(today, "next_school_day") == expected
