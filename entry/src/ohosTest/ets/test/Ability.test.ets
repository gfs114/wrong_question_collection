import { Context } from '@kit.AbilityKit'
import { abilityDelegatorRegistry } from '@kit.TestKit'
import { afterEach, beforeAll, describe, expect, it } from '@ohos/hypium'
import { Question } from '../../../main/ets/models/Question'
import { QuestionBank } from '../../../main/ets/models/QuestionBank'
import { Statistics } from '../../../main/ets/models/Statistics'
import { WrongQuestionFilter, WrongQuestionListItem } from '../../../main/ets/models/WrongQuestion'
import { DatabaseService } from '../../../main/ets/services/DatabaseService'
import { QuestionBankService } from '../../../main/ets/services/QuestionBankService'
import { StatisticsService } from '../../../main/ets/services/StatisticsService'
import { WrongQuestionService } from '../../../main/ets/services/WrongQuestionService'

export default function abilityTest(): void {
  describe('localDatabaseLifecycle', () => {
    let testBankId: string = ''

    beforeAll(async (): Promise<void> => {
      const context: Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext()
      await DatabaseService.initialize(context)
    })

    afterEach(async (): Promise<void> => {
      if (testBankId.length > 0) {
        const imagePaths: Array<string> = await QuestionBankService.deleteBank(testBankId)
        testBankId = ''
      }
    })

    it('persistsMastersAndCleansUpThroughPublicServices', 0, async (): Promise<void> => {
      const baseline: Statistics = await StatisticsService.load()
      const sourceId: string = 'device_question_' + Date.now().toString()
      const question: Question = new Question(sourceId, '', 'single_choice', '设备测试题目',
        ['A. 错误答案', 'B. 正确答案'], 'B', '设备测试解析')
      const bank: QuestionBank = new QuestionBank('', '设备测试题库_' + Date.now().toString(),
        '设备测试', 1, 0, false, [question])

      testBankId = await QuestionBankService.saveImportedBank(bank, false)
      const added: boolean = await WrongQuestionService.add(question.id, testBankId, '设备测试')
      expect(added).assertTrue()

      const filter: WrongQuestionFilter = new WrongQuestionFilter('', testBankId)
      const items: Array<WrongQuestionListItem> = await WrongQuestionService.list(filter)
      expect(items.length).assertEqual(1)
      await WrongQuestionService.markMastered(items[0].id)

      const current: Statistics = await StatisticsService.load()
      expect(current.bankCount - baseline.bankCount).assertEqual(1)
      expect(current.wrongCount - baseline.wrongCount).assertEqual(1)
      expect(current.masteredCount - baseline.masteredCount).assertEqual(1)
    })
  })
}
