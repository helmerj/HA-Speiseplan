from __future__ import annotations

import asyncio
from dataclasses import dataclass, field


@dataclass
class StoredMessage:
    uid: int
    raw: bytes
    sender: str


@dataclass
class RealImapServer:
    messages: list[StoredMessage] = field(default_factory=list)
    commands: list[str] = field(default_factory=list)
    connections_opened: int = 0
    connections_closed: int = 0
    selected_read_only: bool | None = None
    login_ok: bool = True
    ignore_logout: bool = False
    _server: asyncio.AbstractServer | None = None

    @property
    def port(self) -> int:
        return self._server.sockets[0].getsockname()[1]

    @property
    def live_connections(self) -> int:
        return self.connections_opened - self.connections_closed

    async def start(self) -> None:
        self._server = await asyncio.start_server(self._handle, "127.0.0.1", 0)

    async def stop(self) -> None:
        self._server.close()
        await self._server.wait_closed()

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.connections_opened += 1
        writer.write(b"* OK [CAPABILITY IMAP4rev1] fake ready\r\n")
        await writer.drain()
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                if await self._dispatch(line.decode().strip(), writer):
                    break
        finally:
            self.connections_closed += 1
            writer.close()

    async def _dispatch(self, line: str, writer: asyncio.StreamWriter) -> bool:
        self.commands.append(line)
        tag, _, rest = line.partition(" ")
        verb = rest.split(" ")[0].upper() if rest else ""

        if verb == "CAPABILITY":
            writer.write(b"* CAPABILITY IMAP4rev1\r\n")
            writer.write(f"{tag} OK CAPABILITY completed.\r\n".encode())
        elif verb == "LOGIN":
            outcome = "OK LOGIN completed." if self.login_ok else "NO [AUTHENTICATIONFAILED] nope"
            writer.write(f"{tag} {outcome}\r\n".encode())
        elif verb in ("SELECT", "EXAMINE"):
            self.selected_read_only = verb == "EXAMINE"
            writer.write(f"* {len(self.messages)} EXISTS\r\n".encode())
            writer.write(b"* OK [UIDVALIDITY 42] UIDs valid\r\n")
            suffix = "[READ-ONLY]" if verb == "EXAMINE" else "[READ-WRITE]"
            writer.write(f"{tag} OK {suffix} {verb} completed.\r\n".encode())
        elif verb == "UID" and "SEARCH" in rest.upper():
            wanted = rest.split('FROM "')[1].split('"')[0].lower() if 'FROM "' in rest else ""
            uids = [str(m.uid) for m in self.messages if wanted in m.sender.lower()]
            writer.write(f"* SEARCH {' '.join(uids)}\r\n".encode())
            writer.write(f"{tag} OK UID SEARCH completed.\r\n".encode())
        elif verb == "UID" and "FETCH" in rest.upper():
            uid = int(rest.split()[2])
            headers_only = "HEADER.FIELDS" in rest.upper()
            section = "HEADER.FIELDS (FROM SUBJECT DATE)" if headers_only else ""
            for message in self.messages:
                if message.uid == uid:
                    raw = message.raw
                    if headers_only:
                        raw = raw.split(b"\r\n\r\n", 1)[0] + b"\r\n\r\n"
                    head = f"* 1 FETCH (UID {uid} BODY[{section}] {{{len(raw)}}}\r\n"
                    writer.write(head.encode())
                    writer.write(raw)
                    writer.write(b")\r\n")
            writer.write(f"{tag} OK UID FETCH completed.\r\n".encode())
        elif verb == "CLOSE":
            writer.write(f"{tag} OK CLOSE completed.\r\n".encode())
        elif verb == "LOGOUT" and self.ignore_logout:
            return False
        elif verb == "LOGOUT":
            writer.write(b"* BYE logging out\r\n")
            writer.write(f"{tag} OK LOGOUT completed.\r\n".encode())
            await writer.drain()
            return True
        else:
            writer.write(f"{tag} BAD unknown command\r\n".encode())
        await writer.drain()
        return False
