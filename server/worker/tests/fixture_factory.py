"""Test-time PDF fixtures built with the standard library only.

Generates real, parseable PDF files (text pages, scanned-image pages, damaged
and encrypted markers) so the pipeline can be exercised against actual bytes in
container tests, while local unit tests keep using fake engines. No reference
PDFs or copyrighted workbook pages are ever committed.

Deliberate deviation from the plan's ReportLab/Pillow fixtures: this machine has
no PyPI access for those wheels, and a hand-built PDF is byte-deterministic and
dependency-free everywhere, including inside the worker image.

Object numbering: catalog=1, pages=2, then per page ``page=3+i*2`` +
``contents=4+i*2`` for text PDFs, or ``page=3+i*3`` + ``image=4+i*3`` +
``contents=5+i*3`` for scanned PDFs.
"""

from __future__ import annotations

import zlib
from pathlib import Path

PAGE_W = 595
PAGE_H = 842


def _escape_text(text: str) -> str:
    return text.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")


def _content_stream(lines: list[str]) -> bytes:
    """One page's text content: 12pt Helvetica, 24pt line pitch from y=780."""
    commands = ["BT", "/F1 12 Tf"]
    y = 780
    for line in lines:
        commands.append(f"1 0 0 1 72 {y} Tm ({_escape_text(line)}) Tj")
        y -= 24
    commands.append("ET")
    return ("\n".join(commands) + "\n").encode("latin-1")


def _image_stream(width: int, height: int) -> bytes:
    """A simple deterministic RGB gradient, FlateDecode-compressed."""
    pixels = bytearray()
    for row in range(height):
        for column in range(width):
            pixels.append((column * 255) // max(width - 1, 1))
            pixels.append((row * 255) // max(height - 1, 1))
            pixels.append(128)
    return zlib.compress(bytes(pixels))


def _write_pdf(path: Path, objects: list[bytes]) -> None:
    """Assemble a minimal valid PDF with correct xref offsets."""
    header = b"%PDF-1.4\n"
    body = bytearray(header)
    offsets = [len(header)]
    for index, obj in enumerate(objects, start=1):
        body.extend(f"{index} 0 obj\n".encode("latin-1"))
        body.extend(obj)
        body.extend(b"\nendobj\n")
        offsets.append(len(body))
    xref_position = len(body)
    body.extend(f"xref\n0 {len(objects) + 1}\n".encode("latin-1"))
    body.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        body.extend(f"{offset:010d} 00000 n \n".encode("latin-1"))
    body.extend(
        (
            f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
            f"startxref\n{xref_position}\n%%EOF\n"
        ).encode("latin-1")
    )
    path.write_bytes(bytes(body))


def build_text_pdf(path: Path, pages: list[str]) -> Path:
    """A text PDF with one page per entry; page text is ASCII-safe."""
    objects: list[bytes] = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        f"<< /Type /Pages /Kids [{_kids(len(pages), 2)}] /Count {len(pages)} >>".encode("latin-1"),
    ]
    for index, text in enumerate(pages):
        page_number = 3 + index * 2
        stream = _content_stream([text])
        objects.append(
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W} {PAGE_H}] "
            f"/Resources << /Font << /F1 4 0 R >> >> /Contents {page_number + 1} 0 R >>".encode("latin-1")
        )
        objects.append(
            f"<< /Length {len(stream)} >>\nstream\n".encode("latin-1") + stream + b"endstream"
        )
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    _write_pdf(path, objects)
    return path


def build_scanned_pdf(path: Path, pages: list[str]) -> Path:
    """A PDF whose pages are embedded raster images (scanned look)."""
    width, height = 100, 140
    image = _image_stream(width, height)
    objects: list[bytes] = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        f"<< /Type /Pages /Kids [{_kids(len(pages), 3)}] /Count {len(pages)} >>".encode("latin-1"),
    ]
    for index, _text in enumerate(pages):
        page_number = 3 + index * 3
        objects.append(
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W} {PAGE_H}] "
            f"/Resources << /XObject << /Im0 {page_number + 1} 0 R >> >> "
            f"/Contents {page_number + 2} 0 R >>".encode("latin-1")
        )
        objects.append(
            f"<< /Type /XObject /Subtype /Image /Width {width} /Height {height} "
            f"/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode "
            f"/Length {len(image)} >>\nstream\n".encode("latin-1") + image + b"endstream"
        )
        stream = f"q {PAGE_W} 0 0 {PAGE_H} 0 0 cm /Im0 Do Q\n".encode("latin-1")
        objects.append(
            f"<< /Length {len(stream)} >>\nstream\n".encode("latin-1") + stream + b"endstream"
        )
    _write_pdf(path, objects)
    return path


def build_damaged_pdf(path: Path) -> Path:
    """A truncated/garbage file that must classify as PDF_INVALID."""
    path.write_bytes(b"%PDF-1.7\nthis is not a parseable pdf at all")
    return path


def build_encrypted_pdf(path: Path) -> Path:
    """A PDF carrying a standard encryption dictionary (pdfium refuses to open)."""
    objects: list[bytes] = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>",
        b"<< /Filter /Standard /V 1 /R 2 /O <00000000000000000000000000000000> "
        b"/U <00000000000000000000000000000000> /P -4 /EncryptMetadata false >>",
    ]
    _write_pdf(path, objects)
    return path


def _kids(page_count: int, objects_per_page: int) -> str:
    return ", ".join(f"{3 + index * objects_per_page} 0 R" for index in range(page_count))
