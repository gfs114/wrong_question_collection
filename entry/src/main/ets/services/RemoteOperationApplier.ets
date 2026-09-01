import { relationalStore } from '@kit.ArkData'
import {
  RemoteSyncOperation,
  SyncEntityType,
  SyncOperationType,
  SyncPayloadData,
  SyncSequence
} from '../models/SyncModels'
import { IdUtils } from '../utils/IdUtils'
import { DatabaseService } from './DatabaseService'
import { SyncIdentityService } from './SyncIdentityService'
import { SyncOutboxService } from './SyncOutboxService'

const WRITE_TRANSACTION_OPTIONS: relationalStore.TransactionOptions = {
  transactionType: relationalStore.TransactionType.IMMEDIATE
}

export class RemoteOperationApplier {
  static async apply(userId: string, operations: Array<RemoteSyncOperation>,
    nextCursor: string): Promise<void> {
    const ordered: Array<RemoteSyncOperation> = operations.slice()
    ordered.sort((left: RemoteSyncOperation, right: RemoteSyncOperation): number =>
      SyncSequence.compare(left.serverSequence, right.serverSequence))
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction(WRITE_TRANSACTION_OPTIONS)
    try {
      for (let index: number = 0; index < ordered.length; index++) {
        await RemoteOperationApplier.applyOperation(transaction, ordered[index])
      }
      await SyncOutboxService.saveCursor(userId, nextCursor, transaction)
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to apply remote synchronization operations')
    }
  }

  private static async applyOperation(transaction: relationalStore.Transaction,
    operation: RemoteSyncOperation): Promise<void> {
    if (operation.entityType === SyncEntityType.QUESTION_BANK) {
      await RemoteOperationApplier.applyBank(transaction, operation)
    } else if (operation.entityType === SyncEntityType.QUESTION) {
      await RemoteOperationApplier.applyQuestion(transaction, operation)
    } else if (operation.entityType === SyncEntityType.WRONG_QUESTION) {
      await RemoteOperationApplier.applyWrongQuestion(transaction, operation)
    }
  }

  private static async applyBank(transaction: relationalStore.Transaction,
    operation: RemoteSyncOperation): Promise<void> {
    let localId: string = await SyncIdentityService.localId(
      SyncEntityType.QUESTION_BANK, operation.entityId, transaction)
    if (operation.operationType === SyncOperationType.DELETE) {
      if (localId.length > 0) {
        await RemoteOperationApplier.deleteBank(transaction, localId)
      }
      return
    }
    if (localId.length === 0) {
      localId = IdUtils.create('bank_')
      await SyncIdentityService.bindRemote(
        SyncEntityType.QUESTION_BANK, localId, operation.entityId, transaction)
    }
    const payload: SyncPayloadData = operation.payload
    const values: Array<relationalStore.ValueType> = [
      localId, payload.name === undefined || payload.name === null ? '云端题库' : payload.name,
      payload.subject === undefined || payload.subject === null ? '未分类' : payload.subject, Date.now()
    ]
    await transaction.execute(
      'INSERT INTO question_bank(id, bank_name, subject, question_count, create_time, is_sample) ' +
      'VALUES (?, ?, ?, 0, ?, 0) ON CONFLICT(id) DO UPDATE SET ' +
      'bank_name = excluded.bank_name, subject = excluded.subject', values)
  }

  private static async applyQuestion(transaction: relationalStore.Transaction,
    operation: RemoteSyncOperation): Promise<void> {
    let localId: string = await SyncIdentityService.localId(
      SyncEntityType.QUESTION, operation.entityId, transaction)
    if (operation.operationType === SyncOperationType.DELETE) {
      if (localId.length > 0) {
        await RemoteOperationApplier.deleteQuestion(transaction, localId)
      }
      return
    }
    const payload: SyncPayloadData = operation.payload
    const bankClientId: string = payload.bankClientId === undefined || payload.bankClientId === null ?
      '' : payload.bankClientId
    const bankLocalId: string = await SyncIdentityService.localId(
      SyncEntityType.QUESTION_BANK, bankClientId, transaction)
    if (bankLocalId.length === 0) {
      throw new Error('Remote question references an unknown question bank')
    }
    if (localId.length === 0) {
      localId = IdUtils.create('question_')
      await SyncIdentityService.bindRemote(SyncEntityType.QUESTION, localId, operation.entityId, transaction)
    }
    const values: Array<relationalStore.ValueType> = [
      localId, bankLocalId,
      payload.type === undefined || payload.type === null ? 'single_choice' : payload.type,
      payload.question === undefined || payload.question === null ? '未命名题目' : payload.question,
      RemoteOperationApplier.optionsJson(payload.options),
      payload.answer === undefined || payload.answer === null ? '' : payload.answer,
      payload.analysis === undefined || payload.analysis === null ? '' : payload.analysis
    ]
    await transaction.execute(
      'INSERT INTO question(id, bank_id, type, content, options_json, answer, analysis, ' +
      "source_page_start, source_page_end, review_state) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 'confirmed') " +
      'ON CONFLICT(id) DO UPDATE SET bank_id = excluded.bank_id, type = excluded.type, ' +
      'content = excluded.content, options_json = excluded.options_json, answer = excluded.answer, ' +
      'analysis = excluded.analysis', values)
    await RemoteOperationApplier.refreshBankCount(transaction, bankLocalId)
  }

  private static async applyWrongQuestion(transaction: relationalStore.Transaction,
    operation: RemoteSyncOperation): Promise<void> {
    const questionLocalId: string = await SyncIdentityService.localId(
      SyncEntityType.QUESTION, operation.entityId, transaction)
    if (questionLocalId.length === 0) {
      if (operation.operationType === SyncOperationType.DELETE) {
        return
      }
      throw new Error('Remote wrong question references an unknown question')
    }
    if (operation.operationType === SyncOperationType.DELETE) {
      const args: Array<relationalStore.ValueType> = [questionLocalId]
      await transaction.execute('DELETE FROM wrong_question WHERE question_id = ?', args)
      return
    }
    const questionArgs: Array<relationalStore.ValueType> = [questionLocalId]
    const resultSet: relationalStore.ResultSet = await transaction.querySql(
      'SELECT q.bank_id, b.subject FROM question q INNER JOIN question_bank b ON b.id = q.bank_id ' +
      'WHERE q.id = ? LIMIT 1', questionArgs)
    let bankId: string = ''
    let subject: string = ''
    try {
      if (!resultSet.goToFirstRow()) {
        throw new Error('Remote wrong question has no local question')
      }
      bankId = resultSet.getString(0)
      subject = resultSet.getString(1)
    } finally {
      resultSet.close()
    }
    const mastered: number = operation.payload.status === 'mastered' ? 1 : 0
    const values: Array<relationalStore.ValueType> = [
      IdUtils.create('wrong_'), questionLocalId, bankId, subject, Date.now(), mastered
    ]
    await transaction.execute(
      "INSERT INTO wrong_question(id, question_id, bank_id, subject, add_time, mastered, user_answer) " +
      "VALUES (?, ?, ?, ?, ?, ?, '') ON CONFLICT(question_id) DO UPDATE SET " +
      'bank_id = excluded.bank_id, subject = excluded.subject, mastered = excluded.mastered', values)
  }

  private static async deleteBank(transaction: relationalStore.Transaction, bankId: string): Promise<void> {
    const args: Array<relationalStore.ValueType> = [bankId]
    const imageResultSet: relationalStore.ResultSet = await transaction.querySql(
      'SELECT qi.image_path FROM question_image qi INNER JOIN question q ON q.id = qi.question_id ' +
      'WHERE q.bank_id = ?', args)
    try {
      while (imageResultSet.goToNextRow()) {
        const debtArgs: Array<relationalStore.ValueType> = [imageResultSet.getString(0), Date.now()]
        await transaction.execute(
          'INSERT OR IGNORE INTO question_image_cleanup_debt(path, create_time) VALUES (?, ?)', debtArgs)
      }
    } finally {
      imageResultSet.close()
    }
    await transaction.execute(
      'DELETE FROM question_image WHERE question_id IN (SELECT id FROM question WHERE bank_id = ?)', args)
    await transaction.execute('DELETE FROM wrong_question WHERE bank_id = ?', args)
    await transaction.execute('DELETE FROM question WHERE bank_id = ?', args)
    await transaction.execute('DELETE FROM question_bank WHERE id = ?', args)
  }

  private static async deleteQuestion(transaction: relationalStore.Transaction,
    questionId: string): Promise<void> {
    const args: Array<relationalStore.ValueType> = [questionId]
    const bankResultSet: relationalStore.ResultSet = await transaction.querySql(
      'SELECT bank_id FROM question WHERE id = ? LIMIT 1', args)
    let bankId: string = ''
    try {
      if (bankResultSet.goToFirstRow()) {
        bankId = bankResultSet.getString(0)
      }
    } finally {
      bankResultSet.close()
    }
    const imageResultSet: relationalStore.ResultSet = await transaction.querySql(
      'SELECT image_path FROM question_image WHERE question_id = ?', args)
    try {
      while (imageResultSet.goToNextRow()) {
        const debtArgs: Array<relationalStore.ValueType> = [imageResultSet.getString(0), Date.now()]
        await transaction.execute(
          'INSERT OR IGNORE INTO question_image_cleanup_debt(path, create_time) VALUES (?, ?)', debtArgs)
      }
    } finally {
      imageResultSet.close()
    }
    await transaction.execute('DELETE FROM question_image WHERE question_id = ?', args)
    await transaction.execute('DELETE FROM wrong_question WHERE question_id = ?', args)
    await transaction.execute('DELETE FROM question WHERE id = ?', args)
    if (bankId.length > 0) {
      await RemoteOperationApplier.refreshBankCount(transaction, bankId)
    }
  }

  private static async refreshBankCount(transaction: relationalStore.Transaction,
    bankId: string): Promise<void> {
    const args: Array<relationalStore.ValueType> = [bankId]
    await transaction.execute(
      'UPDATE question_bank SET question_count = (SELECT COUNT(*) FROM question WHERE bank_id = ?) ' +
      'WHERE id = ?', [bankId, bankId])
  }

  private static optionsJson(options: Record<string, string> | null | undefined): string {
    if (options === undefined || options === null) {
      return '[]'
    }
    const keys: Array<string> = Object.keys(options)
    keys.sort((left: string, right: string): number => Number(left) - Number(right))
    const values: Array<string> = new Array<string>()
    for (let index: number = 0; index < keys.length; index++) {
      values.push(options[keys[index]])
    }
    return JSON.stringify(values)
  }
}
