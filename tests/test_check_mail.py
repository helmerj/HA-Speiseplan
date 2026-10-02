from __future__ import annotations

from unittest.mock import patch

import pytest
from homeassistant.components import persistent_notification
from homeassistant.const import STATE_UNAVAILABLE
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ServiceValidationError
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import (
    DOMAIN,
    NOTIFICATION_ERROR_ID,
    SERVICE_CHECK_MAIL,
)
from tests.fake_imap import (
    TEACHER_A,
    TEACHER_B,
    FakeImapServer,
    body_fetches,
    mail,
    pdf,
    setup_mailbox,
)

BUTTON = "button.school_menu_check_mail"
LAST_IMPORT = "sensor.school_menu_last_import"


async def _check(hass: HomeAssistant) -> None:
    await hass.services.async_call(DOMAIN, SERVICE_CHECK_MAIL, {}, blocking=True)
    await hass.async_block_till_done()


async def _press(hass: HomeAssistant) -> None:
    await hass.services.async_call("button", "press", {"entity_id": BUTTON}, blocking=True)
    await hass.async_block_till_done()


def _notifications(hass: HomeAssistant) -> dict:
    return persistent_notification._async_get_or_create_notifications(hass)


def _logins(server: FakeImapServer) -> int:
    return len([c for c in server.commands if c[0] == "login"])


async def test_checking_now_polls_once_and_rereads_the_whole_window(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer(
        [
            mail("1", TEACHER_A, "Speiseplan KW40", pdf()),
            mail("2", TEACHER_B, "Elternbrief", pdf()),
        ]
    )
    server.uid_validity = "7"
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.commands.clear()
    await coordinator.async_refresh()
    assert [c for c in server.commands if c[0] == "uid"] == []
    server.commands.clear()

    await _check(hass)

    assert _logins(server) == 1
    assert body_fetches(server) == ["1"]


async def test_checking_now_imports_nothing_twice(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    server.uid_validity = "7"
    coordinator = await setup_mailbox(hass, mail_entry, server)
    stamp = hass.states.get(LAST_IMPORT).state
    calls: list[None] = []
    coordinator.async_add_listener(lambda: calls.append(None))

    await _check(hass)

    assert hass.states.get(LAST_IMPORT).state == stamp
    assert len(coordinator.store.weeks["2026-W40"]["content_hashes"]) == 1
    assert calls == []


async def test_checking_now_retries_an_attachment_that_was_refused(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", b"broken", "kaputt.pdf")])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    assert coordinator.rejected_hashes
    persistent_notification.async_dismiss(hass, NOTIFICATION_ERROR_ID)
    attempts: list[bytes] = []

    def _extract(payload: bytes) -> list[str]:
        attempts.append(payload)
        from custom_components.school_menu.models import MenuParseError

        raise MenuParseError("no_text_layer")

    with patch("custom_components.school_menu.coordinator.extract_lines", _extract):
        await coordinator.async_refresh()
        assert attempts == []
        assert NOTIFICATION_ERROR_ID not in _notifications(hass)
        await _check(hass)

    assert attempts == [b"broken"]
    assert "kaputt.pdf" in _notifications(hass)[NOTIFICATION_ERROR_ID]["message"]


async def test_the_button_checks_the_mailbox_now(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    await setup_mailbox(hass, mail_entry, server)
    server.commands.clear()
    server.messages = [mail("1", TEACHER_A, "Speiseplan KW40", pdf())]

    await _press(hass)

    assert _logins(server) == 1
    assert hass.states.get("sensor.school_menu_today").state == "Chili sin Carne mit Sauer Sahne"


async def test_the_button_has_a_fixed_id_and_a_readable_name(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    from homeassistant.helpers import entity_registry as er

    freezer.move_to("2026-09-30 09:00:00+02:00")
    await setup_mailbox(hass, mail_entry, FakeImapServer([]))

    entity = er.async_get(hass).async_get(BUTTON)
    assert entity.unique_id == f"{mail_entry.entry_id}_check_mail"
    state = hass.states.get(BUTTON)
    assert state.state != STATE_UNAVAILABLE
    assert state.attributes["friendly_name"] == "School menu Check mail now"


async def test_without_a_mailbox_the_button_is_unavailable_and_the_action_refuses(
    hass: HomeAssistant, config_entry: MockConfigEntry
) -> None:
    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()

    assert hass.states.get(BUTTON).state == STATE_UNAVAILABLE
    with pytest.raises(ServiceValidationError) as raised:
        await _check(hass)
    assert raised.value.translation_key == "no_mailbox"


async def test_a_failed_check_is_reported_not_swallowed(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    from homeassistant.exceptions import HomeAssistantError

    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    await setup_mailbox(hass, mail_entry, server)
    server.select_result = "NO"

    with pytest.raises(HomeAssistantError) as raised:
        await _check(hass)

    assert raised.value.translation_key == "check_mail_failed"
    assert "EXAMINE" in raised.value.translation_placeholders["reason"]
    assert "hunter2" not in str(raised.value.translation_placeholders)


async def test_a_second_check_within_a_minute_is_skipped(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    import datetime

    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    await setup_mailbox(hass, mail_entry, server)
    server.commands.clear()

    await _check(hass)
    await _press(hass)
    assert _logins(server) == 1

    freezer.tick(datetime.timedelta(seconds=61))
    await _press(hass)
    assert _logins(server) == 2


async def test_two_checks_at_once_open_one_session(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    import asyncio

    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.commands.clear()

    await asyncio.gather(coordinator.async_check_mail_now(), coordinator.async_check_mail_now())

    assert _logins(server) == 1


async def test_a_check_during_a_running_poll_is_skipped(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.commands.clear()

    async with coordinator.poll_lock:
        await coordinator.async_check_mail_now()

    assert _logins(server) == 0


async def test_a_scheduled_poll_waits_while_a_check_holds_the_mailbox(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    import asyncio

    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.commands.clear()

    async with coordinator.poll_lock:
        task = hass.async_create_task(coordinator.async_refresh())
        for _ in range(5):
            await asyncio.sleep(0)
        assert _logins(server) == 0
    await task

    assert _logins(server) == 1
