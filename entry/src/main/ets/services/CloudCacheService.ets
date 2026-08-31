import { relationalStore } from '@kit.ArkData'
import {
  CacheVersionPolicy,
  CloudBankCache,
  CloudCachePage,
  CloudCacheState,
  CloudQuestionCache,
  CloudWrongCache
} from '../models/CloudCacheModels'
import { DatabaseService } from './DatabaseService'

const CACHE_TRANSACTION_OPTIONS: relationalStore.TransactionOptions = {
  transactionType: relationalStore.TransactionType.IMMEDIATE
}

export class CloudCacheService {
  static async replacePage(accountId: string, page: CloudCachePage): Promise<boolean> {
    CloudCacheService.validateAccountId(accountId)
    CloudCacheService.validatePageOwnership(accountId, page)
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction(CACHE_TRANSACTION_OPTIONS)
    try {
      const currentCursor: string = await CloudCacheService.cursorInTransaction(transaction, accountId)
      if (!CacheVersionPolicy.shouldReplace(currentCursor, page.cursor)) {
        await transaction.rollback()
        return false
      }
      await CloudCacheService.deleteAccountText(transaction, accountId)
      for (let index: number = 0; index < page.banks.length; index++) {
        await CloudCacheService.insertBank(transaction, page.banks[index])
      }
      for (let index: number = 0; index < page.questions.length; index++) {
        await CloudCacheService.insertQuestion(transaction, page.questions[index])
      }
      for (let index: number = 0; index < page.wrongQuestions.length; index++) {
        await CloudCacheService.insertWrongQuestion(transaction, page.wrongQuestions[index])
      }
      const stateArgs: Array<relationalStore.ValueType> = [accountId, page.cursor, page.updateTime]
      await transaction.execute(
        'INSERT INTO cloud_cache_state(account_id, cursor, update_time) VALUES (?, ?, ?) ' +
        'ON CONFLICT(account_id) DO UPDATE SET cursor = excluded.cursor, ' +
        'update_time = excluded.update_time', stateArgs)
      await transaction.commit()
      return true
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to replace cloud cache page')
    }
  }

  static async state(accountId: string): Promise<CloudCacheState | null> {
    CloudCacheService.validateAccountId(accountId)
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [accountId]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT account_id, cursor, update_time FROM cloud_cache_state ' +
      'WHERE account_id = ? LIMIT 1', args)
    try {
      if (!resultSet.goToFirstRow()) {
        return null
      }
      return new CloudCacheState(
        resultSet.getString(0), resultSet.getString(1), resultSet.getLong(2))
    } finally {
      resultSet.close()
    }
  }

  static async banks(accountId: string): Promise<Array<CloudBankCache>> {
    CloudCacheService.validateAccountId(accountId)
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [accountId]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT account_id, bank_uuid, bank_name, subject, question_count, server_version, update_time ' +
      'FROM cloud_bank_cache WHERE account_id = ? ORDER BY update_time DESC, bank_uuid ASC', args)
    const banks: Array<CloudBankCache> = new Array<CloudBankCache>()
    try {
      while (resultSet.goToNextRow()) {
        banks.push(new CloudBankCache(
          resultSet.getString(0), resultSet.getString(1), resultSet.getString(2),
          resultSet.getString(3), resultSet.getLong(4), resultSet.getString(5),
          resultSet.getLong(6)))
      }
      return banks
    } finally {
      resultSet.close()
    }
  }

  static async questions(accountId: string, bankUuid: string): Promise<Array<CloudQuestionCache>> {
    CloudCacheService.validateAccountId(accountId)
    CloudCacheService.validateIdentifier(bankUuid, 'Cloud bank UUID')
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [accountId, bankUuid]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT account_id, question_uuid, bank_uuid, type, content, options_json, answer, analysis, ' +
      'server_version, sort_order FROM cloud_question_cache ' +
      'WHERE account_id = ? AND bank_uuid = ? ORDER BY sort_order ASC, question_uuid ASC', args)
    const questions: Array<CloudQuestionCache> = new Array<CloudQuestionCache>()
    try {
      while (resultSet.goToNextRow()) {
        questions.push(CloudCacheService.questionFromResult(resultSet))
      }
      return questions
    } finally {
      resultSet.close()
    }
  }

  static async question(accountId: string, questionUuid: string): Promise<CloudQuestionCache | null> {
    CloudCacheService.validateAccountId(accountId)
    CloudCacheService.validateIdentifier(questionUuid, 'Cloud question UUID')
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [accountId, questionUuid]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT account_id, question_uuid, bank_uuid, type, content, options_json, answer, analysis, ' +
      'server_version, sort_order FROM cloud_question_cache ' +
      'WHERE account_id = ? AND question_uuid = ? LIMIT 1', args)
    try {
      return resultSet.goToFirstRow() ? CloudCacheService.questionFromResult(resultSet) : null
    } finally {
      resultSet.close()
    }
  }

  static async wrongQuestions(accountId: string): Promise<Array<CloudWrongCache>> {
    CloudCacheService.validateAccountId(accountId)
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [accountId]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT account_id, question_uuid, bank_uuid, subject, status, user_answer, ' +
      'server_version, update_time FROM cloud_wrong_cache ' +
      'WHERE account_id = ? ORDER BY update_time DESC, question_uuid ASC', args)
    const wrongQuestions: Array<CloudWrongCache> = new Array<CloudWrongCache>()
    try {
      while (resultSet.goToNextRow()) {
        wrongQuestions.push(new CloudWrongCache(
          resultSet.getString(0), resultSet.getString(1), resultSet.getString(2),
          resultSet.getString(3), resultSet.getString(4), resultSet.getString(5),
          resultSet.getString(6), resultSet.getLong(7)))
      }
      return wrongQuestions
    } finally {
      resultSet.close()
    }
  }

  static async clearAccountTextCache(accountId: string): Promise<void> {
    CloudCacheService.validateAccountId(accountId)
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction(CACHE_TRANSACTION_OPTIONS)
    try {
      await CloudCacheService.deleteAccountText(transaction, accountId)
      const args: Array<relationalStore.ValueType> = [accountId]
      await transaction.execute('DELETE FROM cloud_cache_state WHERE account_id = ?', args)
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to clear account cloud cache')
    }
  }

  private static async cursorInTransaction(transaction: relationalStore.Transaction,
    accountId: string): Promise<string> {
    const args: Array<relationalStore.ValueType> = [accountId]
    const resultSet: relationalStore.ResultSet = await transaction.querySql(
      'SELECT cursor FROM cloud_cache_state WHERE account_id = ? LIMIT 1', args)
    try {
      return resultSet.goToFirstRow() ? resultSet.getString(0) : ''
    } finally {
      resultSet.close()
    }
  }

  private static async deleteAccountText(transaction: relationalStore.Transaction,
    accountId: string): Promise<void> {
    const args: Array<relationalStore.ValueType> = [accountId]
    await transaction.execute('DELETE FROM cloud_bank_cache WHERE account_id = ?', args)
    await transaction.execute('DELETE FROM cloud_question_cache WHERE account_id = ?', args)
    await transaction.execute('DELETE FROM cloud_wrong_cache WHERE account_id = ?', args)
  }

  private static async insertBank(transaction: relationalStore.Transaction,
    bank: CloudBankCache): Promise<void> {
    const values: Array<relationalStore.ValueType> = [
      bank.accountId, bank.bankUuid, bank.bankName, bank.subject, bank.questionCount,
      bank.serverVersion, bank.updateTime
    ]
    await transaction.execute(
      'INSERT INTO cloud_bank_cache(account_id, bank_uuid, bank_name, subject, question_count, ' +
      'server_version, update_time) VALUES (?, ?, ?, ?, ?, ?, ?)', values)
  }

  private static async insertQuestion(transaction: relationalStore.Transaction,
    question: CloudQuestionCache): Promise<void> {
    const values: Array<relationalStore.ValueType> = [
      question.accountId, question.questionUuid, question.bankUuid, question.type, question.content,
      question.optionsJson, question.answer, question.analysis, question.serverVersion,
      question.sortOrder
    ]
    await transaction.execute(
      'INSERT INTO cloud_question_cache(account_id, question_uuid, bank_uuid, type, content, ' +
      'options_json, answer, analysis, server_version, sort_order) ' +
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', values)
  }

  private static async insertWrongQuestion(transaction: relationalStore.Transaction,
    wrongQuestion: CloudWrongCache): Promise<void> {
    const values: Array<relationalStore.ValueType> = [
      wrongQuestion.accountId, wrongQuestion.questionUuid, wrongQuestion.bankUuid,
      wrongQuestion.subject, wrongQuestion.status, wrongQuestion.userAnswer,
      wrongQuestion.serverVersion, wrongQuestion.updateTime
    ]
    await transaction.execute(
      'INSERT INTO cloud_wrong_cache(account_id, question_uuid, bank_uuid, subject, status, ' +
      'user_answer, server_version, update_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', values)
  }

  private static questionFromResult(resultSet: relationalStore.ResultSet): CloudQuestionCache {
    return new CloudQuestionCache(
      resultSet.getString(0), resultSet.getString(1), resultSet.getString(2),
      resultSet.getString(3), resultSet.getString(4), resultSet.getString(5),
      resultSet.getString(6), resultSet.getString(7), resultSet.getString(8),
      resultSet.getLong(9))
  }

  private static validatePageOwnership(accountId: string, page: CloudCachePage): void {
    for (let index: number = 0; index < page.banks.length; index++) {
      if (page.banks[index].accountId !== accountId) {
        throw new Error('Cloud bank belongs to another account')
      }
    }
    for (let index: number = 0; index < page.questions.length; index++) {
      if (page.questions[index].accountId !== accountId) {
        throw new Error('Cloud question belongs to another account')
      }
    }
    for (let index: number = 0; index < page.wrongQuestions.length; index++) {
      if (page.wrongQuestions[index].accountId !== accountId) {
        throw new Error('Cloud wrong question belongs to another account')
      }
    }
  }

  private static validateAccountId(accountId: string): void {
    CloudCacheService.validateIdentifier(accountId, 'Account ID')
  }

  private static validateIdentifier(value: string, name: string): void {
    if (value.trim().length === 0) {
      throw new Error(name + ' cannot be empty')
    }
  }
}
