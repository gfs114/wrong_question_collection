const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const vm = require('node:vm')
const { stripTypeScriptTypes } = require('node:module')

const etsRoot = path.resolve(__dirname, '..', 'main', 'ets')

function read(relativePath) {
  const filePath = path.join(etsRoot, relativePath)
  assert.equal(fs.existsSync(filePath), true, `Missing Task 11 source: ${relativePath}`)
  return fs.readFileSync(filePath, 'utf8')
}

function blockAt(source, openingBrace) {
  let depth = 0
  for (let index = openingBrace; index < source.length; index++) {
    if (source[index] === '{') {
      depth += 1
    } else if (source[index] === '}') {
      depth -= 1
      if (depth === 0) {
        return source.slice(openingBrace, index + 1)
      }
    }
  }
  assert.fail('unterminated method body')
}

function methodContaining(source, marker) {
  const markerIndex = source.indexOf(marker)
  assert.notEqual(markerIndex, -1, `missing flow marker ${marker}`)
  const signature = /(?:private|public|protected)?\s*(?:async\s+)?[A-Za-z][A-Za-z0-9_]*\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{/g
  let match = signature.exec(source)
  while (match !== null) {
    const openingBrace = source.indexOf('{', match.index)
    const body = blockAt(source, openingBrace)
    const end = openingBrace + body.length
    if (match.index < markerIndex && end > markerIndex) {
      return source.slice(match.index, end)
    }
    match = signature.exec(source)
  }
  assert.fail(`missing method containing ${marker}`)
}

function assertOrdered(source, fragments) {
  let previousIndex = -1
  for (const fragment of fragments) {
    const index = source.indexOf(fragment, previousIndex + 1)
    assert.notEqual(index, -1, `missing ordered fragment ${fragment}`)
    assert.ok(index > previousIndex, `out of order fragment ${fragment}`)
    previousIndex = index
  }
}

test('setup performs signed-in online PDF preflight and creates a cloud job', () => {
  const setup = read('pages/PdfImportSetupPage.ets')

  assert.match(setup, /AccountSessionService/)
  assert.match(setup, /AccountSessionService\.state\(/)
  assert.match(setup, /signedIn/)
  assert.match(setup, /请先登录华为账号/)
  assert.match(setup, /@kit\.NetworkKit/)
  assert.match(setup, /connection\.(?:hasDefaultNetSync|getDefaultNet)/)
  assert.match(setup, /bankName\.trim\(\)/)
  assert.match(setup, /subject\.trim\(\)/)
  assert.match(setup, /PdfImportValidator\.validatePageRange/)
  assert.match(setup, /(?:fs|fileIo)\.(?:lstat|lstatSync|stat|statSync|access|accessSync|open|openSync)\(/)
  assert.match(setup, /CloudImportService\.createJob/)
  assert.doesNotMatch(setup, /OnDeviceOcrService|PdfImportCoordinator|\bpdfService\b/)
})

test('progress resumes upload and polls cloud jobs with bounded backoff', () => {
  const progress = read('pages/PdfImportProgressPage.ets')

  assert.match(progress, /CloudImportService/)
  assert.match(progress, /CloudImportService\.resumeUpload/)
  assert.match(progress, /CloudImportService\.getJob/)
  assert.match(progress, /1000/)
  assert.match(progress, /2000/)
  assert.match(progress, /4000/)
  assert.match(progress, /5000/)
  assert.match(progress, /上传中/)
  assert.match(progress, /服务器识别中/)
  assert.match(progress, /等待确认/)
  assert.match(progress, /处理失败/)
  assert.match(progress, /已取消/)
  assert.match(progress, /已过期/)
  assert.doesNotMatch(progress, /OnDeviceOcrService|PdfImportCoordinator|\bpdfService\b/)
})

test('inactive progress page stops polling without cancelling the server job', () => {
  const progress = read('pages/PdfImportProgressPage.ets')
  const lifecycleMarker = /aboutToDisappear\s*\(|onPageHide\s*\(/
  const match = progress.match(lifecycleMarker)

  assert.ok(match, 'progress must handle an inactive-page lifecycle')
  const lifecycle = methodContaining(progress, match[0])
  assert.match(lifecycle, /stopPolling|pollingActive\s*=\s*false|clearTimeout|clearInterval/)
  assert.doesNotMatch(lifecycle, /CloudImportService\.cancel|CloudImportApi\.cancel/)
  assert.doesNotMatch(progress, /CloudImportService\.cancel|CloudImportApi\.cancel/)
})

test('cloud import status card exposes unified progress error and retry state', () => {
  const card = read('components/CloudImportStatusCard.ets')

  assert.match(card, /@Component/)
  assert.match(card, /status/)
  assert.match(card, /progressCurrent/)
  assert.match(card, /progressTotal/)
  assert.match(card, /errorMessage/)
  assert.match(card, /retry|重试/i)
  assert.match(card, /服务器识别中/)
})

test('review reads and edits the server draft before confirmation', () => {
  const review = read('services/review/CloudPdfReviewAdapter.ets')
  const page = read('pages/PdfImportReviewPage.ets')

  assert.match(review, /CloudImportService\.getDraft/)
  assert.match(review, /CloudImportDraft/)
  assert.match(review, /CloudImportDraftQuestion/)
  assert.match(review, /ConfirmImportResult/)
  assert.match(review, /CloudImportService\.confirm/)
  assert.match(page, /updateQuestionText/)
  assert.match(page, /updateOption/)
  assert.match(page, /new PdfReviewOption\(option.key, option.key === optionKey \? value : option.value\)/)
  assert.match(page, /updateOption\((?:draftQuestion|question)\.draftQuestionId,\s*option.key,\s*value\)/)
})

test('review downloads verified artifacts before acknowledging only stored IDs', () => {
  const review = read('services/review/CloudPdfReviewAdapter.ets')
  const confirmFlow = methodContaining(review, 'CloudImportService.confirm')
  const downloadFlow = methodContaining(review, 'CloudImportService.downloadArtifact')
  const verificationFlow = methodContaining(review, 'hash.hash')

  assert.match(review, /downloadArtifacts/)
  assert.match(review, /acknowledgeArtifacts/)
  assertOrdered(confirmFlow, [
    'CloudImportService.confirm',
    'state.setConfirmResult(result)',
    'downloadArtifacts',
    'requireAccount(context, accountId)',
    'CloudImportService.acknowledgeArtifacts',
    'state.setCloudStatus(CloudImportStatus.CONFIRMED)'
  ])
  const storedIds = confirmFlow.match(
    /const\s+([A-Za-z][A-Za-z0-9_]*[Aa]rtifactIds)\s*:[^=]+=[\s\S]{0,100}downloadArtifacts/)
  assert.ok(storedIds, 'ACK IDs must come from downloadArtifacts')
  assert.match(confirmFlow, new RegExp(
    `CloudImportService\\.acknowledgeArtifacts[\\s\\S]{0,200}\\b${storedIds[1]}\\b`))
  assert.match(downloadFlow,
    /CloudImportService\.downloadArtifact\([\s\S]{0,400}\.size[\s\S]{0,200}\.sha256/)
  assert.match(downloadFlow, /content\.byteLength\s*!==\s*image\.size/)
  assert.match(downloadFlow, /verifyArtifactFile\(tempPath,\s*image\.size,\s*image\.sha256\)/)
  assert.match(downloadFlow, /verifyArtifactFile\(finalPath,\s*image\.size,\s*image\.sha256\)/)
  assert.match(verificationFlow, /fs\.lstat\(path\)/)
  assert.match(verificationFlow, /fs\.stat\(path\)/)
  assert.match(verificationFlow, /size\s*!==\s*expectedSize/)
  assert.match(verificationFlow, /hash\.hash\(path,\s*'sha256'\)/)
  assert.match(verificationFlow, /actualSha256\s*!==\s*expectedSha256/)
  assert.match(downloadFlow, /question_images|DeviceImageScope\.accountDirectory/)
  assert.match(downloadFlow, /cacheDir|temp/i)
  assert.match(downloadFlow, /fs\.moveFile\(/)
  assertOrdered(downloadFlow, [
    'CloudImportService.downloadArtifact',
    'fs.moveFile',
    'DeviceImageStore.save'
  ])
  assert.match(downloadFlow, /DeviceImageStore\.save\([\s\S]{0,600}savedArtifactIds\.push/)
  assert.match(downloadFlow, /new DeviceQuestionImage\(\s*accountId[\s\S]{0,120}questionId/)
  assert.doesNotMatch(downloadFlow, /acknowledgeArtifacts/)
})

test('review keeps confirmed text when an artifact has expired', () => {
  const review = read('pages/PdfImportReviewPage.ets')

  assert.match(review, /原题图片已过期，文字仍可使用/)
})

test('explicit Cloud abandonment removes only its exact staged PDF before clearing state', () => {
  const source = read('services/review/CloudPdfReviewAdapter.ets')
  const abandon = methodContaining(source, 'async abandon')
  assertOrdered(abandon, ['canAbandon', 'requireAccount', 'removeStagedPdf', 'resetCloudFlow'])
  const cleanup = methodContaining(source, '/^cloud_import_pdf_')
  assert.match(cleanup, /cloud_import_pdf_/)
  assert.match(cleanup, /isDirectChild/)
  assert.match(cleanup, /isSymbolicLink/)
  assert.match(cleanup, /isFile/)
  assert.match(cleanup, /fs\.unlink\(path\)/)
})

function cloudAdapterRuntime() {
  const events = []
  const draft = {
    jobId: 'job-1', status: 'review', bankName: 'math', subject: 'math', expiresAt: 'expiry',
    questions: ['single_choice', 'blank', 'short_answer', 'unknown'].map((type, index) => ({
      draftQuestionId: 'draft-' + index, type, question: ' q ', answer: null, analysis: null,
      options: index === 0 ? { B: 'second', A: 'first' } : null,
      pageStart: 1, pageEnd: 1, confidence: 0.8, reviewRequired: true,
      images: [{ artifactId: 'artifact-1', sha256: 'a'.repeat(64), size: 42, contentType: 'image/jpeg' }]
    }))
  }
  let cached = structuredClone(draft)
  let confirmed = null
  let status = 'review'
  let expired = false
  const state = {
    getCloudJobId: () => 'job-1', getCloudAccountId: () => 'account-1',
    getCloudReviewDraft: () => cached, setCloudReviewDraft: value => { cached = value },
    getConfirmResult: () => confirmed,
    setConfirmResult: value => { events.push('checkpoint'); confirmed = value },
    getCloudStatus: () => status,
    setCloudStatus: value => { events.push(value); status = value },
    getCloudArtifactExpired: () => expired, setCloudArtifactExpired: value => { expired = value }
  }
  const sandbox = {
    PdfImportState: { shared: () => state },
    AccountSessionService: { state: async () => {
      events.push('account')
      return { signedIn: true, userId: 'account-1' }
    } },
    CloudImportService: {
      getDraft: async () => structuredClone(draft),
      confirm: async (_context, _job, request) => {
        events.push('confirm')
        assert.equal(request.questions[0].answer, null)
        return { bankId: 'bank-1', questions: [] }
      },
      acknowledgeArtifacts: async (_context, _job, ids) => {
        events.push('ack')
        assert.deepEqual(Array.from(ids), ['artifact-1'])
      }
    }
  }
  const paths = ['models/ai/AiImportModels.ets', 'models/CloudImportModels.ets',
    'services/review/PdfReviewModels.ets', 'services/review/PdfReviewSession.ets',
    'services/review/CloudPdfReviewAdapter.ets']
  const source = paths.map(file => read(file)
    .replace(/^import\s[\s\S]*?\sfrom\s+['"][^'"]+['"]\s*$/gm, '')
    .replace(/^export\s+/gm, '')).join('\n')
  const adapter = vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) +
    '\nnew CloudPdfReviewAdapter()', sandbox)
  return { adapter, events, draft, cached: () => cached, state }
}

test('Cloud adapter preserves nullable protocol fields and makes independent round-trip copies', async () => {
  const runtime = cloudAdapterRuntime()
  const session = await runtime.adapter.load({})
  assert.deepEqual(Array.from(session.questions, q => q.type),
    ['single_choice', 'blank', 'short_answer', 'unknown'])
  assert.deepEqual(Array.from(session.questions[0].options, o => o.key), ['A', 'B'])
  const image = session.questions[0].images[0]
  assert.equal(image.localPath, '')
  assert.equal(image.remoteArtifactId, 'artifact-1')
  assert.equal(image.sha256, 'a'.repeat(64))
  assert.equal(image.size, 42)
  assert.equal(image.contentType, 'image/jpeg')
  runtime.adapter.persist(session)
  assert.equal(runtime.cached().questions[0].answer, null)
  assert.equal(runtime.cached().questions[0].analysis, null)
  session.questions[0].options[0].value = 'edit'
  session.questions[0].images[0].sha256 = 'changed'
  assert.equal(runtime.cached().questions[0].options.A, 'first')
  assert.equal(runtime.cached().questions[0].images[0].sha256, 'a'.repeat(64))
  const retry = await runtime.adapter.retryPage({}, session, 1)
  retry.questions[0].options[0].value = 'retry mutation'
  assert.equal(session.questions[0].options[0].value, 'edit')
  const discarded = await runtime.adapter.discardFailure({}, session, 1, null)
  assert.equal(JSON.stringify(discarded), JSON.stringify(session))
  discarded.questions[0].images[0].localPath = 'discard mutation'
  assert.equal(session.questions[0].images[0].localPath, '')
})

test('Cloud adapter resumes confirmed text with verified IDs and preserves account/ACK ordering', async () => {
  const runtime = cloudAdapterRuntime()
  const session = await runtime.adapter.load({})
  runtime.events.length = 0
  runtime.adapter.downloadArtifacts = async () => {
    runtime.events.push('download')
    runtime.adapter.requiredArtifactCount = 1
    return ['artifact-1']
  }
  await runtime.adapter.save({}, session)
  assert.deepEqual(runtime.events, ['account', 'confirm', 'checkpoint', 'download', 'account', 'ack', 'confirmed'])
  assert.equal(session.saveStage, 'complete')
  runtime.state.setCloudStatus('review')
  runtime.events.length = 0
  session.saveStage = 'text_saved'
  await runtime.adapter.save({}, session)
  assert.deepEqual(runtime.events, ['account', 'download', 'account', 'ack', 'confirmed'])
})

test('PDF import state retains cloud job metadata progress and review state', () => {
  const state = read('utils/PdfImportState.ets')

  assert.match(state, /jobId/)
  assert.match(state, /bankName/)
  assert.match(state, /subject/)
  assert.match(state, /status/)
  assert.match(state, /progressCurrent/)
  assert.match(state, /progressTotal/)
  assert.match(state, /CloudImportDraft/)
})

test('import bank stages an AI PDF selection and opens only the AI setup page', () => {
  const importBank = read('pages/ImportBankPage.ets')

  assert.match(importBank, /PdfImportService\.selectPdf/)
  assert.match(importBank, /pages\/PdfAiImportSetupPage/)
  assert.doesNotMatch(importBank, /CloudPdfSelection|setCloudSelection/)
  assert.doesNotMatch(importBank, /pages\/PdfImportSetupPage/)
  assert.doesNotMatch(importBank,
    /OnDeviceOcrService|PdfImportCoordinator|PdfDocumentService|\bpdfService\b/)
})
