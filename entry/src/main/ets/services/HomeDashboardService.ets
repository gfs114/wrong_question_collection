import { HomeDashboardSnapshot } from '../models/HomeDashboard'
import { QuestionBankSummary } from '../models/QuestionBank'
import { Statistics } from '../models/Statistics'
import { WrongQuestionFilter, WrongQuestionSummary } from '../models/WrongQuestion'
import { QuestionBankService } from './QuestionBankService'
import { StatisticsService } from './StatisticsService'
import { WrongQuestionService } from './WrongQuestionService'

export class HomeDashboardService {
  static async load(): Promise<HomeDashboardSnapshot> {
    const statistics: Statistics = await StatisticsService.load()
    const banks: Array<QuestionBankSummary> = await QuestionBankService.listBanks()
    const wrongQuestions: Array<WrongQuestionSummary> =
      await WrongQuestionService.listSummaries(new WrongQuestionFilter(), 3, 0)
    return new HomeDashboardSnapshot(statistics, banks, wrongQuestions)
  }
}
