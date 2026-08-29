import { Injectable } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { randomUUID } from 'node:crypto';
import { Brackets, DataSource, EntityManager, In, IsNull, LessThanOrEqual, MoreThan } from 'typeorm';
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
import { SyncOperationInput } from '../sync/sync.contracts';
import {
  CompletedSource,
  ConfirmImportInput,
  ConfirmImportResult,
  CreateImportJobRecord,
  ImportArtifactAckPlan,
  ImportCleanupCandidate,
  ImportCleanupRecord,
  ImportCleanupScope,
  ImportDraftRecord,
  ImportDownloadArtifact,
  ImportJobRecord,
  ImportJobStatus,
  ImportPartRecord,
  ImportRepository,
  ImportReviewRecord
} from './import.contracts';
import { canonicalArtifactStorageKey } from './import-storage.service';

const DAY_MS = 24 * 60 * 60 * 1000;
const CANCELLABLE_STATUSES: ImportJobStatus[] = ['uploading', 'queued', 'processing', 'review', 'failed'];
const EXPIRABLE_STATUSES: ImportJobStatus[] = ['uploading', 'queued', 'processing', 'review', 'failed'];
const PART_CLEANUP_STATUSES: ImportJobStatus[] = [
  'queued', 'processing', 'review', 'confirmed', 'failed', 'cancelled', 'expired'
];
const EXPIRY_BATCH_SIZE = 100;
const MAX_CLEANUP_OFFSET = 100_000;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SAFE_SHA256_PATTERN = /^[0-9a-f]{64}$/;
const MAX_DOWNLOAD_ARTIFACT_BYTES = 209_715_200;
const TERMINAL_CLEANUP_STATUSES: ImportJobStatus[] = ['confirmed', 'cancelled', 'expired'];

export class ImportRepositoryError extends Error {
  constructor(public readonly code: 'IMPORT_JOB_CONFLICT' | 'IMPORT_PART_CONFLICT' | 'IMPORT_DRAFT_CONFLICT' | 'IMPORT_ARTIFACT_CONFLICT' | 'IMPORT_CONFIRMATION_CONFLICT' | 'INVALID_DRAFT' | 'INVALID_ARTIFACT_SET' | 'INVALID_PROGRESS' | 'INVALID_STATE' | 'ASSEMBLY_BUSY' | 'ASSEMBLY_LEASE_FAILURE' | 'ASSEMBLY_LEASE_LOST') {
    super(code);
    this.name = 'ImportRepositoryError';
  }
}

function normalizeOptions(value: Record<string, string> | null | undefined): Record<string, string> | null {
  return value ?? null;
}

function normalizeNullableText(value: string | null | undefined): string | null {
  return value ?? null;
}

function sameOptions(left: Record<string, string> | null | undefined,
  right: Record<string, string> | null | undefined): boolean {
  const normalizedLeft = normalizeOptions(left);
  const normalizedRight = normalizeOptions(right);
  if (normalizedLeft === null || normalizedRight === null) return normalizedLeft === normalizedRight;
  const normalize = (value: Record<string, string>) => Object.entries(value)
    .sort(([leftKey], [rightKey]) => leftKey.localeCompare(rightKey));
  return JSON.stringify(normalize(normalizedLeft)) === JSON.stringify(normalize(normalizedRight));
}

function toRecord(job: ImportJobEntity): ImportJobRecord {
  return {
    id: job.id,
    userId: job.userId,
    deviceId: job.deviceId,
    bankName: job.bankName,
    subject: job.subject,
    pageStart: job.pageStart,
    pageEnd: job.pageEnd,
    status: job.status,
    progressCurrent: job.progressCurrent,
    progressTotal: job.progressTotal,
    sourceSha256: job.sourceSha256,
    sourceSize: String(job.sourceSize),
    partCount: job.partCount,
    retryCount: job.retryCount,
    errorCode: job.errorCode,
    claimedAt: job.claimedAt,
    expiresAt: job.expiresAt,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt
  };
}

function assertAffected(affected: number | null | undefined): void {
  if (affected !== 1) {
    throw new ImportRepositoryError('INVALID_STATE');
  }
}

function samePart(existing: ImportUploadPartEntity, input: ImportPartRecord): boolean {
  return existing.size === input.size &&
    existing.sha256 === input.sha256 &&
    existing.storageKey === input.storageKey;
}

function sameSource(existing: ImportArtifactEntity, source: CompletedSource): boolean {
  return existing.type === 'source_pdf' && existing.draftQuestionId === null &&
    existing.storageKey === source.storageKey && existing.sha256 === source.sha256 &&
    String(existing.size) === source.size;
}

function isDuplicateKeyError(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false;
  const candidate = error as { code?: unknown; errno?: unknown };
  return candidate.code === 'ER_DUP_ENTRY' || candidate.errno === 1062;
}

function assertOrderedDraft(draft: ImportDraftRecord): void {
  const positions = new Set<number>();
  let previous = -1;
  for (const question of draft.questions) {
    if (!Number.isInteger(question.position) || question.position < 0 || question.position <= previous || positions.has(question.position)) {
      throw new ImportRepositoryError('INVALID_DRAFT');
    }
    previous = question.position;
    positions.add(question.position);
  }
}

@Injectable()
export class TypeOrmImportRepository implements ImportRepository {
  constructor(
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly clock: () => Date = () => new Date()
  ) {}

  async tryAcquireAssemblyLease(
    jobId: string,
    token: string,
    now: Date,
    expiresAt: Date
  ): Promise<boolean> {
    this.assertValidLeaseInput(jobId, token, now, expiresAt);
    const leases = this.dataSource.getRepository(ImportJobLeaseEntity);
    try {
      await leases.insert({ jobId: jobId.toLowerCase(), token, expiresAt });
      return true;
    } catch (error: unknown) {
      if (!isDuplicateKeyError(error)) throw error;
    }
    const result = await leases.update(
      { jobId: jobId.toLowerCase(), expiresAt: LessThanOrEqual(now) },
      { token, expiresAt }
    );
    return result.affected === 1;
  }

  async renewAssemblyLease(
    jobId: string,
    token: string,
    now: Date,
    expiresAt: Date
  ): Promise<boolean> {
    this.assertValidLeaseInput(jobId, token, now, expiresAt);
    const result = await this.dataSource.getRepository(ImportJobLeaseEntity).update(
      { jobId: jobId.toLowerCase(), token, expiresAt: MoreThan(now) },
      { expiresAt }
    );
    return result.affected === 1;
  }

  async releaseAssemblyLease(jobId: string, token: string): Promise<boolean> {
    if (!UUID_PATTERN.test(jobId) || !UUID_PATTERN.test(token)) {
      throw new ImportRepositoryError('INVALID_STATE');
    }
    const result = await this.dataSource.getRepository(ImportJobLeaseEntity).delete({
      jobId: jobId.toLowerCase(),
      token
    });
    return result.affected === 1;
  }

  async createJob(input: CreateImportJobRecord): Promise<ImportJobRecord> {
    const now = this.clock();
    const entity = {
      ...input,
      status: 'uploading' as ImportJobStatus,
      progressCurrent: 0,
      progressTotal: 0,
      retryCount: 0,
      errorCode: null,
      claimedAt: null,
      expiresAt: new Date(now.getTime() + DAY_MS)
    };
    return this.dataSource.transaction(async (manager) => {
      try { await manager.insert(ImportJobEntity, entity); }
      catch (error) { if (isDuplicateKeyError(error)) throw new ImportRepositoryError('IMPORT_JOB_CONFLICT'); throw error; }
      const saved = await manager.findOne(ImportJobEntity, { where: { id: input.id } });
      if (saved === null) throw new ImportRepositoryError('INVALID_STATE');
      return toRecord(saved);
    });
  }

  async findOwnedJob(userId: string, jobId: string): Promise<ImportJobRecord | null> {
    const entity = await this.dataSource.getRepository(ImportJobEntity).findOne({
      where: { id: jobId, userId }
    });
    return entity === null ? null : toRecord(entity);
  }

  async recordPart(input: ImportPartRecord): Promise<void> {
    const { userId: _userId, deviceId: _deviceId, ...part } = input;
    try {
      await this.dataSource.transaction(async (manager) => {
        await this.lockUploadingJob(manager, input);
        const existing = await manager.findOne(ImportUploadPartEntity, { where: { jobId: input.jobId, partNumber: input.partNumber } });
        if (existing !== null) return this.assertSamePart(existing, input);
        await manager.insert(ImportUploadPartEntity, part);
      });
    } catch (error: unknown) {
      if (!isDuplicateKeyError(error)) throw error;
      const winner = await this.dataSource.transaction(async (manager) => {
        await this.lockUploadingJob(manager, input);
        return manager.findOne(ImportUploadPartEntity, { where: { jobId: input.jobId, partNumber: input.partNumber } });
      });
      if (winner === null) throw new ImportRepositoryError('IMPORT_PART_CONFLICT');
      this.assertSamePart(winner, input);
    }
  }

  async prepareSource(
    userId: string,
    deviceId: string,
    jobId: string,
    source: CompletedSource
  ): Promise<void> {
    await this.dataSource.transaction(async (manager) => {
      const job = await manager.findOne(ImportJobEntity, {
        where: { id: jobId, userId, deviceId, status: 'uploading' },
        lock: { mode: 'pessimistic_write' }
      });
      if (job === null) throw new ImportRepositoryError('INVALID_STATE');
      const existing = await manager.findOne(ImportArtifactEntity, {
        where: { jobId, type: 'source_pdf', draftQuestionId: IsNull() }
      });
      if (existing !== null) {
        if (!sameSource(existing, source)) throw new ImportRepositoryError('IMPORT_ARTIFACT_CONFLICT');
        return;
      }
      try {
        await manager.insert(ImportArtifactEntity, {
          id: randomUUID(),
          jobId,
          draftQuestionId: null,
          type: 'source_pdf',
          storageKey: source.storageKey,
          sha256: source.sha256,
          size: source.size,
          expiresAt: job.expiresAt
        });
      } catch (error: unknown) {
        if (isDuplicateKeyError(error)) throw new ImportRepositoryError('IMPORT_ARTIFACT_CONFLICT');
        throw error;
      }
    });
  }

  async queueCompletedUpload(userId: string, deviceId: string, jobId: string, source: CompletedSource): Promise<void> {
    await this.dataSource.transaction(async (manager) => {
      const job = await manager.findOne(ImportJobEntity, {
        where: { id: jobId, userId, deviceId, status: 'uploading' },
        lock: { mode: 'pessimistic_write' }
      });
      if (job === null) throw new ImportRepositoryError('INVALID_STATE');
      const artifact = await manager.findOne(ImportArtifactEntity, {
        where: { jobId, type: 'source_pdf', draftQuestionId: IsNull() }
      });
      if (artifact === null || !sameSource(artifact, source)) {
        throw new ImportRepositoryError('IMPORT_ARTIFACT_CONFLICT');
      }
      const result = await manager.update(ImportJobEntity,
        { id: jobId, userId, deviceId, status: 'uploading' },
        { status: 'queued', errorCode: null, claimedAt: null });
      assertAffected(result.affected);
    });
  }

  async claimNext(_workerId: string): Promise<ImportJobRecord | null> {
    return this.dataSource.transaction(async (manager) => {
      const job = await manager.getRepository(ImportJobEntity)
        .createQueryBuilder('job')
        .setLock('pessimistic_write')
        .setOnLocked('skip_locked')
        .where({ status: 'queued' })
        .orderBy('job.createdAt', 'ASC')
        .take(1)
        .getOne();
      if (job === null) return null;
      const clockNow = this.clock();
      const claimedAt = job.claimedAt !== null && job.claimedAt.getTime() >= clockNow.getTime()
        ? new Date(job.claimedAt.getTime() + 1)
        : clockNow;
      const result = await manager.update(ImportJobEntity,
        { id: job.id, status: 'queued' },
        { status: 'processing', claimedAt, errorCode: null, updatedAt: claimedAt });
      assertAffected(result.affected);
      job.status = 'processing';
      job.claimedAt = claimedAt;
      job.errorCode = null;
      job.updatedAt = claimedAt;
      return toRecord(job);
    });
  }

  async updateProgress(jobId: string, expectedClaimedAt: Date, current: number, total: number): Promise<void> {
    if (!Number.isInteger(current) || !Number.isInteger(total) || current < 0 || total < 0 || current > total) {
      throw new ImportRepositoryError('INVALID_PROGRESS');
    }
    const result = await this.dataSource.getRepository(ImportJobEntity).update(
      { id: jobId, status: 'processing', claimedAt: expectedClaimedAt },
      { progressCurrent: current, progressTotal: total }
    );
    assertAffected(result.affected);
  }

  async replaceDraft(jobId: string, expectedClaimedAt: Date, draft: ImportDraftRecord): Promise<void> {
    assertOrderedDraft(draft);
    await this.dataSource.transaction(async (manager) => {
      const locked = await manager.findOne(ImportJobEntity, { where: { id: jobId, status: 'processing', claimedAt: expectedClaimedAt }, lock: { mode: 'pessimistic_write' } });
      if (locked === null) throw new ImportRepositoryError('INVALID_STATE');
      await manager.delete(ImportArtifactEntity, { jobId, type: 'question_image' });
      await manager.delete(ImportDraftQuestionEntity, { jobId });
      for (const question of draft.questions) {
        try { await manager.insert(ImportDraftQuestionEntity, {
          id: question.id, jobId, position: question.position, type: question.type,
          question: question.question, options: question.options, answer: question.answer,
          analysis: question.analysis, pageStart: question.pageStart, pageEnd: question.pageEnd,
          confidence: question.confidence, reviewRequired: question.reviewRequired
        }); } catch (error) { if (isDuplicateKeyError(error)) throw new ImportRepositoryError('IMPORT_DRAFT_CONFLICT'); throw error; }
        for (const artifact of question.artifacts) {
          try { await manager.insert(ImportArtifactEntity, {
            id: artifact.id, jobId, draftQuestionId: question.id, type: artifact.type,
            storageKey: artifact.storageKey, sha256: artifact.sha256, size: artifact.size,
            expiresAt: artifact.expiresAt
          }); } catch (error) { if (isDuplicateKeyError(error)) throw new ImportRepositoryError('IMPORT_ARTIFACT_CONFLICT'); throw error; }
        }
      }
      const result = await manager.update(ImportJobEntity,
        { id: jobId, status: 'processing', claimedAt: expectedClaimedAt },
        { status: 'review' });
      assertAffected(result.affected);
    });
  }

  async markFailure(jobId: string, expectedClaimedAt: Date, code: string, retryable: boolean): Promise<void> {
    await this.dataSource.transaction(async (manager) => {
      const job = await manager.findOne(ImportJobEntity, {
        where: { id: jobId, status: 'processing', claimedAt: expectedClaimedAt }, lock: { mode: 'pessimistic_write' }
      });
      if (job === null) throw new ImportRepositoryError('INVALID_STATE');
      const retryCount = job.retryCount + 1;
      if (retryCount > 2) throw new ImportRepositoryError('INVALID_STATE');
      const failed = await manager.update(ImportJobEntity,
        { id: jobId, status: 'processing', retryCount: job.retryCount, claimedAt: expectedClaimedAt },
        { status: 'failed', retryCount, errorCode: code });
      assertAffected(failed.affected);
      if (retryable && retryCount < 2) {
        const requeued = await manager.update(ImportJobEntity,
          { id: jobId, status: 'failed', retryCount },
          { status: 'queued' });
        assertAffected(requeued.affected);
      }
    });
  }

  async cancelOwned(userId: string, deviceId: string, jobId: string): Promise<boolean> {
    const result = await this.dataSource.getRepository(ImportJobEntity).update(
      { id: jobId, userId, deviceId, status: In(CANCELLABLE_STATUSES) },
      { status: 'cancelled' }
    );
    return result.affected === 1;
  }

  async getReviewDraft(userId: string, jobId: string): Promise<ImportReviewRecord | null> {
    return this.dataSource.transaction(async (manager) => {
      const entity = await manager.findOne(ImportJobEntity, {
        where: { id: jobId, userId },
        lock: { mode: 'pessimistic_read' }
      });
      if (entity === null) return null;
      const questions = await manager.find(ImportDraftQuestionEntity, {
        where: { jobId }, order: { position: 'ASC' }
      });
      const artifacts = await manager.find(ImportArtifactEntity, {
        where: { jobId, type: 'question_image' }, order: { id: 'ASC' }
      });
      return {
        job: toRecord(entity),
        questions: questions.map((question) => ({
          id: question.id,
          position: question.position,
          type: question.type,
          question: question.question,
          options: question.options,
          answer: question.answer,
          analysis: question.analysis,
          pageStart: question.pageStart,
          pageEnd: question.pageEnd,
          confidence: question.confidence,
          reviewRequired: question.reviewRequired,
          artifacts: artifacts.filter((artifact) => artifact.draftQuestionId === question.id).map(
            (artifact) => ({
              id: artifact.id,
              type: 'question_image' as const,
              storageKey: artifact.storageKey,
              sha256: artifact.sha256,
              size: String(artifact.size),
              expiresAt: artifact.expiresAt
            })
          )
        }))
      };
    });
  }

  async confirmImport(
    userId: string,
    deviceId: string,
    jobId: string,
    requestSha256: string,
    input: ConfirmImportInput
  ): Promise<ConfirmImportResult> {
    return this.dataSource.transaction(async (manager) => {
      const job = await manager.findOne(ImportJobEntity, {
        where: { id: jobId, userId, deviceId },
        lock: { mode: 'pessimistic_write' }
      });
      if (job === null) throw new ImportRepositoryError('INVALID_STATE');

      const existing = await manager.findOne(ImportConfirmationEntity, { where: { jobId } });
      if (existing !== null) {
        if (existing.requestSha256 !== requestSha256) {
          throw new ImportRepositoryError('IMPORT_CONFIRMATION_CONFLICT');
        }
        return this.confirmationResult(manager, job, existing);
      }
      const now = this.clock();
      if (job.status !== 'review' || job.expiresAt.getTime() <= now.getTime()) {
        throw new ImportRepositoryError('INVALID_STATE');
      }
      const drafts = await manager.find(ImportDraftQuestionEntity, {
        where: { jobId }, order: { position: 'ASC' }
      });
      if (drafts.length === 0 || drafts.length !== input.questions.length) {
        throw new ImportRepositoryError('INVALID_DRAFT');
      }
      const submitted = new Map(input.questions.map((question) => [question.draftQuestionId, question]));
      if (submitted.size !== input.questions.length || drafts.some((draft) => !submitted.has(draft.id))) {
        throw new ImportRepositoryError('INVALID_DRAFT');
      }
      for (const draft of drafts) {
        const edited = submitted.get(draft.id) as ConfirmImportInput['questions'][number];
        const editedOptions = normalizeOptions(edited.options);
        const draftOptions = normalizeOptions(draft.options);
        const editedAnswer = normalizeNullableText(edited.answer);
        const draftAnswer = normalizeNullableText(draft.answer);
        const editedAnalysis = normalizeNullableText(edited.analysis);
        const draftAnalysis = normalizeNullableText(draft.analysis);
        const changed = edited.type !== draft.type || edited.question !== draft.question ||
          !sameOptions(editedOptions, draftOptions) || editedAnswer !== draftAnswer ||
          editedAnalysis !== draftAnalysis;
        if (draft.reviewRequired && !edited.reviewed && !changed) {
          throw new ImportRepositoryError('INVALID_DRAFT');
        }
      }

      const bankId = randomUUID();
      const questionIds = drafts.map(() => randomUUID());
      const operations: SyncOperationInput[] = [{
        operationId: randomUUID(),
        entityType: 'question_bank',
        entityId: bankId,
        operationType: 'upsert',
        payload: { name: input.bankName, subject: input.subject }
      }];
      for (let index = 0; index < drafts.length; index += 1) {
        const edited = submitted.get(drafts[index].id) as ConfirmImportInput['questions'][number];
        operations.push({
          operationId: randomUUID(),
          entityType: 'question',
          entityId: questionIds[index],
          operationType: 'upsert',
          payload: {
            bankClientId: bankId,
            type: edited.type,
            question: edited.question,
            options: normalizeOptions(edited.options),
            answer: normalizeNullableText(edited.answer),
            analysis: normalizeNullableText(edited.analysis)
          }
        });
      }
      await new TypeOrmSyncStore(this.dataSource).applyInTransaction(manager, userId, operations);
      const confirmation = manager.create(ImportConfirmationEntity, {
        id: randomUUID(), jobId, userId, deviceId, requestSha256, bankId,
        acknowledgedAt: null, expiresAt: job.expiresAt
      });
      await manager.save(confirmation);
      for (let index = 0; index < drafts.length; index += 1) {
        await manager.insert(ImportConfirmedQuestionEntity, {
          id: randomUUID(), jobId, draftQuestionId: drafts[index].id,
          questionId: questionIds[index], position: drafts[index].position
        });
      }
      const updated = await manager.update(ImportJobEntity,
        { id: jobId, userId, deviceId, status: 'review' },
        { status: 'confirmed', claimedAt: null, bankName: input.bankName, subject: input.subject });
      assertAffected(updated.affected);
      job.status = 'confirmed';
      return this.confirmationResult(manager, job, confirmation);
    });
  }

  async findDownloadArtifact(
    userId: string,
    deviceId: string,
    jobId: string,
    artifactId: string,
    now: Date
  ): Promise<ImportDownloadArtifact | null> {
    return this.dataSource.transaction(async (manager) => {
      const job = await manager.findOne(ImportJobEntity, {
        where: { id: jobId, userId, deviceId, status: 'confirmed', expiresAt: MoreThan(now) },
        lock: { mode: 'pessimistic_read' }
      });
      if (job === null) return null;
      const confirmation = await manager.findOne(ImportConfirmationEntity, {
        where: { jobId, userId, deviceId }
      });
      if (confirmation === null || confirmation.acknowledgedAt !== null) return null;
      const artifact = await manager.findOne(ImportArtifactEntity, {
        where: { id: artifactId, jobId, type: 'question_image', expiresAt: MoreThan(now) }
      });
      if (artifact === null || artifact.draftQuestionId === null) return null;
      const mapping = await manager.findOne(ImportConfirmedQuestionEntity, {
        where: { jobId, draftQuestionId: artifact.draftQuestionId }
      });
      if (mapping === null) return null;
      const expectedStorageKey = canonicalArtifactStorageKey(jobId, artifactId);
      const size = Number(artifact.size);
      if (expectedStorageKey === null || artifact.id.toLowerCase() !== artifactId.toLowerCase() ||
        artifact.storageKey !== expectedStorageKey || !SAFE_SHA256_PATTERN.test(artifact.sha256) ||
        !Number.isSafeInteger(size) || size < 1 || size > MAX_DOWNLOAD_ARTIFACT_BYTES) return null;
      return {
        artifactId: artifact.id,
        storageKey: artifact.storageKey,
        sha256: artifact.sha256,
        size,
        expiresAt: artifact.expiresAt
      };
    });
  }

  async prepareArtifactAck(
    userId: string,
    deviceId: string,
    jobId: string,
    artifactIds: string[],
    now: Date
  ): Promise<ImportArtifactAckPlan> {
    return this.dataSource.transaction(async (manager) => {
      const job = await manager.findOne(ImportJobEntity, {
        where: { id: jobId, userId, deviceId, status: 'confirmed', expiresAt: MoreThan(now) },
        lock: { mode: 'pessimistic_write' }
      });
      if (job === null) throw new ImportRepositoryError('INVALID_STATE');
      const confirmation = await manager.findOne(ImportConfirmationEntity, {
        where: { jobId, userId, deviceId }
      });
      if (confirmation === null) throw new ImportRepositoryError('INVALID_STATE');
      const mappings = await manager.find(ImportConfirmedQuestionEntity, { where: { jobId } });
      const draftIds = mappings.map((mapping) => mapping.draftQuestionId);
      const images = draftIds.length === 0 ? [] : await manager.find(ImportArtifactEntity, {
        where: { jobId, type: 'question_image', draftQuestionId: In(draftIds) }, order: { id: 'ASC' }
      });
      const expected = images.map((artifact) => artifact.id).sort();
      // Client-supplied ids are canonicalized to lowercase so an uppercase ACK
      // matches the persisted lowercase artifact rows.
      const received = [...artifactIds].map((id) => id.toLowerCase()).sort();
      if (new Set(received).size !== received.length || expected.length !== received.length ||
        expected.some((id, index) => id !== received[index])) {
        throw new ImportRepositoryError('INVALID_ARTIFACT_SET');
      }
      if (confirmation.acknowledgedAt !== null) {
        return { acknowledged: true, records: [] };
      }
      const parts = await manager.find(ImportUploadPartEntity, { where: { jobId } });
      const artifacts = await manager.find(ImportArtifactEntity, { where: { jobId } });
      return {
        acknowledged: false,
        records: [
          ...parts.map((part) => ({ kind: 'part' as const, id: part.id, storageKey: part.storageKey })),
          ...artifacts.map((artifact) => ({ kind: 'artifact' as const, id: artifact.id, storageKey: artifact.storageKey }))
        ]
      };
    });
  }

  async markArtifactsAcknowledged(
    userId: string,
    deviceId: string,
    jobId: string,
    now: Date
  ): Promise<void> {
    await this.dataSource.transaction(async (manager) => {
      const job = await manager.findOne(ImportJobEntity, {
        where: { id: jobId, userId, deviceId, status: 'confirmed', expiresAt: MoreThan(now) },
        lock: { mode: 'pessimistic_write' }
      });
      if (job === null) throw new ImportRepositoryError('INVALID_STATE');
      const confirmation = await manager.findOne(ImportConfirmationEntity, { where: { jobId, userId, deviceId } });
      if (confirmation === null) throw new ImportRepositoryError('INVALID_STATE');
      if (confirmation.acknowledgedAt === null) {
        const result = await manager.update(ImportConfirmationEntity,
          { id: confirmation.id, acknowledgedAt: IsNull() }, { acknowledgedAt: now });
        assertAffected(result.affected);
      }
    });
  }

  async listCleanupCandidates(now: Date, afterJobId: string | null,
    limit: number): Promise<ImportCleanupCandidate[]> {
    if ((afterJobId !== null && (afterJobId !== afterJobId.toLowerCase() || !UUID_PATTERN.test(afterJobId))) ||
      !Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw new ImportRepositoryError('INVALID_STATE');
    }
    const query = this.dataSource.getRepository(ImportJobEntity).createQueryBuilder('job')
      .leftJoin(ImportConfirmationEntity, 'confirmation', 'confirmation.jobId = job.id')
      .leftJoin(ImportCleanupCheckpointEntity, 'checkpoint', 'checkpoint.jobId = job.id')
      .where(new Brackets((conditions) => {
        conditions.where('(job.status IN (:...terminal) AND checkpoint.retiredAt IS NULL)', {
          terminal: ['cancelled', 'expired']
        }).orWhere('(job.status = :confirmed AND checkpoint.retiredAt IS NULL AND (job.expiresAt <= :now OR confirmation.acknowledgedAt IS NOT NULL))', {
          confirmed: 'confirmed', now
        });
      }));
    if (afterJobId !== null) query.andWhere('job.id > :afterJobId', { afterJobId });
    const jobs = await query.orderBy('job.id', 'ASC').take(limit).getMany();
    return jobs.map((job) => ({ jobId: job.id }));
  }

  async listCleanupRecordsForJob(jobId: string, offset: number, limit: number): Promise<ImportCleanupRecord[]> {
    if (!Number.isInteger(offset) || offset < 0 || !Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw new ImportRepositoryError('INVALID_STATE');
    }
    return this.dataSource.transaction(async (manager) => {
      const job = await manager.findOne(ImportJobEntity, {
        where: { id: jobId, status: In(TERMINAL_CLEANUP_STATUSES) },
        lock: { mode: 'pessimistic_read' }
      });
      if (job === null) throw new ImportRepositoryError('INVALID_STATE');
      // Bounded keyset pagination: only the requested window is fetched, never
      // the whole part/artifact set (a 3200-part job must not be rescanned per
      // page).
      const partCount = await manager.count(ImportUploadPartEntity, { where: { jobId } });
      let categoryOffset = offset;
      const parts = categoryOffset < partCount
        ? await manager.find(ImportUploadPartEntity, {
          where: { jobId }, order: { partNumber: 'ASC' }, skip: categoryOffset, take: limit
        })
        : [];
      const records: ImportCleanupRecord[] = parts.map((part) => ({
        kind: 'part' as const, id: part.id, storageKey: part.storageKey
      }));
      if (records.length >= limit) return records;
      categoryOffset = Math.max(0, categoryOffset - partCount);
      const artifacts = await manager.find(ImportArtifactEntity, {
        where: { jobId }, order: { id: 'ASC' }, skip: categoryOffset, take: limit - records.length
      });
      records.push(...artifacts.map((artifact) => ({
        kind: 'artifact' as const, id: artifact.id, storageKey: artifact.storageKey
      })));
      return records;
    });
  }

  async noteCleanupMissing(jobId: string, now: Date, graceMs: number): Promise<boolean> {
    if (!Number.isSafeInteger(graceMs) || graceMs < 1) throw new ImportRepositoryError('INVALID_STATE');
    return this.dataSource.transaction(async (manager) => {
      const job = await manager.findOne(ImportJobEntity, {
        where: { id: jobId, status: In(TERMINAL_CLEANUP_STATUSES) },
        lock: { mode: 'pessimistic_write' }
      });
      if (job === null || job.expiresAt.getTime() > now.getTime()) return false;
      const activeLease = await manager.findOne(ImportJobLeaseEntity, {
        where: { jobId, expiresAt: MoreThan(now) }
      });
      if (activeLease !== null) return false;
      let checkpoint = await manager.findOne(ImportCleanupCheckpointEntity, { where: { jobId } });
      if (checkpoint === null) {
        await manager.insert(ImportCleanupCheckpointEntity, {
          jobId, missingSince: now, retiredAt: null
        });
        return false;
      }
      if (checkpoint.retiredAt !== null) return true;
      if (checkpoint.missingSince.getTime() + graceMs > now.getTime()) return false;
      await manager.delete(ImportArtifactEntity, { jobId });
      await manager.delete(ImportUploadPartEntity, { jobId });
      await manager.delete(ImportConfirmedQuestionEntity, { jobId });
      await manager.delete(ImportConfirmationEntity, { jobId });
      await manager.delete(ImportDraftQuestionEntity, { jobId });
      await manager.delete(ImportJobLeaseEntity, { jobId });
      const retired = await manager.update(ImportCleanupCheckpointEntity,
        { jobId, retiredAt: IsNull() }, { retiredAt: now });
      assertAffected(retired.affected);
      return true;
    });
  }

  async canDeleteOrphan(jobId: string, now: Date, graceMs: number): Promise<boolean> {
    if (!UUID_PATTERN.test(jobId) || !Number.isSafeInteger(graceMs) || graceMs < 1) return false;
    const job = await this.dataSource.getRepository(ImportJobEntity).findOne({ where: { id: jobId } });
    if (job === null) return true;
    if (!TERMINAL_CLEANUP_STATUSES.includes(job.status) ||
      job.expiresAt.getTime() + graceMs > now.getTime()) return false;
    const lease = await this.dataSource.getRepository(ImportJobLeaseEntity).findOne({
      where: { jobId, expiresAt: MoreThan(now) }
    });
    return lease === null;
  }

  async listCleanupRecords(
    userId: string,
    deviceId: string,
    jobId: string,
    scope: ImportCleanupScope,
    offset: number,
    limit: number
  ): Promise<ImportCleanupRecord[]> {
    if (!Number.isInteger(offset) || offset < 0 || offset > MAX_CLEANUP_OFFSET ||
      !Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw new ImportRepositoryError('INVALID_STATE');
    }
    return this.dataSource.transaction(async (manager) => {
      const job = await manager.findOne(ImportJobEntity, {
        where: { id: jobId, userId, deviceId },
        lock: { mode: 'pessimistic_read' }
      });
      if (job === null || (scope === 'all'
        ? job.status !== 'cancelled'
        : !PART_CLEANUP_STATUSES.includes(job.status))) {
        throw new ImportRepositoryError('INVALID_STATE');
      }

      if (scope === 'parts') {
        const parts = await manager.find(ImportUploadPartEntity, {
          where: { jobId }, order: { partNumber: 'ASC' }, skip: offset, take: limit
        });
        return parts.map((part) => ({
          kind: 'part' as const, id: part.id, storageKey: part.storageKey
        }));
      }

      const partCount = await manager.count(ImportUploadPartEntity, { where: { jobId } });
      let categoryOffset = offset;
      const parts = categoryOffset < partCount
        ? await manager.find(ImportUploadPartEntity, {
          where: { jobId }, order: { partNumber: 'ASC' }, skip: categoryOffset, take: limit
        })
        : [];
      const records: ImportCleanupRecord[] = parts.map((part) => ({
        kind: 'part',
        id: part.id,
        storageKey: part.storageKey
      }));
      if (records.length >= limit) {
        return records;
      }
      categoryOffset = Math.max(0, categoryOffset - partCount);

      const sourceCount = await manager.count(ImportArtifactEntity, {
        where: { jobId, type: 'source_pdf' }
      });
      const sources = categoryOffset < sourceCount
        ? await manager.find(ImportArtifactEntity, {
          where: { jobId, type: 'source_pdf' }, order: { id: 'ASC' },
          skip: categoryOffset, take: limit - records.length
        })
        : [];
      records.push(...sources.map((artifact) => ({
        kind: 'artifact' as const,
        id: artifact.id,
        storageKey: artifact.storageKey
      })));
      categoryOffset = Math.max(0, categoryOffset - sourceCount);
      if (records.length < limit) {
        const images = await manager.find(ImportArtifactEntity, {
          where: { jobId, type: 'question_image' },
          order: { id: 'ASC' },
          skip: categoryOffset,
          take: limit - records.length
        });
        records.push(...images.map((artifact) => ({
          kind: 'artifact' as const,
          id: artifact.id,
          storageKey: artifact.storageKey
        })));
      }
      return records;
    });
  }

  async expireBefore(now: Date): Promise<string[]> {
    const expired: string[] = [];
    while (true) {
      const batch = await this.dataSource.transaction(async (manager) => {
        const jobs = await manager.getRepository(ImportJobEntity).createQueryBuilder('job')
          .setLock('pessimistic_write').setOnLocked('skip_locked')
          .where('job.expiresAt < :now', { now })
          .andWhere('job.status IN (:...statuses)', { statuses: EXPIRABLE_STATUSES })
          .orderBy('job.expiresAt', 'ASC').addOrderBy('job.id', 'ASC').take(EXPIRY_BATCH_SIZE).getMany();
        const transitioned: string[] = [];
        for (const job of jobs) {
          const result = await manager.update(ImportJobEntity, { id: job.id, status: job.status }, { status: 'expired' });
          if (result.affected === 1) transitioned.push(job.id);
        }
        return transitioned;
      });
      if (batch.length === 0) return expired;
      expired.push(...batch);
    }
  }

  private async lockUploadingJob(manager: EntityManager, input: ImportPartRecord): Promise<void> {
    const job = await manager.findOne(ImportJobEntity, { where: { id: input.jobId, userId: input.userId, deviceId: input.deviceId, status: 'uploading' }, lock: { mode: 'pessimistic_write' } });
    if (job === null) throw new ImportRepositoryError('INVALID_STATE');
  }

  private async confirmationResult(
    manager: EntityManager,
    job: ImportJobEntity,
    confirmation: ImportConfirmationEntity
  ): Promise<ConfirmImportResult> {
    const mappings = await manager.find(ImportConfirmedQuestionEntity, {
      where: { jobId: job.id }, order: { position: 'ASC' }
    });
    const images = await manager.find(ImportArtifactEntity, {
      where: { jobId: job.id, type: 'question_image' }, order: { id: 'ASC' }
    });
    return {
      bankId: confirmation.bankId,
      questions: mappings.map((mapping) => ({
        draftQuestionId: mapping.draftQuestionId,
        questionId: mapping.questionId,
        images: images.filter((artifact) => artifact.draftQuestionId === mapping.draftQuestionId)
          .map((artifact) => ({
            artifactId: artifact.id,
            sha256: artifact.sha256,
            size: Number(artifact.size)
          }))
      })),
      expiresAt: confirmation.expiresAt.toISOString()
    };
  }

  private assertSamePart(existing: ImportUploadPartEntity, input: ImportPartRecord): void {
    if (!samePart(existing, input)) throw new ImportRepositoryError('IMPORT_PART_CONFLICT');
  }

  private assertValidLeaseInput(jobId: string, token: string, now: Date, expiresAt: Date): void {
    if (!UUID_PATTERN.test(jobId) || !UUID_PATTERN.test(token) ||
      !Number.isFinite(now.getTime()) || !Number.isFinite(expiresAt.getTime()) ||
      expiresAt.getTime() <= now.getTime()) {
      throw new ImportRepositoryError('INVALID_STATE');
    }
  }
}
