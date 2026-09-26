from __future__ import annotations

import re

ALLERGEN_GROUP = re.compile(r"\s*\((?:\d{1,2}[a-e]?)(?:\s*,\s*(?:\d{1,2}[a-e]?))*\)")
SLASH_SPACING = re.compile(r"\s*/\s*")
WHITESPACE = re.compile(r"\s+")


def strip_allergen_codes(text: str) -> str:
    return ALLERGEN_GROUP.sub("", text).strip()


def clean_line(text: str) -> str:
    without_codes = strip_allergen_codes(text)
    spaced = SLASH_SPACING.sub(" / ", without_codes)
    return WHITESPACE.sub(" ", spaced).strip()
