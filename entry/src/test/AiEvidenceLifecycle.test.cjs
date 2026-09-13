const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const { stripTypeScriptTypes } = require('node:module')

function pathsOf(session) {
  if (!session) return []
  return [...new Set(session.questions.flatMap(question =>
    question.images.map(image => image.localPath)).concat(
    session.failures.map(failure => failure.evidencePath)).filter(Boolean))].sort()
}

function createFixture() {
  const source = ['services/review/PdfReviewModels.ets', 'services/review/PdfReviewSession.ets',
    'services/ai/PdfAiImportCoordinator.ets'].map(path =>
    fs.readFileSync('entry/src/main/ets/' + path, 'utf8')
      .replace(/^import\s[\s\S]*?\sfrom\s+['"][^'"]+['"]\s*$/gm, '')
      .replace(/^export\s+/gm, '')).join('\n')
  let sequence = 0
  const codes = { INVALID_JSON: 'invalid_json', NO_QUESTIONS: 'no_questions', CANCELLED: 'cancelled' }
  const runtime = vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) +
    '\n({ PdfAiImportCoordinator, PdfReviewSessionStore })', {
    util: { generateRandomUUID: () => '00000000-0000-4000-8000-' +
      String(++sequence).padStart(12, '0') },
    AiImportErrorCode: codes,
    AiImportError: class extends Error { constructor(code) { super(code); this.code = code } },
    AiProviderConfigValidator: { normalize: config => config },
    MathQuestionPromptBuilder: { build: () => 'prompt' }
  })
  const ledger = new Map()
  const exactCleanups = []
  let crops = [true, true]
  let parseFails = false
  let failCleanup = ''
  let failWholePageCleanup = false
  let sharedCropPath = ''
  const renderSession = {
    pageCount: () => 2,
    close: () => {},
    encodePage: async (_context, page, session, attempt) => {
      const path = '/cache/ai_import_page_' + session + '~attempt~' + attempt + '~' + (page + 1) + '.jpg'
      assert.equal(ledger.has(path), false, 'unique attempt page path')
      ledger.set(path, { session, attempt, kind: 'page' })
      return { jpegBase64: 'jpeg', evidencePath: path, releaseTransientText: () => {} }
    },
    cropEvidence: async (_context, page, session, question, box, attempt) => {
      if (sharedCropPath) return sharedCropPath
      const path = '/cache/ai_import_crop_' + session + '~attempt~' + attempt + '~' + question + '.jpg'
      assert.equal(ledger.has(path), false, 'unique attempt crop path')
      ledger.set(path, { session, attempt, kind: 'crop' })
      return path
    }
  }
  const renderer = {
    open: () => renderSession,
    cleanupEvidence: async (_context, session, path) => {
      exactCleanups.push({ path, storedPaths: pathsOf(runtime.PdfReviewSessionStore.get(session)) })
      if (path === failCleanup || (failWholePageCleanup && path.includes('ai_import_page_'))) {
        throw new Error('exact cleanup failed')
      }
      ledger.delete(path)
    },
    cleanupAttempt: async (_context, session, attempt) => {
      for (const [path, entry] of ledger) {
        if (entry.session === session && entry.attempt === attempt) ledger.delete(path)
      }
    },
    cleanupAttemptCrops: async (_context, session, attempt) => {
      for (const [path, entry] of ledger) {
        if (entry.session === session && entry.attempt === attempt && entry.kind === 'crop') ledger.delete(path)
      }
    }
  }
  const parser = { parse: () => {
    if (parseFails) throw new Error('parse failure')
    return crops.map((bboxUsable, index) => ({ bboxUsable, bbox: {}, options: [], label: String(index),
      type: 'blank', question: 'question-' + sequence + '-' + index, answer: '', analysis: '' }))
  } }
  const coordinator = new runtime.PdfAiImportCoordinator(renderer,
    { run: (_context, action) => action.execute(new Uint8Array([1])) },
    { buildRequest: () => ({ endpoint: 'fake', body: '', release: () => {} }),
      extractAssistantContent: () => 'content' },
    { postJson: async () => 'response', cancel: () => {} }, parser,
    { remove: async () => {} })
  const request = { sessionId: 'evidence-session', accountId: 'account-1', pdfPath: '/cache/input.pdf',
    config: {}, settings: { startPage: 1, endPage: 1, bankName: 'bank', subject: 'math' } }
  return { ...runtime, ledger, exactCleanups,
    discardFailure: (session, page, replacement = null) =>
      coordinator.discardFailure({}, session, page, replacement),
    run: () => coordinator.run({}, request, () => {}),
    retry: session => coordinator.retryPage({}, session, 1, {}),
    setCrops: value => { crops = value }, setParseFailure: value => { parseFails = value },
    setCleanupFailure: value => { failCleanup = value },
    setWholePageCleanupFailure: value => { failWholePageCleanup = value },
    setSharedCropPath: value => { sharedCropPath = value }
  }
}

async function failedPageFixture() {
  const fixture = createFixture()
  fixture.setParseFailure(true)
  const session = await fixture.run()
  assert.equal(session.failures.length, 1)
  assert.ok(session.failures[0].evidencePath)
  return { fixture, session, path: session.failures[0].evidencePath }
}

test('explicit failure discard deletes unreferenced evidence once before removing the failure', async () => {
  const { fixture, session, path } = await failedPageFixture()
  const updated = await fixture.discardFailure(session, 1)
  assert.equal(updated.failures.length, 0)
  assert.equal(fixture.ledger.has(path), false)
  assert.equal(fixture.exactCleanups.filter(event => event.path === path).length, 1)
  assert.deepEqual(fixture.exactCleanups[0].storedPaths, [path])
  await fixture.discardFailure(session, 1)
  assert.equal(fixture.exactCleanups.filter(event => event.path === path).length, 1)
})

test('failure discard cleanup failure retains the published failure and evidence for retry', async () => {
  const { fixture, session, path } = await failedPageFixture()
  fixture.setCleanupFailure(path)
  await assert.rejects(fixture.discardFailure(session, 1))
  assert.equal(fixture.ledger.has(path), true)
  assert.equal(fixture.PdfReviewSessionStore.get(session.sessionId).failures.length, 1)
  assert.equal(session.failures.length, 1)
})

test('manual question transfer publishes one coherent session without deleting transferred evidence', async () => {
  const { fixture, session, path } = await failedPageFixture()
  const replacement = {
    draftQuestionId: 'manual', questionUuid: '11111111-1111-4111-8111-111111111111',
    label: '', type: 'unknown', question: '', options: [], answer: '', analysis: '',
    pageStart: 1, pageEnd: 1, confidence: 0, reviewRequired: true,
    images: [{ remoteArtifactId: '', localPath: path, sha256: '', size: 0, contentType: 'image/jpeg', sortOrder: 0 }]
  }
  const publications = []
  const put = fixture.PdfReviewSessionStore.put
  fixture.PdfReviewSessionStore.put = value => { publications.push(value); put(value) }
  const updated = await fixture.discardFailure(session, 1, replacement)
  assert.equal(publications.length, 1)
  assert.equal(updated.questions.length, 1)
  assert.equal(updated.failures.length, 0)
  assert.equal(updated.questions[0].questionUuid, replacement.questionUuid)
  assert.equal(fixture.ledger.has(path), true)
  assert.equal(fixture.exactCleanups.length, 0)
  replacement.images[0].localPath = 'mutated'
  assert.equal(fixture.PdfReviewSessionStore.get(session.sessionId).questions[0].images[0].localPath, path)
})

test('manual transfer publication failure leaves the original failure and evidence intact', async () => {
  const { fixture, session, path } = await failedPageFixture()
  const replacement = {
    draftQuestionId: 'manual', questionUuid: '11111111-1111-4111-8111-111111111111',
    label: '', type: 'unknown', question: '', options: [], answer: '', analysis: '',
    pageStart: 1, pageEnd: 1, confidence: 0, reviewRequired: true, images: []
  }
  fixture.PdfReviewSessionStore.put = () => { throw new Error('publication failed') }
  await assert.rejects(fixture.discardFailure(session, 1, replacement), /publication failed/)
  const stored = fixture.PdfReviewSessionStore.get(session.sessionId)
  assert.equal(stored.questions.length, 0)
  assert.equal(stored.failures.length, 1)
  assert.equal(stored.failures[0].evidencePath, path)
  assert.equal(fixture.ledger.has(path), true)
  assert.equal(fixture.exactCleanups.length, 0)
})

test('discard deduplicates obsolete paths and retains shared question or other failure evidence', async () => {
  const first = await failedPageFixture()
  first.session.failures.push({ ...first.session.failures[0] })
  first.fixture.PdfReviewSessionStore.put(first.session)
  await first.fixture.discardFailure(first.session, 1)
  assert.equal(first.fixture.exactCleanups.length, 1)
  const second = await failedPageFixture()
  second.session.failures.push({ ...second.session.failures[0], pageNumber: 2 })
  second.fixture.PdfReviewSessionStore.put(second.session)
  const updated = await second.fixture.discardFailure(second.session, 1)
  assert.equal(updated.failures.length, 1)
  assert.equal(second.fixture.ledger.has(second.path), true)
  assert.equal(second.fixture.exactCleanups.length, 0)
  const third = await failedPageFixture()
  third.session.questions.push({
    draftQuestionId: 'other', questionUuid: '11111111-1111-4111-8111-111111111111',
    label: '', type: 'unknown', question: 'shared', options: [], answer: '', analysis: '',
    pageStart: 2, pageEnd: 2, confidence: 0, reviewRequired: true,
    images: [{ remoteArtifactId: '', localPath: third.path, sha256: '', size: 0,
      contentType: 'image/jpeg', sortOrder: 0 }]
  })
  third.fixture.PdfReviewSessionStore.put(third.session)
  const retained = await third.fixture.discardFailure(third.session, 1)
  assert.equal(retained.failures.length, 0)
  assert.equal(retained.questions.length, 1)
  assert.equal(third.fixture.ledger.has(third.path), true)
  assert.equal(third.fixture.exactCleanups.length, 0)
})

test('all-crop success deletes the unused whole-page JPEG before publishing the page', async () => {
  const fixture = createFixture()
  const session = await fixture.run()
  assert.equal(session.questions.length, 2)
  assert.deepEqual([...fixture.ledger.keys()].sort(), pathsOf(session))
  assert.equal(fixture.exactCleanups.length, 1)
  assert.match(fixture.exactCleanups[0].path, /ai_import_page_/)
  assert.deepEqual(fixture.exactCleanups[0].storedPaths, [])
})

test('mixed crop and full-page questions retain the referenced whole-page JPEG', async () => {
  const fixture = createFixture()
  fixture.setCrops([true, false])
  const session = await fixture.run()
  assert.deepEqual([...fixture.ledger.keys()].sort(), pathsOf(session))
  assert.equal(fixture.exactCleanups.length, 0)
})

test('successful retries replace every old image only after new questions are stored', async () => {
  const fixture = createFixture()
  fixture.setCrops([false, false])
  let session = await fixture.run()
  for (let iteration = 0; iteration < 4; iteration++) {
    const oldPaths = pathsOf(session)
    fixture.setCrops([true, true])
    session = await fixture.retry(session)
    assert.deepEqual([...fixture.ledger.keys()].sort(), pathsOf(session))
    for (const oldPath of oldPaths) {
      const deletions = fixture.exactCleanups.filter(event => event.path === oldPath)
      assert.equal(deletions.length, 1)
      assert.deepEqual(deletions[0].storedPaths, pathsOf(session))
    }
  }
})

test('duplicate old question and failure evidence is deleted once, excluding paths still referenced', async () => {
  const fixture = createFixture()
  fixture.setCrops([false, false])
  let session = await fixture.run()
  const oldPath = session.questions[0].images[0].localPath
  session.failures.push({ pageNumber: 1, code: 'invalid_json', message: '', evidencePath: oldPath })
  fixture.PdfReviewSessionStore.put(session)
  session = await fixture.retry(session)
  assert.equal(fixture.exactCleanups.filter(event => event.path === oldPath).length, 1)
  const sharedPath = session.questions[0].images[0].localPath
  fixture.setCrops([true, true])
  fixture.setSharedCropPath(sharedPath)
  session = await fixture.retry(session)
  assert.equal(fixture.exactCleanups.filter(event => event.path === sharedPath).length, 0)
  assert.deepEqual([...fixture.ledger.keys()].sort(), pathsOf(session))
})

test('an old image shared with an unchanged page survives a successful retry', async () => {
  const fixture = createFixture()
  fixture.setCrops([false])
  let session = await fixture.run()
  const extra = fixture.PdfReviewSessionStore.copyOf(session).questions[0]
  extra.pageStart = 2
  extra.pageEnd = 2
  extra.draftQuestionId = 'evidence-session:2:0'
  extra.questionUuid = '11111111-1111-4111-8111-111111111111'
  session.questions.push(extra)
  fixture.PdfReviewSessionStore.put(session)
  const sharedPath = extra.images[0].localPath
  fixture.setCrops([true])
  session = await fixture.retry(session)
  assert.equal(fixture.exactCleanups.filter(event => event.path === sharedPath).length, 0)
  assert.deepEqual([...fixture.ledger.keys()].sort(), pathsOf(session))
})

test('failed retry cleans only the new attempt and keeps old questions and evidence', async () => {
  const fixture = createFixture()
  fixture.setCrops([false, false])
  const session = await fixture.run()
  const before = JSON.stringify(fixture.PdfReviewSessionStore.get(session.sessionId))
  fixture.setParseFailure(true)
  await assert.rejects(fixture.retry(session))
  assert.equal(JSON.stringify(fixture.PdfReviewSessionStore.get(session.sessionId)), before)
  assert.deepEqual([...fixture.ledger.keys()].sort(), pathsOf(session))
  assert.equal(fixture.exactCleanups.length, 0)
})

test('unused whole-page cleanup failure fails and cleans the page attempt', async () => {
  const fixture = createFixture()
  fixture.setWholePageCleanupFailure(true)
  const session = await fixture.run()
  assert.equal(session.questions.length, 0)
  assert.equal(session.failures.length, 1)
  assert.equal(session.failures[0].evidencePath, '')
  assert.equal(fixture.ledger.size, 0)
})

test('post-commit old-image cleanup failure preserves new state and surfaces a diagnostic', async () => {
  const fixture = createFixture()
  fixture.setCrops([false])
  const original = await fixture.run()
  const oldPath = pathsOf(original)[0]
  fixture.setCrops([true])
  fixture.setCleanupFailure(oldPath)
  await assert.rejects(fixture.retry(original), /清理失败/)
  const stored = fixture.PdfReviewSessionStore.get(original.sessionId)
  assert.notEqual(stored.questions[0].question, original.questions[0].question)
  assert.equal(pathsOf(stored).includes(oldPath), false)
  assert.equal(fixture.ledger.has(pathsOf(stored)[0]), true)
})
