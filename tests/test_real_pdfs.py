from __future__ import annotations

from pathlib import Path

import pytest

from custom_components.school_menu.cleaning import strip_allergen_codes
from custom_components.school_menu.parser import FOOTER_SUBSTRINGS, extract_lines, parse_lines
from tests.pdf_fixtures import REAL_FIXTURES

REAL_PDFS = sorted(REAL_FIXTURES.glob("*.pdf"))


@pytest.mark.parametrize("path", REAL_PDFS, ids=lambda path: path.name)
def test_a_real_menu_pdf_parses_to_a_clean_five_day_week(path: Path) -> None:
    week = parse_lines(
        extract_lines(path.read_bytes()), source_file=path.name, content_hash="local"
    )

    assert week.week_start.weekday() == 0
    assert [day.date.weekday() for day in week.days] == [0, 1, 2, 3, 4]
    for day in week.days:
        for line in day.lines:
            assert strip_allergen_codes(line) == line
            assert not line.startswith("„")
            assert not any(substring in line for substring in FOOTER_SUBSTRINGS)
