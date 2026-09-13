const fs = require('fs')
const path = require('path')

const etsRoot = path.resolve(__dirname, '../main/ets')

function read(relativePath) {
  const file = path.join(etsRoot, relativePath)
  if (!fs.existsSync(file)) {
    throw new Error(relativePath + ' is required')
  }
  return fs.readFileSync(file, 'utf8')
}

function expectIncludes(source, text, message) {
  if (!source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

function expectMissing(source, text, message) {
  if (source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

const store = read('services/AccountSessionStore.ets')
const service = read('services/AccountSessionService.ets')
const model = read('models/AccountSession.ets')
const bootstrap = read('services/AppBootstrapService.ets')

expectIncludes(store, "from '@kit.AssetStoreKit'", 'sensitive values must use Asset Store Kit')
expectIncludes(store, 'asset.Tag.SECRET', 'Asset Store records must place tokens in the secret field')
expectIncludes(store, 'asset.SyncType.NEVER', 'session secrets must never be cloned or synced')
expectIncludes(store, 'REFRESH_TOKEN_ALIAS', 'refresh token needs a stable protected alias')
expectIncludes(store, 'DEVICE_KEY_ALIAS', 'device key needs a stable protected alias')
expectIncludes(store, 'class AccountRefreshCredential', 'refresh credentials require typed owner binding')
expectIncludes(store, 'version: number = 1', 'refresh secret records must be versioned')
expectIncludes(store, 'ownerAccountId: string', 'owner and token must share one secret record')
expectIncludes(store, 'JSON.stringify(snapshot)', 'the complete credential must be written atomically')
expectIncludes(store, 'refreshCredential()', 'refresh reads must return a validated credential')
expectIncludes(service, 'credential.ownerAccountId !== accountId', 'refresh must reject a mismatched owner')
expectMissing(store, 'static async refreshToken()', 'legacy raw tokens must not be returned')
expectMissing(store, 'static async saveRefreshToken(', 'ownerless writes must not remain available')
expectMissing(service, 'AccountSessionStore.refreshToken()', 'metadata cannot supply an owner for a raw token')
expectIncludes(service, 'private static accessTokenValue', 'access token must be memory-only')
expectIncludes(service, 'private static refreshInFlight', 'concurrent refreshes must be collapsed')
expectIncludes(service, 'expiresInSeconds', 'client must use the actual server expiry field')
expectIncludes(service, "'/v1/auth/refresh'", 'session refresh must call the backend')
expectIncludes(service, "'/v1/auth/logout'", 'sign-out must revoke the backend session')
expectIncludes(service, 'clearSession()', 'refresh failure and sign-out need a local cleanup path')
expectIncludes(service, 'AccountSessionStore.deviceKey()', 'device key must be stable across launches')
expectIncludes(model, 'expiresInSeconds: number', 'token contract must match the server')
expectIncludes(bootstrap, 'AccountSessionService.restore(context)', 'bootstrap must restore the app session')
expectMissing(service, "put('access_token'", 'access token must not be written to Preferences')
expectMissing(service, "put('refresh_token'", 'refresh token must not be written to Preferences')
expectMissing(service, 'accessTokenExpiresAt: string', 'obsolete server fields must be removed')

process.stdout.write('Account session contracts passed\n')
