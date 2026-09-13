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

from layout_debug import LayoutDebugSession
from math_layout import normalize_math_text, reconstruct_math_layout

# 普通题号：1. / 2、 / 一、 等。
QUESTION_NUMBER = re.compile(
    r"^(?P<num>\d{1,3}|[一二三四五六七八九十百]+)"
    r"\s*[.、．)）]\s*(?P<rest>.*)$"
)

# 教材中的小节式题号：1.1 / 1.2) / 2.3.1 等。
DECIMAL_QUESTION_NUMBER = re.compile(
    r"^(?P<num>\d{1,3}(?:\s*[.．]\s*\d{1,3})+)"
    r"\s*[、.)）．]?\s*(?P<rest>.*)$"
)

# 例如：P50例1 1.1 设……
PAGE_EXAMPLE_SPACED_DECIMAL = re.compile(
    r"^(?:P\s*\d{1,4}\s*)?"
    r"例\s*\d{1,3}\s+"
    r"(?P<num>\d{1,3}(?:\s*[.．]\s*\d{1,3})+)"
    r"\s*[、.)）．]?\s*(?P<rest>.*)$",
    re.IGNORECASE,
)

# 例如：P51例1.2) …… / 例1.3……
PAGE_EXAMPLE_DECIMAL = re.compile(
    r"^(?:P\s*\d{1,4}\s*)?"
    r"例\s*"
    r"(?P<num>\d{1,3}(?:\s*[.．]\s*\d{1,3})+)"
    r"\s*[、.)）．]?\s*(?P<rest>.*)$",
    re.IGNORECASE,
)

# 第1题 / 第一题
QUESTION_LABEL = re.compile(
    r"^第\s*(?P<num>\d{1,3}|[一二三四五六七八九十百]+)"
    r"\s*题\s*[.、．):：]?\s*(?P<rest>.*)$"
)

# 例1. 求极限
EXAMPLE_NUMBER = re.compile(
    r"^例\s*(?P<num>\d{1,3})"
    r"\s*[.、．):：]?\s*(?P<rest>.*)$"
)

# 明显的教材页眉/页脚，不应进入题干。
HEADER_NOISE = (
    re.compile(r"^第\s*\d+\s*页(?:\s*共\s*\d+\s*页)?.*$"),
    re.compile(r"^共\s*\d+\s*页.*$"),
    re.compile(r"^\d+\s*讲(?:\s+\d+\s*[.．、])?.*$"),
    re.compile(r"^第\s*(?:\d+|[一二三四五六七八九十百]+)\s*讲.*$"),
    re.compile(r"^(?:高数|数学|微积分)\s*部分\s*$"),
)

OPTION_KEY = re.compile(r"^(?P<key>[A-H])\s*[.、．)]\s*(?P<text>.*)$")
FILL_BLANK = re.compile(r"[（(]\s*[）)]|_{2,}")

SHORT_ANSWER_VERB = re.compile(
    r"^(证明|求|计算|化简|解|说明|判断|比较|画出|指出|写出|"
    r"因式分解|已知|设|若|当|给定|讨论|验证)"
)
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
    label: str
    lines: list[tuple[int, OcrLine]]
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
        self._layout_debug = LayoutDebugSession.from_environment()

        # OCR may return formula fragments before the first visible question
        # number. Buffer them instead of immediately turning them into a fake
        # numbered-less question. Once a real question number is seen, these
        # fragments are treated as page/header/formula noise.
        self._preamble: list[tuple[int, OcrLine]] = []
        self._saw_numbered_question = False

    def feed(self, page_number: int, lines: list[OcrLine]) -> None:
        """Feed one page's OCR output; page_number is 1-based."""
        ordered = self._order_page_lines(lines)
        if self._layout_debug is not None:
            self._layout_debug.capture_page(page_number, lines, ordered)
        for line in ordered:
            self._feed_line(page_number, line)

    @classmethod
    def _order_page_lines(cls, lines: list[OcrLine]) -> list[OcrLine]:
        """Order one page by question-anchor regions, then visual position.

        OCR engines often emit a tall formula block before the label row that
        it overlaps.  Streaming that sequence directly lets content from the
        next question leak into the previous draft.  Anchor regions are built
        from all labels on the page before any line is fed to the stateful
        parser, so an overlapping block is assigned to the lower region first.
        """
        indexed = list(enumerate(lines))
        anchors = [
            (index, line)
            for index, line in indexed
            if cls._match_question_start(line.text.strip()) is not None
        ]

        def visual_key(item: tuple[int, OcrLine]) -> tuple[float, float, int]:
            index, line = item
            x0, y0, _x1, y1 = line.bbox
            return ((y0 + y1) / 2.0, x0, index)

        if not anchors:
            return [line for _index, line in sorted(indexed, key=visual_key)]

        centers = [(line.bbox[1] + line.bbox[3]) / 2.0 for _index, line in indexed]
        if centers and max(centers) - min(centers) < 1.0:
            # Some text sources expose no useful geometry. Their sequence is
            # already the only available reading-order signal.
            return list(lines)

        anchors.sort(key=visual_key)
        anchor_indices = {index for index, _line in anchors}
        before_first: list[tuple[int, OcrLine]] = []
        regions: list[list[tuple[int, OcrLine]]] = [[] for _anchor in anchors]

        def clipped(
            item: tuple[int, OcrLine],
            lower: Optional[float] = None,
            upper: Optional[float] = None,
        ) -> tuple[int, OcrLine]:
            index, line = item
            x0, y0, x1, y1 = line.bbox
            if lower is not None:
                y0 = max(y0, lower)
            if upper is not None:
                y1 = min(y1, upper)
            return index, OcrLine(line.text, line.confidence, (x0, y0, x1, y1))

        for item in indexed:
            index, line = item
            if index in anchor_indices:
                continue
            _x0, y0, _x1, y1 = line.bbox
            height = max(1.0, y1 - y0)
            center_y = (y0 + y1) / 2.0
            region_index = -1
            for candidate, (_anchor_index, anchor) in enumerate(anchors):
                anchor_top = anchor.bbox[1]
                if center_y >= anchor_top:
                    region_index = candidate
                    continue
                overlap = max(0.0, y1 - anchor_top)
                if overlap / height >= 0.35:
                    region_index = candidate
                break
            if region_index < 0:
                before_first.append(clipped(item, upper=anchors[0][1].bbox[1]))
            else:
                lower = anchors[region_index][1].bbox[1]
                upper = (
                    anchors[region_index + 1][1].bbox[1]
                    if region_index + 1 < len(anchors)
                    else None
                )
                regions[region_index].append(clipped(item, lower=lower, upper=upper))

        ordered = sorted(before_first, key=visual_key)
        for anchor, region in zip(anchors, regions):
            ordered.append(anchor)
            ordered.extend(sorted(region, key=visual_key))
        return [line for _index, line in ordered]

    def finish(self) -> list[QuestionDraft]:
        """Close the open question and return ordered, review-flagged drafts."""

        # Preserve true unnumbered material only when the entire parse never
        # encountered a real question number. In numbered workbooks, OCR
        # fragments appearing before the first number are noise.
        if (
            not self._saw_numbered_question
            and self._open is None
            and self._preamble
        ):
            first_page, first_line = self._preamble[0]

            self._open = _OpenQuestion(
                number="",
                label="",
                lines=list(self._preamble),
                options={},
                page_start=first_page,
                page_end=self._preamble[-1][0],
            )

            for page_number, item in self._preamble:
                self._record_region(page_number, item.bbox)

        self._close_open()

        drafts = self._questions

        self._open = None
        self._questions = []
        self._next_position = 1
        self._preamble = []
        self._saw_numbered_question = False
        if self._layout_debug is not None:
            self._layout_debug.reset()

        return drafts

    def _feed_line(self, page_number: int, line: OcrLine) -> None:
        text = line.text.strip()
        if not text:
            return
        question_start = self._match_question_start(text)
        if question_start is not None:
            number, label, rest = question_start

            self._saw_numbered_question = True
            self._preamble.clear()

            self._close_open()

            body_lines = []
            if rest:
                body_lines.append((page_number, OcrLine(rest, line.confidence, line.bbox)))

            self._open = _OpenQuestion(
                number=number,
                label=label,
                lines=body_lines,
                options={},
                page_start=page_number,
                page_end=page_number,
            )
            self._record_region(page_number, line.bbox)
            return

        # 页眉、页脚、章节标题不能被追加到上一道题，也不能自己形成题目。
        if self._is_header_noise(text):
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
            # Do not immediately create a question from OCR fragments before
            # the first real question number. Formula layouts can easily yield
            # numerator/denominator fragments before the textual question line.
            self._preamble.append((page_number, line))
            return
        self._open.lines.append((page_number, line))
        self._open.page_end = page_number
        self._record_region(page_number, line.bbox)

    @staticmethod
    def _match_question_start(text: str) -> Optional[tuple[str, str, str]]:
        """Return (number, visible_label, body) for a question-start line."""

        # Order matters: "1.1" must be detected before the older "1." rule.
        patterns = (
            (PAGE_EXAMPLE_SPACED_DECIMAL, "example"),
            (PAGE_EXAMPLE_DECIMAL, "example"),
            (DECIMAL_QUESTION_NUMBER, "prefix"),
            (QUESTION_LABEL, "prefix"),
            (QUESTION_NUMBER, "prefix"),
            (EXAMPLE_NUMBER, "example"),
        )

        for pattern, label_kind in patterns:
            match = pattern.match(text)
            if match is None:
                continue

            number = re.sub(
                r"\s+",
                "",
                match.group("num").replace("．", "."),
            )
            rest = match.group("rest").strip()
            if label_kind == "example":
                label = f"例{number}"
            else:
                label = text[: match.start("rest")].strip()
            return number, label, rest

        return None

    @staticmethod
    def _is_header_noise(text: str) -> bool:
        """Recognize common workbook headers/footers that are not question text."""
        return any(pattern.match(text) is not None for pattern in HEADER_NOISE)

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
        page_lines: dict[int, list[OcrLine]] = {}
        for page_number, line in question.lines:
            page_lines.setdefault(page_number, []).append(line)
        debug_matches = (
            self._layout_debug is not None
            and self._layout_debug.matches(
                question.label,
                [line for _page_number, line in question.lines],
            )
        )
        reconstructed_pages: list[str] = []
        for page_number, lines in page_lines.items():
            trace: Optional[list[dict[str, object]]] = [] if debug_matches else None
            reconstructed = reconstruct_math_layout(lines, piecewise_trace=trace)
            if reconstructed:
                reconstructed_pages.append(reconstructed)
            if debug_matches and self._layout_debug is not None and trace is not None:
                region = question.page_regions.get(page_number)
                if region is not None:
                    self._layout_debug.emit_question(
                        page_number=page_number,
                        question_label=question.label,
                        region=region,
                        detector_lines=lines,
                        trace=trace,
                    )
        body = "\n".join(reconstructed_pages)
        text = f"{question.label} {body}".strip() if question.label else body
        text = normalize_math_text(text)
        type_name = self._classify(body, question.options)
        confidences = [
            line.confidence
            for _page_number, line in question.lines
            if line.text.strip()
        ]
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
