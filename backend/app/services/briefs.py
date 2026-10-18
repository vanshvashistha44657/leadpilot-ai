from __future__ import annotations

from ..models import BriefRequest, BriefResponse


def generate_client_brief(request: BriefRequest) -> BriefResponse:
    prompt = (
        "Create a compliant cold-outreach campaign brief for {client_name}. "
        "Focus on {target_audience}, offer {offer}, use a {tone} tone, and end with {call_to_action}. "
        "Avoid unsupported claims, include a clear opt-out, and keep personalization grounded in provided lead data."
    ).format(**request.model_dump())
    brief = (
        f"Client: {request.client_name}\n"
        f"Offer: {request.offer}\n"
        f"Audience: {request.target_audience}\n"
        f"Tone: {request.tone}\n"
        f"CTA: {request.call_to_action}\n"
        "Compliance notes: use accurate sender identity, include an unsubscribe path, and suppress opt-outs."
    )
    return BriefResponse(prompt=prompt, brief=brief)
