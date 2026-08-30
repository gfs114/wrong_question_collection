"""In-memory MySQL stand-in for JobStore tests.

Implements enough transaction/locking semantics for the worker's fixed SQL
dialect: ``SELECT ... FOR UPDATE SKIP LOCKED`` locks rows until commit/rollback,
conditional UPDATEs report rowcount, parameters are captured so tests can assert
that no value is ever interpolated into a statement, and uncommitted writes are
snapshotted per transaction so a rollback discards them exactly like MySQL.

``FakeDatabase.fail_on`` injects a statement-identity failure (raises
RuntimeError before executing) so tests can verify that a mid-transaction crash
leaves no half-written state.
"""

from __future__ import annotations

from job_store import (
    ARTIFACT_INSERT,
    CLAIM_SELECT,
    CLAIM_UPDATE,
    DRAFT_DELETE,
    DRAFT_IMAGE_DELETE,
    DRAFT_INSERT,
    DRAFT_JOB_LOCK,
    FAIL_SELECT,
    FAIL_UPDATE,
    GET_SELECT,
    JOB_FIELDS,
    PROGRESS_UPDATE,
    REQUEUE_UPDATE,
    REVIEW_UPDATE,
    SOURCE_KEY_SELECT,
)

COLUMN_INDEX = {name: index for index, name in enumerate(JOB_FIELDS)}


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


def artifact_row(
    artifact_id: str,
    job_id: str,
    type_: str,
    storage_key: str,
    draft_question_id=None,
    sha256: str = "a" * 64,
    size: int = 8,
    expires_at=None,
) -> dict:
    return {
        "id": artifact_id,
        "job_id": job_id,
        "draft_question_id": draft_question_id,
        "type": type_,
        "storage_key": storage_key,
        "sha256": sha256,
        "size": size,
        "expires_at": expires_at,
    }


def _clone_tables(database: "FakeDatabase") -> tuple[dict, dict, dict]:
    return (
        {job_id: list(row) for job_id, row in database.jobs.items()},
        {artifact_id: dict(row) for artifact_id, row in database.artifacts.items()},
        {draft_id: dict(row) for draft_id, row in database.drafts.items()},
    )


class FakeDatabase:
    """Committed tables plus per-transaction snapshots and failure injection."""

    def __init__(self, rows: list[list] | None = None) -> None:
        self.jobs = {row[COLUMN_INDEX["id"]]: row for row in (rows or [])}
        self.artifacts: dict[str, dict] = {}
        self.drafts: dict[str, dict] = {}
        self.locked: set[str] = set()
        self.statement_log: list[tuple[str, tuple]] = []
        self.fail_on: object | None = None  # statement identity that raises


class _FakeTxn:
    """One transaction's snapshot; commit publishes it, rollback discards it."""

    def __init__(self, database: FakeDatabase) -> None:
        self.jobs, self.artifacts, self.drafts = _clone_tables(database)
        self.locked: set[str] = set()

    def commit(self, database: FakeDatabase) -> None:
        database.jobs, database.artifacts, database.drafts = (
            self.jobs,
            self.artifacts,
            self.drafts,
        )
        database.locked -= self.locked
        self.locked.clear()

    def rollback(self, database: FakeDatabase) -> None:
        database.locked -= self.locked
        self.locked.clear()


class _FakeCursor:
    def __init__(self, database: FakeDatabase, txn: _FakeTxn) -> None:
        self._db = database
        self._txn = txn
        self.rowcount = 0
        self._result: list[list] | None = None
        self._position = 0

    def execute(self, sql: str, params: tuple = ()) -> None:
        self._db.statement_log.append((sql, params))
        if sql is self._db.fail_on:
            raise RuntimeError("injected statement failure")
        self.rowcount = 0
        self._result = None
        self._position = 0
        jobs, artifacts, drafts = self._txn.jobs, self._txn.artifacts, self._txn.drafts
        if sql is CLAIM_SELECT:
            for row_id, row in sorted(
                jobs.items(), key=lambda item: item[1][COLUMN_INDEX["created_at"]] or item[0]
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
            row = jobs.get(job_id)
            if row is not None and row[COLUMN_INDEX["status"]] == "queued":
                row[COLUMN_INDEX["status"]] = "processing"
                row[COLUMN_INDEX["claimed_at"]] = claimed_at
                row[COLUMN_INDEX["error_code"]] = None
                self.rowcount = 1
        elif sql is PROGRESS_UPDATE:
            current, total, job_id, claimed_at = params
            row = jobs.get(job_id)
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
            row = jobs.get(job_id)
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
            row = jobs.get(job_id)
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
            row = jobs.get(job_id)
            if (
                row is not None
                and row[COLUMN_INDEX["status"]] == "failed"
                and row[COLUMN_INDEX["retry_count"]] == retry_count
            ):
                row[COLUMN_INDEX["status"]] = "queued"
                self.rowcount = 1
        elif sql is GET_SELECT:
            (job_id,) = params
            row = jobs.get(job_id)
            if row is not None:
                self._result = [row]
        elif sql is SOURCE_KEY_SELECT:
            (job_id,) = params
            sources = [
                artifact
                for artifact in artifacts.values()
                if artifact["job_id"] == job_id and artifact["type"] == "source_pdf"
            ]
            if sources:
                self._result = [[sources[0]["storage_key"]]]
        elif sql is DRAFT_JOB_LOCK:
            job_id, claimed_at = params
            row = jobs.get(job_id)
            if (
                row is not None
                and row[COLUMN_INDEX["claimed_at"]] == claimed_at
                and row[COLUMN_INDEX["status"]] in ("processing", "review")
                and job_id not in self._db.locked
            ):
                self._db.locked.add(job_id)
                self._txn.locked.add(job_id)
                self._result = [[job_id]]
        elif sql is DRAFT_IMAGE_DELETE:
            (job_id,) = params
            before = len(artifacts)
            for artifact_id in [
                artifact_id
                for artifact_id, row in list(artifacts.items())
                if row["job_id"] == job_id and row["type"] == "question_image"
            ]:
                del artifacts[artifact_id]
            self.rowcount = before - len(artifacts)
        elif sql is DRAFT_DELETE:
            (job_id,) = params
            before = len(drafts)
            for draft_id in [
                draft_id
                for draft_id, row in list(drafts.items())
                if row["job_id"] == job_id
            ]:
                del drafts[draft_id]
            self.rowcount = before - len(drafts)
        elif sql is DRAFT_INSERT:
            (
                draft_id, job_id, position, type_, question, options, answer,
                analysis, page_start, page_end, confidence, review_required,
            ) = params
            drafts[draft_id] = {
                "id": draft_id, "job_id": job_id, "position": position, "type": type_,
                "question": question, "options": options, "answer": answer,
                "analysis": analysis, "page_start": page_start, "page_end": page_end,
                "confidence": confidence, "review_required": review_required,
            }
            self.rowcount = 1
        elif sql is ARTIFACT_INSERT:
            (
                artifact_id, job_id, draft_question_id, type_, storage_key,
                sha256, size, expires_at,
            ) = params
            artifacts[artifact_id] = artifact_row(
                artifact_id, job_id, type_, storage_key,
                draft_question_id=draft_question_id, sha256=sha256,
                size=size, expires_at=expires_at,
            )
            self.rowcount = 1
        elif sql is REVIEW_UPDATE:
            job_id, claimed_at = params
            row = jobs.get(job_id)
            if (
                row is not None
                and row[COLUMN_INDEX["claimed_at"]] == claimed_at
                and row[COLUMN_INDEX["status"]] in ("processing", "review")
            ):
                row[COLUMN_INDEX["status"]] = "review"
                self.rowcount = 1

    def executemany(self, sql: str, params_list: list[tuple]) -> None:
        for params in params_list:
            self.execute(sql, params)
        self.rowcount = len(params_list)

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


class FakeConnection:
    """One connection; cursors share the single transaction of this connection."""

    def __init__(self, database: FakeDatabase) -> None:
        self._db = database
        self._txn = _FakeTxn(database)
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
