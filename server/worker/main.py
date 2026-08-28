"""Single-concurrency OCR worker entry point.

Polls import_jobs through JobStore with a short claim transaction and hands each
claimed job to a PdfPipeline. There is deliberately no HTTP server: the worker
only ever talks to MySQL and the import volume, and it must stay terminated and
restarted by the deployment supervisor (Compose restart policy / systemd).

Shutdown is cooperative: SIGTERM/SIGINT stop the loop between jobs. A job already
in flight is fenced by its claimed_at token; the next claim bumps the token, so a
restart cannot double-process or corrupt progress.
"""

from __future__ import annotations

import logging
import os
import signal
import sys
import time

from job_store import JobStore, JobStoreError, default_connect

logger = logging.getLogger("wqc.worker")

POLL_SECONDS = float(os.environ.get("WQC_WORKER_POLL_SECONDS", "5"))


class PipelineError(Exception):
    """Base class for classified pipeline failures with a stable public code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class RetryablePipelineError(PipelineError):
    """Transient failure; the job may be retried automatically (max twice)."""


class PdfPipeline:
    """Processes one claimed import job (implemented in task 6).

    The worker loop only depends on ``process(job)`` raising classified errors,
    so main.py is testable with a fake pipeline before the real OCR pipeline lands.
    """

    def process(self, job) -> None:  # pragma: no cover - task 6 implementation
        raise NotImplementedError


def run_once(store: JobStore, pipeline: PdfPipeline) -> bool:
    """Claim and process one job; return True when work was performed."""
    worker_id = os.environ.get("HOSTNAME", "ocr-worker")
    job = store.claim_next(worker_id)
    if job is None:
        return False
    try:
        pipeline.process(job)
        return True
    except RetryablePipelineError as exc:
        store.fail(job.id, job.claimed_at, exc.code, retryable=True)
    except PipelineError as exc:
        store.fail(job.id, job.claimed_at, exc.code, retryable=False)
    return True


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
    stopper = _Stopper()
    stopper.install()
    logger.info("ocr worker started")
    try:
        while not stopper.stop:
            try:
                if run_once(store, pipeline):
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
