from __future__ import annotations

from dataclasses import dataclass

from fastapi import Request

from .config import Settings
from .db import Database
from .repositories import (
    AlertRepository,
    AuditRepository,
    CampaignRepository,
    JobRepository,
    LeadRepository,
    OutreachRepository,
    ReplyRepository,
    ClientRepository,
    SettingsRepository,
    AIUsageRepository,
)
from .repositories_sales import (
    FollowUpRepository,
    PackageRepository,
    PaymentRepository,
    ProposalRepository,
    RenewalRepository,
    SalesMetricsRepository,
)
from .services.ai import AIService
from .services.gmail import GmailService
from .services.imports import LeadImportService
from .services.jobs import JobQueue
from .services.metrics import MetricsService
from .services.outreach import OutreachService
from .services.followups import FollowUpService
from .services.providers import ProviderRegistry
from .services.settings import SettingsService


@dataclass(slots=True)
class Services:
    database: Database
    settings: Settings
    leads: LeadRepository
    campaigns: CampaignRepository
    jobs: JobRepository
    events: OutreachRepository
    settings_repo: SettingsRepository
    alerts: AlertRepository
    audit: AuditRepository
    providers: ProviderRegistry
    ai: AIService
    gmail: GmailService
    settings_service: SettingsService
    imports: LeadImportService
    outreach: OutreachService
    metrics: MetricsService
    queue: JobQueue
    replies: ReplyRepository
    clients: ClientRepository
    packages: PackageRepository
    proposals: ProposalRepository
    payments: PaymentRepository
    renewals: RenewalRepository
    follow_ups: FollowUpRepository
    followups: FollowUpService
    ai_usage: AIUsageRepository


def get_services(request: Request) -> Services:
    return request.app.state.services
