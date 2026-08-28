"""OCR line → question draft splitting for Chinese math workbooks.

Pure logic with no third-party imports so the entire splitting/classification
policy is unit-testable without PaddleOCR or PDFium. The OCR worker feeds one
page at a time through ``feed`` and collects drafts from ``finish``.

Splitting heuristics (conservative by design):

- A line whose text starts with a question number (Arabic or Chinese numerals)
  opens a new question; a continuation page keeps appending to the open question
  and updates ``page_end``.
- Option lines (``A.`` … ``H.``) are collected into the open question's options.
- Question type is inferred from shape: options → single choice; fill blanks
  (``( )``/``____``) → blank; imperative verbs (prove/compute/…)
  → short answer; otherwise unknown.
- ``review_required`` is set — never a hard failure — when confidence is low,
  question text is empty, the type is unknown, or the text looks formula-heavy,
  so the reviewer always has the original question image.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional
from uuid import uuid4

QUESTION_NUMBER = re.compile(r"^(?P<num>\d{1,3}|[一二三四五六七八九十百]+)\s*[.、．)](?P<rest>.*)$")
OPTION_KEY = re.compile(r"^(?P<key>[A-H])\s*[.、．)]\s*(?P<text>.*)$")
FILL_BLANK = re.compile(r"[（(]\s*[）)]|_{2,}")
SHORT_ANSWER_VERB = re.compile(r"^(证明|求|计算|化简|解|说明|判断|比较|画出|指出|写出|因式分解|已知)")
FORMULA_CHARS = re.compile(r"[√∫∑≠≥≤±×÷πΔ∞∈∀∃→←αβγθλμσφψω∂∇]|\\[a-zA-Z]+|_\{|_\{?[0-9a-zA-Z]+\}?|\^\{")
LOW_CONFIDENCE = 0.8

QUESTION_TYPES = ("single_choice", "blank", "short_answer", "unknown")

DraftArtifact = dict


@dataclass
class OcrLine:
    """One recognized text line in page coordinates (origin top-left)."""

    text: str
    confidence: float
    bbox: tuple[float, float, float, float]  # x0, y0, x1, y1


@dataclass
class QuestionDraft:
    id: str
    position: int
    type: str
    question: str
    options: Optional[dict[str, str]]
    answer: Optional[str]
    analysis: Optional[str]
    page_start: int
    page_end: int
    confidence: float
    review_required: bool
    artifacts: list[DraftArtifact] = field(default_factory=list)
    # Internal: per-page union bbox of the question's OCR lines, used by the
    # pipeline's second pass to crop images; never serialized to the API.
    page_regions: dict[int, tuple[float, float, float, float]] = field(
        default_factory=dict, repr=False, compare=False
    )


@dataclass
class _OpenQuestion:
    number: str
    lines: list[OcrLine]
    options: dict[str, str]
    page_start: int
    page_end: int
    page_regions: dict[int, tuple[float, float, float, float]] = field(default_factory=dict)


class QuestionParser:
    """Accumulates OCR lines and splits them into ordered question drafts."""

    def __init__(self, low_confidence: float = LOW_CONFIDENCE) -> None:
        self._low_confidence = low_confidence
        self._open: Optional[_OpenQuestion] = None
        self._questions: list[QuestionDraft] = []
        self._next_position = 1
        self._now = datetime.now(timezone.utc)

    def feed(self, page_number: int, lines: list[OcrLine]) -> None:
        """Feed one page's OCR output; page_number is 1-based."""
        for line in lines:
            self._feed_line(page_number, line)

    def finish(self) -> list[QuestionDraft]:
        """Close the open question and return ordered, review-flagged drafts."""
        self._close_open()
        drafts = self._questions
        self._open = None
        self._questions = []
        self._next_position = 1
        return drafts

    def _feed_line(self, page_number: int, line: OcrLine) -> None:
        text = line.text.strip()
        if not text:
            return
        number_match = QUESTION_NUMBER.match(text)
        if number_match is not None:
            self._close_open()
            self._open = _OpenQuestion(
                number=number_match.group("num"),
                lines=[OcrLine(number_match.group("rest").strip(), line.confidence, line.bbox)],
                options={},
                page_start=page_number,
                page_end=page_number,
            )
            self._record_region(page_number, line.bbox)
            return
        option_match = OPTION_KEY.match(text)
        if option_match is not None:
            if self._open is None:
                # Option lines before any question are noise, not a question body.
                return
            self._open.options[option_match.group("key")] = option_match.group("text").strip()
            self._record_region(page_number, line.bbox)
            return
        if self._open is None:
            # Text before any question number: treated as a numbered-less question
            # flagged for review instead of being silently dropped.
            self._open = _OpenQuestion(
                number="", lines=[line], options={}, page_start=page_number, page_end=page_number
            )
            self._record_region(page_number, line.bbox)
            return
        self._open.lines.append(line)
        self._open.page_end = page_number
        self._record_region(page_number, line.bbox)

    def _record_region(self, page_number: int, bbox: tuple[float, float, float, float]) -> None:
        question = self._open
        if question is None:
            return
        x0, y0, x1, y1 = bbox
        previous = question.page_regions.get(page_number)
        if previous is None:
            question.page_regions[page_number] = (x0, y0, x1, y1)
            return
        px0, py0, px1, py1 = previous
        question.page_regions[page_number] = (
            min(x0, px0), min(y0, py0), max(x1, px1), max(y1, py1)
        )

    def _close_open(self) -> None:
        if self._open is None:
            return
        question = self._open
        text = "\n".join(line.text.strip() for line in question.lines if line.text.strip())
        type_name = self._classify(text, question.options)
        confidences = [line.confidence for line in question.lines if line.text.strip()]
        confidence = sum(confidences) / len(confidences) if confidences else 0.0
        review_required = (
            not question.number
            or not text
            or confidence < self._low_confidence
            or type_name == "unknown"
            or FORMULA_CHARS.search(text) is not None
        )
        self._questions.append(
            QuestionDraft(
                id=str(uuid4()),
                position=self._next_position,
                type=type_name,
                question=text,
                options=dict(question.options) if question.options else None,
                answer=None,
                analysis=None,
                page_start=question.page_start,
                page_end=question.page_end,
                confidence=confidence,
                review_required=review_required,
                page_regions=dict(question.page_regions),
            )
        )
        self._next_position += 1
        self._open = None

    @staticmethod
    def _classify(text: str, options: dict[str, str]) -> str:
        if options:
            return "single_choice"
        if FILL_BLANK.search(text) is not None:
            return "blank"
        if SHORT_ANSWER_VERB.search(text) is not None:
            return "short_answer"
        return "unknown"
