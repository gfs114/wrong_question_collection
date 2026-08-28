# OCR Worker

Single-concurrency job runner for cloud PDF imports. Claims `import_jobs` rows
from MySQL with `SELECT ... FOR UPDATE SKIP LOCKED`, hands them to the OCR
pipeline, and writes progress/failure back under a `claimed_at` fencing token.

## Layout

- `job_store.py` — MySQL claim/status transitions mirroring the TypeScript
  `TypeOrmImportRepository` (see `../src/imports/import.repository.ts`).
- `main.py` — one-job loop with cooperative SIGTERM/SIGINT shutdown and
  classified error handling (`RetryablePipelineError` vs `PipelineError`).
- `question_parser.py` — OCR line → question draft splitting/classification
  (question numbers, options, blank/short-answer/unknown types, confidence and
  formula review flags). Pure logic, no third-party imports.
- `pdf_pipeline.py` — bounded PDF processing: one page rendered and OCR'd at a
  time (long edge ≤ 4096, bitmap released before the next page), then a second
  pass renders each needed page once and crops question images as JPEG
  quality 88. Renderer/OCR/cropper are injected; production engines
  (pypdfium2, PaddleOCR, Pillow) are imported lazily.
- `download_models.py` — Docker build-stage script that initializes the Chinese
  PaddleOCR models under `/opt/ocr-models`; the runtime image copies them so the
  worker never needs outbound network access.
- `tests/` — pytest suite: in-memory MySQL stand-in, fake engines, and
  standard-library PDF fixtures (text/scanned/damaged/encrypted). The real
  PDFium integration tests run inside the worker image and skip locally.

## Run tests

```powershell
python -m pytest -q
```

## Required environment (deployment time)

The worker shares only DB runtime credentials with the API — never JWT, Huawei,
or backup secrets:

```text
DB_HOST=mysql
DB_PORT=3306
DB_NAME=wrong_question
DB_RUNTIME_USER=wqc_runtime
DB_RUNTIME_PASSWORD=...
WQC_WORKER_POLL_SECONDS=5        # optional
WQC_WORKER_LOG_LEVEL=INFO        # optional
WQC_OCR_LANGUAGE=ch              # optional; PaddleOCR language
HOSTNAME=ocr-worker              # optional; claim log identity
```

## Dependency lock files

`requirements.txt` / `requirements-dev.txt` are hashed lock files generated on a
Linux + Python 3.11 target (the same platform as the `python:3.11-slim` base
image) with:

```bash
python -m pip install "pip-tools>=7,<8"
python -m piptools compile --generate-hashes requirements.in -o requirements.txt
python -m piptools compile --generate-hashes requirements-dev.in -o requirements-dev.txt
```

The lock files must be regenerated in that target environment because some
transitive wheels (e.g. PaddlePaddle) are not published for newer CPython
versions on every platform. The Dockerfile installs with `--require-hashes` and
builds the OCR model home in a dedicated model stage.
