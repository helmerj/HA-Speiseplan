from __future__ import annotations

import datetime
import hashlib
import logging
from pathlib import Path

import voluptuous as vol
from homeassistant.components import persistent_notification
from homeassistant.config_entries import ConfigEntry, ConfigEntryState
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant, ServiceCall
from homeassistant.exceptions import HomeAssistantError, ServiceValidationError
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.typing import ConfigType

from .const import (
    CONF_FILE_PATH,
    CONF_WEEK_START,
    DOMAIN,
    NOTIFICATION_ERROR_ID,
    NOTIFICATION_OK_ID,
    SERVICE_IMPORT_PDF,
    SOURCE_MANUAL,
)
from .coordinator import SchoolMenuCoordinator
from .models import MenuParseError, ParsedWeek
from .parser import extract_lines, parse_lines

_LOGGER = logging.getLogger(__name__)

PLATFORMS: list[Platform] = [Platform.SENSOR]

IMPORT_PDF_SCHEMA = vol.Schema(
    {
        vol.Required(CONF_FILE_PATH): cv.string,
        vol.Optional(CONF_WEEK_START): cv.date,
    }
)


def _allowed_roots(hass: HomeAssistant) -> list[Path]:
    roots = [Path(hass.config.path("www"))]
    roots.extend(Path(media) for media in hass.config.media_dirs.values())
    return [root.resolve() for root in roots]


def _resolve_within_allowlist(hass: HomeAssistant, raw_path: str) -> Path:
    candidate = Path(raw_path).resolve()
    for root in _allowed_roots(hass):
        if candidate == root or root in candidate.parents:
            return candidate
    raise ServiceValidationError(
        translation_domain=DOMAIN,
        translation_key="path_not_allowed",
        translation_placeholders={"path": raw_path},
    )


def _resolve_and_parse(
    hass: HomeAssistant, raw_path: str, week_start: datetime.date | None
) -> tuple[Path, ParsedWeek]:
    path = _resolve_within_allowlist(hass, raw_path)
    if not path.is_file():
        raise ServiceValidationError(
            translation_domain=DOMAIN,
            translation_key="file_not_found",
            translation_placeholders={"path": str(path)},
        )
    return path, _read_and_parse(path, week_start)


def _read_and_parse(path: Path, week_start: datetime.date | None) -> ParsedWeek:
    raw = path.read_bytes()
    content_hash = hashlib.sha256(raw).hexdigest()
    return parse_lines(
        extract_lines(raw),
        source_file=path.name,
        content_hash=content_hash,
        fallback_week_start=week_start,
    )


def _single_coordinator(hass: HomeAssistant) -> SchoolMenuCoordinator:
    entries = hass.config_entries.async_entries(DOMAIN)
    loaded = [entry for entry in entries if entry.state is ConfigEntryState.LOADED]
    if not loaded:
        raise ServiceValidationError(translation_domain=DOMAIN, translation_key="entry_not_loaded")
    return hass.data[DOMAIN][loaded[0].entry_id]


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    async def _handle_import_pdf(call: ServiceCall) -> None:
        coordinator = _single_coordinator(hass)
        raw_path = call.data[CONF_FILE_PATH]
        name = Path(raw_path).name

        try:
            path, week = await hass.async_add_executor_job(
                _resolve_and_parse, hass, raw_path, call.data.get(CONF_WEEK_START)
            )
        except MenuParseError as err:
            persistent_notification.async_create(
                hass,
                f"Konnte {name} nicht lesen ({err.reason}). Die zuletzt importierte Woche "
                f"bleibt unverändert.",
                title="School menu",
                notification_id=NOTIFICATION_ERROR_ID,
            )
            raise HomeAssistantError(f"{name}: {err.reason}") from err

        imported = await coordinator.async_import_week(week, source=SOURCE_MANUAL)
        if imported:
            message = f"{path.name} importiert: {len(week.days)} Tag(e) ab {week.week_start}."
        elif coordinator.store.record_for_day(week.week_start) is None:
            message = (
                f"{path.name} nicht gespeichert: die Woche ab {week.week_start} liegt ausserhalb "
                f"der letzten vier Wochen."
            )
        else:
            message = (
                f"{path.name} war unveraendert: die Woche ab {week.week_start} bleibt wie sie war."
            )
        persistent_notification.async_create(
            hass, message, title="School menu", notification_id=NOTIFICATION_OK_ID
        )

    hass.services.async_register(
        DOMAIN, SERVICE_IMPORT_PDF, _handle_import_pdf, schema=IMPORT_PDF_SCHEMA
    )
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    coordinator = SchoolMenuCoordinator(hass, entry)
    await coordinator.async_initialise()
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = coordinator
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    unloaded = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if not unloaded:
        return False
    domain_data = hass.data.get(DOMAIN)
    if domain_data is None:
        return True
    domain_data.pop(entry.entry_id, None)
    if not domain_data:
        hass.data.pop(DOMAIN)
    return True
