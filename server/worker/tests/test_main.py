"""Worker loop behavior: claim-or-idle, classified failure handling, shutdown."""

from __future__ import annotations

import signal
from datetime import datetime, timezone

import pytest

from job_store import Job, JobStore  # noqa: F401 (JobStore referenced by docs only)
from main import PipelineError, RetryablePipelineError, _Stopper, run_once

T0 = datetime(2026, 8, 27, 0, 0, 0, tzinfo=timezone.utc)


def make_job(job_id: str = "job-1") -> Job:
    return Job(
        id=job_id,
        user_id="user-1",
        device_id="device-1",
        bank_name="Algebra mistakes",
        subject="Math",
        page_start=1,
        page_end=20,
        source_sha256="a" * 64,
        source_size="8",
        part_count=2,
        retry_count=0,
        claimed_at=T0,
    )


class FakeStore:
    def __init__(self, next_job=None):
        self.next_job = next_job
        self.failures: list[tuple[str, object, str, bool]] = []

    def claim_next(self, worker_id: str):
        assert worker_id
        return self.next_job

    def fail(self, job_id, claimed_at, code, retryable=True):
        self.failures.append((job_id, claimed_at, code, retryable))


class FakePipeline:
    def __init__(self, error=None):
        self.error = error
        self.processed: list[Job] = []

    def process(self, job):
        if self.error is not None:
            raise self.error
        self.processed.append(job)


def test_run_once_returns_false_without_work_when_the_queue_is_empty():
    assert run_once(FakeStore(None), FakePipeline()) is False


def test_run_once_processes_a_claimed_job():
    store = FakeStore(make_job())
    pipeline = FakePipeline()

    assert run_once(store, pipeline) is True
    assert [job.id for job in pipeline.processed] == ["job-1"]
    assert store.failures == []


def test_run_once_requeues_retryable_failures_with_their_token():
    store = FakeStore(make_job())
    pipeline = FakePipeline(error=RetryablePipelineError("OCR_FAILED", "low confidence"))

    assert run_once(store, pipeline) is True
    assert store.failures == [("job-1", T0, "OCR_FAILED", True)]


def test_run_once_fails_permanent_errors_without_requeue():
    store = FakeStore(make_job())
    pipeline = FakePipeline(error=PipelineError("PDF_INVALID", "not a pdf"))

    assert run_once(store, pipeline) is True
    assert store.failures == [("job-1", T0, "PDF_INVALID", False)]


def test_run_once_propagates_unclassified_failures_for_the_supervisor_loop():
    store = FakeStore(make_job())

    with pytest.raises(RuntimeError, match="disk exploded"):
        run_once(store, FakePipeline(error=RuntimeError("disk exploded")))

    assert store.failures == []


def test_stopper_cooperatively_halts_the_loop():
    stopper = _Stopper()
    stopper.install()
    try:
        assert stopper.stop is False
        stopper._handle(signal.SIGTERM, None)  # delivered by the supervisor
        assert stopper.stop is True
    finally:
        stopper.restore()
    assert stopper.stop is True
