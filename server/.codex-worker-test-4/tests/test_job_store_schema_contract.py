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

WORKER_REQUIRED_COLUMNS = {
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
    ),
}

EXPECTED_JOB_COLUMN_SPECS = (
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

EXPECTED_JOB_FIELDS = (
    "id",
    "user_id",
    "device_id",
    "bank_name",
    "subject",
    "page_start",
    "page_end",
    "source_sha256",
    "source_size",
    "part_count",
    "retry_count",
    "progress_current",
    "progress_total",
    "error_code",
    "claimed_at",
    "expires_at",
    "created_at",
    "updated_at",
    "status",
)

EXPECTED_JOB_PROJECTION = (
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
EXPECTED_JOB_COLUMNS = ", ".join(
    f"`{column}`" for column in EXPECTED_JOB_PROJECTION
)

EXPECTED_SQL_CONTRACTS = {
    "CLAIM_SELECT": {
        "table": "import_jobs",
        "sql": (
            f"SELECT {EXPECTED_JOB_COLUMNS} FROM `import_jobs` "
            "WHERE `status` = 'queued' ORDER BY `createdAt` ASC "
            "LIMIT 1 FOR UPDATE SKIP LOCKED"
        ),
        "parameters": (),
    },
    "CLAIM_UPDATE": {
        "table": "import_jobs",
        "sql": (
            "UPDATE `import_jobs` SET `status` = 'processing', `claimedAt` = %s, "
            "`updatedAt` = %s, `errorCode` = NULL "
            "WHERE `id` = %s AND `status` = 'queued'"
        ),
        "parameters": ("claimed_at", "updated_at", "job_id"),
    },
    "PROGRESS_UPDATE": {
        "table": "import_jobs",
        "sql": (
            "UPDATE `import_jobs` SET `progressCurrent` = %s, `progressTotal` = %s "
            "WHERE `id` = %s AND `status` = 'processing' AND `claimedAt` = %s"
        ),
        "parameters": ("current", "total", "job_id", "claimed_at"),
    },
    "FAIL_SELECT": {
        "table": "import_jobs",
        "sql": (
            "SELECT `retryCount` FROM `import_jobs` WHERE `id` = %s "
            "AND `status` = 'processing' AND `claimedAt` = %s FOR UPDATE"
        ),
        "parameters": ("job_id", "claimed_at"),
    },
    "FAIL_UPDATE": {
        "table": "import_jobs",
        "sql": (
            "UPDATE `import_jobs` SET `status` = 'failed', `retryCount` = %s, "
            "`errorCode` = %s, `updatedAt` = %s WHERE `id` = %s "
            "AND `status` = 'processing' AND `claimedAt` = %s"
        ),
        "parameters": (
            "retry_count",
            "error_code",
            "updated_at",
            "job_id",
            "claimed_at",
        ),
    },
    "REQUEUE_UPDATE": {
        "table": "import_jobs",
        "sql": (
            "UPDATE `import_jobs` SET `status` = 'queued' WHERE `id` = %s "
            "AND `status` = 'failed' AND `retryCount` = %s"
        ),
        "parameters": ("job_id", "retry_count"),
    },
    "GET_SELECT": {
        "table": "import_jobs",
        "sql": (
            f"SELECT {EXPECTED_JOB_COLUMNS} FROM `import_jobs` WHERE `id` = %s"
        ),
        "parameters": ("job_id",),
    },
    "DRAFT_JOB_LOCK": {
        "table": "import_jobs",
        "sql": (
            "SELECT `id` FROM `import_jobs` WHERE `id` = %s AND `claimedAt` = %s "
            "AND `status` IN ('processing', 'review') FOR UPDATE"
        ),
        "parameters": ("job_id", "claimed_at"),
    },
    "REVIEW_UPDATE": {
        "table": "import_jobs",
        "sql": (
            "UPDATE `import_jobs` SET `status` = 'review' WHERE `id` = %s "
            "AND `claimedAt` = %s AND `status` IN ('processing', 'review')"
        ),
        "parameters": ("job_id", "claimed_at"),
    },
    "SOURCE_KEY_SELECT": {
        "table": "import_artifacts",
        "sql": (
            "SELECT `storageKey` FROM `import_artifacts` WHERE `jobId` = %s "
            "AND `type` = 'source_pdf' ORDER BY `id` ASC LIMIT 1"
        ),
        "parameters": ("job_id",),
    },
    "DRAFT_IMAGE_DELETE": {
        "table": "import_artifacts",
        "sql": (
            "DELETE FROM `import_artifacts` WHERE `jobId` = %s "
            "AND `type` = 'question_image'"
        ),
        "parameters": ("job_id",),
    },
    "ARTIFACT_INSERT": {
        "table": "import_artifacts",
        "sql": (
            "INSERT INTO `import_artifacts` "
            "(`id`, `jobId`, `draftQuestionId`, `type`, `storageKey`, `sha256`, "
            "`size`, `expiresAt`) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)"
        ),
        "parameters": (
            "id",
            "job_id",
            "draft_question_id",
            "type",
            "storage_key",
            "sha256",
            "size",
            "expires_at",
        ),
    },
    "DRAFT_DELETE": {
        "table": "import_draft_questions",
        "sql": "DELETE FROM `import_draft_questions` WHERE `jobId` = %s",
        "parameters": ("job_id",),
    },
    "DRAFT_INSERT": {
        "table": "import_draft_questions",
        "sql": (
            "INSERT INTO `import_draft_questions` "
            "(`id`, `jobId`, `position`, `type`, `question`, `options`, `answer`, "
            "`analysis`, `pageStart`, `pageEnd`, `confidence`, `reviewRequired`) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)"
        ),
        "parameters": (
            "id",
            "job_id",
            "position",
            "type",
            "question",
            "options",
            "answer",
            "analysis",
            "page_start",
            "page_end",
            "confidence",
            "review_required",
        ),
    },
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
    for table in WORKER_REQUIRED_COLUMNS:
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
        return WORKER_REQUIRED_COLUMNS
    parsed = _parse_migration(migration.read_text(encoding="utf-8"))
    for table, required_columns in WORKER_REQUIRED_COLUMNS.items():
        missing_columns = set(required_columns) - set(parsed[table])
        assert not missing_columns, (
            f"migration {table} is missing worker columns: {sorted(missing_columns)}"
        )
    return parsed


def _sql_without_values(sql: str) -> str:
    return re.sub(r"'(?:''|[^'])*'", " ", sql)


def _normalize_sql(sql: str) -> str:
    return " ".join(sql.split())


def test_real_migration_or_worker_snapshot_contains_all_required_columns():
    schema = _schema_columns()
    for table, required_columns in WORKER_REQUIRED_COLUMNS.items():
        assert set(required_columns) <= set(schema[table])


def test_job_column_specs_fields_and_projection_are_fixed():
    assert len(EXPECTED_JOB_COLUMN_SPECS) == 19
    assert len(EXPECTED_JOB_FIELDS) == 19
    assert len(EXPECTED_JOB_PROJECTION) == 19
    assert job_store.JOB_COLUMN_SPECS == EXPECTED_JOB_COLUMN_SPECS
    assert job_store.JOB_FIELDS == EXPECTED_JOB_FIELDS
    assert job_store.JOB_COLUMNS == EXPECTED_JOB_COLUMNS


def test_job_from_row_maps_the_fixed_nineteen_field_order():
    sentinels = tuple(f"sentinel-{index:02d}" for index in range(19))
    store = job_store.JobStore(connect=lambda: None)

    job = store._job_from_row(sentinels)

    assert tuple(getattr(job, field) for field in EXPECTED_JOB_FIELDS) == sentinels


def test_all_dml_constants_match_their_complete_sql_and_parameter_contracts():
    discovered_sql_constants = {
        name
        for name, value in vars(job_store).items()
        if name.isupper()
        and isinstance(value, str)
        and value.startswith(("SELECT ", "UPDATE ", "INSERT ", "DELETE "))
    }
    assert discovered_sql_constants == set(EXPECTED_SQL_CONTRACTS)

    for constant_name, contract in EXPECTED_SQL_CONTRACTS.items():
        actual_sql = _normalize_sql(getattr(job_store, constant_name))
        expected_sql = _normalize_sql(contract["sql"])
        parameter_order = contract["parameters"]

        assert expected_sql.count("%s") == len(parameter_order)
        assert actual_sql.count("%s") == len(parameter_order), (
            f"{constant_name} parameter order must be {parameter_order}"
        )
        assert actual_sql.split("%s") == expected_sql.split("%s"), (
            f"{constant_name} placeholders must follow {parameter_order}"
        )
        assert actual_sql == expected_sql


def test_all_sql_identifiers_are_quoted_and_exist_in_the_target_table():
    schema = _schema_columns()
    for constant_name, contract in EXPECTED_SQL_CONTRACTS.items():
        table = contract["table"]
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
    for constant_name in EXPECTED_SQL_CONTRACTS:
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
