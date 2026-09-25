from __future__ import annotations

from homeassistant.config_entries import SOURCE_USER
from homeassistant.core import HomeAssistant
from homeassistant.data_entry_flow import FlowResultType
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import DEFAULT_NAME, DOMAIN, SINGLE_ENTRY_UNIQUE_ID


async def test_user_flow_shows_form_then_creates_entry(hass: HomeAssistant) -> None:
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    assert result["type"] is FlowResultType.FORM

    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"name": "Schule"})
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["title"] == "Schule"


async def test_user_flow_defaults_the_name(hass: HomeAssistant) -> None:
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {})
    assert result["title"] == DEFAULT_NAME


async def test_matching_unique_id_aborts(hass: HomeAssistant) -> None:
    MockConfigEntry(domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data={}).add_to_hass(hass)

    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})

    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "single_instance_allowed"


async def test_legacy_entry_without_unique_id_still_aborts(hass: HomeAssistant) -> None:
    MockConfigEntry(domain=DOMAIN, unique_id=None, data={}).add_to_hass(hass)

    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})

    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "single_instance_allowed"
    assert len(hass.config_entries.async_entries(DOMAIN)) == 1


async def test_a_concurrent_flow_aborts_with_a_translated_reason(hass: HomeAssistant) -> None:
    first = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    assert first["type"] is FlowResultType.FORM

    second = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})

    assert second["type"] is FlowResultType.ABORT
    assert second["reason"] == "already_in_progress"
