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

test('push is bounded and acknowledges only after a successful response', () => {
  const source = read('services/CloudSyncService.ets')

  assert.match(source, /pending\(100\)/)
  const requestIndex = source.indexOf("authorizedPost<SyncPushResponse>('/v1/sync/push'")
  const acknowledgeIndex = source.indexOf('SyncOutboxService.acknowledge')
  assert.ok(requestIndex >= 0)
  assert.ok(acknowledgeIndex > requestIndex)
})

test('pull paginates with cursor and advances it only through the remote transaction', () => {
  const cloud = read('services/CloudSyncService.ets')
  const applier = read('services/RemoteOperationApplier.ets')

  assert.match(cloud, /while \(hasMore\)/)
  assert.match(cloud, /cursor=/)
  assert.match(cloud, /RemoteOperationApplier\.apply\(userId, response\.operations, response\.nextCursor\)/)
  assert.match(applier, /createTransaction/)
  assert.match(applier, /saveCursor\(userId, nextCursor, transaction\)/)
  assert.match(applier, /transaction\.commit\(\)/)
  assert.match(applier, /transaction\.rollback\(\)/)
})

test('authorized requests retry a 401 once after refreshing the session', () => {
  const source = read('services/CloudSyncService.ets')

  assert.match(source, /statusCode === 401/)
  assert.match(source, /AccountSessionService\.refresh\(context\)/)
  assert.match(source, /retried/)
})

test('remote application never enters the local outbox', () => {
  const source = read('services/RemoteOperationApplier.ets')

  assert.doesNotMatch(source, /SyncOutboxService\.enqueue/)
  assert.match(source, /serverSequence/)
  assert.match(source, /SyncSequence\.compare/)
})
