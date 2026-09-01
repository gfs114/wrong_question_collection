const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const assert = require('node:assert/strict')

const etsRoot = path.resolve(__dirname, '..', 'main', 'ets')

function read(relativePath) {
  const filePath = path.join(etsRoot, relativePath)
  assert.equal(fs.existsSync(filePath), true, `Missing Task 13 source: ${relativePath}`)
  return fs.readFileSync(filePath, 'utf8')
}

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

test('migration model covers the five stages with strict ArkTS types', () => {
  const models = read('models/LegacyMigrationModels.ets')

  assert.match(models, /export class LegacyMigrationStage/)
  for (const stage of ['unclaimed', 'uploading', 'verifying', 'completed', 'failed']) {
    assert.match(models, new RegExp(`'${stage}'`), `missing stage ${stage}`)
  }

  assert.match(models, /export class LegacyMigrationState/)
  for (const field of [
    'accountId: string',
    'stage: string',
    'bankIds: Array<string>',
    'currentBankId: string',
    'totalBanks: number',
    'totalQuestions: number',
    'totalImages: number',
    'errorCode: string',
    'errorMessage: string',
    'updateTime: number'
  ]) {
    assert.match(models, new RegExp(field.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
      `state must carry ${field}`)
  }
  assert.match(models, /acknowledgedBankIds: Array<string>/)
  assert.match(models, /verifiedBankIds: Array<string>/)
  assert.match(models, /reboundBankIds: Array<string>/)
  assert.match(models, /serverAcknowledged\(\):\s*boolean/)
  assert.match(models, /cacheVerified\(\):\s*boolean/)
  assert.match(models, /imageMappingsCommitted\(\):\s*boolean/)
  assert.match(models, /processedBanks\(\):\s*number/)
  assert.match(models, /canRetry\(\):\s*boolean/)
  assert.doesNotMatch(models, /\bany\b/)
})

test('MigrationPolicy binds accounts and retires only on all three conditions', () => {
  const models = read('models/LegacyMigrationModels.ets')

  assert.match(models, /export class MigrationPolicy/)
  const canClaim = extractMethod(models, 'static canClaim')
  assert.match(canClaim, /existingAccountId\.trim\(\)\.length === 0/)
  assert.match(canClaim, /return existingAccountId === currentAccountId/)

  const canRetire = extractMethod(models, 'static canRetireLegacy')
  assert.match(canRetire,
    /return serverAcknowledged && cacheVerified && imageMappingsCommitted/)
})

test('text normalization is deterministic, UUID ordered, and server-trim aware', () => {
  const models = read('models/LegacyMigrationModels.ets')

  assert.match(models, /export class LegacyCanonicalQuestion/)
  assert.match(models, /export class LegacyTextNormalizer/)
  const canonical = extractMethod(models, 'static canonicalText')
  assert.match(canonical, /questions\.slice\(\)/)
  assert.match(canonical, /left\.uuid < right\.uuid/)
  assert.match(canonical, /name=' \+ bankName\.trim\(\)/)
  assert.match(canonical, /subject=' \+ subject\.trim\(\)/)
  assert.match(canonical, /blocks\.join\('\\n'\)/)
  const questionBlock = extractMethod(models, 'static questionBlock')
  assert.match(questionBlock, /type=' \+ question\.type/)
  assert.match(questionBlock, /question=' \+ question\.content\.trim\(\)/)
  assert.match(questionBlock, /index\.toString\(\) \+ '=' \+ question\.options\[index\]/)
  assert.match(questionBlock, /JSON\.stringify\(optionLines\)/)
  assert.match(questionBlock, /answer=' \+ question\.answer/)
  assert.match(questionBlock, /analysis=' \+ question\.analysis/)
  assert.match(questionBlock, /lines\.join\('\\n'\)/)
})

test('migration state lives outside sync_outbox and never writes it', () => {
  const service = read('services/LegacyCloudMigrationService.ets')

  assert.match(service, /legacy_cloud_migration/)
  assert.doesNotMatch(service, /SyncOutboxService/)
})

test('legacy scan excludes sample data and reads stable identities', () => {
  const service = read('services/LegacyCloudMigrationService.ets')

  assert.match(service, /is_sample = 0/)
  assert.match(service, /FROM question_bank WHERE is_sample = 0/)
  assert.match(service, /FROM question WHERE bank_id = \?/)
  assert.match(service, /FROM question_image/)
  assert.match(service, /SyncIdentityService\.clientUuid\([\s\S]{0,40}SyncEntityType\.QUESTION_BANK/)
  assert.match(service, /SyncIdentityService\.clientUuid\([\s\S]{0,40}SyncEntityType\.QUESTION/)
  assert.doesNotMatch(service, /IdUtils\.create/)
})

test('upload reuses the server sync API with stable UUIDs in bounded batches', () => {
  const service = read('services/LegacyCloudMigrationService.ets')

  assert.match(service, /\/v1\/sync\/push/)
  assert.match(service, /PUSH_BATCH_LIMIT:\s*number\s*=\s*100/)
  assert.match(service, /SyncPayloadFactory\.bankPayload/)
  assert.match(service, /SyncPayloadFactory\.questionFieldsPayload/)
  assert.match(service, /SyncPushOperation/)
  assert.match(service, /util\.generateRandomUUID\(\)/)
  // Entity identifiers are the stable legacy UUIDs; re-pushing upserts the
  // same server rows instead of duplicating them.
  assert.match(service, /SyncOperationType\.UPSERT/)
  assert.match(service, /idempotent/i)
})

test('server ACK is required before the verifying stage', () => {
  const service = read('services/LegacyCloudMigrationService.ets')

  const run = extractMethod(service, 'private static async performRun')
  assertOrdered(run, ['uploadPhase', 'verifyPhase'])

  const pushBatch = extractMethod(service, 'private static async pushBatch')
  assert.match(pushBatch, /response\.operations\.length !== operations\.length[\s\S]*throw/)

  const upload = extractMethod(service, 'private static async uploadPhase')
  assert.match(upload, /LegacyMigrationStage\.VERIFYING/)
  assert.ok(upload.indexOf('uploadBank') < upload.indexOf('acknowledgedState'),
    'bank push must precede its acknowledgement')
  assert.ok(upload.indexOf('acknowledgedState') < upload.indexOf('saveState(context, verifying)'),
    'acknowledgement must persist before the verifying stage')
})

test('verification pulls the authoritative snapshot and fails on count mismatch', () => {
  const service = read('services/LegacyCloudMigrationService.ets')
  const repository = read('services/CloudQuestionRepository.ets')

  assert.match(repository, /\/v1\/sync\/pull\?cursor=/)
  assert.match(service, /CloudQuestionRepository\.pullAuthoritativeSnapshot/)
  assert.match(service, /serverCount !== bank\.questions\.length/)
  assert.match(service, /LegacyMigrationErrors\.COUNT_MISMATCH/)
  assert.match(service, /LegacyMigrationErrors\.SNAPSHOT_FAILED/)
})

test('SHA-256 digest mismatch blocks cacheVerified and completion', () => {
  const service = read('services/LegacyCloudMigrationService.ets')

  assert.match(service, /hash\.createHash\('sha256'\)/)
  assert.match(service, /LegacyTextNormalizer\.canonicalText/)
  assert.match(service, /localDigest !== serverDigest/)
  assert.match(service, /LegacyMigrationErrors\.DIGEST_MISMATCH/)
})

test('cloud cache is written only after every bank verified', () => {
  const service = read('services/LegacyCloudMigrationService.ets')

  const verify = extractMethod(service, 'private static async verifyPhase')
  assertOrdered(verify, ['cacheVerified()', 'writeCloudCache'])
  assert.match(service, /CloudCachePage/)
  assert.match(service, /CloudCacheService\.replacePage/)
})

test('completion requires all three conditions and never deletes legacy data', () => {
  const service = read('services/LegacyCloudMigrationService.ets')

  assert.match(service, /MigrationPolicy\.canRetireLegacy\(/)
  assert.match(service, /LegacyMigrationStage\.COMPLETED/)
  assert.match(service, /LegacyMigrationErrors\.IMAGE_REBIND_FAILED/)
  assert.match(service, /LegacyMigrationErrors\.CACHE_WRITE_FAILED/)
  assert.doesNotMatch(service, /DELETE FROM|DROP TABLE/)
  assert.doesNotMatch(service, /clearAccountTextCache|clearWrong|WrongQuestionService\.clear/)
})

test('image rebinding keeps device images private and preserves the originals', () => {
  const service = read('services/LegacyCloudMigrationService.ets')

  assert.match(service, /DeviceImageScope\.accountDirectory/)
  assert.match(service, /DeviceImageStore\.save/)
  assert.match(service, /hash\.hash\(image\.imagePath, 'sha256'\)/)
  assert.match(service, /fs\.copyFile/)
  assert.doesNotMatch(service, /fs\.unlink|deletePaths|rmdir|moveFile/)
  assert.doesNotMatch(service, /authorizedBinaryPut|uploadPart/)
})

test('failure states allow retry and resume from acknowledged banks', () => {
  const service = read('services/LegacyCloudMigrationService.ets')

  assert.match(service, /LegacyMigrationStage\.FAILED/)
  const upload = extractMethod(service, 'private static async uploadPhase')
  assert.match(upload, /acknowledgedBankIds\.indexOf\(bank\.id\) >= 0[\s\S]*continue/)
  const verify = extractMethod(service, 'private static async verifyPhase')
  assert.match(verify, /verifiedBankIds\.indexOf\(bank\.id\) >= 0[\s\S]*continue/)
  assert.match(verify, /reboundBankIds\.indexOf\(bank\.id\) >= 0[\s\S]*continue/)
})

test('legacy OCR and PDF fallback services are retired and unreferenced by migration', () => {
  assert.equal(fs.existsSync(path.join(etsRoot, 'services', 'OnDeviceOcrService.ets')), false,
    'OnDeviceOcrService must be deleted after the cutover')
  assert.equal(fs.existsSync(path.join(etsRoot, 'services', 'PdfImportCoordinator.ets')), false,
    'PdfImportCoordinator must be deleted after the cutover')

  const service = read('services/LegacyCloudMigrationService.ets')
  assert.doesNotMatch(service, /OnDeviceOcrService|PdfImportCoordinator/)
})

test('bootstrap restores migration state without auto claiming an account', () => {
  const bootstrap = read('services/AppBootstrapService.ets')

  assert.match(bootstrap, /LegacyCloudMigrationService\.initialize\(context\)/)
  assert.doesNotMatch(bootstrap, /LegacyCloudMigrationService\.(claim|run)\(/)
})

test('migration card shows all five states, counts, and a retry action', () => {
  const card = read('components/LegacyMigrationCard.ets')

  assert.match(card, /export struct LegacyMigrationCard/)
  for (const label of ['未迁移', '迁移中', '正在校验', '迁移完成', '迁移失败']) {
    assert.match(card, new RegExp(label), `missing card state ${label}`)
  }
  assert.match(card, /个题库/)
  assert.match(card, /道题目/)
  assert.match(card, /张本机题图/)
  assert.match(card, /重试/)
  assert.match(card, /华为账号/)
  assert.match(card, /onStart/)
  assert.match(card, /onRetry/)
})

test('mine page requires login and explicit confirmation before migrating', () => {
  const page = read('pages/MinePage.ets')

  assert.match(page, /LegacyMigrationCard\(\{/)
  assert.match(page, /LegacyCloudMigrationService\.overview/)
  assert.match(page, /请先登录华为账号/)
  assert.match(page, /value: '开始迁移'/)
  assert.match(page, /绑定到当前登录的华为账号/)
  assert.match(page, /value: '取消'/)
  const persist = extractMethod(page, 'private persistMigration')
  assertOrdered(persist, ['LegacyCloudMigrationService.claim(context)', 'LegacyCloudMigrationService.run(context)'])
  assert.doesNotMatch(persist, /question_bank/)
})
