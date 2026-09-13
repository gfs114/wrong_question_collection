'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { test } = require('node:test')
const vm = require('node:vm')
const { stripTypeScriptTypes } = require('node:module')

test('AI recognition settings expose explicit credential controls and both routes', () => {
  const pagePath = 'entry/src/main/ets/pages/AiRecognitionSettingsPage.ets'
  assert.ok(fs.existsSync(path.join(projectRoot, pagePath)), 'AI settings page must exist')
  const page = read(pagePath)
  for (const label of ['AI 视觉识别（推荐）', '平台', 'API 地址', 'API Key', '云端模型', '选择模型',
    '保存设置', '清除 API Key', '测试连接', '已配置', '自定义',
    '测试连接会发送一张极小测试图片，可能产生极少量模型费用']) assert.ok(page.includes(label), label)
  assert.ok(!page.includes('推荐视觉模型'), 'settings must not present static recommended models')
  assert.doesNotMatch(page, /OpenAI 官方|OpenAI-compatible 自定义/)
  assert.match(page, /AiPlatformCatalog\.find/)
  assert.match(page, /AiPlatformAccess\.LOCAL_HTTP/)
  assert.match(page, /必须重新输入 API Key|REPLACEMENT_KEY_REQUIRED/)
  assert.match(page, /AiPlatformSelectionState\.shared\(\)\.peek\(\)/)
  // UI 半边不被 settingsRuntime 执行，故用源码断言钉住这几处修复；谓词另有行为断言见平台行用例。
  assert.match(page, /AiModelCatalogService/)
  assert.doesNotMatch(page, /platformNote !== this\.statusMessage/)
  assert.match(page, /if \(this\.isCleartextAddress\(\)\) \{\s*Text\('⚠ 明文 HTTP/)
  assert.match(page, /明文 HTTP 仅适用于本机或私网服务/)
  assert.doesNotMatch(page, /Text\(this\.platformNote\)/)
  const setupPage = read('entry/src/main/ets/pages/PdfAiImportSetupPage.ets')
  // 单条有序断言：守卫必须在调用之前（倒置即回归），惰性跨行匹配注释与缩进。
  assert.match(setupPage,
    /onPageShow\(\): void \{[\s\S]{0,200}?if \(!this\.selectionReady\) return\s*this\.loadProviderSummary\(\)/)
  const mine = read('entry/src/main/ets/pages/MinePage.ets')
  assert.ok(mine.indexOf("Text('AI 识别设置')") < mine.indexOf("Text('深色模式')"))
  assert.match(mine, /pages\/AiRecognitionSettingsPage/)
  const route = 'pages/AiRecognitionSettingsPage'
  assert.equal(JSON.parse(read('entry/src/main/resources/base/profile/main_pages.json')).src.filter(p => p === route).length, 1)
  const easy = JSON.parse(read('entry/src/main/resources/base/profile/easy_go.json'))
  assert.equal(easy.common.displayModeOptions.routerSplitOptions.fullScreenPages.filter(p => p === route).length, 1)
})

test('AI PDF setup validates durable provider state, account and key before progress', () => {
  const setupPath = 'entry/src/main/ets/pages/PdfAiImportSetupPage.ets'
  assert.ok(fs.existsSync(path.join(projectRoot, setupPath)), 'AI setup page must exist')
  const source = read(setupPath)
  for (const label of ['已选择 PDF', '识别服务', '识别平台', '识别模型', '题库信息',
    '选择科目', '起始页', '结束页', '单次最多 20 页', '调整 AI 设置']) {
    assert.ok(source.includes(label), label)
  }
  for (const oldLabel of ['AI 视觉识别（推荐）', 'Provider', 'Model', '本机直连']) {
    assert.ok(!source.slice(source.indexOf('  @Builder')).includes(oldLabel), oldLabel)
  }
  assert.match(source, /AiProviderConfigStore\.loadUsable\(context\)/)
  assert.doesNotMatch(source, /AiProviderConfigStore\.load\(context\)/)
  const start = source.slice(source.indexOf('private async startRecognition'), source.indexOf('  @Builder'))
  const accountIndex = start.indexOf('AccountSessionService.state(context)')
  const configIndex = start.indexOf('AiProviderConfigStore.loadUsable(context)')
  const keyIndex = start.indexOf('AiCredentialStore.hasCredential(context)')
  const stateIndex = start.indexOf('state.setSettings')
  const routeIndex = start.indexOf("pages/PdfAiImportProgressPage")
  assert.ok(accountIndex >= 0 && configIndex > accountIndex && keyIndex > configIndex)
  assert.ok(stateIndex > keyIndex && routeIndex > stateIndex)
  assert.match(start, /AiImportErrorMessages\.forCode\(err\.code\)/)
  assert.doesNotMatch(source,
    /CloudImportService|CloudImportApi|\/v1\/imports\/pdf|PaddleOCR|textRecognition|OcrService|fallback|err\.message/)
})

test('AI PDF progress starts once and owns one cancellation cleanup path', () => {
  const progressPath = 'entry/src/main/ets/pages/PdfAiImportProgressPage.ets'
  assert.ok(fs.existsSync(path.join(projectRoot, progressPath)), 'AI progress page must exist')
  const source = read(progressPath)
  assert.equal((source.match(/PdfAiImportCoordinator\.createDefault\(\)/g) || []).length, 1)
  assert.match(source, /private coordinator:\s*PdfAiImportCoordinator/)
  assert.match(source, /private request:\s*PdfAiImportRequest \| null = null/)
  assert.match(source, /private selectedPdfPath:\s*string = ''/)
  assert.match(source, /private completedSessionId:\s*string = ''/)
  assert.match(source, /AiImportCleanupRequiredError/)
  assert.match(source, /private started:\s*boolean\s*=\s*false/)
  assert.match(source, /@State cancellable:\s*boolean\s*=\s*true/)
  assert.match(source, /@State cleanupPending:\s*boolean\s*=\s*false/)
  assert.match(source, /@State reviewNavigationFailed:\s*boolean\s*=\s*false/)
  assert.match(source, /aboutToAppear\(\):\s*void\s*{[\s\S]*?!this\.started[\s\S]*?this\.started = true[\s\S]*?this\.startImport\(\)/)
  assert.match(source, /AiProviderConfigStore\.loadUsable\(context\)/)
  assert.doesNotMatch(source, /AiProviderConfigStore\.load\(context\)/)
  const start = source.slice(source.indexOf('private async startImport'), source.indexOf('private cancelImport'))
  const configIndex = start.indexOf('AiProviderConfigStore.loadUsable(context)')
  const accountIndex = start.indexOf('AccountSessionService.state(context)')
  const keyIndex = start.indexOf('AiCredentialStore.hasCredential(context)')
  const runIndex = start.indexOf('this.coordinator.run')
  assert.ok(configIndex >= 0 && accountIndex > configIndex && keyIndex > accountIndex && runIndex > keyIndex)
  assert.match(start,
    /await this\.coordinator\.run[\s\S]*?this\.running = false[\s\S]*?this\.cancellable = false[\s\S]*?state\.setReviewSessionId/)
  assert.match(start, /state\.setReviewSessionId\(sessionId\)/)
  assert.match(start, /AiImportErrorMessages\.forCode\(err\.code\)/)
  assert.match(start,
    /err instanceof AiImportCleanupRequiredError[\s\S]*?await this\.cleanupAndReturn\(\)/)
  assert.equal((source.match(/this\.coordinator\.discard\(context, this\.request\)/g) || []).length, 1)
  assert.equal((source.match(/PdfImportService\.removeTemporaryPdf\(this\.selectedPdfPath\)/g) || []).length, 1)
  assert.equal((source.match(/this\.coordinator\.cancel\(\)/g) || []).length, 1)
  assert.match(source, /取消识别/)
  assert.match(source, /重试清理/)
  assert.match(source, /重新进入审核/)
  assert.match(source, /放弃并清理/)
  assert.match(source,
    /private async continueToReview[\s\S]*?AccountSessionService\.state\(context\)[\s\S]*?account\.userId !== this\.request\.accountId/)
  const retryNavigation = source.slice(source.indexOf('private async retryReviewNavigation'),
    source.indexOf('private async abandonCompletedImport'))
  assert.match(retryNavigation, /continueToReview/)
  assert.doesNotMatch(retryNavigation, /coordinator\.run/)
  assert.doesNotMatch(source,
    /CloudImportService|CloudImportApi|\/v1\/imports\/pdf|PaddleOCR|textRecognition|OcrService|fallback|autoRetry|err\.message/)
})

function connectionRuntime(credentialStore) {
  const servicePath = 'entry/src/main/ets/services/ai/AiConnectionTestService.ets'
  assert.ok(fs.existsSync(path.join(projectRoot, servicePath)), 'connection service must exist')
  const clean = source => source.replace(/import[\s\S]*?from\s*'[^']+'\s*;?/g, '').replace(/export /g, '')
  const source = clean(read('entry/src/main/ets/models/ai/AiProviderConfig.ets')) +
    clean(read('entry/src/main/ets/services/ai/AiProviderAdapter.ets')) + clean(read(servicePath))
  return vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) +
    '\n({ AiConnectionTestService, AiProviderConfig, AiProviderId, AiImportError, AiImportErrorCode, AiProviderRequest })', {
    url: { URL: { parseURL: text => new URL(text) } },
    util: {
      generateRandomUUID: require('node:crypto').randomUUID,
      TextEncoder: class { encodeInto(text) { return new Uint8Array(Buffer.from(text, 'utf8')) } },
    },
    AiCredentialStore: credentialStore || { withCredential: () => { throw Error('real credential access forbidden') } },
    AiProviderConfigStore: { withUsableConfig: async (context, config, action) => action() },
    AiVisionTransport: class { constructor() { throw Error('real transport forbidden') } },
    OpenAiCompatibleAdapter: class { constructor() { throw Error('real adapter forbidden') } },
  })
}

test('connection test sends one 1x1 JPEG with normalized form config and releases its request', async () => {
  const r = connectionRuntime()
  const credential = new Uint8Array([102, 97, 107, 101])
  const config = new r.AiProviderConfig(r.AiProviderId.CUSTOM, ' model-new ', 'https://vision.invalid/v1/')
  const requests = [], keys = []
  let calls = 0, extractions = 0
  const adapter = {
    buildRequest(c, prompt, jpeg) {
      assert.equal(c.model, 'model-new'); assert.equal(c.baseUrl, 'https://vision.invalid/v1')
      assert.ok(prompt.length < 300)
      const bytes = Buffer.from(jpeg, 'base64')
      assert.ok(bytes.length < 1024)
      assert.equal(bytes.readUInt16BE(0), 0xffd8)
      const sof = bytes.indexOf(Buffer.from([0xff, 0xc0]))
      assert.ok(sof >= 0); assert.equal(bytes.readUInt16BE(sof + 5), 1); assert.equal(bytes.readUInt16BE(sof + 7), 1)
      const request = new r.AiProviderRequest(c.baseUrl + '/chat/completions', 'fake visual body')
      requests.push(request); return request
    },
    extractAssistantContent(raw) {
      extractions++; assert.equal(raw, '{"choices":[{"message":{"content":"OK"}}]}')
      return 'OK'
    },
  }
  const transport = { async postJson(endpoint, key, body, id) {
    calls++; assert.equal(endpoint, 'https://vision.invalid/v1/chat/completions')
    assert.equal(key, credential); assert.equal(body, 'fake visual body'); keys.push(id)
    return '{"choices":[{"message":{"content":"OK"}}]}'
  }, cancel() {} }
  const service = new r.AiConnectionTestService(adapter, transport)
  await service.testWithCredential(config, credential)
  await service.testWithCredential(config, credential)
  assert.equal(calls, 2); assert.equal(extractions, 2); assert.equal(new Set(keys).size, 2)
  assert.ok(requests.every(request => request.body === ''))
})

test('connection response validation releases exactly once after extraction and accepts content without questions', async () => {
  const r = connectionRuntime()
  const config = new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'fake', 'https://vision.invalid')
  for (const scenario of ['success', 'malformed', 'missing', 'empty', 'extraction-error', 'stable-error', 'transport-error']) {
    const events = []
    let releaseCount = 0, extractionCount = 0
    const request = new r.AiProviderRequest('https://vision.invalid/chat/completions', 'fake body')
    const originalRelease = request.release.bind(request)
    request.release = () => { releaseCount++; events.push('release'); originalRelease() }
    const response = scenario === 'malformed' ? 'unsafe malformed provider body' :
      scenario === 'missing' ? '{"choices":[{"message":{}}]}' :
        JSON.stringify({ choices: [{ message: { content: scenario === 'empty' ? '  ' : 'OK without any questions' } }] })
    const stableError = new r.AiImportError(r.AiImportErrorCode.INVALID_CONTENT_TYPE)
    const adapter = {
      buildRequest() { events.push('build'); return request },
      extractAssistantContent(raw) {
        extractionCount++; events.push('extract'); assert.equal(raw, response)
        assert.equal(request.body, 'fake body')
        if (scenario === 'extraction-error') throw Error('unsafe extraction details')
        if (scenario === 'stable-error') throw stableError
        let envelope
        try { envelope = JSON.parse(raw) } catch { throw new r.AiImportError(r.AiImportErrorCode.INVALID_JSON) }
        return envelope.choices[0].message.content || ''
      },
    }
    const transport = { async postJson() {
      events.push('post')
      if (scenario === 'transport-error') throw new r.AiImportError(r.AiImportErrorCode.AUTH_FAILED)
      return response
    }, cancel() {} }
    const service = new r.AiConnectionTestService(adapter, transport)
    const pending = service.testWithCredential(config, new Uint8Array([1]))
    if (scenario === 'success') await pending
    else await assert.rejects(pending, error => {
      assert.ok(error instanceof r.AiImportError)
      if (scenario === 'stable-error') assert.equal(error, stableError)
      else assert.equal(error.code, scenario === 'transport-error' ? r.AiImportErrorCode.AUTH_FAILED : r.AiImportErrorCode.INVALID_JSON)
      assert.ok(!error.message.includes('unsafe')); return true
    })
    events.push('settled')
    assert.equal(releaseCount, 1); assert.equal(request.body, '')
    assert.equal(extractionCount, scenario === 'transport-error' ? 0 : 1)
    assert.deepEqual(events, scenario === 'transport-error' ? ['build', 'post', 'release', 'settled'] :
      ['build', 'post', 'extract', 'release', 'settled'])
  }
})

test('connection failure preserves stable codes, releases body, and never retries', async () => {
  const r = connectionRuntime()
  const config = new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'fake', 'https://vision.invalid')
  for (const failure of [new r.AiImportError(r.AiImportErrorCode.AUTH_FAILED), new Error('unsafe provider text')]) {
    let calls = 0
    const request = new r.AiProviderRequest('https://vision.invalid/chat/completions', 'fake body')
    const adapter = { buildRequest: () => request, extractAssistantContent: () => '' }
    const transport = { async postJson() { calls++; throw failure }, cancel() {} }
    const service = new r.AiConnectionTestService(adapter, transport)
    await assert.rejects(service.testWithCredential(config, new Uint8Array([1])), err => {
      assert.ok(err instanceof r.AiImportError)
      assert.equal(err.code, failure instanceof r.AiImportError ? failure.code : r.AiImportErrorCode.NETWORK_UNAVAILABLE)
      assert.ok(!err.message.includes('unsafe')); return true
    })
    assert.equal(calls, 1); assert.equal(request.body, '')
  }
})

test('connection invalid config and missing saved credential do not reach adapter or transport', async () => {
  const r = connectionRuntime()
  const service = new r.AiConnectionTestService({ buildRequest() { assert.fail('no request') } },
    { postJson() { assert.fail('no transport') }, cancel() {} })
  await assert.rejects(service.testWithCredential(new r.AiProviderConfig(r.AiProviderId.CUSTOM, '', 'https://vision.invalid'), new Uint8Array([1])),
    err => err.code === r.AiImportErrorCode.MISSING_MODEL)
  await assert.rejects(service.testWithCredential(new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'fake', 'https://vision.invalid'), new Uint8Array()),
    err => err.code === r.AiImportErrorCode.MISSING_API_KEY)
})

test('connection test accepts a typed key temporarily and zeroes its encoded bytes', async () => {
  const r = connectionRuntime()
  let captured = null
  const service = new r.AiConnectionTestService({
    buildRequest: () => new r.AiProviderRequest('https://vision.invalid/chat/completions', 'fake body'),
    extractAssistantContent: () => 'OK',
  }, {
    async postJson(endpoint, credential) {
      captured = credential
      assert.equal(Buffer.from(credential).toString('utf8'), 'typed fake key')
      return '{}'
    },
    cancel() {},
  })

  await service.testWithApiKey(
    new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'vision-model', 'https://vision.invalid'),
    ' typed fake key ')

  assert.ok(captured !== null)
  assert.ok(Array.from(captured).every(value => value === 0))
})

test('connection service keeps the entire transport await inside saved credential scope', async () => {
  let active = false, credential = new Uint8Array([1]), release
  const barrier = new Promise(resolve => { release = resolve })
  const r = connectionRuntime({ async withCredential(context, action) {
    assert.equal(context, 'fake context'); active = true
    try { return await action(credential) } finally { active = false; credential.fill(0) }
  } })
  let entered
  const enteredPromise = new Promise(resolve => { entered = resolve })
  const service = new r.AiConnectionTestService({ buildRequest: () => new r.AiProviderRequest('https://vision.invalid', 'fake'),
    extractAssistantContent() { assert.ok(active); return 'OK' } },
    { async postJson(endpoint, key) { assert.equal(key, credential); assert.ok(active); entered(); await barrier; assert.ok(active); return '{}' }, cancel() {} })
  const pending = service.test('fake context', new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'fake', 'https://vision.invalid'))
  await enteredPromise; assert.ok(active); release(); await pending
  assert.equal(active, false); assert.equal(credential[0], 0)
})

function settingsRuntime(stores = {}) {
  const source = read('entry/src/main/ets/pages/AiRecognitionSettingsPage.ets')
  const start = source.indexOf('struct AiRecognitionSettingsPage')
  const page = (source.slice(start, source.indexOf('  @Builder')) + '}')
    .replace('struct AiRecognitionSettingsPage', 'class AiRecognitionSettingsPage')
    .replace(/@State\s+/g, '').replace(/@StorageProp\([^)]*\)\s+/g, '')
  const models = read('entry/src/main/ets/models/ai/AiProviderConfig.ets')
    .replace(/import[^\n]+\n/g, '').replace(/export /g, '')
  // Task 6：设置页现在会查平台目录并读取回传单例，两者都是无 import 的纯模块，直接装进同一个 vm 作用域。
  const catalog = read('entry/src/main/ets/models/ai/AiPlatformCatalog.ets').replace(/export /g, '')
  const selection = read('entry/src/main/ets/utils/AiPlatformSelectionState.ets').replace(/export /g, '')
  return vm.runInNewContext(stripTypeScriptTypes(models + catalog + selection + page, { mode: 'transform' }) +
    '\n({ AiRecognitionSettingsPage, AiImportError, AiImportErrorCode, AiImportErrorMessages, AiProviderId, AiPlatformAccess, AiPlatformCatalog, AiPlatformSelectionState })', {
    url: { URL: { parseURL: text => new URL(text) } }, getContext: () => 'fake context',
    AiCredentialStore: stores.credentials || {}, AiProviderConfigStore: {
      async beginCredentialUpdate() {}, async completeCredentialUpdate() {}, async isCredentialUpdatePending() { return false },
      async requireUsable(context, config) { return config }, async runUpdateExclusive(action) { return action() },
      sameConfig: (left, right) => left !== null && left.providerId === right.providerId && left.model === right.model && left.baseUrl === right.baseUrl,
      sameCredentialScope: (left, right) => left !== null && left.providerId === right.providerId && left.baseUrl === right.baseUrl,
      ...(stores.config || {}),
    },
    AiConnectionTestService: stores.connection || class { constructor() { throw Error('unexpected connection') } },
    AiModelCatalogService: stores.modelCatalog || class { constructor() { throw Error('unexpected model catalog request') } },
    router: stores.router || { back() { assert.fail('unexpected navigation') } },
  })
}

test('settings load never fetches a key and save/clear erase typed key on success and failure', async () => {
  for (const fail of [false, true]) {
    let keySaves = 0, configSaves = 0, clears = 0
    const r = settingsRuntime({
      config: { async load() { if (fail) throw Error('unsafe HUKS details'); return null },
        async save(context, config) { configSaves++; assert.equal(config.model, 'fake'); if (fail) throw Error('unsafe HUKS details'); return config } },
      credentials: { async hasCredential() { return true }, async save(context, key) { keySaves++; assert.equal(key, 'typed fake key') },
        async clear() { clears++; if (fail) throw Error('unsafe HUKS details') },
        withCredential() { assert.fail('page must not decrypt') } },
    })
    const page = new r.AiRecognitionSettingsPage()
    for (const operation of ['loadSettings', 'saveSettings', 'clearApiKey']) {
      page.model = ' fake '; page.baseUrl = 'https://vision.invalid/v1'
      page.apiKey = 'typed fake key'; page.showKey = true
      await page[operation]()
      assert.equal(page.apiKey, ''); assert.equal(page.showKey, false); assert.equal(page.pending, false)
      assert.ok(!page.statusMessage.includes('unsafe'))
    }
    assert.equal(configSaves, 1); assert.equal(keySaves, fail ? 0 : 1); assert.equal(clears, 1)
  }
})

test('settings typed-key model discovery keeps the current model and persistence untouched until save', async () => {
  let modelCalls = 0, credentialSaves = 0, configSaves = 0
  const r = settingsRuntime({
    modelCatalog: class {
      async fetchWithApiKey(baseUrl, apiKey) {
        modelCalls++
        assert.equal(baseUrl, 'https://vision.invalid/v1')
        assert.equal(apiKey, 'typed fake key')
        return ['vision-a', 'vision-b']
      }
    },
    credentials: {
      async save() { credentialSaves++ },
      withCredential() { assert.fail('model discovery must not decrypt the saved key') }
    },
    config: { async save() { configSaves++ } }
  })
  const page = new r.AiRecognitionSettingsPage()
  page.baseUrl = 'https://vision.invalid/v1'
  page.apiKey = 'typed fake key'
  page.model = 'stale-model'

  await page.fetchCloudModels()

  assert.equal(modelCalls, 1)
  assert.equal(credentialSaves, 0)
  assert.equal(configSaves, 0)
  assert.deepEqual(Array.from(page.availableModels), ['vision-a', 'vision-b'])
  assert.equal(page.model, 'stale-model', 'a model absent from the cloud result remains visible until the user selects another')
  assert.equal(page.apiKey, 'typed fake key', 'the typed key remains available for the explicit save action')
  assert.equal(page.statusMessage, '已获取 2 个模型；当前模型不在列表，请重新选择后保存')
  assert.equal(page.pending, false)
})

test('settings reloads models with the saved key while keeping the persisted model visible', async () => {
  let savedCatalogCalls = 0
  const r = settingsRuntime({
    config: {
      async load() {
        return { providerId: 'custom', model: 'saved-model', baseUrl: 'https://vision.invalid/v1' }
      },
    },
    credentials: {
      async hasCredential() { return true },
      withCredential() { assert.fail('the page must not decrypt the saved key') },
    },
    modelCatalog: class {
      async fetchWithSavedCredential(context, baseUrl) {
        savedCatalogCalls++
        assert.equal(context, 'fake context')
        assert.equal(baseUrl, 'https://vision.invalid/v1')
        return ['saved-model', 'vision-b']
      }
      async fetchWithApiKey() { assert.fail('reload must not require a typed key') }
    },
  })
  const page = new r.AiRecognitionSettingsPage()

  await page.loadSettings()

  assert.equal(savedCatalogCalls, 1)
  assert.equal(page.configured, true)
  assert.equal(page.replacingCredential, false)
  assert.equal(page.model, 'saved-model')
  assert.deepEqual(Array.from(page.availableModels), ['saved-model', 'vision-b'])
  assert.equal(page.apiKey, '')
})

test('settings preserves the saved model when saved-key discovery is empty or fails safely', async () => {
  for (const scenario of ['empty', 'failure']) {
    const r = settingsRuntime({
      config: {
        async load() {
          return { providerId: 'custom', model: 'saved-model', baseUrl: 'https://vision.invalid/v1' }
        },
      },
      credentials: { async hasCredential() { return true } },
      modelCatalog: class {
        async fetchWithSavedCredential() {
          if (scenario === 'failure') throw Error('unsafe provider detail')
          return []
        }
      },
    })
    const page = new r.AiRecognitionSettingsPage()

    await page.loadSettings()

    assert.equal(page.model, 'saved-model')
    assert.equal(page.availableModels.length, 0)
    assert.equal(page.failed, true)
    assert.ok(!page.statusMessage.includes('unsafe'))
  }
})

test('settings saves a model-only change with the saved key but rejects changed credential scope', async () => {
  for (const field of ['model', 'providerId', 'baseUrl']) {
    let saves = 0
    const r = settingsRuntime({
      config: {
        async load() {
          return { providerId: 'custom', model: 'saved-model', baseUrl: 'https://vision.invalid/v1' }
        },
        async save(context, config) { saves++; return config },
      },
      credentials: { async hasCredential() { return true } },
      modelCatalog: class { async fetchWithSavedCredential() { return ['saved-model', 'new-model'] } },
    })
    const page = new r.AiRecognitionSettingsPage()
    await page.loadSettings()
    if (field === 'model') page.model = 'new-model'
    if (field === 'providerId') page.providerId = r.AiProviderId.OPENAI
    if (field === 'baseUrl') page.baseUrl = 'https://changed.invalid/v1'

    await page.saveSettings()

    assert.equal(saves, field === 'model' ? 1 : 0)
    if (field === 'model') assert.equal(page.statusMessage, '设置已保存')
    else assert.match(page.statusMessage, /重新输入 API Key/)
  }
})

test('settings tests a typed key before save and blocks mutations/back while the request runs', async () => {
  let typedCalls = 0, savedCalls = 0, release, entered
  const barrier = new Promise(resolve => { release = resolve })
  const enteredPromise = new Promise(resolve => { entered = resolve })
  const r = settingsRuntime({
    config: { async requireUsable(context, config) {
      assert.equal(config.model, 'saved-model'); assert.equal(config.baseUrl, 'https://saved-config.invalid/v1')
      return config
    } },
    credentials: { async hasCredential() { return true } },
    connection: class {
      async testWithApiKey(config, apiKey) {
        typedCalls++
        assert.equal(config.model, 'saved-model'); assert.equal(config.baseUrl, 'https://saved-config.invalid/v1')
        assert.equal(apiKey, 'new fake key')
        entered(); await barrier
      }
      async test(context, config) {
        savedCalls++
        assert.equal(config.model, 'saved-model'); assert.equal(config.baseUrl, 'https://saved-config.invalid/v1')
      }
    },
  })
  const page = new r.AiRecognitionSettingsPage()
  page.model = ' saved-model '; page.baseUrl = 'https://saved-config.invalid/v1/'
  page.apiKey = 'new fake key'
  const pending = page.testConnection()
  await enteredPromise
  assert.equal(page.pending, true); assert.equal(typedCalls, 1); assert.equal(savedCalls, 0)
  await page.saveSettings(); await page.clearApiKey(); await page.testConnection(); await page.loadSettings()
  assert.equal(page.onBackPress(), true); page.leavePage()
  assert.equal(typedCalls, 1); assert.equal(savedCalls, 0)
  release(); await pending
  assert.equal(page.pending, false); assert.equal(page.apiKey, 'new fake key')
  assert.equal(page.statusMessage, '连接成功，请保存设置')
  page.apiKey = ''
  await page.testConnection()
  assert.equal(savedCalls, 1)
  assert.equal(page.statusMessage, '连接成功')
})

test('settings maps missing credential, invalid config, invalid responses, and unsafe connection failures locally', async () => {
  for (const scenario of ['missing', 'invalid', 'invalid-response', 'failure']) {
    let calls = 0
    const r = settingsRuntime({ credentials: { async hasCredential() { return scenario !== 'missing' } },
      connection: class { async test() {
        calls++
        if (scenario === 'invalid-response') throw new r.AiImportError(r.AiImportErrorCode.INVALID_JSON)
        throw Error('unsafe provider secret')
      } } })
    const page = new r.AiRecognitionSettingsPage()
    page.model = scenario === 'invalid' ? '' : 'fake'; page.baseUrl = 'https://vision.invalid'
    await page.testConnection()
    assert.equal(calls, scenario === 'failure' || scenario === 'invalid-response' ? 1 : 0)
    assert.equal(page.pending, false); assert.equal(page.failed, true)
    assert.ok(!page.statusMessage.includes('unsafe'))
    const code = scenario === 'missing' ? r.AiImportErrorCode.MISSING_API_KEY : scenario === 'invalid' ?
      r.AiImportErrorCode.MISSING_MODEL : scenario === 'invalid-response' ? r.AiImportErrorCode.INVALID_JSON :
        r.AiImportErrorCode.PROVIDER_UNAVAILABLE
    assert.equal(page.statusMessage, r.AiImportErrorMessages.forCode(code))
  }
})

// Task 6 平台行行为合同：目录只提供平台地址，模型必须等待鉴权后的云端目录；gateway 不得伪造地址。
test('settings platform row applies addresses without injecting static model recommendations', () => {
  const r = settingsRuntime({ credentials: { async hasCredential() { return true } } })
  const page = new r.AiRecognitionSettingsPage()

  page.model = 'stale-model'
  page.applyPlatform('deepseek')
  const deepseek = r.AiPlatformCatalog.find('deepseek')
  assert.notEqual(deepseek, null)
  assert.equal(deepseek.access, r.AiPlatformAccess.DIRECT)
  assert.equal(page.providerId, 'deepseek')
  assert.equal(page.platformLabel, deepseek.nameZh)
  assert.equal(page.baseUrl, deepseek.baseUrl)
  assert.equal(page.model, '', 'switching platform must drop the previous model')
  assert.equal(page.urlEditable, false, 'direct platforms ship a ready address')
  assert.equal(page.availableModels.length, 0,
    'switching platform must wait for an authenticated cloud model list')
  assert.equal(page.replacingCredential, true, 'switching platform must require a replacement key')

  // local_http：地址自动填且保持可编辑，风险说明来自目录 note。
  const ollama = r.AiPlatformCatalog.find('ollama')
  assert.equal(ollama.access, r.AiPlatformAccess.LOCAL_HTTP)
  page.applyPlatform('ollama')
  assert.equal(page.providerId, 'ollama')
  assert.equal(page.baseUrl, ollama.baseUrl)
  assert.equal(page.urlEditable, true)
  assert.ok(page.platformNote.length > 0)

  // gateway：目录地址为空，应用到表单后必须留空并可编辑，绝不写入伪造地址。
  const gateway = r.AiPlatformCatalog.all()
    .find(item => item.access === r.AiPlatformAccess.GATEWAY)
  assert.ok(gateway, 'catalog must ship at least one gateway platform')
  assert.equal(gateway.baseUrl, '')
  page.applyPlatform(gateway.id)
  assert.equal(page.baseUrl, '', 'gateway platforms must not fabricate an address')
  assert.equal(page.urlEditable, true, 'gateway address must stay editable')
  assert.equal(page.providerId, r.AiProviderId.CUSTOM)
  assert.notEqual(page.providerId, '', 'an empty providerId would desync the store')
  assert.equal(page.statusMessage, gateway.note)
  assert.equal(page.failed, true)

  // M1：重选「同一平台」必须是 no-op —— 不能把用户手填的地址/模型静默清空（gateway 尤其需要手填最长地址）。
  page.model = 'kept-model'
  page.baseUrl = 'https://kept.invalid/v1'
  page.applyPlatform(gateway.id)
  assert.equal(page.model, 'kept-model', 're-selecting the same platform must keep the model')
  assert.equal(page.baseUrl, 'https://kept.invalid/v1',
    're-selecting the same platform must keep the typed address')

  // I2：明文风险必须按「实际地址」判定（private 已被类型剥离，可直接行为断言），
  // 而不是按目录平台 access —— 否则 DIRECT 平台手填 http 地址会漏报、LOCAL_HTTP 的信息性 note 会误报。
  page.baseUrl = ' HTTP://LOCALHOST:11434/v1 '
  assert.equal(page.isCleartextAddress(), true, 'trimmed upper-case scheme must be flagged')
  page.baseUrl = 'https://secure.invalid/v1'
  assert.equal(page.isCleartextAddress(), false)
  page.baseUrl = ''
  assert.equal(page.isCleartextAddress(), false, 'gateway default empty address must not be flagged')

  // 未知/已移除 id：只允许「自定义」兜底，绝不把持久化字符串回显到 UI，也不改写已保存表单。
  page.providerId = 'totally-unknown-id'
  page.baseUrl = 'https://unknown.invalid/v1'
  page.syncPlatformFromConfig()
  assert.equal(page.platformLabel, '自定义')
  assert.notEqual(page.platformLabel, 'totally-unknown-id')
  assert.equal(page.platformNote, '')
  assert.equal(page.availableModels.length, 0)
  assert.equal(page.urlEditable, true)
  assert.equal(page.baseUrl, 'https://unknown.invalid/v1', 'display sync must not rewrite the saved form')

  // syncPlatformFromConfig（load/save 之后的展示路径）不得重新注入静态推荐模型。
  page.providerId = 'deepseek'
  page.syncPlatformFromConfig()
  assert.equal(page.platformLabel, deepseek.nameZh)
  assert.equal(page.availableModels.length, 0)
})

// Task 6 回传合同：onPageShow 必须先 peek 再守卫再 take；pending 与空回传都不得消费选择。
test('settings onPageShow consumes a picker selection once only after the guard', () => {
  const r = settingsRuntime({})
  const page = new r.AiRecognitionSettingsPage()
  const state = r.AiPlatformSelectionState.shared()
  assert.equal(state.peek(), '')

  page.onPageShow()
  assert.equal(state.peek(), '')

  state.select('ollama')
  page.pending = true
  page.onPageShow()
  assert.equal(state.peek(), 'ollama', 'a busy page must not swallow the selection')
  assert.notEqual(page.providerId, 'ollama')
  page.pending = false

  page.onPageShow()
  assert.equal(state.peek(), '', 'take() must consume the selection exactly once')
  assert.equal(page.providerId, 'ollama')
  assert.equal(page.platformLabel, r.AiPlatformCatalog.find('ollama').nameZh)

  page.providerId = 'openai'
  page.onPageShow()
  assert.equal(page.providerId, 'openai', 'a consumed selection must not be applied twice')
})

const projectRoot = path.resolve(__dirname, '../../..')
const sourcePath = path.join(
  projectRoot,
  'entry/src/main/ets/services/ai/AiProviderConfigStore.ets',
)

function read(relativePath) {
  return fs.readFileSync(path.join(projectRoot, relativePath), 'utf8')
}

function extractMethodSource(source, signature) {
  const start = source.indexOf(signature)
  assert.ok(start >= 0, 'missing ' + signature)
  const opening = source.indexOf('{', start)
  let depth = 0
  for (let index = opening; index < source.length; index++) {
    if (source[index] === '{') depth++
    if (source[index] === '}') {
      depth--
      if (depth === 0) return source.slice(start, index + 1)
    }
  }
  assert.fail('unterminated ' + signature)
}

function stripEtsModule(relativePath) {
  return read(relativePath)
    .replace(/^import\s[\s\S]*?\sfrom\s+['"][^'"]+['"]\s*$/gm, '')
    .replace(/^export\s+/gm, '')
}

function aiQuestionParserRuntime() {
  const source = [
    'entry/src/main/ets/constants/AiImportLimits.ets',
    'entry/src/main/ets/models/ai/AiProviderConfig.ets',
    'entry/src/main/ets/models/ai/AiImportModels.ets',
    'entry/src/main/ets/services/ai/AiQuestionResponseParser.ets'
  ].map(stripEtsModule).join('\n')
  return vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) +
    '\n({ AiQuestionResponseParser })')
}

function providerValidatorRuntime() {
  // 保真度：这里用 Node WHATWG URL 顶替 ArkTS url.URL.parseURL。对 http://127.1/、
  // http://2130706433/、http://0x7f.0.0.1/ 这类非规范写法，是否接受取决于平台的 IPv4 规范化：
  // Node 会把它们规范成 127.0.0.1 从而放行，若 ArkTS 保留字面主机名则会被严格解析（段数/位数/≤255）
  // 拒绝，属于 fail-closed 方向，因此这些写法不进任何断言列表。
  const source = stripEtsModule('entry/src/main/ets/models/ai/AiProviderConfig.ets')
  return vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) +
    '\n({ AiProviderConfig, AiProviderConfigValidator, AiProviderId, AiImportError, AiImportErrorCode })', {
    url: { URL: { parseURL: value => new URL(value) } }
  })
}

function bboxCoordinatorRuntime(drafts) {
  const pageEvidencePath = '/cache/ai_import_page_bbox~attempt~1~1.jpg'
  const evidence = new Set()
  const calls = { cropEvidence: 0, cleanupEvidence: 0 }
  let uuid = 0
  let storedSession = null

  class RuntimeAiImportError extends Error {
    constructor(code) {
      super(code)
      this.code = code
    }
  }
  class RuntimePdfReviewFailure {
    constructor(pageNumber, code, message, evidencePath) {
      Object.assign(this, { pageNumber, code, message, evidencePath })
    }
  }
  class RuntimePdfReviewImage {
    constructor(id, localPath, sha256, width, mimeType, sortOrder) {
      Object.assign(this, { id, localPath, sha256, width, mimeType, sortOrder })
    }
  }
  class RuntimePdfReviewOption {
    constructor(key, value) { Object.assign(this, { key, value }) }
  }
  class RuntimePdfReviewQuestion {
    constructor(draftQuestionId, questionUuid, label, type, question, options, answer, analysis,
      pageStart, pageEnd, confidence, reviewRequired, images) {
      Object.assign(this, { draftQuestionId, questionUuid, label, type, question, options,
        answer, analysis, pageStart, pageEnd, confidence, reviewRequired, images })
    }
  }
  class RuntimePdfReviewSession {
    constructor(sessionId, source, bankUuid, bankName, subject, pdfPath, accountId,
      questions, failures, saveStage) {
      Object.assign(this, { sessionId, source, bankUuid, bankName, subject, pdfPath, accountId,
        questions, failures, saveStage })
    }
  }

  const renderSession = {
    pageCount() { return 1 },
    async encodePage() {
      evidence.add(pageEvidencePath)
      return {
        pageNumber: 1, width: 1000, height: 1400, jpegBase64: 'fake-page',
        evidencePath: pageEvidencePath,
        releaseTransientText() { this.jpegBase64 = '' }
      }
    },
    async cropEvidence() {
      calls.cropEvidence++
      return '/cache/forbidden-crop.jpg'
    },
    close() {}
  }
  const renderer = {
    open() { return renderSession },
    async cleanupAttempt() {},
    async cleanupAttemptCrops() {},
    async cleanupEvidence(_context, _sessionId, path) {
      calls.cleanupEvidence++
      evidence.delete(path)
    },
    async cleanupSession() {}
  }
  const credentials = {
    async run(_context, action) {
      const bytes = new Uint8Array([1])
      try { return await action.execute(bytes) } finally { bytes.fill(0) }
    }
  }
  const adapter = {
    buildRequest() {
      return {
        endpoint: 'https://coordinator.invalid/v1/chat/completions',
        body: '{"fixture":true}', release() { this.body = '' }
      }
    },
    extractAssistantContent(response) { return response }
  }
  const transport = { async postJson() { return 'fixture response' }, cancel() {} }
  const parser = { parse() { return drafts } }
  const pdfCleanup = { async remove() {} }
  const reviewStore = {
    put(session) { storedSession = session },
    get(sessionId) {
      return storedSession !== null && storedSession.sessionId === sessionId ? storedSession : null
    },
    remove() { storedSession = null },
    copyOf(session) { return session }
  }
  const codes = {
    CANCELLED: 'CANCELLED', CONFIG_NOT_SAVED: 'CONFIG_NOT_SAVED',
    INVALID_JSON: 'INVALID_JSON', NO_QUESTIONS: 'NO_QUESTIONS'
  }
  const source = stripEtsModule('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const runtime = vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) +
    '\n({ PdfAiImportCoordinator, PdfAiImportRequest })', {
    util: { generateRandomUUID: () => '00000000-0000-4000-8000-' + String(++uuid).padStart(12, '0') },
    AiImportError: RuntimeAiImportError,
    AiImportErrorCode: codes,
    AiProviderConfigValidator: { normalize: value => value },
    PdfReviewFailure: RuntimePdfReviewFailure,
    PdfReviewImage: RuntimePdfReviewImage,
    PdfReviewOption: RuntimePdfReviewOption,
    PdfReviewQuestion: RuntimePdfReviewQuestion,
    PdfReviewSession: RuntimePdfReviewSession,
    PdfReviewSaveStage: { DRAFT: 'draft' },
    PdfReviewSource: { AI: 'ai' },
    PdfReviewSessionStore: reviewStore,
    MathQuestionPromptBuilder: { build: () => 'fixture prompt' }
  })
  const coordinator = new runtime.PdfAiImportCoordinator(
    renderer, credentials, adapter, transport, parser, pdfCleanup)
  const request = new runtime.PdfAiImportRequest('bbox-session', 'account-fixture',
    '/cache/staged_pdf_1.pdf', { bankName: '题库', subject: '数学', startPage: 1, endPage: 1 },
    { providerId: 'openai_compatible', model: 'fixture', baseUrl: 'https://coordinator.invalid/v1' })
  return { coordinator, request, calls, evidence, pageEvidencePath, open: () => renderSession }
}

function urlLiterals(source) {
  return [...source.matchAll(/https?:\/\/[^\s'"<>]+/gi)].map(match => match[0])
}

// 放行的是环回/私网 IP 字面量：私网在 LAN 内可以路由，所以这里不是「不可路由」判断。
function isLoopbackOrPrivateIpLiteral(hostname) {
  const match = hostname.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/)
  if (match === null) return false
  const octets = match.slice(1).map(value => Number(value))
  if (octets.some(value => value > 255)) return false
  if (octets[0] === 127 || octets[0] === 10) return true
  if (octets[0] === 192 && octets[1] === 168) return true
  return octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31
}

function isReservedTestHostname(hostname) {
  // Node WHATWG URL 对 IPv6 主机名保留方括号（本机 IPv6 字面量会给出 '[::1]'），只剥首尾括号。
  const value = hostname.toLowerCase().replace(/^\[|\]$/g, '')
  return value === 'localhost' || value === '::1' || isLoopbackOrPrivateIpLiteral(value) ||
    value.endsWith('.invalid') || value.endsWith('.test') || value.endsWith('.example') ||
    value === 'example.com' || value.endsWith('.example.com') ||
    value === 'example.net' || value.endsWith('.example.net') ||
    value === 'example.org' || value.endsWith('.example.org')
}

function assertTestOnlyUrlLiterals(source) {
  const literals = urlLiterals(source)
  assert.ok(literals.length > 0, 'expected URL fixtures')
  for (const literal of literals) {
    const parsed = new URL(literal)
    assert.equal(isReservedTestHostname(parsed.hostname), true,
      'URL fixture must use a reserved test hostname: ' + literal)
  }
}

function assertNoProductionNetworkUse(source) {
  assert.doesNotMatch(source,
    /import\s*{[^}]*\bAiVisionTransport\b[^}]*}\s*from|\bnew\s+AiVisionTransport\s*\(|\bAiVisionTransport\s*\./)
  assert.doesNotMatch(source,
    /@kit\.NetworkKit|@ohos\.net\.http|@ohos\.request|\bhttp\.createHttp\b|\bfetch\s*\(|\bXMLHttpRequest\b|\brequestInStream\s*\(|\baxios\b/i)
}

function deferredValue() {
  let resolve
  let reject
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

async function waitForEvent(events, value) {
  for (let index = 0; index < 30 && !events.includes(value); index++) await Promise.resolve()
  assert.ok(events.includes(value), 'missing event ' + value + ': ' + events.join(','))
}

function progressRuntime(options = {}) {
  const clean = source => source.replace(/import[\s\S]*?from\s*'[^']+'\s*;?/g, '').replace(/export /g, '')
  const pageText = read('entry/src/main/ets/pages/PdfAiImportProgressPage.ets')
  const pageStart = pageText.indexOf('struct PdfAiImportProgressPage')
  const firstBuilder = pageText.indexOf('  @Builder', pageStart)
  const pageEnd = firstBuilder >= 0 ? firstBuilder : pageText.indexOf('  build()', pageStart)
  const page = (pageText.slice(pageStart, pageEnd) + '}')
    .replace('struct PdfAiImportProgressPage', 'class PdfAiImportProgressPage')
    .replace(/@State\s+/g, '').replace(/@StorageProp\([^)]*\)\s+/g, '')
  const model = clean(read('entry/src/main/ets/models/ai/AiProviderConfig.ets'))
  const events = []
  const defaultConfig = new (class {
    constructor() { this.providerId = 'openai_compatible'; this.model = 'fake'; this.baseUrl = 'https://fake.invalid' }
  })()
  const selection = options.selection === undefined ? { uri: 'selected.pdf' } : options.selection
  const settings = options.settings === undefined ?
    { bankName: 'bank', subject: '数学', startPage: 1, endPage: 1 } : options.settings
  const state = {
    selection, settings, reviewSessionId: '', resets: 0,
    getSelection() { return this.selection }, getSettings() { return this.settings },
    setReviewSessionId(value) { events.push('publish:' + value); this.reviewSessionId = value },
    getReviewSessionId() { return this.reviewSessionId },
    reset() {
      events.push('reset'); this.resets++; this.selection = null; this.settings = null
      this.reviewSessionId = ''
    },
  }
  const configResponses = (options.configResponses || [defaultConfig]).slice()
  const accountResponses = (options.accountResponses || [
    { signedIn: true, userId: 'account-a' }, { signedIn: true, userId: 'account-a' }
  ]).slice()
  const credentialResponses = (options.credentialResponses || [true]).slice()
  const take = async (responses, fallback, event) => {
    events.push(event)
    const value = responses.length > 0 ? responses.shift() : fallback
    if (value instanceof Error) throw value
    return await value
  }
  let runCount = 0
  let cancelCount = 0
  let discardCount = 0
  let discardFailures = options.discardFailures || 0
  let pdfFailures = options.pdfFailures || 0
  class FakeCleanupRequiredError extends Error {
    constructor(code) { super('fixed cleanup signal'); this.code = code }
  }
  const coordinator = {
    async run(context, request, onProgress) {
      runCount++; events.push('run')
      onProgress(1, 1, 1, 1, 'done')
      if (options.runCleanupRequired) throw new FakeCleanupRequiredError('invalid_json')
      if (options.runResult instanceof Error) throw options.runResult
      if (options.runResult !== undefined) await options.runResult
      return { sessionId: request.sessionId }
    },
    cancel() { cancelCount++; events.push('cancel') },
    async discard(context, request) {
      discardCount++; events.push('discard:' + request.sessionId)
      if (discardFailures > 0) { discardFailures--; throw Error('unsafe discard details') }
    },
  }
  const routeFailures = (options.routeFailures || []).slice()
  const routes = []
  const fakeRouter = {
    async replaceUrl(route) {
      events.push('route:' + route.url); routes.push(route.url)
      if (routeFailures.length > 0 && routeFailures.shift()) throw Error('unsafe route details')
    },
    back() { events.push('back') },
  }
  class FakeRequest {
    constructor(sessionId, accountId, pdfPath, requestSettings, config) {
      this.sessionId = sessionId; this.accountId = accountId; this.pdfPath = pdfPath
      this.settings = requestSettings; this.config = config
    }
  }
  const runtime = vm.runInNewContext(stripTypeScriptTypes(model + page, { mode: 'transform' }) +
    '\n({ PdfAiImportProgressPage, AiImportError, AiImportErrorCode })', {
    url: { URL: { parseURL: text => new URL(text) } }, getContext: () => 'context',
    util: { generateRandomUUID: () => '00000000-0000-4000-8000-000000000001' },
    PdfAiImportCoordinator: { createDefault: () => coordinator }, PdfAiImportRequest: FakeRequest,
    AiImportCleanupRequiredError: FakeCleanupRequiredError,
    PdfImportState: { shared: () => state },
    AiProviderConfigStore: {
      loadUsable: () => take(configResponses, defaultConfig, 'config')
    },
    AccountSessionService: {
      state: () => take(accountResponses, { signedIn: true, userId: 'account-a' }, 'account')
    },
    AiCredentialStore: { hasCredential: () => take(credentialResponses, true, 'credential') },
    PdfImportService: { async removeTemporaryPdf(uri) {
      events.push('remove:' + uri)
      if (pdfFailures > 0) { pdfFailures--; throw Error('unsafe pdf details') }
    } },
    WindowSizeClass: { COMPACT: 0, MEDIUM: 1, EXPANDED: 2 },
    ResponsiveLayout: { classify: () => 0 },
    WindowSizeObserver: class { start() {} stop() {} },
    themePalette: () => ({}),
  })
  const pageInstance = new runtime.PdfAiImportProgressPage()
  pageInstance.getUIContext = () => ({ getRouter: () => fakeRouter })
  return {
    ...runtime, page: pageInstance, state, events, routes,
    counts: () => ({ runCount, cancelCount, discardCount }),
    setDiscardFailures: value => { discardFailures = value },
    setPdfFailures: value => { pdfFailures = value },
  }
}

test('preflight cancellation cleans the selected PDF at every await boundary', async () => {
  const cases = [
    { boundary: 'config', config: null },
    { boundary: 'config', config: Error('unsafe config') },
    { boundary: 'account', account: { signedIn: false, userId: '' } },
    { boundary: 'account', account: Error('unsafe account') },
    { boundary: 'credential', credential: false },
    { boundary: 'credential', credential: Error('unsafe credential') },
  ]
  for (const scenario of cases) {
    const gate = deferredValue()
    const options = {}
    if (scenario.boundary === 'config') options.configResponses = [gate.promise]
    if (scenario.boundary === 'account') options.accountResponses = [gate.promise]
    if (scenario.boundary === 'credential') options.credentialResponses = [gate.promise]
    const r = progressRuntime(options)
    const pending = r.page.startImport()
    await waitForEvent(r.events, scenario.boundary)
    r.page.cancelImport()
    if (scenario[scenario.boundary] instanceof Error) gate.reject(scenario[scenario.boundary])
    else gate.resolve(scenario[scenario.boundary])
    await pending
    assert.equal(r.state.resets, 1, scenario.boundary)
    assert.deepEqual(r.routes, ['pages/ImportBankPage'], scenario.boundary)
    assert.equal(r.counts().discardCount, 0, scenario.boundary)
    assert.equal(r.events.filter(value => value === 'remove:selected.pdf').length, 1, scenario.boundary)
    assert.equal(r.page.cleanupPending, false, scenario.boundary)
  }
})

test('preflight cancellation retains identity and exposes retry after direct PDF cleanup failure', async () => {
  const gate = deferredValue()
  const r = progressRuntime({ configResponses: [gate.promise], pdfFailures: 1 })
  const pending = r.page.startImport()
  await waitForEvent(r.events, 'config')
  r.page.cancelImport()
  gate.resolve(null)
  await pending
  assert.equal(r.state.resets, 0)
  assert.equal(r.page.cleanupPending, true)
  assert.equal(r.page.selectedPdfPath, 'selected.pdf')
  assert.deepEqual(r.routes, [])
  await r.page.retryCleanup()
  assert.equal(r.state.resets, 1)
  assert.equal(r.page.cleanupPending, false)
  assert.equal(r.page.selectedPdfPath, '')
  assert.deepEqual(r.routes, ['pages/ImportBankPage'])
})

test('typed non-cancelled run cleanup debt blocks exit and converges through central retry', async () => {
  const r = progressRuntime({ runCleanupRequired: true, discardFailures: 1 })
  await r.page.startImport()
  assert.equal(r.counts().runCount, 1)
  assert.equal(r.counts().discardCount, 1)
  assert.equal(r.page.cleanupPending, true)
  assert.notEqual(r.page.request, null)
  assert.equal(r.page.request.sessionId, '00000000-0000-4000-8000-000000000001')
  assert.equal(r.page.selectedPdfPath, 'selected.pdf')
  assert.equal(r.state.resets, 0)
  assert.deepEqual(r.routes, [])
  assert.equal(r.page.onBackPress(), true)
  r.page.returnToSetup()
  assert.equal(r.events.includes('back'), false)
  await r.page.retryCleanup()
  assert.equal(r.counts().discardCount, 2)
  assert.equal(r.page.cleanupPending, false)
  assert.equal(r.page.request, null)
  assert.equal(r.page.selectedPdfPath, '')
  assert.equal(r.state.resets, 1)
  assert.deepEqual(r.routes, ['pages/ImportBankPage'])
})

test('completed import disables cancellation, rechecks account and retries review navigation without rerun', async () => {
  const postRunAccount = deferredValue()
  const r = progressRuntime({
    accountResponses: [
      { signedIn: true, userId: 'account-a' }, postRunAccount.promise,
      { signedIn: true, userId: 'account-a' }
    ],
    routeFailures: [true, false]
  })
  const pending = r.page.startImport()
  await waitForEvent(r.events, 'publish:00000000-0000-4000-8000-000000000001')
  await waitForEvent(r.events, 'account')
  assert.equal(r.page.running, false)
  assert.equal(r.page.cancellable, false)
  r.page.cancelImport()
  assert.equal(r.counts().cancelCount, 0)
  postRunAccount.resolve({ signedIn: true, userId: 'account-a' })
  await pending
  assert.equal(r.page.reviewNavigationFailed, true)
  assert.equal(r.state.reviewSessionId, '00000000-0000-4000-8000-000000000001')
  assert.notEqual(r.page.request, null)
  assert.equal(r.page.onBackPress(), true)
  assert.equal(r.events.includes('back'), false)
  await r.page.retryReviewNavigation()
  assert.equal(r.counts().runCount, 1)
  assert.deepEqual(r.routes, ['pages/PdfImportReviewPage', 'pages/PdfImportReviewPage'])
})

test('post-run account mismatch discards before clearing state and returning to import', async () => {
  const r = progressRuntime({ accountResponses: [
    { signedIn: true, userId: 'account-a' }, { signedIn: true, userId: 'account-b' }
  ] })
  await r.page.startImport()
  assert.equal(r.counts().runCount, 1)
  assert.equal(r.counts().discardCount, 1)
  assert.equal(r.state.resets, 1)
  assert.deepEqual(r.routes, ['pages/ImportBankPage'])
  const publishIndex = r.events.indexOf('publish:00000000-0000-4000-8000-000000000001')
  const discardIndex = r.events.indexOf('discard:00000000-0000-4000-8000-000000000001')
  const resetIndex = r.events.indexOf('reset')
  assert.ok(publishIndex >= 0 && discardIndex > publishIndex && resetIndex > discardIndex)
})

test('completed-session abandon retains request and review id until discard retry succeeds', async () => {
  const r = progressRuntime({ routeFailures: [true, false], discardFailures: 1 })
  await r.page.startImport()
  assert.equal(r.page.reviewNavigationFailed, true)
  await r.page.abandonCompletedImport()
  assert.equal(r.page.cleanupPending, true)
  assert.notEqual(r.page.request, null)
  assert.notEqual(r.state.reviewSessionId, '')
  assert.equal(r.state.resets, 0)
  assert.deepEqual(r.routes, ['pages/PdfImportReviewPage'])
  await r.page.retryCleanup()
  assert.equal(r.page.cleanupPending, false)
  assert.equal(r.page.request, null)
  assert.equal(r.state.resets, 1)
  assert.deepEqual(r.routes, ['pages/PdfImportReviewPage', 'pages/ImportBankPage'])
})

function barrierRuntime(backing = { durable: new Map(), values: new Map(), failFlush: false }) {
  const clean = source => source.replace(/import[\s\S]*?from\s*'[^']+'\s*;?/g, '').replace(/export /g, '')
  const pageText = read('entry/src/main/ets/pages/AiRecognitionSettingsPage.ets')
  const page = (pageText.slice(pageText.indexOf('struct AiRecognitionSettingsPage'), pageText.indexOf('  @Builder')) + '}')
    .replace('struct AiRecognitionSettingsPage', 'class AiRecognitionSettingsPage')
    .replace(/@State\s+/g, '').replace(/@StorageProp\([^)]*\)\s+/g, '')
  const files = ['models/ai/AiProviderConfig.ets', 'services/ai/AiProviderAdapter.ets',
    'services/ai/AiProviderConfigStore.ets', 'services/ai/AiConnectionTestService.ets',
    'models/ai/AiPlatformCatalog.ets']
  const coordinator = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const credentialAccess = coordinator.slice(coordinator.indexOf('class StoredCredentialAccess'), coordinator.indexOf('class StrictQuestionParser'))
  const source = files.map(file => clean(read('entry/src/main/ets/' + file))).join('\n') + credentialAccess + page
  const events = [], dispatched = []
  let savedKey = 'old fake key', keyFailure = false
  const credentials = {
    async hasCredential() { events.push('has-key'); return savedKey.length > 0 },
    async save(context, key) { events.push('save-key'); if (keyFailure) throw Error('unsafe HUKS details'); savedKey = key },
    async clear() { events.push('clear-key'); if (keyFailure) throw Error('unsafe clear details'); savedKey = '' },
    async withCredential(context, action) { events.push('credential'); return action(new Uint8Array(Buffer.from(savedKey))) },
  }
  const runtime = vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) +
    '\n({ AiProviderConfigStore, AiRecognitionSettingsPage, AiConnectionTestService, AiProviderConfig, AiProviderId, AiImportError, AiImportErrorCode, StoredCredentialAccess })', {
    url: { URL: { parseURL: text => new URL(text) } },
    util: { generateRandomUUID: require('node:crypto').randomUUID }, getContext: () => 'fake context',
    preferences: { async getPreferences() { return {
      async get(key, fallback) { return backing.values.has(key) ? backing.values.get(key) : fallback },
      async put(key, value) { events.push('put:' + key + ':' + String(value)); backing.values.set(key, value) },
      async delete(key) { backing.values.delete(key) },
      async clear() { backing.values.clear() },
      async flush() { backing.durable = new Map(backing.values); if (backing.failFlush) { backing.failFlush = false; throw Error('ambiguous flush') } },
    } } },
    AiCredentialStore: credentials,
    OpenAiCompatibleAdapter: class {
      buildRequest(config) { return { endpoint: config.baseUrl, body: 'fake body', release() { this.body = '' } } }
      extractAssistantContent() { return 'OK' }
    },
    AiVisionTransport: class { async postJson(endpoint, key) { dispatched.push({ endpoint, key: Buffer.from(key).toString() }); return '{}' } },
    AiModelCatalogService: class {
      async fetchWithSavedCredential() { events.push('models'); return ['fake', 'other-model'] }
      async fetchWithApiKey() { return ['fake', 'other-model'] }
    },
    router: { back() {} },
  })
  return { ...runtime, backing, events, dispatched, failKey: value => { keyFailure = value } }
}

test('credential update barrier persists across restart and ambiguous completion failure', async () => {
  const r = barrierRuntime()
  const store = r.AiProviderConfigStore
  assert.equal(typeof store.beginCredentialUpdate, 'function', 'durable credential-update barrier is required')
  await store.save('fake context', new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'fake', 'https://old.invalid'))
  await store.beginCredentialUpdate('fake context')
  assert.equal(await store.isCredentialUpdatePending('fake context'), true)
  const restarted = barrierRuntime({ durable: new Map(r.backing.durable), values: new Map(r.backing.durable), failFlush: false })
  await assert.rejects(restarted.AiProviderConfigStore.loadUsable('fake context'), error => error.code === restarted.AiImportErrorCode.CREDENTIAL_UPDATE_PENDING)
  r.backing.failFlush = true
  await assert.rejects(store.completeCredentialUpdate('fake context'))
  assert.equal(await store.isCredentialUpdatePending('fake context'), true)
  const restartedAgain = barrierRuntime({ durable: new Map(r.backing.durable), values: new Map(r.backing.durable), failFlush: false })
  assert.equal(await restartedAgain.AiProviderConfigStore.isCredentialUpdatePending('fake context'), true)
  await store.completeCredentialUpdate('fake context')
  assert.equal(await store.isCredentialUpdatePending('fake context'), false)
})

test('HUKS failure after config save blocks old-key dispatch until replacement or clear repairs marker', async () => {
  const r = barrierRuntime(), store = r.AiProviderConfigStore
  assert.equal(typeof store.loadUsable, 'function', 'usable config must honor durable barrier')
  await store.save('fake context', new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'fake', 'https://old.invalid'))
  const page = new r.AiRecognitionSettingsPage()
  await page.loadSettings()
  page.baseUrl = 'https://new.invalid'; page.apiKey = 'replacement fake key'; page.showKey = true
  r.failKey(true); r.events.length = 0
  await page.saveSettings()
  assert.equal((await store.load('fake context')).baseUrl, 'https://new.invalid')
  assert.equal(await store.isCredentialUpdatePending('fake context'), true)
  assert.equal(page.apiKey, ''); assert.equal(page.showKey, false)
  const begin = r.events.findIndex(event => event.includes('credential_update_pending:true'))
  const configWrite = r.events.findIndex(event => event.includes('base_url:https://new.invalid'))
  assert.ok(begin >= 0 && begin < configWrite && configWrite < r.events.indexOf('save-key'))
  r.events.length = 0
  await page.testConnection()
  assert.equal(r.events.includes('has-key'), false); assert.equal(r.events.includes('credential'), false)
  assert.equal(r.dispatched.length, 0)
  const service = new r.AiConnectionTestService()
  await assert.rejects(service.test('fake context', page.formConfig()), error => error.code === r.AiImportErrorCode.CREDENTIAL_UPDATE_PENDING)
  assert.equal(r.dispatched.length, 0)
  const reload = new r.AiRecognitionSettingsPage(); await reload.loadSettings()
  assert.match(reload.statusMessage, /密钥更新未完成/); assert.equal(reload.apiKey, '')
  r.failKey(false); page.apiKey = 'replacement fake key'; await page.saveSettings()
  assert.equal(await store.isCredentialUpdatePending('fake context'), false)
  await page.testConnection(); assert.deepEqual(r.dispatched, [{ endpoint: 'https://new.invalid', key: 'replacement fake key' }])
  await store.beginCredentialUpdate('fake context'); await page.clearApiKey()
  assert.equal(await store.isCredentialUpdatePending('fake context'), false)
  assert.equal(page.configured, false)
})

test('provider or address changes and unsaved test forms never reuse an existing key', async () => {
  for (const field of ['providerId', 'baseUrl']) {
    const r = barrierRuntime(), store = r.AiProviderConfigStore
    const saved = new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'fake', 'https://old.invalid')
    await store.save('fake context', saved)
    const page = new r.AiRecognitionSettingsPage(); await page.loadSettings()
    page[field] = field === 'providerId' ? r.AiProviderId.OPENAI : 'https://new.invalid'
    r.events.length = 0
    await page.testConnection()
    assert.equal(r.dispatched.length, 0, 'unsaved form must not send')
    assert.equal(r.events.includes('has-key'), false, 'unsaved form must not access credential status')
    await page.saveSettings()
    const actual = await store.load('fake context')
    assert.equal(actual[field], saved[field], 'config-only changes require replacing key')
    assert.match(page.statusMessage, /重新输入 API Key/)
    assert.equal(r.dispatched.length, 0)
    const service = new r.AiConnectionTestService()
    await assert.rejects(service.test('fake context', page.formConfig()), error => error.code === r.AiImportErrorCode.CONFIG_NOT_SAVED)
    assert.equal(r.dispatched.length, 0)
  }
})

test('model-only changes can reuse the saved credential after the new config is persisted', async () => {
  const r = barrierRuntime(), store = r.AiProviderConfigStore
  const saved = new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'fake', 'https://old.invalid')
  await store.save('fake context', saved)
  const page = new r.AiRecognitionSettingsPage()
  await page.loadSettings()
  page.model = 'other-model'

  r.events.length = 0
  await page.testConnection()
  assert.equal(r.dispatched.length, 0, 'an unsaved model must not reach the provider')
  assert.equal(r.events.includes('has-key'), false)

  await page.saveSettings()
  assert.equal((await store.load('fake context')).model, 'other-model')
  assert.equal(r.events.includes('save-key'), false, 'model-only save must not rewrite HUKS')
  assert.equal(await store.isCredentialUpdatePending('fake context'), false)

  await page.testConnection()
  assert.deepEqual(r.dispatched, [{ endpoint: 'https://old.invalid', key: 'old fake key' }])
})

test('failed marker begin and key clear leave dispatch blocked without updating public configuration', async () => {
  const r = barrierRuntime(), store = r.AiProviderConfigStore
  await store.save('fake context', new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'fake', 'https://old.invalid'))
  const page = new r.AiRecognitionSettingsPage(); await page.loadSettings()
  page.baseUrl = 'https://new.invalid'; page.apiKey = 'replacement'
  r.backing.failFlush = true; r.events.length = 0
  await page.saveSettings()
  assert.equal((await store.load('fake context')).baseUrl, 'https://old.invalid')
  assert.equal(r.events.includes('save-key'), false)
  assert.equal(await store.isCredentialUpdatePending('fake context'), true)
  r.failKey(true); await page.clearApiKey()
  assert.equal(await store.isCredentialUpdatePending('fake context'), true)
  assert.match(page.statusMessage, /密钥更新未完成/)
  const access = new r.StoredCredentialAccess()
  await assert.rejects(access.run('fake context', { execute() { assert.fail('must not dispatch') } }, page.formConfig()),
    error => error.code === r.AiImportErrorCode.CREDENTIAL_UPDATE_PENDING)
  assert.equal(r.events.includes('credential'), false)
})

test('default coordinator checks persisted config and holds update barrier through credential dispatch', async () => {
  const r = barrierRuntime(), store = r.AiProviderConfigStore
  const saved = new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'fake', 'https://old.invalid')
  await store.save('fake context', saved)
  const access = new r.StoredCredentialAccess()
  await assert.rejects(access.run('fake context', { execute() { assert.fail('must not dispatch') } },
    new r.AiProviderConfig(r.AiProviderId.CUSTOM, 'fake', 'https://changed.invalid')),
  error => error.code === r.AiImportErrorCode.CONFIG_NOT_SAVED)
  assert.equal(r.events.includes('credential'), false)
  let entered, release
  const enteredPromise = new Promise(resolve => { entered = resolve })
  const wait = new Promise(resolve => { release = resolve })
  const dispatch = access.run('fake context', { async execute(key) {
    assert.equal(Buffer.from(key).toString(), 'old fake key'); entered(); await wait; return '{}'
  } }, saved)
  await enteredPromise
  let updateBegan = false
  const update = store.beginCredentialUpdate('fake context').then(() => { updateBegan = true })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(updateBegan, false)
  release(); await dispatch; await update
  assert.equal(updateBegan, true)
  await assert.rejects(access.run('fake context', { execute() { assert.fail('must not dispatch') } }, saved),
    error => error.code === r.AiImportErrorCode.CREDENTIAL_UPDATE_PENDING)
})

test('source-neutral review isolates providers and renders editable local evidence', () => {
  const page = read('entry/src/main/ets/pages/PdfImportReviewPage.ets')
  assert.match(page, /PdfReviewAdapter/)
  assert.match(page, /PdfReviewQuestion/)
  assert.match(page, /Image\('file:\/\/' \+ /)
  for (const label of ['重试识别', '手动新增题目', '放弃本页']) assert.ok(page.includes(label))
  assert.doesNotMatch(page, /CloudImportService|CloudImportApi|ConfirmImportResult/)
  assert.match(page, /PdfReviewSavePolicy\.canEdit/)
  assert.match(page, /PdfReviewSavePolicy\.canAbandon/)
  assert.match(page, /AiImportErrorMessages/)
  assert.match(page, /util\.generateRandomUUID\(\)/)
  const cloud = read('entry/src/main/ets/services/review/CloudPdfReviewAdapter.ets')
  const ai = read('entry/src/main/ets/services/review/AiPdfReviewAdapter.ets')
  assert.match(cloud, /implements PdfReviewAdapter/)
  assert.match(cloud, /CloudImportService/)
  assert.match(ai, /implements PdfReviewAdapter/)
  assert.match(ai, /AiImportSaveService\.restore/)
  assert.match(ai, /AiProviderConfigStore\.load/)
  assert.match(ai, /coordinator\.retryPage/)
  assert.match(ai, /coordinator\.cancel\(\)[\s\S]*AiImportSaveService\.abandon/)
  assert.doesNotMatch(ai, /Cloud|\/v1\/imports\/pdf/)
})

test('review retains committed retry state and exposes image retry without draft questions', () => {
  const page = read('entry/src/main/ets/pages/PdfImportReviewPage.ets')
  const retry = page.slice(page.indexOf('private async retryFailure'), page.indexOf('private addManualQuestion'))
  assert.match(retry, /catch \(err\)[\s\S]*if \(!await this\.reconcileReviewState\(\)\) return/)
  const reconciliation = page.slice(page.indexOf('private async reconcileReviewState'),
    page.indexOf('private async retryFailure'))
  assert.match(reconciliation, /this\.adapter\.load\(getContext\(this\)\)/)
  assert.match(reconciliation,
    /authoritativeStatePending = true[\s\S]*applySession\(authoritative\)[\s\S]*authoritativeStatePending = false[\s\S]*return true/)
  assert.match(reconciliation, /return false/)
  assert.doesNotMatch(retry, /err\.message/)
  assert.match(page, /draftQuestions\.length === 0 && this\.failures\.length === 0 && !this\.textSaveStarted\(\)/)
  assert.match(page, /Button\('重试完成保存'\)/)
})

function reviewPageRuntime() {
  const page = read('entry/src/main/ets/pages/PdfImportReviewPage.ets')
  const importsRemoved = page.slice(page.indexOf('struct PdfImportReviewPage'))
  const helperStart = importsRemoved.indexOf('  private showToast')
  const uiBuilderStart = importsRemoved.indexOf('  @Builder', helperStart)
  const source = (importsRemoved.slice(0, importsRemoved.indexOf('  @Builder')) +
    importsRemoved.slice(helperStart, uiBuilderStart) + '}')
    .replace('struct PdfImportReviewPage', 'class PdfImportReviewPage')
    .replace(/@State\s+/g, '')
    .replace(/@StorageProp\([^)]*\)\s+/g, '')
  const models = ['entry/src/main/ets/models/ai/AiImportModels.ets',
    'entry/src/main/ets/services/review/PdfReviewModels.ets',
    'entry/src/main/ets/services/review/PdfReviewSession.ets'].map(file => read(file)
      .replace(/^import\s[\s\S]*?\sfrom\s+['"][^'"]+['"]\s*$/gm, '')
      .replace(/^export\s+/gm, '')).join('\n')
  let uuid = 0
  const runtime = vm.runInNewContext(stripTypeScriptTypes(models + source, { mode: 'transform' }) +
    '\n({ page: new PdfImportReviewPage(), PdfReviewSessionStore })', {
    util: { generateRandomUUID: () => '00000000-0000-4000-8000-' + String(++uuid).padStart(12, '0') },
    getContext: () => ({}),
    AiImportError: class extends Error {},
    AiImportErrorMessages: { forCode: code => 'mapped:' + code },
    MathContentUtils: { containsMath: value => value.includes('$') },
    WindowSizeClass: { COMPACT: 0, MEDIUM: 1, EXPANDED: 2 },
    ResponsiveLayout: { classify: () => 0, EXPANDED_CONTENT_MAX_WIDTH: 1160 },
    WindowSizeObserver: class { start() {} stop() {} },
    PdfImportState: { shared: () => ({ getCloudArtifactExpired: () => false }) }
  })
  const session = {
    sessionId: 'review-session', source: 'ai', bankUuid: 'bank', bankName: 'math', subject: 'math',
    pdfPath: '/cache/input.pdf', accountId: 'account', saveStage: 'draft',
    questions: [{
      draftQuestionId: 'draft', questionUuid: 'question', label: '', type: 'blank', question: 'q',
      options: [{ key: 'A', value: '$x$' }], answer: '', analysis: '', pageStart: 1, pageEnd: 1,
      confidence: 1, reviewRequired: false, images: []
    }],
    failures: [{ pageNumber: 2, code: 'invalid_json', message: 'private raw text',
      evidencePath: '/cache/evidence.jpg' }]
  }
  const copies = []
  const calls = { save: 0, abandon: 0, navigate: 0 }
  let dialog
  runtime.page.adapter = {
    persist: session => copies.push(runtime.PdfReviewSessionStore.copyOf(session)),
    save: async (_context, value) => { calls.save++; return value },
    abandon: async () => { calls.abandon++ },
    load: async () => runtime.PdfReviewSessionStore.copyOf(session)
  }
  runtime.page.adapter.discardFailure = async (_context, current, page, replacement) => {
    const updated = runtime.PdfReviewSessionStore.copyOf(current)
    if (replacement) updated.questions.push(replacement)
    updated.failures = updated.failures.filter(failure => failure.pageNumber !== page)
    copies.push(runtime.PdfReviewSessionStore.copyOf(updated))
    return updated
  }
  runtime.page.getUIContext = () => ({
    showAlertDialog: value => { dialog = value },
    getPromptAction: () => ({ showToast: () => {} }),
    getRouter: () => ({ replaceUrl: async () => { calls.navigate++ } })
  })
  runtime.page.applySession(session)
  runtime.page.loading = false
  return { ...runtime, session, copies, calls, dialog: () => dialog }
}

function aiAdapterRuntime() {
  const fixture = reviewPageRuntime()
  const state = { durable: null, error: null, restores: 0, retries: 0 }
  const source = [
    'entry/src/main/ets/models/ai/AiImportModels.ets',
    'entry/src/main/ets/services/review/PdfReviewModels.ets',
    'entry/src/main/ets/services/review/PdfReviewSession.ets',
    'entry/src/main/ets/services/review/AiPdfReviewAdapter.ets'
  ].map(file => read(file).replace(/^import\s[\s\S]*?\sfrom\s+['"][^'"]+['"]\s*$/gm, '')
    .replace(/^export\s+/gm, '')).join('\n')
  let runtime
  runtime = vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) +
    '\n({ adapter: new AiPdfReviewAdapter(), PdfReviewSessionStore, PdfReviewSavePolicy })', {
    PdfAiImportCoordinator: { createDefault: () => ({ retryPage: async () => { state.retries++ } }) },
    PdfImportState: { shared: () => ({ getReviewSessionId: () => fixture.session.sessionId }) },
    AccountSessionService: { state: async () => ({ signedIn: true, userId: fixture.session.accountId }) },
    AiImportSaveService: { restore: async () => {
      state.restores++
      if (state.error) throw state.error
      if (state.durable) runtime.PdfReviewSessionStore.put(state.durable)
      return state.durable
    } },
    AiImportError: class extends Error {},
    AiImportErrorCode: { INVALID_JSON: 'invalid_json' }
  })
  runtime.PdfReviewSessionStore.put(fixture.session)
  return { ...runtime, state, session: fixture.session }
}

test('AI adapter durable checkpoint overrides stale draft memory and locks retry/edit policy', async () => {
  const runtime = aiAdapterRuntime()
  runtime.state.durable = runtime.PdfReviewSessionStore.copyOf(runtime.session)
  runtime.state.durable.saveStage = 'text_saving'
  const loaded = await runtime.adapter.load({})
  assert.equal(loaded.saveStage, 'text_saving')
  assert.equal(runtime.PdfReviewSessionStore.get(loaded.sessionId).saveStage, 'text_saving')
  assert.equal(runtime.PdfReviewSavePolicy.canEdit(loaded.saveStage), false)
  await assert.rejects(runtime.adapter.retryPage({}, loaded, 1))
  assert.equal(runtime.state.retries, 0)
})

test('AI adapter propagates durable account/corruption failures instead of falling back to memory', async () => {
  for (const message of ['account mismatch', 'corrupt checkpoint']) {
    const runtime = aiAdapterRuntime()
    runtime.state.error = new Error(message)
    await assert.rejects(runtime.adapter.load({}), new RegExp(message))
    assert.equal(runtime.state.restores, 1)
  }
  const draft = aiAdapterRuntime()
  const loaded = await draft.adapter.load({})
  assert.equal(loaded.saveStage, 'draft')
  assert.equal(draft.state.restores, 1)
})

test('review edits and manual failure conversion persist deep copies with stable evidence UUIDs', async () => {
  const runtime = reviewPageRuntime()
  const page = runtime.page
  const original = page.session
  page.updateOption('draft', 'A', 'changed')
  assert.equal(original.questions[0].options[0].value, '$x$')
  assert.equal(page.session.questions[0].options[0].value, 'changed')
  const failure = page.failures[0]
  await page.addManualQuestion(failure)
  const question = page.session.questions[1]
  assert.match(question.questionUuid, /^[0-9a-f-]{36}$/)
  assert.equal(question.draftQuestionId, question.questionUuid)
  assert.equal(question.type, 'unknown')
  assert.equal(question.pageStart, 2)
  assert.equal(question.reviewRequired, true)
  assert.equal(question.images[0].localPath, '/cache/evidence.jpg')
  assert.equal(page.failures.length, 0)
  page.updateQuestionText(question.draftQuestionId, 'manual')
  assert.equal(page.session.questions[1].questionUuid, question.questionUuid)
  assert.equal(question.question, '')
  const count = runtime.copies.length
  page.session.saveStage = 'text_saving'
  page.updateQuestionText('draft', 'forbidden')
  page.discardFailure(2)
  assert.equal(runtime.copies.length, count)
})

test('review serializes save and back and abandons only after explicit draft choice', async () => {
  const runtime = reviewPageRuntime()
  const page = runtime.page
  let release
  page.adapter.save = async (_context, session) => {
    runtime.calls.save++
    await new Promise(resolve => { release = resolve })
    session.saveStage = 'text_saved'
    return session
  }
  const saving = page.saveReview()
  await page.saveReview()
  page.returnToImportPage()
  assert.equal(runtime.calls.save, 1)
  assert.equal(runtime.dialog(), undefined)
  release()
  await saving
  assert.equal(page.pending, false)
  assert.equal(page.session.saveStage, 'text_saved')
  page.returnToImportPage()
  assert.equal(runtime.calls.navigate, 1)
  assert.equal(runtime.calls.abandon, 0)
  page.navigationPending = false
  page.session.saveStage = 'draft'
  page.returnToImportPage()
  assert.equal(page.navigationPending, true)
  await page.saveReview()
  assert.equal(runtime.calls.save, 1)
  runtime.dialog().primaryButton.action()
  assert.equal(page.navigationPending, false)
  assert.equal(runtime.calls.abandon, 0)
  page.returnToImportPage()
  runtime.dialog().secondaryButton.action()
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(runtime.calls.abandon, 1)
  assert.equal(runtime.calls.navigate, 2)
})

test('review failed retry publishes committed session while hiding arbitrary provider errors', async () => {
  const runtime = reviewPageRuntime()
  const committed = runtime.PdfReviewSessionStore.copyOf(runtime.session)
  committed.questions[0].question = 'retried question'
  committed.failures = []
  runtime.page.adapter.retryPage = async () => { throw new Error('secret provider response') }
  runtime.page.adapter.load = async () => committed
  await runtime.page.retryFailure(2)
  assert.equal(runtime.page.session.questions[0].question, 'retried question')
  assert.equal(runtime.page.failures.length, 0)
  assert.equal(runtime.page.errorMessage, '本页重试失败')
  assert.equal(runtime.page.pending, false)
})

test('failure discard delegates cleanup and blocks duplicate clicks/save/back until it settles', async () => {
  const runtime = reviewPageRuntime()
  let calls = 0
  let release
  runtime.page.adapter.discardFailure = async () => {
    calls++
    await new Promise(resolve => { release = resolve })
    throw new Error('private cleanup diagnostics')
  }
  const work = runtime.page.discardFailure(2)
  assert.equal(runtime.page.pending, true)
  runtime.page.discardFailure(2)
  runtime.page.addManualQuestion(runtime.page.failures[0])
  runtime.page.returnToImportPage()
  await runtime.page.saveReview()
  assert.equal(calls, 1)
  assert.equal(runtime.calls.save, 0)
  assert.equal(runtime.dialog(), undefined)
  release()
  await work
  assert.equal(runtime.page.pending, false)
  assert.equal(runtime.page.failures.length, 1)
  assert.equal(runtime.page.errorMessage, '本页处理失败，请重试')
})

test('review exposes an explicit authoritative-state reload action and gates mutation while uncertain', () => {
  const page = read('entry/src/main/ets/pages/PdfImportReviewPage.ets')
  assert.match(page, /@State authoritativeStatePending: boolean = false/)
  assert.match(page, /Button\('重新加载审核状态'\)/)
  assert.match(page, /authoritativeStatePending[\s\S]*this\.loadDraft\(\)/)
  assert.match(page, /private canEdit\(\)[\s\S]*!this\.authoritativeStatePending/)
})

async function uncertainReviewRuntime() {
  const runtime = reviewPageRuntime()
  runtime.page.adapter.save = async () => {
    runtime.calls.save++
    throw new Error('checkpoint persisted then account changed')
  }
  runtime.page.adapter.load = async () => { throw new Error('private account mismatch') }
  await runtime.page.saveReview()
  return runtime
}

test('checkpoint/account-switch reconciliation failure locks every mutation and prevents abandonment', async () => {
  const runtime = await uncertainReviewRuntime()
  const page = runtime.page
  assert.equal(page.authoritativeStatePending, true)
  assert.equal(page.canEdit(), false)
  assert.equal(page.errorMessage, '审核状态暂时无法确认，请切回导入账号后重新加载')
  const before = JSON.stringify(page.session)
  const persisted = runtime.copies.length
  let retryCalls = 0
  let discardCalls = 0
  page.adapter.retryPage = async () => { retryCalls++ }
  page.adapter.discardFailure = async () => { discardCalls++ }
  page.updateType('draft', 'unknown')
  page.updateQuestionText('draft', 'changed')
  page.updateOption('draft', 'A', 'changed')
  page.updateAnswer('draft', 'changed')
  page.updateAnalysis('draft', 'changed')
  page.toggleMathPreview('draft')
  await page.retryFailure(2)
  await page.addManualQuestion(page.failures[0])
  await page.discardFailure(2)
  await page.saveReview()
  await page.abandonReview()
  assert.equal(JSON.stringify(page.session), before)
  assert.equal(page.previewDraftQuestionId, '')
  assert.equal(runtime.copies.length, persisted)
  assert.equal(runtime.calls.save, 1)
  assert.equal(runtime.calls.abandon, 0)
  assert.equal(retryCalls, 0)
  assert.equal(discardCalls, 0)
  page.returnToImportPage()
  assert.equal(runtime.dialog(), undefined)
  assert.equal(runtime.calls.abandon, 0)
  assert.equal(runtime.calls.navigate, 0)
})

test('initial review load failure keeps page ownership until authoritative reload succeeds', async () => {
  const runtime = reviewPageRuntime()
  const page = runtime.page
  page.session = null
  page.authoritativeStatePending = false
  page.adapter.load = async () => { throw new Error('private load diagnostics') }

  await page.loadDraft()

  assert.equal(page.authoritativeStatePending, true)
  assert.equal(page.loading, false)
  assert.equal(page.errorMessage, '审核状态暂时无法确认，请切回导入账号后重新加载')
  page.returnToImportPage()
  assert.equal(runtime.calls.navigate, 0)
  assert.equal(runtime.dialog(), undefined)

  const authoritative = runtime.PdfReviewSessionStore.copyOf(runtime.session)
  page.adapter.load = async () => authoritative
  await page.loadDraft()
  assert.equal(page.authoritativeStatePending, false)
  assert.equal(page.session.sessionId, authoritative.sessionId)
  page.returnToImportPage()
  assert.notEqual(runtime.dialog(), undefined)
  assert.equal(runtime.calls.navigate, 0)
})

test('repeated authoritative reload failure remains locked until owner checkpoint reload succeeds', async () => {
  const runtime = await uncertainReviewRuntime()
  const page = runtime.page
  await page.loadDraft()
  await page.loadDraft()
  assert.equal(page.authoritativeStatePending, true)
  assert.equal(page.canEdit(), false)
  assert.equal(page.loading, false)
  assert.doesNotMatch(page.errorMessage, /private account mismatch/)
  const authoritative = runtime.PdfReviewSessionStore.copyOf(runtime.session)
  authoritative.saveStage = 'text_saving'
  page.adapter.load = async () => authoritative
  await page.loadDraft()
  assert.equal(page.authoritativeStatePending, false)
  assert.equal(page.session.saveStage, 'text_saving')
  assert.equal(page.canEdit(), false)
  assert.equal(page.errorMessage, '')
  await page.abandonReview()
  assert.equal(runtime.calls.abandon, 0)
})

test('committed retry plus authoritative reload failure stays locked until explicit reload', async () => {
  const runtime = reviewPageRuntime()
  const page = runtime.page
  const authoritative = runtime.PdfReviewSessionStore.copyOf(runtime.session)
  authoritative.questions[0].question = 'committed retry'
  authoritative.failures = []
  page.adapter.retryPage = async () => { throw new Error('committed but cleanup failed') }
  page.adapter.load = async () => { throw new Error('account switched') }
  await page.retryFailure(2)
  assert.equal(page.authoritativeStatePending, true)
  assert.equal(page.canEdit(), false)
  assert.equal(page.errorMessage, '审核状态暂时无法确认，请切回导入账号后重新加载')
  await page.saveReview()
  await page.abandonReview()
  assert.equal(runtime.calls.save, 0)
  assert.equal(runtime.calls.abandon, 0)
  page.adapter.load = async () => authoritative
  await page.loadDraft()
  assert.equal(page.authoritativeStatePending, false)
  assert.equal(page.session.questions[0].question, 'committed retry')
  assert.equal(page.failures.length, 0)
})

test('committed discard or manual transfer plus reload failure locks until authoritative reload', async () => {
  for (const manual of [false, true]) {
    const runtime = reviewPageRuntime()
    const page = runtime.page
    let authoritative
    page.adapter.discardFailure = async (_context, session, _page, replacement) => {
      authoritative = runtime.PdfReviewSessionStore.copyOf(session)
      authoritative.failures = []
      if (replacement) authoritative.questions.push(replacement)
      throw new Error('committed then account switched')
    }
    page.adapter.load = async () => { throw new Error('account switched') }
    if (manual) await page.addManualQuestion(page.failures[0])
    else await page.discardFailure(2)
    assert.equal(page.authoritativeStatePending, true)
    assert.equal(page.canEdit(), false)
    assert.equal(page.errorMessage, '审核状态暂时无法确认，请切回导入账号后重新加载')
    await page.saveReview()
    await page.abandonReview()
    assert.equal(runtime.calls.save, 0)
    assert.equal(runtime.calls.abandon, 0)
    page.adapter.load = async () => authoritative
    await page.loadDraft()
    assert.equal(page.authoritativeStatePending, false)
    assert.equal(page.failures.length, 0)
    assert.equal(page.session.questions.length, manual ? 2 : 1)
  }
})

test('AI provider config storage persists only normalized public configuration', () => {
  const source = fs.readFileSync(sourcePath, 'utf8')

  assert.match(source, /const PREFERENCES_NAME:\s*string\s*=\s*'ai_provider_config'/)
  assert.match(source, /AiProviderConfigValidator\.normalize/)
  assert.match(source, /const PROVIDER_KEY:\s*string\s*=\s*'provider_id'/)
  assert.match(source, /const MODEL_KEY:\s*string\s*=\s*'model'/)
  assert.match(source, /const BASE_URL_KEY:\s*string\s*=\s*'base_url'/)
  assert.doesNotMatch(source, /api.?key|authorization|AiCredentialStore|withCredential/i)
  assert.match(source, /const UPDATE_PENDING_KEY:\s*string\s*=\s*'credential_update_pending'/)
  const persistedValues = [...source.matchAll(/store\.put\(([^\n]+)\)/g)].map(match => match[1])
  assert.ok(persistedValues.every(value => /^(UPDATE_PENDING_KEY, (true|false)|PROVIDER_KEY, normalized\.providerId|MODEL_KEY, normalized\.model|BASE_URL_KEY, normalized\.baseUrl)$/.test(value)))
})

test('provider validator accepts local http only for private hosts', () => {
  const runtime = providerValidatorRuntime()
  const accepted = [
    'https://api.example.com/v1',
    'http://localhost:11434/v1',
    'http://127.0.0.1:1234/v1',
    'http://192.168.0.20/v1',
    'http://10.1.2.3/v1',
    'http://172.16.0.1/v1',
    'http://172.31.255.254/v1',
    'http://[::1]:11434/v1'
  ]
  for (const baseUrl of accepted) {
    const config = new runtime.AiProviderConfig('openai_compatible', 'vision-model', baseUrl)
    // 全等断言：协议、主机（含 IPv6 方括号与端口）和受控路径都必须原样保留。
    assert.equal(runtime.AiProviderConfigValidator.normalize(config).baseUrl, baseUrl)
  }
  // 172/12 区间上下界与公网 11.x 前缀只能靠纯 IP 字面量锁定。
  // 注：`256.1.1.1` 与 `0100.0.0.1` 在 WHATWG URL 语义下分别于解析阶段抛错、被八进制归一化为 64.0.0.1，
  // 因此它们并不能锁住校验器里的「每段 ≤255 / 必须 4 段」守卫——那两个守卫是应对 ArkTS parseURL 可能更宽松的防御。
  for (const baseUrl of ['http://api.example.com/v1', 'http://172.32.0.1/v1', 'http://172.15.0.1/v1',
    'http://127.0.0.1.example.com/v1', 'http://10.example.com/v1', 'http://172.16.example.com/v1',
    'http://11.0.0.1/v1', 'http://256.1.1.1/v1', 'http://0100.0.0.1/v1']) {
    assert.throws(() => runtime.AiProviderConfigValidator.normalize(
      new runtime.AiProviderConfig('openai_compatible', 'vision-model', baseUrl)),
    error => error.code === runtime.AiImportErrorCode.INVALID_BASE_URL)
  }
  const platform = runtime.AiProviderConfigValidator.normalize(
    new runtime.AiProviderConfig('deepseek', 'deepseek-v4-flash-vision-exp', 'https://api.deepseek.com'))
  assert.equal(platform.providerId, 'deepseek')
  assert.equal(platform.supportsStructuredOutput, false)
})

test('endpoint guard allows https and private http but never public http', () => {
  const runtime = providerValidatorRuntime()
  const allowed = ['https://api.example.com/v1', 'http://localhost:11434/v1',
    'http://127.0.0.1:1234/v1', 'http://192.168.1.9:8000/v1', 'http://10.0.0.7/v1',
    'http://172.16.4.4/v1', 'http://172.31.4.4/v1']
  for (const endpoint of allowed) {
    assert.equal(runtime.AiProviderConfigValidator.isAllowedEndpoint(endpoint), true, endpoint)
  }
  const rejected = ['http://api.example.com/v1', 'http://10.evil.com/v1',
    'http://127.0.0.1.evil.com/v1', 'http://192.168.1.9.evil.com/v1',
    'http://172.32.4.4.invalid/v1', 'ftp://localhost/v1', 'not a url']
  for (const endpoint of rejected) {
    assert.equal(runtime.AiProviderConfigValidator.isAllowedEndpoint(endpoint), false, endpoint)
  }
  const transport = read('entry/src/main/ets/services/ai/AiVisionTransport.ets')
  assert.match(transport, /AiProviderConfigValidator\.isAllowedEndpoint\(endpoint\)/)
  assert.doesNotMatch(transport, /endpoint\.startsWith\('https:\/\/'\)/)
})

test('OpenAI-compatible adapter sends one page image through chat completions', () => {
  const source = read('entry/src/main/ets/services/ai/OpenAiCompatibleAdapter.ets')
  assert.match(source, /\/chat\/completions/)
  assert.match(source, /data:image\/jpeg;base64,/)
  assert.match(source, /"stream":false/)
  assert.match(source, /"type":"image_url"/)
  assert.match(source, /"role":"system"/)
  assert.match(source, /choices/)
  assert.match(source, /message/)
  assert.match(source, /content/)
  assert.match(source,
    /const bytes:[\s\S]*?try\s*{[\s\S]*?finally\s*{[\s\S]*?bytes\.fill\(0\)/)
})

test('AI transport is bounded, non-redirecting, cancellable and independent', () => {
  const source = read('entry/src/main/ets/services/ai/AiVisionTransport.ets')
  assert.match(source, /maxLimit:\s*AiImportLimits\.MAX_RESPONSE_BYTES/)
  assert.match(source, /maxRedirects:\s*0/)
  assert.match(source, /usingCache:\s*false/)
  assert.match(source, /expectDataType:\s*http\.HttpDataType\.STRING/)
  assert.match(source, /request\.destroy\(\)/)
  assert.match(source, /activeRequests\.get\(requestKey\)\s*===\s*request/)
  assert.match(source, /class AiActiveRequestState/)
  assert.match(source, /cancelled:\s*boolean/)
  assert.match(source, /destroyed:\s*boolean/)
  assert.match(source, /requestStates:\s*Map<http\.HttpRequest,\s*AiActiveRequestState>/)
  assert.match(source, /destroyOnce\(\):\s*void/)
  assert.match(source, /if \(this\.destroyed\) return/)
  assert.match(source,
    /const previousRequest:[\s\S]*?const previousState:[\s\S]*?previousState\.cancel\(\)[\s\S]*?activeRequests\.set\(requestKey, request\)/)
  assert.match(source, /state\.cancelled/)
  assert.match(source, /AiTransportErrorMapper\.system\(error\.code, state\.cancelled\)/)
  assert.match(source, /requestStates\.delete\(request\)/)
  assert.match(source,
    /cancel\(requestKey: string\): void[\s\S]*?if \(request === undefined\) return[\s\S]*?state\.cancel\(\)/)
  assert.match(source,
    /try\s*{[\s\S]*?if \(bodyBytes\.length > AiImportLimits\.MAX_REQUEST_BYTES\)[\s\S]*?finally\s*{[\s\S]*?bodyBytes\.fill\(0\)/)
  assert.doesNotMatch(source, /cancelledKeys/)
  assert.doesNotMatch(source, /ApiHttpClient|ApiConfig\.CA_PATH|remoteValidation|console\.|hilog\./)
  assert.doesNotMatch(source, /\bbody\s*:/)
})

test('PDF encoder releases page pixels before returning network-ready text', () => {
  const source = read('entry/src/main/ets/services/ai/PdfPageImageEncoder.ets')
  const limits = read('entry/src/main/ets/constants/AiImportLimits.ets')

  assert.match(source, /export interface PdfRenderSessionPort/)
  assert.match(source, /export interface PdfPageImageEncoderPort/)
  assert.match(source, /loadDocument\(pdfPath\)/)
  assert.match(source, /getPageCount\(\)/)
  assert.match(source, /getAreaPixelMapWithOptions/)
  assert.match(source, /packToData/)
  assert.match(limits, /\[82, 75, 68, 60\]/)
  assert.match(source, /MAX_JPEG_BYTES/)
  assert.match(source,
    /Number\.isFinite\(width\)[\s\S]*?Number\.isFinite\(height\)[\s\S]*?width <= 0[\s\S]*?height <= 0/)
  assert.match(source, /retriesAfterPackError\(code: number\): boolean/)

  const boundedStart = source.indexOf('private static async packBounded')
  const boundedEnd = source.indexOf('async encodePage', boundedStart)
  const boundedSource = source.slice(boundedStart, boundedEnd)
  assert.match(boundedSource,
    /let output: ArrayBuffer[\s\S]*?try\s*{[\s\S]*?output = await packer\.packToData\(pixelMap, option\)[\s\S]*?}\s*catch \(err\)[\s\S]*?continue[\s\S]*?throw err[\s\S]*?const candidate: Uint8Array = new Uint8Array\(output\)/)
  assert.match(boundedSource,
    /const candidate: Uint8Array = new Uint8Array\(output\)[\s\S]*?accepts\(candidate\.byteLength\)[\s\S]*?return candidate[\s\S]*?candidate\.fill\(0\)/)
  assert.match(boundedSource,
    /catch \(err\)[\s\S]*?retriesAfterPackError\(err\.code\)[\s\S]*?continue[\s\S]*?throw err/)
  assert.match(source, /return code === 62980106/)

  const encodeStart = source.indexOf('async encodePage')
  const cropStart = source.indexOf('async cropEvidence', encodeStart)
  const encodeSource = source.slice(encodeStart, cropStart)
  const pageStageIndex = encodeSource.indexOf('stagePageToFile')
  const base64Index = encodeSource.indexOf('encodeToString')
  const resultIndex = encodeSource.indexOf('encodedPage = new EncodedPdfPage')
  const packerReleaseIndex = encodeSource.indexOf('packer.release()', resultIndex)
  const pixelReleaseIndex = encodeSource.indexOf('pixelMap.release()', packerReleaseIndex)
  const pageReleaseIndex = encodeSource.indexOf('page.release()', pixelReleaseIndex)
  const finishIndex = encodeSource.indexOf('finishOperation()', pageReleaseIndex)
  const commitIndex = encodeSource.indexOf('commitStagedFile', finishIndex)
  const returnIndex = encodeSource.indexOf('return encodedPage', commitIndex)
  assert.ok(pageStageIndex >= 0)
  assert.ok(base64Index > pageStageIndex)
  assert.ok(resultIndex > base64Index)
  assert.ok(packerReleaseIndex > resultIndex)
  assert.ok(pixelReleaseIndex > packerReleaseIndex)
  assert.ok(pageReleaseIndex > pixelReleaseIndex)
  assert.ok(finishIndex > pageReleaseIndex)
  assert.ok(commitIndex > finishIndex)
  assert.ok(returnIndex > commitIndex)
  assert.match(encodeSource, /releaseTransientText\(\)/)
  assert.match(encodeSource, /cleanupStagedFile\(context\.cacheDir, staged/)

  assert.match(source,
    /loadDocument\(pdfPath\)[\s\S]*?PARSE_SUCCESS[\s\S]*?this\.document\.releaseDocument\(\)[\s\S]*?this\.closed = true/)
  const constructorIndex = source.indexOf('constructor(pdfPath: string)')
  const constructorSource = source.slice(
    constructorIndex,
    source.indexOf('pageCount(): number', constructorIndex),
  )
  assert.match(constructorSource,
    /try\s*{[\s\S]*?loadDocument\(pdfPath\)[\s\S]*?getPageCount\(\)[\s\S]*?catch \(err\)[\s\S]*?releaseDocument\(\)[\s\S]*?this\.closed = true/)
  assert.doesNotMatch(source, /textRecognition|PaddleOCR|CloudImport|commitImages/)
})

test('PDF encoder uses bounded exclusive evidence and crop files with narrow cleanup ownership', () => {
  const source = read('entry/src/main/ets/services/ai/PdfPageImageEncoder.ets')

  assert.match(source, /validateIdentifier\(sessionId\)/)
  assert.match(source, /validateIdentifier\(questionId\)/)
  assert.match(source, /\^\[A-Za-z0-9\._:-\]\{1,160\}\$/)
  assert.match(source, /OWNERSHIP_SEPARATOR:\s*string\s*=\s*'~'/)
  assert.match(source, /~ is excluded by the identifier grammar/)
  assert.match(source, /pageEvidenceName\(sessionId, pageNumber, artifactAttemptId\)/)
  assert.match(source, /cropEvidenceName\(sessionId, questionId, artifactAttemptId\)/)
  assert.match(source, /'ai_import_page_' \+ sessionId \+ PdfRenderSession\.OWNERSHIP_SEPARATOR/)
  assert.match(source, /'ai_import_crop_' \+ sessionId \+ PdfRenderSession\.OWNERSHIP_SEPARATOR/)

  const pagePrefix = 'ai_import_page_a~'
  const cropPrefix = 'ai_import_crop_a~'
  assert.equal('ai_import_page_a_b~1.jpg'.startsWith(pagePrefix), false)
  assert.equal('ai_import_crop_a_b~question.jpg'.startsWith(cropPrefix), false)

  const writeStart = source.indexOf('private static async stagePageToFile')
  const cropStart = source.indexOf('private static async stageCropToFile', writeStart)
  const commitStart = source.indexOf('private static async commitStagedFile', cropStart)
  const cleanupStart = source.indexOf('private static async cleanupStagedFile', commitStart)
  const builderStart = source.indexOf('private static createPageTempPath', cleanupStart)
  const pageWriter = source.slice(writeStart, cropStart)
  const cropWriter = source.slice(cropStart, commitStart)
  const commitSource = source.slice(commitStart, cleanupStart)
  const stagedCleanupSource = source.slice(cleanupStart, builderStart)
  const cropBuilderStart = source.indexOf('private static createCropTempPath', builderStart)
  const pageTempBuilderSource = source.slice(builderStart, cropBuilderStart)
  assert.match(pageWriter,
    /WRITE_ONLY \| fs\.OpenMode\.CREATE \| fs\.OpenMode\.TRUNC \| fs\.OpenMode\.NOFOLLOW/)
  assert.match(pageWriter, /while \(written < bytes\.byteLength\)/)
  assert.match(pageWriter, /Number\.isSafeInteger\(currentWrite\)/)
  assert.match(pageWriter, /currentWrite <= 0/)
  assert.match(pageWriter, /currentWrite > remaining\.byteLength/)
  assert.match(pageWriter, /await fs\.fsync\(file\.fd\)/)
  assert.match(pageWriter,
    /await fs\.fsync\(file\.fd\)[\s\S]*?await fs\.close\(file\)[\s\S]*?await fs\.lstat\(staged\.tempPath\)/)
  assert.match(pageWriter, /isSymbolicLink\(\)/)
  assert.match(pageWriter, /!info\.isFile\(\)/)
  assert.match(pageWriter, /info\.size !== bytes\.byteLength/)
  assert.match(pageWriter,
    /const remaining: Uint8Array = bytes\.slice\(written\)[\s\S]*?finally\s*{[\s\S]*?remaining\.fill\(0\)/)
  assert.doesNotMatch(pageWriter, /bytes\.buffer\.slice/)
  assert.doesNotMatch(pageWriter, /staged\.finalPath/)

  assert.match(cropWriter,
    /WRITE_ONLY \| fs\.OpenMode\.CREATE \| fs\.OpenMode\.TRUNC \| fs\.OpenMode\.NOFOLLOW/)
  assert.match(cropWriter, /await packer\.packToFile/)
  assert.match(cropWriter, /await fs\.fsync\(temporaryFile\.fd\)/)
  assert.match(cropWriter, /quality:\s*82/)
  assert.match(cropWriter, /PdfPageSizing\.calculate\(matrix\.width, matrix\.height\)/)
  assert.match(cropWriter,
    /await fs\.lstat\(staged\.tempPath\)[\s\S]*?isSymbolicLink\(\)[\s\S]*?!temporaryInfo\.isFile\(\)[\s\S]*?temporaryInfo\.size <= 0/)
  assert.doesNotMatch(cropWriter, /moveFile/)
  assert.doesNotMatch(cropWriter, /staged\.finalPath/)

  assert.match(commitSource, /lstatIfPresent\(staged\.finalPath\)/)
  assert.match(commitSource, /await fs\.moveFile\(staged\.tempPath, staged\.finalPath, 1\)/)
  assert.doesNotMatch(commitSource, /unlink/)
  assert.match(stagedCleanupSource, /removeOwnedOrdinaryFile\(cacheDir, staged\.tempPath\)/)
  assert.doesNotMatch(stagedCleanupSource, /staged\.finalPath[\s\S]*?unlink/)
  assert.doesNotMatch(source,
    /unlinkIfPresent\(staged\.finalPath\)|removeOwnedOrdinaryFile\([^\n]*staged\.finalPath/)
  assert.match(pageTempBuilderSource, /validateIdentifier\(sessionId\)/)
  assert.match(pageTempBuilderSource,
    /Number\.isSafeInteger\(pageNumber\)[\s\S]*?pageNumber <= 0/)

  assert.match(source, /appendDiagnostic/)
  assert.match(source, /await fs\.listFile\(context\.cacheDir/)
  assert.match(source, /isOwnedPageName\(name, sessionId\)/)
  assert.match(source, /isOwnedCropName\(name, sessionId\)/)
  assert.match(source, /\^\[1-9\]\[0-9\]\*\\\.jpg\$/)
  assert.match(source, /\^\[A-Za-z0-9\._:-\]\{1,160\}\\\.jpg\$/)
  assert.match(source, /~tmp~/)

  const sessionCleanupStart = source.indexOf('static async cleanupOwnedCache')
  const sessionCleanupEnd = source.indexOf('private ensureOpen', sessionCleanupStart)
  const sessionCleanupSource = source.slice(sessionCleanupStart, sessionCleanupEnd)
  assert.match(sessionCleanupSource,
    /verifyParentIdentity\(context\.cacheDir, path\)[\s\S]*?unlinkIfPresent\(path\)/)

  const removeStart = source.indexOf('private static async removeOwnedOrdinaryFile')
  const identityStart = source.indexOf('private static async verifyParentIdentity', removeStart)
  const identityEnd = source.indexOf('private static async lstatIfPresent', identityStart)
  const removeSource = source.slice(removeStart, identityStart)
  const identitySource = source.slice(identityStart, identityEnd)
  assert.match(removeSource,
    /verifyParentIdentity\(cacheDir, path\)[\s\S]*?unlinkIfPresent\(path\)/)
  assert.match(identitySource, /await fs\.lstat\(cacheDir\)/)
  assert.match(identitySource, /await fs\.stat\(cacheDir\)/)
  assert.match(identitySource, /await fs\.lstat\(candidateParent\)/)
  assert.match(identitySource, /await fs\.stat\(candidateParent\)/)
  assert.match(identitySource, /isSymbolicLink\(\)/)
  assert.match(identitySource, /isDirectory\(\)/)
  assert.match(identitySource, /\.ino/)

  assert.match(source, /err\.code === 13900002/)
  assert.match(source, /reject\(new Error\(PdfRenderSession\.errorMessage\(err,/)
  assert.equal((source.match(/err\.code === 13900002/g) || []).length, 2)
  assert.doesNotMatch(source, /commitImages/)
})

test('PDF encoder defers close through active operation leases and preserves late failures', () => {
  const source = read('entry/src/main/ets/services/ai/PdfPageImageEncoder.ets')
  assert.match(source, /private activeOperations: number = 0/)
  assert.match(source, /private closeRequested: boolean = false/)
  assert.match(source, /private closed: boolean = false/)

  const beginStart = source.indexOf('private beginOperation(): void')
  const finishStart = source.indexOf('private finishOperation(): void', beginStart)
  const releaseStart = source.indexOf('private releaseDocumentForClose(): void', finishStart)
  const closeStart = source.indexOf('close(): void', releaseStart)
  const cleanupStart = source.indexOf('static async cleanupOwnedCache', closeStart)
  const beginSource = source.slice(beginStart, finishStart)
  const finishSource = source.slice(finishStart, releaseStart)
  const releaseSource = source.slice(releaseStart, closeStart)
  const closeSource = source.slice(closeStart, cleanupStart)
  assert.match(beginSource, /this\.closed \|\| this\.closeRequested/)
  assert.match(beginSource, /this\.activeOperations\+\+/)
  assert.match(finishSource, /this\.activeOperations--/)
  assert.match(finishSource,
    /this\.activeOperations === 0 && this\.closeRequested && !this\.closed[\s\S]*?releaseDocumentForClose\(\)/)
  assert.match(releaseSource,
    /this\.document\.releaseDocument\(\)[\s\S]*?this\.closed = true/)
  assert.match(closeSource,
    /this\.closeRequested = true[\s\S]*?this\.activeOperations === 0[\s\S]*?releaseDocumentForClose\(\)/)
  assert.doesNotMatch(closeSource,
    /this\.closed = true[\s\S]*?this\.document\.releaseDocument\(\)/)

  const encodeStart = source.indexOf('async encodePage')
  const cropStart = source.indexOf('async cropEvidence', encodeStart)
  const closeMethodStart = source.indexOf('close(): void', cropStart)
  const encodeSource = source.slice(encodeStart, cropStart)
  const cropSource = source.slice(cropStart, closeMethodStart)
  assert.match(encodeSource, /this\.beginOperation\(\)/)
  assert.match(encodeSource, /catch \(finishErr\)[\s\S]*?appendDiagnostic/)
  assert.match(cropSource, /this\.beginOperation\(\)/)
  assert.match(cropSource,
    /page\.release\(\)[\s\S]*?catch \(releaseErr\)[\s\S]*?appendDiagnostic[\s\S]*?finishOperation\(\)/)
  const cropStageIndex = cropSource.indexOf('stageCropToFile')
  const cropPageReleaseIndex = cropSource.indexOf('page.release()', cropStageIndex)
  const cropFinishIndex = cropSource.indexOf('finishOperation()', cropPageReleaseIndex)
  const cropCommitIndex = cropSource.indexOf('commitStagedFile', cropFinishIndex)
  assert.ok(cropStageIndex >= 0)
  assert.ok(cropPageReleaseIndex > cropStageIndex)
  assert.ok(cropFinishIndex > cropPageReleaseIndex)
  assert.ok(cropCommitIndex > cropFinishIndex)
  assert.match(cropSource, /cleanupStagedFile\(context\.cacheDir, staged/)
})

test('PDF encoder isolates retry artifacts by exact logical session and attempt ownership', () => {
  const source = read('entry/src/main/ets/services/ai/PdfPageImageEncoder.ets')
  assert.match(source, /cleanupAttempt\(context: Context, sessionId: string, attemptId: string\)/)
  assert.match(source,
    /cleanupAttemptCrops\(context: Context, sessionId: string, attemptId: string\)/)
  assert.match(source,
    /cleanupEvidence\(context: Context, sessionId: string, evidencePath: string\)/)
  assert.match(source, /ATTEMPT_MARKER:\s*string\s*=\s*'attempt'/)
  assert.match(source,
    /'ai_import_page_' \+ sessionId \+ PdfRenderSession\.OWNERSHIP_SEPARATOR[\s\S]*?ATTEMPT_MARKER[\s\S]*?attemptId/)
  assert.match(source,
    /'ai_import_crop_' \+ sessionId \+ PdfRenderSession\.OWNERSHIP_SEPARATOR[\s\S]*?ATTEMPT_MARKER[\s\S]*?attemptId/)
  assert.match(source, /isOwnedAttemptPageName\(name, sessionId, attemptId\)/)
  assert.match(source, /isOwnedAttemptCropName\(name, sessionId, attemptId\)/)
  assert.match(source, /cleanupOwnedAttemptCrops/)
  assert.match(source, /cleanupOwnedEvidence/)
  assert.match(source,
    /cleanupOwnedAttempt[\s\S]*?verifyParentIdentity\(context\.cacheDir, path\)[\s\S]*?unlinkIfPresent\(path\)/)

  const owned = 'ai_import_page_a~attempt~token~1.jpg'
  const neighbor = 'ai_import_page_a_b~attempt~token~1.jpg'
  assert.equal(owned.startsWith('ai_import_page_a~'), true)
  assert.equal(neighbor.startsWith('ai_import_page_a~'), false)
})

test('PDF encoder deletes only an explicit cache-root session-owned evidence file', () => {
  const source = read('entry/src/main/ets/services/ai/PdfPageImageEncoder.ets')
  const start = source.indexOf('static async cleanupOwnedEvidence')
  const end = source.indexOf('private ensureOpen', start)
  const cleanup = source.slice(start, end)
  assert.ok(start >= 0)
  assert.match(cleanup, /validateIdentifier\(sessionId\)/)
  assert.match(cleanup, /validateCacheDirectory\(context\.cacheDir\)/)
  assert.match(cleanup, /directChildName\(context\.cacheDir, evidencePath\)/)
  assert.match(cleanup, /isOwnedPageName\(name, sessionId\)/)
  assert.match(cleanup, /isOwnedCropName\(name, sessionId\)/)
  assert.match(cleanup, /isSymbolicLink\(\)/)
  assert.match(cleanup, /!info\.isFile\(\)/)
  assert.match(cleanup,
    /verifyParentIdentity\(context\.cacheDir, evidencePath\)[\s\S]*?unlinkIfPresent\(evidencePath\)/)
})

test('AI coordinator owns one sequential local-only page pipeline', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const processStart = source.indexOf('private async processPage')
  const processSource = source.slice(processStart)
  assert.match(source, /for \(let pageNumber:/)
  assert.match(source, /return this\.transport\.postJson\(/)
  assert.match(processSource,
    /encodePage[\s\S]*?credentials\.run[\s\S]*?extractAssistantContent[\s\S]*?parser\.parse/)
  assert.match(processSource, /releaseTransientText\(\)/)
  assert.match(processSource, /providerRequest\.release\(\)/)
  assert.match(processSource, /rawResponse = ''/)
  assert.match(processSource, /assistantContent = ''/)
  assert.match(source, /transport\.cancel\(/)
  assert.doesNotMatch(source,
    /Promise\.all|CloudImportService|CloudImportApi|PaddleOCR|textRecognition/)
})

test('AI coordinator keeps cancellation and request cleanup generation safe', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  assert.match(source, /class ActiveCoordinatorRequest/)
  assert.match(source, /private generation: number = 0/)
  assert.match(source, /private operationTail: Promise<void> = Promise\.resolve\(\)/)
  assert.match(source, /private activeRequest: ActiveCoordinatorRequest \| null = null/)
  assert.match(source,
    /if \(this\.activeRequest === request\)[\s\S]*?this\.activeRequest = null/)
  assert.match(source,
    /beginGeneration\(\)[\s\S]*?this\.transport\.cancel\(active\.requestKey\)/)
  assert.match(source,
    /const generation: number = this\.beginGeneration\(\)[\s\S]*?runExclusive/)
  assert.match(source, /this\.requireGeneration\(generation\)[\s\S]*?questions\.push/)
})

test('AI coordinator retry is page-bounded, atomic and shares processPage', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const processStart = source.indexOf('private async processPage')
  assert.ok(processStart >= 0)
  const processSource = source.slice(processStart)
  assert.match(source, /async retryPage\(/)
  assert.equal((source.match(/this\.processPage\(/g) || []).length, 2)
  assert.match(source, /Number\.isSafeInteger\(pageNumber\)/)
  assert.match(source, /pageNumber > renderSession\.pageCount\(\)/)
  assert.match(source, /representedPage/)
  assert.match(source, /stableIds\.get\(draftQuestionId\)/)
  assert.match(source, /failure\.pageNumber !== pageNumber/)
  assert.match(processSource, /const pageQuestions: Array<PdfReviewQuestion>/)
  assert.match(processSource,
    /cropEvidence[\s\S]*?this\.requireGeneration\(generation\)[\s\S]*?pageQuestions\.push/)
  assert.match(processSource,
    /parsed\.length > 0[\s\S]*?parsed\[parsed\.length - 1\]/)
})

test('AI coordinator cleans only failed attempt artifacts and retains successful namespaces', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const processStart = source.indexOf('private async processPage')
  const processSource = source.slice(processStart)
  assert.match(source, /class ProcessedAiPage[\s\S]*?attemptId: string/)
  assert.match(processSource, /const attemptId: string = util\.generateRandomUUID\(\)/)
  assert.match(processSource, /encodePage\([^\n]+attemptId\)/)
  assert.match(processSource, /cropEvidence\([\s\S]*?attemptId\)/)
  assert.match(processSource,
    /operationError !== null[\s\S]*?cleanupAttempt\(context, sessionId, attemptId\)/)
  assert.match(source, /successfulAttempts: Array<string>/)
  assert.match(source,
    /successfulAttempts\.push\(processed\.attemptId\)[\s\S]*?cleanupAttempts/)
  assert.doesNotMatch(processSource, /cleanupSession\(/)
})

test('AI coordinator retains initial page evidence but fully cleans failed retries', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  assert.match(source, /enum PageAttemptCleanupPolicy/)
  assert.match(source, /RETAIN_PAGE/)
  assert.match(source, /REMOVE_ATTEMPT/)
  assert.match(source, /cleanupAttemptCrops\(context, sessionId, attemptId\)/)
  assert.match(source, /cleanupAttempt\(context, sessionId, attemptId\)/)
  assert.match(source,
    /PageAttemptCleanupPolicy\.RETAIN_PAGE[\s\S]*?PageAttemptCleanupPolicy\.REMOVE_ATTEMPT/)
  assert.match(source, /retainedFailureAttempts/)
  assert.match(source,
    /const evidencePath:\s*string\s*=\s*encoded === null \? '' : encoded\.evidencePath/)
})

test('AI coordinator surfaces cleanup failure while retaining the primary error code', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  assert.match(source, /export class AiImportCleanupRequiredError extends AiImportError/)
  assert.match(source, /cleanupFailed:\s*boolean/)
  assert.match(source, /this\.code = code|super\(code\)/)
  assert.match(source, /本次页面临时文件清理失败/)
  assert.match(source, /cleanupAttemptsAndReport/)
  assert.match(source, /withCleanupFailure/)
  assert.match(source, /withoutCleanupFailure/)
  assert.doesNotMatch(source,
    /cleanupAttempt(?:Crops)?\([^)]*\)[\s\S]{0,100}?catch\s*{\s*}/)
})

test('coordinator exposes cleanup debt only while the final exact cleanup still fails', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const pageErrorStart = source.indexOf('class PageProcessingError')
  const signalStart = source.indexOf('export class AiImportCleanupRequiredError')
  const secondaryStart = source.indexOf('class SecondaryCleanupAiImportError')
  assert.ok(pageErrorStart >= 0 && signalStart > pageErrorStart && secondaryStart > signalStart)
  const withCleanup = extractMethodSource(source, 'private static withCleanupFailure')
  const withoutCleanup = extractMethodSource(source, 'private static withoutCleanupFailure')
  const model = read('entry/src/main/ets/models/ai/AiProviderConfig.ets')
    .replace(/import[\s\S]*?from\s*'[^']+'\s*;?/g, '').replace(/export /g, '')
  const errors = source.slice(pageErrorStart, secondaryStart).replace(/export /g, '')
  const harness = stripTypeScriptTypes(model + errors + `
    class CleanupSignalHarness {
      ${withCleanup}
      ${withoutCleanup}
    }
    ({ AiImportError, AiImportErrorCode, AiImportCleanupRequiredError,
      PageProcessingError, CleanupSignalHarness })`, { mode: 'transform' })
  const r = vm.runInNewContext(harness, { url: { URL: { parseURL: text => new URL(text) } } })
  const primary = new r.AiImportError(r.AiImportErrorCode.AUTH_FAILED)
  const required = r.CleanupSignalHarness.withCleanupFailure(primary)
  assert.ok(required instanceof r.AiImportCleanupRequiredError)
  assert.equal(required.code, primary.code)
  const internal = new r.PageProcessingError(primary.code, 'evidence.jpg', 'attempt-a', true)
  const cleaned = r.CleanupSignalHarness.withoutCleanupFailure(internal)
  assert.ok(cleaned instanceof r.AiImportError)
  assert.equal(cleaned instanceof r.AiImportCleanupRequiredError, false)
  assert.equal(cleaned.code, primary.code)

  const run = extractMethodSource(source, 'private async executeRun')
  assert.equal((run.match(/withoutCleanupFailure\(operationError\)/g) || []).length, 1)
  assert.equal((run.match(/withoutCleanupFailure\(primary\)/g) || []).length, 1)
  const retry = extractMethodSource(source, 'private async executeRetry')
  assert.match(retry,
    /operationError instanceof PageProcessingError[\s\S]*?operationError\.cleanupFailed[\s\S]*?operationError\.attemptId/)
  assert.match(retry, /withoutCleanupFailure\(operationError\)/)
  assert.match(retry, /withoutCleanupFailure\(primary\)/)
})

test('AI coordinator guards credential-delayed transport dispatch by identity and generation', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const actionStart = source.indexOf('class TransportCredentialAction')
  const actionEnd = source.indexOf('class ActiveCoordinatorRequest', actionStart)
  const action = source.slice(actionStart, actionEnd)
  const executeStart = action.indexOf('execute(credential')
  const guardIndex = action.indexOf('dispatchGuard()', executeStart)
  const postIndex = action.indexOf('transport.postJson', executeStart)
  assert.ok(guardIndex > executeStart)
  assert.ok(postIndex > guardIndex)
  assert.match(source, /requireDispatch\(request: ActiveCoordinatorRequest, generation: number\)/)
  assert.match(source,
    /generation !== this\.generation \|\| this\.activeRequest !== request/)
  assert.match(source,
    /this\.activeRequest = requestState[\s\S]*?credentials\.run\(context/)
})

test('AI coordinator commits retry before narrowly deleting superseded failure evidence', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const retryStart = source.indexOf('private async executeRetry')
  const processStart = source.indexOf('private async processPage', retryStart)
  const retry = source.slice(retryStart, processStart)
  const putIndex = retry.indexOf('PdfReviewSessionStore.put(updated)')
  const getIndex = retry.indexOf('PdfReviewSessionStore.get(updated.sessionId)', putIndex)
  const cleanupIndex = retry.indexOf('cleanupEvidenceAndReport', getIndex)
  assert.ok(putIndex >= 0)
  assert.ok(getIndex > putIndex)
  assert.ok(cleanupIndex > getIndex)
  assert.match(source, /renderer\.cleanupEvidence/)
  assert.match(retry, /failure\.pageNumber !== pageNumber/)
  assert.match(retry, /failure\.evidencePath\.length > 0/)
  assert.match(retry, /withCleanupFailure/)
})

test('AI coordinator discard always attempts both cleanups and retains first failure', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const start = source.indexOf('private async executeDiscard')
  const end = source.indexOf('private async executeRun', start)
  const discard = source.slice(start, end)
  const imageIndex = discard.indexOf('renderer.cleanupSession')
  const pdfIndex = discard.indexOf('pdfCleanup.remove')
  assert.ok(imageIndex >= 0)
  assert.ok(pdfIndex > imageIndex)
  assert.match(discard, /let firstError: AiImportError \| null = null/)
  assert.match(discard, /secondaryCleanupFailed/)
  assert.match(discard, /withSecondaryCleanupFailure/)
  assert.match(discard,
    /if \(firstError !== null\)[\s\S]*?throw[\s\S]*?PdfReviewSessionStore\.remove\(request\.sessionId\)/)
  assert.equal((discard.match(/try\s*{/g) || []).length, 2)
})

test('default PDF cleanup remembers successful exact paths across discard retries', async () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const start = source.indexOf('class DefaultPdfTemporaryFileCleanup')
  const end = source.indexOf('class TransportCredentialAction', start)
  assert.ok(start >= 0 && end > start)
  let removeCalls = 0
  const Cleanup = vm.runInNewContext(stripTypeScriptTypes(source.slice(start, end),
    { mode: 'transform' }) + '\nDefaultPdfTemporaryFileCleanup', {
    PdfImportService: { async removeTemporaryPdf(path) {
      assert.equal(path, 'selected.pdf'); removeCalls++
    } }
  })
  const cleanup = new Cleanup()
  await cleanup.remove('selected.pdf')
  await cleanup.remove('selected.pdf')
  assert.equal(removeCalls, 1)
})

test('discard retry converges after image, PDF, or combined partial failure', async () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const cleanupStart = source.indexOf('class DefaultPdfTemporaryFileCleanup')
  const cleanupEnd = source.indexOf('class TransportCredentialAction', cleanupStart)
  const discard = extractMethodSource(source, 'private async executeDiscard')
  for (const scenario of [
    { imageFailures: 1, pdfFailures: 0, expectedPdfCalls: 1 },
    { imageFailures: 0, pdfFailures: 1, expectedPdfCalls: 2 },
    { imageFailures: 1, pdfFailures: 1, expectedPdfCalls: 2 },
  ]) {
    let imageFailures = scenario.imageFailures
    let pdfFailures = scenario.pdfFailures
    let pdfCalls = 0
    const sessions = new Set(['session-a'])
    const events = []
    const harness = stripTypeScriptTypes(source.slice(cleanupStart, cleanupEnd) + `
      class PdfAiImportCoordinator {
        constructor(renderer, pdfCleanup) { this.renderer = renderer; this.pdfCleanup = pdfCleanup }
        requireGeneration() {}
        static normalizeError(error) { return error }
        static withSecondaryCleanupFailure(error) { return error }
        ${discard}
      }
      ({ DefaultPdfTemporaryFileCleanup, PdfAiImportCoordinator })`, { mode: 'transform' })
    const runtime = vm.runInNewContext(harness, {
      PdfImportService: { async removeTemporaryPdf() {
        pdfCalls++; events.push('pdf')
        if (pdfFailures > 0) { pdfFailures--; throw Error('pdf failed') }
      } },
      PdfReviewSessionStore: { remove(id) { events.push('remove-session'); sessions.delete(id) } }
    })
    const renderer = { async cleanupSession() {
      events.push('images')
      if (imageFailures > 0) { imageFailures--; throw Error('images failed') }
    } }
    const cleanup = new runtime.DefaultPdfTemporaryFileCleanup()
    const coordinator = new runtime.PdfAiImportCoordinator(renderer, cleanup)
    const request = { sessionId: 'session-a', pdfPath: 'selected.pdf' }
    await assert.rejects(coordinator.executeDiscard('context', request, 1))
    assert.equal(sessions.has('session-a'), true)
    assert.equal(events.includes('remove-session'), false)
    await coordinator.executeDiscard('context', request, 1)
    assert.equal(pdfCalls, scenario.expectedPdfCalls)
    assert.equal(sessions.has('session-a'), false)
    assert.equal(events.at(-1), 'remove-session')
  }
})

test('AI review keeps an image even when bbox is unusable', () => {
  const parser = read('entry/src/main/ets/services/ai/AiQuestionResponseParser.ets')
  const coordinator = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const review = read('entry/src/main/ets/pages/PdfImportReviewPage.ets')
  assert.match(parser, /bboxUsable/)
  assert.match(coordinator, /evidencePath/)
  assert.match(coordinator, /new PdfReviewImage/)
  assert.match(review, /file:\/\//)
})

test('unusable bbox skips cropping and keeps whole-page evidence as the question image', async () => {
  const drafts = [{ label: '第3题', type: 'short_answer', question: '证明题', options: [],
    answer: null, analysis: null, bboxUsable: false, bbox: null }]
  const runtime = bboxCoordinatorRuntime(drafts)
  const processed = await runtime.coordinator.processPage('fake context', runtime.open(),
    'bbox-session', 1, { providerId: 'openai_compatible', model: 'fixture',
      baseUrl: 'https://coordinator.invalid/v1' }, '', 0, new Map(), 0)
  assert.equal(processed.questions.length, 1)
  assert.equal(processed.questions[0].images[0].localPath, runtime.pageEvidencePath)
  assert.equal(runtime.calls.cropEvidence, 0)
  assert.equal(runtime.calls.cleanupEvidence, 0)
  assert.equal(runtime.evidence.has(runtime.pageEvidencePath), true)
})

test('usable bbox crops per question and discards the unused whole-page evidence', async () => {
  const drafts = [{ label: '第1题', type: 'short_answer', question: '题目', options: [],
    answer: null, analysis: null, bboxUsable: true, bbox: { x1: 0, y1: 0, x2: 100, y2: 100 } }]
  const runtime = bboxCoordinatorRuntime(drafts)
  const processed = await runtime.coordinator.processPage('fake context', runtime.open(),
    'bbox-session', 1, { providerId: 'openai_compatible', model: 'fixture',
      baseUrl: 'https://coordinator.invalid/v1' }, '', 0, new Map(), 0)
  assert.equal(processed.questions.length, 1)
  assert.equal(processed.questions[0].images[0].localPath, '/cache/forbidden-crop.jpg')
  assert.equal(runtime.calls.cropEvidence, 1)
  assert.equal(runtime.calls.cleanupEvidence, 1)
  assert.equal(runtime.evidence.has(runtime.pageEvidencePath), false)
})

test('automated tests use fakes and cannot call an external provider', () => {
  const unit = read('entry/src/test/AiImportLocalUnit.test.ets')
  assert.match(unit, /implements PdfPageImageEncoderPort/)
  assert.match(unit, /implements AiProviderAdapter/)
  assert.match(unit, /FakeConnectionTransport/)
  assert.doesNotMatch(unit, /api\.openai\.com|Authorization|AiConnectionTestService\.test/)
  assertTestOnlyUrlLiterals(unit)
  assertNoProductionNetworkUse(unit)
})

test('test-only network helpers reject real provider URLs and production network APIs', () => {
  assert.throws(() => assertTestOnlyUrlLiterals(
    "const url = 'https://api.openai.com/v1/chat/completions'"))
  assert.throws(() => assertNoProductionNetworkUse(
    "import { AiVisionTransport } from './AiVisionTransport'"))
  assert.throws(() => assertNoProductionNetworkUse("import { http } from '@kit.NetworkKit'"))
  assert.throws(() => assertNoProductionNetworkUse("fetch('https://example.com')"))
  assertTestOnlyUrlLiterals("const url = 'https://vision.example.com/v1'")
  assertNoProductionNetworkUse('const fake = new FakeConnectionTransport()')
  // 本机/私网 http fixture 允许，可公网路由的地址仍然禁止。
  assertTestOnlyUrlLiterals("const url = 'http://192.168.1.9:8000/v1'")
  assertTestOnlyUrlLiterals("const url = 'http://172.31.4.4/v1'")
  // WHATWG URL 会保留 IPv6 方括号，本机 IPv6 字面量同样必须放行。
  assertTestOnlyUrlLiterals("const url = 'http://[::1]:11434/v1'")
  assert.throws(() => assertTestOnlyUrlLiterals("const url = 'http://172.32.4.4/v1'"))
  assert.throws(() => assertTestOnlyUrlLiterals("const url = 'http://11.0.0.1/v1'"))
  assert.throws(() => assertTestOnlyUrlLiterals("const url = 'https://api.deepseek.com/v1'"))
})

test('provider config store keeps catalog platform ids and tolerates unknown ids', async () => {
  const source = read('entry/src/main/ets/services/ai/AiProviderConfigStore.ets')
  assert.doesNotMatch(source, /providerValue === AiProviderId\.OPENAI/, 'store must not collapse ids')
  assert.match(source, /const providerId: string = providerValue/)
})

// 上面的源码断言只防书写格式回归（`providerId: string = providerValue` 的等价改写会假失败），
// 无法识别语义等价的折叠写法，因此这里用与 barrierRuntime 相同的 vm + 假 preferences 装载方式
// 做行为级验证：目录平台 id 必须在 load/save/持久化三个层面原样保留。
test('provider config store preserves catalog and unknown provider ids at runtime', async () => {
  const seeded = barrierRuntime({
    durable: new Map(),
    values: new Map([
      ['provider_id', 'deepseek'],
      ['model', 'm'],
      ['base_url', 'https://a.invalid/v1'],
    ]),
    failFlush: false,
  })
  const loaded = await seeded.AiProviderConfigStore.load('fake context')
  assert.notEqual(loaded, null, 'seeded catalog config must load')
  assert.equal(loaded.providerId, 'deepseek', 'catalog platform id must survive load unchanged')
  assert.notEqual(loaded.providerId, seeded.AiProviderId.CUSTOM,
    'catalog id must not be folded into openai_compatible on load')
  assert.notEqual(loaded.providerId, seeded.AiProviderId.OPENAI)
  assert.equal(loaded.model, 'm')
  assert.equal(loaded.baseUrl, 'https://a.invalid/v1')

  const fresh = barrierRuntime()
  const unknown = new fresh.AiProviderConfig('totally-unknown-id', 'm', 'https://b.invalid/v1')
  const saved = await fresh.AiProviderConfigStore.save('fake context', unknown)
  assert.equal(saved.providerId, 'totally-unknown-id')
  let reloaded = null
  await assert.doesNotReject(async () => {
    reloaded = await fresh.AiProviderConfigStore.load('fake context')
  }, 'unknown provider ids must be tolerated, not rejected')
  assert.notEqual(reloaded, null, 'saved unknown-id config must load back')
  assert.equal(reloaded.providerId, 'totally-unknown-id',
    'unknown ids must be tolerated, not folded or dropped')
  assert.equal(reloaded.model, 'm')
  assert.equal(reloaded.baseUrl, 'https://b.invalid/v1')
  // 反向对照：原始持久化值本身也必须保留未知 id，而不是仅在内存对象里回显。
  assert.equal(fresh.backing.values.get('provider_id'), 'totally-unknown-id',
    'raw persisted provider_id must keep the unknown id')
  assert.equal(fresh.backing.values.get('model'), 'm')
  assert.equal(fresh.backing.values.get('base_url'), 'https://b.invalid/v1')
})

// Task 5 只交付「选择页 + 双处路由注册」，设置页的接线（跳转按钮、AiPlatformSelectionState.shared().peek()/take()、
// 模型芯片）已由 Task 6 补齐，因此本用例末尾补上那两条 settings 断言，并加一条 peek→守卫→take 顺序牙。
test('platform picker page is registered once and reachable from the settings page', () => {
  const route = 'pages/AiPlatformPickerPage'
  const pages = JSON.parse(read('entry/src/main/resources/base/profile/main_pages.json')).src
  assert.equal(pages.filter(value => value === route).length, 1)
  const easy = JSON.parse(read('entry/src/main/resources/base/profile/easy_go.json'))
  assert.equal(easy.common.displayModeOptions.routerSplitOptions.fullScreenPages
    .filter(value => value === route).length, 1)
  const picker = read('entry/src/main/ets/pages/AiPlatformPickerPage.ets')
  assert.match(picker, /AiPlatformCatalog\.search/)
  assert.match(picker, /AiPlatformCatalog\.byCategory/)
  assert.match(picker, /AiPlatformSelectionState\.shared\(\)\.select/)
  assert.match(picker, /getRouter\(\)\.back\(\)/)
  // 选择页自己的行为牙：整行点击必须回传目录 id（而不是空串或显示名），三个 tag 分支各锁一条，
  // 搜索框必须是真正的输入控件，空态文案不能被删。原先的 `/本机|需自建网关/` 是整文件 OR，
  // 删掉任一分支仍会绿，故拆成两条独立断言并删除该 OR。
  assert.match(picker, /\.select\(platform\.id\)/)
  assert.ok(picker.includes('本机'))
  assert.ok(picker.includes('需自建网关'))
  assert.ok(picker.includes('云端模型'))
  assert.ok(!picker.includes('未确认视觉模型'))
  assert.match(picker, /TextInput\(/)
  assert.ok(picker.includes('没有匹配的平台'))

  // Task 6 接线（原先延后到这里的两条）：设置页必须能跳到选择页，并靠 peek/take 回传单例取回选择。
  const settings = read('entry/src/main/ets/pages/AiRecognitionSettingsPage.ets')
  assert.match(settings, /pages\/AiPlatformPickerPage/)
  assert.match(settings, /AiPlatformSelectionState\.shared\(\)\.peek\(\)/)
  // 顺序牙：先 peek、再判空/pending 守卫、最后才 take；反序会把用户的选择静默吞掉。
  const show = settings.slice(settings.indexOf('onPageShow()'))
  const peek = show.indexOf('AiPlatformSelectionState.shared().peek()')
  const guard = show.indexOf('selectedId.length === 0')
  const take = show.indexOf('AiPlatformSelectionState.shared().take()')
  assert.ok(peek >= 0 && guard > peek && take > guard, 'onPageShow must peek, guard, then take')
})
