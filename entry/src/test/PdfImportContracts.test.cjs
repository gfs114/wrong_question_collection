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
  assert.match(source, /SCHEMA_VERSION:\s*number\s*=\s*6/)
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

test('PDF import routes and cloud setup copy are registered', () => {
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
  for (const copy of ['导入 PDF', '选择科目', '起始页', '结束页', '单次最多识别 20 页']) {
    assert.match(source, new RegExp(copy))
  }
  assert.doesNotMatch(source, /正在识别第|取消识别/)
})

test('import page preserves JSON import and stages a guarded cloud PDF selection before setup routing', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/ImportBankPage.ets', 'utf8')
  const jsonImport = extractMethod(source, 'private startImport')
  const selectPdf = extractMethod(source, 'private async selectPdf')
  assert.match(jsonImport, /ImportService\.selectAndImport|this\.importBank\(\)/)
  assert.match(source, /选择 JSON 文件/)
  assert.match(source, /\.enabled\(!this\.importing && !this\.pdfSelecting\)/)
  assert.match(source, /CloudPdfSelection/)
  assert.match(source, /PdfImportState/)
  assert.doesNotMatch(selectPdf,
    /PdfImportService|QuestionImageService|OnDeviceOcrService|PdfImportCoordinator|\bpdfService\b/)
  assertOrdered(selectPdf, [
    'if (this.importing || this.pdfSelecting)',
    'this.pdfSelecting = true',
    "this.errorMessage = ''",
    'const sourceFile: fs.File = await fs.open',
    'await this.copyPdf(sourceFile.fd, stagedPath, sourceSize)',
    'const stagedInfo: fs.Stat = await fs.lstat(stagedPath)',
    'state.reset()',
    'state.setCloudSelection(new CloudPdfSelection',
    "url: 'pages/PdfImportSetupPage'"
  ])
  assert.match(selectPdf, /finally\s*{[\s\S]*this\.pdfSelecting = false/)
  assert.match(selectPdf, /let selectionStored:\s*boolean\s*=\s*false/)
  assert.match(selectPdf,
    /catch \(err\)[\s\S]*removeStagedPdf\(getContext\(this\)\.cacheDir, stagedPath\)[\s\S]*if \(selectionStored\)[\s\S]*PdfImportState\.shared\(\)\.reset\(\)/)
  assert.match(source, /PDF 文件不能超过 200 MB|PDF 暂存失败/)
})

test('PDF setup validates cloud metadata and page range before progress routing', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/PdfImportSetupPage.ets', 'utf8')
  assert.match(source, /@Entry[\s\S]*@Component/)
  assert.match(source, /@State bankName:\s*string/)
  assert.match(source, /@State subject:\s*string/)
  assert.match(source, /@State startPageText:\s*string/)
  assert.match(source, /@State endPageText:\s*string/)
  assert.match(source, /@State errorMessage:\s*string/)
  const appear = extractMethod(source, 'aboutToAppear')
  assert.match(appear, /PdfImportState\.shared\(\)/)
  assert.match(appear, /getCloudSelection\(\)/)
  assert.match(appear, /PdfImportValidator\.bankNameFromFileName/)
  const start = extractMethod(source, 'private async prepareCloudImport')
  assert.match(start, /\.trim\(\)/)
  assert.match(start, /isPositiveIntegerText/)
  assert.match(start, /Number\.parseInt/)
  assert.match(start, /PdfImportValidator\.validatePageRange/)
  assertOrdered(start, [
    'const session: AccountSessionState = await AccountSessionService.state(context)',
    'if (!session.signedIn',
    'if (!(await this.hasUsableNetwork()))',
    'await this.validatePdfFile(selection)',
    'new CloudImportUploadRequest',
    'CloudImportService.createJob(context, request)',
    'state.setCloudAccountId(session.userId)',
    'state.setCloudJob(job)',
    "url: 'pages/PdfImportProgressPage'"
  ])
  const back = extractMethod(source, 'private async finishLeaving')
  assertOrdered(back, [
    'if (state.getCloudJob() === null)',
    'await fs.unlink(selection.pdfPath)',
    'state.reset()',
    'this.getUIContext().getRouter().back()'
  ])
  assert.doesNotMatch(source, /CloudImportService\.cancel/)
  assert.match(source, /题库名/)
  assert.match(source, /数学[\s\S]*语文[\s\S]*英语[\s\S]*物理[\s\S]*化学[\s\S]*其他/)
})

// Task 11 cloud progress page behavior is covered by CloudImportPageContracts.test.cjs.

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

test('import entry serializes JSON and cloud PDF selection, blocks back, and grows errors', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/ImportBankPage.ets', 'utf8')
  const back = extractMethod(source, 'private goBack')
  const jsonImport = extractMethod(source, 'private startImport')
  const selectPdf = extractMethod(source, 'private async selectPdf')
  const hardwareBack = extractMethod(source, 'onBackPress')
  assert.match(back, /if \(this\.importing \|\| this\.pdfSelecting\)/)
  assert.match(jsonImport, /if \(this\.importing \|\| this\.pdfSelecting\)/)
  assert.match(selectPdf, /if \(this\.importing \|\| this\.pdfSelecting\)/)
  assert.doesNotMatch(selectPdf, /QuestionImageService|PdfImportService/)
  assertOrdered(hardwareBack, ['this.goBack()', 'return true'])
  assert.match(source, /\.constraintSize\(\{ minHeight: 48 \}\)/)
  assert.doesNotMatch(source, /Text\(this\.errorMessage\)[\s\S]{0,180}\.height\(48\)/)
})

// Obsolete local-OCR page ownership is covered by the Task 11 cloud page contract suite.

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

// Obsolete local-OCR page ownership is covered by the Task 11 cloud page contract suite.

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

// Obsolete local-OCR page ownership is covered by the Task 11 cloud page contract suite.

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

// Obsolete local-OCR page ownership is covered by the Task 11 cloud page contract suite.

// Obsolete local-OCR page ownership is covered by the Task 11 cloud page contract suite.

// Obsolete local-OCR page ownership is covered by the Task 11 cloud page contract suite.

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

test('partial image commit rollback failure preserves structured recoverable ownership', () => {
  const imageSource = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  const commit = extractMethod(imageSource, 'static async commitImages')
  assert.match(commit, /const expectedCommittedPaths:\s*Array<string>/)
  assert.match(commit,
    /rollbackErrors\.length > 0[\s\S]*throw new QuestionImageRollbackError\([\s\S]*bankId[\s\S]*paths[\s\S]*expectedCommittedPaths/)
  const rollback = extractMethod(imageSource, 'static async rollbackCommittedImages')
  assert.match(rollback,
    /committedInfo === null[\s\S]*cacheInfo === null[\s\S]*continue[\s\S]*cacheInfo !== null[\s\S]*已被占用/)
})

test('uncertain PDF bank save exports exact three-state verification', () => {
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
})

// Obsolete local-OCR page ownership is covered by the Task 11 cloud page contract suite.

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
    'CloudQuestionRepository.updateQuestion(updatedQuestion, getContext(this))',
    "this.showToast('修改已保存')",
    'this.getUIContext().getRouter().back()'
  ])
  assert.doesNotMatch(source, /QuestionImageService|deletePaths|commitImages|QuestionBankService/)
  assert.match(source, /if \(this\.pending \|\| this\.navigationPending\)/)
})

test('bank deletion is server-first and refreshes the cache only after server success', () => {
  const imageSource = fs.readFileSync('entry/src/main/ets/services/QuestionImageService.ets', 'utf8')
  assert.match(imageSource, /export class QuestionImageCleanupError extends Error/)
  assert.match(imageSource, /readonly paths:\s*Array<string>/)
  const deletion = extractMethod(imageSource, 'static async deletePaths')
  assert.match(deletion, /const failedPaths:\s*Array<string>/)
  assert.match(deletion, /failedPaths\.push\(path\)/)
  assert.match(deletion, /throw new QuestionImageCleanupError\(/)

  const books = fs.readFileSync('entry/src/main/ets/pages/BooksPage.ets', 'utf8')
  assert.match(books, /CloudQuestionRepository\.deleteBank/)
  const persist = extractMethod(books, 'private async persistBankDeletion')
  assertOrdered(persist, [
    'CloudQuestionRepository.deleteBank(bankUuid, getContext(this))',
    "this.showToast('题库已删除')",
    'this.refreshWhenActive()'
  ])
  assert.doesNotMatch(persist, /QuestionImageService|QuestionBankService\.deleteBank|rememberCleanupDebt/)
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

// Obsolete local-OCR page ownership is covered by the Task 11 cloud page contract suite.

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

// Obsolete local-OCR page ownership is covered by the Task 11 cloud page contract suite.

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

// Obsolete local-OCR page ownership is covered by the Task 11 cloud page contract suite.

test('current schema durably records exact rollback mappings and retry restores mappings without committed scans', () => {
  const database = fs.readFileSync('entry/src/main/ets/services/DatabaseService.ets', 'utf8')
  assert.match(database, /const SCHEMA_VERSION:\s*number = 6/)
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
})

test('structured PDF storage errors are preserved by retained local services', () => {
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

// Obsolete local-OCR page ownership is covered by the Task 11 cloud page contract suite.

test('PDF page error cards use supported constraint sizing', () => {
  const importSource = fs.readFileSync('entry/src/main/ets/pages/ImportBankPage.ets', 'utf8')
  const progressSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportProgressPage.ets', 'utf8')
  const reviewSource = fs.readFileSync('entry/src/main/ets/pages/PdfImportReviewPage.ets', 'utf8')
  assert.doesNotMatch(importSource, /\.minHeight\(/)
  assert.doesNotMatch(progressSource, /\.minHeight\(/)
  assert.doesNotMatch(reviewSource, /\.minHeight\(/)
  assert.match(importSource, /\.constraintSize\(\{ minHeight: 48 \}\)/)
  assert.match(reviewSource, /\.constraintSize\(\{ minHeight: 48 \}\)/)
})
