import { Context } from '@kit.AbilityKit'
import { AiImportErrorCode } from '../../models/ai/AiProviderConfig'
import { AiQuestionType } from '../../models/ai/AiImportModels'

export enum PdfReviewSource {
  CLOUD = 'cloud',
  AI = 'ai'
}

export enum PdfReviewSaveStage {
  DRAFT = 'draft',
  TEXT_SAVING = 'text_saving',
  TEXT_SAVED = 'text_saved',
  COMPLETE = 'complete'
}

export class PdfReviewSavePolicy {
  static canEdit(stage: PdfReviewSaveStage): boolean {
    return stage === PdfReviewSaveStage.DRAFT
  }

  static canAbandon(stage: PdfReviewSaveStage): boolean {
    return stage === PdfReviewSaveStage.DRAFT
  }
}

export class PdfReviewOption {
  key: string
  value: string

  constructor(key: string, value: string) {
    this.key = key
    this.value = value
  }
}

export class PdfReviewImage {
  remoteArtifactId: string
  localPath: string
  sha256: string
  size: number
  contentType: string
  sortOrder: number

  constructor(remoteArtifactId: string, localPath: string, sha256: string, size: number,
    contentType: string, sortOrder: number) {
    this.remoteArtifactId = remoteArtifactId
    this.localPath = localPath
    this.sha256 = sha256
    this.size = size
    this.contentType = contentType
    this.sortOrder = sortOrder
  }
}

export class PdfReviewQuestion {
  draftQuestionId: string
  questionUuid: string
  label: string
  type: AiQuestionType
  question: string
  options: Array<PdfReviewOption>
  answer: string
  analysis: string
  pageStart: number
  pageEnd: number
  confidence: number
  reviewRequired: boolean
  images: Array<PdfReviewImage>

  constructor(draftQuestionId: string, questionUuid: string, label: string, type: AiQuestionType,
    question: string, options: Array<PdfReviewOption>, answer: string, analysis: string,
    pageStart: number, pageEnd: number, confidence: number, reviewRequired: boolean,
    images: Array<PdfReviewImage>) {
    this.draftQuestionId = draftQuestionId
    this.questionUuid = questionUuid
    this.label = label
    this.type = type
    this.question = question
    this.options = options
    this.answer = answer
    this.analysis = analysis
    this.pageStart = pageStart
    this.pageEnd = pageEnd
    this.confidence = confidence
    this.reviewRequired = reviewRequired
    this.images = images
  }
}

export class PdfReviewFailure {
  pageNumber: number
  code: AiImportErrorCode
  message: string
  evidencePath: string

  constructor(pageNumber: number, code: AiImportErrorCode, message: string, evidencePath: string) {
    this.pageNumber = pageNumber
    this.code = code
    this.message = message
    this.evidencePath = evidencePath
  }
}

export class PdfReviewSession {
  sessionId: string
  source: PdfReviewSource
  bankUuid: string
  bankName: string
  subject: string
  pdfPath: string
  accountId: string
  questions: Array<PdfReviewQuestion>
  failures: Array<PdfReviewFailure>
  saveStage: PdfReviewSaveStage

  constructor(sessionId: string, source: PdfReviewSource, bankUuid: string, bankName: string,
    subject: string, pdfPath: string, accountId: string, questions: Array<PdfReviewQuestion>,
    failures: Array<PdfReviewFailure>, saveStage: PdfReviewSaveStage) {
    this.sessionId = sessionId
    this.source = source
    this.bankUuid = bankUuid
    this.bankName = bankName
    this.subject = subject
    this.pdfPath = pdfPath
    this.accountId = accountId
    this.questions = questions
    this.failures = failures
    this.saveStage = saveStage
  }
}

export interface PdfReviewAdapter {
  load(context: Context): Promise<PdfReviewSession>
  persist(session: PdfReviewSession): void
  save(context: Context, session: PdfReviewSession): Promise<PdfReviewSession>
  retryPage(context: Context, session: PdfReviewSession, pageNumber: number): Promise<PdfReviewSession>
  discardFailure(context: Context, session: PdfReviewSession, pageNumber: number,
    replacement: PdfReviewQuestion | null): Promise<PdfReviewSession>
  abandon(context: Context, session: PdfReviewSession): Promise<void>
}
