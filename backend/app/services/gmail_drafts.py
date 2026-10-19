from __future__ import annotations

import hashlib

from ..repositories import DraftRepository, LeadRepository
from ..repositories_gmail import GmailDraftReferenceRepository
from .gmail import GmailApiError, GmailMessage, GmailService, GmailUnavailableError
from .normalization import normalize_email


class ReviewedDraftError(ValueError):
    pass


class ReviewedDraftPendingError(ReviewedDraftError):
    pass


class ReviewedDraftFailedError(ReviewedDraftError):
    pass


class ReviewedDraftProviderUnavailableError(ReviewedDraftError):
    pass


class ReviewedDraftProviderError(ReviewedDraftError):
    pass


class GmailDraftWorkflowService:
    """Create exactly one provider draft for an already reviewed local draft."""

    def __init__(
        self,
        leads: LeadRepository,
        drafts: DraftRepository,
        references: GmailDraftReferenceRepository,
        gmail: GmailService,
    ):
        self.leads = leads
        self.drafts = drafts
        self.references = references
        self.gmail = gmail

    def create_reviewed(self, local_draft_id: str) -> dict[str, str | None]:
        local = self.drafts.get(local_draft_id)
        if not local:
            raise LookupError("local draft not found")
        if local.get("status") not in {"generated", "edited"}:
            raise ReviewedDraftError("local draft must be generated or edited")
        subject = str(local.get("subject") or "").strip()
        body = str(local.get("body") or "").strip()
        if not subject or not body:
            raise ReviewedDraftError("local draft subject and body are required")
        lead = self.leads.get(int(local["lead_id"]))
        if not lead:
            raise LookupError("draft lead not found")
        try:
            recipient = normalize_email(lead.get("email"))
        except ValueError as exc:
            raise ReviewedDraftError("draft lead has an invalid recipient") from exc
        if not self.leads.is_outreach_eligible(int(lead["id"])):
            raise ReviewedDraftError("Gmail draft creation is blocked for this lead")

        idempotency_key = hashlib.sha256(f"gmail-draft:{local_draft_id}".encode("utf-8")).hexdigest()
        reference, reserved = self.references.reserve(local_draft_id, int(lead["id"]), idempotency_key)
        status = reference.get("status")
        if not reserved:
            if status == "created":
                return self._safe(reference)
            if status == "pending":
                raise ReviewedDraftPendingError("Gmail draft creation is already pending")
            raise ReviewedDraftFailedError("Gmail draft creation previously failed; review before trying again")

        try:
            created = self.gmail.create_draft(GmailMessage(recipient, subject, body))
        except GmailUnavailableError:
            reference = self.references.mark_failed(local_draft_id, "provider_unavailable")
            raise ReviewedDraftProviderUnavailableError("Gmail draft provider is unavailable") from None
        except GmailApiError:
            reference = self.references.mark_failed(local_draft_id, "provider_error")
            raise ReviewedDraftProviderError("Gmail draft provider rejected the request") from None
        except (OSError, TimeoutError):
            reference = self.references.mark_failed(local_draft_id, "provider_network_error")
            raise ReviewedDraftProviderUnavailableError("Gmail draft provider could not be reached") from None

        reference = self.references.mark_created(local_draft_id, created.draft_id, created.thread_id)
        return self._safe(reference)

    @staticmethod
    def _safe(reference: dict) -> dict[str, str | None]:
        return {
            "local_draft_id": reference.get("local_draft_id"),
            "status": reference.get("status"),
            "provider_draft_id": reference.get("provider_draft_id"),
            "provider_thread_id": reference.get("provider_thread_id"),
        }
