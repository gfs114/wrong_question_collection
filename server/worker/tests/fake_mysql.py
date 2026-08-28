"""In-memory MySQL stand-in for JobStore tests.

Implements just enough transaction/locking semantics for the worker's fixed SQL
dialect: ``SELECT ... FOR UPDATE SKIP LOCKED`` locks rows until commit/rollback,
conditional UPDATEs report rowcount, and parameters are captured so tests can
assert that no value is ever interpolated into a statement.
"""

from __future__ import annotations

from job_store import (
    CLAIM_SELECT,
    CLAIM_UPDATE,
    FAIL_SELECT,
    FAIL_UPDATE,
    GET_SELECT,
    JOB_COLUMNS,
    PROGRESS_UPDATE,
    REQUEUE_UPDATE,
)

COLUMN_INDEX = {name: index for index, name in enumerate(JOB_COLUMNS.split(", "))}


def job_row(
    job_id: str,
    status: str = "queued",
    retry_count: int = 0,
    claimed_at=None,
    created_at=None,
    **overrides,
) -> list:
    row = [None] * len(COLUMN_INDEX)
    row[COLUMN_INDEX["id"]] = job_id
    row[COLUMN_INDEX["user_id"]] = "user-1"
    row[COLUMN_INDEX["device_id"]] = "device-1"
    row[COLUMN_INDEX["bank_name"]] = "Algebra mistakes"
    row[COLUMN_INDEX["subject"]] = "Math"
    row[COLUMN_INDEX["page_start"]] = 1
    row[COLUMN_INDEX["page_end"]] = 20
    row[COLUMN_INDEX["source_sha256"]] = "a" * 64
    row[COLUMN_INDEX["source_size"]] = "8"
    row[COLUMN_INDEX["part_count"]] = 2
    row[COLUMN_INDEX["retry_count"]] = retry_count
    row[COLUMN_INDEX["progress_current"]] = 0
    row[COLUMN_INDEX["progress_total"]] = 0
    row[COLUMN_INDEX["error_code"]] = None
    row[COLUMN_INDEX["claimed_at"]] = claimed_at
    row[COLUMN_INDEX["expires_at"]] = created_at
    row[COLUMN_INDEX["created_at"]] = created_at
    row[COLUMN_INDEX["updated_at"]] = created_at
    row[COLUMN_INDEX["status"]] = status
    for name, value in overrides.items():
        row[COLUMN_INDEX[name]] = value
    return row


class FakeDatabase:
    """Shared table plus per-transaction row locks."""

    def __init__(self, rows: list[list] | None = None) -> None:
        self.jobs = {row[COLUMN_INDEX["id"]]: row for row in (rows or [])}
        self.locked: set[str] = set()
        self.statement_log: list[tuple[str, tuple]] = []


class _FakeCursor:
    def __init__(self, database: FakeDatabase, txn: "_FakeTxn") -> None:
        self._db = database
        self._txn = txn
        self.rowcount = 0
        self._result: list[list] | None = None
        self._position = 0

    def execute(self, sql: str, params: tuple = ()) -> None:
        self._db.statement_log.append((sql, params))
        self.rowcount = 0
        self._result = None
        self._position = 0
        if sql is CLAIM_SELECT:
            for row_id, row in sorted(
                self._db.jobs.items(), key=lambda item: item[1][COLUMN_INDEX["created_at"]] or item[0]
            ):
                if (
                    row[COLUMN_INDEX["status"]] == "queued"
                    and row_id not in self._db.locked
                ):
                    self._db.locked.add(row_id)
                    self._txn.locked.add(row_id)
                    self._result = [row]
                    return
        elif sql is CLAIM_UPDATE:
            claimed_at, _now, job_id = params
            row = self._db.jobs.get(job_id)
            if row is not None and row[COLUMN_INDEX["status"]] == "queued":
                row[COLUMN_INDEX["status"]] = "processing"
                row[COLUMN_INDEX["claimed_at"]] = claimed_at
                row[COLUMN_INDEX["error_code"]] = None
                self.rowcount = 1
        elif sql is PROGRESS_UPDATE:
            current, total, job_id, claimed_at = params
            row = self._db.jobs.get(job_id)
            if (
                row is not None
                and row[COLUMN_INDEX["status"]] == "processing"
                and row[COLUMN_INDEX["claimed_at"]] == claimed_at
            ):
                row[COLUMN_INDEX["progress_current"]] = current
                row[COLUMN_INDEX["progress_total"]] = total
                self.rowcount = 1
        elif sql is FAIL_SELECT:
            job_id, claimed_at = params
            row = self._db.jobs.get(job_id)
            if (
                row is not None
                and row[COLUMN_INDEX["status"]] == "processing"
                and row[COLUMN_INDEX["claimed_at"]] == claimed_at
                and job_id not in self._db.locked
            ):
                self._db.locked.add(job_id)
                self._txn.locked.add(job_id)
                # Mirror the real projection: SELECT retry_count ... FOR UPDATE.
                self._result = [[row[COLUMN_INDEX["retry_count"]]]]
        elif sql is FAIL_UPDATE:
            retry_count, code, _now, job_id, claimed_at = params
            row = self._db.jobs.get(job_id)
            if (
                row is not None
                and row[COLUMN_INDEX["status"]] == "processing"
                and row[COLUMN_INDEX["claimed_at"]] == claimed_at
            ):
                row[COLUMN_INDEX["status"]] = "failed"
                row[COLUMN_INDEX["retry_count"]] = retry_count
                row[COLUMN_INDEX["error_code"]] = code
                self.rowcount = 1
        elif sql is REQUEUE_UPDATE:
            job_id, retry_count = params
            row = self._db.jobs.get(job_id)
            if (
                row is not None
                and row[COLUMN_INDEX["status"]] == "failed"
                and row[COLUMN_INDEX["retry_count"]] == retry_count
            ):
                row[COLUMN_INDEX["status"]] = "queued"
                row[COLUMN_INDEX["claimed_at"]] = None
                self.rowcount = 1
        elif sql is GET_SELECT:
            (job_id,) = params
            row = self._db.jobs.get(job_id)
            if row is not None:
                self._result = [row]

    def fetchone(self):
        if self._result is None or self._position >= len(self._result):
            return None
        row = self._result[self._position]
        self._position += 1
        return tuple(row)

    def fetchall(self):
        rows = self._result or []
        self._position = len(rows)
        return [tuple(row) for row in rows]

    def close(self) -> None:
        pass


class _FakeTxn:
    def __init__(self) -> None:
        self.locked: set[str] = set()
        self.closed = False

    def commit(self, database: FakeDatabase) -> None:
        database.locked -= self.locked
        self.locked.clear()

    def rollback(self, database: FakeDatabase) -> None:
        database.locked -= self.locked
        self.locked.clear()


class FakeConnection:
    """One connection; cursors share the single transaction of this connection."""

    def __init__(self, database: FakeDatabase) -> None:
        self._db = database
        self._txn = _FakeTxn()
        self.closed = False

    def cursor(self):
        return _FakeCursor(self._db, self._txn)

    def commit(self) -> None:
        self._txn.commit(self._db)

    def rollback(self) -> None:
        self._txn.rollback(self._db)

    def close(self) -> None:
        self.closed = True


def fake_connect(database: FakeDatabase):
    def connect():
        return FakeConnection(database)

    return connect
