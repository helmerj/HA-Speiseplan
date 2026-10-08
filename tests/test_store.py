from __future__ import annotations

import datetime

from homeassistant.core import HomeAssistant

from custom_components.school_menu.models import DayMenu, ParsedWeek
from custom_components.school_menu.store import MenuStore

WEEK_40 = ParsedWeek(
    week_start=datetime.date(2026, 9, 28),
    days=(
        DayMenu(date=datetime.date(2026, 9, 28), lines=("Pasta", "Salat", "Obst")),
        DayMenu(date=datetime.date(2026, 9, 30), lines=("Chili", "Reis")),
    ),
    source_file="Testplan 26-40.pdf",
    content_hash="hash-40",
)


def _week(start: datetime.date, *, content_hash: str, main: str = "Pasta") -> ParsedWeek:
    return ParsedWeek(
        week_start=start,
        days=(DayMenu(date=start, lines=(main,)),),
        source_file=f"{start}.pdf",
        content_hash=content_hash,
    )


async def test_a_week_round_trips_through_storage(hass: HomeAssistant) -> None:
    store = MenuStore(hass, "entry-1")
    await store.async_load()
    await store.async_save_week(WEEK_40, source="manual")

    reloaded = MenuStore(hass, "entry-1")
    index = await reloaded.async_load()

    assert index[datetime.date(2026, 9, 28)].lines == ("Pasta", "Salat", "Obst")
    assert index[datetime.date(2026, 9, 30)].lines == ("Chili", "Reis")
    assert datetime.date(2026, 9, 29) not in index


async def test_reimporting_a_week_overwrites_it(hass: HomeAssistant) -> None:
    store = MenuStore(hass, "entry-1")
    await store.async_load()
    await store.async_save_week(
        _week(datetime.date(2026, 9, 28), content_hash="a"), source="manual"
    )
    await store.async_save_week(
        _week(datetime.date(2026, 9, 28), content_hash="b", main="Reis"), source="manual"
    )

    assert len(store.weeks) == 1
    assert store.index[datetime.date(2026, 9, 28)].lines == ("Reis",)


async def test_content_hashes_accumulate_rather_than_replace(hass: HomeAssistant) -> None:
    store = MenuStore(hass, "entry-1")
    await store.async_load()
    await store.async_save_week(
        _week(datetime.date(2026, 9, 28), content_hash="a"), source="manual"
    )
    await store.async_save_week(_week(datetime.date(2026, 9, 28), content_hash="b"), source="imap")

    assert store.weeks["2026-W40"]["content_hashes"] == ["a", "b"]
    assert store.knows_hash("a")
    assert store.knows_hash("b")
    assert not store.knows_hash("c")


async def test_only_the_newest_four_weeks_are_kept(hass: HomeAssistant) -> None:
    store = MenuStore(hass, "entry-1")
    await store.async_load()
    for offset in range(6):
        start = datetime.date(2026, 9, 28) + datetime.timedelta(weeks=offset)
        await store.async_save_week(_week(start, content_hash=f"h{offset}"), source="manual")

    assert len(store.weeks) == 4
    assert sorted(store.weeks) == ["2026-W42", "2026-W43", "2026-W44", "2026-W45"]
    assert not store.knows_hash("h0")


async def test_provenance_is_recorded(hass: HomeAssistant) -> None:
    store = MenuStore(hass, "entry-1")
    await store.async_load()
    await store.async_save_week(WEEK_40, source="manual")

    record = store.weeks["2026-W40"]
    assert record["source_file"] == "Testplan 26-40.pdf"
    assert record["source"] == "manual"
    assert record["ingested_at"]
    assert store.last_import is not None


async def test_each_day_resolves_to_its_own_weeks_record(hass: HomeAssistant) -> None:
    store = MenuStore(hass, "entry-1")
    await store.async_load()
    week_39 = ParsedWeek(
        week_start=datetime.date(2026, 9, 21),
        days=(DayMenu(date=datetime.date(2026, 9, 25), lines=("Bohnen Eintopf",)),),
        source_file="Testplan 26-39.pdf",
        content_hash="hash-39",
    )
    await store.async_save_week(week_39, source="manual")
    await store.async_save_week(WEEK_40, source="manual")

    friday_39 = store.record_for_day(datetime.date(2026, 9, 25))
    monday_40 = store.record_for_day(datetime.date(2026, 9, 28))

    assert friday_39["source_file"] == "Testplan 26-39.pdf"
    assert monday_40["source_file"] == "Testplan 26-40.pdf"
    assert store.record_for_day(datetime.date(2026, 9, 24)) is None


async def test_saving_a_week_outside_retention_reports_that_it_was_dropped(
    hass: HomeAssistant,
) -> None:
    store = MenuStore(hass, "entry-1")
    await store.async_load()
    for offset in range(4):
        start = datetime.date(2026, 9, 28) + datetime.timedelta(weeks=offset)
        assert await store.async_save_week(_week(start, content_hash=f"h{offset}"), source="manual")

    stored = await store.async_save_week(
        _week(datetime.date(2026, 6, 1), content_hash="ancient"), source="manual"
    )

    assert stored is False
    assert not store.knows_hash("ancient")


async def test_a_repeated_hash_is_recorded_only_once(hass: HomeAssistant) -> None:
    store = MenuStore(hass, "entry-1")
    await store.async_load()
    await store.async_save_week(
        _week(datetime.date(2026, 9, 28), content_hash="a"), source="manual"
    )
    await store.async_save_week(_week(datetime.date(2026, 9, 28), content_hash="a"), source="imap")

    assert store.weeks["2026-W40"]["content_hashes"] == ["a"]


async def test_a_record_with_an_unparseable_timestamp_is_ignored(hass: HomeAssistant) -> None:
    store = MenuStore(hass, "entry-1")
    await store.async_load()
    await store.async_save_week(WEEK_40, source="manual")
    store.weeks["2026-W41"] = {
        "week_start": "2026-10-05",
        "source_file": "corrupt.pdf",
        "content_hashes": ["x"],
        "ingested_at": "not a timestamp",
        "source": "manual",
        "days": {},
    }

    assert store.latest_week_key == "2026-W40"
    assert store.latest_record["source_file"] == "Testplan 26-40.pdf"
    assert store.last_import is not None
