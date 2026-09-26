from __future__ import annotations

import re
import shutil
from pathlib import Path

import pytest
from homeassistant.core import HomeAssistant
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import MockConfigEntry, async_fire_time_changed

from custom_components.school_menu.const import DOMAIN, SERVICE_IMPORT_PDF
from tests.card_render import card_text, render_card
from tests.conftest import FIXTURES

pytestmark = [pytest.mark.e2e, pytest.mark.m4]

TODAY = "sensor.school_menu_today"
TOMORROW = "sensor.school_menu_tomorrow"


def _stage(hass: HomeAssistant) -> Path:
    www = Path(hass.config.path("www"))
    www.mkdir(parents=True, exist_ok=True)
    target = www / "AHS Speiseplan 26-40.pdf"
    shutil.copyfile(FIXTURES / target.name, target)
    return target


async def _import_week_40(hass: HomeAssistant, entry: MockConfigEntry) -> None:
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    target = _stage(hass)
    await hass.services.async_call(
        DOMAIN, SERVICE_IMPORT_PDF, {"file_path": str(target)}, blocking=True
    )
    await hass.async_block_till_done()


async def test_the_documented_card_follows_the_week_from_sunday_to_wednesday(
    hass: HomeAssistant, config_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-27 18:00:00+02:00")
    await _import_week_40(hass, config_entry)

    sunday = render_card(hass)
    assert sunday[TODAY] == {"primary": "Heute · Sonntag, 27.09.", "secondary": "Kein Mittagessen"}
    assert sunday[TOMORROW] == {
        "primary": "Morgen · Montag, 28.09.",
        "secondary": "Pasta mit Tomaten Sauce dazu Parmesan\nStand: 27.09.",
    }

    freezer.move_to("2026-09-30 00:00:00+02:00")
    async_fire_time_changed(hass, dt_util.utcnow())
    await hass.async_block_till_done()

    wednesday = render_card(hass)
    assert wednesday[TODAY] == {
        "primary": "Heute · Mittwoch, 30.09.",
        "secondary": "Chili sin Carne mit Sauer Sahne\nReis · Blattsalat mit gerösteten Kernen",
    }
    assert wednesday[TOMORROW] == {
        "primary": "Morgen · Donnerstag, 01.10.",
        "secondary": "Blumenkohl-Brokkoli-Möhre mit Käse überbacken\nStand: 27.09.",
    }
    for text in (card_text(hass), str(sunday)):
        assert not re.search(r"(?<![\w-])none(?![\w-])", text, re.IGNORECASE)
