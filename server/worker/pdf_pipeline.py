"""Bounded PDF → OCR → question-draft pipeline.

Production engines (PDFium renderer, PaddleOCR, Pillow cropping) are imported
lazily and injected through the constructor so the whole pipeline is testable
locally with fake engines and no heavy wheels. One page is rendered and OCR'd at
a time; the page bitmap is released before the next page is rendered. The long
edge is capped at ``max_long_edge`` and question images are cropped as JPEG
quality 88.

Classification (stable public codes, never internals):
- ``PDF_INVALID`` / ``PDF_ENCRYPTED`` / ``PAGE_RANGE_INVALID`` are permanent
  failures (``PipelineError``).
- ``OCR_FAILED`` is transient (``RetryablePipelineError``): the job may be
  retried automatically, at most twice.
- Low confidence, missing question text, unknown types and formula-heavy lines
  only flag ``review_required`` — they never fail the job.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from typing import Callable, Optional

from errors import PipelineError, RetryablePipelineError
from question_parser import OcrLine, QuestionDraft, QuestionParser

logger = logging.getLogger("wqc.worker.pipeline")

MAX_PAGES_PER_JOB = 20
DEFAULT_MAX_LONG_EDGE = 4096
JPEG_QUALITY = 88
OCR_LANGUAGE = os.environ.get("WQC_OCR_LANGUAGE", "ch")
OCR_MODEL_HOME = os.environ.get("OCR_MODEL_HOME", "/opt/ocr-models")


@dataclass
class RenderedPage:
    """One rendered page: pixel array plus metadata (engine-agnostic)."""

    width: int
    height: int
    pixels: object  # numpy array in production; opaque in tests
    scale: float = 1.0


@dataclass
class ProcessResult:
    questions: list[QuestionDraft] = field(default_factory=list)
    page_count: int = 0


class PdfDocumentError(Exception):
    """Renderer-level open failure; carries the stable public classification."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class Renderer:
    """Opens a PDF and renders pages (PDFium implementation below)."""

    def open(self, source_path: str) -> object:  # pragma: no cover - interface
        raise NotImplementedError

    def page_count(self, document: object) -> int:  # pragma: no cover - interface
        raise NotImplementedError

    def encrypted(self, document: object) -> bool:  # pragma: no cover - interface
        raise NotImplementedError

    def render(self, document: object, page_index: int, max_long_edge: int) -> RenderedPage:
        raise NotImplementedError  # pragma: no cover - interface

    def close(self, document: object) -> None:  # pragma: no cover - interface
        raise NotImplementedError


class PdfiumRenderer(Renderer):
    """PDFium-backed renderer; imports pypdfium2 lazily (server/container only)."""

    def open(self, source_path: str) -> object:
        import pypdfium2 as pdfium  # noqa: PLC0415

        try:
            return pdfium.PdfDocument(source_path)
        except Exception as exc:  # noqa: BLE001 - classify any open failure
            if "password" in str(exc).lower() or "encrypt" in str(exc).lower():
                raise PdfDocumentError("PDF_ENCRYPTED", "encrypted PDF is not supported") from exc
            raise PdfDocumentError("PDF_INVALID", "PDF could not be parsed") from exc

    def page_count(self, document: object) -> int:
        return len(document)  # type: ignore[arg-type]

    def encrypted(self, document: object) -> bool:
        return False  # PDFium refuses encrypted documents at open time

    def render(self, document: object, page_index: int, max_long_edge: int) -> RenderedPage:
        import pypdfium2 as pdfium  # noqa: PLC0415

        page = document[page_index]  # type: ignore[arg-type]
        width_pt, height_pt = page.get_size()
        scale = min(1.0, max_long_edge / max(width_pt, height_pt))
        bitmap = page.render(scale=scale)
        width, height = bitmap.width, bitmap.height
        pixels = bitmap.to_numpy()
        page.close()
        return RenderedPage(width=width, height=height, pixels=pixels, scale=scale)


class OcrEngine:
    """Recognizes one rendered page into OCR lines."""

    def recognize(self, page: RenderedPage) -> list[OcrLine]:  # pragma: no cover - interface
        raise NotImplementedError


class PaddleOcrEngine(OcrEngine):
    """PaddleOCR (Chinese) engine; imports paddleocr lazily (server/container only)."""

    def __init__(self, language: str = OCR_LANGUAGE) -> None:
        self._language = language
        self._engine = None

    def _ensure(self):
        if self._engine is None:
            # PaddleX 3.7.2 reads PADDLE_PDX_CACHE_HOME at import time. Keep its
            # actual cache rooted at the directory copied by the Docker model
            # stage; PADDLE_PDX_OCR_MODEL_HOME remains aligned with the existing
            # deployment contract even though PaddleX does not consume it.
            os.environ["OCR_MODEL_HOME"] = OCR_MODEL_HOME
            os.environ["PADDLE_PDX_OCR_MODEL_HOME"] = OCR_MODEL_HOME
            os.environ["PADDLE_PDX_CACHE_HOME"] = OCR_MODEL_HOME
            from paddleocr import PaddleOCR  # noqa: PLC0415

            self._engine = PaddleOCR(
                lang=self._language,
                use_textline_orientation=True,
                enable_mkldnn=False,
            )
        return self._engine

    def recognize(self, page: RenderedPage) -> list[OcrLine]:
        import numpy as np  # noqa: PLC0415

        results = self._ensure().predict(np.asarray(page.pixels))
        lines: list[OcrLine] = []
        for result in results or []:
            if result is None:
                continue
            try:
                texts = result["rec_texts"]
                scores = result["rec_scores"]
                boxes = result["rec_boxes"]
            except (KeyError, TypeError) as exc:
                raise ValueError("invalid PaddleOCR 3.x result object") from exc
            if not (len(texts) == len(scores) == len(boxes)):
                raise ValueError("inconsistent PaddleOCR 3.x result lengths")
            for text, score, box in zip(texts, scores, boxes):
                if len(box) != 4:
                    raise ValueError("invalid PaddleOCR 3.x rec_box")
                x0, y0, x1, y1 = (float(value) for value in box)
                lines.append(
                    OcrLine(
                        text=str(text),
                        confidence=float(score),
                        bbox=(x0, y0, x1, y1),
                    )
                )
        return lines


Cropper = Callable[[RenderedPage, tuple[float, float, float, float]], bytes]


def default_cropper(page: RenderedPage, bbox: tuple[float, float, float, float]) -> bytes:
    """Crop a question image from a rendered page and encode JPEG quality 88."""
    from io import BytesIO  # noqa: PLC0415

    import numpy as np  # noqa: PLC0415
    from PIL import Image  # noqa: PLC0415

    x0, y0, x1, y1 = bbox
    x0 = max(0, int(x0 * page.scale))
    y0 = max(0, int(y0 * page.scale))
    x1 = min(page.width, int(x1 * page.scale))
    y1 = min(page.height, int(y1 * page.scale))
    if x1 <= x0 or y1 <= y0:
        return b""
    image = Image.fromarray(np.asarray(page.pixels)[y0:y1, x0:x1])
    buffer = BytesIO()
    image.save(buffer, format="JPEG", quality=JPEG_QUALITY)
    return buffer.getvalue()


class PdfPipeline:
    """Processes one PDF file into ordered question drafts and image crops."""

    def __init__(
        self,
        renderer: Optional[Renderer] = None,
        ocr: Optional[OcrEngine] = None,
        cropper: Optional[Cropper] = None,
        parser_factory: Callable[[], QuestionParser] = QuestionParser,
    ) -> None:
        self._renderer = renderer or PdfiumRenderer()
        self._ocr = ocr or PaddleOcrEngine()
        self._cropper = cropper or default_cropper
        self._parser_factory = parser_factory

    def process_file(
        self,
        source_path: str,
        page_start: int = 1,
        page_end: Optional[int] = None,
        maximum_pages: int = MAX_PAGES_PER_JOB,
        progress_callback: Optional[Callable[[int, int], None]] = None,
    ) -> ProcessResult:
        """Validate the page range, OCR one page at a time, then crop images.

        Pass 1 renders and OCRs each page once, feeding the parser and releasing
        the bitmap before the next page; ``progress_callback(current, total)`` is
        invoked after every page so the worker can persist progress under its
        claimed_at token (a callback raising JobStoreError aborts processing).
        Pass 2 renders each page that carries a question region once and crops
        every region on it — so memory stays bounded to one page while
        cross-page questions still get accurate crops.
        """
        if not isinstance(page_start, int) or page_start < 1:
            raise PipelineError("PAGE_RANGE_INVALID", "page_start must be a positive integer")
        if page_end is not None and (not isinstance(page_end, int) or page_end < page_start):
            raise PipelineError("PAGE_RANGE_INVALID", "page_end must be >= page_start")

        try:
            document = self._renderer.open(source_path)
        except PdfDocumentError as exc:
            raise PipelineError(exc.code, exc.args[0] if exc.args else str(exc)) from exc
        try:
            if self._renderer.encrypted(document):
                raise PipelineError("PDF_ENCRYPTED", "encrypted PDF is not supported")
            total = self._renderer.page_count(document)
            last = page_end if page_end is not None else total
            if last > total:
                raise PipelineError("PAGE_RANGE_INVALID", "page range exceeds the document")
            if last - page_start + 1 > maximum_pages:
                raise PipelineError(
                    "PAGE_RANGE_INVALID", f"at most {maximum_pages} pages may be processed"
                )

            parser = self._parser_factory()
            page_total = last - page_start + 1
            for page_number in range(page_start, last + 1):
                page = self._renderer.render(document, page_number - 1, DEFAULT_MAX_LONG_EDGE)
                try:
                    lines = self._ocr.recognize(page)
                except Exception as exc:  # noqa: BLE001 - classify engine failures
                    raise RetryablePipelineError("OCR_FAILED", "OCR engine failed") from exc
                finally:
                    page.pixels = None  # release the bitmap before the next page
                parser.feed(page_number, lines)
                if progress_callback is not None:
                    progress_callback(page_number - page_start + 1, page_total)

            questions = parser.finish()
            self._crop_questions(document, questions)
            return ProcessResult(questions=questions, page_count=page_total)
        finally:
            self._renderer.close(document)

    def _crop_questions(self, document: object, questions: list[QuestionDraft]) -> None:
        """Render each needed page once and crop every question region on it."""
        targets_by_page: dict[int, list[tuple[QuestionDraft, tuple[float, float, float, float]]]] = {}
        for question in questions:
            for page_number, box in question.page_regions.items():
                targets_by_page.setdefault(page_number, []).append((question, box))
        for page_number, targets in targets_by_page.items():
            page = self._renderer.render(document, page_number - 1, DEFAULT_MAX_LONG_EDGE)
            try:
                for question, box in targets:
                    crop = self._cropper(page, box)
                    if not crop:
                        logger.warning(
                            "empty crop for question %s on page %s", question.id, page_number
                        )
                        question.review_required = True
                        continue
                    question.artifacts.append(
                        {
                            "type": "question_image",
                            "page": page_number,
                            "box": list(box),
                            "jpeg": crop,
                            "jpeg_quality": JPEG_QUALITY,
                        }
                    )
            finally:
                page.pixels = None  # release the bitmap after the page's crops
