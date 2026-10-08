from __future__ import annotations

import datetime

from homeassistant.core import HomeAssistant
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import DOMAIN
from custom_components.school_menu.models import DayMenu, ParsedWeek


def _week(content_hash: str, *, main: str = "Pasta") -> ParsedWeek:
    return ParsedWeek(
        week_start=datetime.date(2026, 9, 28),
        days=(DayMenu(date=datetime.date(2026, 9, 28), lines=(main,)),),
        source_file=f"{content_hash}.pdf",
        content_hash=content_hash,
    )


async def _coordinator(hass: HomeAssistant, entry: MockConfigEntry):
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    return hass.data[DOMAIN][entry.entry_id]


async def test_identical_bytes_are_skipped(hass: HomeAssistant, config_entry) -> None:
    coordinator = await _coordinator(hass, config_entry)

    assert await coordinator.async_import_week(_week("a"), source="manual") is True
    assert await coordinator.async_import_week(_week("a"), source="manual") is False


async def test_new_bytes_with_identical_content_record_the_hash_without_fanning_out(
    hass: HomeAssistant, config_entry
) -> None:
    coordinator = await _coordinator(hass, config_entry)
    await coordinator.async_import_week(_week("a"), source="manual")
    updates: list[None] = []
    coordinator.async_add_listener(lambda: updates.append(None))

    imported = await coordinator.async_import_week(_week("b"), source="imap")

    assert imported is False
    assert updates == []
    assert coordinator.store.weeks["2026-W40"]["content_hashes"] == ["a", "b"]


async def test_changed_content_for_a_known_week_overwrites_and_fans_out(
    hass: HomeAssistant, config_entry
) -> None:
    coordinator = await _coordinator(hass, config_entry)
    await coordinator.async_import_week(_week("a"), source="manual")
    updates: list[None] = []
    coordinator.async_add_listener(lambda: updates.append(None))

    imported = await coordinator.async_import_week(_week("c", main="Reis"), source="imap")

    assert imported is True
    assert updates
    assert coordinator.menu_for(datetime.date(2026, 9, 28)).main == "Reis"
    assert coordinator.store.weeks["2026-W40"]["content_hashes"] == ["a", "c"]


async def test_a_manual_reimport_of_known_bytes_replaces_a_changed_parse(
    hass: HomeAssistant, config_entry
) -> None:
    coordinator = await _coordinator(hass, config_entry)
    await coordinator.async_import_week(_week("a", main="Gemüse Pfanne"), source="imap")
    updates: list[None] = []
    coordinator.async_add_listener(lambda: updates.append(None))

    imported = await coordinator.async_import_week(_week("a", main="Milchreis"), source="manual")

    assert imported is True
    assert updates
    assert coordinator.menu_for(datetime.date(2026, 9, 28)).main == "Milchreis"
    assert coordinator.store.weeks["2026-W40"]["content_hashes"] == ["a"]
    assert coordinator.store.weeks["2026-W40"]["source"] == "manual"


async def test_the_mailbox_still_skips_known_bytes_even_if_the_parse_changed(
    hass: HomeAssistant, config_entry
) -> None:
    coordinator = await _coordinator(hass, config_entry)
    await coordinator.async_import_week(_week("a", main="Gemüse Pfanne"), source="manual")

    imported = await coordinator.async_import_week(_week("a", main="Milchreis"), source="imap")

    assert imported is False
    assert coordinator.menu_for(datetime.date(2026, 9, 28)).main == "Gemüse Pfanne"
