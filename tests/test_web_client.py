from __future__ import annotations

import pytest
from aiohttp import ClientError
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from pytest_homeassistant_custom_component.test_util.aiohttp import AiohttpClientMocker

from custom_components.school_menu.const import DEFAULT_WEB_URL
from custom_components.school_menu.web_client import (
    Validators,
    WebFetchError,
    async_fetch_menu_pdf,
)

NO_VALIDATORS = Validators(etag=None, last_modified=None)


async def _fetch(hass: HomeAssistant, validators: Validators = NO_VALIDATORS, *, cap: int = 1000):
    return await async_fetch_menu_pdf(
        async_get_clientsession(hass), DEFAULT_WEB_URL, validators, max_bytes=cap
    )


async def test_a_200_returns_the_bytes_and_the_validators(
    hass: HomeAssistant, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(
        DEFAULT_WEB_URL,
        content=b"%PDF-1.7 menu",
        headers={"ETag": '"abc"', "Last-Modified": "Sun, 08 Nov 2026 19:27:33 GMT"},
    )

    result = await _fetch(hass)

    assert result.payload == b"%PDF-1.7 menu"
    assert result.validators == Validators(
        etag='"abc"', last_modified="Sun, 08 Nov 2026 19:27:33 GMT"
    )


async def test_the_request_bypasses_caches_and_is_conditional(
    hass: HomeAssistant, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(DEFAULT_WEB_URL, status=304)

    await _fetch(hass, Validators(etag='"abc"', last_modified="Sun, 08 Nov 2026 19:27:33 GMT"))

    headers = aioclient_mock.mock_calls[0][3]
    assert headers["Cache-Control"] == "no-cache"
    assert headers["If-None-Match"] == '"abc"'
    assert headers["If-Modified-Since"] == "Sun, 08 Nov 2026 19:27:33 GMT"


async def test_a_first_request_sends_no_conditional_headers(
    hass: HomeAssistant, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(DEFAULT_WEB_URL, content=b"%PDF")

    await _fetch(hass)

    headers = aioclient_mock.mock_calls[0][3]
    assert "If-None-Match" not in headers
    assert "If-Modified-Since" not in headers


async def test_a_304_means_not_modified_and_keeps_the_validators(
    hass: HomeAssistant, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(DEFAULT_WEB_URL, status=304)
    known = Validators(etag='"abc"', last_modified=None)

    result = await _fetch(hass, known)

    assert result.payload is None
    assert result.validators == known


@pytest.mark.parametrize("status", [403, 404, 500, 503])
async def test_an_http_error_raises(
    hass: HomeAssistant, aioclient_mock: AiohttpClientMocker, status: int
) -> None:
    aioclient_mock.get(DEFAULT_WEB_URL, status=status)

    with pytest.raises(WebFetchError, match=str(status)):
        await _fetch(hass)


@pytest.mark.parametrize("exc", [ClientError("boom"), TimeoutError()])
async def test_a_network_error_raises(
    hass: HomeAssistant, aioclient_mock: AiohttpClientMocker, exc: Exception
) -> None:
    aioclient_mock.get(DEFAULT_WEB_URL, exc=exc)

    with pytest.raises(WebFetchError):
        await _fetch(hass)


async def test_an_announced_oversize_body_is_refused(
    hass: HomeAssistant, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(DEFAULT_WEB_URL, content=b"x", headers={"Content-Length": "5000"})

    with pytest.raises(WebFetchError, match="too large"):
        await _fetch(hass, cap=1000)


async def test_an_unannounced_oversize_body_is_refused(
    hass: HomeAssistant, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(DEFAULT_WEB_URL, content=b"x" * 1001)

    with pytest.raises(WebFetchError, match="too large"):
        await _fetch(hass, cap=1000)


async def test_a_body_at_the_cap_is_accepted(
    hass: HomeAssistant, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(DEFAULT_WEB_URL, content=b"x" * 1000)

    result = await _fetch(hass, cap=1000)

    assert result.payload == b"x" * 1000
