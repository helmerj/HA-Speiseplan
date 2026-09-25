from __future__ import annotations

import pytest
from homeassistant.config_entries import SOURCE_USER, ConfigEntryState
from homeassistant.core import HomeAssistant
from homeassistant.data_entry_flow import FlowResultType
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import DEFAULT_NAME, DOMAIN

pytestmark = [pytest.mark.e2e, pytest.mark.m0]


async def _setup_then_unload(hass: HomeAssistant, entry: MockConfigEntry) -> None:
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    assert entry.entry_id in hass.data[DOMAIN]
    assert await hass.config_entries.async_unload(entry.entry_id)
    await hass.async_block_till_done()


def _bus_listeners(hass: HomeAssistant) -> int:
    return sum(hass.bus.async_listeners().values())


async def test_user_flow_creates_entry_and_loads(hass: HomeAssistant) -> None:
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    assert result["type"] is FlowResultType.FORM
    assert result["step_id"] == "user"

    result = await hass.config_entries.flow.async_configure(result["flow_id"], {})
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["title"] == DEFAULT_NAME

    await hass.async_block_till_done()
    entries = hass.config_entries.async_entries(DOMAIN)
    assert len(entries) == 1
    assert entries[0].state is ConfigEntryState.LOADED
    assert entries[0].entry_id in hass.data[DOMAIN]


async def test_second_entry_is_refused(hass: HomeAssistant, config_entry: MockConfigEntry) -> None:
    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()

    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "single_instance_allowed"


async def test_unload_leaves_no_state_or_listeners_behind(
    hass: HomeAssistant, config_entry: MockConfigEntry
) -> None:
    config_entry.add_to_hass(hass)

    await _setup_then_unload(hass, config_entry)
    settled = _bus_listeners(hass)

    await _setup_then_unload(hass, config_entry)

    assert config_entry.state is ConfigEntryState.NOT_LOADED
    assert DOMAIN not in hass.data
    assert config_entry.update_listeners == []
    assert _bus_listeners(hass) == settled
