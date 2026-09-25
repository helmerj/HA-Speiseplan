from __future__ import annotations

from homeassistant.core import HomeAssistant
from pytest_homeassistant_custom_component.common import MockConfigEntry
from pytest_homeassistant_custom_component.components.diagnostics import (
    get_diagnostics_for_config_entry,
)

from custom_components.school_menu.const import DOMAIN, SINGLE_ENTRY_UNIQUE_ID

SECRET = "hunter2-should-never-appear"


async def test_credentials_are_redacted(hass: HomeAssistant, hass_client) -> None:
    entry = MockConfigEntry(
        domain=DOMAIN,
        unique_id=SINGLE_ENTRY_UNIQUE_ID,
        title="School menu",
        data={"username": "teacher@example.org", "password": SECRET, "host": "imap.example.org"},
    )
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    diagnostics = await get_diagnostics_for_config_entry(hass, hass_client, entry)

    assert SECRET not in str(diagnostics)
    assert diagnostics["data"]["password"] == "**REDACTED**"
    assert diagnostics["data"]["username"] == "**REDACTED**"
    assert diagnostics["data"]["host"] == "imap.example.org"
