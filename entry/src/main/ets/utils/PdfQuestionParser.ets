import { OcrLine, OcrPage, PageCrop, PdfQuestionDraft } from '../models/PdfImportModels'

class OptionMarker {
  index: number
  end: number
  code: string

  constructor(index: number, end: number, code: string) {
    this.index = index
    this.end = end
    this.code = code
  }
}

class QuestionAccumulator {
  questionLines: Array<string>
  options: Array<string>
  optionCodes: Array<string>
  optionSourceLines: Array<string>
  sourcePageStart: number
  sourcePageEnd: number
  crops: Array<PageCrop>

  constructor(pageNumber: number, crop: PageCrop | null) {
    this.questionLines = new Array<string>()
    this.options = new Array<string>()
    this.optionCodes = new Array<string>()
    this.optionSourceLines = new Array<string>()
    this.sourcePageStart = pageNumber
    this.sourcePageEnd = pageNumber
    this.crops = new Array<PageCrop>()
    if (crop !== null) {
      this.crops.push(crop)
    }
  }
}

export class PdfQuestionParser {
  static parse(pages: Array<OcrPage>): Array<PdfQuestionDraft> {
    const sortedPages: Array<OcrPage> = pages.slice()
    sortedPages.sort((first: OcrPage, second: OcrPage): number => first.pageNumber - second.pageNumber)
    const drafts: Array<PdfQuestionDraft> = new Array<PdfQuestionDraft>()
    let current: QuestionAccumulator | null = null

    for (let pageIndex: number = 0; pageIndex < sortedPages.length; pageIndex++) {
      const page: OcrPage = sortedPages[pageIndex]
      const pageWidth: number = PdfQuestionParser.nonNegative(page.width)
      const pageHeight: number = PdfQuestionParser.nonNegative(page.height)
      const sortedLines: Array<OcrLine> = page.lines.slice()
      sortedLines.sort((first: OcrLine, second: OcrLine): number => {
        if (first.top !== second.top) {
          return first.top - second.top
        }
        return first.left - second.left
      })
      const lines: Array<OcrLine> = PdfQuestionParser.contentLines(sortedLines, pageHeight)
      const starts: Array<number> = PdfQuestionParser.questionStarts(lines)

      if (starts.length === 0) {
        if (current !== null && lines.length > 0) {
          PdfQuestionParser.addCrop(current, page.pageNumber, pageWidth, pageHeight, 0, pageHeight)
          PdfQuestionParser.appendLines(current, lines, 0, lines.length)
        } else if (current === null) {
          drafts.push(PdfQuestionParser.createFallback(page.pageNumber, pageWidth, pageHeight, lines))
        }
        continue
      }

      const firstStart: number = starts[0]
      if (current === null && firstStart > 0) {
        const prefixBottom: number = PdfQuestionParser.cropBoundary(lines[firstStart].top, pageHeight)
        drafts.push(PdfQuestionParser.createPrefixFallback(page.pageNumber, pageWidth, pageHeight,
          lines.slice(0, firstStart), prefixBottom, drafts.length))
      }
      if (current !== null) {
        const firstQuestionTop: number = lines[firstStart].top
        if (firstStart > 0 || firstQuestionTop > 0) {
          const boundary: number = PdfQuestionParser.cropBoundary(firstQuestionTop, pageHeight)
          PdfQuestionParser.addCrop(current, page.pageNumber, pageWidth, pageHeight, 0, boundary)
        }
        if (firstStart > 0) {
          PdfQuestionParser.appendLines(current, lines, 0, firstStart)
        }
        drafts.push(PdfQuestionParser.finish(current, drafts.length))
        current = null
      }

      for (let startIndex: number = 0; startIndex < starts.length; startIndex++) {
        const lineIndex: number = starts[startIndex]
        if (current !== null) {
          const boundary: number = PdfQuestionParser.cropBoundary(lines[lineIndex].top, pageHeight)
          PdfQuestionParser.endCrop(current, page.pageNumber, boundary)
          drafts.push(PdfQuestionParser.finish(current, drafts.length))
        }
        const cropTop: number = PdfQuestionParser.clamp(lines[lineIndex].top, 0, pageHeight)
        const crop: PageCrop | null = PdfQuestionParser.createCrop(page.pageNumber, pageWidth, pageHeight,
          0, cropTop, pageWidth, pageHeight)
        current = new QuestionAccumulator(page.pageNumber, crop)
        const nextLineIndex: number = startIndex + 1 < starts.length ? starts[startIndex + 1] : lines.length
        PdfQuestionParser.appendLines(current, lines, lineIndex, nextLineIndex)
      }
    }

    if (current !== null) {
      drafts.push(PdfQuestionParser.finish(current, drafts.length))
    }
    return drafts
  }

  private static questionNumber(text: string): number {
    const trimmed: string = text.trim()
    let index: number = 0
    let value: number = 0
    while (index < trimmed.length && index < 4) {
      const code: number = trimmed.charCodeAt(index)
      if (code < 48 || code > 57) {
        break
      }
      value = value * 10 + code - 48
      index++
    }
    if (index === 0 || index >= trimmed.length) {
      return -1
    }
    const nextCode: number = trimmed.charCodeAt(index)
    if (index === 4 && nextCode >= 48 && nextCode <= 57) {
      return -1
    }
    const marker: string = trimmed.charAt(index)
    if (marker === '.' || marker === '．' || marker === '、' || PdfQuestionParser.isWhitespace(marker)) {
      return value
    }
    return -1
  }

  private static optionCode(text: string): string {
    const trimmed: string = text.trim()
    const marker: OptionMarker | null = PdfQuestionParser.optionMarkerAt(trimmed, 0)
    if (marker === null) {
      return ''
    }
    return marker.code
  }

  private static classify(text: string, options: Array<string>): string {
    if (options.length >= 2) {
      return 'single_choice'
    }
    const trimmed: string = text.trim()
    if (trimmed.indexOf('______') >= 0 || trimmed.indexOf('____') >= 0 || trimmed.indexOf('（ ）') >= 0 ||
      trimmed.indexOf('( )') >= 0) {
      return 'fill_blank'
    }
    if (trimmed.length === 0) {
      return 'unclassified'
    }
    return 'short_answer'
  }

  private static createFallback(pageNumber: number, pageWidth: number, pageHeight: number,
    lines: Array<OcrLine>): PdfQuestionDraft {
    const textLines: Array<string> = new Array<string>()
    for (let index: number = 0; index < lines.length; index++) {
      const value: string = lines[index].value.trim()
      if (value.length > 0) {
        textLines.push(value)
      }
    }
    const width: number = PdfQuestionParser.nonNegative(pageWidth)
    const height: number = PdfQuestionParser.nonNegative(pageHeight)
    const crops: Array<PageCrop> = new Array<PageCrop>()
    const crop: PageCrop | null = PdfQuestionParser.createCrop(pageNumber, width, height, 0, 0, width, height)
    if (crop !== null) {
      crops.push(crop)
    }
    return new PdfQuestionDraft('pdf_page_' + pageNumber.toString(), 'unclassified', textLines.join('\n'),
      new Array<string>(), '', '', pageNumber, pageNumber, 'needs_review', crops, new Array<string>())
  }

  private static createPrefixFallback(pageNumber: number, pageWidth: number, pageHeight: number,
    lines: Array<OcrLine>, bottom: number, draftIndex: number): PdfQuestionDraft {
    const textLines: Array<string> = new Array<string>()
    for (let index: number = 0; index < lines.length; index++) {
      const value: string = lines[index].value.trim()
      if (value.length > 0) {
        textLines.push(value)
      }
    }
    const safeBottom: number = PdfQuestionParser.clamp(bottom, 0, pageHeight)
    const crops: Array<PageCrop> = new Array<PageCrop>()
    const crop: PageCrop | null = PdfQuestionParser.createCrop(pageNumber, pageWidth, pageHeight,
      0, 0, pageWidth, safeBottom)
    if (crop !== null) {
      crops.push(crop)
    }
    return new PdfQuestionDraft('pdf_' + (draftIndex + 1).toString(), 'unclassified', textLines.join('\n'),
      new Array<string>(), '', '', pageNumber, pageNumber, 'needs_review', crops, new Array<string>())
  }

  private static contentLines(lines: Array<OcrLine>, pageHeight: number): Array<OcrLine> {
    const content: Array<OcrLine> = new Array<OcrLine>()
    const headerBottom: number = pageHeight * 0.04
    const footerTop: number = pageHeight * 0.96
    for (let index: number = 0; index < lines.length; index++) {
      const line: OcrLine = lines[index]
      if (line.bottom <= headerBottom || line.top >= footerTop) {
        continue
      }
      if (line.value.trim().length > 0) {
        content.push(line)
      }
    }
    return content
  }

  private static questionStarts(lines: Array<OcrLine>): Array<number> {
    const starts: Array<number> = new Array<number>()
    for (let index: number = 0; index < lines.length; index++) {
      if (PdfQuestionParser.questionNumber(lines[index].value) >= 0) {
        starts.push(index)
      }
    }
    return starts
  }

  private static appendLines(accumulator: QuestionAccumulator, lines: Array<OcrLine>, start: number,
    end: number): void {
    for (let index: number = start; index < end; index++) {
      PdfQuestionParser.appendLine(accumulator, lines[index].value)
    }
  }

  private static appendLine(accumulator: QuestionAccumulator, text: string): void {
    const value: string = text.trim()
    if (value.length === 0) {
      return
    }
    const markers: Array<OptionMarker> = PdfQuestionParser.optionMarkers(value)
    const firstCode: string = PdfQuestionParser.optionCode(value)
    const inlineBrackets: boolean = PdfQuestionParser.isInlineBracketSequence(value, markers)
    if (markers.length === 0 || (firstCode.length === 0 && !inlineBrackets)) {
      PdfQuestionParser.restoreIncompleteOptions(accumulator)
      accumulator.questionLines.push(value)
      return
    }
    if (!PdfQuestionParser.optionsAreSequential(accumulator, markers)) {
      PdfQuestionParser.restoreIncompleteOptions(accumulator)
      accumulator.questionLines.push(value)
      return
    }
    if (markers[0].index > 0) {
      const prefix: string = value.substring(0, markers[0].index).trim()
      if (prefix.length > 0) {
        accumulator.questionLines.push(prefix)
      }
    }
    accumulator.optionSourceLines.push(value.substring(markers[0].index).trim())
    for (let markerIndex: number = 0; markerIndex < markers.length; markerIndex++) {
      const optionStart: number = markers[markerIndex].index
      const optionEnd: number = markerIndex + 1 < markers.length ? markers[markerIndex + 1].index : value.length
      const option: string = value.substring(optionStart, optionEnd).trim()
      if (option.length > 0) {
        accumulator.options.push(option)
        accumulator.optionCodes.push(markers[markerIndex].code)
      }
    }
  }

  private static optionsAreSequential(accumulator: QuestionAccumulator, markers: Array<OptionMarker>): boolean {
    let expectedCode: number = 65
    if (accumulator.optionCodes.length > 0) {
      expectedCode = accumulator.optionCodes[accumulator.optionCodes.length - 1].charCodeAt(0) + 1
    }
    for (let index: number = 0; index < markers.length; index++) {
      if (markers[index].code.charCodeAt(0) !== expectedCode) {
        return false
      }
      expectedCode++
    }
    return true
  }

  private static isInlineBracketSequence(text: string, markers: Array<OptionMarker>): boolean {
    if (markers.length < 2 || markers[0].index === 0) {
      return false
    }
    for (let index: number = 0; index < markers.length; index++) {
      const start: string = text.charAt(markers[index].index)
      if (start !== '(' && start !== '（') {
        return false
      }
    }
    return true
  }

  private static restoreIncompleteOptions(accumulator: QuestionAccumulator): void {
    if (accumulator.options.length === 0 || accumulator.options.length >= 2) {
      return
    }
    for (let index: number = 0; index < accumulator.optionSourceLines.length; index++) {
      accumulator.questionLines.push(accumulator.optionSourceLines[index])
    }
    accumulator.options = new Array<string>()
    accumulator.optionCodes = new Array<string>()
    accumulator.optionSourceLines = new Array<string>()
  }

  private static optionMarkers(text: string): Array<OptionMarker> {
    const markers: Array<OptionMarker> = new Array<OptionMarker>()
    let index: number = 0
    while (index < text.length) {
      const marker: OptionMarker | null = PdfQuestionParser.optionMarkerAt(text, index)
      if (marker !== null) {
        markers.push(marker)
        index = marker.end
      } else {
        index++
      }
    }
    return markers
  }

  private static optionMarkerAt(text: string, index: number): OptionMarker | null {
    if (index + 2 < text.length && text.charAt(index) === '(' && text.charAt(index + 2) === ')' &&
      PdfQuestionParser.isOptionLetter(text.charAt(index + 1))) {
      return new OptionMarker(index, index + 3, text.charAt(index + 1))
    }
    if (index + 2 < text.length && text.charAt(index) === '（' && text.charAt(index + 2) === '）' &&
      PdfQuestionParser.isOptionLetter(text.charAt(index + 1))) {
      return new OptionMarker(index, index + 3, text.charAt(index + 1))
    }
    if (index + 1 < text.length && PdfQuestionParser.isOptionLetter(text.charAt(index)) &&
      (text.charAt(index + 1) === '.' || text.charAt(index + 1) === '．')) {
      return new OptionMarker(index, index + 2, text.charAt(index))
    }
    return null
  }

  private static isOptionLetter(value: string): boolean {
    if (value.length !== 1) {
      return false
    }
    const code: number = value.charCodeAt(0)
    return code >= 65 && code <= 90
  }

  private static isWhitespace(value: string): boolean {
    return value === ' ' || value === '\t' || value === '\n' || value === '\r' || value === '\f' || value === '　'
  }

  private static addCrop(accumulator: QuestionAccumulator, pageNumber: number, pageWidth: number,
    pageHeight: number, top: number, bottom: number): void {
    accumulator.sourcePageEnd = pageNumber
    const crop: PageCrop | null = PdfQuestionParser.createCrop(pageNumber, pageWidth, pageHeight,
      0, top, pageWidth, bottom)
    if (crop !== null) {
      accumulator.crops.push(crop)
    }
  }

  private static endCrop(accumulator: QuestionAccumulator, pageNumber: number, bottom: number): void {
    if (accumulator.crops.length === 0) {
      return
    }
    const crop: PageCrop = accumulator.crops[accumulator.crops.length - 1]
    if (crop.pageNumber === pageNumber && Number.isFinite(bottom) && bottom > crop.top && bottom < crop.bottom) {
      crop.bottom = bottom
    }
  }

  private static createCrop(pageNumber: number, pageWidth: number, pageHeight: number, left: number,
    top: number, right: number, bottom: number): PageCrop | null {
    if (pageWidth <= 0 || pageHeight <= 0) {
      return null
    }
    const safeLeft: number = PdfQuestionParser.clamp(left, 0, pageWidth)
    const safeTop: number = PdfQuestionParser.clamp(top, 0, pageHeight)
    const safeRight: number = PdfQuestionParser.clamp(right, safeLeft, pageWidth)
    const safeBottom: number = PdfQuestionParser.clamp(bottom, safeTop, pageHeight)
    if (safeRight <= safeLeft || safeBottom <= safeTop) {
      return null
    }
    return new PageCrop(pageNumber, safeLeft, safeTop, safeRight, safeBottom)
  }

  private static cropBoundary(top: number, pageHeight: number): number {
    return PdfQuestionParser.clamp(top - 8, 0, pageHeight)
  }

  private static finish(accumulator: QuestionAccumulator, draftIndex: number): PdfQuestionDraft {
    PdfQuestionParser.restoreIncompleteOptions(accumulator)
    const question: string = accumulator.questionLines.join('\n').trim()
    const type: string = PdfQuestionParser.classify(question, accumulator.options)
    const reviewState: string = type === 'unclassified' && question.length === 0 ? 'needs_review' : 'confirmed'
    return new PdfQuestionDraft('pdf_' + (draftIndex + 1).toString(), type, question, accumulator.options.slice(),
      '', '', accumulator.sourcePageStart, accumulator.sourcePageEnd, reviewState, accumulator.crops.slice(),
      new Array<string>())
  }

  private static nonNegative(value: number): number {
    if (!Number.isFinite(value) || value < 0) {
      return 0
    }
    return value
  }

  private static clamp(value: number, minimum: number, maximum: number): number {
    if (!Number.isFinite(value) || value < minimum) {
      return minimum
    }
    if (value > maximum) {
      return maximum
    }
    return value
  }
}
