from __future__ import annotations

import json
from typing import Any

from .db import Database
from .repositories import utc_now


class GmailAccountRepository:
    def __init__(self, database: Database):
        self.database = database

    def upsert(
        self,
        *,
        account_id: str = "default",
        email: str | None = None,
        scopes: tuple[str, ...] = (),
        status: str = "connected",
        last_error: str | None = None,
    ) -> dict[str, Any]:
        now = utc_now()
        with self.database.session() as connection:
            cursor = connection.execute(
                """INSERT INTO gmail_accounts(
                       account_id, email, scopes_json, status, last_error,
                       connected_at, updated_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(account_id) DO UPDATE SET
                       email = COALESCE(excluded.email, gmail_accounts.email),
                       scopes_json = excluded.scopes_json,
                       status = excluded.status,
                       last_error = excluded.last_error,
                       connected_at = CASE WHEN excluded.status = 'connected'
                                           THEN COALESCE(gmail_accounts.connected_at, excluded.connected_at)
                                           ELSE gmail_accounts.connected_at END,
                       updated_at = excluded.updated_at""",
                (account_id, email, json.dumps(list(scopes), separators=(",", ":")), status, last_error, now, now),
            )
            row = connection.execute("SELECT * FROM gmail_accounts WHERE account_id = ?", (account_id,)).fetchone()
        return self._map(row)

    def get(self, account_id: str = "default") -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute("SELECT * FROM gmail_accounts WHERE account_id = ?", (account_id,)).fetchone()
        return self._map(row) if row else None

    def disconnect(self, account_id: str = "default", last_error: str | None = None) -> dict[str, Any]:
        return self.upsert(account_id=account_id, status="disconnected", last_error=last_error)

    @staticmethod
    def _map(row: Any) -> dict[str, Any]:
        result = dict(row)
        try:
            result["scopes"] = json.loads(result.pop("scopes_json", "[]"))
        except (TypeError, json.JSONDecodeError):
            result["scopes"] = []
        return result


class GmailDraftReferenceRepository:
    def __init__(self, database: Database):
        self.database = database

    def reserve(self, local_draft_id: str, lead_id: int, idempotency_key: str) -> tuple[dict[str, Any], bool]:
        """Reserve before the provider call so a retry cannot create a second draft."""
        now = utc_now()
        with self.database.session() as connection:
            cursor = connection.execute(
                """INSERT OR IGNORE INTO gmail_draft_references(
                       local_draft_id, lead_id, idempotency_key, status, created_at, updated_at
                   ) VALUES (?, ?, ?, 'pending', ?, ?)""",
                (local_draft_id, lead_id, idempotency_key, now, now),
            )
            row = connection.execute(
                "SELECT * FROM gmail_draft_references WHERE local_draft_id = ? OR idempotency_key = ?",
                (local_draft_id, idempotency_key),
            ).fetchone()
        if row is None:
            raise RuntimeError("could not reserve Gmail draft reference")
        result = dict(row)
        return result, cursor.rowcount == 1

    def get(self, local_draft_id: str) -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute(
                "SELECT * FROM gmail_draft_references WHERE local_draft_id = ?", (local_draft_id,)
            ).fetchone()
        return dict(row) if row else None

    def mark_created(self, local_draft_id: str, provider_draft_id: str, provider_thread_id: str | None) -> dict[str, Any]:
        with self.database.session() as connection:
            connection.execute(
                """UPDATE gmail_draft_references
                   SET status = 'created', provider_draft_id = ?, provider_thread_id = ?,
                       error_code = NULL, updated_at = ?
                   WHERE local_draft_id = ? AND status = 'pending'""",
                (provider_draft_id, provider_thread_id, utc_now(), local_draft_id),
            )
            row = connection.execute(
                "SELECT * FROM gmail_draft_references WHERE local_draft_id = ?", (local_draft_id,)
            ).fetchone()
        if row is None:
            raise LookupError("Gmail draft reference not found")
        return dict(row)

    def mark_failed(self, local_draft_id: str, error_code: str) -> dict[str, Any]:
        with self.database.session() as connection:
            connection.execute(
                """UPDATE gmail_draft_references
                   SET status = 'failed', error_code = ?, updated_at = ?
                   WHERE local_draft_id = ? AND status = 'pending'""",
                (error_code[:80], utc_now(), local_draft_id),
            )
            row = connection.execute(
                "SELECT * FROM gmail_draft_references WHERE local_draft_id = ?", (local_draft_id,)
            ).fetchone()
        if row is None:
            raise LookupError("Gmail draft reference not found")
        return dict(row)


class GmailSyncRepository:
    def __init__(self, database: Database):
        self.database = database

    def state(self, account_id: str = "default") -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute("SELECT * FROM gmail_sync_state WHERE account_id = ?", (account_id,)).fetchone()
        return dict(row) if row else None

    def save_state(
        self,
        *,
        account_id: str = "default",
        history_id: str | None = None,
        page_token: str | None = None,
        last_error: str | None = None,
    ) -> dict[str, Any]:
        now = utc_now()
        with self.database.session() as connection:
            connection.execute(
                """INSERT INTO gmail_sync_state(
                       account_id, history_id, page_token, last_sync_at, last_error, updated_at
                   ) VALUES (?, ?, ?, ?, ?, ?)
                   ON CONFLICT(account_id) DO UPDATE SET
                       history_id = excluded.history_id,
                       page_token = excluded.page_token,
                       last_sync_at = excluded.last_sync_at,
                       last_error = excluded.last_error,
                       updated_at = excluded.updated_at""",
                (account_id, history_id, page_token, now, last_error, now),
            )
            row = connection.execute("SELECT * FROM gmail_sync_state WHERE account_id = ?", (account_id,)).fetchone()
        return dict(row)

    def upsert_thread(self, provider_thread_id: str, history_id: str | None, snippet: str | None) -> None:
        with self.database.session() as connection:
            connection.execute(
                """INSERT INTO gmail_threads(provider_thread_id, history_id, snippet, synced_at)
                   VALUES (?, ?, ?, ?)
                   ON CONFLICT(provider_thread_id) DO UPDATE SET
                       history_id = excluded.history_id,
                       snippet = excluded.snippet,
                       synced_at = excluded.synced_at""",
                (provider_thread_id, history_id, snippet, utc_now()),
            )

    def upsert_message(self, values: dict[str, Any]) -> bool:
        with self.database.session() as connection:
            existing = connection.execute(
                "SELECT 1 FROM gmail_messages WHERE provider_message_id = ?",
                (values["provider_message_id"],),
            ).fetchone()
            connection.execute(
                """INSERT INTO gmail_messages(
                       provider_message_id, provider_thread_id, lead_id, match_status,
                       from_email, to_emails_json, subject, snippet, body, internal_date, synced_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(provider_message_id) DO UPDATE SET
                       provider_thread_id = excluded.provider_thread_id,
                       lead_id = excluded.lead_id,
                       match_status = excluded.match_status,
                       from_email = excluded.from_email,
                       to_emails_json = excluded.to_emails_json,
                       subject = excluded.subject,
                       snippet = excluded.snippet,
                       body = excluded.body,
                       internal_date = excluded.internal_date,
                       synced_at = excluded.synced_at""",
                (
                    values["provider_message_id"],
                    values["provider_thread_id"],
                    values.get("lead_id"),
                    values["match_status"],
                    values.get("from_email"),
                    json.dumps(values.get("to_emails", []), separators=(",", ":")),
                    values.get("subject"),
                    values.get("snippet"),
                    values.get("body"),
                    values.get("internal_date"),
                    utc_now(),
                ),
            )
        return existing is None
