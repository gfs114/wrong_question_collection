import {
  PageCrop,
  PdfFileSelection,
  PdfImportSettings,
  PdfPageFailure,
  PdfQuestionDraft
} from '../models/PdfImportModels'

export class PdfImportState {
  private static readonly instance: PdfImportState = new PdfImportState()
  private selection: PdfFileSelection | null = null
  private settings: PdfImportSettings | null = null
  private drafts: Array<PdfQuestionDraft> = new Array<PdfQuestionDraft>()
  private failures: Array<PdfPageFailure> = new Array<PdfPageFailure>()
  private cancelRequested: boolean = false

  private constructor() {
  }

  static shared(): PdfImportState {
    return PdfImportState.instance
  }

  setSelection(selection: PdfFileSelection | null): void {
    this.selection = selection === null ? null : PdfImportState.copySelection(selection)
  }

  getSelection(): PdfFileSelection | null {
    return this.selection === null ? null : PdfImportState.copySelection(this.selection)
  }

  setSettings(settings: PdfImportSettings | null): void {
    this.settings = settings === null ? null : PdfImportState.copySettings(settings)
  }

  getSettings(): PdfImportSettings | null {
    return this.settings === null ? null : PdfImportState.copySettings(this.settings)
  }

  setDrafts(drafts: Array<PdfQuestionDraft>): void {
    this.drafts = PdfImportState.copyDrafts(drafts)
  }

  getDrafts(): Array<PdfQuestionDraft> {
    return PdfImportState.copyDrafts(this.drafts)
  }

  setFailures(failures: Array<PdfPageFailure>): void {
    this.failures = PdfImportState.copyFailures(failures)
  }

  getFailures(): Array<PdfPageFailure> {
    return PdfImportState.copyFailures(this.failures)
  }

  requestCancel(): void {
    this.cancelRequested = true
  }

  clearCancelRequest(): void {
    this.cancelRequested = false
  }

  isCancelRequested(): boolean {
    return this.cancelRequested
  }

  reset(): void {
    this.selection = null
    this.settings = null
    this.drafts = new Array<PdfQuestionDraft>()
    this.failures = new Array<PdfPageFailure>()
    this.cancelRequested = false
  }

  private static copySelection(selection: PdfFileSelection): PdfFileSelection {
    return new PdfFileSelection(selection.uri, selection.fileName, selection.fileSize, selection.pageCount,
      selection.startPage, selection.endPage)
  }

  private static copySettings(settings: PdfImportSettings): PdfImportSettings {
    return new PdfImportSettings(settings.bankName, settings.subject, settings.startPage, settings.endPage)
  }

  private static copyDrafts(drafts: Array<PdfQuestionDraft>): Array<PdfQuestionDraft> {
    const copies: Array<PdfQuestionDraft> = new Array<PdfQuestionDraft>()
    for (const draft of drafts) {
      const crops: Array<PageCrop> = new Array<PageCrop>()
      for (const crop of draft.crops) {
        crops.push(new PageCrop(crop.pageNumber, crop.left, crop.top, crop.right, crop.bottom))
      }
      copies.push(new PdfQuestionDraft(draft.localId, draft.type, draft.question, draft.options.slice(), draft.answer,
        draft.analysis, draft.sourcePageStart, draft.sourcePageEnd, draft.reviewState, crops,
        draft.imagePaths.slice()))
    }
    return copies
  }

  private static copyFailures(failures: Array<PdfPageFailure>): Array<PdfPageFailure> {
    const copies: Array<PdfPageFailure> = new Array<PdfPageFailure>()
    for (const failure of failures) {
      copies.push(new PdfPageFailure(failure.pageNumber, failure.message))
    }
    return copies
  }
}
