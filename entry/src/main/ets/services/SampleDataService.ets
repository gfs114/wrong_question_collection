import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { QuestionBank, QuestionBankSummary } from '../models/QuestionBank'
import { JsonParser } from '../utils/JsonParser'
import { Utf8Utils } from '../utils/Utf8Utils'
import { QuestionBankService } from './QuestionBankService'

const PREFERENCES_NAME: string = 'app_bootstrap'
const SAMPLE_INITIALIZED_KEY: string = 'sample_initialized'
const SAMPLE_RAWFILE_NAME: string = 'sample_question_bank.json'

export class SampleDataService {
  static async ensureSample(context: Context): Promise<void> {
    const bootstrapPreferences: preferences.Preferences =
      await preferences.getPreferences(context, PREFERENCES_NAME)
    const initialized: preferences.ValueType =
      await bootstrapPreferences.get(SAMPLE_INITIALIZED_KEY, false)
    if (initialized === true) {
      return
    }

    const banks: Array<QuestionBankSummary> = await QuestionBankService.listBanks()
    for (const bank of banks) {
      if (bank.isSample) {
        await SampleDataService.markInitialized(bootstrapPreferences)
        return
      }
    }

    const content: Uint8Array = await context.resourceManager.getRawFileContent(SAMPLE_RAWFILE_NAME)
    const text: string = Utf8Utils.decode(content)
    const bank: QuestionBank = JsonParser.parse(text)
    await QuestionBankService.saveImportedBank(bank, true)
    await SampleDataService.markInitialized(bootstrapPreferences)
  }

  private static async markInitialized(bootstrapPreferences: preferences.Preferences): Promise<void> {
    // 成功落库后再持久化标记。
    try {
      await bootstrapPreferences.put(SAMPLE_INITIALIZED_KEY, true)
      await bootstrapPreferences.flush()
    } catch (err) {
      // 标记写入失败时保持可重试。
      try {
        await bootstrapPreferences.put(SAMPLE_INITIALIZED_KEY, false)
        await bootstrapPreferences.flush()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to persist sample initialization state')
    }
  }
}
