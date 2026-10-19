from __future__ import annotations

from typing import Any

from ..repositories import LeadRepository
from ..repositories_gmail import GmailAccountRepository, GmailSyncRepository
from .gmail import GmailApiError, GmailHistoryExpiredError, GmailService, GmailUnavailableError
from .normalization import normalize_email


class GmailSyncService:
    def __init__(
        self,
        gmail: GmailService,
        leads: LeadRepository,
        sync: GmailSyncRepository,
        accounts: GmailAccountRepository,
    ):
        self.gmail = gmail
        self.leads = leads
        self.sync = sync
        self.accounts = accounts

    def synchronize(
        self,
        *,
        query: str | None = None,
        page_token: str | None = None,
        max_results: int = 100,
        max_pages: int = 10,
    ) -> dict[str, Any]:
        max_pages = min(max(max_pages, 1), 100)
        state = self.sync.state()
        counters = {
            "mode": "full",
            "pages": 0,
            "threads_seen": 0,
            "threads_skipped": 0,
            "threads_stored": 0,
            "messages_seen": 0,
            "messages_stored": 0,
            "matched": 0,
            "unknown": 0,
            "ambiguous": 0,
        }
        thread_ids: list[str] = []
        history_id = state.get("history_id") if state else None
        next_token = page_token

        if not page_token and history_id and query is None:
            try:
                counters["mode"] = "incremental"
                history_page_token: str | None = None
                history_ids: list[str] = []
                for _ in range(max_pages):
                    page = self.gmail.sync_history(
                        start_history_id=history_id,
                        page_token=history_page_token,
                        max_results=max_results,
                    )
                    counters["pages"] += 1
                    history_ids.extend(page.thread_ids)
                    if page.history_id:
                        history_id = page.history_id
                    if not page.next_page_token:
                        break
                    history_page_token = page.next_page_token
                else:
                    next_token = history_page_token
                thread_ids = list(dict.fromkeys(history_ids))
            except GmailHistoryExpiredError:
                counters["mode"] = "full_resync"
                thread_ids = []
                next_token = None
            except (GmailUnavailableError, GmailApiError):
                raise

        if counters["mode"] in {"full", "full_resync"}:
            page_count = 0
            while page_count < max_pages:
                page = self.gmail.sync_threads(query=query, page_token=next_token, max_results=max_results)
                counters["pages"] += 1
                page_count += 1
                counters["threads_seen"] += len(page.threads)
                thread_ids.extend(item.thread_id for item in page.threads)
                if page.threads:
                    candidate_histories = [item.history_id for item in page.threads if item.history_id and item.history_id.isdigit()]
                    if candidate_histories:
                        history_id = max(candidate_histories, key=int)
                next_token = page.next_page_token
                if not next_token:
                    break
            # A returned cursor means the bounded sync can be resumed safely.

        if counters["mode"] == "incremental":
            counters["threads_seen"] = len(dict.fromkeys(thread_ids))

        for thread_id in dict.fromkeys(thread_ids):
            try:
                thread = self.gmail.get_thread(thread_id)
            except GmailApiError as exc:
                # History can mention a thread that was deleted before this
                # bounded sync fetched it. Preserve the cursor and continue;
                # a deleted remote thread is not a synchronization failure.
                if exc.status_code == 404:
                    counters["threads_skipped"] += 1
                    continue
                raise
            self.sync.upsert_thread(thread.thread_id, thread.history_id, thread.snippet)
            counters["threads_stored"] += 1
            for message in thread.messages:
                counters["messages_seen"] += 1
                lead_id, match_status = self._match_message(message.from_email, message.to_emails)
                if match_status == "matched":
                    counters["matched"] += 1
                elif match_status == "ambiguous":
                    counters["ambiguous"] += 1
                else:
                    counters["unknown"] += 1
                inserted = self.sync.upsert_message(
                    {
                        "provider_message_id": message.message_id,
                        "provider_thread_id": message.thread_id,
                        "lead_id": lead_id,
                        "match_status": match_status,
                        "from_email": message.from_email,
                        "to_emails": list(message.to_emails),
                        "subject": message.subject,
                        "snippet": message.snippet,
                        "body": message.body,
                        "internal_date": message.internal_date,
                    }
                )
                counters["messages_stored"] += int(inserted)

        if history_id and history_id.isdigit():
            saved_history = history_id
        else:
            saved_history = history_id
        self.sync.save_state(history_id=saved_history, page_token=next_token, last_error=None)
        self.accounts.upsert(status="connected", scopes=("https://www.googleapis.com/auth/gmail.compose", "https://www.googleapis.com/auth/gmail.readonly"))
        counters["next_page_token"] = next_token
        counters["history_id"] = saved_history
        return counters

    def _match_message(self, from_email: str | None, to_emails: tuple[str, ...]) -> tuple[int | None, str]:
        candidates: set[str] = set()
        for address in (from_email, *to_emails):
            if not address:
                continue
            try:
                candidates.add(normalize_email(address))
            except ValueError:
                continue
        lead_ids: set[int] = set()
        for address in candidates:
            lead = self.leads.get_by_email(address)
            if lead:
                lead_ids.add(int(lead["id"]))
        if len(lead_ids) == 1:
            return next(iter(lead_ids)), "matched"
        if len(lead_ids) > 1:
            return None, "ambiguous"
        return None, "unknown"
