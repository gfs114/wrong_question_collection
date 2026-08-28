export class WrongQuestion {
  id: string
  questionId: string
  bankId: string
  subject: string
  addTime: number
  mastered: boolean
  userAnswer: string

  constructor(id: string, questionId: string, bankId: string, subject: string,
    addTime: number, mastered: boolean, userAnswer: string) {
    this.id = id
    this.questionId = questionId
    this.bankId = bankId
    this.subject = subject
    this.addTime = addTime
    this.mastered = mastered
    this.userAnswer = userAnswer
  }
}

export class WrongQuestionListItem {
  id: string
  questionId: string
  bankId: string
  subject: string
  addTime: number
  mastered: boolean
  userAnswer: string
  question: string
  options: Array<string>
  answer: string
  analysis: string
  bankName: string
  type: string

  constructor(id: string, questionId: string, bankId: string, subject: string,
    addTime: number, mastered: boolean, userAnswer: string, question: string,
    options: Array<string>, answer: string, analysis: string, bankName: string,
    type: string) {
    this.id = id
    this.questionId = questionId
    this.bankId = bankId
    this.subject = subject
    this.addTime = addTime
    this.mastered = mastered
    this.userAnswer = userAnswer
    this.question = question
    this.options = options
    this.answer = answer
    this.analysis = analysis
    this.bankName = bankName
    this.type = type
  }
}

export class WrongQuestionSummary {
  id: string
  questionId: string
  bankId: string
  subject: string
  addTime: number
  mastered: boolean
  question: string
  bankName: string

  constructor(id: string, questionId: string, bankId: string, subject: string,
    addTime: number, mastered: boolean, question: string, bankName: string) {
    this.id = id
    this.questionId = questionId
    this.bankId = bankId
    this.subject = subject
    this.addTime = addTime
    this.mastered = mastered
    this.question = question
    this.bankName = bankName
  }
}

export class WrongQuestionFilter {
  subject: string
  bankId: string
  masteredMode: number
  startTime: number
  endTime: number

  constructor(subject: string = '', bankId: string = '', masteredMode: number = -1,
    startTime: number = -1, endTime: number = -1) {
    this.subject = subject
    this.bankId = bankId
    this.masteredMode = masteredMode
    this.startTime = startTime
    this.endTime = endTime
  }
}
