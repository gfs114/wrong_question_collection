import { Context } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'
import { BusinessError } from '@kit.BasicServicesKit'
import { hash } from '@kit.CoreFileKit'
import fs from '@ohos.file.fs'
import { AppHeader } from '../components/AppHeader'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { AccountSessionState } from '../models/AccountSession'
import { ApiHttpError } from '../models/ApiModels'
import { DeviceQuestionImage } from '../models/CloudCacheModels'
import {
  CloudImportDraft,
  CloudImportDraftQuestion,
  CloudImportQuestionType,
  CloudImportStatus,
  ConfirmCloudImportQuestion,
  ConfirmCloudImportRequest,
  ConfirmedImportArtifact,
  ConfirmImportQuestionResult,
  ConfirmImportResult
} from '../models/CloudImportModels'
import { AccountSessionService } from '../services/AccountSessionService'
import { CloudImportService } from '../services/CloudImportService'
import { DeviceImageScope, DeviceImageStore } from '../services/DeviceImageStore'
import { AppColors } from '../theme/AppColors'
import { PdfImportState } from '../utils/PdfImportState'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

@Entry
@Component
struct PdfImportReviewPage {
  @State draftQuestions: Array<CloudImportDraftQuestion> = new Array<CloudImportDraftQuestion>()
  @State bankName: string = ''
  @State subject: string = ''
  @State loading: boolean = true
  @State pending: boolean = false
  @State navigationPending: boolean = false
  @State confirmationComplete: boolean = false
  @State artifactExpired: boolean = false
  @State errorMessage: string = ''
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = {
    top: 0, left: 0, right: 0, bottom: 0
  }
  @StorageProp('darkMode') darkMode: boolean = false
  private initialized: boolean = false
  private jobId: string = ''
  private accountId: string = ''
  private confirmedBankId: string = ''
  private requiredArtifactCount: number = 0
  private unavailableArtifactCount: number = 0
  private draftStatus: CloudImportStatus = CloudImportStatus.REVIEW
  private draftExpiresAt: string = ''

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  aboutToAppear(): void {
    if (this.initialized) {
      return
    }
    this.initialized = true
    this.loadDraft()
  }

  onBackPress(): boolean {
    this.returnToImportPage()
    return true
  }

  private async loadDraft(): Promise<void> {
    if (this.pending) {
      return
    }
    const state: PdfImportState = PdfImportState.shared()
    const jobId: string = state.getCloudJobId()
    const accountId: string = state.getCloudAccountId()
    this.loading = true
    this.errorMessage = ''
    try {
      if (jobId.length === 0 || accountId.length === 0) {
        throw new Error('云端导入任务信息已失效，请返回重新导入')
      }
      const context: Context = getContext(this)
      await this.requireAccount(context, accountId)
      const confirmedResult: ConfirmImportResult | null = state.getConfirmResult()
      if (confirmedResult !== null) {
        const cachedDraft: CloudImportDraft | null = state.getCloudReviewDraft()
        this.jobId = jobId
        this.accountId = accountId
        this.confirmedBankId = confirmedResult.bankId
        this.artifactExpired = state.getCloudArtifactExpired()
        this.bankName = state.getCloudBankName()
        this.subject = state.getCloudSubject()
        if (state.getCloudStatus() === CloudImportStatus.CONFIRMED) {
          this.confirmationComplete = true
          return
        }
        if (cachedDraft !== null && cachedDraft.jobId === jobId) {
          this.applyDraft(cachedDraft, accountId)
        } else {
          this.errorMessage = '题目文字已确认，可继续重试保存原题图片'
        }
        return
      }
      const draft: CloudImportDraft = await CloudImportService.getDraft(context, jobId)
      this.applyDraft(draft, accountId)
      state.setCloudReviewDraft(draft)
      if (draft.status === CloudImportStatus.EXPIRED) {
        this.markArtifactExpired()
      }
    } catch (err) {
      if (this.isExpiredHttpError(err)) {
        const cachedDraft: CloudImportDraft | null = state.getCloudReviewDraft()
        if (cachedDraft !== null) {
          this.applyDraft(cachedDraft, accountId)
          this.markArtifactExpired()
        } else {
          this.errorMessage = '云端识别草稿已过期，请返回重新导入'
        }
      } else {
        this.errorMessage = this.errorText(err, '云端识别草稿加载失败，请重试')
      }
    } finally {
      this.loading = false
    }
  }

  private applyDraft(draft: CloudImportDraft, accountId: string): void {
    const copies: Array<CloudImportDraftQuestion> = new Array<CloudImportDraftQuestion>()
    for (let index: number = 0; index < draft.questions.length; index++) {
      copies.push(this.copyQuestion(draft.questions[index]))
    }
    this.jobId = draft.jobId
    this.accountId = accountId
    this.bankName = draft.bankName
    this.subject = draft.subject
    this.draftStatus = draft.status
    this.draftExpiresAt = draft.expiresAt
    this.draftQuestions = copies
    if (copies.length === 0) {
      this.errorMessage = '服务器没有返回可审核的题目'
    }
  }

  private copyQuestion(source: CloudImportDraftQuestion): CloudImportDraftQuestion {
    return new CloudImportDraftQuestion(source.draftQuestionId, source.type, source.question,
      source.options, source.answer, source.analysis, source.pageStart, source.pageEnd,
      source.confidence, source.reviewRequired, source.images.slice())
  }

  private replaceQuestion(draftQuestionId: string, type: string, questionText: string,
    options: Record<string, string> | null, answer: string | null,
    analysis: string | null): void {
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) {
      return
    }
    const source: CloudImportDraftQuestion = this.draftQuestions[index]
    const replacement: CloudImportDraftQuestion = new CloudImportDraftQuestion(
      source.draftQuestionId, type, questionText, options, answer, analysis,
      source.pageStart, source.pageEnd, source.confidence, source.reviewRequired,
      source.images.slice())
    const nextQuestions: Array<CloudImportDraftQuestion> = this.draftQuestions.slice()
    nextQuestions.splice(index, 1, replacement)
    this.draftQuestions = nextQuestions
    const draft: CloudImportDraft = new CloudImportDraft(this.jobId, this.draftStatus,
      this.bankName, this.subject, this.draftExpiresAt, nextQuestions)
    PdfImportState.shared().setCloudReviewDraft(draft)
  }

  private updateType(draftQuestionId: string, value: string): void {
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) {
      return
    }
    const source: CloudImportDraftQuestion = this.draftQuestions[index]
    this.replaceQuestion(draftQuestionId, value, source.question, source.options,
      source.answer, source.analysis)
  }

  private updateQuestionText(draftQuestionId: string, value: string): void {
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) {
      return
    }
    const source: CloudImportDraftQuestion = this.draftQuestions[index]
    this.replaceQuestion(draftQuestionId, source.type, value, source.options,
      source.answer, source.analysis)
  }

  private updateOption(draftQuestionId: string, optionKey: string, value: string): void {
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) {
      return
    }
    const source: CloudImportDraftQuestion = this.draftQuestions[index]
    const options: Record<string, string> | null = source.options
    if (options === null || Object.keys(options).indexOf(optionKey) < 0) {
      return
    }
    options[optionKey] = value
    this.replaceQuestion(draftQuestionId, source.type, source.question, options,
      source.answer, source.analysis)
  }

  private updateAnswer(draftQuestionId: string, value: string): void {
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) {
      return
    }
    const source: CloudImportDraftQuestion = this.draftQuestions[index]
    this.replaceQuestion(draftQuestionId, source.type, source.question, source.options,
      value, source.analysis)
  }

  private updateAnalysis(draftQuestionId: string, value: string): void {
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) {
      return
    }
    const source: CloudImportDraftQuestion = this.draftQuestions[index]
    this.replaceQuestion(draftQuestionId, source.type, source.question, source.options,
      source.answer, value)
  }

  private findQuestionIndex(draftQuestionId: string): number {
    for (let index: number = 0; index < this.draftQuestions.length; index++) {
      if (this.draftQuestions[index].draftQuestionId === draftQuestionId) {
        return index
      }
    }
    return -1
  }

  private validateDraft(): string {
    if (this.draftQuestions.length === 0) {
      return '请至少保留一道题目'
    }
    for (let index: number = 0; index < this.draftQuestions.length; index++) {
      if (this.draftQuestions[index].question.trim().length === 0) {
        return '第 ' + (index + 1).toString() + ' 题缺少题干，请补充后确认'
      }
    }
    return ''
  }

  private buildConfirmQuestions(): Array<ConfirmCloudImportQuestion> {
    const questions: Array<ConfirmCloudImportQuestion> = new Array<ConfirmCloudImportQuestion>()
    for (let index: number = 0; index < this.draftQuestions.length; index++) {
      const source: CloudImportDraftQuestion = this.draftQuestions[index]
      questions.push(new ConfirmCloudImportQuestion(source.draftQuestionId,
        this.questionType(source.type), source.question.trim(), source.options,
        source.answer, source.analysis, true))
    }
    return questions
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

  private async confirmDraft(): Promise<void> {
    if (this.pending || this.loading || this.navigationPending || this.confirmationComplete) {
      return
    }
    const state: PdfImportState = PdfImportState.shared()
    const existingResult: ConfirmImportResult | null = state.getConfirmResult()
    if (existingResult === null) {
      const validationMessage: string = this.validateDraft()
      if (validationMessage.length > 0) {
        this.errorMessage = validationMessage
        return
      }
    }
    const jobId: string = state.getCloudJobId()
    const accountId: string = state.getCloudAccountId()
    if (jobId.length === 0 || accountId.length === 0) {
      this.errorMessage = '云端导入任务信息已失效，请返回重新导入'
      return
    }
    this.pending = true
    this.errorMessage = ''
    try {
      const context: Context = getContext(this)
      await this.requireAccount(context, accountId)
      let result: ConfirmImportResult | null = existingResult
      if (result === null) {
        const request: ConfirmCloudImportRequest = new ConfirmCloudImportRequest(
          this.bankName.trim(), this.subject.trim(), this.buildConfirmQuestions())
        result = await CloudImportService.confirm(context, jobId, request)
        state.setConfirmResult(result)
      }
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
      this.confirmedBankId = result.bankId
      this.confirmationComplete = true
      state.setCloudArtifactExpired(this.artifactExpired)
      state.setCloudStatus(CloudImportStatus.CONFIRMED)
      this.showToast('题目文字已在服务器确认')
    } catch (err) {
      if (state.getConfirmResult() !== null) {
        this.errorMessage = '题目文字已确认，图片下载或保存失败，请重试'
      } else {
        this.errorMessage = this.errorText(err, '云端草稿确认失败，请重试')
      }
    } finally {
      this.pending = false
    }
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

  private nullableText(value: string | null): string {
    return value === null ? '' : value
  }

  private optionKeys(options: Record<string, string> | null): Array<string> {
    if (options === null) {
      return new Array<string>()
    }
    const keys: Array<string> = Object.keys(options)
    keys.sort((left: string, right: string): number => left.localeCompare(right))
    return keys
  }

  private optionValue(options: Record<string, string> | null, optionKey: string): string {
    return options === null ? '' : options[optionKey]
  }

  private typeLabel(value: string): string {
    if (value === 'single_choice') {
      return '单选题'
    }
    if (value === 'blank') {
      return '填空题'
    }
    if (value === 'short_answer') {
      return '解答题'
    }
    return '待确认'
  }

  private errorText(err: Error, fallback: string): string {
    return err instanceof Error && err.message.length > 0 ? err.message : fallback
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  private async returnToImportPage(): Promise<void> {
    if (this.pending || this.navigationPending) {
      return
    }
    this.navigationPending = true
    const options: router.RouterOptions = {
      url: 'pages/ImportBankPage'
    }
    try {
      await this.getUIContext().getRouter().replaceUrl(options)
    } catch {
      this.navigationPending = false
      this.errorMessage = '导入页面暂不可用，请重试返回'
    }
  }

  build() {
    Column() {
      AppHeader({
        title: '云端识别审核',
        showBack: true,
        onBack: () => {
          this.returnToImportPage()
        }
      })

      if (this.artifactExpired) {
        Text('原题图片已过期，文字仍可使用')
          .width('100%')
          .constraintSize({ minHeight: 48 })
          .padding({ left: 16, right: 16, top: 13, bottom: 13 })
          .margin({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 10 })
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.colors().warningText)
          .backgroundColor(this.colors().warning)
          .borderRadius(14)
      }

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .width('100%')
          .constraintSize({ minHeight: 48 })
          .padding({ left: 16, right: 16, top: 13, bottom: 13 })
          .margin({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 10 })
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.colors().error)
          .backgroundColor(this.colors().errorSoft)
          .borderRadius(14)
      }

      if (this.loading) {
        Column({ space: 16 }) {
          LoadingProgress()
            .width(42)
            .height(42)
            .color(this.colors().brand)
          Text('正在读取服务器识别草稿')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.confirmationComplete) {
        Column({ space: 16 }) {
          Text('云端题目已确认')
            .fontSize(SUBTITLE_FONT_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().brand)
          Text('题库标识：' + this.confirmedBankId)
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)
          Text('题目文字已由服务器保存，可返回导入页继续使用。')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textPrimary)
          Button(this.navigationPending ? '正在返回…' : '返回导入页')
            .width('100%')
            .height(52)
            .fontColor(this.colors().onBrand)
            .backgroundColor(this.colors().brand)
            .borderRadius(16)
            .enabled(!this.navigationPending)
            .onClick(() => {
              this.returnToImportPage()
            })
        }
        .layoutWeight(1)
        .width('100%')
        .padding(PAGE_PADDING)
        .justifyContent(FlexAlign.Center)
      } else if (this.draftQuestions.length === 0) {
        Column({ space: 16 }) {
          Text('暂时无法显示云端识别草稿')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textPrimary)
          Button(this.pending ? '正在重试…' : '重新读取草稿')
            .width('100%')
            .height(52)
            .fontColor(this.colors().onBrand)
            .backgroundColor(this.colors().brand)
            .borderRadius(16)
            .enabled(!this.pending)
            .onClick(() => {
              this.loadDraft()
            })
        }
        .layoutWeight(1)
        .width('100%')
        .padding(PAGE_PADDING)
        .justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 8 }) {
          Text(this.bankName)
            .width('100%')
            .fontSize(SUBTITLE_FONT_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().textPrimary)
          Text('学科：' + this.subject + ' · 共 ' + this.draftQuestions.length.toString() + ' 题')
            .width('100%')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)
        }
        .width('100%')
        .padding(16)
        .margin({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 12 })
        .backgroundColor(this.colors().cardBackground)
        .borderRadius(CARD_RADIUS)

        List({ space: 14 }) {
          ForEach(this.draftQuestions,
            (draftQuestion: CloudImportDraftQuestion, questionIndex: number) => {
              ListItem() {
                Column({ space: 14 }) {
                  Row() {
                    Text('第 ' + (questionIndex + 1).toString() + ' 题')
                      .fontSize(SUBTITLE_FONT_SIZE)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(this.colors().textPrimary)
                    Blank()
                    Text(this.typeLabel(draftQuestion.type))
                      .fontSize(12)
                      .fontColor(draftQuestion.type === 'unknown' ?
                        this.colors().error : this.colors().brand)
                  }
                  .width('100%')

                  Text('页码 ' + draftQuestion.pageStart.toString() + '-' +
                    draftQuestion.pageEnd.toString() + ' · 置信度 ' +
                    Math.round(draftQuestion.confidence * 100).toString() + '%')
                    .width('100%')
                    .fontSize(12)
                    .fontColor(this.colors().textSecondary)

                  Row({ space: 6 }) {
                    Button('单选')
                      .layoutWeight(1)
                      .height(38)
                      .fontColor(draftQuestion.type === 'single_choice' ?
                        this.colors().onBrand : this.colors().brand)
                      .backgroundColor(draftQuestion.type === 'single_choice' ?
                        this.colors().brand : this.colors().chipBackground)
                      .enabled(!this.pending)
                      .onClick(() => {
                        this.updateType(draftQuestion.draftQuestionId, 'single_choice')
                      })
                    Button('填空')
                      .layoutWeight(1)
                      .height(38)
                      .fontColor(draftQuestion.type === 'blank' ?
                        this.colors().onBrand : this.colors().brand)
                      .backgroundColor(draftQuestion.type === 'blank' ?
                        this.colors().brand : this.colors().chipBackground)
                      .enabled(!this.pending)
                      .onClick(() => {
                        this.updateType(draftQuestion.draftQuestionId, 'blank')
                      })
                    Button('解答')
                      .layoutWeight(1)
                      .height(38)
                      .fontColor(draftQuestion.type === 'short_answer' ?
                        this.colors().onBrand : this.colors().brand)
                      .backgroundColor(draftQuestion.type === 'short_answer' ?
                        this.colors().brand : this.colors().chipBackground)
                      .enabled(!this.pending)
                      .onClick(() => {
                        this.updateType(draftQuestion.draftQuestionId, 'short_answer')
                      })
                    Button('待确认')
                      .layoutWeight(1)
                      .height(38)
                      .fontColor(draftQuestion.type === 'unknown' ?
                        this.colors().onBrand : this.colors().brand)
                      .backgroundColor(draftQuestion.type === 'unknown' ?
                        this.colors().brand : this.colors().chipBackground)
                      .enabled(!this.pending)
                      .onClick(() => {
                        this.updateType(draftQuestion.draftQuestionId, 'unknown')
                      })
                  }
                  .width('100%')

                  TextArea({ placeholder: '请输入题干', text: draftQuestion.question })
                    .width('100%')
                    .height(108)
                    .fontSize(BODY_FONT_SIZE)
                    .fontColor(this.colors().textPrimary)
                    .backgroundColor(this.colors().inputBackground)
                    .enabled(!this.pending)
                    .onChange((value: string) => {
                      this.updateQuestionText(draftQuestion.draftQuestionId, value)
                    })

                  Column({ space: 6 }) {
                    Text('识别选项')
                      .width('100%')
                      .fontSize(12)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.colors().textCaption)
                    if (this.optionKeys(draftQuestion.options).length === 0) {
                      Text('暂无选项')
                        .width('100%')
                        .padding(12)
                        .fontSize(BODY_FONT_SIZE)
                        .fontColor(this.colors().textSecondary)
                        .backgroundColor(this.colors().inputBackground)
                        .borderRadius(10)
                    } else {
                      ForEach(this.optionKeys(draftQuestion.options), (optionKey: string) => {
                        TextInput({
                          placeholder: '选项 ' + optionKey,
                          text: this.optionValue(draftQuestion.options, optionKey)
                        })
                          .width('100%')
                          .height(46)
                          .fontSize(BODY_FONT_SIZE)
                          .fontColor(this.colors().textPrimary)
                          .backgroundColor(this.colors().inputBackground)
                          .enabled(!this.pending)
                          .onChange((value: string) => {
                            this.updateOption(draftQuestion.draftQuestionId, optionKey, value)
                          })
                      }, (optionKey: string): string =>
                        draftQuestion.draftQuestionId + '_option_' + optionKey)
                    }
                  }
                  .width('100%')

                  TextInput({
                    placeholder: '答案（选填）',
                    text: this.nullableText(draftQuestion.answer)
                  })
                    .width('100%')
                    .height(46)
                    .fontSize(BODY_FONT_SIZE)
                    .fontColor(this.colors().textPrimary)
                    .backgroundColor(this.colors().inputBackground)
                    .enabled(!this.pending)
                    .onChange((value: string) => {
                      this.updateAnswer(draftQuestion.draftQuestionId, value)
                    })

                  TextArea({
                    placeholder: '解析（选填）',
                    text: this.nullableText(draftQuestion.analysis)
                  })
                    .width('100%')
                    .height(96)
                    .fontSize(BODY_FONT_SIZE)
                    .fontColor(this.colors().textPrimary)
                    .backgroundColor(this.colors().inputBackground)
                    .enabled(!this.pending)
                    .onChange((value: string) => {
                      this.updateAnalysis(draftQuestion.draftQuestionId, value)
                    })

                  if (draftQuestion.reviewRequired) {
                    Text('服务器标记：需要人工复核')
                      .width('100%')
                      .fontSize(12)
                      .fontColor(this.colors().error)
                  }
                }
                .width('100%')
                .padding(18)
                .backgroundColor(this.colors().cardBackground)
                .borderRadius(CARD_RADIUS)
              }
            },
            (draftQuestion: CloudImportDraftQuestion): string => draftQuestion.draftQuestionId)
        }
        .layoutWeight(1)
        .width('100%')
        .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
        .scrollBar(BarState.Off)

        Column({ space: 8 }) {
          if (PdfImportState.shared().getConfirmResult() !== null) {
            Text('题目文字已确认；重试只会重新下载和保存图片，不会再次确认文字。')
              .width('100%')
              .fontSize(12)
              .fontColor(this.colors().textCaption)
          }
          Button(this.pending ? '正在处理…' :
            PdfImportState.shared().getConfirmResult() === null ? '确认题目并保存原图' : '重试保存原题图片')
            .width('100%')
            .height(52)
            .fontColor(this.colors().onBrand)
            .backgroundColor(this.colors().brand)
            .borderRadius(16)
            .enabled(!this.pending && !this.navigationPending)
            .onClick(() => {
              this.confirmDraft()
            })
        }
        .width('100%')
        .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
        .padding({
          left: PAGE_PADDING,
          right: PAGE_PADDING,
          top: 12,
          bottom: PAGE_PADDING + SafeAreaUtils.bottom(this.safeAreaInsets)
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
