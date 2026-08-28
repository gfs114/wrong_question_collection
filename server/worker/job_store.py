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

JOB_COLUMNS = (
    "id, user_id, device_id, bank_name, subject, page_start, page_end, "
    "source_sha256, source_size, part_count, retry_count, "
    "progress_current, progress_total, error_code, claimed_at, expires_at, "
    "created_at, updated_at, status"
)

# Short-transaction claim: lock the oldest queued row without waiting on others.
CLAIM_SELECT = (
    "SELECT " + JOB_COLUMNS + " FROM import_jobs "
    "WHERE status = 'queued' ORDER BY created_at ASC LIMIT 1 FOR UPDATE SKIP LOCKED"
)
CLAIM_UPDATE = (
    "UPDATE import_jobs SET status = 'processing', claimed_at = %s, "
    "updated_at = %s, error_code = NULL WHERE id = %s AND status = 'queued'"
)
PROGRESS_UPDATE = (
    "UPDATE import_jobs SET progress_current = %s, progress_total = %s "
    "WHERE id = %s AND status = 'processing' AND claimed_at = %s"
)
FAIL_SELECT = (
    "SELECT retry_count FROM import_jobs "
    "WHERE id = %s AND status = 'processing' AND claimed_at = %s FOR UPDATE"
)
FAIL_UPDATE = (
    "UPDATE import_jobs SET status = 'failed', retry_count = %s, error_code = %s, "
    "updated_at = %s WHERE id = %s AND status = 'processing' AND claimed_at = %s"
)
REQUEUE_UPDATE = (
    "UPDATE import_jobs SET status = 'queued' "
    "WHERE id = %s AND status = 'failed' AND retry_count = %s"
)
GET_SELECT = "SELECT " + JOB_COLUMNS + " FROM import_jobs WHERE id = %s"

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
        stale rounds can never match a newer claim.
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
                now = self._clock()
                claimed_at = row[14]
                if claimed_at is not None and claimed_at >= now:
                    claimed_at = claimed_at + timedelta(microseconds=1000)
                else:
                    claimed_at = now
                cursor.execute(CLAIM_UPDATE, (claimed_at, now, row[0]))
                if cursor.rowcount != 1:
                    # Another worker won the conditional update; the lock is released
                    # by the rollback and the loser retries on the next loop.
                    connection.rollback()
                    return None
                connection.commit()
                # The SELECT snapshot predates the conditional update; return the job
                # exactly as the API would see it after a successful claim.
                return replace(
                    self._job_from_row(row),
                    claimed_at=claimed_at,
                    status="processing",
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
