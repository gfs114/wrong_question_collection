'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const { test } = require('node:test')
const { stripTypeScriptTypes } = require('node:module')

const read = path => fs.readFileSync(path, 'utf8')

function extractMethod(source, signature) {
  const start = source.indexOf(signature)
  assert.notEqual(start, -1, `missing method ${signature}`)
  const openingBrace = source.indexOf('{', start)
  let depth = 0
  for (let index = openingBrace; index < source.length; index++) {
    if (source[index] === '{') depth += 1
    if (source[index] === '}') {
      depth -= 1
      if (depth === 0) return source.slice(start, index + 1)
    }
  }
  assert.fail(`unterminated method ${signature}`)
}

function runtime(credentialStore = { withCredential() { throw Error('real credential access forbidden') } }) {
  const config = read('entry/src/main/ets/models/ai/AiProviderConfig.ets')
    .replace(/import[^\n]+\n/g, '').replace(/export /g, '')
  const service = read('entry/src/main/ets/services/ai/AiModelCatalogService.ets')
    .replace(/import[\s\S]*?from\s*'[^']+'\s*/g, '').replace(/export /g, '')
  return vm.runInNewContext(stripTypeScriptTypes(config + service, { mode: 'transform' }) +
    '\n({ AiModelListParser, AiModelCatalogService, AiImportErrorCode })', {
    url: { URL: { parseURL: text => new URL(text) } },
    util: {
      TextEncoder: class { encodeInto(text) { return new Uint8Array(Buffer.from(text, 'utf8')) } },
      generateRandomUUID: require('node:crypto').randomUUID,
    },
    AiCredentialStore: credentialStore,
    AiVisionTransport: class { constructor() { throw Error('real network forbidden') } },
  })
}

test('settings removes static recommendations and fetches with typed or saved credentials', () => {
  const page = read('entry/src/main/ets/pages/AiRecognitionSettingsPage.ets')
  assert.doesNotMatch(page, /推荐视觉模型|platformModels|AiPlatformModel/)
  assert.match(page, /@State availableModels: Array<string>/)
  assert.match(page, /Select\(this\.modelOptions\(\)\)/)
  assert.match(page, /this\.FieldLabel\('云端模型'\)/)

  const serviceSection = extractMethod(page, 'private ServiceAndModelSection')
  assert.doesNotMatch(serviceSection, /密钥会发送至此地址|Text\(this\.platformNote\)/,
    'the custom-address action must not leave explanatory copy below it')
  const customAddressAction = serviceSection.indexOf("Button(this.urlEditable ? '完成自定义地址' : '自定义地址')")
  const cleartextWarning = serviceSection.indexOf("Text('⚠ 明文 HTTP")
  assert.ok(cleartextWarning >= 0 && cleartextWarning < customAddressAction,
    'the conditional HTTP safety warning must remain above the custom-address action')

  const fetch = extractMethod(page, 'private async fetchCloudModels')
  assert.match(fetch, /new AiModelCatalogService\(\)[\s\S]*?\.fetchWithApiKey/)
  assert.match(fetch, /fetchWithSavedCredential/)
  assert.match(fetch, /canUseSavedCredential/)
  assert.match(fetch, /this\.availableModels = models\.slice\(\)/)
  assert.doesNotMatch(fetch, /this\.model = ''/,
    'catalog refresh must keep the saved model visible when it is missing or the response is empty')
  assert.doesNotMatch(fetch, /AiCredentialStore\.withCredential|console\.|hilog\./)

  const keyStart = page.indexOf("this.FieldLabel('API Key')")
  const keyEnd = page.indexOf("Button(this.showKey", keyStart)
  const keyInput = page.slice(keyStart, keyEnd)
  assert.match(keyInput, /\.onChange\(\(value: string\) => \{[\s\S]*this\.model = ''[\s\S]*this\.availableModels = new Array<string>\(\)/,
    'typing a replacement key must invalidate the old model before cloud discovery')
  assert.match(keyInput, /\.onSubmit\(\(\) => \{ this\.fetchCloudModels\(\) \}\)/)
  assert.match(keyInput, /\.onBlur\(\(\) => \{[\s\S]*this\.fetchCloudModels\(\)/)

  const addressStart = page.indexOf("this.FieldLabel('API 地址')")
  const addressEnd = page.indexOf("Button(this.urlEditable", addressStart)
  const addressInput = page.slice(addressStart, addressEnd)
  assert.match(addressInput, /\.onChange\(\(value: string\) => \{[\s\S]*this\.model = ''[\s\S]*this\.availableModels = new Array<string>\(\)/,
    'changing the provider address must invalidate the old model')

  const picker = read('entry/src/main/ets/pages/AiPlatformPickerPage.ets')
  assert.doesNotMatch(picker, /未确认视觉模型|return '视觉'/)
  assert.match(picker, /return '云端模型'/)
})

test('model list parser accepts the OpenAI envelope, deduplicates ids and rejects malformed payloads', () => {
  const r = runtime()
  const models = r.AiModelListParser.parse(JSON.stringify({
    object: 'list',
    data: [
      { id: 'vision-b', object: 'model' },
      { id: 'vision-a', object: 'model' },
      { id: 'vision-b', object: 'model' },
    ],
  }))
  assert.deepEqual(Array.from(models), ['vision-a', 'vision-b'])
  for (const invalid of ['{}', '{"data":null}', '{"data":[{"id":"bad id"}]}', 'not json']) {
    assert.throws(() => r.AiModelListParser.parse(invalid), error =>
      error.code === r.AiImportErrorCode.INVALID_JSON)
  }
})

test('typed key model fetch stays bounded, uses one GET endpoint and zeroes credential bytes', async () => {
  const r = runtime()
  let captured = null
  let calls = 0
  const transport = {
    async getJson(endpoint, credential, requestKey) {
      calls += 1
      assert.equal(endpoint, 'https://provider.invalid/v1/models')
      assert.match(requestKey, /^ai-model-list-/)
      captured = credential
      assert.equal(Buffer.from(credential).toString('utf8'), 'fake-key')
      return '{"data":[{"id":"vision-model"}]}'
    },
  }
  const service = new r.AiModelCatalogService(transport)
  const models = await service.fetchWithApiKey('https://provider.invalid/v1/', ' fake-key ')
  assert.deepEqual(Array.from(models), ['vision-model'])
  assert.equal(calls, 1)
  assert.ok(captured !== null)
  assert.ok(Array.from(captured).every(value => value === 0), 'temporary credential bytes must be erased')
})

test('saved key model fetch keeps the entire transport await inside credential scope', async () => {
  let active = false
  const credential = new Uint8Array(Buffer.from('saved-fake-key'))
  let release
  const barrier = new Promise(resolve => { release = resolve })
  const r = runtime({
    async withCredential(context, action) {
      assert.equal(context, 'fake context')
      active = true
      try {
        return await action(credential)
      } finally {
        active = false
        credential.fill(0)
      }
    },
  })
  let entered
  const enteredPromise = new Promise(resolve => { entered = resolve })
  const service = new r.AiModelCatalogService({
    async getJson(endpoint, key) {
      assert.equal(endpoint, 'https://provider.invalid/v1/models')
      assert.equal(key, credential)
      assert.equal(active, true)
      entered()
      await barrier
      assert.equal(active, true)
      return '{"data":[{"id":"vision-model"}]}'
    },
  })

  const pending = service.fetchWithSavedCredential('fake context', 'https://provider.invalid/v1')
  await enteredPromise
  assert.equal(active, true)
  release()
  const models = await pending

  assert.deepEqual(Array.from(models), ['vision-model'])
  assert.equal(active, false)
  assert.ok(Array.from(credential).every(value => value === 0))
})

test('transport owns authenticated model GET with the same endpoint and response bounds', () => {
  const transport = read('entry/src/main/ets/services/ai/AiVisionTransport.ets')
  const get = extractMethod(transport, 'async getJson')
  assert.match(get, /AiProviderConfigValidator\.isAllowedEndpoint\(endpoint\)/)
  assert.match(get, /method: http\.RequestMethod\.GET/)
  assert.match(get, /maxRedirects: 0/)
  assert.match(get, /maxLimit: AiImportLimits\.MAX_RESPONSE_BYTES/)
  assert.match(get, /AiCredentialHeaderValidator\.decode\(credential\)/)
  assert.match(get, /finally[\s\S]*headers\.Authorization = ''[\s\S]*credentialText = ''/)
  assert.doesNotMatch(get, /extraData|console\.|hilog\./)
})
