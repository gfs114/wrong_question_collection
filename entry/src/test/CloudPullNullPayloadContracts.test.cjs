const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const etsRoot = path.resolve(__dirname, '..', 'main', 'ets')

function read(relativePath) {
  const filePath = path.join(etsRoot, relativePath)
  assert.equal(fs.existsSync(filePath), true, `Missing source: ${relativePath}`)
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

test('SyncPayloadData mirrors the server contract and allows explicit null optionals', () => {
  const source = read('models/SyncModels.ets')

  assert.match(source, /type\?:\s*string \| null/)
  assert.match(source, /options\?:\s*Record<string, string> \| null/)
  assert.match(source, /answer\?:\s*string \| null/)
  assert.match(source, /analysis\?:\s*string \| null/)
  assert.match(source, /name\?:\s*string \| null/)
  assert.match(source, /subject\?:\s*string \| null/)
  assert.match(source, /bankClientId\?:\s*string \| null/)
  assert.match(source, /status\?:\s*string \| null/)
})

test('applyQuestion normalizes null question payloads into strict cache values', () => {
  const source = read('services/CloudQuestionRepository.ets')
  const applyQuestion = extractMethod(source, 'private static applyQuestion')

  assert.match(applyQuestion,
    /bankClientId === undefined \|\|\s*operation\.payload\.bankClientId === null/)
  assert.match(applyQuestion,
    /type === undefined \|\|\s*operation\.payload\.type === null[\s\S]*'unclassified'/)
  assert.match(applyQuestion,
    /question === undefined \|\|\s*operation\.payload\.question === null[\s\S]*'未命名题目'/)
  assert.match(applyQuestion,
    /answer === undefined \|\|\s*operation\.payload\.answer === null[\s\S]*''/)
  assert.match(applyQuestion,
    /analysis === undefined \|\|\s*operation\.payload\.analysis === null[\s\S]*''/)

  const optionsJson = extractMethod(source, 'private static optionsJson')
  assert.match(optionsJson, /Record<string, string> \| null \| undefined/)
  assert.match(optionsJson, /options === undefined \|\| options === null[\s\S]*return '\[\]'/)
})

test('applyBank and applyWrongQuestion normalize null optionals as well', () => {
  const source = read('services/CloudQuestionRepository.ets')
  const applyBank = extractMethod(source, 'private static applyBank')
  const applyWrongQuestion = extractMethod(source, 'private static applyWrongQuestion')

  assert.match(applyBank,
    /name === undefined \|\|\s*operation\.payload\.name === null[\s\S]*'云端题库'/)
  assert.match(applyBank,
    /subject === undefined \|\|\s*operation\.payload\.subject === null[\s\S]*'未分类'/)
  assert.match(applyWrongQuestion,
    /status === undefined \|\|\s*operation\.payload\.status === null[\s\S]*'pending'/)
})

test('legacy remote applier is null-safe so it still compiles against the aligned model', () => {
  const source = read('services/RemoteOperationApplier.ets')

  assert.match(source, /payload\.name === undefined \|\| payload\.name === null/)
  assert.match(source, /payload\.subject === undefined \|\| payload\.subject === null/)
  assert.match(source, /payload\.bankClientId === undefined \|\| payload\.bankClientId === null/)
  assert.match(source, /payload\.type === undefined \|\| payload\.type === null/)
  assert.match(source, /payload\.question === undefined \|\| payload\.question === null/)
  assert.match(source, /payload\.answer === undefined \|\| payload\.answer === null/)
  assert.match(source, /payload\.analysis === undefined \|\| payload\.analysis === null/)
  const optionsJson = extractMethod(source, 'private static optionsJson')
  assert.match(optionsJson, /options === undefined \|\| options === null/)
})

test('only real network failures mark pages offline; other refresh errors show sync failure', () => {
  const policy = read('services/ConnectivityPolicy.ets')

  assert.match(policy, /static isOfflineError\(err:\s*Error\):\s*boolean/)
  const isOfflineError = extractMethod(policy, 'static isOfflineError')
  assert.match(isOfflineError, /err instanceof ApiHttpError[\s\S]*return false/)
  assert.match(isOfflineError, /err as BusinessError/)
  assert.match(isOfflineError, /code >= 2300000 && code < 2320000/)

  const pages = [
    'pages/HomePage.ets',
    'pages/BooksPage.ets',
    'pages/QuestionListPage.ets',
    'pages/QuestionDetailPage.ets',
    'pages/EditQuestionPage.ets',
    'pages/WrongQuestionsPage.ets',
    'pages/WrongQuestionDetailPage.ets'
  ]
  for (const file of pages) {
    const source = read(file)
    assert.match(source, /ConnectivityPolicy\.isOfflineError\(err\)/,
      `${file} must classify refresh failures instead of assuming offline`)
    assert.match(source, /同步失败：正在显示本地缓存/,
      `${file} must show the sync-failure banner copy`)
    assert.match(source, /离线浏览/, `${file} must keep the true offline copy`)
  }
})
