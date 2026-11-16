from __future__ import annotations

import asyncio
import datetime
import hashlib
import logging
from dataclasses import dataclass, field

from homeassistant.components import persistent_notification
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed, HomeAssistantError
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed
from homeassistant.util import dt as dt_util
from yarl import URL

from .const import (
    CHECK_MAIL_COOLDOWN_SECONDS,
    CONF_FOLDER,
    CONF_HOST,
    CONF_PASSWORD,
    CONF_PORT,
    CONF_SCAN_INTERVAL_MINUTES,
    CONF_SENDERS,
    CONF_SSL,
    CONF_SUBJECT_FILTER,
    CONF_USERNAME,
    CONF_WEB_URL,
    DEFAULT_FOLDER,
    DEFAULT_PORT,
    DEFAULT_SCAN_INTERVAL_MINUTES,
    DEFAULT_SSL,
    DEFAULT_SUBJECT_FILTER,
    DEFAULT_WEB_URL,
    DOMAIN,
    FAILURES_BEFORE_NOTIFYING,
    IMAP_POLL_TIMEOUT_SECONDS,
    MIN_SCAN_INTERVAL_MINUTES,
    NOTIFICATION_ERROR_ID,
    NOTIFICATION_IMAP_ID,
    NOTIFICATION_OK_ID,
    REASON_FEWER_DAYS,
    SOURCE_IMAP,
    SOURCE_WEB,
    UNATTENDED_SOURCES,
    WEB_WINDOW_START_HOUR,
)
from .date_logic import iso_week_key, web_check_week
from .imap_client import (
    ImapAuthError,
    ImapSettings,
    ImapTransportError,
    MailAttachment,
    async_fetch_candidates,
)
from .models import DayMenu, MenuParseError, ParsedWeek
from .parser import extract_lines, parse_lines
from .store import MenuStore
from .web_client import Validators, WebFetchError, async_fetch_menu_pdf

_LOGGER = logging.getLogger(__name__)


def imap_settings(entry: ConfigEntry) -> ImapSettings | None:
    data = entry.data
    if not data.get(CONF_HOST) or not data.get(CONF_SENDERS):
        return None
    return ImapSettings(
        host=data[CONF_HOST],
        port=data.get(CONF_PORT, DEFAULT_PORT),
        username=data.get(CONF_USERNAME, ""),
        password=data.get(CONF_PASSWORD, ""),
        ssl=data.get(CONF_SSL, DEFAULT_SSL),
        folder=data.get(CONF_FOLDER, DEFAULT_FOLDER),
        senders=tuple(data[CONF_SENDERS]),
        subject_filter=data.get(CONF_SUBJECT_FILTER, DEFAULT_SUBJECT_FILTER),
    )


def _parse_payload(
    payload: bytes,
    filename: str,
    content_hash: str,
    fallback_week_start: datetime.date | None,
) -> ParsedWeek:
    return parse_lines(
        extract_lines(payload),
        source_file=filename,
        content_hash=content_hash,
        fallback_week_start=fallback_week_start,
    )


def web_url(entry: ConfigEntry) -> str:
    return str(entry.data.get(CONF_WEB_URL, DEFAULT_WEB_URL)).strip()


@dataclass(slots=True)
class CheckReport:
    imported: dict[str, int] = field(default_factory=dict)
    already_stored: set[str] = field(default_factory=set)
    refused: int = 0


def _week_label(key: str) -> str:
    return f"KW {int(key.rpartition('W')[2])}"


def check_outcome_message(report: CheckReport) -> str:
    if report.imported:
        weeks = ", ".join(
            f"{_week_label(key)} ({days} Tage)" for key, days in sorted(report.imported.items())
        )
        message = f"Neuer Speiseplan importiert: {weeks}."
    elif report.already_stored:
        weeks = ", ".join(_week_label(key) for key in sorted(report.already_stored))
        message = f"Kein neuer Speiseplan. Bereits importiert: {weeks}."
    else:
        message = "Keine Speiseplan-Mail in den letzten 14 Tagen gefunden."
    if report.refused:
        message += f" {report.refused} Anhang/Anhänge nicht übernommen, siehe separate Meldung."
    return message


class SchoolMenuCoordinator(DataUpdateCoordinator[None]):
    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        settings = imap_settings(entry)
        interval = None
        if settings is not None:
            minutes = entry.data.get(CONF_SCAN_INTERVAL_MINUTES, DEFAULT_SCAN_INTERVAL_MINUTES)
            interval = datetime.timedelta(minutes=max(minutes, MIN_SCAN_INTERVAL_MINUTES))
        super().__init__(
            hass,
            _LOGGER,
            config_entry=entry,
            name=DOMAIN,
            update_interval=interval,
            always_update=False,
        )
        self.store = MenuStore(hass, entry.entry_id)
        self.client_factory = None
        self.consecutive_failures = 0
        self.rejected_hashes: set[str] = set()
        self.seen_messages: set[str] = set()
        self.poll_lock = asyncio.Lock()
        self._last_forced_check: datetime.datetime | None = None
        self._check_running = False
        self._report: CheckReport | None = None
        self.web_validators = Validators(etag=None, last_modified=None)
        self._web_lock = asyncio.Lock()

    async def async_initialise(self) -> None:
        await self.store.async_load()

    async def _async_update_data(self) -> None:
        settings = imap_settings(self.config_entry)
        if settings is None or self.client_factory is None:
            return
        try:
            async with self.poll_lock:
                client = self.client_factory(settings)
                async with asyncio.timeout(IMAP_POLL_TIMEOUT_SECONDS):
                    attachments = await async_fetch_candidates(
                        client, settings, dt_util.now().date(), self.seen_messages
                    )
        except ImapAuthError as err:
            raise ConfigEntryAuthFailed(str(err)) from err
        except (ImapTransportError, OSError, TimeoutError) as err:
            reason = str(err) or type(err).__name__
            self.consecutive_failures += 1
            if self.consecutive_failures >= FAILURES_BEFORE_NOTIFYING:
                persistent_notification.async_create(
                    self.hass,
                    f"Der Speiseplan-Abruf schlaegt seit {self.consecutive_failures} Versuchen "
                    f"fehl: {reason}",
                    title="School menu",
                    notification_id=NOTIFICATION_IMAP_ID,
                )
            raise UpdateFailed(reason) from err

        self.consecutive_failures = 0
        persistent_notification.async_dismiss(self.hass, NOTIFICATION_IMAP_ID)
        for attachment in attachments:
            await self._async_ingest(attachment)
        self.seen_messages.update(
            attachment.message_key for attachment in attachments if attachment.message_key
        )

    @property
    def mailbox_configured(self) -> bool:
        return imap_settings(self.config_entry) is not None

    async def async_check_mail_now(self) -> None:
        now = dt_util.utcnow()
        last = self._last_forced_check
        if (
            self._check_running
            or self.poll_lock.locked()
            or (last is not None and (now - last).total_seconds() < CHECK_MAIL_COOLDOWN_SECONDS)
        ):
            raise HomeAssistantError(
                translation_domain=DOMAIN, translation_key="check_mail_skipped"
            )
        self._check_running = True
        report = self._report = CheckReport()
        try:
            self.seen_messages.clear()
            self.rejected_hashes.clear()
            await self.async_refresh()
        finally:
            self._check_running = False
            self._report = None
        if not self.last_update_success:
            raise HomeAssistantError(
                translation_domain=DOMAIN,
                translation_key="check_mail_failed",
                translation_placeholders={"reason": str(self.last_exception or "unknown")},
            )
        self._last_forced_check = now
        persistent_notification.async_create(
            self.hass,
            check_outcome_message(report),
            title="School menu",
            notification_id=NOTIFICATION_OK_ID,
        )

    async def async_check_website(self) -> None:
        url = web_url(self.config_entry)
        if not url or self._web_lock.locked():
            return
        monday = web_check_week(dt_util.now(), WEB_WINDOW_START_HOUR)
        if monday is None or self.store.has_week(iso_week_key(monday)):
            return
        async with self._web_lock:
            try:
                result = await async_fetch_menu_pdf(
                    async_get_clientsession(self.hass), url, self.web_validators
                )
            except WebFetchError as err:
                _LOGGER.warning("Could not fetch the school menu from %s: %s", url, err)
                return
            self.web_validators = result.validators
            if result.payload is None:
                _LOGGER.debug("School menu at %s is unchanged", url)
                return
            await self._async_ingest_payload(
                result.payload, URL(url).name or "website.pdf", source=SOURCE_WEB
            )

    def _reject(self, filename: str, content_hash: str, reason: str) -> None:
        self.rejected_hashes.add(content_hash)
        if self._report is not None:
            self._report.refused += 1
        _LOGGER.warning("Not importing %s: %s", filename, reason)
        persistent_notification.async_create(
            self.hass,
            f"Konnte {filename} nicht übernehmen ({reason}). "
            f"Die gespeicherte Woche bleibt unverändert.",
            title="School menu",
            notification_id=NOTIFICATION_ERROR_ID,
        )

    async def _async_ingest(self, attachment: MailAttachment) -> None:
        await self._async_ingest_payload(
            attachment.payload,
            attachment.filename,
            source=SOURCE_IMAP,
            fallback_week_start=attachment.fallback_week_start(),
            expected_week=attachment.week_number,
        )

    async def _async_ingest_payload(
        self,
        payload: bytes,
        filename: str,
        *,
        source: str,
        fallback_week_start: datetime.date | None = None,
        expected_week: int | None = None,
    ) -> None:
        content_hash = hashlib.sha256(payload).hexdigest()
        if self.store.knows_hash(content_hash) or content_hash in self.rejected_hashes:
            _LOGGER.debug("Skipping %s, content hash already seen", filename)
            self._record_stored(self.store.week_key_for_hash(content_hash))
            return
        try:
            week = await self.hass.async_add_executor_job(
                _parse_payload, payload, filename, content_hash, fallback_week_start
            )
        except MenuParseError as err:
            self._reject(filename, content_hash, err.reason)
            return
        if expected_week is not None and week.week_start.isocalendar().week != expected_week:
            _LOGGER.warning(
                "Subject of %s says KW%s but the PDF header says %s; the header wins",
                filename,
                expected_week,
                iso_week_key(week.week_start),
            )
        await self.async_import_week(week, source=source)

    async def async_import_week(self, week: ParsedWeek, *, source: str) -> bool:
        if source in UNATTENDED_SOURCES and self.store.knows_hash(week.content_hash):
            _LOGGER.debug("Skipping %s, content hash already stored", week.source_file)
            self._record_stored(iso_week_key(week.week_start))
            return False

        existing = self.store.stored_week(week)
        incoming = {day.date.isoformat(): list(day.lines) for day in week.days}
        unchanged = (
            existing is not None
            and {
                iso: list(payload.get("lines", []))
                for iso, payload in existing.get("days", {}).items()
            }
            == incoming
        )

        if source in UNATTENDED_SOURCES and existing is not None and not unchanged:
            stored_days = set(existing.get("days", {}))
            if stored_days and set(incoming) < stored_days:
                self._reject(week.source_file, week.content_hash, REASON_FEWER_DAYS)
                return False

        stored = await self.store.async_save_week(week, source=source, keep_provenance=unchanged)
        if not stored:
            _LOGGER.warning(
                "Week %s was dropped by retention and is not stored",
                iso_week_key(week.week_start),
            )
            return False
        if unchanged:
            _LOGGER.debug("Week %s unchanged, recording hash only", iso_week_key(week.week_start))
            self._record_stored(iso_week_key(week.week_start))
            return False

        _LOGGER.info(
            "Imported %s with %d day(s) from %s",
            iso_week_key(week.week_start),
            len(week.days),
            week.source_file,
        )
        if self._report is not None:
            self._report.imported[iso_week_key(week.week_start)] = len(week.days)
        self.async_set_updated_data(None)
        return True

    def _record_stored(self, key: str | None) -> None:
        if self._report is not None and key is not None:
            self._report.already_stored.add(key)

    def menu_for(self, day: datetime.date) -> DayMenu | None:
        return self.store.index.get(day)

    def record_for(self, day: datetime.date) -> dict | None:
        return self.store.record_for_day(day)
