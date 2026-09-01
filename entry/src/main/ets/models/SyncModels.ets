export enum SyncEntityType {
  QUESTION_BANK = 'question_bank',
  QUESTION = 'question',
  WRONG_QUESTION = 'wrong_question',
  REVIEW_RECORD = 'review_record'
}

export enum SyncOperationType {
  UPSERT = 'upsert',
  DELETE = 'delete'
}

export class SyncIdentity {
  entityType: SyncEntityType
  localId: string
  clientUuid: string

  constructor(entityType: SyncEntityType, localId: string, clientUuid: string) {
    this.entityType = entityType
    this.localId = localId
    this.clientUuid = clientUuid
  }
}

export class SyncOutboxOperation {
  operationId: string
  entityType: SyncEntityType
  entityUuid: string
  operationType: SyncOperationType
  payloadJson: string
  createTime: number

  constructor(operationId: string, entityType: SyncEntityType, entityUuid: string,
    operationType: SyncOperationType, payloadJson: string, createTime: number) {
    this.operationId = operationId
    this.entityType = entityType
    this.entityUuid = entityUuid
    this.operationType = operationType
    this.payloadJson = payloadJson
    this.createTime = createTime
  }
}

export class SyncOutboxPolicy {
  static compactedOperation(previous: SyncOperationType, incoming: SyncOperationType): SyncOperationType {
    if (incoming === SyncOperationType.DELETE) {
      return SyncOperationType.DELETE
    }
    return SyncOperationType.UPSERT
  }
}

export interface SyncPayloadData {
  name?: string | null
  subject?: string | null
  bankClientId?: string | null
  type?: string | null
  question?: string | null
  options?: Record<string, string> | null
  answer?: string | null
  analysis?: string | null
  status?: string | null
}

export interface RemoteSyncOperation {
  operationId: string
  entityType: SyncEntityType
  entityId: string
  operationType: SyncOperationType
  payload: SyncPayloadData
  serverSequence: string
}

export interface SyncPushResponse {
  operations: Array<RemoteSyncOperation>
}

export interface SyncPullResponse {
  operations: Array<RemoteSyncOperation>
  nextCursor: string
  hasMore: boolean
}

export class SyncPushOperation {
  operationId: string
  entityType: SyncEntityType
  entityId: string
  operationType: SyncOperationType
  payload: object

  constructor(source: SyncOutboxOperation) {
    this.operationId = source.operationId
    this.entityType = source.entityType
    this.entityId = source.entityUuid
    this.operationType = source.operationType
    this.payload = JSON.parse(source.payloadJson) as object
  }
}

export class SyncPushBody {
  operations: Array<SyncPushOperation>

  constructor(operations: Array<SyncPushOperation>) {
    this.operations = operations
  }
}

export enum SyncDisplayState {
  LOCAL = 'local',
  SYNCING = 'syncing',
  SYNCED = 'synced',
  PENDING = 'pending',
  FAILED = 'failed'
}

export class CloudSyncResult {
  state: SyncDisplayState
  pushedCount: number
  pulledCount: number

  constructor(state: SyncDisplayState, pushedCount: number = 0, pulledCount: number = 0) {
    this.state = state
    this.pushedCount = pushedCount
    this.pulledCount = pulledCount
  }
}

export class SyncSequence {
  static compare(left: string, right: string): number {
    const normalizedLeft: string = SyncSequence.normalize(left)
    const normalizedRight: string = SyncSequence.normalize(right)
    if (normalizedLeft.length !== normalizedRight.length) {
      return normalizedLeft.length - normalizedRight.length
    }
    if (normalizedLeft === normalizedRight) {
      return 0
    }
    return normalizedLeft < normalizedRight ? -1 : 1
  }

  private static normalize(value: string): string {
    let index: number = 0
    while (index < value.length - 1 && value.charAt(index) === '0') {
      index++
    }
    return value.substring(index)
  }
}
