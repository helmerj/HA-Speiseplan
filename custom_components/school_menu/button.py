from __future__ import annotations

from homeassistant.components.button import ButtonEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceEntryType, DeviceInfo
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from .const import BUTTON_CHECK_MAIL, DOMAIN
from .coordinator import SchoolMenuCoordinator


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddConfigEntryEntitiesCallback
) -> None:
    coordinator: SchoolMenuCoordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities([CheckMailButton(coordinator, entry)])


class CheckMailButton(ButtonEntity):
    _attr_has_entity_name = True
    _attr_translation_key = BUTTON_CHECK_MAIL
    _attr_icon = "mdi:email-sync-outline"

    def __init__(self, coordinator: SchoolMenuCoordinator, entry: ConfigEntry) -> None:
        self._coordinator = coordinator
        self._attr_unique_id = f"{entry.entry_id}_{BUTTON_CHECK_MAIL}"
        self.entity_id = f"button.{DOMAIN}_{BUTTON_CHECK_MAIL}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name=entry.title,
            entry_type=DeviceEntryType.SERVICE,
        )

    @property
    def available(self) -> bool:
        return self._coordinator.mailbox_configured

    async def async_press(self) -> None:
        await self._coordinator.async_check_mail_now()
