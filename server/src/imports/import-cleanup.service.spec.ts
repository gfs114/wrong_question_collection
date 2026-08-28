import { ImportCleanupService } from './import-cleanup.service';

const NOW = new Date('2026-08-28T00:00:00.000Z');
const JOB_ID = '11111111-1111-4111-8111-111111111111';

describe('ImportCleanupService', () => {
  it('expires jobs and retains retryable tombstones when a physical deletion fails', async () => {
    const repository = {
      expireBefore: jest.fn().mockResolvedValue([JOB_ID]),
      listCleanupCandidates: jest.fn().mockResolvedValue([{ jobId: JOB_ID }]),
      listCleanupRecordsForJob: jest.fn().mockResolvedValue([{
        kind: 'artifact', id: 'source', storageKey: `${JOB_ID}/source.pdf`
      }]),
      noteCleanupMissing: jest.fn(),
      canDeleteOrphan: jest.fn()
    };
    const storage = {
      deleteStorageKey: jest.fn().mockRejectedValue(new Error('disk busy')),
      deleteJobDirectory: jest.fn(),
      jobDirectoryExists: jest.fn(),
      listJobDirectories: jest.fn().mockResolvedValue([])
    };
    const cleanup = new ImportCleanupService(repository as never, storage as never, () => NOW);

    await expect(cleanup.runOnce()).resolves.toEqual([{ jobId: JOB_ID }]);

    expect(repository.expireBefore).toHaveBeenCalledWith(NOW);
    expect(repository.listCleanupCandidates).toHaveBeenCalledWith(NOW, null, 32);
    expect(repository.noteCleanupMissing).not.toHaveBeenCalled();
    expect(storage.deleteJobDirectory).not.toHaveBeenCalled();
  });

  it('rejects unsafe unbounded cleanup options', () => {
    const repository = {
      expireBefore: jest.fn().mockResolvedValue([]),
      listCleanupCandidates: jest.fn().mockResolvedValue([])
    };
    expect(() => new ImportCleanupService(repository as never, {} as never, () => NOW, {
      graceMs: 60_000, batchSize: 101
    })).toThrow('Invalid import cleanup options');
  });

  it('retires metadata only after every recorded file and the exact job directory are absent', async () => {
    const repository = {
      expireBefore: jest.fn().mockResolvedValue([]),
      listCleanupCandidates: jest.fn().mockResolvedValue([{ jobId: JOB_ID }]),
      listCleanupRecordsForJob: jest.fn()
        .mockResolvedValueOnce([
          { kind: 'part', id: 'part', storageKey: `${JOB_ID}/part-0000000000.bin` },
          { kind: 'artifact', id: 'source', storageKey: `${JOB_ID}/source.pdf` }
        ])
        .mockResolvedValueOnce([]),
      noteCleanupMissing: jest.fn().mockResolvedValue(false),
      canDeleteOrphan: jest.fn()
    };
    const storage = {
      deleteStorageKey: jest.fn().mockResolvedValue(undefined),
      deleteJobDirectory: jest.fn().mockResolvedValue(undefined),
      jobDirectoryExists: jest.fn().mockResolvedValue(false),
      listJobDirectories: jest.fn().mockResolvedValue([])
    };
    const cleanup = new ImportCleanupService(repository as never, storage as never, () => NOW, {
      graceMs: 60_000, batchSize: 32
    });

    await cleanup.runOnce();

    expect(storage.deleteStorageKey.mock.calls.map((call: string[]) => call[0])).toEqual([
      `${JOB_ID}/part-0000000000.bin`, `${JOB_ID}/source.pdf`
    ]);
    expect(storage.deleteJobDirectory).toHaveBeenCalledWith(JOB_ID);
    expect(repository.noteCleanupMissing).toHaveBeenCalledWith(JOB_ID, NOW, 60_000);
  });

  it('deletes only old direct UUID orphan candidates approved by database and lease checks', async () => {
    const recentId = '22222222-2222-4222-8222-222222222222';
    const deniedId = '33333333-3333-4333-8333-333333333333';
    const repository = {
      expireBefore: jest.fn().mockResolvedValue([]),
      listCleanupCandidates: jest.fn().mockResolvedValue([]),
      canDeleteOrphan: jest.fn(async (jobId: string) => jobId === JOB_ID)
    };
    const storage = {
      listJobDirectories: jest.fn().mockResolvedValue([
        { jobId: JOB_ID, modifiedAt: new Date('2026-08-26T00:00:00.000Z') },
        { jobId: deniedId, modifiedAt: new Date('2026-08-26T00:00:00.000Z') },
        { jobId: recentId, modifiedAt: new Date('2026-08-27T23:59:30.001Z') }
      ]),
      deleteJobDirectory: jest.fn().mockResolvedValue(undefined)
    };
    const cleanup = new ImportCleanupService(repository as never, storage as never, () => NOW, {
      graceMs: 60_000, batchSize: 32
    });

    await cleanup.runOnce();

    expect(repository.canDeleteOrphan).toHaveBeenCalledWith(JOB_ID, NOW, 60_000);
    expect(repository.canDeleteOrphan).toHaveBeenCalledWith(deniedId, NOW, 60_000);
    expect(repository.canDeleteOrphan).not.toHaveBeenCalledWith(recentId, expect.anything(), expect.anything());
    expect(storage.deleteJobDirectory).toHaveBeenCalledTimes(1);
    expect(storage.deleteJobDirectory).toHaveBeenCalledWith(JOB_ID);
  });

  it('uses a rotating keyset so a failed first candidate cannot starve the next run', async () => {
    const nextJobId = '22222222-2222-4222-8222-222222222222';
    const repository = {
      expireBefore: jest.fn().mockResolvedValue([]),
      listCleanupCandidates: jest.fn(async (_now: Date, afterJobId: string | null) => {
        if (afterJobId === null) return [{ jobId: JOB_ID }];
        if (afterJobId === JOB_ID) return [{ jobId: nextJobId }];
        return [];
      }),
      listCleanupRecordsForJob: jest.fn(async (jobId: string, offset: number) => offset === 0 ? [{
        kind: 'artifact', id: jobId, storageKey: `${jobId}/source.pdf`
      }] : []),
      noteCleanupMissing: jest.fn().mockResolvedValue(false),
      canDeleteOrphan: jest.fn()
    };
    const storage = {
      deleteStorageKey: jest.fn(async (key: string) => {
        if (key.startsWith(`${JOB_ID}/`)) throw new Error('disk busy');
      }),
      deleteJobDirectory: jest.fn().mockResolvedValue(undefined),
      jobDirectoryExists: jest.fn().mockResolvedValue(false),
      listJobDirectories: jest.fn().mockResolvedValue([])
    };
    const cleanup = new ImportCleanupService(repository as never, storage as never, () => NOW, {
      graceMs: 60_000, batchSize: 1, maxPages: 1
    } as never);

    await cleanup.runOnce();
    await cleanup.runOnce();

    expect(repository.listCleanupCandidates.mock.calls.map((call: unknown[]) => call[1]))
      .toEqual([null, JOB_ID]);
    expect(storage.deleteStorageKey).toHaveBeenCalledWith(`${nextJobId}/source.pdf`);
    expect(repository.noteCleanupMissing).toHaveBeenCalledWith(nextJobId, NOW, 60_000);
  });

  it('continues with later candidates in the same page after the first deletion fails', async () => {
    const nextJobId = '22222222-2222-4222-8222-222222222222';
    const repository = {
      expireBefore: jest.fn().mockResolvedValue([]),
      listCleanupCandidates: jest.fn().mockResolvedValue([
        { jobId: JOB_ID }, { jobId: nextJobId }
      ]),
      listCleanupRecordsForJob: jest.fn(async (jobId: string, offset: number) => offset === 0 ? [{
        kind: 'artifact', id: jobId, storageKey: `${jobId}/source.pdf`
      }] : []),
      noteCleanupMissing: jest.fn().mockResolvedValue(false),
      canDeleteOrphan: jest.fn()
    };
    const storage = {
      deleteStorageKey: jest.fn(async (key: string) => {
        if (key.startsWith(`${JOB_ID}/`)) throw new Error('disk busy');
      }),
      deleteJobDirectory: jest.fn().mockResolvedValue(undefined),
      jobDirectoryExists: jest.fn().mockResolvedValue(false),
      listJobDirectories: jest.fn().mockResolvedValue([])
    };
    const cleanup = new ImportCleanupService(repository as never, storage as never, () => NOW, {
      graceMs: 60_000, batchSize: 2, maxPages: 1
    } as never);

    await cleanup.runOnce();

    expect(storage.deleteStorageKey).toHaveBeenCalledWith(`${nextJobId}/source.pdf`);
    expect(repository.noteCleanupMissing).toHaveBeenCalledWith(nextJobId, NOW, 60_000);
  });

  it('continues through keyset pages so active prefixes do not hide an old orphan', async () => {
    const activeId = '11111111-1111-4111-8111-111111111111';
    const recentId = '22222222-2222-4222-8222-222222222222';
    const oldId = '33333333-3333-4333-8333-333333333333';
    const repository = {
      expireBefore: jest.fn().mockResolvedValue([]),
      listCleanupCandidates: jest.fn().mockResolvedValue([]),
      canDeleteOrphan: jest.fn(async (jobId: string) => jobId === oldId)
    };
    const storage = {
      listJobDirectories: jest.fn(async (_limit: number, afterJobId: string | null) => {
        if (afterJobId === null) return [
          { jobId: activeId, modifiedAt: new Date('2026-08-26T00:00:00.000Z') },
          { jobId: recentId, modifiedAt: new Date('2026-08-27T23:59:30.001Z') }
        ];
        if (afterJobId === recentId) return [
          { jobId: oldId, modifiedAt: new Date('2026-08-26T00:00:00.000Z') }
        ];
        return [];
      }),
      deleteJobDirectory: jest.fn().mockResolvedValue(undefined)
    };
    const cleanup = new ImportCleanupService(repository as never, storage as never, () => NOW, {
      graceMs: 60_000, batchSize: 2, maxPages: 2
    } as never);

    await cleanup.runOnce();

    expect(storage.listJobDirectories.mock.calls.map((call: unknown[]) => call[1]))
      .toEqual([null, recentId]);
    expect(storage.deleteJobDirectory).toHaveBeenCalledWith(oldId);
  });
});
