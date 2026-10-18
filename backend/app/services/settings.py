from __future__ import annotations

from typing import Any

from ..config import Settings
from ..models import PublicSettings, SettingsUpdate
from ..repositories import SettingsRepository
from .providers import ProviderRegistry


def _as_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


class SettingsService:
    def __init__(self, app_settings: Settings, repository: SettingsRepository, providers: ProviderRegistry):
        self.app_settings = app_settings
        self.repository = repository
        self.providers = providers

    def values(self) -> dict[str, str]:
        return self.repository.all()

    def public(self) -> PublicSettings:
        stored = self.values()
        provider_name = stored.get("provider", self.app_settings.provider)
        provider_status = self.providers.status(provider_name)
        dry_run = self.app_settings.dry_run or _as_bool(stored.get("dry_run"), False)
        sender_name = stored.get("sender_name")
        sender_email = stored.get("sender_email")
        physical_address = stored.get("physical_address", "")
        unsubscribe_url = stored.get("unsubscribe_url", "")
        acknowledged = _as_bool(stored.get("compliance_acknowledged"), False)
        automation_paused = _as_bool(stored.get("automation_paused"), False)
        live_ready = (
            self.app_settings.live_sending_enabled
            and not dry_run
            and acknowledged
            and bool(sender_name and sender_email and physical_address and unsubscribe_url)
            and provider_status.configured
            and provider_status.supports_live_send
            and not automation_paused
        )
        return PublicSettings(
            dry_run=dry_run,
            live_sending_enabled=self.app_settings.live_sending_enabled,
            live_send_ready=live_ready,
            provider=provider_name,
            provider_configured=provider_status.configured,
            sender_name=sender_name,
            sender_email=sender_email,
            physical_address_configured=bool(physical_address),
            unsubscribe_url_configured=bool(unsubscribe_url),
            compliance_acknowledged=acknowledged,
            automation_paused=automation_paused,
        )

    def update(self, update: SettingsUpdate) -> PublicSettings:
        values: dict[str, str] = {}
        for key, value in update.model_dump(exclude_none=True).items():
            if key == "dry_run" and value is False and self.app_settings.dry_run:
                raise ValueError("DRY_RUN=true is enforced by environment and cannot be disabled locally")
            if key == "provider":
                self.providers.get(str(value))
            values[key] = str(value).lower() if isinstance(value, bool) else str(value)
        self.repository.update(values)
        return self.public()

    def assert_live_send_allowed(self, provider_name: str | None = None) -> None:
        public = self.public()
        if provider_name and provider_name != public.provider:
            status = self.providers.status(provider_name)
            ready = (
                self.app_settings.live_sending_enabled
                and not public.dry_run
                and public.compliance_acknowledged
                and public.physical_address_configured
                and public.unsubscribe_url_configured
                and bool(public.sender_name and public.sender_email)
                and status.configured
                and status.supports_live_send
                and not public.automation_paused
            )
        else:
            ready = public.live_send_ready
        if not ready:
            raise ValueError("live sending is blocked: dry-run, compliance, or provider requirements are not satisfied")

    def assert_automation_allowed(self) -> None:
        if self.public().automation_paused:
            raise ValueError("automation is paused by the global stop control")
