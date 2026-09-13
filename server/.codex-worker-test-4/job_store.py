"""MySQL job store for the single-concurrency OCR worker.

Mirrors the TypeScript `TypeOrmImportRepository` semantics so the worker can never
desynchronize from the API:

- ``claim_next`` runs a short transaction: ``SELECT ... FOR UPDATE SKIP LOCKED`` on the
  oldest queued job, then a conditional update to ``processing`` carrying a monotonic
  ``claimed_at`` token. A second worker cannot claim the same row.
- ``update_progress`` and ``fail`` are fenced by the ``claimed_at`` token, so a stale
  processing round can never pollute a newer one.
- ``fail`` increments ``retry_count``; a retryable failure is requeued while
  ``retry_count < 2``, otherwise the job stays ``failed`` with a stable error code.

Every timestamp is UTC. Every statement is parameterized; no input is ever
interpolated into SQL. The mysql-connector-python driver is imported lazily so the
module and its unit tests run without the driver installed.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
from typing import Callable, Optional, Tuple

JOB_COLUMN_SPECS = (
    ("id", "id"),
    ("user_id", "userId"),
    ("device_id", "deviceId"),
    ("bank_name", "bankName"),
    ("subject", "subject"),
    ("page_start", "pageStart"),
    ("page_end", "pageEnd"),
    ("source_sha256", "sourceSha256"),
    ("source_size", "sourceSize"),
    ("part_count", "partCount"),
    ("retry_count", "retryCount"),
    ("progress_current", "progressCurrent"),
    ("progress_total", "progressTotal"),
    ("error_code", "errorCode"),
    ("claimed_at", "claimedAt"),
    ("expires_at", "expiresAt"),
    ("created_at", "createdAt"),
    ("updated_at", "updatedAt"),
    ("status", "status"),
)
JOB_FIELDS = tuple(field for field, _column in JOB_COLUMN_SPECS)
JOB_COLUMNS = ", ".join(f"`{column}`" for _field, column in JOB_COLUMN_SPECS)

# Short-transaction claim: lock the oldest queued row without waiting on others.
CLAIM_SELECT = (
    "SELECT " + JOB_COLUMNS + " FROM `import_jobs` "
    "WHERE `status` = 'queued' ORDER BY `createdAt` ASC LIMIT 1 FOR UPDATE SKIP LOCKED"
)
CLAIM_UPDATE = (
    "UPDATE `import_jobs` SET `status` = 'processing', `claimedAt` = %s, "
    "`updatedAt` = %s, `errorCode` = NULL WHERE `id` = %s AND `status` = 'queued'"
)
PROGRESS_UPDATE = (
    "UPDATE `import_jobs` SET `progressCurrent` = %s, `progressTotal` = %s "
    "WHERE `id` = %s AND `status` = 'processing' AND `claimedAt` = %s"
)
FAIL_SELECT = (
    "SELECT `retryCount` FROM `import_jobs` "
    "WHERE `id` = %s AND `status` = 'processing' AND `claimedAt` = %s FOR UPDATE"
)
FAIL_UPDATE = (
    "UPDATE `import_jobs` SET `status` = 'failed', `retryCount` = %s, `errorCode` = %s, "
    "`updatedAt` = %s WHERE `id` = %s AND `status` = 'processing' AND `claimedAt` = %s"
)
REQUEUE_UPDATE = (
    "UPDATE `import_jobs` SET `status` = 'queued' "
    "WHERE `id` = %s AND `status` = 'failed' AND `retryCount` = %s"
)
GET_SELECT = "SELECT " + JOB_COLUMNS + " FROM `import_jobs` WHERE `id` = %s"

# The worker consumes source.pdf through the manifest-first artifact row written by
# the API's complete step; the row is the tombstone covering the published file.
SOURCE_KEY_SELECT = (
    "SELECT `storageKey` FROM `import_artifacts` "
    "WHERE `jobId` = %s AND `type` = 'source_pdf' ORDER BY `id` ASC LIMIT 1"
)
# Draft replacement is one atomic transaction: stale image rows and drafts are
# deleted, new drafts and image artifact rows are inserted, then the job moves
# processing -> review. Any failure rolls the whole transaction back, so the
# database never observes a half-written draft set.
DRAFT_IMAGE_DELETE = (
    "DELETE FROM `import_artifacts` WHERE `jobId` = %s AND `type` = 'question_image'"
)
DRAFT_DELETE = "DELETE FROM `import_draft_questions` WHERE `jobId` = %s"
DRAFT_INSERT = (
    "INSERT INTO `import_draft_questions` "
    "(`id`, `jobId`, `position`, `type`, `question`, `options`, `answer`, `analysis`, "
    "`pageStart`, `pageEnd`, `confidence`, `reviewRequired`) "
    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)"
)
ARTIFACT_INSERT = (
    "INSERT INTO `import_artifacts` "
    "(`id`, `jobId`, `draftQuestionId`, `type`, `storageKey`, `sha256`, `size`, `expiresAt`) "
    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s)"
)
DRAFT_JOB_LOCK = (
    "SELECT `id` FROM `import_jobs` "
    "WHERE `id` = %s AND `claimedAt` = %s AND `status` IN ('processing', 'review') FOR UPDATE"
)
REVIEW_UPDATE = (
    "UPDATE `import_jobs` SET `status` = 'review' "
    "WHERE `id` = %s AND `claimedAt` = %s AND `status` IN ('processing', 'review')"
)

MAX_AUTOMATIC_RETRIES = 2


class JobStoreError(Exception):
    """Raised for state violations; never exposes SQL or server internals."""


@dataclass(frozen=True)
class Job:
    """Read model of one import_jobs row (columns mirror the API contract)."""

    id: str
    user_id: str
    device_id: str
    bank_name: str
    subject: str
    page_start: int
    page_end: int
    source_sha256: str
    source_size: str
    part_count: int
    retry_count: int
    progress_current: int = 0
    progress_total: int = 0
    error_code: Optional[str] = None
    claimed_at: Optional[datetime] = None
    expires_at: Optional[datetime] = None
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None
    status: str = field(default="queued")
    source_storage_key: Optional[str] = None


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def default_connect():
    """Lazy driver import so tests can run without mysql-connector-python."""
    import mysql.connector  # noqa: PLC0415

    return mysql.connector.connect


class JobStore:
    """Owns claim/failure transitions against the shared import_jobs table."""

    def __init__(
        self,
        connect: Callable[[], object] | None = None,
        clock: Callable[[], datetime] = utcnow,
    ) -> None:
        self._connect = connect if connect is not None else default_connect()
        self._clock = clock

    def claim_next(self, worker_id: str) -> Optional[Job]:
        """Claim the oldest queued job, or None when the queue is empty.

        The claimed_at token is monotonic: when the previous token is still in the
        future (clock skew or a fast requeue), it is bumped by one millisecond so
        stale rounds can never match a newer claim. The manifest-first source_pdf
        artifact row written by the API's complete step is resolved in the same
        transaction, so a claimed job always carries the key of the file to read.
        """
        del worker_id  # single-concurrency worker; the lease token is claimed_at
        connection = self._connect()
        try:
            cursor = connection.cursor()
            try:
                cursor.execute(CLAIM_SELECT)
                row = cursor.fetchone()
                if row is None:
                    connection.commit()
                    return None
                # MySQL `claimedAt` is DATETIME(3), so the fencing token must
                # be generated at millisecond precision. Otherwise Python may
                # retain microseconds that MySQL discards/rounds and subsequent
                # `WHERE claimedAt = %s` progress updates lose the lease.
                now = self._clock()
                now = now.replace(
                    microsecond=(now.microsecond // 1000) * 1000
                )
                claimed_at = row[14]

                if claimed_at is not None:
                    # mysql-connector returns DATETIME as a naive datetime while
                    # the injected clock may be UTC-aware. Align only for the
                    # comparison; all persisted timestamps still represent UTC.
                    compare_now = now
                    if claimed_at.tzinfo is None and now.tzinfo is not None:
                        compare_now = now.astimezone(timezone.utc).replace(tzinfo=None)
                    elif claimed_at.tzinfo is not None and now.tzinfo is None:
                        compare_now = now.replace(tzinfo=timezone.utc)

                    if claimed_at >= compare_now:
                        claimed_at = claimed_at + timedelta(milliseconds=1)
                    else:
                        claimed_at = now
                else:
                    claimed_at = now

                claimed_at = claimed_at.replace(
                    microsecond=(claimed_at.microsecond // 1000) * 1000
                )
                cursor.execute(CLAIM_UPDATE, (claimed_at, now, row[0]))
                if cursor.rowcount != 1:
                    # Another worker won the conditional update; the lock is released
                    # by the rollback and the loser retries on the next loop.
                    connection.rollback()
                    return None
                source_storage_key: Optional[str] = None
                cursor.execute(SOURCE_KEY_SELECT, (row[0],))
                source_row = cursor.fetchone()
                if source_row is not None:
                    source_storage_key = source_row[0]
                connection.commit()
                # The SELECT snapshot predates the conditional update; return the job
                # exactly as the API would see it after a successful claim.
                return replace(
                    self._job_from_row(row),
                    claimed_at=claimed_at,
                    status="processing",
                    source_storage_key=source_storage_key,
                )
            finally:
                cursor.close()
        finally:
            connection.close()

    def update_progress(
        self, job_id: str, claimed_at: datetime, current: int, total: int
    ) -> bool:
        """Persist page progress; returns False when the token no longer owns the job."""
        if not isinstance(current, int) or not isinstance(total, int) or current < 0 or total < 0 or current > total:
            raise JobStoreError("invalid progress")
        connection = self._connect()
        try:
            cursor = connection.cursor()
            try:
                cursor.execute(PROGRESS_UPDATE, (current, total, job_id, claimed_at))
                affected = cursor.rowcount
                connection.commit()
                return affected == 1
            finally:
                cursor.close()
        finally:
            connection.close()

    def replace_draft(
        self,
        job_id: str,
        claimed_at: datetime,
        questions: list[dict],
        artifacts: list[dict],
    ) -> None:
        """Atomically replace the job's draft rows and move processing → review.

        One transaction deletes stale question_image rows and drafts, inserts the
        new drafts and image artifact rows (manifest-first: rows precede file
        publication), then flips the job to review. Any failure rolls everything
        back — the database never observes a half-written draft set. The
        claimed_at token fences the write: a stale round raises JobStoreError.
        The call is idempotent within the same token while the job is still
        processing *or* review, so a retry after a failed image-file publication
        rewrites the rows without changing the state.
        """
        if not questions or not isinstance(questions, list):
            raise JobStoreError("invalid draft payload")
        connection = self._connect()
        try:
            cursor = connection.cursor()
            try:
                cursor.execute(DRAFT_JOB_LOCK, (job_id, claimed_at))
                if cursor.fetchone() is None:
                    raise JobStoreError("job is not processing under this token")
                cursor.execute(DRAFT_IMAGE_DELETE, (job_id,))
                cursor.execute(DRAFT_DELETE, (job_id,))
                cursor.executemany(
                    DRAFT_INSERT,
                    [
                        (
                            q["id"], job_id, q["position"], q["type"], q["question"],
                            q.get("options"), q.get("answer"), q.get("analysis"),
                            q["page_start"], q["page_end"], q["confidence"],
                            bool(q["review_required"]),
                        )
                        for q in questions
                    ],
                )
                if artifacts:
                    cursor.executemany(
                        ARTIFACT_INSERT,
                        [
                            (
                                a["id"], job_id, a["draft_question_id"], "question_image",
                                a["storage_key"], a["sha256"], a["size"], a["expires_at"],
                            )
                            for a in artifacts
                        ],
                    )
                cursor.execute(REVIEW_UPDATE, (job_id, claimed_at))
                if cursor.rowcount != 1:
                    raise JobStoreError("job state changed during draft replacement")
                connection.commit()
            except Exception:
                # Mirror mysql-connector's requirement: a failed transaction must
                # be explicitly rolled back before the connection is reused/closed.
                try:
                    connection.rollback()
                except Exception:  # noqa: BLE001 - preserve the original failure
                    pass
                raise
            finally:
                cursor.close()
        finally:
            connection.close()

    def fail(
        self,
        job_id: str,
        claimed_at: datetime,
        code: str,
        retryable: bool = True,
    ) -> None:
        """Mark a claimed job failed and requeue retryable failures (max twice).

        The claimed_at token fences the write: a stale round whose token no longer
        matches raises JobStoreError instead of touching a newer processing round.
        """
        if not code or not isinstance(code, str):
            raise JobStoreError("invalid failure code")
        connection = self._connect()
        try:
            cursor = connection.cursor()
            try:
                cursor.execute(FAIL_SELECT, (job_id, claimed_at))
                row = cursor.fetchone()
                if row is None:
                    connection.rollback()
                    raise JobStoreError("job is not processing under this token")
                retry_count = int(row[0]) + 1
                if retry_count > MAX_AUTOMATIC_RETRIES:
                    connection.rollback()
                    raise JobStoreError("automatic retry limit exceeded")
                now = self._clock()
                cursor.execute(
                    FAIL_UPDATE, (retry_count, code, now, job_id, claimed_at)
                )
                if cursor.rowcount != 1:
                    connection.rollback()
                    raise JobStoreError("job state changed during failure handling")
                if retryable and retry_count < MAX_AUTOMATIC_RETRIES:
                    cursor.execute(REQUEUE_UPDATE, (job_id, retry_count))
                    if cursor.rowcount != 1:
                        connection.rollback()
                        raise JobStoreError("job state changed during requeue")
                connection.commit()
            finally:
                cursor.close()
        finally:
            connection.close()

    def get(self, job_id: str) -> Optional[Job]:
        """Read one job row by id (None when missing)."""
        connection = self._connect()
        try:
            cursor = connection.cursor()
            try:
                cursor.execute(GET_SELECT, (job_id,))
                row = cursor.fetchone()
                return None if row is None else self._job_from_row(row)
            finally:
                cursor.close()
        finally:
            connection.close()

    def _job_from_row(self, row: Tuple) -> Job:
        return Job(
            id=row[0],
            user_id=row[1],
            device_id=row[2],
            bank_name=row[3],
            subject=row[4],
            page_start=row[5],
            page_end=row[6],
            source_sha256=row[7],
            source_size=row[8],
            part_count=row[9],
            retry_count=row[10],
            progress_current=row[11],
            progress_total=row[12],
            error_code=row[13],
            claimed_at=row[14],
            expires_at=row[15],
            created_at=row[16],
            updated_at=row[17],
            status=row[18],
        )
