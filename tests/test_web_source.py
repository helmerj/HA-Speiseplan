from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock

import pytest
from homeassistant.components import persistent_notification
from homeassistant.core import HomeAssistant
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import MockConfigEntry, async_fire_time_changed

from custom_components.school_menu.const import (
    DEFAULT_WEB_URL,
    DOMAIN,
    NOTIFICATION_ERROR_ID,
    SINGLE_ENTRY_UNIQUE_ID,
    SOURCE_MANUAL,
)
from custom_components.school_menu.parser import extract_lines, parse_lines
from custom_components.school_menu.web_client import Validators, WebFetchError, WebFetchResult
from tests.fake_imap import pdf
from tests.pdf_fixtures import WEEK_39, WEEK_40, build_pdf, menu_lines

pytestmark = pytest.mark.m7

LAST_IMPORT = "sensor.school_menu_last_import"
TODAY = "sensor.school_menu_today"
NONE = Validators(etag=None, last_modified=None)


def _served(payload: bytes | None, validators: Validators = NONE) -> WebFetchResult:
    return WebFetchResult(payload=payload, validators=validators)


def _notifications(hass: HomeAssistant) -> dict:
    return persistent_notification._async_get_or_create_notifications(hass)


def _monday_only_week_40() -> bytes:
    lines = menu_lines(WEEK_40)
    return build_pdf(lines[: lines.index("DIENSTAG")])


async def _setup(hass: HomeAssistant, entry: MockConfigEntry):
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done(wait_background_tasks=True)
    return hass.data[DOMAIN][entry.entry_id]


async def _tick(hass: HomeAssistant, freezer, stamp: str) -> None:
    freezer.move_to(stamp)
    async_fire_time_changed(hass, dt_util.utcnow())
    await hass.async_block_till_done(wait_background_tasks=True)


async def test_sunday_evening_fetches_and_stores_the_coming_week(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer
) -> None:
    freezer.move_to("2026-09-27 20:00:00+02:00")
    web_fetch.return_value = _served(pdf(WEEK_40))

    coordinator = await _setup(hass, config_entry)

    assert web_fetch.await_count == 1
    assert web_fetch.await_args.args[1] == DEFAULT_WEB_URL
    assert coordinator.store.has_week("2026-W40")
    record = coordinator.store.weeks["2026-W40"]
    assert record["source"] == "web"
    assert record["source_file"] == "AHS-Speiseplan.pdf"
    assert hass.states.get(LAST_IMPORT).attributes["source"] == "web"
    assert _notifications(hass) == {}


async def test_a_stored_week_stops_the_checks(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer
) -> None:
    freezer.move_to("2026-09-28 09:00:00+02:00")
    web_fetch.return_value = _served(pdf(WEEK_40))
    coordinator = await _setup(hass, config_entry)

    await coordinator.async_check_website()

    assert web_fetch.await_count == 1
    assert hass.states.get(TODAY).state != "none"


async def test_a_week_stored_by_hand_means_no_request(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer
) -> None:
    freezer.move_to("2026-09-26 12:00:00+02:00")
    coordinator = await _setup(hass, config_entry)
    payload = pdf(WEEK_40)
    week = parse_lines(extract_lines(payload), source_file="plan.pdf", content_hash="h40")
    await coordinator.async_import_week(week, source=SOURCE_MANUAL)
    freezer.move_to("2026-09-28 09:00:00+02:00")

    await coordinator.async_check_website()

    web_fetch.assert_not_awaited()


@pytest.mark.parametrize("stamp", ["2026-09-26 12:00:00+02:00", "2026-09-27 17:59:00+02:00"])
async def test_outside_the_window_nothing_is_fetched(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer, stamp: str
) -> None:
    freezer.move_to(stamp)
    coordinator = await _setup(hass, config_entry)

    await coordinator.async_check_website()

    web_fetch.assert_not_awaited()


async def test_a_stale_file_keeps_the_checks_going(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer
) -> None:
    freezer.move_to("2026-09-28 09:00:00+02:00")
    web_fetch.return_value = _served(pdf(WEEK_39), Validators(etag='"39"', last_modified=None))
    coordinator = await _setup(hass, config_entry)

    assert coordinator.store.has_week("2026-W39")
    assert not coordinator.store.has_week("2026-W40")

    web_fetch.return_value = _served(None, Validators(etag='"39"', last_modified=None))
    await coordinator.async_check_website()

    assert web_fetch.await_count == 2
    assert web_fetch.await_args.args[2] == Validators(etag='"39"', last_modified=None)
    assert len(coordinator.store.weeks["2026-W39"]["content_hashes"]) == 1


async def test_an_unchanged_file_imports_nothing(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer
) -> None:
    freezer.move_to("2026-09-28 09:00:00+02:00")

    coordinator = await _setup(hass, config_entry)

    assert web_fetch.await_count == 1
    assert coordinator.store.weeks == {}


async def test_a_fetch_failure_only_warns(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer, caplog
) -> None:
    freezer.move_to("2026-09-28 09:00:00+02:00")
    web_fetch.side_effect = WebFetchError("HTTP 404")

    coordinator = await _setup(hass, config_entry)

    assert "Could not fetch the school menu from" in caplog.text
    assert "HTTP 404" in caplog.text
    assert _notifications(hass) == {}
    assert coordinator.store.weeks == {}


async def test_an_unreadable_file_is_reported_once_per_run(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer, caplog
) -> None:
    freezer.move_to("2026-09-28 09:00:00+02:00")
    web_fetch.return_value = _served(b"<html>not a pdf</html>")
    coordinator = await _setup(hass, config_entry)

    await coordinator.async_check_website()

    assert caplog.text.count("Not importing AHS-Speiseplan.pdf") == 1
    assert "AHS-Speiseplan.pdf" in _notifications(hass)[NOTIFICATION_ERROR_ID]["message"]
    assert coordinator.store.weeks == {}


async def test_the_shrink_guard_applies_to_the_website(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer
) -> None:
    freezer.move_to("2026-10-01 12:00:00+02:00")
    coordinator = await _setup(hass, config_entry)
    payload = pdf(WEEK_40)
    week = parse_lines(extract_lines(payload), source_file="plan.pdf", content_hash="h40")
    await coordinator.async_import_week(week, source=SOURCE_MANUAL)
    freezer.move_to("2026-10-05 09:00:00+02:00")
    web_fetch.return_value = _served(_monday_only_week_40())

    await coordinator.async_check_website()

    assert len(coordinator.store.weeks["2026-W40"]["days"]) == 5
    assert "fewer_days" in _notifications(hass)[NOTIFICATION_ERROR_ID]["message"]


async def test_an_empty_url_disables_the_source(
    hass: HomeAssistant, web_fetch: AsyncMock, freezer
) -> None:
    freezer.move_to("2026-09-28 09:00:00+02:00")
    entry = MockConfigEntry(domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data={"web_url": ""})
    coordinator = await _setup(hass, entry)

    await coordinator.async_check_website()
    await _tick(hass, freezer, "2026-09-28 10:00:00+02:00")

    web_fetch.assert_not_awaited()


async def test_a_configured_url_is_used(hass: HomeAssistant, web_fetch: AsyncMock, freezer) -> None:
    freezer.move_to("2026-09-28 09:00:00+02:00")
    url = "https://example.org/files/plan.pdf"
    entry = MockConfigEntry(domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data={"web_url": url})
    web_fetch.return_value = _served(pdf(WEEK_40))

    coordinator = await _setup(hass, entry)

    assert web_fetch.await_args.args[1] == url
    assert coordinator.store.weeks["2026-W40"]["source_file"] == "plan.pdf"


async def test_overlapping_checks_fetch_once(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer
) -> None:
    freezer.move_to("2026-09-26 12:00:00+02:00")
    coordinator = await _setup(hass, config_entry)
    freezer.move_to("2026-09-28 09:00:00+02:00")
    release = asyncio.Event()

    async def _slow(*_args, **_kwargs) -> WebFetchResult:
        await release.wait()
        return _served(None)

    web_fetch.side_effect = _slow
    first = hass.async_create_task(coordinator.async_check_website())
    await asyncio.sleep(0)
    await coordinator.async_check_website()
    release.set()
    await first

    assert web_fetch.await_count == 1


async def test_the_timer_checks_every_two_hours_from_sunday_evening(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer
) -> None:
    freezer.move_to("2026-09-27 15:00:00+02:00")
    await _setup(hass, config_entry)
    assert web_fetch.await_count == 0

    await _tick(hass, freezer, "2026-09-27 16:00:00+02:00")
    assert web_fetch.await_count == 0

    await _tick(hass, freezer, "2026-09-27 18:00:00+02:00")
    assert web_fetch.await_count == 1

    await _tick(hass, freezer, "2026-09-27 19:00:00+02:00")
    assert web_fetch.await_count == 1

    web_fetch.return_value = _served(pdf(WEEK_40))
    await _tick(hass, freezer, "2026-09-27 20:00:00+02:00")
    assert web_fetch.await_count == 2

    await _tick(hass, freezer, "2026-09-27 22:00:00+02:00")
    await _tick(hass, freezer, "2026-09-28 00:00:00+02:00")
    assert web_fetch.await_count == 2


async def test_unloading_stops_the_timer(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer
) -> None:
    freezer.move_to("2026-09-27 15:00:00+02:00")
    await _setup(hass, config_entry)
    assert await hass.config_entries.async_unload(config_entry.entry_id)

    await _tick(hass, freezer, "2026-09-27 18:00:00+02:00")

    web_fetch.assert_not_awaited()


async def test_the_website_check_runs_on_new_year(
    hass: HomeAssistant, config_entry: MockConfigEntry, web_fetch: AsyncMock, freezer
) -> None:
    freezer.move_to("2026-12-27 18:30:00+01:00")

    await _setup(hass, config_entry)

    assert web_fetch.await_count == 1
