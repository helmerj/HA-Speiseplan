from __future__ import annotations

import json
from datetime import timedelta
from pathlib import Path

import aiohttp
import pytest
from homeassistant.components import persistent_notification
from homeassistant.components.update import DATA_COMPONENT
from homeassistant.const import STATE_OFF, STATE_ON, STATE_UNKNOWN
from homeassistant.core import HomeAssistant, State
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers import entity_registry as er
from homeassistant.helpers.entity import EntityCategory
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import (
    MockConfigEntry,
    async_fire_time_changed,
    async_mock_service,
    mock_restore_cache,
)
from pytest_homeassistant_custom_component.test_util.aiohttp import AiohttpClientMocker

from custom_components.school_menu.const import (
    GITHUB_LATEST_RELEASE_URL,
    GITHUB_REPOSITORY_ID,
    NOTIFICATION_UPDATE_ID,
)

ENTITY = "update.school_menu_version"
MANIFEST = Path(__file__).parents[1] / "custom_components" / "school_menu" / "manifest.json"
INSTALLED = json.loads(MANIFEST.read_text())["version"]
RELEASE_URL = "https://github.com/helmerj/HA-Speiseplan/releases/tag/v99.0.0"


@pytest.fixture
def no_release_check():
    yield


def _release(tag: str = "v99.0.0", body: str | None = "## Neu\n* Logo") -> dict:
    return {
        "tag_name": tag,
        "html_url": f"https://github.com/helmerj/HA-Speiseplan/releases/tag/{tag}",
        "body": body,
        "draft": False,
        "prerelease": False,
    }


def _notifications(hass: HomeAssistant) -> dict:
    return persistent_notification._async_get_or_create_notifications(hass)


async def _setup(hass: HomeAssistant, entry: MockConfigEntry) -> None:
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()


async def _recheck(hass: HomeAssistant) -> None:
    async_fire_time_changed(hass, dt_util.utcnow() + timedelta(hours=6, seconds=1))
    await hass.async_block_till_done()


def _entity(hass: HomeAssistant):
    return hass.data[DATA_COMPONENT].get_entity(ENTITY)


async def test_a_newer_release_turns_the_entity_on_and_is_announced(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release())

    await _setup(hass, config_entry)

    state = hass.states.get(ENTITY)
    assert state.state == STATE_ON
    assert state.attributes["installed_version"] == INSTALLED
    assert state.attributes["latest_version"] == "99.0.0"
    assert state.attributes["release_url"] == RELEASE_URL
    assert state.attributes["title"] == "School Menu"
    notification = _notifications(hass)[NOTIFICATION_UPDATE_ID]
    assert "99.0.0" in notification["message"]
    assert INSTALLED in notification["message"]
    assert RELEASE_URL in notification["message"]
    request = aioclient_mock.mock_calls[0]
    assert request[3]["Accept"] == "application/vnd.github+json"
    assert "User-Agent" in request[3]


async def test_a_dismissed_announcement_does_not_return_for_the_same_version(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release())
    await _setup(hass, config_entry)
    persistent_notification.async_dismiss(hass, NOTIFICATION_UPDATE_ID)

    await _recheck(hass)

    assert aioclient_mock.call_count == 2
    assert hass.states.get(ENTITY).state == STATE_ON
    assert NOTIFICATION_UPDATE_ID not in _notifications(hass)


async def test_a_still_newer_release_is_announced_again(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release())
    await _setup(hass, config_entry)
    persistent_notification.async_dismiss(hass, NOTIFICATION_UPDATE_ID)
    aioclient_mock.clear_requests()
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release("v99.1.0"))

    await _recheck(hass)

    assert hass.states.get(ENTITY).attributes["latest_version"] == "99.1.0"
    assert "99.1.0" in _notifications(hass)[NOTIFICATION_UPDATE_ID]["message"]


@pytest.mark.parametrize("tag", [f"v{INSTALLED}", INSTALLED, "v0.0.1"])
async def test_the_installed_or_an_older_release_is_off_and_clears_the_notice(
    hass: HomeAssistant,
    config_entry: MockConfigEntry,
    aioclient_mock: AiohttpClientMocker,
    tag: str,
) -> None:
    persistent_notification.async_create(
        hass, "alt", title="School Menu", notification_id=NOTIFICATION_UPDATE_ID
    )
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release(tag))

    await _setup(hass, config_entry)

    assert hass.states.get(ENTITY).state == STATE_OFF
    assert NOTIFICATION_UPDATE_ID not in _notifications(hass)


@pytest.mark.parametrize(
    "mock",
    [
        {"exc": aiohttp.ClientError("down")},
        {"exc": TimeoutError()},
        {"status": 403, "json": {"message": "API rate limit exceeded"}},
        {"status": 429},
        {"status": 404, "json": {"message": "Not Found"}},
        {"status": 500},
        {"text": "<html>not json</html>"},
        {"json": []},
        {"json": {"tag_name": ""}},
        {"json": {"name": "no tag"}},
    ],
    ids=[
        "client-error",
        "timeout",
        "rate-limit-403",
        "rate-limit-429",
        "no-release-404",
        "server-error",
        "not-json",
        "json-list",
        "empty-tag",
        "missing-tag",
    ],
)
async def test_a_failed_check_is_quiet(
    hass: HomeAssistant,
    config_entry: MockConfigEntry,
    aioclient_mock: AiohttpClientMocker,
    caplog: pytest.LogCaptureFixture,
    mock: dict,
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, **mock)

    await _setup(hass, config_entry)

    assert hass.states.get(ENTITY).state == STATE_UNKNOWN
    assert NOTIFICATION_UPDATE_ID not in _notifications(hass)
    loud = [
        record
        for record in caplog.records
        if record.name.startswith("custom_components.school_menu")
        and record.levelname != "DEBUG"
        and record.levelname != "INFO"
    ]
    assert not loud


async def test_a_failed_check_keeps_the_last_known_release(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release())
    await _setup(hass, config_entry)
    aioclient_mock.clear_requests()
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, exc=aiohttp.ClientError("down"))

    await _recheck(hass)

    assert aioclient_mock.call_count == 1
    assert hass.states.get(ENTITY).attributes["latest_version"] == "99.0.0"
    assert hass.states.get(ENTITY).state == STATE_ON


async def test_release_notes_are_the_release_body(
    hass: HomeAssistant,
    config_entry: MockConfigEntry,
    aioclient_mock: AiohttpClientMocker,
    hass_ws_client,
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release(body="## Neu\n* Logo"))
    await _setup(hass, config_entry)
    client = await hass_ws_client(hass)

    await client.send_json({"id": 1, "type": "update/release_notes", "entity_id": ENTITY})
    result = await client.receive_json()

    assert result["success"]
    assert result["result"] == "## Neu\n* Logo"


async def test_a_restart_does_not_announce_the_same_version_again(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    mock_restore_cache(
        hass,
        [State(ENTITY, STATE_ON, {"installed_version": INSTALLED, "latest_version": "99.0.0"})],
    )
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release())

    await _setup(hass, config_entry)

    assert hass.states.get(ENTITY).state == STATE_ON
    assert NOTIFICATION_UPDATE_ID not in _notifications(hass)


async def test_a_skipped_version_is_not_announced(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    mock_restore_cache(
        hass,
        [
            State(
                ENTITY,
                STATE_OFF,
                {
                    "installed_version": INSTALLED,
                    "latest_version": INSTALLED,
                    "skipped_version": "99.0.0",
                },
            )
        ],
    )
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release())

    await _setup(hass, config_entry)

    assert hass.states.get(ENTITY).state == STATE_OFF
    assert NOTIFICATION_UPDATE_ID not in _notifications(hass)


async def test_the_entity_is_a_config_entity_on_the_service_device(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release())
    await _setup(hass, config_entry)

    registry = er.async_get(hass)
    update = registry.async_get(ENTITY)
    sensor = registry.async_get("sensor.school_menu_today")
    assert update.entity_category is EntityCategory.CONFIG
    assert update.device_id == sensor.device_id
    assert update.unique_id == f"{config_entry.entry_id}_version"


async def test_install_hands_the_exact_tag_to_hacs(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release())
    await _setup(hass, config_entry)
    hacs = er.async_get(hass).async_get_or_create(
        "update", "hacs", str(GITHUB_REPOSITORY_ID), suggested_object_id="school_menu_update"
    )
    calls = async_mock_service(hass, "update", "install")

    await _entity(hass).async_install(None, False)

    assert len(calls) == 1
    assert calls[0].data == {"entity_id": hacs.entity_id, "version": "v99.0.0"}


async def test_install_without_hacs_says_to_use_hacs(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release())
    await _setup(hass, config_entry)

    with pytest.raises(HomeAssistantError) as excinfo:
        await _entity(hass).async_install(None, False)

    assert excinfo.value.translation_key == "install_needs_hacs"


async def test_a_failing_hacs_install_is_reported(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release())
    await _setup(hass, config_entry)
    er.async_get(hass).async_get_or_create("update", "hacs", str(GITHUB_REPOSITORY_ID))

    async def _refuse(call) -> None:
        raise HomeAssistantError("Version already downloaded")

    hass.services.async_register("update", "install", _refuse)

    with pytest.raises(HomeAssistantError) as excinfo:
        await _entity(hass).async_install(None, False)

    assert excinfo.value.translation_key == "install_failed"
    assert excinfo.value.translation_placeholders["version"] == "99.0.0"


async def test_install_before_any_release_is_known_is_refused(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, status=500)
    await _setup(hass, config_entry)

    with pytest.raises(HomeAssistantError) as excinfo:
        await _entity(hass).async_install(None, False)

    assert excinfo.value.translation_key == "update_unknown"


async def test_unloading_stops_the_checks(
    hass: HomeAssistant, config_entry: MockConfigEntry, aioclient_mock: AiohttpClientMocker
) -> None:
    aioclient_mock.get(GITHUB_LATEST_RELEASE_URL, json=_release())
    await _setup(hass, config_entry)
    assert await hass.config_entries.async_unload(config_entry.entry_id)
    await hass.async_block_till_done()

    await _recheck(hass)

    assert aioclient_mock.call_count == 1
