const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const { stripTypeScriptTypes } = require('node:module')

// Execute the production save lifecycle and memory store with only IO ports replaced.
function createRuntime() {
  const paths = [
    'entry/src/main/ets/models/Question.ets',
    'entry/src/main/ets/models/QuestionBank.ets',
    'entry/src/main/ets/services/review/PdfReviewModels.ets',
    'entry/src/main/ets/services/review/PdfReviewSession.ets',
    'entry/src/main/ets/services/ai/AiImportSaveService.ets'
  ]
  const source = paths.map(path => fs.readFileSync(path, 'utf8')
    .replace(/^import\s[\s\S]*?\sfrom\s+['"][^'"]+['"]\s*$/gm, '')
    .replace(/^export\s+/gm, '')).join('\n')
  const counts = { bank: 0, image: 0, cleanup: 0, prefix: 0, preflight: 0,
    checkpointSave: 0, remove: 0 }
  const deleted = new Set()
  const prefixDebts = new Map()
  const cleanupEvents = []
  let prefixFailures = 0
  let failAccountAfterPdf = 0
  let pendingPostPdfAccountFailure = false
  let checkpointRemoveFailures = 0
  class FakePdfPageImageEncoder {
    async cleanupSession(_context, sessionId) {
      counts.prefix++
      cleanupEvents.push('prefix:' + sessionId)
      if (!/^[A-Za-z0-9._:-]{1,160}$/.test(sessionId)) throw new Error('invalid session')
      if (prefixFailures > 0) { prefixFailures--; throw new Error('prefix cleanup failed') }
      prefixDebts.delete(sessionId)
    }
  }
  const sandbox = {
    AiQuestionType: { BLANK: 'blank', SINGLE_CHOICE: 'single_choice' },
    PdfPageImageEncoder: FakePdfPageImageEncoder,
    AccountSessionService: {
      async runExpectedAccountLocalExclusive(_context, _accountId, action) { return action() }
    },
    PdfImportService: {
      async removeTemporaryPdf(path) {
        cleanupEvents.push('pdf:' + path)
        if (deleted.has(path)) throw new Error('PDF already deleted')
        deleted.add(path)
        if (failAccountAfterPdf > 0) {
          failAccountAfterPdf--
          pendingPostPdfAccountFailure = true
        }
      },
      async proveTemporaryPdfAbsent(cacheDir, path) {
        cleanupEvents.push('pdf-absent-proof:' + path)
        if (cacheDir !== '/cache' || !/^\/cache\/staged_pdf_[0-9]+\.pdf$/.test(path) ||
          !deleted.has(path)) {
          throw new Error('PDF absence not proven')
        }
        return true
      },
      async removeRecoveredTemporaryPdf(_cacheDir, path) {
        cleanupEvents.push('recovered-pdf:' + path)
        deleted.add(path)
      }
    }
  }
  const runtime = vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) +
    '\n({ AiImportSaveService, PdfReviewSessionStore, DefaultAiImportBankWriter, ' +
    'DefaultAiImportImageWriter, DefaultAiImportAccount, DefaultAiImportCheckpoint, ' +
    'DefaultAiImportCacheCleanup, DefaultAiImportImagePreflight })', sandbox)
  const durable = new Map()
  let activeAccount = 'account-1'
  let bankHook = async () => {}
  const copy = session => runtime.PdfReviewSessionStore.copyOf(session)
  runtime.DefaultAiImportAccount.prototype.require = async (_context, expected) => {
    if (pendingPostPdfAccountFailure) {
      pendingPostPdfAccountFailure = false
      throw new Error('post PDF account failure')
    }
    if (activeAccount !== expected) throw new Error('account mismatch')
  }
  runtime.DefaultAiImportCheckpoint.prototype.load = async (_context, id) =>
    durable.has(id) ? copy(durable.get(id)) : null
  runtime.DefaultAiImportCheckpoint.prototype.save = async (_context, session) => {
    counts.checkpointSave++
    durable.set(session.sessionId, copy(session))
  }
  runtime.DefaultAiImportCheckpoint.prototype.remove = async (_context, id) => {
    cleanupEvents.push('checkpoint-remove:' + id)
    if (checkpointRemoveFailures > 0) {
      checkpointRemoveFailures--
      throw new Error('checkpoint remove failure')
    }
    counts.remove++
    durable.delete(id)
  }
  runtime.DefaultAiImportBankWriter.prototype.write = async () => {
    counts.bank++
    await bankHook()
  }
  runtime.DefaultAiImportImageWriter.prototype.write = async () => { counts.image++ }
  runtime.DefaultAiImportImagePreflight.prototype.preflight = async (_context, session) => {
    counts.preflight++
    for (const question of session.questions) {
      for (const image of question.images) {
        if (deleted.has(image.localPath)) throw new Error('source already deleted')
      }
    }
    return copy(session)
  }
  const defaultCleanup = runtime.DefaultAiImportCacheCleanup.prototype.cleanup
  runtime.DefaultAiImportCacheCleanup.prototype.cleanup = async function (context, session,
    recoveredCheckpoint) {
    counts.cleanup++
    return defaultCleanup.call(this, context, session, recoveredCheckpoint)
  }
  runtime.AiImportSaveService.removeOwnedSessionFile = async (_cacheDir, _sessionId, path) => {
    cleanupEvents.push('referenced:' + path)
    deleted.add(path)
  }
  const context = { cacheDir: '/cache', filesDir: '/files' }
  return {
    ...runtime, counts, durable, copy, context, cleanupEvents, prefixDebts, deleted,
    save: session => runtime.AiImportSaveService.save(context, session),
    setAccount: value => { activeAccount = value },
    setBankHook: value => { bankHook = value },
    setPrefixFailures: value => { prefixFailures = value },
    setFailAccountAfterPdf: value => { failAccountAfterPdf = value },
    setCheckpointRemoveFailures: value => { checkpointRemoveFailures = value },
    addPrefixDebt: (sessionId, name) => {
      const current = prefixDebts.get(sessionId) || new Set()
      current.add(name); prefixDebts.set(sessionId, current)
    }
  }
}

function fixture(id = 'repeat-save') {
  return {
    sessionId: id, source: 'ai', bankUuid: '22222222-2222-4222-8222-222222222222',
    bankName: 'Math', subject: 'Math', accountId: 'account-1', saveStage: 'draft',
    pdfPath: '/cache/' + id + '.pdf',
    questions: [{
      draftQuestionId: id + ':1:0', questionUuid: '11111111-1111-4111-8111-111111111111',
      label: '1', type: 'blank', question: '1 + 1', options: [], answer: '2', analysis: '',
      pageStart: 1, pageEnd: 1, confidence: 1, reviewRequired: false,
      images: [{ remoteArtifactId: '', localPath: '/cache/ai_import_crop_' + id + '~1.jpg',
        sha256: 'a'.repeat(64), size: 10, contentType: 'image/jpeg', sortOrder: 0 }]
    }],
    failures: [{ pageNumber: 2, code: 'invalid_json', message: '', evidencePath: '/cache/evidence.jpg' }]
  }
}

function assertClean(session) {
  assert.equal(session.saveStage, 'complete')
  assert.equal(session.pdfPath, '')
  assert.equal(session.questions[0].images[0].localPath, '')
  assert.equal(session.failures[0].evidencePath, '')
}

function assertOneLifecycle(runtime) {
  assert.deepEqual(runtime.counts,
    { bank: 1, image: 1, cleanup: 1, prefix: 1, preflight: 2, checkpointSave: 3, remove: 1 })
}

test('public save can repeat with the same supplied session after cleanup without IO replay', async () => {
  const runtime = createRuntime()
  const session = fixture()
  const first = await runtime.save(session)
  assertClean(first)
  const second = await runtime.save(session)
  assertClean(session)
  assertClean(second)
  assertOneLifecycle(runtime)
  second.questions[0].images[0].localPath = 'mutated result'
  session.questions[0].question = 'mutated caller'
  assert.equal(first.questions[0].images[0].localPath, '')
  const stored = runtime.PdfReviewSessionStore.get(session.sessionId)
  assertClean(stored)
  assert.equal(stored.questions[0].question, '1 + 1')
})

test('two queued stale DRAFT public saves execute exactly one complete lifecycle', async () => {
  const runtime = createRuntime()
  const firstInput = fixture()
  const secondInput = runtime.copy(firstInput)
  let release
  let entered
  const gate = new Promise(resolve => { release = resolve })
  const started = new Promise(resolve => { entered = resolve })
  runtime.setBankHook(async () => { entered(); await gate })
  const firstSave = runtime.save(firstInput)
  await started
  const secondSave = runtime.save(secondInput)
  release()
  const [first, second] = await Promise.all([firstSave, secondSave])
  assertClean(first)
  assertClean(second)
  assertClean(firstInput)
  assertClean(secondInput)
  assert.equal(JSON.stringify(first), JSON.stringify(second))
  assertOneLifecycle(runtime)
})

test('COMPLETE without durable or memory state is sanitized without another cleanup', async () => {
  const runtime = createRuntime()
  const session = fixture()
  session.saveStage = 'complete'
  const result = await runtime.save(session)
  assertClean(result)
  assertClean(session)
  assert.deepEqual(runtime.counts,
    { bank: 0, image: 0, cleanup: 0, prefix: 0, preflight: 0, checkpointSave: 0, remove: 0 })
})

test('draft abandon prefix-cleans unreferenced failed-attempt debt before releasing ownership', async () => {
  const runtime = createRuntime()
  const session = fixture('abandon-prefix')
  runtime.PdfReviewSessionStore.put(runtime.copy(session))
  runtime.addPrefixDebt(session.sessionId,
    'ai_import_crop_' + session.sessionId + '~attempt~failed~unreferenced.jpg')
  await runtime.AiImportSaveService.abandon(runtime.context, session)
  assert.equal(runtime.prefixDebts.has(session.sessionId), false)
  assert.equal(runtime.PdfReviewSessionStore.get(session.sessionId), null)
  const prefix = runtime.cleanupEvents.indexOf('prefix:' + session.sessionId)
  const pdf = runtime.cleanupEvents.indexOf('pdf:' + session.pdfPath)
  const checkpoint = runtime.cleanupEvents.indexOf('checkpoint-remove:' + session.sessionId)
  assert.ok(prefix >= 0 && pdf > prefix && checkpoint > pdf)
})

test('COMPLETE save prefix-cleans post-commit superseded debt before checkpoint release', async () => {
  const runtime = createRuntime()
  const session = fixture('save-prefix')
  runtime.addPrefixDebt(session.sessionId,
    'ai_import_page_' + session.sessionId + '~attempt~superseded~1.jpg')
  const result = await runtime.save(session)
  assertClean(result)
  assert.equal(runtime.prefixDebts.has(session.sessionId), false)
  const prefix = runtime.cleanupEvents.indexOf('prefix:' + session.sessionId)
  const pdf = runtime.cleanupEvents.indexOf('pdf:/cache/' + session.sessionId + '.pdf')
  const checkpoint = runtime.cleanupEvents.indexOf('checkpoint-remove:' + session.sessionId)
  assert.ok(prefix >= 0 && pdf > prefix && checkpoint > pdf)
})

test('save prefix cleanup failure preserves checkpoint memory and PDF for terminal retry', async () => {
  const runtime = createRuntime()
  const session = fixture('save-prefix-retry')
  runtime.addPrefixDebt(session.sessionId,
    'ai_import_crop_' + session.sessionId + '~attempt~retry~old.jpg')
  runtime.setPrefixFailures(1)
  await assert.rejects(runtime.save(session), /AI 导入会话缓存清理失败/)
  assert.equal(runtime.durable.get(session.sessionId).pdfPath,
    '/cache/' + session.sessionId + '.pdf')
  assert.equal(runtime.PdfReviewSessionStore.get(session.sessionId).pdfPath,
    '/cache/' + session.sessionId + '.pdf')
  assert.equal(runtime.cleanupEvents.some(value => value.startsWith('pdf:')), false)
  assert.equal(runtime.counts.remove, 0)
  assertClean(await runtime.save(session))
  assert.equal(runtime.prefixDebts.has(session.sessionId), false)
  assert.equal(runtime.counts.prefix, 2)
  assert.equal(runtime.counts.remove, 1)
})

test('abandon prefix cleanup failure preserves draft memory and PDF for terminal retry', async () => {
  const runtime = createRuntime()
  const session = fixture('abandon-prefix-retry')
  runtime.PdfReviewSessionStore.put(runtime.copy(session))
  runtime.addPrefixDebt(session.sessionId,
    'ai_import_page_' + session.sessionId + '~attempt~retry~1.jpg')
  runtime.setPrefixFailures(1)
  await assert.rejects(runtime.AiImportSaveService.abandon(runtime.context, session),
    /AI 导入会话缓存清理失败/)
  assert.equal(runtime.PdfReviewSessionStore.get(session.sessionId).pdfPath, session.pdfPath)
  assert.equal(runtime.cleanupEvents.some(value => value.startsWith('pdf:')), false)
  assert.equal(runtime.counts.remove, 0)
  await runtime.AiImportSaveService.abandon(runtime.context, session)
  assert.equal(runtime.PdfReviewSessionStore.get(session.sessionId), null)
  assert.equal(runtime.prefixDebts.has(session.sessionId), false)
  assert.equal(runtime.counts.prefix, 2)
})

test('COMPLETE save retries after PDF deletion and a post-cleanup account failure', async () => {
  const runtime = createRuntime()
  const session = fixture('save-post-pdf-account')
  session.pdfPath = '/cache/staged_pdf_1001.pdf'
  const pdfPath = session.pdfPath
  runtime.setFailAccountAfterPdf(1)

  await assert.rejects(runtime.save(session), /post PDF account failure/)
  assert.equal(runtime.deleted.has(pdfPath), true)
  assert.equal(runtime.durable.get(session.sessionId).pdfPath, pdfPath)
  assert.equal(runtime.PdfReviewSessionStore.get(session.sessionId).pdfPath, pdfPath)
  assert.equal(runtime.counts.remove, 0)

  const result = await runtime.save(session)
  assertClean(result)
  assert.equal(runtime.cleanupEvents.filter(value => value === 'pdf:' + pdfPath).length, 2)
  assert.equal(runtime.cleanupEvents.filter(
    value => value === 'pdf-absent-proof:' + pdfPath).length, 1)
  assert.equal(runtime.cleanupEvents.some(value => value.startsWith('recovered-pdf:')), false)
  assert.equal(runtime.counts.remove, 1)
})

test('abandon retries after PDF deletion and a post-cleanup checkpoint failure', async () => {
  const runtime = createRuntime()
  const session = fixture('abandon-post-pdf-checkpoint')
  session.pdfPath = '/cache/staged_pdf_1002.pdf'
  runtime.PdfReviewSessionStore.put(runtime.copy(session))
  runtime.setCheckpointRemoveFailures(1)

  await assert.rejects(runtime.AiImportSaveService.abandon(runtime.context, session),
    /checkpoint remove failure/)
  assert.equal(runtime.deleted.has(session.pdfPath), true)
  assert.equal(runtime.PdfReviewSessionStore.get(session.sessionId).pdfPath, session.pdfPath)
  assert.equal(runtime.counts.remove, 0)

  await runtime.AiImportSaveService.abandon(runtime.context, session)
  assert.equal(runtime.PdfReviewSessionStore.get(session.sessionId), null)
  assert.equal(runtime.cleanupEvents.filter(value => value === 'pdf:' + session.pdfPath).length, 2)
  assert.equal(runtime.cleanupEvents.filter(
    value => value === 'pdf-absent-proof:' + session.pdfPath).length, 1)
  assert.equal(runtime.cleanupEvents.some(value => value.startsWith('recovered-pdf:')), false)
  assert.equal(runtime.counts.remove, 1)
})

test('completed memory rejects another active account and incompatible caller ownership', async () => {
  const runtime = createRuntime()
  const session = fixture()
  await runtime.save(session)
  const before = { ...runtime.counts }
  runtime.setAccount('account-2')
  await assert.rejects(runtime.save(session), /account mismatch/)
  const otherAccount = fixture()
  otherAccount.accountId = 'account-2'
  await assert.rejects(runtime.save(otherAccount))
  runtime.setAccount('account-1')
  const otherBank = fixture()
  otherBank.bankUuid = '33333333-3333-4333-8333-333333333333'
  await assert.rejects(runtime.save(otherBank))
  assert.deepEqual(runtime.counts, before)
  assertClean(runtime.PdfReviewSessionStore.get(session.sessionId))
})

test('an unrelated session progresses while the first public save is blocked', async () => {
  const runtime = createRuntime()
  let release
  let entered
  const gate = new Promise(resolve => { release = resolve })
  const started = new Promise(resolve => { entered = resolve })
  runtime.setBankHook(async () => {
    if (runtime.counts.bank === 1) { entered(); await gate }
  })
  const first = runtime.save(fixture())
  await started
  const second = await runtime.save(fixture('independent-save'))
  assertClean(second)
  release()
  assertClean(await first)
  assert.equal(runtime.counts.bank, 2)
})

test('a mismatched durable session id is rejected before cleanup or publication', async () => {
  const runtime = createRuntime()
  const session = fixture()
  const mismatched = fixture('different-session')
  mismatched.saveStage = 'complete'
  runtime.durable.set(session.sessionId, mismatched)
  await assert.rejects(runtime.save(session))
  assert.equal(runtime.counts.cleanup, 0)
  assert.equal(runtime.counts.remove, 0)
  assert.equal(runtime.PdfReviewSessionStore.get(session.sessionId), null)
})

test('a terminal caller without memory still requires its owning account', async () => {
  const runtime = createRuntime()
  const session = fixture()
  session.saveStage = 'complete'
  runtime.setAccount('account-2')
  await assert.rejects(runtime.save(session), /account mismatch/)
  assert.equal(session.pdfPath, '/cache/repeat-save.pdf')
  assert.equal(runtime.counts.cleanup, 0)
  assert.equal(runtime.PdfReviewSessionStore.get(session.sessionId), null)
})
