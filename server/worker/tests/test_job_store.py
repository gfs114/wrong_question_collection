"""JobStore claim/failure semantics against the in-memory MySQL stand-in.

Semantics mirror the TypeScript TypeOrmImportRepository: SKIP LOCKED claims,
claimed_at fencing of progress/failure writes, and two automatic retries for
retryable failures.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from job_store import JobStore, JobStoreError, utcnow
from tests.fake_mysql import COLUMN_INDEX, FakeDatabase, fake_connect, job_row

T0 = datetime(2026, 8, 27, 0, 0, 0, tzinfo=timezone.utc)


@pytest.fixture
def store():
    database = FakeDatabase()
    return JobStore(fake_connect(database)), database


def make_store(rows):
    database = FakeDatabase(rows)
    return JobStore(fake_connect(database)), database


def test_claim_returns_only_one_queued_job(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)

    first = imports.claim_next("worker-1")
    second = imports.claim_next("worker-2")

    assert first is not None
    assert first.status == "processing"
    assert first.claimed_at is not None
    assert second is None


def test_claim_takes_the_oldest_queued_job_first(store):
    imports, database = store
    database.jobs["old"] = job_row("old", created_at=T0)
    database.jobs["new"] = job_row("new", created_at=T0 + timedelta(seconds=1))
    database.jobs["busy"] = job_row("busy", status="processing", created_at=T0 - timedelta(days=1))
    database.jobs["done"] = job_row("done", status="failed", created_at=T0 - timedelta(days=2))

    claimed = imports.claim_next("worker-1")

    assert claimed is not None
    assert claimed.id == "old"
    assert imports.claim_next("worker-1").id == "new"
    assert imports.claim_next("worker-1") is None


def test_claim_token_is_monotonic_when_the_previous_token_is_in_the_future():
    database = FakeDatabase()
    now = T0 + timedelta(hours=1)
    future = now + timedelta(seconds=30)
    database.jobs["job-1"] = job_row("job-1", claimed_at=future, created_at=T0)
    imports = JobStore(fake_connect(database), clock=lambda: now)

    claimed = imports.claim_next("worker-1")

    assert claimed is not None
    assert claimed.claimed_at == future + timedelta(microseconds=1000)


def test_retryable_failure_requeues_once(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    claimed = imports.claim_next("worker-1")

    imports.fail("job-1", claimed.claimed_at, "OCR_FAILED", retryable=True)

    after = database.jobs["job-1"]
    assert after[COLUMN_INDEX["status"]] == "queued"
    assert after[COLUMN_INDEX["retry_count"]] == 1
    assert after[COLUMN_INDEX["error_code"]] == "OCR_FAILED"
    assert after[COLUMN_INDEX["claimed_at"]] is None


def test_retryable_failure_stops_after_two_retries(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)

    for _ in range(2):
        claimed = imports.claim_next("worker-1")
        imports.fail("job-1", claimed.claimed_at, "OCR_FAILED", retryable=True)

    assert imports.get("job-1").status == "failed"
    assert imports.get("job-1").retry_count == 2


def test_non_retryable_failure_stays_failed(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    claimed = imports.claim_next("worker-1")

    imports.fail("job-1", claimed.claimed_at, "PDF_INVALID", retryable=False)

    assert imports.get("job-1").status == "failed"
    assert imports.get("job-1").retry_count == 1


def test_fail_with_a_stale_token_raises_and_touches_nothing(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    claimed = imports.claim_next("worker-1")
    stale = claimed.claimed_at - timedelta(seconds=1)

    with pytest.raises(JobStoreError, match="not processing under this token"):
        imports.fail("job-1", stale, "OCR_FAILED", retryable=True)

    assert imports.get("job-1").status == "processing"
    assert imports.get("job-1").retry_count == 0


def test_fail_rejects_an_unknown_or_unclaimed_job(store):
    imports, _database = store
    with pytest.raises(JobStoreError, match="not processing under this token"):
        imports.fail("missing", T0, "OCR_FAILED", retryable=True)


def test_fail_rejects_when_the_automatic_retry_limit_is_exhausted(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", retry_count=2, created_at=T0)
    claimed = imports.claim_next("worker-1")

    with pytest.raises(JobStoreError, match="retry limit exceeded"):
        imports.fail("job-1", claimed.claimed_at, "OCR_FAILED", retryable=True)


def test_fail_validates_the_error_code(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    claimed = imports.claim_next("worker-1")

    with pytest.raises(JobStoreError, match="invalid failure code"):
        imports.fail("job-1", claimed.claimed_at, "", retryable=True)


def test_update_progress_is_fenced_by_the_claim_token(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    claimed = imports.claim_next("worker-1")

    assert imports.update_progress("job-1", claimed.claimed_at, 2, 20) is True
    assert imports.update_progress("job-1", T0, 3, 20) is False

    row = database.jobs["job-1"]
    assert row[COLUMN_INDEX["progress_current"]] == 2
    assert row[COLUMN_INDEX["progress_total"]] == 20


def test_update_progress_rejects_invalid_bounds(store):
    imports, _database = store
    with pytest.raises(JobStoreError, match="invalid progress"):
        imports.update_progress("job-1", T0, -1, 20)
    with pytest.raises(JobStoreError, match="invalid progress"):
        imports.update_progress("job-1", T0, 21, 20)


def test_get_returns_the_row_or_none(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)

    assert imports.get("job-1").id == "job-1"
    assert imports.get("missing") is None


def test_all_writes_are_parameterized_and_use_utc(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    claimed = imports.claim_next("worker-1")
    imports.fail("job-1", claimed.claimed_at, "OCR_FAILED", retryable=True)

    # Values travel only inside bound parameters, never inside SQL text: no job id,
    # error code, or timestamp literal may appear in a statement.
    for sql, params in database.statement_log:
        assert isinstance(params, tuple)
        assert "job-1" not in sql
        assert "OCR_FAILED" not in sql
        assert "2026" not in sql
        # Parameterized statements carry placeholders; pure reads may have none.
        assert "%s" in sql or params == ()
    # Requeue clears the claim token so the next claim can pick the job up again.
    assert database.jobs["job-1"][COLUMN_INDEX["claimed_at"]] is None
    assert imports.get("job-1").status == "queued"


def test_clock_is_injected_for_deterministic_tokens(store):
    database = FakeDatabase()
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    now = T0 + timedelta(hours=1)
    imports = JobStore(fake_connect(database), clock=lambda: now)

    claimed = imports.claim_next("worker-1")

    assert claimed.claimed_at == now


def test_claim_resolves_the_source_pdf_storage_key(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    database.artifacts["source-1"] = {
        "id": "source-1",
        "job_id": "job-1",
        "draft_question_id": None,
        "type": "source_pdf",
        "storage_key": "job-1/source.pdf",
        "sha256": "a" * 64,
        "size": 8,
        "expires_at": None,
    }

    claimed = imports.claim_next("worker-1")

    assert claimed is not None
    assert claimed.source_storage_key == "job-1/source.pdf"


def test_claim_without_a_source_row_still_returns_the_job(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)

    claimed = imports.claim_next("worker-1")

    assert claimed is not None
    assert claimed.source_storage_key is None


def make_draft_rows():
    return [
        {
            "id": "draft-1", "position": 1, "type": "single_choice",
            "question": "求极限", "options": {"A": "0"}, "answer": None,
            "analysis": None, "page_start": 1, "page_end": 1,
            "confidence": 0.95, "review_required": False,
        },
        {
            "id": "draft-2", "position": 2, "type": "blank",
            "question": "填空：x = （ ）", "options": None, "answer": None,
            "analysis": None, "page_start": 1, "page_end": 1,
            "confidence": 0.9, "review_required": False,
        },
    ]


def image_artifact(artifact_id: str, draft_id: str) -> dict:
    return {
        "id": artifact_id, "draft_question_id": draft_id,
        "storage_key": f"job-1/artifact-{artifact_id}.bin", "sha256": "b" * 64,
        "size": 1024, "expires_at": T0,
    }


def test_replace_draft_atomically_writes_drafts_artifacts_and_review(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    claimed = imports.claim_next("worker-1")

    imports.replace_draft(
        "job-1", claimed.claimed_at, make_draft_rows(), [image_artifact("image-1", "draft-1")]
    )

    assert database.jobs["job-1"][COLUMN_INDEX["status"]] == "review"
    assert set(database.drafts) == {"draft-1", "draft-2"}
    assert database.drafts["draft-1"]["question"] == "求极限"
    assert database.drafts["draft-2"]["type"] == "blank"
    assert database.artifacts["image-1"]["type"] == "question_image"
    assert database.artifacts["image-1"]["draft_question_id"] == "draft-1"
    assert database.artifacts["image-1"]["sha256"] == "b" * 64


def test_replace_draft_is_idempotent_for_a_retry(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    claimed = imports.claim_next("worker-1")
    imports.replace_draft(
        "job-1", claimed.claimed_at, make_draft_rows(), [image_artifact("image-1", "draft-1")]
    )
    questions = make_draft_rows()
    questions[1]["question"] = "填空：y = （ ）"

    imports.replace_draft(
        "job-1", claimed.claimed_at, questions, [image_artifact("image-2", "draft-1")]
    )

    assert set(database.drafts) == {"draft-1", "draft-2"}
    assert database.drafts["draft-2"]["question"] == "填空：y = （ ）"
    assert set(database.artifacts) == {"image-2"}


def test_replace_draft_rolls_back_everything_when_an_insert_fails(store):
    from job_store import DRAFT_INSERT

    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    claimed = imports.claim_next("worker-1")
    # Inject a mid-transaction crash on the second draft insert.
    database.fail_on = DRAFT_INSERT

    with pytest.raises(RuntimeError, match="injected statement failure"):
        imports.replace_draft(
            "job-1", claimed.claimed_at, make_draft_rows(), [image_artifact("image-1", "draft-1")]
        )

    # No half-written state: no drafts, no artifacts, still processing.
    assert database.drafts == {}
    assert database.artifacts == {}
    assert database.jobs["job-1"][COLUMN_INDEX["status"]] == "processing"


def test_replace_draft_is_fenced_by_the_claim_token(store):
    imports, database = store
    database.jobs["job-1"] = job_row("job-1", created_at=T0)
    claimed = imports.claim_next("worker-1")
    stale = claimed.claimed_at - timedelta(seconds=1)

    with pytest.raises(JobStoreError, match="not processing under this token"):
        imports.replace_draft("job-1", stale, make_draft_rows(), [])

    assert database.drafts == {}
    assert database.jobs["job-1"][COLUMN_INDEX["status"]] == "processing"


def test_replace_draft_rejects_an_empty_payload(store):
    imports, _database = store
    with pytest.raises(JobStoreError, match="invalid draft payload"):
        imports.replace_draft("job-1", T0, [], [])
