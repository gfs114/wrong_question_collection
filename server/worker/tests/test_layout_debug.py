"""Opt-in OCR layout diagnostics must be observable and side-effect free."""

from __future__ import annotations

import json
import logging

import pytest

from question_parser import OcrLine, QuestionParser


DEBUG_ENV = (
    "WQC_OCR_LAYOUT_DEBUG",
    "WQC_OCR_LAYOUT_DEBUG_MATCH",
    "WQC_OCR_LAYOUT_DEBUG_JSON",
)


@pytest.fixture(autouse=True)
def clear_debug_environment(monkeypatch):
    for name in DEBUG_ENV:
        monkeypatch.delenv(name, raising=False)


def parse(lines: list[OcrLine]) -> list:
    parser = QuestionParser()
    parser.feed(1, lines)
    return parser.finish()


def rejected_piecewise_lines(extra_text: str | None = None) -> list[OcrLine]:
    lines = [
        OcrLine("例1.5 设 g(x)=", 0.95, (10.0, 10.0, 120.0, 30.0)),
        OcrLine("∫2−x,x≤0,", 0.91, (125.0, 34.0, 245.0, 88.0)),
        OcrLine("f(x)", 0.88, (150.0, 62.0, 200.0, 78.0)),
    ]
    if extra_text is not None:
        lines.append(OcrLine(extra_text, 0.80, (10.0, 92.0, 280.0, 112.0)))
    return lines


def debug_events(caplog) -> list[dict]:
    prefix = "ocr_layout_debug "
    return [
        json.loads(record.message[len(prefix):])
        for record in caplog.records
        if record.name == "wqc.worker.layout" and record.message.startswith(prefix)
    ]


def test_debug_disabled_emits_no_diagnostics_and_preserves_question(caplog):
    caplog.set_level(logging.INFO, logger="wqc.worker.layout")

    baseline = parse(rejected_piecewise_lines())[0].question

    assert baseline
    assert debug_events(caplog) == []


def test_debug_enabled_logs_raw_and_detector_block_geometry(monkeypatch, caplog):
    monkeypatch.setenv("WQC_OCR_LAYOUT_DEBUG", "1")
    caplog.set_level(logging.INFO, logger="wqc.worker.layout")

    parse(rejected_piecewise_lines())

    events = debug_events(caplog)
    raw = next(event for event in events if event["stage"] == "raw_block" and "∫" in event["text"])
    detector = next(
        event for event in events
        if event["stage"] == "detector_block" and "∫" in event["text"]
    )
    assert raw["page"] == 1
    assert raw["questionLabel"] == "例1.5"
    assert raw["originalOrder"] == 1
    assert raw["bbox"] == [125.0, 34.0, 245.0, 88.0]
    assert raw["x1"] == 125.0 and raw["y1"] == 34.0
    assert raw["x2"] == 245.0 and raw["y2"] == 88.0
    assert raw["width"] == 120.0 and raw["height"] == 54.0
    assert raw["centerX"] == 185.0 and raw["centerY"] == 61.0
    assert detector["blockIndex"] >= 0
    assert detector["sortedOrder"] >= 0
    assert detector["confidence"] == pytest.approx(0.91)


def test_debug_match_only_emits_the_selected_question(monkeypatch, caplog):
    monkeypatch.setenv("WQC_OCR_LAYOUT_DEBUG", "1")
    monkeypatch.setenv("WQC_OCR_LAYOUT_DEBUG_MATCH", "例1.5")
    caplog.set_level(logging.INFO, logger="wqc.worker.layout")
    parser = QuestionParser()
    parser.feed(1, [
        OcrLine("例1.4 求 φ(x)", 0.95, (10.0, 10.0, 180.0, 30.0)),
        OcrLine("例1.5 设 g(x)=", 0.95, (10.0, 100.0, 180.0, 120.0)),
        OcrLine("∫2−x,x≤0,", 0.91, (125.0, 124.0, 245.0, 178.0)),
        OcrLine("f(x)", 0.88, (150.0, 152.0, 200.0, 168.0)),
    ])
    parser.finish()

    events = debug_events(caplog)
    assert events
    assert {event["questionLabel"] for event in events} == {"例1.5"}


def test_rejected_piecewise_candidate_logs_explicit_reason(monkeypatch, caplog):
    monkeypatch.setenv("WQC_OCR_LAYOUT_DEBUG", "1")
    caplog.set_level(logging.INFO, logger="wqc.worker.layout")

    parse(rejected_piecewise_lines())

    candidates = [event for event in debug_events(caplog) if event["stage"] == "piecewise_candidate"]
    brace = next(event for event in candidates if event["braceLike"])
    assert brace["candidateDetected"] is True
    assert brace["braceToken"] == "∫"
    assert brace["estimatedLineHeight"] > 0
    assert brace["heightRatio"] > 0
    assert brace["rowsDetected"] >= 1
    assert brace["conditionRows"] == 1
    assert brace["accepted"] is False
    assert brace["rejectReason"] in {
        "no_multirow_structure",
        "insufficient_condition_rows",
        "row_cluster_collapsed",
        "payload_not_split",
        "no_right_side_rows",
    }


def test_json_path_unset_writes_no_file(monkeypatch, tmp_path):
    monkeypatch.setenv("WQC_OCR_LAYOUT_DEBUG", "1")
    monkeypatch.chdir(tmp_path)

    parse(rejected_piecewise_lines())

    assert list(tmp_path.iterdir()) == []


def test_json_path_writes_valid_layout_report(monkeypatch, tmp_path):
    output = tmp_path / "ocr-layout-debug.json"
    monkeypatch.setenv("WQC_OCR_LAYOUT_DEBUG", "1")
    monkeypatch.setenv("WQC_OCR_LAYOUT_DEBUG_JSON", str(output))

    parse(rejected_piecewise_lines())

    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["version"] == 1
    assert len(report["questions"]) == 1
    question = report["questions"][0]
    assert question["questionLabel"] == "例1.5"
    assert question["rawBlocks"]
    assert question["blocks"]
    assert question["piecewiseCandidates"]
    assert isinstance(question["clusters"], list)


def test_debug_redacts_sensitive_names_and_values(monkeypatch, caplog, tmp_path):
    output = tmp_path / "safe.json"
    monkeypatch.setenv("WQC_OCR_LAYOUT_DEBUG", "1")
    monkeypatch.setenv("WQC_OCR_LAYOUT_DEBUG_JSON", str(output))
    caplog.set_level(logging.INFO, logger="wqc.worker.layout")
    sensitive = (
        "accessToken=alpha refreshToken=beta Authorization=Bearer-gamma "
        "Cookie=delta apiSecret=epsilon password=zeta"
    )

    parse(rejected_piecewise_lines(sensitive))

    captured = "\n".join(record.message for record in caplog.records)
    captured += output.read_text(encoding="utf-8")
    lowered = captured.lower()
    for forbidden in (
        "accesstoken",
        "refreshtoken",
        "authorization",
        "cookie",
        "apisecret",
        "password",
        "alpha",
        "beta",
        "gamma",
        "delta",
        "epsilon",
        "zeta",
    ):
        assert forbidden not in lowered


def test_debug_mode_does_not_change_parser_output(monkeypatch):
    baseline = parse(rejected_piecewise_lines())[0].question
    monkeypatch.setenv("WQC_OCR_LAYOUT_DEBUG", "1")

    diagnosed = parse(rejected_piecewise_lines())[0].question

    assert diagnosed == baseline
