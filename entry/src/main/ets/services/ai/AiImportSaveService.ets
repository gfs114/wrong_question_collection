import { Context } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { hash } from '@kit.CoreFileKit'
import fs from '@ohos.file.fs'
import { AccountSessionState } from '../../models/AccountSession'
import { DeviceQuestionImage } from '../../models/CloudCacheModels'
import { Question } from '../../models/Question'
import { QuestionBank } from '../../models/QuestionBank'
import { AiQuestionType } from '../../models/ai/AiImportModels'
import { AccountSessionService } from '../AccountSessionService'
import { CloudQuestionRepository } from '../CloudQuestionRepository'
import {
  DeviceImageScope,
  DeviceImageStore,
  DeviceImageStoreError,
  DeviceImageWriteOutcome
} from '../DeviceImageStore'
import { PdfImportService } from '../PdfImportService'
import {
  PdfReviewOption,
  PdfReviewImage,
  PdfReviewQuestion,
  PdfReviewSavePolicy,
  PdfReviewSaveStage,
  PdfReviewSession
} from '../review/PdfReviewModels'
import { PdfReviewSessionStore } from '../review/PdfReviewSession'
import { PdfPageImageEncoder } from './PdfPageImageEncoder'

export interface AiImportBankWriterPort {
  write(context: Context, bank: QuestionBank, expectedAccountId: string): Promise<void>
}

export interface AiImportImageWriterPort {
  write(context: Context, session: PdfReviewSession): Promise<void>
}

export interface AiImportImagePreflightPort {
  preflight(context: Context, session: PdfReviewSession): Promise<PdfReviewSession>
}

export interface AiImportAccountPort {
  require(context: Context, expectedAccountId: string): Promise<void>
}

export interface AiImportCheckpointPort {
  load(context: Context, sessionId: string): Promise<PdfReviewSession | null>
  save(context: Context, session: PdfReviewSession): Promise<void>
  remove(context: Context, sessionId: string): Promise<void>
  pruneMissing(context: Context, sessionId: string): Promise<void>
  pending(context: Context): Promise<Array<string>>
}

export interface AiImportCacheCleanupPort {
  cleanup(context: Context, session: PdfReviewSession,
    recoveredCheckpoint: boolean): Promise<void>
}

class DefaultAiImportBankWriter implements AiImportBankWriterPort {
  async write(context: Context, bank: QuestionBank, expectedAccountId: string): Promise<void> {
    await CloudQuestionRepository.createBankWithIds(bank, context, expectedAccountId)
  }
}

class DefaultAiImportImageWriter implements AiImportImageWriterPort {
  async write(context: Context, session: PdfReviewSession): Promise<void> {
    await AiImportSaveService.writeImages(context, session)
  }
}

class DefaultAiImportImagePreflight implements AiImportImagePreflightPort {
  async preflight(context: Context, session: PdfReviewSession): Promise<PdfReviewSession> {
    return AiImportSaveService.preflightImages(context, session)
  }
}

class DefaultAiImportAccount implements AiImportAccountPort {
  async require(context: Context, expectedAccountId: string): Promise<void> {
    await AccountSessionService.requireAccount(context, expectedAccountId)
  }
}

class DefaultAiImportCheckpoint implements AiImportCheckpointPort {
  async load(context: Context, sessionId: string): Promise<PdfReviewSession | null> {
    return PdfReviewSessionStore.getDurable(context, sessionId)
  }

  async save(context: Context, session: PdfReviewSession): Promise<void> {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    await AccountSessionService.runExpectedAccountLocalExclusive(context, snapshot.accountId,
      (): Promise<void> => PdfReviewSessionStore.putDurable(context, snapshot))
  }

  async remove(context: Context, sessionId: string): Promise<void> {
    const durable: PdfReviewSession | null =
      await PdfReviewSessionStore.getDurable(context, sessionId)
    if (durable === null) {
      await PdfReviewSessionStore.pruneMissingPendingId(context, sessionId)
      return
    }
    await AccountSessionService.runExpectedAccountLocalExclusive(context, durable.accountId,
      (): Promise<void> => PdfReviewSessionStore.removeDurable(context, sessionId))
  }

  async pruneMissing(context: Context, sessionId: string): Promise<void> {
    await PdfReviewSessionStore.pruneMissingPendingId(context, sessionId)
  }

  async pending(context: Context): Promise<Array<string>> {
    return PdfReviewSessionStore.pendingDurableSessionIds(context)
  }
}

class DefaultAiImportCacheCleanup implements AiImportCacheCleanupPort {
  async cleanup(context: Context, session: PdfReviewSession,
    recoveredCheckpoint: boolean): Promise<void> {
    await AiImportSaveService.removeSessionCache(context, session, recoveredCheckpoint)
  }
}

class SourceImageSnapshot {
  inode: bigint
  size: number
  sha256: string

  constructor(inode: bigint, size: number, sha256: string) {
    this.inode = inode
    this.size = size
    this.sha256 = sha256
  }
}

class PreparedFinalFile {
  path: string
  inode: bigint
  size: number
  sha256: string

  constructor(path: string, inode: bigint, size: number, sha256: string) {
    this.path = path
    this.inode = inode
    this.size = size
    this.sha256 = sha256
  }
}

class PreparedImageBatch {
  mappings: Array<DeviceQuestionImage>
  newlyCopied: Array<PreparedFinalFile>
  accountDirectory: string

  constructor(mappings: Array<DeviceQuestionImage>, newlyCopied: Array<PreparedFinalFile>,
    accountDirectory: string) {
    this.mappings = mappings
    this.newlyCopied = newlyCopied
    this.accountDirectory = accountDirectory
  }
}

export class AiImportSaveService {
  private static tempSequence: number = 0
  private static imageOperationTail: Promise<void> = Promise.resolve()
  private static sessionOperationTails: Map<string, Promise<void>> =
    new Map<string, Promise<void>>()
  private bankWriter: AiImportBankWriterPort
  private imageWriter: AiImportImageWriterPort
  private account: AiImportAccountPort
  private checkpoint: AiImportCheckpointPort
  private cacheCleanup: AiImportCacheCleanupPort
  private imagePreflight: AiImportImagePreflightPort

  constructor(bankWriter: AiImportBankWriterPort, imageWriter: AiImportImageWriterPort,
    account: AiImportAccountPort, checkpoint?: AiImportCheckpointPort,
    cacheCleanup?: AiImportCacheCleanupPort, imagePreflight?: AiImportImagePreflightPort) {
    this.bankWriter = bankWriter
    this.imageWriter = imageWriter
    this.account = account
    this.checkpoint = checkpoint === undefined ? new DefaultAiImportCheckpoint() : checkpoint
    this.cacheCleanup = cacheCleanup === undefined ?
      new DefaultAiImportCacheCleanup() : cacheCleanup
    this.imagePreflight = imagePreflight === undefined ?
      new DefaultAiImportImagePreflight() : imagePreflight
  }

  static async save(context: Context, session: PdfReviewSession): Promise<PdfReviewSession> {
    const callerSnapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    AiImportSaveService.validateSessionIdentifiers(callerSnapshot)
    const service: AiImportSaveService = new AiImportSaveService(
      new DefaultAiImportBankWriter(), new DefaultAiImportImageWriter(),
      new DefaultAiImportAccount(), new DefaultAiImportCheckpoint(),
      new DefaultAiImportCacheCleanup(), new DefaultAiImportImagePreflight())
    return AiImportSaveService.runSessionExclusive(callerSnapshot.sessionId,
      (): Promise<PdfReviewSession> => service.saveLifecycleExclusive(
        context, session, callerSnapshot, false))
  }

  static async restore(context: Context, sessionId: string): Promise<PdfReviewSession | null> {
    const service: AiImportSaveService = new AiImportSaveService(
      new DefaultAiImportBankWriter(), new DefaultAiImportImageWriter(),
      new DefaultAiImportAccount(), new DefaultAiImportCheckpoint(),
      new DefaultAiImportCacheCleanup(), new DefaultAiImportImagePreflight())
    return service.restoreSession(context, sessionId)
  }

  static async recoverPending(context: Context): Promise<number> {
    const state: AccountSessionState = await AccountSessionService.state(context)
    if (!state.signedIn || state.userId.trim().length === 0) return 0
    const service: AiImportSaveService = new AiImportSaveService(
      new DefaultAiImportBankWriter(), new DefaultAiImportImageWriter(),
      new DefaultAiImportAccount(), new DefaultAiImportCheckpoint(),
      new DefaultAiImportCacheCleanup(), new DefaultAiImportImagePreflight())
    return service.recoverPendingForAccount(context, state.userId)
  }

  async saveSession(context: Context, session: PdfReviewSession): Promise<PdfReviewSession> {
    const callerSnapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    AiImportSaveService.validateSessionIdentifiers(callerSnapshot)
    return AiImportSaveService.runSessionExclusive(callerSnapshot.sessionId,
      (): Promise<PdfReviewSession> =>
        this.saveSessionExclusive(context, session, callerSnapshot))
  }

  private async saveSessionExclusive(context: Context, session: PdfReviewSession,
    callerSnapshot: PdfReviewSession): Promise<PdfReviewSession> {
    const sessionId: string = callerSnapshot.sessionId
    const durable: PdfReviewSession | null = await this.checkpoint.load(context, sessionId)
    let working: PdfReviewSession
    if (durable !== null) {
      AiImportSaveService.validateSessionIdentifiers(durable)
      if (durable.sessionId !== sessionId || durable.accountId !== callerSnapshot.accountId ||
        durable.bankUuid !== callerSnapshot.bankUuid) {
        throw new Error('AI 导入保存检查点与当前会话不一致')
      }
      await this.account.require(context, durable.accountId)
      working = PdfReviewSessionStore.copyOf(durable)
    } else {
      const completed: PdfReviewSession | null = PdfReviewSessionStore.get(sessionId)
      if (completed !== null && completed.saveStage === PdfReviewSaveStage.COMPLETE) {
        AiImportSaveService.validateSessionIdentifiers(completed)
        if (completed.sessionId !== sessionId || completed.accountId !== callerSnapshot.accountId ||
          completed.bankUuid !== callerSnapshot.bankUuid) {
          throw new Error('AI 导入已完成会话与当前会话不一致')
        }
        await this.account.require(context, completed.accountId)
        return AiImportSaveService.applyCompleteResult(session,
          AiImportSaveService.sanitizedCompleteSession(completed))
      }
      if (callerSnapshot.saveStage === PdfReviewSaveStage.COMPLETE) {
        await this.account.require(context, callerSnapshot.accountId)
        return AiImportSaveService.applyCompleteResult(session,
          AiImportSaveService.sanitizedCompleteSession(callerSnapshot))
      }
      if (callerSnapshot.saveStage !== PdfReviewSaveStage.DRAFT) {
        throw new Error('AI 导入保存检查点缺失')
      }
      await this.account.require(context, callerSnapshot.accountId)
      const preflighted: PdfReviewSession = await this.imagePreflight.preflight(
        context, PdfReviewSessionStore.copyOf(callerSnapshot))
      working = AiImportSaveService.acceptPreflightSnapshot(callerSnapshot, preflighted)
      await this.account.require(context, working.accountId)
      working.saveStage = PdfReviewSaveStage.TEXT_SAVING
      await this.checkpoint.save(context, working)
      await this.account.require(context, working.accountId)
      session.saveStage = PdfReviewSaveStage.TEXT_SAVING
      PdfReviewSessionStore.put(working)
    }
    if (working.saveStage === PdfReviewSaveStage.TEXT_SAVING) {
      await this.account.require(context, working.accountId)
      const preflighted: PdfReviewSession = await this.imagePreflight.preflight(
        context, PdfReviewSessionStore.copyOf(working))
      const writeReady: PdfReviewSession =
        AiImportSaveService.acceptPreflightSnapshot(working, preflighted)
      if (JSON.stringify(writeReady) !== JSON.stringify(working)) {
        throw new Error('原题图片在文字保存前发生变化')
      }
      await this.account.require(context, working.accountId)
      const bank: QuestionBank = AiImportSaveService.toBank(working)
      await this.bankWriter.write(context, bank, working.accountId)
      working.saveStage = PdfReviewSaveStage.TEXT_SAVED
      await this.checkpoint.save(context, working)
      await this.account.require(context, working.accountId)
      session.saveStage = PdfReviewSaveStage.TEXT_SAVED
      PdfReviewSessionStore.put(working)
    }
    if (working.saveStage === PdfReviewSaveStage.TEXT_SAVED) {
      await this.account.require(context, working.accountId)
      await this.imageWriter.write(context, PdfReviewSessionStore.copyOf(working))
      working.saveStage = PdfReviewSaveStage.COMPLETE
      await this.checkpoint.save(context, working)
      await this.account.require(context, working.accountId)
      session.saveStage = PdfReviewSaveStage.COMPLETE
      PdfReviewSessionStore.put(working)
    }
    return PdfReviewSessionStore.copyOf(working)
  }

  async finishCheckpoint(context: Context, sessionId: string): Promise<void> {
    await AiImportSaveService.runSessionExclusive(sessionId, async (): Promise<void> => {
      const durable: PdfReviewSession | null = await this.checkpoint.load(context, sessionId)
      if (durable === null) {
        await this.checkpoint.pruneMissing(context, sessionId)
        return
      }
      AiImportSaveService.validateSessionIdentifiers(durable)
      await this.account.require(context, durable.accountId)
      await this.checkpoint.remove(context, sessionId)
    })
  }

  async restoreSession(context: Context, sessionId: string): Promise<PdfReviewSession | null> {
    return AiImportSaveService.runSessionExclusive(sessionId,
      (): Promise<PdfReviewSession | null> =>
        this.restoreSessionExclusive(context, sessionId))
  }

  private async restoreSessionExclusive(context: Context,
    sessionId: string): Promise<PdfReviewSession | null> {
    const restored: PdfReviewSession | null = await this.checkpoint.load(context, sessionId)
    if (restored === null) return null
    AiImportSaveService.validateSessionIdentifiers(restored)
    await this.account.require(context, restored.accountId)
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(restored)
    PdfReviewSessionStore.put(snapshot)
    return PdfReviewSessionStore.copyOf(snapshot)
  }

  async recoverPendingForAccount(context: Context, expectedAccountId: string): Promise<number> {
    const pendingIds: Array<string> = await this.checkpoint.pending(context)
    let completed: number = 0
    for (let index: number = 0; index < pendingIds.length; index++) {
      const sessionId: string = pendingIds[index]
      try {
        const recovered: boolean = await AiImportSaveService.runSessionExclusive(sessionId,
          (): Promise<boolean> =>
            this.recoverPendingSessionExclusive(context, sessionId, expectedAccountId))
        if (recovered) completed++
      } catch {
      }
    }
    return completed
  }

  private async recoverPendingSessionExclusive(context: Context, sessionId: string,
    expectedAccountId: string): Promise<boolean> {
    const restored: PdfReviewSession | null = await this.checkpoint.load(context, sessionId)
    if (restored === null) {
      await this.checkpoint.pruneMissing(context, sessionId)
      return false
    }
    AiImportSaveService.validateSessionIdentifiers(restored)
    if (restored.accountId !== expectedAccountId) return false
    await this.account.require(context, expectedAccountId)
    const recoverySession: PdfReviewSession = PdfReviewSessionStore.copyOf(restored)
    PdfReviewSessionStore.put(recoverySession)
    const callerSnapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(recoverySession)
    await this.saveLifecycleExclusive(context, recoverySession, callerSnapshot, true)
    return true
  }

  private async saveLifecycleExclusive(context: Context, session: PdfReviewSession,
    callerSnapshot: PdfReviewSession, recoveredCheckpoint: boolean): Promise<PdfReviewSession> {
    const saved: PdfReviewSession =
      await this.saveSessionExclusive(context, session, callerSnapshot)
    if (saved.saveStage !== PdfReviewSaveStage.COMPLETE) return saved
    const remaining: PdfReviewSession | null =
      await this.checkpoint.load(context, saved.sessionId)
    if (remaining === null) {
      await this.account.require(context, saved.accountId)
      PdfReviewSessionStore.putCleanupResult(saved)
      return AiImportSaveService.applyCompleteResult(session, saved)
    }
    await this.account.require(context, saved.accountId)
    await this.cacheCleanup.cleanup(context, saved, recoveredCheckpoint)
    await this.account.require(context, saved.accountId)
    await this.checkpoint.remove(context, saved.sessionId)
    await this.account.require(context, saved.accountId)
    PdfReviewSessionStore.putCleanupResult(saved)
    return AiImportSaveService.applyCompleteResult(session, saved)
  }

  private static sanitizedCompleteSession(session: PdfReviewSession): PdfReviewSession {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    snapshot.pdfPath = ''
    for (let questionIndex: number = 0; questionIndex < snapshot.questions.length; questionIndex++) {
      const images: Array<PdfReviewImage> = snapshot.questions[questionIndex].images
      for (let imageIndex: number = 0; imageIndex < images.length; imageIndex++) {
        images[imageIndex].localPath = ''
      }
    }
    for (let index: number = 0; index < snapshot.failures.length; index++) {
      snapshot.failures[index].evidencePath = ''
    }
    return snapshot
  }

  private static applyCompleteResult(session: PdfReviewSession,
    completed: PdfReviewSession): PdfReviewSession {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(completed)
    session.sessionId = snapshot.sessionId
    session.source = snapshot.source
    session.bankUuid = snapshot.bankUuid
    session.bankName = snapshot.bankName
    session.subject = snapshot.subject
    session.pdfPath = snapshot.pdfPath
    session.accountId = snapshot.accountId
    session.questions = snapshot.questions
    session.failures = snapshot.failures
    session.saveStage = snapshot.saveStage
    return PdfReviewSessionStore.copyOf(snapshot)
  }

  static async abandon(context: Context, session: PdfReviewSession): Promise<void> {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    const checkpoint: AiImportCheckpointPort = new DefaultAiImportCheckpoint()
    const account: AiImportAccountPort = new DefaultAiImportAccount()
    await AiImportSaveService.runSessionExclusive(snapshot.sessionId, async (): Promise<void> => {
      const durable: PdfReviewSession | null = await checkpoint.load(context, snapshot.sessionId)
      if (!PdfReviewSavePolicy.canAbandon(snapshot.saveStage) || durable !== null) {
        throw new Error('题目文字已保存，请完成原题图片保存')
      }
      await account.require(context, snapshot.accountId)
      await AiImportSaveService.removeSessionCache(context, snapshot)
      await account.require(context, snapshot.accountId)
      await checkpoint.remove(context, snapshot.sessionId)
      await account.require(context, snapshot.accountId)
      PdfReviewSessionStore.remove(snapshot.sessionId)
    })
  }

  static async preflightImages(context: Context,
    session: PdfReviewSession): Promise<PdfReviewSession> {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    const filesDir: string = context.filesDir
    const cacheDir: string = context.cacheDir
    AiImportSaveService.validateSessionIdentifiers(snapshot)
    const accountDirectory: string =
      await AiImportSaveService.preflightDestinationDirectory(filesDir, snapshot.accountId)
    const keys: Set<string> = new Set<string>()
    for (let questionIndex: number = 0;
      questionIndex < snapshot.questions.length; questionIndex++) {
      const question: PdfReviewQuestion = snapshot.questions[questionIndex]
      for (let imageIndex: number = 0; imageIndex < question.images.length; imageIndex++) {
        const sourceImage: PdfReviewImage = question.images[imageIndex]
        if (sourceImage.contentType !== 'image/jpeg' || sourceImage.localPath.length === 0 ||
          !Number.isSafeInteger(sourceImage.size) || sourceImage.size < 0 ||
          !Number.isSafeInteger(sourceImage.sortOrder) || sourceImage.sortOrder < 0 ||
          (sourceImage.sha256.length > 0 && !/^[a-f0-9]{64}$/.test(sourceImage.sha256))) {
          throw new Error('原题图片元数据无效')
        }
        const key: string = question.questionUuid + ':' + sourceImage.sortOrder.toString()
        if (keys.has(key)) throw new Error('原题图片批次包含重复键')
        keys.add(key)
        const inspected: SourceImageSnapshot = await AiImportSaveService.inspectSourceImage(
          cacheDir, snapshot.sessionId, sourceImage.localPath)
        if (sourceImage.sha256.length > 0 && sourceImage.sha256 !== inspected.sha256) {
          throw new Error('原题图片 SHA-256 校验失败')
        }
        if (sourceImage.size !== 0 && sourceImage.size !== inspected.size) {
          throw new Error('原题图片大小校验失败')
        }
        sourceImage.sha256 = inspected.sha256
        sourceImage.size = inspected.size
        const finalName: string = 'ai_import_' + question.questionUuid + '_' +
          sourceImage.sortOrder.toString() + '_' + inspected.sha256 + '.jpg'
        const finalPath: string = accountDirectory + '/' + finalName
        if (!AiImportSaveService.isDirectChild(accountDirectory, finalPath)) {
          throw new Error('原题图片目标路径无效')
        }
        const existing: fs.Stat | null = await AiImportSaveService.lstatIfPresent(finalPath)
        if (existing !== null && !(await AiImportSaveService.matchesRegularFile(
          finalPath, inspected.size, inspected.sha256))) {
          throw new Error('原题图片目标已存在且内容不匹配')
        }
      }
    }
    return PdfReviewSessionStore.copyOf(snapshot)
  }

  static async prepareImages(context: Context,
    session: PdfReviewSession): Promise<Array<DeviceQuestionImage>> {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    return AiImportSaveService.runImageExclusive(async (): Promise<Array<DeviceQuestionImage>> => {
      const prepared: PreparedImageBatch =
        await AiImportSaveService.prepareImageBatch(context, snapshot)
      return prepared.mappings
    })
  }

  static async writeImages(context: Context, session: PdfReviewSession): Promise<void> {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    const filesDir: string = context.filesDir
    await AiImportSaveService.runImageExclusive(async (): Promise<void> => {
      const prepared: PreparedImageBatch =
        await AiImportSaveService.prepareImageBatch(context, snapshot)
      try {
        await DeviceImageStore.saveBatch(context, prepared.mappings)
      } catch (err) {
        const primaryError: Error =
          AiImportSaveService.normalizeError(err, '原题图片映射保存失败')
        if (primaryError instanceof DeviceImageStoreError &&
          !AiImportSaveService.shouldCleanupPreparedFinals(primaryError)) {
          throw primaryError
        }
        let cleanupError: Error | null = null
        try {
          await AiImportSaveService.cleanupPreparedFinals(
            filesDir, prepared.accountDirectory, prepared.newlyCopied)
        } catch (err) {
          cleanupError = AiImportSaveService.normalizeError(err, '新复制图片清理失败')
        }
        if (cleanupError !== null) {
          throw new Error(primaryError.message + '；后续清理也失败：' + cleanupError.message)
        }
        throw primaryError
      }
    })
  }

  static shouldCleanupPreparedFinals(error: DeviceImageStoreError): boolean {
    return error.outcome !== DeviceImageWriteOutcome.UNKNOWN
  }

  private static async runImageExclusive<T>(action: () => Promise<T>): Promise<T> {
    const previous: Promise<void> = AiImportSaveService.imageOperationTail
    let release: () => void = (): void => {}
    const gate: Promise<void> = new Promise<void>((resolve): void => {
      release = resolve
    })
    AiImportSaveService.imageOperationTail = previous.then((): Promise<void> => gate,
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

  private static async runSessionExclusive<T>(sessionId: string,
    action: () => Promise<T>): Promise<T> {
    if (!AiImportSaveService.isIdentifier(sessionId)) {
      throw new Error('AI 导入会话标识无效')
    }
    const found: Promise<void> | undefined =
      AiImportSaveService.sessionOperationTails.get(sessionId)
    const previous: Promise<void> = found === undefined ? Promise.resolve() : found
    let release: () => void = (): void => {}
    const gate: Promise<void> = new Promise<void>((resolve): void => {
      release = resolve
    })
    const current: Promise<void> = previous.then((): Promise<void> => gate,
      (): Promise<void> => gate)
    AiImportSaveService.sessionOperationTails.set(sessionId, current)
    try {
      await previous
    } catch {
    }
    try {
      return await action()
    } finally {
      release()
      if (AiImportSaveService.sessionOperationTails.get(sessionId) === current) {
        AiImportSaveService.sessionOperationTails.delete(sessionId)
      }
    }
  }

  static async removeSessionCache(context: Context, session: PdfReviewSession,
    recoveredCheckpoint: boolean = false): Promise<void> {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    await AccountSessionService.runExpectedAccountLocalExclusive(context, snapshot.accountId,
      async (): Promise<void> => {
        await AiImportSaveService.removeSessionCacheExclusive(context, snapshot, recoveredCheckpoint)
        session.pdfPath = snapshot.pdfPath
        session.questions = snapshot.questions
        session.failures = snapshot.failures
      })
  }

  private static async removeSessionCacheExclusive(context: Context, session: PdfReviewSession,
    recoveredCheckpoint: boolean): Promise<void> {
    let firstError: Error | null = null
    for (let questionIndex: number = 0; questionIndex < session.questions.length; questionIndex++) {
      const question: PdfReviewQuestion = session.questions[questionIndex]
      for (let imageIndex: number = 0; imageIndex < question.images.length; imageIndex++) {
        const path: string = question.images[imageIndex].localPath
        if (path.length === 0) {
          continue
        }
        try {
          await AiImportSaveService.removeOwnedSessionFile(
            context.cacheDir, session.sessionId, path)
          question.images[imageIndex].localPath = ''
        } catch (err) {
          firstError = AiImportSaveService.appendError(firstError,
            AiImportSaveService.normalizeError(err, 'AI 导入图片清理失败'))
        }
      }
    }
    for (let index: number = 0; index < session.failures.length; index++) {
      const path: string = session.failures[index].evidencePath
      if (path.length === 0) {
        continue
      }
      try {
        await AiImportSaveService.removeOwnedSessionFile(
          context.cacheDir, session.sessionId, path)
        session.failures[index].evidencePath = ''
      } catch (err) {
        firstError = AiImportSaveService.appendError(firstError,
          AiImportSaveService.normalizeError(err, 'AI 导入失败证据清理失败'))
      }
    }
    try {
      await new PdfPageImageEncoder().cleanupSession(context, session.sessionId)
    } catch (err) {
      firstError = AiImportSaveService.appendError(firstError,
        AiImportSaveService.normalizeError(err, 'AI 导入会话缓存清理失败'))
    }
    if (firstError !== null) {
      throw firstError
    }
    if (session.pdfPath.length > 0) {
      let pdfError: Error | null = null
      try {
        await PdfImportService.removeTemporaryPdf(session.pdfPath)
        session.pdfPath = ''
      } catch (err) {
        pdfError = AiImportSaveService.normalizeError(err, 'PDF 临时文件清理失败')
        try {
          if (await PdfImportService.proveTemporaryPdfAbsent(context.cacheDir, session.pdfPath)) {
            session.pdfPath = ''
            pdfError = null
          }
        } catch (absenceErr) {
          pdfError = AiImportSaveService.appendError(pdfError,
            AiImportSaveService.normalizeError(absenceErr, 'PDF 临时文件缺失验证失败'))
        }
      }
      if (pdfError !== null && recoveredCheckpoint) {
        try {
          await PdfImportService.removeRecoveredTemporaryPdf(context.cacheDir, session.pdfPath)
          session.pdfPath = ''
          pdfError = null
        } catch (err) {
          pdfError = AiImportSaveService.appendError(pdfError,
            AiImportSaveService.normalizeError(err, '恢复任务 PDF 临时文件清理失败'))
        }
      }
      if (pdfError !== null) {
        firstError = AiImportSaveService.appendError(firstError, pdfError)
      }
    }
    if (firstError !== null) {
      throw firstError
    }
  }

  private static async prepareImageBatch(context: Context,
    session: PdfReviewSession): Promise<PreparedImageBatch> {
    const snapshotSession: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    const filesDir: string = context.filesDir
    const cacheDir: string = context.cacheDir
    AiImportSaveService.validateSessionIdentifiers(snapshotSession)
    const accountDirectory: string =
      await AiImportSaveService.ensureAccountDirectory(filesDir, snapshotSession.accountId)
    const mappings: Array<DeviceQuestionImage> = new Array<DeviceQuestionImage>()
    const newlyCopied: Array<PreparedFinalFile> = new Array<PreparedFinalFile>()
    const keys: Set<string> = new Set<string>()
    try {
      for (let questionIndex: number = 0;
        questionIndex < snapshotSession.questions.length; questionIndex++) {
        const question: PdfReviewQuestion = snapshotSession.questions[questionIndex]
        for (let imageIndex: number = 0; imageIndex < question.images.length; imageIndex++) {
          const sourceImage: PdfReviewImage = question.images[imageIndex]
          if (!Number.isSafeInteger(sourceImage.sortOrder) || sourceImage.sortOrder < 0) {
            throw new Error('原题图片排序无效')
          }
          const key: string = question.questionUuid + ':' + sourceImage.sortOrder.toString()
          if (keys.has(key)) {
            throw new Error('原题图片批次包含重复键')
          }
          keys.add(key)
          const snapshot: SourceImageSnapshot = await AiImportSaveService.inspectSourceImage(
            cacheDir, snapshotSession.sessionId, sourceImage.localPath)
          if (sourceImage.sha256.length > 0 &&
            (!/^[a-f0-9]{64}$/.test(sourceImage.sha256) || sourceImage.sha256 !== snapshot.sha256)) {
            throw new Error('原题图片 SHA-256 校验失败')
          }
          if (sourceImage.size !== 0 &&
            (!Number.isSafeInteger(sourceImage.size) || sourceImage.size !== snapshot.size)) {
            throw new Error('原题图片大小校验失败')
          }
          const finalName: string = 'ai_import_' + question.questionUuid + '_' +
            sourceImage.sortOrder.toString() + '_' + snapshot.sha256 + '.jpg'
          const finalPath: string = accountDirectory + '/' + finalName
          const reused: boolean = await AiImportSaveService.reuseFinalIfMatching(
            filesDir, accountDirectory, finalPath, snapshot)
          if (!reused) {
            const preparedFinal: PreparedFinalFile = await AiImportSaveService.copyToFinal(
              filesDir, cacheDir, accountDirectory, sourceImage.localPath,
              finalPath, snapshot)
            newlyCopied.push(preparedFinal)
          }
          mappings.push(new DeviceQuestionImage(snapshotSession.accountId, question.questionUuid,
            finalPath, snapshot.sha256, sourceImage.sortOrder))
        }
      }
      return new PreparedImageBatch(mappings, newlyCopied, accountDirectory)
    } catch (err) {
      const primaryError: Error = AiImportSaveService.normalizeError(err, '原题图片准备失败')
      let cleanupError: Error | null = null
      try {
        await AiImportSaveService.cleanupPreparedFinals(
          filesDir, accountDirectory, newlyCopied)
      } catch (err) {
        cleanupError = AiImportSaveService.normalizeError(err, '新复制图片清理失败')
      }
      if (cleanupError !== null) {
        throw new Error(primaryError.message + '；后续清理也失败：' + cleanupError.message)
      }
      throw primaryError
    }
  }

  private static validateSessionIdentifiers(session: PdfReviewSession): void {
    if (!AiImportSaveService.isIdentifier(session.sessionId) || session.accountId.trim().length === 0 ||
      !AiImportSaveService.isUuid(session.bankUuid)) {
      throw new Error('AI 导入会话标识无效')
    }
    const questionIds: Set<string> = new Set<string>()
    for (let index: number = 0; index < session.questions.length; index++) {
      const questionId: string = session.questions[index].questionUuid
      if (!AiImportSaveService.isUuid(questionId) || questionIds.has(questionId)) {
        throw new Error('AI 导入题目标识无效或重复')
      }
      questionIds.add(questionId)
    }
  }

  private static acceptPreflightSnapshot(source: PdfReviewSession,
    verified: PdfReviewSession): PdfReviewSession {
    const sourceSnapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(source)
    const verifiedSnapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(verified)
    AiImportSaveService.validateSessionIdentifiers(sourceSnapshot)
    AiImportSaveService.validateSessionIdentifiers(verifiedSnapshot)
    if (sourceSnapshot.questions.length !== verifiedSnapshot.questions.length) {
      throw new Error('原题图片预检结果与审核会话不一致')
    }
    for (let questionIndex: number = 0;
      questionIndex < sourceSnapshot.questions.length; questionIndex++) {
      const sourceQuestion: PdfReviewQuestion = sourceSnapshot.questions[questionIndex]
      const verifiedQuestion: PdfReviewQuestion = verifiedSnapshot.questions[questionIndex]
      if (sourceQuestion.images.length !== verifiedQuestion.images.length) {
        throw new Error('原题图片预检结果与审核会话不一致')
      }
      for (let imageIndex: number = 0; imageIndex < sourceQuestion.images.length; imageIndex++) {
        const sourceImage: PdfReviewImage = sourceQuestion.images[imageIndex]
        const verifiedImage: PdfReviewImage = verifiedQuestion.images[imageIndex]
        if (!/^[a-f0-9]{64}$/.test(verifiedImage.sha256) ||
          !Number.isSafeInteger(verifiedImage.size) || verifiedImage.size <= 0 ||
          (sourceImage.sha256.length > 0 && sourceImage.sha256 !== verifiedImage.sha256) ||
          (sourceImage.size !== 0 && sourceImage.size !== verifiedImage.size)) {
          throw new Error('原题图片预检结果无效')
        }
        sourceImage.sha256 = ''
        sourceImage.size = 0
        verifiedImage.sha256 = ''
        verifiedImage.size = 0
      }
    }
    if (JSON.stringify(sourceSnapshot) !== JSON.stringify(verifiedSnapshot)) {
      throw new Error('原题图片预检结果与审核会话不一致')
    }
    return PdfReviewSessionStore.copyOf(verified)
  }

  private static async inspectSourceImage(cacheDir: string, sessionId: string,
    path: string): Promise<SourceImageSnapshot> {
    if (!AiImportSaveService.isOwnedSessionCachePath(cacheDir, sessionId, path)) {
      throw new Error('原题图片不属于当前导入会话')
    }
    await AiImportSaveService.verifyDirectParentIdentity(cacheDir, path)
    const before: fs.Stat = await fs.lstat(path)
    if (before.isSymbolicLink() || !before.isFile() || !Number.isSafeInteger(before.size) ||
      before.size <= 0) {
      throw new Error('原题图片不是普通文件')
    }
    const firstHash: string = (await hash.hash(path, 'sha256')).toLowerCase()
    const after: fs.Stat = await fs.lstat(path)
    if (after.isSymbolicLink() || !after.isFile() || after.ino !== before.ino ||
      after.size !== before.size) {
      throw new Error('原题图片在校验期间发生变化')
    }
    const secondHash: string = (await hash.hash(path, 'sha256')).toLowerCase()
    if (!/^[a-f0-9]{64}$/.test(firstHash) || secondHash !== firstHash) {
      throw new Error('原题图片在校验期间发生变化')
    }
    return new SourceImageSnapshot(before.ino, before.size, firstHash)
  }

  private static async copyToFinal(filesDir: string, cacheDir: string, accountDirectory: string,
    sourcePath: string, finalPath: string, snapshot: SourceImageSnapshot): Promise<PreparedFinalFile> {
    const tempPath: string = AiImportSaveService.createTempPath(accountDirectory, snapshot.sha256)
    let tempCreated: boolean = false
    let finalCreated: boolean = false
    let ownedFinal: PreparedFinalFile | null = null
    try {
      await AiImportSaveService.verifyDirectoryChain(filesDir, accountDirectory)
      await AiImportSaveService.verifyDirectParentIdentity(cacheDir, sourcePath)
      if (!AiImportSaveService.isDirectChild(accountDirectory, finalPath) ||
        !AiImportSaveService.isDirectChild(accountDirectory, tempPath)) {
        throw new Error('原题图片目标路径无效')
      }
      const sourceFile: fs.File = await fs.open(sourcePath,
        fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW)
      let sourceError: Error | null = null
      try {
        const sourceInfo: fs.Stat = await fs.stat(sourceFile.fd)
        if (!sourceInfo.isFile() || sourceInfo.ino !== snapshot.inode ||
          sourceInfo.size !== snapshot.size) {
          throw new Error('原题图片在复制前发生变化')
        }
        await AiImportSaveService.copyDescriptorToTemp(sourceFile.fd, accountDirectory, tempPath)
        tempCreated = true
      } catch (err) {
        sourceError = AiImportSaveService.normalizeError(err, '原题图片复制失败')
      } finally {
        try {
          await fs.close(sourceFile)
        } catch (err) {
          sourceError = AiImportSaveService.appendError(sourceError,
            AiImportSaveService.normalizeError(err, '原题图片源文件关闭失败'))
        }
      }
      if (sourceError !== null) {
        throw sourceError
      }
      const sourceAfter: fs.Stat = await fs.lstat(sourcePath)
      const sourceHashAfter: string = (await hash.hash(sourcePath, 'sha256')).toLowerCase()
      if (sourceAfter.isSymbolicLink() || !sourceAfter.isFile() ||
        sourceAfter.ino !== snapshot.inode || sourceAfter.size !== snapshot.size ||
        sourceHashAfter !== snapshot.sha256) {
        throw new Error('原题图片在复制期间发生变化')
      }
      const stagedInfo: fs.Stat = await AiImportSaveService.verifyRegularFile(
        tempPath, snapshot.size, snapshot.sha256)
      await AiImportSaveService.verifyDirectoryChain(filesDir, accountDirectory)
      const existing: fs.Stat | null = await AiImportSaveService.lstatIfPresent(finalPath)
      if (existing !== null) {
        if (await AiImportSaveService.matchesRegularFile(finalPath, snapshot.size, snapshot.sha256)) {
          await AiImportSaveService.removeOwnedFile(accountDirectory, tempPath)
          tempCreated = false
          const reusedInfo: fs.Stat = await fs.lstat(finalPath)
          return new PreparedFinalFile('', reusedInfo.ino, reusedInfo.size, snapshot.sha256)
        }
        throw new Error('原题图片目标已存在且内容不匹配')
      }
      try {
        await fs.moveFile(tempPath, finalPath, 1)
        tempCreated = false
        finalCreated = true
        ownedFinal = new PreparedFinalFile(
          finalPath, stagedInfo.ino, stagedInfo.size, snapshot.sha256)
      } catch (err) {
        if (await AiImportSaveService.matchesRegularFile(finalPath, snapshot.size, snapshot.sha256)) {
          await AiImportSaveService.removeOwnedFile(accountDirectory, tempPath)
          tempCreated = false
          const racedInfo: fs.Stat = await fs.lstat(finalPath)
          return new PreparedFinalFile('', racedInfo.ino, racedInfo.size, snapshot.sha256)
        }
        throw AiImportSaveService.normalizeError(err, '原题图片提交失败')
      }
      const finalInfo: fs.Stat = await AiImportSaveService.verifyRegularFile(
        finalPath, snapshot.size, snapshot.sha256)
      return new PreparedFinalFile(finalPath, finalInfo.ino, finalInfo.size, snapshot.sha256)
    } catch (err) {
      const primaryError: Error = AiImportSaveService.normalizeError(err, '原题图片复制失败')
      let cleanupError: Error | null = null
      if (finalCreated && ownedFinal !== null) {
        const ownedFinals: Array<PreparedFinalFile> = new Array<PreparedFinalFile>()
        ownedFinals.push(ownedFinal)
        try {
          await AiImportSaveService.cleanupPreparedFinals(
            filesDir, accountDirectory, ownedFinals)
        } catch (err) {
          cleanupError = AiImportSaveService.normalizeError(err, '新复制图片清理失败')
        }
      }
      if (tempCreated) {
        try {
          await AiImportSaveService.removeOwnedFile(accountDirectory, tempPath)
        } catch (err) {
          cleanupError = AiImportSaveService.appendError(cleanupError,
            AiImportSaveService.normalizeError(err, '图片临时文件清理失败'))
        }
      }
      if (cleanupError !== null) {
        throw new Error(primaryError.message + '；后续清理也失败：' + cleanupError.message)
      }
      throw primaryError
    }
  }

  private static async copyDescriptorToTemp(sourceFd: number, accountDirectory: string,
    tempPath: string): Promise<void> {
    const existing: fs.Stat | null = await AiImportSaveService.lstatIfPresent(tempPath)
    if (existing !== null) {
      throw new Error('图片临时目标已存在')
    }
    let destination: fs.File | null = null
    let operationError: Error | null = null
    try {
      destination = await fs.open(tempPath,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW)
      await fs.copyFile(sourceFd, destination.fd, 0)
      await fs.fsync(destination.fd)
    } catch (err) {
      operationError = AiImportSaveService.normalizeError(err, '原题图片复制失败')
    } finally {
      if (destination !== null) {
        try {
          await fs.close(destination)
        } catch (err) {
          operationError = AiImportSaveService.appendError(operationError,
            AiImportSaveService.normalizeError(err, '图片临时文件关闭失败'))
        }
      }
    }
    if (operationError !== null) {
      try {
        await AiImportSaveService.removeOwnedFile(accountDirectory, tempPath)
      } catch (err) {
        operationError = AiImportSaveService.appendError(operationError,
          AiImportSaveService.normalizeError(err, '图片临时文件清理失败'))
      }
      throw operationError
    }
  }

  private static async reuseFinalIfMatching(filesDir: string, accountDirectory: string,
    finalPath: string, snapshot: SourceImageSnapshot): Promise<boolean> {
    if (!AiImportSaveService.isDirectChild(accountDirectory, finalPath)) {
      throw new Error('原题图片目标路径无效')
    }
    await AiImportSaveService.verifyDirectoryChain(filesDir, accountDirectory)
    const info: fs.Stat | null = await AiImportSaveService.lstatIfPresent(finalPath)
    if (info === null) {
      return false
    }
    if (!(await AiImportSaveService.matchesRegularFile(finalPath, snapshot.size, snapshot.sha256))) {
      throw new Error('原题图片目标已存在且内容不匹配')
    }
    return true
  }

  private static async matchesRegularFile(path: string, expectedSize: number,
    expectedSha256: string): Promise<boolean> {
    const info: fs.Stat | null = await AiImportSaveService.lstatIfPresent(path)
    if (info === null || info.isSymbolicLink() || !info.isFile() || info.size !== expectedSize) {
      return false
    }
    const followed: fs.Stat = await fs.stat(path)
    if (!followed.isFile() || followed.ino !== info.ino || followed.size !== expectedSize) {
      return false
    }
    const actualSha256: string = (await hash.hash(path, 'sha256')).toLowerCase()
    const finalInfo: fs.Stat | null = await AiImportSaveService.lstatIfPresent(path)
    return actualSha256 === expectedSha256 && finalInfo !== null &&
      !finalInfo.isSymbolicLink() && finalInfo.isFile() && finalInfo.ino === info.ino &&
      finalInfo.size === expectedSize
  }

  private static async verifyRegularFile(path: string, expectedSize: number,
    expectedSha256: string): Promise<fs.Stat> {
    const linkInfo: fs.Stat = await fs.lstat(path)
    const fileInfo: fs.Stat = await fs.stat(path)
    if (linkInfo.isSymbolicLink() || !linkInfo.isFile() || !fileInfo.isFile() ||
      linkInfo.ino !== fileInfo.ino || linkInfo.size !== expectedSize ||
      fileInfo.size !== expectedSize) {
      throw new Error('原题图片文件校验失败')
    }
    const actualSha256: string = (await hash.hash(path, 'sha256')).toLowerCase()
    const finalInfo: fs.Stat = await fs.lstat(path)
    if (actualSha256 !== expectedSha256 || finalInfo.isSymbolicLink() || !finalInfo.isFile() ||
      finalInfo.ino !== linkInfo.ino || finalInfo.size !== expectedSize) {
      throw new Error('原题图片文件校验失败')
    }
    return finalInfo
  }

  private static async cleanupPreparedFinals(filesDir: string, accountDirectory: string,
    newlyCopied: Array<PreparedFinalFile>): Promise<void> {
    let firstError: Error | null = null
    for (let index: number = newlyCopied.length - 1; index >= 0; index--) {
      const owned: PreparedFinalFile = newlyCopied[index]
      if (owned.path.length === 0) {
        continue
      }
      try {
        await AiImportSaveService.verifyDirectoryChain(filesDir, accountDirectory)
        const current: fs.Stat | null = await AiImportSaveService.lstatIfPresent(owned.path)
        if (current === null) {
          continue
        }
        if (current.isSymbolicLink() || !current.isFile() || current.ino !== owned.inode ||
          current.size !== owned.size ||
          (await hash.hash(owned.path, 'sha256')).toLowerCase() !== owned.sha256) {
          throw new Error('新复制图片所有权校验失败')
        }
        await fs.unlink(owned.path)
      } catch (err) {
        firstError = AiImportSaveService.appendError(firstError,
          AiImportSaveService.normalizeError(err, '新复制图片清理失败'))
      }
    }
    if (firstError !== null) {
      throw firstError
    }
  }

  private static async removeOwnedSessionFile(cacheDir: string, sessionId: string,
    path: string): Promise<void> {
    if (!AiImportSaveService.isOwnedSessionCachePath(cacheDir, sessionId, path)) {
      throw new Error('AI 导入缓存文件所有权无效')
    }
    await AiImportSaveService.verifyDirectParentIdentity(cacheDir, path)
    const info: fs.Stat | null = await AiImportSaveService.lstatIfPresent(path)
    if (info === null) {
      return
    }
    if (info.isSymbolicLink() || !info.isFile()) {
      throw new Error('AI 导入缓存目标不是普通文件')
    }
    await fs.unlink(path)
  }

  private static isOwnedSessionCachePath(cacheDir: string, sessionId: string,
    path: string): boolean {
    if (!AiImportSaveService.isIdentifier(sessionId)) {
      return false
    }
    const name: string = AiImportSaveService.directChildName(cacheDir, path)
    const pagePrefix: string = 'ai_import_page_' + sessionId + '~'
    if (name.startsWith(pagePrefix)) {
      const suffix: string = name.substring(pagePrefix.length)
      return /^[1-9][0-9]*\.jpg$/.test(suffix) ||
        /^attempt~[A-Za-z0-9._:-]{1,160}~[1-9][0-9]*\.jpg$/.test(suffix)
    }
    const cropPrefix: string = 'ai_import_crop_' + sessionId + '~'
    if (!name.startsWith(cropPrefix)) {
      return false
    }
    const suffix: string = name.substring(cropPrefix.length)
    return /^[A-Za-z0-9._:-]{1,160}\.jpg$/.test(suffix) ||
      /^attempt~[A-Za-z0-9._:-]{1,160}~[A-Za-z0-9._:-]{1,160}\.jpg$/.test(suffix)
  }

  private static async ensureAccountDirectory(filesDir: string, accountId: string): Promise<string> {
    const root: string = AiImportSaveService.normalizedRoot(filesDir)
    await AiImportSaveService.validateDirectory(root)
    const imageRoot: string = root + '/question_images'
    await AiImportSaveService.ensureDirectDirectory(root, imageRoot)
    const accountDirectory: string = DeviceImageScope.accountDirectory(root, accountId)
    await AiImportSaveService.ensureDirectDirectory(imageRoot, accountDirectory)
    await AiImportSaveService.verifyDirectoryChain(root, accountDirectory)
    return accountDirectory
  }

  private static async preflightDestinationDirectory(filesDir: string,
    accountId: string): Promise<string> {
    const root: string = AiImportSaveService.normalizedRoot(filesDir)
    await AiImportSaveService.validateDirectory(root)
    const accountDirectory: string = DeviceImageScope.accountDirectory(root, accountId)
    await AiImportSaveService.validateExistingDirectoryChain(root, accountDirectory)
    return accountDirectory
  }

  private static async ensureDirectDirectory(parent: string, path: string): Promise<void> {
    await AiImportSaveService.validateDirectory(parent)
    if (!AiImportSaveService.isDirectChild(parent, path)) {
      throw new Error('本地图片目录路径无效')
    }
    let creationError: Error | null = null
    let info: fs.Stat | null = await AiImportSaveService.lstatIfPresent(path)
    if (info === null) {
      try {
        await fs.mkdir(path)
      } catch (err) {
        creationError = AiImportSaveService.normalizeError(err, '本地图片目录创建失败')
      }
      info = await AiImportSaveService.lstatIfPresent(path)
    }
    if (info === null) {
      if (creationError !== null) {
        throw creationError
      }
      throw new Error('本地图片目录创建失败')
    }
    if (info.isSymbolicLink() || !info.isDirectory()) {
      throw new Error('本地图片目录包含不安全节点')
    }
    const followed: fs.Stat = await fs.stat(path)
    if (!followed.isDirectory() || followed.ino !== info.ino) {
      throw new Error('本地图片目录身份无效')
    }
  }

  private static async validateDirectory(path: string): Promise<void> {
    const linkInfo: fs.Stat | null = await AiImportSaveService.lstatIfPresent(path)
    if (linkInfo === null || linkInfo.isSymbolicLink() || !linkInfo.isDirectory()) {
      throw new Error('受信目录不可用')
    }
    const info: fs.Stat = await fs.stat(path)
    if (!info.isDirectory() || info.ino !== linkInfo.ino) {
      throw new Error('受信目录身份无效')
    }
  }

  private static async verifyDirectoryChain(root: string, path: string): Promise<void> {
    if (!AiImportSaveService.isDescendant(root, path)) {
      throw new Error('本地图片目录超出受信范围')
    }
    await AiImportSaveService.validateDirectory(root)
    const relative: string = path.substring(root.length + 1)
    const parts: Array<string> = relative.split('/')
    let currentPath: string = root
    for (let index: number = 0; index < parts.length; index++) {
      currentPath += '/' + parts[index]
      await AiImportSaveService.validateDirectory(currentPath)
    }
  }

  private static async validateExistingDirectoryChain(root: string, path: string): Promise<void> {
    if (!AiImportSaveService.isDescendant(root, path)) {
      throw new Error('本地图片目录超出受信范围')
    }
    await AiImportSaveService.validateDirectory(root)
    const relative: string = path.substring(root.length + 1)
    const parts: Array<string> = relative.split('/')
    let currentPath: string = root
    for (let index: number = 0; index < parts.length; index++) {
      currentPath += '/' + parts[index]
      const info: fs.Stat | null = await AiImportSaveService.lstatIfPresent(currentPath)
      if (info === null) {
        return
      }
      if (info.isSymbolicLink() || !info.isDirectory()) {
        throw new Error('本地图片目录包含不安全节点')
      }
      const followed: fs.Stat = await fs.stat(currentPath)
      if (!followed.isDirectory() || followed.ino !== info.ino) {
        throw new Error('本地图片目录身份无效')
      }
    }
  }

  private static async verifyDirectParentIdentity(root: string, path: string): Promise<void> {
    const childName: string = AiImportSaveService.directChildName(root, path)
    if (childName.length === 0) {
      throw new Error('文件路径超出受信目录')
    }
    const parent: string = path.substring(0, path.length - childName.length - 1)
    const rootLink: fs.Stat = await fs.lstat(root)
    const rootInfo: fs.Stat = await fs.stat(root)
    const parentLink: fs.Stat = await fs.lstat(parent)
    const parentInfo: fs.Stat = await fs.stat(parent)
    if (rootLink.isSymbolicLink() || !rootLink.isDirectory() || !rootInfo.isDirectory() ||
      parentLink.isSymbolicLink() || !parentLink.isDirectory() || !parentInfo.isDirectory() ||
      rootLink.ino !== rootInfo.ino || parentLink.ino !== parentInfo.ino ||
      rootInfo.ino !== parentInfo.ino) {
      throw new Error('文件父目录身份无效')
    }
  }

  private static async removeOwnedFile(accountDirectory: string, path: string): Promise<void> {
    if (!AiImportSaveService.isDirectChild(accountDirectory, path)) {
      throw new Error('图片清理路径无效')
    }
    await AiImportSaveService.verifyDirectParentIdentity(accountDirectory, path)
    const info: fs.Stat | null = await AiImportSaveService.lstatIfPresent(path)
    if (info === null) {
      return
    }
    if (info.isSymbolicLink() || !info.isFile()) {
      throw new Error('图片清理目标不是普通文件')
    }
    await fs.unlink(path)
  }

  private static createTempPath(accountDirectory: string, sha256: string): string {
    AiImportSaveService.tempSequence++
    if (!Number.isSafeInteger(AiImportSaveService.tempSequence) ||
      AiImportSaveService.tempSequence > 999999999) {
      AiImportSaveService.tempSequence = 1
    }
    return accountDirectory + '/ai_import_copy_' + sha256 + '_' + Date.now().toString() + '_' +
      AiImportSaveService.tempSequence.toString() + '.partial'
  }

  private static normalizedRoot(path: string): string {
    let result: string = path
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1)
    }
    if (result.length === 0 || result.indexOf('\\') >= 0 ||
      result.indexOf(String.fromCharCode(0)) >= 0) {
      throw new Error('受信目录路径无效')
    }
    return result
  }

  private static isDirectChild(parent: string, path: string): boolean {
    if (!AiImportSaveService.isDescendant(parent, path)) {
      return false
    }
    return path.substring(parent.length + 1).indexOf('/') < 0
  }

  private static isDescendant(root: string, path: string): boolean {
    const prefix: string = root + '/'
    if (!path.startsWith(prefix) || path.length <= prefix.length || path.indexOf('\\') >= 0 ||
      path.indexOf(String.fromCharCode(0)) >= 0) {
      return false
    }
    const relative: string = path.substring(prefix.length)
    return !relative.startsWith('/') && !relative.endsWith('/') && relative.indexOf('//') < 0 &&
      relative !== '.' && relative !== '..' && !relative.startsWith('../') &&
      !relative.endsWith('/..') && relative.indexOf('/../') < 0 &&
      !relative.startsWith('./') && !relative.endsWith('/.') && relative.indexOf('/./') < 0
  }

  private static directChildName(parent: string, path: string): string {
    if (!AiImportSaveService.isDirectChild(parent, path)) {
      return ''
    }
    return path.substring(parent.length + 1)
  }

  private static async lstatIfPresent(path: string): Promise<fs.Stat | null> {
    return new Promise<fs.Stat | null>((resolve, reject): void => {
      fs.lstat(path, (err: BusinessError, info: fs.Stat): void => {
        if (err) {
          if (err.code === 13900002) {
            resolve(null)
            return
          }
          reject(new Error(err.message.length > 0 ? err.message : '文件状态读取失败'))
          return
        }
        resolve(info)
      })
    })
  }

  private static appendError(first: Error | null, next: Error): Error {
    if (first === null) {
      return next
    }
    return new Error(first.message + '；后续清理也失败：' + next.message)
  }

  private static normalizeError(value: Error, defaultMessage: string): Error {
    return value instanceof Error ? value : new Error(defaultMessage)
  }

  private static isIdentifier(value: string): boolean {
    return /^[A-Za-z0-9._:-]{1,160}$/.test(value)
  }

  private static isUuid(value: string): boolean {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
  }

  private static toBank(session: PdfReviewSession): QuestionBank {
    const questions: Array<Question> = new Array<Question>()
    for (let index: number = 0; index < session.questions.length; index++) {
      const source: PdfReviewQuestion = session.questions[index]
      const options: Array<string> = new Array<string>()
      const orderedOptions: Array<PdfReviewOption> = source.options.slice()
      orderedOptions.sort((left: PdfReviewOption, right: PdfReviewOption): number =>
        left.key.localeCompare(right.key))
      for (let optionIndex: number = 0; optionIndex < orderedOptions.length; optionIndex++) {
        options.push(AiImportSaveService.optionText(orderedOptions[optionIndex]))
      }
      questions.push(new Question(source.questionUuid, session.bankUuid,
        AiImportSaveService.questionType(source.type),
        AiImportSaveService.withLabel(source.label, source.question), options,
        source.answer, source.analysis, source.pageStart, source.pageEnd,
        source.reviewRequired ? 'needs_review' : 'confirmed'))
    }
    return new QuestionBank(session.bankUuid, session.bankName.trim(), session.subject.trim(),
      questions.length, Date.now(), false, questions)
  }

  private static questionType(type: AiQuestionType): string {
    if (type === AiQuestionType.SINGLE_CHOICE) return 'single_choice'
    if (type === AiQuestionType.BLANK) return 'fill_blank'
    if (type === AiQuestionType.SHORT_ANSWER) return 'short_answer'
    return 'unclassified'
  }

  private static withLabel(label: string, question: string): string {
    const normalizedLabel: string = label.trim()
    const normalizedQuestion: string = question.trim()
    if (normalizedQuestion === normalizedLabel ||
      normalizedQuestion.startsWith(normalizedLabel + ' ') ||
      normalizedQuestion.startsWith(normalizedLabel + '\n')) return normalizedQuestion
    return normalizedLabel.length === 0 ? normalizedQuestion : normalizedLabel + ' ' + normalizedQuestion
  }

  private static optionText(option: PdfReviewOption): string {
    const value: string = option.value.trim()
    if (value.startsWith(option.key + '.') || value.startsWith(option.key + '．') ||
      value.startsWith(option.key + '、')) return value
    return option.key + '. ' + value
  }
}
