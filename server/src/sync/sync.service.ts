import { BadRequestException, Inject, Injectable } from '@nestjs/common';
import { isUUID } from 'class-validator';
import {
  PullResult,
  StoredSyncOperation,
  SYNC_STORE,
  SyncEntityType,
  SyncOperationInput,
  SyncOperationType,
  SyncStore
} from './sync.contracts';

const ENTITY_TYPES: SyncEntityType[] = [
  'question_bank',
  'question',
  'wrong_question',
  'review_record'
];
const OPERATION_TYPES: SyncOperationType[] = ['upsert', 'delete'];

function requirePayloadString(
  payload: Record<string, unknown>,
  key: string,
  maximumLength?: number
): string {
  const value = payload[key];
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new BadRequestException(`${key} is required`);
  }
  const trimmed = value.trim();
  if (maximumLength !== undefined && trimmed.length > maximumLength) {
    throw new BadRequestException(`${key} must contain at most ${maximumLength} characters`);
  }
  return trimmed;
}

function optionalPayloadString(
  payload: Record<string, unknown>,
  key: string,
  maximumLength: number
): void {
  const value = payload[key];
  if (value === undefined || value === null) {
    return;
  }
  if (typeof value !== 'string' || value.length > maximumLength) {
    throw new BadRequestException(`${key} must contain at most ${maximumLength} characters`);
  }
}

@Injectable()
export class SyncService {
  constructor(@Inject(SYNC_STORE) private readonly store: SyncStore) {}

  async push(
    userId: string,
    operations: SyncOperationInput[]
  ): Promise<{ operations: StoredSyncOperation[] }> {
    if (operations.length > 100) {
      throw new BadRequestException('A sync push may contain at most 100 operations');
    }
    const seen = new Set<string>();
    for (const operation of operations) {
      this.validateOperation(operation);
      if (seen.has(operation.operationId)) {
        throw new BadRequestException('A sync push cannot repeat an operationId');
      }
      seen.add(operation.operationId);
    }
    return { operations: await this.store.apply(userId, operations) };
  }

  async pull(userId: string, cursor: string, requestedLimit: number): Promise<PullResult> {
    if (!/^\d+$/.test(cursor)) {
      throw new BadRequestException('Sync cursor must be a non-negative integer');
    }
    if (BigInt(cursor) > 18_446_744_073_709_551_615n) {
      throw new BadRequestException('Sync cursor exceeds the supported range');
    }
    if (!Number.isFinite(requestedLimit)) {
      throw new BadRequestException('Sync limit must be a finite number');
    }
    const limit = Math.max(1, Math.min(200, Math.trunc(requestedLimit)));
    return this.store.pull(userId, cursor, limit);
  }

  private validateOperation(operation: SyncOperationInput): void {
    if (!isUUID(operation.operationId) || !isUUID(operation.entityId)) {
      throw new BadRequestException('Sync operation and entity identifiers must be UUIDs');
    }
    if (!ENTITY_TYPES.includes(operation.entityType)) {
      throw new BadRequestException('Unsupported sync entity type');
    }
    if (!OPERATION_TYPES.includes(operation.operationType)) {
      throw new BadRequestException('Unsupported sync operation type');
    }
    if (
      typeof operation.payload !== 'object' ||
      operation.payload === null ||
      Array.isArray(operation.payload)
    ) {
      throw new BadRequestException('Sync operation payload must be an object');
    }
    if (operation.entityType === 'review_record' && operation.operationType === 'delete') {
      throw new BadRequestException('Review records are append-only');
    }
    if (
      operation.entityType === 'review_record' &&
      operation.operationId !== operation.entityId
    ) {
      throw new BadRequestException('Review operationId must equal entityId');
    }
    if (
      operation.entityType === 'wrong_question' &&
      operation.payload.questionClientId !== undefined &&
      operation.payload.questionClientId !== operation.entityId
    ) {
      throw new BadRequestException('Wrong-question questionClientId must equal entityId');
    }
    if (operation.operationType === 'delete') {
      return;
    }
    switch (operation.entityType) {
      case 'question_bank':
        requirePayloadString(operation.payload, 'name', 255);
        requirePayloadString(operation.payload, 'subject', 64);
        return;
      case 'question': {
        const bankClientId = requirePayloadString(operation.payload, 'bankClientId', 36);
        if (!isUUID(bankClientId)) {
          throw new BadRequestException('bankClientId must be a UUID');
        }
        optionalPayloadString(operation.payload, 'type', 32);
        requirePayloadString(operation.payload, 'question');
        return;
      }
      case 'wrong_question':
        requirePayloadString(operation.payload, 'status', 24);
        return;
      case 'review_record': {
        const questionClientId = requirePayloadString(
          operation.payload,
          'questionClientId',
          36
        );
        if (!isUUID(questionClientId)) {
          throw new BadRequestException('questionClientId must be a UUID');
        }
        requirePayloadString(operation.payload, 'result', 24);
        const reviewedAt = new Date(requirePayloadString(operation.payload, 'reviewedAt'));
        if (Number.isNaN(reviewedAt.getTime())) {
          throw new BadRequestException('reviewedAt must be an ISO date');
        }
        return;
      }
    }
  }
}
