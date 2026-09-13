"""Quality gate for embedded PDF text before choosing visual OCR."""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Protocol, Sequence


class TextLine(Protocol):
    text: str


@dataclass(frozen=True)
class TextLayerQuality:
    reliable: bool
    score: float
    reason: str


_SUSPICIOUS_MATH = re.compile(
    r"(?<![A-Za-z0-9])x[234](?=$|[^A-Za-z0-9])"
    r"|√(?!\s*[（(])"
    r"|(?<![A-Za-z0-9])x\{\d+\}"
    r"|[A-Za-z]\s*[−-]\s*1\s*\("
)


def assess_text_layer(lines: Sequence[TextLine]) -> TextLayerQuality:
    """Classify embedded text without logging or returning its contents."""
    text = "\n".join(line.text for line in lines)
    visible = [character for character in text if not character.isspace()]
    if len(visible) < 8:
        return TextLayerQuality(False, 0.0, "too_short")

    suspicious = 0
    signal = 0
    mojibake_markers = sum(text.count(marker) for marker in ("Ã", "Â", "â", "ð"))
    for character in visible:
        category = unicodedata.category(character)
        if character == "�" or category in {"Cc", "Cs", "Co", "Cn"}:
            suspicious += 1
            continue
        if category[0] in {"L", "N", "P", "S"}:
            signal += 1

    suspicious_ratio = suspicious / len(visible)
    signal_ratio = signal / len(visible)
    score = max(0.0, min(1.0, signal_ratio * (1.0 - suspicious_ratio)))
    if mojibake_markers / len(visible) > 0.05:
        return TextLayerQuality(False, score, "mojibake_markers")
    if _SUSPICIOUS_MATH.search(text) is not None:
        return TextLayerQuality(False, score, "flattened_math_structure")
    if suspicious_ratio > 0.05:
        return TextLayerQuality(False, score, "suspicious_characters")
    if signal_ratio < 0.60:
        return TextLayerQuality(False, score, "low_language_signal")
    return TextLayerQuality(True, score, "reliable")
