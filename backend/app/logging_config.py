from __future__ import annotations

import json
import logging
import sys
from datetime import datetime, timezone


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        request_id = getattr(record, "request_id", None)
        if request_id:
            payload["request_id"] = request_id
        job_id = getattr(record, "job_id", None)
        if job_id:
            payload["job_id"] = job_id
        error_category = getattr(record, "error_category", None)
        if error_category:
            payload["error_category"] = error_category
        exception_class = getattr(record, "exception_class", None)
        if exception_class:
            payload["exception_class"] = exception_class
        http_status = getattr(record, "http_status", None)
        if isinstance(http_status, int) and not isinstance(http_status, bool):
            payload["http_status"] = http_status
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging(level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(getattr(logging, level.upper(), logging.INFO))
