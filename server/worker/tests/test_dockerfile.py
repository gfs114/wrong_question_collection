"""Worker image contracts needed by PaddleOCR CPU inference."""

from __future__ import annotations

from pathlib import Path


DOCKERFILE = Path(__file__).resolve().parent.parent / "Dockerfile"


def docker_stages() -> list[str]:
    contents = DOCKERFILE.read_text(encoding="utf-8")
    return [stage for stage in contents.split("FROM python:3.11-slim AS ")[1:] if stage]


def test_both_docker_stages_disable_paddlex_mkldnn_by_default():
    stages = docker_stages()

    assert len(stages) == 2
    assert all("PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT=0" in stage for stage in stages)


def test_both_docker_stages_keep_native_paddleocr_libraries():
    stages = docker_stages()

    for stage in stages:
        assert "libgl1" in stage
        assert "libglib2.0-0" in stage
        assert "libgomp1" in stage
