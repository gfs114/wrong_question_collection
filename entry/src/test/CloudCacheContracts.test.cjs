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

  assert.match(session, /const session:\s*AccountSessionState = await AccountSessionService\.state\(context\)/)
  assert.match(session, /private static signingOut:\s*boolean = false/)
  assert.match(session, /AccountSessionService\.signingOut = true[\s\S]*const session:\s*AccountSessionState = await AccountSessionService\.state\(context\)[\s\S]*const activeRefresh:\s*Promise<string> \| null = AccountSessionService\.refreshInFlight[\s\S]*await activeRefresh/)
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
