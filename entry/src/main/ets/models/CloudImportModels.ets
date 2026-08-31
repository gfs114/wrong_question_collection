export enum CloudImportStatus {
  UPLOADING = 'uploading',
  QUEUED = 'queued',
  PROCESSING = 'processing',
  REVIEW = 'review',
  CONFIRMED = 'confirmed',
  FAILED = 'failed',
  CANCELLED = 'cancelled',
  EXPIRED = 'expired'
}

export enum CloudImportQuestionType {
  SINGLE_CHOICE = 'single_choice',
  BLANK = 'blank',
  SHORT_ANSWER = 'short_answer',
  UNKNOWN = 'unknown'
}

export class CloudImportProgress {
  current: number
  total: number

  constructor(current: number, total: number) {
    this.current = current
    this.total = total
  }
}

export class CloudImportJob {
  jobId: string
  bankName: string
  subject: string
  pageStart: number
  pageEnd: number
  sourceSha256: string
  sourceSize: number
  partCount: number
  status: CloudImportStatus
  progress: CloudImportProgress
  expiresAt: string
  createdAt: string
  updatedAt: string

  constructor(jobId: string, bankName: string, subject: string, pageStart: number,
    pageEnd: number, sourceSha256: string, sourceSize: number, partCount: number,
    status: CloudImportStatus, progress: CloudImportProgress, expiresAt: string,
    createdAt: string, updatedAt: string) {
    this.jobId = jobId
    this.bankName = bankName
    this.subject = subject
    this.pageStart = pageStart
    this.pageEnd = pageEnd
    this.sourceSha256 = sourceSha256
    this.sourceSize = sourceSize
    this.partCount = partCount
    this.status = status
    this.progress = progress
    this.expiresAt = expiresAt
    this.createdAt = createdAt
    this.updatedAt = updatedAt
  }
}

export class CloudImportArtifact {
  artifactId: string
  sha256: string
  size: number
  contentType: string

  constructor(artifactId: string, sha256: string, size: number, contentType: string) {
    this.artifactId = artifactId
    this.sha256 = sha256
    this.size = size
    this.contentType = contentType
  }
}

export class CloudImportDraftQuestion {
  draftQuestionId: string
  type: string
  question: string
  options: Record<string, string> | null
  answer: string | null
  analysis: string | null
  pageStart: number
  pageEnd: number
  confidence: number
  reviewRequired: boolean
  images: Array<CloudImportArtifact>

  constructor(draftQuestionId: string, type: string, question: string,
    options: Record<string, string> | null, answer: string | null, analysis: string | null,
    pageStart: number, pageEnd: number, confidence: number, reviewRequired: boolean,
    images: Array<CloudImportArtifact>) {
    this.draftQuestionId = draftQuestionId
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

export class CloudImportDraft {
  jobId: string
  status: CloudImportStatus
  bankName: string
  subject: string
  expiresAt: string
  questions: Array<CloudImportDraftQuestion>

  constructor(jobId: string, status: CloudImportStatus, bankName: string, subject: string,
    expiresAt: string, questions: Array<CloudImportDraftQuestion>) {
    this.jobId = jobId
    this.status = status
    this.bankName = bankName
    this.subject = subject
    this.expiresAt = expiresAt
    this.questions = questions
  }
}

export class CreateCloudImportRequest {
  bankName: string
  subject: string
  pageStart: number
  pageEnd: number
  sourceSize: number
  sourceSha256: string

  constructor(bankName: string, subject: string, pageStart: number, pageEnd: number,
    sourceSize: number, sourceSha256: string) {
    this.bankName = bankName
    this.subject = subject
    this.pageStart = pageStart
    this.pageEnd = pageEnd
    this.sourceSize = sourceSize
    this.sourceSha256 = sourceSha256
  }
}

export class CompleteCloudImportRequest {
  partCount: number
  sourceSha256: string

  constructor(partCount: number, sourceSha256: string) {
    this.partCount = partCount
    this.sourceSha256 = sourceSha256
  }
}

export class CompleteCloudImportResult {
  jobId: string
  status: CloudImportStatus

  constructor(jobId: string, status: CloudImportStatus) {
    this.jobId = jobId
    this.status = status
  }
}

export class ConfirmCloudImportQuestion {
  draftQuestionId: string
  type: CloudImportQuestionType
  question: string
  options: Record<string, string> | null
  answer: string | null
  analysis: string | null
  reviewed: boolean

  constructor(draftQuestionId: string, type: CloudImportQuestionType, question: string,
    options: Record<string, string> | null, answer: string | null, analysis: string | null,
    reviewed: boolean) {
    this.draftQuestionId = draftQuestionId
    this.type = type
    this.question = question
    this.options = options
    this.answer = answer
    this.analysis = analysis
    this.reviewed = reviewed
  }
}

export class ConfirmCloudImportRequest {
  bankName: string
  subject: string
  questions: Array<ConfirmCloudImportQuestion>

  constructor(bankName: string, subject: string, questions: Array<ConfirmCloudImportQuestion>) {
    this.bankName = bankName
    this.subject = subject
    this.questions = questions
  }
}

export class ConfirmedImportArtifact {
  artifactId: string
  sha256: string
  size: number

  constructor(artifactId: string, sha256: string, size: number) {
    this.artifactId = artifactId
    this.sha256 = sha256
    this.size = size
  }
}

export class ConfirmImportQuestionResult {
  draftQuestionId: string
  questionId: string
  images: Array<ConfirmedImportArtifact>

  constructor(draftQuestionId: string, questionId: string,
    images: Array<ConfirmedImportArtifact>) {
    this.draftQuestionId = draftQuestionId
    this.questionId = questionId
    this.images = images
  }
}

export class ConfirmImportResult {
  bankId: string
  questions: Array<ConfirmImportQuestionResult>
  expiresAt: string

  constructor(bankId: string, questions: Array<ConfirmImportQuestionResult>, expiresAt: string) {
    this.bankId = bankId
    this.questions = questions
    this.expiresAt = expiresAt
  }
}

export class CloudImportArtifactAckRequest {
  artifactIds: Array<string>

  constructor(artifactIds: Array<string>) {
    this.artifactIds = artifactIds
  }
}

export class CloudImportUploadRequest {
  pdfPath: string
  bankName: string
  subject: string
  pageStart: number
  pageEnd: number

  constructor(pdfPath: string, bankName: string, subject: string, pageStart: number,
    pageEnd: number) {
    this.pdfPath = pdfPath
    this.bankName = bankName
    this.subject = subject
    this.pageStart = pageStart
    this.pageEnd = pageEnd
  }
}

export class CloudImportFileMetadata {
  sourceSize: number
  sourceSha256: string

  constructor(sourceSize: number, sourceSha256: string) {
    this.sourceSize = sourceSize
    this.sourceSha256 = sourceSha256
  }
}

export class CloudImportUploadPolicy {
  static partCount(sourceSize: number, partBytes: number): number {
    if (!Number.isInteger(sourceSize) || sourceSize <= 0 ||
      !Number.isInteger(partBytes) || partBytes <= 0) {
      throw new Error('Invalid cloud import size')
    }
    return Math.ceil(sourceSize / partBytes)
  }

  static partLength(sourceSize: number, partBytes: number, partIndex: number): number {
    const count: number = CloudImportUploadPolicy.partCount(sourceSize, partBytes)
    if (!Number.isInteger(partIndex) || partIndex < 0 || partIndex >= count) {
      throw new Error('Invalid cloud import part index')
    }
    return Math.min(partBytes, sourceSize - partIndex * partBytes)
  }

  static firstMissingPart(value: number, partCount: number): number {
    if (!Number.isInteger(value) || !Number.isInteger(partCount) || partCount <= 0 ||
      value < 0 || value > partCount) {
      throw new Error('Invalid first missing cloud import part')
    }
    return value
  }

  static isSha256(value: string): boolean {
    return /^[a-f0-9]{64}$/.test(value)
  }
}

export class CloudImportRetryPolicy {
  static shouldRefresh(statusCode: number, alreadyRefreshed: boolean): boolean {
    return statusCode === 401 && !alreadyRefreshed
  }
}
