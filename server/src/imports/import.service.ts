import {
  BadRequestException,
  ConflictException,
  HttpException,
  HttpStatus,
  Inject,
  Injectable,
  InternalServerErrorException,
  GoneException,
  NotFoundException,
  Optional,
  PayloadTooLargeException,
  RequestTimeoutException,
  ServiceUnavailableException
} from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import {
  CreateImportJobRecord,
  ConfirmImportInput,
  ConfirmImportResult,
  ImportCleanupRecord,
  ImportCleanupScope,
  ImportJobRecord,
  ImportRepository,
  MAX_UPLOAD_PART_BYTES,
  MIN_UPLOAD_PART_BYTES
} from './import.contracts';
import { CompletePdfImportDto, CreatePdfImportDto } from './import.dto';
import { ImportRepositoryError } from './import.repository';
import {
  ImportStorageError,
  ImportStoragePublishFenceError,
  ImportStorageService,
  OpenedImportFile,
  StoredFile
} from './import-storage.service';

export const IMPORT_REPOSITORY = Symbol('IMPORT_REPOSITORY');
export const IMPORT_UPLOAD_LIMITS = Symbol('IMPORT_UPLOAD_LIMITS');
export const IMPORT_ASSEMBLY_RETRY_POLICY = Symbol('IMPORT_ASSEMBLY_RETRY_POLICY');
export function effectiveImportPartBytes(configuredBytes: number): number {
  if (!Number.isInteger(configuredBytes) ||
    configuredBytes < MIN_UPLOAD_PART_BYTES || configuredBytes > MAX_UPLOAD_PART_BYTES) {
    throw new Error('IMPORT_PART_BYTES must be an integer between 65536 and 4194304');
  }
  return configuredBytes;
}

export interface ImportUploadLimits {
  maxPdfBytes: number;
  partBytes: number;
}

export interface ImportAssemblyRetryPolicy {
  maxWaitMs: number;
  retryDelayMs: number;
  maxRetryDelayMs: number;
  random(): number;
  now(): number;
  sleep(milliseconds: number, signal?: AbortSignal): Promise<void>;
  leaseTtlMs?: number;
  heartbeatIntervalMs?: number;
  heartbeatSleep?(milliseconds: number, signal?: AbortSignal): Promise<void>;
}

interface ImportAssemblyLease {
  assertOwned(): Promise<void>;
}

interface ImportAssemblyLeaseState {
  error?: unknown;
}

export interface PublicImportJob {
  jobId: string;
  bankName: string;
  subject: string;
  pageStart: number;
  pageEnd: number;
  sourceSha256: string;
  sourceSize: number;
  partCount: number;
  status: ImportJobRecord['status'];
  progress: { current: number; total: number };
  expiresAt: string;
  createdAt: string;
  updatedAt: string;
}

export interface PublicImportDraft {
  jobId: string;
  status: 'review';
  bankName: string;
  subject: string;
  expiresAt: string;
  questions: Array<{
    draftQuestionId: string;
    type: string;
    question: string;
    options: Record<string, string> | null;
    answer: string | null;
    analysis: string | null;
    pageStart: number;
    pageEnd: number;
    confidence: number;
    reviewRequired: boolean;
    images: Array<{ artifactId: string; sha256: string; size: number; contentType: 'image/jpeg' }>;
  }>;
}

export interface DownloadedImportArtifact extends OpenedImportFile {
  artifactId: string;
  sha256: string;
}

const CANCELLABLE_STATUSES = new Set<ImportJobRecord['status']>([
  'uploading', 'queued', 'processing', 'review', 'failed'
]);
const COMPLETED_UPLOAD_STATUSES = new Set<ImportJobRecord['status']>([
  'queued', 'processing', 'review', 'confirmed', 'failed'
]);
const CLEANUP_BATCH_SIZE = 32;
const DEFAULT_ASSEMBLY_LEASE_TTL_MS = 60_000;
const DEFAULT_ASSEMBLY_HEARTBEAT_INTERVAL_MS = 20_000;
const MAX_ACTIVE_ASSEMBLY_REQUESTS = 64;
const MAX_ACTIVE_ASSEMBLY_REQUESTS_PER_JOB = 16;
const abortableSleep = (milliseconds: number, signal?: AbortSignal): Promise<void> =>
  new Promise<void>((resolve, reject) => {
    if (signal?.aborted === true) {
      reject(new Error('assembly sleep aborted'));
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, milliseconds);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new Error('assembly sleep aborted'));
    };
    signal?.addEventListener('abort', onAbort, { once: true });
  });
const DEFAULT_ASSEMBLY_RETRY_POLICY: ImportAssemblyRetryPolicy = {
  maxWaitMs: 10 * 60 * 1000,
  retryDelayMs: 200,
  maxRetryDelayMs: 5_000,
  random: () => Math.random(),
  now: () => Date.now(),
  sleep: abortableSleep,
  leaseTtlMs: DEFAULT_ASSEMBLY_LEASE_TTL_MS,
  heartbeatIntervalMs: DEFAULT_ASSEMBLY_HEARTBEAT_INTERVAL_MS,
  heartbeatSleep: abortableSleep
};

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (typeof value === 'object' && value !== null) {
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => `${JSON.stringify(key)}:${stableJson(entry)}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

@Injectable()
export class ImportService {
  private readonly assemblyRetry: ImportAssemblyRetryPolicy;
  private readonly leaseTtlMs: number;
  private readonly heartbeatIntervalMs: number;
  private readonly heartbeatSleep: (milliseconds: number, signal?: AbortSignal) => Promise<void>;
  private activeAssemblyRequests = 0;
  private readonly activeAssemblyRequestsByJob = new Map<string, number>();

  constructor(
    @Inject(IMPORT_REPOSITORY) private readonly repository: ImportRepository,
    private readonly storage: ImportStorageService,
    @Inject(IMPORT_UPLOAD_LIMITS) private readonly limits: ImportUploadLimits,
    @Optional() @Inject(IMPORT_ASSEMBLY_RETRY_POLICY) retryPolicy?: ImportAssemblyRetryPolicy
  ) {
    this.assemblyRetry = retryPolicy ?? DEFAULT_ASSEMBLY_RETRY_POLICY;
    this.leaseTtlMs = this.assemblyRetry.leaseTtlMs ?? DEFAULT_ASSEMBLY_LEASE_TTL_MS;
    this.heartbeatIntervalMs = this.assemblyRetry.heartbeatIntervalMs ??
      DEFAULT_ASSEMBLY_HEARTBEAT_INTERVAL_MS;
    this.heartbeatSleep = this.assemblyRetry.heartbeatSleep ?? abortableSleep;
    if (!Number.isSafeInteger(this.assemblyRetry.maxWaitMs) || this.assemblyRetry.maxWaitMs < 1 ||
      !Number.isSafeInteger(this.assemblyRetry.retryDelayMs) || this.assemblyRetry.retryDelayMs < 1 ||
      !Number.isSafeInteger(this.assemblyRetry.maxRetryDelayMs) ||
      this.assemblyRetry.maxRetryDelayMs < this.assemblyRetry.retryDelayMs ||
      typeof this.assemblyRetry.random !== 'function' ||
      !Number.isSafeInteger(this.leaseTtlMs) || this.leaseTtlMs < 1 ||
      !Number.isSafeInteger(this.heartbeatIntervalMs) || this.heartbeatIntervalMs < 1 ||
      this.heartbeatIntervalMs >= this.leaseTtlMs) {
      throw new Error('Invalid import assembly retry policy');
    }
  }

  async create(
    userId: string,
    deviceId: string,
    input: CreatePdfImportDto
  ): Promise<PublicImportJob> {
    if (input.sourceSize > this.limits.maxPdfBytes) {
      throw this.pdfTooLarge();
    }
    const record: CreateImportJobRecord = {
      id: randomUUID(),
      userId,
      deviceId,
      bankName: input.bankName,
      subject: input.subject,
      pageStart: input.pageStart,
      pageEnd: input.pageEnd,
      sourceSha256: input.sourceSha256,
      sourceSize: String(input.sourceSize),
      partCount: Math.ceil(input.sourceSize / this.limits.partBytes)
    };
    try {
      return this.publicJob(await this.repository.createJob(record));
    } catch (error: unknown) {
      throw this.mapRepositoryError(error);
    }
  }

  async uploadPart(
    userId: string,
    deviceId: string,
    jobId: string,
    partIndex: number,
    body: Buffer,
    expectedSha256: string
  ): Promise<void> {
    if (!Number.isInteger(partIndex) || partIndex < 0) {
      throw this.badRequest('INVALID_PART_INDEX', 'Part index must be a non-negative integer');
    }
    if (body.length === 0) {
      throw this.badRequest('EMPTY_PART', 'Upload part must not be empty');
    }
    if (body.length > this.limits.partBytes) {
      throw this.partTooLarge();
    }
    const actualSha256 = createHash('sha256').update(body).digest('hex');
    if (!/^[0-9a-f]{64}$/.test(expectedSha256) || actualSha256 !== expectedSha256) {
      throw this.badRequest('PART_HASH_MISMATCH', 'Upload part SHA-256 does not match its bytes');
    }

    const initial = await this.ownedJob(userId, jobId);
    this.assertCreatingDevice(initial, deviceId);
    const canonicalJobId = initial.id;
    try {
      await this.withAssemblyLeaseRetry(canonicalJobId, async (lease) => {
        const owned = await this.ownedJob(userId, canonicalJobId);
        this.assertCreatingDevice(owned, deviceId);
        if (owned.status !== 'uploading') {
          throw this.conflict('IMPORT_NOT_UPLOADING', 'Import job is not accepting upload parts');
        }
        if (partIndex >= owned.partCount) {
          throw this.badRequest('INVALID_PART_INDEX', 'Part index exceeds the expected part count');
        }

        const storageKey = this.storage.partKey(canonicalJobId, partIndex);
        try {
          await this.repository.recordPart({
            id: randomUUID(),
            userId,
            deviceId,
            jobId: canonicalJobId,
            partNumber: partIndex,
            size: String(body.length),
            sha256: expectedSha256,
            storageKey
          });
        } catch (error: unknown) {
          throw this.mapRepositoryError(error);
        }
        await lease.assertOwned();
        let stored: StoredFile;
        try {
          stored = await this.storage.writePart(
            canonicalJobId, partIndex, body, expectedSha256, body.length,
            () => lease.assertOwned()
          );
        } catch (error: unknown) {
          throw this.mapStorageError(error);
        }
        try {
          await lease.assertOwned();
        } catch (error: unknown) {
          await this.deleteIgnoringFailure(stored.storageKey);
          throw error;
        }
      });
    } catch (error: unknown) {
      if (error instanceof HttpException) throw error;
      if (error instanceof ImportRepositoryError) throw this.mapRepositoryError(error);
      throw this.internalFailure();
    }
  }

  async complete(
    userId: string,
    deviceId: string,
    jobId: string,
    input: CompletePdfImportDto,
    signal?: AbortSignal
  ): Promise<{ jobId: string; status: ImportJobRecord['status'] }> {
    const initial = await this.ownedJob(userId, jobId);
    this.assertCreatingDevice(initial, deviceId);
    const canonicalJobId = initial.id;
    try {
      return await this.withAssemblyLeaseRetry(canonicalJobId, async (lease) => {
        const owned = await this.ownedJob(userId, canonicalJobId);
        this.assertCreatingDevice(owned, deviceId);
        if (COMPLETED_UPLOAD_STATUSES.has(owned.status)) {
          if (input.partCount !== owned.partCount || input.sourceSha256 !== owned.sourceSha256) {
            throw this.conflict(
              'IMPORT_COMPLETION_CONFLICT',
              'Completion parameters conflict with the completed upload'
            );
          }
          await lease.assertOwned();
          await this.cleanupRecordedFiles(userId, deviceId, canonicalJobId, 'parts', lease);
          return { jobId: canonicalJobId, status: owned.status };
        }
        if (input.partCount !== owned.partCount) {
          throw this.badRequest('PART_COUNT_MISMATCH', 'partCount does not match the created import job');
        }
        if (input.sourceSha256 !== owned.sourceSha256) {
          throw this.badRequest('SOURCE_HASH_MISMATCH', 'sourceSha256 does not match the created import job');
        }
        if (owned.status !== 'uploading') {
          throw this.conflict('IMPORT_NOT_UPLOADING', 'Import job cannot be completed from its current state');
        }
        const expectedSize = Number(owned.sourceSize);
        if (!Number.isSafeInteger(expectedSize) || expectedSize < 1) {
          throw this.internalFailure();
        }
        if (expectedSize > this.limits.maxPdfBytes) {
          throw this.pdfTooLarge();
        }

        const manifest = {
          storageKey: this.storage.sourceKey(canonicalJobId),
          sha256: input.sourceSha256,
          size: String(expectedSize)
        };
        await lease.assertOwned();
        try {
          await this.repository.prepareSource(userId, deviceId, canonicalJobId, manifest);
        } catch (error: unknown) {
          throw this.mapRepositoryError(error);
        }

        const source = await this.storage.mergeParts(
          canonicalJobId,
          input.partCount,
          expectedSize,
          input.sourceSha256,
          () => lease.assertOwned()
        );
        if (source.size !== expectedSize || source.sha256 !== input.sourceSha256) {
          await this.deleteIfNew(source);
          throw this.badRequest('SOURCE_INTEGRITY_MISMATCH', 'Merged PDF does not match the created import job');
        }

        try {
          await lease.assertOwned();
        } catch (error: unknown) {
          await this.deleteIgnoringFailure(source.storageKey);
          throw error;
        }

        try {
          await this.repository.queueCompletedUpload(userId, deviceId, canonicalJobId, manifest);
        } catch (error: unknown) {
          throw this.mapRepositoryError(error);
        }

        await lease.assertOwned();
        await this.cleanupRecordedFiles(userId, deviceId, canonicalJobId, 'parts', lease);
        return { jobId: canonicalJobId, status: 'queued' as const };
      }, signal);
    } catch (error: unknown) {
      if (error instanceof HttpException) throw error;
      if (error instanceof ImportRepositoryError) throw this.mapRepositoryError(error);
      throw this.mapStorageError(error);
    }
  }

  async get(userId: string, jobId: string): Promise<PublicImportJob> {
    return this.publicJob(await this.ownedJob(userId, jobId));
  }

  async getDraft(userId: string, jobId: string): Promise<PublicImportDraft> {
    let review;
    try {
      review = await this.repository.getReviewDraft(userId, jobId);
    } catch (error: unknown) {
      throw this.mapRepositoryError(error);
    }
    if (review === null) throw this.importNotFound();
    if (review.job.expiresAt.getTime() <= Date.now()) throw this.importExpired();
    if (review.job.status !== 'review') {
      throw this.conflict('IMPORT_NOT_IN_REVIEW', 'Import job is not awaiting review');
    }
    return {
      jobId: review.job.id,
      status: 'review',
      bankName: review.job.bankName,
      subject: review.job.subject,
      expiresAt: review.job.expiresAt.toISOString(),
      questions: [...review.questions].sort((left, right) => left.position - right.position)
        .map((question) => ({
          draftQuestionId: question.id,
          type: question.type,
          question: question.question,
          options: question.options,
          answer: question.answer,
          analysis: question.analysis,
          pageStart: question.pageStart,
          pageEnd: question.pageEnd,
          confidence: question.confidence,
          reviewRequired: question.reviewRequired,
          images: question.artifacts.map((artifact) => ({
            artifactId: artifact.id,
            sha256: artifact.sha256,
            size: Number(artifact.size),
            contentType: 'image/jpeg' as const
          }))
        }))
    };
  }

  async confirm(
    userId: string,
    deviceId: string,
    jobId: string,
    input: ConfirmImportInput
  ): Promise<ConfirmImportResult> {
    const owned = await this.ownedJob(userId, jobId);
    this.assertCreatingDevice(owned, deviceId);
    const canonicalJobId = owned.id;
    if (owned.expiresAt.getTime() <= Date.now()) throw this.importExpired();
    if (owned.status !== 'review' && owned.status !== 'confirmed') {
      throw this.conflict('IMPORT_NOT_IN_REVIEW', 'Import job cannot be confirmed from its current state');
    }
    const identifiers = input.questions.map((question) => question.draftQuestionId.toLowerCase());
    if (new Set(identifiers).size !== identifiers.length) {
      throw this.badRequest('INVALID_DRAFT', 'Confirmation repeats a draft question');
    }
    // Nested UUIDs are compared and hashed in lowercase only: an uppercase draft id
    // from the client must match the persisted lowercase row and must not change
    // the idempotency hash.
    const canonicalInput = {
      ...input,
      questions: [...input.questions]
        .map((question) => ({ ...question, draftQuestionId: question.draftQuestionId.toLowerCase() }))
        .sort((left, right) =>
          left.draftQuestionId.localeCompare(right.draftQuestionId))
    };
    const requestSha256 = createHash('sha256').update(stableJson(canonicalInput)).digest('hex');
    try {
      return await this.repository.confirmImport(
        userId, deviceId, canonicalJobId, requestSha256, canonicalInput
      );
    } catch (error: unknown) {
      throw this.mapRepositoryError(error);
    }
  }

  async downloadArtifact(
    userId: string,
    deviceId: string,
    jobId: string,
    artifactId: string
  ): Promise<DownloadedImportArtifact> {
    const owned = await this.ownedJob(userId, jobId);
    this.assertCreatingDevice(owned, deviceId);
    const canonicalJobId = owned.id;
    const now = new Date();
    let metadata;
    try {
      metadata = await this.repository.findDownloadArtifact(
        userId, deviceId, canonicalJobId, artifactId, now
      );
    } catch (error: unknown) {
      throw this.mapRepositoryError(error);
    }
    if (metadata === null) throw this.artifactNotFound();
    let expectedStorageKey: string;
    try {
      expectedStorageKey = this.storage.artifactKey(canonicalJobId, artifactId);
    } catch {
      throw this.artifactNotFound();
    }
    if (metadata.artifactId.toLowerCase() !== artifactId.toLowerCase() ||
      metadata.storageKey !== expectedStorageKey || !/^[0-9a-f]{64}$/.test(metadata.sha256) ||
      !Number.isSafeInteger(metadata.size) || metadata.size < 1) throw this.artifactNotFound();
    let opened: OpenedImportFile;
    try {
      opened = await this.storage.openReadStream(metadata.storageKey, metadata.size,
        metadata.sha256, { jobId: canonicalJobId, artifactId });
    } catch {
      throw this.artifactNotFound();
    }
    try {
      const revalidated = await this.repository.findDownloadArtifact(
        userId, deviceId, canonicalJobId, artifactId, new Date()
      );
      if (revalidated === null || revalidated.artifactId.toLowerCase() !== artifactId.toLowerCase() ||
        revalidated.storageKey !== expectedStorageKey || revalidated.storageKey !== metadata.storageKey ||
        revalidated.sha256 !== metadata.sha256 || revalidated.size !== metadata.size) {
        throw this.artifactNotFound();
      }
      return {
        ...opened,
        artifactId: metadata.artifactId,
        sha256: metadata.sha256
      };
    } catch (error: unknown) {
      await opened.close().catch(() => undefined);
      if (error instanceof HttpException) throw error;
      throw this.artifactNotFound();
    }
  }

  async ackArtifacts(
    userId: string,
    deviceId: string,
    jobId: string,
    artifactIds: string[]
  ): Promise<void> {
    const owned = await this.ownedJob(userId, jobId);
    this.assertCreatingDevice(owned, deviceId);
    const canonicalJobId = owned.id;
    if (owned.expiresAt.getTime() <= Date.now()) throw this.importExpired();
    if (owned.status !== 'confirmed') {
      throw this.conflict('IMPORT_NOT_CONFIRMED', 'Import job is not ready for acknowledgement');
    }
    // ACK ids are canonicalized to lowercase before duplicate detection and
    // delegation; the persisted artifact rows are always lowercase UUIDs.
    const canonicalIds = artifactIds.map((id) => id.toLowerCase());
    if (new Set(canonicalIds).size !== canonicalIds.length) {
      throw this.badRequest('INVALID_ARTIFACT_SET', 'Artifact acknowledgement contains duplicates');
    }
    const now = new Date();
    let plan;
    try {
      plan = await this.repository.prepareArtifactAck(
        userId, deviceId, canonicalJobId, canonicalIds, now
      );
    } catch (error: unknown) {
      throw this.mapRepositoryError(error);
    }
    if (plan.acknowledged) return;
    for (const record of plan.records) {
      if (!record.storageKey.startsWith(`${canonicalJobId}/`)) {
        throw this.cleanupUnavailable();
      }
      try {
        await this.storage.deleteStorageKey(record.storageKey);
      } catch {
        throw this.cleanupUnavailable();
      }
    }
    try {
      await this.storage.deleteJobDirectory(canonicalJobId);
      if (await this.storage.jobDirectoryExists(canonicalJobId)) throw new Error('directory not empty');
    } catch {
      throw this.cleanupUnavailable();
    }
    try {
      await this.repository.markArtifactsAcknowledged(
        userId, deviceId, canonicalJobId, new Date()
      );
    } catch (error: unknown) {
      throw this.mapRepositoryError(error);
    }
  }

  async cancel(userId: string, deviceId: string, jobId: string, signal?: AbortSignal): Promise<void> {
    const initial = await this.ownedJob(userId, jobId);
    this.assertCreatingDevice(initial, deviceId);
    const canonicalJobId = initial.id;
    try {
      await this.withAssemblyLeaseRetry(canonicalJobId, async (lease) => {
        let owned = await this.ownedJob(userId, canonicalJobId);
        this.assertCreatingDevice(owned, deviceId);
        if (owned.status !== 'cancelled') {
          if (!CANCELLABLE_STATUSES.has(owned.status)) {
            throw this.conflict('IMPORT_NOT_CANCELLABLE', 'Import job cannot be cancelled from its current state');
          }
          await lease.assertOwned();
          let cancelled: boolean;
          try {
            cancelled = await this.repository.cancelOwned(userId, deviceId, canonicalJobId);
          } catch (error: unknown) {
            throw this.mapRepositoryError(error);
          }
          if (!cancelled) {
            owned = await this.ownedJob(userId, canonicalJobId);
            this.assertCreatingDevice(owned, deviceId);
            if (owned.status !== 'cancelled') {
              throw this.conflict('IMPORT_STATE_CONFLICT', 'Import job changed while cancellation was requested');
            }
          }
        }
        await lease.assertOwned();
        await this.cleanupRecordedFiles(userId, deviceId, canonicalJobId, 'all', lease);
      }, signal);
    } catch (error: unknown) {
      if (error instanceof HttpException) throw error;
      if (error instanceof ImportRepositoryError) throw this.mapRepositoryError(error);
      throw this.mapStorageError(error);
    }
  }

  private async ownedJob(userId: string, jobId: string): Promise<ImportJobRecord> {
    let owned: ImportJobRecord | null;
    try {
      owned = await this.repository.findOwnedJob(userId, jobId);
    } catch (error: unknown) {
      throw this.mapRepositoryError(error);
    }
    if (owned === null) {
      throw this.importNotFound();
    }
    return owned;
  }

  private assertCreatingDevice(job: ImportJobRecord, deviceId: string): void {
    if (job.deviceId !== deviceId) {
      throw new NotFoundException({
        statusCode: HttpStatus.NOT_FOUND,
        code: 'IMPORT_NOT_FOUND',
        message: 'Import job was not found'
      });
    }
  }

  private publicJob(job: ImportJobRecord): PublicImportJob {
    return {
      jobId: job.id,
      bankName: job.bankName,
      subject: job.subject,
      pageStart: job.pageStart,
      pageEnd: job.pageEnd,
      sourceSha256: job.sourceSha256,
      sourceSize: Number(job.sourceSize),
      partCount: job.partCount,
      status: job.status,
      progress: { current: job.progressCurrent, total: job.progressTotal },
      expiresAt: job.expiresAt.toISOString(),
      createdAt: job.createdAt.toISOString(),
      updatedAt: job.updatedAt.toISOString()
    };
  }

  private async deleteIfNew(stored: StoredFile): Promise<void> {
    if (stored.created) {
      await this.deleteIgnoringFailure(stored.storageKey);
    }
  }

  private async cleanupRecordedFiles(
    userId: string,
    deviceId: string,
    jobId: string,
    scope: ImportCleanupScope,
    lease: ImportAssemblyLease
  ): Promise<void> {
    let offset = 0;
    while (true) {
      await lease.assertOwned();
      let records: ImportCleanupRecord[];
      try {
        records = await this.repository.listCleanupRecords(
          userId, deviceId, jobId, scope, offset, CLEANUP_BATCH_SIZE
        );
      } catch {
        return;
      }
      if (records.length === 0) break;
      for (const record of records) {
        if (!record.storageKey.startsWith(`${jobId}/`)) return;
        await lease.assertOwned();
        try {
          await this.storage.deleteStorageKey(record.storageKey);
        } catch {
          if (scope === 'parts') return;
          continue;
        }
      }
      offset += records.length;
      if (records.length < CLEANUP_BATCH_SIZE) break;
    }
    if (scope === 'all') {
      // The job is terminal, so any file still present is staging or a late publish.
      // Sweep the directory and remove it: once the directory is gone, a late
      // hard-link publish fails with ENOENT and can never materialize a file.
      // Rows are durable tombstones and are retired only with the job.
      try {
        await lease.assertOwned();
        await this.storage.deleteJobDirectory(jobId);
      } catch {
        // Best effort; a later cancellation or the expiry cleanup retries.
      }
    }
  }

  private async withAssemblyLeaseRetry<T>(
    jobId: string,
    operation: (lease: ImportAssemblyLease) => Promise<T>,
    signal?: AbortSignal
  ): Promise<T> {
    this.enterAssemblyRequest(jobId);
    try {
      return await this.waitForAssemblyLease(jobId, operation, signal);
    } finally {
      this.leaveAssemblyRequest(jobId);
    }
  }

  private async waitForAssemblyLease<T>(
    jobId: string,
    operation: (lease: ImportAssemblyLease) => Promise<T>,
    signal?: AbortSignal
  ): Promise<T> {
    const deadline = this.assemblyRetry.now() + this.assemblyRetry.maxWaitMs;
    const token = randomUUID();
    let attempt = 0;
    while (true) {
      this.assertRequestActive(signal);
      const nowMs = this.assemblyRetry.now();
      const remaining = deadline - nowMs;
      if (remaining <= 0) throw new ImportRepositoryError('ASSEMBLY_BUSY');
      let acquired: boolean;
      try {
        acquired = await this.repository.tryAcquireAssemblyLease(
          jobId,
          token,
          new Date(nowMs),
          new Date(nowMs + this.leaseTtlMs)
        );
      } catch (error: unknown) {
        try {
          await this.repository.releaseAssemblyLease(jobId, token);
        } catch {
          // An exact-token lease row expires quickly if the commit result is unknowable.
        }
        throw error;
      }
      if (acquired) {
        if (signal?.aborted === true) {
          try {
            await this.repository.releaseAssemblyLease(jobId, token);
          } catch {
            // Preserve the client-abort response; the expiring row remains safely fenced.
          }
          throw this.requestAborted();
        }
        return this.runWithOwnedLease(jobId, token, operation);
      }
      this.assertRequestActive(signal);
      const delay = this.nextRetryDelay(attempt, remaining);
      attempt += 1;
      await this.retrySleep(delay, signal);
    }
  }

  private enterAssemblyRequest(jobId: string): void {
    const jobCount = this.activeAssemblyRequestsByJob.get(jobId) ?? 0;
    if (this.activeAssemblyRequests >= MAX_ACTIVE_ASSEMBLY_REQUESTS ||
      jobCount >= MAX_ACTIVE_ASSEMBLY_REQUESTS_PER_JOB) {
      throw new ImportRepositoryError('ASSEMBLY_BUSY');
    }
    this.activeAssemblyRequests += 1;
    this.activeAssemblyRequestsByJob.set(jobId, jobCount + 1);
  }

  private leaveAssemblyRequest(jobId: string): void {
    this.activeAssemblyRequests -= 1;
    const jobCount = this.activeAssemblyRequestsByJob.get(jobId) ?? 1;
    if (jobCount <= 1) this.activeAssemblyRequestsByJob.delete(jobId);
    else this.activeAssemblyRequestsByJob.set(jobId, jobCount - 1);
  }

  private async runWithOwnedLease<T>(
    jobId: string,
    token: string,
    operation: (lease: ImportAssemblyLease) => Promise<T>
  ): Promise<T> {
    const state: ImportAssemblyLeaseState = {};
    const heartbeatStop = new AbortController();
    const heartbeat = this.runLeaseHeartbeat(jobId, token, state, heartbeatStop.signal);
    let result: T | undefined;
    let operationError: unknown;
    try {
      result = await operation({
        assertOwned: () => this.renewOwnedLease(jobId, token, state)
      });
    } catch (error: unknown) {
      operationError = error;
    } finally {
      heartbeatStop.abort();
      await heartbeat;
    }
    if (operationError === undefined && state.error !== undefined) operationError = state.error;

    let released = false;
    let releaseError: unknown;
    try {
      released = await this.repository.releaseAssemblyLease(jobId, token);
    } catch (error: unknown) {
      releaseError = error;
    }
    if (operationError !== undefined) throw operationError;
    if (releaseError !== undefined || !released) {
      throw new ImportRepositoryError('ASSEMBLY_LEASE_FAILURE');
    }
    return result as T;
  }

  private async runLeaseHeartbeat(
    jobId: string,
    token: string,
    state: ImportAssemblyLeaseState,
    signal: AbortSignal
  ): Promise<void> {
    while (!signal.aborted && state.error === undefined) {
      try {
        await this.heartbeatSleep(this.heartbeatIntervalMs, signal);
      } catch (error: unknown) {
        if (signal.aborted) return;
        state.error = error;
        return;
      }
      if (signal.aborted) return;
      try {
        await this.renewOwnedLease(jobId, token, state);
      } catch {
        return;
      }
    }
  }

  private async renewOwnedLease(
    jobId: string,
    token: string,
    state: ImportAssemblyLeaseState
  ): Promise<void> {
    if (state.error !== undefined) throw state.error;
    const nowMs = this.assemblyRetry.now();
    try {
      const renewed = await this.repository.renewAssemblyLease(
        jobId,
        token,
        new Date(nowMs),
        new Date(nowMs + this.leaseTtlMs)
      );
      if (!renewed) {
        state.error = new ImportRepositoryError('ASSEMBLY_LEASE_LOST');
        throw state.error;
      }
    } catch (error: unknown) {
      if (state.error === undefined) state.error = error;
      throw state.error;
    }
  }

  private nextRetryDelay(attempt: number, remainingMs: number): number {
    const random = this.assemblyRetry.random();
    if (!Number.isFinite(random) || random < 0 || random > 1) {
      throw new ImportRepositoryError('ASSEMBLY_LEASE_FAILURE');
    }
    const exponent = Math.min(attempt, 30);
    const exponential = Math.min(
      this.assemblyRetry.maxRetryDelayMs,
      this.assemblyRetry.retryDelayMs * (2 ** exponent)
    );
    const jittered = Math.max(1, Math.round(exponential * (0.75 + (random * 0.5))));
    return Math.min(jittered, remainingMs);
  }

  private async retrySleep(milliseconds: number, signal?: AbortSignal): Promise<void> {
    this.assertRequestActive(signal);
    let abortSleep: (error: unknown) => void = () => undefined;
    const aborted = new Promise<void>((_resolve, reject) => { abortSleep = reject; });
    const onAbort = () => abortSleep(this.requestAborted());
    signal?.addEventListener('abort', onAbort, { once: true });
    try {
      await Promise.race([
        this.assemblyRetry.sleep(milliseconds, signal),
        aborted
      ]);
    } catch (error: unknown) {
      this.assertRequestActive(signal);
      throw error;
    } finally {
      signal?.removeEventListener('abort', onAbort);
    }
  }

  private async deleteIgnoringFailure(storageKey: string): Promise<void> {
    try {
      await this.storage.deleteStorageKey(storageKey);
    } catch {
      // A cancelled/queued database state is recoverable; expiry cleanup may retry the file deletion.
    }
  }

  private mapRepositoryError(error: unknown): HttpException {
    if (error instanceof ImportRepositoryError) {
      if (error.code === 'IMPORT_PART_CONFLICT') {
        return this.conflict('IMPORT_PART_CONFLICT', 'Upload part conflicts with the recorded part');
      }
      if (error.code === 'IMPORT_JOB_CONFLICT') {
        return this.conflict('IMPORT_JOB_CONFLICT', 'Import job already exists');
      }
      if (error.code === 'ASSEMBLY_BUSY') {
        return this.conflict('ASSEMBLY_BUSY', 'Import assembly is already in progress');
      }
      if (error.code === 'ASSEMBLY_LEASE_FAILURE') {
        return this.internalFailure('IMPORT_ASSEMBLY_FAILURE');
      }
      if (error.code === 'IMPORT_CONFIRMATION_CONFLICT') {
        return this.conflict('IMPORT_CONFIRMATION_CONFLICT', 'Import was already confirmed with different content');
      }
      if (error.code === 'INVALID_DRAFT') {
        return this.badRequest('INVALID_DRAFT', 'Confirmation must cover the complete current draft');
      }
      if (error.code === 'INVALID_ARTIFACT_SET') {
        return this.badRequest('INVALID_ARTIFACT_SET', 'Acknowledgement must exactly match confirmed images');
      }
      return this.conflict('IMPORT_STATE_CONFLICT', 'Import job changed during the request');
    }
    return this.internalFailure();
  }

  private mapStorageError(error: unknown): HttpException {
    if (error instanceof ImportStoragePublishFenceError) {
      if (error.cause instanceof HttpException) return error.cause;
      if (error.cause instanceof ImportRepositoryError) {
        return this.mapRepositoryError(error.cause);
      }
      return this.internalFailure('IMPORT_ASSEMBLY_FAILURE');
    }
    if (!(error instanceof ImportStorageError)) {
      return this.internalFailure();
    }
    switch (error.code) {
      case 'UPLOAD_PART_CONFLICT':
      case 'SOURCE_FILE_CONFLICT':
        return this.conflict(error.code, 'Stored upload content conflicts with this request');
      case 'INSUFFICIENT_STORAGE':
        return new HttpException({
          statusCode: HttpStatus.INSUFFICIENT_STORAGE,
          code: 'INSUFFICIENT_STORAGE',
          message: 'Import storage has insufficient capacity'
        }, HttpStatus.INSUFFICIENT_STORAGE);
      case 'FILE_HASH_MISMATCH':
      case 'FILE_SIZE_MISMATCH':
      case 'UPLOAD_PART_MISSING':
      case 'Invalid upload part number':
        return this.badRequest(error.code, 'Uploaded PDF parts failed integrity validation');
      default:
        return this.internalFailure('IMPORT_STORAGE_FAILURE');
    }
  }

  private badRequest(code: string, message: string): BadRequestException {
    return new BadRequestException({ statusCode: HttpStatus.BAD_REQUEST, code, message });
  }

  private importNotFound(): NotFoundException {
    return new NotFoundException({
      statusCode: HttpStatus.NOT_FOUND,
      code: 'IMPORT_NOT_FOUND',
      message: 'Import job was not found'
    });
  }

  private artifactNotFound(): NotFoundException {
    return new NotFoundException({
      statusCode: HttpStatus.NOT_FOUND,
      code: 'ARTIFACT_NOT_FOUND',
      message: 'Import artifact was not found'
    });
  }

  private importExpired(): GoneException {
    return new GoneException({
      statusCode: HttpStatus.GONE,
      code: 'IMPORT_EXPIRED',
      message: 'Import job has expired'
    });
  }

  private cleanupUnavailable(): ServiceUnavailableException {
    return new ServiceUnavailableException({
      statusCode: HttpStatus.SERVICE_UNAVAILABLE,
      code: 'ARTIFACT_CLEANUP_RETRY',
      message: 'Import cleanup did not finish; retry acknowledgement'
    });
  }

  private conflict(code: string, message: string): ConflictException {
    return new ConflictException({ statusCode: HttpStatus.CONFLICT, code, message });
  }

  private pdfTooLarge(): PayloadTooLargeException {
    return new PayloadTooLargeException({
      statusCode: HttpStatus.PAYLOAD_TOO_LARGE,
      code: 'PDF_TOO_LARGE',
      message: 'PDF exceeds 200 MB'
    });
  }

  private partTooLarge(): PayloadTooLargeException {
    return new PayloadTooLargeException({
      statusCode: HttpStatus.PAYLOAD_TOO_LARGE,
      code: 'PART_TOO_LARGE',
      message: 'Upload part exceeds the configured limit'
    });
  }

  private requestAborted(): RequestTimeoutException {
    return new RequestTimeoutException({
      statusCode: HttpStatus.REQUEST_TIMEOUT,
      code: 'IMPORT_REQUEST_ABORTED',
      message: 'Import request was cancelled before assembly started'
    });
  }

  private assertRequestActive(signal?: AbortSignal): void {
    if (signal?.aborted === true) throw this.requestAborted();
  }

  private internalFailure(code = 'IMPORT_SERVICE_FAILURE'): InternalServerErrorException {
    return new InternalServerErrorException({
      statusCode: HttpStatus.INTERNAL_SERVER_ERROR,
      code,
      message: 'Import request could not be completed'
    });
  }
}
