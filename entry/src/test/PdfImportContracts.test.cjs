const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')

function extractMethod(source, signature) {
  const start = source.indexOf(signature)
  assert.notEqual(start, -1, 'missing method ' + signature)
  const openingBrace = source.indexOf('{', start)
  assert.notEqual(openingBrace, -1, 'missing method body ' + signature)
  let depth = 0
  for (let index = openingBrace; index < source.length; index++) {
    if (source[index] === '{') {
      depth += 1
    } else if (source[index] === '}') {
      depth -= 1
      if (depth === 0) {
        return source.slice(start, index + 1)
      }
    }
  }
  assert.fail('unterminated method ' + signature)
}

function assertOrdered(source, fragments) {
  let previousIndex = -1
  for (const fragment of fragments) {
    const index = source.indexOf(fragment, previousIndex + 1)
    assert.notEqual(index, -1, 'missing fragment ' + fragment)
    assert.ok(index > previousIndex, 'out of order fragment ' + fragment)
    previousIndex = index
  }
}

test('current schema contains question image storage and durable cleanup debt', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/DatabaseService.ets', 'utf8')
  assert.match(source, /SCHEMA_VERSION:\s*number\s*=\s*5/)
  assert.match(source, /CREATE TABLE IF NOT EXISTS question_image/)
  assert.match(source, /CREATE TABLE IF NOT EXISTS question_image_cleanup_debt/)
  assert.match(source, /path TEXT PRIMARY KEY/)
  assert.match(source, /create_time INTEGER NOT NULL/)
  assert.match(source, /source_page_start/)
  assert.match(source, /review_state/)
})

test('version one migration probes columns and conditionally repairs partial migrations', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/DatabaseService.ets', 'utf8')
  const migration = extractMethod(source, 'private static async migrateVersionOne')
  assert.match(migration, /createTransaction\(SCHEMA_TRANSACTION_OPTIONS\)/)
  assert.match(migration, /transaction\.querySql\('PRAGMA table_info\(question\)'\)/)
  assert.match(migration, /finally\s*{[\s\S]*?\.close\(\)/)
  assert.match(migration, /columnName === 'source_page_start'[\s\S]*hasSourcePageStart = true/)
  assert.match(migration, /columnName === 'source_page_end'[\s\S]*hasSourcePageEnd = true/)
  assert.match(migration, /columnName === 'review_state'[\s\S]*hasReviewState = true/)
  assertOrdered(migration, [
    'if (!hasSourcePageStart)',
    'ALTER TABLE question ADD COLUMN source_page_start',
    'if (!hasSourcePageEnd)',
    'ALTER TABLE question ADD COLUMN source_page_end',
    'if (!hasReviewState)',
    'ALTER TABLE question ADD COLUMN review_state',
    'await transaction.execute(CREATE_QUESTION_IMAGE)',
    'await transaction.execute(CREATE_QUESTION_IMAGE_INDEX)',
    'await transaction.commit()'
  ])
  assert.match(migration, /catch \(err\)[\s\S]*await transaction\.rollback\(\)/)
  assert.doesNotMatch(migration, /store\.version\s*=/)

  const open = extractMethod(source, 'private static async open')
  const versionOneBranch = open.slice(open.indexOf('} else if (version === 1)'))
  assertOrdered(versionOneBranch, [
    'await DatabaseService.migrateVersionOne(store)',
    'await DatabaseService.migrateVersionTwo(store)',
    'await DatabaseService.migrateVersionThree(store)',
    'store.version = SCHEMA_VERSION'
  ])
  assert.match(open,
    /version === 2[\s\S]*await DatabaseService\.migrateVersionTwo\(store\)[\s\S]*migrateVersionThree\(store\)/)
  const versionTwoMigration = extractMethod(source, 'private static async migrateVersionTwo')
  assert.match(versionTwoMigration, /createTransaction\(SCHEMA_TRANSACTION_OPTIONS\)/)
  assert.match(versionTwoMigration, /transaction\.execute\(CREATE_QUESTION_IMAGE_CLEANUP_DEBT\)/)
  assert.match(versionTwoMigration, /await transaction\.commit\(\)/)
  assert.match(versionTwoMigration, /catch \(err\)[\s\S]*await transaction\.rollback\(\)/)
})

test('import persistence snapshots inputs before awaiting and separates commit from object mutation', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionBankService.ets', 'utf8')
  const method = extractMethod(source, 'static async saveImportedBank')
  assert.match(source, /class ImportedBankSnapshot/)
  assert.match(source, /class ImportedQuestionSnapshot/)
  assert.match(source, /class ImportedImageSnapshot/)
  const snapshotFactory = extractMethod(source, 'private static createImportSnapshot')
  assert.match(snapshotFactory, /bank\.questions\.slice\(\)/)
  assert.match(snapshotFactory, /sourceQuestion\.options\.slice\(\)/)
  assert.match(snapshotFactory, /sourceQuestion\.images\.slice\(\)/)
  assert.match(snapshotFactory, /new ImportedQuestionSnapshot/)
  assert.match(snapshotFactory, /new ImportedImageSnapshot/)
  const snapshotCreation = method.indexOf('QuestionBankService.createImportSnapshot')
  assert.ok(snapshotCreation < method.indexOf('await '), 'snapshot must precede the first await')
  assertOrdered(method, [
    'QuestionBankService.createImportSnapshot',
    'await store.createTransaction()',
    'bank_name: snapshot.bankName',
    'type: questionSnapshot.type',
    "transaction.insert('question_image'",
    'await transaction.commit()',
    'committed = true',
    'if (!committed)',
    'questionSnapshot.source.id = questionSnapshot.storedQuestionId',
    'snapshot.source.id = snapshot.bankId'
  ])
  const committedBoundary = method.indexOf('if (!committed)')
  const transactionPhase = method.slice(method.indexOf('await store.createTransaction()'), committedBoundary)
  assert.doesNotMatch(transactionPhase, /\bbank\.|questionSnapshot\.source\.|imageSnapshot\.source\./)
  assert.doesNotMatch(method.slice(committedBoundary), /transaction\.rollback\(\)/)
  assert.doesNotMatch(method.slice(0, committedBoundary), /questionSnapshot\.source\.id\s*=/)
})

test('question image reads are ordered, mapped, and closed in method scope', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionBankService.ets', 'utf8')
  const imageQuery = extractMethod(source, 'private static async listQuestionImages')
  assert.match(imageQuery, /ORDER BY sort_order ASC, rowid ASC/)
  assert.match(imageQuery, /new QuestionImage\(/)
  assert.match(imageQuery, /finally\s*{[\s\S]*resultSet\.close\(\)/)

  const questionDetail = extractMethod(source, 'static async getQuestion')
  assertOrdered(questionDetail, [
    'resultSet.close()',
    'QuestionBankService.listQuestionImages'
  ])
})

test('update and delete methods keep their exact storage boundaries', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionBankService.ets', 'utf8')
  const update = extractMethod(source, 'static async updateQuestion')
  assert.match(update, /review_state: storedReviewState/)
  assert.match(update, /predicates\.equalTo\('id', question\.id\)/)
  assert.match(update, /if \(changedRows !== 1\)/)
  assert.doesNotMatch(update, /bank_id:|source_page_start:|source_page_end:|question_image|\.images/)

  const deletion = extractMethod(source, 'static async deleteBank')
  assertOrdered(deletion, [
    'await store.createTransaction()',
    'SELECT qi.image_path',
    'imageResultSet.close()',
    'INSERT OR IGNORE INTO question_image_cleanup_debt',
    'DELETE FROM question_image',
    'DELETE FROM wrong_question',
    'DELETE FROM question WHERE bank_id',
    'DELETE FROM question_bank',
    'await transaction.commit()',
    'return imagePaths'
  ])
  assert.match(deletion, /catch \(err\)[\s\S]*await transaction\.rollback\(\)/)
})

test('pdf selection stages one validated file through bounded streaming io', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/PdfImportService.ets', 'utf8')
  const selectPdf = extractMethod(source, 'static async selectPdf')
  assert.match(selectPdf, /new picker\.DocumentViewPicker\(context\)/)
  assert.match(selectPdf, /fileSuffixFilters\s*=\s*\['PDF文件\|\.pdf'\]/)
  assert.match(selectPdf, /maxSelectNumber\s*=\s*1/)
  assert.match(selectPdf, /PdfImportValidator\.validateFileSize\(fileInfo\.size\)/)
  assert.match(selectPdf, /64 \* 1024/)
  assert.match(selectPdf, /let totalCopied:\s*number\s*=\s*0/)
  assert.match(selectPdf,
    /Number\.isFinite\(bytesRead\)[\s\S]*Number\.isInteger\(bytesRead\)[\s\S]*bytesRead < 0[\s\S]*bytesRead > buffer\.byteLength/)
  assert.match(selectPdf,
    /const nextTotal:\s*number\s*=\s*totalCopied \+ bytesRead[\s\S]*Number\.isSafeInteger\(nextTotal\)[\s\S]*PdfImportLimits\.MAX_FILE_BYTES/)
  assertOrdered(selectPdf, [
    'const bytesRead: number = await fs.read',
    'const nextTotal: number = totalCopied + bytesRead',
    'if (!Number.isSafeInteger(nextTotal)',
    'while (writtenBytes < bytesRead)',
    'totalCopied = nextTotal'
  ])
  assert.match(selectPdf,
    /if \(totalCopied <= 0 \|\| totalCopied !== fileInfo\.size\)[\s\S]*读取期间发生变化/)
  assert.match(selectPdf, /const stagedInfo:\s*fs\.Stat\s*=\s*await fs\.lstat\(tempPath\)/)
  assert.match(selectPdf, /stagedInfo\.isSymbolicLink\(\) \|\| !stagedInfo\.isFile\(\)/)
  assert.match(selectPdf, /fs\.OpenMode\.NOFOLLOW/)
  assert.match(selectPdf,
    /PdfImportValidator\.validateFileSize\(stagedInfo\.size\)[\s\S]*stagedInfo\.size !== totalCopied/)
  assert.match(selectPdf, /while \(writtenBytes < bytesRead\)/)
  assert.match(selectPdf, /fs\.read\(/)
  assert.match(selectPdf, /fs\.write\(/)
  assert.match(selectPdf, /new pdfService\.PdfDocument\(\)/)
  assert.match(selectPdf, /pdfDocument\.isEncrypted\(tempPath\)/)
  assert.match(selectPdf, /pdfDocument\.loadDocument\(tempPath\)/)
  assert.match(selectPdf, /pdfService\.ParseResult\.PARSE_SUCCESS/)
  assert.match(selectPdf, /pdfDocument\.getPageCount\(\)/)
  assert.match(selectPdf,
    /new PdfFileSelection\(tempPath, fileName, totalCopied, pageCount,[\s\S]*?1, Math\.min\(20, pageCount\)\)/)
  assert.match(selectPdf, /finally\s*{[\s\S]*pdfDocument\.releaseDocument\(\)/)
  assert.match(selectPdf, /finally\s*{[\s\S]*fs\.close\(targetFile\)/)
  assert.match(selectPdf, /finally\s*{[\s\S]*fs\.close\(sourceFile\)/)
  assert.match(selectPdf, /PdfImportService\.cleanupFailedTemporaryPdf\(context\.cacheDir, tempPath\)/)
  assert.doesNotMatch(selectPdf, /new Uint8Array\s*\(\s*(?:fileInfo\.size|fileSize)\s*\)/)
  assert.doesNotMatch(selectPdf, /new ArrayBuffer\s*\(\s*(?:fileInfo\.size|fileSize)\s*\)/)
})

test('temporary pdf cleanup requires exact staged ownership and unregisters only after safe outcomes', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/PdfImportService.ets', 'utf8')
  const selectPdf = extractMethod(source, 'static async selectPdf')
  const removal = extractMethod(source, 'static async removeTemporaryPdf')
  const register = extractMethod(source, 'private static registerStagedPath')
  const unregister = extractMethod(source, 'private static unregisterStagedPath')
  const registerOrphan = extractMethod(source, 'private static registerOrphanPath')
  const unregisterOrphan = extractMethod(source, 'private static unregisterOrphanPath')
  const pathCheck = extractMethod(source, 'private static isDirectTemporaryPdfPath')
  assert.match(source, /private static readonly stagedPaths:\s*Array<string>\s*=\s*new Array<string>\(\)/)
  assert.match(source, /private static readonly stagedCacheDirs:\s*Array<string>\s*=\s*new Array<string>\(\)/)
  assert.match(source, /private static readonly orphanPaths:\s*Array<string>\s*=\s*new Array<string>\(\)/)
  assert.match(source, /private static readonly orphanCacheDirs:\s*Array<string>\s*=\s*new Array<string>\(\)/)
  assert.match(selectPdf, /let candidate:\s*PdfFileSelection \| null\s*=\s*null/)
  assertOrdered(selectPdf, [
    'pageCount = pdfDocument.getPageCount()',
    'if (pageCount <= 0)',
    'candidate = new PdfFileSelection',
    'await fs.close(sourceFile)',
    'PdfImportService.registerStagedPath(candidate.uri, context.cacheDir)',
    'return candidate'
  ])
  const sourceOpenIndex = selectPdf.indexOf('const sourceFile: fs.File = await fs.open')
  const sourceCloseIndex = selectPdf.indexOf('await fs.close(sourceFile)')
  const activeRegisterIndex = selectPdf.indexOf('PdfImportService.registerStagedPath')
  const successReturnIndex = selectPdf.indexOf('return candidate')
  assert.ok(sourceOpenIndex >= 0, 'source open must exist')
  assert.ok(sourceOpenIndex < sourceCloseIndex, 'source close must follow source open')
  assert.ok(sourceCloseIndex < activeRegisterIndex, 'active registration must follow successful source close')
  assert.ok(activeRegisterIndex < successReturnIndex, 'successful return must follow active registration')
  const sourceOwnership = selectPdf.slice(sourceOpenIndex, sourceCloseIndex)
  assert.match(sourceOwnership, /candidate = new PdfFileSelection/)
  assert.doesNotMatch(sourceOwnership, /registerStagedPath|return candidate/)
  assert.equal((selectPdf.match(/PdfImportService\.registerStagedPath\(candidate\.uri, context\.cacheDir\)/g) || []).length, 1)
  assert.doesNotMatch(selectPdf, /registerOrphanPath/)
  assert.match(register, /isDirectTemporaryPdfPath\(cacheDir, path\)/)
  assert.match(register, /stagedPaths\.push\(path\)[\s\S]*stagedCacheDirs\.push\(cacheDir\)/)
  assert.match(unregister, /const index: number = PdfImportService\.stagedPaths\.indexOf\(path\)/)
  assert.match(unregister, /stagedPaths\.splice\(index, 1\)[\s\S]*stagedCacheDirs\.splice\(index, 1\)/)
  assertOrdered(removal, [
    'PdfImportService.registeredCacheDir(path)',
    'PdfImportService.isDirectTemporaryPdfPath(cacheDir, path)',
    'PdfImportService.validateExistingTemporaryPdf(cacheDir, path)',
    'await fs.unlink(path)',
    'PdfImportService.unregisterStagedPath(path)',
    'PdfImportService.unregisterOrphanPath(path)'
  ])
  const cleanupFailure = removal.slice(removal.indexOf('} catch (err)'))
  assert.doesNotMatch(cleanupFailure, /unregisterStagedPath/)
  const failedCleanup = extractMethod(source, 'private static async cleanupFailedTemporaryPdf')
  const selectionFailure = selectPdf.slice(selectPdf.indexOf('} catch (err)'))
  assertOrdered(selectionFailure, [
    'PdfImportService.unregisterStagedPath(tempPath)',
    'await PdfImportService.cleanupFailedTemporaryPdf(context.cacheDir, tempPath)'
  ])
  assert.match(selectionFailure, /await PdfImportService\.cleanupFailedTemporaryPdf\(context\.cacheDir, tempPath\)/)
  assert.match(selectionFailure, /临时文件清理失败/)
  assert.doesNotMatch(selectPdf, /fs\.unlink\(tempPath\)/)
  assert.doesNotMatch(selectionFailure, /removeTemporaryPdf\(tempPath\)/)
  assert.match(failedCleanup, /validateExistingTemporaryPdf\(cacheDir, path\)/)
  assertOrdered(failedCleanup, [
    'await fs.unlink(path)',
    '} catch (err)',
    'PdfImportService.registerOrphanPath(path, cacheDir)'
  ])
  assert.doesNotMatch(failedCleanup, /registerStagedPath|unregisterStagedPath/)
  const failedCleanupCatch = failedCleanup.slice(failedCleanup.indexOf('} catch (err)'))
  assert.match(failedCleanupCatch, /throw err|throw new Error/)
  assert.match(registerOrphan, /isDirectTemporaryPdfPath\(cacheDir, path\)/)
  assert.match(registerOrphan, /orphanPaths\.push\(path\)[\s\S]*orphanCacheDirs\.push\(cacheDir\)/)
  assert.match(unregisterOrphan, /const index: number = PdfImportService\.orphanPaths\.indexOf\(path\)/)
  assert.match(unregisterOrphan, /orphanPaths\.splice\(index, 1\)[\s\S]*orphanCacheDirs\.splice\(index, 1\)/)
  assert.match(pathCheck, /PdfImportService\.isTemporaryPdfName\(name\)/)
})

test('pdf selection serializes picker work and removes only direct unregistered stale cache files', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/PdfImportService.ets', 'utf8')
  const selectPdf = extractMethod(source, 'static async selectPdf')
  const staleCleanup = extractMethod(source, 'private static async cleanupStalePdfs')
  const orphanPrune = extractMethod(source, 'private static async pruneMissingOrphanPaths')
  const nameCheck = extractMethod(source, 'private static isTemporaryPdfName')
  assert.match(source, /private static selectionInProgress:\s*boolean\s*=\s*false/)
  assert.match(selectPdf,
    /if \(PdfImportService\.selectionInProgress\)[\s\S]*throw new Error\([\s\S]*PdfImportService\.selectionInProgress = true/)
  assertOrdered(selectPdf, [
    'PdfImportService.selectionInProgress = true',
    'await PdfImportService.cleanupStalePdfs(context.cacheDir)',
    'new picker.DocumentViewPicker(context)'
  ])
  assert.match(selectPdf,
    /PdfImportService\.selectionInProgress = true[\s\S]*try\s*{[\s\S]*finally\s*{\s*PdfImportService\.selectionInProgress = false\s*}\s*}$/)

  assert.match(staleCleanup, /const options:\s*ListFileOptions\s*=\s*{\s*recursion:\s*false\s*}/)
  assertOrdered(staleCleanup, [
    'await PdfImportService.pruneMissingOrphanPaths(cacheDir)',
    'await fs.listFile(cacheDir, options)'
  ])
  assert.match(staleCleanup, /let names:\s*Array<string>[\s\S]*names = await fs\.listFile\(cacheDir, options\)/)
  assertOrdered(staleCleanup, [
    'for (const name of names)',
    'PdfImportService.isTemporaryPdfName(name)',
    "const path: string = cacheDir + '/' + name",
    'PdfImportService.stagedPaths.indexOf(path) >= 0',
    'await PdfImportService.lstatIfPresent(path)',
    'isFile()',
    'await fs.unlink(path)'
  ])
  const candidateSkip = staleCleanup.slice(staleCleanup.indexOf('for (const name of names)'),
    staleCleanup.indexOf('const candidateInfo: fs.Stat | null'))
  assert.match(candidateSkip,
    /if \(PdfImportService\.stagedPaths\.indexOf\(path\) >= 0\)\s*{\s*continue\s*}/)
  assert.doesNotMatch(candidateSkip, /orphanPaths|OrphanPath/)
  assert.match(staleCleanup, /candidateInfo === null[\s\S]*unregisterOrphanPath\(path\)[\s\S]*continue/)
  assert.match(staleCleanup,
    /if \(candidateInfo\.isSymbolicLink\(\) \|\| !candidateInfo\.isFile\(\)\)\s*{\s*PdfImportService\.unregisterOrphanPath\(path\)\s*continue\s*}/)
  assert.match(staleCleanup,
    /await fs\.unlink\(path\)\s*PdfImportService\.unregisterOrphanPath\(path\)/)
  assert.match(staleCleanup,
    /catch \(cleanupErr\)\s*{\s*PdfImportService\.registerOrphanPath\(path, cacheDir\)[\s\S]*continue\s*}/)
  assert.doesNotMatch(staleCleanup,
    /if \(PdfImportService\.orphanPaths\.indexOf\(path\) >= 0\)\s*{\s*continue\s*}/)
  assert.doesNotMatch(staleCleanup, /recursion:\s*true|listFile\(path|removeTemporaryPdf/)
  assert.match(staleCleanup, /fs\.listFile\(cacheDir, options\)[\s\S]*catch \(err\)[\s\S]*遗留临时文件清理失败/)
  assert.match(orphanPrune, /const cachePrefix:\s*string\s*=\s*cacheDir \+ '\/'/)
  assert.match(orphanPrune, /PdfImportService\.stagedPaths\.indexOf\(path\) >= 0[\s\S]*continue/)
  assert.match(orphanPrune, /path\.startsWith\(cachePrefix\)/)
  assert.match(orphanPrune, /PdfImportService\.isTemporaryPdfName\(name\)/)
  assert.match(orphanPrune,
    /lstatIfPresent\(path\)[\s\S]*PdfImportService\.unregisterOrphanPath\(path\)/)
  assert.match(nameCheck, /const prefix:\s*string\s*=\s*'staged_pdf_'/)
  assert.match(nameCheck, /const suffix:\s*string\s*=\s*'\.pdf'/)
  assert.match(nameCheck, /name\.startsWith\(prefix\)/)
  assert.match(nameCheck, /name\.endsWith\(suffix\)/)
  assert.match(nameCheck, /name\.charCodeAt\(index\)/)
})

test('on device OCR initializes once, recognizes typed lines, and releases once', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/OnDeviceOcrService.ets', 'utf8')
  assert.match(source, /from '@kit\.CoreVisionKit'/)
  assert.match(source, /from '@kit\.ImageKit'/)
  const initialize = extractMethod(source, 'async initialize')
  const recognize = extractMethod(source, 'async recognize')
  const release = extractMethod(source, 'async release')
  assert.match(source, /from '..\/utils\/OcrLifecycleState'/)
  assert.match(source, /private static instance:\s*OnDeviceOcrService\s*=\s*new OnDeviceOcrService\(\)/)
  assert.match(source, /private constructor\(\)/)
  assert.match(source, /static shared\(\): OnDeviceOcrService/)
  assert.match(source, /private static initializePromise:\s*Promise<void> \| null/)
  assert.match(source, /private static releasePromise:\s*Promise<void> \| null/)
  assertOrdered(initialize, [
    'this.lifecycle.currentState()',
    "state === 'initializing'",
    'await pendingInitialization',
    'this.lifecycle.requireReady()',
    "state === 'releasing'",
    'await pendingRelease',
    'continue',
    'this.lifecycle.startInitialization()',
    'OnDeviceOcrService.initializePromise = transition',
    'await transition',
    'this.lifecycle.requireReady()'
  ])
  assertOrdered(recognize, [
    'await this.waitUntilReady()',
    'const operation: OcrRecognitionOperation = this.lifecycle.beginRecognition()',
    'await textRecognition.recognizeText(visionInfo, configuration)',
    'finally',
    'operation.complete()'
  ])
  assert.match(recognize, /const visionInfo:\s*textRecognition\.VisionInfo/)
  assert.match(recognize, /const configuration:\s*textRecognition\.TextRecognitionConfiguration/)
  assert.match(recognize, /isDirectionDetectionSupported:\s*true/)
  assertOrdered(recognize, [
    'const blocks: Array<textRecognition.TextBlock>',
    'const line: textRecognition.TextLine',
    'line.value.trim()',
    'line.cornerPoints.length',
    'Number.isFinite',
    'new OcrLine'
  ])
  assertOrdered(release, [
    'this.lifecycle.currentState()',
    "state === 'initializing'",
    'await pendingInitialization',
    'continue',
    "state === 'releasing'",
    'await pendingRelease',
    'this.lifecycle.requireIdle()',
    'const transition: Promise<void> = this.performRelease()',
    'OnDeviceOcrService.releasePromise = transition',
    'await transition'
  ])
  const platformInitialize = extractMethod(source, 'private async performInitialize')
  assert.match(platformInitialize,
    /await textRecognition\.init\(\)[\s\S]*finishInitialization\(true\)[\s\S]*catch \(err\)[\s\S]*finishInitialization\(false\)/)
  const platformRelease = extractMethod(source, 'private async performRelease')
  assert.match(platformRelease,
    /await this\.lifecycle\.beginRelease\(\)[\s\S]*await textRecognition\.release\(\)[\s\S]*finishRelease\(true\)[\s\S]*catch \(err\)[\s\S]*finishRelease\(false\)/)
})

test('question crop converts coordinates directly and owns every file and image resource', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  assert.match(source, /from '@kit\.PDFKit'/)
  assert.match(source, /from '@kit\.ImageKit'/)
  const saveCrop = extractMethod(source, 'static async saveCrop')
  assert.match(saveCrop, /fullImageInfo:\s*image\.ImageInfo/)
  assert.match(saveCrop, /page:\s*pdfService\.PdfPage/)
  assertOrdered(saveCrop, [
    "QuestionImageService.validateSafeIdentifier(taskId",
    "QuestionImageService.validateSafeIdentifier(draftId",
    'const scaleX: number = pageWidth / fullImageWidth',
    'const scaleY: number = pageHeight / fullImageHeight',
    'matrix.x = crop.left * scaleX',
    'matrix.y = pageHeight - crop.bottom * scaleY',
    'matrix.width = (crop.right - crop.left) * scaleX',
    'matrix.height = (crop.bottom - crop.top) * scaleY',
    'matrix.rotate = 0',
    'const sourceWidth: number = crop.right - crop.left',
    'const sourceHeight: number = crop.bottom - crop.top',
    'PdfCropMath.calculate(sourceWidth, sourceHeight)',
    'page.getAreaPixelMapWithOptions',
    'quality: PdfImportLimits.JPEG_QUALITY',
    'await packer.packToFile',
    'await fs.moveFile(tempPath, targetPath, 1)',
    'ownership.markMoved()'
  ])
  assert.doesNotMatch(saveCrop, /safeFilePart/)
  assert.match(saveCrop, /const tempPath:[\s\S]*new ImageWriteOwnership\(tempPath, targetPath\)/)
  assert.match(saveCrop, /await fs\.open\(tempPath,/)
  assert.doesNotMatch(saveCrop, /fs\.open\(targetPath/)
  assert.match(saveCrop,
    /finally\s*{[\s\S]*const fileToClose:\s*fs\.File = temporaryFile[\s\S]*await fs\.close\(fileToClose\)/)
  assert.match(saveCrop, /finally\s*{[\s\S]*await packer\.release\(\)/)
  assert.match(saveCrop, /finally\s*{[\s\S]*await cropPixelMap\.release\(\)/)
  assert.match(saveCrop, /ownership\.temporaryCleanupPath\(\)[\s\S]*await fs\.unlink\(cleanupPath\)/)
  assert.doesNotMatch(saveCrop, /fs\.unlink\(targetPath\)/)

  const commit = extractMethod(source, 'static async commitImages')
  assert.match(commit, /static async commitImages\(context: Context, bankId: string, paths: Array<string>\): Promise<Array<string>>/)
  assertOrdered(commit, [
    'QuestionImageService.validateSafeIdentifier(bankId',
    "context.filesDir + '/question_images/' + bankId",
    'await QuestionImageService.ensureDirectDirectory(context.filesDir, committedRoot)',
    'await QuestionImageService.ensureDirectDirectory(committedRoot, destinationDir)',
    'const moved: Array<ImageMoveRecord>'
  ])
  const movePhase = commit.slice(commit.indexOf('const moved: Array<ImageMoveRecord>'))
  assertOrdered(movePhase, [
    'await fs.moveFile(record.sourcePath, record.finalPath, 1)',
    'moved.push',
    '} catch (err)',
    'await QuestionImageService.rollbackMoves'
  ])
  assert.match(source, /await fs\.moveFile\(record\.finalPath, record\.sourcePath, 1\)/)
  const deletion = extractMethod(source, 'static async deletePaths')
  assert.match(deletion, /static async deletePaths\(context: Context, paths: Array<string>\): Promise<void>/)
  assert.match(deletion, /QuestionImageService\.ownedDeletionRoot/)
  assert.match(deletion, /seenPaths\.indexOf\(path\)/)
  assert.match(deletion, /QuestionImageService\.validateExistingFileChain\(ownedRoot, path\)/)
  assert.match(deletion, /await fs\.unlink\(path\)/)
  assert.match(source, /await fs\.lstat\(/)
  assert.match(source, /\.isSymbolicLink\(\)/)
  const chainValidation = extractMethod(source, 'private static async validateExistingFileChain')
  assert.match(chainValidation, /relative\.split\('\/'\)/)
  assert.match(chainValidation, /for \(let index:\s*number = 0; index < parts\.length; index\+\+\)/)
  assert.match(chainValidation, /QuestionImageService\.isSymbolicLink\(info\)/)
  const symbolicLinkCheck = extractMethod(source, 'private static isSymbolicLink')
  assert.match(symbolicLinkCheck, /info\.isSymbolicLink\(\)/)
  const directoryCreation = extractMethod(source, 'private static async ensureDirectDirectory')
  assertOrdered(directoryCreation, [
    'await QuestionImageService.validateDirectory(parent)',
    'await fs.mkdir(path)',
    'await fs.lstat(path)',
    'QuestionImageService.isSymbolicLink(info)'
  ])
  const lstatIfPresent = extractMethod(source, 'private static async lstatIfPresent')
  assert.match(source, /BusinessError/)
  assert.match(lstatIfPresent, /err\.code === 13900002/)
  assert.doesNotMatch(lstatIfPresent, /accessible = await fs\.access/)
})

test('PDF coordinator is sequential, cancellation aware, failure tolerant, and fully cleaned', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/PdfImportCoordinator.ets', 'utf8')
  const modelSource = fs.readFileSync('entry/src/main/ets/models/PdfImportModels.ets', 'utf8')
  assert.match(source, /from '@kit\.PDFKit'/)
  assert.match(source, /from '@kit\.ImageKit'/)
  assert.match(source, /export class PdfImportRunResult/)
  assert.match(source, /export class PdfImportCancelledError extends Error/)
  assert.match(source, /class PdfImportResourceError extends Error/)
  assert.match(source, /private static taskSequence:\s*number\s*=\s*0/)
  assert.match(source, /private static runInProgress:\s*boolean\s*=\s*false/)
  assert.match(source, /OnDeviceOcrService\.shared\(\)/)
  const progressModel = extractMethod(modelSource, 'export class PdfImportProgress')
  assert.match(progressModel, /readonly stage:\s*string/)
  assert.match(progressModel, /readonly currentPage:\s*number/)
  assert.match(progressModel, /readonly totalPages:\s*number/)
  assert.match(progressModel, /readonly processedPageCount:\s*number/)
  assert.match(progressModel, /readonly questionCount:\s*number/)
  assert.match(progressModel, /readonly message:\s*string/)
  const run = extractMethod(source, 'static async run')
  assertOrdered(run, [
    'if (PdfImportCoordinator.runInProgress)',
    'PdfImportCoordinator.runInProgress = true',
    'const snapshot: PdfImportInputSnapshot = new PdfImportInputSnapshot(selection, settings)',
    'await PdfImportCoordinator.runSnapshot',
    'PdfImportCoordinator.runInProgress = false'
  ])
  const runSnapshot = extractMethod(source, 'private static async runSnapshot')
  assert.match(run, /Promise<PdfImportRunResult>/)
  assert.match(runSnapshot,
    /PdfImportValidator\.validatePageRange\(\s*snapshot\.startPage, snapshot\.endPage, snapshot\.pageCount\)/)
  assert.doesNotMatch(runSnapshot, /\bselection\.|\bsettings\./)
  assertOrdered(runSnapshot, [
    'PdfImportCoordinator.throwIfCancelled(isCancelled)',
    "new PdfImportProgress('opening'",
    'PdfImportCoordinator.throwIfCancelled(isCancelled)',
    'pdfDocument.isEncrypted(snapshot.uri)',
    'pdfDocument.loadDocument(snapshot.uri)',
    'PdfImportCoordinator.throwIfCancelled(isCancelled)',
    'await ocrService.initialize()',
    'PdfImportCoordinator.throwIfCancelled(isCancelled)',
    'for (let pageNumber: number = snapshot.startPage',
    'PdfImportCoordinator.throwIfCancelled(isCancelled)',
    "progressCallback(new PdfImportProgress('recognizing'",
    'PdfImportCoordinator.throwIfCancelled(isCancelled)',
    'pdfDocument.getPage(pageNumber - 1)',
    'PdfImportCoordinator.renderOcrPixelMap',
    'PdfImportCoordinator.throwIfCancelled(isCancelled)',
    'await fullPixelMap.getImageInfo()',
    'PdfImportCoordinator.validateImageInfo(fullImageInfo)',
    'PdfImportCoordinator.throwIfCancelled(isCancelled)',
    'const lines = await ocrService.recognize(fullPixelMap, pageNumber)',
    'PdfImportCoordinator.throwIfCancelled(isCancelled)',
    'candidatePage = new OcrPage',
    '} catch (pageErr)',
    'failures.push(new PdfPageFailure',
    'ocrPages.push(candidatePage)',
    'const drafts: Array<PdfQuestionDraft> = PdfSuccessfulPageParser.parse(',
    "new PdfImportProgress('cropping'",
    'const path: string = await QuestionImageService.saveCrop',
    'createdPaths.push(path)',
    'PdfImportCoordinator.throwIfCancelled(isCancelled)',
    'result = new PdfImportRunResult',
    'processingSucceeded = true',
    'resultReady = true',
    'await ocrService.release()',
    'pdfDocument.releaseDocument()',
    "new PdfImportProgress('complete'",
    'return result'
  ])
  assert.match(runSnapshot,
    /finally\s*{[\s\S]*fullPixelMap = null[\s\S]*await pixelMapToRelease\.release\(\)[\s\S]*page = null[\s\S]*pageToRelease\.release\(\)/)
  assert.match(runSnapshot, /resourceFatalError/)
  assert.match(runSnapshot, /pageErr instanceof PdfImportResourceError/)
  assert.match(runSnapshot, /if \(resourceFatalError !== null\)[\s\S]*throw resourceFatalError/)
  assert.match(runSnapshot, /finally\s*{[\s\S]*await ocrService\.release\(\)[\s\S]*pdfDocument\.releaseDocument\(\)/)
  assert.match(runSnapshot,
    /if \(!processingSucceeded \|\| cleanupFailures\.length > 0\)[\s\S]*QuestionImageService\.deletePaths\(context, createdPaths\)/)
  assert.match(runSnapshot,
    /const pageToRelease:\s*pdfService\.PdfPage = cropPage[\s\S]*cropPage = null[\s\S]*pageToRelease\.release\(\)/)
  assert.equal((runSnapshot.match(/new PdfImportProgress\('recognizing', pageNumber, totalPages, processedPageCount,\s*0,/g) || []).length,
    2)
  assert.match(runSnapshot, /const taskId:\s*string\s*=\s*PdfImportCoordinator\.createTaskId\(\)/)
  assert.match(runSnapshot,
    /PdfSuccessfulPageParser\.parse\(\s*ocrPages, snapshot\.startPage, snapshot\.endPage\)/)
  assert.match(runSnapshot, /if \(ocrPages\.length === 0 && failures\.length > 0\)[\s\S]*所选页面均识别失败/)
  const renderer = extractMethod(source, 'private static async renderOcrPixelMap')
  assert.match(renderer,
    /catch \(releaseErr\)[\s\S]*new PdfImportResourceError[\s\S]*throw resourceError/)
  assertOrdered(renderer, [
    'page.getPagePixelMap()',
    'await originalPixelMap.getImageInfo()',
    'if (longEdge <= PdfImportLimits.MAX_RENDER_LONG_EDGE)',
    'const originalToRelease: image.PixelMap = originalPixelMap'
  ])
  const oversizedRender = renderer.slice(renderer.indexOf('const originalToRelease: image.PixelMap = originalPixelMap'))
  assertOrdered(oversizedRender, [
    'const originalToRelease: image.PixelMap = originalPixelMap',
    'originalPixelMap = null',
    'await originalToRelease.release()',
    'page.getAreaPixelMapWithOptions'
  ])
  const completeProgress = runSnapshot.indexOf("progressCallback(new PdfImportProgress('complete'")
  const outerOcrRelease = runSnapshot.lastIndexOf('await ocrService.release()')
  const outerDocumentRelease = runSnapshot.lastIndexOf('pdfDocument.releaseDocument()')
  assert.ok(outerOcrRelease < outerDocumentRelease, 'OCR release must precede document release')
  assert.ok(outerDocumentRelease < completeProgress, 'complete progress must follow all outer release work')
  const completeTail = runSnapshot.slice(completeProgress)
  assertOrdered(completeTail, [
    "progressCallback(new PdfImportProgress('complete'",
    '} catch (progressErr)',
    'await QuestionImageService.deletePaths(context, createdPaths)',
    'throw new PdfImportCancelledError',
    'throw new Error',
    'return result'
  ])
})

test('PDF import device pipeline stays offline even with app-level INTERNET permission', () => {
  const paths = [
    'entry/src/main/ets/services/OnDeviceOcrService.ets',
    'entry/src/main/ets/services/QuestionImageService.ets',
    'entry/src/main/ets/services/PdfImportCoordinator.ets'
  ]
  const source = paths.map((path) => fs.readFileSync(path, 'utf8')).join('\n')
  assert.doesNotMatch(source, /@kit\.NetworkKit|ohos\.permission\.INTERNET|\bhttp\b|\bhttps\b|HttpClient|createHttp/)
})

test('PDF import routes and visible flow copy are registered', () => {
  const routes = JSON.parse(fs.readFileSync(
    'entry/src/main/resources/base/profile/main_pages.json', 'utf8')).src
  assert.ok(routes.includes('pages/PdfImportSetupPage'))
  assert.ok(routes.includes('pages/PdfImportProgressPage'))
  assert.ok(routes.includes('pages/PdfImportReviewPage'))
  assert.ok(routes.includes('pages/EditQuestionPage'))

  const source = [
    'entry/src/main/ets/pages/ImportBankPage.ets',
    'entry/src/main/ets/pages/PdfImportSetupPage.ets',
    'entry/src/main/ets/pages/PdfImportProgressPage.ets'
  ].map((path) => fs.readFileSync(path, 'utf8')).join('\n')
  for (const copy of ['导入 PDF', '选择科目', '起始页', '结束页', '单次最多识别 20 页', '正在识别第', '取消识别']) {
    assert.match(source, new RegExp(copy))
  }
})

test('import page preserves JSON import and stages a guarded PDF selection before setup routing', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/ImportBankPage.ets', 'utf8')
  const jsonImport = extractMethod(source, 'private startImport')
  const selectPdf = extractMethod(source, 'private async selectPdf')
  assert.match(jsonImport, /ImportService\.selectAndImport|this\.importBank\(\)/)
  assert.match(source, /选择 JSON 文件/)
  assert.match(source, /\.enabled\(!this\.importing && !this\.pdfSelecting\)/)
  assert.match(source, /PdfImportService/)
  assert.match(source, /PdfImportState/)
  assertOrdered(selectPdf, [
    'if (this.importing || this.pdfSelecting)',
    'this.pdfSelecting = true',
    "this.errorMessage = ''",
    'await QuestionImageService.retryCleanupDebt(getContext(this), this.activeDraftImagePaths())',
    'await PdfImportService.selectPdf(getContext(this))',
    'if (selection === null)',
    'PdfImportState.shared().reset()',
    'PdfImportState.shared().setSelection(selection)',
    "url: 'pages/PdfImportSetupPage'"
  ])
  assert.match(selectPdf, /finally\s*{[\s\S]*this\.pdfSelecting = false/)
  assert.match(selectPdf, /let selectionStored:\s*boolean\s*=\s*false/)
  assert.match(selectPdf,
    /catch \(err\)[\s\S]*let selectedPdfRemoved:\s*boolean\s*=\s*true[\s\S]*selectedPdfRemoved = false[\s\S]*if \(selectionStored && selectedPdfRemoved\)[\s\S]*PdfImportState\.shared\(\)\.reset\(\)/)
  assert.match(source, /不支持加密 PDF|PDF 文件无法解析|PDF 文件大小/)
})

test('PDF setup validates trimmed settings and pure positive page text before progress routing', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/PdfImportSetupPage.ets', 'utf8')
  assert.match(source, /@Entry[\s\S]*@Component/)
  assert.match(source, /@State bankName:\s*string/)
  assert.match(source, /@State subject:\s*string/)
  assert.match(source, /@State startPageText:\s*string/)
  assert.match(source, /@State endPageText:\s*string/)
  assert.match(source, /@State errorMessage:\s*string/)
  const appear = extractMethod(source, 'aboutToAppear')
  assert.match(appear, /PdfImportState\.shared\(\)\.getSelection\(\)/)
  assert.match(appear, /PdfImportValidator\.bankNameFromFileName/)
  const start = extractMethod(source, 'private startRecognition')
  assert.match(start, /\.trim\(\)/)
  assert.match(start, /isPositiveIntegerText/)
  assert.match(start, /Number\.parseInt/)
  assert.match(start, /PdfImportValidator\.validatePageRange/)
  assertOrdered(start, [
    'if (!validation.valid)',
    'new PdfImportSettings',
    'state.setSettings(settings)',
    'state.clearCancelRequest()',
    "url: 'pages/PdfImportProgressPage'"
  ])
  const back = extractMethod(source, 'private async leaveImport')
  assertOrdered(back, [
    'await PdfImportService.removeTemporaryPdf(selection.uri)',
    'this.cleanupPending = false',
    'await this.navigateBack()'
  ])
  const navigateBack = extractMethod(source, 'private async navigateBack')
  assertOrdered(navigateBack, [
    'this.getUIContext().getRouter().back()',
    'PdfImportState.shared().reset()'
  ])
  assert.match(source, /题库名/)
  assert.match(source, /数学[\s\S]*语文[\s\S]*英语[\s\S]*物理[\s\S]*化学[\s\S]*其他/)
})

test('PDF progress runs exactly once and separates completion cancellation retry and cleanup', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/PdfImportProgressPage.ets', 'utf8')
  assert.match(source, /@Entry[\s\S]*@Component/)
  assert.match(source, /private started:\s*boolean\s*=\s*false/)
  const appear = extractMethod(source, 'aboutToAppear')
  assertOrdered(appear, ['if (this.started)', 'this.started = true', 'this.runImport()'])
  const run = extractMethod(source, 'private async runImport')
  assert.match(run, /PdfImportCoordinator\.run/)
  assert.match(run, /PdfImportState\.shared\(\)\.isCancelRequested\(\)/)
  assert.match(run, /this\.currentPage = progress\.currentPage/)
  assert.match(run, /this\.processedPageCount = progress\.processedPageCount/)
  assert.match(run, /state\.setDrafts\(result\.drafts\)/)
  assert.match(run, /state\.setFailures\(result\.failures\)/)
  assertOrdered(run, [
    'state.setDrafts(result.drafts)',
    'state.setFailures(result.failures)',
    'this.completed = true',
    'this.navigateToReview()'
  ])
  const completionStart = run.indexOf('state.setDrafts(result.drafts)')
  const cancellationStart = run.indexOf('if (err instanceof PdfImportCancelledError)')
  assert.doesNotMatch(run.slice(completionStart, cancellationStart), /removeTemporaryPdf|abandonTemporaryPdf/)
  assert.doesNotMatch(run, /pages\/PdfImportReviewPage/)
  assert.match(run, /PdfImportCancelledError/)
  assert.match(run,
    /if \(err instanceof PdfImportCancelledError\)[\s\S]*try\s*{\s*await PdfImportService\.removeTemporaryPdf\(selection\.uri\)\s*}\s*catch\s*{[\s\S]*this\.cleanupPending = true[\s\S]*return\s*}[\s\S]*await this\.navigateToImportBank\(\)/)
  const cancel = extractMethod(source, 'private cancelImport')
  assert.match(cancel, /requestCancel\(\)/)
  assert.match(cancel, /this\.cancelDisabled = true/)
  const retry = extractMethod(source, 'private retryImport')
  assertOrdered(retry, [
    'clearCancelRequest()',
    "this.errorMessage = ''",
    'this.started = false',
    'this.running = false',
    'this.startRun()'
  ])
  const finishCleanup = extractMethod(source, 'private async finishCleanup')
  assert.doesNotMatch(finishCleanup, /this\.navigateToReview\(\)/)
  assert.doesNotMatch(finishCleanup, /pages\/PdfImportReviewPage/)
  const continueReview = extractMethod(source, 'private continueReview')
  assert.match(continueReview, /this\.navigateToReview\(\)/)
  assert.doesNotMatch(continueReview, /pages\/PdfImportReviewPage|replaceUrl/)
  const navigateToReview = extractMethod(source, 'private async navigateToReview')
  assertOrdered(navigateToReview, [
    'if (this.reviewNavigationPending || this.reviewNavigationCompleted)',
    'this.reviewNavigationPending = true',
    "url: 'pages/PdfImportReviewPage'",
    'await this.getUIContext().getRouter().replaceUrl(options)',
    'this.reviewNavigationCompleted = true',
    '} catch {',
    'this.reviewNavigationPending = false'
  ])
  assert.equal((source.match(/pages\/PdfImportReviewPage/g) || []).length, 1)
  assert.equal((source.match(/this\.reviewNavigationPending = false/g) || []).length, 1)
  assert.match(source, /\.enabled\(!this\.reviewNavigationPending && !this\.cleaning\)/)
  const leave = extractMethod(source, 'private async leaveImport')
  assertOrdered(leave, [
    'await PdfImportService.removeTemporaryPdf(selection.uri)',
    'await this.navigateToImportBank()'
  ])
  const navigateToImport = extractMethod(source, 'private async navigateToImportBank')
  assertOrdered(navigateToImport, [
    "url: 'pages/ImportBankPage'",
    'await this.getUIContext().getRouter().replaceUrl(options)',
    'PdfImportState.shared().reset()'
  ])
  assert.match(source, /当前设备不支持端侧文字识别，请使用鸿蒙真机重试/)
  assert.match(source, /继续审核|重试清理/)
})

test('resource route contract requires the exact unique nine route registry', () => {
  const source = fs.readFileSync('entry/src/test/Task9ResourceContracts.test.cjs', 'utf8')
  assert.match(source, /JSON\.stringify\(pages\) !== JSON\.stringify\(expectedPages\)/)
  assert.doesNotMatch(source, /pages\.includes\(expectedPage\)/)
  assertOrdered(source, [
    "'pages/Index'",
    "'pages/ImportBankPage'",
    "'pages/PdfImportSetupPage'",
    "'pages/PdfImportProgressPage'",
    "'pages/PdfImportReviewPage'",
    "'pages/EditQuestionPage'",
    "'pages/QuestionListPage'",
    "'pages/QuestionDetailPage'",
    "'pages/WrongQuestionDetailPage'"
  ])
})

test('import entry serializes JSON and PDF work, blocks back, retries image cleanup debt, and grows errors', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/ImportBankPage.ets', 'utf8')
  const back = extractMethod(source, 'private goBack')
  const jsonImport = extractMethod(source, 'private startImport')
  const selectPdf = extractMethod(source, 'private async selectPdf')
  const hardwareBack = extractMethod(source, 'onBackPress')
  assert.match(back, /if \(this\.importing \|\| this\.pdfSelecting\)/)
  assert.match(jsonImport, /if \(this\.importing \|\| this\.pdfSelecting\)/)
  assert.match(selectPdf, /if \(this\.importing \|\| this\.pdfSelecting\)/)
  assertOrdered(selectPdf, [
    'this.pdfSelecting = true',
    'await QuestionImageService.retryCleanupDebt(getContext(this), this.activeDraftImagePaths())',
    'await PdfImportService.selectPdf(getContext(this))'
  ])
  assert.match(selectPdf,
    /retryCleanupDebt[\s\S]*catch[\s\S]*题图清理仍待处理[\s\S]*PdfImportService\.selectPdf/)
  assertOrdered(hardwareBack, ['this.goBack()', 'return true'])
  assert.match(source, /\.constraintSize\(\{ minHeight: 48 \}\)/)
  assert.doesNotMatch(source, /Text\(this\.errorMessage\)[\s\S]{0,180}\.height\(48\)/)
})

test('review discard owns every unique draft image and resets only after replacement navigation', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  const collect = extractMethod(source, 'private collectDraftImagePaths')
  const discard = extractMethod(source, 'private async performDiscard')
  const defer = extractMethod(source, 'private async rememberDebtAndDiscard')
  const back = extractMethod(source, 'private async discardImport')
  const hardwareBack = extractMethod(source, 'onBackPress')
  assertOrdered(collect, [
    'PdfImportState.shared().getDrafts()',
    'draft.imagePaths',
    'paths.indexOf(path) < 0',
    'paths.push(path)'
  ])
  assertOrdered(discard, [
    'this.collectDraftImagePaths()',
    'await QuestionImageService.deletePaths(getContext(this), paths)',
    'this.navigateAfterDiscard()'
  ])
  assert.match(discard,
    /this\.cleanupPaths = paths\.slice\(\)[\s\S]*catch[\s\S]*this\.cleanupPaths = err\.paths\.slice\(\)[\s\S]*this\.cleanupPending = true[\s\S]*return/)
  assertOrdered(defer, [
    'QuestionImageService.rememberCleanupDebt(this.cleanupPaths)',
    'this.navigateAfterDiscard()'
  ])
  const navigation = extractMethod(source, 'private async navigateAfterDiscard')
  assertOrdered(navigation, [
    "url: 'pages/ImportBankPage'",
    'await this.getUIContext().getRouter().replaceUrl(options)'
  ])
  assert.match(discard, /PdfImportState\.shared\(\)\.reset\(\)/)
  assert.match(navigation, /catch[\s\S]*识别结果已丢弃，请重试返回导入页面/)
  assert.doesNotMatch(navigation.slice(navigation.indexOf('catch')), /reset\(\)/)
  assert.match(back, /this\.performDiscard\(\)/)
  assertOrdered(hardwareBack, ['this.discardImport()', 'return true'])
  assert.doesNotMatch(source, /getRouter\(\)\.back\(/)
  assert.match(source, /丢弃识别结果|稍后清理并返回/)
})

test('coordinator exports structured cleanup errors with copied reachable paths', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/PdfImportCoordinator.ets', 'utf8')
  assert.match(source, /export class PdfImportCleanupError extends Error/)
  assert.match(source, /export class PdfImportCancelledCleanupError extends PdfImportCancelledError/)
  const cleanupError = extractMethod(source, 'export class PdfImportCleanupError')
  const cancelledCleanupError = extractMethod(source, 'export class PdfImportCancelledCleanupError')
  assert.match(cleanupError, /readonly paths:\s*Array<string>/)
  assert.match(cleanupError, /this\.paths = paths\.slice\(\)/)
  assert.match(cancelledCleanupError, /readonly paths:\s*Array<string>/)
  assert.match(cancelledCleanupError, /this\.paths = paths\.slice\(\)/)
  const run = extractMethod(source, 'private static async runSnapshot')
  assert.match(run, /let createdPathCleanupFailed:\s*boolean\s*=\s*false/)
  assert.match(run, /QuestionImageService\.deletePaths\(context, createdPaths\)[\s\S]*createdPathCleanupFailed = true/)
  assert.match(run,
    /createdPathCleanupFailed[\s\S]*PdfImportCancelledCleanupError\(message, createdPaths\)[\s\S]*PdfImportCleanupError\(message, createdPaths\)/)
  assert.match(run,
    /completionCleanupFailed[\s\S]*PdfImportCancelledCleanupError\(completionMessage, createdPaths\)[\s\S]*PdfImportCleanupError\(completionMessage, createdPaths\)/)
})

test('question image cleanup debt is idempotent and retry retains only failed paths', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  assert.match(source, /private static readonly cleanupDebtPaths:\s*Array<string>/)
  const remember = extractMethod(source, 'static rememberCleanupDebt')
  const retry = extractMethod(source, 'static async retryCleanupDebt')
  const perform = extractMethod(source, 'private static async performCleanupDebtRetry')
  assert.match(remember, /cleanupDebtPaths\.indexOf\(path\) < 0[\s\S]*cleanupDebtPaths\.push\(path\)/)
  assert.match(retry, /QuestionImageService\.performCleanupDebtRetry\(context, activePaths\.slice\(\)\)/)
  assert.match(perform, /const candidatePaths:\s*Array<string>\s*=\s*QuestionImageService\.cleanupDebtPaths\.slice\(\)/)
  assert.match(perform, /await fs\.unlink\(path\)[\s\S]*QuestionImageService\.removeCleanupDebt\(\[path\]\)/)
  assert.match(perform, /catch \(err\)[\s\S]*QuestionImageService\.rememberCleanupDebt\(\[path\]\)/)
})

test('temporary PDF abandonment moves only exact active ownership to retryable orphan storage', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/PdfImportService.ets', 'utf8')
  const abandon = extractMethod(source, 'static abandonTemporaryPdf')
  assert.match(abandon, /const stagedIndex:\s*number = PdfImportService\.stagedPaths\.indexOf\(path\)/)
  assert.match(abandon, /stagedIndex < 0[\s\S]*isRegisteredOrphanPath\(path\)[\s\S]*throw new Error/)
  assert.match(abandon, /isDirectTemporaryPdfPath\(cacheDir, path\)/)
  assertOrdered(abandon, [
    'const stagedIndex: number = PdfImportService.stagedPaths.indexOf(path)',
    'PdfImportService.registerOrphanPath(path, cacheDir)',
    'PdfImportService.unregisterStagedPath(path)'
  ])
  assert.match(source, /cleanupStalePdfs[\s\S]*PdfImportService\.stagedPaths\.indexOf\(path\) >= 0[\s\S]*await fs\.unlink\(path\)/)
})

test('setup and progress separate cleanup, abandonment, navigation, and state reset', () => {
  const setupSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportSetupPage.ets', 'utf8')
  const count = extractMethod(setupSource, 'private selectedPageCount')
  assert.match(count, /Number\.isFinite\(startPage\)/)
  assert.match(count, /Number\.isSafeInteger\(startPage\)/)
  assert.match(count, /Number\.isSafeInteger\(selectedCount\)/)
  const setupLeave = extractMethod(setupSource, 'private async leaveImport')
  assert.match(setupLeave, /catch[\s\S]*this\.cleanupPending = true[\s\S]*return/)
  assert.doesNotMatch(setupLeave.slice(setupLeave.indexOf('catch')), /getRouter\(\)\.back|reset\(\)/)
  const setupDefer = extractMethod(setupSource, 'private async abandonAndLeave')
  assertOrdered(setupDefer, ['PdfImportService.abandonTemporaryPdf(selection.uri)', 'this.navigateBack()'])
  const setupNavigate = extractMethod(setupSource, 'private async navigateBack')
  assertOrdered(setupNavigate, ['this.getUIContext().getRouter().back()', 'PdfImportState.shared().reset()'])
  assert.doesNotMatch(setupNavigate.slice(setupNavigate.indexOf('catch')), /reset\(\)/)
  assert.match(setupSource, /稍后清理并返回/)

  const progressSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportProgressPage.ets', 'utf8')
  assert.match(progressSource, /PdfImportCancelledCleanupError/)
  assert.match(progressSource, /PdfImportCleanupError/)
  assert.match(progressSource, /private cleanupPaths:\s*Array<string>/)
  assert.match(progressSource, /private cleanupMode:\s*string/)
  const handle = extractMethod(progressSource, 'private handleStructuredCleanupError')
  assert.match(handle, /this\.cleanupPaths = err\.paths\.slice\(\)/)
  assert.match(handle, /cancelled-images|fatal-images/)
  const retry = extractMethod(progressSource, 'private async finishCleanup')
  assert.match(retry, /QuestionImageService\.deletePaths\(getContext\(this\), this\.cleanupPaths\)/)
  assert.match(retry, /this\.cleanupMode === 'fatal-images'[\s\S]*this\.cleanupPending = false[\s\S]*return/)
  const later = extractMethod(progressSource, 'private async abandonCleanupAndContinue')
  assert.match(later, /QuestionImageService\.rememberCleanupDebt\(this\.cleanupPaths\)/)
  assert.match(later, /PdfImportService\.abandonTemporaryPdf\(selection\.uri\)/)
  assert.match(progressSource, /稍后清理并返回|稍后清理并继续审核/)
})

test('saveCrop registers only an owned temporary residue when immediate cleanup fails', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  const saveCrop = extractMethod(source, 'static async saveCrop')
  const cleanup = saveCrop.slice(saveCrop.indexOf('const cleanupPath: string = ownership.temporaryCleanupPath()'))
  assertOrdered(cleanup, [
    'const cleanupPath: string = ownership.temporaryCleanupPath()',
    'await fs.unlink(cleanupPath)',
    '} catch (err)',
    'QuestionImageService.rememberCleanupDebt([cleanupPath])',
    '残留临时题图删除失败'
  ])
  assert.equal((saveCrop.match(/rememberCleanupDebt\(\[cleanupPath\]\)/g) || []).length, 1)
  assert.doesNotMatch(saveCrop, /rememberCleanupDebt\(\[targetPath\]\)/)
})

test('question image debt retry shares one transition and recovers strict direct cache files after restart', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  assert.match(source, /private static cleanupTransition:\s*Promise<void> \| null\s*=\s*null/)
  const retry = extractMethod(source, 'static async retryCleanupDebt')
  assertOrdered(retry, [
    'QuestionImageService.cleanupTransition',
    'await runningTransition',
    'QuestionImageService.performCleanupDebtRetry(context, activePaths.slice())',
    'QuestionImageService.cleanupTransition = transition',
    'await transition',
    'QuestionImageService.cleanupTransition = null'
  ])
  const perform = extractMethod(source, 'private static async performCleanupDebtRetry')
  assert.match(perform, /const options:\s*ListFileOptions\s*=\s*{\s*recursion:\s*false\s*}/)
  assertOrdered(perform, [
    'await QuestionImageService.validateDirectory(context.cacheDir)',
    'QuestionImageService.cleanupDebtPaths.slice()',
    'await fs.listFile(context.cacheDir, options)',
    'QuestionImageService.isCleanupCandidateName(name)',
    "const path: string = context.cacheDir + '/' + name",
    'activePaths.indexOf(path) >= 0',
    'QuestionImageService.lstatIfPresent(path)',
    'QuestionImageService.isSymbolicLink(info)',
    'QuestionImageService.isFile(info)',
    'await fs.unlink(path)',
    'QuestionImageService.removeCleanupDebt([path])',
    '} catch (err)',
    'QuestionImageService.rememberCleanupDebt([path])',
    'failures.push'
  ])
  assert.match(perform, /if \(failures\.length > 0\)[\s\S]*题图缓存清理失败/)
  const nameCheck = extractMethod(source, 'private static isCleanupCandidateName')
  assert.match(nameCheck, /name\.startsWith\('pdf_question_'\)/)
  assert.match(nameCheck, /name\.endsWith\('\.jpg'\)/)
  assert.match(nameCheck, /name\.charCodeAt\(index\)/)
  assert.match(nameCheck, /QuestionImageService\.isSafeIdentifierCode\(code\)/)
})

test('import entry starts background debt recovery, protects active drafts, and preserves cleanup warnings', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/ImportBankPage.ets', 'utf8')
  assert.match(source, /@State cleanupWarning:\s*string\s*=\s*''/)
  const appear = extractMethod(source, 'aboutToAppear')
  assert.match(appear, /this\.retryImageCleanup\(\)/)
  const active = extractMethod(source, 'private activeDraftImagePaths')
  assertOrdered(active, [
    'PdfImportState.shared().getDrafts()',
    'draft.imagePaths',
    'paths.indexOf(path) < 0',
    'paths.push(path)'
  ])
  const background = extractMethod(source, 'private retryImageCleanup')
  assert.match(background,
    /QuestionImageService\.retryCleanupDebt\(getContext\(this\), this\.activeDraftImagePaths\(\)\)/)
  assert.match(background, /catch[\s\S]*this\.cleanupWarning = '部分遗留题图清理仍待处理'/)
  const selectPdf = extractMethod(source, 'private async selectPdf')
  assertOrdered(selectPdf, [
    'await QuestionImageService.retryCleanupDebt(getContext(this), this.activeDraftImagePaths())',
    'await PdfImportService.selectPdf(getContext(this))'
  ])
  assert.match(selectPdf, /catch[\s\S]*this\.errorMessage = this\.messageForPdfError\(err\)/)
  assert.doesNotMatch(selectPdf, /this\.cleanupWarning = this\.messageForPdfError/)
  assert.match(source, /Text\(this\.cleanupWarning\)/)
})

test('PDF stale cleanup isolates per-file failures so picker construction remains reachable', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/PdfImportService.ets', 'utf8')
  const selectPdf = extractMethod(source, 'static async selectPdf')
  const staleCleanup = extractMethod(source, 'private static async cleanupStalePdfs')
  assertOrdered(selectPdf, [
    'await PdfImportService.cleanupStalePdfs(context.cacheDir)',
    'new picker.DocumentViewPicker(context)'
  ])
  assert.match(staleCleanup,
    /for \(const name of names\)[\s\S]*try\s*{[\s\S]*await PdfImportService\.lstatIfPresent\(path\)[\s\S]*await fs\.unlink\(path\)[\s\S]*catch \(cleanupErr\)\s*{\s*PdfImportService\.registerOrphanPath\(path, cacheDir\)\s*continue/)
  const perFileCatch = staleCleanup.slice(staleCleanup.indexOf('catch (cleanupErr)'))
  assert.doesNotMatch(perFileCatch, /throw cleanupErr|throw new Error/)
  assert.match(staleCleanup, /await fs\.listFile\(cacheDir, options\)/)
})

test('progress reports image cleanup retry failures separately from temporary PDF cleanup', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/PdfImportProgressPage.ets', 'utf8')
  const retry = extractMethod(source, 'private retryCleanup')
  assert.match(retry,
    /this\.cleanupMode === 'fatal-images' \|\| this\.cleanupMode === 'cancelled-images'[\s\S]*题图缓存清理失败/)
  assert.match(retry, /else[\s\S]*this\.messageForCleanupError\(err\)/)
})

test('PDF review renders editable cloned drafts and deletes one draft image set after confirmation', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  assert.match(source, /识别结果/)
  assert.match(source, /待确认/)
  assert.match(source, /删除此题/)
  assert.match(source, /保存题库/)
  assert.match(source, /答案（选填）/)
  assert.match(source, /解析（选填）/)
  assert.match(source, /@State drafts:\s*Array<PdfQuestionDraft>/)
  const appear = extractMethod(source, 'aboutToAppear')
  assert.match(appear, /PdfImportState\.shared\(\)\.getDrafts\(\)/)
  assert.match(appear, /this\.drafts =/)
  const replace = extractMethod(source, 'private replaceDraft')
  assert.match(replace, /new PdfQuestionDraft\(/)
  assert.match(replace, /this\.drafts = nextDrafts/)
  for (const methodName of [
    'private updateQuestionText',
    'private updateOption',
    'private updateAnswer',
    'private updateAnalysis',
    'private updateType'
  ]) {
    const method = extractMethod(source, methodName)
    assert.match(method, /this\.replaceDraft\(/)
  }
  assert.match(source, /Image\('file:\/\/' \+ imagePath\)/)
  assert.match(source, /TextArea\(/)
  assert.match(source, /TextInput\(/)
  assert.match(source, /ForEach\(this\.drafts/)
  assert.match(source, /\(draft: PdfQuestionDraft\): string => draft\.localId/)
  const confirm = extractMethod(source, 'private confirmDeleteDraft')
  assert.match(confirm, /showAlertDialog/)
  assert.match(confirm, /this\.rollbackPending/)
  assert.match(confirm, /value:\s*'删除'/)
  assert.match(confirm, /value:\s*'取消'/)
  const deletion = extractMethod(source, 'private async deleteDraft')
  assertOrdered(deletion, [
    'await QuestionImageService.deletePaths(getContext(this), draft.imagePaths)',
    'this.drafts = nextDrafts',
    'PdfImportState.shared().setDrafts(nextDrafts)'
  ])
})

test('PDF review validates essential content then commits ordered images before one transactional save', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  const validate = extractMethod(source, 'private validateDrafts')
  assert.match(validate, /this\.drafts\.length === 0/)
  assert.match(validate, /draft\.question\.trim\(\)\.length === 0/)
  assert.match(validate, /draft\.type !== 'unclassified'/)
  assert.match(validate, /draft\.imagePaths\.length > 0/)
  assert.doesNotMatch(validate, /draft\.answer\.trim|draft\.analysis\.trim/)
  const save = extractMethod(source, 'private async saveBank')
  assertOrdered(save, [
    "IdUtils.create('bank_')",
    'QuestionImageService.commitImages',
    'new QuestionImage(',
    'new Question(',
    'new QuestionBank(',
    'QuestionBankService.savePdfBank(bank, bankId)',
    'this.completeSuccessfulSave(bankId)'
  ])
  const complete = extractMethod(source, 'private async completeSuccessfulSave')
  assertOrdered(complete, [
    'this.finishSuccessfulPdfOwnership()',
    'this.finalizeSuccessfulSave()'
  ])
  const finalize = extractMethod(source, 'private async finalizeSuccessfulSave')
  assertOrdered(finalize, [
    'PdfImportState.shared().reset()',
    "showToast('题库导入成功')",
    'NavigationState.shared().selectBank(this.savedBankId)',
    "url: 'pages/QuestionListPage'",
    'replaceUrl(options)'
  ])
  assert.match(save, /draft\.type === 'unclassified'[\s\S]*'needs_review'/)
  assert.match(save, /draft\.imagePaths\[imageIndex\]/)
  assert.match(save, /draft\.crops\[imageIndex\]\.pageNumber/)
  assertOrdered(save, [
    'QuestionImageService.commitImages',
    'this.draftsWithCommittedImagePaths(committedPaths)',
    'for (let draftIndex: number = 0; draftIndex < committedDrafts.length; draftIndex++)'
  ])
  assert.match(save, /catch \(err\)[\s\S]*QuestionImageService\.rollbackCommittedImages/)
  assert.match(source, /@State pending:\s*boolean/)
  assert.match(source, /@State saveCompleted:\s*boolean/)
  assert.match(source, /if \(this\.pending \|\|/)
  const discard = extractMethod(source, 'private async discardImport')
  assert.match(discard, /this\.rollbackPending/)
  assert.match(source,
    /\.enabled\(!this\.pending && !this\.discarding && !this\.saveCompleted && !this\.rollbackPending\)/)
})

test('savePdfBank keeps bank questions and images in one transaction without changing JSON import API', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionBankService.ets', 'utf8')
  assert.match(source,
    /static async savePdfBank\(bank: QuestionBank, bankId: string,\s*remoteApply: boolean = false\): Promise<string>/)
  const method = extractMethod(source, 'static async savePdfBank')
  assertOrdered(method, [
    'QuestionBankService.createImportSnapshot',
    'await store.createTransaction()',
    "transaction.insert('question_bank'",
    "transaction.insert('question'",
    "transaction.insert('question_image'",
    'await transaction.commit()',
    'return snapshot.bankId'
  ])
  assert.match(method, /catch \(err\)[\s\S]*await transaction\.rollback\(\)/)
  const jsonMethod = extractMethod(source, 'static async saveImportedBank')
  assert.match(jsonMethod, /IdUtils\.create\('bank_'\)/)
  assert.doesNotMatch(jsonMethod, /savePdfBank/)
})

test('committed PDF image rollback is path-owned idempotent and reports recoverable cleanup state', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  assert.match(source, /export class QuestionImageRollbackError extends Error/)
  const commit = extractMethod(source, 'static async commitImages')
  assert.match(commit,
    /QuestionImageService\.rollbackMoves[\s\S]*QuestionImageService\.removeBankDirectoryIfEmpty/)
  const rollback = extractMethod(source, 'static async rollbackCommittedImages')
  assert.match(rollback,
    /static async rollbackCommittedImages\(context: Context, bankId: string, cachePaths: Array<string>,\s*committedPaths: Array<string>\): Promise<void>/)
  assertOrdered(rollback, [
    'QuestionImageService.validateSafeIdentifier(bankId',
    "context.filesDir + '/question_images/' + bankId",
    'QuestionImageService.validateExistingDirectoryChain',
    'await fs.moveFile(committedPath, cachePath, 1)',
    'await fs.rmdir(destinationDir)'
  ])
  assert.match(rollback, /throw new QuestionImageRollbackError\(/)
  assert.match(source, /readonly bankId:\s*string/)
  assert.match(source, /readonly cachePaths:\s*Array<string>/)
  assert.match(source, /readonly committedPaths:\s*Array<string>/)
})

test('partial image commit rollback failure reaches review as a structured recoverable mapping', () => {
  const imageSource = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  const commit = extractMethod(imageSource, 'static async commitImages')
  assert.match(commit, /const expectedCommittedPaths:\s*Array<string>/)
  assert.match(commit,
    /rollbackErrors\.length > 0[\s\S]*throw new QuestionImageRollbackError\([\s\S]*bankId[\s\S]*paths[\s\S]*expectedCommittedPaths/)
  const reviewSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  const save = extractMethod(reviewSource, 'private async saveBank')
  assert.match(reviewSource, /QuestionImageRollbackError/)
  assert.match(save,
    /catch \(err\)[\s\S]*err instanceof QuestionImageRollbackError[\s\S]*this\.rollbackPending = true[\s\S]*err\.bankId[\s\S]*err\.cachePaths\.slice\(\)[\s\S]*err\.committedPaths\.slice\(\)/)
  const rollback = extractMethod(imageSource, 'static async rollbackCommittedImages')
  assert.match(rollback,
    /committedInfo === null[\s\S]*cacheInfo === null[\s\S]*continue[\s\S]*cacheInfo !== null[\s\S]*已被占用/)
})

test('uncertain PDF bank save exports exact three-state verification and review recovery decisions', () => {
  const serviceSource = fs.readFileSync('entry/src/main/ets/services/QuestionBankService.ets', 'utf8')
  assert.match(serviceSource, /export class PdfBankSaveUncertainError extends Error/)
  assert.match(serviceSource, /readonly bankId:\s*string/)
  assert.match(serviceSource, /readonly originalError:\s*string/)
  assert.match(serviceSource, /readonly rollbackError:\s*string/)
  const save = extractMethod(serviceSource, 'static async savePdfBank')
  assert.match(save,
    /catch \(rollbackErr\)[\s\S]*throw new PdfBankSaveUncertainError\([\s\S]*snapshot\.bankId/)
  const resolve = extractMethod(serviceSource, 'static async resolvePdfBankSave')
  assert.match(resolve,
    /static async resolvePdfBankSave\(bank: QuestionBank, bankId: string\): Promise<string>/)
  assert.match(resolve, /return 'committed'/)
  assert.match(resolve, /return 'absent'/)
  assert.match(resolve, /return 'inconsistent'/)
  assert.match(resolve, /question_bank/)
  assert.match(resolve, /question_image/)
  assert.match(resolve, /image_path/)
  assert.match(resolve, /createImportSnapshot/)

  const reviewSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  assert.match(reviewSource, /@State databaseRecoveryPending:\s*boolean/)
  const uncertain = extractMethod(reviewSource, 'private async resolveUncertainSave')
  assertOrdered(uncertain, [
    'QuestionBankService.resolvePdfBankSave(bank, bankId)',
    "resolution === 'committed'",
    'this.completeSuccessfulSave(bankId)',
    "resolution === 'absent'",
    'QuestionImageService.rollbackCommittedImages',
    'this.setDatabaseRecovery'
  ])
  assert.match(uncertain, /catch[\s\S]*this\.setDatabaseRecovery/)
  const setRecovery = extractMethod(reviewSource, 'private setDatabaseRecovery')
  assert.match(setRecovery, /this\.databaseRecoveryPending = true/)
  const retry = extractMethod(reviewSource, 'private async retryDatabaseRecovery')
  assert.match(retry, /this\.resolveUncertainSave/)
  const discard = extractMethod(reviewSource, 'private async discardImport')
  assert.match(discard, /this\.databaseRecoveryPending/)
  assert.match(reviewSource, /重新核验保存状态/)
})

test('discard completion resets immediately and navigation failure only permits navigation retry', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  assert.match(source, /@State discardCompleted:\s*boolean/)
  assert.match(source, /@State navigationRetryPending:\s*boolean/)
  const discard = extractMethod(source, 'private async performDiscard')
  assertOrdered(discard, [
    'await QuestionImageService.deletePaths(getContext(this), paths)',
    'this.discardCompleted = true',
    'this.drafts = new Array<PdfQuestionDraft>()',
    'PdfImportState.shared().reset()',
    'this.navigateAfterDiscard()'
  ])
  const navigate = extractMethod(source, 'private async navigateAfterDiscard')
  assert.match(navigate,
    /catch[\s\S]*this\.navigationRetryPending = true[\s\S]*识别结果已丢弃，请重试返回导入页面/)
  assert.doesNotMatch(navigate, /识别结果仍已保留/)
  assert.doesNotMatch(navigate, /PdfImportState\.shared\(\)\.reset\(\)/)
  const retry = extractMethod(source, 'private retryDiscardNavigation')
  assert.match(retry, /this\.navigateAfterDiscard\(\)/)
  assert.match(source, /if \(this\.navigationRetryPending\)[\s\S]*重试返回导入页面/)
})

test('saved question source images render only when present and use stable image identifiers', () => {
  const source = fs.readFileSync('entry/src/main/ets/components/QuestionSourceImages.ets', 'utf8')
  assert.match(source, /@Prop images:\s*Array<QuestionImage>\s*=\s*new Array<QuestionImage>\(\)/)
  assert.match(source, /if \(this\.images\.length > 0\)/)
  assert.match(source, /Text\('原题图片'\)/)
  assert.match(source, /Image\('file:\/\/' \+ image\.imagePath\)/)
  assert.match(source, /\.width\('100%'\)/)
  assert.match(source, /\.objectFit\(ImageFit\.Contain\)/)
  assert.match(source, /\(image: QuestionImage\): string => image\.id/)
})

test('question detail reloads on page show, renders source before OCR, and opens editing for selected question', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/QuestionDetailPage.ets', 'utf8')
  const show = extractMethod(source, 'onPageShow')
  assert.match(show, /this\.loadCurrentQuestion\(\)/)
  assertOrdered(source, [
    'QuestionSourceImages({',
    'images: this.currentQuestion.images',
    'Text(this.currentQuestion.question)'
  ])
  assert.match(source, /this\.currentQuestion\.answer\.length === 0 \? '未填写'/)
  assert.match(source, /this\.currentQuestion\.analysis\.length === 0 \? '暂无解析'/)
  const edit = extractMethod(source, 'private openEditor')
  assert.match(edit, /NavigationState\.shared\(\)\.selectedQuestionId/)
  assert.match(edit, /url: 'pages\/EditQuestionPage'/)
  assert.match(source, /Button\('编辑题目'\)/)
})

test('question list cards show pending review only for questions that need review', () => {
  const card = fs.readFileSync('entry/src/main/ets/components/QuestionCard.ets', 'utf8')
  assert.match(card, /@Prop needsReview:\s*boolean\s*=\s*false/)
  assert.match(card, /if \(this\.needsReview\)[\s\S]*Text\('待确认'\)/)
  const list = fs.readFileSync('entry/src/main/ets/pages/QuestionListPage.ets', 'utf8')
  assert.match(list, /needsReview:\s*question\.needsReview\(\)/)
  const typeLabel = extractMethod(list, 'private cardTypeLabel')
  assert.match(typeLabel, /question\.type === 'unclassified'[\s\S]*return '未分类题'/)
  assert.match(list, /typeLabel:\s*this\.cardTypeLabel\(question\)/)
})

test('saved question editor clones all editable fields but preserves source image ownership', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/EditQuestionPage.ets', 'utf8')
  assert.match(source, /@State sourceImages:\s*Array<QuestionImage>/)
  assert.match(source, /QuestionSourceImages\(\{\s*images: this\.sourceImages\s*\}\)/)
  assert.match(source, /TextArea\(\{ placeholder: '请输入题干', text: this\.questionText \}\)/)
  assert.match(source, /TextInput\(\{ placeholder: '选项 '/)
  assert.match(source, /TextInput\(\{ placeholder: '答案（选填）'/)
  assert.match(source, /TextArea\(\{ placeholder: '解析（选填）'/)
  assert.match(source, /Button\('保存修改'\)/)
  const load = extractMethod(source, 'private async loadQuestion')
  assert.match(load, /question\.images\.slice\(\)/)
  const save = extractMethod(source, 'private async saveQuestion')
  assert.match(save, /this\.questionText\.trim\(\)\.length === 0/)
  assertOrdered(save, [
    'new Question(',
    'this.sourceImages.slice()',
    'QuestionBankService.updateQuestion(updatedQuestion)',
    "this.showToast('修改已保存')",
    'this.getUIContext().getRouter().back()'
  ])
  assert.doesNotMatch(source, /QuestionImageService|deletePaths|commitImages/)
  assert.match(source, /if \(this\.pending \|\| this\.navigationPending\)/)
})

test('bank deletion commits database first then tracks only structured image cleanup failures', () => {
  const imageSource = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  assert.match(imageSource, /export class QuestionImageCleanupError extends Error/)
  assert.match(imageSource, /readonly paths:\s*Array<string>/)
  const deletion = extractMethod(imageSource, 'static async deletePaths')
  assert.match(deletion, /const failedPaths:\s*Array<string>/)
  assert.match(deletion, /failedPaths\.push\(path\)/)
  assert.match(deletion, /throw new QuestionImageCleanupError\(/)

  const books = fs.readFileSync('entry/src/main/ets/pages/BooksPage.ets', 'utf8')
  assert.match(books, /QuestionImageCleanupError/)
  const persist = extractMethod(books, 'private async persistBankDeletion')
  assertOrdered(persist, [
    'QuestionBankService.deleteBank(bankId)',
    'QuestionImageService.deletePaths(getContext(this), imagePaths)',
    'QuestionImageService.rememberCleanupDebt(err.paths)',
    "this.showToast('题库已删除，部分缓存稍后清理')",
    'this.refreshWhenActive()'
  ])
  assert.doesNotMatch(persist, /rememberCleanupDebt\(imagePaths\)/)
})

test('question list reloads the active query on page show and lazily renders a fully notified data source', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/QuestionListPage.ets', 'utf8')
  assert.doesNotMatch(source, /aboutToAppear\(\)/)
  const show = extractMethod(source, 'onPageShow')
  assert.match(show, /NavigationState\.shared\(\)\.selectedBankId/)
  assert.match(show, /this\.query\.trim\(\)\.length === 0[\s\S]*this\.loadBank\(\)[\s\S]*this\.search\(this\.query\)/)
  assert.match(source, /class QuestionListDataSource implements IDataSource/)
  assert.match(source, /private listeners:\s*Array<DataChangeListener>/)
  const replace = extractMethod(source, 'replaceAll')
  assert.match(replace, /this\.items = items\.slice\(\)/)
  assert.match(replace, /listener\.onDataReloaded\(\)/)
  assert.match(source, /registerDataChangeListener\(listener: DataChangeListener\)/)
  assert.match(source, /unregisterDataChangeListener\(listener: DataChangeListener\)/)
  assert.match(source, /private readonly questionDataSource:\s*QuestionListDataSource/)
  assert.match(source, /LazyForEach\(this\.questionDataSource/)
  assert.match(source, /\(question: Question\): string => question\.id/)
  assert.doesNotMatch(source, /ForEach\(this\.questions/)
  const load = extractMethod(source, 'private loadBank')
  const search = extractMethod(source, 'private search')
  assert.match(load, /this\.replaceQuestions\(new Array<Question>\(\)\)/)
  assert.match(search, /this\.replaceQuestions\(new Array<Question>\(\)\)/)
})

test('list and search queries do not serially hydrate source images while detail still does', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionBankService.ets', 'utf8')
  const query = extractMethod(source, 'private static async queryQuestions')
  assert.doesNotMatch(query, /listQuestionImages|for \(let index:[\s\S]*await/)
  const detail = extractMethod(source, 'static async getQuestion')
  assert.match(detail, /question\.images = await QuestionBankService\.listQuestionImages\(question\.id\)/)
})

test('bank deletion durably records exact image debt inside the same transaction before deleting rows', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionBankService.ets', 'utf8')
  const deletion = extractMethod(source, 'static async deleteBank')
  assert.match(deletion, /transaction\.querySql\(/)
  assert.doesNotMatch(deletion, /store\.querySql\(/)
  assertOrdered(deletion, [
    'await store.createTransaction()',
    'transaction.querySql(',
    'imagePaths.push(imagePath)',
    'INSERT OR IGNORE INTO question_image_cleanup_debt',
    'DELETE FROM question_image',
    'await transaction.commit()',
    'return imagePaths'
  ])
  assert.match(deletion, /create_time/)
})

test('cleanup retry merges exact durable debt, protects live references, and clears debt only after safe cleanup', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  const listDebt = extractMethod(source, 'private static async listPersistentCleanupDebt')
  assert.match(listDebt, /SELECT path FROM question_image_cleanup_debt/)
  assert.match(listDebt, /finally[\s\S]*resultSet\.close\(\)/)
  const clearDebt = extractMethod(source, 'private static async removePersistentCleanupDebt')
  assert.match(clearDebt, /new relationalStore\.RdbPredicates\('question_image_cleanup_debt'\)/)
  assert.match(clearDebt, /predicates\.equalTo\('path', path\)/)
  const referenced = extractMethod(source, 'private static async isQuestionImageReferenced')
  assert.match(referenced, /SELECT COUNT\(\*\) FROM question_image WHERE image_path = \?/)
  const retry = extractMethod(source, 'private static async performCleanupDebtRetry')
  assertOrdered(retry, [
    'QuestionImageService.listPersistentCleanupDebt()',
    'candidatePaths.push(path)',
    'QuestionImageService.isQuestionImageReferenced(path)',
    'await fs.unlink(path)',
    'QuestionImageService.removeEmptyCommittedBankDirectory(context, path)',
    'QuestionImageService.removePersistentCleanupDebt(path)',
    'QuestionImageService.removeCleanupDebt([path])'
  ])
  assert.match(retry, /isQuestionImageReferenced\(path\)[\s\S]*failures\.push/)
  assert.doesNotMatch(retry, /listFile\([^)]*question_images/)
})

test('direct image deletion clears durable debt after safe absence or unlink and retries empty bank directory cleanup', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  const deletion = extractMethod(source, 'static async deletePaths')
  assertOrdered(deletion, [
    'QuestionImageService.ownedDeletionRoot(context, path)',
    'QuestionImageService.isQuestionImageReferenced(path)',
    'QuestionImageService.validateExistingFileChain(ownedRoot, path)',
    'await fs.unlink(path)',
    'QuestionImageService.removeEmptyCommittedBankDirectory(context, path)',
    'QuestionImageService.removePersistentCleanupDebt(path)'
  ])
  assert.match(deletion, /rootInfo === null[\s\S]*removePersistentCleanupDebt\(path\)/)
  const removeDirectory = extractMethod(source, 'private static async removeEmptyCommittedBankDirectory')
  assert.match(removeDirectory, /context\.filesDir \+ '\/question_images'/)
  assert.match(removeDirectory, /parts\.length !== 2/)
  assert.match(removeDirectory, /QuestionImageService\.validateSafeIdentifier\(bankId/)
  assert.match(removeDirectory, /QuestionImageService\.isSymbolicLink\(directoryInfo\)/)
  assert.match(removeDirectory, /await fs\.listFile\(bankDirectory, options\)/)
  assert.match(removeDirectory, /entries\.length === 0[\s\S]*await fs\.rmdir\(bankDirectory\)/)
})

test('review discard retains recoverable ownership until both crop and staged PDF cleanup finish', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  assert.match(source, /private cleanupPdfPath:\s*string/)
  const discard = extractMethod(source, 'private async performDiscard')
  assertOrdered(discard, [
    'PdfImportState.shared().getSelection()',
    'this.collectDraftImagePaths()',
    'await QuestionImageService.deletePaths(getContext(this), paths)',
    'await PdfImportService.removeTemporaryPdf(selection.uri)',
    'this.cleanupPaths.length > 0 || this.cleanupPdfPath.length > 0',
    'PdfImportState.shared().reset()',
    'this.navigateAfterDiscard()'
  ])
  const retry = extractMethod(source, 'private async retryDiscardCleanup')
  assert.match(retry, /QuestionImageService\.deletePaths\(getContext\(this\), this\.cleanupPaths\)/)
  assert.match(retry, /PdfImportService\.removeTemporaryPdf\(this\.cleanupPdfPath\)/)
  assert.match(retry, /this\.cleanupPaths\.length > 0 \|\| this\.cleanupPdfPath\.length > 0/)
  const defer = extractMethod(source, 'private async rememberDebtAndDiscard')
  assert.match(defer, /QuestionImageService\.rememberCleanupDebt\(this\.cleanupPaths\)/)
  assert.match(defer, /PdfImportService\.abandonTemporaryPdf\(this\.cleanupPdfPath\)/)
  assertOrdered(defer, [
    'QuestionImageService.rememberCleanupDebt(this.cleanupPaths)',
    'PdfImportService.abandonTemporaryPdf(this.cleanupPdfPath)',
    'PdfImportState.shared().reset()',
    'this.navigateAfterDiscard()'
  ])
})

test('each acquired crop page is released from its page ownership finally block', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/PdfImportCoordinator.ets', 'utf8')
  const run = extractMethod(source, 'private static async runSnapshot')
  const cropStart = run.indexOf('const cropJobs: Array<CropJob>')
  const cropEnd = run.indexOf('PdfImportCoordinator.appendCropPaths')
  assert.ok(cropStart >= 0 && cropEnd > cropStart, 'crop ownership block must exist')
  const cropOwnership = run.slice(cropStart, cropEnd)
  assert.doesNotMatch(cropOwnership,
    /if \(cropPage !== null\)[\s\S]{0,180}cropPage = null[\s\S]{0,120}pageToRelease\.release\(\)[\s\S]{0,120}cropPage = pdfDocument\.getPage/)
  assert.match(cropOwnership,
    /activeCropPage:\s*pdfService\.PdfPage = pdfDocument\.getPage[\s\S]*finally\s*{[\s\S]*pageToRelease\.release\(\)/)
})

test('PDF import maps every approved user-visible failure without generic catch replacement', () => {
  const importPage = fs.readFileSync('entry/src/main/ets/pages/ImportBankPage.ets', 'utf8')
  const progressPage = fs.readFileSync('entry/src/main/ets/pages/PdfImportProgressPage.ets', 'utf8')
  const reviewPage = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  assert.ok(importPage.includes('PDF 文件不能超过 200 MB'))
  assert.ok(importPage.includes('暂不支持加密 PDF'))
  assert.ok(importPage.includes('PDF 文件损坏或格式不受支持'))
  assert.ok(progressPage.includes('当前设备不支持端侧文字识别，请使用鸿蒙真机重试'))
  assert.ok(reviewPage.includes('部分页面识别失败，请检查标记页'))
  assert.ok(reviewPage.includes('本地空间不足或图片保存失败'))
  assert.ok(progressPage.includes('PDF 导入失败，请重新选择文件'))
  const importMapping = extractMethod(importPage, 'private messageForPdfError')
  assertOrdered(importMapping, [
    "message.includes('加密')",
    "return '暂不支持加密 PDF'",
    "message.includes('解析')",
    "return 'PDF 文件损坏或格式不受支持'",
    "message.includes('大小')",
    "return 'PDF 文件不能超过 200 MB'",
    "return 'PDF 导入失败，请重新选择文件'"
  ])
  const progressMapping = extractMethod(progressPage, 'private messageForError')
  const progressMessageMapping = extractMethod(progressPage, 'private messageForErrorMessage')
  assert.match(progressMessageMapping,
    /当前设备不支持端侧文字识别，请使用鸿蒙真机重试/)
  assert.match(progressMessageMapping, /PDF 文件损坏或格式不受支持/)
  assert.match(progressMapping, /本地空间不足或图片保存失败/)
  assert.match(progressMessageMapping, /PDF 导入失败，请重新选择文件/)
})

test('PDF import manifest allows INTERNET but device pipeline contains no network client', () => {
  const moduleSource = fs.readFileSync('entry/src/main/module.json5', 'utf8')
  const pipelineSource = [
    'entry/src/main/ets/services/PdfImportService.ets',
    'entry/src/main/ets/services/PdfImportCoordinator.ets',
    'entry/src/main/ets/services/OnDeviceOcrService.ets',
    'entry/src/main/ets/services/QuestionImageService.ets'
  ].map((file) => fs.readFileSync(file, 'utf8')).join('\n')
  assert.ok(moduleSource.includes('ohos.permission.INTERNET'))
  assert.doesNotMatch(pipelineSource, /@kit\.NetworkKit|@ohos\.net\.|createHttp|HttpClient/)
})

test('temporary PDF deletion is an idempotent direct-child operation under its registered cache root', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/PdfImportService.ets', 'utf8')
  assert.match(source, /private static readonly stagedCacheDirs:\s*Array<string>/)
  const selectPdf = extractMethod(source, 'static async selectPdf')
  assert.match(selectPdf, /PdfImportService\.registerStagedPath\(candidate\.uri, context\.cacheDir\)/)
  assert.match(selectPdf, /PdfImportService\.cleanupFailedTemporaryPdf\(context\.cacheDir, tempPath\)/)
  const removal = extractMethod(source, 'static async removeTemporaryPdf')
  assertOrdered(removal, [
    'PdfImportService.registeredCacheDir(path)',
    'PdfImportService.isDirectTemporaryPdfPath(cacheDir, path)',
    'PdfImportService.validateExistingTemporaryPdf(cacheDir, path)',
    'await fs.unlink(path)',
    'PdfImportService.unregisterStagedPath(path)'
  ])
  const validation = extractMethod(source, 'private static async validateExistingTemporaryPdf')
  assert.match(validation, /PdfImportService\.validateCacheDirectory\(cacheDir\)/)
  const cacheValidation = extractMethod(source, 'private static async validateCacheDirectory')
  assert.match(cacheValidation, /PdfImportService\.lstatIfPresent\(cacheDir\)/)
  assert.match(cacheValidation, /cacheInfo\.isSymbolicLink\(\) \|\| !cacheInfo\.isDirectory\(\)/)
  assert.match(validation, /PdfImportService\.lstatIfPresent\(path\)/)
  assert.match(validation, /fileInfo === null[\s\S]*return false/)
  assert.match(validation, /fileInfo\.isSymbolicLink\(\) \|\| !fileInfo\.isFile\(\)/)
  const pathCheck = extractMethod(source, 'private static isDirectTemporaryPdfPath')
  assert.match(pathCheck, /path\.startsWith\(prefix\)/)
  assert.match(pathCheck, /name\.indexOf\('\/'\) < 0/)
  assert.match(pathCheck, /name\.indexOf\('\\\\'\) < 0/)
  assert.match(pathCheck, /PdfImportService\.isTemporaryPdfName\(name\)/)
})

test('oversized OCR bitmap and platform OCR session release from finally ownership boundaries', () => {
  const coordinatorSource = fs.readFileSync('entry/src/main/ets/services/PdfImportCoordinator.ets', 'utf8')
  const renderer = extractMethod(coordinatorSource, 'private static async renderOcrPixelMap')
  const oversized = renderer.slice(renderer.indexOf('const originalToRelease: image.PixelMap'))
  assert.match(oversized,
    /const originalToRelease:\s*image\.PixelMap[\s\S]*try\s*{[\s\S]*finally\s*{[\s\S]*await originalToRelease\.release\(\)[\s\S]*page\.getAreaPixelMapWithOptions/)
  const ocrSource = fs.readFileSync('entry/src/main/ets/services/OnDeviceOcrService.ets', 'utf8')
  const release = extractMethod(ocrSource, 'private async performRelease')
  assert.match(release, /await this\.lifecycle\.beginRelease\(\)/)
  assert.match(release, /finally\s*{[\s\S]*await textRecognition\.release\(\)/)
  assert.match(release, /finishRelease\(true\)/)
  assert.match(release, /finishRelease\(false\)/)
})

test('question image deletion accepts only exact service cache files or exact bank image hierarchy', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  const ownership = extractMethod(source, 'private static ownedDeletionRoot')
  assert.match(ownership, /QuestionImageService\.isDirectServiceImagePath\(context\.cacheDir, path\)/)
  assert.match(ownership, /const relative:\s*string = path\.substring\(committedRoot\.length \+ 1\)/)
  assert.match(ownership, /const parts:\s*Array<string> = relative\.split\('\/'\)/)
  assert.match(ownership, /parts\.length !== 2/)
  assert.match(ownership, /QuestionImageService\.isSafeIdentifierValue\(parts\[0\]\)/)
  assert.match(ownership, /QuestionImageService\.isCleanupCandidateName\(parts\[1\]\)/)
  assert.doesNotMatch(ownership,
    /if \(QuestionImageService\.isNormalizedDescendant\(path, committedRoot\)\)\s*{\s*return context\.filesDir/)
  const deletion = extractMethod(source, 'static async deletePaths')
  assert.match(deletion,
    /ownedRoot\.length === 0[\s\S]*failedPaths\.push\(path\)[\s\S]*路径不属于题图存储目录[\s\S]*continue/)
  const cacheCheck = extractMethod(source, 'private static isDirectServiceImagePath')
  assert.match(cacheCheck, /isNormalizedDescendant\(path, directory\)/)
  assert.match(cacheCheck, /name\.indexOf\('\/'\) < 0/)
  assert.match(cacheCheck, /isCleanupCandidateName\(name\)/)
  const normalization = extractMethod(source, 'private static isNormalizedDescendant')
  assert.match(normalization, /path\.indexOf\('\\\\'\) >= 0/)
  assert.match(normalization, /path\.indexOf\(String\.fromCharCode\(0\)\) >= 0/)
  assert.match(normalization, /relative\.indexOf\('\/\.\.\/'\) >= 0/)
  assert.match(normalization, /relative\.indexOf\('\/\.\/'\) >= 0/)
  const fileNameCheck = extractMethod(source, 'private static isCleanupCandidateName')
  assert.match(fileNameCheck, /!name\.startsWith\('pdf_question_'\)/)
  assert.match(fileNameCheck, /!name\.endsWith\('\.jpg'\)/)
  assert.match(fileNameCheck, /QuestionImageService\.isSafeIdentifierCode\(code\)/)
})

test('unknown or malformed PDF ownership throws and only strict registered staged files can be abandoned', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/PdfImportService.ets', 'utf8')
  const removal = extractMethod(source, 'static async removeTemporaryPdf')
  assert.match(removal,
    /cacheDir\.length === 0[\s\S]*throw new Error\('PDF 临时文件不属于当前导入任务'\)/)
  assert.doesNotMatch(removal, /cacheDir\.length === 0[\s\S]{0,160}return/)
  assert.match(removal,
    /!PdfImportService\.isDirectTemporaryPdfPath\(cacheDir, path\)[\s\S]*throw new Error\('PDF 临时文件路径无效'\)/)
  const abandon = extractMethod(source, 'static abandonTemporaryPdf')
  assert.match(abandon, /const stagedIndex:\s*number = PdfImportService\.stagedPaths\.indexOf\(path\)/)
  assert.match(abandon,
    /stagedIndex < 0[\s\S]*PdfImportService\.isRegisteredOrphanPath\(path\)[\s\S]*throw new Error\('PDF 临时文件不属于当前导入任务'\)/)
  assert.match(abandon, /PdfImportService\.isDirectTemporaryPdfPath\(cacheDir, path\)/)
  assertOrdered(abandon, [
    'const stagedIndex: number = PdfImportService.stagedPaths.indexOf(path)',
    'PdfImportService.registerOrphanPath(path, cacheDir)',
    'PdfImportService.unregisterStagedPath(path)'
  ])
  const nameCheck = extractMethod(source, 'private static isTemporaryPdfName')
  assert.match(nameCheck, /const prefix:\s*string = 'staged_pdf_'/)
  assert.doesNotMatch(nameCheck, /pdf_import_/)
  assert.match(source, /context\.cacheDir \+ '\/staged_pdf_' \+ Date\.now\(\)\.toString\(\) \+ '\.pdf'/)
  const orphanRegistration = extractMethod(source, 'private static registerOrphanPath')
  assert.match(orphanRegistration,
    /!PdfImportService\.isDirectTemporaryPdfPath\(cacheDir, path\)[\s\S]*throw new Error\('PDF 遗留临时文件路径无效'\)/)
  assert.doesNotMatch(orphanRegistration,
    /!PdfImportService\.isDirectTemporaryPdfPath\(cacheDir, path\)[\s\S]{0,100}return/)
})

test('progress preserves staged PDF through review and review terminates ownership after save or discard', () => {
  const progressSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportProgressPage.ets', 'utf8')
  const run = extractMethod(progressSource, 'private async runImport')
  const completionStart = run.indexOf('state.setDrafts(result.drafts)')
  const completionEnd = run.indexOf('} catch (err)')
  assert.ok(completionStart >= 0 && completionEnd > completionStart)
  const completion = run.slice(completionStart, completionEnd)
  assert.doesNotMatch(completion, /removeTemporaryPdf|abandonTemporaryPdf/)
  assert.match(completion, /this\.navigateToReview\(\)/)
  assert.doesNotMatch(progressSource, /complete-pdf/)
  assert.match(run,
    /this\.failed = true\s*this\.cleanupResolvedMessage = this\.messageForError\(err\)[\s\S]*await PdfImportService\.removeTemporaryPdf\(selection\.uri\)[\s\S]*await this\.navigateToImportBank\(\)/)
  const finishProgressCleanup = extractMethod(progressSource, 'private async finishCleanup')
  assert.match(finishProgressCleanup,
    /this\.cleanupMode === 'fatal-images'[\s\S]*this\.cleanupMode = 'fatal-pdf'/)

  const reviewSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  const success = extractMethod(reviewSource, 'private async completeSuccessfulSave')
  assertOrdered(success, [
    'this.saveCompleted = true',
    'await this.finishSuccessfulPdfOwnership()',
    'await this.finalizeSuccessfulSave()'
  ])
  const finalizeSuccess = extractMethod(reviewSource, 'private async finalizeSuccessfulSave')
  assertOrdered(finalizeSuccess, [
    'PdfImportState.shared().reset()',
    "this.showToast('题库导入成功')"
  ])
  const ownership = extractMethod(reviewSource, 'private async finishSuccessfulPdfOwnership')
  assert.match(ownership, /PdfImportState\.shared\(\)\.getSelection\(\)/)
  assert.match(ownership, /await PdfImportService\.removeTemporaryPdf\(selection\.uri\)/)
  assert.match(ownership, /catch[\s\S]*PdfImportService\.abandonTemporaryPdf\(selection\.uri\)/)
  assert.match(ownership, /this\.postSaveWarning = 'PDF 临时文件将在下次选择 PDF 时继续清理'/)
  const discard = extractMethod(reviewSource, 'private async performDiscard')
  assertOrdered(discard, [
    'await QuestionImageService.deletePaths(getContext(this), paths)',
    'await PdfImportService.removeTemporaryPdf(selection.uri)',
    'PdfImportState.shared().reset()'
  ])
  const uncertain = extractMethod(reviewSource, 'private async resolveUncertainSave')
  assert.doesNotMatch(uncertain, /removeTemporaryPdf|abandonTemporaryPdf/)
  const rollback = extractMethod(reviewSource, 'private async retryRollback')
  assert.doesNotMatch(rollback, /removeTemporaryPdf|abandonTemporaryPdf/)
})

test('current schema durably records exact rollback mappings and retry restores mappings without committed scans', () => {
  const database = fs.readFileSync('entry/src/main/ets/services/DatabaseService.ets', 'utf8')
  assert.match(database, /const SCHEMA_VERSION:\s*number = 5/)
  assert.match(database, /CREATE TABLE IF NOT EXISTS question_image_rollback_debt/)
  assert.match(database, /final_path TEXT PRIMARY KEY/)
  assert.match(database, /cache_path TEXT NOT NULL/)
  assert.match(database, /bank_id TEXT NOT NULL/)
  assert.match(database, /else if \(version === 3\)[\s\S]*migrateVersionThree\(store\)/)
  const create = extractMethod(database, 'private static async createSchema')
  assert.match(create, /CREATE_QUESTION_IMAGE_ROLLBACK_DEBT/)
  const migrate = extractMethod(database, 'private static async migrateVersionThree')
  assert.match(migrate, /CREATE_QUESTION_IMAGE_ROLLBACK_DEBT/)
  assert.match(migrate, /transaction\.commit\(\)/)

  const images = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  const commit = extractMethod(images, 'static async commitImages')
  assert.match(commit,
    /rollbackErrors\.length > 0[\s\S]*await QuestionImageService\.registerRollbackDebt\([\s\S]*throw new QuestionImageRollbackError/)
  const rollback = extractMethod(images, 'static async rollbackCommittedImages')
  assert.match(rollback,
    /failures\.length > 0[\s\S]*await QuestionImageService\.registerRollbackDebt\([\s\S]*throw new QuestionImageRollbackError/)
  assert.match(rollback, /await QuestionImageService\.removeRollbackDebt\(committedPaths\)/)
  const list = extractMethod(images, 'private static async listRollbackDebt')
  assert.match(list, /SELECT final_path, cache_path, bank_id FROM question_image_rollback_debt/)
  assert.match(list, /finally[\s\S]*resultSet\.close\(\)/)
  const retry = extractMethod(images, 'private static async performRollbackDebtRetry')
  assert.match(retry, /QuestionImageService\.listRollbackDebt\(\)/)
  assert.match(retry, /QuestionImageService\.isQuestionImageReferenced\(record\.finalPath\)/)
  assert.match(retry, /finalInfo !== null && cacheInfo === null[\s\S]*fs\.moveFile\(record\.finalPath, record\.cachePath, 1\)/)
  assert.match(retry, /finalInfo === null && cacheInfo !== null[\s\S]*removeRollbackDebt\(\[record\.finalPath\]\)/)
  assert.match(retry, /finalInfo !== null && cacheInfo !== null[\s\S]*两端文件同时存在/)
  assert.match(retry, /finalInfo === null && cacheInfo === null[\s\S]*两端文件均不存在/)
  assert.doesNotMatch(retry, /listFile\([^)]*question_images|fs\.listFile\(committedRoot/)
  const cleanup = extractMethod(images, 'private static async performCleanupDebtRetry')
  assertOrdered(cleanup, [
    'await QuestionImageService.performRollbackDebtRetry(context)',
    'await QuestionImageService.listPersistentCleanupDebt()'
  ])
  const importPage = fs.readFileSync('entry/src/main/ets/pages/ImportBankPage.ets', 'utf8')
  const appear = extractMethod(importPage, 'aboutToAppear')
  assert.match(appear, /this\.retryImageCleanup\(\)/)
})

test('structured PDF storage errors are classified before message heuristics', () => {
  const errorSource = fs.readFileSync('entry/src/main/ets/services/PdfStorageError.ets', 'utf8')
  assert.match(errorSource, /export class PdfStorageError extends Error/)
  assert.match(errorSource, /super\('本地空间不足或图片保存失败'\)/)
  const imageSource = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  const crop = extractMethod(imageSource, 'static async saveCrop')
  assert.match(crop, /throw new PdfStorageError\(operationError\)/)
  const importSource = fs.readFileSync('entry/src/main/ets/services/PdfImportService.ets', 'utf8')
  assert.match(importSource, /new PdfStorageError\(/)
  const coordinatorSource = fs.readFileSync('entry/src/main/ets/services/PdfImportCoordinator.ets', 'utf8')
  assert.match(coordinatorSource,
    /primaryError instanceof PdfStorageError[\s\S]*throw new PdfStorageError\(primaryError\.diagnostic\)/)
  const progressSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportProgressPage.ets', 'utf8')
  const progressMapping = extractMethod(progressSource, 'private messageForError')
  const progressMessageMapping = extractMethod(progressSource, 'private messageForErrorMessage')
  assertOrdered(progressMapping, [
    'if (err instanceof PdfStorageError)',
    "return '本地空间不足或图片保存失败'",
    'return this.messageForErrorMessage(err.message)'
  ])
  assertOrdered(progressMessageMapping, [
    "message.includes('OCR')"
  ])
  const importPageSource = fs.readFileSync('entry/src/main/ets/pages/ImportBankPage.ets', 'utf8')
  const importMapping = extractMethod(importPageSource, 'private messageForPdfError')
  assertOrdered(importMapping, [
    'if (err instanceof PdfStorageError)',
    "return '本地空间不足或图片保存失败'",
    "message.includes('加密')"
  ])
})

test('crop aggregation preserves PdfStorageError after cancellation and cleanup diagnostics', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/PdfImportCoordinator.ets', 'utf8')
  const run = extractMethod(source, 'private static async runSnapshot')
  const cropStart = run.indexOf('if (cropError !== null || cropCleanupError.length > 0)')
  const cropEnd = run.indexOf('PdfImportCoordinator.appendCropPaths', cropStart)
  assert.ok(cropStart >= 0 && cropEnd > cropStart)
  const aggregate = run.slice(cropStart, cropEnd)
  assertOrdered(aggregate, [
    'if (cropError instanceof PdfImportCancelledError)',
    'throw new PdfImportCancelledError(combinedMessage)',
    'if (cropError instanceof PdfStorageError)',
    'cropError.diagnostic.length > 0 ?',
    'cropError.diagnostic',
    ": '题图生成失败'",
    'PdfImportCoordinator.appendDiagnostic(storageDiagnostic, cropCleanupError)',
    'throw new PdfStorageError(mergedDiagnostic)'
  ])
  assert.match(aggregate,
    /if \(cropError instanceof PdfStorageError\)[\s\S]*cropError\.diagnostic[\s\S]*cropCleanupError[\s\S]*new PdfStorageError\(mergedDiagnostic\)/)
  assert.doesNotMatch(aggregate,
    /cropError instanceof PdfStorageError[\s\S]{0,100}new PdfStorageError\(combinedMessage\)/)
})

test('abandon failures retain ownership and post-save dual failure enters recovery-only state', () => {
  const progressSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportProgressPage.ets', 'utf8')
  const abandonProgress = extractMethod(progressSource, 'private async abandonCleanupAndContinue')
  assert.match(abandonProgress,
    /try[\s\S]*PdfImportService\.abandonTemporaryPdf\(selection\.uri\)[\s\S]*catch[\s\S]*this\.cleaning = false[\s\S]*PDF 临时文件登记失败[\s\S]*return/)
  const progressCatchStart = abandonProgress.indexOf('catch')
  const progressCatchEnd = abandonProgress.indexOf('await this.navigateToImportBank()', progressCatchStart)
  const progressCatch = abandonProgress.slice(progressCatchStart, progressCatchEnd)
  assert.doesNotMatch(progressCatch, /navigateToImportBank|reset\(\)|cleanupMode = ''/)

  const reviewSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  const abandonDiscard = extractMethod(reviewSource, 'private async rememberDebtAndDiscard')
  assert.match(abandonDiscard,
    /try[\s\S]*PdfImportService\.abandonTemporaryPdf\(this\.cleanupPdfPath\)[\s\S]*catch[\s\S]*this\.discarding = false[\s\S]*this\.pending = false[\s\S]*return/)
  const reviewCatchStart = abandonDiscard.indexOf('catch')
  const reviewCatchEnd = abandonDiscard.indexOf("this.cleanupPaths = new Array<string>()", reviewCatchStart)
  const reviewCatch = abandonDiscard.slice(reviewCatchStart, reviewCatchEnd)
  assert.doesNotMatch(reviewCatch, /PdfImportState\.shared\(\)\.reset|navigateAfterDiscard|cleanupPdfPath = ''/)

  assert.match(reviewSource, /@State postSavePdfCleanupPending:\s*boolean = false/)
  assert.match(reviewSource, /private postSavePdfPath:\s*string = ''/)
  const complete = extractMethod(reviewSource, 'private async completeSuccessfulSave')
  assertOrdered(complete, [
    'this.saveCompleted = true',
    'const ownershipFinished: boolean = await this.finishSuccessfulPdfOwnership()',
    'if (!ownershipFinished)',
    'this.postSavePdfCleanupPending = true',
    'return',
    'await this.finalizeSuccessfulSave()'
  ])
  assert.doesNotMatch(complete, /PdfImportState\.shared\(\)\.reset|replaceUrl/)
  const ownership = extractMethod(reviewSource, 'private async finishSuccessfulPdfOwnership')
  const dualFailure = ownership.slice(ownership.lastIndexOf('catch'))
  assert.match(dualFailure, /this\.postSavePdfPath = selection\.uri/)
  assert.match(dualFailure, /return false/)
  assert.doesNotMatch(dualFailure, /reset\(\)|replaceUrl|postSavePdfPath = ''/)
  const finalize = extractMethod(reviewSource, 'private async finalizeSuccessfulSave')
  assertOrdered(finalize, [
    'this.postSavePdfCleanupPending = false',
    'PdfImportState.shared().reset()',
    'NavigationState.shared().selectBank(this.savedBankId)',
    'replaceUrl(options)'
  ])
  const retry = extractMethod(reviewSource, 'private async retryPostSavePdfCleanup')
  assert.match(retry, /await PdfImportService\.removeTemporaryPdf\(this\.postSavePdfPath\)/)
  assert.match(retry, /catch[\s\S]*this\.postSavePdfCleanupPending = true[\s\S]*this\.pending = false/)
  const defer = extractMethod(reviewSource, 'private async deferPostSavePdfCleanup')
  assertOrdered(defer, [
    'PdfImportService.abandonTemporaryPdf(this.postSavePdfPath)',
    "this.postSavePdfPath = ''",
    'await this.finalizeSuccessfulSave()'
  ])
  assert.match(reviewSource, /题库已保存，请完成 PDF 临时文件清理/)
  assert.match(reviewSource, /Button\(this\.pending \? '正在清理…' : '重试清理并完成'\)/)
  assert.match(reviewSource, /Button\('稍后处理'\)/)
})

test('ArkTS compiler blockers use narrowed throws nominal messages and supported text sizing', () => {
  const progressSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportProgressPage.ets', 'utf8')
  const finishCleanup = extractMethod(progressSource, 'private async finishCleanup')
  assert.match(finishCleanup,
    /catch \(err\)[\s\S]*if \(err instanceof Error\)[\s\S]*throw err[\s\S]*throw new Error\('PDF 临时文件清理失败'\)/)
  const structuredCleanup = extractMethod(progressSource, 'private handleStructuredCleanupError')
  assert.match(structuredCleanup, /this\.messageForErrorMessage\(err\.message\)/)
  assert.match(progressSource, /private messageForErrorMessage\(message: string\): string/)

  const importSource = fs.readFileSync('entry/src/main/ets/pages/ImportBankPage.ets', 'utf8')
  const reviewSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  assert.doesNotMatch(importSource, /\.minHeight\(/)
  assert.doesNotMatch(reviewSource, /\.minHeight\(/)
  assert.match(importSource, /\.constraintSize\(\{ minHeight: 48 \}\)/)
  assert.match(importSource, /\.constraintSize\(\{ minHeight: 44 \}\)/)
  assert.match(reviewSource, /\.constraintSize\(\{ minHeight: 48 \}\)/)
})
