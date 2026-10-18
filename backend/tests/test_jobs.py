from __future__ import annotations

import threading
import time

from app.db import Database
from app.repositories import JobRepository
from app.services.jobs import JobQueue


def test_job_transitions_through_completion_failure_and_retry(tmp_path):
    repository = JobRepository(Database(tmp_path / "jobs.db"))
    repository.database.initialize()
    queue = JobQueue(repository, workers=1)
    try:
        completed = queue.submit("quick", {}, lambda context, payload: {"ok": True})
        queue.futures[completed["id"]].result(timeout=2)
        saved = repository.get(completed["id"])
        assert saved["status"] == "completed"
        assert saved["progress"] == 100
        assert repository.cancel(completed["id"]) is None
        assert repository.retry(completed["id"]) is None

        attempts = {"count": 0}

        def flaky(context, payload):
            attempts["count"] += 1
            if attempts["count"] == 1:
                raise RuntimeError("temporary failure")
            context.update_progress(50)
            return {"recovered": True}

        failed = queue.submit("flaky", {}, flaky, max_attempts=2)
        queue.futures[failed["id"]].result(timeout=2)
        assert repository.get(failed["id"])["status"] == "failed"
        retried = queue.retry(failed["id"])
        assert retried["status"] == "queued"
        queue.futures[failed["id"]].result(timeout=2)
        saved_retry = repository.get(failed["id"])
        assert saved_retry["status"] == "completed"
        assert saved_retry["attempts"] == 2
    finally:
        queue.shutdown()


def test_queued_job_can_be_cancelled(tmp_path):
    repository = JobRepository(Database(tmp_path / "cancel.db"))
    repository.database.initialize()
    queue = JobQueue(repository, workers=1)
    release = threading.Event()
    try:
        def blocking(context, payload):
            release.wait(2)
            return {"done": True}

        first = queue.submit("blocking", {}, blocking)
        time.sleep(0.05)
        second = queue.submit("queued", {}, lambda context, payload: {"should": "not run"})
        cancelled = repository.cancel(second["id"])
        assert cancelled["status"] == "cancelled"
        release.set()
        queue.futures[first["id"]].result(timeout=2)
        assert repository.get(second["id"])["status"] == "cancelled"
    finally:
        release.set()
        queue.shutdown()
