import { relationalStore } from '@kit.ArkData'
import { Statistics } from '../models/Statistics'
import { DatabaseService } from './DatabaseService'

export class StatisticsService {
  static async load(): Promise<Statistics> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [1]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT (SELECT COUNT(*) FROM question_bank) AS bank_count, ' +
      'COUNT(*) AS wrong_count, ' +
      'COALESCE(SUM(CASE WHEN mastered = ? THEN 1 ELSE 0 END), 0) AS mastered_count ' +
      'FROM wrong_question', args)
    try {
      if (!resultSet.goToFirstRow()) {
        return new Statistics(0, 0, 0, 0)
      }
      const bankCount: number = resultSet.getLong(0)
      const wrongCount: number = resultSet.getLong(1)
      const masteredCount: number = resultSet.getLong(2)
      return new Statistics(bankCount, wrongCount, masteredCount, wrongCount - masteredCount)
    } finally {
      resultSet.close()
    }
  }
}
