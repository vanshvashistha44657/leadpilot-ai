from __future__ import annotations

from datetime import datetime, timezone
import csv
import io
import json
import shutil
import zipfile
from pathlib import Path
from typing import Annotated
from uuid import uuid4
from urllib.parse import parse_qs, urlparse
from xml.etree import ElementTree

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile
from fastapi.responses import StreamingResponse

from ..dependencies import Services, get_services
from ..models import (
    AlertCreate,
    AlertOut,
    AIPersonalizationPreview,
    AIPersonalizationRequest,
    AIReplyClassificationPreview,
    AIReplyClassificationRequest,
    AIBriefPreview,
    AIUsageSummary,
    AIProviderConfigOut,
    AIProviderConfigUpdate,
    AIConnectivityResult,
    AIProviderStatus,
    AuditLogOut,
    BriefRequest,
    BriefResponse,
    CampaignCreate,
    CampaignOut,
    DashboardMetrics,
    GmailAuthUrl,
    GmailDisconnectOut,
    GmailReviewedDraftOut,
    GmailReviewedDraftRequest,
    GmailHealth,
    GmailSyncOut,
    GmailSyncRequest,
    GmailThreadOut,
    GmailStatus,
    HealthResponse,
    ImportResult,
    ImportPreview,
    PersonalizedDraftRequest,
    DraftOut,
    DraftUpdate,
    JobOut,
    LeadCreate,
    LeadOut,
    OutreachPreview,
    OutreachRequest,
    OutreachEventOut,
    PricingRequest,
    PricingResult,
    ProviderStatus,
    PublicSettings,
    SettingsUpdate,
    SuppressionCreate,
    SuppressionOut,
    LeadResearchUpdate,
    LeadResearchOut,
    ReplyIngest,
    ReplyOut,
    ClientCreate,
    ClientOut,
    ProjectCreate,
    ProjectOut,
)
from ..services.normalization import clean_text, normalize_email
from ..services.pricing import calculate_pricing
from ..services.briefs import generate_client_brief
from ..services.research import score_verified_lead, score_factors
from ..services.replies import classify_reply
from ..services.ai import AIProviderError, AIUnavailableError
from ..services.drafts import DraftRateLimitError, DraftSuppressedError
from ..services.gmail import GmailApiError, GmailUnavailableError
from ..services.gmail_drafts import (
    ReviewedDraftError,
    ReviewedDraftFailedError,
    ReviewedDraftPendingError,
    ReviewedDraftProviderError,
    ReviewedDraftProviderUnavailableError,
)
from ..services.jobs import JobCancelled

router = APIRouter()
ServiceDep = Annotated[Services, Depends(get_services)]


def _job_out(job: dict) -> JobOut:
    return JobOut.model_validate(job)


@router.get("/health/live", response_model=HealthResponse, tags=["health"])
def live_health(services: ServiceDep) -> HealthResponse:
    return HealthResponse(status="ok", database="not_checked", migration_version=0)


@router.get("/health/ready", response_model=HealthResponse, tags=["health"])
def ready_health(services: ServiceDep) -> HealthResponse:
    try:
        with services.database.session() as connection:
            version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            connection.execute("SELECT 1").fetchone()
        return HealthResponse(status="ready", database="ok", migration_version=version)
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"database unavailable: {exc}") from exc


@router.get("/api/leads", response_model=list[LeadOut], tags=["leads"])
def list_leads(
    services: ServiceDep,
    limit: int = Query(default=100, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
    search: str | None = Query(default=None, max_length=200),
) -> list[LeadOut]:
    return [LeadOut.model_validate(row) for row in services.leads.list(limit=limit, offset=offset, search=search)]


@router.get("/api/leads/count", tags=["leads"])
def count_leads(services: ServiceDep, search: str | None = Query(default=None, max_length=200)) -> dict[str, int]:
    return {"total": services.leads.count_filtered(search)}


@router.post("/api/leads", response_model=LeadOut, status_code=201, tags=["leads"])
def create_lead(payload: LeadCreate, services: ServiceDep) -> LeadOut:
    try:
        normalized = normalize_email(payload.email)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if services.leads.suppressed_emails([normalized]):
        raise HTTPException(status_code=409, detail="lead is suppressed")
    if services.leads.existing_emails([normalized]):
        raise HTTPException(status_code=409, detail="lead already exists")
    services.leads.insert_many(
        [
            {
                "email": payload.email.strip(),
                "normalized_email": normalized,
                "first_name": clean_text(payload.first_name),
                "last_name": clean_text(payload.last_name),
                "company": clean_text(payload.company),
                "title": clean_text(payload.title),
                "source": clean_text(payload.source) or "api",
                "metadata": payload.metadata,
            }
        ]
    )
    services.audit.record("lead.created", "local", {"normalized_email": normalized})
    return LeadOut.model_validate(services.leads.get_by_email(normalized))


@router.post("/api/leads/import", response_model=ImportResult, tags=["leads"])
def import_leads(services: ServiceDep, file: UploadFile = File(...), mapping: str | None = Query(default=None, max_length=4000)) -> ImportResult:
    if not file.filename or not file.filename.lower().endswith((".csv", ".xlsx")):
        raise HTTPException(status_code=422, detail="upload a .csv or .xlsx file")
    batch_id: str | None = None
    try:
        parsed_mapping = json.loads(mapping) if mapping else None
        if parsed_mapping is not None and not isinstance(parsed_mapping, dict):
            raise ValueError("mapping must be a JSON object")
        batch_id = str(uuid4())
        services.import_batches.create(batch_id, Path(file.filename).name, Path(file.filename).suffix.lower().lstrip("."))
        result = services.imports.process(file.file, file.filename, mapping=parsed_mapping, batch_id=batch_id)
        services.import_batches.complete(batch_id, result)
    except (ValueError, zipfile.BadZipFile, ElementTree.ParseError) as exc:
        if batch_id:
            services.import_batches.fail(batch_id, str(exc), error_code="direct_import_error")
        raise HTTPException(status_code=422, detail=f"could not read upload: {exc}") from exc
    result.setdefault("skipped", 0)
    result["batch_id"] = batch_id
    services.audit.record("lead.file_imported", "local", {"filename": Path(file.filename).name, "result": {key: value for key, value in result.items() if key not in {"errors"}}})
    return ImportResult.model_validate(result)


@router.post("/api/leads/import/preview", response_model=ImportPreview, tags=["leads"])
def preview_lead_import(services: ServiceDep, file: UploadFile = File(...)) -> ImportPreview:
    if not file.filename or not file.filename.lower().endswith((".csv", ".xlsx")):
        raise HTTPException(status_code=422, detail="upload a .csv or .xlsx file")
    try:
        preview = services.imports.preview(file.file, Path(file.filename).name)
    except (ValueError, zipfile.BadZipFile, ElementTree.ParseError) as exc:
        raise HTTPException(status_code=413 if "limit" in str(exc).lower() or "size" in str(exc).lower() else 422, detail=f"could not preview upload: {exc}") from exc
    return ImportPreview.model_validate(preview)


@router.post("/api/leads/import/queue", response_model=JobOut, status_code=202, tags=["leads", "jobs"])
def queue_lead_import(services: ServiceDep, file: UploadFile = File(...), mapping: str | None = Query(default=None, max_length=4000)) -> JobOut:
    if not file.filename or not file.filename.lower().endswith((".csv", ".xlsx")):
        raise HTTPException(status_code=422, detail="upload a .csv or .xlsx file")
    try:
        parsed_mapping = json.loads(mapping) if mapping else None
        if parsed_mapping is not None and not isinstance(parsed_mapping, dict):
            raise ValueError("mapping must be a JSON object")
        file.file.seek(0, 2)
        size = file.file.tell()
        file.file.seek(0)
        if size > services.imports.MAX_BYTES:
            raise HTTPException(status_code=413, detail="upload exceeds the 25 MB limit")
    except (OSError, ValueError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    batch_id = str(uuid4())
    services.import_batches.create(batch_id, Path(file.filename).name, Path(file.filename).suffix.lower().lstrip("."))
    incoming = services.database.path.parent / "incoming"
    destination = incoming / f"{uuid4().hex}-{Path(file.filename).name}"
    try:
        incoming.mkdir(parents=True, exist_ok=True)
        file.file.seek(0)
        with destination.open("wb") as target:
            shutil.copyfileobj(file.file, target, length=1024 * 1024)
    except Exception as exc:
        try:
            destination.unlink(missing_ok=True)
        except OSError:
            pass
        services.import_batches.fail(batch_id, str(exc), error_code="staging_error")
        raise HTTPException(status_code=500, detail=f"could not stage upload: {exc}") from exc

    def run_import(context, payload):
        try:
            staged_path = Path(payload["staged_path"])
            with staged_path.open("rb") as source:
                result = services.imports.process(
                    source,
                    payload["filename"],
                    checkpoint=context.check_cancelled,
                    mapping=payload.get("mapping"),
                    batch_id=payload["batch_id"],
                )
            result.setdefault("skipped", 0)
            result["batch_id"] = payload["batch_id"]
            services.import_batches.complete(payload["batch_id"], result)
            context.update_progress(100)
            services.audit.record("lead.import_completed", "local", {"filename": Path(payload["filename"]).name, "result": {key: value for key, value in result.items() if key not in {"errors"}}})
            return result
        except JobCancelled:
            raise
        except Exception as exc:
            services.import_batches.fail(payload["batch_id"], str(exc), error_code="worker_processing_error")
            raise

    def cleanup_staged_file(job_id: str) -> None:
        current = services.jobs.get(job_id)
        if not current or current["status"] != "failed":
            destination.unlink(missing_ok=True)

    try:
        job = services.queue.submit("lead_import", {"filename": file.filename, "staged_path": str(destination), "mapping": parsed_mapping, "batch_id": batch_id}, run_import, cleanup=cleanup_staged_file)
    except Exception as exc:
        services.import_batches.fail(batch_id, str(exc), error_code="queue_submission_error")
        raise HTTPException(status_code=500, detail=f"could not queue import: {exc}") from exc
    services.audit.record("lead.import_queued", "local", {"filename": file.filename, "job_id": job["id"]})
    return _job_out(job)


@router.get("/api/leads/export.csv", tags=["leads"])
def export_leads(services: ServiceDep, search: str | None = Query(default=None, max_length=200)) -> StreamingResponse:
    """Stream a clean lead export instead of materializing the whole database."""

    def rows():
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(["id", "email", "first_name", "last_name", "company", "title", "source", "status", "created_at"])
        yield output.getvalue()
        output.seek(0)
        output.truncate(0)
        for lead in services.leads.iter_rows(search=search):
            writer.writerow([lead.get(key, "") for key in ("id", "email", "first_name", "last_name", "company", "title", "source", "status", "created_at")])
            yield output.getvalue()
            output.seek(0)
            output.truncate(0)

    services.audit.record("lead.csv_exported", "local", {"search": search})
    return StreamingResponse(rows(), media_type="text/csv", headers={"Content-Disposition": "attachment; filename=leadpilot-leads.csv"})


@router.get("/api/leads/{lead_id}", response_model=LeadOut, tags=["leads"])
def get_lead(lead_id: int, services: ServiceDep) -> LeadOut:
    lead = services.leads.get(lead_id)
    if not lead:
        raise HTTPException(status_code=404, detail="lead not found")
    return LeadOut.model_validate(lead)


@router.get("/api/leads/{lead_id}/history", response_model=list[OutreachEventOut], tags=["leads"])
def lead_history(lead_id: int, services: ServiceDep) -> list[OutreachEventOut]:
    if not services.leads.get(lead_id):
        raise HTTPException(status_code=404, detail="lead not found")
    return [OutreachEventOut.model_validate(row) for row in services.events.list_for_lead(lead_id)]


@router.post("/api/suppressions", response_model=SuppressionOut, status_code=201, tags=["leads"])
def add_suppression(payload: SuppressionCreate, services: ServiceDep) -> SuppressionOut:
    try:
        normalized = normalize_email(payload.email)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    result = services.leads.add_suppression(normalized, payload.reason)
    services.leads.mark_suppressed(normalized)
    services.audit.record("lead.suppressed", "local", {"normalized_email": normalized, "reason": payload.reason})
    return SuppressionOut.model_validate(result)


@router.get("/api/suppressions", response_model=list[SuppressionOut], tags=["leads"])
def list_suppressions(services: ServiceDep, limit: int = Query(default=500, ge=1, le=5000)) -> list[SuppressionOut]:
    with services.database.session() as connection:
        rows = connection.execute("SELECT * FROM suppressions ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    return [SuppressionOut.model_validate(dict(row)) for row in rows]


@router.post("/api/leads/{lead_id}/research", response_model=LeadResearchOut, tags=["research"])
def research_lead(lead_id: int, payload: LeadResearchUpdate, services: ServiceDep) -> LeadResearchOut:
    lead = services.leads.get(lead_id)
    if not lead:
        raise HTTPException(status_code=404, detail="lead not found")
    if payload.website_url and not payload.website_url.lower().startswith(("http://", "https://")):
        raise HTTPException(status_code=422, detail="website_url must use http:// or https://")
    score = score_verified_lead(lead, payload.website_url)
    factors = score_factors(lead, payload.website_url)
    updated = services.leads.update_research(
        lead_id,
        score=score,
        status="reviewed",
        website_url=payload.website_url,
        notes=payload.verified_notes,
        score_version="v1",
        score_factors=factors,
        research_source=payload.source,
    )
    services.audit.record("lead.research_reviewed", "local", {"lead_id": lead_id, "source": payload.source, "score": score})
    return LeadResearchOut(
        lead_id=lead_id,
        opportunity_score=score,
        research_status="reviewed",
        website_url=updated.get("website_url") if updated else payload.website_url,
        research_notes=updated.get("research_notes") if updated else payload.verified_notes,
        source=payload.source,
    )


@router.post("/api/replies/ingest", response_model=ReplyOut, status_code=201, tags=["replies"])
def ingest_reply(payload: ReplyIngest, services: ServiceDep) -> ReplyOut:
    try:
        normalized = normalize_email(payload.email)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    lead = services.leads.get_by_email(normalized)
    if not lead:
        raise HTTPException(status_code=404, detail="reply email does not match a stored lead")
    classification = classify_reply(payload.subject, payload.body)
    reply = services.replies.create(lead["id"], payload.provider, payload.subject, payload.body, classification)
    if classification in {"unsubscribe", "bounce"}:
        reason = "unsubscribe request" if classification == "unsubscribe" else "provider bounce"
        services.leads.add_suppression(normalized, reason)
        services.leads.mark_status(normalized, "unsubscribed" if classification == "unsubscribe" else "bounced")
    else:
        services.leads.mark_status(normalized, "replied")
    if classification in {"interested", "pricing", "meeting"}:
        services.alerts.create("info", f"High-intent {classification} reply from {lead.get('company') or lead['email']}")
    services.audit.record("reply.ingested", "local", {"lead_id": lead["id"], "classification": classification})
    return ReplyOut.model_validate(reply)


@router.get("/api/leads/{lead_id}/replies", response_model=list[ReplyOut], tags=["replies"])
def list_lead_replies(lead_id: int, services: ServiceDep) -> list[ReplyOut]:
    if not services.leads.get(lead_id):
        raise HTTPException(status_code=404, detail="lead not found")
    return [ReplyOut.model_validate(row) for row in services.replies.list_for_lead(lead_id)]


@router.post("/api/campaigns", response_model=CampaignOut, status_code=201, tags=["campaigns"])
def create_campaign(payload: CampaignCreate, services: ServiceDep) -> CampaignOut:
    campaign = services.campaigns.create(payload.name, payload.dry_run)
    services.audit.record("campaign.created", "local", {"campaign_id": campaign["id"], "dry_run": payload.dry_run})
    return CampaignOut.model_validate(campaign)


@router.get("/api/campaigns", response_model=list[CampaignOut], tags=["campaigns"])
def list_campaigns(services: ServiceDep) -> list[CampaignOut]:
    return [CampaignOut.model_validate(row) for row in services.campaigns.list()]


@router.post("/api/campaigns/{campaign_id}/outreach/preview", response_model=OutreachPreview, tags=["outreach"])
@router.post("/api/campaigns/{campaign_id}/outreach/dry-run", response_model=OutreachPreview, tags=["outreach"])
def preview_outreach(campaign_id: int, payload: OutreachRequest, services: ServiceDep) -> OutreachPreview:
    try:
        return services.outreach.preview(campaign_id, payload)
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.post("/api/campaigns/{campaign_id}/outreach/run", response_model=JobOut, status_code=202, tags=["outreach"])
def run_outreach(campaign_id: int, payload: OutreachRequest, services: ServiceDep) -> JobOut:
    campaign = services.campaigns.get(campaign_id)
    if not campaign:
        raise HTTPException(status_code=404, detail="campaign not found")
    try:
        services.settings_service.assert_automation_allowed()
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if payload.live:
        if campaign["dry_run"]:
            raise HTTPException(status_code=409, detail="campaign is configured for dry-run")
        try:
            services.settings_service.assert_live_send_allowed(payload.provider)
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
    job = services.queue.submit(
        "campaign_outreach",
        {"campaign_id": campaign_id, "request": payload.model_dump()},
        lambda context, data: services.outreach.execute(
            context, data["campaign_id"], OutreachRequest.model_validate(data["request"])
        ),
    )
    services.audit.record("campaign.outreach_queued", "local", {"campaign_id": campaign_id, "job_id": job["id"], "live": payload.live})
    return _job_out(job)


@router.post("/api/automation/stop", response_model=PublicSettings, tags=["operations"])
def stop_automation(services: ServiceDep) -> PublicSettings:
    services.settings_repo.update({"automation_paused": "true"})
    cancelled = services.jobs.cancel_active()
    services.audit.record("automation.stopped", "local", {"jobs_cancelled": cancelled})
    return services.settings_service.public()


@router.post("/api/automation/resume", response_model=PublicSettings, tags=["operations"])
def resume_automation(services: ServiceDep) -> PublicSettings:
    services.settings_repo.update({"automation_paused": "false"})
    services.audit.record("automation.resumed", "local")
    return services.settings_service.public()


@router.get("/api/jobs", response_model=list[JobOut], tags=["jobs"])
def list_jobs(services: ServiceDep) -> list[JobOut]:
    return [_job_out(job) for job in services.jobs.list()]


@router.get("/api/jobs/{job_id}", response_model=JobOut, tags=["jobs"])
def get_job(job_id: str, services: ServiceDep) -> JobOut:
    job = services.jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="job not found")
    return _job_out(job)


@router.post("/api/jobs/{job_id}/cancel", response_model=JobOut, tags=["jobs"])
def cancel_job(job_id: str, services: ServiceDep) -> JobOut:
    job = services.jobs.cancel(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="job not found or no longer cancellable")
    return _job_out(job)


@router.post("/api/jobs/{job_id}/retry", response_model=JobOut, tags=["jobs"])
def retry_job(job_id: str, services: ServiceDep) -> JobOut:
    job = services.queue.retry(job_id)
    if not job:
        raise HTTPException(status_code=409, detail="job cannot be retried in this process")
    return _job_out(job)


@router.post("/api/pricing/calculate", response_model=PricingResult, tags=["pricing"])
def calculate_price(payload: PricingRequest) -> PricingResult:
    return calculate_pricing(payload)


@router.get("/api/dashboard/metrics", response_model=DashboardMetrics, tags=["dashboard"])
def dashboard_metrics(services: ServiceDep) -> DashboardMetrics:
    return services.metrics.dashboard()


@router.get("/api/settings", response_model=PublicSettings, tags=["settings"])
def get_settings(services: ServiceDep) -> PublicSettings:
    return services.settings_service.public()


@router.patch("/api/settings", response_model=PublicSettings, tags=["settings"])
def update_settings(payload: SettingsUpdate, services: ServiceDep) -> PublicSettings:
    try:
        result = services.settings_service.update(payload)
    except (ValueError, KeyError) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    services.audit.record("settings.updated", "local", {"keys": list(payload.model_dump(exclude_none=True))})
    return result


@router.get("/api/providers", response_model=list[ProviderStatus], tags=["settings"])
def provider_status(services: ServiceDep) -> list[ProviderStatus]:
    return [services.providers.status(name) for name in ("mock", "gmail", "graph")]


@router.get("/api/ai/status", response_model=AIProviderStatus, tags=["ai"])
def ai_status(services: ServiceDep) -> AIProviderStatus:
    return services.ai.status()


@router.get("/api/ai/config", response_model=AIProviderConfigOut, tags=["ai"])
def ai_config(services: ServiceDep) -> AIProviderConfigOut:
    return services.ai.config()


@router.patch("/api/ai/config", response_model=AIProviderConfigOut, tags=["ai"])
def update_ai_config(payload: AIProviderConfigUpdate, services: ServiceDep) -> AIProviderConfigOut:
    try:
        result = services.ai.update_config(payload)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    services.audit.record("ai.config_updated", "local", {"keys": list(payload.model_dump(exclude_none=True))})
    return result


@router.post("/api/ai/connectivity", response_model=AIConnectivityResult, tags=["ai"])
def ai_connectivity(services: ServiceDep) -> AIConnectivityResult:
    result = services.ai.check_connectivity()
    if result.status == "connected" and result.usage is not None:
        services.ai_usage.record(
            operation="connectivity_check",
            provider=result.provider,
            model=result.model or "",
            request_id=result.request_id,
            prompt_tokens=result.usage.prompt_tokens,
            completion_tokens=result.usage.completion_tokens,
            total_tokens=result.usage.total_tokens,
            estimated_cost_usd=result.usage.estimated_cost_usd,
        )
    return result


@router.post("/api/ai/personalization/preview", response_model=AIPersonalizationPreview, tags=["ai"])
def ai_personalization_preview(payload: AIPersonalizationRequest, services: ServiceDep) -> AIPersonalizationPreview:
    try:
        result = services.ai.personalize(payload)
    except AIUnavailableError as exc:
        raise HTTPException(status_code=503, detail=f"AI personalization unavailable: {exc}") from exc
    except AIProviderError as exc:
        raise HTTPException(status_code=502, detail=f"AI personalization provider error: {exc}") from exc
    services.ai_usage.record(
        operation="personalization",
        provider=result.provider,
        model=result.model,
        request_id=result.request_id,
        prompt_tokens=result.usage.prompt_tokens,
        completion_tokens=result.usage.completion_tokens,
        total_tokens=result.usage.total_tokens,
        estimated_cost_usd=result.usage.estimated_cost_usd,
    )
    return AIPersonalizationPreview(
        provider=result.provider,
        model=result.model,
        result=result.output,
        usage=result.usage,
        request_id=result.request_id,
    )


@router.post("/api/ai/reply-classification/preview", response_model=AIReplyClassificationPreview, tags=["ai"])
def ai_reply_classification_preview(payload: AIReplyClassificationRequest, services: ServiceDep) -> AIReplyClassificationPreview:
    try:
        result = services.ai.classify_reply(payload.subject, payload.body)
    except AIUnavailableError as exc:
        raise HTTPException(status_code=503, detail=f"AI reply classification unavailable: {exc}") from exc
    except AIProviderError as exc:
        raise HTTPException(status_code=502, detail=f"AI reply classification provider error: {exc}") from exc
    services.ai_usage.record(
        operation="reply_classification",
        provider=result.provider,
        model=result.model,
        request_id=result.request_id,
        prompt_tokens=result.usage.prompt_tokens,
        completion_tokens=result.usage.completion_tokens,
        total_tokens=result.usage.total_tokens,
        estimated_cost_usd=result.usage.estimated_cost_usd,
    )
    return AIReplyClassificationPreview(provider=result.provider, model=result.model, result=result.output, usage=result.usage, request_id=result.request_id)


@router.post("/api/ai/brief/preview", response_model=AIBriefPreview, tags=["ai"])
def ai_brief_preview(payload: BriefRequest, services: ServiceDep) -> AIBriefPreview:
    try:
        result = services.ai.generate_brief(payload)
    except AIUnavailableError as exc:
        raise HTTPException(status_code=503, detail=f"AI brief generation unavailable: {exc}") from exc
    except AIProviderError as exc:
        raise HTTPException(status_code=502, detail=f"AI brief generation provider error: {exc}") from exc
    services.ai_usage.record(
        operation="brief_generation",
        provider=result.provider,
        model=result.model,
        request_id=result.request_id,
        prompt_tokens=result.usage.prompt_tokens,
        completion_tokens=result.usage.completion_tokens,
        total_tokens=result.usage.total_tokens,
        estimated_cost_usd=result.usage.estimated_cost_usd,
    )
    return AIBriefPreview(provider=result.provider, model=result.model, result=result.output, usage=result.usage, request_id=result.request_id)


@router.get("/api/ai/usage", response_model=AIUsageSummary, tags=["ai"])
def ai_usage_summary(services: ServiceDep) -> AIUsageSummary:
    return AIUsageSummary.model_validate(services.ai_usage.summary())


@router.post("/api/drafts/generate", response_model=DraftOut, tags=["drafts"])
def generate_personalized_draft(payload: PersonalizedDraftRequest, services: ServiceDep) -> DraftOut:
    try:
        draft = services.draft_service.generate(payload)
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except DraftSuppressedError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except DraftRateLimitError as exc:
        raise HTTPException(status_code=429, detail=str(exc)) from exc
    except AIUnavailableError as exc:
        services.audit.record("draft.generation_failed", "local", {"lead_id": payload.lead_id, "category": "not_configured"})
        raise HTTPException(status_code=503, detail=f"AI draft generation unavailable: {exc}") from exc
    except AIProviderError as exc:
        services.audit.record("draft.generation_failed", "local", {"lead_id": payload.lead_id, "category": "provider_error"})
        raise HTTPException(status_code=502, detail=f"AI draft generation provider error: {exc}") from exc
    services.audit.record("draft.generated", "local", {"draft_id": draft.id, "lead_id": draft.lead_id, "status": draft.status, "provider": draft.provider, "model": draft.model})
    return draft


@router.get("/api/drafts", response_model=list[DraftOut], tags=["drafts"])
def list_personalized_drafts(services: ServiceDep, status: str | None = Query(default=None, max_length=20), limit: int = Query(default=100, ge=1, le=500), offset: int = Query(default=0, ge=0)) -> list[DraftOut]:
    return services.draft_service.list(status, limit, offset)


@router.patch("/api/drafts/{draft_id}", response_model=DraftOut, tags=["drafts"])
def update_personalized_draft(draft_id: str, payload: DraftUpdate, services: ServiceDep) -> DraftOut:
    try:
        draft = services.draft_service.update(draft_id, payload)
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    services.audit.record("draft.edited", "local", {"draft_id": draft_id, "lead_id": draft.lead_id})
    return draft


@router.get("/api/gmail/status", response_model=GmailStatus, tags=["gmail"])
def gmail_status(services: ServiceDep) -> GmailStatus:
    return services.gmail.public_status()


@router.get("/api/gmail/health", response_model=GmailHealth, tags=["gmail"])
def gmail_health(services: ServiceDep) -> GmailHealth:
    return services.gmail.health_check()


@router.post("/api/gmail/drafts/reviewed", response_model=GmailReviewedDraftOut, status_code=201, tags=["gmail"])
@router.post("/api/gmail/drafts", response_model=GmailReviewedDraftOut, status_code=201, tags=["gmail"])
def create_gmail_draft(payload: GmailReviewedDraftRequest, services: ServiceDep) -> GmailReviewedDraftOut:
    try:
        draft = services.gmail_draft_workflow.create_reviewed(payload.local_draft_id)
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ReviewedDraftPendingError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ReviewedDraftFailedError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ReviewedDraftProviderUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except ReviewedDraftProviderError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except ReviewedDraftError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    services.audit.record(
        "gmail.draft_created",
        "local",
        {
            "local_draft_id": draft["local_draft_id"],
            "status": draft["status"],
            "provider_draft_id": draft.get("provider_draft_id"),
            "provider_thread_id": draft.get("provider_thread_id"),
        },
    )
    return GmailReviewedDraftOut.model_validate(draft)


@router.post("/api/drafts/{draft_id}/gmail", response_model=GmailReviewedDraftOut, status_code=201, tags=["gmail"])
def create_reviewed_gmail_draft(draft_id: str, services: ServiceDep) -> GmailReviewedDraftOut:
    return create_gmail_draft(GmailReviewedDraftRequest(local_draft_id=draft_id), services)


@router.get("/api/gmail/threads", response_model=list[GmailThreadOut], tags=["gmail"])
def sync_gmail_threads(
    services: ServiceDep,
    query: str | None = Query(default=None, max_length=500),
    page_token: str | None = Query(default=None, max_length=500),
    max_results: int = Query(default=100, ge=1, le=500),
) -> list[GmailThreadOut]:
    try:
        page = services.gmail.sync_threads(query=query, page_token=page_token, max_results=max_results)
    except GmailUnavailableError as exc:
        raise HTTPException(status_code=503, detail="Gmail thread synchronization unavailable") from None
    except GmailApiError as exc:
        raise HTTPException(status_code=502, detail="Gmail thread synchronization failed") from None
    return [GmailThreadOut(thread_id=item.thread_id, snippet=item.snippet, history_id=item.history_id) for item in page.threads]


@router.post("/api/gmail/sync", response_model=GmailSyncOut, tags=["gmail"])
def synchronize_gmail(payload: GmailSyncRequest, services: ServiceDep) -> GmailSyncOut:
    try:
        result = services.gmail_sync_service.synchronize(**payload.model_dump())
    except GmailUnavailableError:
        services.gmail_sync.save_state(last_error="provider_unavailable")
        services.audit.record("gmail.sync_failed", "local", {"category": "unavailable"})
        raise HTTPException(status_code=503, detail="Gmail synchronization is unavailable") from None
    except GmailApiError:
        services.gmail_sync.save_state(last_error="provider_error")
        services.audit.record("gmail.sync_failed", "local", {"category": "provider_error"})
        raise HTTPException(status_code=502, detail="Gmail synchronization failed") from None
    services.audit.record(
        "gmail.sync_completed",
        "local",
        {
            key: result[key]
            for key in (
                "mode",
                "pages",
                "threads_seen",
                "threads_skipped",
                "threads_stored",
                "messages_seen",
                "messages_stored",
                "matched",
                "unknown",
                "ambiguous",
            )
            if key in result
        },
    )
    return GmailSyncOut.model_validate(result)


@router.get("/api/gmail/auth-url", response_model=GmailAuthUrl, tags=["gmail"])
def gmail_auth_url(services: ServiceDep, state: str | None = Query(default=None, max_length=500)) -> GmailAuthUrl:
    try:
        # A legacy query value is deliberately ignored: OAuth state authority
        # is always generated and retained by the server.
        authorization_url = services.gmail.authorization_url()
    except GmailUnavailableError as exc:
        raise HTTPException(status_code=503, detail="Gmail OAuth is unavailable") from None
    except ValueError as exc:
        raise HTTPException(status_code=503, detail="Gmail OAuth is unavailable") from None
    parsed_state = parse_qs(urlparse(authorization_url).query).get("state", [""])[0]
    return GmailAuthUrl(authorization_url=authorization_url, state=parsed_state)


@router.get("/api/gmail/oauth/callback", response_model=GmailStatus, tags=["gmail"])
def gmail_oauth_callback(
    services: ServiceDep,
    code: str | None = Query(default=None, min_length=1, max_length=5000),
    state: str = Query(..., min_length=1, max_length=500),
    error: str | None = Query(default=None, max_length=200),
) -> GmailStatus:
    if error is not None:
        raise HTTPException(status_code=400, detail="Gmail authorization was denied")
    if not code:
        raise HTTPException(status_code=400, detail="Gmail OAuth callback is missing an authorization code")
    try:
        status = services.gmail.exchange_code(code, state)
        health = services.gmail.health_check()
        if health.sender_identity is not None:
            status = status.model_copy(
                update={
                    "sender_email": health.sender_identity.email_address,
                    "sender_email_configured": True,
                    "health": health.status,
                }
            )
        services.gmail_accounts.upsert(
            email=health.sender_identity.email_address if health.sender_identity else status.sender_email,
            scopes=("https://www.googleapis.com/auth/gmail.compose", "https://www.googleapis.com/auth/gmail.readonly"),
        )
        return status
    except (GmailUnavailableError, GmailApiError, ValueError):
        # Do not reflect provider details, authorization codes, or state in a
        # browser-visible error response.
        raise HTTPException(status_code=400, detail="Gmail OAuth callback failed") from None


@router.post("/api/gmail/disconnect", response_model=GmailDisconnectOut, tags=["gmail"])
def disconnect_gmail(services: ServiceDep) -> GmailDisconnectOut:
    try:
        revoked = services.gmail.disconnect()
    except (GmailUnavailableError, GmailApiError):
        revoked = False
    services.gmail_accounts.disconnect()
    services.audit.record("gmail.disconnected", "local", {"provider_revoked": revoked})
    return GmailDisconnectOut(provider_revoked=revoked)


@router.post("/api/briefs/generate", response_model=BriefResponse, tags=["fulfillment"])
def generate_brief(payload: BriefRequest, services: ServiceDep) -> BriefResponse:
    result = generate_client_brief(payload)
    services.audit.record("fulfillment.brief_generated", "local", {"client_name": payload.client_name})
    return result


@router.post("/api/clients", response_model=ClientOut, status_code=201, tags=["clients"])
def create_client(payload: ClientCreate, services: ServiceDep) -> ClientOut:
    if payload.lead_id is not None and not services.leads.get(payload.lead_id):
        raise HTTPException(status_code=404, detail="lead not found")
    result = services.clients.create(payload.model_dump())
    services.audit.record("client.created", "local", {"client_id": result["id"]})
    return ClientOut.model_validate(result)


@router.get("/api/clients", response_model=list[ClientOut], tags=["clients"])
def list_clients(services: ServiceDep, limit: int = Query(default=100, ge=1, le=1000), offset: int = Query(default=0, ge=0)) -> list[ClientOut]:
    return [ClientOut.model_validate(row) for row in services.clients.list(limit=limit, offset=offset)]


@router.post("/api/projects", response_model=ProjectOut, status_code=201, tags=["fulfillment"])
def create_project(payload: ProjectCreate, services: ServiceDep) -> ProjectOut:
    try:
        result = services.clients.create_project(payload.model_dump())
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    services.audit.record("project.created", "local", {"project_id": result["id"], "client_id": payload.client_id})
    return ProjectOut.model_validate(result)


@router.get("/api/projects", response_model=list[ProjectOut], tags=["fulfillment"])
def list_projects(services: ServiceDep, client_id: int | None = None, limit: int = Query(default=100, ge=1, le=1000)) -> list[ProjectOut]:
    return [ProjectOut.model_validate(row) for row in services.clients.list_projects(client_id=client_id, limit=limit)]


@router.post("/api/alerts", response_model=AlertOut, status_code=201, tags=["operations"])
def create_alert(payload: AlertCreate, services: ServiceDep) -> AlertOut:
    return AlertOut.model_validate(services.alerts.create(payload.severity, payload.message))


@router.get("/api/alerts", response_model=list[AlertOut], tags=["operations"])
def list_alerts(services: ServiceDep, include_acknowledged: bool = False) -> list[AlertOut]:
    return [AlertOut.model_validate(row) for row in services.alerts.list(include_acknowledged)]


@router.post("/api/alerts/{alert_id}/acknowledge", response_model=AlertOut, tags=["operations"])
def acknowledge_alert(alert_id: int, services: ServiceDep) -> AlertOut:
    alert = services.alerts.acknowledge(alert_id)
    if not alert:
        raise HTTPException(status_code=404, detail="alert not found")
    return AlertOut.model_validate(alert)


@router.get("/api/audit-log", response_model=list[AuditLogOut], tags=["operations"])
def audit_log(services: ServiceDep, limit: int = Query(default=100, ge=1, le=1000)) -> list[AuditLogOut]:
    return [AuditLogOut.model_validate(row) for row in services.audit.list(limit)]


@router.post("/api/backup", tags=["operations"])
def backup_database(services: ServiceDep) -> dict[str, str | int]:
    directory = services.settings.backup_directory or services.database.path.parent / "backups"
    filename = f"leadpilot-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.db"
    destination = services.database.backup(Path(directory) / filename)
    services.audit.record("database.backup_created", "local", {"filename": filename})
    return {"path": str(destination), "size_bytes": destination.stat().st_size}
