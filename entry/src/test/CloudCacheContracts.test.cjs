const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const etsRoot = path.resolve(__dirname, '..', 'main', 'ets')

function read(relativePath) {
  const filePath = path.join(etsRoot, relativePath)
  assert.equal(fs.existsSync(filePath), true, `Missing Task 10 source: ${relativePath}`)
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
      if (depth === 0) return source.slice(start, index + 1)
    }
  }
  assert.fail('unterminated method ' + signature)
}

function assertOrdered(source, fragments) {
  let prior = -1
  for (const fragment of fragments) {
    const current = source.indexOf(fragment, prior + 1)
    assert.notEqual(current, -1, 'missing fragment ' + fragment)
    prior = current
  }
}

function tableDefinition(source, tableName) {
  const marker = `CREATE TABLE IF NOT EXISTS ${tableName} (`
  const start = source.indexOf(marker)
  assert.notEqual(start, -1, `Missing ${tableName} table`)
  const nextConstant = source.indexOf('\n\nconst ', start)
  return source.slice(start, nextConstant === -1 ? source.length : nextConstant)
}

test('schema version six adds every account-scoped cache table', () => {
  const database = read('services/DatabaseService.ets')

  assert.match(database, /const SCHEMA_VERSION:\s*number\s*=\s*6/)
  for (const tableName of [
    'cloud_cache_state',
    'cloud_bank_cache',
    'cloud_question_cache',
    'cloud_wrong_cache',
    'device_question_image'
  ]) {
    const definition = tableDefinition(database, tableName)
    assert.match(definition, /account_id TEXT NOT NULL/i, `${tableName} must own account_id`)
  }

  assert.match(tableDefinition(database, 'cloud_cache_state'), /cursor TEXT NOT NULL/i)
  assert.match(tableDefinition(database, 'cloud_cache_state'), /update_time INTEGER NOT NULL/i)
  assert.match(tableDefinition(database, 'cloud_question_cache'), /question_uuid TEXT NOT NULL/i)
  assert.match(tableDefinition(database, 'device_question_image'), /question_uuid TEXT NOT NULL/i)
  assert.match(tableDefinition(database, 'device_question_image'), /image_path TEXT NOT NULL/i)
  assert.match(tableDefinition(database, 'device_question_image'), /sha256 TEXT NOT NULL/i)
  assert.match(tableDefinition(database, 'device_question_image'), /sort_order INTEGER NOT NULL/i)
})

test('version five migration only creates cache tables and indexes', () => {
  const database = read('services/DatabaseService.ets')
  const migrationMatch = database.match(
    /private static async migrateVersionFive[\s\S]*?\n  }\n}/)

  assert.ok(migrationMatch, 'migrateVersionFive must exist')
  const migration = migrationMatch[0]
  assert.match(database, /version === 5[\s\S]*migrateVersionFive\(store\)[\s\S]*store\.version = SCHEMA_VERSION/)
  assert.match(migration, /createTransaction\(SCHEMA_TRANSACTION_OPTIONS\)/)
  assert.match(migration, /transaction\.commit\(\)/)
  assert.match(migration, /transaction\.rollback\(\)/)
  for (const tableConstant of [
    'CREATE_CLOUD_CACHE_STATE',
    'CREATE_CLOUD_BANK_CACHE',
    'CREATE_CLOUD_QUESTION_CACHE',
    'CREATE_CLOUD_WRONG_CACHE',
    'CREATE_DEVICE_QUESTION_IMAGE'
  ]) {
    assert.match(migration, new RegExp(`transaction\\.execute\\(${tableConstant}\\)`))
  }
  assert.doesNotMatch(migration, /\b(?:DROP|ALTER|UPDATE|DELETE)\b/i)
})

test('legacy tables and outbox remain intact while device OCR services are retired', () => {
  const database = read('services/DatabaseService.ets')

  assert.match(database, /CREATE TABLE IF NOT EXISTS question_bank/i)
  assert.match(database, /CREATE TABLE IF NOT EXISTS question\s*\(/i)
  assert.match(database, /CREATE TABLE IF NOT EXISTS question_image/i)
  assert.match(database, /CREATE TABLE IF NOT EXISTS sync_outbox/i)
  assert.doesNotMatch(database, /DROP\s+TABLE/i)
  assert.equal(fs.existsSync(path.join(etsRoot, 'services', 'OnDeviceOcrService.ets')), false,
    'OnDeviceOcrService must be retired after the cutover')
  assert.equal(fs.existsSync(path.join(etsRoot, 'services', 'PdfImportCoordinator.ets')), false,
    'PdfImportCoordinator must be retired after the cutover')
})

test('cache models are strict ArkTS classes with server UUID ownership', () => {
  const models = read('models/CloudCacheModels.ets')

  for (const className of [
    'CloudCacheState',
    'CloudBankCache',
    'CloudQuestionCache',
    'CloudWrongCache',
    'DeviceQuestionImage'
  ]) {
    assert.match(models, new RegExp(`export class ${className}\\b`))
  }
  assert.match(models, /questionUuid:\s*string/)
  assert.match(models, /accountId:\s*string/)
  assert.doesNotMatch(models, /\bany\b|:\s*object\b/)
})

test('replacePage atomically replaces account text and rejects stale cursors', () => {
  const service = read('services/CloudCacheService.ets')
  const models = read('models/CloudCacheModels.ets')

  assert.match(models, /return CacheVersionPolicy\.compare\(currentCursor, incomingCursor\) < 0/)
  assert.match(service, /static async replacePage\(accountId:\s*string/)
  assert.match(service, /createTransaction\(CACHE_TRANSACTION_OPTIONS\)/)
  assert.match(service, /SELECT cursor FROM cloud_cache_state WHERE account_id = \? LIMIT 1/)
  assert.match(service, /CacheVersionPolicy\.shouldReplace\(currentCursor,\s*page\.cursor\)/)
  assert.match(service, /if \(!CacheVersionPolicy\.shouldReplace[\s\S]*?transaction\.rollback\(\)[\s\S]*?return false/)
  assert.match(service, /DELETE FROM cloud_bank_cache WHERE account_id = \?/)
  assert.match(service, /DELETE FROM cloud_question_cache WHERE account_id = \?/)
  assert.match(service, /DELETE FROM cloud_wrong_cache WHERE account_id = \?/)
  assert.match(service, /INSERT INTO cloud_cache_state\(account_id, cursor, update_time\)/)
  assert.match(service, /transaction\.commit\(\)/)
  assert.match(service, /transaction\.rollback\(\)/)
})

test('all cloud cache reads require account ID', () => {
  const service = read('services/CloudCacheService.ets')

  assert.match(service, /static async state\(accountId:\s*string\)/)
  assert.match(service, /static async banks\(accountId:\s*string\)/)
  assert.match(service, /static async questions\(accountId:\s*string,\s*bankUuid:\s*string\)/)
  assert.match(service, /static async wrongQuestions\(accountId:\s*string\)/)
  assert.match(service, /FROM cloud_bank_cache WHERE account_id = \?/)
  assert.match(service, /FROM cloud_question_cache[\s\S]{0,100}WHERE account_id = \? AND bank_uuid = \?/)
  assert.match(service, /FROM cloud_wrong_cache WHERE account_id = \?/)
  assert.doesNotMatch(service, /\b(?:updateQuestion|saveQuestion|editQuestion|enqueue)\s*\(/)
})

test('device image mappings require matching account and question ownership', () => {
  const service = read('services/DeviceImageStore.ets')

  assert.match(service, /export class DeviceImageScope/)
  assert.match(service, /static key\(accountId:\s*string,\s*questionUuid:\s*string\)/)
  assert.match(service, /question_images\//)
  assert.match(service, /accountHash\(accountId\)/)
  assert.match(service, /validateOwnedPath/)
  assert.match(service, /WHERE account_id = \? AND question_uuid = \?/)
  assert.match(service, /INSERT INTO device_question_image\(account_id, question_uuid, image_path, sha256, sort_order\)/)
})

test('logout removes only current account text cache and retains device images', () => {
  const session = read('services/AccountSessionService.ets')
  const cache = read('services/CloudCacheService.ets')
  const signOut = extractMethod(session, 'static async signOut')
  const signOutExclusive = extractMethod(session, 'private static async performSignOutExclusive')

  assert.match(signOutExclusive,
    /const session:\s*AccountSessionState = await AccountSessionService\.state\(context\)/)
  assert.match(session, /private static signingOut:\s*boolean = false/)
  assert.match(signOut,
    /AccountSessionService\.signingOut = true[\s\S]*const activeRefresh:\s*Promise<string> \| null = AccountSessionService\.refreshInFlight[\s\S]*await activeRefresh[\s\S]*runAccountExclusive/)
  assert.match(session, /static async refresh[\s\S]*if \(AccountSessionService\.signingOut\)[\s\S]*return ''/)
  assert.match(session, /err\.statusCode === 401[\s\S]*if \(!AccountSessionService\.signingOut\)[\s\S]*clearMetadata\(context\)/)
  assert.match(session, /finally \{[\s\S]*AccountSessionService\.signingOut = false/)
  assert.match(session, /AccountSessionStore\.clearSession\(\)[\s\S]*CloudCacheService\.clearAccountTextCache\(session\.userId\)/)
  assert.match(session, /AccountSessionStore\.clearSession\(\)[\s\S]*AccountSessionService\.clearMemory\(\)[\s\S]*CloudCacheService\.clearAccountTextCache/)
  assert.doesNotMatch(session, /DELETE FROM device_question_image|clearDeviceImage|removeDeviceImage/)
  assert.match(cache, /static async clearAccountTextCache\(accountId:\s*string\)/)
  assert.match(cache, /DELETE FROM cloud_bank_cache WHERE account_id = \?/)
  assert.match(cache, /DELETE FROM cloud_question_cache WHERE account_id = \?/)
  assert.match(cache, /DELETE FROM cloud_wrong_cache WHERE account_id = \?/)
  assert.match(cache, /DELETE FROM cloud_cache_state WHERE account_id = \?/)
  assert.doesNotMatch(cache, /DELETE FROM device_question_image/)
})

test('AI import can persist validated stable bank and question UUIDs', () => {
  const source = read('services/CloudQuestionRepository.ets')
  const account = read('services/AccountSessionService.ets')
  const payloadFactory = read('services/SyncPayloadFactory.ets')
  const legacy = extractMethod(source, 'static async createBank(')
  const withIds = extractMethod(source, 'static async createBankWithIds')
  const questionPayload = extractMethod(payloadFactory, 'static questionFieldsPayload')

  assert.match(legacy, /createBankWithIds/)
  assert.match(withIds, /snapshotBank\.id/)
  assert.match(withIds, /question\.id/)
  assert.match(withIds, /SyncEntityType\.QUESTION_BANK/)
  assert.match(withIds, /SyncEntityType\.QUESTION/)
  assert.match(withIds, /pushOperations/)
  assert.doesNotMatch(withIds, /entityId.*generateRandomUUID/)
  assert.doesNotMatch(withIds,
    /localPath|pdfPath|imagePath|sha256|bbox|provider|credential|authorization/i)
  assert.ok(withIds.indexOf('snapshotBank(bank)') < withIds.indexOf('await'),
    'all entity UUIDs must be snapshotted and validated before authentication or outbound work')
  assert.match(withIds, /expectedAccountId:\s*string/)
  assert.match(withIds, /snapshotBank/)
  assert.match(withIds, /pushOperationsForAccount\(context, expectedAccountId/)
  assert.match(withIds, /requireAccount\(context, expectedAccountId\)/)
  assert.match(account, /static async accessTokenForAccount\(context:\s*Context,\s*expectedAccountId:\s*string\)/)
  assert.match(account,
    /accessTokenForAccount[\s\S]*requireAccount\(context, expectedAccountId\)[\s\S]*accessToken\(context\)[\s\S]*requireAccount\(context, expectedAccountId\)/)
  for (const field of ['bankClientId', 'type', 'question', 'options', 'answer', 'analysis']) {
    assert.match(questionPayload, new RegExp(`['"]${field}['"]`), `sync payload must retain ${field}`)
  }
  assert.doesNotMatch(questionPayload,
    /localPath|pdfPath|imagePath|imageBytes|sha256|bbox|provider|credential|authorization|api[_ -]?key|baseUrl/i)
})

test('AI bank batches stay pinned to one expected account across every response', () => {
  const source = read('services/CloudQuestionRepository.ets')
  const push = extractMethod(source, 'private static async pushOperationsForAccount')
  const authorized = extractMethod(source, 'private static async authorizedPushForAccount')

  assert.match(push, /while \(offset < operations\.length\)/)
  assert.match(push, /authorizedPushForAccount[\s\S]*expectedAccountId/)
  assert.match(authorized, /accessTokenForAccount\(context, expectedAccountId\)/)
  assert.match(authorized,
    /ApiHttpClient\.authorizedPost[\s\S]*requireAccount\(context, expectedAccountId\)/)
  assert.match(authorized, /refreshForAccount\(context, expectedAccountId\)/)
})

test('sign out is gated before joining the serialized account mutation lane', () => {
  const source = read('services/AccountSessionService.ets')
  const installLogin = extractMethod(source, 'static async installLogin')
  const signOut = extractMethod(source, 'static async signOut')
  const exclusive = extractMethod(source, 'private static async performSignOutExclusive')

  assert.match(installLogin, /if \(AccountSessionService\.signingOut\)/)
  assert.match(installLogin, /runAccountExclusive/)
  assert.ok(signOut.indexOf('signingOut = true') < signOut.indexOf('runAccountExclusive'),
    'new token reads must be gated before sign-out waits for the account lock')
  assert.match(signOut, /refreshInFlight[\s\S]*await activeRefresh/)
  assert.match(signOut, /runAccountExclusive/)
  assert.match(exclusive, /AccountSessionStore\.clearSession/)
  assert.match(exclusive, /clearMetadata\(context\)/)
})

test('AI bank cache apply is scoped under the serialized expected-account lane', () => {
  const source = read('services/CloudQuestionRepository.ets')
  const account = read('services/AccountSessionService.ets')
  const withIds = extractMethod(source, 'static async createBankWithIds')
  const localExclusive = extractMethod(account, 'static async runExpectedAccountLocalExclusive')

  assert.match(withIds, /runExpectedAccountLocalExclusive\(context, expectedAccountId/)
  assert.match(withIds,
    /runExpectedAccountLocalExclusive[\s\S]*loadSnapshot\(expectedAccountId\)[\s\S]*applyOrdered\(expectedAccountId[\s\S]*saveSnapshot\(expectedAccountId/)
  assert.doesNotMatch(withIds, /clearAccountTextCache/)
  assert.match(localExclusive, /runAccountExclusive/)
  assert.match(localExclusive, /AccountSessionService\.state\(context\)/)
  assert.match(localExclusive, /current\.userId !== accountId/)
  assert.doesNotMatch(localExclusive, /accessToken|refresh\(/)
})

test('device images validate a complete batch before one immediate transaction', () => {
  const source = read('services/DeviceImageStore.ets')
  const save = extractMethod(source, 'static async save(')
  const batch = extractMethod(source, 'static async saveBatch')
  const optionsStart = source.indexOf('const DEVICE_IMAGE_TRANSACTION_OPTIONS')
  const optionsEnd = source.indexOf('export enum DeviceImageWriteOutcome', optionsStart)
  const transactionOptions = source.slice(optionsStart, optionsEnd)

  assert.match(save, /return DeviceImageStore\.saveBatch\(context, \[image\]\)/)
  assert.match(transactionOptions,
    /transactionType:\s*relationalStore\.TransactionType\.IMMEDIATE/)
  assert.equal((batch.match(/createTransaction\(DEVICE_IMAGE_TRANSACTION_OPTIONS\)/g) || []).length, 1)
  assert.ok(batch.indexOf('createTransaction(DEVICE_IMAGE_TRANSACTION_OPTIONS)') >
    batch.indexOf('const store: relationalStore.RdbStore = DatabaseService.getStore()'))
  assert.match(batch, /await transaction\.commit\(\)/)
  assert.match(batch, /await transaction\.rollback\(\)/)
  assert.match(batch, /duplicate/i)
  assertOrdered(batch, [
    'for (let index: number = 0; index < images.length; index++)',
    'if (keys.has(key))',
    'snapshotImages.push',
    'const store: relationalStore.RdbStore = DatabaseService.getStore()',
    'createTransaction(DEVICE_IMAGE_TRANSACTION_OPTIONS)'
  ])
  assert.match(batch, /primaryError/)
  assert.match(batch, /rollbackError/)
  assert.match(batch, /snapshotImages/)
  assert.match(source, /export enum DeviceImageWriteOutcome/)
  assert.match(source, /export class DeviceImageStoreError extends Error/)
  assert.match(batch, /DeviceImageWriteOutcome\.UNKNOWN/)
  assert.match(batch, /DeviceImageWriteOutcome\.ROLLED_BACK/)
})
