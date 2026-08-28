import { DataSource } from 'typeorm';
import {
  QuestionBankEntity,
  QuestionEntity,
  ReviewRecordEntity,
  SyncOperationEntity,
  UserEntity,
  WrongQuestionEntity
} from './entities';
import { TypeOrmSyncStore } from './typeorm-sync.store';
import { SyncOperationInput } from '../sync/sync.contracts';

const operation = (
  entityType: SyncOperationInput['entityType'],
  payload: Record<string, unknown>
): SyncOperationInput => ({
  operationId: '11111111-1111-4111-8111-111111111111',
  entityType,
  entityId: '22222222-2222-4222-8222-222222222222',
  operationType: 'upsert',
  payload
});

describe('TypeOrmSyncStore', () => {
  it.each([
    [
      'question_bank',
      { name: '数学题库', subject: '数学' },
      QuestionBankEntity
    ],
    [
      'question',
      {
        bankClientId: '33333333-3333-4333-8333-333333333333',
        type: 'single_choice',
        question: '1 + 1 = ?',
        options: { A: '1', B: '2' },
        answer: 'B',
        analysis: '基础计算'
      },
      QuestionEntity
    ],
    ['wrong_question', { questionClientId: 'q-1', status: 'pending' }, WrongQuestionEntity],
    [
      'review_record',
      {
        questionClientId: 'q-1',
        result: 'correct',
        reviewedAt: '2026-08-24T08:00:00.000Z'
      },
      ReviewRecordEntity
    ]
  ])('materializes %s operations before recording the sync event', async (entityType, payload, target) => {
    const savedTargets: Function[] = [];
    const manager = {
      findOne: async (entity: Function) => {
        if (entity === UserEntity) {
          return Object.assign(new UserEntity(), { id: 'user-1' });
        }
        if (entity === SyncOperationEntity) {
          return null;
        }
        if (entity === QuestionBankEntity) {
          return Object.assign(new QuestionBankEntity(), {
            id: 'bank-1',
            userId: 'user-1',
            clientId: '33333333-3333-4333-8333-333333333333',
            version: 1
          });
        }
        return null;
      },
      create: (entity: Function, values: object) => Object.assign(new (entity as new () => object)(), values),
      save: async (value: object) => {
        savedTargets.push(value.constructor);
        if (value instanceof SyncOperationEntity) {
          value.serverSequence = '9';
        }
        return value;
      }
    };
    const dataSource = {
      transaction: async (work: (value: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource;
    const store = new TypeOrmSyncStore(dataSource);

    const result = await store.apply('user-1', [
      operation(entityType as SyncOperationInput['entityType'], payload as Record<string, unknown>)
    ]);

    expect(savedTargets).toContain(target);
    expect(savedTargets.at(-1)).toBe(SyncOperationEntity);
    expect(result[0].serverSequence).toBe('9');
  });

  it('returns the existing acknowledgement for a repeated operation', async () => {
    const existing = Object.assign(new SyncOperationEntity(), {
      operationId: '11111111-1111-4111-8111-111111111111',
      entityType: 'question_bank',
      entityId: '22222222-2222-4222-8222-222222222222',
      operationType: 'upsert',
      payload: { name: '数学题库', subject: '数学' },
      serverSequence: '7'
    });
    const manager = {
      findOne: async (entity: Function) =>
        entity === UserEntity ? Object.assign(new UserEntity(), { id: 'user-1' }) : existing,
      save: async () => {
        throw new Error('repeated operations must not write');
      }
    };
    const dataSource = {
      transaction: async (work: (value: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource;
    const store = new TypeOrmSyncStore(dataSource);

    await expect(
      store.apply('user-1', [operation('question_bank', { name: 'ignored', subject: '数学' })])
    ).resolves.toEqual([
      {
        operationId: existing.operationId,
        entityType: existing.entityType,
        entityId: existing.entityId,
        operationType: existing.operationType,
        payload: existing.payload,
        serverSequence: '7'
      }
    ]);
  });

  it('uses wrong-question entityId as the materialized question identity', async () => {
    let savedWrongQuestion: WrongQuestionEntity | null = null;
    const manager = {
      findOne: async (entity: Function) => {
        if (entity === UserEntity) {
          return Object.assign(new UserEntity(), { id: 'user-1' });
        }
        return null;
      },
      create: (entity: Function, values: object) =>
        Object.assign(new (entity as new () => object)(), values),
      save: async (value: object) => {
        if (value instanceof WrongQuestionEntity) {
          savedWrongQuestion = value;
        }
        if (value instanceof SyncOperationEntity) {
          value.serverSequence = '9';
        }
        return value;
      }
    };
    const dataSource = {
      transaction: async (work: (value: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource;

    await new TypeOrmSyncStore(dataSource).apply('user-1', [
      operation('wrong_question', { questionClientId: 'different-id', status: 'pending' })
    ]);

    expect(savedWrongQuestion).toMatchObject({
      questionClientId: '22222222-2222-4222-8222-222222222222'
    });
  });

  it('rejects a conflicting payload for an existing append-only review record', async () => {
    const existingReview = Object.assign(new ReviewRecordEntity(), {
      userId: 'user-1',
      clientEventId: '22222222-2222-4222-8222-222222222222',
      questionClientId: '33333333-3333-4333-8333-333333333333',
      result: 'correct',
      reviewedAt: new Date('2026-08-24T08:00:00.000Z')
    });
    const manager = {
      findOne: async (entity: Function) => {
        if (entity === UserEntity) {
          return Object.assign(new UserEntity(), { id: 'user-1' });
        }
        if (entity === ReviewRecordEntity) {
          return existingReview;
        }
        return null;
      },
      create: (entity: Function, values: object) =>
        Object.assign(new (entity as new () => object)(), values),
      save: async (value: object) => value
    };
    const dataSource = {
      transaction: async (work: (value: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource;
    const conflicting = operation('review_record', {
      questionClientId: '44444444-4444-4444-8444-444444444444',
      result: 'wrong',
      reviewedAt: '2026-08-24T09:00:00.000Z'
    });
    conflicting.operationId = conflicting.entityId;

    await expect(new TypeOrmSyncStore(dataSource).apply('user-1', [conflicting])).rejects.toThrow(
      'Review record conflicts with an existing append-only event'
    );
  });

  it('serializes pushes for the same user before checking operation idempotency', async () => {
    const calls: object[] = [];
    const existing = Object.assign(new SyncOperationEntity(), {
      operationId: '11111111-1111-4111-8111-111111111111',
      entityType: 'question_bank',
      entityId: '22222222-2222-4222-8222-222222222222',
      operationType: 'upsert',
      payload: { name: '数学题库', subject: '数学' },
      serverSequence: '7'
    });
    const manager = {
      findOne: async (entity: Function, options: object) => {
        calls.push({ entity, options });
        return entity === UserEntity
          ? Object.assign(new UserEntity(), { id: 'user-1' })
          : existing;
      }
    };
    const dataSource = {
      transaction: async (work: (value: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource;

    await new TypeOrmSyncStore(dataSource).apply('user-1', [
      operation('question_bank', { name: '数学题库', subject: '数学' })
    ]);

    expect(calls[0]).toMatchObject({
      entity: UserEntity,
      options: { where: { id: 'user-1' }, lock: { mode: 'pessimistic_write' } }
    });
  });

  it('pulls one page plus a hasMore marker inside the authenticated user boundary', async () => {
    const events = ['11', '12', '13'].map((serverSequence) =>
      Object.assign(new SyncOperationEntity(), {
        operationId: `11111111-1111-4111-8111-1111111111${serverSequence}`,
        entityType: 'question_bank',
        entityId: '22222222-2222-4222-8222-222222222222',
        operationType: 'upsert',
        payload: { name: serverSequence },
        serverSequence
      })
    );
    let findOptions: object | null = null;
    const dataSource = {
      getRepository: () => ({
        find: async (options: object) => {
          findOptions = options;
          return events;
        }
      })
    } as unknown as DataSource;
    const store = new TypeOrmSyncStore(dataSource);

    await expect(store.pull('user-1', '10', 2)).resolves.toMatchObject({
      nextCursor: '12',
      hasMore: true,
      operations: [{ serverSequence: '11' }, { serverSequence: '12' }]
    });
    expect(findOptions).toMatchObject({ take: 3 });
  });
});
