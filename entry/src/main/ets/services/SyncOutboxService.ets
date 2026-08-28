import { util } from '@kit.ArkTS'
import { relationalStore } from '@kit.ArkData'
import {
  SyncEntityType,
  SyncOperationType,
  SyncOutboxOperation,
  SyncOutboxPolicy
} from '../models/SyncModels'
import { DatabaseService } from './DatabaseService'

const WRITE_TRANSACTION_OPTIONS: relationalStore.TransactionOptions = {
  transactionType: relationalStore.TransactionType.IMMEDIATE
}

export class SyncOutboxService {
  static async enqueue(entityType: SyncEntityType, entityUuid: string, operationType: SyncOperationType,
    payloadJson: string, transaction?: relationalStore.Transaction): Promise<string> {
    if (entityUuid.trim().length === 0) {
      throw new Error('Synchronization entity UUID cannot be empty')
    }
    if (transaction !== undefined) {
      return SyncOutboxService.enqueueInTransaction(
        transaction, entityType, entityUuid, operationType, payloadJson)
    }
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const owned: relationalStore.Transaction = await store.createTransaction(WRITE_TRANSACTION_OPTIONS)
    try {
      const operationId: string = await SyncOutboxService.enqueueInTransaction(
        owned, entityType, entityUuid, operationType, payloadJson)
      await owned.commit()
      return operationId
    } catch (err) {
      try {
        await owned.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to enqueue synchronization operation')
    }
  }

  static async pending(limit: number = 100): Promise<Array<SyncOutboxOperation>> {
    const safeLimit: number = Math.max(1, Math.min(500, Math.trunc(limit)))
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [safeLimit]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT operation_id, entity_type, entity_uuid, operation_type, payload_json, create_time ' +
      'FROM sync_outbox ORDER BY create_time ASC, rowid ASC LIMIT ?', args)
    const operations: Array<SyncOutboxOperation> = new Array<SyncOutboxOperation>()
    try {
      while (resultSet.goToNextRow()) {
        operations.push(new SyncOutboxOperation(
          resultSet.getString(0), resultSet.getString(1) as SyncEntityType, resultSet.getString(2),
          resultSet.getString(3) as SyncOperationType, resultSet.getString(4), resultSet.getLong(5)))
      }
      return operations
    } finally {
      resultSet.close()
    }
  }

  static async acknowledge(operationIds: Array<string>,
    transaction?: relationalStore.Transaction): Promise<void> {
    if (operationIds.length === 0) {
      return
    }
    if (transaction !== undefined) {
      await SyncOutboxService.deleteOperations(transaction, operationIds)
      return
    }
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const owned: relationalStore.Transaction = await store.createTransaction(WRITE_TRANSACTION_OPTIONS)
    try {
      await SyncOutboxService.deleteOperations(owned, operationIds)
      await owned.commit()
    } catch (err) {
      try {
        await owned.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to acknowledge synchronization operations')
    }
  }

  static async cursor(userId: string): Promise<string> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [userId]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT cursor FROM sync_state WHERE user_id = ? LIMIT 1', args)
    try {
      return resultSet.goToFirstRow() ? resultSet.getString(0) : '0'
    } finally {
      resultSet.close()
    }
  }

  static async saveCursor(userId: string, cursor: string,
    transaction: relationalStore.Transaction): Promise<void> {
    const args: Array<relationalStore.ValueType> = [userId, cursor, Date.now()]
    await transaction.execute(
      'INSERT INTO sync_state(user_id, cursor, update_time) VALUES (?, ?, ?) ' +
      'ON CONFLICT(user_id) DO UPDATE SET cursor = excluded.cursor, update_time = excluded.update_time', args)
  }

  private static async enqueueInTransaction(transaction: relationalStore.Transaction,
    entityType: SyncEntityType, entityUuid: string, incomingType: SyncOperationType,
    payloadJson: string): Promise<string> {
    const lookupArgs: Array<relationalStore.ValueType> = [entityType, entityUuid]
    const resultSet: relationalStore.ResultSet = await transaction.querySql(
      'SELECT operation_id, operation_type FROM sync_outbox ' +
      'WHERE entity_type = ? AND entity_uuid = ? LIMIT 1', lookupArgs)
    let previousId: string = ''
    let previousType: SyncOperationType = SyncOperationType.UPSERT
    try {
      if (resultSet.goToFirstRow()) {
        previousId = resultSet.getString(0)
        previousType = resultSet.getString(1) as SyncOperationType
      }
    } finally {
      resultSet.close()
    }

    const operationId: string = util.generateRandomUUID()
    const compactedType: SyncOperationType =
      SyncOutboxPolicy.compactedOperation(previousType, incomingType)
    const normalizedPayload: string = compactedType === SyncOperationType.DELETE ? '{}' : payloadJson
    const createTime: number = Date.now()
    if (previousId.length > 0) {
      const updateArgs: Array<relationalStore.ValueType> = [
        operationId, compactedType, normalizedPayload, createTime, entityType, entityUuid
      ]
      await transaction.execute(
        'UPDATE sync_outbox SET operation_id = ?, operation_type = ?, payload_json = ?, create_time = ? ' +
        'WHERE entity_type = ? AND entity_uuid = ?', updateArgs)
      return operationId
    }

    const values: relationalStore.ValuesBucket = {
      operation_id: operationId,
      entity_type: entityType,
      entity_uuid: entityUuid,
      operation_type: compactedType,
      payload_json: normalizedPayload,
      create_time: createTime
    }
    const rowId: number = await transaction.insert('sync_outbox', values)
    if (rowId < 0) {
      throw new Error('Failed to insert synchronization operation')
    }
    return operationId
  }

  private static async deleteOperations(transaction: relationalStore.Transaction,
    operationIds: Array<string>): Promise<void> {
    for (const operationId of operationIds) {
      const args: Array<relationalStore.ValueType> = [operationId]
      await transaction.execute('DELETE FROM sync_outbox WHERE operation_id = ?', args)
    }
  }
}
