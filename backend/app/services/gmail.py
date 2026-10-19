from __future__ import annotations

import base64
import ctypes
import hashlib
import html
import json
import os
import re
import secrets
import time
from dataclasses import dataclass, field
from email.message import EmailMessage as RFCEmailMessage
from email.utils import getaddresses
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol
from urllib.parse import urlencode, quote, urlsplit
from urllib.error import URLError
from ctypes import wintypes

from ..models import GmailHealth, GmailSenderIdentity, GmailStatus, ProviderStatus
from .http_transport import HttpResponse, HttpTransport, UrllibHttpTransport
from .normalization import normalize_email


GMAIL_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GMAIL_TOKEN_URL = "https://oauth2.googleapis.com/token"
GMAIL_API_URL = "https://gmail.googleapis.com/gmail/v1"
DEFAULT_GMAIL_REDIRECT_URI = "http://127.0.0.1:8000/api/gmail/oauth/callback"
GMAIL_COMPOSE_SCOPE = "https://www.googleapis.com/auth/gmail.compose"
GMAIL_READONLY_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
DEFAULT_GMAIL_SCOPES = (GMAIL_COMPOSE_SCOPE, GMAIL_READONLY_SCOPE)
ALLOWED_GMAIL_SCOPES = frozenset(DEFAULT_GMAIL_SCOPES)
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
    fallback = Path.home() / ".leadpilot" / "gmail_tokens.dpapi"
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
        raw_scopes = os.getenv("GMAIL_SCOPES", " ".join(DEFAULT_GMAIL_SCOPES))
        requested_scopes = {scope.strip() for scope in raw_scopes.split() if scope.strip()}
        scopes = tuple(scope for scope in DEFAULT_GMAIL_SCOPES if scope in requested_scopes)
        if set(scopes) != ALLOWED_GMAIL_SCOPES:
            scopes = DEFAULT_GMAIL_SCOPES
        return cls(
            client_id=os.getenv("GMAIL_CLIENT_ID", "").strip(),
            client_secret=os.getenv("GMAIL_CLIENT_SECRET", "").strip(),
            # Refresh tokens are issued by OAuth and must live only in the
            # encrypted OS-backed token store. Do not reintroduce an
            # environment/plaintext refresh-token escape hatch here.
            refresh_token="",
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
        parsed = urlsplit(self.redirect_uri)
        try:
            exact_loopback = (
                parsed.scheme == "http"
                and parsed.hostname == "127.0.0.1"
                and parsed.port == 8000
                and parsed.path == "/api/gmail/oauth/callback"
                and not parsed.query
                and not parsed.fragment
                and not parsed.username
                and not parsed.password
            )
        except ValueError:
            exact_loopback = False
        return bool(self.client_id and self.client_secret and exact_loopback)


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

    def delete(self) -> None: ...


class SecureStorageUnavailableError(RuntimeError):
    """Raised when the configured OS-backed token storage cannot be used."""


class MemoryTokenStore:
    """Injectable token store for mocked tests; never used by the application default."""

    def __init__(self, token: GmailToken | None = None):
        self.token = token

    def load(self) -> GmailToken | None:
        return self.token

    def save(self, token: GmailToken) -> None:
        self.token = token

    def delete(self) -> None:
        self.token = None


class _DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_byte))]


class WindowsDPAPITokenStore:
    """Encrypt Gmail tokens with Windows DPAPI in the current user's profile.

    The file contains only DPAPI ciphertext. There is deliberately no plaintext
    or alternate-file fallback: a missing DPAPI implementation fails closed.
    """

    def __init__(self, path: Path):
        self.path = Path(path)

    @staticmethod
    def _crypt(data: bytes, protect: bool) -> bytes:
        if os.name != "nt":
            raise SecureStorageUnavailableError("Windows DPAPI is unavailable on this platform")
        try:
            crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            function = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
            function.argtypes = [
                ctypes.POINTER(_DATA_BLOB),
                wintypes.LPCWSTR,
                ctypes.POINTER(_DATA_BLOB),
                wintypes.LPVOID,
                wintypes.LPVOID,
                wintypes.DWORD,
                ctypes.POINTER(_DATA_BLOB),
            ]
            function.restype = wintypes.BOOL
            source_buffer = ctypes.create_string_buffer(data)
            source = _DATA_BLOB(len(data), ctypes.cast(source_buffer, ctypes.POINTER(ctypes.c_byte)))
            result = _DATA_BLOB()
            if not function(ctypes.byref(source), None, None, None, None, 0, ctypes.byref(result)):
                error = ctypes.get_last_error()
                raise SecureStorageUnavailableError(f"Windows DPAPI operation failed ({error})")
            try:
                return ctypes.string_at(result.pbData, result.cbData)
            finally:
                kernel32.LocalFree(result.pbData)
        except SecureStorageUnavailableError:
            raise
        except (AttributeError, OSError, TypeError) as exc:
            raise SecureStorageUnavailableError("Windows DPAPI is unavailable") from exc

    def load(self) -> GmailToken | None:
        if not self.path.exists():
            if os.name != "nt":
                raise SecureStorageUnavailableError("Windows DPAPI is unavailable on this platform")
            return None
        try:
            encrypted = self.path.read_bytes()
            payload = json.loads(self._crypt(encrypted, protect=False).decode("utf-8"))
        except SecureStorageUnavailableError:
            raise
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise SecureStorageUnavailableError("stored Gmail credentials could not be opened") from exc
        if not isinstance(payload, dict) or not isinstance(payload.get("access_token"), str) or not payload["access_token"]:
            raise SecureStorageUnavailableError("stored Gmail credentials are invalid")
        return GmailToken(
            access_token=payload["access_token"],
            refresh_token=payload.get("refresh_token") if isinstance(payload.get("refresh_token"), str) else None,
            token_type=payload.get("token_type", "Bearer") if isinstance(payload.get("token_type", "Bearer"), str) else "Bearer",
            expires_at=payload.get("expires_at") if isinstance(payload.get("expires_at"), (int, float)) else None,
            scope=payload.get("scope") if isinstance(payload.get("scope"), str) else None,
        )

    def save(self, token: GmailToken) -> None:
        payload = json.dumps(
            {
                "access_token": token.access_token,
                "refresh_token": token.refresh_token,
                "token_type": token.token_type,
                "expires_at": token.expires_at,
                "scope": token.scope,
            },
            separators=(",", ":"),
        ).encode("utf-8")
        encrypted = self._crypt(payload, protect=True)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(f".{self.path.name}.tmp")
        temporary.write_bytes(encrypted)
        try:
            temporary.chmod(0o600)
        except OSError:
            pass
        temporary.replace(self.path)

    def delete(self) -> None:
        try:
            self.path.unlink(missing_ok=True)
        except OSError as exc:
            raise SecureStorageUnavailableError("stored Gmail credentials could not be deleted") from exc


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


@dataclass(frozen=True, slots=True)
class GmailSyncedMessage:
    message_id: str
    thread_id: str
    from_email: str | None = None
    to_emails: tuple[str, ...] = ()
    subject: str | None = None
    snippet: str | None = None
    body: str | None = None
    internal_date: str | None = None


@dataclass(frozen=True, slots=True)
class GmailThreadData:
    thread_id: str
    history_id: str | None
    snippet: str | None
    messages: tuple[GmailSyncedMessage, ...]


@dataclass(frozen=True, slots=True)
class GmailHistoryPage:
    thread_ids: tuple[str, ...]
    history_id: str | None = None
    next_page_token: str | None = None


class GmailUnavailableError(RuntimeError):
    pass


class GmailApiError(RuntimeError):
    def __init__(self, message: str, status_code: int | None = None):
        super().__init__(message)
        self.status_code = status_code


class GmailHistoryExpiredError(GmailApiError):
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


def _clean_untrusted(value: Any, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = "".join(character for character in value if character in "\n\r\t" or ord(character) >= 32)
    return cleaned.strip()[:limit] or None


def _header_values(headers: Any) -> dict[str, str]:
    result: dict[str, str] = {}
    if not isinstance(headers, list):
        return result
    for header in headers:
        if not isinstance(header, dict):
            continue
        name = header.get("name")
        value = header.get("value")
        if isinstance(name, str) and isinstance(value, str):
            result.setdefault(name.casefold(), value)
    return result


def _decode_part_body(part: dict[str, Any]) -> str | None:
    body = part.get("body")
    if not isinstance(body, dict) or not isinstance(body.get("data"), str):
        return None
    try:
        encoded = body["data"]
        decoded = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
        text = decoded.decode("utf-8", errors="replace")
    except (ValueError, UnicodeError):
        return None
    mime_type = str(part.get("mimeType") or "").casefold()
    if mime_type == "text/html":
        text = html.unescape(re.sub(r"<[^>]*>", " ", text))
    # Thread synchronization keeps only a bounded excerpt. Full message
    # bodies are not copied into the local database in Phase 3.
    return _clean_untrusted(text, 4000)


def _message_body(payload: Any) -> str | None:
    if not isinstance(payload, dict):
        return None
    # Attachments are intentionally ignored, including inline parts with an
    # attachment id. Only bounded text/plain or text/html content is retained.
    if payload.get("filename") or (isinstance(payload.get("body"), dict) and payload["body"].get("attachmentId")):
        return None
    mime_type = str(payload.get("mimeType") or "").casefold()
    if mime_type in {"text/plain", "text/html"}:
        body = _decode_part_body(payload)
        if body:
            return body
    parts = payload.get("parts")
    if isinstance(parts, list):
        plain: str | None = None
        for part in parts:
            if not isinstance(part, dict):
                continue
            candidate = _message_body(part)
            part_type = str(part.get("mimeType") or "").casefold()
            if candidate and part_type == "text/plain":
                return candidate
            plain = plain or candidate
        return plain
    return None


def _safe_email(value: str | None) -> str | None:
    if not value:
        return None
    try:
        return normalize_email(value)
    except ValueError:
        return None


class GmailApiAdapter:
    """OAuth and Gmail API boundary using only official HTTPS endpoints."""

    def __init__(self, config: GmailConfig, transport: HttpTransport | None = None, token_store: TokenStore | None = None):
        self.config = config
        self.transport = transport or UrllibHttpTransport()
        self.token_store = token_store or WindowsDPAPITokenStore(config.token_path)
        self.name = "gmail"

    def _token_available(self) -> bool:
        try:
            return bool(self.config.refresh_token or self.token_store.load())
        except SecureStorageUnavailableError:
            return False

    def status(self) -> ProviderStatus:
        configured = (
            self.config.oauth_configured
            and self._token_available()
            and self._secure_storage_available()
        )
        # Phase 3 is draft-only. Keep the old status fields for API
        # compatibility, but never advertise or enable provider sending.
        supports_live_send = False
        if not self.config.oauth_configured:
            reason = "Gmail OAuth client credentials are not configured"
        elif not self._secure_storage_available():
            reason = "Windows DPAPI token storage is unavailable"
        elif not self._token_available():
            reason = "Gmail OAuth token is not configured"
        else:
            reason = "Gmail Phase 3 supports draft creation and synchronization only; sending is disabled"
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

    def authorization_url(self, state: str, code_challenge: str | None = None) -> str:
        if not self.config.oauth_configured:
            raise GmailUnavailableError("Gmail OAuth client credentials are not configured")
        if not state.strip():
            raise ValueError("OAuth state is required")
        query = {
            "client_id": self.config.client_id,
            "redirect_uri": self.config.redirect_uri,
            "response_type": "code",
            "scope": " ".join(self.config.scopes),
            "access_type": "offline",
            "prompt": "consent",
            "state": state,
        }
        if code_challenge:
            query["code_challenge"] = code_challenge
            query["code_challenge_method"] = "S256"
        return f"{GMAIL_AUTH_URL}?{urlencode(query)}"

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
        retryable: bool = True,
    ) -> dict[str, Any]:
        request_headers = dict(headers or {})
        request_body = body
        if form is not None:
            request_headers["Content-Type"] = "application/x-www-form-urlencoded"
            request_body = urlencode(form).encode("utf-8")
        last_error: Exception | None = None
        attempts = self.config.max_retries + 1 if retryable else 1
        for attempt in range(attempts):
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
                if attempt >= attempts - 1:
                    raise GmailApiError("Gmail request failed after retries") from exc
                if self.config.retry_backoff_seconds:
                    time.sleep(self.config.retry_backoff_seconds * (2**attempt))
                continue
            if retryable and response.status_code in RETRYABLE_STATUS_CODES and attempt < attempts - 1:
                if self.config.retry_backoff_seconds:
                    time.sleep(self.config.retry_backoff_seconds * (2**attempt))
                continue
            if not 200 <= response.status_code < 300:
                raise GmailApiError(_error_detail(response), status_code=response.status_code)
            return self._decode_json(response) if response.body else {}
        raise GmailApiError("Gmail request failed after retries") from last_error

    def exchange_code(self, code: str, code_verifier: str | None = None) -> GmailTokenResult:
        if not self.config.oauth_configured:
            raise GmailUnavailableError("Gmail OAuth client credentials are not configured")
        if not code.strip():
            raise ValueError("OAuth authorization code is required")
        self._require_secure_storage()
        form = {
            "code": code,
            "client_id": self.config.client_id,
            "client_secret": self.config.client_secret,
            "redirect_uri": self.config.redirect_uri,
            "grant_type": "authorization_code",
        }
        # GmailService always supplies the verifier. The optional low-level
        # argument keeps older adapter injections usable in unit tests.
        if code_verifier is not None:
            if not (43 <= len(code_verifier) <= 128):
                raise ValueError("OAuth PKCE verifier is invalid")
            form["code_verifier"] = code_verifier
        payload = self._request(
            "POST",
            GMAIL_TOKEN_URL,
            form=form,
        )
        return self._store_token(payload)

    def refresh_access_token(self) -> GmailTokenResult:
        if not self.config.oauth_configured:
            raise GmailUnavailableError("Gmail OAuth client credentials are not configured")
        self._require_secure_storage()
        stored = self.token_store.load()
        refresh_token = self.config.refresh_token or (stored.refresh_token if stored else None)
        if not refresh_token:
            raise GmailUnavailableError("Gmail refresh token is not configured")
        try:
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
        except GmailApiError as exc:
            if exc.status_code in {400, 401}:
                self._delete_token_safely()
                raise GmailUnavailableError("Gmail authorization is missing or expired") from exc
            raise
        return self._store_token(payload, fallback_refresh_token=refresh_token)

    def _require_secure_storage(self) -> None:
        try:
            self.token_store.load()
        except SecureStorageUnavailableError as exc:
            raise GmailUnavailableError("secure Gmail token storage is unavailable") from exc

    def _delete_token_safely(self) -> None:
        try:
            self.token_store.delete()
        except (AttributeError, SecureStorageUnavailableError):
            # A mocked legacy store may not implement deletion. The production
            # DPAPI store does, and no token value is included in this path.
            pass

    def _store_token(self, payload: dict[str, Any], fallback_refresh_token: str | None = None) -> GmailTokenResult:
        access_token = payload.get("access_token")
        if not isinstance(access_token, str) or not access_token:
            raise GmailApiError("Gmail token response did not contain an access token")
        expires_in = payload.get("expires_in")
        expires_at = time.time() + float(expires_in) if isinstance(expires_in, (int, float)) else None
        refresh_token = payload.get("refresh_token") if isinstance(payload.get("refresh_token"), str) else fallback_refresh_token
        raw_scope = payload.get("scope") if isinstance(payload.get("scope"), str) else ""
        scope = " ".join(scope for scope in raw_scope.split() if scope in ALLOWED_GMAIL_SCOPES) or None
        token = GmailToken(
            access_token=access_token,
            refresh_token=refresh_token,
            token_type=payload.get("token_type", "Bearer") if isinstance(payload.get("token_type", "Bearer"), str) else "Bearer",
            expires_at=expires_at,
            scope=scope,
        )
        try:
            self.token_store.save(token)
        except SecureStorageUnavailableError as exc:
            raise GmailUnavailableError("secure Gmail token storage is unavailable") from exc
        return GmailTokenResult(expires_at=expires_at, scope=scope, has_refresh_token=bool(refresh_token))

    def _access_token(self) -> str:
        self._require_secure_storage()
        stored = self.token_store.load()
        if stored and stored.access_token and (stored.expires_at is None or stored.expires_at > time.time() + 60):
            return stored.access_token
        return_value = self.refresh_access_token()
        refreshed = self.token_store.load()
        if not refreshed or not refreshed.access_token:
            raise GmailApiError("Gmail token refresh did not produce an access token")
        return refreshed.access_token

    def revoke_credentials(self) -> bool:
        """Revoke the stored credential when possible, then always delete it."""
        token: GmailToken | None = None
        try:
            self._require_secure_storage()
            token = self.token_store.load()
        except GmailUnavailableError:
            token = None
        revoke_value = token.refresh_token if token and token.refresh_token else token.access_token if token else self.config.refresh_token
        revoked = False
        if revoke_value and self.config.oauth_configured:
            try:
                self._request("POST", "https://oauth2.googleapis.com/revoke", form={"token": revoke_value})
                revoked = True
            except GmailApiError:
                pass
        self._delete_token_safely()
        return revoked

    def _authorized_request(
        self,
        method: str,
        path: str,
        *,
        payload: dict[str, Any] | None = None,
        retryable: bool = True,
    ) -> dict[str, Any]:
        access_token = self._access_token()
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8") if payload is not None else None
        headers = {"Authorization": f"Bearer {access_token}", "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        try:
            return self._request(
                method,
                f"{GMAIL_API_URL}{path}",
                headers=headers,
                body=body,
                retryable=retryable,
            )
        except GmailApiError as exc:
            if exc.status_code in {401, 403}:
                self._delete_token_safely()
                raise GmailUnavailableError("Gmail authorization was rejected") from exc
            raise

    def _secure_storage_available(self) -> bool:
        try:
            self.token_store.load()
        except SecureStorageUnavailableError:
            return False
        return True

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
        except (GmailApiError, GmailUnavailableError):
            return GmailHealth(status="unhealthy", detail="Gmail profile request failed")
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
        # A timeout after Gmail accepts this mutation is ambiguous. Do not
        # retry the provider POST; the local workflow records the attempt and
        # prevents an automatic second draft from being created.
        result = self._authorized_request(
            "POST", "/users/me/drafts", payload=payload, retryable=False
        )
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
        raise GmailLiveSendBlocked("Gmail sending is disabled in Phase 3; only draft creation is available")

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

    def get_thread(self, thread_id: str) -> GmailThreadData:
        if not thread_id or len(thread_id) > 200:
            raise ValueError("invalid Gmail thread id")
        payload = self._authorized_request("GET", f"/users/me/threads/{quote(thread_id, safe='')}?format=full")
        messages: list[GmailSyncedMessage] = []
        raw_messages = payload.get("messages")
        if isinstance(raw_messages, list):
            for raw in raw_messages:
                if not isinstance(raw, dict) or not isinstance(raw.get("id"), str):
                    continue
                headers = _header_values(raw.get("payload", {}).get("headers") if isinstance(raw.get("payload"), dict) else [])
                addresses = getaddresses([headers.get("to", ""), headers.get("cc", "")])
                to_emails = tuple(
                    normalized
                    for _, address in addresses
                    if (normalized := _safe_email(address)) is not None
                )
                sender_addresses = getaddresses([headers.get("from", "")])
                from_email = _safe_email(sender_addresses[0][1]) if sender_addresses and sender_addresses[0][1] else None
                messages.append(
                    GmailSyncedMessage(
                        message_id=raw["id"],
                        thread_id=thread_id,
                        from_email=from_email,
                        to_emails=to_emails,
                        subject=_clean_untrusted(headers.get("subject"), 500),
                        snippet=_clean_untrusted(raw.get("snippet"), 2000),
                        body=_message_body(raw.get("payload")),
                        internal_date=_clean_untrusted(raw.get("internalDate"), 32),
                    )
                )
        history_id = payload.get("historyId") if isinstance(payload.get("historyId"), str) else None
        snippet = _clean_untrusted(payload.get("snippet"), 2000)
        return GmailThreadData(thread_id=thread_id, history_id=history_id, snippet=snippet, messages=tuple(messages))

    def sync_history(self, *, start_history_id: str, page_token: str | None = None, max_results: int = 100) -> GmailHistoryPage:
        if not start_history_id or not start_history_id.isdigit():
            raise ValueError("invalid Gmail history cursor")
        params: dict[str, str] = {
            "startHistoryId": start_history_id,
            "maxResults": str(min(max(max_results, 1), 500)),
        }
        if page_token:
            params["pageToken"] = page_token
        try:
            payload = self._authorized_request(
                "GET",
                "/users/me/history?" + urlencode(
                    [
                        ("startHistoryId", start_history_id),
                        ("historyTypes", "messageAdded"),
                        ("historyTypes", "messageDeleted"),
                        ("historyTypes", "labelAdded"),
                        ("historyTypes", "labelRemoved"),
                        ("maxResults", params["maxResults"]),
                        *([("pageToken", page_token)] if page_token else []),
                    ]
                ),
            )
        except GmailApiError as exc:
            if exc.status_code == 404:
                raise GmailHistoryExpiredError("Gmail history cursor expired", status_code=404) from exc
            raise
        thread_ids: list[str] = []
        raw_history = payload.get("history")
        if isinstance(raw_history, list):
            for item in raw_history:
                if not isinstance(item, dict):
                    continue
                for event_name in ("messagesAdded", "messagesDeleted", "labelsAdded", "labelsRemoved"):
                    events = item.get(event_name)
                    if not isinstance(events, list):
                        continue
                    for entry in events:
                        message = entry.get("message") if isinstance(entry, dict) else None
                        thread_id = message.get("threadId") if isinstance(message, dict) else None
                        if isinstance(thread_id, str):
                            thread_ids.append(thread_id)
        return GmailHistoryPage(
            thread_ids=tuple(dict.fromkeys(thread_ids)),
            history_id=payload.get("historyId") if isinstance(payload.get("historyId"), str) else None,
            next_page_token=payload.get("nextPageToken") if isinstance(payload.get("nextPageToken"), str) else None,
        )


class GmailService:
    def __init__(
        self,
        transport: HttpTransport | None = None,
        token_store_factory: Callable[[Path], TokenStore] | None = None,
    ):
        self.transport = transport
        self.token_store_factory = token_store_factory or WindowsDPAPITokenStore
        self._oauth_states: dict[str, tuple[float, str]] = {}
        self._compat_state_aliases: dict[str, str] = {}

    def adapter(self) -> GmailApiAdapter:
        config = GmailConfig.from_env()
        return GmailApiAdapter(config, transport=self.transport, token_store=self.token_store_factory(config.token_path))

    def status(self) -> ProviderStatus:
        return self.adapter().status()

    def public_status(self) -> GmailStatus:
        return self.adapter().public_status()

    def health_check(self) -> GmailHealth:
        return self.adapter().health_check()

    def create_draft(self, message: GmailMessage) -> GmailDraft:
        return self.adapter().create_draft(message)

    def sync_threads(self, *, query: str | None = None, page_token: str | None = None, max_results: int = 100) -> GmailThreadPage:
        return self.adapter().sync_threads(query=query, page_token=page_token, max_results=max_results)

    def get_thread(self, thread_id: str) -> GmailThreadData:
        return self.adapter().get_thread(thread_id)

    def sync_history(self, *, start_history_id: str, page_token: str | None = None, max_results: int = 100) -> GmailHistoryPage:
        return self.adapter().sync_history(start_history_id=start_history_id, page_token=page_token, max_results=max_results)

    def disconnect(self) -> bool:
        return self.adapter().revoke_credentials()

    def authorization_url(self, state: str | None = None) -> str:
        if state is not None and not state.strip():
            raise ValueError("OAuth state is required")
        self._prune_oauth_states()
        generated_state = secrets.token_urlsafe(32)
        verifier = secrets.token_urlsafe(64)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).decode("ascii").rstrip("=")
        self._oauth_states[generated_state] = (time.time() + 600, verifier)
        # Compatibility for the old direct service injection seam. The HTTP
        # route never supplies a state and therefore has no caller authority.
        if state is not None:
            self._compat_state_aliases[state] = generated_state
        return self.adapter().authorization_url(generated_state, code_challenge=challenge)

    def exchange_code(self, code: str, state: str) -> GmailStatus:
        self._prune_oauth_states()
        actual_state = state if state in self._oauth_states else self._compat_state_aliases.get(state)
        record = self._oauth_states.get(actual_state) if actual_state else None
        if record is None or record[0] < time.time():
            raise GmailUnavailableError("OAuth state is missing or expired")
        if not code.strip():
            raise ValueError("OAuth authorization code is required")
        # Consume before the provider exchange: a callback state is single-use
        # even when the provider rejects the authorization code.
        self._oauth_states.pop(actual_state, None)
        self._compat_state_aliases.pop(state, None)
        self.adapter().exchange_code(code, code_verifier=record[1])
        return self.public_status()

    def _prune_oauth_states(self) -> None:
        now = time.time()
        expired = {state for state, (expiry, _) in self._oauth_states.items() if expiry < now}
        self._oauth_states = {state: record for state, record in self._oauth_states.items() if record[0] >= now}
        self._compat_state_aliases = {
            alias: generated
            for alias, generated in self._compat_state_aliases.items()
            if generated not in expired and generated in self._oauth_states
        }
