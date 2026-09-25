from __future__ import annotations

import datetime
import logging

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator

from .const import DOMAIN
from .date_logic import iso_week_key
from .models import DayMenu, ParsedWeek
from .store import MenuStore

_LOGGER = logging.getLogger(__name__)


class SchoolMenuCoordinator(DataUpdateCoordinator[None]):
    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        super().__init__(hass, _LOGGER, name=DOMAIN, update_interval=None)
        self.store = MenuStore(hass, entry.entry_id)

    async def async_initialise(self) -> None:
        await self.store.async_load()

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
