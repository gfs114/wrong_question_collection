export const SYNC_STORE = Symbol('SYNC_STORE');

export type SyncEntityType =
  | 'question_bank'
  | 'question'
  | 'wrong_question'
  | 'review_record';

export type SyncOperationType = 'upsert' | 'delete';

export interface SyncOperationInput {
  operationId: string;
  entityType: SyncEntityType;
  entityId: string;
  operationType: SyncOperationType;
  payload: Record<string, unknown>;
}

export interface StoredSyncOperation extends SyncOperationInput {
  serverSequence: string;
}

export interface PullResult {
  operations: StoredSyncOperation[];
  nextCursor: string;
  hasMore: boolean;
}

export interface SyncStore {
  apply(userId: string, operations: SyncOperationInput[]): Promise<StoredSyncOperation[]>;
  pull(userId: string, cursor: string, limit: number): Promise<PullResult>;
}
