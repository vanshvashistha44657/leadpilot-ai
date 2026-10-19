from __future__ import annotations

from urllib.parse import urlparse


def score_verified_lead(lead: dict[str, object], website_url: str | None = None) -> int:
    """Score only operator-supplied facts; never infer business claims.

    This is deliberately deterministic until an authorized research provider is
    configured. It gives operators a useful triage score without fabricating
    website findings or contact data.
    """
    return sum(item["points"] for item in score_factors(lead, website_url).values())


def score_factors(lead: dict[str, object], website_url: str | None = None) -> dict[str, dict[str, object]]:
    factors = {
        "email": {"present": bool(lead.get("email")), "points": 10 if lead.get("email") else 0},
        "company": {"present": bool(lead.get("company")), "points": 25 if lead.get("company") else 0},
        "name": {"present": bool(lead.get("first_name") or lead.get("last_name")), "points": 10 if lead.get("first_name") or lead.get("last_name") else 0},
        "title": {"present": bool(lead.get("title")), "points": 15 if lead.get("title") else 0},
        "website_url": {"valid_http_url": bool(website_url and _is_http_url(website_url)), "points": 25 if website_url and _is_http_url(website_url) else 0},
        "source": {"present": bool(lead.get("source")), "points": 5 if lead.get("source") else 0},
    }
    factors["total"] = {"points": min(100, sum(int(item["points"]) for item in factors.values()))}
    return factors


def _is_http_url(value: str) -> bool:
    parsed = urlparse(value.strip())
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)
