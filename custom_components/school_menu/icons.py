from __future__ import annotations

import re

DEFAULT_ICON = "mdi:food"

DISH_ICONS: tuple[tuple[str, str], ...] = (
    (r"pizza", "mdi:pizza"),
    (r"burger", "mdi:hamburger"),
    (r"pasta|nudel|spaghetti|lasagne|penne|tortellini|ravioli", "mdi:pasta"),
    (r"suppe|eintopf", "mdi:pot-steam"),
    (r"chili", "mdi:chili-mild"),
    (r"(?<![a-zäöüß])reis|milchreis|risotto", "mdi:rice"),
    (r"fisch|lachs", "mdi:fish"),
    (r"hähnchen|huhn|geflügel", "mdi:food-drumstick"),
    (r"pilz|champignon", "mdi:mushroom"),
    (r"rührei|spiegelei|omelett", "mdi:egg-fried"),
    (r"gemüse|möhre|karotte|blumenkohl|brokkoli|zucchini|kohlrabi", "mdi:carrot"),
    (r"salat", "mdi:leaf"),
    (r"käse", "mdi:cheese"),
    (r"brot|brötchen", "mdi:bread-slice"),
    (r"kuchen|muffin|waffel", "mdi:cupcake"),
    (r"obst|apfel|banane|birne", "mdi:food-apple"),
)

_COMPILED = tuple((re.compile(pattern, re.IGNORECASE), icon) for pattern, icon in DISH_ICONS)


def dish_icon(main: str | None) -> str:
    if not main:
        return DEFAULT_ICON
    for pattern, icon in _COMPILED:
        if pattern.search(main):
            return icon
    return DEFAULT_ICON
