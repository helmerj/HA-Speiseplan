from __future__ import annotations

import pytest
from homeassistant.config_entries import SOURCE_USER
from homeassistant.core import HomeAssistant
from homeassistant.data_entry_flow import FlowResultType
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import DEFAULT_NAME, DOMAIN, SINGLE_ENTRY_UNIQUE_ID


async def test_user_flow_shows_form_then_creates_entry(hass: HomeAssistant) -> None:
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    assert result["type"] is FlowResultType.FORM

    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"name": "Schule"})
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["title"] == "Schule"


async def test_user_flow_defaults_the_name(hass: HomeAssistant) -> None:
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {})
    assert result["title"] == DEFAULT_NAME


async def test_matching_unique_id_aborts(hass: HomeAssistant) -> None:
    MockConfigEntry(domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data={}).add_to_hass(hass)

    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})

    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "single_instance_allowed"


async def test_legacy_entry_without_unique_id_still_aborts(hass: HomeAssistant) -> None:
    MockConfigEntry(domain=DOMAIN, unique_id=None, data={}).add_to_hass(hass)

    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})

    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "single_instance_allowed"
    assert len(hass.config_entries.async_entries(DOMAIN)) == 1


async def test_a_concurrent_flow_aborts_with_a_translated_reason(hass: HomeAssistant) -> None:
    first = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    assert first["type"] is FlowResultType.FORM

    second = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})

    assert second["type"] is FlowResultType.ABORT
    assert second["reason"] == "already_in_progress"


MAILBOX_INPUT = {
    "host": "imap.example.org",
    "port": 993,
    "ssl": True,
    "username": "parent@example.org",
    "password": "hunter2",
    "folder": "INBOX",
    "senders": [
        "Maximilian.Stollberg@annie-heuser.schule",
        "Lena.Putzmann@annie-heuser.schule",
    ],
    "subject_filter": "Speiseplan KW",
    "scan_interval_minutes": 15,
}


async def test_the_options_flow_stores_credentials_in_entry_data(hass: HomeAssistant) -> None:
    from unittest.mock import patch

    entry = MockConfigEntry(domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data={})
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    result = await hass.config_entries.options.async_init(entry.entry_id)
    assert result["type"] is FlowResultType.FORM

    with patch("custom_components.school_menu._imap_client_factory"):
        result = await hass.config_entries.options.async_configure(
            result["flow_id"], dict(MAILBOX_INPUT)
        )
        await hass.async_block_till_done()

    assert entry.data["password"] == "hunter2"
    assert entry.data["senders"] == MAILBOX_INPUT["senders"]
    assert entry.data["scan_interval_minutes"] == 15
    assert "password" not in entry.options


@pytest.mark.parametrize(
    ("change", "errors"),
    [
        ({"senders": []}, {"senders": "no_senders"}),
        ({"host": "   "}, {"host": "no_host"}),
        ({"senders": ["hello"]}, {"senders": "invalid_sender"}),
        ({"senders": ["Herr Stollberg <a@b.de>"]}, {"senders": "invalid_sender"}),
        ({"senders": ["@"]}, {"senders": "invalid_sender"}),
        ({"senders": ["@foo"]}, {"senders": "invalid_sender"}),
        ({"senders": ["a@@b.de"]}, {"senders": "invalid_sender"}),
        ({"senders": ["@annie heuser.schule"]}, {"senders": "invalid_sender"}),
        ({"subject_filter": "  "}, {"subject_filter": "no_subject_filter"}),
        ({"password": ""}, {"password": "no_password"}),
    ],
)
async def test_the_options_flow_refuses_unusable_input(
    hass: HomeAssistant, change: dict, errors: dict
) -> None:
    entry = MockConfigEntry(domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data={})
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    result = await hass.config_entries.options.async_init(entry.entry_id)
    result = await hass.config_entries.options.async_configure(
        result["flow_id"], {**MAILBOX_INPUT, **change}
    )

    assert result["type"] is FlowResultType.FORM
    assert result["errors"] == errors
    assert entry.data == {}


async def test_the_options_flow_rejects_a_poll_interval_below_five_minutes(
    hass: HomeAssistant,
) -> None:
    from homeassistant.data_entry_flow import InvalidData

    entry = MockConfigEntry(domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data={})
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    result = await hass.config_entries.options.async_init(entry.entry_id)
    with pytest.raises(InvalidData):
        await hass.config_entries.options.async_configure(
            result["flow_id"], {**MAILBOX_INPUT, "scan_interval_minutes": 4}
        )


async def test_a_blank_password_keeps_the_stored_one(hass: HomeAssistant) -> None:
    from unittest.mock import patch

    entry = MockConfigEntry(
        domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data=dict(MAILBOX_INPUT)
    )
    entry.add_to_hass(hass)
    with patch("custom_components.school_menu._imap_client_factory"):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done()

        result = await hass.config_entries.options.async_init(entry.entry_id)
        await hass.config_entries.options.async_configure(
            result["flow_id"], {**MAILBOX_INPUT, "password": "", "folder": "Schule"}
        )
        await hass.async_block_till_done()

    assert entry.data["password"] == "hunter2"
    assert entry.data["folder"] == "Schule"


async def test_reauth_replaces_only_the_password(hass: HomeAssistant) -> None:
    from unittest.mock import patch

    entry = MockConfigEntry(
        domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data=dict(MAILBOX_INPUT)
    )
    entry.add_to_hass(hass)

    with patch("custom_components.school_menu._imap_client_factory"):
        result = await entry.start_reauth_flow(hass)
        assert result["type"] is FlowResultType.FORM
        assert result["step_id"] == "reauth_confirm"

        result = await hass.config_entries.flow.async_configure(
            result["flow_id"], {"password": "new-secret"}
        )
        await hass.async_block_till_done()

    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "reauth_successful"
    assert entry.data["password"] == "new-secret"
    assert entry.data["username"] == MAILBOX_INPUT["username"]


async def test_the_options_flow_accepts_a_whole_school_domain(hass: HomeAssistant) -> None:
    from unittest.mock import patch

    entry = MockConfigEntry(domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data={})
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    result = await hass.config_entries.options.async_init(entry.entry_id)
    with patch("custom_components.school_menu._imap_client_factory"):
        result = await hass.config_entries.options.async_configure(
            result["flow_id"],
            {**MAILBOX_INPUT, "senders": ["@annie-heuser.schule", "Extra@Example.org"]},
        )
        await hass.async_block_till_done()

    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert entry.data["senders"] == ["@annie-heuser.schule", "Extra@Example.org"]


async def test_the_options_form_offers_the_school_domain_by_default(hass: HomeAssistant) -> None:
    entry = MockConfigEntry(domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, data={})
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    result = await hass.config_entries.options.async_init(entry.entry_id)
    defaults = {
        str(key): key.default() for key in result["data_schema"].schema if callable(key.default)
    }

    assert defaults["senders"] == ["@annie-heuser.schule"]
    assert defaults["subject_filter"] == "Speiseplan"
