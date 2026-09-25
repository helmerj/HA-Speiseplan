from __future__ import annotations

import datetime
from typing import Any

from homeassistant.core import HomeAssistant
from homeassistant.helpers.storage import Store
from homeassistant.util import dt as dt_util

from .const import STORAGE_KEY_PREFIX, STORAGE_MINOR_VERSION, STORAGE_VERSION, WEEKS_RETAINED
from .date_logic import iso_week_key
from .models import DayMenu, ParsedWeek


class MenuStore:
    def __init__(self, hass: HomeAssistant, entry_id: str) -> None:
        self._store: Store[dict[str, Any]] = Store(
            hass,
            STORAGE_VERSION,
            f"{STORAGE_KEY_PREFIX}.{entry_id}",
            minor_version=STORAGE_MINOR_VERSION,
        )
        self.weeks: dict[str, dict[str, Any]] = {}
        self.index: dict[datetime.date, DayMenu] = {}
        self.week_of_day: dict[datetime.date, str] = {}

    async def async_load(self) -> dict[datetime.date, DayMenu]:
        data = await self._store.async_load()
        self.weeks = dict(data.get("weeks", {})) if data else {}
        self._rebuild_index()
        return self.index

    async def async_save_week(self, week: ParsedWeek, *, source: str) -> bool:
        key = iso_week_key(week.week_start)
        existing = self.weeks.get(key, {})
        hashes: list[str] = list(existing.get("content_hashes", []))
        if week.content_hash not in hashes:
            hashes.append(week.content_hash)
        self.weeks[key] = {
            "week_start": week.week_start.isoformat(),
            "source_file": week.source_file,
            "content_hashes": hashes,
            "ingested_at": dt_util.now().isoformat(),
            "source": source,
            "days": {day.date.isoformat(): {"lines": list(day.lines)} for day in week.days},
        }
        self._prune()
        self._rebuild_index()
        await self._store.async_save({"weeks": self.weeks})
        return key in self.weeks

    def knows_hash(self, content_hash: str) -> bool:
        return any(
            content_hash in record.get("content_hashes", []) for record in self.weeks.values()
        )

    def stored_week(self, week: ParsedWeek) -> dict[str, Any] | None:
        return self.weeks.get(iso_week_key(week.week_start))

    @property
    def last_import(self) -> datetime.datetime | None:
        stamps = [
            dt_util.parse_datetime(record["ingested_at"])
            for record in self.weeks.values()
            if record.get("ingested_at")
        ]
        present = [stamp for stamp in stamps if stamp is not None]
        return max(present) if present else None

    @property
    def latest_record(self) -> dict[str, Any] | None:
        newest: dict[str, Any] | None = None
        newest_stamp: datetime.datetime | None = None
        for record in self.weeks.values():
            stamp = dt_util.parse_datetime(record.get("ingested_at", "") or "")
            if stamp is None:
                continue
            if newest_stamp is None or stamp > newest_stamp:
                newest, newest_stamp = record, stamp
        return newest

    def record_for_day(self, day: datetime.date) -> dict[str, Any] | None:
        key = self.week_of_day.get(day)
        return self.weeks.get(key) if key is not None else None

    def _prune(self) -> None:
        if len(self.weeks) <= WEEKS_RETAINED:
            return
        ordered = sorted(self.weeks.items(), key=lambda item: item[1]["week_start"])
        self.weeks = dict(ordered[-WEEKS_RETAINED:])

    def _rebuild_index(self) -> None:
        index: dict[datetime.date, DayMenu] = {}
        week_of_day: dict[datetime.date, str] = {}
        for key, record in self.weeks.items():
            for iso_date, payload in record.get("days", {}).items():
                day = datetime.date.fromisoformat(iso_date)
                index[day] = DayMenu(date=day, lines=tuple(payload.get("lines", [])))
                week_of_day[day] = key
        self.index = index
        self.week_of_day = week_of_day
