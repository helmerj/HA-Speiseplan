from __future__ import annotations

import shutil
from pathlib import Path

import pytest
from homeassistant.config_entries import SOURCE_USER
from homeassistant.core import HomeAssistant

from custom_components.school_menu.const import DOMAIN, SERVICE_IMPORT_PDF
from tests.conftest import FIXTURES


def _stage_week_40(hass: HomeAssistant) -> Path:
    www = Path(hass.config.path("www"))
    www.mkdir(parents=True, exist_ok=True)
    target = www / "AHS Speiseplan 26-40.pdf"
    shutil.copyfile(FIXTURES / "AHS Speiseplan 26-40.pdf", target)
    return target


pytestmark = [pytest.mark.e2e, pytest.mark.m1]

TODAY = "sensor.school_menu_today"


async def test_importing_a_pdf_puts_todays_lunch_on_a_sensor(hass: HomeAssistant, freezer) -> None:
    freezer.move_to("2026-09-30 12:00:00+02:00")

    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {})
    await hass.async_block_till_done()
    entry = hass.config_entries.async_entries(DOMAIN)[0]

    assert hass.states.get(TODAY).state == "none"

    target = _stage_week_40(hass)

    await hass.services.async_call(
        DOMAIN, SERVICE_IMPORT_PDF, {"file_path": str(target)}, blocking=True
    )
    await hass.async_block_till_done()

    state = hass.states.get(TODAY)
    assert state.state == "Chili sin Carne mit Sauer Sahne"
    assert state.attributes["side"] == "Reis"
    assert state.attributes["dessert"] == "Blattsalat mit gerösteten Kernen"
    assert state.attributes["weekday"] == "Mittwoch"

    assert await hass.config_entries.async_reload(entry.entry_id)
    await hass.async_block_till_done()

    assert hass.states.get(TODAY).state == "Chili sin Carne mit Sauer Sahne"
