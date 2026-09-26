from __future__ import annotations

import pytest

from custom_components.school_menu.icons import DEFAULT_ICON, dish_icon


@pytest.mark.parametrize(
    ("main", "icon"),
    [
        ("Pasta mit Tomaten Sauce dazu Parmesan", "mdi:pasta"),
        ("Spaghetti Bolognese", "mdi:pasta"),
        ("Gemüselasagne", "mdi:pasta"),
        ("Bandnudeln mit Pesto", "mdi:pasta"),
        ("Lauch-Kartoffel Suppe", "mdi:pot-steam"),
        ("Tomatensuppe", "mdi:pot-steam"),
        ("Linseneintopf", "mdi:pot-steam"),
        ("Chili sin Carne mit Sauer Sahne", "mdi:chili-mild"),
        ("Gemüse-Risotto", "mdi:rice"),
        ("Milchreis mit Zimt", "mdi:rice"),
        ("Fischstäbchen mit Kartoffelpüree", "mdi:fish"),
        ("Lachs auf Blattspinat", "mdi:fish"),
        ("Hähnchenschenkel", "mdi:food-drumstick"),
        ("Pizza Margherita", "mdi:pizza"),
        ("Gemüseburger", "mdi:hamburger"),
        ("Pilzpfanne", "mdi:mushroom"),
        ("Champignon-Rahm", "mdi:mushroom"),
        ("Rührei mit Schnittlauch", "mdi:egg-fried"),
        ("Blumenkohl-Brokkoli-Möhre mit Käse überbacken", "mdi:carrot"),
        ("Gemüsepfanne", "mdi:carrot"),
        ("Blattsalat mit gerösteten Kernen", "mdi:leaf"),
        ("Käsespätzle", "mdi:cheese"),
        ("Brot", "mdi:bread-slice"),
        ("Bananen Kuchen", "mdi:cupcake"),
        ("Obst", "mdi:food-apple"),
        ("Apfelstrudel", "mdi:food-apple"),
    ],
)
def test_a_dish_gets_the_icon_of_its_first_matching_keyword(main: str, icon: str) -> None:
    assert dish_icon(main) == icon


@pytest.mark.parametrize(
    "main",
    ["Kartoffel Gratin", "Erdbeere Joghurt", "Grießbrei mit Preiselbeeren", "", None],
)
def test_an_unknown_or_missing_dish_keeps_the_neutral_icon(main: str | None) -> None:
    assert dish_icon(main) == DEFAULT_ICON == "mdi:food"


@pytest.mark.parametrize("main", ["Reis mit Gemüse", "Kartoffelbrei", "Weißkohl"])
def test_short_ambiguous_keywords_do_not_misfire(main: str) -> None:
    assert dish_icon(main) != "mdi:egg-fried"


def test_matching_ignores_case() -> None:
    assert dish_icon("PASTA") == dish_icon("pasta") == "mdi:pasta"
