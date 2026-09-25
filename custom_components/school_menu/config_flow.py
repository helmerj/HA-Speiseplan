from __future__ import annotations

from typing import Any

import voluptuous as vol
from homeassistant.config_entries import ConfigFlow, ConfigFlowResult

from .const import CONF_NAME, DEFAULT_NAME, DOMAIN, SINGLE_ENTRY_UNIQUE_ID

STEP_USER_SCHEMA = vol.Schema({vol.Optional(CONF_NAME, default=DEFAULT_NAME): str})


class SchoolMenuConfigFlow(ConfigFlow, domain=DOMAIN):
    VERSION = 1

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        await self.async_set_unique_id(SINGLE_ENTRY_UNIQUE_ID)
        self._abort_if_unique_id_configured()
        if user_input is None:
            return self.async_show_form(step_id="user", data_schema=STEP_USER_SCHEMA)
        return self.async_create_entry(title=user_input[CONF_NAME], data={})
