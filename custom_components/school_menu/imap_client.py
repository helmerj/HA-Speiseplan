from __future__ import annotations

import asyncio
import datetime
import email
import logging
import re
from collections.abc import Iterable
from dataclasses import dataclass, field
from email.header import decode_header, make_header
from email.message import Message
from email.utils import getaddresses, parsedate_to_datetime
from typing import Protocol

from aioimaplib import IMAP4, IMAP4_SSL, SELECTED, AioImapException

from .const import IMAP_COMMAND_TIMEOUT_SECONDS, IMAP_TEARDOWN_TIMEOUT_SECONDS, SEARCH_WINDOW_DAYS

_LOGGER = logging.getLogger(__name__)

SUBJECT_WEEK = re.compile(r"Speiseplan\s*KW\s*(\d{1,2})", re.IGNORECASE)
PDF_CONTENT_TYPE = "application/pdf"
IMAP_DATE_FORMAT = "%d-%b-%Y"
HEADER_FETCH = "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])"
BODY_FETCH = "(BODY.PEEK[])"
UIDVALIDITY = re.compile(r"\[UIDVALIDITY (\d+)\]", re.IGNORECASE)
UNAVAILABLE = "[UNAVAILABLE]"


class ImapResponse(Protocol):
    result: str
    lines: list


class ImapClient(Protocol):
    async def wait_hello_from_server(self) -> None: ...

    async def login(self, username: str, password: str) -> ImapResponse: ...

    async def examine(self, folder: str) -> ImapResponse: ...

    async def uid_search(self, *criteria: str, charset: str | None = None) -> ImapResponse: ...

    async def uid(self, command: str, *args: str) -> ImapResponse: ...

    async def close(self) -> ImapResponse: ...

    async def logout(self) -> ImapResponse: ...


class _ExamineSelects:
    async def wait_hello_from_server(self) -> None:
        await asyncio.wait_for(self._client_task, self.timeout)
        await super().wait_hello_from_server()

    async def disconnect(self) -> None:
        transport = getattr(self.protocol, "transport", None)
        if transport is not None:
            transport.close()

    async def examine(self, mailbox: str = "INBOX"):
        response = await super().examine(mailbox)
        if response.result == "OK":
            async with self.protocol.state_condition:
                self.protocol.state = SELECTED
                self.protocol.state_condition.notify_all()
        return response


class ReadOnlyIMAP4(_ExamineSelects, IMAP4):
    pass


class ReadOnlyIMAP4SSL(_ExamineSelects, IMAP4_SSL):
    pass


class ImapAuthError(Exception):
    pass


class ImapTransportError(Exception):
    pass


@dataclass(frozen=True, slots=True)
class ImapSettings:
    host: str
    port: int
    username: str = field(repr=False)
    password: str = field(repr=False)
    ssl: bool
    folder: str
    senders: tuple[str, ...]
    subject_filter: str


@dataclass(frozen=True, slots=True)
class MailAttachment:
    filename: str
    payload: bytes
    subject: str
    sender: str
    received: datetime.datetime | None
    message_key: str | None = None

    @property
    def week_number(self) -> int | None:
        match = SUBJECT_WEEK.search(self.subject)
        return int(match[1]) if match else None

    def fallback_week_start(self) -> datetime.date | None:
        week = self.week_number
        if week is None or self.received is None:
            return None
        received = self.received.date()
        best: datetime.date | None = None
        for year in (
            received.isocalendar().year - 1,
            received.isocalendar().year,
            received.isocalendar().year + 1,
        ):
            try:
                candidate = datetime.date.fromisocalendar(year, week, 1)
            except ValueError:
                continue
            if best is None or abs((candidate - received).days) < abs((best - received).days):
                best = candidate
        return best


def decode_subject(raw: str | None) -> str:
    if not raw:
        return ""
    try:
        return str(make_header(decode_header(raw)))
    except UnicodeDecodeError, LookupError, ValueError:
        return raw


def subject_matches(subject: str, subject_filter: str) -> bool:
    return subject_filter.casefold() in subject.casefold()


def search_criteria(sender: str, today: datetime.date) -> tuple[str, ...]:
    since = (today - datetime.timedelta(days=SEARCH_WINDOW_DAYS)).strftime(IMAP_DATE_FORMAT)
    return ("SINCE", since, "FROM", f'"{sender}"')


def pdf_attachments(message: Message) -> list[tuple[str, bytes]]:
    found: list[tuple[str, bytes]] = []
    for part in message.walk():
        filename = part.get_filename()
        content_type = (part.get_content_type() or "").lower()
        is_pdf = content_type == PDF_CONTENT_TYPE or (
            filename is not None and filename.lower().endswith(".pdf")
        )
        if not is_pdf:
            continue
        payload = part.get_payload(decode=True)
        if payload:
            found.append((decode_subject(filename) or "menu.pdf", payload))
    return found


def _uids(lines: list) -> list[str]:
    for line in lines:
        text = line.decode() if isinstance(line, bytes) else str(line)
        parts = text.split()
        if parts and all(part.isdigit() for part in parts):
            return parts
    return []


def _message_bytes(lines: list) -> bytes | None:
    for line in lines:
        if isinstance(line, bytearray):
            return bytes(line)
    return None


def _uid_validity(lines: list) -> str | None:
    for line in lines:
        text = line.decode(errors="replace") if isinstance(line, bytes | bytearray) else str(line)
        match = UIDVALIDITY.search(text)
        if match:
            return match[1]
    return None


def _login_failure(response: ImapResponse) -> Exception:
    detail = " ".join(
        line.decode(errors="replace") if isinstance(line, bytes | bytearray) else str(line)
        for line in response.lines or []
    )
    if response.result == "NO" and UNAVAILABLE not in detail.upper():
        return ImapAuthError(response.result)
    return ImapTransportError(f"LOGIN: {response.result}")


def sender_addresses(raw_from: str) -> set[str]:
    return {address.lower() for _, address in getaddresses([raw_from]) if address}


def sender_allowed(raw_from: str, senders: Iterable[str]) -> bool:
    allowed = {sender.strip().lower() for sender in senders}
    return bool(sender_addresses(raw_from) & allowed)


async def _async_teardown(client: ImapClient) -> None:
    for step in ("close", "logout", "disconnect"):
        action = getattr(client, step, None)
        if action is None:
            continue
        try:
            await asyncio.wait_for(action(), IMAP_TEARDOWN_TIMEOUT_SECONDS)
        except Exception as err:
            _LOGGER.debug("Ignoring %s during IMAP teardown: %s", step, err)


async def _async_fetch(client: ImapClient, uid: str, what: str) -> Message | None:
    fetched = await client.uid("fetch", uid, what)
    if fetched.result != "OK":
        raise ImapTransportError(f"FETCH {uid}: {fetched.result}")
    raw = _message_bytes(fetched.lines)
    return email.message_from_bytes(raw) if raw is not None else None


def _received(message: Message) -> datetime.datetime | None:
    if not message.get("Date"):
        return None
    try:
        return parsedate_to_datetime(message["Date"])
    except TypeError, ValueError:
        return None


async def _async_collect(
    client: ImapClient,
    settings: ImapSettings,
    today: datetime.date,
    seen: set[str],
) -> list[MailAttachment]:
    await client.wait_hello_from_server()

    response = await client.login(settings.username, settings.password)
    if response.result != "OK":
        raise _login_failure(response)

    opened = await client.examine(settings.folder)
    if opened.result != "OK":
        raise ImapTransportError(f"EXAMINE {settings.folder}: {opened.result}")
    validity = _uid_validity(opened.lines)

    found: set[str] = set()
    for sender in settings.senders:
        search = await client.uid_search(*search_criteria(sender, today), charset=None)
        if search.result != "OK":
            raise ImapTransportError(f"SEARCH {sender}: {search.result}")
        found.update(_uids(search.lines))

    attachments: list[MailAttachment] = []
    for uid in sorted(found, key=int):
        key = f"{validity}:{uid}" if validity is not None else None
        if key is not None and key in seen:
            continue
        headers = await _async_fetch(client, uid, HEADER_FETCH)
        if headers is None:
            continue
        subject = decode_subject(headers.get("Subject"))
        raw_from = headers.get("From") or ""
        if not subject_matches(subject, settings.subject_filter):
            _LOGGER.debug("Ignoring uid %s, subject does not match", uid)
        elif not sender_allowed(raw_from, settings.senders):
            _LOGGER.debug("Ignoring uid %s, sender address does not match", uid)
        else:
            message = await _async_fetch(client, uid, BODY_FETCH)
            if message is None:
                continue
            found_pdf = False
            for filename, payload in pdf_attachments(message):
                found_pdf = True
                attachments.append(
                    MailAttachment(
                        filename=filename,
                        payload=payload,
                        subject=subject,
                        sender=decode_subject(raw_from),
                        received=_received(message),
                        message_key=key,
                    )
                )
            if found_pdf:
                continue
        if key is not None:
            seen.add(key)
    return attachments


async def async_fetch_candidates(
    client: ImapClient,
    settings: ImapSettings,
    today: datetime.date,
    seen: set[str] | None = None,
) -> list[MailAttachment]:
    try:
        return await _async_collect(client, settings, today, seen if seen is not None else set())
    except ImapAuthError, ImapTransportError:
        raise
    except AioImapException as err:
        raise ImapTransportError(f"{type(err).__name__}: {err}") from err
    finally:
        await _async_teardown(client)


def create_client(settings: ImapSettings) -> ReadOnlyIMAP4:
    if settings.ssl:
        from homeassistant.util.ssl import client_context

        return ReadOnlyIMAP4SSL(
            host=settings.host,
            port=settings.port,
            ssl_context=client_context(),
            timeout=IMAP_COMMAND_TIMEOUT_SECONDS,
        )
    return ReadOnlyIMAP4(
        host=settings.host, port=settings.port, timeout=IMAP_COMMAND_TIMEOUT_SECONDS
    )
