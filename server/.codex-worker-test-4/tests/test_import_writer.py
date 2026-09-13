"""ImportWriter safety and atomicity tests (real filesystem, sandbox tmp)."""

from __future__ import annotations

import hashlib
import os
import uuid
from pathlib import Path

import pytest

from import_writer import ImportWriter, ImportWriterError

JOB_ID = "11111111-1111-4111-8111-111111111111"


@pytest.fixture
def writer() -> ImportWriter:
    # A fresh per-test root avoids both cross-test pollution and sandbox
    # protection left on reused directories.
    root = Path(__file__).resolve().parent.parent / ".pytest-tmp" / f"writer-{uuid.uuid4()}"
    return ImportWriter(str(root))


def test_source_path_resolves_only_manifested_source_keys(writer):
    assert writer.source_path(JOB_ID, f"{JOB_ID}/source.pdf") == (
        Path(writer._root) / JOB_ID / "source.pdf"
    )
    with pytest.raises(ImportWriterError):
        writer.source_path(JOB_ID, "other-job/source.pdf")
    with pytest.raises(ImportWriterError):
        writer.source_path(JOB_ID, f"{JOB_ID}/part-0000000000.bin")
    with pytest.raises(ImportWriterError):
        writer.source_path(JOB_ID, "../escape.pdf")
    with pytest.raises(ImportWriterError):
        writer.source_path("not-a-uuid", "x/source.pdf")


def test_publish_artifact_is_atomic_and_no_overwrite(writer):
    artifact_id = str(uuid.uuid4())
    payload = b"jpeg-bytes-1"
    result = writer.publish_artifact(JOB_ID, artifact_id, payload)

    assert result == {
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size": len(payload),
    }
    target = Path(writer._root) / JOB_ID / f"artifact-{artifact_id}.bin"
    assert target.read_bytes() == payload
    # No staging leftovers.
    assert not any(name.endswith(".partial") for name in os.listdir(target.parent))


def test_publish_artifact_is_idempotent_for_identical_bytes(writer):
    artifact_id = str(uuid.uuid4())
    payload = b"same-bytes"
    first = writer.publish_artifact(JOB_ID, artifact_id, payload)
    second = writer.publish_artifact(JOB_ID, artifact_id, payload)

    assert first == second
    assert (Path(writer._root) / JOB_ID / f"artifact-{artifact_id}.bin").read_bytes() == payload


def test_publish_artifact_rejects_conflicting_bytes(writer):
    artifact_id = str(uuid.uuid4())
    writer.publish_artifact(JOB_ID, artifact_id, b"first")

    with pytest.raises(ImportWriterError, match="already published"):
        writer.publish_artifact(JOB_ID, artifact_id, b"second")


def test_publish_artifact_rejects_invalid_ids(writer):
    with pytest.raises(ImportWriterError, match="invalid artifact id"):
        writer.publish_artifact(JOB_ID, "../escape", b"x")
    with pytest.raises(ImportWriterError, match="invalid job id"):
        writer.publish_artifact("not-a-uuid", str(uuid.uuid4()), b"x")


def test_delete_artifact_is_best_effort(writer):
    artifact_id = str(uuid.uuid4())
    writer.publish_artifact(JOB_ID, artifact_id, b"data")
    writer.delete_artifact(JOB_ID, artifact_id)
    assert not (Path(writer._root) / JOB_ID / f"artifact-{artifact_id}.bin").exists()
    # Missing/stale ids are harmless.
    writer.delete_artifact(JOB_ID, artifact_id)
    writer.delete_artifact("not-a-uuid", "bad-id")


def test_root_rejects_non_absolute_paths():
    with pytest.raises(ImportWriterError, match="must be absolute"):
        ImportWriter("relative/root")


def test_symlinked_job_directory_is_rejected(writer):
    outside = Path(writer._root).parent / f"outside-{uuid.uuid4()}"
    outside.mkdir(exist_ok=True)
    link = Path(writer._root) / JOB_ID
    link.symlink_to(outside, target_is_directory=True)

    with pytest.raises(ImportWriterError, match="unsafe storage path"):
        writer.source_path(JOB_ID, f"{JOB_ID}/source.pdf")

    link.unlink(missing_ok=True)
    outside.rmdir()
