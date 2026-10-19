from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class LeadCreate(BaseModel):
    email: str
    first_name: str | None = None
    last_name: str | None = None
    company: str | None = None
    title: str | None = None
    source: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class LeadOut(LeadCreate):
    model_config = ConfigDict(from_attributes=True)
    id: int
    normalized_email: str
    status: str
    created_at: datetime
    updated_at: datetime
    opportunity_score: int = 0
    research_status: str = "unresearched"
    website_url: str | None = None
    research_notes: str | None = None
    score_version: str = "v1"
    score_factors: dict[str, Any] = Field(default_factory=dict)
    research_source: str | None = None
    research_verified_at: datetime | None = None


class ImportResult(BaseModel):
    imported: int
    duplicates: int
    suppressed: int
    invalid: int
    processed: int
    errors: list[str] = Field(default_factory=list)
    skipped: int = 0
    batch_id: str | None = None


class ImportPreview(BaseModel):
    filename: str
    file_type: Literal["csv", "xlsx"]
    columns: list[str]
    suggested_mapping: dict[str, str]
    sample_rows: list[dict[str, str]]
    row_count: int
    limit_exceeded: bool = False
    errors: list[str] = Field(default_factory=list)


class PersonalizedDraftRequest(BaseModel):
    lead_id: int = Field(gt=0)
    offer: str = Field(min_length=1, max_length=2000)
    tone: str = Field(default="professional", min_length=1, max_length=100)
    call_to_action: str = Field(min_length=1, max_length=1000)
    regenerate: bool = False


class DraftUpdate(BaseModel):
    subject: str = Field(min_length=1, max_length=500)
    body: str = Field(min_length=1, max_length=10000)


class DraftOut(BaseModel):
    id: str
    lead_id: int
    status: Literal["generated", "edited", "failed"]
    provider: str
    model: str
    subject: str
    body: str
    generated_subject: str
    generated_body: str
    offer: str
    tone: str
    call_to_action: str
    request_id: str | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None
    estimated_cost_usd: float | None = None
    error: str | None = None
    generated_at: datetime
    updated_at: datetime


class SuppressionCreate(BaseModel):
    email: str
    reason: str = Field(min_length=1, max_length=500)


class SuppressionOut(BaseModel):
    id: int
    normalized_email: str
    reason: str
    created_at: datetime


class LeadResearchUpdate(BaseModel):
    website_url: str | None = Field(default=None, max_length=1000)
    verified_notes: str | None = Field(default=None, max_length=4000)
    source: str = Field(default="operator_verified", min_length=1, max_length=200)


class LeadResearchOut(BaseModel):
    lead_id: int
    opportunity_score: int
    research_status: str
    website_url: str | None = None
    research_notes: str | None = None
    source: str


class CampaignCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    dry_run: bool = True


class CampaignOut(BaseModel):
    id: int
    name: str
    status: str
    dry_run: bool
    created_at: datetime
    updated_at: datetime


class OutreachRequest(BaseModel):
    subject: str = Field(min_length=1, max_length=500)
    body_template: str = Field(min_length=1, max_length=10000)
    lead_ids: list[int] | None = None
    provider: str | None = None
    live: bool = False


class OutreachPreviewItem(BaseModel):
    lead_id: int
    email: str
    subject: str
    body: str
    suppressed: bool = False


class OutreachPreview(BaseModel):
    campaign_id: int
    dry_run: Literal[True] = True
    items: list[OutreachPreviewItem]


class OutreachEventOut(BaseModel):
    id: int
    campaign_id: int
    lead_id: int
    provider: str
    status: str
    subject: str
    body: str
    dry_run: bool
    provider_message_id: str | None = None
    error: str | None = None
    created_at: datetime


class JobOut(BaseModel):
    id: str
    job_type: str
    status: str
    progress: int
    attempts: int
    max_attempts: int
    cancel_requested: bool
    payload: dict[str, Any]
    result: dict[str, Any] | None = None
    error: str | None = None
    created_at: datetime
    started_at: datetime | None = None
    finished_at: datetime | None = None
    updated_at: datetime


class PricingRequest(BaseModel):
    leads: int = Field(ge=0)
    price_per_lead: float = Field(ge=0)
    expected_close_rate: float = Field(default=0, ge=0, le=1)
    revenue_per_conversion: float = Field(default=0, ge=0)
    email_cost_per_lead: float = Field(default=0, ge=0)
    labor_cost: float = Field(default=0, ge=0)
    other_cost: float = Field(default=0, ge=0)
    platform_fee_percent: float = Field(default=0, ge=0, le=100)


class PricingResult(BaseModel):
    billable_revenue: float
    expected_conversions: float
    expected_downstream_revenue: float
    delivery_cost: float
    platform_fee: float
    total_cost: float
    net_profit: float
    margin_percent: float


class WebsitePackageCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=2000)
    setup_price: float = Field(default=0, ge=0)
    hosting_monthly_revenue: float = Field(default=0, ge=0)
    maintenance_monthly_revenue: float = Field(default=0, ge=0)
    delivery_labor_cost: float = Field(default=0, ge=0)
    ai_api_cost: float = Field(default=0, ge=0)
    domain_cost: float = Field(default=0, ge=0)
    database_cost: float = Field(default=0, ge=0)
    liability_cost: float = Field(default=0, ge=0)
    other_cost: float = Field(default=0, ge=0)
    active: bool = True


class WebsitePackageOut(WebsitePackageCreate):
    id: int
    created_at: datetime
    updated_at: datetime


class PackageProfitRequest(WebsitePackageCreate):
    months: int = Field(default=12, ge=1, le=120)


class PackageProfitResult(BaseModel):
    package_id: int | None = None
    setup_revenue: float
    hosting_monthly_revenue: float
    maintenance_monthly_revenue: float
    monthly_recurring_revenue: float
    upfront_cost: float
    upfront_profit: float
    first_year_revenue: float
    first_year_cost: float
    first_year_profit: float
    first_year_margin_percent: float
    months: int


class PackageRecommendationRequest(BaseModel):
    max_setup_price: float | None = Field(default=None, ge=0)
    max_monthly_price: float | None = Field(default=None, ge=0)
    requires_hosting: bool = False
    requires_maintenance: bool = False
    minimum_first_year_profit: float = 0


class PackageRecommendationOut(WebsitePackageOut):
    monthly_recurring_revenue: float
    first_year_profit: float
    first_year_margin_percent: float


class PackageRecommendationResponse(BaseModel):
    recommendations: list[PackageRecommendationOut]


class ProposalCreate(BaseModel):
    client_id: int = Field(gt=0)
    package_id: int | None = Field(default=None, gt=0)
    status: Literal["draft", "sent", "accepted", "rejected", "expired", "cancelled", "won", "paid", "active"] = "draft"
    amount: float | None = Field(default=None, ge=0)
    recurring_amount: float | None = Field(default=None, ge=0)
    valid_until: datetime | None = None
    notes: str | None = Field(default=None, max_length=4000)
    hosting_monthly_revenue: float | None = Field(default=None, ge=0)
    maintenance_monthly_revenue: float | None = Field(default=None, ge=0)
    delivery_labor_cost: float | None = Field(default=None, ge=0)
    ai_api_cost: float | None = Field(default=None, ge=0)
    domain_cost: float | None = Field(default=None, ge=0)
    database_cost: float | None = Field(default=None, ge=0)
    liability_cost: float | None = Field(default=None, ge=0)
    other_cost: float | None = Field(default=None, ge=0)


class ProposalOut(BaseModel):
    id: int
    client_id: int
    package_id: int | None = None
    status: str
    amount: float
    recurring_amount: float
    valid_until: datetime | None = None
    notes: str | None = None
    hosting_monthly_revenue: float
    maintenance_monthly_revenue: float
    delivery_labor_cost: float
    ai_api_cost: float
    domain_cost: float
    database_cost: float
    liability_cost: float
    other_cost: float
    created_at: datetime
    updated_at: datetime


class ProposalStatusUpdate(BaseModel):
    status: Literal["draft", "sent", "accepted", "rejected", "expired", "cancelled", "won", "paid", "active"]


class PaymentCreate(BaseModel):
    client_id: int = Field(gt=0)
    proposal_id: int | None = Field(default=None, gt=0)
    amount: float = Field(ge=0)
    status: Literal["pending", "paid", "failed", "refunded"] = "pending"
    paid_at: datetime | None = None


class PaymentOut(BaseModel):
    id: int
    client_id: int
    proposal_id: int | None = None
    amount: float
    status: str
    paid_at: datetime | None = None
    created_at: datetime


class PaymentStatusUpdate(BaseModel):
    status: Literal["pending", "paid", "failed", "refunded"]
    paid_at: datetime | None = None


class RenewalCreate(BaseModel):
    client_id: int = Field(gt=0)
    project_id: int | None = Field(default=None, gt=0)
    due_at: datetime
    amount: float = Field(ge=0)
    status: Literal["upcoming", "due", "paid", "overdue", "cancelled"] = "upcoming"


class RenewalOut(BaseModel):
    id: int
    client_id: int
    project_id: int | None = None
    due_at: datetime
    amount: float
    status: str
    created_at: datetime


class RenewalStatusUpdate(BaseModel):
    status: Literal["upcoming", "due", "paid", "overdue", "cancelled"]


class FollowUpQueueRequest(BaseModel):
    campaign_id: int = Field(gt=0)
    subject: str = Field(min_length=1, max_length=500)
    body_template: str = Field(min_length=1, max_length=10000)
    lead_ids: list[int] | None = None
    scheduled_for: datetime
    sequence_number: int = Field(default=1, ge=1, le=100)
    provider: str | None = Field(default=None, max_length=40)
    dry_run: Literal[True] = True


class FollowUpOut(BaseModel):
    id: int
    campaign_id: int
    lead_id: int
    sequence_number: int
    scheduled_for: datetime
    provider: str | None = None
    subject: str
    body: str
    status: str
    dry_run: Literal[True] = True
    error: str | None = None
    created_at: datetime
    updated_at: datetime
    executed_at: datetime | None = None


class DashboardMetrics(BaseModel):
    total_leads: int
    active_leads: int
    suppressed_leads: int
    campaigns: int
    dry_run_outreach_events: int
    live_outreach_events: int
    jobs_by_status: dict[str, int]
    pending_alerts: int
    total_replies: int = 0
    interested_replies: int = 0
    pricing_replies: int = 0
    meeting_replies: int = 0
    reviewed_leads: int = 0
    clients: int = 0
    projects: int = 0
    deliveries: int = 0
    bounces: int = 0
    replies: int = 0
    positive_intent: int = 0
    meetings: int = 0
    conversions: int = 0
    revenue: float = 0
    recurring_revenue: float = 0
    failures: int = 0


class SettingsUpdate(BaseModel):
    sender_name: str | None = Field(default=None, max_length=200)
    sender_email: str | None = Field(default=None, max_length=320)
    physical_address: str | None = Field(default=None, max_length=500)
    unsubscribe_url: str | None = Field(default=None, max_length=1000)
    compliance_acknowledged: bool | None = None
    dry_run: bool | None = None
    provider: str | None = Field(default=None, max_length=40)
    automation_paused: bool | None = None


class PublicSettings(BaseModel):
    dry_run: bool
    live_sending_enabled: bool
    live_send_ready: bool
    provider: str
    provider_configured: bool
    sender_name: str | None = None
    sender_email: str | None = None
    physical_address_configured: bool
    unsubscribe_url_configured: bool
    compliance_acknowledged: bool
    automation_paused: bool = False


class AlertCreate(BaseModel):
    severity: Literal["info", "warning", "critical"] = "info"
    message: str = Field(min_length=1, max_length=2000)


class AlertOut(BaseModel):
    id: int
    severity: str
    message: str
    acknowledged: bool
    created_at: datetime


class AuditLogOut(BaseModel):
    id: int
    action: str
    actor: str
    details: dict[str, Any]
    created_at: datetime


class ProviderStatus(BaseModel):
    name: str
    configured: bool
    supports_live_send: bool
    reason: str | None = None


class AIProviderStatus(BaseModel):
    name: str
    status: Literal["available", "unavailable", "error"]
    configured: bool
    model: str | None = None
    capabilities: list[str] = Field(default_factory=list)
    api_key_configured: bool = False
    reason: str


class AIProviderConfigOut(BaseModel):
    provider: str
    model: str | None = None
    base_url: str | None = None
    timeout_seconds: float
    max_retries: int
    retry_backoff_seconds: float
    api_key_configured: bool
    configuration_errors: list[str] = Field(default_factory=list)


class AIProviderConfigUpdate(BaseModel):
    provider: str | None = Field(default=None, min_length=1, max_length=80)
    model: str | None = Field(default=None, max_length=200)
    base_url: str | None = Field(default=None, max_length=2000)
    timeout_seconds: float | None = Field(default=None, ge=0.1, le=300)
    max_retries: int | None = Field(default=None, ge=0, le=5)
    retry_backoff_seconds: float | None = Field(default=None, ge=0, le=10)


class AIUsageMetadata(BaseModel):
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None
    estimated_cost_usd: float | None = None
    currency: Literal["USD"] = "USD"
    available: bool = False


class AIConnectivityResult(BaseModel):
    status: Literal[
        "connected",
        "not_configured",
        "invalid_configuration",
        "authentication_error",
        "rate_limited",
        "network_error",
        "timeout",
        "invalid_response",
        "provider_error",
    ]
    provider: str
    model: str | None = None
    detail: str
    checked_at: datetime
    request_id: str | None = None
    usage: AIUsageMetadata | None = None


class AIPersonalizationRequest(BaseModel):
    lead: dict[str, Any] = Field(default_factory=dict)
    offer: str = Field(min_length=1, max_length=2000)
    tone: str = Field(default="professional", min_length=1, max_length=100)
    call_to_action: str = Field(min_length=1, max_length=1000)
    subject_hint: str | None = Field(default=None, max_length=500)
    instructions: str | None = Field(default=None, max_length=4000)


class AIPersonalizationOutput(BaseModel):
    subject: str = Field(min_length=1, max_length=500)
    body: str = Field(min_length=1, max_length=10000)
    personalization_summary: str | None = Field(default=None, max_length=2000)


class AIPersonalizationPreview(BaseModel):
    provider: str
    model: str
    result: AIPersonalizationOutput
    usage: AIUsageMetadata
    request_id: str | None = None


class AIReplyClassificationOutput(BaseModel):
    classification: str = Field(min_length=1, max_length=100)
    confidence: float = Field(ge=0, le=1)
    rationale: str = Field(min_length=1, max_length=4000)


class AIBriefOutput(BaseModel):
    brief: str = Field(min_length=1, max_length=20000)
    key_points: list[str] = Field(default_factory=list, max_length=50)


class AIReplyClassificationRequest(BaseModel):
    subject: str | None = Field(default=None, max_length=500)
    body: str = Field(min_length=1, max_length=50000)


class AIReplyClassificationPreview(BaseModel):
    provider: str
    model: str
    result: AIReplyClassificationOutput
    usage: AIUsageMetadata
    request_id: str | None = None


class AIBriefPreview(BaseModel):
    provider: str
    model: str
    result: AIBriefOutput
    usage: AIUsageMetadata
    request_id: str | None = None


class AIUsageSummary(BaseModel):
    requests: int
    total_tokens: int
    estimated_cost_usd: float


class GmailStatus(BaseModel):
    configured: bool
    token_available: bool
    sender_email_configured: bool
    sender_email: str | None = None
    supports_live_send: bool
    health: Literal["not_checked", "healthy", "unhealthy"] = "not_checked"
    reason: str


class GmailAuthUrl(BaseModel):
    authorization_url: str
    state: str


class GmailReviewedDraftRequest(BaseModel):
    local_draft_id: str = Field(min_length=1, max_length=100)


class GmailReviewedDraftOut(BaseModel):
    local_draft_id: str
    status: Literal["pending", "created", "failed"]
    provider_draft_id: str | None = None
    provider_thread_id: str | None = None


class GmailSyncRequest(BaseModel):
    query: str | None = Field(default=None, max_length=500)
    page_token: str | None = Field(default=None, max_length=500)
    max_results: int = Field(default=100, ge=1, le=500)
    max_pages: int = Field(default=10, ge=1, le=100)


class GmailSyncOut(BaseModel):
    mode: Literal["full", "incremental", "full_resync"]
    pages: int
    threads_seen: int
    threads_skipped: int = 0
    threads_stored: int
    messages_seen: int
    messages_stored: int
    matched: int
    unknown: int
    ambiguous: int
    next_page_token: str | None = None
    history_id: str | None = None


class GmailDisconnectOut(BaseModel):
    status: Literal["disconnected"] = "disconnected"
    provider_revoked: bool


class GmailSenderIdentity(BaseModel):
    email_address: str
    messages_total: int | None = None
    threads_total: int | None = None


class GmailHealth(BaseModel):
    status: Literal["healthy", "unhealthy"]
    detail: str
    sender_identity: GmailSenderIdentity | None = None


class GmailDraftRequest(BaseModel):
    recipient: str = Field(min_length=3, max_length=320)
    subject: str = Field(min_length=1, max_length=500)
    body: str = Field(min_length=1, max_length=50000)
    thread_id: str | None = Field(default=None, max_length=200)


class GmailDraftOut(BaseModel):
    draft_id: str
    thread_id: str | None = None


class GmailThreadOut(BaseModel):
    thread_id: str
    snippet: str | None = None
    history_id: str | None = None


class BriefRequest(BaseModel):
    client_name: str = Field(min_length=1, max_length=200)
    offer: str = Field(min_length=1, max_length=1000)
    target_audience: str = Field(min_length=1, max_length=1000)
    tone: str = Field(default="professional", max_length=100)
    call_to_action: str = Field(min_length=1, max_length=500)


class BriefResponse(BaseModel):
    prompt: str
    brief: str


class ReplyIngest(BaseModel):
    email: str
    provider: str = Field(default="manual", max_length=40)
    subject: str | None = Field(default=None, max_length=500)
    body: str = Field(min_length=1, max_length=50000)


class ReplyOut(BaseModel):
    id: int
    lead_id: int
    provider: str
    subject: str | None = None
    body: str
    classification: str
    created_at: datetime


class ClientCreate(BaseModel):
    company_name: str = Field(min_length=1, max_length=200)
    contact_name: str | None = Field(default=None, max_length=200)
    email: str | None = Field(default=None, max_length=320)
    lead_id: int | None = None
    status: str = Field(default="prospect", max_length=40)
    notes: str | None = Field(default=None, max_length=4000)


class ClientOut(ClientCreate):
    id: int
    created_at: datetime
    updated_at: datetime


class ProjectCreate(BaseModel):
    client_id: int
    name: str = Field(min_length=1, max_length=200)
    status: str = Field(default="intake", max_length=40)
    preview_url: str | None = Field(default=None, max_length=1000)
    deployment_url: str | None = Field(default=None, max_length=1000)
    domain: str | None = Field(default=None, max_length=253)
    hosting_plan: str | None = Field(default=None, max_length=200)
    database_plan: str | None = Field(default=None, max_length=200)
    revisions_allowed: int = Field(default=2, ge=0, le=100)


class ProjectOut(ProjectCreate):
    id: int
    revisions_used: int
    created_at: datetime
    updated_at: datetime


class HealthResponse(BaseModel):
    status: str
    database: str
    migration_version: int
