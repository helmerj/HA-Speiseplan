from __future__ import annotations

import datetime

import pytest
from homeassistant.components import persistent_notification
from homeassistant.core import HomeAssistant
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.coordinator import imap_settings
from custom_components.school_menu.imap_client import (
    MailAttachment,
    decode_subject,
    search_criteria,
    subject_matches,
)
from tests.fake_imap import (
    MAILBOX,
    TEACHER_A,
    TEACHER_B,
    AlwaysFindsIt,
    FakeImapServer,
    FakeMessage,
    body_fetches,
    mail,
    pdf,
    setup_mailbox,
)


def _notifications(hass: HomeAssistant) -> dict:
    return persistent_notification._async_get_or_create_notifications(hass)


def _attachment(subject: str, received: datetime.datetime | None) -> MailAttachment:
    return MailAttachment(
        filename="plan.pdf", payload=b"", subject=subject, sender=TEACHER_A, received=received
    )


def test_the_search_window_is_fourteen_days_and_names_the_sender() -> None:
    criteria = search_criteria(TEACHER_A, datetime.date(2026, 9, 28))

    assert criteria == ("SINCE", "14-Sep-2026", "FROM", f'"{TEACHER_A}"')


@pytest.mark.parametrize(
    ("subject", "expected"),
    [
        ("Speiseplan KW40", True),
        ("Fwd: Speiseplan KW 40", True),
        ("AW: speiseplan kw40 fuer naechste Woche", True),
        ("Elternbrief", False),
        ("Speiseplan", False),
    ],
)
def test_subject_matching_is_a_case_insensitive_substring(subject: str, expected: bool) -> None:
    assert subject_matches(subject, "Speiseplan KW") is expected


def test_rfc2047_subjects_are_decoded() -> None:
    assert decode_subject("=?utf-8?q?Speiseplan_KW40_f=C3=BCr_n=C3=A4chste_Woche?=") == (
        "Speiseplan KW40 für nächste Woche"
    )


def test_the_subject_week_number_is_extracted() -> None:
    attachment = _attachment(
        "Fwd: Speiseplan KW 40", datetime.datetime(2026, 9, 27, 18, 4, tzinfo=datetime.UTC)
    )

    assert attachment.week_number == 40
    assert attachment.fallback_week_start() == datetime.date(2026, 9, 28)


def test_a_subject_without_a_week_number_has_no_fallback() -> None:
    attachment = _attachment("Speiseplan", datetime.datetime(2026, 9, 27, tzinfo=datetime.UTC))

    assert attachment.week_number is None
    assert attachment.fallback_week_start() is None


def test_kw1_sent_in_late_december_means_the_coming_january() -> None:
    attachment = _attachment(
        "Speiseplan KW1", datetime.datetime(2026, 12, 27, 18, 0, tzinfo=datetime.UTC)
    )

    assert attachment.fallback_week_start() == datetime.date(2027, 1, 4)


def test_kw53_sent_in_early_january_means_the_past_december() -> None:
    attachment = _attachment(
        "Speiseplan KW53", datetime.datetime(2027, 1, 2, 9, 0, tzinfo=datetime.UTC)
    )

    assert attachment.fallback_week_start() == datetime.date(2026, 12, 28)


def test_the_settings_never_show_credentials_in_their_repr(mail_entry: MockConfigEntry) -> None:
    rendered = repr(imap_settings(mail_entry))

    assert "hunter2" not in rendered
    assert MAILBOX["username"] not in rendered


async def test_both_senders_are_searched_separately(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.commands.clear()

    await coordinator.async_refresh()

    searches = [c for c in server.commands if c[0] == "uid_search"]
    assert len(searches) == 2
    assert {c[4] for c in searches} == {f'"{TEACHER_A}"', f'"{TEACHER_B}"'}


async def test_the_mailbox_is_opened_read_only_and_never_modified(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)

    await coordinator.async_refresh()

    verbs = {c[0] for c in server.commands}
    assert "examine" in verbs
    assert "select" not in verbs
    assert server.flags_set == []
    fetches = [c for c in server.commands if c[0] == "uid"]
    assert fetches
    assert all(c[1] == "fetch" for c in fetches)
    assert all("BODY.PEEK[" in " ".join(c[3:]) for c in fetches)


async def test_only_matching_mails_are_downloaded_in_full(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer(
        [
            mail("1", TEACHER_A, "Elternbrief zur Klassenfahrt", pdf()),
            mail("2", TEACHER_B, "Speiseplan KW40", pdf()),
        ]
    )

    await setup_mailbox(hass, mail_entry, server)

    assert body_fetches(server) == ["2"]


async def test_a_processed_mail_is_not_downloaded_again(
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


async def test_a_new_uid_validity_downloads_again(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    server.uid_validity = "7"
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.commands.clear()
    server.uid_validity = "8"

    await coordinator.async_refresh()

    assert body_fetches(server) == ["1"]


async def test_without_uid_validity_nothing_is_cached(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Speiseplan KW40", pdf())])
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.commands.clear()

    await coordinator.async_refresh()

    assert body_fetches(server) == ["1"]


async def test_a_mail_whose_poll_failed_is_fetched_again(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    server.uid_validity = "7"
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.messages = [mail("1", TEACHER_A, "Speiseplan KW40", pdf())]
    server.fetch_result = "NO"
    await coordinator.async_refresh()
    server.fetch_result = "OK"

    await coordinator.async_refresh()
    await hass.async_block_till_done()

    assert "2026-W40" in coordinator.store.weeks


async def test_a_mail_downloaded_by_a_poll_that_then_failed_is_not_forgotten(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([])
    server.uid_validity = "7"
    coordinator = await setup_mailbox(hass, mail_entry, server)
    server.messages = [
        mail("1", TEACHER_A, "Speiseplan KW40", pdf()),
        mail("2", TEACHER_B, "Elternbrief", pdf()),
    ]
    server.fail_uid = "2"
    await coordinator.async_refresh()
    assert coordinator.store.weeks == {}
    server.fail_uid = None

    await coordinator.async_refresh()
    await hass.async_block_till_done()

    assert "2026-W40" in coordinator.store.weeks


async def test_a_non_matching_subject_is_ignored(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", TEACHER_A, "Elternbrief zur Klassenfahrt", pdf())])

    coordinator = await setup_mailbox(hass, mail_entry, server)

    assert coordinator.store.weeks == {}
    assert hass.states.get("sensor.school_menu_today").state == "none"


async def test_a_stranger_is_ignored_even_if_the_server_returns_the_uid(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", "spam@example.net", "Speiseplan KW40", pdf())])
    server.client = lambda _s: AlwaysFindsIt(server)

    coordinator = await setup_mailbox(hass, mail_entry, server)

    assert coordinator.store.weeks == {}
    assert body_fetches(server) == []


async def test_a_spoofed_display_name_is_rejected(
    hass: HomeAssistant, mail_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    spoof = FakeMessage(
        uid="1",
        sender=f'"{TEACHER_A}" <attacker@evil.example>',
        subject="Speiseplan KW40",
        date="Sun, 27 Sep 2026 18:04:11 +0200",
        attachments=[("plan.pdf", pdf())],
    )

    coordinator = await setup_mailbox(hass, mail_entry, FakeImapServer([spoof]))

    assert coordinator.store.weeks == {}
