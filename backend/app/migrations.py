from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path


def _migration_number(path: Path) -> int:
    return int(path.name.split("_", 1)[0])


def apply_migrations(connection: sqlite3.Connection, migrations_directory: Path | None = None) -> int:
    directory = migrations_directory or Path(__file__).with_name("migrations")
    current = int(connection.execute("PRAGMA user_version").fetchone()[0])
    files = sorted(directory.glob("*.sql"), key=_migration_number)
    for path in files:
        version = _migration_number(path)
        if version <= current:
            continue
        if version == 2:
            _ensure_lead_research_columns(connection)
        connection.executescript(path.read_text(encoding="utf-8"))
        if version == 3:
            _ensure_sales_workflow_columns(connection)
        connection.execute(f"PRAGMA user_version = {version}")
        connection.execute(
            "INSERT OR REPLACE INTO schema_version(version, applied_at) VALUES (?, ?)",
            (version, datetime.now(timezone.utc).isoformat()),
        )
        connection.commit()
        current = version
    return current


def _ensure_lead_research_columns(connection: sqlite3.Connection) -> None:
    """Make the additive research migration safe to resume after interruption."""
    columns = {row[1] for row in connection.execute("PRAGMA table_info(leads)").fetchall()}
    additions = {
        "opportunity_score": "INTEGER NOT NULL DEFAULT 0",
        "research_status": "TEXT NOT NULL DEFAULT 'unresearched'",
        "website_url": "TEXT",
        "research_notes": "TEXT",
    }
    for name, definition in additions.items():
        if name not in columns:
            connection.execute(f"ALTER TABLE leads ADD COLUMN {name} {definition}")


def _ensure_sales_workflow_columns(connection: sqlite3.Connection) -> None:
    """Add proposal financial snapshots without rewriting existing sales rows."""
    columns = {row[1] for row in connection.execute("PRAGMA table_info(proposals)").fetchall()}
    additions = {
        "package_id": "INTEGER",
        "hosting_monthly_revenue": "REAL NOT NULL DEFAULT 0",
        "maintenance_monthly_revenue": "REAL NOT NULL DEFAULT 0",
        "delivery_labor_cost": "REAL NOT NULL DEFAULT 0",
        "ai_api_cost": "REAL NOT NULL DEFAULT 0",
        "domain_cost": "REAL NOT NULL DEFAULT 0",
        "database_cost": "REAL NOT NULL DEFAULT 0",
        "liability_cost": "REAL NOT NULL DEFAULT 0",
        "other_cost": "REAL NOT NULL DEFAULT 0",
    }
    for name, definition in additions.items():
        if name not in columns:
            connection.execute(f"ALTER TABLE proposals ADD COLUMN {name} {definition}")
    connection.execute("CREATE INDEX IF NOT EXISTS idx_proposals_package ON proposals(package_id)")
