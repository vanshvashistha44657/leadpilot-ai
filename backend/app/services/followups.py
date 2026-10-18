from __future__ import annotations

from typing import Any

from ..models import FollowUpQueueRequest
from ..repositories import CampaignRepository, LeadRepository
from ..repositories_sales import FollowUpRepository
from .outreach import render_template


class FollowUpService:
    """Queue-only follow-up planning; this service has no provider/send path."""

    def __init__(self, leads: LeadRepository, follow_ups: FollowUpRepository, campaigns: CampaignRepository):
        self.leads = leads
        self.follow_ups = follow_ups
        self.campaigns = campaigns

    def queue(self, request: FollowUpQueueRequest) -> list[dict[str, Any]]:
        if not request.dry_run:
            raise ValueError("follow-up queue only supports dry-run")
        campaign = self.campaigns.get(request.campaign_id)
        if not campaign:
            raise LookupError("campaign not found")
        if not campaign["dry_run"]:
            raise ValueError("follow-up queue requires a dry-run campaign")

        values: list[dict[str, Any]] = []
        for lead in self.leads.follow_up_candidates(request.lead_ids):
            values.append(
                {
                    "campaign_id": request.campaign_id,
                    "lead_id": lead["id"],
                    "sequence_number": request.sequence_number,
                    "scheduled_for": request.scheduled_for,
                    "provider": request.provider,
                    "subject": render_template(request.subject, lead),
                    "body": render_template(request.body_template, lead),
                }
            )
        return self.follow_ups.create_many(values)
