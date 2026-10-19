from __future__ import annotations

from pathlib import Path

from app.db import Database
from app.repositories import LeadRepository


def test_versioned_migration_and_lead_persistence(tmp_path: Path):
    database = Database(tmp_path / "leadpilot.db")
    assert database.initialize() == 6
    with database.session() as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 6
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        assert {"schema_version", "leads", "jobs", "audit_logs", "website_packages", "follow_up_queue", "ai_usage_events"}.issubset(tables)

    repository = LeadRepository(database)
    assert repository.insert_many(
        [{"email": "Ada@Example.com", "normalized_email": "ada@example.com", "first_name": "Ada", "metadata": {}}]
    ) == 1

    reopened = LeadRepository(Database(tmp_path / "leadpilot.db"))
    saved = reopened.get_by_email("ada@example.com")
    assert saved is not None
    assert saved["first_name"] == "Ada"
    assert reopened.count() == 1


def test_interrupted_additive_migration_is_recoverable(tmp_path: Path):
    database = Database(tmp_path / "partial.db")
    connection = database.connect()
    try:
        connection.executescript((Path(__file__).parents[1] / "app" / "migrations" / "001_initial.sql").read_text(encoding="utf-8"))
        connection.execute("PRAGMA user_version = 1")
        connection.execute("ALTER TABLE leads ADD COLUMN opportunity_score INTEGER NOT NULL DEFAULT 0")
        connection.commit()
    finally:
        connection.close()

    assert database.initialize() == 6
    with database.session() as connection:
        columns = {row[1] for row in connection.execute("PRAGMA table_info(leads)").fetchall()}
    assert {"opportunity_score", "research_status", "website_url", "research_notes"}.issubset(columns)
