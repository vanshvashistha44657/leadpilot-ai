from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(slots=True)
class Settings:
    """Runtime configuration with conservative local defaults.

    Secrets are read only from environment variables by provider adapters. They
    are never persisted in the database or returned by the settings endpoint.
    """

    database_path: Path
    local_token: str
    local_only: bool = True
    dry_run: bool = True
    live_sending_enabled: bool = False
    provider: str = "mock"
    batch_size: int = 100
    log_level: str = "INFO"
    backup_directory: Path | None = None

    @classmethod
    def from_env(cls, base_directory: Path | None = None) -> "Settings":
        base = (base_directory or Path(__file__).resolve().parents[1]).resolve()
        data_directory = base / "data"
        database_path = Path(os.getenv("DATABASE_PATH", str(data_directory / "leadpilot.db")))
        if not database_path.is_absolute():
            database_path = (base / database_path).resolve()
        backup_directory = Path(os.getenv("BACKUP_DIRECTORY", str(base / "backups")))
        if not backup_directory.is_absolute():
            backup_directory = (base / backup_directory).resolve()
        return cls(
            database_path=database_path,
            local_token=os.getenv("LOCAL_TOKEN", "local-development-token"),
            local_only=_env_bool("LOCAL_ONLY_API", True),
            dry_run=_env_bool("DRY_RUN", True),
            live_sending_enabled=_env_bool("LIVE_SENDING_ENABLED", False),
            provider=os.getenv("EMAIL_PROVIDER", "mock").strip().lower() or "mock",
            batch_size=max(1, int(os.getenv("IMPORT_BATCH_SIZE", "100"))),
            log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
            backup_directory=backup_directory,
        )
