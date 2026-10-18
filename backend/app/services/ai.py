from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from typing import Any, Callable, Generic, Protocol, TypeVar
from urllib.parse import urlsplit, urlunsplit

from pydantic import ValidationError
from urllib.error import URLError

from ..models import (
    AIBriefOutput,
    AIPersonalizationOutput,
    AIPersonalizationRequest,
    AIProviderConfigOut,
    AIProviderStatus,
    AIReplyClassificationOutput,
    AIUsageMetadata,
    BriefRequest,
)
from .http_transport import HttpResponse, HttpTransport, UrllibHttpTransport


AI_CAPABILITIES = ["personalization", "reply_classification", "brief_generation"]
RETRYABLE_STATUS_CODES = {408, 425, 429, 500, 502, 503, 504}


def _env_float(name: str, default: float, *, minimum: float, maximum: float) -> float:
    try:
        value = float(os.getenv(name, str(default)))
    except ValueError:
        return default
    return min(max(value, minimum), maximum)


def _env_int(name: str, default: int, *, minimum: int, maximum: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError:
        return default
    return min(max(value, minimum), maximum)


def _public_base_url(value: str) -> str | None:
    """Remove URL userinfo and query data before returning provider config."""
    if not value:
        return None
    try:
        parts = urlsplit(value)
        if not parts.hostname:
            return value.split("?", 1)[0].split("#", 1)[0]
        hostname = parts.hostname
        netloc = f"[{hostname}]" if ":" in hostname else hostname
        if parts.port:
            netloc = f"{netloc}:{parts.port}"
        return urlunsplit((parts.scheme, netloc, parts.path, "", ""))
    except ValueError:
        return value.split("?", 1)[0].split("#", 1)[0]


@dataclass(frozen=True, slots=True)
class AIConfig:
    provider: str
    model: str
    base_url: str
    api_key: str
    timeout_seconds: float = 20.0
    max_retries: int = 2
    retry_backoff_seconds: float = 0.25

    @classmethod
    def from_env(cls) -> "AIConfig":
        return cls(
            provider=os.getenv("AI_PROVIDER", "none").strip().lower() or "none",
            model=os.getenv("AI_MODEL", "").strip(),
            base_url=os.getenv("AI_BASE_URL", "https://api.openai.com/v1").strip().rstrip("/"),
            api_key=os.getenv("AI_API_KEY", "").strip(),
            timeout_seconds=_env_float("AI_TIMEOUT_SECONDS", 20.0, minimum=0.1, maximum=300.0),
            max_retries=_env_int("AI_MAX_RETRIES", 2, minimum=0, maximum=5),
            retry_backoff_seconds=_env_float("AI_RETRY_BACKOFF_SECONDS", 0.25, minimum=0.0, maximum=10.0),
        )

    @property
    def credentials_present(self) -> bool:
        return self.provider not in {"", "none", "disabled"} and bool(self.api_key and self.model and self.base_url)


T = TypeVar("T")


@dataclass(frozen=True, slots=True)
class AIResult(Generic[T]):
    output: T
    usage: AIUsageMetadata
    provider: str
    model: str
    request_id: str | None = None


class AIUnavailableError(RuntimeError):
    pass


class AIProviderError(RuntimeError):
    pass


class AIProvider(Protocol):
    name: str

    def status(self) -> AIProviderStatus: ...

    def personalize(self, request: AIPersonalizationRequest) -> AIResult[AIPersonalizationOutput]: ...

    def classify_reply(self, subject: str | None, body: str) -> AIResult[AIReplyClassificationOutput]: ...

    def generate_brief(self, request: BriefRequest) -> AIResult[AIBriefOutput]: ...


def _usage_metadata(payload: dict[str, Any]) -> AIUsageMetadata:
    usage = payload.get("usage")
    if not isinstance(usage, dict):
        return AIUsageMetadata()

    def integer(name: str) -> int | None:
        value = usage.get(name)
        return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None

    cost = usage.get("estimated_cost_usd", usage.get("cost_usd"))
    estimated_cost = float(cost) if isinstance(cost, (int, float)) and not isinstance(cost, bool) and cost >= 0 else None
    prompt_tokens = integer("prompt_tokens")
    completion_tokens = integer("completion_tokens")
    total_tokens = integer("total_tokens")
    return AIUsageMetadata(
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        total_tokens=total_tokens,
        estimated_cost_usd=estimated_cost,
        available=any(value is not None for value in (prompt_tokens, completion_tokens, total_tokens, estimated_cost)),
    )


def _error_detail(response: HttpResponse) -> str:
    try:
        payload = json.loads(response.body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return f"HTTP {response.status_code} from AI provider"
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict) and isinstance(error.get("message"), str):
            return error["message"][:500]
        if isinstance(payload.get("message"), str):
            return payload["message"][:500]
    return f"HTTP {response.status_code} from AI provider"


class HttpLLMProvider:
    """OpenAI-compatible JSON provider with no SDK or implicit fallback output."""

    def __init__(self, config: AIConfig, transport: HttpTransport | None = None):
        self.config = config
        self.transport = transport or UrllibHttpTransport()
        self.name = config.provider

    def status(self) -> AIProviderStatus:
        if self.config.provider in {"", "none", "disabled"}:
            return AIProviderStatus(
                name="none",
                status="unavailable",
                configured=False,
                model=self.config.model or None,
                capabilities=AI_CAPABILITIES,
                api_key_configured=False,
                reason="AI provider is not configured",
            )
        if not self.config.credentials_present:
            return AIProviderStatus(
                name=self.name,
                status="unavailable",
                configured=False,
                model=self.config.model or None,
                capabilities=AI_CAPABILITIES,
                api_key_configured=bool(self.config.api_key),
                reason="AI provider requires AI_API_KEY, AI_MODEL, and AI_BASE_URL",
            )
        return AIProviderStatus(
            name=self.name,
            status="available",
            configured=True,
            model=self.config.model,
            capabilities=AI_CAPABILITIES,
            api_key_configured=True,
            reason="Configured; provider health is checked only when an operation is requested",
        )

    def _ensure_configured(self) -> None:
        if not self.config.credentials_present:
            raise AIUnavailableError(self.status().reason)

    def _request(self, payload: dict[str, Any]) -> tuple[dict[str, Any], str | None]:
        self._ensure_configured()
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers = {
            "Authorization": f"Bearer {self.config.api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        last_error: Exception | None = None
        for attempt in range(self.config.max_retries + 1):
            try:
                response = self.transport.request(
                    "POST",
                    f"{self.config.base_url}/chat/completions",
                    headers=headers,
                    body=body,
                    timeout=self.config.timeout_seconds,
                )
            except (OSError, TimeoutError, URLError) as exc:
                last_error = exc
                if attempt >= self.config.max_retries:
                    raise AIProviderError("AI provider request failed after retries") from exc
                if self.config.retry_backoff_seconds:
                    time.sleep(self.config.retry_backoff_seconds * (2**attempt))
                continue

            if response.status_code in RETRYABLE_STATUS_CODES and attempt < self.config.max_retries:
                if self.config.retry_backoff_seconds:
                    time.sleep(self.config.retry_backoff_seconds * (2**attempt))
                continue
            if not 200 <= response.status_code < 300:
                raise AIProviderError(_error_detail(response))
            try:
                decoded = json.loads(response.body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise AIProviderError("AI provider returned invalid JSON") from exc
            if not isinstance(decoded, dict):
                raise AIProviderError("AI provider returned an invalid response object")
            return decoded, decoded.get("id") if isinstance(decoded.get("id"), str) else None
        raise AIProviderError("AI provider request failed after retries") from last_error

    @staticmethod
    def _structured_content(payload: dict[str, Any]) -> dict[str, Any]:
        choices = payload.get("choices")
        if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
            raise AIProviderError("AI provider returned no choices")
        message = choices[0].get("message")
        if not isinstance(message, dict):
            raise AIProviderError("AI provider returned no message")
        content = message.get("content")
        if isinstance(content, dict):
            return content
        if not isinstance(content, str) or not content.strip():
            raise AIProviderError("AI provider returned no structured content")
        text = content.strip()
        if text.startswith("```"):
            lines = text.splitlines()
            if lines and lines[0].startswith("```"):
                lines = lines[1:]
            if lines and lines[-1].strip() == "```":
                lines = lines[:-1]
            text = "\n".join(lines).strip()
        try:
            decoded = json.loads(text)
        except json.JSONDecodeError as exc:
            raise AIProviderError("AI provider returned non-JSON content") from exc
        if not isinstance(decoded, dict):
            raise AIProviderError("AI provider returned a non-object result")
        return decoded

    def _generate(
        self,
        operation: str,
        instructions: str,
        parser: Callable[[dict[str, Any]], T],
    ) -> AIResult[T]:
        payload, request_id = self._request(
            {
                "model": self.config.model,
                "temperature": 0,
                "response_format": {"type": "json_object"},
                "messages": [
                    {
                        "role": "system",
                        "content": (
                            "Return only a JSON object matching the requested schema. "
                            "Do not invent facts that are absent from the supplied input."
                        ),
                    },
                    {"role": "user", "content": f"Operation: {operation}\n{instructions}"},
                ],
            }
        )
        try:
            output = parser(self._structured_content(payload))
        except (ValidationError, ValueError) as exc:
            raise AIProviderError("AI provider returned a result with the wrong schema") from exc
        return AIResult(
            output=output,
            usage=_usage_metadata(payload),
            provider=self.name,
            model=self.config.model,
            request_id=request_id,
        )

    def personalize(self, request: AIPersonalizationRequest) -> AIResult[AIPersonalizationOutput]:
        return self._generate(
            "personalization",
            "Create a personalized subject and body from this JSON input. "
            "The response schema is {subject: string, body: string, personalization_summary: string|null}.\n"
            + json.dumps(request.model_dump(), ensure_ascii=False, sort_keys=True),
            AIPersonalizationOutput.model_validate,
        )

    def classify_reply(self, subject: str | None, body: str) -> AIResult[AIReplyClassificationOutput]:
        return self._generate(
            "reply_classification",
            "Classify this reply without guessing beyond its text. The response schema is "
            "{classification: string, confidence: number from 0 to 1, rationale: string}.\n"
            + json.dumps({"subject": subject, "body": body}, ensure_ascii=False),
            AIReplyClassificationOutput.model_validate,
        )

    def generate_brief(self, request: BriefRequest) -> AIResult[AIBriefOutput]:
        return self._generate(
            "brief_generation",
            "Generate a concise campaign/client brief from this JSON input. The response schema is "
            "{brief: string, key_points: array of strings}.\n"
            + json.dumps(request.model_dump(), ensure_ascii=False, sort_keys=True),
            AIBriefOutput.model_validate,
        )


class UnavailableAIProvider(HttpLLMProvider):
    """Deterministic status object used when no provider is configured."""

    def __init__(self, config: AIConfig):
        super().__init__(config, transport=UrllibHttpTransport())

    def _ensure_configured(self) -> None:
        raise AIUnavailableError("AI provider is not configured")


class AIProviderRegistry:
    def __init__(self, transport: HttpTransport | None = None):
        self.transport = transport

    def current(self) -> HttpLLMProvider:
        config = AIConfig.from_env()
        if config.provider in {"", "none", "disabled"}:
            return UnavailableAIProvider(config)
        return HttpLLMProvider(config, transport=self.transport)


class AIService:
    def __init__(self, registry: AIProviderRegistry | None = None):
        self.registry = registry or AIProviderRegistry()

    def config(self) -> AIProviderConfigOut:
        config = AIConfig.from_env()
        return AIProviderConfigOut(
            provider=config.provider,
            model=config.model or None,
            base_url=_public_base_url(config.base_url),
            timeout_seconds=config.timeout_seconds,
            max_retries=config.max_retries,
            api_key_configured=bool(config.api_key),
        )

    def status(self) -> AIProviderStatus:
        return self.registry.current().status()

    def personalize(self, request: AIPersonalizationRequest) -> AIResult[AIPersonalizationOutput]:
        return self.registry.current().personalize(request)

    def classify_reply(self, subject: str | None, body: str) -> AIResult[AIReplyClassificationOutput]:
        return self.registry.current().classify_reply(subject, body)

    def generate_brief(self, request: BriefRequest) -> AIResult[AIBriefOutput]:
        return self.registry.current().generate_brief(request)
