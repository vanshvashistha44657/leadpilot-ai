from __future__ import annotations

import json

import pytest

from app.services.http_transport import HttpResponse


def response(payload: dict, status_code: int = 200) -> HttpResponse:
    return HttpResponse(status_code=status_code, headers={}, body=json.dumps(payload).encode())


class FakeTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def request(self, method, url, *, headers=None, body=None, timeout):
        self.calls.append({"method": method, "url": url, "body": body, "timeout": timeout})
        value = self.responses.pop(0)
        if isinstance(value, Exception):
            raise value
        return value


def test_suppressed_lead_cannot_generate_draft(client):
    headers = {"X-Local-Token": "test-token"}
    lead = client.post("/api/leads", headers=headers, json={"email": "blocked@example.com", "company": "Acme"})
    assert lead.status_code == 201
    client.post("/api/suppressions", headers=headers, json={"email": "blocked@example.com", "reason": "opt out"})

    result = client.post("/api/drafts/generate", headers=headers, json={"lead_id": lead.json()["id"], "offer": "websites", "call_to_action": "Reply"})
    assert result.status_code == 409


def test_draft_generation_is_structured_editable_and_does_not_send(client, monkeypatch):
    headers = {"X-Local-Token": "test-token"}
    lead = client.post("/api/leads", headers=headers, json={"email": "ada@example.com", "first_name": "Ada", "company": "Analytical Engines", "source": "csv"})
    assert lead.status_code == 201
    monkeypatch.setenv("AI_PROVIDER", "test-llm")
    monkeypatch.setenv("AI_MODEL", "test-model")
    monkeypatch.setenv("AI_BASE_URL", "https://llm.example.test/v1")
    monkeypatch.setenv("AI_API_KEY", "secret-key")
    client.app.state.services.ai.registry.transport = FakeTransport([response({"id": "draft-1", "choices": [{"message": {"content": '{"subject":"A useful idea","body":"Hi Ada","personalization_summary":"Uses supplied fields"}'}}], "usage": {"total_tokens": 8}})])

    generated = client.post("/api/drafts/generate", headers=headers, json={"lead_id": lead.json()["id"], "offer": "websites", "call_to_action": "Reply", "tone": "professional"})
    assert generated.status_code == 200
    assert generated.json()["status"] == "generated"
    assert "secret-key" not in generated.text
    request_body = json.loads(client.app.state.services.ai.registry.transport.calls[0]["body"])
    assert "Never invent company facts" in request_body["messages"][1]["content"]
    assert "Analytical Engines" in request_body["messages"][1]["content"]
    draft_id = generated.json()["id"]

    edited = client.patch(f"/api/drafts/{draft_id}", headers=headers, json={"subject": "Edited subject", "body": "Edited body"})
    assert edited.status_code == 200
    assert edited.json()["status"] == "edited"
    assert edited.json()["generated_body"] == "Hi Ada"


def test_duplicate_draft_generation_returns_existing_without_second_provider_call(client, monkeypatch):
    headers = {"X-Local-Token": "test-token"}
    lead = client.post("/api/leads", headers=headers, json={"email": "repeat@example.com"})
    monkeypatch.setenv("AI_PROVIDER", "test-llm")
    monkeypatch.setenv("AI_MODEL", "test-model")
    monkeypatch.setenv("AI_API_KEY", "secret-key")
    transport = FakeTransport([response({"choices": [{"message": {"content": '{"subject":"Subject","body":"Body"}'}}]})])
    client.app.state.services.ai.registry.transport = transport
    payload = {"lead_id": lead.json()["id"], "offer": "websites", "call_to_action": "Reply"}
    first = client.post("/api/drafts/generate", headers=headers, json=payload)
    second = client.post("/api/drafts/generate", headers=headers, json=payload)
    assert first.status_code == second.status_code == 200
    assert len(transport.calls) == 1


def test_unavailable_generation_persists_failed_draft_and_lists_by_status(client, monkeypatch):
    headers = {"X-Local-Token": "test-token"}
    for key in ("AI_PROVIDER", "AI_MODEL", "AI_BASE_URL", "AI_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    lead = client.post("/api/leads", headers=headers, json={"email": "unavailable@example.com"})

    result = client.post(
        "/api/drafts/generate",
        headers=headers,
        json={"lead_id": lead.json()["id"], "offer": "websites", "tone": "warm", "call_to_action": "Reply"},
    )

    assert result.status_code == 503
    assert "AI draft generation unavailable" in result.json()["detail"]
    failed = client.get("/api/drafts", headers=headers, params={"status": "failed"})
    assert failed.status_code == 200
    assert len(failed.json()) == 1
    row = failed.json()[0]
    assert row["status"] == "failed"
    assert row["lead_id"] == lead.json()["id"]
    assert row["offer"] == "websites"
    assert row["tone"] == "warm"
    assert row["call_to_action"] == "Reply"
    assert row["error"] == "AI provider is not configured"
    assert row["subject"]
    assert row["body"]
    assert row["generated_subject"]
    assert row["generated_body"]


def test_rate_limited_generation_persists_failed_draft_and_preserves_http_error(client):
    headers = {"X-Local-Token": "test-token"}
    lead = client.post("/api/leads", headers=headers, json={"email": "limited@example.com"})
    client.app.state.services.draft_service._max_per_minute = 0

    result = client.post(
        "/api/drafts/generate",
        headers=headers,
        json={"lead_id": lead.json()["id"], "offer": "websites", "call_to_action": "Reply"},
    )

    assert result.status_code == 429
    assert "rate limit" in result.json()["detail"]
    failed = client.get("/api/drafts", headers=headers, params={"status": "failed"})
    assert failed.status_code == 200
    assert failed.json()[0]["error"] == "AI draft generation rate limit reached; try again shortly"


def test_regeneration_failure_persists_failed_draft_with_previous_content(client, monkeypatch):
    headers = {"X-Local-Token": "test-token"}
    monkeypatch.setenv("AI_PROVIDER", "test-llm")
    monkeypatch.setenv("AI_MODEL", "test-model")
    monkeypatch.setenv("AI_BASE_URL", "https://llm.example.test/v1")
    monkeypatch.setenv("AI_API_KEY", "secret-key")
    monkeypatch.setenv("AI_MAX_RETRIES", "0")
    lead = client.post("/api/leads", headers=headers, json={"email": "regenerate@example.com", "first_name": "Pat"})
    transport = FakeTransport(
        [
            response({"choices": [{"message": {"content": '{"subject":"Original subject","body":"Original body"}'}}]}),
            response({"error": {"message": "provider overloaded"}}, status_code=500),
        ]
    )
    client.app.state.services.ai.registry.transport = transport
    payload = {"lead_id": lead.json()["id"], "offer": "websites", "tone": "professional", "call_to_action": "Reply"}

    generated = client.post("/api/drafts/generate", headers=headers, json=payload)
    assert generated.status_code == 200
    edited = client.patch(
        f"/api/drafts/{generated.json()['id']}",
        headers=headers,
        json={"subject": "Edited subject", "body": "Edited body"},
    )
    assert edited.status_code == 200

    failed = client.post("/api/drafts/generate", headers=headers, json={**payload, "regenerate": True, "offer": "new offer"})

    assert failed.status_code == 502
    assert "AI draft generation provider error: provider overloaded" == failed.json()["detail"]
    listed = client.get("/api/drafts", headers=headers, params={"status": "failed"})
    assert listed.status_code == 200
    row = listed.json()[0]
    assert row["status"] == "failed"
    assert row["subject"] == "Edited subject"
    assert row["body"] == "Edited body"
    assert row["generated_subject"] == "Original subject"
    assert row["generated_body"] == "Original body"
    assert row["offer"] == "new offer"
    assert row["error"] == "provider overloaded"
