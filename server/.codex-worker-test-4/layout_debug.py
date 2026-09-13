"""Opt-in, read-only OCR geometry diagnostics for the math layout pipeline."""

from __future__ import annotations

import json
import logging
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Optional, Protocol, Sequence


logger = logging.getLogger("wqc.worker.layout")

_TRUE_VALUES = {"1", "true", "yes", "on"}
_TEXT_LIMIT = 160
_SENSITIVE_TEXT = re.compile(
    r"(?i)(?:access[_-]?token|refresh[_-]?token|authorization|cookie|"
    r"api[_-]?secret|password|client[_-]?secret)"
    r"(?:\s*[:=]\s*|\s+)(?:bearer\s+)?[^\s,;]+"
)


class DebugLine(Protocol):
    text: str
    confidence: float
    bbox: tuple[float, float, float, float]


@dataclass(frozen=True)
class _PageCapture:
    raw: tuple[DebugLine, ...]
    ordered: tuple[DebugLine, ...]


def _safe_text(value: object) -> str:
    text = str(value).replace("\r", " ").replace("\n", " ")
    text = _SENSITIVE_TEXT.sub("[REDACTED]", text)
    for name in (
        "accessToken",
        "refreshToken",
        "Authorization",
        "Cookie",
        "apiSecret",
        "password",
        "clientSecret",
    ):
        text = re.sub(re.escape(name), "[REDACTED]", text, flags=re.IGNORECASE)
    return text if len(text) <= _TEXT_LIMIT else text[: _TEXT_LIMIT - 1] + "…"


def _geometry(bbox: Sequence[float]) -> dict[str, object]:
    x1, y1, x2, y2 = (float(value) for value in bbox)
    return {
        "bbox": [x1, y1, x2, y2],
        "x1": x1,
        "y1": y1,
        "x2": x2,
        "y2": y2,
        "width": max(0.0, x2 - x1),
        "height": max(0.0, y2 - y1),
        "centerX": (x1 + x2) / 2.0,
        "centerY": (y1 + y2) / 2.0,
    }


def _intersection_area(
    first: Sequence[float],
    second: Sequence[float],
) -> float:
    return max(0.0, min(first[2], second[2]) - max(first[0], second[0])) * max(
        0.0,
        min(first[3], second[3]) - max(first[1], second[1]),
    )


def _matches_region(bbox: Sequence[float], region: Sequence[float]) -> bool:
    return _intersection_area(bbox, region) > 0.0


def _best_line_index(line: DebugLine, candidates: Sequence[DebugLine]) -> Optional[int]:
    best_index: Optional[int] = None
    best_score = float("-inf")
    for index, candidate in enumerate(candidates):
        text_score = 0.0
        if line.text == candidate.text:
            text_score = 1_000_000.0
        elif line.text in candidate.text or candidate.text in line.text:
            text_score = 100_000.0
        overlap = _intersection_area(line.bbox, candidate.bbox)
        line_center = ((line.bbox[0] + line.bbox[2]) / 2.0, (line.bbox[1] + line.bbox[3]) / 2.0)
        candidate_center = (
            (candidate.bbox[0] + candidate.bbox[2]) / 2.0,
            (candidate.bbox[1] + candidate.bbox[3]) / 2.0,
        )
        distance = abs(line_center[0] - candidate_center[0]) + abs(
            line_center[1] - candidate_center[1]
        )
        score = text_score + overlap - distance
        if score > best_score:
            best_score = score
            best_index = index
    return best_index


def _sanitize_trace(value: object) -> object:
    if isinstance(value, dict):
        return {
            str(key): (_safe_text(item) if key in {"text", "questionLabel"} else _sanitize_trace(item))
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_sanitize_trace(item) for item in value]
    if isinstance(value, tuple):
        return [_sanitize_trace(item) for item in value]
    return value


def _write_json_atomic(path: Path, payload: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


class LayoutDebugSession:
    """Collect diagnostics only when explicitly enabled through environment."""

    def __init__(self, match: str, json_path: Optional[Path]) -> None:
        self._match = match
        self._json_path = json_path
        self._pages: dict[int, _PageCapture] = {}
        self._reports: list[dict[str, object]] = []

    @classmethod
    def from_environment(cls) -> Optional["LayoutDebugSession"]:
        enabled = os.environ.get("WQC_OCR_LAYOUT_DEBUG", "").strip().lower()
        if enabled not in _TRUE_VALUES:
            return None
        match = os.environ.get("WQC_OCR_LAYOUT_DEBUG_MATCH", "").strip()
        raw_path = os.environ.get("WQC_OCR_LAYOUT_DEBUG_JSON", "").strip()
        return cls(match, Path(raw_path) if raw_path else None)

    def capture_page(
        self,
        page_number: int,
        raw: Sequence[DebugLine],
        ordered: Sequence[DebugLine],
    ) -> None:
        self._pages[page_number] = _PageCapture(tuple(raw), tuple(ordered))

    def matches(self, question_label: str, lines: Sequence[DebugLine]) -> bool:
        if not self._match:
            return True
        searchable = "\n".join([question_label, *(line.text for line in lines)])
        return self._match in searchable

    def emit_question(
        self,
        *,
        page_number: int,
        question_label: str,
        region: Sequence[float],
        detector_lines: Sequence[DebugLine],
        trace: Sequence[dict[str, object]],
    ) -> None:
        capture = self._pages.get(page_number, _PageCapture((), ()))
        raw_blocks: list[dict[str, object]] = []
        for original_order, line in enumerate(capture.raw):
            if not _matches_region(line.bbox, region):
                continue
            event = {
                "stage": "raw_block",
                "page": page_number,
                "questionLabel": _safe_text(question_label),
                "blockIndex": original_order,
                "originalOrder": original_order,
                "sortedOrder": _best_line_index(line, capture.ordered),
                "text": _safe_text(line.text),
                "confidence": float(line.confidence),
                **_geometry(line.bbox),
            }
            raw_blocks.append(event)
            self._log(event)

        blocks: list[dict[str, object]] = []
        for sorted_order, line in enumerate(detector_lines):
            event = {
                "stage": "detector_block",
                "page": page_number,
                "questionLabel": _safe_text(question_label),
                "blockIndex": sorted_order,
                "originalOrder": _best_line_index(line, capture.raw),
                "sortedOrder": sorted_order,
                "text": _safe_text(line.text),
                "confidence": float(line.confidence),
                **_geometry(line.bbox),
            }
            blocks.append(event)
            self._log(event)

        sanitized_trace = [
            {
                **dict(_sanitize_trace(item)),
                "page": page_number,
                "questionLabel": _safe_text(question_label),
            }
            for item in trace
        ]
        for event in sanitized_trace:
            self._log(event)

        report = {
            "page": page_number,
            "questionLabel": _safe_text(question_label),
            "region": _geometry(region),
            "rawBlocks": raw_blocks,
            "blocks": blocks,
            "piecewiseInputBlocks": [
                item for item in sanitized_trace if item.get("stage") == "piecewise_input_block"
            ],
            "piecewiseCandidates": [
                item for item in sanitized_trace if item.get("stage") == "piecewise_candidate"
            ],
            "clusters": [
                item for item in sanitized_trace if item.get("stage") == "piecewise_cluster"
            ],
        }
        self._reports.append(report)
        self._write_report()

    def reset(self) -> None:
        self._pages.clear()
        self._reports.clear()

    @staticmethod
    def _log(event: Mapping[str, object]) -> None:
        logger.info(
            "ocr_layout_debug %s",
            json.dumps(event, ensure_ascii=False, separators=(",", ":")),
        )

    def _write_report(self) -> None:
        if self._json_path is None:
            return
        try:
            _write_json_atomic(
                self._json_path,
                {"version": 1, "questions": self._reports},
            )
        except OSError as exc:
            logger.warning(
                "ocr_layout_debug json_write_failed path=%s error=%s",
                self._json_path,
                type(exc).__name__,
            )
