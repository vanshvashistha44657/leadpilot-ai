from __future__ import annotations

from datetime import datetime, timedelta, timezone
from threading import Lock
from uuid import uuid4

from ..models import AIPersonalizationRequest, DraftOut, DraftUpdate, PersonalizedDraftRequest
from ..repositories import DraftRepository, LeadRepository, AIUsageRepository
from .ai import AIProviderError, AIService, AIUnavailableError


class DraftSuppressedError(ValueError):
    pass


class DraftRateLimitError(ValueError):
    pass


class DraftService:
    _lock = Lock()
    _max_per_minute = 20
    _failed_subject = "Draft generation failed"
    _failed_body = "No outreach message was generated."

    def __init__(self, leads: LeadRepository, drafts: DraftRepository, ai: AIService, usage: AIUsageRepository):
        self.leads = leads
        self.drafts = drafts
        self.ai = ai
        self.usage = usage

    @staticmethod
    def _safe_lead(lead: dict) -> dict:
        return {
            key: lead.get(key)
            for key in (
                "email", "first_name", "last_name", "company", "title", "source",
                "opportunity_score", "research_status", "website_url", "research_notes",
            )
            if lead.get(key) not in (None, "")
        }

    def _record_failure(self, request: PersonalizedDraftRequest, current: dict | None, error: Exception) -> None:
        provider = "unknown"
        model = "unknown"
        try:
            config = self.ai.config()
            provider = config.provider or provider
            model = config.model or model
        except Exception:
            if current:
                provider = current.get("provider") or provider
                model = current.get("model") or model

        subject = current.get("subject") if current else None
        body = current.get("body") if current else None
        generated_subject = current.get("generated_subject") if current else None
        generated_body = current.get("generated_body") if current else None
        subject = subject or self._failed_subject
        body = body or self._failed_body
        generated_subject = generated_subject or subject
        generated_body = generated_body or body
        error_text = str(error).strip() or error.__class__.__name__
        self.drafts.upsert_failed(
            {
                "id": current.get("id") if current else str(uuid4()),
                "lead_id": request.lead_id,
                "provider": provider,
                "model": model,
                "subject": subject,
                "body": body,
                "generated_subject": generated_subject,
                "generated_body": generated_body,
                "offer": request.offer,
                "tone": request.tone,
                "call_to_action": request.call_to_action,
                "error": error_text[:2000],
            }
        )

    def generate(self, request: PersonalizedDraftRequest) -> DraftOut:
        lead = self.leads.get(request.lead_id)
        if not lead:
            raise LookupError("lead not found")
        if not self.leads.is_outreach_eligible(request.lead_id):
            raise DraftSuppressedError("personalized drafts are blocked for suppressed, opted-out, replied, or bounced leads")
        with self._lock:
            current = self.drafts.get_for_lead(request.lead_id)
            if current and current.get("status") != "failed" and not request.regenerate:
                return DraftOut.model_validate(current)
            since = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
            if self.drafts.count_recent_draft_generations(since) >= self._max_per_minute:
                error = DraftRateLimitError("AI draft generation rate limit reached; try again shortly")
                self._record_failure(request, current, error)
                raise error
            instructions = (
                "Use only the supplied lead fields and verified research fields. Never invent company facts, "
                "achievements, metrics, prior interactions, pain points, or relationships. If a fact is absent, "
                "omit it. Do not mention research or claim that a message was previously sent. Keep the draft concise."
            )
            try:
                result = self.ai.personalize(
                    AIPersonalizationRequest(
                        lead=self._safe_lead(lead),
                        offer=request.offer,
                        tone=request.tone,
                        call_to_action=request.call_to_action,
                        instructions=instructions,
                    )
                )
            except (AIUnavailableError, AIProviderError) as exc:
                self._record_failure(request, current, exc)
                raise
            row = self.drafts.upsert_generated(
                {
                    "id": str(uuid4()),
                    "lead_id": request.lead_id,
                    "provider": result.provider,
                    "model": result.model,
                    "subject": result.output.subject,
                    "body": result.output.body,
                    "offer": request.offer,
                    "tone": request.tone,
                    "call_to_action": request.call_to_action,
                    "request_id": result.request_id,
                    "prompt_tokens": result.usage.prompt_tokens,
                    "completion_tokens": result.usage.completion_tokens,
                    "total_tokens": result.usage.total_tokens,
                    "estimated_cost_usd": result.usage.estimated_cost_usd,
                }
            )
            self.usage.record(
                operation="personalized_draft",
                provider=result.provider,
                model=result.model,
                request_id=result.request_id,
                prompt_tokens=result.usage.prompt_tokens,
                completion_tokens=result.usage.completion_tokens,
                total_tokens=result.usage.total_tokens,
                estimated_cost_usd=result.usage.estimated_cost_usd,
            )
            return DraftOut.model_validate(row)

    def list(self, status: str | None = None, limit: int = 100, offset: int = 0) -> list[DraftOut]:
        return [DraftOut.model_validate(row) for row in self.drafts.list(status, limit, offset)]

    def update(self, draft_id: str, payload: DraftUpdate) -> DraftOut:
        row = self.drafts.update_content(draft_id, payload.subject, payload.body)
        if not row:
            raise LookupError("draft not found")
        return DraftOut.model_validate(row)
