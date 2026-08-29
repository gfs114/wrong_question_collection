"""Safe import-volume file access for the OCR worker (Python mirror of the
TypeScript ImportStorageService's security invariants).

The worker only ever reads the manifest-first ``source.pdf`` and publishes
question images. Every path is derived as ``<root>/<job UUID>/<fixed name>``,
rejects traversal and symbolic links, and publication is atomic and
no-overwrite (write a unique staging file, fsync, then hard-link it to the
canonical name — the same publish shape the API uses). The manifest-first rule
is enforced by the caller: artifact rows are committed before bytes are
published, so a late or failed publication always lands on a row-covered key.
"""

from __future__ import annotations

import hashlib
import os
import re
import uuid
from pathlib import Path

UUID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)
SOURCE_FILE = "source.pdf"


class ImportWriterError(Exception):
    """Stable, non-path-leaking storage failure for the worker."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class ImportWriter:
    """Owns the private incoming root; only this process writes under it."""

    def __init__(self, root: str) -> None:
        if not os.path.isabs(root):
            raise ImportWriterError("IMPORT_STORAGE_FAILURE", "import root must be absolute")
        self._root = Path(root).resolve()
        # Mode is meaningful on POSIX only (the TypeScript storage service makes
        # the same platform split); passing it on Windows confuses sandboxes.
        if os.name == "nt":
            self._root.mkdir(parents=True, exist_ok=True)
        else:
            self._root.mkdir(parents=True, exist_ok=True, mode=0o700)

    def source_path(self, job_id: str, storage_key: str) -> Path:
        """Resolve a manifest-recorded source key into a readable file path."""
        job_dir = self._job_directory(job_id)
        segments = storage_key.split("/")
        if len(segments) != 2 or segments[0] != job_id or segments[1] != SOURCE_FILE:
            raise ImportWriterError("IMPORT_STORAGE_FAILURE", "invalid source storage key")
        path = job_dir / SOURCE_FILE
        self._assert_safe(path)
        return path

    def publish_artifact(self, job_id: str, artifact_id: str, payload: bytes) -> dict:
        """Atomically publish one question image; returns its sha256 and size.

        The canonical file is created only via a no-overwrite hard link from a
        unique staging file, so a duplicate artifact id fails instead of
        clobbering existing bytes. Callers must have committed the manifest row
        first (manifest-first).
        """
        if not UUID_PATTERN.match(artifact_id):
            raise ImportWriterError("IMPORT_STORAGE_FAILURE", "invalid artifact id")
        job_dir = self._job_directory(job_id)
        target = job_dir / f"artifact-{artifact_id}.bin"
        self._assert_safe(target)
        if target.exists() and not target.is_symlink():
            # Idempotent retry: verify the existing bytes instead of overwriting.
            if target.read_bytes() == payload:
                return self._digest(payload)
            raise ImportWriterError("IMPORT_STORAGE_FAILURE", "artifact id already published")
        staging = job_dir / f".artifact-{artifact_id}.{uuid.uuid4()}.partial"
        try:
            self._write_fsync(staging, payload)
            try:
                os.link(staging, target)
            except FileExistsError:
                if target.read_bytes() != payload:
                    raise ImportWriterError(
                        "IMPORT_STORAGE_FAILURE", "artifact id already published"
                    ) from None
        finally:
            try:
                staging.unlink(missing_ok=True)
            except OSError:  # pragma: no cover - Windows open-file edge
                pass
        return self._digest(payload)

    def delete_artifact(self, job_id: str, artifact_id: str) -> None:
        """Best-effort removal of a failed/stale artifact file."""
        if not UUID_PATTERN.match(artifact_id):
            return
        job_dir = self._job_directory(job_id)
        target = job_dir / f"artifact-{artifact_id}.bin"
        try:
            self._assert_safe(target)
            target.unlink(missing_ok=True)
        except (ImportWriterError, OSError):
            pass

    def _job_directory(self, job_id: str) -> Path:
        if not UUID_PATTERN.match(job_id):
            raise ImportWriterError("IMPORT_STORAGE_FAILURE", "invalid job id")
        candidate = self._root / job_id
        self._assert_contained(candidate)
        if candidate.is_symlink():
            raise ImportWriterError("IMPORT_STORAGE_FAILURE", "unsafe storage path")
        if os.name == "nt":
            candidate.mkdir(exist_ok=True)
        else:
            candidate.mkdir(mode=0o700, exist_ok=True)
        if not candidate.is_dir() or candidate.is_symlink():
            raise ImportWriterError("IMPORT_STORAGE_FAILURE", "unsafe storage path")
        return candidate

    def _assert_safe(self, path: Path) -> None:
        self._assert_contained(path)
        if path.is_symlink():
            raise ImportWriterError("IMPORT_STORAGE_FAILURE", "unsafe storage path")

    def _assert_contained(self, path: Path) -> None:
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path.absolute()
        if resolved != self._root and self._root not in resolved.parents:
            raise ImportWriterError("IMPORT_STORAGE_FAILURE", "unsafe storage path")

    @staticmethod
    def _write_fsync(path: Path, payload: bytes) -> None:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(path, flags, 0o600)
        try:
            os.write(fd, payload)
            os.fsync(fd)
        finally:
            os.close(fd)

    @staticmethod
    def _digest(payload: bytes) -> dict:
        return {"sha256": hashlib.sha256(payload).hexdigest(), "size": len(payload)}
