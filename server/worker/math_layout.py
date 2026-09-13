"""Geometry-aware math text reconstruction for OCR/PDF text lines.

The helpers in this module are deterministic and dependency-free.  They only
recover structures for which the source text or bounding boxes provide direct
evidence; they never solve or invent mathematical content.
"""

from __future__ import annotations

import re
import statistics
from dataclasses import dataclass
from typing import Optional, Protocol, Sequence


_SUPERSCRIPT_DIGITS = str.maketrans("⁰¹²³⁴⁵⁶⁷⁸⁹", "0123456789")
_UNICODE_POWER = re.compile(r"(?<![\w\\])(?P<base>[A-Za-z])(?P<power>[⁰¹²³⁴⁵⁶⁷⁸⁹]+)(?!\w)")
_COMPACT_X_POWER = re.compile(r"(?<![A-Za-z0-9])x(?P<power>[234])(?=$|[^A-Za-z0-9])")
_BRACED_X_POWER = re.compile(r"(?<![A-Za-z0-9])x\{(?P<power>[0-9]+)\}")
_INVERSE_FUNCTION = re.compile(r"(?<!\w)(?P<name>[A-Za-z])⁻¹\s*(?P<args>\([^()]*\))")
_FLAT_INVERSE_FUNCTION = re.compile(
    r"(?<!\w)(?P<name>[A-Za-z])\s*[−-]\s*1\s*(?P<args>\([^()]*\))"
)
_PHI_FUNCTION = re.compile(r"φ\s*(?P<args>\([^()]*\))")
_INFINITE_INTERVAL = re.compile(
    r"(?P<left>[([])\s*(?P<first>[+-]?)∞\s*,\s*"
    r"(?P<second>[+-]?)∞\s*(?P<right>[])])"
)
_PARENTHESIZED_ROOT = re.compile(r"√\s*[（(](?P<radicand>[^）)]+)[）)]")
_ROOT_IN_BLOCK = re.compile(
    r"√\s*(?P<radicand>[A-Za-z0-9⁰¹²³⁴⁵⁶⁷⁸⁹+\-*/^.{}]+)"
)
_LATEX_SPAN = re.compile(r"(\$\$.*?\$\$|\$.*?\$)", re.DOTALL)
_CJK = re.compile(r"[\u3400-\u9fff]")
_PIECEWISE_GLYPHS = {"{", "⎧", "⎨", "⎩", "∫", "(", "[", "|"}
_MERGED_PIECEWISE_GLYPHS = ("∫", "{", "⎧")
_RELATION = re.compile(r"(?:<=|>=|<|>|≤|≥)")


class PositionedText(Protocol):
    text: str
    confidence: float
    bbox: tuple[float, float, float, float]


@dataclass
class _LayoutBlock:
    text: str
    bbox: tuple[float, float, float, float]
    source_index: int
    role: str = "text"


LayoutTrace = list[dict[str, object]]


def _trace_block_geometry(block: _LayoutBlock) -> dict[str, object]:
    x1, y1, x2, y2 = block.bbox
    return {
        "text": block.text,
        "bbox": [x1, y1, x2, y2],
        "width": max(0.0, x2 - x1),
        "height": max(0.0, y2 - y1),
        "centerX": (x1 + x2) / 2.0,
        "centerY": (y1 + y2) / 2.0,
    }


def _trace_piecewise_candidate(
    trace: Optional[LayoutTrace],
    *,
    block: _LayoutBlock,
    piecewise_pass: int,
    candidate_detected: bool,
    brace_token: Optional[str],
    estimated_line_height: float,
    rows_detected: int,
    condition_rows: int,
    accepted: bool,
    reject_reason: Optional[str],
) -> None:
    if trace is None:
        return
    height = max(1.0, block.bbox[3] - block.bbox[1])
    trace.append(
        {
            "stage": "piecewise_candidate",
            "piecewisePass": piecewise_pass,
            "blockIndex": block.source_index,
            "candidateDetected": candidate_detected,
            "braceLike": candidate_detected,
            "braceToken": brace_token,
            "estimatedLineHeight": estimated_line_height,
            "heightRatio": height / max(1.0, estimated_line_height),
            "rowsDetected": rows_detected,
            "conditionRows": condition_rows,
            "accepted": accepted,
            "rejectReason": reject_reason,
            **_trace_block_geometry(block),
        }
    )


def _unicode_powers_to_latex(text: str) -> str:
    return _UNICODE_POWER.sub(
        lambda match: f"{match.group('base')}^{match.group('power').translate(_SUPERSCRIPT_DIGITS)}",
        text,
    )


def _plain_fragment_to_latex(text: str) -> str:
    # This helper produces content for an enclosing math node. Existing OCR or
    # reconstructed delimiters must not become nested ``$...$`` spans.
    text = text.replace("$", "")
    text = _unicode_powers_to_latex(text)
    text = _BRACED_X_POWER.sub(
        lambda match: f"x^{match.group('power')}",
        text,
    )
    text = _COMPACT_X_POWER.sub(
        lambda match: f"x^{match.group('power')}",
        text,
    )
    return (
        text.replace("≤", r"\le ")
        .replace("≥", r"\ge ")
        .replace("∞", r"\infty")
        .replace("φ", r"\varphi")
        .replace("−", "-")
    )


def _normalize_plain_math(text: str) -> str:
    text = _INVERSE_FUNCTION.sub(
        lambda match: rf"${match.group('name')}^{{-1}}{match.group('args')}$",
        text,
    )
    text = _FLAT_INVERSE_FUNCTION.sub(
        lambda match: rf"${match.group('name')}^{{-1}}{match.group('args')}$",
        text,
    )
    text = _PHI_FUNCTION.sub(
        lambda match: rf"$\varphi{match.group('args')}$",
        text,
    )
    text = _INFINITE_INTERVAL.sub(
        lambda match: (
            f"${match.group('left')}{match.group('first')}\\infty,"
            f"{match.group('second')}\\infty{match.group('right')}$"
        ),
        text,
    )
    text = _PARENTHESIZED_ROOT.sub(
        lambda match: rf"$\sqrt{{{_plain_fragment_to_latex(match.group('radicand'))}}}$",
        text,
    )
    text = _UNICODE_POWER.sub(
        lambda match: f"${_unicode_powers_to_latex(match.group(0))}$",
        text,
    )
    text = _BRACED_X_POWER.sub(
        lambda match: f"$x^{match.group('power')}$",
        text,
    )
    return _COMPACT_X_POWER.sub(
        lambda match: f"$x^{match.group('power')}$",
        text,
    )


def normalize_math_text(text: str) -> str:
    """Normalize supported Unicode math forms outside existing LaTeX spans."""
    text = _validate_math_delimiters(text)
    parts = _LATEX_SPAN.split(text)
    return "".join(
        part if part.startswith("$") else _normalize_plain_math(part)
        for part in parts
    )


def _validate_math_delimiters(text: str) -> str:
    """Keep non-empty balanced math spans and remove every other dollar run."""
    protected: list[str] = []

    def stash(match: re.Match[str]) -> str:
        protected.append(match.group(0))
        return f"\ue000{len(protected) - 1}\ue001"

    # The worker emits display math with content immediately after the opener.
    # Requiring that evidence prevents an empty ``$$`` artifact from stealing a
    # later closing delimiter across unrelated OCR lines.
    text = re.sub(
        r"\$\$(?=[^$\s])(?:(?!\$\$).)*?[^$\s]\$\$",
        stash,
        text,
        flags=re.DOTALL,
    )
    text = re.sub(
        r"(?<!\$)\$(?!\$)(?=[^$\s])[^$\n]*?[^$\s]\$(?!\$)",
        stash,
        text,
    )
    text = re.sub(r"\$+", "", text)
    for index, span in enumerate(protected):
        text = text.replace(f"\ue000{index}\ue001", span)
    return text


def _is_radical_fragment(text: str) -> bool:
    stripped = text.strip()
    return bool(
        stripped
        and len(stripped) <= 40
        and _CJK.search(stripped) is None
        and "$" not in stripped
        and _RELATION.search(stripped) is None
        and not any(character in stripped for character in ",，;；。！？?")
        and re.search(r"[A-Za-z0-9⁰¹²³⁴⁵⁶⁷⁸⁹]", stripped) is not None
    )


def _vertical_overlap(first: _LayoutBlock, second: _LayoutBlock) -> float:
    return max(0.0, min(first.bbox[3], second.bbox[3]) - max(first.bbox[1], second.bbox[1]))


def _reconstruct_radicals(blocks: list[_LayoutBlock]) -> list[_LayoutBlock]:
    """Build radical nodes only from OCR blocks covered by the radical bbox."""
    consumed: set[int] = set()
    rebuilt: list[_LayoutBlock] = []

    for radical_index, radical in enumerate(blocks):
        if radical_index in consumed or "√" not in radical.text:
            continue
        stripped = radical.text.strip()
        if stripped != "√":
            match = _ROOT_IN_BLOCK.search(radical.text)
            if match is None:
                continue
            radicand = _plain_fragment_to_latex(match.group("radicand"))
            rebuilt.append(
                _LayoutBlock(
                    radical.text[:match.start()]
                    + rf"$\sqrt{{{radicand}}}$"
                    + radical.text[match.end():],
                    radical.bbox,
                    radical.source_index,
                    radical.role,
                )
            )
            consumed.add(radical_index)
            continue

        rx0, ry0, rx1, ry1 = radical.bbox
        radical_height = max(1.0, ry1 - ry0)
        covered: list[tuple[int, _LayoutBlock]] = []
        for index, candidate in enumerate(blocks):
            if index == radical_index or index in consumed:
                continue
            cx0, _cy0, cx1, _cy1 = candidate.bbox
            candidate_height = max(1.0, candidate.bbox[3] - candidate.bbox[1])
            if cx0 < rx0 or cx1 > rx1 + max(2.0, radical_height * 0.08):
                continue
            if _vertical_overlap(radical, candidate) / min(radical_height, candidate_height) < 0.45:
                continue
            if _is_radical_fragment(candidate.text):
                covered.append((index, candidate))
        if not covered:
            continue
        covered.sort(key=lambda item: (item[1].bbox[0], item[1].source_index))
        radicand = "".join(item.text.strip() for _index, item in covered)
        used = [radical, *(item for _index, item in covered)]
        rebuilt.append(
            _LayoutBlock(
                rf"$\sqrt{{{_plain_fragment_to_latex(radicand)}}}$",
                (
                    min(block.bbox[0] for block in used),
                    min(block.bbox[1] for block in used),
                    max(block.bbox[2] for block in used),
                    max(block.bbox[3] for block in used),
                ),
                min(block.source_index for block in used),
                "formula",
            )
        )
        consumed.add(radical_index)
        consumed.update(index for index, _candidate in covered)

    rebuilt.extend(block for index, block in enumerate(blocks) if index not in consumed)
    return rebuilt


def _is_fraction_fragment(text: str) -> bool:
    stripped = text.strip()
    return bool(
        stripped
        and len(stripped) <= 40
        and _CJK.search(stripped) is None
        and not any(character in stripped for character in ",，;；=<>≤≥")
        and re.search(r"[A-Za-z0-9]", stripped) is not None
    )


def _looks_stacked(
    upper: _LayoutBlock,
    lower: _LayoutBlock,
) -> bool:
    ux0, uy0, ux1, uy1 = upper.bbox
    lx0, ly0, lx1, ly1 = lower.bbox
    upper_height = max(1.0, uy1 - uy0)
    lower_height = max(1.0, ly1 - ly0)
    if (uy0 + uy1) / 2.0 >= (ly0 + ly1) / 2.0:
        return False
    if ly0 - uy1 > max(upper_height, lower_height) * 1.5:
        return False
    overlap = max(0.0, min(ux1, lx1) - max(ux0, lx0))
    smaller_width = max(1.0, min(ux1 - ux0, lx1 - lx0))
    if overlap / smaller_width < 0.75:
        return False
    upper_center = (ux0 + ux1) / 2.0
    lower_center = (lx0 + lx1) / 2.0
    return abs(upper_center - lower_center) <= max(ux1 - ux0, lx1 - lx0) * 0.25


def _split_piecewise_row(row: list[_LayoutBlock]) -> tuple[str, str] | None:
    ordered = sorted(row, key=lambda block: (block.bbox[0], block.source_index))
    condition_index = next(
        (index for index, block in enumerate(ordered) if _RELATION.search(block.text)),
        None,
    )
    if condition_index is None:
        return None

    condition_block = ordered[condition_index]
    expression_parts = [block.text for block in ordered[:condition_index]]
    condition = condition_block.text.strip()
    if not expression_parts:
        match = re.match(r"^(?P<expression>.+?)[,，]\s*(?P<condition>.+)$", condition)
        if match is None or _RELATION.search(match.group("condition")) is None:
            return None
        expression_parts = [match.group("expression")]
        condition = match.group("condition")
    condition = condition.strip(" ,，")
    expression = " ".join(part.strip(" ,，") for part in expression_parts if part.strip(" ,，"))
    if not expression:
        return None
    return _plain_fragment_to_latex(expression), _plain_fragment_to_latex(condition)


def _reconstruct_piecewise(
    blocks: list[_LayoutBlock],
    trace: Optional[LayoutTrace] = None,
    piecewise_pass: int = 0,
) -> list[_LayoutBlock]:
    if len(blocks) < 3:
        if trace is not None:
            for block in blocks:
                brace_text = block.text.strip()
                brace_token = next(
                    (glyph for glyph in _PIECEWISE_GLYPHS if brace_text.startswith(glyph)),
                    None,
                )
                _trace_piecewise_candidate(
                    trace,
                    block=block,
                    piecewise_pass=piecewise_pass,
                    candidate_detected=brace_token is not None,
                    brace_token=brace_token,
                    estimated_line_height=1.0,
                    rows_detected=0,
                    condition_rows=0,
                    accepted=False,
                    reject_reason=(
                        "no_multirow_structure" if brace_token is not None else "not_brace_like"
                    ),
                )
        return blocks
    ordinary_heights = [
        max(1.0, block.bbox[3] - block.bbox[1])
        for block in blocks
        if block.text not in _PIECEWISE_GLYPHS
    ]
    median_height = statistics.median(ordinary_heights) if ordinary_heights else 1.0

    for brace_index, brace in enumerate(blocks):
        bx0, by0, bx1, by1 = brace.bbox
        brace_text = brace.text.strip()
        standalone_brace = brace_text in _PIECEWISE_GLYPHS
        merged_glyph = (
            brace_text
            if standalone_brace
            else next(
                (glyph for glyph in _MERGED_PIECEWISE_GLYPHS if brace_text.startswith(glyph)),
                None,
            )
        )
        if merged_glyph is None:
            _trace_piecewise_candidate(
                trace,
                block=brace,
                piecewise_pass=piecewise_pass,
                candidate_detected=False,
                brace_token=None,
                estimated_line_height=median_height,
                rows_detected=0,
                condition_rows=0,
                accepted=False,
                reject_reason="not_brace_like",
            )
            continue
        if standalone_brace:
            brace_height = max(1.0, by1 - by0)
            brace_width = max(1.0, bx1 - bx0)
            if brace_height < median_height * 1.6:
                _trace_piecewise_candidate(
                    trace,
                    block=brace,
                    piecewise_pass=piecewise_pass,
                    candidate_detected=True,
                    brace_token=merged_glyph,
                    estimated_line_height=median_height,
                    rows_detected=0,
                    condition_rows=0,
                    accepted=False,
                    reject_reason="brace_not_tall_enough",
                )
                continue
            if brace_width > brace_height * 0.65:
                _trace_piecewise_candidate(
                    trace,
                    block=brace,
                    piecewise_pass=piecewise_pass,
                    candidate_detected=True,
                    brace_token=merged_glyph,
                    estimated_line_height=median_height,
                    rows_detected=0,
                    condition_rows=0,
                    accepted=False,
                    reject_reason="brace_not_narrow_enough",
                )
                continue
        brace_center = (by0 + by1) / 2.0
        following_braces = [
            (block.bbox[1] + block.bbox[3]) / 2.0
            for index, block in enumerate(blocks)
            if index != brace_index
            and (block.bbox[1] + block.bbox[3]) / 2.0 > brace_center
            and any(block.text.strip().startswith(glyph) for glyph in _PIECEWISE_GLYPHS)
        ]
        next_brace_center = min(following_braces) if following_braces else None

        def before_next_brace(block: _LayoutBlock) -> bool:
            return (
                next_brace_center is None
                or (block.bbox[1] + block.bbox[3]) / 2.0 < next_brace_center
            )

        if standalone_brace:
            candidates = [
                (index, block)
                for index, block in enumerate(blocks)
                if index != brace_index
                and block.bbox[0] >= bx1
                and (block.bbox[1] + block.bbox[3]) / 2.0 >= by0 - median_height * 0.5
                and (block.bbox[1] + block.bbox[3]) / 2.0 <= by1 + median_height * 0.5
                and _CJK.search(block.text) is None
                and before_next_brace(block)
            ]
        else:
            candidates = [
                (index, block)
                for index, block in enumerate(blocks)
                if index != brace_index
                and (block.bbox[1] + block.bbox[3]) / 2.0 >= brace_center - median_height * 0.5
                and block.bbox[0] >= bx0 - median_height
                and _CJK.search(block.text) is None
                and before_next_brace(block)
            ]
            payload = brace_text[len(merged_glyph):].strip(" ,，")
            if payload:
                # A recognizer may merge the first cases row into a tall brace
                # block (for example ``∫2-x,x≤0``). The text payload belongs to
                # the top row, not to the vertical centre of the brace bbox.
                payload_bbox = (
                    bx0,
                    by0,
                    bx1,
                    min(by1, by0 + median_height),
                )
                candidates.append(
                    (
                        brace_index,
                        _LayoutBlock(payload, payload_bbox, brace.source_index),
                    )
                )
        candidates.sort(
            key=lambda item: (
                (item[1].bbox[1] + item[1].bbox[3]) / 2.0,
                item[1].bbox[0],
                item[1].source_index,
            )
        )
        rows: list[list[tuple[int, _LayoutBlock]]] = []
        tolerance = max(4.0, median_height * 0.6)
        for candidate in candidates:
            center_y = (candidate[1].bbox[1] + candidate[1].bbox[3]) / 2.0
            if not rows:
                rows.append([candidate])
                continue
            previous_center = statistics.mean(
                (item[1].bbox[1] + item[1].bbox[3]) / 2.0
                for item in rows[-1]
            )
            if abs(center_y - previous_center) <= tolerance:
                rows[-1].append(candidate)
            else:
                rows.append([candidate])

        if trace is not None:
            for cluster_index, row in enumerate(rows):
                trace.append(
                    {
                        "stage": "piecewise_cluster",
                        "piecewisePass": piecewise_pass,
                        "candidateBlockIndex": brace.source_index,
                        "clusterIndex": cluster_index,
                        "clusterCenterY": statistics.mean(
                            (item[1].bbox[1] + item[1].bbox[3]) / 2.0
                            for item in row
                        ),
                        "blockIndices": [item[1].source_index for item in row],
                    }
                )

        parsed_rows: list[tuple[str, str]] = []
        consumed = {brace_index}
        for row in rows:
            parsed = _split_piecewise_row([block for _index, block in row])
            if parsed is None:
                continue
            parsed_rows.append(parsed)
            consumed.update(index for index, _block in row)
        if len(parsed_rows) < 2:
            if not candidates:
                reject_reason = "no_right_side_rows"
            elif len(rows) < 2 and len(candidates) > 1:
                reject_reason = "row_cluster_collapsed"
            elif len(rows) < 2:
                relation_count = len(_RELATION.findall(payload)) if not standalone_brace else 0
                reject_reason = "payload_not_split" if relation_count > 1 else "no_multirow_structure"
            else:
                reject_reason = "insufficient_condition_rows"
            _trace_piecewise_candidate(
                trace,
                block=brace,
                piecewise_pass=piecewise_pass,
                candidate_detected=True,
                brace_token=merged_glyph,
                estimated_line_height=median_height,
                rows_detected=len(rows),
                condition_rows=len(parsed_rows),
                accepted=False,
                reject_reason=reject_reason,
            )
            continue

        _trace_piecewise_candidate(
            trace,
            block=brace,
            piecewise_pass=piecewise_pass,
            candidate_detected=True,
            brace_token=merged_glyph,
            estimated_line_height=median_height,
            rows_detected=len(rows),
            condition_rows=len(parsed_rows),
            accepted=True,
            reject_reason=None,
        )

        row_text = " \\\\\n".join(
            f"{expression}, & {condition}"
            for expression, condition in parsed_rows
        )
        cases = "$$\\begin{cases}\n" + row_text + "\n\\end{cases}$$"
        used = [blocks[index] for index in consumed]
        replacement = _LayoutBlock(
            cases,
            (
                min(block.bbox[0] for block in used),
                min(block.bbox[1] for block in used),
                max(block.bbox[2] for block in used),
                max(block.bbox[3] for block in used),
            ),
            min(block.source_index for block in used),
            "display",
        )
        return [
            replacement,
            *(block for index, block in enumerate(blocks) if index not in consumed),
        ]
    return blocks


def _same_logical_row(first: _LayoutBlock, second: _LayoutBlock) -> bool:
    if first.role == "display" or second.role == "display":
        return False
    if first.bbox == second.bbox:
        # Identical fallback boxes carry no usable row geometry. Preserve the
        # source sequence instead of flattening independent text lines.
        return False
    first_height = max(1.0, first.bbox[3] - first.bbox[1])
    second_height = max(1.0, second.bbox[3] - second.bbox[1])
    overlap_ratio = _vertical_overlap(first, second) / min(first_height, second_height)
    if overlap_ratio >= 0.45:
        return True
    first_center = (first.bbox[1] + first.bbox[3]) / 2.0
    second_center = (second.bbox[1] + second.bbox[3]) / 2.0
    return abs(first_center - second_center) <= max(3.0, min(first_height, second_height) * 0.35)


def _join_row(blocks: list[_LayoutBlock]) -> str:
    ordered = sorted(blocks, key=lambda block: (block.bbox[0], block.source_index))
    result = ""
    for block in ordered:
        fragment = block.text.strip()
        if not result:
            result = fragment
        elif fragment.startswith((",", "，", ".", "。", ";", "；", ")", "）")):
            result += fragment
        elif result.endswith(("=", "+", "-", "−", "(", "（", "[", "{")):
            result += fragment
        else:
            result += " " + fragment
    return result


def _reading_order(blocks: list[_LayoutBlock]) -> str:
    """Group overlapping baselines, then apply left-to-right order per row."""
    parent = list(range(len(blocks)))

    def find(index: int) -> int:
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    def union(first: int, second: int) -> None:
        first_root = find(first)
        second_root = find(second)
        if first_root != second_root:
            parent[second_root] = first_root

    for first_index, first in enumerate(blocks):
        for second_index in range(first_index + 1, len(blocks)):
            if _same_logical_row(first, blocks[second_index]):
                union(first_index, second_index)

    rows: dict[int, list[_LayoutBlock]] = {}
    for index, block in enumerate(blocks):
        rows.setdefault(find(index), []).append(block)

    def row_key(row: list[_LayoutBlock]) -> tuple[float, float, int]:
        text_centers = [
            (block.bbox[1] + block.bbox[3]) / 2.0
            for block in row
            if block.role == "text"
        ]
        centers = text_centers or [
            (block.bbox[1] + block.bbox[3]) / 2.0 for block in row
        ]
        return (
            statistics.median(centers),
            min(block.bbox[0] for block in row),
            min(block.source_index for block in row),
        )

    return "\n".join(_join_row(row) for row in sorted(rows.values(), key=row_key))


def reconstruct_math_layout(
    lines: Sequence[PositionedText],
    piecewise_trace: Optional[LayoutTrace] = None,
) -> str:
    """Recover directly evidenced math structures and visual reading order."""
    blocks = [
        _LayoutBlock(line.text.strip(), line.bbox, index)
        for index, line in enumerate(lines)
        if line.text.strip() and line.text.strip() != "$"
    ]
    blocks = _reconstruct_radicals(blocks)
    piecewise_pass = 0
    while True:
        if piecewise_trace is not None:
            for detector_order, block in enumerate(blocks):
                piecewise_trace.append(
                    {
                        "stage": "piecewise_input_block",
                        "piecewisePass": piecewise_pass,
                        "blockIndex": block.source_index,
                        "detectorOrder": detector_order,
                        **_trace_block_geometry(block),
                    }
                )
        reconstructed = _reconstruct_piecewise(
            blocks,
            trace=piecewise_trace,
            piecewise_pass=piecewise_pass,
        )
        if reconstructed == blocks:
            break
        blocks = reconstructed
        piecewise_pass += 1
    blocks.sort(
        key=lambda block: (
            (block.bbox[1] + block.bbox[3]) / 2.0,
            block.bbox[0],
            block.source_index,
        )
    )
    consumed: set[int] = set()
    rebuilt: list[_LayoutBlock] = []

    for upper_index, upper in enumerate(blocks):
        if upper_index in consumed or not _is_fraction_fragment(upper.text):
            continue
        for lower_index in range(upper_index + 1, len(blocks)):
            lower = blocks[lower_index]
            if lower_index in consumed or not _is_fraction_fragment(lower.text):
                continue
            if not _looks_stacked(upper, lower):
                continue
            ux0, uy0, ux1, _uy1 = upper.bbox
            lx0, _ly0, lx1, ly1 = lower.bbox
            numerator = _plain_fragment_to_latex(upper.text)
            denominator = _plain_fragment_to_latex(lower.text)
            rebuilt.append(
                _LayoutBlock(
                    rf"$\frac{{{numerator}}}{{{denominator}}}$",
                    (min(ux0, lx0), uy0, max(ux1, lx1), ly1),
                    min(upper.source_index, lower.source_index),
                    "formula",
                )
            )
            consumed.update((upper_index, lower_index))
            break

    rebuilt.extend(block for index, block in enumerate(blocks) if index not in consumed)
    return _reading_order(rebuilt)
