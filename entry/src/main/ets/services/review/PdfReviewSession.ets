import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { AiImportErrorCode } from '../../models/ai/AiProviderConfig'
import { AiQuestionType } from '../../models/ai/AiImportModels'
import {
  PdfReviewFailure,
  PdfReviewImage,
  PdfReviewOption,
  PdfReviewQuestion,
  PdfReviewSaveStage,
  PdfReviewSession,
  PdfReviewSource
} from './PdfReviewModels'

const REVIEW_CHECKPOINT_PREFERENCES: string = 'ai_import_review_checkpoint'
const REVIEW_CHECKPOINT_PREFIX: string = 'session.'
const REVIEW_CHECKPOINT_INDEX_KEY: string = 'pending_ids_v1'
const REVIEW_CHECKPOINT_VERSION: number = 1
const MAX_CHECKPOINT_LENGTH: number = 16 * 1024 * 1024
const MAX_PENDING_CHECKPOINTS: number = 128

class PersistedReviewSession {
  version: number
  sessionId: string
  source: PdfReviewSource
  bankUuid: string
  bankName: string
  subject: string
  pdfPath: string
  accountId: string
  questions: Array<PdfReviewQuestion>
  failures: Array<PdfReviewFailure>
  saveStage: PdfReviewSaveStage

  constructor(session: PdfReviewSession) {
    this.version = REVIEW_CHECKPOINT_VERSION
    this.sessionId = session.sessionId
    this.source = session.source
    this.bankUuid = session.bankUuid
    this.bankName = session.bankName
    this.subject = session.subject
    this.pdfPath = session.pdfPath
    this.accountId = session.accountId
    this.questions = session.questions
    this.failures = session.failures
    this.saveStage = session.saveStage
  }
}

export class PdfReviewSessionCodec {
  static encode(session: PdfReviewSession): string {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    const persisted: PersistedReviewSession = new PersistedReviewSession(snapshot)
    PdfReviewSessionCodec.validateDecoded(persisted, snapshot.sessionId)
    const encoded: string = JSON.stringify(persisted)
    if (encoded.length === 0 || encoded.length > MAX_CHECKPOINT_LENGTH) {
      throw new Error('AI 导入保存检查点大小无效')
    }
    return encoded
  }

  static decode(encoded: string, expectedSessionId: string): PdfReviewSession {
    if (encoded.length === 0 || encoded.length > MAX_CHECKPOINT_LENGTH) {
      throw new Error('AI 导入保存检查点大小无效')
    }
    let parsed: PersistedReviewSession
    try {
      parsed = JSON.parse(encoded) as PersistedReviewSession
    } catch {
      throw new Error('AI 导入保存检查点已损坏')
    }
    return PdfReviewSessionCodec.validateDecoded(parsed, expectedSessionId)
  }

  private static validateDecoded(parsed: PersistedReviewSession,
    expectedSessionId: string): PdfReviewSession {
    if (parsed === null || parsed.version !== REVIEW_CHECKPOINT_VERSION ||
      typeof parsed.sessionId !== 'string' || parsed.sessionId !== expectedSessionId ||
      !PdfReviewSessionCodec.isIdentifier(parsed.sessionId) ||
      typeof parsed.bankUuid !== 'string' || !PdfReviewSessionCodec.isUuid(parsed.bankUuid) ||
      typeof parsed.bankName !== 'string' || typeof parsed.subject !== 'string' ||
      typeof parsed.pdfPath !== 'string' || typeof parsed.accountId !== 'string' ||
      parsed.accountId.trim().length === 0 || !Array.isArray(parsed.questions) ||
      !Array.isArray(parsed.failures)) {
      throw new Error('AI 导入保存检查点字段无效')
    }
    const source: PdfReviewSource = PdfReviewSessionCodec.validateSource(parsed.source)
    const stage: PdfReviewSaveStage = PdfReviewSessionCodec.validateStage(parsed.saveStage)
    const questions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
    const questionIds: Set<string> = new Set<string>()
    for (let index: number = 0; index < parsed.questions.length; index++) {
      const question: PdfReviewQuestion = parsed.questions[index]
      if (question === null || typeof question.draftQuestionId !== 'string' ||
        typeof question.questionUuid !== 'string' ||
        !PdfReviewSessionCodec.isUuid(question.questionUuid) ||
        questionIds.has(question.questionUuid) || typeof question.label !== 'string' ||
        typeof question.question !== 'string' || typeof question.answer !== 'string' ||
        typeof question.analysis !== 'string' || !Number.isSafeInteger(question.pageStart) ||
        !Number.isSafeInteger(question.pageEnd) || typeof question.confidence !== 'number' ||
        !Number.isFinite(question.confidence) || typeof question.reviewRequired !== 'boolean' ||
        !Array.isArray(question.options) || !Array.isArray(question.images)) {
        throw new Error('AI 导入保存检查点题目无效')
      }
      questionIds.add(question.questionUuid)
      const options: Array<PdfReviewOption> = new Array<PdfReviewOption>()
      for (let optionIndex: number = 0; optionIndex < question.options.length; optionIndex++) {
        const option: PdfReviewOption = question.options[optionIndex]
        if (option === null || typeof option.key !== 'string' || typeof option.value !== 'string') {
          throw new Error('AI 导入保存检查点选项无效')
        }
        options.push(new PdfReviewOption(option.key, option.value))
      }
      const images: Array<PdfReviewImage> = new Array<PdfReviewImage>()
      for (let imageIndex: number = 0; imageIndex < question.images.length; imageIndex++) {
        const image: PdfReviewImage = question.images[imageIndex]
        if (image === null || typeof image.remoteArtifactId !== 'string' ||
          typeof image.localPath !== 'string' || typeof image.sha256 !== 'string' ||
          !Number.isSafeInteger(image.size) || typeof image.contentType !== 'string' ||
          !Number.isSafeInteger(image.sortOrder) || image.sortOrder < 0) {
          throw new Error('AI 导入保存检查点图片无效')
        }
        images.push(new PdfReviewImage(image.remoteArtifactId, image.localPath, image.sha256,
          image.size, image.contentType, image.sortOrder))
      }
      questions.push(new PdfReviewQuestion(question.draftQuestionId, question.questionUuid,
        question.label, PdfReviewSessionCodec.validateQuestionType(question.type),
        question.question, options, question.answer, question.analysis, question.pageStart,
        question.pageEnd, question.confidence, question.reviewRequired, images))
    }
    const failures: Array<PdfReviewFailure> = new Array<PdfReviewFailure>()
    for (let index: number = 0; index < parsed.failures.length; index++) {
      const failure: PdfReviewFailure = parsed.failures[index]
      if (failure === null || !Number.isSafeInteger(failure.pageNumber) ||
        typeof failure.message !== 'string' || typeof failure.evidencePath !== 'string') {
        throw new Error('AI 导入保存检查点失败记录无效')
      }
      failures.push(new PdfReviewFailure(failure.pageNumber,
        PdfReviewSessionCodec.validateErrorCode(failure.code), failure.message,
        failure.evidencePath))
    }
    return new PdfReviewSession(parsed.sessionId, source, parsed.bankUuid, parsed.bankName,
      parsed.subject, parsed.pdfPath, parsed.accountId, questions, failures, stage)
  }

  private static validateSource(value: PdfReviewSource): PdfReviewSource {
    if (value === PdfReviewSource.AI || value === PdfReviewSource.CLOUD) return value
    throw new Error('AI 导入保存检查点来源无效')
  }

  private static validateStage(value: PdfReviewSaveStage): PdfReviewSaveStage {
    if (value === PdfReviewSaveStage.TEXT_SAVING || value === PdfReviewSaveStage.TEXT_SAVED ||
      value === PdfReviewSaveStage.COMPLETE) return value
    throw new Error('AI 导入保存检查点阶段无效')
  }

  private static validateQuestionType(value: AiQuestionType): AiQuestionType {
    if (value === AiQuestionType.SINGLE_CHOICE || value === AiQuestionType.BLANK ||
      value === AiQuestionType.SHORT_ANSWER || value === AiQuestionType.UNKNOWN) return value
    throw new Error('AI 导入保存检查点题型无效')
  }

  private static validateErrorCode(value: AiImportErrorCode): AiImportErrorCode {
    if (value === AiImportErrorCode.INVALID_BASE_URL || value === AiImportErrorCode.MISSING_API_KEY ||
      value === AiImportErrorCode.MISSING_MODEL || value === AiImportErrorCode.NETWORK_UNAVAILABLE ||
      value === AiImportErrorCode.TLS_FAILED || value === AiImportErrorCode.AUTH_FAILED ||
      value === AiImportErrorCode.ENDPOINT_OR_MODEL_NOT_FOUND ||
      value === AiImportErrorCode.RATE_LIMITED || value === AiImportErrorCode.PROVIDER_UNAVAILABLE ||
      value === AiImportErrorCode.TIMEOUT || value === AiImportErrorCode.RESPONSE_TOO_LARGE ||
      value === AiImportErrorCode.INVALID_CONTENT_TYPE || value === AiImportErrorCode.INVALID_JSON ||
      value === AiImportErrorCode.NO_QUESTIONS || value === AiImportErrorCode.LATEX_INVALID ||
      value === AiImportErrorCode.CANCELLED) return value
    throw new Error('AI 导入保存检查点错误码无效')
  }

  private static isIdentifier(value: string): boolean {
    return /^[A-Za-z0-9._:-]{1,160}$/.test(value)
  }

  private static isUuid(value: string): boolean {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
  }
}

export class PdfReviewSessionStore {
  private static sessions: Map<string, PdfReviewSession> = new Map<string, PdfReviewSession>()
  private static durableOperationTail: Promise<void> = Promise.resolve()

  static put(session: PdfReviewSession): void {
    PdfReviewSessionStore.assertAllowedUpdate(session)
    PdfReviewSessionStore.sessions.set(session.sessionId, PdfReviewSessionStore.copyOf(session))
  }

  static putCleanupResult(session: PdfReviewSession): void {
    if (session.saveStage !== PdfReviewSaveStage.COMPLETE) {
      throw new Error('只有已完成会话可以记录缓存清理结果')
    }
    PdfReviewSessionStore.sessions.set(session.sessionId, PdfReviewSessionStore.copyOf(session))
  }

  static get(sessionId: string): PdfReviewSession | null {
    const session: PdfReviewSession | undefined = PdfReviewSessionStore.sessions.get(sessionId)
    return session === undefined ? null : PdfReviewSessionStore.copyOf(session)
  }

  static remove(sessionId: string): void {
    PdfReviewSessionStore.sessions.delete(sessionId)
  }

  static clearMemory(): void {
    PdfReviewSessionStore.sessions.clear()
  }

  static async putDurable(context: Context, session: PdfReviewSession): Promise<void> {
    if (session.saveStage === PdfReviewSaveStage.DRAFT) {
      throw new Error('草稿阶段不能写入保存检查点')
    }
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    PdfReviewSessionStore.assertAllowedUpdate(snapshot)
    const encoded: string = PdfReviewSessionCodec.encode(snapshot)
    await PdfReviewSessionStore.runDurableExclusive(async (): Promise<void> => {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, REVIEW_CHECKPOINT_PREFERENCES)
      const pendingIds: Array<string> = await PdfReviewSessionStore.pendingIdsFromStore(store)
      if (pendingIds.indexOf(snapshot.sessionId) < 0) {
        if (pendingIds.length >= MAX_PENDING_CHECKPOINTS) {
          throw new Error('待恢复 AI 导入任务数量超过限制')
        }
        pendingIds.push(snapshot.sessionId)
        pendingIds.sort()
      }
      await store.put(REVIEW_CHECKPOINT_PREFIX + snapshot.sessionId, encoded)
      await store.put(REVIEW_CHECKPOINT_INDEX_KEY,
        PdfReviewSessionStore.encodePendingIds(pendingIds))
      await store.flush()
    })
  }

  static async getDurable(context: Context, sessionId: string): Promise<PdfReviewSession | null> {
    if (!/^[A-Za-z0-9._:-]{1,160}$/.test(sessionId)) {
      throw new Error('AI 导入会话标识无效')
    }
    return PdfReviewSessionStore.runDurableExclusive(async (): Promise<PdfReviewSession | null> => {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, REVIEW_CHECKPOINT_PREFERENCES)
      const stored: preferences.ValueType =
        await store.get(REVIEW_CHECKPOINT_PREFIX + sessionId, '')
      if (typeof stored !== 'string' || stored.length === 0) {
        return null
      }
      return PdfReviewSessionCodec.decode(stored, sessionId)
    })
  }

  static async pendingDurableSessionIds(context: Context): Promise<Array<string>> {
    return PdfReviewSessionStore.runDurableExclusive(async (): Promise<Array<string>> => {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, REVIEW_CHECKPOINT_PREFERENCES)
      return PdfReviewSessionStore.pendingIdsFromStore(store)
    })
  }

  static async removeDurable(context: Context, sessionId: string): Promise<void> {
    if (!/^[A-Za-z0-9._:-]{1,160}$/.test(sessionId)) {
      throw new Error('AI 导入会话标识无效')
    }
    await PdfReviewSessionStore.runDurableExclusive(async (): Promise<void> => {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, REVIEW_CHECKPOINT_PREFERENCES)
      const pendingIds: Array<string> = await PdfReviewSessionStore.pendingIdsFromStore(store)
      const index: number = pendingIds.indexOf(sessionId)
      if (index >= 0) pendingIds.splice(index, 1)
      await store.delete(REVIEW_CHECKPOINT_PREFIX + sessionId)
      await store.put(REVIEW_CHECKPOINT_INDEX_KEY,
        PdfReviewSessionStore.encodePendingIds(pendingIds))
      await store.flush()
    })
  }

  static async pruneMissingPendingId(context: Context, sessionId: string): Promise<void> {
    if (!/^[A-Za-z0-9._:-]{1,160}$/.test(sessionId)) {
      throw new Error('AI 导入会话标识无效')
    }
    await PdfReviewSessionStore.runDurableExclusive(async (): Promise<void> => {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, REVIEW_CHECKPOINT_PREFERENCES)
      const stored: preferences.ValueType =
        await store.get(REVIEW_CHECKPOINT_PREFIX + sessionId, '')
      if (typeof stored !== 'string') {
        throw new Error('AI 导入保存检查点类型无效')
      }
      if (stored.length > 0) return
      const pendingIds: Array<string> = await PdfReviewSessionStore.pendingIdsFromStore(store)
      const index: number = pendingIds.indexOf(sessionId)
      if (index < 0) return
      pendingIds.splice(index, 1)
      await store.put(REVIEW_CHECKPOINT_INDEX_KEY,
        PdfReviewSessionStore.encodePendingIds(pendingIds))
      await store.flush()
    })
  }

  static copyOf(source: PdfReviewSession): PdfReviewSession {
    const questions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
    for (let questionIndex: number = 0; questionIndex < source.questions.length; questionIndex++) {
      const question: PdfReviewQuestion = source.questions[questionIndex]
      const options: Array<PdfReviewOption> = new Array<PdfReviewOption>()
      for (let optionIndex: number = 0; optionIndex < question.options.length; optionIndex++) {
        const option: PdfReviewOption = question.options[optionIndex]
        options.push(new PdfReviewOption(option.key, option.value))
      }
      const images: Array<PdfReviewImage> = new Array<PdfReviewImage>()
      for (let imageIndex: number = 0; imageIndex < question.images.length; imageIndex++) {
        const image: PdfReviewImage = question.images[imageIndex]
        images.push(new PdfReviewImage(image.remoteArtifactId, image.localPath, image.sha256,
          image.size, image.contentType, image.sortOrder))
      }
      questions.push(new PdfReviewQuestion(question.draftQuestionId, question.questionUuid,
        question.label, question.type, question.question, options, question.answer, question.analysis,
        question.pageStart, question.pageEnd, question.confidence, question.reviewRequired, images))
    }
    const failures: Array<PdfReviewFailure> = new Array<PdfReviewFailure>()
    for (let index: number = 0; index < source.failures.length; index++) {
      const failure: PdfReviewFailure = source.failures[index]
      failures.push(new PdfReviewFailure(failure.pageNumber, failure.code,
        failure.message, failure.evidencePath))
    }
    return new PdfReviewSession(source.sessionId, source.source, source.bankUuid, source.bankName,
      source.subject, source.pdfPath, source.accountId, questions, failures, source.saveStage)
  }

  private static isAllowedLockedUpdate(current: PdfReviewSession,
    next: PdfReviewSession): boolean {
    if (PdfReviewSessionStore.frozenContent(current) !==
      PdfReviewSessionStore.frozenContent(next)) {
      return false
    }
    if (current.saveStage === next.saveStage) return true
    if (current.saveStage === PdfReviewSaveStage.TEXT_SAVING) {
      return next.saveStage === PdfReviewSaveStage.TEXT_SAVED
    }
    if (current.saveStage === PdfReviewSaveStage.TEXT_SAVED) {
      return next.saveStage === PdfReviewSaveStage.COMPLETE
    }
    return false
  }

  private static assertAllowedUpdate(session: PdfReviewSession): void {
    const current: PdfReviewSession | undefined =
      PdfReviewSessionStore.sessions.get(session.sessionId)
    if (current !== undefined && current.saveStage !== PdfReviewSaveStage.DRAFT &&
      !PdfReviewSessionStore.isAllowedLockedUpdate(current, session)) {
      throw new Error('AI 导入文字保存开始后不能编辑审核内容')
    }
  }

  private static frozenContent(session: PdfReviewSession): string {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    snapshot.saveStage = PdfReviewSaveStage.DRAFT
    return JSON.stringify(snapshot)
  }

  private static async pendingIdsFromStore(
    store: preferences.Preferences): Promise<Array<string>> {
    const value: preferences.ValueType = await store.get(REVIEW_CHECKPOINT_INDEX_KEY, '')
    if (typeof value !== 'string') {
      throw new Error('AI 导入恢复索引类型无效')
    }
    return PdfReviewSessionStore.validatePendingIds(value)
  }

  private static validatePendingIds(encoded: string): Array<string> {
    if (encoded.length === 0) return new Array<string>()
    if (encoded.length > 20480) throw new Error('AI 导入恢复索引过大')
    const ids: Array<string> = encoded.split('\n')
    if (ids.length > MAX_PENDING_CHECKPOINTS) {
      throw new Error('AI 导入恢复索引数量无效')
    }
    const seen: Set<string> = new Set<string>()
    let previous: string = ''
    for (let index: number = 0; index < ids.length; index++) {
      const id: string = ids[index]
      if (!/^[A-Za-z0-9._:-]{1,160}$/.test(id) || seen.has(id) ||
        (index > 0 && previous.localeCompare(id) >= 0)) {
        throw new Error('AI 导入恢复索引内容无效')
      }
      seen.add(id)
      previous = id
    }
    return ids
  }

  private static encodePendingIds(ids: Array<string>): string {
    return ids.join('\n')
  }

  private static async runDurableExclusive<T>(action: () => Promise<T>): Promise<T> {
    const previous: Promise<void> = PdfReviewSessionStore.durableOperationTail
    let release: () => void = (): void => {}
    const gate: Promise<void> = new Promise<void>((resolve): void => {
      release = resolve
    })
    PdfReviewSessionStore.durableOperationTail = previous.then((): Promise<void> => gate,
      (): Promise<void> => gate)
    try {
      await previous
    } catch {
    }
    try {
      return await action()
    } finally {
      release()
    }
  }
}
