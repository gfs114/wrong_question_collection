import {
  PageCrop,
  PdfFileSelection,
  PdfImportSettings,
  PdfPageFailure,
  PdfQuestionDraft
} from '../models/PdfImportModels'
import {
  CloudImportArtifact,
  CloudImportDraft,
  CloudImportDraftQuestion,
  CloudImportJob,
  CloudImportProgress,
  CloudImportStatus,
  ConfirmedImportArtifact,
  ConfirmImportQuestionResult,
  ConfirmImportResult
} from '../models/CloudImportModels'

export class CloudPdfSelection {
  pdfPath: string
  fileName: string
  sourceSize: number

  constructor(pdfPath: string, fileName: string, sourceSize: number) {
    this.pdfPath = pdfPath
    this.fileName = fileName
    this.sourceSize = sourceSize
  }
}

export class PdfImportState {
  private static readonly instance: PdfImportState = new PdfImportState()
  private selection: PdfFileSelection | null = null
  private settings: PdfImportSettings | null = null
  private drafts: Array<PdfQuestionDraft> = new Array<PdfQuestionDraft>()
  private failures: Array<PdfPageFailure> = new Array<PdfPageFailure>()
  private cancelRequested: boolean = false
  private cloudSelection: CloudPdfSelection | null = null
  private accountId: string = ''
  private jobId: string = ''
  private bankName: string = ''
  private subject: string = ''
  private status: CloudImportStatus = CloudImportStatus.UPLOADING
  private progressCurrent: number = 0
  private progressTotal: number = 0
  private firstMissingPart: number = 0
  private cloudJob: CloudImportJob | null = null
  private cloudReviewDraft: CloudImportDraft | null = null
  private confirmResult: ConfirmImportResult | null = null
  private cloudArtifactExpired: boolean = false

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

  setCloudSelection(selection: CloudPdfSelection | null): void {
    this.cloudSelection = selection === null ? null :
      new CloudPdfSelection(selection.pdfPath, selection.fileName, selection.sourceSize)
  }

  getCloudSelection(): CloudPdfSelection | null {
    const selection: CloudPdfSelection | null = this.cloudSelection
    return selection === null ? null :
      new CloudPdfSelection(selection.pdfPath, selection.fileName, selection.sourceSize)
  }

  clearCloudSelection(): void {
    this.cloudSelection = null
  }

  setCloudAccountId(accountId: string): void {
    this.accountId = accountId
  }

  getCloudAccountId(): string {
    return this.accountId
  }

  setCloudJob(job: CloudImportJob): void {
    this.cloudJob = PdfImportState.copyCloudJob(job)
    this.jobId = job.jobId
    this.bankName = job.bankName
    this.subject = job.subject
    this.status = job.status
    this.progressCurrent = job.progress.current
    this.progressTotal = job.progress.total
  }

  getCloudJob(): CloudImportJob | null {
    const job: CloudImportJob | null = this.cloudJob
    return job === null ? null : PdfImportState.copyCloudJob(job)
  }

  getCloudJobId(): string {
    return this.jobId
  }

  getCloudBankName(): string {
    return this.bankName
  }

  getCloudSubject(): string {
    return this.subject
  }

  setCloudStatus(status: CloudImportStatus): void {
    this.status = status
    const job: CloudImportJob | null = this.cloudJob
    if (job !== null) {
      job.status = status
    }
  }

  getCloudStatus(): CloudImportStatus {
    return this.status
  }

  setCloudProgress(progressCurrent: number, progressTotal: number): void {
    this.progressCurrent = progressCurrent
    this.progressTotal = progressTotal
    const job: CloudImportJob | null = this.cloudJob
    if (job !== null) {
      job.progress = new CloudImportProgress(progressCurrent, progressTotal)
    }
  }

  getCloudProgressCurrent(): number {
    return this.progressCurrent
  }

  getCloudProgressTotal(): number {
    return this.progressTotal
  }

  setFirstMissingPart(firstMissingPart: number): void {
    this.firstMissingPart = firstMissingPart
  }

  getFirstMissingPart(): number {
    return this.firstMissingPart
  }

  setCloudReviewDraft(draft: CloudImportDraft | null): void {
    this.cloudReviewDraft = draft === null ? null : PdfImportState.copyCloudDraft(draft)
  }

  getCloudReviewDraft(): CloudImportDraft | null {
    const draft: CloudImportDraft | null = this.cloudReviewDraft
    return draft === null ? null : PdfImportState.copyCloudDraft(draft)
  }

  setConfirmResult(result: ConfirmImportResult | null): void {
    this.confirmResult = result === null ? null : PdfImportState.copyConfirmResult(result)
  }

  getConfirmResult(): ConfirmImportResult | null {
    const result: ConfirmImportResult | null = this.confirmResult
    return result === null ? null : PdfImportState.copyConfirmResult(result)
  }

  setCloudArtifactExpired(expired: boolean): void {
    this.cloudArtifactExpired = expired
  }

  getCloudArtifactExpired(): boolean {
    return this.cloudArtifactExpired
  }

  resetCloudFlow(): void {
    this.cloudSelection = null
    this.accountId = ''
    this.jobId = ''
    this.bankName = ''
    this.subject = ''
    this.status = CloudImportStatus.UPLOADING
    this.progressCurrent = 0
    this.progressTotal = 0
    this.firstMissingPart = 0
    this.cloudJob = null
    this.cloudReviewDraft = null
    this.confirmResult = null
    this.cloudArtifactExpired = false
  }

  reset(): void {
    this.selection = null
    this.settings = null
    this.drafts = new Array<PdfQuestionDraft>()
    this.failures = new Array<PdfPageFailure>()
    this.cancelRequested = false
    this.resetCloudFlow()
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

  private static copyCloudJob(job: CloudImportJob): CloudImportJob {
    return new CloudImportJob(job.jobId, job.bankName, job.subject, job.pageStart, job.pageEnd,
      job.sourceSha256, job.sourceSize, job.partCount, job.status,
      new CloudImportProgress(job.progress.current, job.progress.total), job.expiresAt,
      job.createdAt, job.updatedAt)
  }

  private static copyCloudDraft(draft: CloudImportDraft): CloudImportDraft {
    const questions: Array<CloudImportDraftQuestion> = new Array<CloudImportDraftQuestion>()
    for (let questionIndex: number = 0; questionIndex < draft.questions.length; questionIndex++) {
      const source: CloudImportDraftQuestion = draft.questions[questionIndex]
      const images: Array<CloudImportArtifact> = new Array<CloudImportArtifact>()
      for (let imageIndex: number = 0; imageIndex < source.images.length; imageIndex++) {
        const image: CloudImportArtifact = source.images[imageIndex]
        images.push(new CloudImportArtifact(image.artifactId, image.sha256, image.size,
          image.contentType))
      }
      questions.push(new CloudImportDraftQuestion(source.draftQuestionId, source.type,
        source.question, source.options, source.answer, source.analysis, source.pageStart,
        source.pageEnd, source.confidence, source.reviewRequired, images))
    }
    return new CloudImportDraft(draft.jobId, draft.status, draft.bankName, draft.subject,
      draft.expiresAt, questions)
  }

  private static copyConfirmResult(result: ConfirmImportResult): ConfirmImportResult {
    const questions: Array<ConfirmImportQuestionResult> = new Array<ConfirmImportQuestionResult>()
    for (let questionIndex: number = 0; questionIndex < result.questions.length; questionIndex++) {
      const source: ConfirmImportQuestionResult = result.questions[questionIndex]
      const images: Array<ConfirmedImportArtifact> = new Array<ConfirmedImportArtifact>()
      for (let imageIndex: number = 0; imageIndex < source.images.length; imageIndex++) {
        const image: ConfirmedImportArtifact = source.images[imageIndex]
        images.push(new ConfirmedImportArtifact(image.artifactId, image.sha256, image.size))
      }
      questions.push(new ConfirmImportQuestionResult(source.draftQuestionId,
        source.questionId, images))
    }
    return new ConfirmImportResult(result.bankId, questions, result.expiresAt)
  }
}
