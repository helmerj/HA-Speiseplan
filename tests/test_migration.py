from __future__ import annotations

from unittest.mock import patch

import pytest
from homeassistant.config_entries import ConfigEntryState
from homeassistant.core import HomeAssistant
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import DOMAIN, SINGLE_ENTRY_UNIQUE_ID
from tests.fake_imap import MAILBOX, FakeImapServer

OLD_SENDERS = [
    "Maximilian.Stollberg@annie-heuser.schule",
    "Lena.Putzmann@annie-heuser.schule",
]


def _entry(data: dict, minor_version: int = 1) -> MockConfigEntry:
    return MockConfigEntry(
        domain=DOMAIN,
        unique_id=SINGLE_ENTRY_UNIQUE_ID,
        title="AHS Speiseplan",
        version=1,
        minor_version=minor_version,
        data=data,
    )


async def _set_up(hass: HomeAssistant, entry: MockConfigEntry) -> None:
    entry.add_to_hass(hass)
    with patch("custom_components.school_menu._imap_client_factory", FakeImapServer([]).client):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done(wait_background_tasks=True)


async def test_the_old_defaults_become_the_whole_school_and_speiseplan(
    hass: HomeAssistant,
) -> None:
    entry = _entry({**MAILBOX, "senders": list(OLD_SENDERS), "subject_filter": "Speiseplan KW"})

    await _set_up(hass, entry)

    assert entry.state is ConfigEntryState.LOADED
    assert entry.minor_version == 2
    assert entry.data["senders"] == ["@annie-heuser.schule"]
    assert entry.data["subject_filter"] == "Speiseplan"
    assert entry.data["password"] == MAILBOX["password"]
    assert entry.data["username"] == MAILBOX["username"]
    assert entry.data["host"] == MAILBOX["host"]


async def test_the_old_senders_in_another_order_or_case_still_count_as_the_default(
    hass: HomeAssistant,
) -> None:
    senders = [s.lower() for s in reversed(OLD_SENDERS)]
    entry = _entry({**MAILBOX, "senders": senders, "subject_filter": "Speiseplan KW"})

    await _set_up(hass, entry)

    assert entry.data["senders"] == ["@annie-heuser.schule"]


@pytest.mark.parametrize(
    ("senders", "subject", "expected_senders", "expected_subject"),
    [
        (
            ["only.one@annie-heuser.schule"],
            "Speiseplan KW",
            ["only.one@annie-heuser.schule"],
            "Speiseplan",
        ),
        (list(OLD_SENDERS), "Mittagessen", ["@annie-heuser.schule"], "Mittagessen"),
        ([*OLD_SENDERS, "third@x.de"], "Menü", [*OLD_SENDERS, "third@x.de"], "Menü"),
        (
            [f" {OLD_SENDERS[0]} ", OLD_SENDERS[1]],
            "  Speiseplan KW ",
            ["@annie-heuser.schule"],
            "Speiseplan",
        ),
    ],
)
async def test_senders_and_subject_are_migrated_independently(
    hass: HomeAssistant,
    senders: list[str],
    subject: str,
    expected_senders: list[str],
    expected_subject: str,
) -> None:
    entry = _entry({**MAILBOX, "senders": senders, "subject_filter": subject})

    await _set_up(hass, entry)

    assert entry.minor_version == 2
    assert entry.data["senders"] == expected_senders
    assert entry.data["subject_filter"] == expected_subject


async def test_an_entry_without_a_mailbox_only_gets_its_version_bumped(
    hass: HomeAssistant,
) -> None:
    entry = _entry({})

    await _set_up(hass, entry)

    assert entry.minor_version == 2
    assert entry.data == {}


async def test_a_migrated_entry_is_left_alone(hass: HomeAssistant) -> None:
    data = {**MAILBOX, "senders": list(OLD_SENDERS), "subject_filter": "Speiseplan KW"}
    entry = _entry(data, minor_version=2)

    await _set_up(hass, entry)

    assert entry.data["senders"] == OLD_SENDERS
    assert entry.data["subject_filter"] == "Speiseplan KW"
