import { Inject, Injectable, OnModuleDestroy, OnModuleInit, Optional } from '@nestjs/common';
import { ImportCleanupCandidate, ImportRepository } from './import.contracts';
import { ImportStorageService } from './import-storage.service';
import { IMPORT_REPOSITORY } from './import.service';

export const IMPORT_CLEANUP_CLOCK = Symbol('IMPORT_CLEANUP_CLOCK');
export const IMPORT_CLEANUP_OPTIONS = Symbol('IMPORT_CLEANUP_OPTIONS');

export interface ImportCleanupOptions {
  graceMs: number;
  batchSize: number;
  intervalMs?: number;
  maxPages?: number;
}

const DEFAULT_OPTIONS: ImportCleanupOptions = {
  graceMs: 60 * 60 * 1000,
  batchSize: 32,
  intervalMs: 5 * 60 * 1000,
  maxPages: 32
};

@Injectable()
export class ImportCleanupService implements OnModuleInit, OnModuleDestroy {
  private readonly options: Required<ImportCleanupOptions>;
  private timer: NodeJS.Timeout | undefined;
  private running = false;
  private cleanupAfterJobId: string | null = null;
  private orphanAfterJobId: string | null = null;

  constructor(
    @Inject(IMPORT_REPOSITORY) private readonly repository: ImportRepository,
    private readonly storage: ImportStorageService,
    @Optional() @Inject(IMPORT_CLEANUP_CLOCK) private readonly clock: () => Date = () => new Date(),
    @Optional() @Inject(IMPORT_CLEANUP_OPTIONS) options: ImportCleanupOptions = DEFAULT_OPTIONS
  ) {
    const intervalMs = options.intervalMs ?? DEFAULT_OPTIONS.intervalMs as number;
    const maxPages = options.maxPages ?? DEFAULT_OPTIONS.maxPages as number;
    if (!Number.isSafeInteger(options.graceMs) || options.graceMs < 1 ||
      !Number.isInteger(options.batchSize) || options.batchSize < 1 || options.batchSize > 100 ||
      !Number.isInteger(maxPages) || maxPages < 1 || maxPages > 100 ||
      !Number.isSafeInteger(intervalMs) || intervalMs < 1_000) {
      throw new Error('Invalid import cleanup options');
    }
    this.options = { ...options, intervalMs, maxPages };
  }

  onModuleInit(): void {
    this.timer = setInterval(() => { void this.runScheduled(); }, this.options.intervalMs);
    this.timer.unref();
  }

  onModuleDestroy(): void {
    if (this.timer !== undefined) clearInterval(this.timer);
    this.timer = undefined;
  }

  async runOnce(): Promise<ImportCleanupCandidate[]> {
    const now = this.clock();
    await this.repository.expireBefore(now);
    const candidates = await this.cleanupCandidates(now);
    await this.cleanupOrphans(now);
    return candidates;
  }

  private async cleanupCandidates(now: Date): Promise<ImportCleanupCandidate[]> {
    const processed: ImportCleanupCandidate[] = [];
    let afterJobId = this.cleanupAfterJobId;
    for (let page = 0; page < this.options.maxPages; page += 1) {
      const candidates = await this.repository.listCleanupCandidates(
        now, afterJobId, this.options.batchSize
      );
      if (candidates.length === 0) {
        this.cleanupAfterJobId = null;
        break;
      }
      for (const candidate of candidates) {
        processed.push(candidate);
        try {
          await this.cleanupRecordedJob(candidate.jobId, now);
        } catch {
          // A concurrent state change or database failure leaves this job retryable.
        }
      }
      afterJobId = candidates[candidates.length - 1].jobId;
      this.cleanupAfterJobId = afterJobId;
      if (candidates.length < this.options.batchSize) {
        this.cleanupAfterJobId = null;
        break;
      }
    }
    return processed;
  }

  private async cleanupRecordedJob(jobId: string, now: Date): Promise<void> {
    let offset = 0;
    while (true) {
      const records = await this.repository.listCleanupRecordsForJob(
        jobId, offset, this.options.batchSize
      );
      if (records.length === 0) break;
      for (const record of records) {
        if (!record.storageKey.startsWith(`${jobId}/`)) return;
        try {
          await this.storage.deleteStorageKey(record.storageKey);
        } catch {
          return;
        }
      }
      offset += records.length;
      if (records.length < this.options.batchSize) break;
    }
    try {
      await this.storage.deleteJobDirectory(jobId);
      if (await this.storage.jobDirectoryExists(jobId)) return;
    } catch {
      return;
    }
    await this.repository.noteCleanupMissing(jobId, now, this.options.graceMs);
  }

  private async cleanupOrphans(now: Date): Promise<void> {
    let afterJobId = this.orphanAfterJobId;
    for (let page = 0; page < this.options.maxPages; page += 1) {
      const directories = await this.storage.listJobDirectories(this.options.batchSize, afterJobId);
      if (directories.length === 0) {
        this.orphanAfterJobId = null;
        break;
      }
      for (const directory of directories) {
        if (directory.modifiedAt.getTime() + this.options.graceMs > now.getTime()) continue;
        try {
          if (!await this.repository.canDeleteOrphan(directory.jobId, now, this.options.graceMs)) continue;
          await this.storage.deleteJobDirectory(directory.jobId);
        } catch {
          // A later keyset pass retries; no database metadata is retired here.
        }
      }
      afterJobId = directories[directories.length - 1].jobId;
      this.orphanAfterJobId = afterJobId;
      if (directories.length < this.options.batchSize) {
        this.orphanAfterJobId = null;
        break;
      }
    }
  }

  private async runScheduled(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      await this.runOnce();
    } catch {
      // Keep metadata for the next bounded interval; never claim cleanup succeeded.
    } finally {
      this.running = false;
    }
  }
}
