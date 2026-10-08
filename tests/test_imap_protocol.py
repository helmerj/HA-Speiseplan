from __future__ import annotations

import asyncio
import datetime
from email.message import EmailMessage

import pytest

from custom_components.school_menu.imap_client import (
    ImapSettings,
    ReadOnlyIMAP4,
    async_fetch_candidates,
)
from tests.conftest import FIXTURES
from tests.real_imap_server import RealImapServer, StoredMessage

TEACHER_A = "Maximilian.Stollberg@annie-heuser.schule"
TEACHER_B = "Lena.Putzmann@annie-heuser.schule"


def _raw_message(sender: str, subject: str, payload: bytes) -> bytes:
    message = EmailMessage()
    message["From"] = f"Klassenlehrer <{sender}>"
    message["To"] = "parent@example.org"
    message["Subject"] = subject
    message["Date"] = "Sun, 27 Sep 2026 18:04:11 +0200"
    message.set_content("Anbei der Speiseplan.")
    message.add_attachment(
        payload, maintype="application", subtype="pdf", filename="Testplan 26-40.pdf"
    )
    return message.as_bytes().replace(b"\n", b"\r\n")


@pytest.fixture
async def imap_server(socket_enabled) -> RealImapServer:
    payload = (FIXTURES / "Testplan 26-40.pdf").read_bytes()
    server = RealImapServer(
        messages=[
            StoredMessage(
                uid=1, raw=_raw_message(TEACHER_A, "Speiseplan KW40", payload), sender=TEACHER_A
            )
        ]
    )
    await server.start()
    yield server
    await server.stop()


def _settings(port: int) -> ImapSettings:
    return ImapSettings(
        host="127.0.0.1",
        port=port,
        username="parent@example.org",
        password="hunter2",
        ssl=False,
        folder="INBOX",
        senders=(TEACHER_A, TEACHER_B),
        subject_filter="Speiseplan KW",
    )


async def test_the_real_protocol_round_trip_returns_the_attachment(
    imap_server: RealImapServer, socket_enabled
) -> None:
    client = ReadOnlyIMAP4(host="127.0.0.1", port=imap_server.port, timeout=10)

    attachments = await async_fetch_candidates(
        client, _settings(imap_server.port), datetime.date(2026, 9, 30)
    )

    assert len(attachments) == 1
    assert attachments[0].filename == "Testplan 26-40.pdf"
    assert attachments[0].payload == (FIXTURES / "Testplan 26-40.pdf").read_bytes()
    assert attachments[0].week_number == 40


async def test_the_real_session_opens_the_mailbox_read_only_and_never_mutates_it(
    imap_server: RealImapServer, socket_enabled
) -> None:
    client = ReadOnlyIMAP4(host="127.0.0.1", port=imap_server.port, timeout=10)

    await async_fetch_candidates(client, _settings(imap_server.port), datetime.date(2026, 9, 30))

    wire = " | ".join(imap_server.commands)
    assert "EXAMINE INBOX" in wire
    assert "SELECT" not in wire
    assert imap_server.selected_read_only is True
    assert "BODY.PEEK[]" in wire
    assert "BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)]" in wire
    for forbidden in ("STORE", "COPY", "MOVE", "EXPUNGE", "APPEND"):
        assert forbidden not in wire


async def test_the_real_session_is_closed_and_leaks_nothing(
    imap_server: RealImapServer, socket_enabled
) -> None:
    for _ in range(3):
        client = ReadOnlyIMAP4(host="127.0.0.1", port=imap_server.port, timeout=10)
        await async_fetch_candidates(
            client, _settings(imap_server.port), datetime.date(2026, 9, 30)
        )

    assert "LOGOUT" in " ".join(imap_server.commands)
    assert imap_server.connections_opened == 3
    assert imap_server.live_connections == 0


async def test_the_real_session_is_closed_when_the_login_is_refused(
    imap_server: RealImapServer, socket_enabled
) -> None:
    from custom_components.school_menu.imap_client import ImapAuthError

    imap_server.login_ok = False
    client = ReadOnlyIMAP4(host="127.0.0.1", port=imap_server.port, timeout=10)

    with pytest.raises(ImapAuthError):
        await async_fetch_candidates(
            client, _settings(imap_server.port), datetime.date(2026, 9, 30)
        )
    await asyncio.sleep(0)

    assert imap_server.live_connections == 0


async def test_a_processed_real_message_is_not_downloaded_twice(
    imap_server: RealImapServer, socket_enabled
) -> None:
    seen: set[str] = set()
    first = ReadOnlyIMAP4(host="127.0.0.1", port=imap_server.port, timeout=10)
    found = await async_fetch_candidates(
        first, _settings(imap_server.port), datetime.date(2026, 9, 30), seen
    )
    seen.update(attachment.message_key for attachment in found)
    imap_server.commands.clear()

    second = ReadOnlyIMAP4(host="127.0.0.1", port=imap_server.port, timeout=10)
    again = await async_fetch_candidates(
        second, _settings(imap_server.port), datetime.date(2026, 9, 30), seen
    )

    assert found[0].message_key == "42:1"
    assert again == []
    assert "FETCH" not in " ".join(imap_server.commands)


async def test_a_refused_connection_fails_fast_with_the_real_reason(socket_enabled) -> None:
    from custom_components.school_menu.imap_client import ImapTransportError

    probe = await asyncio.start_server(lambda r, w: None, "127.0.0.1", 0)
    port = probe.sockets[0].getsockname()[1]
    probe.close()
    await probe.wait_closed()
    client = ReadOnlyIMAP4(host="127.0.0.1", port=port, timeout=10)
    loop = asyncio.get_running_loop()
    started = loop.time()

    with pytest.raises((OSError, ImapTransportError)) as caught:
        await async_fetch_candidates(client, _settings(port), datetime.date(2026, 9, 30))

    assert loop.time() - started < 5
    assert str(caught.value)


@pytest.mark.parametrize("use_ssl", [True, False])
def test_the_production_factory_sets_a_timeout_and_the_cached_ssl_context(use_ssl: bool) -> None:
    import dataclasses
    from unittest.mock import patch

    from custom_components.school_menu.const import IMAP_COMMAND_TIMEOUT_SECONDS
    from custom_components.school_menu.imap_client import ReadOnlyIMAP4SSL, create_client

    settings = dataclasses.replace(_settings(993), ssl=use_ssl)
    with (
        patch.object(ReadOnlyIMAP4, "create_client") as plain,
        patch.object(ReadOnlyIMAP4SSL, "create_client") as secure,
        patch("homeassistant.util.ssl.client_context", return_value="cached-context"),
    ):
        client = create_client(settings)

    assert client.timeout == IMAP_COMMAND_TIMEOUT_SECONDS
    assert isinstance(client, ReadOnlyIMAP4SSL) is use_ssl
    if use_ssl:
        assert secure.call_args.args[-1] == "cached-context"
    else:
        assert plain.call_args.args[-1] is None


async def test_a_server_that_ignores_logout_is_still_disconnected_promptly(
    imap_server: RealImapServer, socket_enabled
) -> None:
    from unittest.mock import patch

    imap_server.ignore_logout = True
    client = ReadOnlyIMAP4(host="127.0.0.1", port=imap_server.port, timeout=10)
    loop = asyncio.get_running_loop()
    started = loop.time()

    with patch("custom_components.school_menu.imap_client.IMAP_TEARDOWN_TIMEOUT_SECONDS", 0.2):
        await async_fetch_candidates(
            client, _settings(imap_server.port), datetime.date(2026, 9, 30)
        )
    for _ in range(20):
        if imap_server.live_connections == 0:
            break
        await asyncio.sleep(0.01)

    assert loop.time() - started < 3
    assert imap_server.live_connections == 0


async def test_a_domain_sender_is_searched_by_domain_on_the_wire(
    imap_server: RealImapServer, socket_enabled
) -> None:
    import dataclasses

    settings = dataclasses.replace(
        _settings(imap_server.port), senders=("@annie-heuser.schule",), subject_filter="Speiseplan"
    )
    client = ReadOnlyIMAP4(host="127.0.0.1", port=imap_server.port, timeout=10)

    attachments = await async_fetch_candidates(client, settings, datetime.date(2026, 9, 30))

    searches = [c for c in imap_server.commands if "SEARCH" in c.upper()]
    assert len(searches) == 1
    assert 'FROM "annie-heuser.schule"' in searches[0]
    assert [a.filename for a in attachments] == ["Testplan 26-40.pdf"]
