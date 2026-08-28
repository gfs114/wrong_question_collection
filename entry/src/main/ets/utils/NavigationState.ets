export class NavigationState {
  private static readonly instance: NavigationState = new NavigationState()
  private bankId: string = ''
  private questionId: string = ''
  private wrongQuestionId: string = ''
  private questionBankId: string = ''
  private orderedQuestionIds: Array<string> = []
  private currentQuestionIndex: number = -1

  private constructor() {
  }

  static shared(): NavigationState {
    return NavigationState.instance
  }

  selectBank(bankId: string): void {
    this.bankId = bankId
  }

  selectQuestion(questionId: string, bankId: string, orderedIds: Array<string>, index: number): void {
    this.questionId = questionId
    this.questionBankId = bankId
    this.orderedQuestionIds = orderedIds.slice()
    this.currentQuestionIndex = index
  }

  selectWrongQuestion(wrongId: string): void {
    this.wrongQuestionId = wrongId
  }

  moveQuestion(delta: number): void {
    const nextIndex: number = this.currentQuestionIndex + delta
    if (nextIndex < 0 || nextIndex >= this.orderedQuestionIds.length) {
      return
    }
    this.currentQuestionIndex = nextIndex
    this.questionId = this.orderedQuestionIds[nextIndex]
  }

  get selectedBankId(): string {
    return this.bankId
  }

  get selectedQuestionId(): string {
    return this.questionId
  }

  get selectedQuestionBankId(): string {
    return this.questionBankId
  }

  get selectedWrongQuestionId(): string {
    return this.wrongQuestionId
  }

  get orderedIds(): Array<string> {
    return this.orderedQuestionIds.slice()
  }

  get questionIndex(): number {
    return this.currentQuestionIndex
  }
}
