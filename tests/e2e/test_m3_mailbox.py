from __future__ import annotations

import datetime
from unittest.mock import patch

import pytest
from homeassistant.components import persistent_notification
from homeassistant.const import EVENT_STATE_CHANGED
from homeassistant.core import Event, HomeAssistant, callback
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import MockConfigEntry, async_fire_time_changed

from custom_components.school_menu.const import DOMAIN, SINGLE_ENTRY_UNIQUE_ID
from custom_components.school_menu.diagnostics import async_get_config_entry_diagnostics
from tests.fake_imap import MAILBOX, TEACHER_A, TEACHER_B, FakeImapServer, FakeMessage, pdf

pytestmark = [pytest.mark.e2e, pytest.mark.m3]

WATCHED = (
    "sensor.school_menu_today",
    "sensor.school_menu_next_school_day",
    "sensor.school_menu_last_import",
)


def _both_teachers_send_the_same_week(second_copy: bytes) -> FakeImapServer:
    return FakeImapServer(
        [
            FakeMessage(
                uid="1",
                sender=f"Herr Stollberg <{TEACHER_A}>",
                subject="Speiseplan KW40",
                date="Sun, 27 Sep 2026 18:04:11 +0200",
                attachments=[("AHS Speiseplan 26-40.pdf", pdf())],
            ),
            FakeMessage(
                uid="2",
                sender=f"Frau Putzmann <{TEACHER_B}>",
                subject="Fwd: Speiseplan KW40",
                date="Sun, 27 Sep 2026 19:12:00 +0200",
                attachments=[("AHS Speiseplan 26-40.pdf", second_copy)],
            ),
        ]
    )


def _record_changes(hass: HomeAssistant) -> dict[str, list[str]]:
    changes: dict[str, list[str]] = {entity_id: [] for entity_id in WATCHED}

    @callback
    def _record(event: Event) -> None:
        entity_id = event.data["entity_id"]
        old, new = event.data["old_state"], event.data["new_state"]
        if entity_id in changes and old is not None and old.state != new.state:
            changes[entity_id].append(new.state)

    hass.bus.async_listen(EVENT_STATE_CHANGED, _record)
    return changes


@pytest.mark.parametrize(
    "second_copy",
    [pdf(), pdf() + b"\n% forwarded\n"],
    ids=["identical-bytes", "re-attached-bytes"],
)
async def test_the_weekly_mail_updates_the_sensors_once_and_the_second_copy_changes_nothing(
    hass: HomeAssistant, freezer, caplog, second_copy: bytes
) -> None:
    freezer.move_to("2026-09-30 07:30:00+02:00")
    arriving = _both_teachers_send_the_same_week(second_copy).messages
    server = FakeImapServer([])
    entry = MockConfigEntry(
        domain=DOMAIN, unique_id=SINGLE_ENTRY_UNIQUE_ID, title="School menu", data=dict(MAILBOX)
    )
    entry.add_to_hass(hass)

    async def _poll_cycle() -> None:
        logins = len([c for c in server.commands if c[0] == "login"])
        freezer.tick(datetime.timedelta(minutes=16))
        async_fire_time_changed(hass, dt_util.utcnow())
        await hass.async_block_till_done(wait_background_tasks=True)
        assert len([c for c in server.commands if c[0] == "login"]) == logins + 1

    with patch("custom_components.school_menu._imap_client_factory", server.client):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done(wait_background_tasks=True)
        assert hass.states.get("sensor.school_menu_today").state == "none"

        changes = _record_changes(hass)
        server.messages = arriving
        await _poll_cycle()

        today = hass.states.get("sensor.school_menu_today")
        assert today.state == "Chili sin Carne mit Sauer Sahne"
        assert today.attributes["side"] == "Reis"
        assert today.attributes["source_file"] == "AHS Speiseplan 26-40.pdf"
        assert hass.states.get("sensor.school_menu_next_school_day").state == (
            "Blumenkohl-Brokkoli-Möhre mit Käse überbacken"
        )
        stamp = hass.states.get("sensor.school_menu_last_import").state

        await _poll_cycle()

    assert len(changes["sensor.school_menu_today"]) == 1, changes
    assert len(changes["sensor.school_menu_next_school_day"]) == 1, changes
    assert len(changes["sensor.school_menu_last_import"]) == 1, changes
    assert hass.states.get("sensor.school_menu_last_import").state == stamp
    assert hass.states.get("sensor.school_menu_last_import").attributes["source"] == "imap"

    coordinator = hass.data[DOMAIN][entry.entry_id]
    assert list(coordinator.store.weeks) == ["2026-W40"]
    assert coordinator.store.weeks["2026-W40"]["source"] == "imap"

    assert server.flags_set == []
    assert persistent_notification._async_get_or_create_notifications(hass) == {}

    diagnostics = str(await async_get_config_entry_diagnostics(hass, entry))
    for secret in (MAILBOX["password"], MAILBOX["username"]):
        assert secret not in caplog.text
        assert secret not in diagnostics
