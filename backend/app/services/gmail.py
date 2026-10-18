from __future__ import annotations

import base64
import json
import os
import time
from dataclasses import dataclass, field
from email.message import EmailMessage as RFCEmailMessage
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol
from urllib.parse import urlencode
from urllib.error import URLError

from ..models import GmailHealth, GmailSenderIdentity, GmailStatus, ProviderStatus
from .http_transport import HttpResponse, HttpTransport, UrllibHttpTransport


GMAIL_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GMAIL_TOKEN_URL = "https://oauth2.googleapis.com/token"
GMAIL_API_URL = "https://gmail.googleapis.com/gmail/v1"
DEFAULT_GMAIL_REDIRECT_URI = "http://127.0.0.1:8000/api/gmail/oauth/callback"
DEFAULT_GMAIL_SCOPES = ("https://www.googleapis.com/auth/gmail.modify",)
RETRYABLE_STATUS_CODES = {408, 425, 429, 500, 502, 503, 504}


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    return default if value is None else value.strip().lower() in {"1", "true", "yes", "on"}


def _env_float(name: str, default: float, minimum: float, maximum: float) -> float:
    try:
        value = float(os.getenv(name, str(default)))
    except ValueError:
        return default
    return min(max(value, minimum), maximum)


def _env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError:
        return default
    return min(max(value, minimum), maximum)


def _default_token_path() -> Path:
    """Use a per-user path, never a path inside the repository."""
    fallback = Path.home() / ".leadpilot" / "gmail_tokens.json"
    configured = os.getenv("GMAIL_TOKEN_PATH", "").strip()
    if not configured:
        return fallback
    candidate = Path(configured).expanduser()
    if not candidate.is_absolute():
        candidate = Path.home() / candidate
    candidate = candidate.resolve()
    repository = Path(__file__).resolve().parents[2]
    try:
        candidate.relative_to(repository)
    except ValueError:
        return candidate
    return fallback


@dataclass(frozen=True, slots=True)
class GmailConfig:
    client_id: str = field(default="", repr=False)
    client_secret: str = field(default="", repr=False)
    refresh_token: str = field(default="", repr=False)
    redirect_uri: str = DEFAULT_GMAIL_REDIRECT_URI
    sender_email: str = ""
    scopes: tuple[str, ...] = DEFAULT_GMAIL_SCOPES
    token_path: Path = field(default_factory=_default_token_path)
    timeout_seconds: float = 20.0
    max_retries: int = 2
    retry_backoff_seconds: float = 0.25
    live_send_approved: bool = False
    live_send_tested: bool = False

    @classmethod
    def from_env(cls) -> "GmailConfig":
        raw_scopes = os.getenv("GMAIL_SCOPES", "https://www.googleapis.com/auth/gmail.modify")
        scopes = tuple(scope.strip() for scope in raw_scopes.split() if scope.strip())
        return cls(
            client_id=os.getenv("GMAIL_CLIENT_ID", "").strip(),
            client_secret=os.getenv("GMAIL_CLIENT_SECRET", "").strip(),
            refresh_token=os.getenv("GMAIL_REFRESH_TOKEN", "").strip(),
            redirect_uri=os.getenv("GMAIL_REDIRECT_URI", DEFAULT_GMAIL_REDIRECT_URI).strip(),
            sender_email=os.getenv("GMAIL_SENDER_EMAIL", "").strip(),
            scopes=scopes or DEFAULT_GMAIL_SCOPES,
            token_path=_default_token_path(),
            timeout_seconds=_env_float("GMAIL_TIMEOUT_SECONDS", 20.0, 0.1, 300.0),
            max_retries=_env_int("GMAIL_MAX_RETRIES", 2, 0, 5),
            retry_backoff_seconds=_env_float("GMAIL_RETRY_BACKOFF_SECONDS", 0.25, 0.0, 10.0),
            live_send_approved=_env_bool("GMAIL_LIVE_SEND_APPROVED", False),
            live_send_tested=_env_bool("GMAIL_LIVE_SEND_TESTED", False),
        )

    @property
    def oauth_configured(self) -> bool:
        return bool(self.client_id and self.client_secret and self.redirect_uri)


@dataclass(frozen=True, slots=True)
class GmailToken:
    access_token: str = field(repr=False)
    refresh_token: str | None = field(default=None, repr=False)
    token_type: str = "Bearer"
    expires_at: float | None = None
    scope: str | None = None


class TokenStore(Protocol):
    def load(self) -> GmailToken | None: ...

    def save(self, token: GmailToken) -> None: ...


class JsonFileTokenStore:
    """Minimal token store; callers can replace it with an OS keychain hook."""

    def __init__(self, path: Path):
        self.path = path

    def load(self) -> GmailToken | None:
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return None
        if not isinstance(payload, dict) or not isinstance(payload.get("access_token"), str):
            return None
        return GmailToken(
            access_token=payload["access_token"],
            refresh_token=payload.get("refresh_token") if isinstance(payload.get("refresh_token"), str) else None,
            token_type=payload.get("token_type", "Bearer") if isinstance(payload.get("token_type", "Bearer"), str) else "Bearer",
            expires_at=payload.get("expires_at") if isinstance(payload.get("expires_at"), (int, float)) else None,
            scope=payload.get("scope") if isinstance(payload.get("scope"), str) else None,
        )

    def save(self, token: GmailToken) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "access_token": token.access_token,
            "refresh_token": token.refresh_token,
            "token_type": token.token_type,
            "expires_at": token.expires_at,
            "scope": token.scope,
        }
        temporary = self.path.with_name(f".{self.path.name}.tmp")
        temporary.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
        try:
            temporary.chmod(0o600)
        except OSError:
            pass
        temporary.replace(self.path)


@dataclass(frozen=True, slots=True)
class GmailTokenResult:
    expires_at: float | None
    scope: str | None
    has_refresh_token: bool


@dataclass(frozen=True, slots=True)
class GmailMessage:
    recipient: str
    subject: str
    body: str
    thread_id: str | None = None


@dataclass(frozen=True, slots=True)
class GmailDraft:
    draft_id: str
    thread_id: str | None = None


@dataclass(frozen=True, slots=True)
class GmailThreadSummary:
    thread_id: str
    snippet: str | None = None
    history_id: str | None = None


@dataclass(frozen=True, slots=True)
class GmailThreadPage:
    threads: tuple[GmailThreadSummary, ...]
    next_page_token: str | None = None


class GmailUnavailableError(RuntimeError):
    pass


class GmailApiError(RuntimeError):
    pass


class GmailLiveSendBlocked(RuntimeError):
    pass


def _error_detail(response: HttpResponse) -> str:
    try:
        payload = json.loads(response.body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return f"HTTP {response.status_code} from Gmail"
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            message = error.get("message")
            if isinstance(message, str):
                return message[:500]
        if isinstance(payload.get("error_description"), str):
            return payload["error_description"][:500]
    return f"HTTP {response.status_code} from Gmail"


class GmailApiAdapter:
    """OAuth and Gmail API boundary using only official HTTPS endpoints."""

    def __init__(self, config: GmailConfig, transport: HttpTransport | None = None, token_store: TokenStore | None = None):
        self.config = config
        self.transport = transport or UrllibHttpTransport()
        self.token_store = token_store or JsonFileTokenStore(config.token_path)
        self.name = "gmail"

    def _token_available(self) -> bool:
        return bool(self.config.refresh_token or self.token_store.load())

    def status(self) -> ProviderStatus:
        configured = self.config.oauth_configured and self._token_available() and bool(self.config.sender_email)
        supports_live_send = configured and self.config.live_send_approved and self.config.live_send_tested
        if not self.config.oauth_configured:
            reason = "Gmail OAuth client credentials are not configured"
        elif not self._token_available():
            reason = "Gmail OAuth token is not configured"
        elif not self.config.sender_email:
            reason = "GMAIL_SENDER_EMAIL is not configured"
        elif not self.config.live_send_approved:
            reason = "Gmail live sending requires explicit GMAIL_LIVE_SEND_APPROVED=true"
        elif not self.config.live_send_tested:
            reason = "Gmail live sending requires a completed controlled integration test"
        else:
            reason = "Gmail live sending is explicitly approved; use a real integration test before enabling it"
        return ProviderStatus(
            name=self.name,
            configured=configured,
            supports_live_send=supports_live_send,
            reason=reason,
        )

    def public_status(self) -> GmailStatus:
        provider_status = self.status()
        return GmailStatus(
            configured=provider_status.configured,
            token_available=self._token_available(),
            sender_email_configured=bool(self.config.sender_email),
            sender_email=self.config.sender_email or None,
            supports_live_send=provider_status.supports_live_send,
            reason=provider_status.reason or "Gmail status unavailable",
        )

    def health_check(self) -> GmailHealth:
        return self.adapter().health_check()

    def create_draft(self, message: GmailMessage) -> GmailDraft:
        return self.adapter().create_draft(message)

    def sync_threads(self, *, query: str | None = None, page_token: str | None = None, max_results: int = 100) -> GmailThreadPage:
        return self.adapter().sync_threads(query=query, page_token=page_token, max_results=max_results)

    def authorization_url(self, state: str) -> str:
        if not self.config.oauth_configured:
            raise GmailUnavailableError("Gmail OAuth client credentials are not configured")
        if not state.strip():
            raise ValueError("OAuth state is required")
        return f"{GMAIL_AUTH_URL}?{urlencode({'client_id': self.config.client_id, 'redirect_uri': self.config.redirect_uri, 'response_type': 'code', 'scope': ' '.join(self.config.scopes), 'access_type': 'offline', 'prompt': 'consent', 'state': state})}"

    @staticmethod
    def _decode_json(response: HttpResponse) -> dict[str, Any]:
        try:
            payload = json.loads(response.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise GmailApiError("Gmail returned invalid JSON") from exc
        if not isinstance(payload, dict):
            raise GmailApiError("Gmail returned an invalid response object")
        return payload

    def _request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str] | None = None,
        body: bytes | None = None,
        form: Mapping[str, str] | None = None,
    ) -> dict[str, Any]:
        request_headers = dict(headers or {})
        request_body = body
        if form is not None:
            request_headers["Content-Type"] = "application/x-www-form-urlencoded"
            request_body = urlencode(form).encode("utf-8")
        last_error: Exception | None = None
        for attempt in range(self.config.max_retries + 1):
            try:
                response = self.transport.request(
                    method,
                    url,
                    headers=request_headers,
                    body=request_body,
                    timeout=self.config.timeout_seconds,
                )
            except (OSError, TimeoutError, URLError) as exc:
                last_error = exc
                if attempt >= self.config.max_retries:
                    raise GmailApiError("Gmail request failed after retries") from exc
                if self.config.retry_backoff_seconds:
                    time.sleep(self.config.retry_backoff_seconds * (2**attempt))
                continue
            if response.status_code in RETRYABLE_STATUS_CODES and attempt < self.config.max_retries:
                if self.config.retry_backoff_seconds:
                    time.sleep(self.config.retry_backoff_seconds * (2**attempt))
                continue
            if not 200 <= response.status_code < 300:
                raise GmailApiError(_error_detail(response))
            return self._decode_json(response) if response.body else {}
        raise GmailApiError("Gmail request failed after retries") from last_error

    def exchange_code(self, code: str) -> GmailTokenResult:
        if not self.config.oauth_configured:
            raise GmailUnavailableError("Gmail OAuth client credentials are not configured")
        if not code.strip():
            raise ValueError("OAuth authorization code is required")
        payload = self._request(
            "POST",
            GMAIL_TOKEN_URL,
            form={
                "code": code,
                "client_id": self.config.client_id,
                "client_secret": self.config.client_secret,
                "redirect_uri": self.config.redirect_uri,
                "grant_type": "authorization_code",
            },
        )
        return self._store_token(payload)

    def refresh_access_token(self) -> GmailTokenResult:
        if not self.config.oauth_configured:
            raise GmailUnavailableError("Gmail OAuth client credentials are not configured")
        stored = self.token_store.load()
        refresh_token = self.config.refresh_token or (stored.refresh_token if stored else None)
        if not refresh_token:
            raise GmailUnavailableError("Gmail refresh token is not configured")
        payload = self._request(
            "POST",
            GMAIL_TOKEN_URL,
            form={
                "client_id": self.config.client_id,
                "client_secret": self.config.client_secret,
                "refresh_token": refresh_token,
                "grant_type": "refresh_token",
            },
        )
        return self._store_token(payload, fallback_refresh_token=refresh_token)

    def _store_token(self, payload: dict[str, Any], fallback_refresh_token: str | None = None) -> GmailTokenResult:
        access_token = payload.get("access_token")
        if not isinstance(access_token, str) or not access_token:
            raise GmailApiError("Gmail token response did not contain an access token")
        expires_in = payload.get("expires_in")
        expires_at = time.time() + float(expires_in) if isinstance(expires_in, (int, float)) else None
        refresh_token = payload.get("refresh_token") if isinstance(payload.get("refresh_token"), str) else fallback_refresh_token
        scope = payload.get("scope") if isinstance(payload.get("scope"), str) else None
        token = GmailToken(
            access_token=access_token,
            refresh_token=refresh_token,
            token_type=payload.get("token_type", "Bearer") if isinstance(payload.get("token_type", "Bearer"), str) else "Bearer",
            expires_at=expires_at,
            scope=scope,
        )
        self.token_store.save(token)
        return GmailTokenResult(expires_at=expires_at, scope=scope, has_refresh_token=bool(refresh_token))

    def _access_token(self) -> str:
        stored = self.token_store.load()
        if stored and stored.access_token and (stored.expires_at is None or stored.expires_at > time.time() + 60):
            return stored.access_token
        return_value = self.refresh_access_token()
        refreshed = self.token_store.load()
        if not refreshed or not refreshed.access_token:
            raise GmailApiError("Gmail token refresh did not produce an access token")
        return refreshed.access_token

    def _authorized_request(self, method: str, path: str, *, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        access_token = self._access_token()
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8") if payload is not None else None
        headers = {"Authorization": f"Bearer {access_token}", "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        return self._request(method, f"{GMAIL_API_URL}{path}", headers=headers, body=body)

    def sender_identity(self) -> GmailSenderIdentity:
        payload = self._authorized_request("GET", "/users/me/profile")
        email_address = payload.get("emailAddress")
        if not isinstance(email_address, str) or not email_address:
            raise GmailApiError("Gmail profile did not contain a sender identity")
        return GmailSenderIdentity(
            email_address=email_address,
            messages_total=payload.get("messagesTotal") if isinstance(payload.get("messagesTotal"), int) else None,
            threads_total=payload.get("threadsTotal") if isinstance(payload.get("threadsTotal"), int) else None,
        )

    def health_check(self) -> GmailHealth:
        try:
            identity = self.sender_identity()
        except (GmailApiError, GmailUnavailableError) as exc:
            return GmailHealth(status="unhealthy", detail=str(exc))
        return GmailHealth(status="healthy", detail="Gmail profile request succeeded", sender_identity=identity)

    @staticmethod
    def _raw_message(message: GmailMessage) -> str:
        raw = RFCEmailMessage()
        raw["To"] = message.recipient
        raw["Subject"] = message.subject
        raw.set_content(message.body)
        return base64.urlsafe_b64encode(raw.as_bytes()).decode("ascii").rstrip("=")

    def create_draft(self, message: GmailMessage) -> GmailDraft:
        payload: dict[str, Any] = {"message": {"raw": self._raw_message(message)}}
        if message.thread_id:
            payload["message"]["threadId"] = message.thread_id
        result = self._authorized_request("POST", "/users/me/drafts", payload=payload)
        draft_id = result.get("id")
        if not isinstance(draft_id, str) or not draft_id:
            raise GmailApiError("Gmail draft response did not contain a draft id")
        thread_id = result.get("message", {}).get("threadId") if isinstance(result.get("message"), dict) else None
        return GmailDraft(draft_id=draft_id, thread_id=thread_id if isinstance(thread_id, str) else None)

    def send_draft(self, draft_id: str) -> str:
        self._assert_live_send()
        result = self._authorized_request("POST", "/users/me/drafts/send", payload={"id": draft_id})
        message_id = result.get("id")
        if not isinstance(message_id, str) or not message_id:
            raise GmailApiError("Gmail send response did not contain a message id")
        return message_id

    def send_message(self, message: GmailMessage) -> str:
        self._assert_live_send()
        result = self._authorized_request("POST", "/users/me/messages/send", payload={"raw": self._raw_message(message)})
        message_id = result.get("id")
        if not isinstance(message_id, str) or not message_id:
            raise GmailApiError("Gmail send response did not contain a message id")
        return message_id

    def _assert_live_send(self) -> None:
        status = self.status()
        if not status.supports_live_send:
            raise GmailLiveSendBlocked(status.reason or "Gmail live sending is blocked")

    def sync_threads(self, *, query: str | None = None, page_token: str | None = None, max_results: int = 100) -> GmailThreadPage:
        params: dict[str, str] = {"maxResults": str(min(max(max_results, 1), 500))}
        if query:
            params["q"] = query
        if page_token:
            params["pageToken"] = page_token
        path = "/users/me/threads?" + urlencode(params)
        payload = self._authorized_request("GET", path)
        raw_threads = payload.get("threads")
        threads: list[GmailThreadSummary] = []
        if isinstance(raw_threads, list):
            for item in raw_threads:
                if isinstance(item, dict) and isinstance(item.get("id"), str):
                    threads.append(
                        GmailThreadSummary(
                            thread_id=item["id"],
                            snippet=item.get("snippet") if isinstance(item.get("snippet"), str) else None,
                            history_id=item.get("historyId") if isinstance(item.get("historyId"), str) else None,
                        )
                    )
        next_page = payload.get("nextPageToken") if isinstance(payload.get("nextPageToken"), str) else None
        return GmailThreadPage(threads=tuple(threads), next_page_token=next_page)


class GmailService:
    def __init__(
        self,
        transport: HttpTransport | None = None,
        token_store_factory: Callable[[Path], TokenStore] | None = None,
    ):
        self.transport = transport
        self.token_store_factory = token_store_factory or JsonFileTokenStore
        self._oauth_states: dict[str, float] = {}

    def adapter(self) -> GmailApiAdapter:
        config = GmailConfig.from_env()
        return GmailApiAdapter(config, transport=self.transport, token_store=self.token_store_factory(config.token_path))

    def status(self) -> ProviderStatus:
        return self.adapter().status()

    def public_status(self) -> GmailStatus:
        return self.adapter().public_status()

    def authorization_url(self, state: str) -> str:
        if not state.strip():
            raise ValueError("OAuth state is required")
        self._prune_oauth_states()
        self._oauth_states[state] = time.time() + 600
        return self.adapter().authorization_url(state)

    def exchange_code(self, code: str, state: str) -> GmailStatus:
        self._prune_oauth_states()
        expiry = self._oauth_states.get(state)
        if expiry is None or expiry < time.time():
            raise GmailUnavailableError("OAuth state is missing or expired")
        if not code.strip():
            raise ValueError("OAuth authorization code is required")
        self.adapter().exchange_code(code)
        self._oauth_states.pop(state, None)
        return self.public_status()

    def _prune_oauth_states(self) -> None:
        now = time.time()
        self._oauth_states = {state: expiry for state, expiry in self._oauth_states.items() if expiry >= now}
