from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping, Protocol
from urllib.error import HTTPError
from urllib.request import Request, urlopen


@dataclass(frozen=True, slots=True)
class HttpResponse:
    status_code: int
    headers: Mapping[str, str]
    body: bytes


class HttpTransport(Protocol):
    def request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str] | None = None,
        body: bytes | None = None,
        timeout: float,
    ) -> HttpResponse: ...


class UrllibHttpTransport:
    """Small injectable HTTPS transport shared by provider adapters."""

    def request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str] | None = None,
        body: bytes | None = None,
        timeout: float,
    ) -> HttpResponse:
        request = Request(url, data=body, headers=dict(headers or {}), method=method.upper())
        try:
            with urlopen(request, timeout=timeout) as response:
                return HttpResponse(
                    status_code=int(response.status),
                    headers=dict(response.headers.items()),
                    body=response.read(),
                )
        except HTTPError as exc:
            # Returning an HTTP response lets adapters apply operation-specific
            # retry rules without coupling them to urllib exception classes.
            return HttpResponse(
                status_code=int(exc.code),
                headers=dict(exc.headers.items()) if exc.headers else {},
                body=exc.read(),
            )
