"""Fixture PDF validity checks (standard library) plus a container-only
integration test that exercises the real PDFium renderer against the fixtures.
The integration test skips locally where pypdfium2 is not installed.

Temporary files live under ``.pytest-tmp/`` inside the repo (git-ignored) so the
suite works in sandboxed environments where %TEMP% is not writable."""

from __future__ import annotations

import zlib
from pathlib import Path

import pytest

from tests.fixture_factory import (
    build_damaged_pdf,
    build_encrypted_pdf,
    build_scanned_pdf,
    build_text_pdf,
)

try:
    import pypdfium2  # noqa: F401

    HAS_PDFIUM = True
except ImportError:  # pragma: no cover - local machines without the wheel
    HAS_PDFIUM = False


@pytest.fixture
def scratch() -> Path:
    root = Path(__file__).resolve().parent.parent / ".pytest-tmp"
    root.mkdir(parents=True, exist_ok=True)
    return root


def test_text_pdf_is_a_well_formed_file(scratch: Path):
    path = build_text_pdf(scratch / "text.pdf", ["1. Find the limit", "2. Compute"])

    raw = path.read_bytes()
    assert raw.startswith(b"%PDF-1.4")
    assert b"xref" in raw
    assert b"startxref" in raw
    assert b"%%EOF" in raw
    assert raw.count(b"endobj") == 7  # catalog, pages, 2x page, 2x contents, font


def test_scanned_pdf_embeds_a_decompressible_image(scratch: Path):
    path = build_scanned_pdf(scratch / "scanned.pdf", ["1. 求函数的极限"])

    raw = path.read_bytes()
    assert raw.startswith(b"%PDF-1.4")
    # The first stream payload (the image) must round-trip through zlib.
    payload = raw.split(b"endstream")[0].split(b"stream\n")[-1]
    pixels = zlib.decompress(payload)
    assert len(pixels) == 100 * 140 * 3  # width * height * RGB


def test_damaged_and_encrypted_fixtures_are_distinguishable(scratch: Path):
    damaged = build_damaged_pdf(scratch / "damaged.pdf")
    encrypted = build_encrypted_pdf(scratch / "encrypted.pdf")

    assert damaged.read_bytes().startswith(b"%PDF-1.7")
    assert b"/Encrypt" in encrypted.read_bytes()


@pytest.mark.skipif(not HAS_PDFIUM, reason="pypdfium2 not installed (container test)")
def test_pdfium_renders_the_text_fixture(scratch: Path):  # pragma: no cover
    """Executed in the container test step; skipped on machines without pdfium."""
    import pypdfium2 as pdfium  # noqa: PLC0415

    from pdf_pipeline import PdfiumRenderer

    path = build_text_pdf(scratch / "text.pdf", ["1. Find the limit", "2. Compute"])
    renderer = PdfiumRenderer()
    document = renderer.open(str(path))
    try:
        assert renderer.page_count(document) == 2
        page = renderer.render(document, 0, 4096)
        assert page.width > 0 and page.height > 0
    finally:
        renderer.close(document)


@pytest.mark.skipif(not HAS_PDFIUM, reason="pypdfium2 not installed (container test)")
def test_pdfium_classifies_damaged_and_encrypted_fixtures(scratch: Path):  # pragma: no cover
    """Executed in the container test step; skipped on machines without pdfium."""
    from pdf_pipeline import PdfDocumentError, PdfiumRenderer

    renderer = PdfiumRenderer()
    with pytest.raises(PdfDocumentError) as error:
        renderer.open(str(build_damaged_pdf(scratch / "damaged.pdf")))
    assert error.value.code == "PDF_INVALID"
    with pytest.raises(PdfDocumentError) as error:
        renderer.open(str(build_encrypted_pdf(scratch / "encrypted.pdf")))
    assert error.value.code == "PDF_ENCRYPTED"
