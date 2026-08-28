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

const card = read('components/HuaweiAccountCard.ets')
const service = read('services/HuaweiLoginService.ets')
const mine = read('pages/MinePage.ets')

expectIncludes(card, "from '@kit.AccountKit'", 'account card must use Account Kit')
expectIncludes(card, 'LoginWithHuaweiIDButton', 'account card must render the official login button')
expectIncludes(card, 'loginComponentManager', 'account card must use the official controller')
expectIncludes(card, 'authorizationCode', 'account card must return only the short-lived code')
expectIncludes(card, '.systemMaterial(ImmersiveMaterials.accountCard)',
  'account card must use the official immersive account material')
expectIncludes(card, '登录后开启云同步', 'signed-out copy must explain optional sync')
expectIncludes(card, '本地功能无需登录即可使用', 'signed-out copy must preserve local-first behavior')
expectIncludes(card, '已登录华为账号', 'signed-in state must be visible')
expectIncludes(card, '退出登录', 'signed-in state must offer sign-out')
expectIncludes(service, '1001502012', 'user cancellation must be recognized')
expectIncludes(service, 'authorizationCode: authorizationCode', 'only the authorization code is exchanged')
expectIncludes(service, 'deviceKey: deviceKey', 'backend exchange must identify the device')
expectIncludes(service, 'deviceName: deviceName', 'backend exchange must include the display name')
expectIncludes(service, "'/v1/auth/huawei'", 'authorization code must go to the backend')
expectIncludes(service, 'AccountSessionService.installLogin', 'login result must enter the secure session layer')
expectIncludes(mine, 'HuaweiAccountCard({', 'Mine page must host the account card')
expectIncludes(mine, 'HuaweiLoginService.exchange', 'Mine page must exchange the official authorization code')
expectMissing(service, 'Client Secret', 'client login service must never contain a client secret')
expectMissing(service, 'idToken', 'ID token must not be sent to the app backend')
expectMissing(service, 'unionID', 'raw Huawei identity must not be sent to the app backend')

process.stdout.write('Huawei login contracts passed\n')
