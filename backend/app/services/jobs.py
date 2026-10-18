from __future__ import annotations

import logging
from concurrent.futures import Future, ThreadPoolExecutor
from typing import Any, Callable
from uuid import uuid4

from ..repositories import JobRepository

logger = logging.getLogger(__name__)
JobHandler = Callable[["JobContext", dict[str, Any]], dict[str, Any]]


class JobCancelled(Exception):
    pass


class JobContext:
    def __init__(self, job_id: str, repository: JobRepository):
        self.job_id = job_id
        self.repository = repository

    def update_progress(self, progress: int) -> None:
        self.check_cancelled()
        self.repository.update_progress(self.job_id, progress)

    def check_cancelled(self) -> None:
        if self.repository.is_cancel_requested(self.job_id):
            raise JobCancelled()


class JobQueue:
    """Small process-local queue primitive with persisted state transitions."""

    def __init__(self, repository: JobRepository, workers: int = 2, can_start: Callable[[], bool] | None = None):
        self.repository = repository
        self.executor = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="leadpilot-job")
        self.handlers: dict[str, JobHandler] = {}
        self.futures: dict[str, Future[Any]] = {}
        self.cleanups: dict[str, Callable[[str], None]] = {}
        self.can_start = can_start

    def submit(
        self,
        job_type: str,
        payload: dict[str, Any],
        handler: JobHandler,
        max_attempts: int = 3,
        cleanup: Callable[[str], None] | None = None,
    ) -> dict[str, Any]:
        job_id = str(uuid4())
        job = self.repository.create(job_id, job_type, payload, max_attempts)
        self.handlers[job_id] = handler
        if cleanup:
            self.cleanups[job_id] = cleanup
        self.futures[job_id] = self.executor.submit(self._execute, job_id, handler)
        return job

    def retry(self, job_id: str) -> dict[str, Any] | None:
        handler = self.handlers.get(job_id)
        if handler is None:
            return None
        job = self.repository.retry(job_id)
        if job and job["status"] == "queued":
            self.futures[job_id] = self.executor.submit(self._execute, job_id, handler)
        return job

    def _execute(self, job_id: str, handler: JobHandler) -> None:
        try:
            job = self.repository.get(job_id)
            if not job or job["status"] == "cancelled":
                return
            if self.can_start is not None and not self.can_start():
                self.repository.cancel(job_id)
                return
            self.repository.start(job_id)
            context = JobContext(job_id, self.repository)
            context.check_cancelled()
            result = handler(context, job["payload"])
            if self.repository.is_cancel_requested(job_id):
                self._cleanup_if_safe(job_id)
                self.repository.mark_cancelled(job_id)
            else:
                # Make cleanup observable before publishing the completed state. This
                # keeps staged-file jobs from looking complete while their files remain.
                self._cleanup_if_safe(job_id)
                self.repository.complete(job_id, result)
        except JobCancelled:
            self.repository.mark_cancelled(job_id)
        except Exception as exc:  # persisted for API consumers; worker remains healthy
            logger.exception("background job failed", extra={"job_id": job_id})
            self.repository.fail(job_id, str(exc))
        finally:
            self._cleanup_if_safe(job_id)

    def _cleanup_if_safe(self, job_id: str) -> None:
        current = self.repository.get(job_id)
        if current and current["status"] == "failed":
            return
        cleanup = self.cleanups.pop(job_id, None)
        if cleanup:
            try:
                cleanup(job_id)
            except Exception:
                logger.exception("background job cleanup failed", extra={"job_id": job_id})

    def shutdown(self) -> None:
        self.executor.shutdown(wait=False, cancel_futures=False)
