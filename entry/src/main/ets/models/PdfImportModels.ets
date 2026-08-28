export class PdfFileSelection {
  uri: string
  fileName: string
  fileSize: number
  pageCount: number
  startPage: number
  endPage: number

  constructor(uri: string, fileName: string, fileSize: number, pageCount: number,
    startPage: number = 1, endPage: number = 0) {
    this.uri = uri
    this.fileName = fileName
    this.fileSize = fileSize
    this.pageCount = pageCount
    this.startPage = startPage
    this.endPage = endPage > 0 ? endPage : Math.min(20, pageCount)
  }
}

export class PdfImportSettings {
  bankName: string
  subject: string
  startPage: number
  endPage: number

  constructor(bankName: string, subject: string, startPage: number, endPage: number) {
    this.bankName = bankName
    this.subject = subject
    this.startPage = startPage
    this.endPage = endPage
  }
}

export class PdfPageRangeValidation {
  valid: boolean
  message: string
  selectedPageCount: number

  constructor(valid: boolean, message: string, selectedPageCount: number) {
    this.valid = valid
    this.message = message
    this.selectedPageCount = selectedPageCount
  }
}

export class OcrLine {
  value: string
  pageNumber: number
  left: number
  top: number
  right: number
  bottom: number

  constructor(value: string, pageNumber: number, left: number, top: number, right: number, bottom: number) {
    this.value = value
    this.pageNumber = pageNumber
    this.left = left
    this.top = top
    this.right = right
    this.bottom = bottom
  }
}

export class OcrPage {
  pageNumber: number
  width: number
  height: number
  lines: Array<OcrLine>

  constructor(pageNumber: number, width: number, height: number, lines: Array<OcrLine>) {
    this.pageNumber = pageNumber
    this.width = width
    this.height = height
    this.lines = lines
  }
}

export class PageCrop {
  pageNumber: number
  left: number
  top: number
  right: number
  bottom: number

  constructor(pageNumber: number, left: number, top: number, right: number, bottom: number) {
    this.pageNumber = pageNumber
    this.left = left
    this.top = top
    this.right = right
    this.bottom = bottom
  }
}

export class PdfQuestionDraft {
  localId: string
  type: string
  question: string
  options: Array<string>
  answer: string
  analysis: string
  sourcePageStart: number
  sourcePageEnd: number
  reviewState: string
  crops: Array<PageCrop>
  imagePaths: Array<string>

  constructor(localId: string, type: string, question: string, options: Array<string>, answer: string,
    analysis: string, sourcePageStart: number, sourcePageEnd: number, reviewState: string,
    crops: Array<PageCrop>, imagePaths: Array<string>) {
    this.localId = localId
    this.type = type
    this.question = question
    this.options = options
    this.answer = answer
    this.analysis = analysis
    this.sourcePageStart = sourcePageStart
    this.sourcePageEnd = sourcePageEnd
    this.reviewState = reviewState
    this.crops = crops
    this.imagePaths = imagePaths
  }
}

export class PdfImportProgress {
  readonly stage: string
  readonly currentPage: number
  readonly totalPages: number
  readonly processedPageCount: number
  readonly questionCount: number
  readonly message: string

  constructor(stage: string, currentPage: number, totalPages: number, processedPageCount: number,
    questionCount: number, message: string) {
    this.stage = stage
    this.currentPage = currentPage
    this.totalPages = totalPages
    this.processedPageCount = processedPageCount
    this.questionCount = questionCount
    this.message = message
  }
}

export class PdfPageFailure {
  pageNumber: number
  message: string

  constructor(pageNumber: number, message: string) {
    this.pageNumber = pageNumber
    this.message = message
  }
}
