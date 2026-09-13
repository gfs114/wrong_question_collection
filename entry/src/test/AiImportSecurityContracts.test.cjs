const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')

test('AI settings never decrypt or redisplay a saved key and clear typed state on every operation', () => {
  const path = 'entry/src/main/ets/pages/AiRecognitionSettingsPage.ets'
  assert.ok(fs.existsSync(path), 'settings page must exist')
  const page = read(path)
  assert.doesNotMatch(page, /getCredential|withCredential|\.message|\.stack|console\.|hilog\.|slice\(-|substring\(/)
  assert.match(page, /AiImportErrorMessages\.forCode/)
  assert.match(page, /AiCredentialStore\.hasCredential/)
  assert.match(page, /••••••••（已安全保存）/)
  assert.match(page, /更换 API Key/)
  assert.doesNotMatch(page, /this\.apiKey\s*=\s*['"]••••••••/,
    'the display-only mask must never enter the typed credential state')
  for (const name of ['private async loadSettings', 'private async saveSettings', 'private async clearApiKey']) {
    const body = extractMethod(page, name)
    assert.match(body, /finally[\s\S]*this\.apiKey = ''[\s\S]*this\.showKey = false/)
    assert.match(body, /this\.pending/)
  }
  const testBody = extractMethod(page, 'private async testConnection')
  assert.match(testBody, /this\.apiKey\.trim\(\)\.length > 0[\s\S]*testWithApiKey/)
  assert.doesNotMatch(testBody, /请先保存新 API Key/)
  assert.match(testBody, /this\.formConfig\(\)/)
  assert.match(testBody, /requireUsable[\s\S]*hasCredential[\s\S]*\.test\(/)
  assert.match(testBody, /if \(this\.pending\) return/)
  assert.match(page, /onBackPress\(\)[\s\S]*this\.pending/)
  assert.match(page, /InputType\.Password/)

  const modelService = read('entry/src/main/ets/services/ai/AiModelCatalogService.ets')
  assert.match(modelService, /fetchWithSavedCredential[\s\S]*AiCredentialStore\.withCredential/)
  assert.doesNotMatch(modelService, /TextDecoder|credential\.toString/)
})

test('connection test uses saved credential scope and releases temporary body and response', () => {
  const path = 'entry/src/main/ets/services/ai/AiConnectionTestService.ets'
  assert.ok(fs.existsSync(path), 'connection service must exist')
  const source = read(path)
  assert.match(source, /AiCredentialStore\.withCredential/)
  assert.match(source, /async testWithApiKey[\s\S]*TextEncoder[\s\S]*credential\.fill\(0\)/)
  assert.match(source, /finally[\s\S]*request\.release\(\)[\s\S]*raw = ''/)
  assert.doesNotMatch(source, /AiQuestionResponseParser|setTimeout|setInterval|console\.|hilog\./)
  assert.equal((source.match(/\.extractAssistantContent\(raw\)/g) || []).length, 1)
  assert.match(source, /postJson[\s\S]*extractAssistantContent\(raw\)[\s\S]*finally/)
  assert.equal((source.match(/\.postJson\(/g) || []).length, 1)
  assert.match(source, /withUsableConfig[\s\S]*AiCredentialStore\.withCredential/)
})

test('production AI retry and credential dispatch require persisted usable config', () => {
  const retry = read('entry/src/main/ets/services/review/AiPdfReviewAdapter.ets')
  const coordinator = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const page = read('entry/src/main/ets/pages/AiRecognitionSettingsPage.ets')
  assert.match(retry, /AiProviderConfigStore\.loadUsable\(context\)/)
  assert.match(coordinator, /withUsableConfig[\s\S]*AiCredentialStore\.withCredential/)
  assert.match(extractMethod(page, 'private async testConnection'), /requireUsable[\s\S]*hasCredential/)
  assert.match(extractMethod(page, 'private async saveSettings'), /beginCredentialUpdate[\s\S]*AiProviderConfigStore\.save[\s\S]*AiCredentialStore\.save[\s\S]*completeCredentialUpdate/)
})

function read(path) {
  return fs.readFileSync(path, 'utf8')
}

function sourceFiles(root) {
  const values = []
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const path = `${root}/${entry.name}`
    if (entry.isDirectory()) values.push(...sourceFiles(path))
    else if (/\.(?:ets|ts)$/.test(entry.name)) values.push(path)
  }
  return values.sort()
}

// 从严扫描：AI 目录内除 transport 外，任何 authorization 出现（含注释与标识符）即违约。
function authorizationOwnerPaths(paths, sources) {
  return paths
    .filter((_path, index) => /authorization/i.test(sources[index]))
    .map((path) => path.replace(/\\/g, '/'))
    .sort()
}

function assertSoleAuthorizationOwner(paths, sources) {
  assert.deepEqual(authorizationOwnerPaths(paths, sources),
    ['entry/src/main/ets/services/ai/AiVisionTransport.ets'])
}

function assertOrdered(source, fragments) {
  let prior = -1
  for (const fragment of fragments) {
    const current = source.indexOf(fragment, prior + 1)
    assert.notEqual(current, -1, 'missing fragment ' + fragment)
    prior = current
  }
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
      if (depth === 0) return source.slice(start, index + 1)
    }
  }
  assert.fail('unterminated method ' + signature)
}

test('credential storage uses HUKS AES-256-GCM and a versioned envelope', () => {
  const cipher = read('entry/src/main/ets/services/ai/HuksAesGcmCipher.ets')
  const codec = read('entry/src/main/ets/services/ai/AiCredentialEnvelopeCodec.ets')
  const store = read('entry/src/main/ets/services/ai/AiCredentialStore.ets')
  assert.match(cipher, /HUKS_AES_KEY_SIZE_256/)
  assert.match(cipher, /HUKS_MODE_GCM/)
  assert.match(cipher, /HUKS_PADDING_NONE/)
  assert.match(cipher, /NONCE_LENGTH:\s*number\s*=\s*12/)
  assert.match(cipher, /TAG_LENGTH:\s*number\s*=\s*16/)
  assert.match(cipher, /abortSession/)
  assert.doesNotMatch(cipher, /exportKeyItem|console\.|hilog\./)
  assert.match(codec, /'1\.'/)
  assert.match(store, /withCredential/)
  assert.doesNotMatch(store, /getCredential|getApiKey|console\.|hilog\./i)
})

test('credential preferences are excluded from device backup', () => {
  const config = JSON.parse(read('entry/src/main/resources/base/profile/backup_config.json'))
  assert.equal(config.allowToBackupRestore, true)
  assert.deepEqual(config.excludes, [
    'data/storage/el2/base/preferences/ai_credentials.xml'
  ])
})

test('credential operations use one atomic record and detect corruption before HUKS decrypt', () => {
  const codec = read('entry/src/main/ets/services/ai/AiCredentialEnvelopeCodec.ets')
  const store = read('entry/src/main/ets/services/ai/AiCredentialStore.ets')
  assert.match(store, /operationTail:\s*Promise<void>\s*=\s*Promise\.resolve\(\)/)
  assert.match(store, /runExclusive/)
  assert.match(store, /static async save[\s\S]*?runExclusive<void>/)
  assert.match(store, /static async hasCredential[\s\S]*?runExclusive<boolean>/)
  assert.match(store, /static async withCredential<T>[\s\S]*?runExclusive<T>/)
  assert.match(store, /static async clear[\s\S]*?runExclusive<void>/)
  assert.match(store, /operationTail\s*=\s*run\.then/)
  assert.match(codec, /export class AiCredentialRecord/)
  assert.match(codec, /export class AiCredentialRecordCodec/)
  assert.match(codec, /'1~'/)
  assert.doesNotMatch(codec, /JSON\.|\bany\b|\bunknown\b/)
  assert.match(store, /CREDENTIAL_RECORD_KEY:\s*string\s*=\s*'credential_record'/)
  assert.doesNotMatch(store, /ENVELOPE_SHA256_KEY|envelope_sha256/)
  assert.match(store, /createMd\('SHA256'\)/)
  assert.equal((store.match(/store\.put\(/g) || []).length, 1)
  assert.match(store, /store\.put\(CREDENTIAL_RECORD_KEY, recordText\)/)
  assert.equal((store.match(/store\.delete\(/g) || []).length, 1)
  assert.match(store, /store\.delete\(CREDENTIAL_RECORD_KEY\)/)
  assert.match(store, /AiCredentialRecordCodec\.decode/)
  assert.match(store, /AiCredentialEnvelopeCodec\.decode\(record\.envelope\)/)
  assert.match(store,
    /matchesEnvelopeDigest[\s\S]*HuksAesGcmCipher\.hasKey[\s\S]*HuksAesGcmCipher\.decrypt/)
  assert.match(store, /self-contained record/)
  assert.match(store, /either the old or new record/)
  assert.doesNotMatch(store, /catch \(err\)/)
})

test('AI network errors expose only local stable messages', () => {
  const source = read('entry/src/main/ets/services/ai/AiVisionTransport.ets')
  assert.doesNotMatch(source, /JSON\.stringify\(error\)|error\.message|response\.result.*throw/)
  assert.match(source, /2300028/)
  assert.match(source, /2300058/)
  assert.match(source, /2300063/)
})

test('AI credentials reject empty and header-control values before Authorization construction', () => {
  const source = read('entry/src/main/ets/services/ai/AiVisionTransport.ets')
  assert.match(source, /export class AiCredentialHeaderValidator/)
  assert.match(source, /credential\.length === 0/)
  assert.match(source, /code <= 0x1F \|\| code === 0x7F/)
  assert.match(source, /AiImportErrorCode\.MISSING_API_KEY/)
  assert.match(source,
    /AiCredentialHeaderValidator\.decode\(credential\)[\s\S]*headers\.Authorization = 'Bearer ' \+ credentialText/)
  assert.doesNotMatch(source, /console\.|hilog\.|error\.message|credentialText\s*\+\s*['"]error/)
})

test('AI coordinator does not retain credentials, provider bodies or response text', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const processStart = source.indexOf('private async processPage')
  const processSource = source.slice(processStart)
  assert.doesNotMatch(source, /api.?key|authorization|bearer/i)
  assert.match(processSource,
    /finally\s*{[\s\S]*?rawResponse = ''[\s\S]*?assistantContent = ''[\s\S]*?providerRequest\.release\(\)[\s\S]*?encoded\.releaseTransientText\(\)/)
  const runSessionStart = source.indexOf('const session: PdfReviewSession')
  const runSessionEnd = source.indexOf('PdfReviewSessionStore.put(session)', runSessionStart)
  const retrySessionStart = source.indexOf('const updated: PdfReviewSession')
  const retrySessionEnd = source.indexOf('PdfReviewSessionStore.put(updated)', retrySessionStart)
  assert.ok(runSessionStart >= 0 && runSessionEnd > runSessionStart)
  assert.ok(retrySessionStart >= 0 && retrySessionEnd > retrySessionStart)
  assert.doesNotMatch(source.slice(runSessionStart, runSessionEnd),
    /rawResponse|assistantContent|providerRequest|credential/)
  assert.doesNotMatch(source.slice(retrySessionStart, retrySessionEnd),
    /rawResponse|assistantContent|providerRequest|credential/)
  assert.doesNotMatch(source, /console\.|hilog\./)
})

test('AI save payload excludes provider and local-only data', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  assert.doesNotMatch(source, /api.?key|authorization|base.?url|prompt|raw.?response/i)
  assert.doesNotMatch(source,
    /CloudImportService|\/v1\/imports\/pdf|QuestionImageService\.commitImages/)
  assert.match(source, /createBankWithIds/)
  assert.match(source, /DeviceImageStore\.saveBatch/)
})

test('AI image preparation verifies ownership and cleans only newly copied finals on failure', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  assert.match(source, /static async prepareImages/)
  assert.match(source, /fs\.lstat/)
  assert.match(source, /isSymbolicLink\(\)/)
  assert.match(source, /isFile\(\)/)
  assert.match(source, /hash\.hash\([^,]+,\s*'sha256'\)/)
  assert.match(source, /fs\.copyFile/)
  assert.match(source, /newlyCopied/)
  assert.match(source, /DeviceImageStore\.saveBatch/)
  assert.match(source, /cleanupPreparedFinals/)
  assert.doesNotMatch(source, /fs\.copyFile\([^,]+,\s*finalPath/)
})

test('AI session cache cleanup accepts exact legacy and attempt names using tilde ownership', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const cleanupStart = source.indexOf('static async removeSessionCache')
  const cleanupEnd = source.indexOf('private static async prepareImageBatch', cleanupStart)
  const cleanup = source.slice(cleanupStart, cleanupEnd)
  assert.match(source, /ai_import_page_/)
  assert.match(source, /ai_import_crop_/)
  assert.match(source, /\^attempt~/)
  assert.match(source, /PdfImportService\.removeTemporaryPdf\(session\.pdfPath\)/)
  assert.match(cleanup, /firstError/)
  assert.doesNotMatch(source, /ai_import_page_['"]?\s*\+\s*session\.sessionId\s*\+\s*['_]/)
  assert.doesNotMatch(cleanup, /listFile|question_images/)
})

test('AI terminal cleanup performs the strict encoder session sweep before releasing ownership', () => {
  const save = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const cleanup = extractMethod(save, 'private static async removeSessionCacheExclusive')
  assert.match(save, /import \{ PdfPageImageEncoder \} from '.\/PdfPageImageEncoder'/)
  assert.match(cleanup, /new PdfPageImageEncoder\(\)/)
  assertOrdered(cleanup, [
    'cleanupSession(context, session.sessionId)',
    'if (firstError !== null)',
    'PdfImportService.removeTemporaryPdf(session.pdfPath)',
    'PdfImportService.proveTemporaryPdfAbsent(context.cacheDir, session.pdfPath)',
    'if (pdfError !== null && recoveredCheckpoint)',
    'PdfImportService.removeRecoveredTemporaryPdf(context.cacheDir, session.pdfPath)'
  ])
  const abandon = extractMethod(save, 'static async abandon')
  assertOrdered(abandon, [
    'AiImportSaveService.removeSessionCache(context, snapshot)',
    'checkpoint.remove(context, snapshot.sessionId)',
    'PdfReviewSessionStore.remove(snapshot.sessionId)'
  ])

  const encoder = read('entry/src/main/ets/services/ai/PdfPageImageEncoder.ets')
  const exact = extractMethod(encoder, 'static async cleanupOwnedCache')
  assert.match(exact, /validateIdentifier\(sessionId\)/)
  assert.match(exact, /validateCacheDirectory\(context.cacheDir\)/)
  assert.match(exact, /isOwnedPageName\(name, sessionId\)/)
  assert.match(exact, /isOwnedCropName\(name, sessionId\)/)
  assert.match(exact, /verifyParentIdentity\(context.cacheDir, path\)/)
  assert.match(encoder, /'ai_import_page_' \+ sessionId \+ PdfRenderSession\.OWNERSHIP_SEPARATOR/)
  assert.match(encoder, /'ai_import_crop_' \+ sessionId \+ PdfRenderSession\.OWNERSHIP_SEPARATOR/)
  assert.match(encoder, /OWNERSHIP_SEPARATOR:\s*string = '~'/)
})

test('AI image copy cleans partial and newly committed files after late failures', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const copyTemp = extractMethod(source, 'private static async copyDescriptorToTemp')
  const copyFinal = extractMethod(source, 'private static async copyToFinal')
  const matchesFinal = extractMethod(source, 'private static async matchesRegularFile')
  assert.match(copyTemp, /let destination:\s*fs\.File \| null = null/)
  assert.match(copyTemp, /operationError[\s\S]*removeOwnedFile/)
  assert.match(copyFinal, /finalCreated/)
  assert.match(copyFinal, /ownedFinal/)
  assert.match(copyFinal, /cleanupPreparedFinals/)
  assert.match(matchesFinal, /finalInfo[\s\S]*finalInfo\.ino === info\.ino/)
})

test('AI save freezes a durable checkpoint before any text write and checks the account first', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const models = read('entry/src/main/ets/services/review/PdfReviewModels.ets')
  const sessions = read('entry/src/main/ets/services/review/PdfReviewSession.ets')
  const save = extractMethod(source, 'async saveSession')
  const saveExclusive = extractMethod(source, 'private async saveSessionExclusive')

  assert.match(models, /TEXT_SAVING\s*=\s*'text_saving'/)
  assert.match(source, /export interface AiImportCheckpointPort/)
  assert.match(save, /PdfReviewSessionStore\.copyOf\(session\)/)
  assert.match(saveExclusive,
    /account\.require\(context, [^)]+\.accountId\)[\s\S]*checkpoint\.save[\s\S]*bankWriter\.write/)
  assert.match(saveExclusive, /PdfReviewSaveStage\.TEXT_SAVING/)
  assert.match(saveExclusive, /checkpoint\.load\(context, sessionId\)/)
  assert.match(source, /static async restore\(context:\s*Context,\s*sessionId:\s*string\)/)
  assert.match(sessions, /static async putDurable/)
  assert.match(sessions, /static async getDurable/)
  assert.match(sessions, /validateDecoded/)
  assert.match(sessions, /assertAllowedUpdate/)
  assert.match(sessions, /文字保存开始后不能编辑/)
  const persistedShape = sessions.slice(sessions.indexOf('class PersistedReviewSession'),
    sessions.indexOf('export class PdfReviewSessionCodec'))
  assert.doesNotMatch(persistedShape,
    /api.?key|authorization|base.?url|providerId|credential|raw.?response/i)
})

test('AI image persistence is serialized and retains finals for an ambiguous DB outcome', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const write = extractMethod(source, 'static async writeImages')

  assert.match(source, /private static imageOperationTail:\s*Promise<void>/)
  assert.match(write, /PdfReviewSessionStore\.copyOf\(session\)/)
  assert.match(write, /runImageExclusive/)
  assert.match(source, /DeviceImageStoreError/)
  assert.match(source, /DeviceImageWriteOutcome\.UNKNOWN/)
  assert.match(source, /shouldCleanupPreparedFinals/)
})

test('AI abandon rejects every durable or in-progress text stage', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const abandon = extractMethod(source, 'static async abandon')

  assert.match(abandon, /checkpoint\.load/)
  assert.match(abandon, /PdfReviewSavePolicy\.canAbandon/)
  assert.match(abandon, /TEXT_SAVING|durable/)
})

test('raw durable loads stay unpublished until identifiers and account ownership pass', () => {
  const saveSource = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const storeSource = read('entry/src/main/ets/services/review/PdfReviewSession.ets')
  const load = extractMethod(storeSource, 'static async getDurable')
  const restore = extractMethod(saveSource, 'private async restoreSessionExclusive')
  const recover = extractMethod(saveSource, 'private async recoverPendingSessionExclusive')

  assert.doesNotMatch(load, /sessions\.set/)
  assert.match(restore,
    /checkpoint\.load[\s\S]*validateSessionIdentifiers[\s\S]*account\.require[\s\S]*PdfReviewSessionStore\.put/)
  assert.match(recover,
    /checkpoint\.load[\s\S]*validateSessionIdentifiers[\s\S]*account\.require[\s\S]*PdfReviewSessionStore\.put/)
})

test('AI save lifecycle uses removable keyed session tails', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const lock = extractMethod(source, 'private static async runSessionExclusive')
  const save = extractMethod(source, 'async saveSession')
  const restore = extractMethod(source, 'async restoreSession')
  const finish = extractMethod(source, 'async finishCheckpoint')
  const recover = extractMethod(source, 'async recoverPendingForAccount')

  assert.match(source, /sessionOperationTails:\s*Map<string, Promise<void>>/)
  assert.match(lock, /sessionOperationTails\.get\(sessionId\)/)
  assert.match(lock, /sessionOperationTails\.set\(sessionId/)
  assert.match(lock,
    /sessionOperationTails\.get\(sessionId\) === current[\s\S]*sessionOperationTails\.delete\(sessionId\)/)
  assert.match(save, /runSessionExclusive/)
  assert.match(restore, /runSessionExclusive/)
  assert.match(finish, /runSessionExclusive/)
  assert.match(recover, /runSessionExclusive\(sessionId/)
})

test('durable checkpoint index drives foreground recovery and safe staged PDF deletion', () => {
  const store = read('entry/src/main/ets/services/review/PdfReviewSession.ets')
  const save = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const pdf = read('entry/src/main/ets/services/PdfImportService.ets')
  const ability = read('entry/src/main/ets/entryability/EntryAbility.ets')
  const put = extractMethod(store, 'static async putDurable')
  const remove = extractMethod(store, 'static async removeDurable')
  const recoveredPdf = extractMethod(pdf, 'static async removeRecoveredTemporaryPdf')

  assert.match(store, /REVIEW_CHECKPOINT_INDEX_KEY/)
  assert.match(store, /static async pendingDurableSessionIds/)
  assert.match(store, /validatePendingIds/)
  assert.match(put, /REVIEW_CHECKPOINT_PREFIX[\s\S]*REVIEW_CHECKPOINT_INDEX_KEY[\s\S]*store\.flush/)
  assert.match(remove, /REVIEW_CHECKPOINT_PREFIX[\s\S]*REVIEW_CHECKPOINT_INDEX_KEY[\s\S]*store\.flush/)
  assert.match(save, /static async recoverPending/)
  assert.match(save, /pending\(context\)/)
  assert.match(pdf, /static async removeRecoveredTemporaryPdf\(cacheDir:\s*string,\s*path:\s*string\)/)
  assert.match(recoveredPdf, /isDirectTemporaryPdfPath\(trustedCacheDir, recoveredPath\)/)
  assert.match(recoveredPdf, /validateExistingTemporaryPdf/)
  assert.match(ability, /AiImportSaveService\.recoverPending\(this\.context\)/)
})

test('COMPLETE access cleanup removal and publication remain account owned', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const saveExclusive = extractMethod(source, 'private async saveSessionExclusive')
  const lifecycle = extractMethod(source, 'private async saveLifecycleExclusive')
  const finish = extractMethod(source, 'async finishCheckpoint')

  assert.match(saveExclusive,
    /durable !== null[\s\S]*account\.require\(context, durable\.accountId\)/)
  assert.match(saveExclusive,
    /callerSnapshot\.saveStage === PdfReviewSaveStage\.COMPLETE[\s\S]*account\.require\(context, callerSnapshot\.accountId\)[\s\S]*return/)
  assert.match(lifecycle,
    /account\.require\(context, saved\.accountId\)[\s\S]*cacheCleanup\.cleanup/)
  assert.match(lifecycle,
    /account\.require\(context, saved\.accountId\)[\s\S]*checkpoint\.remove/)
  assert.match(lifecycle,
    /account\.require\(context, saved\.accountId\)[\s\S]*PdfReviewSessionStore\.putCleanupResult/)
  assert.match(finish,
    /checkpoint\.load[\s\S]*account\.require\(context, durable\.accountId\)[\s\S]*checkpoint\.remove/)
})

test('image preflight is non-mutating and precedes durable and remote text writes', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const saveExclusive = extractMethod(source, 'private async saveSessionExclusive')
  const preflight = extractMethod(source, 'static async preflightImages')

  assert.match(source, /export interface AiImportImagePreflightPort/)
  assert.match(saveExclusive,
    /imagePreflight\.preflight[\s\S]*PdfReviewSaveStage\.TEXT_SAVING[\s\S]*checkpoint\.save/)
  assert.match(saveExclusive,
    /checkpoint\.save[\s\S]*imagePreflight\.preflight[\s\S]*bankWriter\.write/)
  assert.match(preflight, /PdfReviewSessionStore\.copyOf\(session\)/)
  assert.match(preflight, /inspectSourceImage/)
  assert.match(preflight, /sha256/)
  assert.match(preflight, /sortOrder/)
  assert.match(preflight, /preflightDestinationDirectory/)
  assert.doesNotMatch(preflight, /copyToFinal|saveBatch|fs\.mkdir|fs\.moveFile/)
})

test('stale pending pruning repairs only durable index state', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const store = read('entry/src/main/ets/services/review/PdfReviewSession.ets')
  const recover = extractMethod(source, 'private async recoverPendingSessionExclusive')
  const prune = extractMethod(store, 'static async pruneMissingPendingId')

  assert.match(recover, /restored === null[\s\S]*checkpoint\.pruneMissing/)
  assert.doesNotMatch(recover, /restored === null[\s\S]*checkpoint\.remove/)
  assert.match(prune, /REVIEW_CHECKPOINT_INDEX_KEY/)
  assert.doesNotMatch(prune, /sessions\.(delete|set)/)
  assert.doesNotMatch(prune, /store\.delete\(REVIEW_CHECKPOINT_PREFIX/)
})

test('durable IO cannot publish or delete memory before lifecycle account revalidation', () => {
  const store = read('entry/src/main/ets/services/review/PdfReviewSession.ets')
  assert.doesNotMatch(extractMethod(store, 'static async putDurable'), /sessions\.(set|delete)/)
  assert.doesNotMatch(extractMethod(store, 'static async removeDurable'), /sessions\.(set|delete)/)
})

test('default checkpoint mutations and cache cleanup pin the owning account for all awaits', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  const checkpoint = source.slice(source.indexOf('class DefaultAiImportCheckpoint'),
    source.indexOf('class DefaultAiImportCacheCleanup'))
  assert.match(extractMethod(checkpoint, 'async save'),
    /runExpectedAccountLocalExclusive[\s\S]*snapshot\.accountId[\s\S]*putDurable/)
  assert.match(extractMethod(checkpoint, 'async remove'),
    /getDurable[\s\S]*runExpectedAccountLocalExclusive[\s\S]*durable\.accountId[\s\S]*removeDurable/)
  assert.match(extractMethod(source, 'static async removeSessionCache'),
    /copyOf\(session\)[\s\S]*runExpectedAccountLocalExclusive[\s\S]*snapshot\.accountId/)
})

test('AI modules have no logging, OCR fallback, or business import endpoint', () => {
  const paths = sourceFiles('entry/src/main/ets/services/ai')
  const sources = paths.map((path) => read(path))
  const combined = sources.join('\n')
  assert.doesNotMatch(combined, /\b(?:console|hilog)\s*\./)
  assert.doesNotMatch(combined,
    /CloudImportService|CloudImportApi|PaddleOCR|OcrService|CoreVision|textRecognition|\/v1\/imports\/pdf/)
  assertSoleAuthorizationOwner(paths, sources)
})

test('Authorization ownership scan catches lowercase leaks and normalizes Windows paths', () => {
  const paths = [
    'entry\\src\\main\\ets\\services\\ai\\AiVisionTransport.ets',
    'entry\\src\\main\\ets\\services\\ai\\LeakingAdapter.ets'
  ]
  const cleanSources = ['const Authorization = true', 'const requestBody = true']
  assertSoleAuthorizationOwner(paths.slice(0, 1), cleanSources.slice(0, 1))
  const mutatedSources = [cleanSources[0], 'const authorization = "Bearer secret"']
  assert.deepEqual(authorizationOwnerPaths(paths, mutatedSources), [
    'entry/src/main/ets/services/ai/AiVisionTransport.ets',
    'entry/src/main/ets/services/ai/LeakingAdapter.ets'
  ])
  assert.throws(() => assertSoleAuthorizationOwner(paths, mutatedSources))
})

test('sync writer cannot see provider configuration, credentials, PDF, or image bytes', () => {
  const repository = read('entry/src/main/ets/services/CloudQuestionRepository.ets')
  const save = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  assert.doesNotMatch(repository,
    /AiProviderConfig|AiCredential|Authorization|api[_ -]?key|baseUrl|pdfPath|imageBytes/i)
  assert.doesNotMatch(save, /Authorization|AiCredentialStore|AiVisionTransport/)
  assert.match(repository, /\/v1\/sync\/push/)
})

test('transport delegates its endpoint scheme guard to the shared private-host predicate', () => {
  const source = read('entry/src/main/ets/services/ai/AiVisionTransport.ets')
  assert.match(source, /AiProviderConfigValidator\.isAllowedEndpoint\(endpoint\)/)
  assert.doesNotMatch(source, /startsWith\('https:\/\/'\)/)
  assert.match(read('entry/src/main/ets/models/ai/AiProviderConfig.ets'),
    /static isAllowedEndpoint\(rawEndpoint: string\): boolean/)
  // 传输层不得复制第二份私网白名单（只允许委托共用谓词）。
  assert.doesNotMatch(source, /(?:127|10|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d/)
})
