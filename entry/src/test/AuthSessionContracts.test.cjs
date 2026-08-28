const fs = require('fs')
const path = require('path')

const projectRoot = path.resolve(__dirname, '../../..')

function read(relativePath) {
  return fs.readFileSync(path.join(projectRoot, relativePath), 'utf8')
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

// 1. Login must use the official Account Kit component and exchange only the
//    short-lived authorization code with the app backend.
const card = read('entry/src/main/ets/components/HuaweiAccountCard.ets')
const login = read('entry/src/main/ets/services/HuaweiLoginService.ets')
expectIncludes(card, 'LoginWithHuaweiIDButton', 'login must use the official Huawei ID button')
expectIncludes(card, 'loginComponentManager', 'login must use the official component controller')
expectIncludes(login, 'authorizationCode', 'login must exchange the authorization code')
expectIncludes(login, '/v1/auth/huawei', 'login must exchange the code with the backend')
expectMissing(login, 'idToken', 'ID tokens must not be forwarded to the app backend')

// 2. Sensitive session values must use Asset Store; only non-sensitive
//    metadata may use Preferences.
const session = read('entry/src/main/ets/services/AccountSessionService.ets')
const store = read('entry/src/main/ets/services/AccountSessionStore.ets')
expectIncludes(store, "from '@kit.AssetStoreKit'", 'tokens must be persisted with Asset Store Kit')
expectIncludes(store, 'asset.Tag.SECRET', 'refresh token must be an encrypted asset secret')
expectIncludes(session, '/v1/auth/refresh', 'session refresh must call the backend')
expectIncludes(session, '/v1/auth/logout', 'sign-out must call the backend')
expectIncludes(session, 'accessTokenExpiresAt', 'access token expiry must be tracked in memory')
expectMissing(session, "put('access_token'", 'access token must not be persisted in Preferences')
expectMissing(session, "put('refresh_token'", 'refresh token must not be persisted in Preferences')

// 3. The Mine page must host the login card and preserve local-first copy.
const minePage = read('entry/src/main/ets/pages/MinePage.ets')
expectIncludes(minePage, 'HuaweiAccountCard', 'Mine page must host the account card')
expectIncludes(minePage, 'signOut', 'Mine page must trigger sign-out')
expectMissing(minePage, '所有学习数据仅保存在本机', 'local-only copy must be updated')
expectIncludes(minePage, 'PDF 原文件和题图始终保存在本机', 'privacy copy must mention on-device PDFs')

process.stdout.write('Auth session contracts passed\n')
