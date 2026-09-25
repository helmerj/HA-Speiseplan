from __future__ import annotations

import datetime
from typing import Any

from homeassistant.components.sensor import SensorDeviceClass, SensorEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceEntryType, DeviceInfo
from homeassistant.helpers.entity import EntityCategory
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity
from homeassistant.util import dt as dt_util

from .const import (
    ATTR_DATE,
    ATTR_DESSERT,
    ATTR_INGESTED_AT,
    ATTR_LINES,
    ATTR_MAIN,
    ATTR_REASON,
    ATTR_SIDE,
    ATTR_SOURCE,
    ATTR_SOURCE_FILE,
    ATTR_WEEK,
    ATTR_WEEKDAY,
    ATTR_WEEKS_STORED,
    DOMAIN,
    GERMAN_WEEKDAYS,
    NO_MENU_STATE,
    REASON_NO_MENU,
    REASON_WEEKEND,
    SENSOR_LAST_IMPORT,
    SENSOR_TODAY,
    SENSOR_TOMORROW,
    STATE_MAX_LENGTH,
)
from .coordinator import SchoolMenuCoordinator
from .date_logic import target_date


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddConfigEntryEntitiesCallback
) -> None:
    coordinator: SchoolMenuCoordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities(
        [
            SchoolMenuSensor(coordinator, entry, SENSOR_TODAY),
            SchoolMenuSensor(coordinator, entry, SENSOR_TOMORROW),
            LastImportSensor(coordinator, entry),
        ]
    )


def _device(entry: ConfigEntry) -> DeviceInfo:
    return DeviceInfo(
        identifiers={(DOMAIN, entry.entry_id)},
        name=entry.title,
        entry_type=DeviceEntryType.SERVICE,
    )


class SchoolMenuSensor(CoordinatorEntity[SchoolMenuCoordinator], SensorEntity):
    _attr_has_entity_name = True
    _attr_icon = "mdi:food"

    def __init__(self, coordinator: SchoolMenuCoordinator, entry: ConfigEntry, which: str) -> None:
        super().__init__(coordinator)
        self._which = which
        self._attr_name = which.capitalize()
        self._attr_unique_id = f"{entry.entry_id}_{which}"
        self._attr_device_info = _device(entry)

    @property
    def _target(self) -> datetime.date | None:
        return target_date(dt_util.now().date(), self._which)

    @property
    def native_value(self) -> str:
        day = self._target
        if day is None:
            return NO_MENU_STATE
        menu = self.coordinator.menu_for(day)
        if menu is None or not menu.lines:
            return NO_MENU_STATE
        if len(menu.main) > STATE_MAX_LENGTH:
            return f"{menu.main[: STATE_MAX_LENGTH - 1]}…"
        return menu.main

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        day = self._target
        if day is None:
            today = dt_util.now().date()
            return {
                ATTR_WEEKDAY: GERMAN_WEEKDAYS[today.weekday()],
                ATTR_DATE: today.isoformat(),
                ATTR_REASON: REASON_WEEKEND,
            }

        attributes: dict[str, Any] = {
            ATTR_WEEKDAY: GERMAN_WEEKDAYS[day.weekday()],
            ATTR_DATE: day.isoformat(),
        }
        menu = self.coordinator.menu_for(day)
        if menu is None or not menu.lines:
            attributes[ATTR_REASON] = REASON_NO_MENU
            return attributes

        attributes[ATTR_MAIN] = menu.main
        attributes[ATTR_SIDE] = menu.side
        attributes[ATTR_DESSERT] = menu.dessert
        attributes[ATTR_LINES] = list(menu.lines)
        record = self.coordinator.record_for(day)
        if record is not None:
            attributes[ATTR_SOURCE_FILE] = record.get("source_file")
            attributes[ATTR_INGESTED_AT] = record.get("ingested_at")
        return attributes


class LastImportSensor(CoordinatorEntity[SchoolMenuCoordinator], SensorEntity):
    _attr_has_entity_name = True
    _attr_icon = "mdi:clock-check-outline"
    _attr_device_class = SensorDeviceClass.TIMESTAMP
    _attr_entity_category = EntityCategory.DIAGNOSTIC

    def __init__(self, coordinator: SchoolMenuCoordinator, entry: ConfigEntry) -> None:
        super().__init__(coordinator)
        self._attr_name = "Last import"
        self._attr_unique_id = f"{entry.entry_id}_{SENSOR_LAST_IMPORT}"
        self._attr_device_info = _device(entry)

    @property
    def native_value(self) -> datetime.datetime | None:
        return self.coordinator.store.last_import

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        attributes: dict[str, Any] = {
            ATTR_WEEKS_STORED: len(self.coordinator.store.weeks),
        }
        record = self.coordinator.store.latest_record
        if record is not None:
            attributes[ATTR_WEEK] = self.coordinator.store.latest_week_key
            attributes[ATTR_SOURCE_FILE] = record.get("source_file")
            attributes[ATTR_SOURCE] = record.get("source")
        return attributes
