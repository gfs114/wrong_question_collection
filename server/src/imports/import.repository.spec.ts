import { DataSource } from 'typeorm';
import {
  ImportArtifactEntity,
  ImportCleanupCheckpointEntity,
  ImportConfirmationEntity,
  ImportConfirmedQuestionEntity,
  ImportDraftQuestionEntity,
  ImportJobEntity,
  ImportJobLeaseEntity,
  ImportUploadPartEntity
} from '../database/entities';
import { TypeOrmSyncStore } from '../database/typeorm-sync.store';
import {
  canTransition,
  ConfirmImportInput,
  CreateImportJobRecord,
  IMPORT_ARTIFACT_PUBLISH_POLICY,
  ImportJobRecord,
  ImportJobStatus
} from './import.contracts';
import {
  ImportRepositoryError,
  TypeOrmImportRepository
} from './import.repository';

const NOW = new Date('2026-08-26T08:00:00.000Z');

const createInput = (): CreateImportJobRecord => ({
  id: '11111111-1111-4111-8111-111111111111',
  userId: '22222222-2222-4222-8222-222222222222',
  deviceId: '33333333-3333-4333-8333-333333333333',
  bankName: '数学题库',
  subject: '数学',
  pageStart: 1,
  pageEnd: 2,
  sourceSha256: 'a'.repeat(64),
  sourceSize: '100',
  partCount: 1
});

const job = (overrides: Partial<ImportJobRecord> = {}): ImportJobRecord => ({
  ...createInput(),
  status: 'uploading',
  progressCurrent: 0,
  progressTotal: 0,
  retryCount: 0,
  errorCode: null,
  claimedAt: null,
  expiresAt: new Date('2026-08-27T08:00:00.000Z'),
  createdAt: NOW,
  updatedAt: NOW,
  ...overrides
});

function updateResult(affected = 1): { affected: number } {
  return { affected };
}

function inValues(where: unknown): unknown[] {
  return (where as { status: { _value: unknown[] } }).status._value;
}

describe('import job transition policy', () => {
  const all: ImportJobStatus[] = [
    'uploading', 'queued', 'processing', 'review', 'confirmed', 'failed', 'cancelled', 'expired'
  ];
  const allowed: Readonly<Record<ImportJobStatus, readonly ImportJobStatus[]>> = {
    uploading: ['queued', 'cancelled', 'expired'],
    queued: ['processing', 'cancelled', 'expired'],
    processing: ['review', 'failed', 'cancelled', 'expired'],
    review: ['confirmed', 'cancelled', 'expired'],
    confirmed: [],
    failed: ['queued', 'cancelled', 'expired'],
    cancelled: [],
    expired: []
  };

  it('allows exactly the declared state transitions', () => {
    for (const from of all) {
      for (const to of all) {
        expect(canTransition(from, to)).toBe(allowed[from].includes(to));
      }
    }
  });
});

describe('import artifact publication policy', () => {
  it('requires source PDFs and future question images to publish only after a durable manifest', () => {
    expect(IMPORT_ARTIFACT_PUBLISH_POLICY).toBe('manifest-first');
  });
});

describe('TypeOrmImportRepository', () => {
  it('acquires a durable assembly lease by inserting a job-keyed token row', async () => {
    const insert = jest.fn().mockResolvedValue({ identifiers: [{ jobId: createInput().id }] });
    const repository = new TypeOrmImportRepository({
      getRepository: (entity: unknown) => {
        expect(entity).toBe(ImportJobLeaseEntity);
        return { insert };
      }
    } as unknown as DataSource);
    const expiresAt = new Date('2026-08-26T09:00:00.000Z');

    await expect(repository.tryAcquireAssemblyLease(
      createInput().id, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', NOW, expiresAt
    )).resolves.toBe(true);
    expect(insert).toHaveBeenCalledWith({
      jobId: createInput().id,
      token: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      expiresAt
    });
  });

  it('takes over only an expired durable lease and requires affected=1', async () => {
    const duplicate = Object.assign(new Error('duplicate'), { code: 'ER_DUP_ENTRY' });
    const update = jest.fn().mockResolvedValueOnce(updateResult(1)).mockResolvedValueOnce(updateResult(0));
    const repository = new TypeOrmImportRepository({ getRepository: () => ({
      insert: jest.fn().mockRejectedValue(duplicate), update
    }) } as unknown as DataSource);
    const expiresAt = new Date('2026-08-26T09:00:00.000Z');

    await expect(repository.tryAcquireAssemblyLease(
      createInput().id, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', NOW, expiresAt
    )).resolves.toBe(true);
    await expect(repository.tryAcquireAssemblyLease(
      createInput().id, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', NOW, expiresAt
    )).resolves.toBe(false);
    expect(update).toHaveBeenNthCalledWith(1,
      expect.objectContaining({ jobId: createInput().id, expiresAt: expect.anything() }),
      { token: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', expiresAt }
    );
    expect((update.mock.calls[0][0].expiresAt as { _value: unknown })._value).toEqual(NOW);
  });

  it('renews and releases only the exact non-expired lease token', async () => {
    const update = jest.fn().mockResolvedValueOnce(updateResult(1)).mockResolvedValueOnce(updateResult(0));
    const remove = jest.fn().mockResolvedValueOnce(updateResult(1)).mockResolvedValueOnce(updateResult(0));
    const repository = new TypeOrmImportRepository({ getRepository: () => ({ update, delete: remove }) } as unknown as DataSource);
    const expiresAt = new Date('2026-08-26T09:00:00.000Z');

    await expect(repository.renewAssemblyLease(
      createInput().id, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', NOW, expiresAt
    )).resolves.toBe(true);
    await expect(repository.renewAssemblyLease(
      createInput().id, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', NOW, expiresAt
    )).resolves.toBe(false);
    expect((update.mock.calls[0][0].expiresAt as { _value: unknown })._value).toEqual(NOW);
    expect(update.mock.calls[0][0]).toMatchObject({
      jobId: createInput().id,
      token: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    });
    await expect(repository.releaseAssemblyLease(
      createInput().id, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    )).resolves.toBe(true);
    await expect(repository.releaseAssemblyLease(
      createInput().id, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    )).resolves.toBe(false);
    expect(remove).toHaveBeenCalledWith({
      jobId: createInput().id,
      token: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    });
  });

  it('rejects malformed lease identifiers before issuing a repository query', async () => {
    const getRepository = jest.fn();
    const repository = new TypeOrmImportRepository({ getRepository } as unknown as DataSource);

    await expect(repository.tryAcquireAssemblyLease(
      'job-1; SELECT 1', 'not-a-token', NOW, new Date(NOW.getTime() + 1000)
    )).rejects.toMatchObject({ code: 'INVALID_STATE' });
    expect(getRepository).not.toHaveBeenCalled();
  });

  it('does not disguise durable lease database failures as a busy business conflict', async () => {
    const infrastructure = new Error('private database endpoint unavailable');
    const repository = new TypeOrmImportRepository({ getRepository: () => ({
      insert: jest.fn().mockRejectedValue(infrastructure)
    }) } as unknown as DataSource);

    await expect(repository.tryAcquireAssemblyLease(
      createInput().id, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', NOW,
      new Date(NOW.getTime() + 1000)
    )).rejects.toBe(infrastructure);
  });

  it('creates an uploading job for the owning user and device with a 24-hour expiry', async () => {
    let saved: ImportJobRecord | undefined;
    const manager = {
      insert: async (_entity: unknown, value: ImportJobRecord) => { saved = value; },
      findOne: async () => saved
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource, () => NOW);

    await expect(repository.createJob(createInput())).resolves.toMatchObject({
      userId: createInput().userId, deviceId: createInput().deviceId, status: 'uploading',
      progressCurrent: 0, progressTotal: 0, retryCount: 0
    });
    expect(saved?.expiresAt).toEqual(new Date('2026-08-27T08:00:00.000Z'));
  });

  it('inserts a new job rather than allowing save to upsert an existing primary key', async () => {
    let inserted = false;
    const manager = {
      insert: async () => { inserted = true; },
      findOne: async () => job(),
      create: () => { throw new Error('create/save upsert path must not be used'); },
      save: async () => { throw new Error('save upsert path must not be used'); }
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource, () => NOW);

    await expect(repository.createJob(createInput())).resolves.toMatchObject({ status: 'uploading' });
    expect(inserted).toBe(true);
  });

  it('scopes user-facing lookups to the authenticated user and job id', async () => {
    let options: unknown;
    const repository = new TypeOrmImportRepository({ getRepository: () => ({
      findOne: async (input: unknown) => { options = input; return null; }
    }) } as unknown as DataSource);

    await expect(repository.findOwnedJob('user-1', 'job-1')).resolves.toBeNull();
    expect(options).toMatchObject({ where: { id: 'job-1', userId: 'user-1' } });
  });

  it('records an identical upload part idempotently, rejects a conflict, and does not accept client paths', async () => {
    const existing = { userId: 'user-1', deviceId: 'device-1', jobId: 'job-1', partNumber: 0, size: '12', sha256: 'a'.repeat(64), storageKey: 'job-1/part-0000000000.bin' };
    const manager = { findOne: async (entity: unknown) => entity === ImportJobEntity ? job({ id: 'job-1', userId: 'user-1', deviceId: 'device-1' }) : existing, save: async () => { throw new Error('must not save'); } };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource);
    const input = { ...existing, id: 'part-1' };

    await expect(repository.recordPart(input)).resolves.toBeUndefined();
    await expect(repository.recordPart({ ...input, sha256: 'b'.repeat(64) })).rejects.toMatchObject({ code: 'IMPORT_PART_CONFLICT' });
    expect('clientPath' in input).toBe(false);
  });

  it('reconciles a duplicate-key race in a fresh transaction without exposing the database error', async () => {
    const input = { id: 'part-1', userId: 'user-1', deviceId: 'device-1', jobId: 'job-1', partNumber: 0, size: '12', sha256: 'a'.repeat(64), storageKey: 'job-1/part-0000000000.bin' };
    const duplicate = Object.assign(new Error('Duplicate entry'), { code: 'ER_DUP_ENTRY', errno: 1062 });
    const winner = { ...input };
    const managers = [
      { findOne: async (entity: unknown) => entity === ImportJobEntity ? job({ id: 'job-1', userId: 'user-1', deviceId: 'device-1' }) : null, insert: async () => { throw duplicate; } },
      { findOne: async (entity: unknown) => entity === ImportJobEntity ? job({ id: 'job-1', userId: 'user-1', deviceId: 'device-1' }) : winner }
    ];
    let transactionNumber = 0;
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (manager: object) => Promise<unknown>) => work(managers[transactionNumber++])
    } as unknown as DataSource);

    await expect(repository.recordPart(input)).resolves.toBeUndefined();
    expect(transactionNumber).toBe(2);
  });

  it('maps a conflicting duplicate-key race to the stable part-conflict code', async () => {
    const input = { id: 'part-1', userId: 'user-1', deviceId: 'device-1', jobId: 'job-1', partNumber: 0, size: '12', sha256: 'a'.repeat(64), storageKey: 'job-1/part-0000000000.bin' };
    const duplicate = Object.assign(new Error('Duplicate entry'), { code: 'ER_DUP_ENTRY' });
    const managers = [
      { findOne: async (entity: unknown) => entity === ImportJobEntity ? job({ id: 'job-1', userId: 'user-1', deviceId: 'device-1' }) : null, insert: async () => { throw duplicate; } },
      { findOne: async (entity: unknown) => entity === ImportJobEntity ? job({ id: 'job-1', userId: 'user-1', deviceId: 'device-1' }) : ({ ...input, sha256: 'b'.repeat(64) }) }
    ];
    let transactionNumber = 0;
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (manager: object) => Promise<unknown>) => work(managers[transactionNumber++])
    } as unknown as DataSource);

    await expect(repository.recordPart(input)).rejects.toMatchObject({ code: 'IMPORT_PART_CONFLICT' });
    expect(transactionNumber).toBe(2);
  });

  it('rejects upload parts from another user or device before inserting any part row', async () => {
    let jobLookup: unknown;
    const manager = {
      findOne: async (_entity: unknown, options: unknown) => { jobLookup = options; return null; },
      insert: async () => { throw new Error('part insert must not run'); }
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource);

    await expect(repository.recordPart({ id: 'part-1', userId: 'user-a', deviceId: 'device-b', jobId: 'job-1', partNumber: 0, size: '12', sha256: 'a'.repeat(64), storageKey: 'job-1/part-0000000000.bin' })).rejects.toMatchObject({ code: 'INVALID_STATE' });
    expect(jobLookup).toMatchObject({ where: { id: 'job-1', userId: 'user-a', deviceId: 'device-b', status: 'uploading' }, lock: { mode: 'pessimistic_write' } });
  });

  it('persists a source cleanup manifest before publication and accepts an identical retry', async () => {
    const source = { storageKey: 'job-1/source.pdf', sha256: 'a'.repeat(64), size: '12' };
    const inserted: Array<{ expiresAt: Date; type: string }> = [];
    let artifact: object | null = null;
    const manager = {
      findOne: async (entity: unknown) => entity === ImportJobEntity
        ? job({ id: 'job-1', userId: 'user-1', deviceId: 'device-1' })
        : artifact,
      insert: async (_entity: unknown, value: { expiresAt: Date; type: string }) => {
        inserted.push(value);
        artifact = value;
      }
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource);

    await repository.prepareSource('user-1', 'device-1', 'job-1', source);
    await repository.prepareSource('user-1', 'device-1', 'job-1', source);

    expect(inserted).toHaveLength(1);
    expect(inserted[0]).toMatchObject({
      jobId: 'job-1', draftQuestionId: null, type: 'source_pdf', ...source,
      expiresAt: new Date('2026-08-27T08:00:00.000Z')
    });
  });

  it('rejects conflicting metadata for an existing source manifest', async () => {
    const manager = {
      findOne: async (entity: unknown) => entity === ImportJobEntity
        ? job({ id: 'job-1', userId: 'user-1', deviceId: 'device-1' })
        : ({ storageKey: 'job-1/source.pdf', sha256: 'b'.repeat(64), size: '12' }),
      insert: jest.fn()
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource);

    await expect(repository.prepareSource('user-1', 'device-1', 'job-1', {
      storageKey: 'job-1/source.pdf', sha256: 'a'.repeat(64), size: '12'
    })).rejects.toMatchObject({ code: 'IMPORT_ARTIFACT_CONFLICT' });
    expect(manager.insert).not.toHaveBeenCalled();
  });

  it('queues only when the matching source manifest already exists and never inserts after publication', async () => {
    const calls: unknown[] = [];
    const source = { storageKey: 'job-1/source.pdf', sha256: 'a'.repeat(64), size: '12' };
    const manager = {
      findOne: async (entity: unknown) => entity === ImportJobEntity
        ? job({ id: 'job-1', userId: 'user-1', deviceId: 'device-1' })
        : ({ ...source, type: 'source_pdf', draftQuestionId: null }),
      update: async (...input: unknown[]) => { calls.push(input); return updateResult(); },
      insert: jest.fn(),
      save: async () => { throw new Error('artifact save/upsert path must not be used'); }
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource, () => NOW);

    await repository.queueCompletedUpload('user-1', 'device-1', 'job-1', source);
    expect(calls[0]).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: 'job-1', userId: 'user-1', deviceId: 'device-1', status: 'uploading' })
    ]));
    expect(manager.insert).not.toHaveBeenCalled();
  });

  it('refuses to queue when the durable source manifest is absent or mismatched', async () => {
    const source = { storageKey: 'job-1/source.pdf', sha256: 'a'.repeat(64), size: '12' };
    for (const artifact of [null, { ...source, size: '13', type: 'source_pdf', draftQuestionId: null }]) {
      const manager = {
        findOne: async (entity: unknown) => entity === ImportJobEntity
          ? job({ id: 'job-1', userId: 'user-1', deviceId: 'device-1' })
          : artifact,
        update: jest.fn(),
        insert: jest.fn()
      };
      const repository = new TypeOrmImportRepository({
        transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
      } as unknown as DataSource);

      await expect(repository.queueCompletedUpload('user-1', 'device-1', 'job-1', source))
        .rejects.toMatchObject({ code: 'IMPORT_ARTIFACT_CONFLICT' });
      expect(manager.update).not.toHaveBeenCalled();
      expect(manager.insert).not.toHaveBeenCalled();
    }
  });

  it('claims one oldest job through FOR UPDATE SKIP LOCKED and a conditional queued update', async () => {
    const oldUpdatedAt = new Date('2026-08-25T08:00:00.000Z');
    const state = { job: job({ id: 'job-1', status: 'queued', updatedAt: oldUpdatedAt }), lockOwner: null as number | null };
    const trace: string[] = [];
    const updates: unknown[][] = [];
    let releaseFirstClaim: () => void = () => undefined;
    const secondObserved = new Promise<void>((resolve) => { releaseFirstClaim = resolve; });
    let nextTransactionId = 0;

    const managerFor = (transactionId: number) => {
      let lockMode: string | undefined;
      let onLocked: string | undefined;
      let selection: unknown;
      let ordering: string | undefined;
      let limit: number | undefined;
      const query = {
        setLock: (value: string) => { lockMode = value; trace.push(`lock:${value}`); return query; },
        setOnLocked: (value: string) => { onLocked = value; trace.push(`onLocked:${value}`); return query; },
        where: (value: unknown) => { selection = value; return query; },
        orderBy: (value: string, direction: string) => { ordering = `${value}:${direction}`; return query; },
        take: (value: number) => { limit = value; return query; },
        getOne: async () => {
          if (lockMode !== 'pessimistic_write' || onLocked !== 'skip_locked' ||
            JSON.stringify(selection) !== JSON.stringify({ status: 'queued' }) ||
            ordering !== 'job.createdAt:ASC' || limit !== 1) {
            throw new Error('claim query is not a bounded FOR UPDATE SKIP LOCKED query');
          }
          if (state.job.status !== 'queued') return null;
          if (state.lockOwner !== null) {
            releaseFirstClaim();
            return null;
          }
          state.lockOwner = transactionId;
          await secondObserved;
          return { ...state.job };
        }
      };
      return {
        getRepository: () => ({ createQueryBuilder: () => query }),
        update: async (...input: unknown[]) => {
          updates.push(input);
          const [, where, values] = input as [unknown, { id: string; status: string }, { status: string; claimedAt: Date; updatedAt: Date }];
          if (where.id !== 'job-1' || where.status !== 'queued' || values.status !== 'processing') {
            throw new Error('claim update is not conditional on the queued job');
          }
          if (state.job.status !== where.status) return updateResult(0);
          Object.assign(state.job, values);
          return updateResult();
        }
      };
    };
    const dataSource = {
      transaction: async (work: (manager: ReturnType<typeof managerFor>) => Promise<unknown>) => {
        const transactionId = nextTransactionId++;
        try { return await work(managerFor(transactionId)); }
        finally { if (state.lockOwner === transactionId) state.lockOwner = null; }
      }
    } as unknown as DataSource;
    const repository = new TypeOrmImportRepository(dataSource, () => NOW);

    const [first, second] = await Promise.all([repository.claimNext('worker-a'), repository.claimNext('worker-b')]);
    expect(first).toMatchObject({ id: 'job-1', status: 'processing', claimedAt: NOW, updatedAt: NOW });
    expect(second).toBeNull();
    expect(trace).toEqual(expect.arrayContaining(['lock:pessimistic_write', 'onLocked:skip_locked']));
    expect(updates).toHaveLength(1);
    expect(state.job).toMatchObject({ status: 'processing', claimedAt: NOW, updatedAt: NOW });
  });

  it('rejects a claim whose conditional queued update loses the row', async () => {
    const query = {
      setLock: () => query,
      setOnLocked: () => query,
      where: () => query,
      orderBy: () => query,
      take: () => query,
      getOne: async () => job({ id: 'job-1', status: 'queued' })
    };
    const manager = {
      getRepository: () => ({ createQueryBuilder: () => query }),
      update: async () => updateResult(0)
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource, () => NOW);

    await expect(repository.claimNext('worker-a')).rejects.toMatchObject({ code: 'INVALID_STATE' });
  });

  it('advances a re-claim token past a retained prior token even when the clock has not advanced', async () => {
    const query = {
      setLock: () => query, setOnLocked: () => query, where: () => query, orderBy: () => query, take: () => query,
      getOne: async () => job({ id: 'job-1', status: 'queued', claimedAt: NOW })
    };
    let values: { claimedAt: Date } | undefined;
    const manager = {
      getRepository: () => ({ createQueryBuilder: () => query }),
      update: async (_entity: unknown, _where: unknown, update: { claimedAt: Date }) => { values = update; return updateResult(); }
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource, () => NOW);

    await repository.claimNext('worker-a');
    expect(values?.claimedAt).toEqual(new Date(NOW.getTime() + 1));
  });

  it('updates progress only while processing and only for a valid bounded range', async () => {
    let predicate: unknown;
    const repository = new TypeOrmImportRepository({ getRepository: () => ({
      update: async (where: unknown) => { predicate = where; return updateResult(); }
    }) } as unknown as DataSource);

    await repository.updateProgress('job-1', NOW, 2, 3);
    expect(predicate).toMatchObject({ id: 'job-1', status: 'processing', claimedAt: NOW });
    await expect(repository.updateProgress('job-1', NOW, 4, 3)).rejects.toMatchObject({ code: 'INVALID_PROGRESS' });
  });

  it('rejects stale worker progress after a newer claim token has taken ownership', async () => {
    const oldToken = new Date('2026-08-26T08:00:00.001Z');
    const newToken = new Date('2026-08-26T08:00:00.002Z');
    let predicate: unknown;
    const repository = new TypeOrmImportRepository({ getRepository: () => ({
      update: async (where: unknown) => { predicate = where; return updateResult(0); }
    }) } as unknown as DataSource);

    await expect(repository.updateProgress('job-1', oldToken, 1, 2)).rejects.toMatchObject({ code: 'INVALID_STATE' });
    expect(predicate).toMatchObject({ id: 'job-1', status: 'processing', claimedAt: oldToken });
    expect((predicate as { claimedAt: Date }).claimedAt).not.toEqual(newToken);
  });

  it('replaces all draft and artifact metadata atomically before moving a processing job to review', async () => {
    const calls: Array<[string, ...unknown[]]> = [];
    const manager = {
      findOne: async () => job({ id: 'job-1', status: 'processing', claimedAt: NOW }),
      delete: async (...input: unknown[]) => { calls.push(['delete', ...input]); return updateResult(); },
      insert: async (...input: unknown[]) => { calls.push(['insert', ...input]); },
      update: async (...input: unknown[]) => { calls.push(['update', ...input]); return updateResult(); }
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource);

    await repository.replaceDraft('job-1', NOW, {
      questions: [{ id: 'draft-1', position: 0, type: 'single_choice', question: '题目', options: null, answer: null, analysis: null, pageStart: 1, pageEnd: 1, confidence: 0.5, reviewRequired: true, artifacts: [{ id: 'artifact-1', type: 'question_image', storageKey: 'job-1/artifact-draft-1.bin', sha256: 'a'.repeat(64), size: '9', expiresAt: NOW }] }]
    });
    expect(calls.filter(([name]) => name === 'delete')).toHaveLength(2);
    expect(calls.at(-1)).toEqual(expect.arrayContaining(['update', expect.anything(), expect.objectContaining({ id: 'job-1', status: 'processing' })]));
  });

  it('replaces only draft question images and fences stale workers with their claim token', async () => {
    const calls: unknown[][] = [];
    const token = new Date('2026-08-26T08:00:00.001Z');
    const manager = {
      findOne: async () => job({ id: 'job-1', status: 'processing', claimedAt: token }),
      delete: async (...input: unknown[]) => { calls.push(input); return updateResult(); },
      insert: async () => undefined,
      update: async (...input: unknown[]) => { calls.push(input); return updateResult(); }
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource);
    const fenced = repository as unknown as { replaceDraft(jobId: string, expectedClaimedAt: Date, draft: { questions: [] }): Promise<void> };

    await expect(fenced.replaceDraft('job-1', token, { questions: [] })).resolves.toBeUndefined();
    expect(calls[0]).toEqual(expect.arrayContaining([expect.anything(), expect.objectContaining({ jobId: 'job-1', type: 'question_image' })]));
    expect(calls.at(-1)).toEqual(expect.arrayContaining([expect.anything(), expect.objectContaining({ id: 'job-1', status: 'processing', claimedAt: token })]));
  });

  it('restores the persisted draft and artifact snapshot when a write fails after replacement begins', async () => {
    const cause = new Error('artifact write failed');
    let persisted = {
      drafts: [{ id: 'old-draft', jobId: 'job-1' }],
      artifacts: [{ id: 'old-artifact', jobId: 'job-1' }]
    };
    const before = structuredClone(persisted);
    const manager = {
      delete: async (entity: unknown) => {
        if (entity === ImportArtifactEntity) persisted.artifacts = [];
        if (entity === ImportDraftQuestionEntity) persisted.drafts = [];
        return updateResult();
      },
      findOne: async () => job({ id: 'job-1', status: 'processing', claimedAt: NOW }),
      insert: async (_entity: unknown, value: { id: string; jobId: string; draftQuestionId?: string | null; position?: number }) => {
        if (value.position !== undefined) persisted.drafts.push({ id: value.id, jobId: value.jobId });
        else {
          persisted.artifacts.push({ id: value.id, jobId: value.jobId });
          throw cause;
        }
      }
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => {
        const snapshot = structuredClone(persisted);
        try { return await work(manager); }
        catch (error) { persisted = snapshot; throw error; }
      }
    } as unknown as DataSource);

    await expect(repository.replaceDraft('job-1', NOW, {
      questions: [{ id: 'draft-1', position: 0, type: 'single_choice', question: '题目', options: null, answer: null, analysis: null, pageStart: 1, pageEnd: 1, confidence: 0.5, reviewRequired: true, artifacts: [{ id: 'artifact-1', type: 'question_image', storageKey: 'job-1/artifact-draft-1.bin', sha256: 'a'.repeat(64), size: '9', expiresAt: NOW }] }]
    })).rejects.toBe(cause);
    expect(persisted).toEqual(before);
  });

  it('moves processing to failed before explicitly requeueing retryable work below the limit', async () => {
    const calls: unknown[] = [];
    let lockLookup: unknown;
    const manager = {
      findOne: async (_entity: unknown, options: unknown) => { lockLookup = options; return job({ id: 'job-1', status: 'processing', retryCount: 0, claimedAt: NOW }); },
      update: async (...input: unknown[]) => { calls.push(input); return updateResult(); }
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource);

    await repository.markFailure('job-1', NOW, 'WORKER_TIMEOUT', true);
    expect(lockLookup).toMatchObject({ where: { id: 'job-1', status: 'processing', claimedAt: NOW }, lock: { mode: 'pessimistic_write' } });
    expect(calls).toHaveLength(2);
    expect(calls[0]).toEqual(expect.arrayContaining([expect.objectContaining({ id: 'job-1', status: 'processing', retryCount: 0, claimedAt: NOW }), expect.objectContaining({ retryCount: 1, status: 'failed', errorCode: 'WORKER_TIMEOUT' })]));
    expect(calls[1]).toEqual(expect.arrayContaining([expect.objectContaining({ id: 'job-1', status: 'failed', retryCount: 1 }), expect.objectContaining({ status: 'queued' })]));
  });

  it('rejects a stale failure worker after a newer claim token owns the processing job', async () => {
    const oldToken = new Date('2026-08-26T08:00:00.001Z');
    const newToken = new Date('2026-08-26T08:00:00.002Z');
    let lookup: unknown;
    const manager = {
      findOne: async (_entity: unknown, options: unknown) => { lookup = options; return null; },
      update: async () => { throw new Error('stale failure must not update'); }
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource);

    await expect(repository.markFailure('job-1', oldToken, 'WORKER_TIMEOUT', true)).rejects.toMatchObject({ code: 'INVALID_STATE' });
    expect(lookup).toMatchObject({ where: { id: 'job-1', status: 'processing', claimedAt: oldToken }, lock: { mode: 'pessimistic_write' } });
    expect((lookup as { where: { claimedAt: Date } }).where.claimedAt).not.toEqual(newToken);
  });

  it('fails rather than requeues at the retry limit and enforces the processing predicate', async () => {
    let updated: unknown;
    const manager = {
      findOne: async () => job({ status: 'processing', retryCount: 1 }),
      update: async (...input: unknown[]) => { updated = input; return updateResult(); }
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource);

    await repository.markFailure('job-1', NOW, 'WORKER_TIMEOUT', true);
    expect(updated).toEqual(expect.arrayContaining([expect.objectContaining({ id: 'job-1', status: 'processing', retryCount: 1 }), expect.objectContaining({ retryCount: 2, status: 'failed' })]));
  });

  it('does not cancel when a competing transition has already reached a terminal status', async () => {
    let where: unknown;
    let changes: unknown;
    const repository = new TypeOrmImportRepository({ getRepository: () => ({
      update: async (input: unknown, values: unknown) => { where = input; changes = values; return updateResult(0); }
    }) } as unknown as DataSource);

    await expect(repository.cancelOwned('user-1', 'device-1', 'job-1')).resolves.toBe(false);
    expect(where).toMatchObject({ id: 'job-1', userId: 'user-1', deviceId: 'device-1' });
    expect(inValues(where)).toEqual(['uploading', 'queued', 'processing', 'review', 'failed']);
    expect(changes).toEqual({ status: 'cancelled' });
  });

  it('confirms the complete draft in one locked transaction and reuses canonical sync materialization', async () => {
    const draftId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const artifactId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const lockedJob = job({ id: createInput().id, status: 'review' }) as unknown as ImportJobEntity;
    const drafts = [{
      id: draftId, jobId: createInput().id, position: 0, type: 'single_choice',
      question: 'Original', options: { A: '1', B: '2' }, answer: 'B', analysis: null,
      pageStart: 1, pageEnd: 1, confidence: 0.9, reviewRequired: true
    }];
    const mappings: Array<Record<string, unknown>> = [];
    let lockOptions: unknown;
    const manager = {
      findOne: async (entity: unknown, options: unknown) => {
        if (entity === ImportJobEntity) { lockOptions = options; return lockedJob; }
        if (entity === ImportConfirmationEntity) return null;
        return null;
      },
      find: async (entity: unknown) => {
        if (entity === ImportDraftQuestionEntity) return drafts;
        if (entity === ImportConfirmedQuestionEntity) return mappings;
        if (entity === ImportArtifactEntity) return [{
          id: artifactId, draftQuestionId: draftId, sha256: 'b'.repeat(64), size: '123'
        }];
        return [];
      },
      create: (_entity: unknown, value: object) => value,
      save: async (value: object) => value,
      insert: async (entity: unknown, value: Record<string, unknown>) => {
        if (entity === ImportConfirmedQuestionEntity) mappings.push(value);
      },
      update: async () => updateResult()
    };
    const dataSource = {
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource;
    const sync = jest.spyOn(TypeOrmSyncStore.prototype, 'applyInTransaction')
      .mockResolvedValue([]);
    try {
      const repository = new TypeOrmImportRepository(dataSource, () => NOW);
      const input = {
        bankName: 'Edited bank', subject: 'Math', questions: [{
          draftQuestionId: draftId, type: 'single_choice', question: 'Original',
          options: { A: '1', B: '2' }, answer: 'B', analysis: null, reviewed: true
        }]
      };

      const result = await repository.confirmImport(
        createInput().userId, createInput().deviceId, createInput().id, 'c'.repeat(64), input
      );

      expect(lockOptions).toMatchObject({
        where: {
          id: createInput().id, userId: createInput().userId,
          deviceId: createInput().deviceId
        },
        lock: { mode: 'pessimistic_write' }
      });
      expect(sync).toHaveBeenCalledTimes(1);
      expect(sync.mock.calls[0][2]).toEqual([
        expect.objectContaining({ entityType: 'question_bank', operationType: 'upsert' }),
        expect.objectContaining({
          entityType: 'question', operationType: 'upsert',
          payload: expect.objectContaining({ bankClientId: expect.any(String) })
        })
      ]);
      expect(result).toMatchObject({
        bankId: expect.any(String),
        questions: [{
          draftQuestionId: draftId,
          questionId: expect.any(String),
          images: [{ artifactId, sha256: 'b'.repeat(64), size: 123 }]
        }]
      });
      expect(JSON.stringify(result)).not.toContain('storageKey');
    } finally {
      sync.mockRestore();
    }
  });

  it('rejects missing, duplicate and unreviewed current drafts before writing sync events', async () => {
    const draftId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const manager = {
      findOne: async (entity: unknown) => entity === ImportJobEntity
        ? (job({ status: 'review' }) as unknown as ImportJobEntity)
        : null,
      find: async (entity: unknown) => entity === ImportDraftQuestionEntity ? [{
        id: draftId, position: 0, type: 'unknown', question: 'Needs review',
        options: null, answer: null, analysis: null, reviewRequired: true
      }] : [],
      insert: jest.fn(), update: jest.fn(), save: jest.fn(), create: jest.fn()
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource, () => NOW);

    await expect(repository.confirmImport(
      createInput().userId, createInput().deviceId, createInput().id, 'c'.repeat(64), {
        bankName: 'Bank', subject: 'Math', questions: []
      }
    )).rejects.toMatchObject({ code: 'INVALID_DRAFT' });
    await expect(repository.confirmImport(
      createInput().userId, createInput().deviceId, createInput().id, 'c'.repeat(64), {
        bankName: 'Bank', subject: 'Math', questions: [{
          draftQuestionId: draftId, type: 'unknown', question: 'Needs review',
          options: null, answer: null, analysis: null, reviewed: false
        }]
      }
    )).rejects.toMatchObject({ code: 'INVALID_DRAFT' });
    const missingOptions = {
      bankName: 'Bank', subject: 'Math', questions: [{
        draftQuestionId: draftId, type: 'unknown', question: 'Needs review',
        options: undefined, answer: null, analysis: null, reviewed: false
      }]
    } as unknown as ConfirmImportInput;
    await expect(repository.confirmImport(
      createInput().userId, createInput().deviceId, createInput().id, 'c'.repeat(64), missingOptions
    )).rejects.toMatchObject({ code: 'INVALID_DRAFT' });
    const undefinedNullableText = {
      bankName: 'Bank', subject: 'Math', questions: [{
        draftQuestionId: draftId, type: 'unknown', question: 'Needs review',
        options: null, answer: undefined, analysis: undefined, reviewed: false
      }]
    } as unknown as ConfirmImportInput;
    await expect(repository.confirmImport(
      createInput().userId, createInput().deviceId, createInput().id, 'c'.repeat(64),
      undefinedNullableText
    )).rejects.toMatchObject({ code: 'INVALID_DRAFT' });
    expect(manager.insert).not.toHaveBeenCalled();
    expect(manager.update).not.toHaveBeenCalled();
  });

  it('returns a persisted same-hash confirmation idempotently and rejects a different hash', async () => {
    const confirmation = {
      id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', jobId: createInput().id,
      requestSha256: 'c'.repeat(64), bankId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
      expiresAt: job().expiresAt
    } as ImportConfirmationEntity;
    const mapping = {
      draftQuestionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      questionId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', position: 0
    };
    const manager = {
      findOne: async (entity: unknown) => entity === ImportJobEntity
        ? (job({ status: 'confirmed' }) as unknown as ImportJobEntity)
        : entity === ImportConfirmationEntity ? confirmation : null,
      find: async (entity: unknown) => entity === ImportConfirmedQuestionEntity ? [mapping] : [],
      update: jest.fn(), insert: jest.fn(), save: jest.fn()
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource);
    const input = { bankName: 'Bank', subject: 'Math', questions: [] };

    await expect(repository.confirmImport(
      createInput().userId, createInput().deviceId, createInput().id, 'c'.repeat(64), input
    )).resolves.toMatchObject({ bankId: confirmation.bankId });
    await expect(repository.confirmImport(
      createInput().userId, createInput().deviceId, createInput().id, 'd'.repeat(64), input
    )).rejects.toMatchObject({ code: 'IMPORT_CONFIRMATION_CONFLICT' });
    expect(manager.update).not.toHaveBeenCalled();
  });

  it('rolls back confirmation before status change when canonical sync materialization fails', async () => {
    const draftId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const manager = {
      findOne: async (entity: unknown) => entity === ImportJobEntity
        ? (job({ status: 'review' }) as unknown as ImportJobEntity)
        : null,
      find: async (entity: unknown) => entity === ImportDraftQuestionEntity ? [{
        id: draftId, position: 0, type: 'single_choice', question: 'Question',
        options: null, answer: null, analysis: null, reviewRequired: false
      }] : [],
      insert: jest.fn(), update: jest.fn(), save: jest.fn(), create: jest.fn()
    };
    const cause = new Error('sync event insert failed');
    const sync = jest.spyOn(TypeOrmSyncStore.prototype, 'applyInTransaction').mockRejectedValue(cause);
    try {
      const repository = new TypeOrmImportRepository({
        transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
      } as unknown as DataSource, () => NOW);
      await expect(repository.confirmImport(
        createInput().userId, createInput().deviceId, createInput().id, 'c'.repeat(64), {
          bankName: 'Bank', subject: 'Math', questions: [{
            draftQuestionId: draftId, type: 'single_choice', question: 'Question',
            options: null, answer: null, analysis: null, reviewed: false
          }]
        }
      )).rejects.toBe(cause);
      expect(manager.save).not.toHaveBeenCalled();
      expect(manager.insert).not.toHaveBeenCalled();
      expect(manager.update).not.toHaveBeenCalled();
    } finally {
      sync.mockRestore();
    }
  });

  it('finds only an unacknowledged confirmed image for the exact owner and creating device', async () => {
    const artifactId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const draftId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const lookups: unknown[] = [];
    const manager = {
      findOne: async (entity: unknown, options: unknown) => {
        lookups.push({ entity, options });
        if (entity === ImportJobEntity) return job({ status: 'confirmed' });
        if (entity === ImportConfirmationEntity) return { acknowledgedAt: null };
        if (entity === ImportArtifactEntity) return {
          id: artifactId, jobId: createInput().id, draftQuestionId: draftId,
          type: 'question_image', storageKey: `${createInput().id}/artifact-${artifactId}.bin`,
          sha256: 'b'.repeat(64), size: '123', expiresAt: job().expiresAt
        };
        if (entity === ImportConfirmedQuestionEntity) return { draftQuestionId: draftId };
        return null;
      }
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource);

    await expect(repository.findDownloadArtifact(
      createInput().userId, createInput().deviceId, createInput().id, artifactId, NOW
    )).resolves.toMatchObject({ artifactId, size: 123, sha256: 'b'.repeat(64) });
    expect(lookups[0]).toMatchObject({
      entity: ImportJobEntity,
      options: { where: {
        id: createInput().id, userId: createInput().userId,
        deviceId: createInput().deviceId, status: 'confirmed'
      }, lock: { mode: 'pessimistic_read' } }
    });
    expect(lookups[2]).toMatchObject({
      entity: ImportArtifactEntity,
      options: { where: { id: artifactId, jobId: createInput().id, type: 'question_image' } }
    });
  });

  it.each([
    [`${createInput().id}/source.pdf`, 'b'.repeat(64), '123'],
    [`${createInput().id}/part-0000000000.bin`, 'b'.repeat(64), '123'],
    [`${createInput().id}/artifact-cccccccc-cccc-4ccc-8ccc-cccccccccccc.bin`, 'b'.repeat(64), '123'],
    [`${createInput().id}/artifact-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.bin`, 'B'.repeat(64), '123'],
    [`${createInput().id}/artifact-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.bin`, 'b'.repeat(64), '0']
  ])('rejects unsafe download metadata before returning it (%s)', async (storageKey, sha256, size) => {
    const artifactId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const draftId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const manager = {
      findOne: async (entity: unknown) => {
        if (entity === ImportJobEntity) return job({ status: 'confirmed' });
        if (entity === ImportConfirmationEntity) return { acknowledgedAt: null };
        if (entity === ImportArtifactEntity) return {
          id: artifactId, jobId: createInput().id, draftQuestionId: draftId,
          type: 'question_image', storageKey, sha256, size, expiresAt: job().expiresAt
        };
        if (entity === ImportConfirmedQuestionEntity) return { draftQuestionId: draftId };
        return null;
      }
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource);

    await expect(repository.findDownloadArtifact(
      createInput().userId, createInput().deviceId, createInput().id, artifactId, NOW
    )).resolves.toBeNull();
  });

  it('requires ACK to exactly equal all confirmed question images and never accepts source_pdf', async () => {
    const imageId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const sourceId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    const draftId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const manager = {
      findOne: async (entity: unknown) => entity === ImportJobEntity
        ? job({ status: 'confirmed' })
        : entity === ImportConfirmationEntity ? { acknowledgedAt: null } : null,
      find: async (entity: unknown, options: { where?: { type?: string } }) => {
        if (entity === ImportConfirmedQuestionEntity) return [{ draftQuestionId: draftId }];
        if (entity === ImportUploadPartEntity) return [];
        if (entity === ImportArtifactEntity && options.where?.type === 'question_image') {
          return [{ id: imageId, draftQuestionId: draftId, storageKey: `${createInput().id}/artifact-${imageId}.bin` }];
        }
        if (entity === ImportArtifactEntity) return [
          { id: sourceId, type: 'source_pdf', storageKey: `${createInput().id}/source.pdf` },
          { id: imageId, type: 'question_image', storageKey: `${createInput().id}/artifact-${imageId}.bin` }
        ];
        return [];
      }
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource);

    await expect(repository.prepareArtifactAck(
      createInput().userId, createInput().deviceId, createInput().id, [], NOW
    )).rejects.toMatchObject({ code: 'INVALID_ARTIFACT_SET' });
    await expect(repository.prepareArtifactAck(
      createInput().userId, createInput().deviceId, createInput().id, [imageId, sourceId], NOW
    )).rejects.toMatchObject({ code: 'INVALID_ARTIFACT_SET' });
    await expect(repository.prepareArtifactAck(
      createInput().userId, createInput().deviceId, createInput().id, [imageId], NOW
    )).resolves.toEqual({
      acknowledged: false,
      records: [
        { kind: 'artifact', id: sourceId, storageKey: `${createInput().id}/source.pdf` },
        { kind: 'artifact', id: imageId, storageKey: `${createInput().id}/artifact-${imageId}.bin` }
      ]
    });
  });

  it('accepts an empty ACK set when the confirmation has no question images', async () => {
    const sourceId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    const draftId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const manager = {
      findOne: async (entity: unknown) => entity === ImportJobEntity
        ? job({ status: 'confirmed' })
        : entity === ImportConfirmationEntity ? { acknowledgedAt: null } : null,
      find: async (entity: unknown, options: { where?: { type?: string } }) => {
        if (entity === ImportConfirmedQuestionEntity) return [{ draftQuestionId: draftId }];
        if (entity === ImportUploadPartEntity) return [];
        if (entity === ImportArtifactEntity && options.where?.type === 'question_image') return [];
        if (entity === ImportArtifactEntity) return [{
          id: sourceId, type: 'source_pdf', storageKey: `${createInput().id}/source.pdf`
        }];
        return [];
      }
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource);

    await expect(repository.prepareArtifactAck(
      createInput().userId, createInput().deviceId, createInput().id, [], NOW
    )).resolves.toEqual({
      acknowledged: false,
      records: [{ kind: 'artifact', id: sourceId, storageKey: `${createInput().id}/source.pdf` }]
    });
  });

  it('requires two missing-file observations across grace and no active lease before retiring tombstones', async () => {
    const deleted: unknown[] = [];
    const inserted: unknown[] = [];
    let checkpoint: { missingSince: Date; retiredAt: Date | null } | null = null;
    const manager = {
      findOne: async (entity: unknown) => {
        if (entity === ImportJobEntity) return job({ status: 'expired', expiresAt: new Date(NOW.getTime() - 1) });
        if (entity === ImportJobLeaseEntity) return null;
        if (entity === ImportCleanupCheckpointEntity) return checkpoint;
        return null;
      },
      insert: async (entity: unknown, value: { missingSince: Date }) => {
        inserted.push(entity);
        if (entity === ImportCleanupCheckpointEntity) checkpoint = { ...value, retiredAt: null };
      },
      delete: async (entity: unknown) => { deleted.push(entity); return updateResult(); },
      update: async () => updateResult()
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource);

    await expect(repository.noteCleanupMissing(createInput().id, NOW, 60_000)).resolves.toBe(false);
    expect(inserted).toEqual([ImportCleanupCheckpointEntity]);
    expect(deleted).toEqual([]);

    checkpoint = { missingSince: new Date(NOW.getTime() - 60_001), retiredAt: null };
    await expect(repository.noteCleanupMissing(createInput().id, NOW, 60_000)).resolves.toBe(true);
    expect(deleted).toEqual([
      ImportArtifactEntity,
      ImportUploadPartEntity,
      ImportConfirmedQuestionEntity,
      ImportConfirmationEntity,
      ImportDraftQuestionEntity,
      ImportJobLeaseEntity
    ]);
  });

  it('pages cleanup candidates by an exclusive durable job-id key instead of offset', async () => {
    const cursor = '11111111-1111-4111-8111-111111111111';
    const nextId = '22222222-2222-4222-8222-222222222222';
    const trace: Array<{ method: string; input: unknown[] }> = [];
    const query = {
      leftJoin: (...input: unknown[]) => { trace.push({ method: 'leftJoin', input }); return query; },
      where: (...input: unknown[]) => { trace.push({ method: 'where', input }); return query; },
      andWhere: (...input: unknown[]) => { trace.push({ method: 'andWhere', input }); return query; },
      orderBy: (...input: unknown[]) => { trace.push({ method: 'orderBy', input }); return query; },
      take: (...input: unknown[]) => { trace.push({ method: 'take', input }); return query; },
      getMany: async () => [{ id: nextId }]
    };
    const repository = new TypeOrmImportRepository({
      getRepository: () => ({ createQueryBuilder: () => query })
    } as unknown as DataSource);

    await expect(repository.listCleanupCandidates(NOW, cursor, 2))
      .resolves.toEqual([{ jobId: nextId }]);
    expect(trace).toContainEqual({
      method: 'andWhere', input: ['job.id > :afterJobId', { afterJobId: cursor }]
    });
    expect(trace).toContainEqual({ method: 'orderBy', input: ['job.id', 'ASC'] });
    expect(trace).toContainEqual({ method: 'take', input: [2] });
    expect(trace.some(({ method }) => method === 'skip')).toBe(false);
  });

  it('lists only bounded persisted storage records after checking owner and creating device', async () => {
    const calls: Array<{ entity: unknown; options: unknown }> = [];
    const manager = {
      findOne: async (entity: unknown, options: unknown) => {
        calls.push({ entity, options });
        return job({ id: 'job-1', userId: 'user-1', deviceId: 'device-1', status: 'cancelled' });
      },
      count: async (entity: unknown, options: { where?: { type?: string } }) => {
        if (entity === ImportUploadPartEntity) return 1;
        if (options.where?.type === 'source_pdf') return 1;
        return 1;
      },
      find: async (entity: unknown, options: { skip: number; take: number; where?: { type?: string } }) => {
        calls.push({ entity, options });
        if (entity === ImportUploadPartEntity) {
          return [{ id: 'part-1', jobId: 'job-1', storageKey: 'job-1/part-0000000007.bin' }];
        }
        const source = { id: 'z-source', jobId: 'job-1', type: 'source_pdf', storageKey: 'job-1/source.pdf' };
        const image = { id: 'a-image', jobId: 'job-1', type: 'question_image', storageKey: 'job-1/artifact-image.bin' };
        if (options.where?.type === 'source_pdf') return [source].slice(0, options.take);
        if (options.where?.type === 'question_image') return [image].slice(0, options.take);
        return [image, source].slice(0, options.take);
      }
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource);

    await expect(repository.listCleanupRecords(
      'user-1', 'device-1', 'job-1', 'all', 0, 3
    )).resolves.toEqual([
      { kind: 'part', id: 'part-1', storageKey: 'job-1/part-0000000007.bin' },
      { kind: 'artifact', id: 'z-source', storageKey: 'job-1/source.pdf' },
      { kind: 'artifact', id: 'a-image', storageKey: 'job-1/artifact-image.bin' }
    ]);
    expect(calls[0]).toMatchObject({
      entity: ImportJobEntity,
      options: { where: { id: 'job-1', userId: 'user-1', deviceId: 'device-1' } }
    });
    expect(calls.filter(({ entity }) => entity !== ImportJobEntity)).toHaveLength(3);
    expect(calls.slice(1).map(({ options }) => options)).toEqual([
      expect.objectContaining({ skip: 0, take: 3, order: { partNumber: 'ASC' } }),
      expect.objectContaining({ skip: 0, take: 2, order: { id: 'ASC' } }),
      expect.objectContaining({ skip: 0, take: 1, order: { id: 'ASC' } })
    ]);
  });

  it('rejects unsafe cleanup page offsets and limits before querying', async () => {
    const dataSource = { transaction: jest.fn() } as unknown as DataSource;
    const repository = new TypeOrmImportRepository(dataSource);

    await expect(repository.listCleanupRecords(
      'user-1', 'device-1', 'job-1', 'all', -1, 32
    )).rejects.toThrow('INVALID_STATE');
    await expect(repository.listCleanupRecords(
      'user-1', 'device-1', 'job-1', 'all', 100_001, 32
    )).rejects.toThrow('INVALID_STATE');
    await expect(repository.listCleanupRecords(
      'user-1', 'device-1', 'job-1', 'all', 0, 101
    )).rejects.toThrow('INVALID_STATE');
    expect(dataSource.transaction).not.toHaveBeenCalled();
  });

  it('pages queued part tombstones by offset for file-only parts sweeps', async () => {
    const calls: Array<{ entity: unknown; options: unknown }> = [];
    const manager = {
      findOne: async () => job({
        id: 'job-1', userId: 'user-1', deviceId: 'device-1', status: 'queued'
      }),
      find: async (entity: unknown, options: { skip: number; take: number }) => {
        calls.push({ entity, options });
        return [{ id: 'part-1', jobId: 'job-1', storageKey: 'job-1/part-0000000007.bin' }];
      }
    };
    const repository = new TypeOrmImportRepository({
      transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager)
    } as unknown as DataSource);

    await expect(repository.listCleanupRecords(
      'user-1', 'device-1', 'job-1', 'parts', 7, 3
    )).resolves.toEqual([
      { kind: 'part', id: 'part-1', storageKey: 'job-1/part-0000000007.bin' }
    ]);
    expect(calls[0]).toMatchObject({
      entity: ImportUploadPartEntity,
      options: { skip: 7, take: 3, order: { partNumber: 'ASC' } }
    });
  });

  it('uses effective expiry and non-terminal predicates before returning expired ids', async () => {
    const queryTrace: string[] = [];
    const persisted = [
      job({ id: 'expired-1', status: 'queued', expiresAt: new Date('2026-08-26T07:00:00.000Z') }),
      job({ id: 'expired-2', status: 'processing', expiresAt: new Date('2026-08-26T07:30:00.000Z') }),
      job({ id: 'confirmed-1', status: 'confirmed', expiresAt: new Date('2026-08-26T07:00:00.000Z') }),
      job({ id: 'future-1', status: 'queued', expiresAt: new Date('2026-08-26T09:00:00.000Z') })
    ];
    const manager = {
      getRepository: () => ({ createQueryBuilder: () => {
        let expiresBefore: Date | undefined;
        let statuses: ImportJobStatus[] | undefined;
        const query = { setLock: (value: string) => { queryTrace.push(`lock:${value}`); return query; }, setOnLocked: (value: string) => { queryTrace.push(`onLocked:${value}`); return query; }, where: (value: string, parameters?: { now?: Date }) => { queryTrace.push(value); expiresBefore = parameters?.now; return query; }, andWhere: (value: string, parameters?: { statuses?: ImportJobStatus[] }) => { queryTrace.push(value); statuses = parameters?.statuses; return query; }, orderBy: (value: string, direction: string) => { queryTrace.push(`${value}:${direction}`); return query; }, addOrderBy: (value: string, direction: string) => { queryTrace.push(`${value}:${direction}`); return query; }, take: (value: number) => { queryTrace.push(`take:${value}`); return query; },
          getMany: async () => persisted.filter((entry) =>
            (expiresBefore === undefined || entry.expiresAt < expiresBefore) &&
            (statuses === undefined || statuses.includes(entry.status))
          ).slice(0, 1) };
        return query;
      } }),
      update: async (_entity: unknown, where: { id: string; status: ImportJobStatus }, values: { status: ImportJobStatus }) => {
        const entry = persisted.find((candidate) => candidate.id === where.id);
        if (entry === undefined || entry.status !== where.status || entry.status === 'confirmed') {
          throw new Error('attempted to expire a non-expirable job');
        }
        entry.status = values.status;
        return updateResult();
      }
    };
    const repository = new TypeOrmImportRepository({ transaction: async (work: (m: typeof manager) => Promise<unknown>) => work(manager) } as unknown as DataSource);

    await expect(repository.expireBefore(NOW)).resolves.toEqual(['expired-1', 'expired-2']);
    expect(queryTrace).toEqual(expect.arrayContaining(['lock:pessimistic_write', 'onLocked:skip_locked', 'job.expiresAt:ASC', 'job.id:ASC', 'take:100']));
    expect(persisted.find((entry) => entry.id === 'confirmed-1')?.status).toBe('confirmed');
  });

  it('maps every persisted job field, including bigint, dates, and nullable columns', async () => {
    const stored = job({
      sourceSize: '9007199254740993', errorCode: null, claimedAt: null,
      createdAt: new Date('2026-08-20T01:02:03.004Z'), updatedAt: new Date('2026-08-21T01:02:03.004Z')
    });
    const repository = new TypeOrmImportRepository({ getRepository: () => ({ findOne: async () => stored }) } as unknown as DataSource);

    await expect(repository.findOwnedJob('user-1', 'job-1')).resolves.toEqual(stored);
  });

  it('lets every error escape its transaction so TypeORM rolls it back', async () => {
    const cause = new ImportRepositoryError('INVALID_STATE');
    const dataSource = {
      transaction: async (work: (manager: object) => Promise<unknown>) => {
        await expect(work({ findOne: async () => job({ id: 'job-1', status: 'processing', claimedAt: NOW }), delete: async () => { throw cause; } })).rejects.toBe(cause);
        throw cause;
      }
    } as unknown as DataSource;
    const repository = new TypeOrmImportRepository(dataSource);

    await expect(repository.replaceDraft('job-1', NOW, { questions: [] })).rejects.toBe(cause);
  });
});
