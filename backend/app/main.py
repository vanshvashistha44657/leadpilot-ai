from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI

from .api.routes import router
from .api.sales_routes import router as sales_router
from .config import Settings
from .db import Database
from .dependencies import Services
from .logging_config import configure_logging
from .middleware import LocalAuthMiddleware, RequestIDMiddleware
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
    DraftRepository,
    ImportBatchRepository,
)
from .repositories_sales import (
    FollowUpRepository,
    PackageRepository,
    PaymentRepository,
    ProposalRepository,
    RenewalRepository,
    SalesMetricsRepository,
)
from .repositories_gmail import GmailAccountRepository, GmailDraftReferenceRepository, GmailSyncRepository
from .services.ai import AIService
from .services.gmail import GmailService
from .services.imports import LeadImportService
from .services.jobs import JobQueue
from .services.metrics import MetricsService
from .services.outreach import OutreachService
from .services.followups import FollowUpService
from .services.providers import ProviderRegistry
from .services.settings import SettingsService
from .services.drafts import DraftService
from .services.gmail_drafts import GmailDraftWorkflowService
from .services.gmail_sync import GmailSyncService


def create_app(settings: Settings | None = None) -> FastAPI:
    app_settings = settings or Settings.from_env()
    configure_logging(app_settings.log_level)
    database = Database(app_settings.database_path)
    database.initialize()

    leads = LeadRepository(database)
    campaigns = CampaignRepository(database)
    jobs = JobRepository(database)
    events = OutreachRepository(database)
    replies = ReplyRepository(database)
    clients = ClientRepository(database)
    packages = PackageRepository(database)
    proposals = ProposalRepository(database)
    payments = PaymentRepository(database)
    renewals = RenewalRepository(database)
    follow_ups = FollowUpRepository(database)
    sales_metrics = SalesMetricsRepository(database)
    settings_repo = SettingsRepository(database)
    ai_usage = AIUsageRepository(database)
    drafts = DraftRepository(database)
    import_batches = ImportBatchRepository(database)
    gmail_accounts = GmailAccountRepository(database)
    gmail_draft_references = GmailDraftReferenceRepository(database)
    gmail_sync = GmailSyncRepository(database)
    alerts = AlertRepository(database)
    audit = AuditRepository(database)
    gmail = GmailService()
    providers = ProviderRegistry(gmail=gmail)
    ai = AIService(settings_repository=settings_repo)
    settings_service = SettingsService(app_settings, settings_repo, providers)
    jobs.reconcile_interrupted()
    queue = JobQueue(jobs, can_start=lambda: not settings_service.public().automation_paused)
    services = Services(
        database=database,
        settings=app_settings,
        leads=leads,
        campaigns=campaigns,
        jobs=jobs,
        events=events,
        settings_repo=settings_repo,
        alerts=alerts,
        audit=audit,
        providers=providers,
        ai=ai,
        gmail=gmail,
        settings_service=settings_service,
        imports=LeadImportService(leads, app_settings.batch_size),
        outreach=OutreachService(campaigns, leads, events, providers, settings_service),
        metrics=MetricsService(leads, campaigns, events, jobs, alerts, replies, clients, sales_metrics),
        queue=queue,
        replies=replies,
        clients=clients,
        packages=packages,
        proposals=proposals,
        payments=payments,
        renewals=renewals,
        follow_ups=follow_ups,
        followups=FollowUpService(leads, follow_ups, campaigns),
        ai_usage=ai_usage,
        drafts=drafts,
        draft_service=DraftService(leads, drafts, ai, ai_usage),
        import_batches=import_batches,
        gmail_accounts=gmail_accounts,
        gmail_draft_references=gmail_draft_references,
        gmail_sync=gmail_sync,
        gmail_draft_workflow=GmailDraftWorkflowService(leads, drafts, gmail_draft_references, gmail),
        gmail_sync_service=GmailSyncService(gmail, leads, gmail_sync, gmail_accounts),
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        yield
        gmail.close()
        queue.shutdown()

    app = FastAPI(
        title="LeadPilot AI Backend",
        version="0.1.0",
        description="Local-first lead operations, outreach dry-runs, fulfillment, and reporting API.",
        lifespan=lifespan,
    )
    app.state.services = services
    app.state.settings = app_settings
    app.add_middleware(RequestIDMiddleware)
    app.add_middleware(LocalAuthMiddleware, settings=app_settings)
    app.include_router(router)
    app.include_router(sales_router)
    return app


app = create_app()
