from __future__ import annotations

from datetime import datetime
from typing import Any

from .db import Database
from .repositories import utc_now


def _package(row: Any) -> dict[str, Any]:
    result = dict(row)
    result["active"] = bool(result["active"])
    return result


def _follow_up(row: Any) -> dict[str, Any]:
    result = dict(row)
    result["dry_run"] = bool(result["dry_run"])
    return result


class PackageRepository:
    def __init__(self, database: Database):
        self.database = database

    def create(self, values: dict[str, Any]) -> dict[str, Any]:
        now = utc_now()
        with self.database.session() as connection:
            cursor = connection.execute(
                """
                INSERT INTO website_packages(
                    name, description, setup_price, hosting_monthly_revenue,
                    maintenance_monthly_revenue, delivery_labor_cost, ai_api_cost,
                    domain_cost, database_cost, liability_cost, other_cost, active,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    values["name"],
                    values.get("description"),
                    values.get("setup_price", 0),
                    values.get("hosting_monthly_revenue", 0),
                    values.get("maintenance_monthly_revenue", 0),
                    values.get("delivery_labor_cost", 0),
                    values.get("ai_api_cost", 0),
                    values.get("domain_cost", 0),
                    values.get("database_cost", 0),
                    values.get("liability_cost", 0),
                    values.get("other_cost", 0),
                    int(values.get("active", True)),
                    now,
                    now,
                ),
            )
            row = connection.execute("SELECT * FROM website_packages WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return _package(row)

    def get(self, package_id: int) -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute("SELECT * FROM website_packages WHERE id = ?", (package_id,)).fetchone()
        return _package(row) if row else None

    def list(self, include_inactive: bool = False) -> list[dict[str, Any]]:
        query = "SELECT * FROM website_packages"
        if not include_inactive:
            query += " WHERE active = 1"
        query += " ORDER BY id"
        with self.database.session() as connection:
            rows = connection.execute(query).fetchall()
        return [_package(row) for row in rows]


class ProposalRepository:
    def __init__(self, database: Database):
        self.database = database

    def create(self, values: dict[str, Any]) -> dict[str, Any]:
        now = utc_now()
        with self.database.session() as connection:
            cursor = connection.execute(
                """
                INSERT INTO proposals(
                    client_id, package_id, status, amount, recurring_amount, valid_until,
                    notes, hosting_monthly_revenue, maintenance_monthly_revenue,
                    delivery_labor_cost, ai_api_cost, domain_cost, database_cost,
                    liability_cost, other_cost, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    values["client_id"],
                    values.get("package_id"),
                    values.get("status", "draft"),
                    values.get("amount", 0),
                    values.get("recurring_amount", 0),
                    _iso(values.get("valid_until")),
                    values.get("notes"),
                    values.get("hosting_monthly_revenue", 0),
                    values.get("maintenance_monthly_revenue", 0),
                    values.get("delivery_labor_cost", 0),
                    values.get("ai_api_cost", 0),
                    values.get("domain_cost", 0),
                    values.get("database_cost", 0),
                    values.get("liability_cost", 0),
                    values.get("other_cost", 0),
                    now,
                    now,
                ),
            )
            row = connection.execute("SELECT * FROM proposals WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return dict(row)

    def get(self, proposal_id: int) -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute("SELECT * FROM proposals WHERE id = ?", (proposal_id,)).fetchone()
        return dict(row) if row else None

    def list(self, client_id: int | None = None, limit: int = 100, offset: int = 0) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            if client_id is None:
                rows = connection.execute(
                    "SELECT * FROM proposals ORDER BY id DESC LIMIT ? OFFSET ?", (limit, offset)
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT * FROM proposals WHERE client_id = ? ORDER BY id DESC LIMIT ? OFFSET ?",
                    (client_id, limit, offset),
                ).fetchall()
        return [dict(row) for row in rows]

    def set_status(self, proposal_id: int, status: str) -> dict[str, Any] | None:
        with self.database.session() as connection:
            connection.execute(
                "UPDATE proposals SET status = ?, updated_at = ? WHERE id = ?",
                (status, utc_now(), proposal_id),
            )
            row = connection.execute("SELECT * FROM proposals WHERE id = ?", (proposal_id,)).fetchone()
        return dict(row) if row else None


class PaymentRepository:
    def __init__(self, database: Database):
        self.database = database

    def create(self, values: dict[str, Any]) -> dict[str, Any]:
        paid_at = values.get("paid_at")
        if values.get("status") == "paid" and paid_at is None:
            paid_at = utc_now()
        with self.database.session() as connection:
            cursor = connection.execute(
                """
                INSERT INTO payments(client_id, proposal_id, amount, status, paid_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    values["client_id"],
                    values.get("proposal_id"),
                    values["amount"],
                    values.get("status", "pending"),
                    _iso(paid_at),
                    utc_now(),
                ),
            )
            row = connection.execute("SELECT * FROM payments WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return dict(row)

    def get(self, payment_id: int) -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute("SELECT * FROM payments WHERE id = ?", (payment_id,)).fetchone()
        return dict(row) if row else None

    def list(self, client_id: int | None = None, limit: int = 100, offset: int = 0) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            if client_id is None:
                rows = connection.execute(
                    "SELECT * FROM payments ORDER BY id DESC LIMIT ? OFFSET ?", (limit, offset)
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT * FROM payments WHERE client_id = ? ORDER BY id DESC LIMIT ? OFFSET ?",
                    (client_id, limit, offset),
                ).fetchall()
        return [dict(row) for row in rows]

    def set_status(self, payment_id: int, status: str, paid_at: Any = None) -> dict[str, Any] | None:
        if status == "paid" and paid_at is None:
            paid_at = utc_now()
        with self.database.session() as connection:
            connection.execute(
                "UPDATE payments SET status = ?, paid_at = ? WHERE id = ?",
                (status, _iso(paid_at), payment_id),
            )
            row = connection.execute("SELECT * FROM payments WHERE id = ?", (payment_id,)).fetchone()
        return dict(row) if row else None


class RenewalRepository:
    def __init__(self, database: Database):
        self.database = database

    def create(self, values: dict[str, Any]) -> dict[str, Any]:
        with self.database.session() as connection:
            cursor = connection.execute(
                """
                INSERT INTO renewals(client_id, project_id, due_at, amount, status, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    values["client_id"],
                    values.get("project_id"),
                    _iso(values["due_at"]),
                    values["amount"],
                    values.get("status", "upcoming"),
                    utc_now(),
                ),
            )
            row = connection.execute("SELECT * FROM renewals WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return dict(row)

    def get(self, renewal_id: int) -> dict[str, Any] | None:
        with self.database.session() as connection:
            row = connection.execute("SELECT * FROM renewals WHERE id = ?", (renewal_id,)).fetchone()
        return dict(row) if row else None

    def list(self, client_id: int | None = None, limit: int = 100, offset: int = 0) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            if client_id is None:
                rows = connection.execute(
                    "SELECT * FROM renewals ORDER BY due_at, id LIMIT ? OFFSET ?", (limit, offset)
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT * FROM renewals WHERE client_id = ? ORDER BY due_at, id LIMIT ? OFFSET ?",
                    (client_id, limit, offset),
                ).fetchall()
        return [dict(row) for row in rows]

    def set_status(self, renewal_id: int, status: str) -> dict[str, Any] | None:
        with self.database.session() as connection:
            connection.execute("UPDATE renewals SET status = ? WHERE id = ?", (status, renewal_id))
            row = connection.execute("SELECT * FROM renewals WHERE id = ?", (renewal_id,)).fetchone()
        return dict(row) if row else None


class FollowUpRepository:
    def __init__(self, database: Database):
        self.database = database

    def create_many(self, values: list[dict[str, Any]]) -> list[dict[str, Any]]:
        if not values:
            return []
        now = utc_now()
        with self.database.session() as connection:
            created: list[dict[str, Any]] = []
            for value in values:
                cursor = connection.execute(
                    """
                    INSERT INTO follow_up_queue(
                        campaign_id, lead_id, sequence_number, scheduled_for, provider,
                        subject, body, status, dry_run, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', 1, ?, ?)
                    """,
                    (
                        value["campaign_id"],
                        value["lead_id"],
                        value["sequence_number"],
                        _iso(value["scheduled_for"]),
                        value.get("provider"),
                        value["subject"],
                        value["body"],
                        now,
                        now,
                    ),
                )
                row = connection.execute("SELECT * FROM follow_up_queue WHERE id = ?", (cursor.lastrowid,)).fetchone()
                created.append(_follow_up(row))
        return created

    def list(self, status: str | None = None, limit: int = 100, offset: int = 0) -> list[dict[str, Any]]:
        with self.database.session() as connection:
            if status:
                rows = connection.execute(
                    "SELECT * FROM follow_up_queue WHERE status = ? ORDER BY scheduled_for, id LIMIT ? OFFSET ?",
                    (status, limit, offset),
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT * FROM follow_up_queue ORDER BY scheduled_for, id LIMIT ? OFFSET ?",
                    (limit, offset),
                ).fetchall()
        return [_follow_up(row) for row in rows]


class SalesMetricsRepository:
    """Read-only aggregates for the sales dashboard."""

    def __init__(self, database: Database):
        self.database = database

    def conversions(self) -> int:
        with self.database.session() as connection:
            row = connection.execute(
                """
                SELECT COUNT(*) FROM (
                    SELECT id AS client_id FROM clients
                    WHERE status IN ('won', 'converted', 'customer', 'active')
                    UNION
                    SELECT client_id FROM proposals
                    WHERE status IN ('accepted', 'won', 'paid', 'active')
                )
                """
            ).fetchone()
        return int(row[0])

    def revenue(self) -> float:
        with self.database.session() as connection:
            payment_row = connection.execute(
                "SELECT COALESCE(SUM(amount), 0) FROM payments WHERE status = 'paid'"
            ).fetchone()
            renewal_row = connection.execute(
                "SELECT COALESCE(SUM(amount), 0) FROM renewals WHERE status = 'paid'"
            ).fetchone()
        return round(float(payment_row[0]) + float(renewal_row[0]), 2)

    def recurring_revenue(self) -> float:
        with self.database.session() as connection:
            row = connection.execute(
                """
                SELECT COALESCE(SUM(recurring_amount), 0)
                FROM proposals
                WHERE status IN ('accepted', 'won', 'paid', 'active')
                """
            ).fetchone()
        return round(float(row[0]), 2)


def _iso(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.isoformat()
    return str(value)
