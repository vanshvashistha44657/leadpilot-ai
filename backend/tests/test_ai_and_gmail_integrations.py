from __future__ import annotations

import json
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest

from app.models import AIPersonalizationRequest, BriefRequest
from app.services.ai import AIConfig, AIProviderError, AIUnavailableError, HttpLLMProvider
from app.services.gmail import (
    GmailApiAdapter,
    GmailConfig,
    GmailLiveSendBlocked,
    GmailUnavailableError,
    GmailMessage,
    GmailService,
    GmailToken,
)
from app.services.http_transport import HttpResponse


class FakeTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls: list[dict] = []

    def request(self, method, url, *, headers=None, body=None, timeout):
        self.calls.append({"method": method, "url": url, "headers": headers or {}, "body": body, "timeout": timeout})
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class MemoryTokenStore:
    def __init__(self, token: GmailToken | None = None):
        self.token = token

    def load(self):
        return self.token

    def save(self, token):
        self.token = token


def response(payload: dict, status_code: int = 200) -> HttpResponse:
    return HttpResponse(status_code=status_code, headers={}, body=json.dumps(payload).encode())


def ai_config(**overrides) -> AIConfig:
    values = {
        "provider": "test-llm",
        "model": "test-model",
        "base_url": "https://llm.example.test/v1",
        "api_key": "test-key-only",
        "timeout_seconds": 3,
        "max_retries": 1,
        "retry_backoff_seconds": 0,
    }
    values.update(overrides)
    return AIConfig(**values)


def gmail_config(**overrides) -> GmailConfig:
    values = {
        "client_id": "test-client-id",
        "client_secret": "test-client-secret",
        "refresh_token": "test-refresh-token",
        "redirect_uri": "http://127.0.0.1:8000/api/gmail/oauth/callback",
        "sender_email": "sender@example.test",
        "token_path": Path("C:/outside-repo/gmail-tokens.json"),
        "retry_backoff_seconds": 0,
    }
    values.update(overrides)
    return GmailConfig(**values)


def test_unconfigured_ai_is_deterministically_unavailable_without_transport_call(monkeypatch):
    for key in ("AI_PROVIDER", "AI_MODEL", "AI_BASE_URL", "AI_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    transport = FakeTransport([])
    provider = HttpLLMProvider(AIConfig.from_env(), transport=transport)

    status = provider.status()
    assert status.status == "unavailable"
    assert status.configured is False
    with pytest.raises(AIUnavailableError, match="not configured"):
        provider.personalize(
            AIPersonalizationRequest(offer="websites", call_to_action="Reply", lead={"company": "Example"})
        )
    assert transport.calls == []


def test_ai_http_provider_retries_and_returns_structured_usage_metadata():
    transport = FakeTransport(
        [
            response({"error": {"message": "temporary"}}, status_code=503),
            response(
                {
                    "id": "request-1",
                    "choices": [
                        {
                            "message": {
                                "content": '{"subject":"A useful idea","body":"Hi there","personalization_summary":"Uses the company name"}'
                            }
                        }
                    ],
                    "usage": {"prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20, "cost_usd": 0.004},
                }
            ),
        ]
    )
    provider = HttpLLMProvider(ai_config(), transport=transport)

    result = provider.personalize(
        AIPersonalizationRequest(
            offer="websites",
            call_to_action="Reply if useful",
            lead={"first_name": "Pat", "company": "Example"},
        )
    )

    assert result.output.subject == "A useful idea"
    assert result.usage.total_tokens == 20
    assert result.usage.estimated_cost_usd == 0.004
    assert result.request_id == "request-1"
    assert len(transport.calls) == 2
    assert transport.calls[0]["timeout"] == 3
    assert "Bearer test-key-only" in transport.calls[0]["headers"]["Authorization"]


def test_ai_provider_does_not_fabricate_when_provider_returns_unstructured_content():
    transport = FakeTransport(
        [response({"choices": [{"message": {"content": "I cannot produce JSON"}}]})]
    )
    provider = HttpLLMProvider(ai_config(), transport=transport)

    with pytest.raises(AIProviderError, match="non-JSON"):
        provider.classify_reply("Question", "Can you send pricing?")


def test_ai_provider_exposes_typed_reply_and_brief_operations():
    transport = FakeTransport(
        [
            response({"choices": [{"message": {"content": '{"classification":"pricing","confidence":0.9,"rationale":"Asked for pricing"}'}}]}),
            response({"choices": [{"message": {"content": '{"brief":"A concise brief","key_points":["Accurate claims"]}'}}]}),
        ]
    )
    provider = HttpLLMProvider(ai_config(), transport=transport)

    classification = provider.classify_reply("Pricing", "What does it cost?")
    brief = provider.generate_brief(
        BriefRequest(
            client_name="Example",
            offer="websites",
            target_audience="local businesses",
            call_to_action="Reply",
        )
    )

    assert classification.output.classification == "pricing"
    assert classification.output.confidence == 0.9
    assert brief.output.brief == "A concise brief"
    assert brief.output.key_points == ["Accurate claims"]


def test_unconfigured_ai_and_gmail_routes_are_explicit_and_secret_free(client, monkeypatch):
    for key in ("AI_PROVIDER", "AI_MODEL", "AI_BASE_URL", "AI_API_KEY", "GMAIL_CLIENT_ID", "GMAIL_CLIENT_SECRET", "GMAIL_REFRESH_TOKEN", "GMAIL_SENDER_EMAIL"):
        monkeypatch.delenv(key, raising=False)

    headers = {"X-Local-Token": "test-token"}
    ai_status = client.get("/api/ai/status", headers=headers)
    assert ai_status.status_code == 200
    assert ai_status.json()["status"] == "unavailable"
    assert "AI_API_KEY" not in ai_status.text

    config = client.get("/api/ai/config", headers=headers)
    assert config.status_code == 200
    assert config.json()["api_key_configured"] is False
    assert "test-key" not in config.text

    preview = client.post(
        "/api/ai/personalization/preview",
        headers=headers,
        json={"offer": "websites", "call_to_action": "Reply", "lead": {"company": "Example"}},
    )
    assert preview.status_code == 503
    assert "AI personalization unavailable" in preview.json()["detail"]

    gmail_status = client.get("/api/gmail/status", headers=headers)
    assert gmail_status.status_code == 200
    assert gmail_status.json()["configured"] is False
    assert gmail_status.json()["supports_live_send"] is False


def test_gmail_authorization_url_uses_official_endpoint_and_no_network():
    adapter = GmailApiAdapter(gmail_config(), transport=FakeTransport([]), token_store=MemoryTokenStore())

    authorization_url = adapter.authorization_url("state-value")
    parsed = urlparse(authorization_url)
    query = parse_qs(parsed.query)
    assert parsed.scheme == "https"
    assert parsed.netloc == "accounts.google.com"
    assert parsed.path == "/o/oauth2/v2/auth"
    assert query["client_id"] == ["test-client-id"]
    assert query["state"] == ["state-value"]


def test_gmail_oauth_exchange_stores_tokens_without_exposing_token_result():
    store = MemoryTokenStore()
    transport = FakeTransport([response({"access_token": "access", "refresh_token": "refresh", "expires_in": 3600, "scope": "gmail.modify"})])
    adapter = GmailApiAdapter(gmail_config(), transport=transport, token_store=store)

    result = adapter.exchange_code("authorization-code")

    assert result.has_refresh_token is True
    assert store.token is not None
    assert store.token.access_token == "access"
    assert "access_token" not in repr(result)
    assert transport.calls[0]["url"] == "https://oauth2.googleapis.com/token"
    assert transport.calls[0]["headers"]["Content-Type"] == "application/x-www-form-urlencoded"


def test_gmail_refresh_uses_stored_refresh_token_and_replaces_access_token():
    store = MemoryTokenStore(GmailToken(access_token="expired", refresh_token="stored-refresh", expires_at=0))
    transport = FakeTransport([response({"access_token": "new-access", "expires_in": 1800})])
    adapter = GmailApiAdapter(gmail_config(refresh_token=""), transport=transport, token_store=store)

    result = adapter.refresh_access_token()

    assert result.has_refresh_token is True
    assert store.token is not None
    assert store.token.access_token == "new-access"
    assert store.token.refresh_token == "stored-refresh"


def test_gmail_send_is_blocked_before_http_until_explicit_approval():
    store = MemoryTokenStore(GmailToken(access_token="access", refresh_token="refresh", expires_at=None))
    transport = FakeTransport([])
    adapter = GmailApiAdapter(gmail_config(), transport=transport, token_store=store)

    with pytest.raises(GmailLiveSendBlocked):
        adapter.send_message(GmailMessage("recipient@example.test", "Subject", "Body"))
    assert transport.calls == []
    assert adapter.status().supports_live_send is False


def test_gmail_profile_draft_and_thread_sync_use_typed_offline_transport():
    store = MemoryTokenStore(GmailToken(access_token="access", refresh_token="refresh", expires_at=None))
    transport = FakeTransport(
        [
            response({"emailAddress": "sender@example.test", "messagesTotal": 4, "threadsTotal": 2}),
            response({"id": "draft-1", "message": {"threadId": "thread-1"}}),
            response({"threads": [{"id": "thread-1", "snippet": "Hello", "historyId": "9"}], "nextPageToken": "next"}),
        ]
    )
    adapter = GmailApiAdapter(gmail_config(), transport=transport, token_store=store)

    identity = adapter.sender_identity()
    draft = adapter.create_draft(GmailMessage("recipient@example.test", "Subject", "Body"))
    page = adapter.sync_threads(max_results=1)

    assert identity.email_address == "sender@example.test"
    assert draft.draft_id == "draft-1"
    assert page.threads[0].thread_id == "thread-1"
    assert page.next_page_token == "next"
    assert len(transport.calls) == 3
    assert all(call["url"].startswith("https://gmail.googleapis.com/gmail/v1/") for call in transport.calls)


def test_ai_preview_records_usage_without_exposing_api_key(client, monkeypatch):
    monkeypatch.setenv("AI_PROVIDER", "test-llm")
    monkeypatch.setenv("AI_MODEL", "test-model")
    monkeypatch.setenv("AI_BASE_URL", "https://llm.example.test/v1")
    monkeypatch.setenv("AI_API_KEY", "secret-key")
    client.app.state.services.ai.registry.transport = FakeTransport([
        response({
            "id": "usage-request",
            "choices": [{"message": {"content": '{"subject":"A useful idea","body":"Hi there"}'}}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 7, "total_tokens": 12, "cost_usd": 0.01},
        })
    ])

    headers = {"X-Local-Token": "test-token"}
    response_value = client.post(
        "/api/ai/personalization/preview",
        headers=headers,
        json={"offer": "websites", "call_to_action": "Reply", "lead": {"company": "Example"}},
    )
    assert response_value.status_code == 200
    assert "secret-key" not in response_value.text

    usage = client.get("/api/ai/usage", headers=headers)
    assert usage.status_code == 200
    assert usage.json() == {"requests": 1, "total_tokens": 12, "estimated_cost_usd": 0.01}


def test_gmail_service_requires_registered_oauth_state_and_stores_exchange_token(monkeypatch):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client")
    monkeypatch.setenv("GMAIL_CLIENT_SECRET", "secret")
    monkeypatch.setenv("GMAIL_SENDER_EMAIL", "sender@example.test")
    store = MemoryTokenStore()
    transport = FakeTransport([response({"access_token": "access", "refresh_token": "refresh", "expires_in": 3600})])
    service = GmailService(transport=transport, token_store_factory=lambda _: store)

    service.authorization_url("state-1")
    status = service.exchange_code("code-1", "state-1")

    assert status.token_available is True
    assert store.token is not None
    with pytest.raises(GmailUnavailableError, match="missing or expired"):
        service.exchange_code("code-2", "state-1")
