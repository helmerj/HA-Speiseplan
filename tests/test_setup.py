from __future__ import annotations

from homeassistant.core import HomeAssistant
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu import async_unload_entry
from custom_components.school_menu.const import DOMAIN


async def test_unload_is_idempotent(hass: HomeAssistant, config_entry: MockConfigEntry) -> None:
    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()
    assert await hass.config_entries.async_unload(config_entry.entry_id)
    await hass.async_block_till_done()

    assert DOMAIN not in hass.data
    assert await async_unload_entry(hass, config_entry)


async def test_removing_the_entry_deletes_its_stored_weeks(
    hass: HomeAssistant, config_entry: MockConfigEntry, hass_storage
) -> None:
    import datetime

    from custom_components.school_menu.models import DayMenu, ParsedWeek

    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()
    week = ParsedWeek(
        week_start=datetime.date(2026, 9, 28),
        days=(DayMenu(date=datetime.date(2026, 9, 28), lines=("Pasta",)),),
        source_file="plan.pdf",
        content_hash="bytes",
    )
    assert await hass.data[DOMAIN][config_entry.entry_id].async_import_week(week, source="manual")
    key = f"school_menu.{config_entry.entry_id}"
    assert key in hass_storage

    assert await hass.config_entries.async_remove(config_entry.entry_id)
    await hass.async_block_till_done()

    assert key not in hass_storage
