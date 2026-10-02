from __future__ import annotations

import datetime
import hashlib
import logging
from pathlib import Path

import voluptuous as vol
from homeassistant.components import persistent_notification
from homeassistant.config_entries import ConfigEntry, ConfigEntryState
from homeassistant.const import EVENT_CORE_CONFIG_UPDATE, Platform
from homeassistant.core import Event, HomeAssistant, ServiceCall, callback
from homeassistant.exceptions import HomeAssistantError, ServiceValidationError
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.event import async_track_time_change
from homeassistant.helpers.typing import ConfigType

from .const import (
    CONF_FILE_ID,
    CONF_FILE_PATH,
    CONF_SENDERS,
    CONF_SUBJECT_FILTER,
    CONF_WEEK_START,
    DEFAULT_SENDERS,
    DEFAULT_SUBJECT_FILTER,
    DOMAIN,
    LEGACY_DEFAULT_SENDERS,
    LEGACY_DEFAULT_SUBJECT_FILTER,
    NOTIFICATION_ERROR_ID,
    NOTIFICATION_OK_ID,
    SERVICE_CHECK_MAIL,
    SERVICE_IMPORT_PDF,
    SOURCE_MANUAL,
)
from .coordinator import SchoolMenuCoordinator
from .imap_client import create_client
from .models import MenuParseError, ParsedWeek
from .parser import extract_lines, parse_lines
from .store import MenuStore

_LOGGER = logging.getLogger(__name__)

PLATFORMS: list[Platform] = [Platform.SENSOR, Platform.BUTTON]

CONFIG_SCHEMA = cv.config_entry_only_config_schema(DOMAIN)

IMPORT_PDF_SCHEMA = vol.Schema(
    {
        vol.Optional(CONF_FILE_PATH): cv.string,
        vol.Optional(CONF_FILE_ID): cv.string,
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


def _parse_upload(
    hass: HomeAssistant, file_id: str, week_start: datetime.date | None, seen_name: list[str]
) -> ParsedWeek:
    from homeassistant.components.file_upload import process_uploaded_file

    try:
        with process_uploaded_file(hass, file_id) as path:
            seen_name.append(path.name)
            return _read_and_parse(path, week_start)
    except (ValueError, KeyError) as err:
        raise ServiceValidationError(
            translation_domain=DOMAIN,
            translation_key="upload_not_found",
            translation_placeholders={"file_id": file_id},
        ) from err


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
        raw_path = call.data.get(CONF_FILE_PATH)
        file_id = call.data.get(CONF_FILE_ID)
        if (raw_path is None) == (file_id is None):
            raise ServiceValidationError(
                translation_domain=DOMAIN, translation_key="exactly_one_source"
            )
        name = Path(raw_path).name if raw_path is not None else file_id
        week_start = call.data.get(CONF_WEEK_START)
        seen_name: list[str] = []

        try:
            if raw_path is not None:
                resolved, week = await hass.async_add_executor_job(
                    _resolve_and_parse, hass, raw_path, week_start
                )
                name = resolved.name
            else:
                week = await hass.async_add_executor_job(
                    _parse_upload, hass, file_id, week_start, seen_name
                )
                name = seen_name[0] if seen_name else file_id
        except MenuParseError as err:
            name = seen_name[0] if seen_name else name
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
            message = f"{name} importiert: {len(week.days)} Tag(e) ab {week.week_start}."
        elif coordinator.store.record_for_day(week.week_start) is None:
            message = (
                f"{name} nicht gespeichert: die Woche ab {week.week_start} liegt ausserhalb "
                f"der letzten vier Wochen."
            )
        else:
            message = f"{name} war unveraendert: die Woche ab {week.week_start} bleibt wie sie war."
        persistent_notification.async_create(
            hass, message, title="School menu", notification_id=NOTIFICATION_OK_ID
        )

    hass.services.async_register(
        DOMAIN, SERVICE_IMPORT_PDF, _handle_import_pdf, schema=IMPORT_PDF_SCHEMA
    )

    async def _handle_check_mail(call: ServiceCall) -> None:
        coordinator = _single_coordinator(hass)
        if not coordinator.mailbox_configured:
            raise ServiceValidationError(translation_domain=DOMAIN, translation_key="no_mailbox")
        await coordinator.async_check_mail_now()

    hass.services.async_register(
        DOMAIN, SERVICE_CHECK_MAIL, _handle_check_mail, schema=vol.Schema({})
    )
    return True


_imap_client_factory = create_client


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    coordinator = SchoolMenuCoordinator(hass, entry)
    coordinator.client_factory = _imap_client_factory
    await coordinator.async_initialise()
    if coordinator.update_interval is not None:
        entry.async_create_background_task(
            hass, coordinator.async_refresh(), f"{DOMAIN}_first_poll"
        )
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = coordinator
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)

    @callback
    def _at_midnight(now: datetime.datetime) -> None:
        coordinator.async_update_listeners()

    @callback
    def _on_core_config(event: Event) -> None:
        coordinator.async_update_listeners()

    entry.async_on_unload(async_track_time_change(hass, _at_midnight, hour=0, minute=0, second=0))
    entry.async_on_unload(hass.bus.async_listen(EVENT_CORE_CONFIG_UPDATE, _on_core_config))
    return True


def _is_legacy_sender_default(senders: object) -> bool:
    if not isinstance(senders, list):
        return False
    normalised = sorted(str(sender).strip().lower() for sender in senders)
    return normalised == sorted(sender.lower() for sender in LEGACY_DEFAULT_SENDERS)


async def async_migrate_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    if entry.minor_version < 2:
        data = dict(entry.data)
        if _is_legacy_sender_default(data.get(CONF_SENDERS)):
            data[CONF_SENDERS] = list(DEFAULT_SENDERS)
        if str(data.get(CONF_SUBJECT_FILTER, "")).strip() == LEGACY_DEFAULT_SUBJECT_FILTER:
            data[CONF_SUBJECT_FILTER] = DEFAULT_SUBJECT_FILTER
        hass.config_entries.async_update_entry(entry, data=data, minor_version=2)
    return True


async def async_remove_entry(hass: HomeAssistant, entry: ConfigEntry) -> None:
    await MenuStore(hass, entry.entry_id).async_remove()


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
