from __future__ import annotations

import re
from typing import Any


EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def normalize_email(value: Any) -> str:
    if value is None:
        raise ValueError("email is required")
    normalized = "".join(str(value).strip().casefold().split())
    if len(normalized) > 320 or not EMAIL_RE.fullmatch(normalized):
        raise ValueError("invalid email")
    return normalized


def clean_text(value: Any) -> str | None:
    if value is None:
        return None
    cleaned = " ".join(str(value).strip().split())
    return cleaned or None
