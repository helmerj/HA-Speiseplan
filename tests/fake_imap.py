from __future__ import annotations

from dataclasses import dataclass, field
from email.message import EmailMessage

from tests.pdf_fixtures import FIXTURES, WEEK_40

TEACHER_A = "Maximilian.Stollberg@annie-heuser.schule"
TEACHER_B = "Lena.Putzmann@annie-heuser.schule"
MAILBOX = {
    "host": "imap.example.org",
    "port": 993,
    "ssl": True,
    "username": "parent@example.org",
    "password": "hunter2",
    "folder": "INBOX",
    "senders": [TEACHER_A, TEACHER_B],
    "subject_filter": "Speiseplan KW",
    "scan_interval_minutes": 15,
}
SUNDAY_EVENING = "Sun, 27 Sep 2026 18:04:11 +0200"

STARTED = "STARTED"
NONAUTH = "NONAUTH"
AUTH = "AUTH"
SELECTED = "SELECTED"
LOGOUT = "LOGOUT"


class FakeAbort(Exception):
    pass


@dataclass
class FakeResponse:
    result: str
    lines: list


@dataclass
class FakeMessage:
    uid: str
    sender: str
    subject: str
    date: str
    attachments: list[tuple[str, bytes]] = field(default_factory=list)

    def as_bytes(self) -> bytes:
        message = EmailMessage()
        message["From"] = self.sender
        message["To"] = "parent@example.org"
        message["Subject"] = self.subject
        message["Date"] = self.date
        message.set_content("Anbei der Speiseplan.")
        for filename, payload in self.attachments:
            message.add_attachment(
                payload, maintype="application", subtype="pdf", filename=filename
            )
        return message.as_bytes()


class FakeImapServer:
    def __init__(self, messages: list[FakeMessage]) -> None:
        self.messages = messages
        self.commands: list[tuple] = []
        self.flags_set: list[tuple[str, str]] = []
        self.login_result = "OK"
        self.login_lines: list = [b"auth failed"]
        self.uid_validity: str | None = None
        self.select_result = "OK"
        self.search_result = "OK"
        self.fetch_result = "OK"
        self.raise_on_fetch: Exception | None = None
        self.fail_uid: str | None = None
        self.opened = 0
        self.closed = 0
        self.read_only = True

    def client(self, _settings) -> FakeImapClient:
        self.opened += 1
        return FakeImapClient(self)

    @property
    def live_connections(self) -> int:
        return self.opened - self.closed


class FakeImapClient:
    def __init__(self, server: FakeImapServer) -> None:
        self.server = server
        self.state = STARTED

    def _require(self, *states: str) -> None:
        if self.state not in states:
            raise FakeAbort(f"command illegal in state {self.state}")

    async def wait_hello_from_server(self) -> None:
        self.server.commands.append(("hello",))
        self.state = NONAUTH

    async def login(self, username: str, password: str) -> FakeResponse:
        self._require(NONAUTH)
        self.server.commands.append(("login", username))
        if self.server.login_result != "OK":
            return FakeResponse(self.server.login_result, list(self.server.login_lines))
        self.state = AUTH
        return FakeResponse("OK", [b"logged in"])

    async def examine(self, folder: str) -> FakeResponse:
        self._require(AUTH)
        self.server.commands.append(("examine", folder))
        if self.server.select_result != "OK":
            return FakeResponse(self.server.select_result, [])
        self.server.read_only = True
        self.state = SELECTED
        lines = [b"1 EXISTS"]
        if self.server.uid_validity is not None:
            lines.append(f"OK [UIDVALIDITY {self.server.uid_validity}] UIDs valid".encode())
        return FakeResponse("OK", lines)

    async def select(self, folder: str) -> FakeResponse:
        self._require(AUTH)
        self.server.commands.append(("select", folder))
        self.server.read_only = False
        self.state = SELECTED
        return FakeResponse(self.server.select_result, [b"1 EXISTS"])

    async def uid_search(self, *criteria: str, charset: str | None = None) -> FakeResponse:
        self._require(SELECTED)
        self.server.commands.append(("uid_search", *criteria, f"charset={charset}"))
        if self.server.search_result != "OK":
            return FakeResponse(self.server.search_result, [])
        wanted = criteria[criteria.index("FROM") + 1].strip('"').lower()
        uids = [m.uid for m in self.server.messages if wanted in m.sender.lower()]
        return FakeResponse("OK", [" ".join(uids).encode(), b"Search completed."])

    async def uid(self, command: str, uid: str, *args: str) -> FakeResponse:
        self._require(SELECTED)
        self.server.commands.append(("uid", command, uid, *args))
        if command.lower() == "store":
            self.server.flags_set.append((uid, " ".join(args)))
            if self.server.read_only:
                return FakeResponse("NO", [b"mailbox is read-only"])
            return FakeResponse("OK", [])
        if self.server.raise_on_fetch is not None:
            raise self.server.raise_on_fetch
        if self.server.fetch_result != "OK" or uid == self.server.fail_uid:
            return FakeResponse("NO", [])
        if any("BODY[" in arg and "PEEK" not in arg for arg in args):
            self.server.flags_set.append((uid, "\\Seen"))
        headers_only = any("HEADER.FIELDS" in arg for arg in args)
        for message in self.server.messages:
            if message.uid == uid:
                raw = message.as_bytes()
                if headers_only:
                    raw = raw.split(b"\n\n", 1)[0] + b"\n\n"
                return FakeResponse(
                    "OK",
                    [
                        f"1 FETCH (UID {uid} BODY[] ".encode(),
                        bytearray(raw),
                        b")",
                        b"FETCH completed.",
                    ],
                )
        return FakeResponse("NO", [])

    async def close(self) -> FakeResponse:
        if self.state != SELECTED:
            raise FakeAbort(f"CLOSE illegal in state {self.state}")
        self.server.commands.append(("close",))
        self.state = AUTH
        return FakeResponse("OK", [])

    async def logout(self) -> FakeResponse:
        if self.state == STARTED:
            raise FakeAbort("LOGOUT illegal in state STARTED")
        self.server.commands.append(("logout",))
        self.state = LOGOUT
        self.server.closed += 1
        return FakeResponse("OK", [])


def pdf(name: str = WEEK_40) -> bytes:
    return (FIXTURES / name).read_bytes()


def mail(
    uid: str,
    sender: str,
    subject: str,
    payload: bytes,
    name: str = "plan.pdf",
    date: str = SUNDAY_EVENING,
) -> FakeMessage:
    return FakeMessage(
        uid=uid,
        sender=f"Klassenlehrer <{sender}>",
        subject=subject,
        date=date,
        attachments=[(name, payload)],
    )


def body_fetches(server: FakeImapServer) -> list[str]:
    return [
        c[2]
        for c in server.commands
        if c[0] == "uid" and c[1] == "fetch" and not any("HEADER.FIELDS" in a for a in c[3:])
    ]


async def setup_mailbox(hass, entry, server: FakeImapServer):
    from unittest.mock import patch

    from custom_components.school_menu.const import DOMAIN

    entry.add_to_hass(hass)
    with patch("custom_components.school_menu._imap_client_factory", server.client):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done(wait_background_tasks=True)
    return hass.data[DOMAIN][entry.entry_id]


class AlwaysFindsIt:
    def __init__(self, server: FakeImapServer) -> None:
        self._inner = FakeImapClient(server)
        self._server = server

    async def wait_hello_from_server(self):
        return await self._inner.wait_hello_from_server()

    async def login(self, username, password):
        return await self._inner.login(username, password)

    async def examine(self, folder):
        return await self._inner.examine(folder)

    async def uid_search(self, *criteria, charset=None):
        self._server.commands.append(("uid_search", *criteria))
        return FakeResponse("OK", [b"1"])

    async def uid(self, command, uid, *args):
        return await self._inner.uid(command, uid, *args)

    async def close(self):
        return await self._inner.close()

    async def logout(self):
        return await self._inner.logout()
