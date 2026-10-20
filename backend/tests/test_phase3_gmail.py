from __future__ import annotations

import json
import socket
from concurrent.futures import ThreadPoolExecutor
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import urlopen

import pytest

from app.logging_config import JsonFormatter
from app.services.gmail import (
    GmailApiAdapter,
    GmailApiError,
    GmailConfig,
    GMAIL_COMPOSE_SCOPE,
    GmailDraft,
    GmailMessage,
    GmailSyncedMessage,
    GmailThreadData,
    GmailToken,
    GmailHistoryExpiredError,
    GmailUnavailableError,
    MemoryTokenStore,
    SecureStorageUnavailableError,
    WindowsDPAPITokenStore,
)
from app.services.http_transport import HttpResponse


class FakeTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls: list[dict] = []

    def request(self, method, url, *, headers=None, body=None, timeout):
        self.calls.append({"method": method, "url": url, "headers": headers or {}, "body": body, "timeout": timeout})
        value = self.responses.pop(0)
        if isinstance(value, Exception):
            raise value
        return value


class FakeAITransport(FakeTransport):
    pass


class FakeGmailDrafts:
    def __init__(self, result: GmailDraft | Exception | None = None):
        self.result = result or GmailDraft("provider-draft-1", "provider-thread-1")
        self.calls: list[GmailMessage] = []

    def create_draft(self, message):
        self.calls.append(message)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


class FakeGmailSync:
    def __init__(self):
        self.pages = [
            ([{"id": "thread-1", "historyId": "10", "snippet": "one"}], "next-page"),
            ([
                {"id": "thread-1", "historyId": "10", "snippet": "one"},
                {"id": "thread-2", "historyId": "11", "snippet": "two"},
            ], None),
        ]
        self.threads = {
            "thread-1": GmailThreadData(
                "thread-1",
                "10",
                "one",
                (
                    GmailSyncedMessage("message-1", "thread-1", "alice@example.com", ("sender@example.com",), "Hello", "one", "Plain body"),
                    GmailSyncedMessage("message-2", "thread-1", "unknown@example.com", ("sender@example.com",), "Unknown", "two", "Untrusted body"),
                ),
            ),
            "thread-2": GmailThreadData(
                "thread-2",
                "11",
                "two",
                (
                    GmailSyncedMessage("message-1", "thread-2", "alice@example.com", ("sender@example.com",), "Duplicate", "duplicate", "replacement"),
                    GmailSyncedMessage("message-3", "thread-2", "alice@example.com", ("bob@example.com",), "Ambiguous", "ambiguous", "body"),
                ),
            ),
        }

    def sync_threads(self, *, query=None, page_token=None, max_results=100):
        index = 1 if page_token else 0
        rows, next_token = self.pages[index]
        from app.services.gmail import GmailThreadPage, GmailThreadSummary

        return GmailThreadPage(
            tuple(GmailThreadSummary(row["id"], row["snippet"], row["historyId"]) for row in rows),
            next_token,
        )

    def get_thread(self, thread_id):
        return self.threads[thread_id]


def response(payload: dict, status_code: int = 200) -> HttpResponse:
    return HttpResponse(status_code=status_code, headers={}, body=json.dumps(payload).encode())


GMAIL_SCOPE_RESPONSE = "https://www.googleapis.com/auth/gmail.compose https://www.googleapis.com/auth/gmail.readonly"


def _callback_url(auth_response, **params):
    auth_values = parse_qs(urlparse(auth_response.json()["authorization_url"]).query)
    redirect_uri = auth_values["redirect_uri"][0]
    query = {"state": auth_values["state"][0], **params}
    return f"{redirect_uri}?{urlencode(query)}"


def _listener_port(auth_response) -> int:
    redirect_uri = parse_qs(urlparse(auth_response.json()["authorization_url"]).query)["redirect_uri"][0]
    parsed = urlparse(redirect_uri)
    assert parsed.scheme == "http"
    assert parsed.hostname == "127.0.0.1"
    assert parsed.path == ""
    assert parsed.port is not None and parsed.port > 0
    return parsed.port


def _assert_listener_closed(port: int) -> None:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            raise AssertionError("OAuth listener is still accepting connections")
    except OSError:
        return


def test_oauth_route_generates_dynamic_loopback_pkce_and_cleans_listener(client, monkeypatch):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")
    monkeypatch.delenv("GMAIL_CLIENT_SECRET", raising=False)
    monkeypatch.setenv("GMAIL_SENDER_EMAIL", "sender@example.test")
    store = MemoryTokenStore()
    transport = FakeTransport([
        response({"access_token": "access", "refresh_token": "refresh", "expires_in": 3600, "scope": GMAIL_SCOPE_RESPONSE}),
        response({"emailAddress": "sender@example.test"}),
    ])
    client.app.state.services.gmail.transport = transport
    client.app.state.services.gmail.token_store_factory = lambda _: store

    auth = client.get("/api/gmail/auth-url", headers={"X-Local-Token": "test-token"}, params={"state": "caller-state"})
    assert auth.status_code == 200
    values = parse_qs(urlparse(auth.json()["authorization_url"]).query)
    assert auth.json()["state"] != "caller-state"
    assert values["state"] == [auth.json()["state"]]
    assert values["redirect_uri"][0].startswith("http://127.0.0.1:")
    assert urlparse(values["redirect_uri"][0]).path == ""
    assert values["code_challenge_method"] == ["S256"]
    assert values["scope"] == ["https://www.googleapis.com/auth/gmail.compose https://www.googleapis.com/auth/gmail.readonly"]

    callback = urlopen(_callback_url(auth, code="authorization-code"), timeout=2)
    assert callback.status == 200
    callback_body = callback.read().decode()
    assert "access" not in callback_body
    assert "refresh" not in callback_body
    token_request = parse_qs(transport.calls[0]["body"].decode())
    assert token_request["redirect_uri"] == values["redirect_uri"]
    assert token_request["code_verifier"]
    import base64
    import hashlib

    expected_challenge = base64.urlsafe_b64encode(hashlib.sha256(token_request["code_verifier"][0].encode()).digest()).decode().rstrip("=")
    assert expected_challenge == values["code_challenge"][0]
    _assert_listener_closed(_listener_port(auth))
    assert client.get("/api/dashboard/metrics").status_code == 401


def test_legacy_fastapi_callback_is_authenticated_and_rejects_old_contract(client, monkeypatch):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")
    result = client.get(
        "/api/gmail/oauth/callback",
        params={"code": "secret-code-value", "state": "attacker-state"},
    )
    assert result.status_code == 401
    rejected = client.get(
        "/api/gmail/oauth/callback",
        headers={"X-Local-Token": "test-token"},
        params={"code": "secret-code-value", "state": "attacker-state"},
    )
    assert rejected.status_code == 410
    assert "secret-code-value" not in rejected.text
    assert "attacker-state" not in rejected.text


def test_oauth_consent_denial_is_handled_without_provider_details(client, monkeypatch):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")
    store = MemoryTokenStore()
    transport = FakeTransport([])
    client.app.state.services.gmail.transport = transport
    client.app.state.services.gmail.token_store_factory = lambda _: store
    auth = client.get("/api/gmail/auth-url", headers={"X-Local-Token": "test-token"})
    denied = urlopen(_callback_url(auth, error="access_denied"), timeout=2)
    assert denied.status == 200
    body = denied.read().decode()
    assert "access_denied" not in body
    assert "state" not in body
    assert transport.calls == []
    _assert_listener_closed(_listener_port(auth))


def test_oauth_token_exchange_rejection_is_generic_and_structured(caplog, client, monkeypatch):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")
    store = MemoryTokenStore()
    transport = FakeTransport(
        [response({"error": "invalid_grant", "error_description": "provider details"}, status_code=400)]
    )
    client.app.state.services.gmail.transport = transport
    client.app.state.services.gmail.token_store_factory = lambda _: store

    auth = client.get("/api/gmail/auth-url", headers={"X-Local-Token": "test-token"})
    values = parse_qs(urlparse(auth.json()["authorization_url"]).query)
    state = values["state"][0]
    authorization_code = "authorization-code-secret"
    with pytest.raises(HTTPError) as error:
        urlopen(f'{values["redirect_uri"][0]}?{urlencode({"state": state, "code": authorization_code})}', timeout=2)

    assert error.value.code == 400
    body = error.value.read().decode()
    assert "authorization-code-secret" not in body
    assert "provider details" not in body
    assert store.token is None
    records = [record for record in caplog.records if record.getMessage() == "gmail_oauth_callback_failed"]
    assert records
    assert records[-1].error_category == "oauth_token_exchange_rejected"
    assert records[-1].exception_class == "GmailApiError"
    assert records[-1].http_status == 400
    formatted = json.loads(JsonFormatter().format(records[-1]))
    assert formatted["error_category"] == "oauth_token_exchange_rejected"
    assert formatted["exception_class"] == "GmailApiError"
    assert formatted["http_status"] == 400
    assert authorization_code not in caplog.text
    assert state not in caplog.text
    assert "provider details" not in caplog.text
    _assert_listener_closed(urlparse(values["redirect_uri"][0]).port)


@pytest.mark.parametrize(
    ("payload", "category"),
    [
        (
            {"access_token": "access", "refresh_token": "refresh", "scope": GMAIL_COMPOSE_SCOPE},
            "token_response_missing_required_scopes",
        ),
        (
            {"access_token": "access", "scope": GMAIL_SCOPE_RESPONSE},
            "token_response_missing_refresh_token",
        ),
    ],
)
def test_oauth_callback_rejects_incomplete_token_response_without_saving(caplog, client, monkeypatch, payload, category):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")
    store = MemoryTokenStore()
    transport = FakeTransport([response(payload)])
    client.app.state.services.gmail.transport = transport
    client.app.state.services.gmail.token_store_factory = lambda _: store

    auth = client.get("/api/gmail/auth-url", headers={"X-Local-Token": "test-token"})
    values = parse_qs(urlparse(auth.json()["authorization_url"]).query)
    state = values["state"][0]
    with pytest.raises(HTTPError) as error:
        urlopen(f'{values["redirect_uri"][0]}?{urlencode({"state": state, "code": "authorization-code"})}', timeout=2)

    assert error.value.code == 400
    assert "authorization-code" not in error.value.read().decode()
    assert store.token is None
    records = [record for record in caplog.records if record.getMessage() == "gmail_oauth_callback_failed"]
    assert records[-1].error_category == category
    assert records[-1].exception_class == "GmailApiError"


def test_oauth_callback_storage_failure_is_generic_and_sanitized(caplog, client, monkeypatch):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")

    class FailingStore(MemoryTokenStore):
        def save(self, token):
            raise SecureStorageUnavailableError("storage path details")

    store = FailingStore()
    transport = FakeTransport([response({"access_token": "access", "refresh_token": "refresh", "scope": GMAIL_SCOPE_RESPONSE})])
    client.app.state.services.gmail.transport = transport
    client.app.state.services.gmail.token_store_factory = lambda _: store

    auth = client.get("/api/gmail/auth-url", headers={"X-Local-Token": "test-token"})
    values = parse_qs(urlparse(auth.json()["authorization_url"]).query)
    with pytest.raises(HTTPError) as error:
        urlopen(f'{values["redirect_uri"][0]}?{urlencode({"state": values["state"][0], "code": "authorization-code"})}', timeout=2)

    assert error.value.code == 400
    assert "storage path details" not in error.value.read().decode()
    records = [record for record in caplog.records if record.getMessage() == "gmail_oauth_callback_failed"]
    assert records[-1].error_category == "secure_storage_unavailable"
    assert records[-1].exception_class == "GmailUnavailableError"
    assert "storage path details" not in caplog.text


def test_oauth_callback_rejects_invalid_state_without_exchange_and_logs_safe_category(caplog, client, monkeypatch):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")
    transport = FakeTransport([])
    client.app.state.services.gmail.transport = transport
    client.app.state.services.gmail.token_store_factory = lambda _: MemoryTokenStore()

    auth = client.get("/api/gmail/auth-url", headers={"X-Local-Token": "test-token"})
    values = parse_qs(urlparse(auth.json()["authorization_url"]).query)
    with pytest.raises(HTTPError) as error:
        urlopen(
            f'{values["redirect_uri"][0]}?{urlencode({"state": "attacker-state", "code": "authorization-code"})}',
            timeout=2,
        )

    assert error.value.code == 400
    assert "attacker-state" not in error.value.read().decode()
    assert transport.calls == []
    records = [record for record in caplog.records if record.getMessage() == "gmail_oauth_callback_failed"]
    assert records[-1].error_category == "oauth_state_invalid"
    assert not hasattr(records[-1], "exception_class")


def test_invalid_loopback_callback_is_generic_and_closes_the_bound_listener(monkeypatch):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")
    store = MemoryTokenStore()
    transport = FakeTransport([])
    from app.services.gmail import GmailService

    service = GmailService(transport=transport, token_store_factory=lambda _: store)
    authorization_url = service.authorization_url()
    values = parse_qs(urlparse(authorization_url).query)
    port = urlparse(values["redirect_uri"][0]).port
    assert port is not None
    assert service._oauth_attempt is not None
    assert service._oauth_attempt.server.server_address[0] == "127.0.0.1"

    try:
        with pytest.raises(HTTPError) as error:
            urlopen(f"{values['redirect_uri'][0]}/wrong-root?code=secret&state=attacker", timeout=2)
        assert error.value.code == 404
        body = error.value.read().decode()
        assert "secret" not in body
        assert "attacker" not in body
        _assert_listener_closed(port)
        assert transport.calls == []
        assert service._oauth_attempt is None
    finally:
        service.close()


def test_state_expiry_and_replay_are_single_use(monkeypatch):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")
    from app.services.gmail import GmailService

    expired_service = GmailService(transport=FakeTransport([]), token_store_factory=lambda _: MemoryTokenStore())
    expired_url = expired_service.authorization_url()
    expired_state = parse_qs(urlparse(expired_url).query)["state"][0]
    attempt = expired_service._oauth_attempt
    assert attempt is not None
    expired_service._oauth_states[expired_state] = (0.0, attempt.verifier)
    expired_service._prune_oauth_states()
    with pytest.raises(GmailUnavailableError, match="missing or expired"):
        expired_service.exchange_code("code", expired_state)
    assert expired_service._oauth_attempt is None

    store = MemoryTokenStore()
    transport = FakeTransport([response({"access_token": "access", "refresh_token": "refresh", "scope": GMAIL_SCOPE_RESPONSE})])
    service = GmailService(transport=transport, token_store_factory=lambda _: store)
    try:
        authorization_url = service.authorization_url()
        state = parse_qs(urlparse(authorization_url).query)["state"][0]
        service.exchange_code("code", state)
        with pytest.raises(GmailUnavailableError, match="missing or expired"):
            service.exchange_code("replay", state)
        assert len(transport.calls) == 1
    finally:
        expired_service.close()
        service.close()


def test_new_authorization_attempt_replaces_and_closes_previous_listener(monkeypatch):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")
    from app.services.gmail import GmailService

    service = GmailService(transport=FakeTransport([]), token_store_factory=lambda _: MemoryTokenStore())
    try:
        first = service.authorization_url()
        first_port = urlparse(parse_qs(urlparse(first).query)["redirect_uri"][0]).port
        second = service.authorization_url()
        second_port = urlparse(parse_qs(urlparse(second).query)["redirect_uri"][0]).port
        assert first_port is not None and second_port is not None
        assert first_port != second_port
        _assert_listener_closed(first_port)
        assert service._oauth_attempt is not None
        assert service._oauth_attempt.redirect_uri.endswith(str(second_port))
    finally:
        service.close()


def test_concurrent_authorization_requests_leave_only_the_latest_listener(monkeypatch):
    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")
    from app.services.gmail import GmailService

    service = GmailService(transport=FakeTransport([]), token_store_factory=lambda _: MemoryTokenStore())
    try:
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(service.authorization_url) for _ in range(2)]
            urls = [future.result() for future in futures]
        ports = [urlparse(parse_qs(urlparse(url).query)["redirect_uri"][0]).port for url in urls]
        assert all(port is not None for port in ports)
        assert len(set(ports)) == 2
        assert service._oauth_attempt is not None
        active_port = urlparse(service._oauth_attempt.redirect_uri).port
        assert active_port in ports
        _assert_listener_closed(next(port for port in ports if port != active_port))
    finally:
        service.close()


@pytest.mark.parametrize(
    "payload",
    [
        {"access_token": "access", "refresh_token": "refresh", "scope": "https://www.googleapis.com/auth/gmail.compose"},
        {"access_token": "access", "scope": GMAIL_SCOPE_RESPONSE},
    ],
)
def test_token_exchange_fails_closed_before_saving_incomplete_offline_credentials(payload):
    store = MemoryTokenStore()
    transport = FakeTransport([response(payload)])
    config = GmailConfig(
        client_id="client-id",
        client_secret="",
        redirect_uri="http://127.0.0.1:49152",
    )
    adapter = GmailApiAdapter(config, transport=transport, token_store=store)
    with pytest.raises(GmailApiError):
        adapter.exchange_code("code", code_verifier="v" * 64)
    assert store.token is None


def test_authorization_code_exchange_is_not_retried_after_a_provider_failure():
    store = MemoryTokenStore()
    transport = FakeTransport([response({"error": "temporarily unavailable"}, status_code=503), response({})])
    config = GmailConfig(
        client_id="client-id",
        client_secret="",
        redirect_uri="http://127.0.0.1:49152",
        max_retries=3,
        retry_backoff_seconds=0,
    )
    adapter = GmailApiAdapter(config, transport=transport, token_store=store)

    with pytest.raises(GmailApiError) as error:
        adapter.exchange_code("code", code_verifier="v" * 64)

    assert error.value.category == "oauth_token_exchange_rejected"
    assert error.value.status_code == 503
    assert len(transport.calls) == 1
    assert store.token is None


def test_incomplete_scope_token_is_not_reported_as_connected():
    store = MemoryTokenStore(GmailToken("access", "refresh", scope=GMAIL_COMPOSE_SCOPE))
    config = GmailConfig(
        client_id="client-id",
        client_secret="",
        redirect_uri="http://127.0.0.1:49152",
    )
    status = GmailApiAdapter(config, transport=FakeTransport([]), token_store=store).status()
    assert status.configured is False
    assert status.supports_live_send is False


def test_gmail_health_uses_profile_endpoint_and_returns_safe_status():
    store = MemoryTokenStore(GmailToken("access", "refresh", scope=GMAIL_SCOPE_RESPONSE))
    transport = FakeTransport(
        [response({"emailAddress": "sender@example.test", "messagesTotal": 3, "threadsTotal": 2})]
    )
    adapter = GmailApiAdapter(
        GmailConfig(
            client_id="client",
            client_secret="secret",
            refresh_token="refresh",
            sender_email="sender@example.test",
            retry_backoff_seconds=0,
        ),
        transport=transport,
        token_store=store,
    )

    health = adapter.health_check()

    assert health.status == "healthy"
    assert health.sender_identity is not None
    assert health.sender_identity.email_address == "sender@example.test"
    assert len(transport.calls) == 1


def test_gmail_draft_provider_mutation_is_not_retried_after_transient_failure():
    store = MemoryTokenStore(GmailToken("access", "refresh", scope=GMAIL_SCOPE_RESPONSE))
    transport = FakeTransport([response({"error": "temporarily unavailable"}, status_code=503)])
    adapter = GmailApiAdapter(
        GmailConfig(
            client_id="client",
            client_secret="secret",
            refresh_token="refresh",
            sender_email="sender@example.test",
            max_retries=3,
            retry_backoff_seconds=0,
        ),
        transport=transport,
        token_store=store,
    )

    with pytest.raises(GmailApiError):
        adapter.create_draft(GmailMessage("recipient@example.test", "Subject", "Body"))

    assert len(transport.calls) == 1


def test_oauth_legacy_path_is_not_public_and_other_routes_need_token(app, monkeypatch):
    from fastapi.testclient import TestClient

    monkeypatch.setenv("GMAIL_CLIENT_ID", "client-id")
    external = TestClient(app, client=("203.0.113.10", 1234))
    callback = external.get("/api/gmail/oauth/callback", params={"code": "code", "state": "state"})
    assert callback.status_code == 403
    business = external.get("/api/gmail/status", headers={"X-Local-Token": "test-token"})
    assert business.status_code == 403


def test_secure_storage_unavailable_fails_closed_without_network_call():
    class UnavailableStore:
        def load(self):
            raise SecureStorageUnavailableError("no DPAPI")

        def save(self, token):
            raise AssertionError("must not save")

        def delete(self):
            raise AssertionError("must not delete")

    config = GmailConfig(
        client_id="client",
        client_secret="secret",
        refresh_token="refresh",
        redirect_uri="http://127.0.0.1:49152",
        sender_email="sender@example.test",
    )
    transport = FakeTransport([])
    adapter = GmailApiAdapter(config, transport=transport, token_store=UnavailableStore())
    with pytest.raises(GmailUnavailableError, match="secure Gmail token storage"):
        adapter.exchange_code("code", code_verifier="a" * 64)
    assert transport.calls == []


def test_refresh_rejected_clears_local_token_and_disconnect_revokes_when_possible():
    store = MemoryTokenStore(GmailToken("expired", "refresh-token", expires_at=0, scope=GMAIL_SCOPE_RESPONSE))
    transport = FakeTransport([response({"error": "invalid_grant"}, status_code=400)])
    config = GmailConfig(client_id="client", client_secret="secret", sender_email="sender@example.test")
    adapter = GmailApiAdapter(config, transport=transport, token_store=store)
    with pytest.raises(GmailUnavailableError, match="missing or expired"):
        adapter.refresh_access_token()
    assert store.token is None

    store = MemoryTokenStore(GmailToken("access", "refresh-token", scope=GMAIL_SCOPE_RESPONSE))
    revoke_transport = FakeTransport([response({})])
    adapter = GmailApiAdapter(config, transport=revoke_transport, token_store=store)
    assert adapter.revoke_credentials() is True
    assert store.token is None
    assert revoke_transport.calls[0]["url"] == "https://oauth2.googleapis.com/revoke"


def test_client_secret_is_optional_and_conditionally_sent_to_token_and_revoke():
    no_secret_store = MemoryTokenStore()
    no_secret_transport = FakeTransport([response({"access_token": "access", "refresh_token": "refresh", "scope": GMAIL_SCOPE_RESPONSE})])
    no_secret_adapter = GmailApiAdapter(
        GmailConfig(client_id="client", client_secret="", redirect_uri="http://127.0.0.1:49152"),
        transport=no_secret_transport,
        token_store=no_secret_store,
    )
    no_secret_adapter.exchange_code("code", code_verifier="v" * 64)
    assert "client_secret" not in parse_qs(no_secret_transport.calls[0]["body"].decode())

    secret_store = MemoryTokenStore(GmailToken("access", "refresh", scope=GMAIL_SCOPE_RESPONSE))
    secret_transport = FakeTransport([response({})])
    secret_adapter = GmailApiAdapter(
        GmailConfig(client_id="client", client_secret="secret", redirect_uri="http://127.0.0.1:49152"),
        transport=secret_transport,
        token_store=secret_store,
    )
    assert secret_adapter.revoke_credentials() is True
    assert parse_qs(secret_transport.calls[0]["body"].decode())["client_secret"] == ["secret"]


def test_dpapi_store_does_not_fallback_to_plaintext_on_non_windows(tmp_path):
    store = WindowsDPAPITokenStore(tmp_path / "tokens.bin")
    if __import__("os").name != "nt":
        with pytest.raises(SecureStorageUnavailableError):
            store.save(GmailToken("access", "refresh"))


def test_dpapi_store_round_trips_and_deletes_on_windows(tmp_path):
    if __import__("os").name != "nt":
        pytest.skip("Windows DPAPI is only available on Windows")
    store = WindowsDPAPITokenStore(tmp_path / "tokens.bin")
    store.save(GmailToken("dummy-access", "dummy-refresh", expires_at=123.0, scope=GMAIL_SCOPE_RESPONSE))
    assert store.path.read_bytes() != b'{"access_token":"dummy-access"}'
    assert store.load() == GmailToken("dummy-access", "dummy-refresh", expires_at=123.0, scope=GMAIL_SCOPE_RESPONSE)
    store.delete()
    assert not store.path.exists()


def test_reviewed_gmail_draft_is_idempotent_and_never_sends(client, monkeypatch):
    headers = {"X-Local-Token": "test-token"}
    lead = client.post("/api/leads", headers=headers, json={"email": "alice@example.com"}).json()
    monkeypatch.setenv("AI_PROVIDER", "test-llm")
    monkeypatch.setenv("AI_MODEL", "model")
    monkeypatch.setenv("AI_BASE_URL", "https://llm.example.test/v1")
    monkeypatch.setenv("AI_API_KEY", "not-returned")
    client.app.state.services.ai.registry.transport = FakeAITransport([
        response({"choices": [{"message": {"content": '{"subject":"Subject","body":"Body"}'}}]})
    ])
    generated = client.post("/api/drafts/generate", headers=headers, json={"lead_id": lead["id"], "offer": "websites", "call_to_action": "Reply"})
    assert generated.status_code == 200

    fake = FakeGmailDrafts()
    client.app.state.services.gmail_draft_workflow.gmail = fake
    first = client.post("/api/gmail/drafts/reviewed", headers=headers, json={"local_draft_id": generated.json()["id"]})
    second = client.post("/api/gmail/drafts/reviewed", headers=headers, json={"local_draft_id": generated.json()["id"]})
    assert first.status_code == second.status_code == 201
    assert first.json() == second.json() == {
        "local_draft_id": generated.json()["id"],
        "status": "created",
        "provider_draft_id": "provider-draft-1",
        "provider_thread_id": "provider-thread-1",
    }
    assert len(fake.calls) == 1
    assert "Body" not in client.get("/api/audit-log", headers=headers).text


def test_reviewed_gmail_draft_rejects_missing_or_unreviewed_local_draft(client):
    headers = {"X-Local-Token": "test-token"}
    missing = client.post("/api/gmail/drafts/reviewed", headers=headers, json={"local_draft_id": "missing"})
    assert missing.status_code == 404
    lead = client.post("/api/leads", headers=headers, json={"email": "invalid-draft@example.com"}).json()
    with client.app.state.services.database.session() as connection:
        connection.execute(
            """INSERT INTO outreach_drafts(
                   id, lead_id, status, provider, model, subject, body,
                   generated_subject, generated_body, offer, tone, call_to_action,
                   generated_at, updated_at
               ) VALUES (?, ?, 'failed', 'test', 'model', '', '', '', '', 'offer', 'tone', 'cta', datetime('now'), datetime('now'))""",
            ("failed-draft", lead["id"]),
        )
    rejected = client.post("/api/gmail/drafts/reviewed", headers=headers, json={"local_draft_id": "failed-draft"})
    assert rejected.status_code == 422


def test_reviewed_gmail_draft_rechecks_suppression_and_does_not_retry_provider_failure(client, monkeypatch):
    headers = {"X-Local-Token": "test-token"}
    lead = client.post("/api/leads", headers=headers, json={"email": "blocked-phase3@example.com"}).json()
    monkeypatch.setenv("AI_PROVIDER", "test-llm")
    monkeypatch.setenv("AI_MODEL", "model")
    monkeypatch.setenv("AI_BASE_URL", "https://llm.example.test/v1")
    monkeypatch.setenv("AI_API_KEY", "key")
    client.app.state.services.ai.registry.transport = FakeAITransport([
        response({"choices": [{"message": {"content": '{"subject":"Subject","body":"Body"}'}}]})
    ])
    generated = client.post("/api/drafts/generate", headers=headers, json={"lead_id": lead["id"], "offer": "websites", "call_to_action": "Reply"}).json()
    client.post("/api/suppressions", headers=headers, json={"email": lead["email"], "reason": "opt out"})
    fake = FakeGmailDrafts()
    client.app.state.services.gmail_draft_workflow.gmail = fake
    blocked = client.post("/api/gmail/drafts/reviewed", headers=headers, json={"local_draft_id": generated["id"]})
    assert blocked.status_code == 422
    assert fake.calls == []

    lead2 = client.post("/api/leads", headers=headers, json={"email": "provider-failure@example.com"}).json()
    client.app.state.services.ai.registry.transport = FakeAITransport([
        response({"choices": [{"message": {"content": '{"subject":"Subject 2","body":"Body 2"}'}}]})
    ])
    generated2 = client.post("/api/drafts/generate", headers=headers, json={"lead_id": lead2["id"], "offer": "websites", "call_to_action": "Reply"}).json()
    failing = FakeGmailDrafts(GmailUnavailableError("secret provider detail"))
    client.app.state.services.gmail_draft_workflow.gmail = failing
    first = client.post("/api/gmail/drafts/reviewed", headers=headers, json={"local_draft_id": generated2["id"]})
    second = client.post("/api/gmail/drafts/reviewed", headers=headers, json={"local_draft_id": generated2["id"]})
    assert first.status_code == 503
    assert second.status_code == 409
    assert len(failing.calls) == 1
    assert "secret provider detail" not in second.text


def test_gmail_sync_paginates_deduplicates_and_marks_unknown_or_ambiguous(client, monkeypatch):
    headers = {"X-Local-Token": "test-token"}
    alice = client.post("/api/leads", headers=headers, json={"email": "alice@example.com"}).json()
    client.post("/api/leads", headers=headers, json={"email": "bob@example.com"})
    fake = FakeGmailSync()
    client.app.state.services.gmail_sync_service.gmail = fake
    result = client.post("/api/gmail/sync", headers=headers, json={"max_results": 2})
    assert result.status_code == 200
    assert result.json()["pages"] == 2
    assert result.json()["threads_seen"] == 3
    assert result.json()["messages_seen"] == 4
    assert result.json()["messages_stored"] == 3
    assert result.json()["matched"] == 2
    assert result.json()["unknown"] == 1
    assert result.json()["ambiguous"] == 1
    with client.app.state.services.database.session() as connection:
        assert connection.execute("SELECT COUNT(*) FROM gmail_messages").fetchone()[0] == 3
        assert connection.execute("SELECT body FROM gmail_messages WHERE provider_message_id = 'message-2'").fetchone()[0] == "Untrusted body"
        assert connection.execute("SELECT lead_id FROM gmail_messages WHERE provider_message_id = 'message-1'").fetchone()[0] == alice["id"]


def test_gmail_sync_skips_deleted_threads_and_audits_safe_counters(client):
    headers = {"X-Local-Token": "test-token"}

    class DeletedThreadGmail:
        def sync_threads(self, **kwargs):
            from app.services.gmail import GmailThreadPage, GmailThreadSummary

            return GmailThreadPage((GmailThreadSummary("deleted-thread", "gone", "12"),), None)

        def get_thread(self, thread_id):
            raise GmailApiError("remote thread deleted", status_code=404)

    client.app.state.services.gmail_sync_service.gmail = DeletedThreadGmail()
    result = client.post("/api/gmail/sync", headers=headers, json={"max_results": 1})

    assert result.status_code == 200
    assert result.json()["threads_skipped"] == 1
    audit = client.get("/api/audit-log", headers=headers)
    assert audit.status_code == 200
    assert "gmail.sync_completed" in audit.text
    assert "remote thread deleted" not in audit.text


def test_gmail_sync_uses_incremental_history_cursor_when_available(client):
    headers = {"X-Local-Token": "test-token"}
    client.app.state.services.gmail_sync.save_state(history_id="20")

    class IncrementalGmail:
        def sync_history(self, **kwargs):
            from app.services.gmail import GmailHistoryPage

            return GmailHistoryPage(("thread-incremental",), "21", None)

        def get_thread(self, thread_id):
            return GmailThreadData(
                thread_id,
                "21",
                "incremental",
                (GmailSyncedMessage("message-incremental", thread_id, "unknown@example.com"),),
            )

        def sync_threads(self, **kwargs):
            raise AssertionError("incremental synchronization must not list all threads")

    client.app.state.services.gmail_sync_service.gmail = IncrementalGmail()
    result = client.post("/api/gmail/sync", headers=headers, json={"max_results": 1})

    assert result.status_code == 200
    assert result.json()["mode"] == "incremental"
    assert result.json()["history_id"] == "21"


def test_gmail_sync_errors_are_sanitized(client):
    class ErrorGmail:
        def sync_threads(self, **kwargs):
            raise GmailApiError("provider included secret detail")

    client.app.state.services.gmail_sync_service.gmail = ErrorGmail()
    result = client.post("/api/gmail/sync", headers={"X-Local-Token": "test-token"}, json={})
    assert result.status_code == 502
    assert result.json()["detail"] == "Gmail synchronization failed"
    assert "secret detail" not in result.text
