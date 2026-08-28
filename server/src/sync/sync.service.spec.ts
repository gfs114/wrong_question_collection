import { BadRequestException } from '@nestjs/common';
import {
  PullResult,
  StoredSyncOperation,
  SyncOperationInput,
  SyncStore
} from './sync.contracts';
import { SyncService } from './sync.service';

class InMemorySyncStore implements SyncStore {
  readonly accepted: Array<{ userId: string; operation: SyncOperationInput }> = [];

  async apply(userId: string, operations: SyncOperationInput[]): Promise<StoredSyncOperation[]> {
    return operations.map((operation, index) => {
      this.accepted.push({ userId, operation });
      return { ...operation, serverSequence: String(index + 1) };
    });
  }

  async pull(_userId: string, cursor: string, limit: number): Promise<PullResult> {
    return { operations: [], nextCursor: cursor, hasMore: limit === 200 };
  }
}

const operation = (operationId: string): SyncOperationInput => ({
  operationId,
  entityType: 'question_bank',
  entityId: '22222222-2222-4222-8222-222222222222',
  operationType: 'upsert',
  payload: { name: '数学题库', subject: '数学' }
});

describe('SyncService', () => {
  it('applies a validated batch under the authenticated user only', async () => {
    const store = new InMemorySyncStore();
    const service = new SyncService(store);

    const result = await service.push('server-user-1', [
      operation('11111111-1111-4111-8111-111111111111')
    ]);

    expect(result).toEqual({
      operations: [
        {
          ...operation('11111111-1111-4111-8111-111111111111'),
          serverSequence: '1'
        }
      ]
    });
    expect(store.accepted[0].userId).toBe('server-user-1');
  });

  it('rejects duplicate operation identifiers in one request', async () => {
    const service = new SyncService(new InMemorySyncStore());
    const duplicate = operation('11111111-1111-4111-8111-111111111111');

    await expect(service.push('user-1', [duplicate, duplicate])).rejects.toBeInstanceOf(
      BadRequestException
    );
  });

  it('rejects an oversized push batch', async () => {
    const service = new SyncService(new InMemorySyncStore());
    const operations = Array.from({ length: 101 }, (_, index) =>
      operation(`11111111-1111-4111-8111-${String(index).padStart(12, '0')}`)
    );

    await expect(service.push('user-1', operations)).rejects.toThrow(
      'A sync push may contain at most 100 operations'
    );
  });

  it('keeps review records append-only', async () => {
    const service = new SyncService(new InMemorySyncStore());
    const review: SyncOperationInput = {
      ...operation('11111111-1111-4111-8111-111111111111'),
      entityType: 'review_record',
      operationType: 'delete'
    };

    await expect(service.push('user-1', [review])).rejects.toThrow(
      'Review records are append-only'
    );
  });

  it('binds an append-only review entity to its operation identifier', async () => {
    const service = new SyncService(new InMemorySyncStore());
    const review: SyncOperationInput = {
      ...operation('11111111-1111-4111-8111-111111111111'),
      entityType: 'review_record',
      entityId: '22222222-2222-4222-8222-222222222222',
      payload: {
        questionClientId: '33333333-3333-4333-8333-333333333333',
        result: 'correct',
        reviewedAt: '2026-08-24T08:00:00.000Z'
      }
    };

    await expect(service.push('user-1', [review])).rejects.toThrow(
      'Review operationId must equal entityId'
    );
  });

  it('rejects a wrong-question payload that contradicts entityId', async () => {
    const service = new SyncService(new InMemorySyncStore());
    const wrongQuestion: SyncOperationInput = {
      ...operation('11111111-1111-4111-8111-111111111111'),
      entityType: 'wrong_question',
      payload: {
        questionClientId: '33333333-3333-4333-8333-333333333333',
        status: 'pending'
      }
    };

    await expect(service.push('user-1', [wrongQuestion])).rejects.toThrow(
      'Wrong-question questionClientId must equal entityId'
    );
  });

  it('caps pull pages at 200 operations', async () => {
    const service = new SyncService(new InMemorySyncStore());

    await expect(service.pull('user-1', '10', 500)).resolves.toEqual({
      operations: [],
      nextCursor: '10',
      hasMore: true
    });
  });

  it('rejects a non-numeric pull limit and an oversized cursor', async () => {
    const service = new SyncService(new InMemorySyncStore());

    await expect(service.pull('user-1', '0', Number.NaN)).rejects.toThrow(
      'Sync limit must be a finite number'
    );
    await expect(service.pull('user-1', '18446744073709551616', 100)).rejects.toThrow(
      'Sync cursor exceeds the supported range'
    );
  });

  it('rejects entity fields that exceed the MySQL schema before writing', async () => {
    const service = new SyncService(new InMemorySyncStore());
    const bank = operation('11111111-1111-4111-8111-111111111111');
    bank.payload.name = 'x'.repeat(256);

    await expect(service.push('user-1', [bank])).rejects.toThrow(
      'name must contain at most 255 characters'
    );
  });

  it('validates payload shape before entity-specific fields', async () => {
    const service = new SyncService(new InMemorySyncStore());
    const wrongQuestion = {
      ...operation('11111111-1111-4111-8111-111111111111'),
      entityType: 'wrong_question',
      payload: []
    } as unknown as SyncOperationInput;

    await expect(service.push('user-1', [wrongQuestion])).rejects.toThrow(
      'Sync operation payload must be an object'
    );
  });
});
