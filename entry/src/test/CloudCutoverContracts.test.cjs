const assert = require('node:assert/strict')
const childProcess = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const repoRoot = path.resolve(__dirname, '..', '..', '..')
const etsRoot = path.join(repoRoot, 'entry', 'src', 'main', 'ets')

function read(relativePath) {
  const filePath = path.join(etsRoot, relativePath)
  assert.equal(fs.existsSync(filePath), true, `Missing source: ${relativePath}`)
  return fs.readFileSync(filePath, 'utf8')
}

function extractMethod(source, signature) {
  const start = source.indexOf(signature)
  assert.notEqual(start, -1, 'missing method ' + signature)
  const openingBrace = source.indexOf('{', start)
  assert.notEqual(openingBrace, -1, 'missing method body ' + signature)
  let depth = 0
  for (let index = openingBrace; index < source.length; index++) {
    if (source[index] === '{') depth++
    else if (source[index] === '}') {
      depth--
      if (depth === 0) return source.slice(start, index + 1)
    }
  }
  assert.fail('unterminated method ' + signature)
}

function walkEtsSources(directory) {
  const sources = []
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const absolute = path.join(directory, entry.name)
    if (entry.isDirectory()) {
      sources.push(...walkEtsSources(absolute))
    } else if (entry.isFile() && entry.name.endsWith('.ets')) {
      sources.push({ relative: path.relative(etsRoot, absolute), source: fs.readFileSync(absolute, 'utf8') })
    }
  }
  return sources
}

const productionSources = walkEtsSources(etsRoot)

test('production code no longer references device OCR services or recognizeText', () => {
  for (const file of productionSources) {
    assert.doesNotMatch(file.source, /OnDeviceOcrService|PdfImportCoordinator|recognizeText/,
      `${file.relative} must not reference retired device OCR services`)
  }
  assert.equal(fs.existsSync(path.join(etsRoot, 'services', 'OnDeviceOcrService.ets')), false,
    'OnDeviceOcrService.ets must be deleted after cutover')
  assert.equal(fs.existsSync(path.join(etsRoot, 'services', 'PdfImportCoordinator.ets')), false,
    'PdfImportCoordinator.ets must be deleted after cutover')
})

test('QuestionBankService no longer produces legacy outbox writes', () => {
  const source = read('services/QuestionBankService.ets')

  assert.doesNotMatch(source, /SyncOutboxService\.enqueue/)
  assert.doesNotMatch(source, /SyncOutboxService/)
  assert.doesNotMatch(source, /SyncEntityType|SyncOperationType/)
})

test('WrongQuestionService no longer produces legacy outbox writes', () => {
  const source = read('services/WrongQuestionService.ets')

  assert.doesNotMatch(source, /SyncOutboxService\.enqueue/)
  assert.doesNotMatch(source, /SyncOutboxService/)
  assert.doesNotMatch(source, /SyncEntityType|SyncOperationType/)
})

test('normal business write paths go through CloudQuestionRepository', () => {
  const pages = {
    'pages/EditQuestionPage.ets': /CloudQuestionRepository\.updateQuestion/,
    'pages/BooksPage.ets': /CloudQuestionRepository\.deleteBank/,
    'pages/QuestionDetailPage.ets': /CloudQuestionRepository\.setWrongState/,
    'pages/WrongQuestionDetailPage.ets': /CloudQuestionRepository\.setWrongState/,
    'pages/MinePage.ets': /CloudQuestionRepository\.clearWrongQuestions/,
    'services/ImportService.ets': /CloudQuestionRepository\.createBank/
  }
  for (const file of Object.keys(pages)) {
    const source = read(file)
    assert.match(source, pages[file], `${file} must mutate through CloudQuestionRepository`)
    assert.doesNotMatch(source, /SyncOutboxService/, `${file} must not touch the legacy outbox`)
  }

  const repository = read('services/CloudQuestionRepository.ets')
  assert.match(repository, /static async createBank\(/)
  assert.match(repository, /static async clearWrongQuestions\(/)
  assert.match(repository, /'\/v1\/sync\/push'/)
  assert.doesNotMatch(repository, /SyncOutboxService\.enqueue|QuestionBankService\.(?:updateQuestion|deleteBank|saveImportedBank|savePdfBank)|WrongQuestionService\.(?:add|remove|markMastered|clear)/)

  const mine = read('pages/MinePage.ets')
  assert.doesNotMatch(mine, /WrongQuestionService\./, 'MinePage must not call the local-first wrong-question service')
})

test('rollback cloud pages remain intact but the formal PDF flow is client AI only', () => {
  const rollbackPages = [
    'pages/PdfImportSetupPage.ets',
    'pages/PdfImportProgressPage.ets'
  ]
  for (const file of rollbackPages) {
    const source = read(file)
    assert.match(source, /CloudImportService/, `${file} must use CloudImportService`)
    assert.doesNotMatch(source, /OnDeviceOcrService|PdfImportCoordinator|PdfImportService|\bpdfService\b/,
      `${file} must not touch the retired device pipeline`)
  }
  assert.match(read('pages/PdfImportReviewPage.ets'), /CloudPdfReviewAdapter/)
  const importPage = read('pages/ImportBankPage.ets')
  const formalPages = importPage + read('pages/PdfAiImportSetupPage.ets') +
    read('pages/PdfAiImportProgressPage.ets') + read('services/ai/PdfAiImportCoordinator.ets') +
    read('services/review/AiPdfReviewAdapter.ets')
  assert.match(importPage, /pages\/PdfAiImportSetupPage/)
  assert.match(formalPages, /AiVisionTransport/)
  assert.doesNotMatch(formalPages,
    /CloudImportService|CloudImportApi|\/v1\/imports\/pdf|PaddleOCR|textRecognition|OcrService|fallback/)
  assert.equal(fs.existsSync(path.join(etsRoot, 'services', 'OnDeviceOcrService.ets')), false)
  assert.equal(fs.existsSync(path.join(etsRoot, 'services', 'PdfImportCoordinator.ets')), false)
})

test('formal entry prohibitions are scoped to the AI flow and leave rollback files available', () => {
  const importPage = read('pages/ImportBankPage.ets')
  const scopedSources = [
    ['selectPdf', extractMethod(importPage, 'private async selectPdf')],
    ['setup', read('pages/PdfAiImportSetupPage.ets')],
    ['progress', read('pages/PdfAiImportProgressPage.ets')],
    ['coordinator', read('services/ai/PdfAiImportCoordinator.ets')],
    ['AI adapter', read('services/review/AiPdfReviewAdapter.ets')]
  ]
  const forbidden = /fallback|PaddleOCR|OcrService|CloudImportService|\/v1\/imports\/pdf/
  for (const [name, source] of scopedSources) {
    assert.doesNotMatch(source, forbidden, `${name} must remain client-AI-only`)
  }
  assert.equal(fs.existsSync(path.join(etsRoot, 'pages', 'PdfImportSetupPage.ets')), true)
  assert.equal(fs.existsSync(path.join(etsRoot, 'pages', 'PdfImportProgressPage.ets')), true)
})

test('AppBootstrap integrates LegacyCloudMigrationService without legacy backfill', () => {
  const source = read('services/AppBootstrapService.ets')

  assert.match(source, /LegacyCloudMigrationService/)
  assert.match(source, /LegacyCloudMigrationService\.initialize\(context\)/)
  assert.doesNotMatch(source, /LegacyCloudMigrationService\.(claim|run)\(/)
  assert.doesNotMatch(source, /SyncBootstrapService\.enqueueLegacyLocalText/)
  assert.doesNotMatch(source, /DROP TABLE|DELETE FROM/)
})

test('legacy migration gate blocks retirement until all three conditions hold', () => {
  const models = read('models/LegacyMigrationModels.ets')
  assert.match(models, /static canRetireLegacy\(serverAcknowledged:\s*boolean,\s*cacheVerified:\s*boolean,\s*imageMappingsCommitted:\s*boolean\)/)
  assert.match(models, /return serverAcknowledged && cacheVerified && imageMappingsCommitted/)
  assert.match(models, /static canClaim\(existingAccountId:\s*string,\s*currentAccountId:\s*string\)/)
  assert.match(models, /existingAccountId === currentAccountId/)

  const service = read('services/LegacyCloudMigrationService.ets')
  assert.match(service, /MigrationPolicy\.canRetireLegacy\(/)
  assert.match(service, /LegacyMigrationStage\.COMPLETED/)
  assert.doesNotMatch(service, /DELETE FROM|DROP TABLE/)
  assert.doesNotMatch(service, /SyncOutboxService/)

  const bootstrap = read('services/AppBootstrapService.ets')
  assert.doesNotMatch(bootstrap, /SyncBootstrapService\.enqueueLegacyLocalText/)
})

test('legacy v5 schema and sync_outbox remain for recovery', () => {
  const source = read('services/DatabaseService.ets')

  assert.match(source, /CREATE TABLE IF NOT EXISTS sync_outbox/)
  assert.match(source, /CREATE TABLE IF NOT EXISTS question_bank/)
  assert.match(source, /CREATE TABLE IF NOT EXISTS question\s*\(/)
  assert.match(source, /CREATE TABLE IF NOT EXISTS question_image/)
  assert.match(source, /CREATE TABLE IF NOT EXISTS wrong_question/)
})

test('no destructive legacy cleanup exists in production startup or sync paths', () => {
  for (const file of productionSources) {
    assert.doesNotMatch(file.source, /DROP TABLE/,
      `${file.relative} must never drop a legacy table`)
  }

  const bootstrap = read('services/AppBootstrapService.ets')
  assert.doesNotMatch(bootstrap, /DELETE FROM|DROP TABLE/)

  const sync = read('services/CloudSyncService.ets')
  assert.doesNotMatch(sync, /SyncOutboxService\.(pending|acknowledge|enqueue)/,
    'CloudSyncService must stop draining the legacy outbox')
  assert.doesNotMatch(sync, /RemoteOperationApplier/,
    'CloudSyncService must stop applying remote operations into legacy tables')

  const outbox = read('services/SyncOutboxService.ets')
  assert.match(outbox, /enqueue/, 'recovery-only outbox service remains intact for future recovery work')
})

test('server directory has zero uncommitted changes', () => {
  // Sandboxed runners forbid capturing child stdout through pipes, so git
  // writes its porcelain output straight into a scratch file descriptor.
  const scratch = path.join(require('node:os').tmpdir(), 'wqc_server_status_' + process.pid + '.txt')
  const descriptor = fs.openSync(scratch, 'w')
  let output = ''
  try {
    const result = childProcess.spawnSync('git', ['status', '--porcelain', '--', 'server'], {
      cwd: repoRoot,
      stdio: ['ignore', descriptor, 'ignore']
    })
    assert.equal(result.error, undefined, 'git must be available: ' + (result.error && result.error.message))
    assert.equal(result.status, 0, 'git status must succeed')
    output = fs.readFileSync(scratch, 'utf8')
  } finally {
    fs.closeSync(descriptor)
    try {
      fs.unlinkSync(scratch)
    } catch {
    }
  }
  assert.equal(output.trim(), '', 'server/ must remain untouched by the cutover task')
})
