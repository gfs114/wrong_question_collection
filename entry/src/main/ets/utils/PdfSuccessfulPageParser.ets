import { OcrPage, PdfQuestionDraft } from '../models/PdfImportModels'
import { PdfQuestionParser } from './PdfQuestionParser'

export class PdfSuccessfulPageParser {
  static parse(pages: Array<OcrPage>, selectedStart: number, selectedEnd: number): Array<PdfQuestionDraft> {
    if (!Number.isInteger(selectedStart) || !Number.isInteger(selectedEnd) || selectedStart <= 0 ||
      selectedEnd < selectedStart) {
      throw new Error('所选页面范围无效')
    }
    const sortedPages: Array<OcrPage> = pages.slice()
    sortedPages.sort((first: OcrPage, second: OcrPage): number => first.pageNumber - second.pageNumber)
    const drafts: Array<PdfQuestionDraft> = new Array<PdfQuestionDraft>()
    let segment: Array<OcrPage> = new Array<OcrPage>()
    let previousPageNumber: number = 0
    let missingBeforeSegment: boolean = false
    for (let pageIndex: number = 0; pageIndex < sortedPages.length; pageIndex++) {
      const currentPage: OcrPage = sortedPages[pageIndex]
      if (!Number.isInteger(currentPage.pageNumber) || currentPage.pageNumber < selectedStart ||
        currentPage.pageNumber > selectedEnd || currentPage.pageNumber === previousPageNumber) {
        throw new Error('成功识别页面序列无效')
      }
      if (segment.length === 0) {
        missingBeforeSegment = currentPage.pageNumber > selectedStart
      } else if (currentPage.pageNumber !== previousPageNumber + 1) {
        PdfSuccessfulPageParser.appendSegment(drafts, segment, missingBeforeSegment, true)
        segment = new Array<OcrPage>()
        missingBeforeSegment = true
      }
      segment.push(currentPage)
      previousPageNumber = currentPage.pageNumber
    }
    if (segment.length > 0) {
      PdfSuccessfulPageParser.appendSegment(drafts, segment, missingBeforeSegment,
        previousPageNumber < selectedEnd)
    }
    for (let draftIndex: number = 0; draftIndex < drafts.length; draftIndex++) {
      drafts[draftIndex].localId = 'pdf_' + (draftIndex + 1).toString()
    }
    return drafts
  }

  private static appendSegment(output: Array<PdfQuestionDraft>, pages: Array<OcrPage>, missingBefore: boolean,
    missingAfter: boolean): void {
    const parsed: Array<PdfQuestionDraft> = PdfQuestionParser.parse(pages)
    if (missingBefore && parsed.length > 0) {
      parsed[0].reviewState = 'needs_review'
    }
    if (missingAfter && parsed.length > 0) {
      parsed[parsed.length - 1].reviewState = 'needs_review'
    }
    for (let draftIndex: number = 0; draftIndex < parsed.length; draftIndex++) {
      output.push(parsed[draftIndex])
    }
  }
}
