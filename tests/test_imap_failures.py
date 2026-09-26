from __future__ import annotations

from unittest.mock import patch

import pytest
from homeassistant.components import persistent_notification
from homeassistant.config_entries import SOURCE_REAUTH, ConfigEntryState
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed
from homeassistant.helpers.update_coordinator import UpdateFailed
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import (
    DOMAIN,
    NOTIFICATION_IMAP_ID,
    SINGLE_ENTRY_UNIQUE_ID,
)
from tests.fake_imap import (
    MAILBOX,
    TEACHER_A,
    AlwaysFindsIt,
    FakeImapServer,
    mail,
    pdf,
    setup_mailbox,
)


def _notifications(hass: HomeAssistant) -> dict:
    return persistent_notification._async_get_or_create_notifications(hass)


async def test_a_wrong_password_starts_the_reauth_flow(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.login_result = "NO"

    with pytest.raises(ConfigEntryAuthFailed):
        await coordinator._async_update_data()
    await coordinator.async_refresh()
    await hass.async_block_till_done()

    flows = hass.config_entries.flow.async_progress()
    assert [flow["context"]["source"] for flow in flows] == [SOURCE_REAUTH]


@pytest.mark.parametrize(
    ("result", "lines"),
    [("NO", [b"[UNAVAILABLE] try again later"]), ("BAD", [b"command unknown"])],
)
async def test_a_login_that_is_not_a_bad_password_is_transient(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer, result: str, lines: list
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.login_result = result
    server.login_lines = lines

    with pytest.raises(UpdateFailed):
        await coordinator._async_update_data()

    assert hass.config_entries.flow.async_progress() == []


async def _fail(coordinator, times: int) -> None:
    for _ in range(times):
        with pytest.raises(UpdateFailed):
            await coordinator._async_update_data()


async def test_a_transient_failure_only_notifies_after_three_attempts(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.select_result = "NO"

    await _fail(coordinator, 2)
    assert NOTIFICATION_IMAP_ID not in _notifications(hass)
    assert coordinator.consecutive_failures == 2

    await _fail(coordinator, 1)
    assert "seit 3 Versuchen" in _notifications(hass)[NOTIFICATION_IMAP_ID]["message"]

    await _fail(coordinator, 1)
    assert "seit 4 Versuchen" in _notifications(hass)[NOTIFICATION_IMAP_ID]["message"]


async def test_a_success_in_between_resets_the_failure_count(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)

    server.select_result = "NO"
    await _fail(coordinator, 2)
    server.select_result = "OK"
    await coordinator._async_update_data()
    server.select_result = "NO"
    await _fail(coordinator, 2)

    assert NOTIFICATION_IMAP_ID not in _notifications(hass)


async def test_recovery_dismisses_the_failure_notification(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.select_result = "NO"
    await _fail(coordinator, 3)
    assert NOTIFICATION_IMAP_ID in _notifications(hass)

    server.select_result = "OK"
    await coordinator._async_update_data()

    assert NOTIFICATION_IMAP_ID not in _notifications(hass)


async def test_a_bare_timeout_still_names_a_reason(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.raise_on_fetch = TimeoutError()

    await _fail(coordinator, 3)

    assert _notifications(hass)[NOTIFICATION_IMAP_ID]["message"].endswith("TimeoutError")


async def test_a_failure_never_leaks_credentials(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer, caplog
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.fetch_result = "NO"

    await _fail(coordinator, 3)
    await coordinator.async_refresh()

    message = _notifications(hass)[NOTIFICATION_IMAP_ID]["message"]
    for secret in ("hunter2", MAILBOX["username"]):
        assert secret not in message
        assert secret not in caplog.text


async def test_the_session_is_always_closed(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)

    for _ in range(3):
        await coordinator.async_refresh()

    assert server.opened == 4
    assert server.live_connections == 0


async def test_the_session_is_closed_even_when_the_fetch_fails(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.fetch_result = "NO"

    await _fail(coordinator, 1)

    assert server.live_connections == 0


async def test_a_library_exception_becomes_a_transient_failure(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    from aioimaplib import CommandTimeout

    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.raise_on_fetch = CommandTimeout("UID FETCH 1")

    await _fail(coordinator, 1)

    assert coordinator.consecutive_failures == 1
    assert server.live_connections == 0


async def test_configuring_the_mailbox_starts_polling(hass: HomeAssistant, freezer) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    entry = MockConfigEntry(
        domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, title="School menu", data={}
    )
    entry.add_to_hass(hass)

    with patch("custom_components.school_menu._imap_client_factory", server.client):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done()
        assert hass.data[DOMAIN][entry.entry_id].update_interval is None

        result = await hass.config_entries.options.async_init(entry.entry_id)
        await hass.config_entries.options.async_configure(result["flow_id"], dict(MAILBOX))
        await hass.async_block_till_done(wait_background_tasks=True)

        assert hass.data[DOMAIN][entry.entry_id].update_interval is not None
        assert [c for c in server.commands if c[0] == "login"]
        assert hass.states.get("sensor.school_menu_today").state == (
            "Chili sin Carne mit Sauer Sahne"
        )


async def test_a_mailbox_outage_at_startup_still_loads_the_stored_week(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    healthy = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, healthy)
    assert coordinator.store.weeks

    assert await hass.config_entries.async_unload(mail_entry.entry_id)
    await hass.async_block_till_done()

    def _unreachable(_settings):
        raise OSError("mail host is down")

    with patch("custom_components.school_menu._imap_client_factory", _unreachable):
        assert await hass.config_entries.async_setup(mail_entry.entry_id)
        await hass.async_block_till_done(wait_background_tasks=True)

    assert mail_entry.state is ConfigEntryState.LOADED
    assert hass.states.get("sensor.school_menu_today").state == ("Chili sin Carne mit Sauer Sahne")
    assert hass.services.has_service(DOMAIN, "import_pdf")


async def test_setup_does_not_wait_for_a_hung_mailbox(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    import asyncio

    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    release = asyncio.Event()

    class _Hung(AlwaysFindsIt):
        async def wait_hello_from_server(self):
            await release.wait()
            return await super().wait_hello_from_server()

    mail_entry.add_to_hass(hass)
    with patch("custom_components.school_menu._imap_client_factory", lambda _s: _Hung(server)):
        assert await hass.config_entries.async_setup(mail_entry.entry_id)
        await hass.async_block_till_done()

        assert mail_entry.state is ConfigEntryState.LOADED
        assert hass.states.get("sensor.school_menu_today") is not None
        release.set()
        await hass.async_block_till_done(wait_background_tasks=True)


async def test_a_poll_that_outlives_its_deadline_is_a_transient_failure(
    hass: HomeAssistant, mail_entry: MockConfigEntry
) -> None:
    import asyncio

    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)

    class _Stalled(AlwaysFindsIt):
        async def wait_hello_from_server(self):
            await asyncio.Event().wait()

    coordinator.client_factory = lambda _s: _Stalled(server)
    with patch("custom_components.school_menu.coordinator.IMAP_POLL_TIMEOUT_SECONDS", 0.05):
        await _fail(coordinator, 1)

    assert coordinator.consecutive_failures == 1
