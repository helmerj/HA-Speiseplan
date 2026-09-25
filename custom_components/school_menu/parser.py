from __future__ import annotations

import datetime
import logging
from io import BytesIO

from .cleaning import clean_line
from .date_logic import monday_of, parse_header_range, week_dates
from .models import DayMenu, MenuParseError, ParsedWeek

_LOGGER = logging.getLogger(__name__)

DAY_ANCHORS = ("MONTAG", "DIENSTAG", "MITTWOCH", "DONNERSTAG", "FREITAG")
FOOTER_PREFIXES = (
    "„",
    "(Änderung Vorbehalten)",
    "Allergene und Zusatzstoffe",
    "Konservierungsstoff",
)
FOOTER_SUBSTRINGS = ("organiced-kitchen",)
MAX_LINES_PER_DAY = 5
TYPICAL_LINES_PER_DAY = 3


def extract_lines(pdf_bytes: bytes) -> list[str]:
    from pypdf import PdfReader
    from pypdf.errors import PdfReadError

    try:
        reader = PdfReader(BytesIO(pdf_bytes))
        text = "\n".join(page.extract_text() or "" for page in reader.pages)
    except (PdfReadError, OSError, ValueError) as err:
        raise MenuParseError("no_text_layer", detail=str(err)) from err
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        raise MenuParseError("no_text_layer")
    return lines


def _is_footer(line: str) -> bool:
    return any(line.startswith(prefix) for prefix in FOOTER_PREFIXES) or any(
        substring in line for substring in FOOTER_SUBSTRINGS
    )


def _anchor_positions(lines: list[str]) -> list[tuple[int, str]]:
    return [(index, line) for index, line in enumerate(lines) if line in DAY_ANCHORS]


def _resolve_week_start(
    lines: list[str], fallback_week_start: datetime.date | None
) -> datetime.date:
    for line in lines:
        found = parse_header_range(line)
        if found is not None:
            normalised = monday_of(found)
            if normalised != found:
                _LOGGER.info("Header start %s is not a Monday, using %s", found, normalised)
            return normalised
    if fallback_week_start is not None:
        return monday_of(fallback_week_start)
    raise MenuParseError("no_date_range")


def _day_lines(lines: list[str], start: int, end: int) -> list[str]:
    collected: list[str] = []
    for line in lines[start:end]:
        if _is_footer(line):
            break
        cleaned = clean_line(line)
        if cleaned:
            collected.append(cleaned)
        if len(collected) == MAX_LINES_PER_DAY:
            break
    return collected


def parse_lines(
    lines: list[str],
    *,
    source_file: str,
    content_hash: str,
    fallback_week_start: datetime.date | None = None,
) -> ParsedWeek:
    week_start = _resolve_week_start(lines, fallback_week_start)
    anchors = _anchor_positions(lines)
    if not anchors:
        raise MenuParseError("no_day_anchors")

    order = [DAY_ANCHORS.index(name) for _, name in anchors]
    if order != sorted(order):
        raise MenuParseError("day_order")

    dates = week_dates(week_start)
    days: list[DayMenu] = []
    for position, (index, name) in enumerate(anchors):
        end = anchors[position + 1][0] if position + 1 < len(anchors) else len(lines)
        collected = _day_lines(lines, index + 1, end)
        if not collected:
            _LOGGER.warning("%s has no menu lines in %s", name, source_file)
            continue
        if len(collected) > TYPICAL_LINES_PER_DAY:
            _LOGGER.warning(
                "%s has %d lines in %s, expected %d",
                name,
                len(collected),
                source_file,
                TYPICAL_LINES_PER_DAY,
            )
        days.append(DayMenu(date=dates[DAY_ANCHORS.index(name)], lines=tuple(collected)))

    if not days:
        raise MenuParseError("no_days_with_content")

    return ParsedWeek(
        week_start=week_start,
        days=tuple(days),
        source_file=source_file,
        content_hash=content_hash,
    )
