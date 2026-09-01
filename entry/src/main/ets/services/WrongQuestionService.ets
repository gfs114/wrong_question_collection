import { relationalStore } from '@kit.ArkData'
import { WrongQuestionFilter, WrongQuestionListItem, WrongQuestionSummary } from '../models/WrongQuestion'
import { IdUtils } from '../utils/IdUtils'
import { DatabaseService } from './DatabaseService'

const WRONG_QUESTION_COLUMNS: string = 'w.id, w.question_id, w.bank_id, w.subject, w.add_time, ' +
  'w.mastered, w.user_answer, q.content, q.options_json, q.answer, q.analysis, b.bank_name, q.type'
const WRONG_QUESTION_SUMMARY_COLUMNS: string = 'w.id, w.question_id, w.bank_id, w.subject, w.add_time, ' +
  'w.mastered, q.content, b.bank_name'
const WRONG_QUESTION_JOIN: string = ' FROM wrong_question w ' +
  'INNER JOIN question q ON q.id = w.question_id ' +
  'INNER JOIN question_bank b ON b.id = w.bank_id'
const WRITE_TRANSACTION_OPTIONS: relationalStore.TransactionOptions = {
  transactionType: relationalStore.TransactionType.IMMEDIATE
}

export class WrongQuestionService {
  static async add(questionId: string, bankId: string, subject: string): Promise<boolean> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction(WRITE_TRANSACTION_OPTIONS)
    try {
      const questionArgs: Array<relationalStore.ValueType> = [questionId, bankId]
      const questionResultSet: relationalStore.ResultSet = await transaction.querySql(
        'SELECT b.subject FROM question q INNER JOIN question_bank b ON b.id = q.bank_id ' +
        'WHERE q.id = ? AND q.bank_id = ?', questionArgs)
      let storedSubject: string = ''
      try {
        if (!questionResultSet.goToFirstRow()) {
          throw new Error('Question does not belong to the specified bank')
        }
        storedSubject = questionResultSet.getString(0)
      } finally {
        questionResultSet.close()
      }

      const duplicateArgs: Array<relationalStore.ValueType> = [questionId]
      const duplicateResultSet: relationalStore.ResultSet = await transaction.querySql(
        'SELECT 1 FROM wrong_question WHERE question_id = ? LIMIT 1', duplicateArgs)
      let duplicate: boolean = false
      try {
        duplicate = duplicateResultSet.goToFirstRow()
      } finally {
        duplicateResultSet.close()
      }
      if (duplicate) {
        await transaction.commit()
        return false
      }

      const values: relationalStore.ValuesBucket = {
        id: IdUtils.create('wrong_'),
        question_id: questionId,
        bank_id: bankId,
        subject: storedSubject,
        add_time: Date.now(),
        mastered: 0,
        user_answer: ''
      }
      const rowId: number = await transaction.insert('wrong_question', values)
      if (rowId < 0) {
        throw new Error('Failed to insert wrong question')
      }
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
      throw new Error('Failed to add wrong question')
    }
  }

  static async containsQuestion(questionId: string): Promise<boolean> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [questionId]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT 1 FROM wrong_question WHERE question_id = ? LIMIT 1', args)
    try {
      return resultSet.goToFirstRow()
    } finally {
      resultSet.close()
    }
  }

  static async list(filter: WrongQuestionFilter): Promise<Array<WrongQuestionListItem>> {
    const args: Array<relationalStore.ValueType> = new Array<relationalStore.ValueType>()
    let sql: string = 'SELECT ' + WRONG_QUESTION_COLUMNS + WRONG_QUESTION_JOIN + ' WHERE 1 = 1'
    if (filter.subject.length > 0) {
      sql += ' AND w.subject = ?'
      args.push(filter.subject)
    }
    if (filter.bankId.length > 0) {
      sql += ' AND w.bank_id = ?'
      args.push(filter.bankId)
    }
    if (filter.masteredMode === 0 || filter.masteredMode === 1) {
      sql += ' AND w.mastered = ?'
      args.push(filter.masteredMode)
    }
    if (filter.startTime >= 0) {
      sql += ' AND w.add_time >= ?'
      args.push(filter.startTime)
    }
    if (filter.endTime >= 0) {
      sql += ' AND w.add_time <= ?'
      args.push(filter.endTime)
    }
    sql += ' ORDER BY w.add_time DESC'
    return WrongQuestionService.queryItems(sql, args)
  }

  static async listSummaries(filter: WrongQuestionFilter, limit: number,
    offset: number): Promise<Array<WrongQuestionSummary>> {
    if (limit < 1 || limit > 100 || Math.floor(limit) !== limit) {
      throw new Error('Wrong question summary limit must be an integer from 1 to 100')
    }
    if (offset < 0 || Math.floor(offset) !== offset) {
      throw new Error('Wrong question summary offset must be a non-negative integer')
    }
    const args: Array<relationalStore.ValueType> = new Array<relationalStore.ValueType>()
    let sql: string = 'SELECT ' + WRONG_QUESTION_SUMMARY_COLUMNS + WRONG_QUESTION_JOIN + ' WHERE 1 = 1'
    if (filter.subject.length > 0) {
      sql += ' AND w.subject = ?'
      args.push(filter.subject)
    }
    if (filter.bankId.length > 0) {
      sql += ' AND w.bank_id = ?'
      args.push(filter.bankId)
    }
    if (filter.masteredMode === 0 || filter.masteredMode === 1) {
      sql += ' AND w.mastered = ?'
      args.push(filter.masteredMode)
    }
    if (filter.startTime >= 0) {
      sql += ' AND w.add_time >= ?'
      args.push(filter.startTime)
    }
    if (filter.endTime >= 0) {
      sql += ' AND w.add_time <= ?'
      args.push(filter.endTime)
    }
    sql += ' ORDER BY w.add_time DESC, w.id ASC LIMIT ? OFFSET ?'
    args.push(limit)
    args.push(offset)
    return WrongQuestionService.querySummaries(sql, args)
  }

  static async getDetail(wrongId: string): Promise<WrongQuestionListItem | null> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [wrongId]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT ' + WRONG_QUESTION_COLUMNS + WRONG_QUESTION_JOIN + ' WHERE w.id = ?', args)
    try {
      if (!resultSet.goToFirstRow()) {
        return null
      }
      return WrongQuestionService.mapItem(resultSet)
    } finally {
      resultSet.close()
    }
  }

  static async markMastered(wrongId: string): Promise<void> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction(WRITE_TRANSACTION_OPTIONS)
    try {
      // 校验错题记录存在，缺失时抛错回滚。
      await WrongQuestionService.questionIdForWrong(transaction, wrongId)
      const args: Array<relationalStore.ValueType> = [1, wrongId]
      await transaction.execute('UPDATE wrong_question SET mastered = ? WHERE id = ?', args)
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to mark wrong question as mastered')
    }
  }

  static async remove(wrongId: string): Promise<void> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction(WRITE_TRANSACTION_OPTIONS)
    try {
      // 校验错题记录存在，缺失时抛错回滚。
      await WrongQuestionService.questionIdForWrong(transaction, wrongId)
      const args: Array<relationalStore.ValueType> = [wrongId]
      await transaction.execute('DELETE FROM wrong_question WHERE id = ?', args)
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to remove wrong question')
    }
  }

  static async clear(): Promise<void> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction(WRITE_TRANSACTION_OPTIONS)
    try {
      await transaction.execute('DELETE FROM wrong_question')
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to clear wrong questions')
    }
  }

  static async listSubjects(): Promise<Array<string>> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT DISTINCT subject FROM wrong_question ORDER BY subject ASC')
    const subjects: Array<string> = new Array<string>()
    try {
      while (resultSet.goToNextRow()) {
        subjects.push(resultSet.getString(0))
      }
      return subjects
    } finally {
      resultSet.close()
    }
  }

  private static async questionIdForWrong(transaction: relationalStore.Transaction,
    wrongId: string): Promise<string> {
    const args: Array<relationalStore.ValueType> = [wrongId]
    const resultSet: relationalStore.ResultSet = await transaction.querySql(
      'SELECT question_id FROM wrong_question WHERE id = ? LIMIT 1', args)
    try {
      if (!resultSet.goToFirstRow()) {
        throw new Error('Wrong question does not exist')
      }
      return resultSet.getString(0)
    } finally {
      resultSet.close()
    }
  }

  private static async queryItems(sql: string,
    args: Array<relationalStore.ValueType>): Promise<Array<WrongQuestionListItem>> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const resultSet: relationalStore.ResultSet = await store.querySql(sql, args)
    const items: Array<WrongQuestionListItem> = new Array<WrongQuestionListItem>()
    try {
      while (resultSet.goToNextRow()) {
        items.push(WrongQuestionService.mapItem(resultSet))
      }
      return items
    } finally {
      resultSet.close()
    }
  }

  private static async querySummaries(sql: string,
    args: Array<relationalStore.ValueType>): Promise<Array<WrongQuestionSummary>> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const resultSet: relationalStore.ResultSet = await store.querySql(sql, args)
    const items: Array<WrongQuestionSummary> = new Array<WrongQuestionSummary>()
    try {
      while (resultSet.goToNextRow()) {
        items.push(WrongQuestionService.mapSummary(resultSet))
      }
      return items
    } finally {
      resultSet.close()
    }
  }

  private static mapItem(resultSet: relationalStore.ResultSet): WrongQuestionListItem {
    const options: Array<string> = JSON.parse(resultSet.getString(8))
    return new WrongQuestionListItem(
      resultSet.getString(0),
      resultSet.getString(1),
      resultSet.getString(2),
      resultSet.getString(3),
      resultSet.getLong(4),
      resultSet.getLong(5) === 1,
      resultSet.getString(6),
      resultSet.getString(7),
      options,
      resultSet.getString(9),
      resultSet.getString(10),
      resultSet.getString(11),
      resultSet.getString(12))
  }

  private static mapSummary(resultSet: relationalStore.ResultSet): WrongQuestionSummary {
    return new WrongQuestionSummary(
      resultSet.getString(0),
      resultSet.getString(1),
      resultSet.getString(2),
      resultSet.getString(3),
      resultSet.getLong(4),
      resultSet.getLong(5) === 1,
      resultSet.getString(6),
      resultSet.getString(7))
  }
}
