"""QuestionParser splitting/classification policy tests (pure logic)."""

from __future__ import annotations

import pytest

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
    assert questions[1].question == "2. 计算下列积分"


def test_splits_chinese_numbered_questions():
    questions = parse([[line("一、求极限"), line("二、证明不等式")]])

    assert len(questions) == 2
    assert questions[0].question == "一、 求极限"
    assert questions[1].question == "二、 证明不等式"


def test_preserves_example_decimal_label_in_question_text():
    questions = parse([[line("例1.1 设函数 f(x)=x²")]])

    assert len(questions) == 1
    assert questions[0].question.startswith("例1.1 ")


def test_canonicalizes_ocr_spacing_inside_example_decimal_label():
    questions = parse([[line("例 1 . 1 设函数 f(x)=x²")]])

    assert questions[0].question.startswith("例1.1 ")


def test_anchor_regions_keep_overlapping_next_question_content_out_of_previous_question():
    questions = parse([[
        OcrLine("例1.4 设 f(x)=x²", 0.95, (10.0, 10.0, 210.0, 30.0)),
        # A tall formula block from Q5 overlaps the Q5 label row. Paddle's
        # centre-y ordering can emit it before the label itself.
        OcrLine("2-x, x≤0", 0.90, (70.0, 85.0, 180.0, 115.0)),
        OcrLine("例1.5 设 g(x)=", 0.95, (10.0, 100.0, 210.0, 120.0)),
    ]])

    assert len(questions) == 2
    assert "2-x" not in questions[0].question
    assert "2-x" in questions[1].question
    assert questions[0].page_regions[1][3] <= 100.0
    assert questions[1].page_regions[1][1] == 100.0


def test_normalizes_unicode_superscript_to_katex_inline_math():
    questions = parse([[line("例1.2 设函数 f(x)=x²")]])

    assert "$x^2$" in questions[0].question
    assert "x²" not in questions[0].question


def test_recovers_compact_x2_as_an_exponent_in_math_context():
    questions = parse([[line("例1.2 设函数 f(x)=x2+1")]])

    assert "$x^2$+1" in questions[0].question
    assert "x2" not in questions[0].question


def test_recovers_missing_caret_in_compact_braced_power():
    questions = parse([[line("例1.1 设 f(x)=1+x{4}")]])

    assert "$x^4$" in questions[0].question
    assert "x{4}" not in questions[0].question


def test_normalizes_parenthesized_root_with_full_radicand():
    questions = parse([[line("例1.3 求 y=√(x²+1) 的定义域")]])

    assert r"$\sqrt{x^2+1}$" in questions[0].question
    assert "√" not in questions[0].question


def test_recovers_unparenthesized_ocr_root_from_covered_geometry():
    questions = parse([[
        OcrLine("例1.2 且满足 y=", 0.95, (10.0, 10.0, 75.0, 30.0)),
        # The radical glyph's overbar bbox covers the complete radicand.
        OcrLine("√", 0.90, (80.0, 8.0, 155.0, 31.0)),
        OcrLine("1+x2", 0.94, (100.0, 11.0, 150.0, 29.0)),
        OcrLine(", 求 f(x)", 0.95, (160.0, 10.0, 220.0, 30.0)),
    ]])

    assert r"$\sqrt{1+x^2}$" in questions[0].question
    assert "√" not in questions[0].question


def test_does_not_expand_radical_past_its_overbar_geometry():
    questions = parse([[
        OcrLine("例1.3 求 ln(x+", 0.95, (10.0, 10.0, 75.0, 30.0)),
        OcrLine("√", 0.90, (80.0, 8.0, 128.0, 31.0)),
        OcrLine("x²", 0.94, (100.0, 11.0, 123.0, 29.0)),
        OcrLine("+1) 的定义域", 0.95, (134.0, 10.0, 220.0, 30.0)),
    ]])

    question = questions[0].question
    assert r"$\sqrt{x^2}$" in question
    assert r"\sqrt{x^2+1}" not in question
    assert question.index(r"\sqrt{x^2}") < question.index("+1")


def test_reconstructs_fraction_with_a_geometric_radical_denominator():
    questions = parse([[
        OcrLine("例1.2 求函数值", 0.95, (10.0, 10.0, 75.0, 30.0)),
        OcrLine("x²+2x", 0.94, (100.0, 12.0, 160.0, 26.0)),
        OcrLine("√", 0.90, (80.0, 34.0, 175.0, 61.0)),
        OcrLine("1+x²", 0.94, (100.0, 39.0, 165.0, 57.0)),
    ]])

    question = questions[0].question
    assert r"$\frac{x^2+2x}{\sqrt{1+x^2}}$" in question
    assert "{$" not in question


def test_normalizes_inverse_function_to_katex_inline_math():
    questions = parse([[line("例1.3 求反函数 f⁻¹(x) 的表达式")]])

    assert r"$f^{-1}(x)$" in questions[0].question
    assert "⁻¹" not in questions[0].question


def test_recovers_flattened_inverse_function_from_ocr_spacing():
    questions = parse([[line("例1.3 求反函数 f −1(x) 的表达式")]])

    assert r"$f^{-1}(x)$" in questions[0].question
    assert "f −1(x)" not in questions[0].question


def test_normalizes_phi_function_to_katex_inline_math():
    questions = parse([[line("例1.4 求 φ(x) 的定义域")]])

    assert r"$\varphi(x)$" in questions[0].question
    assert "φ(x)" not in questions[0].question


def test_normalizes_infinite_interval_to_katex_inline_math():
    questions = parse([[line("例1.6 证明函数在(-∞,+∞)内有界")]])

    assert r"$(-\infty,+\infty)$" in questions[0].question


def test_recovers_stacked_fraction_and_keeps_it_before_following_prose():
    questions = parse([[
        OcrLine("例1.6 证明函数 f(x)=", 0.95, (10.0, 10.0, 220.0, 30.0)),
        OcrLine("x", 0.94, (95.0, 34.0, 115.0, 44.0)),
        OcrLine("1+x2", 0.93, (75.0, 49.0, 135.0, 64.0)),
        OcrLine("在(-∞,+∞)内有界.", 0.95, (10.0, 75.0, 240.0, 95.0)),
    ]])

    question = questions[0].question
    assert r"\frac{x}{1+x^2}" in question
    assert question.index(r"\frac") < question.index("在")


def test_anchors_stacked_formulas_into_their_logical_row_by_geometry():
    questions = parse([[
        OcrLine("例1.1 设 f(x)+", 0.95, (10.0, 20.0, 92.0, 40.0)),
        OcrLine("1", 0.94, (108.0, 30.0, 118.0, 42.0)),
        OcrLine("x", 0.94, (102.0, 48.0, 124.0, 62.0)),
        OcrLine("=", 0.95, (132.0, 20.0, 142.0, 40.0)),
        OcrLine("x+x3", 0.94, (158.0, 30.0, 205.0, 42.0)),
        OcrLine("1+x4", 0.94, (153.0, 48.0, 210.0, 62.0)),
        OcrLine(",则当 x≥2 时，f(x)=", 0.95, (220.0, 20.0, 350.0, 40.0)),
    ]])

    question = questions[0].question
    first_fraction = question.index(r"\frac{1}{x}")
    equals = question.index("=", question.index("f(x)+"))
    second_fraction = question.index(r"\frac{x+x^3}{1+x^4}")
    suffix = question.index(",则当")
    assert question.index("f(x)+") < first_fraction < equals < second_fraction < suffix


def test_anchors_fraction_before_same_row_suffix_in_q6_geometry():
    questions = parse([[
        OcrLine("例1.6 证明函数 f(x)=", 0.95, (10.0, 20.0, 120.0, 40.0)),
        OcrLine("x", 0.94, (138.0, 30.0, 148.0, 42.0)),
        OcrLine("1+x2", 0.94, (125.0, 48.0, 165.0, 62.0)),
        OcrLine("在(-∞,+∞)内有界.", 0.95, (175.0, 20.0, 300.0, 40.0)),
    ]])

    question = questions[0].question
    assert question.index(r"\frac{x}{1+x^2}") < question.index("在")


def test_reconstructs_piecewise_rows_as_katex_cases_in_visual_order():
    questions = parse([[
        OcrLine("例1.5 设函数 f(x)=", 0.95, (10.0, 10.0, 220.0, 30.0)),
        # Deliberately scrambled to exercise bbox-driven row ordering.
        OcrLine("x>0", 0.94, (145.0, 64.0, 185.0, 76.0)),
        OcrLine("∫", 0.72, (55.0, 35.0, 70.0, 82.0)),
        OcrLine("-x-1", 0.93, (80.0, 40.0, 125.0, 52.0)),
        OcrLine("2+x", 0.93, (80.0, 64.0, 125.0, 76.0)),
        OcrLine("x≤0", 0.94, (145.0, 40.0, 185.0, 52.0)),
    ]])

    question = questions[0].question
    assert r"\begin{cases}" in question
    assert r"-x-1, & x\le 0" in question
    assert r"2+x, & x>0" in question
    assert question.index("-x-1") < question.index("2+x")
    assert "∫" not in question


@pytest.mark.parametrize("brace_text", ["∫", "(", "[", "|"])
def test_reconstructs_piecewise_for_supported_ocr_brace_glyphs(brace_text):
    questions = parse([[
        OcrLine("例1.5 设 g(x)=", 0.95, (10.0, 10.0, 120.0, 30.0)),
        OcrLine(brace_text, 0.72, (125.0, 34.0, 136.0, 88.0)),
        OcrLine("2−x", 0.93, (145.0, 40.0, 185.0, 54.0)),
        OcrLine("x≤0", 0.94, (205.0, 40.0, 242.0, 54.0)),
        OcrLine("2+x", 0.93, (145.0, 68.0, 185.0, 82.0)),
        OcrLine("x>0", 0.94, (205.0, 68.0, 242.0, 82.0)),
    ]])

    question = questions[0].question
    assert r"\begin{cases}" in question
    assert r"2-x, & x\le 0" in question
    assert r"2+x, & x>0" in question
    assert brace_text not in question.split(r"\begin{cases}", 1)[0].split("g(x)=", 1)[-1]


def test_reconstructs_piecewise_when_tall_narrow_brace_is_ocr_parenthesis():
    questions = parse([[
        OcrLine("例1.5 设 g(x)=", 0.95, (10.0, 10.0, 120.0, 30.0)),
        OcrLine("(", 0.72, (125.0, 34.0, 136.0, 88.0)),
        OcrLine("2−x", 0.93, (145.0, 40.0, 185.0, 54.0)),
        OcrLine("x≤0", 0.94, (205.0, 40.0, 242.0, 54.0)),
        OcrLine("2+x", 0.93, (145.0, 68.0, 185.0, 82.0)),
        OcrLine("x>0", 0.94, (205.0, 68.0, 242.0, 82.0)),
    ]])

    question = questions[0].question
    assert r"\begin{cases}" in question
    assert r"2-x, & x\le 0" in question
    assert r"2+x, & x>0" in question
    assert "(" not in question.split(r"\begin{cases}", 1)[0].split("g(x)=", 1)[-1]


def test_does_not_treat_a_real_integral_as_a_piecewise_brace():
    questions = parse([[
        OcrLine("例1.5 计算定积分", 0.95, (10.0, 10.0, 120.0, 30.0)),
        OcrLine("∫", 0.92, (125.0, 35.0, 139.0, 72.0)),
        OcrLine("f(x)dx", 0.94, (145.0, 45.0, 205.0, 60.0)),
        OcrLine("并讨论 x>0", 0.94, (10.0, 85.0, 135.0, 105.0)),
    ]])

    question = questions[0].question
    assert r"\begin{cases}" not in question
    assert "∫" in question


def test_pairs_piecewise_expressions_and_conditions_by_row_geometry():
    questions = parse([[
        OcrLine("例1.5 设 g(x)=", 0.95, (10.0, 10.0, 120.0, 30.0)),
        OcrLine("|", 0.72, (125.0, 34.0, 132.0, 88.0)),
        # Scrambled source order and slightly different baselines.
        OcrLine("x>0", 0.94, (205.0, 70.0, 242.0, 84.0)),
        OcrLine("2−x", 0.93, (145.0, 40.0, 185.0, 54.0)),
        OcrLine("2+x", 0.93, (145.0, 67.0, 185.0, 81.0)),
        OcrLine("x≤0", 0.94, (205.0, 42.0, 242.0, 56.0)),
    ]])

    question = questions[0].question
    assert r"2-x, & x\le 0" in question
    assert r"2+x, & x>0" in question
    assert question.index("2-x") < question.index("2+x")


def test_reconstructs_piecewise_when_ocr_merges_brace_with_first_row():
    questions = parse([[
        OcrLine("例1.5 设 g(x)=", 0.95, (10.0, 10.0, 220.0, 30.0)),
        OcrLine("∫2−x,x≤0,", 0.78, (55.0, 38.0, 190.0, 55.0)),
        OcrLine("−x−1,x≥0,", 0.90, (80.0, 65.0, 190.0, 82.0)),
    ]])

    question = questions[0].question
    assert r"\begin{cases}" in question
    assert r"2-x, & x\le 0" in question
    assert r"-x-1, & x\ge 0" in question
    assert "∫" not in question


def test_merged_brace_payload_uses_first_row_band_not_tall_brace_center():
    questions = parse([[
        OcrLine("例1.5 设 g(x)=", 0.95, (10.0, 10.0, 120.0, 30.0)),
        # OCR merged the first row into the brace block, while retaining the
        # brace's two-row height. Its bbox centre is therefore not row 1.
        OcrLine("∫2−x,x≤0,", 0.78, (125.0, 34.0, 245.0, 88.0)),
        OcrLine("2+x,x>0,", 0.91, (150.0, 62.0, 245.0, 78.0)),
    ]])

    question = questions[0].question
    assert r"\begin{cases}" in question
    assert r"2-x, & x\le 0" in question
    assert r"2+x, & x>0" in question
    assert "∫2−x" not in question


def test_reconstructs_multiple_piecewise_blocks_independently():
    questions = parse([[
        OcrLine("例1.5 设 f(x)=", 0.95, (10.0, 10.0, 220.0, 30.0)),
        OcrLine("∫1−x,x≤0,", 0.80, (55.0, 38.0, 190.0, 55.0)),
        OcrLine("x+1,x>0,", 0.91, (80.0, 62.0, 190.0, 79.0)),
        OcrLine("另设 h(x)=", 0.95, (10.0, 95.0, 220.0, 115.0)),
        OcrLine("∫2−x,x≤1,", 0.80, (55.0, 125.0, 190.0, 142.0)),
        OcrLine("x+2,x>1,", 0.91, (80.0, 150.0, 190.0, 167.0)),
    ]])

    question = questions[0].question
    assert question.count(r"\begin{cases}") == 2
    assert "∫" not in question


def test_discards_an_isolated_ocr_dollar_artifact():
    questions = parse([[
        OcrLine("例1.5 设 g(x)=", 0.95, (10.0, 10.0, 200.0, 30.0)),
        OcrLine("$", 0.60, (80.0, 35.0, 90.0, 50.0)),
    ]])

    assert questions[0].question.splitlines()[-1] != "$"


def test_removes_unmatched_trailing_dollar_without_damaging_valid_math():
    questions = parse([[
        OcrLine("例1.5 设 g(x)=f ( ) $", 0.95, (10.0, 10.0, 210.0, 30.0)),
        OcrLine("且 h(x)=$x^2$", 0.95, (10.0, 40.0, 180.0, 60.0)),
    ]])

    question = questions[0].question
    assert "f ( ) $" not in question
    assert "f ( )" in question
    assert "$x^2$" in question


def test_removes_empty_repeated_and_unclosed_math_delimiters():
    questions = parse([[
        OcrLine("例1.5 空公式 $$", 0.95, (10.0, 10.0, 150.0, 30.0)),
        OcrLine("重复 $$$", 0.95, (10.0, 40.0, 150.0, 60.0)),
        OcrLine("未闭合 $abc", 0.95, (10.0, 70.0, 150.0, 90.0)),
        OcrLine("合法 $$x+1$$ 与 $x^2$", 0.95, (10.0, 100.0, 210.0, 120.0)),
    ]])

    question = questions[0].question
    assert "空公式 $$" not in question
    assert "$$$" not in question
    assert "$abc" not in question
    assert "$$x+1$$" in question
    assert "$x^2$" in question


def test_real_q5_fragment_shape_reconstructs_cases_and_removes_orphan_dollar():
    questions = parse([[
        OcrLine("例1.5 设 g(x)=", 0.95, (10.0, 10.0, 125.0, 30.0)),
        OcrLine("∫2−x,x≤0,", 0.78, (130.0, 35.0, 245.0, 52.0)),
        OcrLine("f ( ) $", 0.62, (20.0, 58.0, 85.0, 75.0)),
        OcrLine("则 g[f(x)]=", 0.95, (10.0, 82.0, 125.0, 102.0)),
        OcrLine("2+x,x>0,", 0.91, (155.0, 60.0, 245.0, 77.0)),
        OcrLine("(−x−1,x≥0,", 0.90, (130.0, 110.0, 245.0, 127.0)),
    ]])

    question = questions[0].question
    assert r"\begin{cases}" in question
    assert r"2-x, & x\le 0" in question
    assert r"2+x, & x>0" in question
    assert "∫2−x" not in question
    assert "f ( ) $" not in question


def test_math_pdf_six_question_regression_keeps_labels_boundaries_and_structure():
    questions = parse([
        [
            OcrLine("例1.1 设 f(x)=x2", 0.95, (10.0, 10.0, 220.0, 30.0)),
            OcrLine("例1.2 设 y=√(x²+1)", 0.95, (10.0, 100.0, 220.0, 120.0)),
            OcrLine("例1.3 求 f⁻¹(x)", 0.95, (10.0, 200.0, 220.0, 220.0)),
        ],
        [
            OcrLine("例1.4 求 φ(x)", 0.95, (10.0, 10.0, 220.0, 30.0)),
            OcrLine("例1.5 设 g(x)=", 0.95, (10.0, 100.0, 220.0, 120.0)),
            OcrLine("∫", 0.72, (55.0, 125.0, 70.0, 200.0)),
            OcrLine("-x-1", 0.93, (80.0, 135.0, 125.0, 147.0)),
            OcrLine("x≤0", 0.94, (145.0, 135.0, 185.0, 147.0)),
            OcrLine("2+x", 0.93, (80.0, 175.0, 125.0, 187.0)),
            OcrLine("x>0", 0.94, (145.0, 175.0, 185.0, 187.0)),
            OcrLine("例1.6 证明函数 f(x)=", 0.95, (10.0, 220.0, 220.0, 240.0)),
            OcrLine("x", 0.94, (95.0, 245.0, 115.0, 255.0)),
            OcrLine("1+x2", 0.93, (75.0, 260.0, 135.0, 275.0)),
            OcrLine("在(-∞,+∞)内有界.", 0.95, (10.0, 285.0, 240.0, 305.0)),
        ],
    ])

    assert len(questions) == 6
    assert [f"例1.{index}" in question.question for index, question in enumerate(questions, 1)] == [True] * 6
    assert r"\sqrt{x^2+1}" in questions[1].question
    assert r"f^{-1}(x)" in questions[2].question
    assert r"\begin{cases}" not in questions[3].question
    assert r"\begin{cases}" in questions[4].question
    assert "∫" not in questions[4].question
    assert "例1.5" not in questions[3].question
    assert r"\frac{x}{1+x^2}" in questions[5].question
    assert questions[5].question.index(r"\frac{x}{1+x^2}") < questions[5].question.index("在")


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


def test_preamble_before_numbered_question_is_ignored():
    questions = parse([[line("这是标题还是题干？"), line("1. 正常题目")]])

    assert len(questions) == 1
    assert questions[0].question == "1. 正常题目"
    assert "这是标题还是题干？" not in questions[0].question


def test_unnumbered_only_input_preserves_preamble_as_review_draft():
    questions = parse([[line("这是没有编号的题干"), line("继续内容")]])

    assert len(questions) == 1
    assert questions[0].question == "这是没有编号的题干\n继续内容"
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
