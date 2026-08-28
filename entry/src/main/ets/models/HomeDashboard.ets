import { QuestionBankSummary } from './QuestionBank'
import { Statistics } from './Statistics'
import { WrongQuestionSummary } from './WrongQuestion'

export class HomeDashboardMath {
  static masteryRate(wrongCount: number, masteredCount: number): number {
    if (wrongCount <= 0) {
      return 0
    }
    const safeMastered: number = Math.max(0, Math.min(masteredCount, wrongCount))
    return Math.round(safeMastered * 100 / wrongCount)
  }
}

export class HomeDashboardSnapshot {
  statistics: Statistics
  recentBanks: Array<QuestionBankSummary>
  recentWrongQuestions: Array<WrongQuestionSummary>
  masteryRate: number

  constructor(statistics: Statistics, recentBanks: Array<QuestionBankSummary>,
    recentWrongQuestions: Array<WrongQuestionSummary>) {
    this.statistics = statistics
    this.recentBanks = recentBanks.slice(0, 3)
    this.recentWrongQuestions = recentWrongQuestions.slice(0, 3)
    this.masteryRate = HomeDashboardMath.masteryRate(statistics.wrongCount, statistics.masteredCount)
  }
}
