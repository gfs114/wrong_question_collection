const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const assert = require('node:assert/strict')

const root = path.resolve(__dirname, '..', 'main', 'ets')
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8')

test('database schema version five owns sync identity, outbox and cursor tables', () => {
  const source = read('services/DatabaseService.ets')

  assert.match(source, /const SCHEMA_VERSION:\s*number\s*=\s*5/)
  assert.match(source, /CREATE TABLE IF NOT EXISTS sync_identity/i)
  assert.match(source, /PRIMARY KEY\s*\(entity_type,\s*local_id\)/i)
  assert.match(source, /UNIQUE\s*\(entity_type,\s*client_uuid\)/i)
  assert.match(source, /CREATE TABLE IF NOT EXISTS sync_outbox/i)
  assert.match(source, /operation_id TEXT PRIMARY KEY/i)
  assert.match(source, /payload_json TEXT NOT NULL/i)
  assert.match(source, /CREATE TABLE IF NOT EXISTS sync_state/i)
  assert.match(source, /user_id TEXT PRIMARY KEY/i)
  assert.match(source, /cursor TEXT NOT NULL/i)
})

test('version four migration is transactional and advances only after success', () => {
  const source = read('services/DatabaseService.ets')

  assert.match(source, /version === 4[\s\S]*migrateVersionFour\(store\)[\s\S]*store\.version = SCHEMA_VERSION/)
  assert.match(source, /migrateVersionFour[\s\S]*createTransaction\(SCHEMA_TRANSACTION_OPTIONS\)[\s\S]*transaction\.commit\(\)/)
  assert.match(source, /migrateVersionFour[\s\S]*transaction\.rollback\(\)/)
})

test('sync identity service creates stable server-compatible UUID mappings', () => {
  const source = read('services/SyncIdentityService.ets')

  assert.match(source, /generateRandomUUID\(\)/)
  assert.match(source, /sync_identity/)
  assert.match(source, /entity_type/)
  assert.match(source, /local_id/)
  assert.match(source, /client_uuid/)
})

test('outbox compacts pending mutations without removing them on sign out', () => {
  const outbox = read('services/SyncOutboxService.ets')
  const session = read('services/AccountSessionService.ets')

  assert.match(outbox, /sync_outbox/)
  assert.match(outbox, /operation_id/)
  assert.match(outbox, /entity_uuid/)
  assert.match(outbox, /operation_type/)
  assert.match(outbox, /payload_json/)
  assert.match(outbox, /UPDATE sync_outbox SET operation_id/)
  assert.match(outbox, /SyncOperationType\.DELETE/)
  assert.doesNotMatch(session, /DELETE FROM sync_outbox/i)
  assert.doesNotMatch(session, /clearOutbox/i)
})
