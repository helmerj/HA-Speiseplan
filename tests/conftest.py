from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import DOMAIN, SINGLE_ENTRY_UNIQUE_ID
from tests.pdf_fixtures import FIXTURES, WEEK_39, WEEK_40

pytest_plugins = ["pytest_homeassistant_custom_component"]


@pytest.fixture(autouse=True)
def auto_enable_custom_integrations(enable_custom_integrations):
    yield


@pytest.fixture(autouse=True)
def no_release_check():
    with patch(
        "custom_components.school_menu.update.async_fetch_latest_release",
        AsyncMock(return_value=None),
    ):
        yield


@pytest.fixture(autouse=True)
async def german_timezone(hass):
    await hass.config.async_update(time_zone="Europe/Berlin")


@pytest.fixture
def week_39_pdf() -> bytes:
    return (FIXTURES / WEEK_39).read_bytes()


@pytest.fixture
def week_40_pdf() -> bytes:
    return (FIXTURES / WEEK_40).read_bytes()


@pytest.fixture
def config_entry() -> MockConfigEntry:
    return MockConfigEntry(
        domain=DOMAIN,
        unique_id=SINGLE_ENTRY_UNIQUE_ID,
        title="School menu",
        data={},
    )


@pytest.fixture
def mail_entry() -> MockConfigEntry:
    from tests.fake_imap import MAILBOX

    return MockConfigEntry(
        domain=DOMAIN,
        unique_id=SINGLE_ENTRY_UNIQUE_ID,
        title="School menu",
        minor_version=2,
        data=dict(MAILBOX),
    )
