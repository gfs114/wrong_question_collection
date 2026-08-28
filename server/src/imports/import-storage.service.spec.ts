import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, mkdir, readFile, readdir, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as fsPromises from 'node:fs/promises';
import {
  ImportStorageError,
  ImportStoragePublishFenceError,
  ImportStorageService
} from './import-storage.service';

const sha256 = (body: Buffer): string => createHash('sha256').update(body).digest('hex');
const jobId = (): string => randomUUID();
const partFileName = (partNumber: number): string => `part-${partNumber.toString().padStart(10, '0')}.bin`;
const partPath = (root: string, id: string, partNumber: number): string =>
  join(root, id, partFileName(partNumber));

describe('ImportStorageService', () => {
  let root: string;
  let storage: ImportStorageService;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'wqc-import-storage-'));
    storage = new ImportStorageService(
      { root, maxPdfBytes: 32, partBytes: 8, minFreeBytes: 4 },
      async () => Number.MAX_SAFE_INTEGER
    );
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it('rejects invalid job UUIDs and bounded part numbers', async () => {
    const body = Buffer.from('12345678');
    expect(() => storage.partKey('not-a-uuid', 0)).toThrow('Invalid import job');
    expect(() => storage.partKey(jobId(), -1)).toThrow('Invalid upload part number');
    expect(() => storage.partKey(jobId(), 0.5)).toThrow('Invalid upload part number');
    expect(() => storage.partKey(jobId(), 4)).toThrow('Invalid upload part number');
    expect(storage.partKey(jobId(), 3)).toMatch(/part-0000000003\.bin$/);
    expect('partPath' in storage).toBe(false);
    await expect(storage.writePart(jobId(), 0, body, sha256(body), 9)).rejects.toThrow(
      'FILE_SIZE_MISMATCH'
    );
  });

  it('round-trips the maximum allowed part number through generated storage keys', async () => {
    const id = jobId();
    const body = Buffer.from('12345678');
    const result = await storage.writePart(id, 3, body, sha256(body));
    expect(result.storageKey).toBe(`${id}/part-0000000003.bin`);
    await storage.deleteStorageKey(result.storageKey);
    await expect(readFile(partPath(root, id, 3))).rejects.toThrow();
  });

  it('only accepts generated storage keys and prevents traversal or absolute paths', async () => {
    const id = jobId();
    expect(storage.workerMountAccess()).toBe('read-only');
    await expect(storage.deleteStorageKey('../escape')).rejects.toThrow('Invalid storage key');
    await expect(storage.deleteStorageKey('/tmp/escape')).rejects.toThrow('Invalid storage key');
    await expect(storage.deleteStorageKey(`${id}/../source.pdf`)).rejects.toThrow('Invalid storage key');
    await expect(storage.deleteStorageKey(`${id}/untrusted-name.bin`)).rejects.toThrow('Invalid storage key');
  });

  it('opens a no-follow file-handle stream with exact size and an idempotent close', async () => {
    const id = jobId();
    const artifactId = jobId();
    const body = Buffer.from('jpeg-stream');
    await mkdir(join(root, id));
    await writeFile(join(root, id, `artifact-${artifactId}.bin`), body);

    const opened = await storage.openReadStream(
      `${id}/artifact-${artifactId}.bin`, body.length, { jobId: id, artifactId }
    );
    expect(Buffer.isBuffer(opened.stream)).toBe(false);
    const chunks: Buffer[] = [];
    for await (const chunk of opened.stream) chunks.push(Buffer.from(chunk));
    expect(Buffer.concat(chunks)).toEqual(body);
    await expect(opened.close()).resolves.toBeUndefined();
    await expect(opened.close()).resolves.toBeUndefined();

    await expect(storage.openReadStream(
      `${id}/artifact-${artifactId}.bin`, body.length + 1, { jobId: id, artifactId }
    )).rejects.toThrow('FILE_SIZE_MISMATCH');
  });

  it('canonicalizes artifact keys and enforces the expected job and artifact binding', async () => {
    const id = jobId();
    const artifactId = jobId();
    const otherArtifactId = jobId();
    const body = Buffer.from('jpeg-stream');
    const canonicalKey = `${id}/artifact-${artifactId}.bin`;
    expect(storage.artifactKey(id.toUpperCase(), artifactId.toUpperCase())).toBe(canonicalKey);
    await mkdir(join(root, id));
    await writeFile(join(root, id, `artifact-${artifactId}.bin`), body);
    await writeFile(join(root, id, 'source.pdf'), body);

    const boundOpen = storage.openReadStream.bind(storage) as unknown as (
      key: string, size: number, expected: { jobId: string; artifactId: string }
    ) => Promise<unknown>;
    await expect(boundOpen(`${id}/source.pdf`, body.length, { jobId: id, artifactId }))
      .rejects.toThrow('Invalid storage key');
    await expect(boundOpen(canonicalKey, body.length, { jobId: id, artifactId: otherArtifactId }))
      .rejects.toThrow('Invalid storage key');
  });

  it('never follows a symbolic-link artifact while opening a download stream', async () => {
    const id = jobId();
    const artifactId = jobId();
    const outside = await mkdtemp(join(tmpdir(), 'wqc-import-download-outside-'));
    await writeFile(join(outside, 'secret.bin'), Buffer.from('secret'));
    await mkdir(join(root, id));
    await symlink(
      join(outside, 'secret.bin'),
      join(root, id, `artifact-${artifactId}.bin`),
      'file'
    );
    try {
      await expect(storage.openReadStream(
        `${id}/artifact-${artifactId}.bin`, 6, { jobId: id, artifactId }
      )).rejects.toThrow('Unsafe storage path');
    } finally {
      await rm(outside, { recursive: true, force: true });
    }
  });

  it('inventories only canonical direct UUID directories without following links', async () => {
    const canonical = jobId();
    const uppercase = jobId().toUpperCase();
    const outside = await mkdtemp(join(tmpdir(), 'wqc-import-directory-outside-'));
    await mkdir(join(root, canonical));
    await mkdir(join(root, uppercase));
    await mkdir(join(root, 'not-a-job'));
    const linkedId = jobId();
    await symlink(outside, join(root, linkedId), process.platform === 'win32' ? 'junction' : 'dir');
    try {
      const directories = await storage.listJobDirectories(10);
      expect(directories.map((entry) => entry.jobId)).toEqual([canonical]);
      expect(Number.isFinite(directories[0].modifiedAt.getTime())).toBe(true);
    } finally {
      await rm(outside, { recursive: true, force: true });
    }
  });

  it('inventories canonical job directories after an exclusive UUID keyset cursor', async () => {
    const ids = [jobId(), jobId(), jobId()].sort();
    await Promise.all(ids.map((id) => mkdir(join(root, id))));

    const first = await storage.listJobDirectories(1, null);
    const second = await storage.listJobDirectories(2, first[0].jobId);

    expect(first.map((entry) => entry.jobId)).toEqual([ids[0]]);
    expect(second.map((entry) => entry.jobId)).toEqual(ids.slice(1));
    await expect(storage.listJobDirectories(1, ids[0].toUpperCase()))
      .rejects.toThrow('IMPORT_STORAGE_FAILURE');
  });

  it('rejects symbolic links in task directories and target files', async () => {
    const id = jobId();
    const outside = await mkdtemp(join(tmpdir(), 'wqc-import-outside-'));
    await symlink(outside, join(root, id), process.platform === 'win32' ? 'junction' : 'dir');
    await expect(storage.writePart(id, 0, Buffer.from('12345678'), sha256(Buffer.from('12345678')))).rejects.toThrow('Unsafe storage path');
    await rm(join(root, id), { recursive: true, force: true });
    await mkdir(join(root, id));
    await symlink(join(outside, 'target.bin'), partPath(root, id, 0), 'file');
    await expect(storage.writePart(id, 0, Buffer.from('12345678'), sha256(Buffer.from('12345678')))).rejects.toThrow(
      'Unsafe storage path'
    );
    await rm(outside, { recursive: true, force: true });
  });

  it('rejects a configured root whose existing ancestor is symbolic link', async () => {
    const outside = await mkdtemp(join(tmpdir(), 'wqc-import-outside-'));
    const alias = join(root, 'root-alias');
    await symlink(outside, alias, process.platform === 'win32' ? 'junction' : 'dir');
    const unsafe = new ImportStorageService(
      { root: join(alias, 'imports'), maxPdfBytes: 32, partBytes: 8, minFreeBytes: 4 },
      async () => Number.MAX_SAFE_INTEGER
    );
    const body = Buffer.from('12345678');
    await expect(unsafe.writePart(jobId(), 0, body, sha256(body))).rejects.toThrow('Unsafe storage path');
    await rm(outside, { recursive: true, force: true });
  });

  it('writes an exact-sized and hashed part atomically', async () => {
    const id = jobId();
    const body = Buffer.from('12345678');
    const result = await storage.writePart(id, 0, body, sha256(body), body.length);

    expect(result).toEqual({ storageKey: `${id}/part-0000000000.bin`, size: body.length, sha256: sha256(body), created: true });
    expect(await readFile(partPath(root, id, 0))).toEqual(body);
  });

  it('runs the part publish fence once after integrity validation and removes staging when it fails', async () => {
    const id = jobId();
    const body = Buffer.from('12345678');
    const fenceFailure = new Error('assembly lease lost');
    const fence = jest.fn(async () => {
      const names = await readdir(join(root, id));
      expect(names).not.toContain(partFileName(0));
      expect(names.filter((name) => name.endsWith('.partial'))).toHaveLength(1);
      throw fenceFailure;
    });

    await expect(storage.writePart(id, 0, body, sha256(body), body.length, fence))
      .rejects.toEqual(expect.objectContaining({
        name: 'ImportStoragePublishFenceError',
        cause: fenceFailure
      } satisfies Partial<ImportStoragePublishFenceError>));

    expect(fence).toHaveBeenCalledTimes(1);
    await expect(readFile(partPath(root, id, 0))).rejects.toThrow();
    expect((await readdir(join(root, id))).filter((name) => name.endsWith('.partial'))).toEqual([]);

    const invalidFence = jest.fn(async () => undefined);
    await expect(storage.writePart(id, 0, body, '0'.repeat(64), body.length, invalidFence))
      .rejects.toThrow('FILE_HASH_MISMATCH');
    await expect(storage.writePart(id, 0, body, sha256(body), body.length - 1, invalidFence))
      .rejects.toThrow('FILE_SIZE_MISMATCH');
    expect(invalidFence).not.toHaveBeenCalled();

    const successfulId = jobId();
    const successfulFence = jest.fn(async () => {
      const names = await readdir(join(root, successfulId));
      expect(names).not.toContain(partFileName(0));
      expect(names.filter((name) => name.endsWith('.partial'))).toHaveLength(1);
    });
    await expect(storage.writePart(
      successfulId, 0, body, sha256(body), body.length, successfulFence
    )).resolves.toMatchObject({ created: true });
    expect(successfulFence).toHaveBeenCalledTimes(1);
    await expect(readFile(partPath(root, successfulId, 0))).resolves.toEqual(body);
  });

  it('rejects wrong part size or SHA-256 and cleans partial files after a failed write', async () => {
    const id = jobId();
    const body = Buffer.from('12345678');
    await expect(storage.writePart(id, 0, body, '0'.repeat(64), body.length)).rejects.toThrow(
      'FILE_HASH_MISMATCH'
    );
    await expect(storage.writePart(id, 0, body, sha256(body), 7)).rejects.toThrow('FILE_SIZE_MISMATCH');
    await expect(readdir(join(root, id))).rejects.toThrow();
  });

  it('is idempotent for a duplicate part with identical content and rejects different content', async () => {
    const id = jobId();
    const original = Buffer.from('12345678');
    const replacement = Buffer.from('abcdefgh');
    await expect(storage.writePart(id, 0, original, sha256(original))).resolves.toMatchObject({ created: true });
    await expect(storage.writePart(id, 0, original, sha256(original))).resolves.toMatchObject({ size: 8, created: false });
    await expect(storage.writePart(id, 0, replacement, sha256(replacement))).rejects.toThrow(
      'UPLOAD_PART_CONFLICT'
    );
  });

  it('rejects a duplicate body whose actual hash differs from its declared stored hash', async () => {
    const id = jobId();
    const original = Buffer.from('12345678');
    const replacement = Buffer.from('abcdefgh');
    await storage.writePart(id, 0, original, sha256(original));
    await expect(storage.writePart(id, 0, replacement, sha256(original))).rejects.toThrow(
      'FILE_HASH_MISMATCH'
    );
  });

  it('serializes simultaneous hard-link publishers and cleans generated partials', async () => {
    const id = jobId();
    const body = Buffer.from('12345678');
    const first = storage.writePart(id, 0, body, sha256(body));
    const second = storage.writePart(id, 0, body, sha256(body));
    const identicalOutcomes = await Promise.all([first, second]);
    expect(identicalOutcomes.map((result) => result.created).sort()).toEqual([false, true]);
    expect((await readdir(join(root, id))).filter((name) => name.endsWith('.partial'))).toEqual([]);

    const different = Buffer.from('abcdefgh');
    const third = storage.writePart(id, 1, body, sha256(body));
    const fourth = storage.writePart(id, 1, different, sha256(different));
    const outcomes = await Promise.allSettled([third, fourth]);
    expect(outcomes.filter((outcome) => outcome.status === 'fulfilled')).toHaveLength(1);
    expect(outcomes.filter((outcome) => outcome.status === 'rejected')).toHaveLength(1);
    expect((await readdir(join(root, id))).filter((name) => name.endsWith('.partial'))).toEqual([]);
  });

  it('cleans generated partial files when final publication fails', async () => {
    const id = jobId();
    const body = Buffer.from('12345678');
    const service = storage as unknown as { fsyncDirectory: () => Promise<void> };
    jest.spyOn(service, 'fsyncDirectory').mockRejectedValueOnce(new Error('directory sync failed'));

    await expect(storage.writePart(id, 0, body, sha256(body))).rejects.toThrow('IMPORT_STORAGE_FAILURE');
    const names = await readdir(join(root, id));
    expect(names.filter((name) => name.endsWith('.partial'))).toEqual([]);
  });

  it('publishes a final file when only a crash-orphan partial exists', async () => {
    const id = jobId();
    const body = Buffer.from('12345678');
    await writeFile(join(root, id, `${partFileName(0)}.${randomUUID()}.partial`), body).catch(async () => {
      await mkdir(join(root, id));
      await writeFile(join(root, id, `${partFileName(0)}.${randomUUID()}.partial`), body);
    });
    const first = await storage.writePart(id, 0, body, sha256(body));
    expect(await readFile(partPath(root, id, 0))).toEqual(body);
    expect(first.storageKey).toBe(`${id}/part-0000000000.bin`);
  });

  it('treats an existing final as authoritative despite a crash-orphan partial and low disk space', async () => {
    const id = jobId();
    const body = Buffer.from('12345678');
    const first = await storage.writePart(id, 0, body, sha256(body));
    await writeFile(join(root, id, `${partFileName(0)}.${randomUUID()}.partial`), body);
    const lowSpace = new ImportStorageService(
      { root, maxPdfBytes: 32, partBytes: 8, minFreeBytes: 10 },
      async () => 0
    );
    await expect(lowSpace.writePart(id, 0, body, sha256(body))).resolves.toEqual({ ...first, created: false });
  });

  it('returns an existing source before part validation or disk admission', async () => {
    const id = jobId();
    const first = Buffer.from('12345678');
    const second = Buffer.from('abcdefgh');
    const source = Buffer.concat([first, second]);
    await storage.writePart(id, 0, first, sha256(first));
    await storage.writePart(id, 1, second, sha256(second));
    const merged = await storage.mergeParts(id, 2, source.length, sha256(source));
    await rm(partPath(root, id, 0));
    await rm(partPath(root, id, 1));
    const lowSpace = new ImportStorageService(
      { root, maxPdfBytes: 32, partBytes: 8, minFreeBytes: 10 },
      async () => 0
    );
    await expect(lowSpace.mergeParts(id, 2, source.length, sha256(source))).resolves.toEqual({ ...merged, created: false });
  });

  it('fails fast when the private root cannot create hard links', async () => {
    const unsupported = new ImportStorageService(
      { root, maxPdfBytes: 32, partBytes: 8, minFreeBytes: 4 },
      async () => Number.MAX_SAFE_INTEGER,
      async () => {
        const error = new Error('links disabled') as Error & { code: string };
        error.code = 'EOPNOTSUPP';
        throw error;
      }
    );
    const body = Buffer.from('12345678');
    await expect(unsupported.writePart(jobId(), 0, body, sha256(body))).rejects.toThrow(
      'IMPORT_STORAGE_UNSUPPORTED'
    );
    expect(await readdir(root)).toEqual([]);
  });

  it('keeps diagnostic causes private while returning stable storage errors', async () => {
    const limited = new ImportStorageService(
      { root, maxPdfBytes: 32, partBytes: 8, minFreeBytes: 10 },
      async () => 9
    );
    const body = Buffer.from('12345678');
    await expect(limited.writePart(jobId(), 0, body, sha256(body))).rejects.toEqual(
      expect.objectContaining({ message: 'INSUFFICIENT_STORAGE', cause: expect.any(Error) })
    );
  });

  it('creates a private writable root with POSIX owner-only mode', async () => {
    const body = Buffer.from('12345678');
    await storage.writePart(jobId(), 0, body, sha256(body));
    if (process.platform !== 'win32') {
      expect((await stat(root)).mode & 0o077).toBe(0);
    }
  });

  it('merges sequential parts and validates final size and SHA-256', async () => {
    const id = jobId();
    const first = Buffer.from('12345678');
    const second = Buffer.from('abcdefgh');
    const source = Buffer.concat([first, second]);
    await storage.writePart(id, 0, first, sha256(first));
    await storage.writePart(id, 1, second, sha256(second));

    const result = await storage.mergeParts(id, 2, source.length, sha256(source));
    expect(result).toEqual({ storageKey: `${id}/source.pdf`, size: source.length, sha256: sha256(source), created: true });
    await expect(readFile(join(root, id, 'source.pdf'))).resolves.toEqual(source);
    await expect(storage.mergeParts(jobId(), 1, source.length, sha256(source))).rejects.toThrow('UPLOAD_PART_MISSING');
  });

  it('runs the source publish fence once after merge validation and never leaves a target or staging file on rejection', async () => {
    const id = jobId();
    const first = Buffer.from('12345678');
    const second = Buffer.from('abcdefgh');
    const source = Buffer.concat([first, second]);
    await storage.writePart(id, 0, first, sha256(first));
    await storage.writePart(id, 1, second, sha256(second));
    const fenceFailure = new Error('assembly lease lost');
    const fence = jest.fn(async () => {
      const names = await readdir(join(root, id));
      expect(names).not.toContain('source.pdf');
      expect(names.filter((name) => name.startsWith('source.pdf.') && name.endsWith('.partial')))
        .toHaveLength(1);
      throw fenceFailure;
    });

    await expect(storage.mergeParts(id, 2, source.length, sha256(source), fence))
      .rejects.toEqual(expect.objectContaining({
        name: 'ImportStoragePublishFenceError',
        cause: fenceFailure
      } satisfies Partial<ImportStoragePublishFenceError>));

    expect(fence).toHaveBeenCalledTimes(1);
    await expect(readFile(join(root, id, 'source.pdf'))).rejects.toThrow();
    expect((await readdir(join(root, id))).filter((name) => name.endsWith('.partial'))).toEqual([]);
  });

  it('marks exactly one simultaneous merge publisher as the source creator', async () => {
    const id = jobId();
    const first = Buffer.from('12345678');
    const second = Buffer.from('abcdefgh');
    const source = Buffer.concat([first, second]);
    await storage.writePart(id, 0, first, sha256(first));
    await storage.writePart(id, 1, second, sha256(second));

    const outcomes = await Promise.all([
      storage.mergeParts(id, 2, source.length, sha256(source)),
      storage.mergeParts(id, 2, source.length, sha256(source))
    ]);

    expect(outcomes.map((result) => result.created).sort()).toEqual([false, true]);
    expect(outcomes[0].storageKey).toBe(`${id}/source.pdf`);
    expect(outcomes[1].storageKey).toBe(`${id}/source.pdf`);
    expect((await readdir(join(root, id))).filter((name) => name.endsWith('.partial'))).toEqual([]);
  });

  it('rejects merged output with a wrong expected final size or SHA-256', async () => {
    const id = jobId();
    const first = Buffer.from('12345678');
    const second = Buffer.from('abcdefgh');
    const source = Buffer.concat([first, second]);
    await storage.writePart(id, 0, first, sha256(first));
    await storage.writePart(id, 1, second, sha256(second));
    await expect(storage.mergeParts(id, 2, source.length - 1, sha256(source))).rejects.toThrow('FILE_SIZE_MISMATCH');
    await expect(storage.mergeParts(id, 2, source.length, '0'.repeat(64))).rejects.toThrow('FILE_HASH_MISMATCH');
    expect((await readdir(join(root, id))).filter((name) => name.endsWith('.partial') || name.endsWith('.lock'))).toEqual([]);
  });

  it('deletes only valid generated files beneath the storage root', async () => {
    const id = jobId();
    const body = Buffer.from('12345678');
    const write = await storage.writePart(id, 0, body, sha256(body));
    const outside = join(root, '..', `outside-${randomUUID()}.txt`);
    await writeFile(outside, 'keep');
    await storage.deleteStorageKey(write.storageKey);

    await expect(readFile(partPath(root, id, 0))).rejects.toThrow();
    await expect(readFile(outside, 'utf8')).resolves.toBe('keep');
    await rm(outside, { force: true });
  });

  it('rejects symbolic-link files before reading or deleting them', async () => {
    const id = jobId();
    const outside = await mkdtemp(join(tmpdir(), 'wqc-import-outside-'));
    await mkdir(join(root, id));
    await symlink(join(outside, 'source.pdf'), join(root, id, 'source.pdf'), 'file');
    await expect(storage.deleteStorageKey(`${id}/source.pdf`)).rejects.toThrow('Unsafe storage path');
    await symlink(join(outside, 'part.bin'), partPath(root, id, 0), 'file');
    await expect(storage.mergeParts(id, 1, 8, sha256(Buffer.from('12345678')))).rejects.toThrow('Unsafe storage path');
    await rm(outside, { recursive: true, force: true });
  });

  it('rejects writes when the injected disk watermark is not met', async () => {
    const limited = new ImportStorageService(
      { root, maxPdfBytes: 32, partBytes: 8, minFreeBytes: 10 },
      async () => 9
    );
    const body = Buffer.from('12345678');
    await expect(limited.writePart(jobId(), 0, body, sha256(body))).rejects.toThrow('INSUFFICIENT_STORAGE');
  });

  it.each([Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, -1, Number.MAX_SAFE_INTEGER + 1])(
    'fails closed when the free-space seam returns %p',
    async (freeBytes) => {
      const limited = new ImportStorageService(
        { root, maxPdfBytes: 32, partBytes: 8, minFreeBytes: 4 },
        async () => freeBytes
      );
      const body = Buffer.from('12345678');
      await expect(limited.writePart(jobId(), 0, body, sha256(body))).rejects.toThrow('INSUFFICIENT_STORAGE');
    }
  );

  it('does not create a task directory when deleting a missing valid storage key', async () => {
    const id = jobId();
    await storage.deleteStorageKey(`${id}/source.pdf`);
    await expect(stat(join(root, id))).rejects.toThrow();
  });

  it('reclaims every remaining file and then removes the job directory for a terminal job', async () => {
    const id = jobId();
    const body = Buffer.from('12345678');
    await storage.writePart(id, 0, body, sha256(body));
    await writeFile(join(root, id, `source.pdf.${randomUUID()}.partial`), 'staging');
    await writeFile(join(root, id, 'leftover.bin'), 'late publish');

    await storage.deleteJobDirectory(id);

    await expect(stat(join(root, id))).rejects.toThrow();
    await expect(readFile(partPath(root, id, 0))).rejects.toThrow();
  });

  it('ignores missing job directories and rejects invalid or escaping job ids', async () => {
    const missing = jobId();
    await storage.deleteJobDirectory(missing);
    await expect(stat(join(root, missing))).rejects.toThrow();

    await expect(storage.deleteJobDirectory('not-a-uuid')).rejects.toThrow('Invalid import job');
    await expect(storage.deleteJobDirectory('../../escape')).rejects.toThrow('Invalid import job');
  });

  it('never follows or removes directories or symbolic links inside a job directory', async () => {
    const id = jobId();
    const outside = await mkdtemp(join(tmpdir(), 'wqc-import-outside-'));
    try {
      await mkdir(join(root, id));
      await writeFile(join(outside, 'target.txt'), 'keep');
      await symlink(join(outside, 'target.txt'), join(root, id, 'linked.txt'), 'file');
      await mkdir(join(root, id, 'nested'));

      await storage.deleteJobDirectory(id);

      expect((await readdir(join(root, id))).sort()).toEqual(['linked.txt', 'nested']);
      await expect(readFile(join(outside, 'target.txt'), 'utf8')).resolves.toBe('keep');
    } finally {
      await rm(outside, { recursive: true, force: true });
    }
  });

  it('never unlinks direct entries that are not regular files at enumeration or revalidation', async () => {
    const id = jobId();
    await storage.jobDirectoryExists(id);
    await mkdir(join(root, id));
    const originalLstat = fsPromises.lstat;
    const readdirSpy = jest.spyOn(fsPromises, 'readdir').mockResolvedValue([
      {
        name: 'fifo', isDirectory: () => false, isSymbolicLink: () => false,
        isFile: () => false
      },
      {
        name: 'changed-to-socket', isDirectory: () => false, isSymbolicLink: () => false,
        isFile: () => true
      }
    ] as never);
    const lstatSpy = jest.spyOn(fsPromises, 'lstat').mockImplementation(async (path) => {
      if (String(path).endsWith('changed-to-socket')) {
        return { isFile: () => false, isSymbolicLink: () => false } as never;
      }
      return originalLstat(path);
    });
    const unlinkSpy = jest.spyOn(fsPromises, 'unlink');
    try {
      await storage.deleteJobDirectory(id);
      expect(unlinkSpy).not.toHaveBeenCalled();
    } finally {
      readdirSpy.mockRestore();
      lstatSpy.mockRestore();
      unlinkSpy.mockRestore();
    }
  });
});
