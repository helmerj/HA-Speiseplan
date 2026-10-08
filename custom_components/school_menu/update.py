from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from datetime import timedelta
from http import HTTPStatus
from typing import Any

import aiohttp
from homeassistant.components import persistent_notification
from homeassistant.components.update import (
    ATTR_LATEST_VERSION,
    ATTR_VERSION,
    UpdateEntity,
    UpdateEntityFeature,
)
from homeassistant.components.update import DOMAIN as UPDATE_DOMAIN
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import ATTR_ENTITY_ID, STATE_ON
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers import entity_registry as er
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.device_registry import DeviceEntryType, DeviceInfo
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback
from homeassistant.loader import async_get_integration

from .const import (
    DOMAIN,
    GITHUB_HEADERS,
    GITHUB_LATEST_RELEASE_URL,
    GITHUB_REPOSITORY_ID,
    GITHUB_TIMEOUT_SECONDS,
    HACS_DOMAIN,
    NOTIFICATION_UPDATE_ID,
    UPDATE_CHECK_HOURS,
    UPDATE_TITLE,
    UPDATE_VERSION,
)

_LOGGER = logging.getLogger(__name__)

SCAN_INTERVAL = timedelta(hours=UPDATE_CHECK_HOURS)
PARALLEL_UPDATES = 1


@dataclass(frozen=True)
class Release:
    tag: str
    version: str
    url: str | None
    notes: str | None


def parse_release(payload: object) -> Release | None:
    if not isinstance(payload, dict):
        return None
    tag = payload.get("tag_name")
    if not isinstance(tag, str) or not tag.strip():
        return None
    tag = tag.strip()
    url = payload.get("html_url")
    notes = payload.get("body")
    return Release(
        tag=tag,
        version=tag.removeprefix("v"),
        url=url if isinstance(url, str) and url else None,
        notes=notes if isinstance(notes, str) and notes.strip() else None,
    )


async def async_fetch_latest_release(hass: HomeAssistant) -> Release | None:
    session = async_get_clientsession(hass)
    try:
        async with asyncio.timeout(GITHUB_TIMEOUT_SECONDS):
            async with session.get(GITHUB_LATEST_RELEASE_URL, headers=GITHUB_HEADERS) as response:
                if response.status != HTTPStatus.OK:
                    _LOGGER.debug("Release check answered HTTP %s", response.status)
                    return None
                payload = await response.json(content_type=None)
    except (aiohttp.ClientError, TimeoutError, ValueError) as err:
        _LOGGER.debug("Release check failed: %r", err)
        return None
    release = parse_release(payload)
    if release is None:
        _LOGGER.debug("Release check returned no usable tag")
    return release


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddConfigEntryEntitiesCallback
) -> None:
    integration = await async_get_integration(hass, DOMAIN)
    installed = str(integration.version) if integration.version is not None else None
    async_add_entities([SchoolMenuUpdate(entry, installed)])


class SchoolMenuUpdate(UpdateEntity):
    _attr_has_entity_name = True
    _attr_translation_key = UPDATE_VERSION
    _attr_supported_features = UpdateEntityFeature.INSTALL | UpdateEntityFeature.RELEASE_NOTES
    _attr_title = UPDATE_TITLE
    _attr_should_poll = True

    def __init__(self, entry: ConfigEntry, installed_version: str | None) -> None:
        self._attr_unique_id = f"{entry.entry_id}_{UPDATE_VERSION}"
        self.entity_id = f"update.{DOMAIN}_{UPDATE_VERSION}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name=entry.title,
            entry_type=DeviceEntryType.SERVICE,
        )
        self._attr_installed_version = installed_version
        self._release: Release | None = None
        self._announced: str | None = None

    async def async_added_to_hass(self) -> None:
        await super().async_added_to_hass()
        last = await self.async_get_last_state()
        if last is not None and isinstance(last.attributes.get(ATTR_LATEST_VERSION), str):
            self._announced = last.attributes[ATTR_LATEST_VERSION]
        self.async_schedule_update_ha_state(force_refresh=True)

    async def async_update(self) -> None:
        release = await async_fetch_latest_release(self.hass)
        if release is None:
            return
        self._release = release
        self._attr_latest_version = release.version
        self._attr_release_url = release.url
        self._sync_notification()

    def _sync_notification(self) -> None:
        if self.state != STATE_ON:
            persistent_notification.async_dismiss(self.hass, NOTIFICATION_UPDATE_ID)
            return
        if self._announced == self.latest_version:
            return
        self._announced = self.latest_version
        message = (
            f"Version {self.latest_version} ist verfügbar, installiert ist "
            f"{self.installed_version}. Installieren unter Einstellungen → Updates oder über HACS."
        )
        if self.release_url:
            message += f" [Versionshinweise]({self.release_url})"
        persistent_notification.async_create(
            self.hass, message, title=UPDATE_TITLE, notification_id=NOTIFICATION_UPDATE_ID
        )

    async def async_release_notes(self) -> str | None:
        return self._release.notes if self._release is not None else None

    async def async_install(self, version: str | None, backup: bool, **kwargs: Any) -> None:
        if self._release is None:
            raise HomeAssistantError(translation_domain=DOMAIN, translation_key="update_unknown")
        target = er.async_get(self.hass).async_get_entity_id(
            UPDATE_DOMAIN, HACS_DOMAIN, str(GITHUB_REPOSITORY_ID)
        )
        if target is None:
            raise HomeAssistantError(
                translation_domain=DOMAIN, translation_key="install_needs_hacs"
            )
        try:
            await self.hass.services.async_call(
                UPDATE_DOMAIN,
                "install",
                {ATTR_ENTITY_ID: target, ATTR_VERSION: self._release.tag},
                blocking=True,
            )
        except HomeAssistantError as err:
            raise HomeAssistantError(
                translation_domain=DOMAIN,
                translation_key="install_failed",
                translation_placeholders={"version": self._release.version, "error": str(err)},
            ) from err
