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
REQUIRED_CHINESE_MODEL_NAMES = (
    "PP-LCNet_x1_0_doc_ori",
    "UVDoc",
    "PP-LCNet_x1_0_textline_ori",
    "PP-OCRv6_medium_det",
    "PP-OCRv6_medium_rec",
)


def configure_model_home() -> None:
    """Point both the deployment contract and PaddleX's real cache at one directory."""
    model_home = str(MODEL_HOME)
    os.environ["OCR_MODEL_HOME"] = model_home
    os.environ["PADDLE_PDX_OCR_MODEL_HOME"] = model_home
    # PaddleX 3.7.2 reads this variable when paddlex.utils.cache is imported.
    os.environ["PADDLE_PDX_CACHE_HOME"] = model_home


def main() -> int:
    MODEL_HOME.mkdir(parents=True, exist_ok=True)
    configure_model_home()
    # Configure the cache before importing PaddleOCR: PaddleX resolves and
    # freezes PADDLE_PDX_CACHE_HOME during module import.
    import numpy as np  # noqa: PLC0415
    from paddleocr import PaddleOCR  # noqa: PLC0415

    engine = PaddleOCR(
        lang=LANGUAGE,
        use_textline_orientation=True,
        enable_mkldnn=False,
    )
    # PaddleOCR 3.x predict() is eager (it returns a list), and exercising it
    # also proves the downloaded models can be initialized by Paddle Inference.
    engine.predict(np.zeros((32, 128, 3), dtype=np.uint8))

    official_models = MODEL_HOME / "official_models"
    missing_models = [
        name
        for name in REQUIRED_CHINESE_MODEL_NAMES
        if not any(path.is_file() for path in (official_models / name).rglob("*"))
    ]
    if missing_models:
        raise RuntimeError(
            "missing PaddleX model files under "
            f"{official_models}: {', '.join(missing_models)}"
        )
    print(
        f"paddleocr models initialized under {MODEL_HOME} "
        f"({len(REQUIRED_CHINESE_MODEL_NAMES)} model directories)",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
