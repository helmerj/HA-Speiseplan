from __future__ import annotations

import datetime
import threading
from unittest.mock import patch

import pytest
from homeassistant.components import persistent_notification
from homeassistant.const import EVENT_STATE_CHANGED
from homeassistant.core import Event, HomeAssistant, callback
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import NOTIFICATION_ERROR_ID, NOTIFICATION_IMAP_ID
from custom_components.school_menu.models import DayMenu, ParsedWeek
from custom_components.school_menu.parser import extract_lines
from tests.fake_imap import TEACHER_A, TEACHER_B, FakeImapServer, mail, pdf, setup_mailbox

LAST_IMPORT = "sensor.school_menu_last_import"
TODAY = "sensor.school_menu_today"
EXTRACT = "custom_components.school_menu.coordinator.extract_lines"
WEEK_40 = extract_lines(pdf())


def _notifications(hass: HomeAssistant) -> dict:
    return persistent_notification._async_get_or_create_notifications(hass)


def _listener_calls(coordinator) -> list[None]:
    calls: list[None] = []
    coordinator.async_add_listener(lambda: calls.append(None))
    return calls


def _changes(hass: HomeAssistant, entity_id: str) -> list[str]:
    seen: list[str] = []

    @callback
    def _record(event: Event) -> None:
        if event.data["entity_id"] == entity_id and event.data["old_state"] is not None:
            seen.append(event.data["new_state"].state)

    hass.bus.async_listen(EVENT_STATE_CHANGED, _record)
    return seen


def _by_payload(table: dict[bytes, list[str]]):
    calls: list[bytes] = []

    def _extract(payload: bytes) -> list[str]:
        calls.append(payload)
        if payload not in table:
            return extract_lines(payload)
        return table[payload]

    return _extract, calls


def _with_wednesday(main: str) -> list[str]:
    return [main if line.startswith("Chili sin Carne") else line for line in WEEK_40]


def _monday_only() -> list[str]:
    return (
        WEEK_40[: WEEK_40.index("DIENSTAG")]
        + WEEK_40[WEEK_40.index("„Das Beste in der Musik steht nicht in den Noten.“") :]
    )


async def _poll(hass: HomeAssistant, coordinator) -> None:
    await coordinator.async_refresh()
    await hass.async_block_till_done()


async def test_a_matching_mail_updates_the_sensors(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])

    await setup_mailbox(hass, mail_entry, server)

    assert hass.states.get(TODAY).state == "Chili sin Carne mit Sauer Sahne"


async def test_the_second_teachers_identical_copy_is_skipped_before_parsing(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    stamp = hass.states.get(LAST_IMPORT).state
    calls = _listener_calls(coordinator)
    server.messages.append(mail("2", TEACHER_B, "Fwd: Speiseplan KW40", pdf()))
    extract, parsed = _by_payload({})

    with patch(EXTRACT, extract):
        await _poll(hass, coordinator)

    assert parsed == []
    assert calls == []
    assert len(coordinator.store.weeks["2026-W40"]["content_hashes"]) == 1
    assert hass.states.get(LAST_IMPORT).state == stamp


async def test_a_byte_different_copy_of_the_same_menu_changes_nothing_visible(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    stamp = hass.states.get(LAST_IMPORT).state
    calls = _listener_calls(coordinator)
    resent = pdf() + b"\n% forwarded by the second teacher\n"
    server.messages.append(mail("2", TEACHER_B, "Fwd: Speiseplan KW40", resent))

    await _poll(hass, coordinator)
    await _poll(hass, coordinator)

    hashes = coordinator.store.weeks["2026-W40"]["content_hashes"]
    assert len(hashes) == 2
    assert len(set(hashes)) == 2
    assert calls == []
    assert hass.states.get(LAST_IMPORT).state == stamp
    assert coordinator.store.weeks["2026-W40"]["source_file"] == "plan.pdf"


async def test_a_poll_with_nothing_new_notifies_no_listener(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    calls = _listener_calls(coordinator)

    for _ in range(3):
        await _poll(hass, coordinator)

    assert calls == []


async def test_a_genuine_update_notifies_listeners_exactly_once(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    calls = _listener_calls(coordinator)
    imports = _changes(hass, LAST_IMPORT)
    server.messages = [mail("1", TEACHER_A, "Speiseplan KW40", pdf())]

    await _poll(hass, coordinator)

    assert len(calls) == 1
    assert len(imports) == 1


@pytest.mark.parametrize("uids", [("1", "2", "3"), ("998", "1002", "1003")])
async def test_the_newest_mail_wins_whatever_order_the_senders_are_searched_in(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer, uids: tuple[str, str, str]
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    original, forwarded, corrected = uids
    server = FakeImapServer(
        [
            mail(original, TEACHER_A, "Speiseplan KW40", b"original"),
            mail(forwarded, TEACHER_B, "Fwd: Speiseplan KW40", b"original, forwarded"),
            mail(corrected, TEACHER_A, "Speiseplan KW40 korrigiert", b"corrected"),
        ]
    )
    extract, _ = _by_payload(
        {
            b"original": WEEK_40,
            b"original, forwarded": WEEK_40,
            b"corrected": _with_wednesday("Chili con Carne"),
        }
    )

    with patch(EXTRACT, extract):
        coordinator = await setup_mailbox(hass, mail_entry, server)
        await _poll(hass, coordinator)

    assert hass.states.get(TODAY).state == "Chili con Carne"


async def test_a_corrected_menu_for_a_known_week_overwrites(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    calls = _listener_calls(coordinator)
    server.messages.append(mail("2", TEACHER_A, "Speiseplan KW40", b"corrected"))
    extract, _ = _by_payload({b"corrected": _with_wednesday("Chili con Carne")})

    with patch(EXTRACT, extract):
        await _poll(hass, coordinator)

    assert hass.states.get(TODAY).state == "Chili con Carne"
    assert len(coordinator.store.weeks["2026-W40"]["days"]) == 5
    assert len(coordinator.store.weeks["2026-W40"]["content_hashes"]) == 2
    assert len(calls) == 1


async def test_a_mail_that_would_shrink_a_stored_week_is_refused_once(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer, caplog
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.messages.append(mail("2", TEACHER_B, "Speiseplan KW40", b"degraded", "degraded.pdf"))
    extract, parsed = _by_payload({b"degraded": _monday_only()})

    with patch(EXTRACT, extract):
        await _poll(hass, coordinator)
        await _poll(hass, coordinator)

    assert len(coordinator.store.weeks["2026-W40"]["days"]) == 5
    assert hass.states.get(TODAY).state == "Chili sin Carne mit Sauer Sahne"
    assert parsed == [b"degraded"]
    assert caplog.text.count("Not importing degraded.pdf") == 1
    notice = _notifications(hass)[NOTIFICATION_ERROR_ID]["message"]
    assert "degraded.pdf" in notice
    assert "fewer_days" in notice


async def test_a_manual_import_may_shrink_a_week(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-28 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    studientag = ParsedWeek(
        week_start=datetime.date(2026, 9, 28),
        days=(DayMenu(date=datetime.date(2026, 9, 28), lines=("Nur Montag",)),),
        source_file="studientag.pdf",
        content_hash="studientag-bytes",
    )

    assert await coordinator.async_import_week(studientag, source="manual") is True

    assert list(coordinator.store.weeks["2026-W40"]["days"]) == ["2026-09-28"]
    assert hass.states.get(TODAY).state == "Nur Montag"


async def test_an_unparseable_attachment_is_reported_once_and_never_blocks_the_rest(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer, caplog
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer(
        [
            mail("1", TEACHER_A, "Speiseplan KW40", b"not a pdf", "kaputt.pdf"),
            mail("2", TEACHER_B, "Speiseplan KW40", pdf()),
        ]
    )
    extract, parsed = _by_payload({})

    with patch(EXTRACT, extract):
        coordinator = await setup_mailbox(hass, mail_entry, server)
        await _poll(hass, coordinator)

    assert hass.states.get(TODAY).state == "Chili sin Carne mit Sauer Sahne"
    assert parsed.count(b"not a pdf") == 1
    assert caplog.text.count("Not importing kaputt.pdf") == 1
    assert "kaputt.pdf" in _notifications(hass)[NOTIFICATION_ERROR_ID]["message"]
    assert NOTIFICATION_IMAP_ID not in _notifications(hass)


async def test_any_library_error_on_a_malformed_pdf_is_a_parse_failure(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    before = {key: dict(value) for key, value in coordinator.store.weeks.items()}
    server.messages.append(mail("2", TEACHER_B, "Speiseplan KW41", b"%PDF-1.7 broken"))

    with patch("pypdf.PdfReader", side_effect=KeyError("/Root")):
        await _poll(hass, coordinator)

    assert coordinator.last_update_success is True
    assert coordinator.store.weeks == before
    assert NOTIFICATION_ERROR_ID in _notifications(hass)


async def test_a_subject_week_that_disagrees_with_the_header_warns_and_the_header_wins(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer, caplog
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW17", pdf())])

    coordinator = await setup_mailbox(hass, mail_entry, server)

    assert list(coordinator.store.weeks) == ["2026-W40"]
    assert "KW17" in caplog.text
    assert "header wins" in caplog.text


async def test_a_pdf_with_no_readable_header_falls_back_to_the_subject_week(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    headerless = ["WOCHENPLAN", "MONTAG", "Pasta mit Tomaten Sauce dazu Parmesan (1a, 3)", "Obst"]

    with patch(EXTRACT, return_value=headerless):
        coordinator = await setup_mailbox(hass, mail_entry, server)

    assert list(coordinator.store.weeks) == ["2026-W40"]
    assert coordinator.store.weeks["2026-W40"]["days"]["2026-09-28"]["lines"][0] == (
        "Pasta mit Tomaten Sauce dazu Parmesan"
    )


async def test_without_a_subject_week_a_headerless_pdf_is_skipped(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW", pdf())])

    with patch(EXTRACT, return_value=["WOCHENPLAN", "MONTAG", "Pasta", "Obst"]):
        coordinator = await setup_mailbox(hass, mail_entry, server)

    assert coordinator.store.weeks == {}


async def test_the_attachment_is_parsed_off_the_event_loop(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.messages = [mail("1", TEACHER_A, "Speiseplan KW40", pdf())]
    threads: list[str] = []

    def _spy(payload):
        threads.append(threading.current_thread().name)
        return extract_lines(payload)

    with patch(EXTRACT, _spy):
        await _poll(hass, coordinator)

    assert threads
    assert "MainThread" not in threads


async def test_credentials_never_reach_the_log_or_diagnostics(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer, caplog
) -> None:
    from custom_components.school_menu.diagnostics import async_get_config_entry_diagnostics

    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    await setup_mailbox(hass, mail_entry, server)

    diagnostics = await async_get_config_entry_diagnostics(hass, mail_entry)

    for secret in ("hunter2", "parent@example.org"):
        assert secret not in caplog.text
        assert secret not in str(diagnostics)
    assert diagnostics["data"]["password"] == "**REDACTED**"
    assert diagnostics["data"]["username"] == "**REDACTED**"
