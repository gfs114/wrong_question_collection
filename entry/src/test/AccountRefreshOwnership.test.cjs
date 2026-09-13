const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const { stripTypeScriptTypes } = require('node:module')

function createDisk() {
  return { secrets: new Map(), metadata: new Map(), calls: [], assetsWritten: 0,
    interruptMetadata: false }
}

function freshRuntime(disk) {
  const decode = bytes => new TextDecoder().decode(bytes)
  const key = attributes => decode(attributes.get('alias'))
  const asset = {
    Tag: { ALIAS: 'alias', SECRET: 'secret', ACCESSIBILITY: 'accessibility',
      SYNC_TYPE: 'sync', CONFLICT_RESOLUTION: 'conflict', RETURN_TYPE: 'return' },
    Accessibility: { DEVICE_FIRST_UNLOCKED: 1 }, SyncType: { NEVER: 0 },
    ConflictResolution: { OVERWRITE: 1 }, ReturnType: { ALL: 1 },
    add: async attributes => {
      disk.assetsWritten++
      disk.secrets.set(key(attributes), decode(attributes.get('secret')))
    },
    query: async attributes => disk.secrets.has(key(attributes)) ?
      [new Map([['secret', new TextEncoder().encode(disk.secrets.get(key(attributes)))]])] : [],
    remove: async attributes => { disk.secrets.delete(key(attributes)) }
  }
  const preferences = { getPreferences: async () => {
    if (disk.interruptMetadata) {
      disk.interruptMetadata = false
      throw new Error('simulated process interruption before metadata write')
    }
    return {
      get: async (name, fallback) => disk.metadata.has(name) ? disk.metadata.get(name) : fallback,
      put: async (name, value) => { disk.metadata.set(name, value) },
      delete: async name => { disk.metadata.delete(name) }, flush: async () => {}
    }
  } }
  const util = {
    TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value) } },
    TextDecoder: { create: () => ({ decodeToString: decode }) },
    generateRandomUUID: () => '11111111-1111-4111-8111-111111111111'
  }
  const source = ['models/AccountSession.ets', 'services/AccountSessionStore.ets',
    'services/AccountSessionService.ets'].map(path =>
    fs.readFileSync('entry/src/main/ets/' + path, 'utf8')
      .replace(/^import\s[\s\S]*?\sfrom\s+['"][^'"]+['"]\s*$/gm, '')
      .replace(/^export\s+/gm, '')).join('\n')
  return vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) +
    '\n({ AccountSessionService, AccountSessionStore })', {
    asset, preferences, util, Uint8Array,
    ApiHttpError: class extends Error {},
    ApiHttpClient: { post: async (url, body) => {
      disk.calls.push({ url, refreshToken: body.refreshToken })
      const owner = body.refreshToken.includes('B') ? 'B' : 'A'
      return { accessToken: 'access-' + owner, refreshToken: 'refresh-' + owner + '-rotated',
        expiresInSeconds: 3600 }
    } },
    CloudCacheService: { clearAccountTextCache: async () => {} }
  })
}

function login(owner) {
  return { userId: owner, deviceId: 'device-' + owner, accessToken: 'access-' + owner,
    refreshToken: 'refresh-' + owner, expiresInSeconds: 3600 }
}

test('interrupted B credential write cannot relabel its token as metadata account A after restart', async () => {
  const disk = createDisk()
  const original = freshRuntime(disk).AccountSessionService
  await original.installLogin({}, login('A'), 'device')
  disk.interruptMetadata = true
  await assert.rejects(original.installLogin({}, login('B'), 'device'))
  assert.equal(disk.metadata.get('user_id'), 'A')
  assert.equal(disk.assetsWritten, 2)
  const restarted = freshRuntime(disk).AccountSessionService
  const state = await restarted.state({})
  let access = ''
  try { access = await restarted.accessTokenForAccount({}, 'A') } catch {}
  await restarted.restore({})
  await restarted.signOut({})
  assert.equal(state.signedIn, false)
  assert.notEqual(access, 'access-B')
  assert.deepEqual(disk.calls, [])
})

test('normal login writes one owner-bound secret and restart refresh and logout retain its owner', async () => {
  const disk = createDisk()
  let service = freshRuntime(disk).AccountSessionService
  await service.installLogin({}, login('A'), 'device')
  assert.equal(await service.accessTokenForAccount({}, 'A'), 'access-A')
  assert.equal(disk.assetsWritten, 1)
  const record = JSON.parse(disk.secrets.get('wqc_refresh_token'))
  assert.deepEqual(record, { version: 1, ownerAccountId: 'A', refreshToken: 'refresh-A' })
  service = freshRuntime(disk).AccountSessionService
  await service.restore({})
  assert.equal(await service.accessTokenForAccount({}, 'A'), 'access-A')
  await service.signOut({})
  assert.deepEqual(disk.calls, [
    { url: '/v1/auth/refresh', refreshToken: 'refresh-A' },
    { url: '/v1/auth/logout', refreshToken: 'refresh-A-rotated' }
  ])
  assert.equal((await service.state({})).signedIn, false)
  assert.equal(disk.secrets.has('wqc_refresh_token'), false)
})

test('legacy and malformed secret records fail closed without refresh or logout requests', async () => {
  const invalid = ['legacy-raw-refresh-A', '{broken', 'null',
    '{"version":2,"ownerAccountId":"A","refreshToken":"refresh-A"}',
    '{"version":1,"ownerAccountId":"","refreshToken":"refresh-A"}',
    '{"version":1,"ownerAccountId":"A","refreshToken":""}',
    '{"version":1,"ownerAccountId":"A","refreshToken":"bad\\nheader"}',
    '{"version":1,"ownerAccountId":"A","refreshToken":"refresh-A","extra":true}']
  for (const secret of invalid) {
    const disk = createDisk()
    disk.metadata.set('user_id', 'A')
    disk.secrets.set('wqc_refresh_token', secret)
    const service = freshRuntime(disk).AccountSessionService
    assert.equal((await service.state({})).signedIn, false, secret)
    await service.restore({})
    await assert.rejects(service.accessTokenForAccount({}, 'A'))
    await service.signOut({})
    assert.deepEqual(disk.calls, [])
  }
})

test('metadata B with credential A also fails closed and cached access is not reused', async () => {
  const disk = createDisk()
  const service = freshRuntime(disk).AccountSessionService
  await service.installLogin({}, login('A'), 'device')
  disk.metadata.set('user_id', 'B')
  assert.equal((await service.state({})).signedIn, false)
  assert.equal(await service.accessToken({}), '')
  await assert.rejects(service.accessTokenForAccount({}, 'B'))
  assert.deepEqual(disk.calls, [])
})
