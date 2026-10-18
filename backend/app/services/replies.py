from __future__ import annotations

import re


_CATEGORIES = {
    "unsubscribe": ("unsubscribe", "remove me", "stop emailing", "do not contact", "opt out"),
    "bounce": ("delivery failed", "mailbox full", "user unknown", "undeliverable", "returned mail"),
    "pricing": ("pricing", "price", "cost", "quote", "budget"),
    "meeting": ("book a call", "schedule", "calendar", "meeting", "talk next week"),
    "interested": ("interested", "sounds good", "tell me more", "yes", "let's do it"),
}


def classify_reply(subject: str | None, body: str) -> str:
    text = re.sub(r"\s+", " ", f"{subject or ''} {body}".casefold()).strip()
    for category in ("unsubscribe", "bounce", "pricing", "meeting", "interested"):
        if any(phrase in text for phrase in _CATEGORIES[category]):
            return category
    return "other"
