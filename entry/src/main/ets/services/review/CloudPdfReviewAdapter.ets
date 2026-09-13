import { Context } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { hash } from '@kit.CoreFileKit'
import fs from '@ohos.file.fs'
import { AccountSessionState } from '../../models/AccountSession'
import { ApiHttpError } from '../../models/ApiModels'
import { DeviceQuestionImage } from '../../models/CloudCacheModels'
import {
  CloudImportArtifact,
  CloudImportDraft,
  CloudImportDraftQuestion,
  CloudImportQuestionType,
  CloudImportStatus,
  ConfirmCloudImportQuestion,
  ConfirmCloudImportRequest,
  ConfirmedImportArtifact,
  ConfirmImportQuestionResult,
  ConfirmImportResult
} from '../../models/CloudImportModels'
import { AccountSessionService } from '../../services/AccountSessionService'
import { CloudImportService } from '../../services/CloudImportService'
import { DeviceImageScope, DeviceImageStore } from '../../services/DeviceImageStore'
import { CloudPdfSelection, PdfImportState } from '../../utils/PdfImportState'

import { AiQuestionType } from '../../models/ai/AiImportModels'
import { PdfReviewAdapter, PdfReviewSession, PdfReviewQuestion, PdfReviewOption,
  PdfReviewImage, PdfReviewFailure, PdfReviewSource, PdfReviewSaveStage,
  PdfReviewSavePolicy } from './PdfReviewModels'
import { PdfReviewSessionStore } from './PdfReviewSession'

export class CloudPdfReviewAdapter implements PdfReviewAdapter {
  private requiredArtifactCount: number = 0
  private unavailableArtifactCount: number = 0
  private artifactExpired: boolean = false
  private draftStatus: CloudImportStatus = CloudImportStatus.REVIEW
  private draftExpiresAt: string = ''
  private current: PdfReviewSession | null = null
  private nullableFields: Map<string, CloudImportDraftQuestion> = new Map<string, CloudImportDraftQuestion>()

  async load(context: Context): Promise<PdfReviewSession> {
    const state: PdfImportState = PdfImportState.shared()
    const jobId: string = state.getCloudJobId()
    const accountId: string = state.getCloudAccountId()
    if (jobId.length === 0 || accountId.length === 0) {
      throw new Error('云端导入任务信息已失效，请返回重新导入')
    }
    await this.requireAccount(context, accountId)
    const result: ConfirmImportResult | null = state.getConfirmResult()
    let draft: CloudImportDraft | null = state.getCloudReviewDraft()
    if (result === null) {
      try {
        draft = await CloudImportService.getDraft(context, jobId)
        await this.requireAccount(context, accountId)
        state.setCloudReviewDraft(draft)
      } catch (err) {
        if (!this.isExpiredHttpError(err) || draft === null || draft.jobId !== jobId) throw err instanceof Error ? err : new Error(`${err}`)
        this.markArtifactExpired()
      }
    }
    if (draft === null || draft.jobId !== jobId) {
      draft = new CloudImportDraft(jobId, state.getCloudStatus(), state.getCloudBankName(),
        state.getCloudSubject(), '', new Array<CloudImportDraftQuestion>())
    }
    if (draft.status === CloudImportStatus.EXPIRED) this.markArtifactExpired()
    this.draftStatus = draft.status
    this.draftExpiresAt = draft.expiresAt
    const questions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
    this.nullableFields.clear()
    for (const question of draft.questions) {
      this.nullableFields.set(question.draftQuestionId, question)
      questions.push(this.toReviewQuestion(question))
    }
    const stage: PdfReviewSaveStage = state.getCloudStatus() === CloudImportStatus.CONFIRMED ?
      PdfReviewSaveStage.COMPLETE : result === null ?
        PdfReviewSaveStage.DRAFT : PdfReviewSaveStage.TEXT_SAVED
    const session: PdfReviewSession = new PdfReviewSession(jobId, PdfReviewSource.CLOUD,
      result === null ? '' : result.bankId, draft.bankName, draft.subject, '', accountId,
      questions, new Array<PdfReviewFailure>(), stage)
    await this.requireAccount(context, accountId)
    this.current = PdfReviewSessionStore.copyOf(session)
    return PdfReviewSessionStore.copyOf(session)
  }

  persist(session: PdfReviewSession): void {
    this.requireSession(session)
    if (!PdfReviewSavePolicy.canEdit(session.saveStage)) return
    const questions: Array<CloudImportDraftQuestion> = new Array<CloudImportDraftQuestion>()
    for (const question of session.questions) questions.push(this.toCloudQuestion(question))
    PdfImportState.shared().setCloudReviewDraft(new CloudImportDraft(session.sessionId,
      this.draftStatus, session.bankName, session.subject, this.draftExpiresAt, questions))
    this.current = PdfReviewSessionStore.copyOf(session)
  }

  async save(context: Context, session: PdfReviewSession): Promise<PdfReviewSession> {
    this.requireSession(session)
    const state: PdfImportState = PdfImportState.shared()
    const jobId: string = state.getCloudJobId()
    const accountId: string = state.getCloudAccountId()
    await this.requireAccount(context, accountId)
    let result: ConfirmImportResult | null = state.getConfirmResult()
    if (result === null) {
      this.persist(session)
      const questions: Array<ConfirmCloudImportQuestion> = new Array<ConfirmCloudImportQuestion>()
      for (const question of session.questions) {
        const cloud: CloudImportDraftQuestion = this.toCloudQuestion(question)
        questions.push(new ConfirmCloudImportQuestion(cloud.draftQuestionId,
          this.questionType(cloud.type), cloud.question.trim(), cloud.options,
          cloud.answer, cloud.analysis, true))
      }
      const request: ConfirmCloudImportRequest = new ConfirmCloudImportRequest(
        session.bankName.trim(), session.subject.trim(), questions)
      result = await CloudImportService.confirm(context, jobId, request)
      state.setConfirmResult(result)
    }
    session.saveStage = PdfReviewSaveStage.TEXT_SAVED
    session.bankUuid = result.bankId
    const savedArtifactIds: Array<string> = await this.downloadArtifacts(
      context, jobId, accountId, result)
    await this.requireAccount(context, accountId)
    if (this.unavailableArtifactCount > 0) {
      this.markArtifactExpired()
    } else {
      if (savedArtifactIds.length !== this.requiredArtifactCount) {
        throw new Error('原题图片保存数量不完整')
      }
      try {
        await CloudImportService.acknowledgeArtifacts(context, jobId, savedArtifactIds)
      } catch (err) {
        if (await this.isArtifactUnavailable(context, jobId, err)) {
          this.markArtifactExpired()
        } else if (err instanceof Error) {
          throw err
        } else {
          throw new Error('云端图片确认失败')
        }
      }
    }
    state.setCloudArtifactExpired(this.artifactExpired || state.getCloudArtifactExpired())
    state.setCloudStatus(CloudImportStatus.CONFIRMED)
    session.saveStage = PdfReviewSaveStage.COMPLETE
    this.current = PdfReviewSessionStore.copyOf(session)
    return PdfReviewSessionStore.copyOf(session)
  }

  async retryPage(context: Context, session: PdfReviewSession,
    pageNumber: number): Promise<PdfReviewSession> {
    return PdfReviewSessionStore.copyOf(session)
  }

  async abandon(context: Context, session: PdfReviewSession): Promise<void> {
    this.requireSession(session)
    if (!PdfReviewSavePolicy.canAbandon(session.saveStage) ||
      PdfImportState.shared().getConfirmResult() !== null) {
      throw new Error('题目文字已确认，请完成原题图片保存')
    }
    await this.requireAccount(context, session.accountId)
    const selection: CloudPdfSelection | null = PdfImportState.shared().getCloudSelection()
    if (selection !== null) await this.removeStagedPdf(context.cacheDir, selection.pdfPath)
    await this.requireAccount(context, session.accountId)
    PdfImportState.shared().resetCloudFlow()
    this.current = null
  }

  async discardFailure(context: Context, session: PdfReviewSession, pageNumber: number,
    replacement: PdfReviewQuestion | null): Promise<PdfReviewSession> {
    return PdfReviewSessionStore.copyOf(session)
  }

  private async removeStagedPdf(cacheDir: string, path: string): Promise<void> {
    if (!this.isDirectChild(cacheDir, path) ||
      !/^cloud_import_pdf_[0-9]+\.pdf$/.test(path.substring(cacheDir.length + 1))) {
      throw new Error('PDF 临时文件路径无效')
    }
    await this.validateDirectory(cacheDir)
    const root: fs.Stat = await fs.lstat(cacheDir)
    const followedRoot: fs.Stat = await fs.stat(cacheDir)
    if (!followedRoot.isDirectory() || root.ino !== followedRoot.ino) {
      throw new Error('PDF 临时文件目录发生变化')
    }
    const info: fs.Stat | null = await this.lstatIfPresent(path)
    if (info === null) return
    if (info.isSymbolicLink() || !info.isFile()) {
      throw new Error('PDF 临时文件包含不安全节点')
    }
    const currentRoot: fs.Stat = await fs.lstat(cacheDir)
    if (currentRoot.isSymbolicLink() || !currentRoot.isDirectory() || currentRoot.ino !== root.ino) {
      throw new Error('PDF 临时文件目录发生变化')
    }
    await fs.unlink(path)
  }

  private requireSession(session: PdfReviewSession): void {
    const state: PdfImportState = PdfImportState.shared()
    if (session.source !== PdfReviewSource.CLOUD || session.sessionId !== state.getCloudJobId() ||
      session.accountId !== state.getCloudAccountId() || this.current === null ||
      session.sessionId !== this.current.sessionId || session.accountId !== this.current.accountId) {
      throw new Error('云端导入任务信息已失效，请返回重新导入')
    }
  }

  private toReviewQuestion(source: CloudImportDraftQuestion): PdfReviewQuestion {
    const options: Array<PdfReviewOption> = new Array<PdfReviewOption>()
    if (source.options !== null) {
      const keys: Array<string> = Object.keys(source.options).sort()
      for (const key of keys) options.push(new PdfReviewOption(key, source.options[key]))
    }
    const images: Array<PdfReviewImage> = new Array<PdfReviewImage>()
    for (let index: number = 0; index < source.images.length; index++) {
      const image: CloudImportArtifact = source.images[index]
      images.push(new PdfReviewImage(image.artifactId, '', image.sha256, image.size,
        image.contentType, index))
    }
    return new PdfReviewQuestion(source.draftQuestionId, source.draftQuestionId, '',
      this.reviewType(source.type), source.question, options, source.answer === null ? '' : source.answer,
      source.analysis === null ? '' : source.analysis, source.pageStart, source.pageEnd,
      source.confidence, source.reviewRequired, images)
  }

  private toCloudQuestion(source: PdfReviewQuestion): CloudImportDraftQuestion {
    const original: CloudImportDraftQuestion | undefined = this.nullableFields.get(source.draftQuestionId)
    const options: Record<string, string> | null =
      source.options.length === 0 && (original === undefined || original.options === null) ? null : {}
    if (options !== null) {
      for (const option of source.options) options[option.key] = option.value
    }
    const images: Array<CloudImportArtifact> = new Array<CloudImportArtifact>()
    for (const image of source.images) {
      images.push(new CloudImportArtifact(image.remoteArtifactId, image.sha256,
        image.size, image.contentType))
    }
    return new CloudImportDraftQuestion(source.draftQuestionId, this.questionType(source.type),
      source.question, options,
      source.answer.length === 0 && original !== undefined && original.answer === null ? null : source.answer,
      source.analysis.length === 0 && original !== undefined && original.analysis === null ? null : source.analysis,
      source.pageStart, source.pageEnd,
      source.confidence, source.reviewRequired, images)
  }

  private reviewType(value: string): AiQuestionType {
    if (value === 'single_choice') return AiQuestionType.SINGLE_CHOICE
    if (value === 'blank') return AiQuestionType.BLANK
    if (value === 'short_answer') return AiQuestionType.SHORT_ANSWER
    return AiQuestionType.UNKNOWN
  }

  private questionType(value: string): CloudImportQuestionType {
    if (value === 'single_choice') {
      return CloudImportQuestionType.SINGLE_CHOICE
    }
    if (value === 'blank') {
      return CloudImportQuestionType.BLANK
    }
    if (value === 'short_answer') {
      return CloudImportQuestionType.SHORT_ANSWER
    }
    return CloudImportQuestionType.UNKNOWN
  }

  private async downloadArtifacts(context: Context, jobId: string, accountId: string,
    result: ConfirmImportResult): Promise<Array<string>> {
    const accountDirectory: string = DeviceImageScope.accountDirectory(context.filesDir, accountId)
    const preparedDirectory: string = await this.ensureAccountDirectory(context.filesDir, accountId)
    if (preparedDirectory !== accountDirectory) {
      throw new Error('账号隔离图片目录校验失败')
    }
    const savedArtifactIds: Array<string> = new Array<string>()
    this.requiredArtifactCount = 0
    this.unavailableArtifactCount = 0
    for (let questionIndex: number = 0; questionIndex < result.questions.length; questionIndex++) {
      const question: ConfirmImportQuestionResult = result.questions[questionIndex]
      for (let imageIndex: number = 0; imageIndex < question.images.length; imageIndex++) {
        const image: ConfirmedImportArtifact = question.images[imageIndex]
        this.requiredArtifactCount++
        if (!/^[a-f0-9]{64}$/.test(image.sha256) || !Number.isSafeInteger(image.size) ||
          image.size <= 0) {
          throw new Error('原题图片元数据校验失败')
        }
        const fileStem: string = this.artifactFileStem(image.artifactId, image.sha256)
        const tempPath: string = accountDirectory + '/' + fileStem + '.partial'
        const finalPath: string = accountDirectory + '/' + fileStem + '.jpg'
        await this.validateDirectoryChain(context.filesDir, accountDirectory)
        await this.validateFinalTarget(accountDirectory, finalPath)
        if (await this.reuseStoredArtifact(context, accountDirectory, finalPath, accountId,
          question.questionId, image, imageIndex)) {
          if (savedArtifactIds.indexOf(image.artifactId) < 0) {
            savedArtifactIds.push(image.artifactId)
          }
          continue
        }
        let content: ArrayBuffer
        try {
          content = await CloudImportService.downloadArtifact(context, jobId, image.artifactId,
            image.size, image.sha256)
        } catch (err) {
          if (await this.isArtifactUnavailable(context, jobId, err)) {
            this.markArtifactExpired()
            this.unavailableArtifactCount++
            continue
          }
          if (err instanceof Error) {
            throw err
          }
          throw new Error('原题图片下载失败')
        }
        if (content.byteLength !== image.size) {
          throw new Error('原题图片元数据校验失败')
        }
        await this.validateDirectoryChain(context.filesDir, accountDirectory)
        await this.prepareTemporaryFile(context.filesDir, accountDirectory, tempPath)
        let moved: boolean = false
        try {
          await this.writeArtifact(tempPath, content)
          await this.verifyArtifactFile(tempPath, image.size, image.sha256)
          await this.validateFinalTarget(accountDirectory, finalPath)
          await fs.moveFile(tempPath, finalPath, 0)
          moved = true
          await this.validateDirectoryChain(context.filesDir, accountDirectory)
          await this.verifyArtifactFile(finalPath, image.size, image.sha256)
          try {
            await DeviceImageStore.save(context, new DeviceQuestionImage(
              accountId, question.questionId, finalPath, image.sha256, imageIndex))
          } catch (err) {
            await this.tryRemoveOwnedFile(context.filesDir, accountDirectory, finalPath)
            if (err instanceof Error) {
              throw err
            }
            throw new Error('本地图片映射保存失败')
          }
          if (savedArtifactIds.indexOf(image.artifactId) < 0) {
            savedArtifactIds.push(image.artifactId)
          }
        } catch (err) {
          if (moved) {
            await this.tryRemoveOwnedFile(context.filesDir, accountDirectory, finalPath)
          }
          if (err instanceof Error) {
            throw err
          }
          throw new Error('原题图片保存失败')
        } finally {
          await this.tryRemoveOwnedFile(context.filesDir, accountDirectory, tempPath)
        }
      }
    }
    return savedArtifactIds
  }

  private async reuseStoredArtifact(context: Context, accountDirectory: string, finalPath: string,
    accountId: string, questionId: string, image: ConfirmedImportArtifact,
    sortOrder: number): Promise<boolean> {
    const info: fs.Stat | null = await this.lstatIfPresent(finalPath)
    if (info === null) {
      return false
    }
    try {
      await this.verifyArtifactFile(finalPath, image.size, image.sha256)
    } catch {
      return false
    }
    await DeviceImageStore.save(context, new DeviceQuestionImage(
      accountId, questionId, finalPath, image.sha256, sortOrder))
    return true
  }

  private artifactFileStem(artifactId: string, sha256: string): string {
    const normalizedId: string = artifactId.toLowerCase()
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
      normalizedId)) {
      throw new Error('原题图片标识无效')
    }
    return 'cloud_import_' + normalizedId + '_' + sha256
  }

  private async writeArtifact(tempPath: string, content: ArrayBuffer): Promise<void> {
    const file: fs.File = await fs.open(tempPath,
      fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW)
    let operationError: Error | null = null
    try {
      let written: number = 0
      while (written < content.byteLength) {
        const remaining: ArrayBuffer = content.slice(written)
        const currentWrite: number = await fs.write(file.fd, remaining)
        if (!Number.isInteger(currentWrite) || currentWrite <= 0 ||
          currentWrite > remaining.byteLength) {
          throw new Error('原题图片临时文件写入失败')
        }
        written += currentWrite
      }
      await fs.fsync(file.fd)
    } catch (err) {
      operationError = err instanceof Error ? err : new Error('原题图片临时文件写入失败')
    } finally {
      try {
        await fs.close(file)
      } catch (err) {
        if (operationError === null) {
          operationError = err instanceof Error ? err : new Error('原题图片临时文件关闭失败')
        }
      }
    }
    if (operationError !== null) {
      throw operationError
    }
  }

  private async verifyArtifactFile(path: string, expectedSize: number,
    expectedSha256: string): Promise<void> {
    const linkInfo: fs.Stat = await fs.lstat(path)
    const fileInfo: fs.Stat = await fs.stat(path)
    if (linkInfo.isSymbolicLink() || !linkInfo.isFile() || !fileInfo.isFile() ||
      linkInfo.size !== expectedSize || fileInfo.size !== expectedSize) {
      throw new Error('原题图片大小校验失败')
    }
    const actualSha256: string = (await hash.hash(path, 'sha256')).toLowerCase()
    if (actualSha256 !== expectedSha256) {
      throw new Error('原题图片 SHA-256 校验失败')
    }
  }

  private async ensureAccountDirectory(filesDir: string, accountId: string): Promise<string> {
    await this.validateDirectory(filesDir)
    const imageRoot: string = filesDir + '/question_images'
    await this.ensureDirectDirectory(filesDir, imageRoot)
    const accountDirectory: string = DeviceImageScope.accountDirectory(filesDir, accountId)
    await this.ensureDirectDirectory(imageRoot, accountDirectory)
    await this.validateDirectoryChain(filesDir, accountDirectory)
    return accountDirectory
  }

  private async ensureDirectDirectory(parent: string, path: string): Promise<void> {
    await this.validateDirectory(parent)
    if (!this.isDirectChild(parent, path)) {
      throw new Error('本地图片目录路径无效')
    }
    let info: fs.Stat | null = await this.lstatIfPresent(path)
    if (info === null) {
      await fs.mkdir(path)
      info = await fs.lstat(path)
    }
    if (info.isSymbolicLink() || !info.isDirectory()) {
      throw new Error('本地图片目录包含不安全节点')
    }
  }

  private async validateDirectory(path: string): Promise<void> {
    const info: fs.Stat | null = await this.lstatIfPresent(path)
    if (info === null || info.isSymbolicLink() || !info.isDirectory()) {
      throw new Error('受信目录不可用')
    }
  }

  private async validateDirectoryChain(root: string, path: string): Promise<void> {
    if (!this.isDescendant(root, path)) {
      throw new Error('本地图片目录超出受信范围')
    }
    await this.validateDirectory(root)
    const relative: string = path.substring(root.length + 1)
    const parts: Array<string> = relative.split('/')
    let currentPath: string = root
    for (let index: number = 0; index < parts.length; index++) {
      currentPath += '/' + parts[index]
      const info: fs.Stat | null = await this.lstatIfPresent(currentPath)
      if (info === null || info.isSymbolicLink() || !info.isDirectory()) {
        throw new Error('本地图片目录包含不安全节点')
      }
    }
  }

  private async prepareTemporaryFile(filesDir: string, accountDirectory: string,
    tempPath: string): Promise<void> {
    if (!this.isDirectChild(accountDirectory, tempPath) || !tempPath.endsWith('.partial')) {
      throw new Error('原题图片临时路径无效')
    }
    await this.validateDirectoryChain(filesDir, accountDirectory)
    const info: fs.Stat | null = await this.lstatIfPresent(tempPath)
    if (info === null) {
      return
    }
    if (info.isSymbolicLink() || !info.isFile()) {
      throw new Error('原题图片临时路径包含不安全节点')
    }
    await fs.unlink(tempPath)
  }

  private async validateFinalTarget(accountDirectory: string, finalPath: string): Promise<void> {
    if (!this.isDirectChild(accountDirectory, finalPath) || !finalPath.endsWith('.jpg')) {
      throw new Error('原题图片保存路径无效')
    }
    const info: fs.Stat | null = await this.lstatIfPresent(finalPath)
    if (info !== null && (info.isSymbolicLink() || !info.isFile())) {
      throw new Error('原题图片保存路径包含不安全节点')
    }
  }

  private async tryRemoveOwnedFile(filesDir: string, accountDirectory: string,
    path: string): Promise<void> {
    try {
      if (!this.isDirectChild(accountDirectory, path)) {
        return
      }
      await this.validateDirectoryChain(filesDir, accountDirectory)
      const info: fs.Stat | null = await this.lstatIfPresent(path)
      if (info !== null && !info.isSymbolicLink() && info.isFile()) {
        await fs.unlink(path)
      }
    } catch {
    }
  }

  private async lstatIfPresent(path: string): Promise<fs.Stat | null> {
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

  private isDirectChild(parent: string, path: string): boolean {
    if (!this.isDescendant(parent, path)) {
      return false
    }
    return path.substring(parent.length + 1).indexOf('/') < 0
  }

  private isDescendant(root: string, path: string): boolean {
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

  private async requireAccount(context: Context, accountId: string): Promise<void> {
    const session: AccountSessionState = await AccountSessionService.state(context)
    if (!session.signedIn || session.userId.length === 0) {
      throw new Error('请先登录华为账号')
    }
    if (session.userId !== accountId) {
      throw new Error('当前华为账号与导入任务不一致')
    }
  }

  private markArtifactExpired(): void {
    this.artifactExpired = true
    PdfImportState.shared().setCloudArtifactExpired(true)
  }

  private async isArtifactUnavailable(context: Context, jobId: string, err: Error): Promise<boolean> {
    if (this.isExpiredHttpError(err)) {
      return true
    }
    try {
      return (await CloudImportService.getJob(context, jobId)).status === CloudImportStatus.EXPIRED
    } catch {
      return false
    }
  }

  private isExpiredHttpError(err: Error): boolean {
    return err instanceof ApiHttpError &&
      (err.statusCode === 404 || err.statusCode === 410 || err.code === 'ARTIFACT_EXPIRED')
  }

}
