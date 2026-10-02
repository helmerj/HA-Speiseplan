from __future__ import annotations

import asyncio
import datetime
import hashlib
import logging

from homeassistant.components import persistent_notification
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed, HomeAssistantError
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed
from homeassistant.util import dt as dt_util

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
    DEFAULT_FOLDER,
    DEFAULT_PORT,
    DEFAULT_SCAN_INTERVAL_MINUTES,
    DEFAULT_SSL,
    DEFAULT_SUBJECT_FILTER,
    DOMAIN,
    FAILURES_BEFORE_NOTIFYING,
    IMAP_POLL_TIMEOUT_SECONDS,
    MIN_SCAN_INTERVAL_MINUTES,
    NOTIFICATION_ERROR_ID,
    NOTIFICATION_IMAP_ID,
    REASON_FEWER_DAYS,
    SOURCE_IMAP,
)
from .date_logic import iso_week_key
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


def _parse_attachment(attachment: MailAttachment, content_hash: str) -> ParsedWeek:
    return parse_lines(
        extract_lines(attachment.payload),
        source_file=attachment.filename,
        content_hash=content_hash,
        fallback_week_start=attachment.fallback_week_start(),
    )


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
        if self.poll_lock.locked() or (
            last is not None and (now - last).total_seconds() < CHECK_MAIL_COOLDOWN_SECONDS
        ):
            _LOGGER.info("Skipping a forced mail check: one ran or is running just now")
            return
        self._last_forced_check = now
        self.seen_messages.clear()
        self.rejected_hashes.clear()
        await self.async_refresh()
        if not self.last_update_success:
            raise HomeAssistantError(
                translation_domain=DOMAIN,
                translation_key="check_mail_failed",
                translation_placeholders={"reason": str(self.last_exception or "unknown")},
            )

    def _reject(self, filename: str, content_hash: str, reason: str) -> None:
        self.rejected_hashes.add(content_hash)
        _LOGGER.warning("Not importing %s from the mailbox: %s", filename, reason)
        persistent_notification.async_create(
            self.hass,
            f"Konnte {filename} aus der E-Mail nicht übernehmen ({reason}). "
            f"Die gespeicherte Woche bleibt unverändert.",
            title="School menu",
            notification_id=NOTIFICATION_ERROR_ID,
        )

    async def _async_ingest(self, attachment: MailAttachment) -> None:
        content_hash = hashlib.sha256(attachment.payload).hexdigest()
        if self.store.knows_hash(content_hash) or content_hash in self.rejected_hashes:
            _LOGGER.debug("Skipping %s, content hash already seen", attachment.filename)
            return
        try:
            week = await self.hass.async_add_executor_job(
                _parse_attachment, attachment, content_hash
            )
        except MenuParseError as err:
            self._reject(attachment.filename, content_hash, err.reason)
            return
        expected = attachment.week_number
        if expected is not None and week.week_start.isocalendar().week != expected:
            _LOGGER.warning(
                "Subject of %s says KW%s but the PDF header says %s; the header wins",
                attachment.filename,
                expected,
                iso_week_key(week.week_start),
            )
        await self.async_import_week(week, source=SOURCE_IMAP)

    async def async_import_week(self, week: ParsedWeek, *, source: str) -> bool:
        if self.store.knows_hash(week.content_hash):
            _LOGGER.debug("Skipping %s, content hash already stored", week.source_file)
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

        if source == SOURCE_IMAP and existing is not None and not unchanged:
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
            return False

        _LOGGER.info(
            "Imported %s with %d day(s) from %s",
            iso_week_key(week.week_start),
            len(week.days),
            week.source_file,
        )
        self.async_set_updated_data(None)
        return True

    def menu_for(self, day: datetime.date) -> DayMenu | None:
        return self.store.index.get(day)

    def record_for(self, day: datetime.date) -> dict | None:
        return self.store.record_for_day(day)
