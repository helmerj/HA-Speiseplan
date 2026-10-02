from __future__ import annotations

import re
from collections.abc import Mapping
from typing import Any

import voluptuous as vol
from homeassistant.config_entries import (
    ConfigEntry,
    ConfigFlow,
    ConfigFlowResult,
    OptionsFlow,
)
from homeassistant.core import callback
from homeassistant.helpers.selector import (
    NumberSelector,
    NumberSelectorConfig,
    NumberSelectorMode,
    SelectSelector,
    SelectSelectorConfig,
    TextSelector,
    TextSelectorConfig,
    TextSelectorType,
)

from .const import (
    CONF_FOLDER,
    CONF_HOST,
    CONF_NAME,
    CONF_PASSWORD,
    CONF_PORT,
    CONF_SCAN_INTERVAL_MINUTES,
    CONF_SENDERS,
    CONF_SSL,
    CONF_SUBJECT_FILTER,
    CONF_USERNAME,
    DEFAULT_FOLDER,
    DEFAULT_NAME,
    DEFAULT_PORT,
    DEFAULT_SCAN_INTERVAL_MINUTES,
    DEFAULT_SENDERS,
    DEFAULT_SSL,
    DEFAULT_SUBJECT_FILTER,
    DOMAIN,
    MIN_SCAN_INTERVAL_MINUTES,
    SINGLE_ENTRY_UNIQUE_ID,
)

EMAIL_ADDRESS = re.compile(r"[^@\s\"<>,;]+@[^@\s\"<>,;]+\.[^@\s\"<>,;]+")
EMAIL_DOMAIN = re.compile(r"@[^@\s\"<>,;]+\.[^@\s\"<>,;]+")

STEP_USER_SCHEMA = vol.Schema({vol.Optional(CONF_NAME, default=DEFAULT_NAME): str})

REAUTH_SCHEMA = vol.Schema(
    {vol.Required(CONF_PASSWORD): TextSelector(TextSelectorConfig(type=TextSelectorType.PASSWORD))}
)


def _mailbox_schema(current: Mapping[str, Any]) -> vol.Schema:
    return vol.Schema(
        {
            vol.Required(CONF_HOST, default=current.get(CONF_HOST, "")): str,
            vol.Required(CONF_PORT, default=current.get(CONF_PORT, DEFAULT_PORT)): NumberSelector(
                NumberSelectorConfig(min=1, max=65535, mode=NumberSelectorMode.BOX)
            ),
            vol.Required(CONF_SSL, default=current.get(CONF_SSL, DEFAULT_SSL)): bool,
            vol.Required(CONF_USERNAME, default=current.get(CONF_USERNAME, "")): str,
            vol.Optional(CONF_PASSWORD, default=""): TextSelector(
                TextSelectorConfig(type=TextSelectorType.PASSWORD)
            ),
            vol.Required(CONF_FOLDER, default=current.get(CONF_FOLDER, DEFAULT_FOLDER)): str,
            vol.Required(
                CONF_SENDERS, default=list(current.get(CONF_SENDERS, DEFAULT_SENDERS))
            ): SelectSelector(SelectSelectorConfig(options=[], multiple=True, custom_value=True)),
            vol.Required(
                CONF_SUBJECT_FILTER,
                default=current.get(CONF_SUBJECT_FILTER, DEFAULT_SUBJECT_FILTER),
            ): str,
            vol.Required(
                CONF_SCAN_INTERVAL_MINUTES,
                default=current.get(CONF_SCAN_INTERVAL_MINUTES, DEFAULT_SCAN_INTERVAL_MINUTES),
            ): NumberSelector(
                NumberSelectorConfig(
                    min=MIN_SCAN_INTERVAL_MINUTES, max=1440, mode=NumberSelectorMode.BOX
                )
            ),
        }
    )


def _normalise(user_input: dict[str, Any]) -> dict[str, Any]:
    cleaned = dict(user_input)
    cleaned[CONF_PORT] = int(cleaned[CONF_PORT])
    cleaned[CONF_SCAN_INTERVAL_MINUTES] = int(cleaned[CONF_SCAN_INTERVAL_MINUTES])
    cleaned[CONF_SENDERS] = [
        sender.strip() for sender in cleaned.get(CONF_SENDERS, []) if sender.strip()
    ]
    cleaned[CONF_HOST] = cleaned.get(CONF_HOST, "").strip()
    cleaned[CONF_SUBJECT_FILTER] = cleaned.get(CONF_SUBJECT_FILTER, "").strip()
    return cleaned


def _errors(cleaned: dict[str, Any]) -> dict[str, str]:
    if not cleaned[CONF_HOST]:
        return {CONF_HOST: "no_host"}
    if not cleaned[CONF_SENDERS]:
        return {CONF_SENDERS: "no_senders"}
    if not all(
        EMAIL_ADDRESS.fullmatch(sender) or EMAIL_DOMAIN.fullmatch(sender)
        for sender in cleaned[CONF_SENDERS]
    ):
        return {CONF_SENDERS: "invalid_sender"}
    if not cleaned[CONF_SUBJECT_FILTER]:
        return {CONF_SUBJECT_FILTER: "no_subject_filter"}
    if not cleaned[CONF_PASSWORD]:
        return {CONF_PASSWORD: "no_password"}
    return {}


class SchoolMenuConfigFlow(ConfigFlow, domain=DOMAIN):
    VERSION = 1
    MINOR_VERSION = 2

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        await self.async_set_unique_id(SINGLE_ENTRY_UNIQUE_ID)
        self._abort_if_unique_id_configured()
        if user_input is None:
            return self.async_show_form(step_id="user", data_schema=STEP_USER_SCHEMA)
        return self.async_create_entry(title=user_input[CONF_NAME], data={})

    async def async_step_reauth(self, entry_data: Mapping[str, Any]) -> ConfigFlowResult:
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        if user_input is None:
            return self.async_show_form(step_id="reauth_confirm", data_schema=REAUTH_SCHEMA)
        return self.async_update_reload_and_abort(
            self._get_reauth_entry(), data_updates={CONF_PASSWORD: user_input[CONF_PASSWORD]}
        )

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: ConfigEntry) -> OptionsFlow:
        return SchoolMenuOptionsFlow()


class SchoolMenuOptionsFlow(OptionsFlow):
    async def async_step_init(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        if user_input is None:
            return self.async_show_form(
                step_id="init", data_schema=_mailbox_schema(self.config_entry.data)
            )
        cleaned = _normalise(user_input)
        if not cleaned[CONF_PASSWORD]:
            cleaned[CONF_PASSWORD] = self.config_entry.data.get(CONF_PASSWORD, "")
        errors = _errors(cleaned)
        if errors:
            return self.async_show_form(
                step_id="init",
                data_schema=_mailbox_schema({**self.config_entry.data, **user_input}),
                errors=errors,
            )
        self.hass.config_entries.async_update_entry(
            self.config_entry, data={**self.config_entry.data, **cleaned}
        )
        self.hass.config_entries.async_schedule_reload(self.config_entry.entry_id)
        return self.async_create_entry(data={})
