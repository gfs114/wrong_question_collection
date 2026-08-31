const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const assert = require('node:assert/strict')

const etsRoot = path.resolve(__dirname, '..', 'main', 'ets')

function read(relativePath) {
  const filePath = path.join(etsRoot, relativePath)
  assert.equal(fs.existsSync(filePath), true, `Missing Task 12 source: ${relativePath}`)
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

test('ConnectivityPolicy allows mutation only when signed in and online', () => {
  const source = read('services/ConnectivityPolicy.ets')

  assert.match(source, /export class ConnectivityPolicy/)
  assert.match(source, /static canMutate\(isSignedIn:\s*boolean,\s*isOnline:\s*boolean\):\s*boolean/)
  const canMutate = extractMethod(source, 'static canMutate')
  assert.match(canMutate, /return isSignedIn && isOnline/)
  // The policy must also expose read-only/offline state for page usage.
  assert.match(source, /static isOfflineBrowsing\(isSignedIn:\s*boolean,\s*isOnline:\s*boolean\)/)
  assert.match(source, /static isReadOnly\(isSignedIn:\s*boolean,\s*isOnline:\s*boolean\)/)
  assert.match(source, /离线浏览/)
})

test('every data page shows the offline read-only state and uses the cloud repository', () => {
  const pages = [
    'BooksPage',
    'QuestionListPage',
    'QuestionDetailPage',
    'EditQuestionPage',
    'WrongQuestionsPage',
    'WrongQuestionDetailPage',
    'HomePage'
  ]
  for (const name of pages) {
    const source = read(`pages/${name}.ets`)
    assert.match(source, /离线浏览/, `${name} must carry the offline banner copy`)
    assert.match(source, /CloudQuestionRepository/, `${name} must read through the cloud repository`)
    assert.doesNotMatch(source, /SyncOutboxService/, `${name} must never write the legacy outbox`)
  }
})

test('pages never call the old local-first mutation services', () => {
  const pages = [
    'BooksPage',
    'QuestionListPage',
    'QuestionDetailPage',
    'EditQuestionPage',
    'WrongQuestionsPage',
    'WrongQuestionDetailPage',
    'HomePage'
  ]
  const localFirstMutations = /QuestionBankService\.(?:updateQuestion|deleteBank|saveImportedBank|savePdfBank)|WrongQuestionService\.(?:add|remove|markMastered|clear|listSummaries|getDetail)/
  for (const name of pages) {
    const source = read(`pages/${name}.ets`)
    assert.doesNotMatch(source, localFirstMutations,
      `${name} must not call local-first mutation services`)
  }
})

test('mutation buttons are disabled or guarded when offline or signed out', () => {
  const edit = read('pages/EditQuestionPage.ets')
  assert.match(edit, /ConnectivityPolicy\.canMutate\(this\.signedIn,\s*!this\.offline\)/)
  assert.match(edit, /未登录，无法保存/)
  assert.match(edit, /离线浏览[\s\S]{0,80}只读状态[\s\S]{0,80}无法保存/)

  const detail = read('pages/QuestionDetailPage.ets')
  assert.match(detail, /ConnectivityPolicy\.canMutate\(this\.signedIn,\s*!this\.offline\)/)
  assert.match(detail, /setWrongState/)

  const wrongDetail = read('pages/WrongQuestionDetailPage.ets')
  assert.match(wrongDetail, /ConnectivityPolicy\.canMutate\(this\.signedIn,\s*!this\.offline\)/)
  assert.match(wrongDetail, /setWrongState/)

  const books = read('pages/BooksPage.ets')
  assert.match(books, /ConnectivityPolicy\.canMutate\(this\.signedIn,\s*!this\.offline\)/)
  assert.match(books, /CloudQuestionRepository\.deleteBank/)
})

test('CloudQuestionRepository exposes the required server-first API', () => {
  const source = read('services/CloudQuestionRepository.ets')

  assert.match(source, /export class CloudQuestionRepository/)
  assert.match(source, /static async listCachedBanks\(accountId:\s*string\)/)
  assert.match(source, /static async refresh\(accountId:\s*string,\s*context:\s*Context\)/)
  assert.match(source, /static async updateQuestion\(question:\s*Question,\s*context:\s*Context\)/)
  assert.match(source, /static async setWrongState\(questionUuid:\s*string,\s*status:\s*string,\s*context:\s*Context\)/)
  assert.match(source, /\/v1\/sync\/push/)
  assert.match(source, /\/v1\/sync\/pull/)
})

test('mutation order is server request then server success then cache update', () => {
  const source = read('services/CloudQuestionRepository.ets')

  const pushPath = source.indexOf("'/v1/sync/push'")
  const cacheReplace = source.indexOf('CloudCacheService.replacePage')
  assert.ok(pushPath >= 0, '/v1/sync/push must exist')
  assert.ok(cacheReplace > pushPath,
    'cache must be replaced only after the server push succeeds')

  const pullPath = source.indexOf("'/v1/sync/pull?cursor='")
  const refresh = extractMethod(source, 'static async refresh')
  assert.ok(pullPath >= 0, '/v1/sync/pull must exist')
  assert.ok(refresh.indexOf('saveSnapshot') > refresh.indexOf('authorizedPull'),
    'refresh must finish pulling before writing the cache')

  assert.doesNotMatch(source, /SyncOutboxService\.enqueue/,
    'repository must never insert into the legacy outbox')
  assert.doesNotMatch(source, /QuestionBankService|WrongQuestionService/,
    'repository must not reuse local-first mutation services')
  assert.doesNotMatch(source, /INSERT INTO question\b|UPDATE question\b|DELETE FROM question\b/,
    'repository must never perform speculative local mutations')
})

test('refresh failure preserves the existing cloud cache', () => {
  const source = read('services/CloudQuestionRepository.ets')

  assert.doesNotMatch(source, /clearAccountTextCache/,
    'refresh must never clear the account cache')
  assert.doesNotMatch(source, /DELETE FROM cloud_/,
    'repository must never delete cache rows')
  const refresh = extractMethod(source, 'static async refresh')
  assert.match(refresh, /while \(hasMore\)/)
  assert.match(refresh, /if \(operations\.length === 0\)[\s\S]*return/)
  assert.ok(refresh.indexOf('saveSnapshot') > refresh.indexOf('while (hasMore)'),
    'cache must be written only after the full pull finishes')
})

test('mutation success reflects in cache before the page refreshes', () => {
  const source = read('services/CloudQuestionRepository.ets')
  const update = extractMethod(source, 'static async updateQuestion')
  const push = extractMethod(source, 'private static async pushOne')
  assert.match(update, /pushOne\(context, accountId, SyncEntityType\.QUESTION/)
  assert.match(push, /authorizedPost<SyncPushResponse>\('\/v1\/sync\/push'/)
  assert.ok(push.indexOf('applyOrdered') > push.indexOf("'/v1/sync/push'"),
    'authoritative operations must be applied only after the server responds')
  assert.ok(push.indexOf('saveSnapshot') > push.indexOf('applyOrdered'),
    'cache save must follow the authoritative operation application')
})
