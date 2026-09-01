import { Context } from '@kit.AbilityKit'
import { preferences, relationalStore } from '@kit.ArkData'
import { SyncEntityType, SyncOperationType } from '../models/SyncModels'
import { DatabaseService } from './DatabaseService'
import { SyncIdentityService } from './SyncIdentityService'
import { SyncOutboxService } from './SyncOutboxService'
import { SyncPayloadFactory } from './SyncPayloadFactory'

const PREFERENCES_NAME: string = 'sync_bootstrap'
const LEGACY_TEXT_BACKFILL_KEY: string = 'legacy_text_backfill_v1'
const WRITE_TRANSACTION_OPTIONS: relationalStore.TransactionOptions = {
  transactionType: relationalStore.TransactionType.IMMEDIATE
}

class LegacyBankRow {
  localId: string
  name: string
  subject: string

  constructor(localId: string, name: string, subject: string) {
    this.localId = localId
    this.name = name
    this.subject = subject
  }
}

class LegacyQuestionRow {
  localId: string
  bankLocalId: string
  type: string
  content: string
  optionsJson: string
  answer: string
  analysis: string

  constructor(localId: string, bankLocalId: string, type: string, content: string,
    optionsJson: string, answer: string, analysis: string) {
    this.localId = localId
    this.bankLocalId = bankLocalId
    this.type = type
    this.content = content
    this.optionsJson = optionsJson
    this.answer = answer
    this.analysis = analysis
  }
}

class LegacyWrongQuestionRow {
  questionLocalId: string
  mastered: boolean

  constructor(questionLocalId: string, mastered: boolean) {
    this.questionLocalId = questionLocalId
    this.mastered = mastered
  }
}

/**
 * Recovery-compatible legacy backfill retained after the server-first
 * cutover. Production startup no longer calls enqueueLegacyLocalText: legacy
 * text now moves to the cloud only through the opt-in
 * LegacyCloudMigrationService. The outbox rows this helper could create and
 * the v5 legacy tables remain preserved for migration recovery.
 */
export class SyncBootstrapService {
  static async enqueueLegacyLocalText(context: Context): Promise<void> {
    const state: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const completed: preferences.ValueType = await state.get(LEGACY_TEXT_BACKFILL_KEY, false)
    if (completed === true) {
      return
    }

    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction(WRITE_TRANSACTION_OPTIONS)
    try {
      await SyncBootstrapService.enqueueBanks(transaction)
      await SyncBootstrapService.enqueueQuestions(transaction)
      await SyncBootstrapService.enqueueWrongQuestions(transaction)
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to enqueue legacy local text for synchronization')
    }

    await state.put(LEGACY_TEXT_BACKFILL_KEY, true)
    await state.flush()
  }

  private static async enqueueBanks(transaction: relationalStore.Transaction): Promise<void> {
    const rows: Array<LegacyBankRow> = new Array<LegacyBankRow>()
    const resultSet: relationalStore.ResultSet = await transaction.querySql(
      "SELECT b.id, b.bank_name, b.subject FROM question_bank b " +
      "LEFT JOIN sync_identity i ON i.entity_type = 'question_bank' AND i.local_id = b.id " +
      'WHERE b.is_sample = 0 AND i.client_uuid IS NULL ORDER BY b.rowid ASC')
    try {
      while (resultSet.goToNextRow()) {
        rows.push(new LegacyBankRow(resultSet.getString(0), resultSet.getString(1), resultSet.getString(2)))
      }
    } finally {
      resultSet.close()
    }
    for (let index: number = 0; index < rows.length; index++) {
      const row: LegacyBankRow = rows[index]
      const clientUuid: string = await SyncIdentityService.clientUuid(
        SyncEntityType.QUESTION_BANK, row.localId, transaction)
      await SyncOutboxService.enqueue(SyncEntityType.QUESTION_BANK, clientUuid, SyncOperationType.UPSERT,
        SyncPayloadFactory.bankPayload(row.name, row.subject), transaction)
    }
  }

  private static async enqueueQuestions(transaction: relationalStore.Transaction): Promise<void> {
    const rows: Array<LegacyQuestionRow> = new Array<LegacyQuestionRow>()
    const resultSet: relationalStore.ResultSet = await transaction.querySql(
      "SELECT q.id, q.bank_id, q.type, q.content, q.options_json, q.answer, q.analysis " +
      'FROM question q INNER JOIN question_bank b ON b.id = q.bank_id ' +
      "LEFT JOIN sync_identity i ON i.entity_type = 'question' AND i.local_id = q.id " +
      'WHERE b.is_sample = 0 AND i.client_uuid IS NULL ORDER BY q.rowid ASC')
    try {
      while (resultSet.goToNextRow()) {
        rows.push(new LegacyQuestionRow(
          resultSet.getString(0), resultSet.getString(1), resultSet.getString(2), resultSet.getString(3),
          resultSet.getString(4), resultSet.getString(5), resultSet.getString(6)))
      }
    } finally {
      resultSet.close()
    }
    for (let index: number = 0; index < rows.length; index++) {
      const row: LegacyQuestionRow = rows[index]
      const bankUuid: string = await SyncIdentityService.clientUuid(
        SyncEntityType.QUESTION_BANK, row.bankLocalId, transaction)
      const questionUuid: string = await SyncIdentityService.clientUuid(
        SyncEntityType.QUESTION, row.localId, transaction)
      const options: Array<string> = JSON.parse(row.optionsJson) as Array<string>
      const payload: string = SyncPayloadFactory.questionFieldsPayload(
        row.type, row.content, options, row.answer, row.analysis, bankUuid)
      await SyncOutboxService.enqueue(
        SyncEntityType.QUESTION, questionUuid, SyncOperationType.UPSERT, payload, transaction)
    }
  }

  private static async enqueueWrongQuestions(transaction: relationalStore.Transaction): Promise<void> {
    const rows: Array<LegacyWrongQuestionRow> = new Array<LegacyWrongQuestionRow>()
    const resultSet: relationalStore.ResultSet = await transaction.querySql(
      'SELECT w.question_id, w.mastered FROM wrong_question w ' +
      'INNER JOIN question_bank b ON b.id = w.bank_id WHERE b.is_sample = 0 ORDER BY w.rowid ASC')
    try {
      while (resultSet.goToNextRow()) {
        rows.push(new LegacyWrongQuestionRow(resultSet.getString(0), resultSet.getLong(1) === 1))
      }
    } finally {
      resultSet.close()
    }
    for (let index: number = 0; index < rows.length; index++) {
      const row: LegacyWrongQuestionRow = rows[index]
      const questionUuid: string = await SyncIdentityService.clientUuid(
        SyncEntityType.QUESTION, row.questionLocalId, transaction)
      await SyncOutboxService.enqueue(
        SyncEntityType.WRONG_QUESTION, questionUuid, SyncOperationType.UPSERT,
        SyncPayloadFactory.wrongQuestionPayload(row.mastered), transaction)
    }
  }
}
