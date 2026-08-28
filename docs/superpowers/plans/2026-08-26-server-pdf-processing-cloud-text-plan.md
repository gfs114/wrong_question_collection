# Server PDF Processing and Cloud Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move PDF rendering, OCR, question splitting, and cropping to the Ubuntu server while making MySQL the authoritative text store, retaining read-only offline text caches and device-private question images on HarmonyOS.

**Architecture:** NestJS owns authenticated resumable upload, task state, draft review, confirmation, artifact download, and cleanup. A single-concurrency Python worker claims jobs from MySQL and writes OCR drafts plus temporary images to a restricted volume. The HarmonyOS client uploads PDFs and downloads text caches and source-device images; offline mode is read-only, and existing local data is migrated without deletion until server verification succeeds.

**Tech Stack:** HarmonyOS API 26, ArkTS, ArkUI, Network Kit, ArkData RDB, Asset Store Kit, NestJS 11, TypeORM, MySQL 8.4, Python 3.11, PaddleOCR 3, PDFium, OpenCV, Pillow, Docker Compose, Jest, pytest, Hypium, Hvigor.

---

## Safety and sequencing rules

- Do not remove `OnDeviceOcrService.ets`, `PdfImportCoordinator.ets`, existing local tables, or `sync_outbox` until Tasks 1-12 pass end-to-end verification.
- Never commit `.env`, Huawei Client Secret, JWT keys, signing passwords, private keys, uploaded PDFs, generated question images, OCR models, or database backups.
- Every database migration must have an `up` and `down` test and must run in the existing migration container before the API or worker starts.
- Every task stages only the files listed for that task. Preserve the repository's unrelated dirty files.
- Run ArkTS checking after every `.ets` edit, then run Hvigor before claiming client success.

## File responsibility map

### NestJS

- `server/src/database/entities.ts`: TypeORM entities only.
- `server/src/database/migrations/1788000000000-cloud-import-schema.ts`: cloud-import schema only.
- `server/src/imports/import.contracts.ts`: domain enums and repository interfaces.
- `server/src/imports/import.dto.ts`: request validation DTOs only.
- `server/src/imports/import.repository.ts`: MySQL persistence and conditional state transitions.
- `server/src/imports/import-storage.service.ts`: safe task paths, hashes, atomic files, and deletion.
- `server/src/imports/import.service.ts`: authenticated import orchestration.
- `server/src/imports/import.controller.ts`: HTTP mapping only.
- `server/src/imports/import-cleanup.service.ts`: expiry and orphan cleanup.
- `server/src/imports/import.module.ts`: dependency wiring.

### OCR worker

- `server/worker/job_store.py`: MySQL job claiming and status updates.
- `server/worker/pdf_pipeline.py`: PDF validation, rendering, OCR, splitting, and crop generation.
- `server/worker/main.py`: one-job loop and retry policy.
- `server/worker/Dockerfile`: non-root worker image.

### HarmonyOS

- `entry/src/main/ets/models/CloudImportModels.ets`: typed API and page-state models.
- `entry/src/main/ets/services/CloudImportApi.ets`: authenticated upload/task/draft/artifact requests.
- `entry/src/main/ets/services/CloudImportService.ets`: resumable upload and task orchestration.
- `entry/src/main/ets/services/CloudCacheService.ets`: server-authoritative read-only cache replacement.
- `entry/src/main/ets/services/LegacyCloudMigrationService.ets`: old local text upload and image rebinding.
- `entry/src/main/ets/services/DeviceImageStore.ets`: account-scoped server-question UUID to local-image mapping.
- Existing PDF pages: UI state and navigation only; no OCR or rendering after cutover.

## Task 1: Add the cloud-import MySQL schema

**Files:**

- Modify: `server/src/database/entities.ts`
- Modify: `server/src/database/database-options.ts`
- Create: `server/src/database/migrations/1788000000000-cloud-import-schema.ts`
- Create: `server/src/database/migrations/1788000000000-cloud-import-schema.spec.ts`
- Modify: `server/src/database/entities.spec.ts`

- [ ] **Step 1: Write failing migration and entity tests**

Add assertions for `import_jobs`, `import_upload_parts`, `import_draft_questions`, and `import_artifacts`, including ownership indexes, unique part numbers, status indexes, expiry indexes, and foreign keys to users/devices/jobs.

```ts
expect(source).toContain('CREATE TABLE `import_jobs`');
expect(source).toContain('KEY `idx_import_job_status_created` (`status`, `createdAt`)');
expect(source).toContain('UNIQUE KEY `uq_import_part_job_number` (`jobId`, `partNumber`)');
expect(source).toContain('KEY `idx_import_artifact_expiry` (`expiresAt`)');
expect(ALL_ENTITIES).toEqual(expect.arrayContaining([
  ImportJobEntity,
  ImportUploadPartEntity,
  ImportDraftQuestionEntity,
  ImportArtifactEntity
]));
```

- [ ] **Step 2: Run the new tests and verify failure**

Run:

```powershell
npm test --prefix server -- --runInBand src/database/migrations/1788000000000-cloud-import-schema.spec.ts src/database/entities.spec.ts
```

Expected: FAIL because the migration and entities do not exist.

- [ ] **Step 3: Implement the four entities and migration**

Use these exact status and artifact values in both TypeScript and SQL:

```ts
export type ImportJobStatus =
  | 'uploading' | 'queued' | 'processing' | 'review'
  | 'confirmed' | 'failed' | 'cancelled' | 'expired';

export type ImportArtifactType = 'source_pdf' | 'question_image';
```

`ImportJobEntity` must contain `userId`, `deviceId`, bank metadata, page range, progress, `sourceSha256`, `sourceSize`, `partCount`, `retryCount`, nullable `errorCode`, nullable `claimedAt`, and `expiresAt`. `ImportUploadPartEntity` contains `jobId`, `partNumber`, `size`, `sha256`, and `storageKey`. `ImportDraftQuestionEntity` contains ordered text fields, page range, confidence, and `reviewRequired`. `ImportArtifactEntity` contains `jobId`, nullable `draftQuestionId`, type, storage key, content hash, size, and expiry.

Register the migration after the initial migration:

```ts
migrations: [InitialSchema1760000000000, CloudImportSchema1788000000000],
```

- [ ] **Step 4: Run schema tests and the complete server suite**

Run:

```powershell
npm test --prefix server -- --runInBand src/database/migrations/1788000000000-cloud-import-schema.spec.ts src/database/entities.spec.ts
npm test --prefix server -- --runInBand
```

Expected: the focused tests pass; the complete suite remains 0 failures.

- [ ] **Step 5: Commit Task 1**

```powershell
git add -- server/src/database/entities.ts server/src/database/entities.spec.ts server/src/database/database-options.ts server/src/database/migrations/1788000000000-cloud-import-schema.ts server/src/database/migrations/1788000000000-cloud-import-schema.spec.ts
git commit -m "feat(server): add cloud import schema"
```

## Task 2: Implement safe import storage

**Files:**

- Create: `server/src/imports/import-storage.service.ts`
- Create: `server/src/imports/import-storage.service.spec.ts`
- Modify: `server/src/config/environment.ts`
- Modify: `server/src/config/environment.spec.ts`

- [ ] **Step 1: Write failing path, hash, and deletion tests**

Cover rejection of traversal, symlinks, wrong sizes, wrong SHA-256 values, duplicate parts with different content, and deletion outside the configured root.

```ts
await expect(storage.partPath(jobId, -1)).rejects.toThrow('Invalid upload part number');
await expect(storage.writePart(jobId, 0, body, wrongHash)).rejects.toThrow('FILE_HASH_MISMATCH');
await expect(storage.deleteStorageKey('../escape')).rejects.toThrow('Invalid storage key');
expect(await storage.writePart(jobId, 0, body, sha256(body))).toEqual({ size: body.length, sha256: sha256(body) });
```

- [ ] **Step 2: Run the focused test and verify failure**

```powershell
npm test --prefix server -- --runInBand src/imports/import-storage.service.spec.ts
```

Expected: FAIL because `ImportStorageService` is missing.

- [ ] **Step 3: Implement storage with atomic writes**

Add validated environment values:

```ts
IMPORT_STORAGE_ROOT: string;
IMPORT_MAX_PDF_BYTES: number; // exactly 209715200
IMPORT_PART_BYTES: number; // exactly 4194304
IMPORT_ARTIFACT_TTL_HOURS: number; // exactly 24
IMPORT_MIN_FREE_BYTES: number; // exactly 5368709120
```

The service must derive every path as `<root>/<job UUID>/<server filename>`, write to `.partial`, `fsync`, then rename atomically. `deleteStorageKey` must compare the resolved path against the resolved root plus path separator before unlinking. Do not accept a filesystem path from an HTTP DTO.

- [ ] **Step 4: Run storage, environment, and server tests**

```powershell
npm test --prefix server -- --runInBand src/imports/import-storage.service.spec.ts src/config/environment.spec.ts
npm test --prefix server -- --runInBand
```

Expected: all tests pass.

- [ ] **Step 5: Commit Task 2**

```powershell
git add -- server/src/imports/import-storage.service.ts server/src/imports/import-storage.service.spec.ts server/src/config/environment.ts server/src/config/environment.spec.ts
git commit -m "feat(server): add isolated import storage"
```

## Task 3: Implement the import repository and state machine

**Files:**

- Create: `server/src/imports/import.contracts.ts`
- Create: `server/src/imports/import.repository.ts`
- Create: `server/src/imports/import.repository.spec.ts`

- [ ] **Step 1: Write failing conditional-transition tests**

Test allowed transitions, ownership, single-worker claims, two automatic retries, cancellation races, and expiry.

```ts
expect(canTransition('uploading', 'queued')).toBe(true);
expect(canTransition('processing', 'cancelled')).toBe(true);
expect(canTransition('confirmed', 'processing')).toBe(false);
expect(await repository.claimNext(workerId)).toMatchObject({ status: 'processing', retryCount: 0 });
expect(await repository.claimNext(secondWorkerId)).toBeNull();
```

- [ ] **Step 2: Run the focused test and verify failure**

```powershell
npm test --prefix server -- --runInBand src/imports/import.repository.spec.ts
```

Expected: FAIL because repository contracts are missing.

- [ ] **Step 3: Implement explicit state transitions**

Expose only these repository methods:

```ts
export interface ImportRepository {
  createJob(input: CreateImportJobRecord): Promise<ImportJobRecord>;
  findOwnedJob(userId: string, jobId: string): Promise<ImportJobRecord | null>;
  recordPart(input: ImportPartRecord): Promise<void>;
  queueCompletedUpload(userId: string, deviceId: string, jobId: string, source: CompletedSource): Promise<void>;
  claimNext(workerId: string): Promise<ImportJobRecord | null>;
  updateProgress(jobId: string, current: number, total: number): Promise<void>;
  replaceDraft(jobId: string, draft: ImportDraftRecord): Promise<void>;
  markFailure(jobId: string, code: string, retryable: boolean): Promise<void>;
  cancelOwned(userId: string, deviceId: string, jobId: string): Promise<boolean>;
  expireBefore(now: Date): Promise<string[]>;
}
```

Use `SELECT ... FOR UPDATE SKIP LOCKED` inside a short transaction for `claimNext`. Every user-facing lookup must include both `userId` and job ID; artifact download later also includes `deviceId`.

- [ ] **Step 4: Run focused and complete server tests**

```powershell
npm test --prefix server -- --runInBand src/imports/import.repository.spec.ts
npm test --prefix server -- --runInBand
```

Expected: all tests pass.

- [ ] **Step 5: Commit Task 3**

```powershell
git add -- server/src/imports/import.contracts.ts server/src/imports/import.repository.ts server/src/imports/import.repository.spec.ts
git commit -m "feat(server): add import job state machine"
```

## Task 4: Add authenticated resumable upload endpoints

**Files:**

- Create: `server/src/imports/import.dto.ts`
- Create: `server/src/imports/import.service.ts`
- Create: `server/src/imports/import.controller.ts`
- Create: `server/src/imports/import.module.ts`
- Create: `server/src/imports/import.controller.spec.ts`
- Create: `server/src/imports/import.service.spec.ts`
- Modify: `server/src/app.module.ts`
- Modify: `server/src/main.ts`

- [x] **Step 1: Write failing controller and service tests**

Cover unauthenticated rejection, 200MB limit, 4MB part limit, page range 1-20, duplicate idempotent parts, final hash mismatch, and ownership.

```ts
await request(app.getHttpServer()).post('/v1/imports/pdf').send(validCreate).expect(401);
await authenticated().post('/v1/imports/pdf').send({ ...validCreate, pageEnd: 21 }).expect(400);
await authenticated().put(`/v1/imports/pdf/${jobId}/parts/0`).set('X-Part-Sha256', partHash).send(part).expect(204);
await authenticated().post(`/v1/imports/pdf/${jobId}/complete`).send({ partCount: 1, sourceSha256 }).expect(202);
```

- [x] **Step 2: Run focused tests and verify failure**

```powershell
npm test --prefix server -- --runInBand src/imports/import.controller.spec.ts src/imports/import.service.spec.ts
```

Expected: FAIL because the imports module and routes do not exist.

- [x] **Step 3: Implement create, part, complete, status, and cancel**

Use validated DTOs with exact limits:

```ts
export class CreatePdfImportDto {
  @IsString() @Length(1, 255) bankName!: string;
  @IsString() @Length(1, 64) subject!: string;
  @IsInt() @Min(1) pageStart!: number;
  @IsInt() @Min(1) pageEnd!: number;
  @IsInt() @Min(1) @Max(209715200) sourceSize!: number;
  @Matches(/^[a-f0-9]{64}$/) sourceSha256!: string;
}
```

Add raw `application/octet-stream` handling only for the part route, cap the body at 4MB, and preserve the existing JSON validation pipeline for all other routes. Return stable public error codes rather than paths or stack traces.

- [x] **Step 4: Run imports tests, complete server tests, and build**

```powershell
npm test --prefix server -- --runInBand src/imports/import.controller.spec.ts src/imports/import.service.spec.ts
npm test --prefix server -- --runInBand
npm run build --prefix server
```

Expected: tests and TypeScript build pass.

- [x] **Step 5: Commit Task 4**

```powershell
git add -- server/src/imports server/src/app.module.ts server/src/main.ts
git commit -m "feat(server): add resumable PDF uploads"
```

## Task 5: Create the isolated Python worker and job claim loop

**Files:**

- Create: `server/worker/requirements.in`
- Create: `server/worker/requirements-dev.in`
- Create: `server/worker/requirements.txt`
- Create: `server/worker/requirements-dev.txt`
- Create: `server/worker/job_store.py`
- Create: `server/worker/main.py`
- Create: `server/worker/tests/test_job_store.py`
- Create: `server/worker/tests/test_main.py`
- Create: `server/worker/Dockerfile`

- [x] **Step 1: Write failing Python tests**

```python
def test_claim_returns_only_one_queued_job(store):
    first = store.claim_next('worker-1')
    second = store.claim_next('worker-2')
    assert first.status == 'processing'
    assert second is None

def test_retryable_failure_stops_after_two_retries(store):
    store.fail('job-1', 'OCR_FAILED', retryable=True)
    store.fail('job-1', 'OCR_FAILED', retryable=True)
    assert store.get('job-1').status == 'failed'
    assert store.get('job-1').retry_count == 2
```

- [x] **Step 2: Run pytest and verify failure**

From `server/worker` run:

```powershell
python -m pytest -q
```

Expected: FAIL because worker modules are absent.

- [x] **Step 3: Implement one-job worker loop**

`main.py` must have a stoppable loop and no HTTP server:

```python
def run_once(store: JobStore, pipeline: PdfPipeline) -> bool:
    job = store.claim_next(os.environ.get('HOSTNAME', 'ocr-worker'))
    if job is None:
        return False
    try:
        pipeline.process(job)
        return True
    except RetryablePipelineError as exc:
        store.fail(job.id, exc.code, retryable=True)
    except PipelineError as exc:
        store.fail(job.id, exc.code, retryable=False)
    return True
```

Use `mysql-connector-python`, parameterized SQL, UTC timestamps, and environment variables shared only for DB access and import storage. Do not pass JWT or Huawei secrets to the worker.

Create dependency inputs exactly as follows, then generate hashed lock files with `pip-compile --generate-hashes`:

```text
# requirements.in
mysql-connector-python>=9,<10
numpy>=2,<3
opencv-python-headless>=4.10,<5
paddleocr>=3,<4
paddlepaddle>=3,<4
Pillow>=11,<12
pypdfium2>=4,<5
```

```text
# requirements-dev.in
-r requirements.in
pytest>=8,<9
reportlab>=4,<5
```

```powershell
python -m pip install "pip-tools>=7,<8"
python -m piptools compile --generate-hashes server/worker/requirements.in -o server/worker/requirements.txt
python -m piptools compile --generate-hashes server/worker/requirements-dev.in -o server/worker/requirements-dev.txt
```

- [ ] **Step 4: Build and test the worker image**

```powershell
python -m pytest server/worker/tests -q
docker build -f server/worker/Dockerfile -t wrong-question-ocr-worker:test server/worker
docker run --rm --entrypoint python wrong-question-ocr-worker:test -m pytest -q
```

Expected: pytest passes locally and inside the image.

- [ ] **Step 5: Commit Task 5**

```powershell
git add -- server/worker
git commit -m "feat(worker): add isolated OCR job runner"
```

## Task 6: Implement PDF validation, OCR, splitting, and crops

**Files:**

- Create: `server/worker/pdf_pipeline.py`
- Create: `server/worker/question_parser.py`
- Create: `server/worker/tests/fixture_factory.py`
- Create: `server/worker/tests/test_pdf_pipeline.py`
- Create: `server/worker/tests/test_question_parser.py`

- [x] **Step 1: Write fixture-driven failing tests**

```python
def test_scanned_chinese_pdf_produces_reviewable_drafts(pipeline, tmp_path):
    scanned_pdf = build_scanned_pdf(tmp_path / 'scanned.pdf', ['1. 求函数的极限'])
    result = pipeline.process_file(scanned_pdf, page_start=1, page_end=1)
    assert result.questions
    assert all(question.page_start >= 1 for question in result.questions)
    assert all(question.image_artifacts for question in result.questions)

def test_damaged_pdf_is_classified(pipeline, tmp_path):
    damaged_pdf = tmp_path / 'damaged.pdf'
    damaged_pdf.write_bytes(b'%PDF-1.7\ntruncated')
    with pytest.raises(PipelineError) as error:
        pipeline.process_file(damaged_pdf, page_start=1, page_end=1)
    assert error.value.code == 'PDF_INVALID'
```

`fixture_factory.py` must generate text PDFs and scanned-image PDFs at test time with ReportLab and Pillow. Do not commit the user's reference PDF or any copyrighted workbook pages as fixtures.

- [x] **Step 2: Run worker tests and verify failure**

```powershell
python -m pytest server/worker/tests/test_pdf_pipeline.py server/worker/tests/test_question_parser.py -q
```

Expected: FAIL because the pipeline is not implemented.

- [x] **Step 3: Implement bounded PDF processing**

Implement these stages with explicit ownership cleanup:

```python
with pdfium.PdfDocument(source_path) as document:
    validate_page_range(document, page_start, page_end, maximum_pages=20)
    for page_number in range(page_start, page_end + 1):
        bitmap = render_page(document[page_number - 1], max_long_edge=4096)
        lines = ocr.recognize(bitmap)
        parsed = parser.feed(page_number, bitmap, lines)
        store.update_progress(job_id, page_number - page_start + 1, page_end - page_start + 1)
    result = parser.finish()
```

Render one page at a time, release image arrays before moving to the next page, cap the long edge at 4096 pixels, and save crops as JPEG quality 88. Low confidence, missing question text, unclassified types, and formula-heavy lines set `review_required=True` rather than failing the whole job.

The Docker build stage must initialize the Chinese PaddleOCR models into `/opt/ocr-models`; the final runtime image copies that directory and sets the model home to it. Runtime processing is tested with external network disabled so a model download attempt fails the test rather than reaching production.

- [ ] **Step 4: Run worker tests and inspect resource bounds**

```powershell
python -m pytest server/worker/tests -q
docker build -f server/worker/Dockerfile -t wrong-question-ocr-worker:test server/worker
```

Expected: all worker tests pass; Git status contains no generated PDFs and no downloaded OCR model cache.

- [ ] **Step 5: Commit Task 6**

```powershell
git add -- server/worker/pdf_pipeline.py server/worker/question_parser.py server/worker/tests
git commit -m "feat(worker): process PDFs into review drafts"
```

## Task 7: Add draft review, confirmation, device image download, and cleanup

**Files:**

- Modify: `server/src/imports/import.dto.ts`
- Modify: `server/src/imports/import.service.ts`
- Modify: `server/src/imports/import.controller.ts`
- Create: `server/src/imports/import-cleanup.service.ts`
- Create: `server/src/imports/import-cleanup.service.spec.ts`
- Modify: `server/src/imports/import.service.spec.ts`
- Modify: `server/src/imports/import.controller.spec.ts`

- [ ] **Step 1: Write failing authorization and transaction tests**

```ts
await service.downloadArtifact(ownerUser, otherDevice, jobId, artifactId)
  .then(() => fail('expected rejection'), error => expect(error.code).toBe('DEVICE_NOT_OWNER'));
await service.confirm(ownerUser, ownerDevice, jobId, editedDraft);
expect(transaction.commit).toHaveBeenCalledTimes(1);
expect(await repository.jobStatus(jobId)).toBe('confirmed');
await cleanup.expire(new Date('2026-08-27T00:00:00Z'));
expect(storage.deletedKeys()).toEqual(expect.arrayContaining(expiredKeys));
```

- [ ] **Step 2: Run focused tests and verify failure**

```powershell
npm test --prefix server -- --runInBand src/imports/import.service.spec.ts src/imports/import.controller.spec.ts src/imports/import-cleanup.service.spec.ts
```

Expected: FAIL for missing review, confirmation, artifact, and cleanup behavior.

- [ ] **Step 3: Implement review and confirmation endpoints**

`confirm` must validate every draft, write bank and questions in one MySQL transaction, emit the existing sync operations for other devices, and return mappings:

```ts
export interface ConfirmImportResult {
  bankId: string;
  questions: Array<{
    draftQuestionId: string;
    questionId: string;
    images: Array<{ artifactId: string; sha256: string; size: number }>;
  }>;
  expiresAt: string;
}
```

Artifact streaming must verify user ID, device ID, job ID, artifact ID, unexpired state, and exact storage metadata before opening the file. `ack` accepts only artifact IDs returned by the confirmed task, verifies that every required artifact is acknowledged, then deletes all job files and artifact rows.

- [ ] **Step 4: Implement and test TTL cleanup**

Use an injectable clock. Cleanup changes expired nonterminal jobs to `expired`, deletes their storage keys, and removes orphan files only when their direct job directory is a valid UUID under the configured root. A failed unlink remains retryable and is not falsely removed from the database.

Run:

```powershell
npm test --prefix server -- --runInBand src/imports
npm test --prefix server -- --runInBand
npm run build --prefix server
```

Expected: all tests and build pass.

- [ ] **Step 5: Commit Task 7**

```powershell
git add -- server/src/imports
git commit -m "feat(server): confirm imports and deliver device images"
```

## Task 8: Deploy the worker and enforce server resource limits

**Files:**

- Modify: `server/compose.yaml`
- Modify: `server/Caddyfile`
- Modify: `server/.env.example`
- Create: `server/.gitignore`
- Create: `server/src/security/import-deployment.spec.ts`

- [ ] **Step 1: Write failing Compose and Caddy contract tests**

Assert that the worker has no public ports, no Huawei/JWT secrets, a read-only root, dropped capabilities, memory/CPU limits, one replica, and an import volume. Assert that Caddy rejects bodies over 5MB except the authenticated part route handled by API streaming, and that MySQL remains unexposed.

```ts
expect(compose.services['ocr-worker'].ports).toBeUndefined();
expect(compose.services['ocr-worker'].read_only).toBe(true);
expect(compose.services['ocr-worker'].cap_drop).toContain('ALL');
expect(compose.services['ocr-worker'].environment).not.toHaveProperty('HUAWEI_CLIENT_SECRET');
expect(compose.services.mysql.ports).toBeUndefined();
```

- [ ] **Step 2: Run the deployment test and verify failure**

```powershell
npm test --prefix server -- --runInBand src/security/import-deployment.spec.ts
```

Expected: FAIL because `ocr-worker` is not in Compose.

- [ ] **Step 3: Add worker service and restricted volume**

Add:

```yaml
ocr-worker:
  build:
    context: ./worker
  restart: unless-stopped
  read_only: true
  cap_drop: ["ALL"]
  security_opt: ["no-new-privileges:true"]
  tmpfs: ["/tmp:size=256m,noexec,nosuid,nodev"]
  volumes:
    - import_data:/work/imports
  networks: [worker_backend]
  deploy:
    resources:
      limits:
        cpus: "2.0"
        memory: 3072M
```

Mount the same `import_data` volume into API at `/work/imports`; API and worker receive only their required environment variables. Add an internal `worker_backend` network shared only by MySQL and the worker so the worker can reach MySQL but cannot reach the public internet. Keep API on the existing outbound-capable `backend` network because Huawei authorization exchange requires it. Add a disk-watermark health signal without making `/health/ready` fail for read-only text traffic.

- [ ] **Step 4: Validate deployment locally**

```powershell
docker compose -f server/compose.yaml config
npm test --prefix server -- --runInBand src/security/import-deployment.spec.ts
npm test --prefix server -- --runInBand
npm run build --prefix server
```

Expected: Compose parses, deployment contracts pass, server suite and build pass.

- [ ] **Step 5: Commit Task 8**

```powershell
git add -- server/compose.yaml server/Caddyfile server/.env.example server/.gitignore server/src/security/import-deployment.spec.ts
git commit -m "feat(deploy): run bounded OCR worker"
```

## Task 9: Add typed HarmonyOS cloud-import transport

**Files:**

- Create: `entry/src/main/ets/models/CloudImportModels.ets`
- Create: `entry/src/main/ets/services/CloudImportApi.ets`
- Create: `entry/src/main/ets/services/CloudImportService.ets`
- Modify: `entry/src/main/ets/services/ApiHttpClient.ets`
- Create: `entry/src/test/CloudImportApiContracts.test.cjs`
- Modify: `entry/src/test/LocalUnit.test.ets`

- [ ] **Step 1: Write failing upload-state and API contract tests**

Cover 4MB parts, SHA-256 values, retry from the first missing part, one token refresh, cancellation, and no local OCR imports.

```ts
expect(source).toMatch(/const PART_BYTES:\s*number = 4 \* 1024 \* 1024/);
expect(source).toMatch(/X-Part-Sha256/);
expect(source).toMatch(/authorizedBinaryPut/);
expect(source).not.toMatch(/OnDeviceOcrService|PdfImportCoordinator/);
```

- [ ] **Step 2: Run contract tests and verify failure**

```powershell
node entry/src/test/CloudImportApiContracts.test.cjs
```

Expected: FAIL because cloud import transport is absent.

- [ ] **Step 3: Add strict ArkTS models and streaming requests**

Define nominal classes rather than structural `object` values:

```ts
export class CloudImportJob {
  id: string
  status: string
  progressCurrent: number
  progressTotal: number
  errorCode: string
  expiresAt: string
  constructor(id: string, status: string, progressCurrent: number,
    progressTotal: number, errorCode: string, expiresAt: string) {
    this.id = id
    this.status = status
    this.progressCurrent = progressCurrent
    this.progressTotal = progressTotal
    this.errorCode = errorCode
    this.expiresAt = expiresAt
  }
}
```

Extend `ApiHttpClient` with authenticated `PUT application/octet-stream` and binary download methods. Each request must set the private CA path, connect/read timeouts, Bearer token, and exact response code checks. Never log authorization headers, PDF bytes, draft text, or artifact content.

- [ ] **Step 4: Run ArkTS checks, contracts, unit tests, and build**

```powershell
node entry/src/test/CloudImportApiContracts.test.cjs
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon test
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon assembleHap
```

Expected: contract passes and Hvigor reports `BUILD SUCCESSFUL` for tests and HAP.

- [ ] **Step 5: Commit Task 9**

```powershell
git add -- entry/src/main/ets/models/CloudImportModels.ets entry/src/main/ets/services/CloudImportApi.ets entry/src/main/ets/services/CloudImportService.ets entry/src/main/ets/services/ApiHttpClient.ets entry/src/test/CloudImportApiContracts.test.cjs entry/src/test/LocalUnit.test.ets
git commit -m "feat(app): upload PDFs to cloud imports"
```

## Task 10: Convert local storage into an account-scoped read-only cache

**Files:**

- Modify: `entry/src/main/ets/services/DatabaseService.ets`
- Create: `entry/src/main/ets/services/CloudCacheService.ets`
- Create: `entry/src/main/ets/services/DeviceImageStore.ets`
- Create: `entry/src/main/ets/models/CloudCacheModels.ets`
- Modify: `entry/src/main/ets/services/AccountSessionService.ets`
- Create: `entry/src/test/CloudCacheContracts.test.cjs`
- Modify: `entry/src/test/LocalUnit.test.ets`

- [ ] **Step 1: Write failing cache replacement and isolation tests**

```ts
expect(CacheVersionPolicy.shouldReplace('12', '13')).toBe(true)
expect(CacheVersionPolicy.shouldReplace('13', '12')).toBe(false)
expect(DeviceImageScope.key('user-a', 'question-a')).not.toEqual(
  DeviceImageScope.key('user-b', 'question-a'))
```

Contract assertions must require account ID columns, server UUIDs, cache version metadata, image ownership, and transactionally replaced snapshots.

- [ ] **Step 2: Run cache tests and verify failure**

```powershell
node entry/src/test/CloudCacheContracts.test.cjs
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon test
```

Expected: FAIL because read-only cache services are absent.

- [ ] **Step 3: Add schema version 6 cache tables without deleting old tables**

Create `cloud_cache_state(account_id, cursor, update_time)`, `cloud_bank_cache`, `cloud_question_cache`, `cloud_wrong_cache`, and `device_question_image(account_id, question_uuid, image_path, sha256, sort_order)`. Version 5 to 6 migration only creates these tables and indexes. It must not drop or rewrite existing question/image/outbox tables.

`CloudCacheService.replacePage()` writes a downloaded page and cursor in one RDB transaction. `DeviceImageStore` validates paths under the app's account-scoped `question_images/<accountHash>/` directory and never exposes another account's rows.

On logout, `AccountSessionService` deletes only the signed-in account's cloud text-cache rows and cursor after clearing its secure session. It retains `device_question_image` rows and files, but all image queries require the matching account ID so another account on the same device cannot view them.

- [ ] **Step 4: Run cache tests and API 26 build**

```powershell
node entry/src/test/CloudCacheContracts.test.cjs
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon test
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon assembleHap
```

Expected: all tests pass and HAP builds.

- [ ] **Step 5: Commit Task 10**

```powershell
git add -- entry/src/main/ets/services/DatabaseService.ets entry/src/main/ets/services/CloudCacheService.ets entry/src/main/ets/services/DeviceImageStore.ets entry/src/main/ets/models/CloudCacheModels.ets entry/src/main/ets/services/AccountSessionService.ets entry/src/test/CloudCacheContracts.test.cjs entry/src/test/LocalUnit.test.ets
git commit -m "feat(app): add server-authoritative offline cache"
```

## Task 11: Replace the PDF pages with the cloud task flow

**Files:**

- Modify: `entry/src/main/ets/pages/PdfImportSetupPage.ets`
- Modify: `entry/src/main/ets/pages/PdfImportProgressPage.ets`
- Modify: `entry/src/main/ets/pages/PdfImportReviewPage.ets`
- Modify: `entry/src/main/ets/pages/ImportBankPage.ets`
- Modify: `entry/src/main/ets/utils/PdfImportState.ets`
- Create: `entry/src/main/ets/components/CloudImportStatusCard.ets`
- Create: `entry/src/test/CloudImportPageContracts.test.cjs`

- [ ] **Step 1: Write failing page-flow contracts**

Require login and network before starting, resumable upload state, task polling, review drafts from server, artifact download before ACK, explicit expired-image UI, and no imports of device OCR/render services.

```ts
assert.match(progress, /CloudImportService/)
assert.match(review, /downloadArtifacts/)
assert.match(review, /acknowledgeArtifacts/)
assert.doesNotMatch(progress, /OnDeviceOcrService|PdfImportCoordinator|pdfService/)
assert.match(setup, /请先登录华为账号/)
assert.match(progress, /上传中|服务器识别中|等待确认|处理失败/)
```

- [ ] **Step 2: Run the new page contract and verify failure**

```powershell
node entry/src/test/CloudImportPageContracts.test.cjs
```

Expected: FAIL because pages still call the on-device pipeline.

- [ ] **Step 3: Implement the online-only write flow**

`PdfImportSetupPage` validates account, network, bank metadata, and pages. `PdfImportProgressPage` resumes part upload and polls with bounded backoff: 1, 2, 4, then 5 seconds maximum. `PdfImportReviewPage` edits server drafts online, confirms text, downloads each artifact to an account-scoped temporary file, verifies SHA-256 and size, atomically moves it to the device image directory, records the UUID mapping, then ACKs only successfully stored artifacts.

If an artifact expires, keep the confirmed text and show “原题图片已过期，文字仍可使用”. If the page becomes inactive, cancel polling but do not cancel the server task.

- [ ] **Step 4: Run page contracts, ArkTS checks, tests, and build**

```powershell
node entry/src/test/CloudImportPageContracts.test.cjs
Get-ChildItem entry/src/test -Filter '*.test.cjs' | ForEach-Object { node $_.FullName; if ($LASTEXITCODE -ne 0) { throw $_.Name } }
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon test
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon assembleHap
```

Expected: all contracts and tests pass; HAP builds.

- [ ] **Step 5: Commit Task 11**

```powershell
git add -- entry/src/main/ets/pages/PdfImportSetupPage.ets entry/src/main/ets/pages/PdfImportProgressPage.ets entry/src/main/ets/pages/PdfImportReviewPage.ets entry/src/main/ets/pages/ImportBankPage.ets entry/src/main/ets/utils/PdfImportState.ets entry/src/main/ets/components/CloudImportStatusCard.ets entry/src/test/CloudImportPageContracts.test.cjs
git commit -m "feat(app): review cloud-processed PDF imports"
```

## Task 12: Make normal data access server-first and offline read-only

**Files:**

- Create: `entry/src/main/ets/services/CloudQuestionRepository.ets`
- Create: `entry/src/main/ets/services/ConnectivityPolicy.ets`
- Modify: `entry/src/main/ets/pages/BooksPage.ets`
- Modify: `entry/src/main/ets/pages/QuestionListPage.ets`
- Modify: `entry/src/main/ets/pages/QuestionDetailPage.ets`
- Modify: `entry/src/main/ets/pages/EditQuestionPage.ets`
- Modify: `entry/src/main/ets/pages/WrongQuestionsPage.ets`
- Modify: `entry/src/main/ets/pages/WrongQuestionDetailPage.ets`
- Modify: `entry/src/main/ets/pages/HomePage.ets`
- Create: `entry/src/test/ServerFirstContracts.test.cjs`
- Modify: `entry/src/test/LocalUnit.test.ets`

- [ ] **Step 1: Write failing server-first and offline policy tests**

```ts
expect(ConnectivityPolicy.canMutate(true, true)).toBe(true)
expect(ConnectivityPolicy.canMutate(true, false)).toBe(false)
expect(ConnectivityPolicy.canMutate(false, true)).toBe(false)
```

Page contracts require the visible “离线浏览” state, disabled mutations when offline/signed out, server success before cache update, and preservation of cached content on request failure.

- [ ] **Step 2: Run focused tests and verify failure**

```powershell
node entry/src/test/ServerFirstContracts.test.cjs
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon test
```

Expected: FAIL because pages still use local-first mutation services.

- [ ] **Step 3: Implement repository and page policy**

`CloudQuestionRepository` must expose online mutations and cache reads separately:

```ts
export class CloudQuestionRepository {
  static async listCachedBanks(accountId: string): Promise<Array<QuestionBankSummary>>
  static async refresh(accountId: string): Promise<void>
  static async updateQuestion(question: Question): Promise<void>
  static async setWrongState(questionUuid: string, status: string): Promise<void>
}
```

Each mutation obtains an access token and sends exactly one synchronous operation to the existing `/v1/sync/push` endpoint. Only after the server returns the authoritative operation does it apply the returned version to cache and refresh UI. Initial and incremental cache refresh use `/v1/sync/pull` with the account cursor. It never writes a speculative local mutation or outbox row. Pages keep cached data visible when refresh fails and show a nonblocking offline banner.

- [ ] **Step 4: Run full client verification**

```powershell
Get-ChildItem entry/src/test -Filter '*.test.cjs' | ForEach-Object { node $_.FullName; if ($LASTEXITCODE -ne 0) { throw $_.Name } }
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon test
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon assembleHap
```

Expected: client contracts, ArkTS tests, and HAP build pass.

- [ ] **Step 5: Commit Task 12**

```powershell
git add -- entry/src/main/ets/services/CloudQuestionRepository.ets entry/src/main/ets/services/ConnectivityPolicy.ets entry/src/main/ets/pages entry/src/test/ServerFirstContracts.test.cjs entry/src/test/LocalUnit.test.ets
git commit -m "feat(app): enforce offline read-only cloud data"
```

## Task 13: Migrate existing local text and rebind images safely

**Files:**

- Create: `entry/src/main/ets/services/LegacyCloudMigrationService.ets`
- Create: `entry/src/main/ets/models/LegacyMigrationModels.ets`
- Modify: `entry/src/main/ets/services/AppBootstrapService.ets`
- Modify: `entry/src/main/ets/pages/MinePage.ets`
- Create: `entry/src/main/ets/components/LegacyMigrationCard.ets`
- Create: `entry/src/test/LegacyCloudMigrationContracts.test.cjs`
- Modify: `entry/src/test/LocalUnit.test.ets`

- [ ] **Step 1: Write failing migration state tests**

Cover unclaimed, uploading, verifying, completed, and failed states; account binding; idempotent batches; text digest verification; image rebinding; and preservation of old tables/outbox on every failure.

```ts
expect(MigrationPolicy.canClaim('', 'user-a')).toBe(true)
expect(MigrationPolicy.canClaim('user-a', 'user-b')).toBe(false)
expect(MigrationPolicy.canRetireLegacy(true, true, true)).toBe(true)
expect(MigrationPolicy.canRetireLegacy(true, true, false)).toBe(false)
```

- [ ] **Step 2: Run migration tests and verify failure**

```powershell
node entry/src/test/LegacyCloudMigrationContracts.test.cjs
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon test
```

Expected: FAIL because legacy cloud migration is absent.

- [ ] **Step 3: Implement opt-in, resumable migration**

Before upload, show the number of local banks/questions/images and require confirmation that they will bind to the current Huawei account. Upload one bank per request with stable existing sync UUIDs. After server ACK, download the corresponding server snapshot, compare bank/question counts and SHA-256 digests of normalized text, then transactionally populate cloud cache and rebind every existing image path to the returned question UUID.

Store migration state separately from `sync_outbox`. A completed marker requires all three booleans: server acknowledged, cache verified, image mappings committed. Do not delete legacy rows in this task.

- [ ] **Step 4: Run migration and full client tests**

```powershell
node entry/src/test/LegacyCloudMigrationContracts.test.cjs
Get-ChildItem entry/src/test -Filter '*.test.cjs' | ForEach-Object { node $_.FullName; if ($LASTEXITCODE -ne 0) { throw $_.Name } }
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon test
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon assembleHap
```

Expected: all tests and build pass.

- [ ] **Step 5: Commit Task 13**

```powershell
git add -- entry/src/main/ets/services/LegacyCloudMigrationService.ets entry/src/main/ets/models/LegacyMigrationModels.ets entry/src/main/ets/services/AppBootstrapService.ets entry/src/main/ets/pages/MinePage.ets entry/src/main/ets/components/LegacyMigrationCard.ets entry/src/test/LegacyCloudMigrationContracts.test.cjs entry/src/test/LocalUnit.test.ets
git commit -m "feat(app): migrate local text to cloud safely"
```

## Task 14: Retire device OCR and old outbox only after cutover verification

**Files:**

- Modify: `entry/src/main/ets/services/AppBootstrapService.ets`
- Modify: `entry/src/main/ets/services/CloudSyncService.ets`
- Modify: `entry/src/main/ets/services/SyncBootstrapService.ets`
- Modify: `entry/src/main/ets/services/QuestionBankService.ets`
- Modify: `entry/src/main/ets/services/WrongQuestionService.ets`
- Delete after zero references: `entry/src/main/ets/services/OnDeviceOcrService.ets`
- Delete after zero references: `entry/src/main/ets/services/PdfImportCoordinator.ets`
- Create: `entry/src/test/CloudCutoverContracts.test.cjs`
- Modify: `entry/src/test/PdfImportContracts.test.cjs`

- [ ] **Step 1: Write a failing cutover contract**

Require no production references to on-device OCR/PDF rendering, no new outbox enqueue from business writes, preserved legacy tables, and a completed-migration gate.

```ts
assert.doesNotMatch(productionSources, /OnDeviceOcrService|PdfImportCoordinator|recognizeText/)
assert.doesNotMatch(questionBankService, /SyncOutboxService\.enqueue/)
assert.match(databaseService, /CREATE TABLE IF NOT EXISTS sync_outbox/)
assert.match(appBootstrap, /LegacyCloudMigrationService/)
```

- [ ] **Step 2: Run cutover contracts and verify failure**

```powershell
node entry/src/test/CloudCutoverContracts.test.cjs
```

Expected: FAIL while device OCR and outbox writes remain.

- [ ] **Step 3: Remove active usage, not recovery data**

Route all normal writes through `CloudQuestionRepository`. Stop calling `SyncBootstrapService.enqueueLegacyLocalText` for accounts using the server-first model. Delete OCR/coordinator source only after `rg` confirms zero production imports. Keep schema-v5 legacy tables and image cleanup services for one release so migration recovery remains possible.

- [ ] **Step 4: Run complete client verification**

```powershell
rg -n "OnDeviceOcrService|PdfImportCoordinator|recognizeText" entry/src/main/ets
node entry/src/test/CloudCutoverContracts.test.cjs
Get-ChildItem entry/src/test -Filter '*.test.cjs' | ForEach-Object { node $_.FullName; if ($LASTEXITCODE -ne 0) { throw $_.Name } }
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon test
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon assembleHap
```

Expected: `rg` has no production matches, all contracts pass, and HAP builds.

- [ ] **Step 5: Commit Task 14**

```powershell
git add -A -- entry/src/main/ets entry/src/test
git commit -m "refactor(app): complete server-first cutover"
```

## Task 15: Full regression, server deployment, and device acceptance

**Files:**

- Modify: `项目开发进度与待办.md`
- Modify: `server/README.md` if created during implementation
- Modify: `docs/superpowers/plans/2026-08-26-server-pdf-processing-cloud-text-plan.md` checkboxes only

- [ ] **Step 1: Run all automated verification from a clean command session**

```powershell
$contracts = Get-ChildItem entry/src/test -Filter '*.test.cjs'
foreach ($contract in $contracts) {
  node $contract.FullName
  if ($LASTEXITCODE -ne 0) { throw "Contract failed: $($contract.Name)" }
}
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon test
if ($LASTEXITCODE -ne 0) { throw 'Hvigor test failed' }
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon assembleHap
if ($LASTEXITCODE -ne 0) { throw 'HAP build failed' }
npm test --prefix server -- --runInBand
if ($LASTEXITCODE -ne 0) { throw 'Server tests failed' }
npm run build --prefix server
if ($LASTEXITCODE -ne 0) { throw 'Server build failed' }
python -m pytest server/worker/tests -q
if ($LASTEXITCODE -ne 0) { throw 'Worker tests failed' }
docker compose -f server/compose.yaml config
if ($LASTEXITCODE -ne 0) { throw 'Compose validation failed' }
```

Expected: every command exits 0.

- [ ] **Step 2: Verify the target Ubuntu server before deployment**

Run on the server:

```bash
nproc
free -h
df -h /opt/wqc
docker version
docker compose version
```

Acceptance floor: at least 2 CPU cores, 4GB RAM or RAM plus configured swap, and 15GB free under `/opt/wqc`. If below the floor, do not start OCR jobs; keep existing API available and increase server resources first.

- [ ] **Step 3: Deploy with a recoverable database and file backup**

On the server, first create a logical MySQL backup using the existing backup account and copy the current `/opt/wqc` configuration to a timestamped protected directory without copying secrets into Git. Upload the new source, add only the new import environment values to `/opt/wqc/.env`, then run:

```bash
cd /opt/wqc
docker compose config --quiet
docker compose build api migrate ocr-worker
docker compose up -d mysql
docker compose run --rm migrate
docker compose up -d api ocr-worker caddy backup
docker compose ps -a
```

Expected: MySQL and API healthy, migration exits 0, OCR worker remains running with no public port, Caddy and backup run normally.

- [ ] **Step 4: Perform authenticated server smoke tests**

Use a newly obtained test-device access token without printing it. Verify create, one-part fixture upload, complete, progress, review, confirm, image download, ACK, and post-ACK artifact rejection. Query MySQL to confirm formal text remains while artifact rows and files are removed.

Expected: status reaches `confirmed`; downloaded image hash matches; ACK removes temporary files; a second device receives 403 for the artifact.

- [ ] **Step 5: Perform HarmonyOS device acceptance in required order**

```powershell
& 'D:\Program Files\Huawei\DevEco Studio1\sdk\default\openharmony\toolchains\hdc.exe' list targets
& 'D:\Program Files\Huawei\DevEco Studio1\sdk\default\openharmony\toolchains\hdc.exe' install -r 'G:\code\openHarmony\wrong_question_collection\entry\build\default\outputs\default\entry-default-signed.hap'
& 'D:\Program Files\Huawei\DevEco Studio1\sdk\default\openharmony\toolchains\hdc.exe' shell aa start -a EntryAbility -b com.gfs.wrongquestion
```

Verify: login, resumable upload, background return, review edits, image download, offline read-only pages, disabled offline writes, same-account relogin, different-account isolation, and two-device text/image behavior.

- [ ] **Step 6: Run the 24-hour cleanup and disk-pressure acceptance tests**

Use an injectable clock or a test-only short TTL in an isolated deployment. Confirm expired artifacts are unavailable, formal text remains, orphan cleanup stays inside the import volume, and the API rejects new imports with `SERVER_STORAGE_PRESSURE` while health/text reads stay available.

- [ ] **Step 7: Update progress documentation with actual evidence**

Record exact passing test counts, build outputs, server container states, measured OCR duration/memory/disk use, device IDs used for acceptance, and any unverified items. Do not mark two-device or 24-hour cleanup complete without observed evidence.

- [ ] **Step 8: Final security and diff checks**

```powershell
git diff --check
git status --short
git diff --stat
rg -l "HUAWEI_CLIENT_SECRET|JWT_ACCESS_SECRET|JWT_REFRESH_SECRET|MYSQL_ROOT_PASSWORD" entry/src/main server/src server/worker
```

Expected: diff check passes; no `.env`, private key, PDF, image, model cache, backup, or signing secret is staged; production client code contains no server secret.

- [ ] **Step 9: Commit verified documentation only**

```powershell
git add -- 项目开发进度与待办.md docs/superpowers/plans/2026-08-26-server-pdf-processing-cloud-text-plan.md
git commit -m "docs: record cloud import verification"
```
