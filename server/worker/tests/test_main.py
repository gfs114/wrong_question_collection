"""Worker loop behavior: claim-or-idle, classified failure handling, shutdown."""

from __future__ import annotations

import signal
from datetime import datetime, timezone

import pytest

from errors import PipelineError, RetryablePipelineError
from import_writer import ImportWriterError
from job_store import Job, JobStoreError
from main import _Stopper, run_once
from pdf_pipeline import ProcessResult
from question_parser import QuestionDraft

T0 = datetime(2026, 8, 27, 0, 0, 0, tzinfo=timezone.utc)


def make_job(job_id: str = "job-1", source_key: str | None = "job-1/source.pdf") -> Job:
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
        expires_at=T0,
        source_storage_key=source_key,
    )


class FakeStore:
    def __init__(self, next_job=None):
        self.next_job = next_job
        self.failures: list[tuple[str, object, str, bool]] = []
        self.progress: list[tuple[int, int]] = []
        self.replace_calls = 0
        self.progress_ok = True

    def claim_next(self, worker_id: str):
        assert worker_id
        return self.next_job

    def fail(self, job_id, claimed_at, code, retryable=True):
        self.failures.append((job_id, claimed_at, code, retryable))

    def update_progress(self, job_id, claimed_at, current, total):
        self.progress.append((current, total))
        return self.progress_ok

    def replace_draft(self, job_id, claimed_at, questions, artifacts):
        self.replace_calls += 1
        self.last_questions = questions
        self.last_artifacts = artifacts


class FakePipeline:
    def __init__(self, result=None, error=None):
        self.result = result or ProcessResult()
        self.error = error
        self.calls: list[tuple[str, int, int, object]] = []

    def process_file(self, source_path, page_start=1, page_end=None,
                     maximum_pages=20, progress_callback=None):
        self.calls.append((source_path, page_start, page_end, progress_callback))
        if progress_callback is not None:
            progress_callback(1, 20)
            progress_callback(20, 20)
        if self.error is not None:
            raise self.error
        return self.result


class FakeWriter:
    def __init__(self, error=None):
        self.error = error
        self.published: list[tuple[str, str, bytes]] = []
        self.sources: list[tuple[str, str]] = []

    def source_path(self, job_id, storage_key):
        self.sources.append((job_id, storage_key))
        return f"/vol/{storage_key}"

    def publish_artifact(self, job_id, artifact_id, payload):
        if self.error is not None:
            raise self.error
        self.published.append((job_id, artifact_id, payload))


def make_draft(question: str = "求极限") -> QuestionDraft:
    return QuestionDraft(
        id="draft-1", position=1, type="single_choice", question=question,
        options={"A": "0"}, answer=None, analysis=None,
        page_start=1, page_end=1, confidence=0.95, review_required=False,
        artifacts=[{"type": "question_image", "jpeg": b"jpeg-1"}],
    )


def test_run_once_returns_false_without_work_when_the_queue_is_empty():
    assert run_once(FakeStore(None), FakePipeline()) is False


def test_run_once_processes_a_claimed_job_end_to_end():
    store = FakeStore(make_job())
    pipeline = FakePipeline(result=ProcessResult(questions=[make_draft()]))
    writer = FakeWriter()

    assert run_once(store, pipeline, writer) is True

    assert pipeline.calls[0][0] == "/vol/job-1/source.pdf"
    assert pipeline.calls[0][1] == 1 and pipeline.calls[0][2] == 20
    assert store.progress == [(1, 20), (20, 20)]
    assert store.replace_calls == 1
    assert store.last_questions[0]["id"] == "draft-1"
    assert store.last_questions[0]["options"] == '{"A": "0"}'
    assert store.last_artifacts[0]["draft_question_id"] == "draft-1"
    assert store.last_artifacts[0]["size"] == len(b"jpeg-1")
    assert len(store.last_artifacts[0]["sha256"]) == 64
    assert store.last_artifacts[0]["expires_at"] == T0
    assert writer.published == [("job-1", store.last_artifacts[0]["id"], b"jpeg-1")]
    assert store.failures == []


def test_run_once_requeues_retryable_failures_with_their_token():
    store = FakeStore(make_job())
    pipeline = FakePipeline(error=RetryablePipelineError("OCR_FAILED", "low confidence"))

    assert run_once(store, pipeline, FakeWriter()) is True
    assert store.failures == [("job-1", T0, "OCR_FAILED", True)]


def test_run_once_fails_permanent_errors_without_requeue():
    store = FakeStore(make_job())
    pipeline = FakePipeline(error=PipelineError("PDF_INVALID", "not a pdf"))

    assert run_once(store, pipeline, FakeWriter()) is True
    assert store.failures == [("job-1", T0, "PDF_INVALID", False)]


def test_run_once_fails_storage_errors_as_retryable():
    store = FakeStore(make_job())
    writer = FakeWriter(error=ImportWriterError("IMPORT_STORAGE_FAILURE", "disk full"))

    assert run_once(
        store,
        FakePipeline(result=ProcessResult(questions=[make_draft()])),
        writer,
    ) is True
    assert store.failures == [("job-1", T0, "IMPORT_STORAGE_FAILURE", True)]
    assert store.replace_calls == 1  # rows were committed manifest-first


def test_run_once_aborts_when_the_claim_token_is_lost_during_progress():
    store = FakeStore(make_job())
    store.progress_ok = False  # update_progress returns False -> fence lost
    pipeline = FakePipeline(result=ProcessResult(questions=[make_draft()]))

    with pytest.raises(JobStoreError, match="lease lost"):
        run_once(store, pipeline, FakeWriter())

    assert store.replace_calls == 0


def test_run_once_fails_a_job_without_a_source_row():
    store = FakeStore(make_job(source_key=None))

    assert run_once(store, FakePipeline(), FakeWriter()) is True
    assert store.failures == [("job-1", T0, "IMPORT_STORAGE_FAILURE", True)]


def test_run_once_propagates_unclassified_failures_for_the_supervisor_loop():
    store = FakeStore(make_job())

    with pytest.raises(RuntimeError, match="disk exploded"):
        run_once(store, FakePipeline(error=RuntimeError("disk exploded")), FakeWriter())

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
