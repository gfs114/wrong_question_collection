import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { access, chmod, FileHandle, link, lstat, mkdir, open, readdir, realpath, rmdir, unlink } from 'node:fs/promises';
import { dirname, isAbsolute, join, resolve, sep } from 'node:path';
import { Readable } from 'node:stream';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256_PATTERN = /^[0-9a-f]{64}$/i;
const PART_FILE_PATTERN = /^part-(\d{10})\.bin$/;
const SOURCE_FILE = 'source.pdf';
const ARTIFACT_FILE_PATTERN = /^artifact-([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.bin$/i;
const PUBLIC_CODES = new Set([
  'FILE_HASH_MISMATCH', 'FILE_SIZE_MISMATCH', 'IMPORT_STORAGE_FAILURE',
  'IMPORT_STORAGE_UNSUPPORTED', 'INSUFFICIENT_STORAGE', 'Invalid import job',
  'Invalid storage key', 'Invalid upload part number', 'SOURCE_FILE_CONFLICT',
  'UPLOAD_PART_CONFLICT', 'UPLOAD_PART_MISSING', 'Unsafe storage path'
]);

export interface ImportStorageOptions {
  root: string;
  maxPdfBytes: number;
  partBytes: number;
  minFreeBytes: number;
}

export interface StoredFile {
  storageKey: string;
  size: number;
  sha256: string;
  created: boolean;
}

export interface OpenedImportFile {
  stream: Readable;
  size: number;
  close(): Promise<void>;
}

export interface ImportArtifactBinding {
  jobId: string;
  artifactId: string;
}

export interface ImportJobDirectory {
  jobId: string;
  modifiedAt: Date;
}

export type FreeSpace = (root: string) => Promise<number>;
export type HardLink = (existingPath: string, newPath: string) => Promise<void>;
export type ImportPublishFence = () => Promise<void>;

export function canonicalArtifactStorageKey(jobId: string, artifactId: string): string | null {
  if (typeof jobId !== 'string' || typeof artifactId !== 'string' ||
    !UUID_PATTERN.test(jobId) || !UUID_PATTERN.test(artifactId)) return null;
  return `${jobId.toLowerCase()}/artifact-${artifactId.toLowerCase()}.bin`;
}

export class ImportStorageError extends Error {
  constructor(public readonly code: string, public readonly cause: unknown) {
    super(code);
    this.name = 'ImportStorageError';
  }
}

/** Preserves the lease error raised by the publish fence for the API layer. */
export class ImportStoragePublishFenceError extends Error {
  constructor(public readonly cause: unknown) {
    super('IMPORT_PUBLISH_FENCE_REJECTED');
    this.name = 'ImportStoragePublishFenceError';
  }
}

interface TaskDirectory { root: string; path: string; }
interface FileMetadata { size: number; sha256: string; }

/**
 * Owns a private incoming root. Protection assumes no other writer can mutate this root.
 * Worker processes may consume generated keys only after mounting this area read-only.
 */
export class ImportStorageService {
  private readonly configuredRoot: string;
  private probedRoot: string | undefined;

  constructor(
    private readonly options: ImportStorageOptions,
    private readonly freeSpace: FreeSpace,
    private readonly hardLink: HardLink = link
  ) {
    if (!isAbsolute(options.root) || !Number.isInteger(options.maxPdfBytes) || options.maxPdfBytes < 1 ||
      !Number.isInteger(options.partBytes) || options.partBytes < 1 || options.partBytes > options.maxPdfBytes ||
      !Number.isSafeInteger(options.minFreeBytes) || options.minFreeBytes < 1) {
      throw new ImportStorageError('IMPORT_STORAGE_FAILURE', new Error('invalid storage configuration'));
    }
    this.configuredRoot = resolve(options.root);
  }

  workerMountAccess(): 'read-only' { return 'read-only'; }

  partKey(jobId: string, partNumber: number): string {
    this.assertJobId(jobId);
    this.assertPartNumber(partNumber);
    return `${jobId}/${this.partFileName(partNumber)}`;
  }

  sourceKey(jobId: string): string {
    this.assertJobId(jobId);
    return `${jobId}/${SOURCE_FILE}`;
  }

  artifactKey(jobId: string, artifactId: string): string {
    const key = canonicalArtifactStorageKey(jobId, artifactId);
    if (key === null) throw this.error('Invalid import job');
    return key;
  }

  async writePart(jobId: string, partNumber: number, body: Buffer, expectedSha256: string,
    expectedSize: number = body.length, beforePublish?: ImportPublishFence): Promise<StoredFile> {
    return this.publicCall(async () => {
      this.assertJobId(jobId); this.assertPartNumber(partNumber);
      this.assertExpectedSize(expectedSize, this.options.partBytes); this.assertExpectedHash(expectedSha256);
      if (body.length !== expectedSize) throw this.error('FILE_SIZE_MISMATCH');
      const actualSha256 = this.hashBuffer(body);
      if (actualSha256 !== expectedSha256.toLowerCase()) throw this.error('FILE_HASH_MISMATCH');
      const task = await this.taskDirectory(jobId);
      const storageKey = this.partKey(jobId, partNumber);
      const target = await this.filePath(task, this.partFileName(partNumber), true);
      const existing = await this.existingFile(task, target, true);
      if (existing !== undefined) return this.idempotentOrConflict(existing, expectedSize, actualSha256, storageKey, 'UPLOAD_PART_CONFLICT');
      // This watermark is admission control for a new write, not a global concurrent reservation.
      await this.assertFreeSpace(task.root, body.length);
      const partial = await this.filePath(task, `${this.partFileName(partNumber)}.${randomUUID()}.partial`, true);
      let handle: FileHandle | undefined;
      try {
        handle = await this.openNewRegularFile(task, partial);
        await handle.writeFile(body); await handle.sync(); await handle.close(); handle = undefined;
        const stored = await this.existingFile(task, partial, false);
        if (stored === undefined || stored.size !== expectedSize) throw this.error('FILE_SIZE_MISMATCH');
        if (stored.sha256 !== actualSha256) throw this.error('FILE_HASH_MISMATCH');
        const created = await this.publish(
          task, partial, target, expectedSize, actualSha256, storageKey,
          'UPLOAD_PART_CONFLICT', beforePublish
        );
        return { storageKey, size: expectedSize, sha256: actualSha256, created };
      } finally {
        try { if (handle !== undefined) await handle.close(); }
        finally { await this.removeGeneratedFile(task, partial); }
      }
    });
  }

  async mergeParts(jobId: string, partCount: number, expectedSize: number, expectedSha256: string,
    beforePublish?: ImportPublishFence): Promise<StoredFile> {
    return this.publicCall(async () => {
      this.assertJobId(jobId);
      if (!Number.isInteger(partCount) || partCount < 1 || partCount > this.maxPartCount()) throw this.error('Invalid upload part number');
      this.assertExpectedSize(expectedSize, this.options.maxPdfBytes); this.assertExpectedHash(expectedSha256);
      const task = await this.taskDirectory(jobId);
      const storageKey = this.sourceKey(jobId);
      const target = await this.filePath(task, SOURCE_FILE, true);
      const existing = await this.existingFile(task, target, true);
      if (existing !== undefined) return this.idempotentOrConflict(existing, expectedSize, expectedSha256.toLowerCase(), storageKey, 'SOURCE_FILE_CONFLICT');
      await this.assertFreeSpace(task.root, expectedSize);
      const partial = await this.filePath(task, `${SOURCE_FILE}.${randomUUID()}.partial`, true);
      let destination: FileHandle | undefined;
      try {
        destination = await this.openNewRegularFile(task, partial);
        const hash = createHash('sha256'); let size = 0;
        for (let number = 0; number < partCount; number += 1) {
          const source = await this.filePath(task, this.partFileName(number), true);
          const sourceHandle = await this.openRegularFile(task, source, 'UPLOAD_PART_MISSING');
          try {
            const buffer = Buffer.allocUnsafe(Math.min(this.options.partBytes, 64 * 1024)); let position = 0;
            while (true) {
              const read = await sourceHandle.read(buffer, 0, buffer.length, position);
              if (read.bytesRead === 0) break;
              const chunk = buffer.subarray(0, read.bytesRead);
              await this.writeFully(destination, chunk); hash.update(chunk); size += chunk.length; position += read.bytesRead;
            }
          } finally { await sourceHandle.close(); }
        }
        const actualSha256 = hash.digest('hex');
        if (size !== expectedSize) throw this.error('FILE_SIZE_MISMATCH');
        if (actualSha256 !== expectedSha256.toLowerCase()) throw this.error('FILE_HASH_MISMATCH');
        await destination.sync(); await destination.close(); destination = undefined;
        const created = await this.publish(
          task, partial, target, size, actualSha256, storageKey,
          'SOURCE_FILE_CONFLICT', beforePublish
        );
        return { storageKey, size, sha256: actualSha256, created };
      } finally {
        try { if (destination !== undefined) await destination.close(); }
        finally { await this.removeGeneratedFile(task, partial); }
      }
    });
  }

  async deleteStorageKey(storageKey: string): Promise<void> {
    return this.publicCall(async () => {
      const parsed = this.parseStorageKey(storageKey);
      const task = await this.existingTaskDirectory(parsed.jobId);
      if (task === undefined) {
        return;
      }
      const target = await this.filePath(task, parsed.fileName, true);
      let handle: FileHandle | undefined;
      try {
        handle = await this.openRegularFile(task, target);
        const info = await handle.stat();
        if (!info.isFile()) throw this.error('Unsafe storage path');
      } catch (cause: unknown) {
        if (this.isNotFound(cause)) return;
        throw cause;
      } finally { if (handle !== undefined) await handle.close(); }
      await this.revalidateTaskDirectory(task); await unlink(target); await this.fsyncDirectory(task);
      await this.removeEmptyTaskDirectory(task);
    });
  }

  async openReadStream(storageKey: string, expectedSize: number, expectedSha256: string,
    expected: ImportArtifactBinding): Promise<OpenedImportFile> {
    return this.publicCall(async () => {
      if (!Number.isSafeInteger(expectedSize) || expectedSize < 1) {
        throw this.error('FILE_SIZE_MISMATCH');
      }
      if (!SHA256_PATTERN.test(expectedSha256)) {
        throw this.error('FILE_HASH_MISMATCH');
      }
      const expectedKey = this.artifactKey(expected.jobId, expected.artifactId);
      if (storageKey !== expectedKey) throw this.error('Invalid storage key');
      const parsed = this.parseStorageKey(storageKey);
      if (parsed.jobId !== expected.jobId.toLowerCase() ||
        parsed.fileName !== `artifact-${expected.artifactId.toLowerCase()}.bin`) {
        throw this.error('Invalid storage key');
      }
      const task = await this.existingTaskDirectory(parsed.jobId);
      if (task === undefined) throw this.error('IMPORT_STORAGE_FAILURE');
      const target = await this.filePath(task, parsed.fileName, false);
      let handle: FileHandle | undefined;
      try {
        handle = await this.openRegularFile(task, target);
        const info = await handle.stat();
        if (!info.isFile() || Number(info.size) !== expectedSize) {
          throw this.error('FILE_SIZE_MISMATCH');
        }
        // Verify the file's actual content before any byte is handed to the
        // client: the same O_NOFOLLOW handle is read once with an explicit
        // position (the handle position is unchanged), so a same-size corrupt
        // file can never be served with a 200.
        if (await this.hashHandle(handle) !== expectedSha256.toLowerCase()) {
          throw this.error('FILE_HASH_MISMATCH');
        }
        await this.revalidateTaskDirectory(task);
        const ownedHandle = handle;
        handle = undefined;
        const stream = ownedHandle.createReadStream({ autoClose: false });
        let closed = false;
        return {
          stream,
          size: expectedSize,
          close: async () => {
            if (closed) return;
            closed = true;
            stream.destroy();
            try { await ownedHandle.close(); }
            catch (cause: unknown) {
              if (this.errorCode(cause) !== 'EBADF') throw cause;
            }
          }
        };
      } finally {
        if (handle !== undefined) await handle.close();
      }
    });
  }

  async jobDirectoryExists(jobId: string): Promise<boolean> {
    return this.publicCall(async () => {
      this.assertJobId(jobId);
      return (await this.existingTaskDirectory(jobId)) !== undefined;
    });
  }

  async listJobDirectories(limit: number, afterJobId: string | null = null): Promise<ImportJobDirectory[]> {
    return this.publicCall(async () => {
      if (!Number.isInteger(limit) || limit < 1 || limit > 100 ||
        (afterJobId !== null && (afterJobId !== afterJobId.toLowerCase() || !UUID_PATTERN.test(afterJobId)))) {
        throw this.error('IMPORT_STORAGE_FAILURE');
      }
      const root = await this.rootDirectory();
      const result: ImportJobDirectory[] = [];
      const entries = await readdir(root, { withFileTypes: true });
      for (const entry of entries.sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0)) {
        if (result.length >= limit) break;
        if (!entry.isDirectory() || entry.isSymbolicLink() ||
          entry.name !== entry.name.toLowerCase() || !UUID_PATTERN.test(entry.name) ||
          (afterJobId !== null && entry.name <= afterJobId)) {
          continue;
        }
        const candidate = join(root, entry.name);
        this.assertContained(root, candidate);
        const info = await lstat(candidate);
        if (!info.isDirectory() || info.isSymbolicLink()) continue;
        this.assertContained(root, await realpath(candidate));
        result.push({ jobId: entry.name, modifiedAt: info.mtime });
      }
      return result;
    });
  }

  /**
   * Reclaims every remaining file inside a terminal job directory and then removes the
   * directory itself when empty. Only safe for terminal jobs (cancelled/expired): at that
   * point any leftover file is either the staging partial of a fenced-out writer or a late
   * hard-link publication, all reclaimable garbage. Once the directory is gone, a still
   * running publish hard-link fails with ENOENT, so no file can materialize after teardown;
   * a link that lands while the sweep runs is removed here and remains covered by its
   * manifest-first tombstone row until it is. A missing directory is a no-op; a directory
   * that cannot be emptied is left in place for a later sweep. Directories and symbolic
   * links are never followed or removed.
   */
  async deleteJobDirectory(jobId: string): Promise<void> {
    return this.publicCall(async () => {
      this.assertJobId(jobId);
      const task = await this.existingTaskDirectory(jobId);
      if (task === undefined) {
        return;
      }
      const entries = await readdir(task.path, { withFileTypes: true });
      for (const entry of entries) {
        if (!entry.isFile() || entry.isSymbolicLink()) {
          continue;
        }
        const target = join(task.path, entry.name);
        await this.revalidateTaskDirectory(task);
        this.assertContained(task.root, target);
        try {
          const info = await lstat(target);
          if (!info.isFile() || info.isSymbolicLink()) continue;
          await this.revalidateTaskDirectory(task);
          await unlink(target);
        } catch (cause: unknown) {
          // A concurrent deletion may have removed the entry between readdir and unlink.
          if (!this.isNotFound(cause)) throw cause;
        }
      }
      await this.removeEmptyTaskDirectory(task);
    });
  }

  private async taskDirectory(jobId: string): Promise<TaskDirectory> {
    const root = await this.rootDirectory(); const candidate = join(root, jobId); this.assertContained(root, candidate);
    try { const info = await lstat(candidate); this.assertDirectory(info.isDirectory(), info.isSymbolicLink()); }
    catch (cause: unknown) {
      if (!this.isNotFound(cause)) throw cause;
      try { await mkdir(candidate, { mode: 0o700 }); }
      catch (mkdirCause: unknown) { if (!this.isAlreadyExists(mkdirCause)) throw mkdirCause; }
    }
    const task = { root, path: candidate }; await this.revalidateTaskDirectory(task); return task;
  }

  private async existingTaskDirectory(jobId: string): Promise<TaskDirectory | undefined> {
    const root = await this.rootDirectory();
    const candidate = join(root, jobId);
    this.assertContained(root, candidate);
    try {
      const info = await lstat(candidate);
      this.assertDirectory(info.isDirectory(), info.isSymbolicLink());
    } catch (cause: unknown) {
      if (this.isNotFound(cause)) {
        return undefined;
      }
      throw cause;
    }
    const task = { root, path: candidate };
    await this.revalidateTaskDirectory(task);
    return task;
  }

  private async rootDirectory(): Promise<string> {
    await this.assertExistingAncestorsSafe(this.configuredRoot); await mkdir(this.configuredRoot, { recursive: true, mode: 0o700 });
    if (process.platform !== 'win32') await chmod(this.configuredRoot, 0o700);
    await access(this.configuredRoot, constants.W_OK); await this.assertExistingAncestorsSafe(this.configuredRoot);
    const info = await lstat(this.configuredRoot); this.assertDirectory(info.isDirectory(), info.isSymbolicLink());
    const root = await realpath(this.configuredRoot); await this.ensureHardLinkSupport(root); return root;
  }

  private async ensureHardLinkSupport(root: string): Promise<void> {
    if (this.probedRoot === root) return;
    const source = join(root, `.link-probe-${randomUUID()}.partial`); const target = join(root, `.link-probe-${randomUUID()}`);
    let handle: FileHandle | undefined;
    try {
      handle = await open(source, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      await handle.sync(); await handle.close(); handle = undefined;
      await this.hardLink(source, target); this.probedRoot = root;
    } catch (cause: unknown) {
      if (this.isUnsupportedLink(cause)) throw this.error('IMPORT_STORAGE_UNSUPPORTED', cause);
      throw cause;
    } finally {
      try { if (handle !== undefined) await handle.close(); }
      finally { await this.removeRootProbe(root, target); await this.removeRootProbe(root, source); }
    }
  }

  private async removeRootProbe(root: string, target: string): Promise<void> {
    try {
      this.assertContained(root, target); const info = await lstat(target);
      if (info.isFile() && !info.isSymbolicLink()) await unlink(target);
    } catch (cause: unknown) { if (!this.isNotFound(cause)) throw cause; }
  }

  private async assertExistingAncestorsSafe(path: string): Promise<void> {
    let current = resolve(path);
    while (true) {
      try { if ((await lstat(current)).isSymbolicLink()) throw this.error('Unsafe storage path'); }
      catch (cause: unknown) { if (!this.isNotFound(cause)) throw cause; }
      const parent = dirname(current); if (parent === current) return; current = parent;
    }
  }

  private async revalidateTaskDirectory(task: TaskDirectory): Promise<void> {
    const root = await this.rootDirectory(); if (root !== task.root) throw this.error('Unsafe storage path');
    const info = await lstat(task.path); this.assertDirectory(info.isDirectory(), info.isSymbolicLink());
    this.assertContained(task.root, await realpath(task.path));
  }

  private async filePath(task: TaskDirectory, name: string, allowMissing: boolean): Promise<string> {
    await this.revalidateTaskDirectory(task); const target = join(task.path, name); this.assertContained(task.root, target);
    try { const info = await lstat(target); if (info.isSymbolicLink() || !info.isFile()) throw this.error('Unsafe storage path'); }
    catch (cause: unknown) { if (allowMissing && this.isNotFound(cause)) return target; throw cause; }
    return target;
  }

  private async existingFile(task: TaskDirectory, target: string, allowMissing: boolean): Promise<FileMetadata | undefined> {
    try {
      const handle = await this.openRegularFile(task, target);
      try { const info = await handle.stat(); return { size: Number(info.size), sha256: await this.hashHandle(handle) }; }
      finally { await handle.close(); }
    } catch (cause: unknown) { if (allowMissing && this.isNotFound(cause)) return undefined; throw cause; }
  }

  private async openRegularFile(task: TaskDirectory, target: string, missingCode?: string): Promise<FileHandle> {
    await this.revalidateTaskDirectory(task); await this.filePath(task, target.slice(task.path.length + 1), true);
    let handle: FileHandle | undefined;
    try {
      handle = await open(target, constants.O_RDONLY | constants.O_NOFOLLOW);
      if (!(await handle.stat()).isFile()) throw this.error('Unsafe storage path');
      const result = handle; handle = undefined; return result;
    } catch (cause: unknown) {
      if (this.isNotFound(cause) && missingCode !== undefined) throw this.error(missingCode, cause);
      throw cause;
    } finally { if (handle !== undefined) await handle.close(); }
  }

  private async openNewRegularFile(task: TaskDirectory, target: string): Promise<FileHandle> {
    await this.revalidateTaskDirectory(task); await this.filePath(task, target.slice(task.path.length + 1), true);
    let handle: FileHandle | undefined;
    try {
      handle = await open(target, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      if (!(await handle.stat()).isFile()) throw this.error('Unsafe storage path');
      const result = handle; handle = undefined; return result;
    } finally { if (handle !== undefined) await handle.close(); }
  }

  private async publish(task: TaskDirectory, partial: string, target: string, size: number,
    sha256: string, key: string, conflict: string, beforePublish?: ImportPublishFence): Promise<boolean> {
    await this.revalidateTaskDirectory(task); await this.filePath(task, target.slice(task.path.length + 1), true);
    if (beforePublish !== undefined) {
      try {
        await beforePublish();
      } catch (cause: unknown) {
        throw new ImportStoragePublishFenceError(cause);
      }
    }
    // Fencing invariant: after the final lease check, invoke the no-overwrite atomic publish
    // immediately. In particular, never add awaited I/O between the callback and hardLink().
    //
    // Publish-commit protocol (tombstone form): every published target is manifest-first —
    // the service persists the cleanup row for `key` before this publish runs, and callers
    // never consume that row while the job is active. If the lease expires and another owner
    // cancels while this hardLink is in flight, the late link either lands on a row-covered
    // key (reclaimed by a later sweep) or fails with ENOENT after the cancelled job's
    // directory is torn down. A publisher must never skip the post-publish lease check.
    let publishing: Promise<void>;
    try {
      publishing = this.hardLink(partial, target);
      await publishing;
    }
    catch (cause: unknown) {
      if (!this.isAlreadyExists(cause)) throw cause;
      const existing = await this.existingFile(task, target, false);
      this.idempotentOrConflict(existing as FileMetadata, size, sha256, key, conflict); return false;
    }
    await this.fsyncDirectory(task); await unlink(partial);
    return true;
  }

  private async fsyncDirectory(task: TaskDirectory): Promise<void> {
    if (process.platform === 'win32') {
      return;
    }
    let handle: FileHandle | undefined;
    try {
      handle = await open(task.path, constants.O_RDONLY | constants.O_DIRECTORY);
      await handle.sync();
    } catch (cause: unknown) {
      if (!this.isUnsupportedDirectoryFsync(cause)) {
        throw cause;
      }
    } finally {
      if (handle !== undefined) {
        await handle.close();
      }
    }
  }

  private async removeGeneratedFile(task: TaskDirectory, target: string): Promise<void> {
    try {
      const relative = target.startsWith(`${task.path}${sep}`) ? target.slice(task.path.length + 1) : '';
      if (relative.length === 0) {
        throw this.error('Unsafe storage path');
      }
      await this.filePath(task, relative, true);
      const info = await lstat(target);
      if (info.isFile() && !info.isSymbolicLink()) {
        await unlink(target);
      }
    } catch (cause: unknown) {
      if (!this.isNotFound(cause)) {
        throw cause;
      }
    }
  }

  private async removeEmptyTaskDirectory(task: TaskDirectory): Promise<void> {
    try {
      await this.revalidateTaskDirectory(task);
      await rmdir(task.path);
    } catch (cause: unknown) {
      if (!this.isNotFound(cause) && !this.isDirectoryNotEmpty(cause)) {
        throw cause;
      }
    }
  }

  private idempotentOrConflict(existing: FileMetadata, size: number, sha256: string, key: string, conflict: string): StoredFile {
    if (existing.size === size && existing.sha256 === sha256.toLowerCase()) {
      return { storageKey: key, ...existing, created: false };
    }
    throw this.error(conflict);
  }

  private parseStorageKey(key: string): { jobId: string; fileName: string } {
    if (typeof key !== 'string' || key.includes('\\') || key.includes('..')) {
      throw this.error('Invalid storage key');
    }
    const segments = key.split('/');
    if (segments.length !== 2 || !UUID_PATTERN.test(segments[0])) {
      throw this.error('Invalid storage key');
    }
    const part = PART_FILE_PATTERN.exec(segments[1]);
    if (part !== null) {
      this.assertPartNumber(Number(part[1]));
    } else if (segments[1] !== SOURCE_FILE && !ARTIFACT_FILE_PATTERN.test(segments[1])) {
      throw this.error('Invalid storage key');
    }
    return { jobId: segments[0], fileName: segments[1] };
  }

  private partFileName(number: number): string {
    return `part-${number.toString().padStart(10, '0')}.bin`;
  }

  private assertJobId(id: string): void {
    if (typeof id !== 'string' || !UUID_PATTERN.test(id)) {
      throw this.error('Invalid import job');
    }
  }

  private assertPartNumber(number: number): void {
    if (!Number.isInteger(number) || number < 0 || number >= this.maxPartCount()) {
      throw this.error('Invalid upload part number');
    }
  }

  private maxPartCount(): number {
    return Math.ceil(this.options.maxPdfBytes / this.options.partBytes);
  }

  private assertExpectedSize(size: number, max: number): void {
    if (!Number.isInteger(size) || size < 1 || size > max) {
      throw this.error('FILE_SIZE_MISMATCH');
    }
  }

  private assertExpectedHash(hash: string): void {
    if (typeof hash !== 'string' || !SHA256_PATTERN.test(hash)) {
      throw this.error('FILE_HASH_MISMATCH');
    }
  }

  private assertContained(root: string, target: string): void {
    const prefix = root.endsWith(sep) ? root : `${root}${sep}`;
    if (!target.startsWith(prefix)) {
      throw this.error('Invalid storage key');
    }
  }

  private assertDirectory(directory: boolean, symbolic: boolean): void {
    if (!directory || symbolic) {
      throw this.error('Unsafe storage path');
    }
  }
  private async assertFreeSpace(root: string, incoming: number): Promise<void> {
    const available = await this.freeSpace(root);
    const required = this.options.minFreeBytes + incoming;
    if (!Number.isFinite(available) || !Number.isSafeInteger(available) || available < 0 ||
      !Number.isSafeInteger(required) || available < required) {
      throw this.error('INSUFFICIENT_STORAGE');
    }
  }
  private hashBuffer(body: Buffer): string {
    return createHash('sha256').update(body).digest('hex');
  }

  private async hashHandle(handle: FileHandle): Promise<string> {
    const hash = createHash('sha256');
    const buffer = Buffer.allocUnsafe(64 * 1024);
    let position = 0;
    while (true) {
      const read = await handle.read(buffer, 0, buffer.length, position);
      if (read.bytesRead === 0) {
        return hash.digest('hex');
      }
      hash.update(buffer.subarray(0, read.bytesRead));
      position += read.bytesRead;
    }
  }

  private async writeFully(handle: FileHandle, data: Buffer): Promise<void> {
    let offset = 0;
    while (offset < data.length) {
      const wrote = await handle.write(data, offset, data.length - offset, null);
      offset += wrote.bytesWritten;
    }
  }

  private error(code: string, cause: unknown = new Error(code)): ImportStorageError {
    return new ImportStorageError(code, cause);
  }

  private async publicCall<T>(operation: () => Promise<T>): Promise<T> {
    try {
      return await operation();
    } catch (cause: unknown) {
      if (cause instanceof ImportStorageError) {
        throw cause;
      }
      if (cause instanceof ImportStoragePublishFenceError) {
        throw cause;
      }
      if (cause instanceof Error && PUBLIC_CODES.has(cause.message)) {
        throw this.error(cause.message, cause);
      }
      throw this.error('IMPORT_STORAGE_FAILURE', cause);
    }
  }
  private isNotFound(cause: unknown): boolean { return this.errorCode(cause) === 'ENOENT'; }
  private isAlreadyExists(cause: unknown): boolean { return this.errorCode(cause) === 'EEXIST'; }
  private isDirectoryNotEmpty(cause: unknown): boolean { const code = this.errorCode(cause); return code === 'ENOTEMPTY' || code === 'EEXIST'; }
  private isUnsupportedLink(cause: unknown): boolean { const code = this.errorCode(cause); return code === 'EXDEV' || code === 'EPERM' || code === 'ENOTSUP' || code === 'EOPNOTSUPP'; }
  private isUnsupportedDirectoryFsync(cause: unknown): boolean { const code = this.errorCode(cause); return code === 'EINVAL' || code === 'ENOTSUP' || code === 'EOPNOTSUPP'; }
  private errorCode(cause: unknown): string | undefined { if (typeof cause === 'object' && cause !== null && 'code' in cause) { const code = (cause as { code?: unknown }).code; return typeof code === 'string' ? code : undefined; } return undefined; }
}
