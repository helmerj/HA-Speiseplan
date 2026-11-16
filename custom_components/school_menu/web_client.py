from __future__ import annotations

import asyncio
from dataclasses import dataclass
from http import HTTPStatus

import aiohttp

from .const import WEB_MAX_BYTES, WEB_TIMEOUT_SECONDS


class WebFetchError(Exception):
    pass


@dataclass(frozen=True)
class Validators:
    etag: str | None
    last_modified: str | None


@dataclass(frozen=True)
class WebFetchResult:
    payload: bytes | None
    validators: Validators


def _request_headers(validators: Validators) -> dict[str, str]:
    headers = {"Cache-Control": "no-cache"}
    if validators.etag:
        headers["If-None-Match"] = validators.etag
    if validators.last_modified:
        headers["If-Modified-Since"] = validators.last_modified
    return headers


async def async_fetch_menu_pdf(
    session: aiohttp.ClientSession,
    url: str,
    validators: Validators,
    *,
    max_bytes: int = WEB_MAX_BYTES,
) -> WebFetchResult:
    try:
        async with asyncio.timeout(WEB_TIMEOUT_SECONDS):
            async with session.get(url, headers=_request_headers(validators)) as response:
                if response.status == HTTPStatus.NOT_MODIFIED:
                    return WebFetchResult(payload=None, validators=validators)
                if response.status != HTTPStatus.OK:
                    raise WebFetchError(f"HTTP {response.status}")
                announced = response.headers.get("Content-Length")
                if announced is not None and announced.isdigit() and int(announced) > max_bytes:
                    raise WebFetchError(f"too large ({announced} bytes)")
                payload = bytearray()
                async for chunk in response.content.iter_chunked(64 * 1024):
                    payload.extend(chunk)
                    if len(payload) > max_bytes:
                        raise WebFetchError(f"too large (over {max_bytes} bytes)")
                return WebFetchResult(
                    payload=bytes(payload),
                    validators=Validators(
                        etag=response.headers.get("ETag"),
                        last_modified=response.headers.get("Last-Modified"),
                    ),
                )
    except (aiohttp.ClientError, TimeoutError) as err:
        raise WebFetchError(str(err) or type(err).__name__) from err
