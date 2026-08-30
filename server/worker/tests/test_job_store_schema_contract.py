"""Contract tests keeping worker SQL aligned with the TypeORM migration.

The worker image is built from ``server/worker`` alone, so the migration is not
always present at test time.  Repository runs parse the real migration; worker-
image runs fall back to the same fixed schema snapshot used for comparison.
"""

from __future__ import annotations

import re
from pathlib import Path

import job_store


MIGRATION_FILENAME = "1788000000000-cloud-import-schema.ts"

SCHEMA_SNAPSHOT = {
    "import_jobs": (
        "id",
        "userId",
        "deviceId",
        "bankName",
        "subject",
        "pageStart",
        "pageEnd",
        "status",
        "progressCurrent",
        "progressTotal",
        "sourceSha256",
        "sourceSize",
        "partCount",
        "retryCount",
        "errorCode",
        "claimedAt",
        "expiresAt",
        "createdAt",
        "updatedAt",
    ),
    "import_draft_questions": (
        "id",
        "jobId",
        "position",
        "type",
        "question",
        "options",
        "answer",
        "analysis",
        "pageStart",
        "pageEnd",
        "confidence",
        "reviewRequired",
        "createdAt",
        "updatedAt",
    ),
    "import_artifacts": (
        "id",
        "jobId",
        "draftQuestionId",
        "type",
        "storageKey",
        "sha256",
        "size",
        "expiresAt",
        "createdAt",
        "updatedAt",
    ),
}

JOB_PROJECTION = (
    "id",
    "userId",
    "deviceId",
    "bankName",
    "subject",
    "pageStart",
    "pageEnd",
    "sourceSha256",
    "sourceSize",
    "partCount",
    "retryCount",
    "progressCurrent",
    "progressTotal",
    "errorCode",
    "claimedAt",
    "expiresAt",
    "createdAt",
    "updatedAt",
    "status",
)

SQL_TABLE_BY_CONSTANT = {
    "CLAIM_SELECT": "import_jobs",
    "CLAIM_UPDATE": "import_jobs",
    "PROGRESS_UPDATE": "import_jobs",
    "FAIL_SELECT": "import_jobs",
    "FAIL_UPDATE": "import_jobs",
    "REQUEUE_UPDATE": "import_jobs",
    "GET_SELECT": "import_jobs",
    "DRAFT_JOB_LOCK": "import_jobs",
    "REVIEW_UPDATE": "import_jobs",
    "SOURCE_KEY_SELECT": "import_artifacts",
    "DRAFT_IMAGE_DELETE": "import_artifacts",
    "ARTIFACT_INSERT": "import_artifacts",
    "DRAFT_DELETE": "import_draft_questions",
    "DRAFT_INSERT": "import_draft_questions",
}

OLD_SNAKE_CASE_COLUMNS = {
    "user_id",
    "device_id",
    "bank_name",
    "page_start",
    "page_end",
    "progress_current",
    "progress_total",
    "source_sha256",
    "source_size",
    "part_count",
    "retry_count",
    "error_code",
    "claimed_at",
    "expires_at",
    "created_at",
    "updated_at",
    "job_id",
    "review_required",
    "draft_question_id",
    "storage_key",
}

SQL_KEYWORDS = {
    "AND",
    "ASC",
    "BY",
    "DELETE",
    "FOR",
    "FROM",
    "IN",
    "INSERT",
    "INTO",
    "LIMIT",
    "LOCKED",
    "NULL",
    "ORDER",
    "SELECT",
    "SET",
    "SKIP",
    "UPDATE",
    "VALUES",
    "WHERE",
}


def _find_migration() -> Path | None:
    """Return this checkout's migration, or None in the worker-only image."""
    server_root = Path(__file__).resolve().parents[2]
    migration = (
        server_root / "src" / "database" / "migrations" / MIGRATION_FILENAME
    )
    if migration.is_file():
        return migration
    assert not (server_root / "package.json").is_file(), (
        f"repository migration is missing: {migration}"
    )
    return None


def _parse_migration(source: str) -> dict[str, tuple[str, ...]]:
    normalized = source.replace("\\`", "`")
    parsed: dict[str, tuple[str, ...]] = {}
    for table in SCHEMA_SNAPSHOT:
        match = re.search(
            rf"CREATE\s+TABLE\s+`{re.escape(table)}`\s*\((.*?)\)\s*ENGINE\s*=",
            normalized,
            flags=re.DOTALL,
        )
        assert match is not None, f"migration does not create {table}"
        parsed[table] = tuple(
            column.group(1)
            for line in match.group(1).splitlines()
            if (column := re.match(r"\s*`([A-Za-z][A-Za-z0-9]*)`\s+", line))
        )
    return parsed


def _schema_columns() -> dict[str, tuple[str, ...]]:
    migration = _find_migration()
    if migration is None:
        return SCHEMA_SNAPSHOT
    parsed = _parse_migration(migration.read_text(encoding="utf-8"))
    assert parsed == SCHEMA_SNAPSHOT
    return parsed


def _sql_without_values(sql: str) -> str:
    return re.sub(r"'(?:''|[^'])*'", " ", sql)


def test_real_migration_or_worker_snapshot_defines_the_three_table_contract():
    assert _schema_columns() == SCHEMA_SNAPSHOT


def test_job_columns_keep_the_existing_nineteen_column_projection_order():
    assert len(JOB_PROJECTION) == 19
    assert job_store.JOB_COLUMNS == ", ".join(
        f"`{column}`" for column in JOB_PROJECTION
    )


def test_all_sql_identifiers_are_quoted_and_exist_in_the_target_table():
    schema = _schema_columns()
    discovered_sql_constants = {
        name
        for name, value in vars(job_store).items()
        if name.isupper()
        and isinstance(value, str)
        and value.startswith(("SELECT ", "UPDATE ", "INSERT ", "DELETE "))
    }
    assert discovered_sql_constants == set(SQL_TABLE_BY_CONSTANT)

    for constant_name, table in SQL_TABLE_BY_CONSTANT.items():
        sql = getattr(job_store, constant_name)
        quoted_identifiers = re.findall(r"`([^`]+)`", sql)
        assert table in quoted_identifiers, f"{constant_name} must quote `{table}`"

        referenced_columns = set(quoted_identifiers) - {table}
        unknown_columns = referenced_columns - set(schema[table])
        assert not unknown_columns, (
            f"{constant_name} references columns absent from {table}: "
            f"{sorted(unknown_columns)}"
        )

        without_values = _sql_without_values(sql).replace("%s", " ")
        without_quoted_identifiers = re.sub(r"`[^`]+`", " ", without_values)
        bare_identifiers = {
            token
            for token in re.findall(
                r"(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*(?![A-Za-z0-9_])",
                without_quoted_identifiers,
            )
            if token.upper() not in SQL_KEYWORDS
        }
        assert not bare_identifiers, (
            f"{constant_name} has unquoted identifiers: {sorted(bare_identifiers)}"
        )


def test_sql_never_uses_legacy_snake_case_physical_columns():
    for constant_name in SQL_TABLE_BY_CONSTANT:
        sql = _sql_without_values(getattr(job_store, constant_name))
        legacy_identifiers = {
            column
            for column in OLD_SNAKE_CASE_COLUMNS
            if re.search(
                rf"(?<![A-Za-z0-9_]){re.escape(column)}(?![A-Za-z0-9_])",
                sql,
            )
        }
        assert not legacy_identifiers, (
            f"{constant_name} uses legacy columns: {sorted(legacy_identifiers)}"
        )
