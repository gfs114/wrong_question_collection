const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const assert = require('node:assert/strict')

const root = path.resolve(__dirname, '..', 'main', 'ets')
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8')

test('cloud sync stays local when signed out and serializes concurrent requests', () => {
  const source = read('services/CloudSyncService.ets')

  assert.match(source, /if \(!session\.signedIn\)/)
  assert.match(source, /SyncDisplayState\.LOCAL/)
  assert.match(source, /syncInFlight/)
})

test('signed-in sync refreshes the server-first cache and retires the legacy outbox drain', () => {
  const source = read('services/CloudSyncService.ets')

  assert.match(source, /CloudQuestionRepository\.refresh\(session\.userId, context\)/)
  assert.match(source, /SyncDisplayState\.SYNCED/)
  assert.doesNotMatch(source, /SyncOutboxService/)
  assert.doesNotMatch(source, /RemoteOperationApplier/)
  assert.doesNotMatch(source, /authorizedPost|authorizedGet/)
})

test('legacy outbox and remote applier remain intact as recovery-only services', () => {
  const outbox = read('services/SyncOutboxService.ets')
  const applier = read('services/RemoteOperationApplier.ets')

  assert.match(outbox, /pending\(/)
  assert.match(outbox, /acknowledge/)
  assert.match(outbox, /enqueue/)
  assert.doesNotMatch(applier, /SyncOutboxService\.enqueue/)
  assert.match(applier, /createTransaction/)
  assert.match(applier, /saveCursor\(userId, nextCursor, transaction\)/)
  assert.match(applier, /transaction\.commit\(\)/)
  assert.match(applier, /transaction\.rollback\(\)/)
})
