from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Protocol

from ..models import ProviderStatus
from .gmail import GmailService


@dataclass(slots=True)
class EmailMessage:
    recipient: str
    subject: str
    body: str


@dataclass(slots=True)
class ProviderSendResult:
    provider_message_id: str
    dry_run: bool


class EmailProvider(Protocol):
    name: str

    def status(self) -> ProviderStatus: ...

    def send(self, message: EmailMessage) -> ProviderSendResult: ...


class MockEmailProvider:
    name = "mock"

    def status(self) -> ProviderStatus:
        return ProviderStatus(
            name=self.name,
            configured=True,
            supports_live_send=False,
            reason="Mock adapter is intentionally dry-run only",
        )

    def send(self, message: EmailMessage) -> ProviderSendResult:
        return ProviderSendResult(provider_message_id=f"dry-run:{message.recipient}", dry_run=True)


class GmailProvider:
    name = "gmail"

    def __init__(self, service: GmailService | None = None):
        self.service = service or GmailService()

    def status(self) -> ProviderStatus:
        return self.service.status()

    def send(self, message: EmailMessage) -> ProviderSendResult:
        raise RuntimeError("Gmail sending is disabled in Phase 3; create a reviewed Gmail draft instead")


class GraphProvider:
    name = "graph"

    def _credentials_present(self) -> bool:
        return all(
            os.getenv(key, "").strip()
            for key in ("GRAPH_TENANT_ID", "GRAPH_CLIENT_ID", "GRAPH_CLIENT_SECRET", "GRAPH_SENDER_EMAIL")
        )

    def status(self) -> ProviderStatus:
        configured = self._credentials_present()
        return ProviderStatus(
            name=self.name,
            configured=configured,
            supports_live_send=False,
            reason="Microsoft Graph adapter is not implemented; credentials alone do not enable live sending" if configured else "Microsoft Graph credentials are not configured",
        )

    def send(self, message: EmailMessage) -> ProviderSendResult:
        if not self._credentials_present():
            raise RuntimeError("Microsoft Graph provider is not configured")
        raise RuntimeError("Graph adapter is a configuration stub; no live send implementation is enabled")


class ProviderRegistry:
    def __init__(self, gmail: GmailService | None = None) -> None:
        self._providers: dict[str, EmailProvider] = {
            "mock": MockEmailProvider(),
            "gmail": GmailProvider(gmail),
            "graph": GraphProvider(),
        }

    def get(self, name: str) -> EmailProvider:
        try:
            return self._providers[name.lower()]
        except KeyError as exc:
            raise ValueError(f"unknown email provider: {name}") from exc

    def status(self, name: str) -> ProviderStatus:
        return self.get(name).status()
