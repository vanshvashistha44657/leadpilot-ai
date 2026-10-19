from __future__ import annotations

import re
from typing import Any

from ..models import OutreachPreview, OutreachPreviewItem, OutreachRequest
from ..repositories import CampaignRepository, LeadRepository, OutreachRepository
from .jobs import JobCancelled, JobContext
from .providers import EmailMessage, ProviderRegistry
from .settings import SettingsService


PLACEHOLDER_RE = re.compile(r"\{\{\s*([a-zA-Z_]+)\s*\}\}|\{([a-zA-Z_]+)\}")


def render_template(template: str, lead: dict[str, Any]) -> str:
    values = {key: lead.get(key) or "" for key in ("first_name", "last_name", "company", "title", "email")}

    def replace(match: re.Match[str]) -> str:
        return str(values.get(match.group(1) or match.group(2), match.group(0)))

    return PLACEHOLDER_RE.sub(replace, template)


class OutreachService:
    def __init__(
        self,
        campaigns: CampaignRepository,
        leads: LeadRepository,
        events: OutreachRepository,
        providers: ProviderRegistry,
        settings: SettingsService,
    ):
        self.campaigns = campaigns
        self.leads = leads
        self.events = events
        self.providers = providers
        self.settings = settings

    def preview(self, campaign_id: int, request: OutreachRequest) -> OutreachPreview:
        campaign = self.campaigns.get(campaign_id)
        if not campaign:
            raise LookupError("campaign not found")
        items = []
        for lead in self.leads.list(request.lead_ids):
            if lead["status"] in {"suppressed", "unsubscribed", "replied", "bounced"} or not self.leads.is_outreach_eligible(lead["id"]):
                continue
            items.append(
                OutreachPreviewItem(
                    lead_id=lead["id"],
                    email=lead["email"],
                    subject=render_template(request.subject, lead),
                    body=render_template(request.body_template, lead),
                )
            )
        return OutreachPreview(campaign_id=campaign_id, items=items)

    def execute(self, context: JobContext, campaign_id: int, request: OutreachRequest) -> dict[str, Any]:
        campaign = self.campaigns.get(campaign_id)
        if not campaign:
            raise LookupError("campaign not found")
        provider_name = request.provider or self.settings.public().provider
        provider = self.providers.get(provider_name)
        if request.live:
            self.settings.assert_live_send_allowed(provider_name)
        else:
            # Dry-runs deliberately use the deterministic mock provider. A configured
            # real adapter is never contacted by a preview or ordinary campaign run.
            provider = self.providers.get("mock")
        leads = [lead for lead in self.leads.list(request.lead_ids) if self.leads.is_outreach_eligible(lead["id"])]
        self.campaigns.set_status(campaign_id, "running")
        sent = 0
        failed = 0
        skipped = 0
        try:
            for index, lead in enumerate(leads, start=1):
                context.update_progress(int((index - 1) / max(1, len(leads)) * 100))
                subject = render_template(request.subject, lead)
                body = render_template(request.body_template, lead)
                if self.events.has_successful(campaign_id, lead["id"], subject, body, not request.live):
                    skipped += 1
                    continue
                try:
                    result = provider.send(EmailMessage(lead["email"], subject, body))
                    self.events.create(campaign_id, lead["id"], provider.name, "dry_run" if result.dry_run else "sent", subject, body, result.dry_run, result.provider_message_id)
                    sent += 1
                except Exception as exc:
                    failed += 1
                    self.events.create(campaign_id, lead["id"], provider.name, "failed", subject, body, not request.live, error=str(exc))
        except JobCancelled:
            self.campaigns.set_status(campaign_id, "paused")
            raise
        if failed and failed == len(leads) - skipped:
            self.campaigns.set_status(campaign_id, "failed")
            raise RuntimeError(f"all {failed} outreach attempts failed")
        try:
            context.update_progress(100)
        except JobCancelled:
            self.campaigns.set_status(campaign_id, "paused")
            raise
        self.campaigns.set_status(campaign_id, "completed_with_errors" if failed else "completed")
        return {"campaign_id": campaign_id, "processed": len(leads), "completed": sent, "failed": failed, "skipped": skipped, "dry_run": not request.live}
