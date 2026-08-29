"""Download/verify the Chinese PaddleOCR models into a model home directory.

Runs only in the Docker build stage (network available, no runtime traffic).
The runtime image copies the populated directory and points PaddleOCR at it, so
the worker never needs outbound network access in production.

The OCR engine version must match the pinned paddleocr wheel in requirements.txt;
upgrading the wheel requires rebuilding this stage and re-verifying the model set.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

MODEL_HOME = Path(os.environ.get("OCR_MODEL_HOME", "/opt/ocr-models"))
LANGUAGE = os.environ.get("WQC_OCR_LANGUAGE", "ch")


def main() -> int:
    MODEL_HOME.mkdir(parents=True, exist_ok=True)
    # PaddleOCR 3.x resolves its model cache through PADDLE_PDX_OCR_MODEL_HOME;
    # point it at the stage-local model home so the runtime image can copy it.
    os.environ["PADDLE_PDX_OCR_MODEL_HOME"] = str(MODEL_HOME)
    # Importing and instantiating PaddleOCR downloads/initializes the language
    # models into its model home; a first OCR call forces eager initialization.
    from paddleocr import PaddleOCR  # noqa: PLC0415

    engine = PaddleOCR(lang=LANGUAGE, use_angle_cls=True)
    # Force any lazy model materialization before the build stage ends.
    engine.ocr([[0, 0, 1, 1]], cls=True)
    print(f"paddleocr models initialized under {MODEL_HOME}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
