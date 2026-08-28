export class Statistics {
  bankCount: number
  wrongCount: number
  masteredCount: number
  pendingCount: number

  constructor(bankCount: number, wrongCount: number, masteredCount: number, pendingCount: number) {
    this.bankCount = bankCount
    this.wrongCount = wrongCount
    this.masteredCount = masteredCount
    this.pendingCount = pendingCount
  }
}
