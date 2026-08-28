import { util } from '@kit.ArkTS'
import { relationalStore } from '@kit.ArkData'
import { SyncEntityType, SyncIdentity } from '../models/SyncModels'
import { DatabaseService } from './DatabaseService'

const WRITE_TRANSACTION_OPTIONS: relationalStore.TransactionOptions = {
  transactionType: relationalStore.TransactionType.IMMEDIATE
}

export class SyncIdentityService {
  static async clientUuid(entityType: SyncEntityType, localId: string,
    transaction?: relationalStore.Transaction): Promise<string> {
    SyncIdentityService.requireId(localId)
    if (transaction !== undefined) {
      return SyncIdentityService.findOrCreate(transaction, entityType, localId)
    }
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const owned: relationalStore.Transaction = await store.createTransaction(WRITE_TRANSACTION_OPTIONS)
    try {
      const clientUuid: string = await SyncIdentityService.findOrCreate(owned, entityType, localId)
      await owned.commit()
      return clientUuid
    } catch (err) {
      try {
        await owned.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Failed to create synchronization identity')
    }
  }

  static async localId(entityType: SyncEntityType, clientUuid: string,
    transaction?: relationalStore.Transaction): Promise<string> {
    SyncIdentityService.requireId(clientUuid)
    if (transaction !== undefined) {
      return SyncIdentityService.findLocalId(transaction, entityType, clientUuid)
    }
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [entityType, clientUuid]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT local_id FROM sync_identity WHERE entity_type = ? AND client_uuid = ? LIMIT 1', args)
    try {
      return resultSet.goToFirstRow() ? resultSet.getString(0) : ''
    } finally {
      resultSet.close()
    }
  }

  static async bindRemote(entityType: SyncEntityType, localId: string, clientUuid: string,
    transaction: relationalStore.Transaction): Promise<SyncIdentity> {
    SyncIdentityService.requireId(localId)
    SyncIdentityService.requireId(clientUuid)
    const existingUuid: string = await SyncIdentityService.findClientUuid(transaction, entityType, localId)
    if (existingUuid.length > 0 && existingUuid !== clientUuid) {
      throw new Error('Local synchronization identity is already bound')
    }
    const existingLocalId: string = await SyncIdentityService.findLocalId(transaction, entityType, clientUuid)
    if (existingLocalId.length > 0 && existingLocalId !== localId) {
      throw new Error('Remote synchronization identity is already bound')
    }
    if (existingUuid.length === 0) {
      const values: relationalStore.ValuesBucket = {
        entity_type: entityType,
        local_id: localId,
        client_uuid: clientUuid
      }
      const rowId: number = await transaction.insert('sync_identity', values)
      if (rowId < 0) {
        throw new Error('Failed to bind synchronization identity')
      }
    }
    return new SyncIdentity(entityType, localId, clientUuid)
  }

  private static async findOrCreate(transaction: relationalStore.Transaction,
    entityType: SyncEntityType, localId: string): Promise<string> {
    const existing: string = await SyncIdentityService.findClientUuid(transaction, entityType, localId)
    if (existing.length > 0) {
      return existing
    }
    const generated: string = util.generateRandomUUID()
    const values: relationalStore.ValuesBucket = {
      entity_type: entityType,
      local_id: localId,
      client_uuid: generated
    }
    const rowId: number = await transaction.insert('sync_identity', values)
    if (rowId < 0) {
      throw new Error('Failed to insert synchronization identity')
    }
    return generated
  }

  private static async findClientUuid(transaction: relationalStore.Transaction,
    entityType: SyncEntityType, localId: string): Promise<string> {
    const args: Array<relationalStore.ValueType> = [entityType, localId]
    const resultSet: relationalStore.ResultSet = await transaction.querySql(
      'SELECT client_uuid FROM sync_identity WHERE entity_type = ? AND local_id = ? LIMIT 1', args)
    try {
      return resultSet.goToFirstRow() ? resultSet.getString(0) : ''
    } finally {
      resultSet.close()
    }
  }

  private static async findLocalId(transaction: relationalStore.Transaction,
    entityType: SyncEntityType, clientUuid: string): Promise<string> {
    const args: Array<relationalStore.ValueType> = [entityType, clientUuid]
    const resultSet: relationalStore.ResultSet = await transaction.querySql(
      'SELECT local_id FROM sync_identity WHERE entity_type = ? AND client_uuid = ? LIMIT 1', args)
    try {
      return resultSet.goToFirstRow() ? resultSet.getString(0) : ''
    } finally {
      resultSet.close()
    }
  }

  private static requireId(value: string): void {
    if (value.trim().length === 0) {
      throw new Error('Synchronization identity cannot be empty')
    }
  }
}
