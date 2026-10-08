from __future__ import annotations

import datetime

import pytest

from custom_components.school_menu.cleaning import clean_line
from custom_components.school_menu.models import MenuParseError
from custom_components.school_menu.parser import extract_lines, parse_lines
from tests.pdf_fixtures import WEEK_40, menu_lines

WEEK_40_LINES = menu_lines(WEEK_40)
THURSDAY = "Süßer DONNERSTAG"


def _parse(lines: list[str], **kwargs):
    return parse_lines(lines, source_file="test.pdf", content_hash="deadbeef", **kwargs)


def test_extract_lines_reads_a_menu_pdf_line_by_line(week_40_pdf: bytes) -> None:
    assert extract_lines(week_40_pdf) == WEEK_40_LINES


def test_extract_lines_rejects_a_pdf_without_a_text_layer() -> None:
    with pytest.raises(MenuParseError) as excinfo:
        extract_lines(b"not a pdf at all")
    assert excinfo.value.reason == "no_text_layer"


def test_a_menu_pdf_parses_to_five_days(week_40_pdf: bytes) -> None:
    week = parse_lines(
        extract_lines(week_40_pdf), source_file="Testplan 26-40.pdf", content_hash="abc"
    )

    assert week.week_start == datetime.date(2026, 9, 28)
    assert len(week.days) == 5
    assert week.days[0].date == datetime.date(2026, 9, 28)
    assert week.days[0].main == "Spaghetti mit Kürbis-Salbei Sauce"
    assert week.days[2].lines == (
        "Ananas-Chili mit Kidneybohnen",
        "Reis",
        "Feldsalat mit Kürbiskernen",
    )
    assert week.days[4].date == datetime.date(2026, 10, 2)


def test_both_menu_pdfs_carry_no_allergen_codes(week_39_pdf: bytes, week_40_pdf: bytes) -> None:
    for raw in (week_39_pdf, week_40_pdf):
        week = parse_lines(extract_lines(raw), source_file="x.pdf", content_hash="h")
        for day in week.days:
            for line in day.lines:
                assert "(" not in line


def test_the_footer_never_leaks_into_friday(week_39_pdf: bytes) -> None:
    week = parse_lines(extract_lines(week_39_pdf), source_file="x.pdf", content_hash="h")

    friday = week.days[4]
    assert friday.lines == ("Bohnen Eintopf", "Brot", "Apfel Crumble")


def test_a_wrapped_quote_is_still_treated_as_footer() -> None:
    lines = [*WEEK_40_LINES[:22], "„Wer mit Freude kocht, braucht kein", "Rezept.“", "Tante Erna"]

    week = _parse(lines)

    assert week.days[4].lines == ("Kürbis-Kokos Suppe", "Dinkelbrot", "Haferkekse")


def test_a_day_with_two_lines_has_no_dessert() -> None:
    lines = [line for line in WEEK_40_LINES if line != "Obst"]

    week = _parse(lines)

    assert week.days[0].lines == ("Spaghetti mit Kürbis-Salbei Sauce", "Gurkensalat mit Dill")
    assert week.days[0].dessert is None


def test_a_day_with_four_lines_keeps_all_of_them(caplog: pytest.LogCaptureFixture) -> None:
    lines = list(WEEK_40_LINES)
    lines.insert(6, "Nachschlag")

    week = _parse(lines)

    assert len(week.days[0].lines) == 4
    assert week.days[0].main == "Spaghetti mit Kürbis-Salbei Sauce"
    assert week.days[0].dessert == "Obst"
    assert "MONTAG" in caplog.text


def test_a_day_anchor_with_no_lines_is_omitted(caplog: pytest.LogCaptureFixture) -> None:
    lines = [
        line
        for line in WEEK_40_LINES
        if line
        not in {"Süßkartoffel Auflauf (3)", "Rotkohl-Birnen Rohkost (4)", "Vanille Joghurt (3)"}
    ]

    week = _parse(lines)

    assert len(week.days) == 4
    assert datetime.date(2026, 9, 29) not in {day.date for day in week.days}
    assert "DIENSTAG" in caplog.text


def test_a_non_monday_start_date_normalises_to_monday() -> None:
    lines = list(WEEK_40_LINES)
    lines[1] = "30.09.26 – 02.10.26"

    week = _parse(lines)

    assert week.week_start == datetime.date(2026, 9, 28)


def test_a_missing_header_falls_back_to_the_supplied_week_start() -> None:
    lines = [line for line in WEEK_40_LINES if line != "28.09.26 – 02.10.26"]

    week = _parse(lines, fallback_week_start=datetime.date(2026, 9, 28))

    assert week.week_start == datetime.date(2026, 9, 28)


def test_a_missing_header_with_no_fallback_is_an_error() -> None:
    lines = [line for line in WEEK_40_LINES if line != "28.09.26 – 02.10.26"]

    with pytest.raises(MenuParseError) as excinfo:
        _parse(lines)
    assert excinfo.value.reason == "no_date_range"


def test_no_day_anchors_is_an_error() -> None:
    with pytest.raises(MenuParseError) as excinfo:
        _parse(["WOCHENPLAN", "28.09.26 – 02.10.26", "Irgendwas"])
    assert excinfo.value.reason == "no_day_anchors"


def test_out_of_order_day_anchors_are_an_error() -> None:
    lines = ["WOCHENPLAN", "28.09.26 – 02.10.26", "DIENSTAG", "Suppe", "MONTAG", "Pasta"]

    with pytest.raises(MenuParseError) as excinfo:
        _parse(lines)
    assert excinfo.value.reason == "day_order"


def test_a_week_whose_every_day_is_empty_is_an_error() -> None:
    lines = ["WOCHENPLAN", "28.09.26 – 02.10.26", "MONTAG", "DIENSTAG", "MITTWOCH"]

    with pytest.raises(MenuParseError) as excinfo:
        _parse(lines)
    assert excinfo.value.reason == "no_days_with_content"


def test_the_parsed_week_records_its_provenance(week_40_pdf: bytes) -> None:
    week = parse_lines(extract_lines(week_40_pdf), source_file="AHS.pdf", content_hash="cafe")

    assert week.source_file == "AHS.pdf"
    assert week.content_hash == "cafe"


def test_a_missing_day_anchor_does_not_shift_later_days_onto_it() -> None:
    lines = [
        line
        for line in WEEK_40_LINES
        if line
        not in {
            "Süß-saurer MITTWOCH",
            "Ananas-Chili mit Kidneybohnen (7)",
            "Reis",
            "Feldsalat mit Kürbiskernen (4)",
        }
    ]

    week = _parse(lines)

    by_date = {day.date: day for day in week.days}
    assert datetime.date(2026, 9, 30) not in by_date
    assert by_date[datetime.date(2026, 10, 1)].main == "Zucchini-Möhren Puffer mit Kräuterquark"
    assert by_date[datetime.date(2026, 10, 2)].main == "Kürbis-Kokos Suppe"


@pytest.mark.parametrize(
    "terminator",
    [
        "(Änderung Vorbehalten)",
        "Allergene und Zusatzstoffe: Gluten (1), Weizen (1a)",
        "Konservierungsstoff: Natriumnitrit(a)",
        "Testküche Bio Catering kantine@organiced-kitchen.example",
    ],
)
def test_each_footer_sentinel_stops_friday(terminator: str) -> None:
    lines = [*WEEK_40_LINES[:22], terminator, "Opa Hubert", "Noch mehr Fliesstext"]

    week = _parse(lines)

    assert week.days[4].lines == ("Kürbis-Kokos Suppe", "Dinkelbrot", "Haferkekse")


def test_a_day_is_capped_at_five_lines() -> None:
    lines = list(WEEK_40_LINES)
    for extra in ("Zusatz eins", "Zusatz zwei", "Zusatz drei", "Zusatz vier", "Zusatz fuenf"):
        lines.insert(6, extra)

    week = _parse(lines)

    assert len(week.days[0].lines) == 5


def test_an_impossible_header_date_is_ignored() -> None:
    lines = list(WEEK_40_LINES)
    lines[1] = "31.02.26 – 02.03.26"

    with pytest.raises(MenuParseError) as excinfo:
        _parse(lines)
    assert excinfo.value.reason == "no_date_range"


def test_prefixed_anchors_in_menu_pdfs_keep_their_own_menus(
    week_39_pdf: bytes, week_40_pdf: bytes
) -> None:
    week_39 = parse_lines(extract_lines(week_39_pdf), source_file="x.pdf", content_hash="a")
    week_40 = parse_lines(extract_lines(week_40_pdf), source_file="y.pdf", content_hash="b")

    by_date = {day.date: day for day in (*week_39.days, *week_40.days)}
    assert len(by_date) == 10
    assert by_date[datetime.date(2026, 9, 24)].main == "Pfannkuchen mit Blaubeeren"
    assert by_date[datetime.date(2026, 9, 23)].lines == (
        "Hirse-Gemüse Pfanne / Frische Kräuter",
        "Couscous",
        "Radieschen Salat",
    )
    assert by_date[datetime.date(2026, 9, 28)].main == "Spaghetti mit Kürbis-Salbei Sauce"
    assert by_date[datetime.date(2026, 9, 30)].main == "Ananas-Chili mit Kidneybohnen"
    assert by_date[datetime.date(2026, 10, 1)].lines == (
        "Zucchini-Möhren Puffer mit Kräuterquark",
        "Kartoffeln",
        "Obst",
    )


@pytest.mark.parametrize(
    "anchor",
    [
        "DONNERSTAG",
        "SÜSSER DONNERSTAG",
        "SÜßER DONNERSTAG",
        "Bunter veganer DONNERSTAG",
        "Süß-saurer DONNERSTAG",
        "Süßer  DONNERSTAG",
    ],
)
def test_a_day_name_with_a_prefix_is_still_an_anchor(anchor: str) -> None:
    lines = [anchor if line == THURSDAY else line for line in WEEK_40_LINES]

    week = _parse(lines)

    by_date = {day.date: day for day in week.days}
    assert len(week.days) == 5
    assert by_date[datetime.date(2026, 9, 30)].lines == (
        "Ananas-Chili mit Kidneybohnen",
        "Reis",
        "Feldsalat mit Kürbiskernen",
    )
    assert by_date[datetime.date(2026, 10, 1)].main == "Zucchini-Möhren Puffer mit Kräuterquark"


@pytest.mark.parametrize(
    "line",
    [
        "Reste vom Donnerstag",
        "DONNERSTAGS",
        "Kuchen (1a) DONNERSTAG",
        "Reste vom Mittwoch und DONNERSTAG",
        "DONNERSTAG Spezial",
    ],
)
def test_a_dish_line_mentioning_a_day_is_not_an_anchor(line: str) -> None:
    lines = [line if entry == THURSDAY else entry for entry in WEEK_40_LINES]

    week = _parse(lines)

    dates = {day.date for day in week.days}
    assert datetime.date(2026, 10, 1) not in dates
    wednesday = next(day for day in week.days if day.date == datetime.date(2026, 9, 30))
    assert clean_line(line) in wednesday.lines


def test_out_of_order_prefixed_anchors_are_an_error() -> None:
    lines = [
        "WOCHENPLAN",
        "28.09.26 – 02.10.26",
        "Süßer DONNERSTAG",
        "Pfannkuchen",
        "MONTAG",
        "Spaghetti",
    ]

    with pytest.raises(MenuParseError) as excinfo:
        _parse(lines)
    assert excinfo.value.reason == "day_order"
