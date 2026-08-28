import {
  ConflictException,
  HttpException,
  NotFoundException,
  PayloadTooLargeException
} from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import { link, mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  ImportJobRecord,
  ImportRepository
} from './import.contracts';
import { ImportRepositoryError } from './import.repository';
import {
  ImportStorageError,
  ImportStoragePublishFenceError,
  ImportStorageService,
  StoredFile
} from './import-storage.service';
import { ImportAssemblyRetryPolicy, ImportService } from './import.service';

const JOB_ID = '11111111-1111-4111-8111-111111111111';
const USER_ID = '22222222-2222-4222-8222-222222222222';
const DEVICE_ID = '33333333-3333-4333-8333-333333333333';
const SOURCE_HASH = 'a'.repeat(64);
const MAX_PDF_BYTES = 209_715_200;
const PART_BYTES = 4_194_304;

function job(overrides: Partial<ImportJobRecord> = {}): ImportJobRecord {
  return {
    id: JOB_ID,
    userId: USER_ID,
    deviceId: DEVICE_ID,
    bankName: 'Algebra mistakes',
    subject: 'Math',
    pageStart: 1,
    pageEnd: 20,
    sourceSha256: SOURCE_HASH,
    sourceSize: '8',
    partCount: 2,
    status: 'uploading',
    progressCurrent: 0,
    progressTotal: 0,
    retryCount: 0,
    errorCode: null,
    claimedAt: null,
    expiresAt: new Date('2026-08-27T00:00:00.000Z'),
    createdAt: new Date('2026-08-26T00:00:00.000Z'),
    updatedAt: new Date('2026-08-26T00:00:00.000Z'),
    ...overrides
  };
}

function repository(overrides: Partial<ImportRepository> = {}): jest.Mocked<ImportRepository> {
  return {
    tryAcquireAssemblyLease: jest.fn().mockResolvedValue(true),
    renewAssemblyLease: jest.fn().mockResolvedValue(true),
    releaseAssemblyLease: jest.fn().mockResolvedValue(true),
    createJob: jest.fn().mockResolvedValue(job()),
    findOwnedJob: jest.fn().mockResolvedValue(job()),
    recordPart: jest.fn().mockResolvedValue(undefined),
    prepareSource: jest.fn().mockResolvedValue(undefined),
    queueCompletedUpload: jest.fn().mockResolvedValue(undefined),
    claimNext: jest.fn(),
    updateProgress: jest.fn(),
    replaceDraft: jest.fn(),
    markFailure: jest.fn(),
    cancelOwned: jest.fn().mockResolvedValue(true),
    listCleanupRecords: jest.fn().mockResolvedValue([]),
    expireBefore: jest.fn(),
    ...overrides
  } as jest.Mocked<ImportRepository>;
}

type StorageMock = {
  writePart: jest.Mock;
  mergeParts: jest.Mock;
  deleteStorageKey: jest.Mock;
  deleteJobDirectory: jest.Mock;
  jobDirectoryExists: jest.Mock;
  partKey: jest.Mock;
  sourceKey: jest.Mock;
  artifactKey: jest.Mock;
};

function storage(overrides: Partial<StorageMock> = {}): StorageMock {
  return {
    writePart: jest.fn().mockResolvedValue({
      storageKey: `${JOB_ID}/part-0000000000.bin`,
      size: 4,
      sha256: createHash('sha256').update('part').digest('hex'),
      created: true
    } satisfies StoredFile),
    mergeParts: jest.fn().mockResolvedValue({
      storageKey: `${JOB_ID}/source.pdf`,
      size: 8,
      sha256: SOURCE_HASH,
      created: true
    } satisfies StoredFile),
    deleteStorageKey: jest.fn().mockResolvedValue(undefined),
    deleteJobDirectory: jest.fn().mockResolvedValue(undefined),
    jobDirectoryExists: jest.fn().mockResolvedValue(false),
    partKey: jest.fn((jobId: string, partIndex: number) =>
      `${jobId}/part-${partIndex.toString().padStart(10, '0')}.bin`
    ),
    sourceKey: jest.fn((jobId: string) => `${jobId}/source.pdf`),
    artifactKey: jest.fn((jobId: string, artifactId: string) =>
      `${jobId.toLowerCase()}/artifact-${artifactId.toLowerCase()}.bin`
    ),
    ...overrides
  } as StorageMock;
}

function service(
  repo = repository(),
  files = storage(),
  retryPolicy?: ImportAssemblyRetryPolicy
): ImportService {
  return new ImportService(repo, files as unknown as ImportStorageService, {
    maxPdfBytes: MAX_PDF_BYTES,
    partBytes: PART_BYTES
  }, retryPolicy);
}

function publicResponse(error: unknown): unknown {
  expect(error).toBeInstanceOf(HttpException);
  return (error as HttpException).getResponse();
}

describe('ImportService', () => {
  it('returns an ordered review draft without private storage keys', async () => {
    const repo = repository();
    (repo as unknown as { getReviewDraft: jest.Mock }).getReviewDraft = jest.fn().mockResolvedValue({
      job: job({ status: 'review', expiresAt: new Date('2099-08-27T00:00:00.000Z') }),
      questions: [{
        id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        position: 0,
        type: 'single_choice',
        question: '1 + 1 = ?',
        options: { A: '1', B: '2' },
        answer: 'B',
        analysis: 'Addition',
        pageStart: 1,
        pageEnd: 1,
        confidence: 0.99,
        reviewRequired: false,
        artifacts: [{
          id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          type: 'question_image',
          storageKey: `${JOB_ID}/artifact-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg`,
          sha256: 'b'.repeat(64),
          size: '123',
          expiresAt: job().expiresAt
        }]
      }]
    });

    const result = await (service(repo) as unknown as {
      getDraft(userId: string, jobId: string): Promise<unknown>;
    }).getDraft(USER_ID, JOB_ID);

    expect(result).toEqual(expect.objectContaining({
      jobId: JOB_ID,
      status: 'review',
      questions: [expect.objectContaining({
        draftQuestionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        images: [{
          artifactId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          sha256: 'b'.repeat(64),
          size: 123,
          contentType: 'image/jpeg'
        }]
      })]
    }));
    expect(JSON.stringify(result)).not.toMatch(/storageKey|source\.pdf|\\\\/);
  });

  it('binds confirmation to the creating device and delegates one canonical payload', async () => {
    const confirmed = {
      bankId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      questions: [{
        draftQuestionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        questionId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        images: []
      }],
      expiresAt: job().expiresAt.toISOString()
    };
    const repo = repository({ findOwnedJob: jest.fn().mockResolvedValue(job({
      status: 'review', expiresAt: new Date('2099-08-27T00:00:00.000Z')
    })) });
    (repo as unknown as { confirmImport: jest.Mock }).confirmImport = jest.fn().mockResolvedValue(confirmed);
    const input = {
      bankName: 'Edited bank',
      subject: 'Math',
      questions: [{
        draftQuestionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        type: 'single_choice',
        question: 'Edited question',
        options: { A: '1', B: '2' },
        answer: 'B',
        analysis: 'Edited analysis',
        reviewed: true
      }]
    };
    const imports = service(repo) as unknown as {
      confirm(userId: string, deviceId: string, jobId: string, body: unknown): Promise<unknown>;
    };

    await expect(imports.confirm(USER_ID, 'other-device', JOB_ID, input))
      .rejects.toBeInstanceOf(NotFoundException);
    await expect(imports.confirm(USER_ID, DEVICE_ID, JOB_ID, input)).resolves.toEqual(confirmed);
    expect((repo as unknown as { confirmImport: jest.Mock }).confirmImport)
      .toHaveBeenCalledWith(USER_ID, DEVICE_ID, JOB_ID, expect.any(String), input);
  });

  it('opens only an exact confirmed question image and revalidates metadata after opening', async () => {
    const artifact = {
      artifactId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      storageKey: `${JOB_ID}/artifact-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.bin`,
      sha256: 'b'.repeat(64),
      size: 123,
      expiresAt: job().expiresAt
    };
    const repo = repository();
    const lookup = jest.fn().mockResolvedValue(artifact);
    (repo as unknown as { findDownloadArtifact: jest.Mock }).findDownloadArtifact = lookup;
    const close = jest.fn().mockResolvedValue(undefined);
    const files = storage();
    (files as unknown as { openReadStream: jest.Mock }).openReadStream = jest.fn().mockResolvedValue({
      stream: { pipe: jest.fn() }, size: 123, close
    });

    const result = await (service(repo, files) as unknown as {
      downloadArtifact(userId: string, deviceId: string, jobId: string, artifactId: string): Promise<unknown>;
    }).downloadArtifact(USER_ID, DEVICE_ID, JOB_ID, artifact.artifactId);

    expect(lookup).toHaveBeenCalledTimes(2);
    expect((files as unknown as { openReadStream: jest.Mock }).openReadStream)
      .toHaveBeenCalledWith(artifact.storageKey, artifact.size, {
        jobId: JOB_ID, artifactId: artifact.artifactId
      });
    expect(result).toEqual(expect.objectContaining({
      artifactId: artifact.artifactId,
      sha256: artifact.sha256,
      size: artifact.size,
      close
    }));
  });

  it('rejects a noncanonical artifact binding before opening storage', async () => {
    const artifactId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const repo = repository();
    (repo as unknown as { findDownloadArtifact: jest.Mock }).findDownloadArtifact = jest.fn()
      .mockResolvedValue({
        artifactId,
        storageKey: `${JOB_ID}/source.pdf`,
        sha256: 'b'.repeat(64),
        size: 123,
        expiresAt: job().expiresAt
      });
    const files = storage();
    (files as unknown as { openReadStream: jest.Mock }).openReadStream = jest.fn();

    await expect((service(repo, files) as unknown as {
      downloadArtifact(userId: string, deviceId: string, jobId: string, id: string): Promise<unknown>;
    }).downloadArtifact(USER_ID, DEVICE_ID, JOB_ID, artifactId)).rejects.toBeInstanceOf(NotFoundException);
    expect((files as unknown as { openReadStream: jest.Mock }).openReadStream).not.toHaveBeenCalled();
  });

  it('acknowledges only after every confirmed file and job directory is deleted', async () => {
    const repo = repository({ findOwnedJob: jest.fn().mockResolvedValue(job({
      status: 'confirmed', expiresAt: new Date('2099-08-27T00:00:00.000Z')
    })) });
    const prepareArtifactAck = jest.fn().mockResolvedValue({
      acknowledged: false,
      records: [{
        kind: 'artifact', id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        storageKey: `${JOB_ID}/artifact-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg`
      }]
    });
    const markArtifactsAcknowledged = jest.fn().mockResolvedValue(undefined);
    Object.assign(repo, { prepareArtifactAck, markArtifactsAcknowledged });
    const files = storage();

    await (service(repo, files) as unknown as {
      ackArtifacts(userId: string, deviceId: string, jobId: string, ids: string[]): Promise<void>;
    }).ackArtifacts(USER_ID, DEVICE_ID, JOB_ID, ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb']);

    expect(files.deleteStorageKey).toHaveBeenCalledWith(
      `${JOB_ID}/artifact-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg`
    );
    expect(files.deleteJobDirectory).toHaveBeenCalledWith(JOB_ID);
    expect(files.deleteJobDirectory.mock.invocationCallOrder[0]).toBeLessThan(
      markArtifactsAcknowledged.mock.invocationCallOrder[0]
    );
  });

  it('acknowledges an empty image set after cleaning non-image import files', async () => {
    const repo = repository({ findOwnedJob: jest.fn().mockResolvedValue(job({
      status: 'confirmed', expiresAt: new Date('2099-08-27T00:00:00.000Z')
    })) });
    const prepareArtifactAck = jest.fn().mockResolvedValue({
      acknowledged: false,
      records: [{ kind: 'artifact', id: 'source', storageKey: `${JOB_ID}/source.pdf` }]
    });
    const markArtifactsAcknowledged = jest.fn().mockResolvedValue(undefined);
    Object.assign(repo, { prepareArtifactAck, markArtifactsAcknowledged });
    const files = storage();

    await (service(repo, files) as unknown as {
      ackArtifacts(userId: string, deviceId: string, jobId: string, ids: string[]): Promise<void>;
    }).ackArtifacts(USER_ID, DEVICE_ID, JOB_ID, []);

    expect(prepareArtifactAck).toHaveBeenCalledWith(USER_ID, DEVICE_ID, JOB_ID, [], expect.any(Date));
    expect(files.deleteStorageKey).toHaveBeenCalledWith(`${JOB_ID}/source.pdf`);
    expect(markArtifactsAcknowledged).toHaveBeenCalledWith(USER_ID, DEVICE_ID, JOB_ID, expect.any(Date));
  });

  it('downloads through the persisted lowercase job id after an uppercase route lookup', async () => {
    const canonicalJobId = 'abcdefab-cdef-4abc-8def-abcdefabcdef';
    const routeJobId = canonicalJobId.toUpperCase();
    const artifactId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const artifact = {
      artifactId,
      storageKey: `${canonicalJobId}/artifact-${artifactId}.bin`,
      sha256: 'b'.repeat(64), size: 123,
      expiresAt: new Date('2099-08-27T00:00:00.000Z')
    };
    const findDownloadArtifact = jest.fn(async (
      _userId: string, _deviceId: string, persistedJobId: string
    ) => persistedJobId === canonicalJobId ? artifact : null);
    const repo = repository({
      findOwnedJob: jest.fn().mockResolvedValue(job({
        id: canonicalJobId, status: 'confirmed', expiresAt: new Date('2099-08-27T00:00:00.000Z')
      })),
      findDownloadArtifact
    });
    const files = storage();
    const close = jest.fn().mockResolvedValue(undefined);
    (files as unknown as { openReadStream: jest.Mock }).openReadStream = jest.fn().mockResolvedValue({
      stream: { pipe: jest.fn() }, size: 123, close
    });

    await expect((service(repo, files) as unknown as {
      downloadArtifact(userId: string, deviceId: string, jobId: string, id: string): Promise<unknown>;
    }).downloadArtifact(USER_ID, DEVICE_ID, routeJobId, artifactId)).resolves.toMatchObject({ artifactId });

    expect(findDownloadArtifact).toHaveBeenCalledTimes(2);
    expect(findDownloadArtifact.mock.calls.every((call: unknown[]) => call[2] === canonicalJobId)).toBe(true);
    expect(files.artifactKey).toHaveBeenCalledWith(canonicalJobId, artifactId);
    expect((files as unknown as { openReadStream: jest.Mock }).openReadStream)
      .toHaveBeenCalledWith(artifact.storageKey, 123, { jobId: canonicalJobId, artifactId });
  });

  it('keeps download device isolation opaque before artifact lookup', async () => {
    const findDownloadArtifact = jest.fn();
    const repo = repository({
      findOwnedJob: jest.fn().mockResolvedValue(job({ deviceId: 'other-device' })),
      findDownloadArtifact
    });

    await expect((service(repo) as unknown as {
      downloadArtifact(userId: string, deviceId: string, jobId: string, id: string): Promise<unknown>;
    }).downloadArtifact(
      USER_ID, DEVICE_ID, JOB_ID, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    )).rejects.toBeInstanceOf(NotFoundException);
    expect(findDownloadArtifact).not.toHaveBeenCalled();
  });

  it('acknowledges through only the persisted lowercase job id after an uppercase route lookup', async () => {
    const canonicalJobId = 'abcdefab-cdef-4abc-8def-abcdefabcdef';
    const routeJobId = canonicalJobId.toUpperCase();
    const artifactId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const prepareArtifactAck = jest.fn().mockResolvedValue({
      acknowledged: false,
      records: [{
        kind: 'artifact', id: artifactId,
        storageKey: `${canonicalJobId}/artifact-${artifactId}.bin`
      }]
    });
    const markArtifactsAcknowledged = jest.fn().mockResolvedValue(undefined);
    const repo = repository({
      findOwnedJob: jest.fn().mockResolvedValue(job({
        id: canonicalJobId, status: 'confirmed', expiresAt: new Date('2099-08-27T00:00:00.000Z')
      })),
      prepareArtifactAck,
      markArtifactsAcknowledged
    });
    const files = storage();

    await expect((service(repo, files) as unknown as {
      ackArtifacts(userId: string, deviceId: string, jobId: string, ids: string[]): Promise<void>;
    }).ackArtifacts(USER_ID, DEVICE_ID, routeJobId, [artifactId])).resolves.toBeUndefined();

    expect(prepareArtifactAck).toHaveBeenCalledWith(
      USER_ID, DEVICE_ID, canonicalJobId, [artifactId], expect.any(Date)
    );
    expect(files.deleteStorageKey).toHaveBeenCalledWith(`${canonicalJobId}/artifact-${artifactId}.bin`);
    expect(files.deleteJobDirectory).toHaveBeenCalledWith(canonicalJobId);
    expect(files.jobDirectoryExists).toHaveBeenCalledWith(canonicalJobId);
    expect(markArtifactsAcknowledged).toHaveBeenCalledWith(
      USER_ID, DEVICE_ID, canonicalJobId, expect.any(Date)
    );
  });

  it('confirms through the persisted lowercase job id after an uppercase route lookup', async () => {
    const canonicalJobId = 'abcdefab-cdef-4abc-8def-abcdefabcdef';
    const routeJobId = canonicalJobId.toUpperCase();
    const input = {
      bankName: 'Bank', subject: 'Math', questions: [{
        draftQuestionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        type: 'short_answer', question: 'Question', options: null,
        answer: null, analysis: null, reviewed: true
      }]
    };
    const confirmImport = jest.fn().mockResolvedValue({
      bankId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', questions: [],
      expiresAt: '2099-08-27T00:00:00.000Z'
    });
    const repo = repository({
      findOwnedJob: jest.fn().mockResolvedValue(job({
        id: canonicalJobId, status: 'review', expiresAt: new Date('2099-08-27T00:00:00.000Z')
      })),
      confirmImport
    });

    await (service(repo) as unknown as {
      confirm(userId: string, deviceId: string, jobId: string, body: typeof input): Promise<unknown>;
    }).confirm(USER_ID, DEVICE_ID, routeJobId, input);

    expect(confirmImport).toHaveBeenCalledWith(
      USER_ID, DEVICE_ID, canonicalJobId, expect.any(String), input
    );
  });

  it('creates an uploading job for the authenticated user and device with a derived part count', async () => {
    const repo = repository();
    repo.createJob.mockImplementation(async (input) => job({ ...input, id: JOB_ID }));
    const imports = service(repo);

    const result = await imports.create(USER_ID, DEVICE_ID, {
      bankName: 'Algebra mistakes',
      subject: 'Math',
      pageStart: 1,
      pageEnd: 20,
      sourceSize: PART_BYTES + 1,
      sourceSha256: SOURCE_HASH
    });

    expect(repo.createJob).toHaveBeenCalledWith(expect.objectContaining({
      userId: USER_ID,
      deviceId: DEVICE_ID,
      sourceSize: String(PART_BYTES + 1),
      partCount: 2
    }));
    expect(result).toEqual(expect.objectContaining({
      jobId: JOB_ID,
      status: 'uploading',
      partCount: 2
    }));
    expect(JSON.stringify(result)).not.toMatch(/storageKey|claimedAt|retryCount|deviceId|userId/);
  });

  it('enforces the 200 MB total limit before creating a database row', async () => {
    const repo = repository();
    const imports = service(repo);

    await expect(imports.create(USER_ID, DEVICE_ID, {
      bankName: 'Bank', subject: 'Math', pageStart: 1, pageEnd: 1,
      sourceSize: MAX_PDF_BYTES + 1, sourceSha256: SOURCE_HASH
    })).rejects.toBeInstanceOf(PayloadTooLargeException);
    expect(repo.createJob).not.toHaveBeenCalled();
  });

  it('rejects a part whose declared hash does not match its bytes before touching storage', async () => {
    const files = storage();
    const imports = service(repository(), files);

    await expect(imports.uploadPart(
      USER_ID,
      DEVICE_ID,
      JOB_ID,
      0,
      Buffer.from('part'),
      '0'.repeat(64)
    )).rejects.toMatchObject({ status: 400 });
    expect(files.writePart).not.toHaveBeenCalled();
  });

  it.each([Buffer.alloc(0), Buffer.alloc(PART_BYTES + 1)])(
    'rejects empty and oversized part bodies before touching storage',
    async (body) => {
      const files = storage();
      const imports = service(repository(), files);
      await expect(imports.uploadPart(
        USER_ID,
        DEVICE_ID,
        JOB_ID,
        0,
        body,
        createHash('sha256').update(body).digest('hex')
      )).rejects.toBeInstanceOf(HttpException);
      expect(files.writePart).not.toHaveBeenCalled();
    }
  );

  it('binds part upload to the creating device and expected part range', async () => {
    const files = storage();
    const imports = service(repository(), files);

    await expect(imports.uploadPart(
      USER_ID,
      'other-device',
      JOB_ID,
      0,
      Buffer.from('part'),
      createHash('sha256').update('part').digest('hex')
    )).rejects.toBeInstanceOf(NotFoundException);
    await expect(imports.uploadPart(
      USER_ID,
      DEVICE_ID,
      JOB_ID,
      2,
      Buffer.from('part'),
      createHash('sha256').update('part').digest('hex')
    )).rejects.toMatchObject({ status: 400 });
    expect(files.writePart).not.toHaveBeenCalled();
  });

  it('uses the persisted canonical job id for storage and repository work after an uppercase route lookup', async () => {
    const routeJobId = JOB_ID.toUpperCase();
    const partBody = Buffer.from('part');
    const partHash = createHash('sha256').update(partBody).digest('hex');
    const uploadRepo = repository({ findOwnedJob: jest.fn().mockResolvedValue(job()) });
    const uploadFiles = storage();
    await service(uploadRepo, uploadFiles).uploadPart(
      USER_ID, DEVICE_ID, routeJobId, 0, partBody, partHash
    );
    expect(uploadFiles.writePart).toHaveBeenCalledWith(
      JOB_ID, 0, partBody, partHash, partBody.length, expect.any(Function)
    );
    expect(uploadRepo.recordPart).toHaveBeenCalledWith(expect.objectContaining({ jobId: JOB_ID }));

    const completeRepo = repository({ findOwnedJob: jest.fn().mockResolvedValue(job()) });
    const completeFiles = storage();
    await expect(service(completeRepo, completeFiles).complete(
      USER_ID, DEVICE_ID, routeJobId, { partCount: 2, sourceSha256: SOURCE_HASH }
    )).resolves.toEqual({ jobId: JOB_ID, status: 'queued' });
    expect(completeRepo.tryAcquireAssemblyLease).toHaveBeenCalledWith(
      JOB_ID, expect.any(String), expect.any(Date), expect.any(Date)
    );
    const acquiredAt = completeRepo.tryAcquireAssemblyLease.mock.calls[0][2] as Date;
    const acquiredUntil = completeRepo.tryAcquireAssemblyLease.mock.calls[0][3] as Date;
    expect(acquiredUntil.getTime() - acquiredAt.getTime()).toBe(60_000);
    expect(completeFiles.mergeParts).toHaveBeenCalledWith(
      JOB_ID, 2, 8, SOURCE_HASH, expect.any(Function)
    );
    expect(completeRepo.queueCompletedUpload).toHaveBeenCalledWith(
      USER_ID, DEVICE_ID, JOB_ID, expect.any(Object)
    );

    const cancelRepo = repository({ findOwnedJob: jest.fn().mockResolvedValue(job()) });
    await service(cancelRepo).cancel(USER_ID, DEVICE_ID, routeJobId);
    expect(cancelRepo.tryAcquireAssemblyLease).toHaveBeenCalledWith(
      JOB_ID, expect.any(String), expect.any(Date), expect.any(Date)
    );
    expect(cancelRepo.cancelOwned).toHaveBeenCalledWith(USER_ID, DEVICE_ID, JOB_ID);
  });

  it('persists a deterministic part manifest before publishing bytes and accepts identical retries', async () => {
    const files = storage({
      writePart: jest.fn().mockResolvedValue({
        storageKey: `${JOB_ID}/part-0000000000.bin`,
        size: 4,
        sha256: createHash('sha256').update('part').digest('hex'),
        created: false
      })
    });
    const repo = repository();
    const imports = service(repo, files);

    await expect(imports.uploadPart(
      USER_ID,
      DEVICE_ID,
      JOB_ID,
      0,
      Buffer.from('part'),
      createHash('sha256').update('part').digest('hex')
    )).resolves.toBeUndefined();
    expect(repo.recordPart).toHaveBeenCalledTimes(1);
    expect(repo.recordPart).toHaveBeenCalledWith(expect.objectContaining({
      jobId: JOB_ID,
      partNumber: 0,
      storageKey: `${JOB_ID}/part-0000000000.bin`,
      size: '4',
      sha256: createHash('sha256').update('part').digest('hex')
    }));
    expect(repo.recordPart.mock.invocationCallOrder[0]).toBeLessThan(
      files.writePart.mock.invocationCallOrder[0]
    );
    expect(files.deleteStorageKey).not.toHaveBeenCalled();
  });

  it('maps a different duplicate part to stable 409', async () => {
    const files = storage({
      writePart: jest.fn().mockRejectedValue(
        new ImportStorageError('UPLOAD_PART_CONFLICT', new Error('private path G:\\incoming'))
      )
    });
    const imports = service(repository(), files);

    await expect(imports.uploadPart(
      USER_ID,
      DEVICE_ID,
      JOB_ID,
      0,
      Buffer.from('part'),
      createHash('sha256').update('part').digest('hex')
    )).rejects.toBeInstanceOf(ConflictException);
  });

  it('does not publish a part when its durable manifest is rejected', async () => {
    const repo = repository({
      recordPart: jest.fn().mockRejectedValue(new ImportRepositoryError('INVALID_STATE'))
    });
    const files = storage();
    const imports = service(repo, files);

    await expect(imports.uploadPart(
      USER_ID,
      DEVICE_ID,
      JOB_ID,
      0,
      Buffer.from('part'),
      createHash('sha256').update('part').digest('hex')
    )).rejects.toBeInstanceOf(ConflictException);
    expect(files.writePart).not.toHaveBeenCalled();
    expect(files.deleteStorageKey).not.toHaveBeenCalled();
  });

  it('never publishes after a commit-unknown manifest result and a retry can discover the row first', async () => {
    const files = storage();
    const recordPart = jest.fn()
      .mockRejectedValueOnce(new Error('commit result unknown at private DB host'))
      .mockResolvedValueOnce(undefined);
    const repo = repository({ recordPart });
    const imports = service(repo, files);

    await expect(imports.uploadPart(
      USER_ID, DEVICE_ID, JOB_ID, 0, Buffer.from('part'),
      createHash('sha256').update('part').digest('hex')
    )).rejects.toBeInstanceOf(HttpException);
    expect(files.writePart).not.toHaveBeenCalled();

    await expect(imports.uploadPart(
      USER_ID, DEVICE_ID, JOB_ID, 0, Buffer.from('part'),
      createHash('sha256').update('part').digest('hex')
    )).resolves.toBeUndefined();
    expect(recordPart).toHaveBeenCalledTimes(2);
    expect(files.writePart).toHaveBeenCalledTimes(1);
  });

  it('keeps a durable part row when storage publication fails so cancellation can retry cleanup', async () => {
    const record = {
      kind: 'part' as const,
      id: 'part-row',
      storageKey: `${JOB_ID}/part-0000000000.bin`
    };
    const repo = repository({
      listCleanupRecords: jest.fn()
        .mockResolvedValueOnce([record])
        .mockResolvedValueOnce([])
    });
    const files = storage({
      writePart: jest.fn().mockRejectedValue(new ImportStorageError('INSUFFICIENT_STORAGE', new Error('disk full')))
    });
    const imports = service(repo, files);

    await expect(imports.uploadPart(
      USER_ID, DEVICE_ID, JOB_ID, 0, Buffer.from('part'),
      createHash('sha256').update('part').digest('hex')
    )).rejects.toMatchObject({ status: 507 });
    expect(repo.recordPart).toHaveBeenCalledTimes(1);

    await imports.cancel(USER_ID, DEVICE_ID, JOB_ID);
    expect(files.deleteStorageKey).toHaveBeenCalledWith(record.storageKey);
  });

  it('fences cancellation until a manifest-first part publication finishes', async () => {
    let status: ImportJobRecord['status'] = 'uploading';
    let owner: string | null = null;
    let announceBusy: () => void = () => undefined;
    const busySeen = new Promise<void>((resolve) => { announceBusy = resolve; });
    const record = { kind: 'part' as const, id: 'part-row', storageKey: `${JOB_ID}/part-0000000000.bin` };
    const repo = repository({
      findOwnedJob: jest.fn().mockImplementation(async () => job({ status })),
      tryAcquireAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (owner !== null) { announceBusy(); return false; }
        owner = token;
        return true;
      }),
      renewAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => owner === token),
      releaseAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (owner !== token) return false;
        owner = null;
        return true;
      }),
      cancelOwned: jest.fn().mockImplementation(async () => { status = 'cancelled'; return true; }),
      listCleanupRecords: jest.fn().mockResolvedValue([record])
    });
    let announceWrite: () => void = () => undefined;
    let releaseWrite: () => void = () => undefined;
    const writeEntered = new Promise<void>((resolve) => { announceWrite = resolve; });
    const holdWrite = new Promise<void>((resolve) => { releaseWrite = resolve; });
    const files = storage({
      writePart: jest.fn().mockImplementation(async () => {
        announceWrite();
        await holdWrite;
        return {
          storageKey: record.storageKey,
          size: 4,
          sha256: createHash('sha256').update('part').digest('hex'),
          created: true
        };
      })
    });
    let simulatedNow = 0;
    let uploading: Promise<void>;
    let allowRetry: () => void = () => undefined;
    const retryGate = new Promise<void>((resolve) => { allowRetry = resolve; });
    const imports = service(repo, files, {
      maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
      now: () => simulatedNow,
      sleep: async (milliseconds) => {
        simulatedNow += milliseconds;
        await retryGate;
      }
    });

    uploading = imports.uploadPart(
      USER_ID, DEVICE_ID, JOB_ID, 0, Buffer.from('part'),
      createHash('sha256').update('part').digest('hex')
    );
    await writeEntered;
    const cancelling = imports.cancel(USER_ID, DEVICE_ID, JOB_ID);

    await expect(Promise.race([
      busySeen.then(() => 'busy'),
      cancelling.then(() => 'cancelled')
    ])).resolves.toBe('busy');
    releaseWrite();
    await uploading;
    allowRetry();
    await expect(Promise.all([uploading, cancelling])).resolves.toEqual([undefined, undefined]);
    expect(repo.cancelOwned).toHaveBeenCalledTimes(1);
    expect(files.deleteStorageKey).toHaveBeenCalledWith(record.storageKey);
  });

  it.each([
    ['FILE_HASH_MISMATCH', 400],
    ['UPLOAD_PART_MISSING', 400],
    ['INSUFFICIENT_STORAGE', 507],
    ['IMPORT_STORAGE_FAILURE', 500]
  ])('maps storage code %s to a stable public response', async (code, status) => {
    const privateCause = new Error('G:\\secret\\incoming\\source.pdf');
    const files = storage({
      mergeParts: jest.fn().mockRejectedValue(new ImportStorageError(code, privateCause))
    });
    const imports = service(repository(), files);

    let caught: unknown;
    try {
      await imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
        partCount: 2,
        sourceSha256: SOURCE_HASH
      });
    } catch (error: unknown) {
      caught = error;
    }
    expect(caught).toMatchObject({ status });
    expect(JSON.stringify(publicResponse(caught))).not.toContain('G:\\secret');
  });

  it('rejects missing/noncontiguous parts and complete count/hash mismatches', async () => {
    const missing = storage({
      mergeParts: jest.fn().mockRejectedValue(
        new ImportStorageError('UPLOAD_PART_MISSING', new Error('private path'))
      )
    });
    await expect(service(repository(), missing).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2,
      sourceSha256: SOURCE_HASH
    })).rejects.toMatchObject({ status: 400 });

    const files = storage();
    const imports = service(repository(), files);
    await expect(imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 1,
      sourceSha256: SOURCE_HASH
    })).rejects.toMatchObject({ status: 400 });
    await expect(imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2,
      sourceSha256: 'b'.repeat(64)
    })).rejects.toMatchObject({ status: 400 });
    expect(files.mergeParts).not.toHaveBeenCalled();
  });

  it('returns 404 for another device before complete performs storage or repository work', async () => {
    const repo = repository();
    const files = storage();

    await expect(service(repo, files).complete(USER_ID, 'another-device', JOB_ID, {
      partCount: 2,
      sourceSha256: SOURCE_HASH
    })).rejects.toBeInstanceOf(NotFoundException);
    expect(files.mergeParts).not.toHaveBeenCalled();
    expect(repo.queueCompletedUpload).not.toHaveBeenCalled();
  });

  it('persists the deterministic source manifest before merge and renews ownership before queue', async () => {
    const repo = repository();
    const files = storage();

    await service(repo, files).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2,
      sourceSha256: SOURCE_HASH
    });

    expect(repo.prepareSource).toHaveBeenCalledWith(USER_ID, DEVICE_ID, JOB_ID, {
      storageKey: `${JOB_ID}/source.pdf`, sha256: SOURCE_HASH, size: '8'
    });
    expect(repo.prepareSource.mock.invocationCallOrder[0]).toBeLessThan(
      files.mergeParts.mock.invocationCallOrder[0]
    );
    const renewalAfterMerge = repo.renewAssemblyLease.mock.invocationCallOrder.find(
      (order) => order > files.mergeParts.mock.invocationCallOrder[0]
    );
    expect(renewalAfterMerge).toBeDefined();
    expect(renewalAfterMerge as number).toBeLessThan(
      repo.queueCompletedUpload.mock.invocationCallOrder[0]
    );
  });

  it('does not merge after a commit-unknown source manifest result and retries through the persisted row', async () => {
    const prepareSource = jest.fn()
      .mockRejectedValueOnce(new Error('commit result unknown at private DB host'))
      .mockResolvedValueOnce(undefined);
    const repo = repository({ prepareSource });
    const files = storage();
    const imports = service(repo, files);

    await expect(imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    })).rejects.toMatchObject({ status: 500 });
    expect(files.mergeParts).not.toHaveBeenCalled();

    await expect(imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    })).resolves.toEqual({ jobId: JOB_ID, status: 'queued' });
    expect(prepareSource).toHaveBeenCalledTimes(2);
    expect(files.mergeParts).toHaveBeenCalledTimes(1);
  });

  it('keeps the source manifest when merge storage fails and cancellation cleans from that row', async () => {
    const sourceRecord = { kind: 'artifact' as const, id: 'source-row', storageKey: `${JOB_ID}/source.pdf` };
    const repo = repository({
      listCleanupRecords: jest.fn()
        .mockResolvedValueOnce([sourceRecord])
        .mockResolvedValueOnce([])
    });
    const files = storage({
      mergeParts: jest.fn().mockRejectedValue(new ImportStorageError('INSUFFICIENT_STORAGE', new Error('disk full')))
    });
    const imports = service(repo, files);

    await expect(imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    })).rejects.toMatchObject({ status: 507 });
    expect(repo.prepareSource).toHaveBeenCalledTimes(1);

    await imports.cancel(USER_ID, DEVICE_ID, JOB_ID);
    expect(files.deleteStorageKey).toHaveBeenCalledWith(sourceRecord.storageKey);
  });

  it('does not queue or clean parts after losing the durable lease during merge', async () => {
    const repo = repository({
      renewAssemblyLease: jest.fn()
        .mockResolvedValueOnce(true)
        .mockResolvedValue(false)
    });
    const files = storage();

    await expect(service(repo, files).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    })).rejects.toBeInstanceOf(ConflictException);
    expect(repo.queueCompletedUpload).not.toHaveBeenCalled();
    expect(repo.listCleanupRecords).not.toHaveBeenCalled();
  });

  it.each(['FILE_SIZE_MISMATCH', 'FILE_HASH_MISMATCH'])(
    'rejects final merged %s mismatches without queueing',
    async (code) => {
      const repo = repository();
      const files = storage({
        mergeParts: jest.fn().mockRejectedValue(new ImportStorageError(code, new Error('internal')))
      });
      await expect(service(repo, files).complete(USER_ID, DEVICE_ID, JOB_ID, {
        partCount: 2,
        sourceSha256: SOURCE_HASH
      })).rejects.toMatchObject({ status: 400 });
      expect(repo.queueCompletedUpload).not.toHaveBeenCalled();
    }
  );

  it('queues a verified source and then best-effort deletes all temporary parts while retaining rows', async () => {
    const repo = repository();
    (repo.listCleanupRecords as jest.Mock)
      .mockResolvedValueOnce([
        { kind: 'part', id: 'part-0', storageKey: `${JOB_ID}/part-0000000000.bin` },
        { kind: 'part', id: 'part-1', storageKey: `${JOB_ID}/part-0000000001.bin` }
      ]);
    const files = storage();
    const imports = service(repo, files);

    await expect(imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2,
      sourceSha256: SOURCE_HASH
    })).resolves.toEqual({ jobId: JOB_ID, status: 'queued' });
    expect(repo.queueCompletedUpload).toHaveBeenCalledWith(USER_ID, DEVICE_ID, JOB_ID, {
      storageKey: `${JOB_ID}/source.pdf`, sha256: SOURCE_HASH, size: '8'
    });
    expect(files.deleteStorageKey).toHaveBeenCalledWith(`${JOB_ID}/part-0000000000.bin`);
    expect(files.deleteStorageKey).toHaveBeenCalledWith(`${JOB_ID}/part-0000000001.bin`);
    // Part rows are durable tombstones: the parts sweep only deletes files, so a late
    // hard-link publication stays reclaimable until the job is retired. The queued job
    // directory must survive for the worker, so no directory sweep runs here.
    expect(repo.listCleanupRecords).toHaveBeenCalledTimes(1);
    expect(files.deleteJobDirectory).not.toHaveBeenCalled();
  });

  it('leaves a newly merged source for orphan cleanup when cancellation wins the queue race', async () => {
    const repo = repository({
      queueCompletedUpload: jest.fn().mockRejectedValue(new ImportRepositoryError('INVALID_STATE'))
    });
    const files = storage();

    await expect(service(repo, files).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2,
      sourceSha256: SOURCE_HASH
    })).rejects.toBeInstanceOf(ConflictException);
    expect(files.deleteStorageKey).not.toHaveBeenCalledWith(`${JOB_ID}/source.pdf`);
  });

  it('does not delete a source when an existing artifact makes repository ownership uncertain', async () => {
    const repo = repository({
      queueCompletedUpload: jest.fn().mockRejectedValue(
        new ImportRepositoryError('IMPORT_ARTIFACT_CONFLICT')
      )
    });
    const files = storage();

    await expect(service(repo, files).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2,
      sourceSha256: SOURCE_HASH
    })).rejects.toBeInstanceOf(ConflictException);
    expect(files.deleteStorageKey).not.toHaveBeenCalledWith(`${JOB_ID}/source.pdf`);
  });

  it('polls a durable lease beyond five seconds and returns two queued results with one merge', async () => {
    let status: ImportJobRecord['status'] = 'uploading';
    let owner: string | null = null;
    let busyAttempts = 0;
    const repo = repository({
      findOwnedJob: jest.fn().mockImplementation(async () => job({ status })),
      queueCompletedUpload: jest.fn().mockImplementation(async () => { status = 'queued'; }),
      tryAcquireAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (owner !== null) {
          busyAttempts += 1;
          return false;
        }
        owner = token;
        return true;
      }),
      renewAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => owner === token),
      releaseAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (owner !== token) return false;
        owner = null;
        return true;
      })
    });
    let announceMerge: () => void = () => undefined;
    let releaseMerge: () => void = () => undefined;
    const mergeEntered = new Promise<void>((resolve) => { announceMerge = resolve; });
    const holdMerge = new Promise<void>((resolve) => { releaseMerge = resolve; });
    const files = storage({
      mergeParts: jest.fn().mockImplementation(async () => {
        announceMerge();
        await holdMerge;
        return { storageKey: `${JOB_ID}/source.pdf`, size: 8, sha256: SOURCE_HASH, created: true };
      })
    });
    let simulatedNow = 0;
    let first: Promise<{ jobId: string; status: ImportJobRecord['status'] }>;
    const delays: number[] = [];
    const imports = service(repo, files, {
      maxWaitMs: 600_000,
      retryDelayMs: 200,
      maxRetryDelayMs: 5_000,
      random: () => 0.5,
      now: () => simulatedNow,
      sleep: async (milliseconds) => {
        delays.push(milliseconds);
        simulatedNow += milliseconds;
        if (simulatedNow > 5_000) {
          releaseMerge();
          await first;
        }
      }
    });

    first = imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    });
    await mergeEntered;
    const second = imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    });

    await expect(Promise.all([first, second])).resolves.toEqual([
      { jobId: JOB_ID, status: 'queued' },
      { jobId: JOB_ID, status: 'queued' }
    ]);
    expect(simulatedNow).toBeGreaterThan(5_000);
    expect(delays).toEqual([200, 400, 800, 1600, 3200]);
    expect(busyAttempts).toBe(5);
    expect(files.mergeParts).toHaveBeenCalledTimes(1);
    expect(repo.queueCompletedUpload).toHaveBeenCalledTimes(1);
  });

  it('heartbeats an active lease every 20 seconds so it cannot be taken over after the 60-second TTL', async () => {
    let simulatedNow = 0;
    let lease: { token: string; expiresAt: number } | null = null;
    const renewals: number[] = [];
    const repo = repository({
      tryAcquireAssemblyLease: jest.fn().mockImplementation(async (_jobId, token, now, expiresAt) => {
        if (lease === null || lease.expiresAt <= now.getTime()) {
          lease = { token, expiresAt: expiresAt.getTime() };
          return true;
        }
        return false;
      }),
      renewAssemblyLease: jest.fn().mockImplementation(async (_jobId, token, now, expiresAt) => {
        if (lease === null || lease.token !== token || lease.expiresAt <= now.getTime()) return false;
        lease.expiresAt = expiresAt.getTime();
        renewals.push(now.getTime());
        return true;
      }),
      releaseAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (lease === null || lease.token !== token) return false;
        lease = null;
        return true;
      })
    });
    const heartbeatResolvers: Array<() => void> = [];
    const heartbeatSleep = jest.fn(async (milliseconds: number, signal?: AbortSignal) =>
      new Promise<void>((resolve, reject) => {
        const onAbort = () => reject(new Error('heartbeat stopped'));
        signal?.addEventListener('abort', onAbort, { once: true });
        heartbeatResolvers.push(() => {
          signal?.removeEventListener('abort', onAbort);
          simulatedNow += milliseconds;
          resolve();
        });
      }));
    let announceMerge: () => void = () => undefined;
    let releaseMerge: () => void = () => undefined;
    const mergeEntered = new Promise<void>((resolve) => { announceMerge = resolve; });
    const holdMerge = new Promise<void>((resolve) => { releaseMerge = resolve; });
    const files = storage({
      mergeParts: jest.fn().mockImplementation(async () => {
        announceMerge();
        await holdMerge;
        return { storageKey: `${JOB_ID}/source.pdf`, size: 8, sha256: SOURCE_HASH, created: true };
      })
    });
    const policy = {
      maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
      leaseTtlMs: 60_000, heartbeatIntervalMs: 20_000, heartbeatSleep,
      now: () => simulatedNow,
      sleep: async (milliseconds: number) => { simulatedNow += milliseconds; }
    } as unknown as ImportAssemblyRetryPolicy;
    const pending = service(repo, files, policy).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    });
    await mergeEntered;
    await Promise.resolve();
    await Promise.resolve();
    if (heartbeatResolvers.length === 0) {
      releaseMerge();
      await pending;
      expect(heartbeatSleep).toHaveBeenCalled();
      return;
    }

    for (let tick = 0; tick < 3; tick += 1) {
      while (heartbeatResolvers.length <= tick) await Promise.resolve();
      heartbeatResolvers[tick]();
      await Promise.resolve();
      await Promise.resolve();
    }
    const activeToken = (lease as { token: string; expiresAt: number } | null)?.token;
    await expect(repo.tryAcquireAssemblyLease(
      JOB_ID, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      new Date(simulatedNow + 1), new Date(simulatedNow + 60_001)
    )).resolves.toBe(false);
    expect(renewals).toEqual(expect.arrayContaining([20_000, 40_000, 60_000]));

    releaseMerge();
    await expect(pending).resolves.toEqual({ jobId: JOB_ID, status: 'queued' });
    expect(activeToken).toEqual(expect.any(String));
  });

  it('uses a 20-second heartbeat interval by default and cancels its timer on completion', async () => {
    let announceMerge: () => void = () => undefined;
    let releaseMerge: () => void = () => undefined;
    const mergeEntered = new Promise<void>((resolve) => { announceMerge = resolve; });
    const holdMerge = new Promise<void>((resolve) => { releaseMerge = resolve; });
    const files = storage({
      mergeParts: jest.fn().mockImplementation(async () => {
        announceMerge();
        await holdMerge;
        return { storageKey: `${JOB_ID}/source.pdf`, size: 8, sha256: SOURCE_HASH, created: true };
      })
    });
    const heartbeatSleep = jest.fn(async (_milliseconds: number, signal?: AbortSignal) =>
      new Promise<void>((_resolve, reject) =>
        signal?.addEventListener('abort', () => reject(new Error('stopped')), { once: true })));
    const policy = {
      maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
      heartbeatSleep, now: () => 0, sleep: async () => undefined
    } as ImportAssemblyRetryPolicy;
    const pending = service(repository(), files, policy).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    });
    await mergeEntered;

    expect(heartbeatSleep).toHaveBeenCalledWith(20_000, expect.any(AbortSignal));
    releaseMerge();
    await expect(pending).resolves.toEqual({ jobId: JOB_ID, status: 'queued' });
  });

  it('marks heartbeat renewal loss and fences queue and cleanup after an in-flight merge', async () => {
    let announceMerge: () => void = () => undefined;
    let releaseMerge: () => void = () => undefined;
    const mergeEntered = new Promise<void>((resolve) => { announceMerge = resolve; });
    const holdMerge = new Promise<void>((resolve) => { releaseMerge = resolve; });
    const repo = repository({
      renewAssemblyLease: jest.fn()
        .mockResolvedValueOnce(true)
        .mockResolvedValue(false)
    });
    const publishCanonical = jest.fn();
    const files = storage({
      mergeParts: jest.fn().mockImplementation(async (
        _jobId: string,
        _partCount: number,
        _expectedSize: number,
        _expectedSha256: string,
        beforePublish?: () => Promise<void>
      ) => {
        announceMerge();
        await holdMerge;
        try {
          await beforePublish?.();
        } catch (cause: unknown) {
          throw new ImportStoragePublishFenceError(cause);
        }
        if (beforePublish === undefined) throw new Error('missing source publish fence');
        publishCanonical();
        return { storageKey: `${JOB_ID}/source.pdf`, size: 8, sha256: SOURCE_HASH, created: true };
      })
    });
    let releaseHeartbeat: () => void = () => undefined;
    const heartbeatSleep = jest.fn(async () =>
      new Promise<void>((resolve) => { releaseHeartbeat = resolve; }));
    const policy = {
      maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
      leaseTtlMs: 60_000, heartbeatIntervalMs: 20_000, heartbeatSleep,
      now: () => 20_000,
      sleep: async () => undefined
    } as unknown as ImportAssemblyRetryPolicy;
    const pending = service(repo, files, policy).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    });
    await mergeEntered;
    releaseHeartbeat();
    await Promise.resolve();
    await Promise.resolve();
    const renewalsBeforeMergeFinished = repo.renewAssemblyLease.mock.calls.length;
    releaseMerge();

    await expect(pending).rejects.toBeInstanceOf(ConflictException);
    expect(renewalsBeforeMergeFinished).toBeGreaterThan(0);
    expect(publishCanonical).not.toHaveBeenCalled();
    expect(repo.queueCompletedUpload).not.toHaveBeenCalled();
    expect(repo.listCleanupRecords).not.toHaveBeenCalled();
  });

  it('fences a staged part before publication when heartbeat ownership is lost during the write', async () => {
    let announceStaging: () => void = () => undefined;
    let releaseStaging: () => void = () => undefined;
    const stagingEntered = new Promise<void>((resolve) => { announceStaging = resolve; });
    const holdStaging = new Promise<void>((resolve) => { releaseStaging = resolve; });
    const publishCanonical = jest.fn();
    const files = storage({
      writePart: jest.fn().mockImplementation(async (
        _jobId: string,
        _partIndex: number,
        _body: Buffer,
        _sha256: string,
        _size: number,
        beforePublish?: () => Promise<void>
      ) => {
        announceStaging();
        await holdStaging;
        try {
          await beforePublish?.();
        } catch (cause: unknown) {
          throw new ImportStoragePublishFenceError(cause);
        }
        if (beforePublish === undefined) throw new Error('missing part publish fence');
        publishCanonical();
        return {
          storageKey: `${JOB_ID}/part-0000000000.bin`,
          size: 4,
          sha256: createHash('sha256').update('part').digest('hex'),
          created: true
        };
      })
    });
    let releaseHeartbeat: () => void = () => undefined;
    const heartbeatSleep = jest.fn(async () =>
      new Promise<void>((resolve) => { releaseHeartbeat = resolve; }));
    const repo = repository({
      renewAssemblyLease: jest.fn()
        .mockResolvedValueOnce(true)
        .mockResolvedValue(false)
    });
    const policy = {
      maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
      leaseTtlMs: 60_000, heartbeatIntervalMs: 20_000, heartbeatSleep,
      now: () => 20_000, sleep: async () => undefined
    } as unknown as ImportAssemblyRetryPolicy;
    const pending = service(repo, files, policy).uploadPart(
      USER_ID, DEVICE_ID, JOB_ID, 0, Buffer.from('part'),
      createHash('sha256').update('part').digest('hex')
    );
    await stagingEntered;
    releaseHeartbeat();
    await Promise.resolve();
    await Promise.resolve();
    releaseStaging();

    await expect(pending).rejects.toBeInstanceOf(ConflictException);
    expect(publishCanonical).not.toHaveBeenCalled();
    expect(repo.recordPart).toHaveBeenCalledTimes(1);
  });

  it.each(['part', 'source'] as const)(
    'prevents a stale %s publisher after another service takes over and cancels with a tombstone',
    async (kind) => {
      let now = 0;
      let currentJob = job();
      let activeLease: { token: string; expiresAt: number } | null = null;
      let cleanupRecords: Array<{
        kind: 'part' | 'source_pdf'; id: string; storageKey: string;
      }> = [];
      const repo = repository({
        findOwnedJob: jest.fn().mockImplementation(async () => currentJob),
        tryAcquireAssemblyLease: jest.fn().mockImplementation(async (
          _jobId: string, token: string, _at: Date, expiresAt: Date
        ) => {
          if (activeLease !== null && activeLease.expiresAt > now) return false;
          activeLease = { token, expiresAt: expiresAt.getTime() };
          return true;
        }),
        renewAssemblyLease: jest.fn().mockImplementation(async (
          _jobId: string, token: string, _at: Date, expiresAt: Date
        ) => {
          if (activeLease === null || activeLease.token !== token || activeLease.expiresAt <= now) {
            return false;
          }
          activeLease.expiresAt = expiresAt.getTime();
          return true;
        }),
        releaseAssemblyLease: jest.fn().mockImplementation(async (_jobId: string, token: string) => {
          if (activeLease === null || activeLease.token !== token) return false;
          activeLease = null;
          return true;
        }),
        recordPart: jest.fn().mockImplementation(async (record) => {
          cleanupRecords = [{ kind: 'part', id: record.id, storageKey: record.storageKey }];
        }),
        prepareSource: jest.fn().mockImplementation(async (_userId, _deviceId, _jobId, manifest) => {
          cleanupRecords = [{ kind: 'source_pdf', id: 'source-manifest', storageKey: manifest.storageKey }];
        }),
        cancelOwned: jest.fn().mockImplementation(async () => {
          currentJob = job({ status: 'cancelled' });
          return true;
        }),
        listCleanupRecords: jest.fn().mockImplementation(async () => cleanupRecords.slice())
      });
      let announceStaging: () => void = () => undefined;
      let releaseStaging: () => void = () => undefined;
      const stagingEntered = new Promise<void>((resolve) => { announceStaging = resolve; });
      const holdStaging = new Promise<void>((resolve) => { releaseStaging = resolve; });
      const publishCanonical = jest.fn();
      const publishAfterFence = async (
        beforePublish: (() => Promise<void>) | undefined,
        result: StoredFile
      ): Promise<StoredFile> => {
        announceStaging();
        await holdStaging;
        if (beforePublish === undefined) {
          publishCanonical();
          return result;
        }
        try {
          await beforePublish();
        } catch (cause: unknown) {
          throw new ImportStoragePublishFenceError(cause);
        }
        publishCanonical();
        return result;
      };
      const files = storage({
        writePart: jest.fn().mockImplementation(async (
          _jobId: string, _partIndex: number, _body: Buffer, sha256: string, size: number,
          beforePublish?: () => Promise<void>
        ) => publishAfterFence(beforePublish, {
          storageKey: `${JOB_ID}/part-0000000000.bin`, size, sha256, created: true
        })),
        mergeParts: jest.fn().mockImplementation(async (
          _jobId: string, _partCount: number, _size: number, _sha256: string,
          beforePublish?: () => Promise<void>
        ) => publishAfterFence(beforePublish, {
          storageKey: `${JOB_ID}/source.pdf`, size: 8, sha256: SOURCE_HASH, created: true
        }))
      });
      const heartbeatSleep = async (_milliseconds: number, signal?: AbortSignal): Promise<void> =>
        new Promise<void>((_resolve, reject) => {
          if (signal?.aborted === true) {
            reject(new Error('heartbeat stopped'));
            return;
          }
          signal?.addEventListener('abort', () => reject(new Error('heartbeat stopped')), { once: true });
        });
      const policy = {
        maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
        leaseTtlMs: 60_000, heartbeatIntervalMs: 20_000, heartbeatSleep,
        now: () => now, sleep: async () => undefined
      } as ImportAssemblyRetryPolicy;
      const staleService = service(repo, files, policy);
      const cancellingService = service(repo, files, policy);
      const body = Buffer.from('part');
      const pending = kind === 'part'
        ? staleService.uploadPart(
          USER_ID, DEVICE_ID, JOB_ID, 0, body, createHash('sha256').update(body).digest('hex')
        )
        : staleService.complete(USER_ID, DEVICE_ID, JOB_ID, {
          partCount: 2, sourceSha256: SOURCE_HASH
        });
      await stagingEntered;
      expect(cleanupRecords).toHaveLength(1);

      now = 60_001;
      await cancellingService.cancel(USER_ID, DEVICE_ID, JOB_ID);
      expect(currentJob.status).toBe('cancelled');
      expect(cleanupRecords).toHaveLength(1);

      releaseStaging();
      await expect(pending).rejects.toBeInstanceOf(ConflictException);
      expect(publishCanonical).not.toHaveBeenCalled();
      await cancellingService.cancel(USER_ID, DEVICE_ID, JOB_ID);
      expect(cleanupRecords).toHaveLength(1);
      expect(publishCanonical).not.toHaveBeenCalled();
    }
  );

  it.each(['part', 'source'] as const)(
    'a delayed %s hard-link publication cannot materialize after cancellation tears down the job directory',
    async (kind) => {
      const root = await mkdtemp(join(tmpdir(), 'wqc-import-tombstone-'));
      let delayPublish = false;
      let announcePublish: () => void = () => undefined;
      let releasePublish: () => void = () => undefined;
      let announceLinkFailed: () => void = () => undefined;
      const publishEntered = new Promise<void>((resolve) => { announcePublish = resolve; });
      const holdPublish = new Promise<void>((resolve) => { releasePublish = resolve; });
      const linkFailed = new Promise<void>((resolve) => { announceLinkFailed = resolve; });
      const hardLink = jest.fn(async (sourcePath: string, targetPath: string) => {
        if (!delayPublish) {
          await link(sourcePath, targetPath);
          return;
        }
        announcePublish();
        await holdPublish;
        try {
          await link(sourcePath, targetPath);
        } catch (cause: unknown) {
          announceLinkFailed();
          throw cause;
        }
      });
      const realStorage = new ImportStorageService(
        { root, maxPdfBytes: 32, partBytes: 8, minFreeBytes: 1 },
        async () => Number.MAX_SAFE_INTEGER,
        hardLink
      );
      const hash = (body: Buffer): string => createHash('sha256').update(body).digest('hex');
      let now = 0;
      let currentJob = job();
      let activeLease: { token: string; expiresAt: number } | null = null;
      let cleanupRecords: Array<{
        kind: 'part' | 'artifact'; id: string; storageKey: string;
      }> = [];
      const repo = repository({
        findOwnedJob: jest.fn().mockImplementation(async () => currentJob),
        tryAcquireAssemblyLease: jest.fn().mockImplementation(async (
          _jobId: string, token: string, _at: Date, expiresAt: Date
        ) => {
          if (activeLease !== null && activeLease.expiresAt > now) return false;
          activeLease = { token, expiresAt: expiresAt.getTime() };
          return true;
        }),
        renewAssemblyLease: jest.fn().mockImplementation(async (
          _jobId: string, token: string, _at: Date, expiresAt: Date
        ) => {
          if (activeLease === null || activeLease.token !== token || activeLease.expiresAt <= now) {
            return false;
          }
          activeLease.expiresAt = expiresAt.getTime();
          return true;
        }),
        releaseAssemblyLease: jest.fn().mockImplementation(async (_jobId: string, token: string) => {
          if (activeLease === null || activeLease.token !== token) return false;
          activeLease = null;
          return true;
        }),
        recordPart: jest.fn().mockImplementation(async (record) => {
          cleanupRecords = [{ kind: 'part', id: record.id, storageKey: record.storageKey }];
        }),
        prepareSource: jest.fn().mockImplementation(async (_userId, _deviceId, _jobId, manifest) => {
          cleanupRecords.push({
            kind: 'artifact', id: 'source-manifest', storageKey: manifest.storageKey
          });
        }),
        cancelOwned: jest.fn().mockImplementation(async () => {
          currentJob = job({ status: 'cancelled' });
          return true;
        }),
        listCleanupRecords: jest.fn().mockImplementation(async (
          _userId, _deviceId, _jobId, _scope, offset, limit
        ) => cleanupRecords.slice(offset, offset + limit))
      });
      const heartbeatSleep = async (_milliseconds: number, signal?: AbortSignal): Promise<void> =>
        new Promise<void>((_resolve, reject) => {
          if (signal?.aborted === true) {
            reject(new Error('heartbeat stopped'));
            return;
          }
          signal?.addEventListener('abort', () => reject(new Error('heartbeat stopped')), { once: true });
        });
      const policy = {
        maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
        leaseTtlMs: 60_000, heartbeatIntervalMs: 20_000, heartbeatSleep,
        now: () => now, sleep: async () => undefined
      } as ImportAssemblyRetryPolicy;
      const makeService = (): ImportService => new ImportService(
        repo, realStorage, { maxPdfBytes: 32, partBytes: 8 }, policy
      );
      const probeId = randomUUID();
      const probeBody = Buffer.from('probe');

      try {
        const probe = await realStorage.writePart(probeId, 0, probeBody, hash(probeBody));
        await realStorage.deleteStorageKey(probe.storageKey);
        if (kind === 'source') {
          const first = Buffer.from('1234');
          const second = Buffer.from('5678');
          const firstStored = await realStorage.writePart(JOB_ID, 0, first, hash(first));
          const secondStored = await realStorage.writePart(JOB_ID, 1, second, hash(second));
          cleanupRecords = [
            { kind: 'part', id: 'part-0', storageKey: firstStored.storageKey },
            { kind: 'part', id: 'part-1', storageKey: secondStored.storageKey }
          ];
          currentJob = job({ sourceSha256: hash(Buffer.from('12345678')) });
        }
        delayPublish = true;
        const body = Buffer.from('part');
        const stale = kind === 'part'
          ? makeService().uploadPart(USER_ID, DEVICE_ID, JOB_ID, 0, body, hash(body))
          : makeService().complete(USER_ID, DEVICE_ID, JOB_ID, {
            partCount: 2, sourceSha256: hash(Buffer.from('12345678'))
          });
        await publishEntered;
        const expectedKey = kind === 'part'
          ? `${JOB_ID}/part-0000000000.bin`
          : `${JOB_ID}/source.pdf`;
        expect(cleanupRecords.some((record) => record.storageKey === expectedKey)).toBe(true);

        now = 60_001;
        await makeService().cancel(USER_ID, DEVICE_ID, JOB_ID);
        // The cancellation sweep removed the row-covered files and tore down the job
        // directory, so a still running hard-link publish now fails with ENOENT.
        await expect(readdir(join(root, JOB_ID))).rejects.toThrow();
        expect(cleanupRecords.some((record) => record.storageKey === expectedKey)).toBe(true);

        releasePublish();
        await linkFailed;
        await expect(stale).rejects.toBeInstanceOf(HttpException);
        await expect(readFile(join(root, expectedKey))).rejects.toThrow();
        await expect(readdir(join(root, JOB_ID))).rejects.toThrow();
        expect(cleanupRecords.some((record) => record.storageKey === expectedKey)).toBe(true);
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    }
  );

  it.each(['part', 'source'] as const)(
    'a %s hard-link completing during the cancellation sweep is reclaimed by the directory sweep',
    async (kind) => {
      const root = await mkdtemp(join(tmpdir(), 'wqc-import-tombstone-'));
      let delayPublish = false;
      let announcePublish: () => void = () => undefined;
      let releasePublish: () => void = () => undefined;
      let announceLinked: () => void = () => undefined;
      const publishEntered = new Promise<void>((resolve) => { announcePublish = resolve; });
      const holdPublish = new Promise<void>((resolve) => { releasePublish = resolve; });
      const linked = new Promise<void>((resolve) => { announceLinked = resolve; });
      const hardLink = jest.fn(async (sourcePath: string, targetPath: string) => {
        if (!delayPublish) {
          await link(sourcePath, targetPath);
          return;
        }
        announcePublish();
        await holdPublish;
        await link(sourcePath, targetPath);
        announceLinked();
        // Models a process disappearing after the kernel published the link but before
        // storage/service can run their normal post-publish lease check.
        throw new Error('simulated crash after hard-link publication');
      });
      const realStorage = new ImportStorageService(
        { root, maxPdfBytes: 32, partBytes: 8, minFreeBytes: 1 },
        async () => Number.MAX_SAFE_INTEGER,
        hardLink
      );
      const hash = (body: Buffer): string => createHash('sha256').update(body).digest('hex');
      let now = 0;
      let currentJob = job();
      let activeLease: { token: string; expiresAt: number } | null = null;
      let cleanupRecords: Array<{
        kind: 'part' | 'artifact'; id: string; storageKey: string;
      }> = [];
      const repo = repository({
        findOwnedJob: jest.fn().mockImplementation(async () => currentJob),
        tryAcquireAssemblyLease: jest.fn().mockImplementation(async (
          _jobId: string, token: string, _at: Date, expiresAt: Date
        ) => {
          if (activeLease !== null && activeLease.expiresAt > now) return false;
          activeLease = { token, expiresAt: expiresAt.getTime() };
          return true;
        }),
        renewAssemblyLease: jest.fn().mockImplementation(async (
          _jobId: string, token: string, _at: Date, expiresAt: Date
        ) => {
          if (activeLease === null || activeLease.token !== token || activeLease.expiresAt <= now) {
            return false;
          }
          activeLease.expiresAt = expiresAt.getTime();
          return true;
        }),
        releaseAssemblyLease: jest.fn().mockImplementation(async (_jobId: string, token: string) => {
          if (activeLease === null || activeLease.token !== token) return false;
          activeLease = null;
          return true;
        }),
        recordPart: jest.fn().mockImplementation(async (record) => {
          cleanupRecords = [{ kind: 'part', id: record.id, storageKey: record.storageKey }];
        }),
        prepareSource: jest.fn().mockImplementation(async (_userId, _deviceId, _jobId, manifest) => {
          cleanupRecords.push({
            kind: 'artifact', id: 'source-manifest', storageKey: manifest.storageKey
          });
        }),
        cancelOwned: jest.fn().mockImplementation(async () => {
          currentJob = job({ status: 'cancelled' });
          return true;
        }),
        listCleanupRecords: jest.fn().mockImplementation(async (
          _userId, _deviceId, _jobId, _scope, offset, limit
        ) => cleanupRecords.slice(offset, offset + limit))
      });
      const heartbeatSleep = async (_milliseconds: number, signal?: AbortSignal): Promise<void> =>
        new Promise<void>((_resolve, reject) => {
          if (signal?.aborted === true) {
            reject(new Error('heartbeat stopped'));
            return;
          }
          signal?.addEventListener('abort', () => reject(new Error('heartbeat stopped')), { once: true });
        });
      const policy = {
        maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
        leaseTtlMs: 60_000, heartbeatIntervalMs: 20_000, heartbeatSleep,
        now: () => now, sleep: async () => undefined
      } as ImportAssemblyRetryPolicy;
      const makeService = (): ImportService => new ImportService(
        repo, realStorage, { maxPdfBytes: 32, partBytes: 8 }, policy
      );
      const probeId = randomUUID();
      const probeBody = Buffer.from('probe');

      try {
        const probe = await realStorage.writePart(probeId, 0, probeBody, hash(probeBody));
        await realStorage.deleteStorageKey(probe.storageKey);
        if (kind === 'source') {
          const first = Buffer.from('1234');
          const second = Buffer.from('5678');
          const firstStored = await realStorage.writePart(JOB_ID, 0, first, hash(first));
          const secondStored = await realStorage.writePart(JOB_ID, 1, second, hash(second));
          cleanupRecords = [
            { kind: 'part', id: 'part-0', storageKey: firstStored.storageKey },
            { kind: 'part', id: 'part-1', storageKey: secondStored.storageKey }
          ];
          currentJob = job({ sourceSha256: hash(Buffer.from('12345678')) });
        }
        delayPublish = true;
        const body = Buffer.from('part');
        const stale = kind === 'part'
          ? makeService().uploadPart(USER_ID, DEVICE_ID, JOB_ID, 0, body, hash(body))
          : makeService().complete(USER_ID, DEVICE_ID, JOB_ID, {
            partCount: 2, sourceSha256: hash(Buffer.from('12345678'))
          });
        await publishEntered;
        const expectedKey = kind === 'part'
          ? `${JOB_ID}/part-0000000000.bin`
          : `${JOB_ID}/source.pdf`;
        expect(cleanupRecords.some((record) => record.storageKey === expectedKey)).toBe(true);

        // Gate the directory sweep so the delayed publish can complete while the
        // cancellation sweep is already running.
        let announceSweep: () => void = () => undefined;
        let releaseSweep: () => void = () => undefined;
        const sweepEntered = new Promise<void>((resolve) => { announceSweep = resolve; });
        const sweepHeld = new Promise<void>((resolve) => { releaseSweep = resolve; });
        const originalSweep = realStorage.deleteJobDirectory.bind(realStorage);
        jest.spyOn(realStorage, 'deleteJobDirectory').mockImplementation(async (jobId: string) => {
          announceSweep();
          await sweepHeld;
          return originalSweep(jobId);
        });

        now = 60_001;
        const cancelling = makeService().cancel(USER_ID, DEVICE_ID, JOB_ID);
        await sweepEntered;
        releasePublish();
        await linked;
        await expect(stale).rejects.toBeInstanceOf(HttpException);
        releaseSweep();
        await cancelling;

        // The late canonical file materialized while the sweep was running; the directory
        // sweep reclaimed it, and the durable tombstone row was never consumed.
        await expect(readFile(join(root, expectedKey))).rejects.toThrow();
        await expect(readdir(join(root, JOB_ID))).rejects.toThrow();
        expect(cleanupRecords.some((record) => record.storageKey === expectedKey)).toBe(true);
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    }
  );

  it('does not publish part bytes after heartbeat loss while its manifest transaction is in flight', async () => {
    let releaseRecord: () => void = () => undefined;
    let announceRecord: () => void = () => undefined;
    const recordEntered = new Promise<void>((resolve) => { announceRecord = resolve; });
    const holdRecord = new Promise<void>((resolve) => { releaseRecord = resolve; });
    let releaseHeartbeat: () => void = () => undefined;
    const heartbeatSleep = jest.fn(async () =>
      new Promise<void>((resolve) => { releaseHeartbeat = resolve; }));
    const repo = repository({
      recordPart: jest.fn().mockImplementation(async () => {
        announceRecord();
        await holdRecord;
      }),
      renewAssemblyLease: jest.fn().mockResolvedValue(false)
    });
    const files = storage();
    const policy = {
      maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
      leaseTtlMs: 60_000, heartbeatIntervalMs: 20_000, heartbeatSleep,
      now: () => 20_000, sleep: async () => undefined
    } as unknown as ImportAssemblyRetryPolicy;
    const pending = service(repo, files, policy).uploadPart(
      USER_ID, DEVICE_ID, JOB_ID, 0, Buffer.from('part'),
      createHash('sha256').update('part').digest('hex')
    );
    await recordEntered;
    releaseHeartbeat();
    await Promise.resolve();
    await Promise.resolve();
    releaseRecord();

    await expect(pending).rejects.toBeInstanceOf(ConflictException);
    expect(files.writePart).not.toHaveBeenCalled();
  });

  it('does not cancel or clean after heartbeat loss while the owned job is being re-read', async () => {
    let releaseOwnedRead: () => void = () => undefined;
    let announceOwnedRead: () => void = () => undefined;
    const ownedReadEntered = new Promise<void>((resolve) => { announceOwnedRead = resolve; });
    const holdOwnedRead = new Promise<void>((resolve) => { releaseOwnedRead = resolve; });
    let lookup = 0;
    let releaseHeartbeat: () => void = () => undefined;
    const heartbeatSleep = jest.fn(async () =>
      new Promise<void>((resolve) => { releaseHeartbeat = resolve; }));
    const repo = repository({
      findOwnedJob: jest.fn().mockImplementation(async () => {
        lookup += 1;
        if (lookup === 1) return job();
        announceOwnedRead();
        await holdOwnedRead;
        return job();
      }),
      renewAssemblyLease: jest.fn().mockResolvedValue(false)
    });
    const policy = {
      maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
      leaseTtlMs: 60_000, heartbeatIntervalMs: 20_000, heartbeatSleep,
      now: () => 20_000, sleep: async () => undefined
    } as unknown as ImportAssemblyRetryPolicy;
    const pending = service(repo, storage(), policy).cancel(USER_ID, DEVICE_ID, JOB_ID);
    await ownedReadEntered;
    releaseHeartbeat();
    await Promise.resolve();
    await Promise.resolve();
    releaseOwnedRead();

    await expect(pending).rejects.toBeInstanceOf(ConflictException);
    expect(repo.cancelOwned).not.toHaveBeenCalled();
    expect(repo.listCleanupRecords).not.toHaveBeenCalled();
  });

  it('stops cleanup between physical deletion and metadata deletion when heartbeat ownership is lost', async () => {
    const records = [
      { kind: 'part' as const, id: 'part-0', storageKey: `${JOB_ID}/part-0000000000.bin` },
      { kind: 'part' as const, id: 'part-1', storageKey: `${JOB_ID}/part-0000000001.bin` }
    ];
    let loseLease = false;
    let releaseHeartbeat: () => void = () => undefined;
    const heartbeatSleep = jest.fn(async () =>
      new Promise<void>((resolve) => { releaseHeartbeat = resolve; }));
    const repo = repository({
      renewAssemblyLease: jest.fn().mockImplementation(async () => !loseLease),
      listCleanupRecords: jest.fn().mockResolvedValueOnce(records).mockResolvedValueOnce([])
    });
    let announceFirstDelete: () => void = () => undefined;
    let releaseFirstDelete: () => void = () => undefined;
    const firstDeleteEntered = new Promise<void>((resolve) => { announceFirstDelete = resolve; });
    const holdFirstDelete = new Promise<void>((resolve) => { releaseFirstDelete = resolve; });
    const files = storage({
      deleteStorageKey: jest.fn().mockImplementation(async () => {
        if (files.deleteStorageKey.mock.calls.length === 1) {
          announceFirstDelete();
          await holdFirstDelete;
        }
      })
    });
    const policy = {
      maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
      leaseTtlMs: 60_000, heartbeatIntervalMs: 20_000, heartbeatSleep,
      now: () => 20_000, sleep: async () => undefined
    } as unknown as ImportAssemblyRetryPolicy;
    const pending = service(repo, files, policy).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    });
    await firstDeleteEntered;
    loseLease = true;
    releaseHeartbeat();
    await Promise.resolve();
    await Promise.resolve();
    releaseFirstDelete();

    await expect(pending).rejects.toBeInstanceOf(ConflictException);
    expect(files.deleteStorageKey).toHaveBeenCalledTimes(1);
  });

  it('best-effort releases the same token after an acquire commit-unknown result', async () => {
    let persistedToken: string | null = null;
    let first = true;
    const repo = repository({
      tryAcquireAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (first) {
          first = false;
          persistedToken = token;
          throw new Error('insert committed but response was lost');
        }
        if (persistedToken !== null) return false;
        persistedToken = token;
        return true;
      }),
      releaseAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (persistedToken !== token) return false;
        persistedToken = null;
        return true;
      })
    });
    const imports = service(repo);

    await expect(imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    })).rejects.toMatchObject({ status: 500 });
    expect(persistedToken).toBeNull();
    expect(repo.releaseAssemblyLease).toHaveBeenCalledTimes(1);

    await expect(imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    })).resolves.toEqual({ jobId: JOB_ID, status: 'queued' });
  });

  it('takes over a crash lease after 60 seconds but before the ten-minute wait window', async () => {
    let simulatedNow = 61_000;
    let lease = { token: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', expiresAt: 60_000 };
    const repo = repository({
      tryAcquireAssemblyLease: jest.fn().mockImplementation(async (_jobId, token, now, expiresAt) => {
        if (lease.expiresAt > now.getTime()) return false;
        lease = { token, expiresAt: expiresAt.getTime() };
        return true;
      }),
      renewAssemblyLease: jest.fn().mockImplementation(async (_jobId, token, now, expiresAt) => {
        if (lease.token !== token || lease.expiresAt <= now.getTime()) return false;
        lease.expiresAt = expiresAt.getTime();
        return true;
      }),
      releaseAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (lease.token !== token) return false;
        lease = { token: '', expiresAt: 0 };
        return true;
      })
    });
    const policy = {
      maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
      leaseTtlMs: 60_000, heartbeatIntervalMs: 20_000,
      heartbeatSleep: async (_milliseconds: number, signal?: AbortSignal) =>
        new Promise<void>((_resolve, reject) => signal?.addEventListener('abort', () => reject(new Error('stopped')), { once: true })),
      now: () => simulatedNow,
      sleep: async (milliseconds: number) => { simulatedNow += milliseconds; }
    } as unknown as ImportAssemblyRetryPolicy;
    let announceMerge: () => void = () => undefined;
    let releaseMerge: () => void = () => undefined;
    const mergeEntered = new Promise<void>((resolve) => { announceMerge = resolve; });
    const holdMerge = new Promise<void>((resolve) => { releaseMerge = resolve; });
    const files = storage({
      mergeParts: jest.fn().mockImplementation(async () => {
        announceMerge();
        await holdMerge;
        return { storageKey: `${JOB_ID}/source.pdf`, size: 8, sha256: SOURCE_HASH, created: true };
      })
    });
    const pending = service(repo, files, policy).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    });
    await mergeEntered;
    const takeoverToken = repo.tryAcquireAssemblyLease.mock.calls[0][1];
    expect(takeoverToken).not.toBe('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    const acquiredAt = repo.tryAcquireAssemblyLease.mock.calls[0][2] as Date;
    const acquiredUntil = repo.tryAcquireAssemblyLease.mock.calls[0][3] as Date;
    expect(acquiredUntil.getTime() - acquiredAt.getTime()).toBe(60_000);
    await expect(repo.renewAssemblyLease(
      JOB_ID, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      new Date(simulatedNow), new Date(simulatedNow + 60_000)
    )).resolves.toBe(false);
    await expect(repo.releaseAssemblyLease(
      JOB_ID, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    )).resolves.toBe(false);
    expect(lease.token).toBe(takeoverToken);
    releaseMerge();
    await expect(pending).resolves.toEqual({ jobId: JOB_ID, status: 'queued' });
  });

  it('lets a durable-lease waiter take over when the first assembly fails', async () => {
    let status: ImportJobRecord['status'] = 'uploading';
    let owner: string | null = null;
    const repo = repository({
      findOwnedJob: jest.fn().mockImplementation(async () => job({ status })),
      queueCompletedUpload: jest.fn().mockImplementation(async () => { status = 'queued'; }),
      tryAcquireAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (owner !== null) return false;
        owner = token;
        return true;
      }),
      renewAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => owner === token),
      releaseAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (owner !== token) return false;
        owner = null;
        return true;
      })
    });
    let announceFirstMerge: () => void = () => undefined;
    let releaseFirstMerge: () => void = () => undefined;
    const firstMergeEntered = new Promise<void>((resolve) => { announceFirstMerge = resolve; });
    const holdFirstMerge = new Promise<void>((resolve) => { releaseFirstMerge = resolve; });
    const files = storage({
      mergeParts: jest.fn()
        .mockImplementationOnce(async () => {
          announceFirstMerge();
          await holdFirstMerge;
          throw new ImportStorageError('FILE_HASH_MISMATCH', new Error('bad first merge'));
        })
        .mockResolvedValueOnce({
          storageKey: `${JOB_ID}/source.pdf`, size: 8, sha256: SOURCE_HASH, created: true
        })
    });
    let simulatedNow = 0;
    let firstOutcome: Promise<unknown>;
    const imports = service(repo, files, {
      maxWaitMs: 600_000,
      retryDelayMs: 200,
      maxRetryDelayMs: 5_000,
      random: () => 0.5,
      now: () => simulatedNow,
      sleep: async (milliseconds) => {
        simulatedNow += milliseconds;
        releaseFirstMerge();
        await firstOutcome;
      }
    });

    const first = imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    });
    firstOutcome = first.catch((error: unknown) => error);
    await firstMergeEntered;
    const second = imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    });

    await expect(firstOutcome).resolves.toMatchObject({ status: 400 });
    await expect(second).resolves.toEqual({ jobId: JOB_ID, status: 'queued' });
    expect(files.mergeParts).toHaveBeenCalledTimes(2);
    expect(repo.queueCompletedUpload).toHaveBeenCalledTimes(1);
  });

  it('fences cancellation behind an active durable lease', async () => {
    let status: ImportJobRecord['status'] = 'uploading';
    let owner: string | null = null;
    const order: string[] = [];
    const repo = repository({
      findOwnedJob: jest.fn().mockImplementation(async () => job({ status })),
      queueCompletedUpload: jest.fn().mockImplementation(async () => { order.push('queue'); status = 'queued'; }),
      cancelOwned: jest.fn().mockImplementation(async () => { order.push('cancel'); status = 'cancelled'; return true; }),
      tryAcquireAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (owner !== null) return false;
        owner = token;
        return true;
      }),
      renewAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => owner === token),
      releaseAssemblyLease: jest.fn().mockImplementation(async (_jobId, token) => {
        if (owner !== token) return false;
        owner = null;
        return true;
      })
    });
    let announceMerge: () => void = () => undefined;
    let releaseMerge: () => void = () => undefined;
    const mergeEntered = new Promise<void>((resolve) => { announceMerge = resolve; });
    const holdMerge = new Promise<void>((resolve) => { releaseMerge = resolve; });
    const files = storage({
      mergeParts: jest.fn().mockImplementation(async () => {
        announceMerge();
        await holdMerge;
        return { storageKey: `${JOB_ID}/source.pdf`, size: 8, sha256: SOURCE_HASH, created: true };
      })
    });
    let simulatedNow = 0;
    const imports = service(repo, files, {
      maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
      now: () => simulatedNow,
      sleep: async (milliseconds) => {
        simulatedNow += milliseconds;
        releaseMerge();
      }
    });

    const completing = imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    });
    await mergeEntered;
    const cancelling = imports.cancel(USER_ID, DEVICE_ID, JOB_ID);

    await expect(Promise.all([completing, cancelling])).resolves.toEqual([
      { jobId: JOB_ID, status: 'queued' }, undefined
    ]);
    expect(order).toEqual(['queue', 'cancel']);
  });

  it('returns stable 409 only after the durable lease wait deadline with exponential delays', async () => {
    const repo = repository({ tryAcquireAssemblyLease: jest.fn().mockResolvedValue(false) });
    let simulatedNow = 0;
    const delays: number[] = [];
    let caught: unknown;
    try {
      await service(repo, storage(), {
        maxWaitMs: 500, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
        now: () => simulatedNow,
        sleep: async (milliseconds) => { delays.push(milliseconds); simulatedNow += milliseconds; }
      }).complete(USER_ID, DEVICE_ID, JOB_ID, {
        partCount: 2, sourceSha256: SOURCE_HASH
      });
    } catch (error: unknown) {
      caught = error;
    }
    expect(caught).toMatchObject({ status: 409 });
    expect(publicResponse(caught)).toMatchObject({ code: 'ASSEMBLY_BUSY' });
    expect(repo.tryAcquireAssemblyLease).toHaveBeenCalledTimes(2);
    expect(delays).toEqual([200, 300]);
  });

  it('stops durable lease retries when the client disconnects', async () => {
    const repo = repository({ tryAcquireAssemblyLease: jest.fn().mockResolvedValue(false) });
    const abort = new AbortController();
    let announceSleep: () => void = () => undefined;
    const sleepEntered = new Promise<void>((resolve) => { announceSleep = resolve; });
    const imports = service(repo, storage(), {
      maxWaitMs: 600_000, retryDelayMs: 200, maxRetryDelayMs: 5_000, random: () => 0.5,
      now: () => 0,
      sleep: async (_milliseconds, signal) => {
        announceSleep();
        await new Promise<void>((_resolve, reject) => {
          signal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
        });
      }
    });

    const pending = imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    }, abort.signal);
    await sleepEntered;
    abort.abort();

    await expect(pending).rejects.toMatchObject({ status: 408 });
    expect(repo.tryAcquireAssemblyLease).toHaveBeenCalledTimes(1);
  });

  it('releases a lease acquired concurrently with request cancellation before starting merge', async () => {
    const abort = new AbortController();
    const repo = repository({
      tryAcquireAssemblyLease: jest.fn().mockImplementation(async () => {
        abort.abort();
        return true;
      })
    });
    const files = storage();

    await expect(service(repo, files).complete(
      USER_ID, DEVICE_ID, JOB_ID,
      { partCount: 2, sourceSha256: SOURCE_HASH },
      abort.signal
    )).rejects.toMatchObject({ status: 408 });
    expect(repo.releaseAssemblyLease).toHaveBeenCalledWith(JOB_ID, expect.any(String));
    expect(files.mergeParts).not.toHaveBeenCalled();
  });

  it('bounds concurrent assembly requests for one job before issuing more database probes', async () => {
    const resolvers: Array<(value: boolean) => void> = [];
    let announceAllProbes: () => void = () => undefined;
    const allProbesEntered = new Promise<void>((resolve) => { announceAllProbes = resolve; });
    const repo = repository({
      tryAcquireAssemblyLease: jest.fn().mockImplementation(async () => {
        if (resolvers.length >= 16) return true;
        return new Promise<boolean>((resolve) => {
          resolvers.push(resolve);
          if (resolvers.length === 16) announceAllProbes();
        });
      })
    });
    const imports = service(repo);
    const controllers = Array.from({ length: 16 }, () => new AbortController());
    const pending = controllers.map((controller) => imports.complete(
      USER_ID, DEVICE_ID, JOB_ID,
      { partCount: 2, sourceSha256: SOURCE_HASH },
      controller.signal
    ));
    await allProbesEntered;

    await expect(imports.complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    })).rejects.toMatchObject({ status: 409 });
    expect(repo.tryAcquireAssemblyLease).toHaveBeenCalledTimes(16);

    resolvers.forEach((resolve) => resolve(false));
    controllers.forEach((controller) => controller.abort());
    await Promise.allSettled(pending);
  });

  it('maps durable lease infrastructure failures to safe 500 rather than a busy conflict', async () => {
    const repo = repository({
      tryAcquireAssemblyLease: jest.fn().mockRejectedValue(new Error('private database endpoint'))
    });
    let caught: unknown;
    try {
      await service(repo).complete(USER_ID, DEVICE_ID, JOB_ID, {
        partCount: 2, sourceSha256: SOURCE_HASH
      });
    } catch (error: unknown) {
      caught = error;
    }
    expect(caught).toMatchObject({ status: 500 });
    expect(publicResponse(caught)).toMatchObject({ code: 'IMPORT_SERVICE_FAILURE' });
  });

  it('returns 409 when a completed retry uses different completion parameters', async () => {
    const repo = repository({ findOwnedJob: jest.fn().mockResolvedValue(job({ status: 'queued' })) });

    await expect(service(repo).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 1,
      sourceSha256: SOURCE_HASH
    })).rejects.toMatchObject({ status: 409 });
  });

  /* Previous MySQL advisory-lock tests lived here. Durable row leases deliberately use
     short repository operations, so no request retains a pool checkout while waiting. */

  it('treats a same-device complete retry for an already queued source as idempotent', async () => {
    const repo = repository({
      findOwnedJob: jest.fn().mockResolvedValue(job({ status: 'queued' }))
    });
    const record = {
      kind: 'part' as const,
      id: 'part-0',
      storageKey: `${JOB_ID}/part-0000000000.bin`
    };
    (repo.listCleanupRecords as jest.Mock).mockResolvedValueOnce([record]);
    const files = storage();

    await expect(service(repo, files).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    })).resolves.toEqual({ jobId: JOB_ID, status: 'queued' });
    expect(files.mergeParts).not.toHaveBeenCalled();
    expect(repo.queueCompletedUpload).not.toHaveBeenCalled();
    expect(files.deleteStorageKey).toHaveBeenCalledWith(record.storageKey);
    // The parts sweep is file-only: the durable tombstone row stays for a later sweep,
    // and the queued job directory must survive for the worker.
    expect(files.deleteJobDirectory).not.toHaveBeenCalled();
  });

  it('cancels only a job owned by the authenticated user and creating device', async () => {
    const repo = repository();
    (repo.listCleanupRecords as jest.Mock)
      .mockResolvedValueOnce([
        { kind: 'part', id: 'part-0', storageKey: `${JOB_ID}/part-0000000000.bin` },
        { kind: 'part', id: 'part-1', storageKey: `${JOB_ID}/part-0000000001.bin` }
      ])
      .mockResolvedValueOnce([]);
    const files = storage();
    const imports = service(repo, files);

    await expect(imports.cancel(USER_ID, DEVICE_ID, JOB_ID)).resolves.toBeUndefined();
    expect(repo.cancelOwned).toHaveBeenCalledWith(USER_ID, DEVICE_ID, JOB_ID);
    expect(files.deleteStorageKey).toHaveBeenCalledWith(`${JOB_ID}/part-0000000000.bin`);
    expect(files.deleteStorageKey).toHaveBeenCalledWith(`${JOB_ID}/part-0000000001.bin`);

    repo.findOwnedJob.mockResolvedValueOnce(job({ deviceId: 'another-device' }));
    await expect(imports.cancel(USER_ID, DEVICE_ID, JOB_ID)).rejects.toBeInstanceOf(NotFoundException);
  });

  it('cancels first, then sequentially deletes every recorded part, source, and question image', async () => {
    const records = [
      { kind: 'part' as const, id: 'part-1', storageKey: `${JOB_ID}/part-0000000007.bin` },
      { kind: 'artifact' as const, id: 'source-1', storageKey: `${JOB_ID}/source.pdf` },
      { kind: 'artifact' as const, id: 'image-1', storageKey: `${JOB_ID}/artifact-44444444-4444-4444-8444-444444444444.bin` }
    ];
    const repo = repository();
    (repo.listCleanupRecords as jest.Mock)
      .mockResolvedValueOnce(records)
      .mockResolvedValueOnce([]);
    const order: string[] = [];
    let activeDeletes = 0;
    let maximumActiveDeletes = 0;
    repo.cancelOwned.mockImplementation(async () => { order.push('cancel'); return true; });
    const files = storage({
      deleteStorageKey: jest.fn(async (key: string) => {
        activeDeletes += 1;
        maximumActiveDeletes = Math.max(maximumActiveDeletes, activeDeletes);
        await Promise.resolve();
        order.push(`file:${key}`);
        activeDeletes -= 1;
      })
    });

    await service(repo, files).cancel(USER_ID, DEVICE_ID, JOB_ID);

    expect(order[0]).toBe('cancel');
    expect(files.partKey).not.toHaveBeenCalled();
    expect(files.deleteStorageKey.mock.calls.map(([key]) => key)).toEqual(records.map((item) => item.storageKey));
    expect(files.deleteJobDirectory).toHaveBeenCalledWith(JOB_ID);
    expect(maximumActiveDeletes).toBe(1);
  });

  it.each(['uploading', 'queued', 'processing', 'review', 'failed'] as const)(
    'fences and cleans a %s job through the same cancellation flow',
    async (status) => {
      const record = { kind: 'artifact' as const, id: 'image-1', storageKey: `${JOB_ID}/artifact-44444444-4444-4444-8444-444444444444.bin` };
      const repo = repository({ findOwnedJob: jest.fn().mockResolvedValue(job({ status })) });
      (repo.listCleanupRecords as jest.Mock)
        .mockResolvedValueOnce([record])
        .mockResolvedValueOnce([]);
      const files = storage();

      await service(repo, files).cancel(USER_ID, DEVICE_ID, JOB_ID);

      expect(repo.cancelOwned).toHaveBeenCalledWith(USER_ID, DEVICE_ID, JOB_ID);
      expect(files.deleteStorageKey).toHaveBeenCalledWith(record.storageKey);
      expect(files.deleteJobDirectory).toHaveBeenCalledWith(JOB_ID);
    }
  );

  it('retains failed cleanup metadata and retries it on repeated DELETE of a cancelled job', async () => {
    const record = { kind: 'artifact' as const, id: 'source-1', storageKey: `${JOB_ID}/source.pdf` };
    const repo = repository({
      findOwnedJob: jest.fn().mockResolvedValue(job({ status: 'cancelled' }))
    });
    (repo.listCleanupRecords as jest.Mock)
      .mockResolvedValueOnce([record])
      .mockResolvedValueOnce([record])
      .mockResolvedValueOnce([]);
    const files = storage();
    files.deleteStorageKey.mockRejectedValueOnce(new Error('disk busy'));
    const imports = service(repo, files);

    await expect(imports.cancel(USER_ID, DEVICE_ID, JOB_ID)).resolves.toBeUndefined();
    await expect(imports.cancel(USER_ID, DEVICE_ID, JOB_ID)).resolves.toBeUndefined();
    expect(files.deleteJobDirectory).toHaveBeenCalledTimes(2);
    expect(repo.cancelOwned).not.toHaveBeenCalled();
  });

  it('does not derive or allocate cleanup work for an empty maximum-sized cancelled job', async () => {
    const repo = repository({
      findOwnedJob: jest.fn().mockResolvedValue(job({
        status: 'cancelled',
        sourceSize: String(MAX_PDF_BYTES),
        partCount: 3_200
      }))
    });
    const files = storage();

    await service(repo, files).cancel(USER_ID, DEVICE_ID, JOB_ID);

    expect(repo.listCleanupRecords).toHaveBeenCalledTimes(1);
    expect(files.partKey).not.toHaveBeenCalled();
    expect(files.deleteStorageKey).not.toHaveBeenCalled();
    expect(files.deleteJobDirectory).toHaveBeenCalledWith(JOB_ID);
  });

  it('pages through 3200 cancelled part tombstones in fixed sequential batches without deleting rows', async () => {
    const records = Array.from({ length: 3_200 }, (_, partNumber) => ({
      kind: 'part' as const,
      id: `part-${partNumber}`,
      storageKey: `${JOB_ID}/part-${partNumber.toString().padStart(10, '0')}.bin`
    }));
    let activeDeletes = 0;
    let maximumActiveDeletes = 0;
    const repo = repository({
      findOwnedJob: jest.fn().mockResolvedValue(job({
        status: 'cancelled', sourceSize: String(MAX_PDF_BYTES), partCount: 3_200
      })),
      listCleanupRecords: jest.fn().mockImplementation(async (
        _userId, _deviceId, _jobId, scope, offset, limit
      ) => {
        expect(scope).toBe('all');
        return records.slice(offset, offset + limit);
      })
    });
    const files = storage({
      deleteStorageKey: jest.fn().mockImplementation(async () => {
        activeDeletes += 1;
        maximumActiveDeletes = Math.max(maximumActiveDeletes, activeDeletes);
        await Promise.resolve();
        activeDeletes -= 1;
      })
    });

    await service(repo, files).cancel(USER_ID, DEVICE_ID, JOB_ID);

    expect(repo.listCleanupRecords).toHaveBeenCalledTimes(101);
    expect((repo.listCleanupRecords as jest.Mock).mock.calls.map((call) => call.slice(4)))
      .toEqual(Array.from({ length: 101 }, (_, page) => [page * 32, 32]));
    expect(files.deleteStorageKey).toHaveBeenCalledTimes(3_200);
    expect(maximumActiveDeletes).toBe(1);
    expect(files.deleteJobDirectory).toHaveBeenCalledWith(JOB_ID);
  });

  it('never deletes a cleanup record whose storage key belongs to another job', async () => {
    const repo = repository();
    (repo.listCleanupRecords as jest.Mock).mockResolvedValueOnce([{
      kind: 'artifact',
      id: 'foreign-source',
      storageKey: '44444444-4444-4444-8444-444444444444/source.pdf'
    }]);
    const files = storage();

    await service(repo, files).cancel(USER_ID, DEVICE_ID, JOB_ID);

    expect(files.deleteStorageKey).not.toHaveBeenCalled();
    // A foreign key aborts the sweep before the directory teardown.
    expect(files.deleteJobDirectory).not.toHaveBeenCalled();
  });

  it('returns 409 when complete or cancel observes a non-uploadable/non-cancellable state', async () => {
    const completeRepo = repository({ findOwnedJob: jest.fn().mockResolvedValue(job({ status: 'cancelled' })) });
    await expect(service(completeRepo).complete(USER_ID, DEVICE_ID, JOB_ID, {
      partCount: 2, sourceSha256: SOURCE_HASH
    })).rejects.toBeInstanceOf(ConflictException);

    const cancelRepo = repository({ findOwnedJob: jest.fn().mockResolvedValue(job({ status: 'confirmed' })) });
    await expect(service(cancelRepo).cancel(USER_ID, DEVICE_ID, JOB_ID)).rejects.toBeInstanceOf(ConflictException);
  });

  it('returns a user-owned job without leaking storage or internal fields', async () => {
    const imports = service(repository());
    const result = await imports.get(USER_ID, JOB_ID);

    expect(result).toEqual(expect.objectContaining({ jobId: JOB_ID, status: 'uploading' }));
    expect(JSON.stringify(result)).not.toMatch(/storageKey|claimedAt|retryCount|deviceId|userId|errorCode/);
  });
});
