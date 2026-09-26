from __future__ import annotations

import datetime
from dataclasses import dataclass


class MenuParseError(Exception):
    def __init__(self, reason: str, *, detail: str | None = None) -> None:
        super().__init__(reason if detail is None else f"{reason}: {detail}")
        self.reason = reason
        self.detail = detail


@dataclass(frozen=True, slots=True)
class DayMenu:
    date: datetime.date
    lines: tuple[str, ...]

    @property
    def main(self) -> str | None:
        return self.lines[0] if len(self.lines) > 0 else None

    @property
    def side(self) -> str | None:
        return self.lines[1] if len(self.lines) > 1 else None

    @property
    def dessert(self) -> str | None:
        return self.lines[2] if len(self.lines) > 2 else None


@dataclass(frozen=True, slots=True)
class ParsedWeek:
    week_start: datetime.date
    days: tuple[DayMenu, ...]
    source_file: str
    content_hash: str
