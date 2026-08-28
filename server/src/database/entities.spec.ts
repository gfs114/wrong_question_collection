import { getMetadataArgsStorage } from 'typeorm';
import {
  ALL_ENTITIES,
  BaseEntity,
  DeviceEntity,
  IMPORT_ARTIFACT_TYPES,
  IMPORT_JOB_STATUSES,
  ImportArtifactEntity,
  ImportCleanupCheckpointEntity,
  ImportConfirmationEntity,
  ImportConfirmedQuestionEntity,
  ImportDraftQuestionEntity,
  ImportJobEntity,
  ImportJobLeaseEntity,
  ImportUploadPartEntity,
  importConfidenceTransformer,
  SyncOperationEntity
} from './entities';

describe('database entities', () => {
  it('defines every table required by authentication and synchronization', () => {
    expect(ALL_ENTITIES.map((entity: Function) => getMetadataArgsStorage().tables.find(
      (table) => table.target === entity
    )?.name)).toEqual([
      'users',
      'huawei_identities',
      'devices',
      'sessions',
      'question_banks',
      'questions',
      'wrong_questions',
      'review_records',
      'sync_operations',
      'import_jobs',
      'import_upload_parts',
      'import_draft_questions',
      'import_artifacts',
      'import_job_leases',
      'import_confirmations',
      'import_confirmed_questions',
      'import_cleanup_checkpoints'
    ]);
  });

  it('keeps every synchronized table scoped to a user', () => {
    const indirectlyOwnedTables: Function[] = [
      ImportUploadPartEntity,
      ImportDraftQuestionEntity,
      ImportArtifactEntity,
      ImportJobLeaseEntity,
      ImportConfirmedQuestionEntity,
      ImportCleanupCheckpointEntity
    ];
    const userOwnedTables = ALL_ENTITIES.slice(1).filter(
      (entity: Function) => !indirectlyOwnedTables.includes(entity)
    );

    for (const entity of userOwnedTables) {
      const columns = getMetadataArgsStorage().columns
        .filter((column) => column.target === entity)
        .map((column) => column.propertyName);
      expect(columns).toContain('userId');
    }
  });

  it('defines a job-keyed expiring import assembly lease without user payload fields', () => {
    expectCloudImportColumns(ImportJobLeaseEntity, {
      jobId: { options: { type: 'char', length: 36, primary: true } },
      token: { options: { type: 'char', length: 36 } },
      expiresAt: { options: { type: 'datetime', precision: 3 } },
      createdAt: { options: { type: 'datetime', precision: 3 } },
      updatedAt: { options: { type: 'datetime', precision: 3 } }
    });
    expect(findIndex(ImportJobLeaseEntity, 'idx_import_job_lease_expiry')?.columns).toEqual(['expiresAt']);
  });

  it('makes Huawei identity and client operation identifiers unique per boundary', () => {
    const uniqueDefinitions: string[][] = getMetadataArgsStorage().uniques.map((unique) =>
      Array.isArray(unique.columns) ? unique.columns.map((column) => String(column)) : []
    );

    expect(uniqueDefinitions.some((columns) => columns.includes('unionIdHash'))).toBe(true);
    expect(
      uniqueDefinitions.some(
        (columns) => columns.includes('userId') && columns.includes('operationId')
      )
    ).toBe(true);
  });

  it('assigns a database generated sequence to every accepted sync operation', () => {
    const generation = getMetadataArgsStorage().generations.find(
      (candidate) => candidate.propertyName === 'serverSequence'
    );

    expect(generation?.strategy).toBe('increment');
  });

  it('keeps UUID primary columns aligned with the char(36) migration schema', () => {
    const idColumn = getMetadataArgsStorage().columns.find(
      (column) => column.target === BaseEntity && column.propertyName === 'id'
    );
    expect(idColumn?.options).toMatchObject({ primary: true, type: 'char', length: 36 });
  });

  it('defines the sync cursor index as user and server sequence together', () => {
    const index = getMetadataArgsStorage().indices.find(
      (candidate) =>
        candidate.target === SyncOperationEntity &&
        candidate.name === 'idx_sync_operation_user_sequence'
    );

    expect(index?.columns).toEqual(['userId', 'serverSequence']);
  });

  it('stores a server-generated login generation on each device', () => {
    const column = getMetadataArgsStorage().columns.find(
      (candidate) =>
        candidate.target === DeviceEntity && candidate.propertyName === 'sessionGeneration'
    );

    expect(column?.options).toMatchObject({ type: 'char', length: 36 });
  });

  it('registers every cloud import table for TypeORM metadata', () => {
    expect(ALL_ENTITIES).toEqual(expect.arrayContaining([
      ImportJobEntity,
      ImportUploadPartEntity,
      ImportDraftQuestionEntity,
      ImportArtifactEntity,
      ImportJobLeaseEntity,
      ImportConfirmationEntity,
      ImportConfirmedQuestionEntity,
      ImportCleanupCheckpointEntity
    ]));
  });

  it('exposes immutable cloud import domain values for every direct writer', () => {
    expect(IMPORT_JOB_STATUSES).toEqual([
      'uploading',
      'queued',
      'processing',
      'review',
      'confirmed',
      'failed',
      'cancelled',
      'expired'
    ]);
    expect(IMPORT_ARTIFACT_TYPES).toEqual(['source_pdf', 'question_image']);
    expect(Object.isFrozen(IMPORT_JOB_STATUSES)).toBe(true);
    expect(Object.isFrozen(IMPORT_ARTIFACT_TYPES)).toBe(true);
  });

  it('converts decimal confidence values to finite domain-safe numbers', () => {
    expect(importConfidenceTransformer.from('0')).toBe(0);
    expect(importConfidenceTransformer.from('0.8750')).toBe(0.875);
    expect(importConfidenceTransformer.from('1')).toBe(1);
    expect(importConfidenceTransformer.to(0)).toBe(0);
    expect(importConfidenceTransformer.to(0.875)).toBe(0.875);
    expect(importConfidenceTransformer.to(1)).toBe(1);
    expect(() => importConfidenceTransformer.from('not-a-number')).toThrow();
    expect(() => importConfidenceTransformer.to(Number.NaN)).toThrow();
    expect(() => importConfidenceTransformer.to(1.001)).toThrow();
  });

  it('inherits the UUID and timestamp contract in every cloud import entity', () => {
    const baseColumns = getMetadataArgsStorage().columns.filter(
      (column) => column.target === BaseEntity
    );
    const expectedBaseColumns = {
      id: { type: 'char', length: 36, primary: true },
      createdAt: { type: 'datetime', precision: 3 },
      updatedAt: { type: 'datetime', precision: 3 }
    };

    for (const [propertyName, options] of Object.entries(expectedBaseColumns)) {
      const column = baseColumns.find((candidate) => candidate.propertyName === propertyName);
      expect(column?.options).toMatchObject(options);
    }

    for (const entity of [
      ImportJobEntity,
      ImportUploadPartEntity,
      ImportDraftQuestionEntity,
      ImportArtifactEntity
    ]) {
      expect(Object.getPrototypeOf(entity.prototype)).toBe(BaseEntity.prototype);
    }
  });

  it('defines every import job field and its index metadata', () => {
    expectCloudImportColumns(ImportJobEntity, {
      userId: { options: { type: 'char', length: 36 } },
      deviceId: { options: { type: 'char', length: 36 } },
      bankName: { options: { type: 'varchar', length: 255 } },
      subject: { options: { type: 'varchar', length: 64 } },
      pageStart: { options: { type: 'int', unsigned: true } },
      pageEnd: { options: { type: 'int', unsigned: true } },
      status: { options: { type: 'varchar', length: 24, default: 'uploading' } },
      progressCurrent: { options: { type: 'int', unsigned: true, default: 0 } },
      progressTotal: { options: { type: 'int', unsigned: true, default: 0 } },
      sourceSha256: { options: { type: 'char', length: 64 } },
      sourceSize: { options: { type: 'bigint', unsigned: true } },
      partCount: { options: { type: 'int', unsigned: true } },
      retryCount: { options: { type: 'int', unsigned: true, default: 0 } },
      errorCode: { nullable: true, options: { type: 'varchar', length: 64 } },
      claimedAt: { nullable: true, options: { type: 'datetime', precision: 3 } },
      expiresAt: { options: { type: 'datetime', precision: 3 } }
    });

    const indices = getMetadataArgsStorage().indices.filter(
      (index) => index.target === ImportJobEntity
    );

    expect(indices).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: 'idx_import_job_device', columns: ['deviceId'] }),
      expect.objectContaining({
        name: 'idx_import_job_status_created',
        columns: ['status', 'createdAt']
      }),
      expect.objectContaining({ name: 'idx_import_job_expiry', columns: ['expiresAt'] })
    ]));
    expect(findIndex(ImportJobEntity, 'idx_import_job_user_device')?.columns).toEqual([
      'userId',
      'deviceId'
    ]);
    expect(findIndex(ImportJobEntity, 'idx_import_job_user')).toBeUndefined();
    expect(findUnique(DeviceEntity, 'uq_device_user_id')?.columns).toEqual(['userId', 'id']);
    expectChecks(ImportJobEntity, {
      chk_import_job_status: "`status` IN ('uploading', 'queued', 'processing', 'review', 'confirmed', 'failed', 'cancelled', 'expired')",
      chk_import_job_page_range: '`pageStart` >= 1 AND `pageEnd` >= `pageStart` AND `pageEnd` <= `pageStart` + 19',
      chk_import_job_source_size: '`sourceSize` BETWEEN 1 AND 209715200',
      chk_import_job_progress: '`progressCurrent` <= `progressTotal`',
      chk_import_job_retry_count: '`retryCount` BETWEEN 0 AND 2',
      chk_import_job_part_count: '`partCount` >= 0'
    });
  });

  it('defines every upload part field and scopes part numbers to a job', () => {
    expectCloudImportColumns(ImportUploadPartEntity, {
      jobId: { options: { type: 'char', length: 36 } },
      partNumber: { options: { type: 'int', unsigned: true } },
      size: { options: { type: 'bigint', unsigned: true } },
      sha256: { options: { type: 'char', length: 64 } },
      storageKey: { options: { type: 'varchar', length: 512 } }
    });

    const unique = getMetadataArgsStorage().uniques.find(
      (candidate) =>
        candidate.target === ImportUploadPartEntity && candidate.name === 'uq_import_part_job_number'
    );

    expect(unique?.columns).toEqual(['jobId', 'partNumber']);
    expect(findIndex(ImportUploadPartEntity, 'idx_import_part_job')).toBeUndefined();
    expectChecks(ImportUploadPartEntity, { chk_import_part_number: '`partNumber` >= 0' });
  });

  it('defines ordered draft question fields and their job-position index', () => {
    expectCloudImportColumns(ImportDraftQuestionEntity, {
      jobId: { options: { type: 'char', length: 36 } },
      position: { options: { type: 'int', unsigned: true } },
      type: { options: { type: 'varchar', length: 32 } },
      question: { options: { type: 'longtext' } },
      options: { nullable: true, options: { type: 'json' } },
      answer: { nullable: true, options: { type: 'longtext' } },
      analysis: { nullable: true, options: { type: 'longtext' } },
      pageStart: { options: { type: 'int', unsigned: true } },
      pageEnd: { options: { type: 'int', unsigned: true } },
      confidence: {
        options: {
          type: 'decimal',
          precision: 5,
          scale: 4,
          default: 0,
          transformer: importConfidenceTransformer
        }
      },
      reviewRequired: { options: { type: 'boolean', default: true } }
    });

    expect(findIndex(ImportDraftQuestionEntity, 'idx_import_draft_job_position')).toBeUndefined();
    expect(findUnique(ImportDraftQuestionEntity, 'uq_import_draft_job_position')?.columns).toEqual([
      'jobId',
      'position'
    ]);
    expect(findUnique(ImportDraftQuestionEntity, 'uq_import_draft_job_id')?.columns).toEqual([
      'jobId',
      'id'
    ]);
    expectChecks(ImportDraftQuestionEntity, {
      chk_import_draft_position: '`position` >= 0',
      chk_import_draft_page_range: '`pageStart` >= 1 AND `pageEnd` >= `pageStart` AND `pageEnd` <= `pageStart` + 19',
      chk_import_draft_confidence: '`confidence` BETWEEN 0 AND 1',
      chk_import_draft_review_required: '`reviewRequired` IN (0, 1)'
    });
  });

  it('defines every artifact field and its job, draft, and expiry indexes', () => {
    expectCloudImportColumns(ImportArtifactEntity, {
      jobId: { options: { type: 'char', length: 36 } },
      draftQuestionId: { nullable: true, options: { type: 'char', length: 36 } },
      type: { options: { type: 'varchar', length: 32 } },
      storageKey: { options: { type: 'varchar', length: 512 } },
      sha256: { options: { type: 'char', length: 64 } },
      size: { options: { type: 'bigint', unsigned: true } },
      expiresAt: { options: { type: 'datetime', precision: 3 } }
    });

    expect(findIndex(ImportArtifactEntity, 'idx_import_artifact_job')).toBeUndefined();
    expect(findIndex(ImportArtifactEntity, 'idx_import_artifact_draft')?.columns).toEqual([
      'draftQuestionId'
    ]);
    expect(findIndex(ImportArtifactEntity, 'idx_import_artifact_expiry')?.columns).toEqual([
      'expiresAt'
    ]);
    expect(findIndex(ImportArtifactEntity, 'idx_import_artifact_job_draft')?.columns).toEqual([
      'jobId',
      'draftQuestionId'
    ]);
    expectChecks(ImportArtifactEntity, {
      chk_import_artifact_type: "`type` IN ('source_pdf', 'question_image')"
    });
  });
});

function expectCloudImportColumns(
  entity: Function,
  expected: Record<string, { nullable?: boolean; options: Record<string, unknown> }>
): void {
  const columns = getMetadataArgsStorage().columns.filter((column) => column.target === entity);

  expect(columns.map((column) => column.propertyName)).toEqual(Object.keys(expected));
  for (const [propertyName, contract] of Object.entries(expected)) {
    const column = columns.find((candidate) => candidate.propertyName === propertyName);
    expect(column?.options).toMatchObject(contract.options);
    expect(column?.options.nullable ?? false).toBe(contract.nullable ?? false);
  }
}

function findIndex(entity: Function, name: string) {
  return getMetadataArgsStorage().indices.find(
    (candidate) => candidate.target === entity && candidate.name === name
  );
}

function findUnique(entity: Function, name: string) {
  return getMetadataArgsStorage().uniques.find(
    (candidate) => candidate.target === entity && candidate.name === name
  );
}

function expectChecks(entity: Function, expected: Record<string, string>): void {
  const checks = getMetadataArgsStorage().checks.filter((check) => check.target === entity);

  for (const [name, expression] of Object.entries(expected)) {
    const check = checks.find((candidate) => candidate.name === name);
    expect(check?.expression).toBe(expression);
  }
}
