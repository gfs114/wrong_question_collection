import { QuestionImage } from './QuestionImage'

export class Question {
  id: string
  bankId: string
  type: string
  question: string
  options: Array<string>
  answer: string
  analysis: string
  sourcePageStart: number
  sourcePageEnd: number
  reviewState: string
  images: Array<QuestionImage>

  constructor(id: string, bankId: string, type: string, question: string,
    options: Array<string>, answer: string, analysis: string, sourcePageStart: number = 0,
    sourcePageEnd: number = 0, reviewState: string = 'confirmed',
    images: Array<QuestionImage> = new Array<QuestionImage>()) {
    this.id = id
    this.bankId = bankId
    this.type = type
    this.question = question
    this.options = options
    this.answer = answer
    this.analysis = analysis
    this.sourcePageStart = sourcePageStart
    this.sourcePageEnd = sourcePageEnd
    this.reviewState = reviewState
    this.images = images
  }

  getTypeLabel(): string {
    if (this.type === 'single_choice') {
      return '单选题'
    }
    if (this.type === 'fill_blank') {
      return '填空题'
    }
    if (this.type === 'short_answer') {
      return '解答题'
    }
    if (this.type === 'unclassified') {
      return '待确认题型'
    }
    return '未知题型'
  }

  needsReview(): boolean {
    return this.reviewState === 'needs_review'
  }
}
