export const MAX_PDF_BYTES = 209_715_200;
export const MIN_UPLOAD_PART_BYTES = 65_536;
export const MAX_UPLOAD_PART_BYTES = 4_194_304;
export const MAX_UPLOAD_PART_COUNT = Math.ceil(MAX_PDF_BYTES / MIN_UPLOAD_PART_BYTES);

export const IMPORT_JOB_STATUSES = [
  'uploading',
  'queued',
  'processing',
  'review',
  'confirmed',
  'failed',
  'cancelled',
  'expired'
] as const;

export type ImportJobStatus = (typeof IMPORT_JOB_STATUSES)[number];

export const IMPORT_TRANSITIONS: Readonly<Record<ImportJobStatus, readonly ImportJobStatus[]>> = {
  uploading: ['queued', 'cancelled', 'expired'],
  queued: ['processing', 'cancelled', 'expired'],
  processing: ['review', 'failed', 'cancelled', 'expired'],
  review: ['confirmed', 'cancelled', 'expired'],
  confirmed: [],
  failed: ['queued', 'cancelled', 'expired'],
  cancelled: [],
  expired: []
};

export function canTransition(from: ImportJobStatus, to: ImportJobStatus): boolean {
  return IMPORT_TRANSITIONS[from].includes(to);
}

export interface CreateImportJobRecord {
  id: string;
  userId: string;
  deviceId: string;
  bankName: string;
  subject: string;
  pageStart: number;
  pageEnd: number;
  sourceSha256: string;
  sourceSize: string;
  partCount: number;
}

export interface ImportJobRecord extends CreateImportJobRecord {
  status: ImportJobStatus;
  progressCurrent: number;
  progressTotal: number;
  retryCount: number;
  errorCode: string | null;
  claimedAt: Date | null;
  expiresAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

export interface ImportPartRecord {
  id: string;
  userId: string;
  deviceId: string;
  jobId: string;
  partNumber: number;
  size: string;
  sha256: string;
  storageKey: string;
}

export interface ImportCleanupRecord {
  kind: 'part' | 'artifact';
  id: string;
  storageKey: string;
}

export type ImportCleanupScope = 'parts' | 'all';

export interface CompletedSource {
  storageKey: string;
  sha256: string;
  size: string;
}

/**
 * Physical import artifacts are always manifest-first: persist their cleanup/business
 * row before publishing bytes. This applies to source_pdf and future question_image writers.
 */
export const IMPORT_ARTIFACT_PUBLISH_POLICY = 'manifest-first' as const;

export interface ImportArtifactRecord {
  id: string;
  type: 'question_image';
  storageKey: string;
  sha256: string;
  size: string;
  expiresAt: Date;
}

export interface ImportDraftQuestionRecord {
  id: string;
  position: number;
  type: string;
  question: string;
  options: Record<string, string> | null;
  answer: string | null;
  analysis: string | null;
  pageStart: number;
  pageEnd: number;
  confidence: number;
  reviewRequired: boolean;
  artifacts: ImportArtifactRecord[];
}

export interface ImportDraftRecord {
  questions: ImportDraftQuestionRecord[];
}

export interface ImportReviewRecord {
  job: ImportJobRecord;
  questions: ImportDraftQuestionRecord[];
}

export interface ConfirmImportQuestionInput {
  draftQuestionId: string;
  type: string;
  question: string;
  options: Record<string, string> | null;
  answer: string | null;
  analysis: string | null;
  reviewed: boolean;
}

export interface ConfirmImportInput {
  bankName: string;
  subject: string;
  questions: ConfirmImportQuestionInput[];
}

export interface ConfirmImportResult {
  bankId: string;
  questions: Array<{
    draftQuestionId: string;
    questionId: string;
    images: Array<{ artifactId: string; sha256: string; size: number }>;
  }>;
  expiresAt: string;
}

export interface ImportDownloadArtifact {
  artifactId: string;
  storageKey: string;
  sha256: string;
  size: number;
  expiresAt: Date;
}

export interface ImportArtifactAckPlan {
  acknowledged: boolean;
  records: ImportCleanupRecord[];
}

export interface ImportCleanupCandidate {
  jobId: string;
}

export interface ImportRepository {
  tryAcquireAssemblyLease(jobId: string, token: string, now: Date, expiresAt: Date): Promise<boolean>;
  renewAssemblyLease(jobId: string, token: string, now: Date, expiresAt: Date): Promise<boolean>;
  releaseAssemblyLease(jobId: string, token: string): Promise<boolean>;
  createJob(input: CreateImportJobRecord): Promise<ImportJobRecord>;
  findOwnedJob(userId: string, jobId: string): Promise<ImportJobRecord | null>;
  recordPart(input: ImportPartRecord): Promise<void>;
  prepareSource(userId: string, deviceId: string, jobId: string, source: CompletedSource): Promise<void>;
  queueCompletedUpload(userId: string, deviceId: string, jobId: string, source: CompletedSource): Promise<void>;
  claimNext(workerId: string): Promise<ImportJobRecord | null>;
  updateProgress(jobId: string, expectedClaimedAt: Date, current: number, total: number): Promise<void>;
  replaceDraft(jobId: string, expectedClaimedAt: Date, draft: ImportDraftRecord): Promise<void>;
  markFailure(jobId: string, expectedClaimedAt: Date, code: string, retryable: boolean): Promise<void>;
  cancelOwned(userId: string, deviceId: string, jobId: string): Promise<boolean>;
  getReviewDraft(userId: string, jobId: string): Promise<ImportReviewRecord | null>;
  confirmImport(userId: string, deviceId: string, jobId: string, requestSha256: string,
    input: ConfirmImportInput): Promise<ConfirmImportResult>;
  findDownloadArtifact(userId: string, deviceId: string, jobId: string,
    artifactId: string, now: Date): Promise<ImportDownloadArtifact | null>;
  prepareArtifactAck(userId: string, deviceId: string, jobId: string,
    artifactIds: string[], now: Date): Promise<ImportArtifactAckPlan>;
  markArtifactsAcknowledged(userId: string, deviceId: string, jobId: string,
    now: Date): Promise<void>;
  listCleanupCandidates(now: Date, afterJobId: string | null,
    limit: number): Promise<ImportCleanupCandidate[]>;
  listCleanupRecordsForJob(jobId: string, offset: number, limit: number): Promise<ImportCleanupRecord[]>;
  noteCleanupMissing(jobId: string, now: Date, graceMs: number): Promise<boolean>;
  canDeleteOrphan(jobId: string, now: Date, graceMs: number): Promise<boolean>;
  /**
   * `all` pages cancelled-job tombstones without consuming them; `parts` lists upload parts
   * of queued-or-later jobs for file-only sweeps. Rows are manifest-first durable tombstones
   * and are never consumed while the job is active: a late hard-link publication always
   * lands on a row-covered key and stays reclaimable. Rows are retired only with the job
   * (repeated cancellation sweeps and the 24-hour expiry cleanup).
   */
  listCleanupRecords(userId: string, deviceId: string, jobId: string,
    scope: ImportCleanupScope, offset: number, limit: number): Promise<ImportCleanupRecord[]>;
  expireBefore(now: Date): Promise<string[]>;
}
