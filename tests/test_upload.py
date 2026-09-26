from __future__ import annotations

import datetime
import shutil
from pathlib import Path

import pytest
from homeassistant.components.file_upload import DOMAIN as FILE_UPLOAD_DOMAIN
from homeassistant.components.file_upload import FileUploadData
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError, ServiceValidationError
from homeassistant.setup import async_setup_component
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import DOMAIN, SERVICE_IMPORT_PDF
from tests.conftest import FIXTURES

FILE_ID = "01ABCDEFGHIJKLMNOPQRSTUVWX"


def _stage_upload(tmp_path: Path, name: str) -> Path:
    upload_dir = tmp_path / FILE_ID
    upload_dir.mkdir(parents=True, exist_ok=True)
    target = upload_dir / name
    shutil.copyfile(FIXTURES / name, target)
    return target


def _write_upload(tmp_path: Path, name: str, payload: bytes) -> Path:
    upload_dir = tmp_path / FILE_ID
    upload_dir.mkdir(parents=True, exist_ok=True)
    target = upload_dir / name
    target.write_bytes(payload)
    return target


@pytest.fixture
async def uploads(hass: HomeAssistant, tmp_path: Path) -> Path:
    assert await async_setup_component(hass, FILE_UPLOAD_DOMAIN, {})
    hass.data[FILE_UPLOAD_DOMAIN] = FileUploadData(tmp_path, {})
    return tmp_path


@pytest.fixture
async def loaded_entry(hass: HomeAssistant, config_entry: MockConfigEntry) -> MockConfigEntry:
    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()
    return config_entry


async def _import_upload(hass: HomeAssistant) -> None:
    await hass.services.async_call(DOMAIN, SERVICE_IMPORT_PDF, {"file_id": FILE_ID}, blocking=True)
    await hass.async_block_till_done()


async def test_a_real_upload_imports_and_is_consumed(
    hass: HomeAssistant, loaded_entry, uploads: Path
) -> None:
    name = "AHS Speiseplan 26-40.pdf"
    _stage_upload(uploads, name)
    hass.data[FILE_UPLOAD_DOMAIN].files[FILE_ID] = name

    await _import_upload(hass)

    coordinator = hass.data[DOMAIN][loaded_entry.entry_id]
    assert coordinator.menu_for(datetime.date(2026, 9, 28)) is not None
    assert coordinator.store.weeks["2026-W40"]["source_file"] == name
    assert not (uploads / FILE_ID).exists()


async def test_a_consumed_upload_cannot_be_imported_twice(
    hass: HomeAssistant, loaded_entry, uploads: Path
) -> None:
    name = "AHS Speiseplan 26-40.pdf"
    _stage_upload(uploads, name)
    hass.data[FILE_UPLOAD_DOMAIN].files[FILE_ID] = name
    await _import_upload(hass)

    with pytest.raises(ServiceValidationError) as excinfo:
        await _import_upload(hass)
    assert excinfo.value.translation_key == "upload_not_found"


async def test_an_unknown_upload_id_is_a_validation_error(
    hass: HomeAssistant, loaded_entry, uploads: Path
) -> None:
    with pytest.raises(ServiceValidationError) as excinfo:
        await _import_upload(hass)
    assert excinfo.value.translation_key == "upload_not_found"


async def test_an_upload_failure_names_the_real_filename(
    hass: HomeAssistant, loaded_entry, uploads: Path
) -> None:
    from homeassistant.components import persistent_notification

    from custom_components.school_menu.const import NOTIFICATION_ERROR_ID

    _write_upload(uploads, "Speiseplan KW40.pdf", b"not a pdf")
    hass.data[FILE_UPLOAD_DOMAIN].files[FILE_ID] = "Speiseplan KW40.pdf"

    with pytest.raises(HomeAssistantError):
        await _import_upload(hass)

    message = persistent_notification._async_get_or_create_notifications(hass)[
        NOTIFICATION_ERROR_ID
    ]["message"]
    assert "Speiseplan KW40.pdf" in message
    assert FILE_ID not in message


async def test_the_upload_is_parsed_off_the_event_loop(
    hass: HomeAssistant, loaded_entry, uploads: Path
) -> None:
    from unittest.mock import patch

    name = "AHS Speiseplan 26-40.pdf"
    _stage_upload(uploads, name)
    hass.data[FILE_UPLOAD_DOMAIN].files[FILE_ID] = name

    from custom_components.school_menu import _parse_upload

    seen: list[str] = []
    original = hass.async_add_executor_job

    def _record(target, *args):
        if target is _parse_upload:
            seen.append(target.__name__)
        return original(target, *args)

    with patch.object(hass, "async_add_executor_job", _record):
        await _import_upload(hass)

    assert seen == ["_parse_upload"]
