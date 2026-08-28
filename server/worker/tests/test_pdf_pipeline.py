"""PdfPipeline behavior with fake engines: page bounds, classification, crops."""

from __future__ import annotations

import pytest

from main import PipelineError, RetryablePipelineError
from pdf_pipeline import DEFAULT_MAX_LONG_EDGE, PdfPipeline
from question_parser import OcrLine
from tests.fake_engines import FakeCropper, FakeOcr, FakeRenderer


def make_pipeline(renderer=None, ocr=None, cropper=None):
    return PdfPipeline(
        renderer=renderer or FakeRenderer(),
        ocr=ocr or FakeOcr(),
        cropper=cropper or FakeCropper(),
    )


def ocr_lines(texts: list[str], page: int = 1):
    return [
        OcrLine(text, 0.95, (10.0 + offset, 10.0 + offset, 200.0 + offset, 30.0 + offset))
        for offset, text in enumerate(texts)
    ]


def test_processes_two_pages_into_two_questions_with_crops():
    renderer = FakeRenderer(page_count=2)
    ocr = FakeOcr([
        [OcrLine("1. 求极限", 0.95, (10.0, 10.0, 200.0, 30.0))],
        [OcrLine("2. 计算积分", 0.95, (10.0, 10.0, 200.0, 30.0))],
    ])
    cropper = FakeCropper()
    result = make_pipeline(renderer, ocr, cropper).process_file("fixture.pdf")

    assert result.page_count == 2
    assert [question.position for question in result.questions] == [1, 2]
    # Pass 1 renders both pages for OCR; pass 2 re-renders each page for crops.
    assert renderer.render_calls == [
        (0, DEFAULT_MAX_LONG_EDGE),
        (1, DEFAULT_MAX_LONG_EDGE),
        (0, DEFAULT_MAX_LONG_EDGE),
        (1, DEFAULT_MAX_LONG_EDGE),
    ]
    assert renderer.close_calls == 1
    assert ocr.calls == 2
    # Each question carries a question_image artifact with the JPEG payload.
    assert all(question.artifacts for question in result.questions)
    assert result.questions[0].artifacts[0]["jpeg"] == b"jpeg-bytes"
    assert result.questions[0].artifacts[0]["jpeg_quality"] == 88


def test_bitmaps_are_released_before_the_next_page_is_rendered():
    renderer = FakeRenderer(page_count=2)
    ocr = FakeOcr([ocr_lines(["1. 题干"]), ocr_lines(["2. 题干"])])

    make_pipeline(renderer, ocr).process_file("fixture.pdf")

    assert len(renderer.pages) == 4  # two OCR pages + two crop pages
    assert all(page.pixels is None for page in renderer.pages)


def test_crops_are_scaled_from_page_regions():
    renderer = FakeRenderer(page_count=1)
    ocr = FakeOcr([[OcrLine("1. 题干", 0.95, (20.0, 30.0, 120.0, 60.0))]])
    cropper = FakeCropper()

    make_pipeline(renderer, ocr, cropper).process_file("fixture.pdf")

    assert cropper.calls == [(renderer.pages[0], (20.0, 30.0, 120.0, 60.0))]


def test_cross_page_question_crops_both_pages():
    renderer = FakeRenderer(page_count=2)
    ocr = FakeOcr([
        [OcrLine("1. 题干", 0.95, (10.0, 10.0, 200.0, 30.0))],
        [OcrLine("续行", 0.95, (15.0, 12.0, 90.0, 28.0))],
    ])
    cropper = FakeCropper()

    result = make_pipeline(renderer, ocr, cropper).process_file("fixture.pdf")

    assert len(result.questions) == 1
    assert len(result.questions[0].artifacts) == 2
    assert result.questions[0].artifacts[0]["page"] == 1
    assert result.questions[0].artifacts[1]["page"] == 2
    # Second pass renders page 0 and page 1 once each for cropping.
    assert renderer.render_calls == [
        (0, DEFAULT_MAX_LONG_EDGE),
        (1, DEFAULT_MAX_LONG_EDGE),
        (0, DEFAULT_MAX_LONG_EDGE),
        (1, DEFAULT_MAX_LONG_EDGE),
    ]


def test_empty_crop_flags_the_question_for_review():
    ocr = FakeOcr([[OcrLine("1. 题干", 0.95, (10.0, 10.0, 200.0, 30.0))]])
    cropper = FakeCropper(empty=True)

    result = make_pipeline(ocr=ocr, cropper=cropper).process_file("fixture.pdf")

    assert result.questions[0].artifacts == []
    assert result.questions[0].review_required is True


def test_damaged_pdf_is_classified_permanently():
    renderer = FakeRenderer(fail_open=True)

    with pytest.raises(PipelineError) as error:
        make_pipeline(renderer=renderer).process_file("damaged.pdf")

    assert error.value.code == "PDF_INVALID"
    assert not isinstance(error.value, RetryablePipelineError)


def test_encrypted_pdf_is_classified_permanently():
    renderer = FakeRenderer(encrypted=True)

    with pytest.raises(PipelineError) as error:
        make_pipeline(renderer=renderer).process_file("encrypted.pdf")

    assert error.value.code == "PDF_ENCRYPTED"


def test_page_range_validation():
    renderer = FakeRenderer(page_count=2)

    with pytest.raises(PipelineError) as error:
        make_pipeline(renderer=renderer).process_file("fixture.pdf", page_start=0)
    assert error.value.code == "PAGE_RANGE_INVALID"

    with pytest.raises(PipelineError) as error:
        make_pipeline(renderer=renderer).process_file("fixture.pdf", page_start=2, page_end=1)
    assert error.value.code == "PAGE_RANGE_INVALID"

    with pytest.raises(PipelineError) as error:
        make_pipeline(renderer=renderer).process_file("fixture.pdf", page_start=1, page_end=3)
    assert error.value.code == "PAGE_RANGE_INVALID"


def test_page_count_limit_is_enforced():
    renderer = FakeRenderer(page_count=30)

    with pytest.raises(PipelineError) as error:
        make_pipeline(renderer=renderer).process_file("fixture.pdf", page_start=1, page_end=21)
    assert error.value.code == "PAGE_RANGE_INVALID"


def test_ocr_engine_failure_is_retryable():
    ocr = FakeOcr(fail=True)

    with pytest.raises(RetryablePipelineError) as error:
        make_pipeline(ocr=ocr).process_file("fixture.pdf")

    assert error.value.code == "OCR_FAILED"


def test_low_confidence_does_not_fail_the_job():
    ocr = FakeOcr([[OcrLine("1. 模糊题干", 0.5, (10.0, 10.0, 200.0, 30.0))]])

    result = make_pipeline(renderer=FakeRenderer(page_count=1), ocr=ocr).process_file("fixture.pdf")

    assert len(result.questions) == 1
    assert result.questions[0].review_required is True


def test_renderer_is_closed_even_on_ocr_failure():
    renderer = FakeRenderer()
    ocr = FakeOcr(fail=True)

    with pytest.raises(RetryablePipelineError):
        make_pipeline(renderer, ocr).process_file("fixture.pdf")

    assert renderer.close_calls == 1
