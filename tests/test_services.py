from __future__ import annotations

import datetime
import shutil
from pathlib import Path

import pytest
from homeassistant.components import persistent_notification
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError, ServiceValidationError
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import (
    DOMAIN,
    NOTIFICATION_ERROR_ID,
    NOTIFICATION_OK_ID,
    SERVICE_IMPORT_PDF,
)
from tests.conftest import FIXTURES


@pytest.fixture
async def loaded_entry(hass: HomeAssistant, config_entry: MockConfigEntry) -> MockConfigEntry:
    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()
    return config_entry


def _notifications(hass: HomeAssistant) -> dict:
    return persistent_notification._async_get_or_create_notifications(hass)


def _www(hass: HomeAssistant, name: str, source: str | None = None) -> Path:
    www = Path(hass.config.path("www"))
    www.mkdir(parents=True, exist_ok=True)
    target = www / name
    shutil.copyfile(FIXTURES / (source or name), target)
    return target


def _write_www(hass: HomeAssistant, name: str, payload: bytes) -> Path:
    www = Path(hass.config.path("www"))
    www.mkdir(parents=True, exist_ok=True)
    target = www / name
    target.write_bytes(payload)
    return target


def _write_outside(hass: HomeAssistant, name: str, payload: bytes) -> Path:
    target = Path(hass.config.path(name))
    target.write_bytes(payload)
    return target


def _symlink_out(hass: HomeAssistant, name: str) -> Path:
    outside = _write_outside(hass, "outside-target.pdf", b"secret")
    www = Path(hass.config.path("www"))
    www.mkdir(parents=True, exist_ok=True)
    link = www / name
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(outside)
    return link


def _sibling_of_www(hass: HomeAssistant, name: str) -> Path:
    sibling = Path(hass.config.path("wwwevil"))
    sibling.mkdir(parents=True, exist_ok=True)
    target = sibling / name
    target.write_bytes(b"nope")
    return target


def _www_path(hass: HomeAssistant, name: str) -> Path:
    www = Path(hass.config.path("www"))
    www.mkdir(parents=True, exist_ok=True)
    return www / name


async def _import(hass: HomeAssistant, path: str | Path, **extra) -> None:
    await hass.services.async_call(
        DOMAIN, SERVICE_IMPORT_PDF, {"file_path": str(path), **extra}, blocking=True
    )


async def test_a_pdf_under_www_imports(hass: HomeAssistant, loaded_entry) -> None:
    path = _www(hass, "AHS Speiseplan 26-40.pdf")

    await _import(hass, path)

    coordinator = hass.data[DOMAIN][loaded_entry.entry_id]
    assert coordinator.menu_for(datetime.date(2026, 9, 28)).main == (
        "Pasta mit Tomaten Sauce dazu Parmesan"
    )


async def test_a_traversal_path_is_refused(hass: HomeAssistant, loaded_entry) -> None:
    with pytest.raises(ServiceValidationError) as excinfo:
        await _import(hass, f"{hass.config.path('www')}/../../etc/passwd")
    assert excinfo.value.translation_key == "path_not_allowed"


async def test_traversal_to_a_file_that_exists_is_refused(
    hass: HomeAssistant, loaded_entry
) -> None:
    secret = _write_outside(hass, "secrets.yaml", b"api_key: hunter2")

    with pytest.raises(ServiceValidationError) as excinfo:
        await _import(hass, f"{hass.config.path('www')}/../{secret.name}")
    assert excinfo.value.translation_key == "path_not_allowed"


async def test_a_symlink_out_of_www_is_refused(hass: HomeAssistant, loaded_entry) -> None:
    link = _symlink_out(hass, "escape.pdf")

    with pytest.raises(ServiceValidationError) as excinfo:
        await _import(hass, link)
    assert excinfo.value.translation_key == "path_not_allowed"


async def test_a_sibling_directory_sharing_the_prefix_is_refused(
    hass: HomeAssistant, loaded_entry
) -> None:
    sibling = _sibling_of_www(hass, "x.pdf")

    with pytest.raises(ServiceValidationError) as excinfo:
        await _import(hass, sibling)
    assert excinfo.value.translation_key == "path_not_allowed"


async def test_a_path_outside_the_allowlist_is_refused(hass: HomeAssistant, loaded_entry) -> None:
    with pytest.raises(ServiceValidationError) as excinfo:
        await _import(hass, "/etc/hosts")
    assert excinfo.value.translation_key == "path_not_allowed"


async def test_a_missing_file_is_refused(hass: HomeAssistant, loaded_entry) -> None:
    missing = _www_path(hass, "nope.pdf")

    with pytest.raises(ServiceValidationError):
        await _import(hass, missing)


async def test_the_service_refuses_when_no_entry_is_loaded(hass: HomeAssistant) -> None:
    from homeassistant.setup import async_setup_component

    assert await async_setup_component(hass, DOMAIN, {})

    with pytest.raises(ServiceValidationError):
        await _import(hass, "/config/www/whatever.pdf")


async def test_a_corrupt_pdf_keeps_previous_data_and_raises(
    hass: HomeAssistant, loaded_entry
) -> None:
    good = _www(hass, "AHS Speiseplan 26-40.pdf")
    await _import(hass, good)
    coordinator = hass.data[DOMAIN][loaded_entry.entry_id]
    before = dict(coordinator.store.weeks)

    bad = _write_www(hass, "broken.pdf", b"this is not a pdf")

    with pytest.raises(HomeAssistantError):
        await _import(hass, bad)

    assert coordinator.store.weeks == before
    assert coordinator.menu_for(datetime.date(2026, 9, 28)) is not None


async def test_a_failed_import_raises_a_notification(hass: HomeAssistant, loaded_entry) -> None:
    broken = _write_www(hass, "broken.pdf", b"nope")

    with pytest.raises(HomeAssistantError):
        await _import(hass, broken)

    assert NOTIFICATION_ERROR_ID in _notifications(hass)
    assert NOTIFICATION_OK_ID not in _notifications(hass)


async def test_a_successful_manual_import_notifies(hass: HomeAssistant, loaded_entry) -> None:
    await _import(hass, _www(hass, "AHS Speiseplan 26-40.pdf"))

    assert NOTIFICATION_OK_ID in _notifications(hass)


async def test_reimporting_the_same_file_is_idempotent(hass: HomeAssistant, loaded_entry) -> None:
    path = _www(hass, "AHS Speiseplan 26-40.pdf")

    await _import(hass, path)
    coordinator = hass.data[DOMAIN][loaded_entry.entry_id]
    hashes_after_first = list(coordinator.store.weeks["2026-W40"]["content_hashes"])

    await _import(hass, path)

    assert len(coordinator.store.weeks) == 1
    assert len(hashes_after_first) == 1
    assert coordinator.store.weeks["2026-W40"]["content_hashes"] == hashes_after_first


async def test_a_second_import_of_known_bytes_says_unchanged(
    hass: HomeAssistant, loaded_entry
) -> None:
    path = _www(hass, "AHS Speiseplan 26-40.pdf")
    await _import(hass, path)
    await _import(hass, path)

    message = _notifications(hass)[NOTIFICATION_OK_ID]["message"]
    assert "unveraendert" in message


async def test_known_bytes_are_skipped_before_any_store_write(
    hass: HomeAssistant, loaded_entry, freezer
) -> None:
    freezer.move_to("2026-09-28 10:00:00+02:00")
    path = _www(hass, "AHS Speiseplan 26-40.pdf")
    await _import(hass, path)
    coordinator = hass.data[DOMAIN][loaded_entry.entry_id]
    first_ingest = coordinator.store.weeks["2026-W40"]["ingested_at"]

    freezer.move_to("2026-09-28 18:00:00+02:00")
    await _import(hass, path)

    assert coordinator.store.weeks["2026-W40"]["ingested_at"] == first_ingest
