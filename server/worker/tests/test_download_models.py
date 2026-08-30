"""PaddleOCR 3.x build-stage model materialization tests."""

from __future__ import annotations

import os
import sys
from types import SimpleNamespace

import pytest

import download_models


def test_download_models_uses_predict_and_materializes_configured_cache(monkeypatch, tmp_path):
    calls = {}
    model_home = tmp_path / "ocr-models"
    for name in ("OCR_MODEL_HOME", "PADDLE_PDX_OCR_MODEL_HOME", "PADDLE_PDX_CACHE_HOME"):
        monkeypatch.setenv(name, "before-test")

    class FakePaddleOCR:
        def __init__(self, **kwargs):
            calls["init"] = kwargs
            cache_home = os.environ["PADDLE_PDX_CACHE_HOME"]
            assert cache_home == str(model_home)
            for model_name in download_models.REQUIRED_CHINESE_MODEL_NAMES:
                model_file = model_home / "official_models" / model_name / "inference.json"
                model_file.parent.mkdir(parents=True)
                model_file.write_text("{}", encoding="utf-8")

        def predict(self, image):
            calls["predict_shape"] = image.shape
            return [{"rec_texts": [], "rec_scores": [], "rec_boxes": []}]

    monkeypatch.setattr(download_models, "MODEL_HOME", model_home)
    monkeypatch.setitem(sys.modules, "paddleocr", SimpleNamespace(PaddleOCR=FakePaddleOCR))

    assert download_models.main() == 0
    assert calls["init"] == {"lang": "ch", "use_textline_orientation": True}
    assert calls["predict_shape"] == (32, 128, 3)
    assert os.environ["OCR_MODEL_HOME"] == str(model_home)
    assert os.environ["PADDLE_PDX_OCR_MODEL_HOME"] == str(model_home)
    assert os.environ["PADDLE_PDX_CACHE_HOME"] == str(model_home)


def test_download_models_rejects_an_empty_model_cache(monkeypatch, tmp_path):
    for name in ("OCR_MODEL_HOME", "PADDLE_PDX_OCR_MODEL_HOME", "PADDLE_PDX_CACHE_HOME"):
        monkeypatch.setenv(name, "before-test")

    class FakePaddleOCR:
        def __init__(self, **kwargs):
            pass

        def predict(self, image):
            return []

    monkeypatch.setattr(download_models, "MODEL_HOME", tmp_path / "ocr-models")
    monkeypatch.setitem(sys.modules, "paddleocr", SimpleNamespace(PaddleOCR=FakePaddleOCR))

    with pytest.raises(RuntimeError, match="missing PaddleX model files"):
        download_models.main()
