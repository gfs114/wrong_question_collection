"""Fake renderer/OCR/cropper engines for local pipeline tests."""

from __future__ import annotations

from pdf_pipeline import PdfDocumentError, RenderedPage


class FakeRenderer:
    """In-memory document with recorded render/close calls and released pages."""

    def __init__(self, page_count: int = 2, fail_open: bool = False, encrypted: bool = False):
        self.page_count_value = page_count
        self.fail_open = fail_open
        self.encrypted_value = encrypted
        self.open_calls: list[str] = []
        self.render_calls: list[tuple[int, int]] = []  # (page_index, max_long_edge)
        self.close_calls = 0
        self.pages: list[RenderedPage] = []

    def open(self, source_path: str) -> object:
        self.open_calls.append(source_path)
        if self.fail_open:
            raise PdfDocumentError("PDF_INVALID", "simulated open failure")
        return {"path": source_path}

    def page_count(self, document: object) -> int:
        return self.page_count_value

    def encrypted(self, document: object) -> bool:
        return self.encrypted_value

    def render(self, document: object, page_index: int, max_long_edge: int) -> RenderedPage:
        self.render_calls.append((page_index, max_long_edge))
        page = RenderedPage(width=100, height=200, pixels=object(), scale=1.0)
        self.pages.append(page)
        return page

    def close(self, document: object) -> None:
        self.close_calls += 1


class FakeOcr:
    """Returns one canned line list per recognize() call, in page order."""

    def __init__(self, pages_lines=None, fail: bool = False):
        self.pages_lines = pages_lines or []
        self.fail = fail
        self.calls = 0

    def recognize(self, page: RenderedPage) -> list:
        self.calls += 1
        if self.fail:
            raise RuntimeError("simulated OCR engine crash")
        index = min(self.calls - 1, len(self.pages_lines) - 1)
        return list(self.pages_lines[index]) if self.pages_lines else []


class FakeCropper:
    """Records crop requests and returns a canned JPEG payload."""

    def __init__(self, payload: bytes = b"jpeg-bytes", empty: bool = False):
        self.payload = payload
        self.empty = empty
        self.calls: list[tuple[RenderedPage, tuple[float, float, float, float]]] = []

    def __call__(self, page: RenderedPage, bbox: tuple[float, float, float, float]) -> bytes:
        self.calls.append((page, bbox))
        return b"" if self.empty else self.payload
