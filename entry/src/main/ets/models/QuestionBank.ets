import { Question } from './Question'

export class QuestionBank {
  id: string
  bankName: string
  subject: string
  questionCount: number
  createTime: number
  isSample: boolean
  questions: Array<Question>

  constructor(id: string, bankName: string, subject: string, questionCount: number,
    createTime: number, isSample: boolean, questions: Array<Question>) {
    this.id = id
    this.bankName = bankName
    this.subject = subject
    this.questionCount = questionCount
    this.createTime = createTime
    this.isSample = isSample
    this.questions = questions
  }
}

export class QuestionBankSummary {
  id: string
  bankName: string
  subject: string
  questionCount: number
  createTime: number
  isSample: boolean

  constructor(id: string, bankName: string, subject: string, questionCount: number,
    createTime: number, isSample: boolean) {
    this.id = id
    this.bankName = bankName
    this.subject = subject
    this.questionCount = questionCount
    this.createTime = createTime
    this.isSample = isSample
  }
}
