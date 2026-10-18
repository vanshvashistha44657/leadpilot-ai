from __future__ import annotations

from urllib.parse import urlparse


def score_verified_lead(lead: dict[str, object], website_url: str | None = None) -> int:
    """Score only operator-supplied facts; never infer business claims.

    This is deliberately deterministic until an authorized research provider is
    configured. It gives operators a useful triage score without fabricating
    website findings or contact data.
    """
    score = 0
    if lead.get("email"):
        score += 10
    if lead.get("company"):
        score += 25
    if lead.get("first_name") or lead.get("last_name"):
        score += 10
    if lead.get("title"):
        score += 15
    if website_url and _is_http_url(website_url):
        score += 25
    if lead.get("source"):
        score += 5
    return min(100, score)


def _is_http_url(value: str) -> bool:
    parsed = urlparse(value.strip())
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)
