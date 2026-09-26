from __future__ import annotations

from pathlib import Path

import pytest
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import DOMAIN, SINGLE_ENTRY_UNIQUE_ID

FIXTURES = Path(__file__).parent / "fixtures"

pytest_plugins = ["pytest_homeassistant_custom_component"]


@pytest.fixture(autouse=True)
def auto_enable_custom_integrations(enable_custom_integrations):
    yield


@pytest.fixture(autouse=True)
async def german_timezone(hass):
    await hass.config.async_update(time_zone="Europe/Berlin")


@pytest.fixture
def week_39_pdf() -> bytes:
    return (FIXTURES / "AHS Speiseplan 26-39.pdf").read_bytes()


@pytest.fixture
def week_40_pdf() -> bytes:
    return (FIXTURES / "AHS Speiseplan 26-40.pdf").read_bytes()


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
        domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, title="School menu", data=dict(MAILBOX)
    )
