from __future__ import annotations

import pytest

from custom_components.school_menu.cleaning import clean_line, strip_allergen_codes


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("Pasta mit Käsesauce / Frische Kräuter (1a, 3)", "Pasta mit Käsesauce / Frische Kräuter"),
        ("Blattsalat mit gerösteten Kernen (4)", "Blattsalat mit gerösteten Kernen"),
        ("Soja geschnetzeltes (3, 7)", "Soja geschnetzeltes"),
        ("Brot (1a)", "Brot"),
        ("Obst", "Obst"),
    ],
)
def test_allergen_groups_are_stripped(raw: str, expected: str) -> None:
    assert strip_allergen_codes(raw) == expected


@pytest.mark.parametrize("raw", ["Suppe (vegan)", "Curry (scharf)", "Saft (Bio)"])
def test_non_allergen_parentheses_survive(raw: str) -> None:
    assert strip_allergen_codes(raw) == raw


def test_slash_spacing_is_normalised() -> None:
    assert clean_line("Soja geschnetzeltes /Frische Kräuter (3, 7)") == (
        "Soja geschnetzeltes / Frische Kräuter"
    )


def test_whitespace_is_collapsed_and_umlauts_survive() -> None:
    assert clean_line("  Kartoffel   Ecken mit Kräuter Quark (3)  ") == (
        "Kartoffel Ecken mit Kräuter Quark"
    )


def test_a_line_that_is_only_an_allergen_group_cleans_to_empty() -> None:
    assert clean_line("(1a, 3)") == ""
