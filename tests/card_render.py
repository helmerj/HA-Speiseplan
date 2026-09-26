from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml
from homeassistant.core import HomeAssistant
from homeassistant.helpers.template import Template

CARD = Path(__file__).parents[1] / "cards" / "mushroom-today-tomorrow.yaml"
TEMPLATED = ("primary", "secondary")


def load_card() -> dict[str, Any]:
    return yaml.safe_load(CARD.read_text())


def template_cards(card: dict[str, Any]) -> list[dict[str, Any]]:
    if card.get("type") == "custom:mushroom-template-card":
        return [card]
    found: list[dict[str, Any]] = []
    for child in card.get("cards", []):
        found.extend(template_cards(child))
    return found


def render(hass: HomeAssistant, source: str, tile: dict[str, Any]) -> str:
    variables = {"entity": tile["entity"], "config": tile, "user": "Parent"}
    info = Template(source, hass).async_render_to_info(variables, strict=True)
    assert info.exception is None, info.exception
    result = info.result()
    return "" if result is None else str(result)


def render_card(hass: HomeAssistant, card: dict[str, Any] | None = None) -> dict[str, dict]:
    rendered: dict[str, dict] = {}
    for tile in template_cards(card or load_card()):
        rendered[tile["entity"]] = {
            key: render(hass, tile[key], tile) for key in TEMPLATED if key in tile
        }
    return rendered


def card_text(hass: HomeAssistant) -> str:
    return "\n".join(value for tile in render_card(hass).values() for value in tile.values())


def render_icons(hass: HomeAssistant, card: dict[str, Any] | None = None) -> dict[str, str]:
    return {
        tile["entity"]: render(hass, tile["icon"], tile)
        for tile in template_cards(card or load_card())
    }
