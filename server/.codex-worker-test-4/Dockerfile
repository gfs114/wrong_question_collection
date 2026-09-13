# OCR worker runtime image.
#
# The worker has no HTTP server and no public ports; it only talks to MySQL and
# the shared import volume. This image deliberately carries no JWT, Huawei, or
# backup secrets: the deployment (task 8) injects only the DB runtime credentials
# needed to claim jobs. The base image matches the lock file generation target
# (Python 3.11 + Linux) so hashes verified at build time match production.
#
# Multi-stage build: the model stage downloads the Chinese PaddleOCR models with
# outbound network access; the runtime stage copies the populated model home and
# the worker runs with no network (deployment enforces this via the internal
# worker network and read-only root in task 8).

FROM python:3.11-slim AS models

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    OCR_MODEL_HOME=/opt/ocr-models \
    PADDLE_PDX_OCR_MODEL_HOME=/opt/ocr-models \
    PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT=0

WORKDIR /build

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        libgl1 \
        libglib2.0-0 \
        libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --require-hashes -r requirements.txt

COPY download_models.py ./
RUN python download_models.py

FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    OCR_MODEL_HOME=/opt/ocr-models \
    PADDLE_PDX_OCR_MODEL_HOME=/opt/ocr-models \
    PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT=0

WORKDIR /work

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        libgl1 \
        libglib2.0-0 \
        libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system ocr \
    && useradd --system --gid ocr --home-dir /work --shell /usr/sbin/nologin ocr

COPY --from=models /opt/ocr-models /opt/ocr-models
COPY requirements.txt ./
RUN pip install --require-hashes -r requirements.txt

COPY . .

USER ocr
CMD ["python", "-m", "main"]
