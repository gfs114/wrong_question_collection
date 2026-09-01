import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { preferences, relationalStore } from '@kit.ArkData'
import { fileIo as fs, hash } from '@kit.CoreFileKit'
import {
  CloudBankCache,
  CloudCachePage,
  CloudQuestionCache,
  CloudWrongCache,
  DeviceQuestionImage
} from '../models/CloudCacheModels'
import { AccountSessionState } from '../models/AccountSession'
import { ApiHttpError } from '../models/ApiModels'
import {
  LegacyCanonicalQuestion,
  LegacyMigrationErrors,
  LegacyMigrationStage,
  LegacyMigrationState,
  LegacyTextNormalizer,
  MigrationPolicy
} from '../models/LegacyMigrationModels'
import {
  SyncEntityType,
  SyncOperationType,
  SyncOutboxOperation,
  SyncPushBody,
  SyncPushOperation,
  SyncPushResponse
} from '../models/SyncModels'
import { AccountSessionService } from './AccountSessionService'
import { ApiHttpClient } from './ApiHttpClient'
import { AuthoritativeSnapshot, CloudQuestionRepository } from './CloudQuestionRepository'
import { CloudCacheService } from './CloudCacheService'
import { DatabaseService } from './DatabaseService'
import { DeviceImageScope, DeviceImageStore } from './DeviceImageStore'
import { SyncIdentityService } from './SyncIdentityService'
import { SyncPayloadFactory } from './SyncPayloadFactory'

const PREFERENCES_NAME: string = 'legacy_cloud_migration'
const STATE_KEY: string = 'migration_state_v1'
const PUSH_BATCH_LIMIT: number = 100

interface MigrationStateJson {
  accountId: string
  stage: string
  bankIds: Array<string>
  currentBankId: string
  acknowledgedBankIds: Array<string>
  verifiedBankIds: Array<string>
  reboundBankIds: Array<string>
  totalBanks: number
  totalQuestions: number
  totalImages: number
  errorCode: string
  errorMessage: string
  updateTime: number
}

class MigrationVerificationError extends Error {
  readonly code: string

  constructor(code: string, message: string) {
    super(message)
    this.code = code
  }
}

class LegacyQuestionRow {
  id: string
  uuid: string
  type: string
  content: string
  optionsJson: string
  answer: string
  analysis: string

  constructor(id: string, uuid: string, type: string, content: string, optionsJson: string,
    answer: string, analysis: string) {
    this.id = id
    this.uuid = uuid
    this.type = type
    this.content = content
    this.optionsJson = optionsJson
    this.answer = answer
    this.analysis = analysis
  }
}

class LegacyImageRow {
  questionId: string
  imagePath: string
  sortOrder: number

  constructor(questionId: string, imagePath: string, sortOrder: number) {
    this.questionId = questionId
    this.imagePath = imagePath
    this.sortOrder = sortOrder
  }
}

class LegacyBankRow {
  id: string
  name: string
  subject: string
  questions: Array<LegacyQuestionRow>
  images: Array<LegacyImageRow>

  constructor(id: string, name: string, subject: string, questions: Array<LegacyQuestionRow>,
    images: Array<LegacyImageRow>) {
    this.id = id
    this.name = name
    this.subject = subject
    this.questions = questions
    this.images = images
  }
}

class LegacyMigrationPlan {
  banks: Array<LegacyBankRow>
  totalBanks: number
  totalQuestions: number
  totalImages: number

  constructor(banks: Array<LegacyBankRow>, totalQuestions: number, totalImages: number) {
    this.banks = banks
    this.totalBanks = banks.length
    this.totalQuestions = totalQuestions
    this.totalImages = totalImages
  }
}

/**
 * Safely migrates legacy local question text to the current Huawei account
 * cloud and rebinds device question images (Task 13).
 *
 * The migration is explicit (the user confirms the account binding), runs one
 * bank at a time with the stable sync UUIDs, pushes through POST /v1/sync/push,
 * re-downloads the authoritative snapshot through GET /v1/sync/pull, verifies
 * question counts and normalized text SHA-256 digests, and only then updates
 * the cloud cache and rebinds images through DeviceImageStore. Its state is
 * stored in app preferences, completely separate from sync_outbox. Legacy
 * tables, outbox rows, OCR services and original image files are never
 * deleted here.
 */
export class LegacyCloudMigrationService {
  private static runInFlight: Promise<LegacyMigrationState> | null = null

  /**
   * Restores the persisted migration state at startup without claiming an
   * account or starting any upload. An unreadable state resets to a fresh
   * unclaimed state.
   */
  static async initialize(context: Context): Promise<void> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const raw: preferences.ValueType = await store.get(STATE_KEY, '')
    if (typeof raw !== 'string' || raw.length === 0) {
      return
    }
    try {
      LegacyCloudMigrationService.parseState(raw)
    } catch {
      await store.delete(STATE_KEY)
      await store.flush()
    }
  }

  /**
   * Returns the migration state with fresh legacy counts for the UI. This is
   * read-only: it never claims an account or uploads anything.
   */
  static async overview(context: Context): Promise<LegacyMigrationState> {
    const persisted: LegacyMigrationState = await LegacyCloudMigrationService.loadState(context)
    const counts: LegacyMigrationCounts = await LegacyCloudMigrationService.scanCounts()
    return new LegacyMigrationState(
      persisted.accountId, persisted.stage, persisted.bankIds, persisted.currentBankId,
      persisted.acknowledgedBankIds, persisted.verifiedBankIds, persisted.reboundBankIds,
      counts.totalBanks, counts.totalQuestions, counts.totalImages,
      persisted.errorCode, persisted.errorMessage, Date.now())
  }

  /**
   * Binds the migration to the current Huawei account after the user has
   * explicitly confirmed the binding in the UI. Never called automatically.
   */
  static async claim(context: Context): Promise<LegacyMigrationState> {
    const accountId: string = await LegacyCloudMigrationService.requireSignedIn(context)
    const existing: LegacyMigrationState = await LegacyCloudMigrationService.loadState(context)
    if (!MigrationPolicy.canClaim(existing.accountId, accountId)) {
      throw new Error('旧数据迁移已绑定其他华为账号')
    }
    if (existing.accountId.length > 0) {
      return existing
    }
    const plan: LegacyMigrationPlan = await LegacyCloudMigrationService.buildPlan()
    if (plan.totalBanks === 0) {
      throw new Error('没有可迁移的旧数据')
    }
    const bankIds: Array<string> = new Array<string>()
    for (let index: number = 0; index < plan.banks.length; index++) {
      bankIds.push(plan.banks[index].id)
    }
    const state: LegacyMigrationState = new LegacyMigrationState(
      accountId, LegacyMigrationStage.UPLOADING, bankIds, bankIds[0],
      new Array<string>(), new Array<string>(), new Array<string>(),
      plan.totalBanks, plan.totalQuestions, plan.totalImages, '', '', Date.now())
    await LegacyCloudMigrationService.saveState(context, state)
    return state
  }

  /**
   * Runs or resumes the migration for the currently signed-in account. Only
   * a previously claimed migration can run. Operational failures return a
   * FAILED state with retry; precondition violations throw.
   */
  static async run(context: Context): Promise<LegacyMigrationState> {
    const active: Promise<LegacyMigrationState> | null = LegacyCloudMigrationService.runInFlight
    if (active !== null) {
      return active
    }
    const started: Promise<LegacyMigrationState> = LegacyCloudMigrationService.performRun(context)
    LegacyCloudMigrationService.runInFlight = started
    try {
      return await started
    } finally {
      if (LegacyCloudMigrationService.runInFlight === started) {
        LegacyCloudMigrationService.runInFlight = null
      }
    }
  }

  private static async performRun(context: Context): Promise<LegacyMigrationState> {
    const accountId: string = await LegacyCloudMigrationService.requireSignedIn(context)
    let state: LegacyMigrationState = await LegacyCloudMigrationService.loadState(context)
    if (state.accountId.length === 0 || state.stage === LegacyMigrationStage.UNCLAIMED) {
      throw new Error('旧数据迁移尚未确认绑定账号')
    }
    if (!MigrationPolicy.canClaim(state.accountId, accountId)) {
      throw new Error('旧数据迁移已绑定其他华为账号')
    }
    if (state.stage === LegacyMigrationStage.COMPLETED) {
      return state
    }
    try {
      state = await LegacyCloudMigrationService.uploadPhase(context, accountId, state)
    } catch (err) {
      const message: string = err instanceof Error ?
        LegacyCloudMigrationService.errorMessage(err) : '旧数据上传失败'
      return LegacyCloudMigrationService.markFailed(context, state,
        LegacyMigrationErrors.UPLOAD_FAILED, message)
    }
    try {
      state = await LegacyCloudMigrationService.verifyPhase(context, accountId, state)
    } catch (err) {
      const failure: Error = err instanceof Error ? err : new Error('旧数据校验失败')
      return LegacyCloudMigrationService.markFailed(context, state,
        LegacyCloudMigrationService.failureCode(failure),
        LegacyCloudMigrationService.errorMessage(failure))
    }
    return state
  }

  private static async uploadPhase(context: Context, accountId: string,
    state: LegacyMigrationState): Promise<LegacyMigrationState> {
    const plan: LegacyMigrationPlan = await LegacyCloudMigrationService.buildPlan()
    let current: LegacyMigrationState = state
    for (let index: number = 0; index < plan.banks.length; index++) {
      const bank: LegacyBankRow = plan.banks[index]
      if (current.acknowledgedBankIds.indexOf(bank.id) >= 0) {
        continue
      }
      await LegacyCloudMigrationService.uploadBank(context, bank)
      current = LegacyCloudMigrationService.acknowledgedState(current, bank.id)
      await LegacyCloudMigrationService.saveState(context, current)
    }
    if (!current.serverAcknowledged()) {
      throw new MigrationVerificationError(LegacyMigrationErrors.COUNT_MISMATCH,
        '待迁移题库数量与本地记录不一致')
    }
    const verifying: LegacyMigrationState = new LegacyMigrationState(
      current.accountId, LegacyMigrationStage.VERIFYING, current.bankIds, current.currentBankId,
      current.acknowledgedBankIds, current.verifiedBankIds, current.reboundBankIds,
      current.totalBanks, current.totalQuestions, current.totalImages,
      current.errorCode, current.errorMessage, Date.now())
    await LegacyCloudMigrationService.saveState(context, verifying)
    return verifying
  }

  /**
   * Uploads one bank (bank upsert first, then its question upserts) through
   * the existing server sync API using the stable sync UUIDs. The server
   * materializes upserts by entity UUID, so re-pushing a bank after a retry
   * or crash is idempotent and never duplicates cloud rows.
   */
  private static async uploadBank(context: Context, bank: LegacyBankRow): Promise<void> {
    const bankUuid: string = await SyncIdentityService.clientUuid(
      SyncEntityType.QUESTION_BANK, bank.id)
    const operations: Array<SyncPushOperation> = new Array<SyncPushOperation>()
    operations.push(new SyncPushOperation(new SyncOutboxOperation(
      util.generateRandomUUID(), SyncEntityType.QUESTION_BANK, bankUuid, SyncOperationType.UPSERT,
      SyncPayloadFactory.bankPayload(bank.name, bank.subject), Date.now())))
    for (let index: number = 0; index < bank.questions.length; index++) {
      const question: LegacyQuestionRow = bank.questions[index]
      const questionUuid: string = question.uuid
      const payload: string = SyncPayloadFactory.questionFieldsPayload(
        question.type, question.content, LegacyCloudMigrationService.parseOptionsJson(question.optionsJson),
        question.answer, question.analysis, bankUuid)
      operations.push(new SyncPushOperation(new SyncOutboxOperation(
        util.generateRandomUUID(), SyncEntityType.QUESTION, questionUuid, SyncOperationType.UPSERT,
        payload, Date.now())))
    }
    await LegacyCloudMigrationService.pushInBatches(context, operations)
  }

  private static async pushInBatches(context: Context,
    operations: Array<SyncPushOperation>): Promise<void> {
    let offset: number = 0
    while (offset < operations.length) {
      const batchSize: number = Math.min(PUSH_BATCH_LIMIT, operations.length - offset)
      const batch: Array<SyncPushOperation> = new Array<SyncPushOperation>()
      for (let index: number = offset; index < offset + batchSize; index++) {
        batch.push(operations[index])
      }
      await LegacyCloudMigrationService.pushBatch(context, batch)
      offset += batchSize
    }
  }

  private static async pushBatch(context: Context, operations: Array<SyncPushOperation>,
    retried: boolean = false): Promise<void> {
    const accessToken: string = await AccountSessionService.accessToken(context)
    if (accessToken.length === 0) {
      throw new Error('请先登录华为账号')
    }
    const body: SyncPushBody = new SyncPushBody(operations)
    try {
      const response: SyncPushResponse =
        await ApiHttpClient.authorizedPost<SyncPushResponse>('/v1/sync/push', body, accessToken)
      if (response.operations.length !== operations.length) {
        throw new Error('服务器未确认全部同步操作')
      }
    } catch (err) {
      if (!retried && err instanceof ApiHttpError && err.statusCode === 401) {
        await AccountSessionService.refresh(context)
        await LegacyCloudMigrationService.pushBatch(context, operations, true)
        return
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('旧数据上传失败')
    }
  }

  private static async verifyPhase(context: Context, accountId: string,
    state: LegacyMigrationState): Promise<LegacyMigrationState> {
    const snapshot: AuthoritativeSnapshot =
      await CloudQuestionRepository.pullAuthoritativeSnapshot(accountId, context)
    const plan: LegacyMigrationPlan = await LegacyCloudMigrationService.buildPlan()
    let current: LegacyMigrationState = state
    for (let index: number = 0; index < plan.banks.length; index++) {
      const bank: LegacyBankRow = plan.banks[index]
      if (current.verifiedBankIds.indexOf(bank.id) >= 0) {
        continue
      }
      await LegacyCloudMigrationService.verifyBank(accountId, snapshot, bank)
      current = LegacyCloudMigrationService.verifiedState(current, bank.id)
      await LegacyCloudMigrationService.saveState(context, current)
    }
    if (!current.cacheVerified()) {
      throw new MigrationVerificationError(LegacyMigrationErrors.COUNT_MISMATCH,
        '迁移题库数量校验失败')
    }
    await LegacyCloudMigrationService.writeCloudCache(accountId, snapshot)
    for (let index: number = 0; index < plan.banks.length; index++) {
      const bank: LegacyBankRow = plan.banks[index]
      if (current.reboundBankIds.indexOf(bank.id) >= 0) {
        continue
      }
      await LegacyCloudMigrationService.rebindBank(context, accountId, bank)
      current = LegacyCloudMigrationService.reboundState(current, bank.id)
      await LegacyCloudMigrationService.saveState(context, current)
    }
    if (!MigrationPolicy.canRetireLegacy(current.serverAcknowledged(), current.cacheVerified(),
      current.imageMappingsCommitted())) {
      throw new MigrationVerificationError(LegacyMigrationErrors.IMAGE_REBIND_FAILED,
        '迁移完成条件未满足')
    }
    const completed: LegacyMigrationState = new LegacyMigrationState(
      current.accountId, LegacyMigrationStage.COMPLETED, current.bankIds, current.currentBankId,
      current.acknowledgedBankIds, current.verifiedBankIds, current.reboundBankIds,
      current.totalBanks, current.totalQuestions, current.totalImages, '', '', Date.now())
    await LegacyCloudMigrationService.saveState(context, completed)
    return completed
  }

  private static async verifyBank(accountId: string, snapshot: AuthoritativeSnapshot,
    bank: LegacyBankRow): Promise<void> {
    const bankUuid: string = await SyncIdentityService.clientUuid(
      SyncEntityType.QUESTION_BANK, bank.id)
    const serverBank: CloudBankCache | undefined = snapshot.banks.get(bankUuid)
    if (serverBank === undefined) {
      throw new MigrationVerificationError(LegacyMigrationErrors.COUNT_MISMATCH, '服务器快照缺少题库')
    }
    let serverCount: number = 0
    snapshot.questions.forEach((question: CloudQuestionCache) => {
      if (question.bankUuid === bankUuid) {
        serverCount++
      }
    })
    if (serverCount !== bank.questions.length) {
      throw new MigrationVerificationError(LegacyMigrationErrors.COUNT_MISMATCH,
        '服务器题目数量与本地不一致')
    }
    const localDigest: string = MigrationTextDigest.digestText(LegacyTextNormalizer.canonicalText(
      bank.name, bank.subject, LegacyCloudMigrationService.localCanonicalQuestions(bank)))
    const serverDigest: string = MigrationTextDigest.digestText(LegacyTextNormalizer.canonicalText(
      serverBank.bankName, serverBank.subject,
      LegacyCloudMigrationService.serverCanonicalQuestions(snapshot, bankUuid)))
    if (localDigest !== serverDigest) {
      throw new MigrationVerificationError(LegacyMigrationErrors.DIGEST_MISMATCH,
        '服务器文字摘要与本地不一致')
    }
  }

  private static localCanonicalQuestions(bank: LegacyBankRow): Array<LegacyCanonicalQuestion> {
    const questions: Array<LegacyCanonicalQuestion> = new Array<LegacyCanonicalQuestion>()
    for (let index: number = 0; index < bank.questions.length; index++) {
      const question: LegacyQuestionRow = bank.questions[index]
      questions.push(new LegacyCanonicalQuestion(
        question.uuid, question.type, question.content,
        LegacyCloudMigrationService.parseOptionsJson(question.optionsJson),
        question.answer, question.analysis))
    }
    return questions
  }

  private static serverCanonicalQuestions(snapshot: AuthoritativeSnapshot,
    bankUuid: string): Array<LegacyCanonicalQuestion> {
    const questions: Array<LegacyCanonicalQuestion> = new Array<LegacyCanonicalQuestion>()
    snapshot.questions.forEach((question: CloudQuestionCache) => {
      if (question.bankUuid === bankUuid) {
        questions.push(new LegacyCanonicalQuestion(
          question.questionUuid, question.type, question.content,
          LegacyCloudMigrationService.parseOptionsJson(question.optionsJson),
          question.answer, question.analysis))
      }
    })
    return questions
  }

  /**
   * Transactionally replaces the cloud cache with the verified server
   * snapshot. This runs only after every migrated bank passed verification.
   */
  private static async writeCloudCache(accountId: string,
    snapshot: AuthoritativeSnapshot): Promise<void> {
    try {
      const banks: Array<CloudBankCache> = new Array<CloudBankCache>()
      const questions: Array<CloudQuestionCache> = new Array<CloudQuestionCache>()
      const wrongQuestions: Array<CloudWrongCache> = new Array<CloudWrongCache>()
      snapshot.banks.forEach((bank: CloudBankCache) => {
        let count: number = 0
        snapshot.questions.forEach((question: CloudQuestionCache) => {
          if (question.bankUuid === bank.bankUuid) {
            count++
          }
        })
        banks.push(new CloudBankCache(
          bank.accountId, bank.bankUuid, bank.bankName, bank.subject, count,
          bank.serverVersion, bank.updateTime))
      })
      snapshot.questions.forEach((question: CloudQuestionCache) => {
        questions.push(question)
      })
      snapshot.wrongQuestions.forEach((item: CloudWrongCache) => {
        wrongQuestions.push(item)
      })
      await CloudCacheService.replacePage(accountId,
        new CloudCachePage(snapshot.cursor, Date.now(), banks, questions, wrongQuestions))
    } catch (err) {
      throw new MigrationVerificationError(LegacyMigrationErrors.CACHE_WRITE_FAILED,
        '云端缓存更新失败')
    }
  }

  /**
   * Rebinds the legacy device images to the authoritative server question
   * UUIDs inside the account-scoped image directory. Original image files
   * stay in place; only the accountId + serverQuestionUuid -> local path
   * mapping is created. No image content is uploaded anywhere.
   */
  private static async rebindBank(context: Context, accountId: string,
    bank: LegacyBankRow): Promise<void> {
    const imageRoot: string = context.filesDir + '/question_images'
    const accountDirectory: string = DeviceImageScope.accountDirectory(context.filesDir, accountId)
    await LegacyCloudMigrationService.ensureImageDirectory(imageRoot, accountDirectory)
    for (let index: number = 0; index < bank.images.length; index++) {
      const image: LegacyImageRow = bank.images[index]
      const questionUuid: string = LegacyCloudMigrationService.questionUuid(bank, image.questionId)
      await LegacyCloudMigrationService.rebindImage(context, accountId, accountDirectory,
        image, questionUuid)
    }
  }

  private static async rebindImage(context: Context, accountId: string, accountDirectory: string,
    image: LegacyImageRow, questionUuid: string): Promise<void> {
    LegacyCloudMigrationService.validateLegacyImagePath(context.filesDir, image.imagePath)
    const info: fs.Stat | null = await LegacyCloudMigrationService.lstatIfPresent(image.imagePath)
    if (info === null || info.isSymbolicLink() || !info.isFile()) {
      throw new MigrationVerificationError(LegacyMigrationErrors.IMAGE_REBIND_FAILED,
        '本机题图文件缺失')
    }
    const sha256: string = (await hash.hash(image.imagePath, 'sha256')).toLowerCase()
    if (!/^[a-f0-9]{64}$/.test(sha256)) {
      throw new MigrationVerificationError(LegacyMigrationErrors.IMAGE_REBIND_FAILED,
        '本机题图摘要无效')
    }
    const destinationPath: string = accountDirectory + '/legacy_' + questionUuid + '_' +
      image.sortOrder.toString() + '.jpg'
    await fs.copyFile(image.imagePath, destinationPath)
    await DeviceImageStore.save(context, new DeviceQuestionImage(
      accountId, questionUuid, destinationPath, sha256, image.sortOrder))
  }

  private static questionUuid(bank: LegacyBankRow, questionId: string): string {
    for (let index: number = 0; index < bank.questions.length; index++) {
      if (bank.questions[index].id === questionId) {
        return bank.questions[index].uuid
      }
    }
    throw new MigrationVerificationError(LegacyMigrationErrors.IMAGE_REBIND_FAILED,
      '题图所属题目不存在')
  }

  private static async ensureImageDirectory(imageRoot: string,
    accountDirectory: string): Promise<void> {
    await LegacyCloudMigrationService.ensureDirectory(imageRoot)
    await LegacyCloudMigrationService.ensureDirectory(accountDirectory)
  }

  private static async ensureDirectory(path: string): Promise<void> {
    const info: fs.Stat | null = await LegacyCloudMigrationService.lstatIfPresent(path)
    if (info === null) {
      await fs.mkdir(path, true)
      const created: fs.Stat | null = await LegacyCloudMigrationService.lstatIfPresent(path)
      if (created === null) {
        throw new Error('本地图片目录创建失败')
      }
      if (created.isSymbolicLink() || !created.isDirectory()) {
        throw new Error('本地图片目录不安全')
      }
      return
    }
    if (info.isSymbolicLink() || !info.isDirectory()) {
      throw new Error('本地图片目录不安全')
    }
  }

  private static validateLegacyImagePath(filesDir: string, imagePath: string): void {
    const root: string = filesDir + '/question_images'
    if (imagePath.indexOf('\\') >= 0 || imagePath.indexOf('\0') >= 0 ||
      !imagePath.startsWith(root + '/')) {
      throw new MigrationVerificationError(LegacyMigrationErrors.IMAGE_REBIND_FAILED,
        '本机题图路径无效')
    }
    const relative: string = imagePath.substring(root.length + 1)
    if (relative.length === 0) {
      throw new MigrationVerificationError(LegacyMigrationErrors.IMAGE_REBIND_FAILED,
        '本机题图路径无效')
    }
    const parts: Array<string> = relative.split('/')
    for (let index: number = 0; index < parts.length; index++) {
      if (parts[index].length === 0 || parts[index] === '.' || parts[index] === '..') {
        throw new MigrationVerificationError(LegacyMigrationErrors.IMAGE_REBIND_FAILED,
          '本机题图路径无效')
      }
    }
  }

  private static async lstatIfPresent(path: string): Promise<fs.Stat | null> {
    try {
      return await fs.lstat(path)
    } catch {
      return null
    }
  }

  private static async markFailed(context: Context, state: LegacyMigrationState, code: string,
    message: string): Promise<LegacyMigrationState> {
    const failed: LegacyMigrationState = new LegacyMigrationState(
      state.accountId, LegacyMigrationStage.FAILED, state.bankIds, state.currentBankId,
      state.acknowledgedBankIds, state.verifiedBankIds, state.reboundBankIds,
      state.totalBanks, state.totalQuestions, state.totalImages, code, message, Date.now())
    await LegacyCloudMigrationService.saveState(context, failed)
    return failed
  }

  private static acknowledgedState(state: LegacyMigrationState, bankId: string): LegacyMigrationState {
    const acknowledged: Array<string> = state.acknowledgedBankIds.slice()
    if (acknowledged.indexOf(bankId) < 0) {
      acknowledged.push(bankId)
    }
    return new LegacyMigrationState(
      state.accountId, state.stage, state.bankIds, bankId, acknowledged,
      state.verifiedBankIds, state.reboundBankIds, state.totalBanks, state.totalQuestions,
      state.totalImages, state.errorCode, state.errorMessage, Date.now())
  }

  private static verifiedState(state: LegacyMigrationState, bankId: string): LegacyMigrationState {
    const verified: Array<string> = state.verifiedBankIds.slice()
    if (verified.indexOf(bankId) < 0) {
      verified.push(bankId)
    }
    return new LegacyMigrationState(
      state.accountId, state.stage, state.bankIds, bankId, state.acknowledgedBankIds,
      verified, state.reboundBankIds, state.totalBanks, state.totalQuestions,
      state.totalImages, state.errorCode, state.errorMessage, Date.now())
  }

  private static reboundState(state: LegacyMigrationState, bankId: string): LegacyMigrationState {
    const rebound: Array<string> = state.reboundBankIds.slice()
    if (rebound.indexOf(bankId) < 0) {
      rebound.push(bankId)
    }
    return new LegacyMigrationState(
      state.accountId, state.stage, state.bankIds, bankId, state.acknowledgedBankIds,
      state.verifiedBankIds, rebound, state.totalBanks, state.totalQuestions,
      state.totalImages, state.errorCode, state.errorMessage, Date.now())
  }

  private static async buildPlan(): Promise<LegacyMigrationPlan> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const bankRows: Array<LegacyBankRow> = new Array<LegacyBankRow>()
    let totalQuestions: number = 0
    let totalImages: number = 0
    const bankResultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT id, bank_name, subject FROM question_bank WHERE is_sample = 0 ORDER BY rowid ASC')
    try {
      while (bankResultSet.goToNextRow()) {
        const bankId: string = bankResultSet.getString(0)
        const questions: Array<LegacyQuestionRow> = new Array<LegacyQuestionRow>()
        const questionArgs: Array<relationalStore.ValueType> = [bankId]
        const questionResultSet: relationalStore.ResultSet = await store.querySql(
          'SELECT id, type, content, options_json, answer, analysis ' +
          'FROM question WHERE bank_id = ? ORDER BY rowid ASC', questionArgs)
        try {
          while (questionResultSet.goToNextRow()) {
            const questionId: string = questionResultSet.getString(0)
            const questionUuid: string = await SyncIdentityService.clientUuid(
              SyncEntityType.QUESTION, questionId)
            questions.push(new LegacyQuestionRow(
              questionId, questionUuid, questionResultSet.getString(1), questionResultSet.getString(2),
              questionResultSet.getString(3), questionResultSet.getString(4),
              questionResultSet.getString(5)))
            totalQuestions++
          }
        } finally {
          questionResultSet.close()
        }
        const images: Array<LegacyImageRow> = new Array<LegacyImageRow>()
        const imageArgs: Array<relationalStore.ValueType> = [bankId]
        const imageResultSet: relationalStore.ResultSet = await store.querySql(
          'SELECT qi.question_id, qi.image_path, qi.sort_order FROM question_image qi ' +
          'INNER JOIN question q ON q.id = qi.question_id WHERE q.bank_id = ? ' +
          'ORDER BY qi.rowid ASC', imageArgs)
        try {
          while (imageResultSet.goToNextRow()) {
            images.push(new LegacyImageRow(
              imageResultSet.getString(0), imageResultSet.getString(1), imageResultSet.getLong(2)))
            totalImages++
          }
        } finally {
          imageResultSet.close()
        }
        bankRows.push(new LegacyBankRow(
          bankId, bankResultSet.getString(1), bankResultSet.getString(2), questions, images))
      }
    } finally {
      bankResultSet.close()
    }
    return new LegacyMigrationPlan(bankRows, totalQuestions, totalImages)
  }

  private static async scanCounts(): Promise<LegacyMigrationCounts> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    let totalBanks: number = 0
    let totalQuestions: number = 0
    let totalImages: number = 0
    const bankResultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT COUNT(*) FROM question_bank WHERE is_sample = 0')
    try {
      if (bankResultSet.goToFirstRow()) {
        totalBanks = bankResultSet.getLong(0)
      }
    } finally {
      bankResultSet.close()
    }
    const questionResultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT COUNT(*) FROM question q INNER JOIN question_bank b ON b.id = q.bank_id ' +
      'WHERE b.is_sample = 0')
    try {
      if (questionResultSet.goToFirstRow()) {
        totalQuestions = questionResultSet.getLong(0)
      }
    } finally {
      questionResultSet.close()
    }
    const imageResultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT COUNT(*) FROM question_image qi INNER JOIN question q ON q.id = qi.question_id ' +
      'INNER JOIN question_bank b ON b.id = q.bank_id WHERE b.is_sample = 0')
    try {
      if (imageResultSet.goToFirstRow()) {
        totalImages = imageResultSet.getLong(0)
      }
    } finally {
      imageResultSet.close()
    }
    return new LegacyMigrationCounts(totalBanks, totalQuestions, totalImages)
  }

  private static async requireSignedIn(context: Context): Promise<string> {
    const session: AccountSessionState = await AccountSessionService.state(context)
    if (!session.signedIn || session.userId.trim().length === 0) {
      throw new Error('请先登录华为账号')
    }
    return session.userId
  }

  private static parseOptionsJson(optionsJson: string): Array<string> {
    if (optionsJson.trim().length === 0) {
      return new Array<string>()
    }
    try {
      const parsed: Array<string> = JSON.parse(optionsJson) as Array<string>
      if (!Array.isArray(parsed)) {
        return new Array<string>()
      }
      return parsed
    } catch {
      return new Array<string>()
    }
  }

  private static failureCode(err: Error): string {
    if (err instanceof MigrationVerificationError) {
      return err.code
    }
    return LegacyMigrationErrors.SNAPSHOT_FAILED
  }

  private static errorMessage(err: Error): string {
    return err instanceof Error && err.message.length > 0 ? err.message : '旧数据迁移失败'
  }

  private static async loadState(context: Context): Promise<LegacyMigrationState> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const raw: preferences.ValueType = await store.get(STATE_KEY, '')
    if (typeof raw !== 'string' || raw.length === 0) {
      return new LegacyMigrationState('', LegacyMigrationStage.UNCLAIMED,
        new Array<string>(), '', new Array<string>(), new Array<string>(), new Array<string>(),
        0, 0, 0, '', '', 0)
    }
    try {
      return LegacyCloudMigrationService.parseState(raw)
    } catch {
      return new LegacyMigrationState('', LegacyMigrationStage.UNCLAIMED,
        new Array<string>(), '', new Array<string>(), new Array<string>(), new Array<string>(),
        0, 0, 0, '', '', 0)
    }
  }

  private static parseState(raw: string): LegacyMigrationState {
    const parsed: MigrationStateJson = JSON.parse(raw) as MigrationStateJson
    const accountId: string = typeof parsed.accountId === 'string' ? parsed.accountId : ''
    const stage: string = typeof parsed.stage === 'string' ? parsed.stage :
      LegacyMigrationStage.UNCLAIMED
    return new LegacyMigrationState(
      accountId, stage,
      LegacyCloudMigrationService.stringArray(parsed.bankIds),
      typeof parsed.currentBankId === 'string' ? parsed.currentBankId : '',
      LegacyCloudMigrationService.stringArray(parsed.acknowledgedBankIds),
      LegacyCloudMigrationService.stringArray(parsed.verifiedBankIds),
      LegacyCloudMigrationService.stringArray(parsed.reboundBankIds),
      typeof parsed.totalBanks === 'number' ? parsed.totalBanks : 0,
      typeof parsed.totalQuestions === 'number' ? parsed.totalQuestions : 0,
      typeof parsed.totalImages === 'number' ? parsed.totalImages : 0,
      typeof parsed.errorCode === 'string' ? parsed.errorCode : '',
      typeof parsed.errorMessage === 'string' ? parsed.errorMessage : '',
      typeof parsed.updateTime === 'number' ? parsed.updateTime : 0)
  }

  private static stringArray(value: Array<string>): Array<string> {
    const result: Array<string> = new Array<string>()
    if (!Array.isArray(value)) {
      return result
    }
    for (let index: number = 0; index < value.length; index++) {
      if (typeof value[index] === 'string') {
        result.push(value[index])
      }
    }
    return result
  }

  private static async saveState(context: Context, state: LegacyMigrationState): Promise<void> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const json: MigrationStateJson = {
      accountId: state.accountId,
      stage: state.stage,
      bankIds: state.bankIds.slice(),
      currentBankId: state.currentBankId,
      acknowledgedBankIds: state.acknowledgedBankIds.slice(),
      verifiedBankIds: state.verifiedBankIds.slice(),
      reboundBankIds: state.reboundBankIds.slice(),
      totalBanks: state.totalBanks,
      totalQuestions: state.totalQuestions,
      totalImages: state.totalImages,
      errorCode: state.errorCode,
      errorMessage: state.errorMessage,
      updateTime: state.updateTime
    }
    await store.put(STATE_KEY, JSON.stringify(json))
    await store.flush()
  }
}

class LegacyMigrationCounts {
  totalBanks: number
  totalQuestions: number
  totalImages: number

  constructor(totalBanks: number, totalQuestions: number, totalImages: number) {
    this.totalBanks = totalBanks
    this.totalQuestions = totalQuestions
    this.totalImages = totalImages
  }
}

export class MigrationTextDigest {
  static digestText(text: string): string {
    const encoder: util.TextEncoder = new util.TextEncoder()
    const encoded: Uint8Array = encoder.encodeInto(text)
    const stream: hash.HashStream = hash.createHash('sha256')
    stream.update(encoded.buffer as ArrayBuffer)
    return stream.digest().toLowerCase()
  }
}
