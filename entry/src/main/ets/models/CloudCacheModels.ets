export class CloudCacheState {
  accountId: string
  cursor: string
  updateTime: number

  constructor(accountId: string, cursor: string, updateTime: number) {
    this.accountId = accountId
    this.cursor = cursor
    this.updateTime = updateTime
  }
}

export class CloudBankCache {
  accountId: string
  bankUuid: string
  bankName: string
  subject: string
  questionCount: number
  serverVersion: string
  updateTime: number

  constructor(accountId: string, bankUuid: string, bankName: string, subject: string,
    questionCount: number, serverVersion: string, updateTime: number) {
    this.accountId = accountId
    this.bankUuid = bankUuid
    this.bankName = bankName
    this.subject = subject
    this.questionCount = questionCount
    this.serverVersion = serverVersion
    this.updateTime = updateTime
  }
}

export class CloudQuestionCache {
  accountId: string
  questionUuid: string
  bankUuid: string
  type: string
  content: string
  optionsJson: string
  answer: string
  analysis: string
  serverVersion: string
  sortOrder: number

  constructor(accountId: string, questionUuid: string, bankUuid: string, type: string,
    content: string, optionsJson: string, answer: string, analysis: string,
    serverVersion: string, sortOrder: number) {
    this.accountId = accountId
    this.questionUuid = questionUuid
    this.bankUuid = bankUuid
    this.type = type
    this.content = content
    this.optionsJson = optionsJson
    this.answer = answer
    this.analysis = analysis
    this.serverVersion = serverVersion
    this.sortOrder = sortOrder
  }
}

export class CloudWrongCache {
  accountId: string
  questionUuid: string
  bankUuid: string
  subject: string
  status: string
  userAnswer: string
  serverVersion: string
  updateTime: number

  constructor(accountId: string, questionUuid: string, bankUuid: string, subject: string,
    status: string, userAnswer: string, serverVersion: string, updateTime: number) {
    this.accountId = accountId
    this.questionUuid = questionUuid
    this.bankUuid = bankUuid
    this.subject = subject
    this.status = status
    this.userAnswer = userAnswer
    this.serverVersion = serverVersion
    this.updateTime = updateTime
  }
}

export class DeviceQuestionImage {
  accountId: string
  questionUuid: string
  imagePath: string
  sha256: string
  sortOrder: number

  constructor(accountId: string, questionUuid: string, imagePath: string, sha256: string,
    sortOrder: number) {
    this.accountId = accountId
    this.questionUuid = questionUuid
    this.imagePath = imagePath
    this.sha256 = sha256
    this.sortOrder = sortOrder
  }
}

export class CloudCachePage {
  cursor: string
  updateTime: number
  banks: Array<CloudBankCache>
  questions: Array<CloudQuestionCache>
  wrongQuestions: Array<CloudWrongCache>

  constructor(cursor: string, updateTime: number, banks: Array<CloudBankCache>,
    questions: Array<CloudQuestionCache>, wrongQuestions: Array<CloudWrongCache>) {
    this.cursor = cursor
    this.updateTime = updateTime
    this.banks = banks
    this.questions = questions
    this.wrongQuestions = wrongQuestions
  }
}

export class CacheVersionPolicy {
  static shouldReplace(currentCursor: string, incomingCursor: string): boolean {
    if (!CacheVersionPolicy.isCursor(incomingCursor)) {
      return false
    }
    if (currentCursor.length === 0) {
      return true
    }
    if (!CacheVersionPolicy.isCursor(currentCursor)) {
      return false
    }
    return CacheVersionPolicy.compare(currentCursor, incomingCursor) < 0
  }

  private static compare(left: string, right: string): number {
    const normalizedLeft: string = CacheVersionPolicy.normalize(left)
    const normalizedRight: string = CacheVersionPolicy.normalize(right)
    if (normalizedLeft.length !== normalizedRight.length) {
      return normalizedLeft.length - normalizedRight.length
    }
    if (normalizedLeft === normalizedRight) {
      return 0
    }
    return normalizedLeft < normalizedRight ? -1 : 1
  }

  private static normalize(value: string): string {
    let index: number = 0
    while (index < value.length - 1 && value.charAt(index) === '0') {
      index++
    }
    return value.substring(index)
  }

  private static isCursor(value: string): boolean {
    return /^[0-9]+$/.test(value)
  }
}
