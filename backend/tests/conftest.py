from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        database_path=tmp_path / "leadpilot.db",
        local_token="test-token",
        dry_run=True,
        live_sending_enabled=False,
        backup_directory=tmp_path / "backups",
    )


@pytest.fixture
def app(settings: Settings):
    application = create_app(settings)
    yield application
    application.state.services.queue.shutdown()


@pytest.fixture
def client(app):
    with TestClient(app) as test_client:
        yield test_client
