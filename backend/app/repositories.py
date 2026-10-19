from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any, Iterable

from .db import Database


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _json_load(value: str | None, default: Any) -> Any:
    if not value:
        return default
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return default


def _lead(row: Any) -> dict[str, Any]:
    result = dict(row)
    result["metadata"] = _json_load(result.pop("metadata_json", None), {})
    result["score_factors"] = _json_load(result.pop("score_factors_json", None), {})
    return result


def _job(row: Any) -> dict[str, Any]:
    result = dict(row)
    result["payload"] = _json_load(result.pop("payload_json", None), {})
    result["result"] = _json_load(result.pop("result_json", None), None)
    result["cancel_requested"] = bool(result["cancel_requested"])
    return result


class LeadRepository:
    def __init__(self, database: Database):
        self.database = database

    def existing_emails(self, emails: Iterable[str]) -> set[str]:
        values = list(set(emails))
        if not values:
            return set()
        placeholders = ",".join("?" for _ in values)
        with self.database.session() as connection:
            rows = connection.execute(
                f"SELECT normalized_email FROM leads WHERE normalized_email IN ({placeholders})", values
            ).fetchall()
        return {row[0] for row in rows}

    def suppressed_emails(self, emails: Iterable[str]) -> set[str]:
        values = list(set(emails))
        if not values:
            return set()
        placeholders = ",".join("?" for _ in values)
        with self.database.session() as connection:
            rows = connection.execute(
                f"SELECT normalized_email FROM suppressions WHERE normalized_email IN ({placeholders})", values
            ).fetchall()
        return {row[0] for row in rows}

    def insert_many(self, leads: list[dict[str, Any]]) -> int:
        if not leads:
            return 0
        now = utc_now()
        inserted = 0
        with self.database.session() as connection:
            for lead in leads:
                cursor = connection.execute(
                    """
                    INSERT OR IGNORE INTO leads
                    (email, normalized_email, first_name, last_name, company, title,
                     source, status, metadata_json, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'new', ?, ?, ?)
                    """,
                    (
                        lead["email"],
                        lead["normalized_email"],
                        lead.get("first_name"),
                        lead.get("last_name"),
                        lead.get("company"),
                        lead.get("title"),
                        lead.get("source"),
                        json.dumps(lead.get("metadata", {}), separators=(",", ":")),
                        now,
                        now,
                    ),
                )
                inserted += cursor.rowcount
                if cursor.rowcount and lead.get("import_batch_id"):
                    connection.execute(
                        """INSERT OR IGNORE INTO lead_import_sources
                           (lead_id, batch_id, source_row, source_label, imported_at)
                           VALUES (?, ?, ?, ?, ?)""",
                        (
                            cursor.lastrowid,
                            lead["import_batch_id"],
                            lead["source_row"],
                            lead.get("source_label"),
                            now,
                        ),
                    )
        return inserted

    def get(self, lead_id: int) -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute("SELECT * FROM leads WHERE id = ?", (lead_id,)).fetchone()
        return _lead(row) if row else None

    def get_by_email(self, normalized_email: str) -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute(
                "SELECT * FROM leads WHERE normalized_email = ?", (normalized_email,)
            ).fetchone()
        return _lead(row) if row else None

    def mark_suppressed(self, normalized_email: str) -> None:
        with self.database.session() as connection:
            connection.execute(
                "UPDATE leads SET status = 'suppressed', updated_at = ? WHERE normalized_email = ?",
                (utc_now(), normalized_email),
            )

    def mark_status(self, normalized_email: str, status: str) -> None:
        with self.database.session() as connection:
            connection.execute(
                "UPDATE leads SET status = ?, updated_at = ? WHERE normalized_email = ?",
                (status, utc_now(), normalized_email),
            )

    def update_research(
        self,
        lead_id: int,
        *,
        score: int,
        status: str,
        website_url: str | None,
        notes: str | None,
        score_version: str = "v1",
        score_factors: dict[str, Any] | None = None,
        research_source: str | None = None,
    ) -> dict[str, Any] | None:
        with self.database.session() as connection:
            connection.execute(
                """UPDATE leads SET opportunity_score = ?, research_status = ?, website_url = ?,
                   research_notes = ?, score_version = ?, score_factors_json = ?,
                   research_source = ?, research_verified_at = ?, updated_at = ? WHERE id = ?""",
                (score, status, website_url, notes, score_version, json.dumps(score_factors or {}, separators=(",", ":")), research_source, utc_now(), utc_now(), lead_id),
            )
            row = connection.execute("SELECT * FROM leads WHERE id = ?", (lead_id,)).fetchone()
        return _lead(row) if row else None

    def list(
        self,
        lead_ids: list[int] | None = None,
        limit: int = 500,
        offset: int = 0,
        search: str | None = None,
    ) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            if lead_ids is not None:
                if not lead_ids:
                    return []
                placeholders = ",".join("?" for _ in lead_ids)
                rows = connection.execute(
                    f"SELECT * FROM leads WHERE id IN ({placeholders}) ORDER BY id LIMIT ? OFFSET ?",
                    [*lead_ids, limit, offset],
                ).fetchall()
            else:
                query = "SELECT * FROM leads"
                params: list[Any] = []
                if search and search.strip():
                    term = f"%{search.strip()}%"
                    query += " WHERE email LIKE ? OR first_name LIKE ? OR last_name LIKE ? OR company LIKE ? OR title LIKE ? OR status LIKE ? OR source LIKE ?"
                    params.extend([term] * 7)
                query += " ORDER BY id LIMIT ? OFFSET ?"
                params.extend([limit, offset])
                rows = connection.execute(query, params).fetchall()
        return [_lead(row) for row in rows]

    def follow_up_candidates(self, lead_ids: list[int] | None = None) -> list[dict[str, Any]]:
        """Return leads that have no reply or suppression signal at queue time."""
        query = """
            SELECT l.*
            FROM leads AS l
            WHERE l.status NOT IN ('suppressed', 'unsubscribed', 'replied', 'bounced')
              AND NOT EXISTS (
                  SELECT 1 FROM suppressions AS s
                  WHERE s.normalized_email = l.normalized_email
              )
              AND NOT EXISTS (
                  SELECT 1 FROM reply_events AS r
                  WHERE r.lead_id = l.id
              )
        """
        params: list[Any] = []
        if lead_ids is not None:
            if not lead_ids:
                return []
            placeholders = ",".join("?" for _ in lead_ids)
            query += f" AND l.id IN ({placeholders})"
            params.extend(lead_ids)
        query += " ORDER BY l.id"
        with self.database.session() as connection:
            rows = connection.execute(query, params).fetchall()
        return [_lead(row) for row in rows]

    def iter_rows(self, search: str | None = None, batch_size: int = 500) -> Iterable[dict[str, Any]]:
        """Yield leads in bounded batches for exports and background work."""
        offset = 0
        while True:
            batch = self.list(limit=batch_size, offset=offset, search=search)
            if not batch:
                return
            yield from batch
            offset += len(batch)
            if len(batch) < batch_size:
                return

    def suppression_count(self) -> int:
        with self.database.session() as connection:
            return int(connection.execute("SELECT COUNT(*) FROM suppressions").fetchone()[0])

    def add_suppression(self, normalized_email: str, reason: str) -> dict[str, Any]:
        now = utc_now()
        with self.database.session() as connection:
            connection.execute(
                "INSERT INTO suppressions(normalized_email, reason, created_at) VALUES (?, ?, ?) "
                "ON CONFLICT(normalized_email) DO UPDATE SET reason = excluded.reason",
                (normalized_email, reason, now),
            )
            row = connection.execute(
                "SELECT * FROM suppressions WHERE normalized_email = ?", (normalized_email,)
            ).fetchone()
        return dict(row)

    def count(self) -> int:
        with self.database.session() as connection:
            return int(connection.execute("SELECT COUNT(*) FROM leads").fetchone()[0])

    def count_filtered(self, search: str | None = None) -> int:
        with self.database.session() as connection:
            if search and search.strip():
                term = f"%{search.strip()}%"
                return int(connection.execute(
                    "SELECT COUNT(*) FROM leads WHERE email LIKE ? OR first_name LIKE ? OR last_name LIKE ? OR company LIKE ? OR title LIKE ? OR status LIKE ? OR source LIKE ?",
                    [term] * 7,
                ).fetchone()[0])
            return int(connection.execute("SELECT COUNT(*) FROM leads").fetchone()[0])

    def active_count(self) -> int:
        with self.database.session() as connection:
            return int(
                connection.execute("SELECT COUNT(*) FROM leads WHERE status NOT IN ('suppressed', 'unsubscribed')").fetchone()[0]
            )

    def count_status(self, status: str) -> int:
        with self.database.session() as connection:
            return int(connection.execute("SELECT COUNT(*) FROM leads WHERE status = ?", (status,)).fetchone()[0])

    def is_outreach_eligible(self, lead_id: int) -> bool:
        with self.database.session() as connection:
            row = connection.execute(
                """SELECT l.status FROM leads AS l
                   WHERE l.id = ?
                     AND l.status NOT IN ('suppressed', 'unsubscribed', 'replied', 'bounced')
                     AND NOT EXISTS (SELECT 1 FROM suppressions s WHERE s.normalized_email = l.normalized_email)""",
                (lead_id,),
            ).fetchone()
        return row is not None

    def count_recent_draft_generations(self, since: str) -> int:
        with self.database.session() as connection:
            return int(connection.execute("SELECT COUNT(*) FROM outreach_drafts WHERE generated_at >= ?", (since,)).fetchone()[0])


class ReplyRepository:
    def __init__(self, database: Database):
        self.database = database

    def create(
        self,
        lead_id: int,
        provider: str,
        subject: str | None,
        body: str,
        classification: str,
    ) -> dict[str, Any]:
        with self.database.session() as connection:
            cursor = connection.execute(
                """INSERT INTO reply_events(lead_id, provider, subject, body, classification, created_at)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (lead_id, provider, subject, body, classification, utc_now()),
            )
            row = connection.execute("SELECT * FROM reply_events WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return dict(row)

    def list_for_lead(self, lead_id: int, limit: int = 100) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            rows = connection.execute(
                "SELECT * FROM reply_events WHERE lead_id = ? ORDER BY id DESC LIMIT ?",
                (lead_id, limit),
            ).fetchall()
        return [dict(row) for row in rows]

    def count(self, classification: str | None = None) -> int:
        with self.database.session() as connection:
            if classification:
                return int(connection.execute("SELECT COUNT(*) FROM reply_events WHERE classification = ?", (classification,)).fetchone()[0])
            return int(connection.execute("SELECT COUNT(*) FROM reply_events").fetchone()[0])

    def count_classifications(self, classifications: tuple[str, ...]) -> int:
        if not classifications:
            return 0
        placeholders = ",".join("?" for _ in classifications)
        with self.database.session() as connection:
            return int(
                connection.execute(
                    f"SELECT COUNT(*) FROM reply_events WHERE classification IN ({placeholders})",
                    classifications,
                ).fetchone()[0]
            )


class ClientRepository:
    def __init__(self, database: Database):
        self.database = database

    def create(self, values: dict[str, Any]) -> dict[str, Any]:
        now = utc_now()
        with self.database.session() as connection:
            cursor = connection.execute(
                """INSERT INTO clients(lead_id, company_name, contact_name, email, status, notes, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (values.get("lead_id"), values["company_name"], values.get("contact_name"), values.get("email"), values.get("status", "prospect"), values.get("notes"), now, now),
            )
            row = connection.execute("SELECT * FROM clients WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return dict(row)

    def list(self, limit: int = 100, offset: int = 0) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            rows = connection.execute("SELECT * FROM clients ORDER BY id DESC LIMIT ? OFFSET ?", (limit, offset)).fetchall()
        return [dict(row) for row in rows]

    def count(self, table: str) -> int:
        if table not in {"clients", "projects"}:
            raise ValueError("unsupported count table")
        with self.database.session() as connection:
            return int(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])

    def get(self, client_id: int) -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute("SELECT * FROM clients WHERE id = ?", (client_id,)).fetchone()
        return dict(row) if row else None

    def create_project(self, values: dict[str, Any]) -> dict[str, Any]:
        now = utc_now()
        with self.database.session() as connection:
            if not connection.execute("SELECT 1 FROM clients WHERE id = ?", (values["client_id"],)).fetchone():
                raise LookupError("client not found")
            cursor = connection.execute(
                """INSERT INTO projects(client_id, name, status, preview_url, deployment_url, domain,
                   hosting_plan, database_plan, revisions_allowed, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (values["client_id"], values["name"], values.get("status", "intake"), values.get("preview_url"), values.get("deployment_url"), values.get("domain"), values.get("hosting_plan"), values.get("database_plan"), values.get("revisions_allowed", 2), now, now),
            )
            row = connection.execute("SELECT * FROM projects WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return dict(row)

    def list_projects(self, client_id: int | None = None, limit: int = 100) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            if client_id is None:
                rows = connection.execute("SELECT * FROM projects ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
            else:
                rows = connection.execute("SELECT * FROM projects WHERE client_id = ? ORDER BY id DESC LIMIT ?", (client_id, limit)).fetchall()
        return [dict(row) for row in rows]


class CampaignRepository:
    def __init__(self, database: Database):
        self.database = database

    def create(self, name: str, dry_run: bool) -> dict[str, Any]:
        now = utc_now()
        with self.database.session() as connection:
            cursor = connection.execute(
                "INSERT INTO campaigns(name, status, dry_run, created_at, updated_at) VALUES (?, 'draft', ?, ?, ?)",
                (name, int(dry_run), now, now),
            )
            row = connection.execute("SELECT * FROM campaigns WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return self._map(row)

    def get(self, campaign_id: int) -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute("SELECT * FROM campaigns WHERE id = ?", (campaign_id,)).fetchone()
        return self._map(row) if row else None

    def list(self) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            rows = connection.execute("SELECT * FROM campaigns ORDER BY id DESC").fetchall()
        return [self._map(row) for row in rows]

    def set_status(self, campaign_id: int, status: str) -> None:
        with self.database.session() as connection:
            connection.execute(
                "UPDATE campaigns SET status = ?, updated_at = ? WHERE id = ?",
                (status, utc_now(), campaign_id),
            )

    @staticmethod
    def _map(row: Any) -> dict[str, Any]:
        result = dict(row)
        result["dry_run"] = bool(result["dry_run"])
        return result


class JobRepository:
    def __init__(self, database: Database):
        self.database = database

    def create(self, job_id: str, job_type: str, payload: dict[str, Any], max_attempts: int) -> dict[str, Any]:
        now = utc_now()
        with self.database.session() as connection:
            connection.execute(
                """
                INSERT INTO jobs(id, job_type, status, progress, attempts, max_attempts,
                                 payload_json, created_at, updated_at)
                VALUES (?, ?, 'queued', 0, 0, ?, ?, ?, ?)
                """,
                (job_id, job_type, max_attempts, json.dumps(payload), now, now),
            )
        return self.get(job_id)  # type: ignore[return-value]

    def get(self, job_id: str) -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return _job(row) if row else None

    def list(self, limit: int = 100) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            rows = connection.execute("SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
        return [_job(row) for row in rows]

    def start(self, job_id: str) -> None:
        with self.database.session() as connection:
            connection.execute(
                "UPDATE jobs SET status = 'running', attempts = attempts + 1, started_at = ?, updated_at = ? WHERE id = ?",
                (utc_now(), utc_now(), job_id),
            )

    def update_progress(self, job_id: str, progress: int) -> None:
        with self.database.session() as connection:
            connection.execute(
                "UPDATE jobs SET progress = ?, updated_at = ? WHERE id = ? AND status = 'running'",
                (max(0, min(100, progress)), utc_now(), job_id),
            )

    def is_cancel_requested(self, job_id: str) -> bool:
        with self.database.session() as connection:
            row = connection.execute("SELECT cancel_requested FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return bool(row and row[0])

    def complete(self, job_id: str, result: dict[str, Any]) -> None:
        with self.database.session() as connection:
            connection.execute(
                "UPDATE jobs SET status = 'completed', progress = 100, result_json = ?, finished_at = ?, updated_at = ? WHERE id = ?",
                (json.dumps(result), utc_now(), utc_now(), job_id),
            )

    def fail(self, job_id: str, error: str) -> None:
        with self.database.session() as connection:
            connection.execute(
                "UPDATE jobs SET status = 'failed', error = ?, finished_at = ?, updated_at = ? WHERE id = ?",
                (error[:2000], utc_now(), utc_now(), job_id),
            )

    def cancel(self, job_id: str) -> dict[str, Any] | None:
        with self.database.session() as connection:
            cursor = connection.execute(
                """UPDATE jobs SET cancel_requested = 1,
                   status = CASE WHEN status = 'queued' THEN 'cancelled' ELSE status END,
                   finished_at = CASE WHEN status = 'queued' THEN ? ELSE finished_at END,
                   updated_at = ? WHERE id = ? AND status IN ('queued', 'running')""",
                (utc_now(), utc_now(), job_id),
            )
            if cursor.rowcount == 0:
                return None
        return self.get(job_id)

    def mark_cancelled(self, job_id: str) -> None:
        with self.database.session() as connection:
            connection.execute(
                "UPDATE jobs SET status = 'cancelled', finished_at = ?, updated_at = ? WHERE id = ?",
                (utc_now(), utc_now(), job_id),
            )

    def retry(self, job_id: str) -> dict[str, Any] | None:
        with self.database.session() as connection:
            cursor = connection.execute(
                """UPDATE jobs SET status = 'queued', progress = 0, error = NULL,
                   result_json = NULL, cancel_requested = 0, finished_at = NULL, updated_at = ?
                   WHERE id = ? AND status IN ('failed', 'cancelled') AND attempts < max_attempts""",
                (utc_now(), job_id),
            )
            if cursor.rowcount == 0:
                return None
        return self.get(job_id)

    def status_counts(self) -> dict[str, int]:
        with self.database.session() as connection:
            rows = connection.execute("SELECT status, COUNT(*) AS total FROM jobs GROUP BY status").fetchall()
        return {row["status"]: int(row["total"]) for row in rows}

    def cancel_active(self) -> int:
        """Request cancellation for every queued/running job atomically."""
        now = utc_now()
        with self.database.session() as connection:
            cursor = connection.execute(
                """UPDATE jobs SET cancel_requested = 1,
                   status = CASE WHEN status = 'queued' THEN 'cancelled' ELSE status END,
                   finished_at = CASE WHEN status = 'queued' THEN ? ELSE finished_at END,
                   updated_at = ? WHERE status IN ('queued', 'running')""",
                (now, now),
            )
        return max(0, cursor.rowcount)

    def reconcile_interrupted(self) -> int:
        """Mark jobs from a prior process as recoverable failures."""
        now = utc_now()
        with self.database.session() as connection:
            cursor = connection.execute(
                """UPDATE jobs SET status = 'failed', error = ?, finished_at = ?, updated_at = ?
                   WHERE status IN ('queued', 'running')""",
                ("worker process restarted before this job completed; resubmit after checking inputs", now, now),
            )
        return max(0, cursor.rowcount)


class OutreachRepository:
    def __init__(self, database: Database):
        self.database = database

    def create(
        self,
        campaign_id: int,
        lead_id: int,
        provider: str,
        status: str,
        subject: str,
        body: str,
        dry_run: bool,
        provider_message_id: str | None = None,
        error: str | None = None,
    ) -> dict[str, Any]:
        with self.database.session() as connection:
            cursor = connection.execute(
                """INSERT INTO outreach_events
                   (campaign_id, lead_id, provider, status, subject, body, dry_run,
                    provider_message_id, error, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    campaign_id,
                    lead_id,
                    provider,
                    status,
                    subject,
                    body,
                    int(dry_run),
                    provider_message_id,
                    error,
                    utc_now(),
                ),
            )
            row = connection.execute("SELECT * FROM outreach_events WHERE id = ?", (cursor.lastrowid,)).fetchone()
        result = dict(row)
        result["dry_run"] = bool(result["dry_run"])
        return result

    def count(self, dry_run: bool | None = None) -> int:
        query = "SELECT COUNT(*) FROM outreach_events"
        params: tuple[Any, ...] = ()
        if dry_run is not None:
            query += " WHERE dry_run = ?"
            params = (int(dry_run),)
        with self.database.session() as connection:
            return int(connection.execute(query, params).fetchone()[0])

    def count_status(self, status: str) -> int:
        with self.database.session() as connection:
            return int(connection.execute("SELECT COUNT(*) FROM outreach_events WHERE status = ?", (status,)).fetchone()[0])

    def list_for_lead(self, lead_id: int, limit: int = 100) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            rows = connection.execute(
                "SELECT * FROM outreach_events WHERE lead_id = ? ORDER BY id DESC LIMIT ?",
                (lead_id, limit),
            ).fetchall()
        result = []
        for row in rows:
            item = dict(row)
            item["dry_run"] = bool(item["dry_run"])
            result.append(item)
        return result

    def has_successful(self, campaign_id: int, lead_id: int, subject: str, body: str, dry_run: bool) -> bool:
        with self.database.session() as connection:
            row = connection.execute(
                """SELECT 1 FROM outreach_events WHERE campaign_id = ? AND lead_id = ?
                   AND subject = ? AND body = ? AND dry_run = ? AND status IN ('sent', 'dry_run') LIMIT 1""",
                (campaign_id, lead_id, subject, body, int(dry_run)),
            ).fetchone()
        return row is not None


class SettingsRepository:
    def __init__(self, database: Database):
        self.database = database

    def all(self) -> dict[str, str]:
        with self.database.session() as connection:
            rows = connection.execute("SELECT key, value FROM settings").fetchall()
        return {row["key"]: row["value"] for row in rows}

    def update(self, values: dict[str, str]) -> None:
        now = utc_now()
        with self.database.session() as connection:
            for key, value in values.items():
                connection.execute(
                    "INSERT INTO settings(key, value, updated_at) VALUES (?, ?, ?) "
                    "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                    (key, value, now),
                )


class DraftRepository:
    def __init__(self, database: Database):
        self.database = database

    def get_for_lead(self, lead_id: int) -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute("SELECT * FROM outreach_drafts WHERE lead_id = ?", (lead_id,)).fetchone()
        return dict(row) if row else None


    def list(self, status: str | None = None, limit: int = 100, offset: int = 0) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            if status:
                rows = connection.execute("SELECT * FROM outreach_drafts WHERE status = ? ORDER BY updated_at DESC LIMIT ? OFFSET ?", (status, limit, offset)).fetchall()
            else:
                rows = connection.execute("SELECT * FROM outreach_drafts ORDER BY updated_at DESC LIMIT ? OFFSET ?", (limit, offset)).fetchall()
        return [dict(row) for row in rows]

    def count_recent_draft_generations(self, since: str) -> int:
        with self.database.session() as connection:
            return int(connection.execute("SELECT COUNT(*) FROM outreach_drafts WHERE generated_at >= ?", (since,)).fetchone()[0])

    def upsert_generated(self, values: dict[str, Any]) -> dict[str, Any]:
        now = utc_now()
        with self.database.session() as connection:
            connection.execute(
                """INSERT INTO outreach_drafts
                   (id, lead_id, status, provider, model, subject, body, generated_subject, generated_body,
                    offer, tone, call_to_action, request_id, prompt_tokens, completion_tokens, total_tokens,
                    estimated_cost_usd, error, generated_at, updated_at)
                   VALUES (?, ?, 'generated', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                   ON CONFLICT(lead_id) DO UPDATE SET
                     status = 'generated', provider = excluded.provider, model = excluded.model,
                     subject = excluded.subject, body = excluded.body,
                     generated_subject = excluded.generated_subject, generated_body = excluded.generated_body,
                     offer = excluded.offer, tone = excluded.tone, call_to_action = excluded.call_to_action,
                     request_id = excluded.request_id, prompt_tokens = excluded.prompt_tokens,
                     completion_tokens = excluded.completion_tokens, total_tokens = excluded.total_tokens,
                     estimated_cost_usd = excluded.estimated_cost_usd, error = NULL,
                     generated_at = excluded.generated_at, updated_at = excluded.updated_at""",
                (values["id"], values["lead_id"], values["provider"], values["model"], values["subject"], values["body"], values["subject"], values["body"], values["offer"], values["tone"], values["call_to_action"], values.get("request_id"), values.get("prompt_tokens"), values.get("completion_tokens"), values.get("total_tokens"), values.get("estimated_cost_usd"), now, now),
            )
            row = connection.execute("SELECT * FROM outreach_drafts WHERE lead_id = ?", (values["lead_id"],)).fetchone()
        return dict(row)

    def upsert_failed(self, values: dict[str, Any]) -> dict[str, Any]:
        now = utc_now()
        with self.database.session() as connection:
            connection.execute(
                """INSERT INTO outreach_drafts
                   (id, lead_id, status, provider, model, subject, body, generated_subject, generated_body,
                    offer, tone, call_to_action, request_id, prompt_tokens, completion_tokens, total_tokens,
                    estimated_cost_usd, error, generated_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(lead_id) DO UPDATE SET
                     status = 'failed', provider = excluded.provider, model = excluded.model,
                     subject = excluded.subject, body = excluded.body,
                     generated_subject = excluded.generated_subject, generated_body = excluded.generated_body,
                     offer = excluded.offer, tone = excluded.tone, call_to_action = excluded.call_to_action,
                     request_id = excluded.request_id, prompt_tokens = excluded.prompt_tokens,
                     completion_tokens = excluded.completion_tokens, total_tokens = excluded.total_tokens,
                     estimated_cost_usd = excluded.estimated_cost_usd, error = excluded.error,
                     generated_at = excluded.generated_at, updated_at = excluded.updated_at""",
                (
                    values["id"],
                    values["lead_id"],
                    "failed",
                    values["provider"],
                    values["model"],
                    values["subject"],
                    values["body"],
                    values["generated_subject"],
                    values["generated_body"],
                    values["offer"],
                    values["tone"],
                    values["call_to_action"],
                    values.get("request_id"),
                    values.get("prompt_tokens"),
                    values.get("completion_tokens"),
                    values.get("total_tokens"),
                    values.get("estimated_cost_usd"),
                    values["error"],
                    now,
                    now,
                ),
            )
            row = connection.execute("SELECT * FROM outreach_drafts WHERE lead_id = ?", (values["lead_id"],)).fetchone()
        return dict(row)

    def update_content(self, draft_id: str, subject: str, body: str) -> dict[str, Any] | None:
        with self.database.session() as connection:
            connection.execute("UPDATE outreach_drafts SET subject = ?, body = ?, status = 'edited', updated_at = ? WHERE id = ?", (subject, body, utc_now(), draft_id))
            row = connection.execute("SELECT * FROM outreach_drafts WHERE id = ?", (draft_id,)).fetchone()
        return dict(row) if row else None


class ImportBatchRepository:
    def __init__(self, database: Database):
        self.database = database

    def create(self, batch_id: str, filename: str, file_type: str) -> None:
        with self.database.session() as connection:
            connection.execute("INSERT INTO import_batches(id, filename, file_type, status, created_at) VALUES (?, ?, ?, 'running', ?)", (batch_id, filename, file_type, utc_now()))

    def complete(
        self,
        batch_id: str,
        result: dict[str, Any],
        error: str | None = None,
        error_details: list[dict[str, Any]] | None = None,
    ) -> None:
        details = error_details
        if details is None:
            details = getattr(result, "error_details", None) or result.get("error_details", [])
        if not details and result.get("errors"):
            details = [
                {
                    "row_number": 0,
                    "field_name": None,
                    "error_code": "import_error",
                    "message": str(message),
                }
                for message in result["errors"]
            ]
        if not details and error:
            details = [
                {
                    "row_number": 0,
                    "field_name": None,
                    "error_code": "import_error",
                    "message": error,
                }
            ]
        details = [self._normalize_error_detail(detail) for detail in details]
        with self.database.session() as connection:
            connection.execute(
                """UPDATE import_batches SET status = ?, rows_processed = ?, imported_count = ?, duplicate_count = ?,
                   suppressed_count = ?, invalid_count = ?, skipped_count = ?, error_count = ?, finished_at = ?, error = ?
                   WHERE id = ?""",
                (
                    "failed" if error else "completed",
                    result.get("processed", 0),
                    result.get("imported", 0),
                    result.get("duplicates", 0),
                    result.get("suppressed", 0),
                    result.get("invalid", 0),
                    result.get("skipped", 0),
                    len(details),
                    utc_now(),
                    error,
                    batch_id,
                ),
            )
            for detail in details:
                connection.execute(
                    """INSERT INTO import_errors
                       (batch_id, row_number, field_name, error_code, message, created_at)
                       VALUES (?, ?, ?, ?, ?, ?)""",
                    (
                        batch_id,
                        detail["row_number"],
                        detail["field_name"],
                        detail["error_code"],
                        detail["message"],
                        utc_now(),
                    ),
                )

    def fail(
        self,
        batch_id: str,
        error: str,
        *,
        error_code: str = "import_error",
        result: dict[str, Any] | None = None,
        error_details: list[dict[str, Any]] | None = None,
    ) -> None:
        details = error_details or [
            {
                "row_number": 0,
                "field_name": None,
                "error_code": error_code,
                "message": error,
            }
        ]
        self.complete(batch_id, result or {}, error=error, error_details=details)

    def list_errors(self, batch_id: str) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            rows = connection.execute(
                "SELECT * FROM import_errors WHERE batch_id = ? ORDER BY id", (batch_id,)
            ).fetchall()
        return [dict(row) for row in rows]

    def list_sources(self, batch_id: str) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            rows = connection.execute(
                "SELECT * FROM lead_import_sources WHERE batch_id = ? ORDER BY source_row, lead_id",
                (batch_id,),
            ).fetchall()
        return [dict(row) for row in rows]

    @staticmethod
    def _normalize_error_detail(detail: dict[str, Any]) -> dict[str, Any]:
        return {
            "row_number": int(detail.get("row_number", 0)),
            "field_name": detail.get("field_name"),
            "error_code": str(detail.get("error_code") or "import_error"),
            "message": str(detail.get("message") or "import error"),
        }


class AlertRepository:
    def __init__(self, database: Database):
        self.database = database

    def create(self, severity: str, message: str) -> dict[str, Any]:
        with self.database.session() as connection:
            cursor = connection.execute(
                "INSERT INTO alerts(severity, message, created_at) VALUES (?, ?, ?)",
                (severity, message, utc_now()),
            )
            row = connection.execute("SELECT * FROM alerts WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return self._map(row)

    def list(self, include_acknowledged: bool = False) -> list[dict[str, Any]]:
        query = "SELECT * FROM alerts"
        if not include_acknowledged:
            query += " WHERE acknowledged = 0"
        query += " ORDER BY id DESC"
        with self.database.session() as connection:
            rows = connection.execute(query).fetchall()
        return [self._map(row) for row in rows]

    def acknowledge(self, alert_id: int) -> dict[str, Any] | None:
        with self.database.session() as connection:
            connection.execute("UPDATE alerts SET acknowledged = 1 WHERE id = ?", (alert_id,))
            row = connection.execute("SELECT * FROM alerts WHERE id = ?", (alert_id,)).fetchone()
        return self._map(row) if row else None

    def pending_count(self) -> int:
        with self.database.session() as connection:
            return int(connection.execute("SELECT COUNT(*) FROM alerts WHERE acknowledged = 0").fetchone()[0])

    @staticmethod
    def _map(row: Any) -> dict[str, Any]:
        result = dict(row)
        result["acknowledged"] = bool(result["acknowledged"])
        return result


class AuditRepository:
    def __init__(self, database: Database):
        self.database = database

    def record(self, action: str, actor: str, details: dict[str, Any] | None = None) -> None:
        with self.database.session() as connection:
            connection.execute(
                "INSERT INTO audit_logs(action, actor, details_json, created_at) VALUES (?, ?, ?, ?)",
                (action, actor, json.dumps(details or {}, default=str), utc_now()),
            )

    def list(self, limit: int = 100) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            rows = connection.execute("SELECT * FROM audit_logs ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        result = []
        for row in rows:
            item = dict(row)
            item["details"] = _json_load(item.pop("details_json", None), {})
            result.append(item)
        return result


class AIUsageRepository:
    def __init__(self, database: Database):
        self.database = database

    def record(
        self,
        *,
        operation: str,
        provider: str,
        model: str,
        request_id: str | None,
        prompt_tokens: int | None,
        completion_tokens: int | None,
        total_tokens: int | None,
        estimated_cost_usd: float | None,
    ) -> None:
        with self.database.session() as connection:
            connection.execute(
                """INSERT INTO ai_usage_events(
                   operation, provider, model, request_id, prompt_tokens,
                   completion_tokens, total_tokens, estimated_cost_usd, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    operation,
                    provider,
                    model,
                    request_id,
                    prompt_tokens,
                    completion_tokens,
                    total_tokens,
                    estimated_cost_usd,
                    utc_now(),
                ),
            )

    def summary(self) -> dict[str, int | float]:
        with self.database.session() as connection:
            row = connection.execute(
                """SELECT COUNT(*) AS requests,
                   COALESCE(SUM(total_tokens), 0) AS total_tokens,
                   COALESCE(SUM(estimated_cost_usd), 0) AS estimated_cost_usd
                   FROM ai_usage_events"""
            ).fetchone()
        return {
            "requests": int(row["requests"]),
            "total_tokens": int(row["total_tokens"]),
            "estimated_cost_usd": round(float(row["estimated_cost_usd"]), 6),
        }
