from __future__ import annotations

import datetime
from unittest.mock import patch

import pytest
from homeassistant.const import EVENT_STATE_CHANGED
from homeassistant.core import Event, HomeAssistant, callback
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import MockConfigEntry, async_fire_time_changed

from custom_components.school_menu.const import DOMAIN, SINGLE_ENTRY_UNIQUE_ID
from tests.fake_imap import MAILBOX, TEACHER_A, FakeImapServer, FakeMessage, pdf

pytestmark = [pytest.mark.e2e, pytest.mark.m5]

KITCHEN_OFFICE = "Sekretariat.Kueche@annie-heuser.schule"
OLD_DEFAULT_SENDERS = [
    "Maximilian.Stollberg@annie-heuser.schule",
    "Lena.Putzmann@annie-heuser.schule",
]


def _message(uid: str, sender: str, subject: str, payload: bytes | None) -> FakeMessage:
    return FakeMessage(
        uid=uid,
        sender=sender,
        subject=subject,
        date="Sun, 27 Sep 2026 18:04:11 +0200",
        attachments=[("AHS Speiseplan 26-40.pdf", payload)] if payload is not None else [],
    )


async def test_a_v010_install_picks_up_any_school_sender_and_can_check_on_demand(
    hass: HomeAssistant, freezer
) -> None:
    freezer.move_to("2026-09-30 07:30:00+02:00")
    entry = MockConfigEntry(
        domain=DOMAIN,
        unique_id=SINGLE_ENTRY_UNIQUE_ID,
        title="AHS Speiseplan",
        version=1,
        minor_version=1,
        data={**MAILBOX, "senders": list(OLD_DEFAULT_SENDERS), "subject_filter": "Speiseplan KW"},
    )
    server = FakeImapServer([])
    server.uid_validity = "11"
    entry.add_to_hass(hass)

    with patch("custom_components.school_menu._imap_client_factory", server.client):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done(wait_background_tasks=True)
        assert entry.data["senders"] == ["@annie-heuser.schule"]
        assert entry.data["subject_filter"] == "Speiseplan"
        assert hass.states.get("sensor.school_menu_today").state == "none"

        server.messages = [
            _message("1", f"Küche <{KITCHEN_OFFICE}>", "Speiseplan für nächste Woche", pdf()),
            _message("2", f"Herr Stollberg <{TEACHER_A}>", "Speiseplan KW40", pdf() + b"\n%x\n"),
            _message("3", '"annie-heuser.schule" <menu@evil.example>', "Speiseplan KW41", pdf()),
            _message("4", f"Eltern <{KITCHEN_OFFICE}>", "AW: Frage zum Speiseplan", None),
        ]
        changes: list[str] = []

        @callback
        def _record(event: Event) -> None:
            old, new = event.data["old_state"], event.data["new_state"]
            is_import = event.data["entity_id"] == "sensor.school_menu_last_import"
            if is_import and old and new and old.state != new.state:
                changes.append(new.state)

        hass.bus.async_listen(EVENT_STATE_CHANGED, _record)

        freezer.tick(datetime.timedelta(minutes=16))
        async_fire_time_changed(hass, dt_util.utcnow())
        await hass.async_block_till_done(wait_background_tasks=True)

        assert hass.states.get("sensor.school_menu_today").state == (
            "Chili sin Carne mit Sauer Sahne"
        )
        coordinator = hass.data[DOMAIN][entry.entry_id]
        assert list(coordinator.store.weeks) == ["2026-W40"]
        assert len(changes) == 1

        logins = len([c for c in server.commands if c[0] == "login"])
        await hass.services.async_call(
            "button", "press", {"entity_id": "button.school_menu_check_mail"}, blocking=True
        )
        await hass.async_block_till_done(wait_background_tasks=True)

        assert len([c for c in server.commands if c[0] == "login"]) == logins + 1
        assert len(changes) == 1
        assert list(coordinator.store.weeks) == ["2026-W40"]
        assert server.flags_set == []
