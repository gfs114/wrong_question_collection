"""Single-concurrency OCR worker entry point.

Polls import_jobs through JobStore with a short claim transaction and processes
each claimed job end-to-end:

1. claim → resolve the manifest-first ``source.pdf`` storage key (claimedAt token);
2. PdfPipeline renders/OCRs one page at a time, cropping question images;
3. per-page progress is persisted under the claim token (fence loss aborts);
4. draft + question_image artifact rows are committed atomically (replace_draft)
   and the job moves processing → review — rows precede bytes (manifest-first);
5. only then are the image files published atomically into the import volume.

Failures are classified: permanent PDF errors and page-range errors fail the job
(PipelineError), transient OCR/storage errors requeue it (RetryablePipelineError,
at most twice), and a lost claim token surfaces as JobStoreError for the loop.

There is deliberately no HTTP server: the worker only ever talks to MySQL and
the import volume, and it must stay terminated and restarted by the deployment
supervisor (Compose restart policy / systemd). SIGTERM/SIGINT stop the loop
between jobs; a job in flight is fenced by its claimed_at token, so a restart
cannot double-process or corrupt progress.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import signal
import sys
import time
import uuid
from typing import Callable, Optional

from errors import PipelineError, RetryablePipelineError
from import_writer import ImportWriter, ImportWriterError
from job_store import Job, JobStore, JobStoreError, default_connect
from pdf_pipeline import PdfPipeline

logger = logging.getLogger("wqc.worker")

POLL_SECONDS = float(os.environ.get("WQC_WORKER_POLL_SECONDS", "5"))


def run_once(
    store: JobStore,
    pipeline: PdfPipeline,
    writer: Optional[ImportWriter] = None,
) -> bool:
    """Claim and process one job end-to-end; True when work was performed."""
    worker_id = os.environ.get("HOSTNAME", "ocr-worker")
    job = store.claim_next(worker_id)
    if job is None:
        return False
    if writer is None:
        writer = ImportWriter(os.environ["IMPORT_STORAGE_ROOT"])
    try:
        _process_job(store, pipeline, writer, job)
        return True
    except RetryablePipelineError as exc:
        store.fail(job.id, job.claimed_at, exc.code, retryable=True)
    except PipelineError as exc:
        store.fail(job.id, job.claimed_at, exc.code, retryable=False)
    except ImportWriterError as exc:
        store.fail(job.id, job.claimed_at, exc.code, retryable=True)
    return True


def _process_job(
    store: JobStore,
    pipeline: PdfPipeline,
    writer: ImportWriter,
    job: Job,
) -> None:
    if job.source_storage_key is None:
        # Data inconsistency: the API's complete step always writes the source
        # row before queueing; a missing row cannot be fixed by reprocessing.
        raise RetryablePipelineError("IMPORT_STORAGE_FAILURE", "source pdf row missing")
    source = writer.source_path(job.id, job.source_storage_key)
    page_total = job.page_end - job.page_start + 1

    def on_page(current: int, total: int) -> None:
        if not store.update_progress(job.id, job.claimed_at, current, total):
            raise JobStoreError("lease lost during progress update")

    result = pipeline.process_file(
        str(source),
        page_start=job.page_start,
        page_end=job.page_end,
        progress_callback=on_page,
    )

    questions = [
        {
            "id": draft.id,
            "position": draft.position,
            "type": draft.type,
            "question": draft.question,
            "options": json.dumps(draft.options, ensure_ascii=False) if draft.options else None,
            "answer": draft.answer,
            "analysis": draft.analysis,
            "page_start": draft.page_start,
            "page_end": draft.page_end,
            "confidence": draft.confidence,
            "review_required": draft.review_required,
        }
        for draft in result.questions
    ]
    artifacts: list[dict] = []
    publications: list[tuple[str, bytes]] = []
    for draft in result.questions:
        for image in draft.artifacts:
            artifact_id = str(uuid.uuid4())
            payload = image["jpeg"]
            artifacts.append(
                {
                    "id": artifact_id,
                    "draft_question_id": draft.id,
                    "storage_key": f"{job.id}/artifact-{artifact_id}.bin",
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size": len(payload),
                    "expires_at": job.expires_at,
                }
            )
            publications.append((artifact_id, payload))

    # Manifest-first: the draft/artifact rows and the review transition commit
    # atomically before any image bytes are published. A later publication
    # failure leaves row-covered tombstones, and the idempotent replace_draft
    # lets a retry rewrite the rows under the same token.
    store.replace_draft(job.id, job.claimed_at, questions, artifacts)
    for artifact_id, payload in publications:
        writer.publish_artifact(job.id, artifact_id, payload)
    logger.info(
        "job %s processed: %d questions, %d images",
        job.id, len(questions), len(publications),
    )


def build_store() -> JobStore:
    connect = default_connect()
    connect(  # validate configuration eagerly so a misconfigured worker fails fast
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "3306")),
        user=os.environ["DB_RUNTIME_USER"],
        password=os.environ["DB_RUNTIME_PASSWORD"],
        database=os.environ["DB_NAME"],
    ).close()
    return JobStore(connect)


def build_writer() -> ImportWriter:
    return ImportWriter(os.environ["IMPORT_STORAGE_ROOT"])


class _Stopper:
    """Turns SIGTERM/SIGINT into a cooperative loop stop."""

    def __init__(self) -> None:
        self.stop = False
        self._previous: dict[int, object] = {}

    def install(self) -> None:
        for signum in (signal.SIGTERM, signal.SIGINT):
            self._previous[signum] = signal.getsignal(signum)
            signal.signal(signum, self._handle)

    def _handle(self, signum, _frame) -> None:  # noqa: ANN001
        self.stop = True

    def restore(self) -> None:
        for signum, handler in self._previous.items():
            signal.signal(signum, handler)  # type: ignore[arg-type]


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("WQC_WORKER_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    store = build_store()
    pipeline = PdfPipeline()
    writer = build_writer()
    stopper = _Stopper()
    stopper.install()
    logger.info("ocr worker started")
    try:
        while not stopper.stop:
            try:
                if run_once(store, pipeline, writer):
                    continue
            except JobStoreError as exc:
                logger.error("job store rejected a transition: %s", exc)
            except Exception:  # noqa: BLE001 - keep the loop alive on any failure
                logger.exception("unexpected worker failure")
            time.sleep(POLL_SECONDS)
    finally:
        stopper.restore()
    logger.info("ocr worker stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
