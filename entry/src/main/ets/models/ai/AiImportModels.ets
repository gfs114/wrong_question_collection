import { AiImportErrorCode } from './AiProviderConfig'

export enum AiQuestionType {
  SINGLE_CHOICE = 'single_choice',
  BLANK = 'blank',
  SHORT_ANSWER = 'short_answer',
  UNKNOWN = 'unknown'
}

export class AiOption {
  key: string
  value: string

  constructor(key: string, value: string) {
    this.key = key
    this.value = value
  }
}

export class AiBoundingBox {
  x1: number
  y1: number
  x2: number
  y2: number

  constructor(x1: number, y1: number, x2: number, y2: number) {
    this.x1 = x1
    this.y1 = y1
    this.x2 = x2
    this.y2 = y2
  }
}

export class AiQuestionDraft {
  label: string
  type: AiQuestionType
  question: string
  options: Array<AiOption>
  answer: string
  analysis: string
  bbox: AiBoundingBox
  bboxUsable: boolean
  pageNumber: number

  constructor(label: string, type: AiQuestionType, question: string, options: Array<AiOption>,
    answer: string, analysis: string, bbox: AiBoundingBox, bboxUsable: boolean, pageNumber: number) {
    this.label = label
    this.type = type
    this.question = question
    this.options = options
    this.answer = answer
    this.analysis = analysis
    this.bbox = bbox
    this.bboxUsable = bboxUsable
    this.pageNumber = pageNumber
  }
}

export class EncodedPdfPage {
  pageNumber: number
  width: number
  height: number
  jpegBase64: string
  evidencePath: string

  constructor(pageNumber: number, width: number, height: number,
    jpegBase64: string, evidencePath: string) {
    this.pageNumber = pageNumber
    this.width = width
    this.height = height
    this.jpegBase64 = jpegBase64
    this.evidencePath = evidencePath
  }

  releaseTransientText(): void {
    this.jpegBase64 = ''
  }
}

export class AiPageFailure {
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

export class AiImportProgress {
  currentPage: number
  totalPages: number
  processedPages: number
  questionCount: number
  stage: string

  constructor(currentPage: number, totalPages: number, processedPages: number,
    questionCount: number, stage: string) {
    this.currentPage = currentPage
    this.totalPages = totalPages
    this.processedPages = processedPages
    this.questionCount = questionCount
    this.stage = stage
  }
}
