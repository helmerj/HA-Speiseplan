from __future__ import annotations

import datetime

import pytest
from homeassistant.core import HomeAssistant
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.school_menu.const import (
    DEFAULT_SENDERS,
    DEFAULT_SUBJECT_FILTER,
    DOMAIN,
    SINGLE_ENTRY_UNIQUE_ID,
)
from custom_components.school_menu.imap_client import search_criteria, sender_allowed
from tests.fake_imap import (
    MAILBOX,
    TEACHER_A,
    FakeImapServer,
    FakeMessage,
    mail,
    pdf,
    setup_mailbox,
)

SCHOOL = "@annie-heuser.schule"
KITCHEN_OFFICE = "Sekretariat.Kueche@annie-heuser.schule"
TODAY = "sensor.school_menu_today"


@pytest.fixture
def school_entry() -> MockConfigEntry:
    return MockConfigEntry(
        domain=DOMAIN,
        unique_id=SINGLE_ENTRY_UNIQUE_ID,
        title="School menu",
        data={**MAILBOX, "senders": [SCHOOL], "subject_filter": "Speiseplan"},
    )


def test_the_defaults_cover_the_whole_school_and_any_speiseplan_subject() -> None:
    assert DEFAULT_SENDERS == (SCHOOL,)
    assert DEFAULT_SUBJECT_FILTER == "Speiseplan"


@pytest.mark.parametrize(
    "raw_from",
    [
        f"Frau Meier <{KITCHEN_OFFICE}>",
        "maximilian.stollberg@annie-heuser.schule",
        "=?utf-8?q?J=C3=BCrgen?= <Juergen@Annie-Heuser.Schule>",
    ],
)
def test_any_address_of_the_school_domain_is_allowed(raw_from: str) -> None:
    assert sender_allowed(raw_from, [SCHOOL]) is True


@pytest.mark.parametrize(
    "raw_from",
    [
        '"annie-heuser.schule" <attacker@evil.example>',
        "Mallory <x@annie-heuser.schule.evil.example>",
        "Mallory <annie-heuser.schule@evil.example>",
        "Mallory <x@notannie-heuser.schule>",
        "Mallory <x@sub.annie-heuser.schule>",
        "@annie-heuser.schule",
        '""@annie-heuser.schule',
        'Mallory <""@annie-heuser.schule>',
        "attacker@evil.example, x@annie-heuser.schule",
        "x@annie-heuser.schule, attacker@evil.example",
        "Group: x@annie-heuser.schule;",
        "a@annie-heuser.schule, b@annie-heuser.schule",
        "",
    ],
)
def test_look_alikes_of_the_school_domain_are_rejected(raw_from: str) -> None:
    assert sender_allowed(raw_from, [SCHOOL]) is False


@pytest.mark.parametrize(
    "raw_from",
    [
        '"Maximilian Stollberg"\r\n <Maximilian.Stollberg@annie-heuser.schule>',
        "Maximilian Stollberg Klassenlehrer der Klasse 3b\n <x@annie-heuser.schule>",
        "=?utf-8?q?Sekretariat_K=C3=BCche_der_Annie-Heuser-Schule_Berlin?=\r\n\t<k@annie-heuser.schule>",
        "A <x@annie-heuser.schule>\r\n",
        "<X@ANNIE-HEUSER.SCHULE>",
    ],
)
def test_folded_or_trailing_crlf_from_headers_are_accepted(raw_from: str) -> None:
    assert sender_allowed(raw_from, [SCHOOL]) is True


def test_a_header_the_parser_rejects_counts_as_no_sender() -> None:
    assert sender_allowed('"Name\r\nX" <x@annie-heuser.schule>', [SCHOOL]) is False


def test_full_addresses_still_match_exactly() -> None:
    assert sender_allowed(f"Herr Stollberg <{TEACHER_A}>", [TEACHER_A]) is True
    assert sender_allowed(f"Frau Meier <{KITCHEN_OFFICE}>", [TEACHER_A]) is False


def test_a_domain_entry_and_an_address_entry_can_be_mixed() -> None:
    senders = ["@example.org", TEACHER_A]

    assert sender_allowed("a@example.org", senders) is True
    assert sender_allowed(TEACHER_A, senders) is True
    assert sender_allowed(KITCHEN_OFFICE, senders) is False


def test_a_domain_entry_searches_for_the_bare_domain() -> None:
    criteria = search_criteria(SCHOOL, datetime.date(2026, 10, 2))

    assert criteria == ("SINCE", "18-Sep-2026", "FROM", '"annie-heuser.schule"')


def test_an_address_entry_searches_for_the_address() -> None:
    assert search_criteria(TEACHER_A, datetime.date(2026, 10, 2))[3] == f'"{TEACHER_A}"'


async def test_a_third_school_sender_with_another_subject_is_imported(
    hass: HomeAssistant, school_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer(
        [
            mail(
                "1",
                KITCHEN_OFFICE,
                "Speiseplan für nächste Woche",
                pdf(),
                "Testplan 26-40.pdf",
            )
        ]
    )

    await setup_mailbox(hass, school_entry, server)

    assert hass.states.get(TODAY).state == "Ananas-Chili mit Kidneybohnen"
    searches = [c for c in server.commands if c[0] == "uid_search"]
    assert [c[4] for c in searches] == ['"annie-heuser.schule"']


async def test_a_speiseplan_mail_without_a_pdf_is_ignored(
    hass: HomeAssistant, school_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    question = FakeMessage(
        uid="1",
        sender=f"Eltern <{KITCHEN_OFFICE}>",
        subject="AW: Frage zum Speiseplan",
        date="Sun, 27 Sep 2026 18:04:11 +0200",
        attachments=[],
    )

    coordinator = await setup_mailbox(hass, school_entry, FakeImapServer([question]))

    assert coordinator.store.weeks == {}


async def test_a_school_mail_without_speiseplan_in_the_subject_is_ignored(
    hass: HomeAssistant, school_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    server = FakeImapServer([mail("1", KITCHEN_OFFICE, "Elternbrief Oktober", pdf())])

    coordinator = await setup_mailbox(hass, school_entry, server)

    assert coordinator.store.weeks == {}


async def test_a_stranger_with_speiseplan_and_a_pdf_is_ignored(
    hass: HomeAssistant, school_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    spoof = FakeMessage(
        uid="1",
        sender='"annie-heuser.schule" <menu@evil.example>',
        subject="Speiseplan KW40",
        date="Sun, 27 Sep 2026 18:04:11 +0200",
        attachments=[("plan.pdf", pdf())],
    )
    server = FakeImapServer([spoof])

    coordinator = await setup_mailbox(hass, school_entry, server)

    assert coordinator.store.weeks == {}


async def test_a_long_umlaut_sender_name_folded_by_the_mail_server_is_imported(
    hass: HomeAssistant, school_entry: MockConfigEntry, freezer
) -> None:
    freezer.move_to("2026-09-30 09:00:00+02:00")
    long_name = FakeMessage(
        uid="1",
        sender=(
            f"Sekretariat Küche der Annie-Heuser-Schule Berlin-Charlottenburg <{KITCHEN_OFFICE}>"
        ),
        subject="Speiseplan für nächste Woche",
        date="Sun, 27 Sep 2026 18:04:11 +0200",
        attachments=[("Testplan 26-40.pdf", pdf())],
    )
    assert b"\n " in long_name.as_bytes().split(b"Subject:")[0]

    await setup_mailbox(hass, school_entry, FakeImapServer([long_name]))

    assert hass.states.get(TODAY).state == "Ananas-Chili mit Kidneybohnen"
