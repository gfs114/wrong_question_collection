"""QuestionParser splitting/classification policy tests (pure logic)."""

from __future__ import annotations

from question_parser import OcrLine, QuestionParser


def line(text: str, confidence: float = 0.95, bbox=(0.0, 0.0, 100.0, 20.0)) -> OcrLine:
    return OcrLine(text=text, confidence=confidence, bbox=bbox)


def parse(pages: list[list[OcrLine]]) -> list:
    parser = QuestionParser()
    for page_number, page_lines in enumerate(pages, start=1):
        parser.feed(page_number, page_lines)
    return parser.finish()


def test_splits_arabic_numbered_questions_and_collects_options():
    questions = parse([
        [
            line("1. 求函数 f(x) 的极限"),
            line("A. 0"),
            line("B. 1"),
            line("2. 计算下列积分"),
        ]
    ])

    assert [question.position for question in questions] == [1, 2]
    assert questions[0].type == "single_choice"
    assert questions[0].options == {"A": "0", "B": "1"}
    assert questions[0].page_start == 1 and questions[0].page_end == 1
    assert questions[1].question == "计算下列积分"


def test_splits_chinese_numbered_questions():
    questions = parse([[line("一、求极限"), line("二、证明不等式")]])

    assert len(questions) == 2
    assert questions[0].question == "求极限"
    assert questions[1].question == "证明不等式"


def test_blank_and_short_answer_classification():
    questions = parse([
        [line("1. 填空：f(x) = （ ）")],
        [line("2. 证明：a^2 + b^2 >= 2ab")],
    ])

    assert questions[0].type == "blank"
    assert questions[1].type == "short_answer"


def test_unknown_type_is_flagged_for_review():
    questions = parse([[line("1. 一些无法分类的内容")]])

    assert questions[0].type == "unknown"
    assert questions[0].review_required is True


def test_low_confidence_is_flagged_but_never_fails():
    questions = parse([[line("1. 题干文本", confidence=0.6)]])

    assert questions[0].review_required is True
    assert questions[0].confidence == 0.6


def test_formula_heavy_lines_are_flagged_for_review():
    questions = parse([[line("1. 计算 ∫₀¹ x² dx = ?")]])

    assert questions[0].review_required is True


def test_text_before_any_number_starts_a_review_question():
    questions = parse([[line("这是标题还是题干？"), line("1. 正常题目")]])

    assert len(questions) == 2
    assert questions[0].question == "这是标题还是题干？"
    assert questions[0].review_required is True


def test_cross_page_question_merges_and_tracks_both_regions():
    questions = parse([
        [
            OcrLine("1. 求函数极限", 0.95, (10.0, 10.0, 200.0, 30.0)),
            OcrLine("A. 0", 0.95, (10.0, 30.0, 60.0, 50.0)),
        ],
        [OcrLine("答案是 1", 0.95, (15.0, 12.0, 90.0, 28.0))],
    ])

    assert len(questions) == 1
    assert questions[0].page_start == 1 and questions[0].page_end == 2
    assert questions[0].page_regions == {
        1: (10.0, 10.0, 200.0, 50.0),
        2: (15.0, 12.0, 90.0, 28.0),
    }


def test_option_lines_without_an_open_question_are_ignored():
    questions = parse([[line("A. 0"), line("B. 1")]])

    assert questions == []


def test_empty_lines_are_ignored():
    questions = parse([[line(""), line("1. 题干")]])

    assert len(questions) == 1


def test_finish_resets_state_for_the_next_run():
    parser = QuestionParser()
    parser.feed(1, [line("1. 题干")])

    first = parser.finish()
    second = parser.finish()

    assert len(first) == 1
    assert second == []


def test_regions_union_within_one_page():
    questions = parse([
        [
            OcrLine("1. 第一行", 0.95, (10.0, 10.0, 100.0, 25.0)),
            OcrLine("续行", 0.95, (30.0, 25.0, 150.0, 40.0)),
        ]
    ])

    assert questions[0].page_regions == {1: (10.0, 10.0, 150.0, 40.0)}
