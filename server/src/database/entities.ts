import { randomUUID } from 'node:crypto';
import {
  Check,
  Column,
  CreateDateColumn,
  Entity,
  Generated,
  Index,
  PrimaryColumn,
  Unique,
  UpdateDateColumn,
  ValueTransformer
} from 'typeorm';

export abstract class BaseEntity {
  @PrimaryColumn({ type: 'char', length: 36 })
  id: string = randomUUID();

  @CreateDateColumn({ type: 'datetime', precision: 3 })
  createdAt!: Date;

  @UpdateDateColumn({ type: 'datetime', precision: 3 })
  updatedAt!: Date;
}

@Entity('users')
export class UserEntity extends BaseEntity {
  @Column({ type: 'varchar', length: 24, default: 'active' })
  status!: string;
}

@Entity('huawei_identities')
@Unique('uq_huawei_identity_union_hash', ['unionIdHash'])
export class HuaweiIdentityEntity extends BaseEntity {
  @Index('idx_huawei_identity_user')
  @Column({ type: 'char', length: 36 })
  userId!: string;

  @Column({ type: 'char', length: 64 })
  unionIdHash!: string;

  @Column({ type: 'text' })
  encryptedUnionId!: string;

  @Column({ type: 'text', nullable: true })
  encryptedOpenId!: string | null;
}

@Entity('devices')
@Unique('uq_device_user_key', ['userId', 'deviceKey'])
@Unique('uq_device_user_id', ['userId', 'id'])
export class DeviceEntity extends BaseEntity {
  @Index('idx_device_user')
  @Column({ type: 'char', length: 36 })
  userId!: string;

  @Column({ type: 'varchar', length: 128 })
  deviceKey!: string;

  @Column({ type: 'varchar', length: 128 })
  name!: string;

  @Column({ type: 'char', length: 36 })
  sessionGeneration!: string;

  @Column({ type: 'datetime', precision: 3 })
  lastSeenAt!: Date;

  @Column({ type: 'datetime', precision: 3, nullable: true })
  revokedAt!: Date | null;
}

@Entity('sessions')
@Unique('uq_session_refresh_hash', ['refreshTokenHash'])
export class SessionEntity extends BaseEntity {
  @Index('idx_session_user')
  @Column({ type: 'char', length: 36 })
  userId!: string;

  @Index('idx_session_device')
  @Column({ type: 'char', length: 36 })
  deviceId!: string;

  @Column({ type: 'char', length: 64 })
  refreshTokenHash!: string;

  @Column({ type: 'datetime', precision: 3 })
  expiresAt!: Date;

  @Column({ type: 'datetime', precision: 3, nullable: true })
  revokedAt!: Date | null;
}

@Entity('question_banks')
@Unique('uq_bank_user_client', ['userId', 'clientId'])
export class QuestionBankEntity extends BaseEntity {
  @Index('idx_bank_user')
  @Column({ type: 'char', length: 36 })
  userId!: string;

  @Column({ type: 'char', length: 36 })
  clientId!: string;

  @Column({ type: 'varchar', length: 255 })
  name!: string;

  @Column({ type: 'varchar', length: 64 })
  subject!: string;

  @Column({ type: 'int', unsigned: true, default: 1 })
  version!: number;

  @Column({ type: 'datetime', precision: 3, nullable: true })
  deletedAt!: Date | null;
}

@Entity('questions')
@Unique('uq_question_user_client', ['userId', 'clientId'])
export class QuestionEntity extends BaseEntity {
  @Index('idx_question_user')
  @Column({ type: 'char', length: 36 })
  userId!: string;

  @Index('idx_question_bank')
  @Column({ type: 'char', length: 36 })
  bankId!: string;

  @Column({ type: 'char', length: 36 })
  clientId!: string;

  @Column({ type: 'varchar', length: 32, default: 'single_choice' })
  type!: string;

  @Column({ type: 'longtext' })
  question!: string;

  @Column({ type: 'json', nullable: true })
  options!: Record<string, string> | null;

  @Column({ type: 'longtext', nullable: true })
  answer!: string | null;

  @Column({ type: 'longtext', nullable: true })
  analysis!: string | null;

  @Column({ type: 'int', unsigned: true, default: 1 })
  version!: number;

  @Column({ type: 'datetime', precision: 3, nullable: true })
  deletedAt!: Date | null;
}

@Entity('wrong_questions')
@Unique('uq_wrong_question_user_client', ['userId', 'questionClientId'])
export class WrongQuestionEntity extends BaseEntity {
  @Index('idx_wrong_question_user')
  @Column({ type: 'char', length: 36 })
  userId!: string;

  @Column({ type: 'char', length: 36 })
  questionClientId!: string;

  @Column({ type: 'varchar', length: 24, default: 'pending' })
  status!: string;

  @Column({ type: 'int', unsigned: true, default: 1 })
  version!: number;

  @Column({ type: 'datetime', precision: 3, nullable: true })
  deletedAt!: Date | null;
}

@Entity('review_records')
@Unique('uq_review_user_event', ['userId', 'clientEventId'])
export class ReviewRecordEntity extends BaseEntity {
  @Index('idx_review_user')
  @Column({ type: 'char', length: 36 })
  userId!: string;

  @Column({ type: 'char', length: 36 })
  questionClientId!: string;

  @Column({ type: 'char', length: 36 })
  clientEventId!: string;

  @Column({ type: 'varchar', length: 24 })
  result!: string;

  @Column({ type: 'datetime', precision: 3 })
  reviewedAt!: Date;
}

@Entity('sync_operations')
@Unique('uq_sync_operation_user_id', ['userId', 'operationId'])
@Index('idx_sync_operation_user_sequence', ['userId', 'serverSequence'])
export class SyncOperationEntity extends BaseEntity {
  @Column({ type: 'char', length: 36 })
  userId!: string;

  @Column({ type: 'char', length: 36 })
  operationId!: string;

  @Column({ type: 'varchar', length: 32 })
  entityType!: string;

  @Column({ type: 'char', length: 36 })
  entityId!: string;

  @Column({ type: 'varchar', length: 16 })
  operationType!: string;

  @Column({ type: 'bigint', unsigned: true })
  @Generated('increment')
  @Index('uq_sync_operation_sequence', { unique: true })
  serverSequence!: string;

  @Column({ type: 'json' })
  payload!: Record<string, unknown>;
}

export const IMPORT_JOB_STATUSES = Object.freeze([
  'uploading',
  'queued',
  'processing',
  'review',
  'confirmed',
  'failed',
  'cancelled',
  'expired'
] as const);

export type ImportJobStatus = (typeof IMPORT_JOB_STATUSES)[number];

export const IMPORT_ARTIFACT_TYPES = Object.freeze(['source_pdf', 'question_image'] as const);

export type ImportArtifactType = (typeof IMPORT_ARTIFACT_TYPES)[number];

export const importConfidenceTransformer: ValueTransformer = {
  to(value: unknown): number {
    return normalizeImportConfidence(value, 'application');
  },
  from(value: unknown): number {
    return normalizeImportConfidence(value, 'database');
  }
};

function normalizeImportConfidence(value: unknown, source: string): number {
  const parsed = typeof value === 'number'
    ? value
    : typeof value === 'string' && value.trim() !== ''
      ? Number(value)
      : Number.NaN;

  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 1) {
    throw new TypeError(`Invalid ${source} confidence value.`);
  }

  return parsed;
}

@Entity('import_jobs')
@Check('chk_import_job_status', "`status` IN ('uploading', 'queued', 'processing', 'review', 'confirmed', 'failed', 'cancelled', 'expired')")
@Check('chk_import_job_page_range', '`pageStart` >= 1 AND `pageEnd` >= `pageStart` AND `pageEnd` <= `pageStart` + 19')
@Check('chk_import_job_source_size', '`sourceSize` BETWEEN 1 AND 209715200')
@Check('chk_import_job_progress', '`progressCurrent` <= `progressTotal`')
@Check('chk_import_job_retry_count', '`retryCount` BETWEEN 0 AND 2')
@Check('chk_import_job_part_count', '`partCount` >= 0')
@Index('idx_import_job_status_created', ['status', 'createdAt'])
@Index('idx_import_job_user_device', ['userId', 'deviceId'])
export class ImportJobEntity extends BaseEntity {
  @Column({ type: 'char', length: 36 })
  userId!: string;

  @Index('idx_import_job_device')
  @Column({ type: 'char', length: 36 })
  deviceId!: string;

  @Column({ type: 'varchar', length: 255 })
  bankName!: string;

  @Column({ type: 'varchar', length: 64 })
  subject!: string;

  @Column({ type: 'int', unsigned: true })
  pageStart!: number;

  @Column({ type: 'int', unsigned: true })
  pageEnd!: number;

  @Column({ type: 'varchar', length: 24, default: 'uploading' })
  status!: ImportJobStatus;

  @Column({ type: 'int', unsigned: true, default: 0 })
  progressCurrent!: number;

  @Column({ type: 'int', unsigned: true, default: 0 })
  progressTotal!: number;

  @Column({ type: 'char', length: 64 })
  sourceSha256!: string;

  @Column({ type: 'bigint', unsigned: true })
  sourceSize!: string;

  @Column({ type: 'int', unsigned: true })
  partCount!: number;

  @Column({ type: 'int', unsigned: true, default: 0 })
  retryCount!: number;

  @Column({ type: 'varchar', length: 64, nullable: true })
  errorCode!: string | null;

  @Column({ type: 'datetime', precision: 3, nullable: true })
  claimedAt!: Date | null;

  @Index('idx_import_job_expiry')
  @Column({ type: 'datetime', precision: 3 })
  expiresAt!: Date;
}

@Entity('import_job_leases')
export class ImportJobLeaseEntity {
  @PrimaryColumn({ type: 'char', length: 36 })
  jobId!: string;

  @Column({ type: 'char', length: 36 })
  token!: string;

  @Index('idx_import_job_lease_expiry')
  @Column({ type: 'datetime', precision: 3 })
  expiresAt!: Date;

  @CreateDateColumn({ type: 'datetime', precision: 3 })
  createdAt!: Date;

  @UpdateDateColumn({ type: 'datetime', precision: 3 })
  updatedAt!: Date;
}

@Entity('import_upload_parts')
@Check('chk_import_part_number', '`partNumber` >= 0')
@Unique('uq_import_part_job_number', ['jobId', 'partNumber'])
export class ImportUploadPartEntity extends BaseEntity {
  @Column({ type: 'char', length: 36 })
  jobId!: string;

  @Column({ type: 'int', unsigned: true })
  partNumber!: number;

  @Column({ type: 'bigint', unsigned: true })
  size!: string;

  @Column({ type: 'char', length: 64 })
  sha256!: string;

  @Column({ type: 'varchar', length: 512 })
  storageKey!: string;
}

@Entity('import_draft_questions')
@Check('chk_import_draft_position', '`position` >= 0')
@Check('chk_import_draft_page_range', '`pageStart` >= 1 AND `pageEnd` >= `pageStart` AND `pageEnd` <= `pageStart` + 19')
@Check('chk_import_draft_confidence', '`confidence` BETWEEN 0 AND 1')
@Check('chk_import_draft_review_required', '`reviewRequired` IN (0, 1)')
@Unique('uq_import_draft_job_position', ['jobId', 'position'])
@Unique('uq_import_draft_job_id', ['jobId', 'id'])
export class ImportDraftQuestionEntity extends BaseEntity {
  @Column({ type: 'char', length: 36 })
  jobId!: string;

  @Column({ type: 'int', unsigned: true })
  position!: number;

  @Column({ type: 'varchar', length: 32 })
  type!: string;

  @Column({ type: 'longtext' })
  question!: string;

  @Column({ type: 'json', nullable: true })
  options!: Record<string, string> | null;

  @Column({ type: 'longtext', nullable: true })
  answer!: string | null;

  @Column({ type: 'longtext', nullable: true })
  analysis!: string | null;

  @Column({ type: 'int', unsigned: true })
  pageStart!: number;

  @Column({ type: 'int', unsigned: true })
  pageEnd!: number;

  @Column({
    type: 'decimal',
    precision: 5,
    scale: 4,
    default: 0,
    transformer: importConfidenceTransformer
  })
  confidence!: number;

  @Column({ type: 'boolean', default: true })
  reviewRequired!: boolean;
}

@Entity('import_artifacts')
@Check('chk_import_artifact_type', "`type` IN ('source_pdf', 'question_image')")
@Index('idx_import_artifact_job_draft', ['jobId', 'draftQuestionId'])
export class ImportArtifactEntity extends BaseEntity {
  @Column({ type: 'char', length: 36 })
  jobId!: string;

  @Index('idx_import_artifact_draft')
  @Column({ type: 'char', length: 36, nullable: true })
  draftQuestionId!: string | null;

  @Column({ type: 'varchar', length: 32 })
  type!: ImportArtifactType;

  @Column({ type: 'varchar', length: 512 })
  storageKey!: string;

  @Column({ type: 'char', length: 64 })
  sha256!: string;

  @Column({ type: 'bigint', unsigned: true })
  size!: string;

  @Index('idx_import_artifact_expiry')
  @Column({ type: 'datetime', precision: 3 })
  expiresAt!: Date;
}

@Entity('import_confirmations')
@Unique('uq_import_confirmation_job', ['jobId'])
@Index('idx_import_confirmation_expiry', ['expiresAt'])
export class ImportConfirmationEntity extends BaseEntity {
  @Column({ type: 'char', length: 36 })
  jobId!: string;

  @Column({ type: 'char', length: 36 })
  userId!: string;

  @Column({ type: 'char', length: 36 })
  deviceId!: string;

  @Column({ type: 'char', length: 64 })
  requestSha256!: string;

  @Column({ type: 'char', length: 36 })
  bankId!: string;

  @Column({ type: 'datetime', precision: 3, nullable: true })
  acknowledgedAt!: Date | null;

  @Column({ type: 'datetime', precision: 3 })
  expiresAt!: Date;
}

@Entity('import_confirmed_questions')
@Unique('uq_import_confirmed_draft', ['jobId', 'draftQuestionId'])
@Unique('uq_import_confirmed_position', ['jobId', 'position'])
export class ImportConfirmedQuestionEntity extends BaseEntity {
  @Column({ type: 'char', length: 36 })
  jobId!: string;

  @Column({ type: 'char', length: 36 })
  draftQuestionId!: string;

  @Column({ type: 'char', length: 36 })
  questionId!: string;

  @Column({ type: 'int', unsigned: true })
  position!: number;
}

@Entity('import_cleanup_checkpoints')
export class ImportCleanupCheckpointEntity {
  @PrimaryColumn({ type: 'char', length: 36 })
  jobId!: string;

  @Column({ type: 'datetime', precision: 3 })
  missingSince!: Date;

  @Column({ type: 'datetime', precision: 3, nullable: true })
  retiredAt!: Date | null;

  @CreateDateColumn({ type: 'datetime', precision: 3 })
  createdAt!: Date;

  @UpdateDateColumn({ type: 'datetime', precision: 3 })
  updatedAt!: Date;
}

export const ALL_ENTITIES = [
  UserEntity,
  HuaweiIdentityEntity,
  DeviceEntity,
  SessionEntity,
  QuestionBankEntity,
  QuestionEntity,
  WrongQuestionEntity,
  ReviewRecordEntity,
  SyncOperationEntity,
  ImportJobEntity,
  ImportUploadPartEntity,
  ImportDraftQuestionEntity,
  ImportArtifactEntity,
  ImportJobLeaseEntity,
  ImportConfirmationEntity,
  ImportConfirmedQuestionEntity,
  ImportCleanupCheckpointEntity
];
