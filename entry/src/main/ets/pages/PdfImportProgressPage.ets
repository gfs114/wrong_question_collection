import { Context } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'
import { AppHeader } from '../components/AppHeader'
import { CloudImportStatusCard } from '../components/CloudImportStatusCard'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { AccountSessionState } from '../models/AccountSession'
import {
  CloudImportJob,
  CloudImportStatus,
  CompleteCloudImportResult
} from '../models/CloudImportModels'
import { AccountSessionService } from '../services/AccountSessionService'
import { CloudImportService } from '../services/CloudImportService'
import { AppColors } from '../theme/AppColors'
import { CloudPdfSelection, PdfImportState } from '../utils/PdfImportState'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

@Entry
@Component
struct PdfImportProgressPage {
  @State statusLabel: string = '上传中'
  @State serverStatus: string = '上传中'
  @State progressCurrent: number = 0
  @State progressTotal: number = 0
  @State errorMessage: string = ''
  @State retryHint: string = '上传中断后可继续上传'
  @State bankName: string = ''
  @State subject: string = ''
  @State actionPending: boolean = false
  @State reviewNavigationPending: boolean = false
  @State accountVerified: boolean = false
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = {
    top: 0, left: 0, right: 0, bottom: 0
  }
  @StorageProp('darkMode') darkMode: boolean = false
  private initialized: boolean = false
  private pageActive: boolean = false
  private flowInFlight: boolean = false
  private flowNeedsRestart: boolean = false
  private flowGeneration: number = 0
  private pollingActive: boolean = false
  private pollingGeneration: number = 0
  private pollAttempt: number = 0
  private pollTimerId: number = -1
  private reviewNavigationCompleted: boolean = false

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  aboutToAppear(): void {
    this.pageActive = true
    if (this.initialized) {
      return
    }
    this.initialized = true
    this.startCloudFlow()
  }

  onPageShow(): void {
    this.pageActive = true
    if (this.initialized && this.flowInFlight && !this.pollingActive &&
      !this.reviewNavigationPending && !this.reviewNavigationCompleted) {
      this.startPolling()
      return
    }
    if (this.initialized && !this.flowInFlight && !this.pollingActive &&
      !this.reviewNavigationPending && !this.reviewNavigationCompleted) {
      this.startCloudFlow()
    }
  }

  onPageHide(): void {
    this.pageActive = false
    if (this.flowInFlight) {
      this.flowNeedsRestart = true
    }
    this.flowGeneration++
    this.hideJobMetadata()
    this.stopPolling()
  }

  aboutToDisappear(): void {
    this.pageActive = false
    if (this.flowInFlight) {
      this.flowNeedsRestart = true
    }
    this.flowGeneration++
    this.hideJobMetadata()
    this.stopPolling()
  }

  onBackPress(): boolean {
    this.goBack()
    return true
  }

  private startCloudFlow(): void {
    if (this.flowInFlight || this.reviewNavigationPending || this.reviewNavigationCompleted) {
      return
    }
    this.clearPollTimer()
    this.pollingActive = false
    this.pollingGeneration++
    this.flowInFlight = true
    this.flowNeedsRestart = false
    this.flowGeneration++
    const generation: number = this.flowGeneration
    this.actionPending = true
    this.errorMessage = ''
    this.runCloudFlow(generation).catch((err: Error) => {
      if (generation === this.flowGeneration) {
        this.handleFlowFailure(err)
      }
    }).finally(() => {
      this.flowInFlight = false
      this.actionPending = false
      if (this.pageActive && this.flowNeedsRestart && !this.reviewNavigationPending &&
        !this.reviewNavigationCompleted) {
        this.startCloudFlow()
      }
    })
  }

  private async runCloudFlow(generation: number): Promise<void> {
    const state: PdfImportState = PdfImportState.shared()
    const storedJob: CloudImportJob | null = state.getCloudJob()
    if (storedJob === null || storedJob.jobId.length === 0) {
      throw new Error('云端导入任务信息不完整')
    }
    const accountId: string = state.getCloudAccountId()
    if (accountId.length === 0) {
      throw new Error('云端导入账号信息不完整')
    }
    const jobId: string = storedJob.jobId
    const context: Context = getContext(this)
    await this.requireAccount(context, accountId)
    if (!this.isFlowCurrent(generation, jobId, accountId)) {
      return
    }
    this.accountVerified = true
    this.applyJob(storedJob)
    const remoteJob: CloudImportJob = await CloudImportService.getJob(context, jobId)
    if (!this.isFlowCurrent(generation, jobId, accountId)) {
      return
    }
    await this.requireAccount(context, accountId)
    if (!this.isFlowCurrent(generation, jobId, accountId)) {
      return
    }
    state.setCloudJob(remoteJob)
    this.applyJob(remoteJob)
    if (remoteJob.status !== CloudImportStatus.UPLOADING) {
      this.continueForStatus(remoteJob)
      return
    }
    const selection: CloudPdfSelection | null = state.getCloudSelection()
    if (selection === null || selection.pdfPath.length === 0) {
      throw new Error('PDF 暂存文件信息已丢失，无法继续上传')
    }
    const firstMissingPart: number = this.resumePart(remoteJob, state.getFirstMissingPart())
    state.setFirstMissingPart(firstMissingPart)
    this.progressCurrent = firstMissingPart
    this.progressTotal = remoteJob.partCount
    this.statusLabel = '上传中'
    this.serverStatus = '上传中'
    this.retryHint = '上传中断后可从已记录分片继续'
    if (this.pageActive && this.isFlowCurrent(generation, jobId, accountId)) {
      this.startPolling()
    }
    const completed: CompleteCloudImportResult = await CloudImportService.resumeUpload(
      context, selection.pdfPath, remoteJob, firstMissingPart)
    if (!this.isFlowCurrent(generation, jobId, accountId)) {
      return
    }
    await this.requireAccount(context, accountId)
    if (!this.isFlowCurrent(generation, jobId, accountId)) {
      return
    }
    state.setFirstMissingPart(remoteJob.partCount)
    state.setCloudStatus(completed.status)
    state.setCloudProgress(remoteJob.partCount, remoteJob.partCount)
    if (this.pageActive) {
      this.statusLabel = this.labelForStatus(completed.status)
      this.serverStatus = this.serverLabelForStatus(completed.status)
      this.progressCurrent = remoteJob.partCount
      this.progressTotal = remoteJob.partCount
      this.retryHint = this.retryHintForStatus(completed.status)
      this.startPolling()
    }
  }

  private resumePart(job: CloudImportJob, savedPart: number): number {
    let firstMissingPart: number = savedPart
    if (!Number.isInteger(firstMissingPart) || firstMissingPart < 0 ||
      firstMissingPart > job.partCount) {
      firstMissingPart = 0
    }
    if (job.progress.total === job.partCount && Number.isInteger(job.progress.current) &&
      job.progress.current >= 0 && job.progress.current <= job.partCount) {
      firstMissingPart = Math.max(firstMissingPart, job.progress.current)
    }
    return firstMissingPart
  }

  private applyJob(job: CloudImportJob): void {
    if (!this.pageActive) {
      return
    }
    this.bankName = job.bankName
    this.subject = job.subject
    this.statusLabel = this.labelForStatus(job.status)
    this.serverStatus = this.serverLabelForStatus(job.status)
    this.retryHint = this.retryHintForStatus(job.status)
    if (job.status === CloudImportStatus.UPLOADING) {
      const uploadPart: number = this.resumePart(job, PdfImportState.shared().getFirstMissingPart())
      this.progressCurrent = uploadPart
      this.progressTotal = job.partCount
    } else {
      this.progressCurrent = job.progress.current
      this.progressTotal = job.progress.total
    }
    if (job.status === CloudImportStatus.FAILED) {
      this.errorMessage = '服务器处理失败，请稍后重新导入'
    } else {
      this.errorMessage = ''
    }
  }

  private continueForStatus(job: CloudImportJob): void {
    if (!this.pageActive) {
      return
    }
    if (job.status === CloudImportStatus.REVIEW) {
      this.stopPolling()
      this.navigateToReview()
      return
    }
    if (this.shouldPoll(job.status)) {
      this.startPolling()
      return
    }
    this.stopPolling()
  }

  private shouldPoll(status: CloudImportStatus): boolean {
    return status === CloudImportStatus.UPLOADING || status === CloudImportStatus.QUEUED ||
      status === CloudImportStatus.PROCESSING
  }

  private startPolling(): void {
    if (!this.pageActive || this.reviewNavigationPending || this.reviewNavigationCompleted) {
      return
    }
    this.clearPollTimer()
    this.pollingActive = true
    this.pollAttempt = 0
    this.pollingGeneration++
    const generation: number = this.pollingGeneration
    this.pollJob(generation)
  }

  private async pollJob(generation: number): Promise<void> {
    if (!this.pollingActive || !this.pageActive || generation !== this.pollingGeneration) {
      return
    }
    const state: PdfImportState = PdfImportState.shared()
    const jobId: string = state.getCloudJobId()
    const accountId: string = state.getCloudAccountId()
    if (jobId.length === 0 || accountId.length === 0) {
      this.errorMessage = '云端导入任务信息不完整'
      this.retryHint = '请返回导入页重新创建任务'
      this.stopPolling()
      return
    }
    try {
      await this.requireAccount(getContext(this), accountId)
      if (!this.isPollingCurrent(generation, jobId, accountId)) {
        return
      }
      this.accountVerified = true
      const job: CloudImportJob = await CloudImportService.getJob(getContext(this), jobId)
      if (!this.isPollingCurrent(generation, jobId, accountId)) {
        return
      }
      await this.requireAccount(getContext(this), accountId)
      if (!this.isPollingCurrent(generation, jobId, accountId)) {
        return
      }
      state.setCloudJob(job)
      this.applyJob(job)
      if (job.status === CloudImportStatus.REVIEW) {
        this.stopPolling()
        this.navigateToReview()
        return
      }
      if (!this.shouldPoll(job.status)) {
        this.stopPolling()
        return
      }
      this.scheduleNextPoll(generation)
    } catch (err) {
      if (!this.pollingActive || !this.pageActive || generation !== this.pollingGeneration) {
        return
      }
      this.errorMessage = this.messageForError(err)
      if (this.isAccountError(err)) {
        this.hideJobMetadata()
        this.retryHint = '请使用创建此任务的华为账号后重试'
        this.stopPolling()
        return
      }
      this.retryHint = '网络恢复后会自动重试，也可立即重新查询'
      this.scheduleNextPoll(generation)
    }
  }

  private scheduleNextPoll(generation: number): void {
    if (!this.pollingActive || !this.pageActive || generation !== this.pollingGeneration) {
      return
    }
    this.clearPollTimer()
    const delay: number = this.nextPollDelay()
    this.pollTimerId = setTimeout(() => {
      this.pollTimerId = -1
      this.pollJob(generation)
    }, delay)
  }

  private nextPollDelay(): number {
    const attempt: number = this.pollAttempt
    this.pollAttempt = Math.min(this.pollAttempt + 1, 3)
    if (attempt === 0) {
      return 1000
    }
    if (attempt === 1) {
      return 2000
    }
    if (attempt === 2) {
      return 4000
    }
    return 5000
  }

  private stopPolling(): void {
    this.pollingActive = false
    this.pollingGeneration++
    this.clearPollTimer()
  }

  private clearPollTimer(): void {
    if (this.pollTimerId >= 0) {
      clearTimeout(this.pollTimerId)
      this.pollTimerId = -1
    }
  }

  private retryNow(): void {
    if (this.flowInFlight || this.reviewNavigationPending || this.reviewNavigationCompleted) {
      return
    }
    this.pageActive = true
    this.stopPolling()
    this.startCloudFlow()
  }

  private handleFlowFailure(err: Error): void {
    if (!this.pageActive) {
      return
    }
    if (this.isAccountError(err)) {
      this.hideJobMetadata()
    }
    this.errorMessage = this.messageForError(err)
    this.retryHint = '请检查网络与登录状态后重试'
  }

  private messageForError(err: Error): string {
    if (err instanceof Error) {
      if (err.message.includes('请先登录') || err.message.includes('账号')) {
        return err.message
      }
      if (err.message.includes('信息不完整')) {
        return '云端导入任务信息不完整，请返回重新导入'
      }
      if (err.message.includes('暂存文件')) {
        return 'PDF 暂存文件不可用，请返回重新选择'
      }
      if (err.message.includes('does not match') || err.message.includes('changed')) {
        return 'PDF 文件已变化，请返回重新选择'
      }
      if (err.message.includes('already active')) {
        return 'PDF 正在上传，请稍后重新查询状态'
      }
    }
    return '云端导入暂时不可用，请检查网络后重试'
  }

  private isFlowCurrent(generation: number, jobId: string, accountId: string): boolean {
    const state: PdfImportState = PdfImportState.shared()
    return generation === this.flowGeneration && state.getCloudJobId() === jobId &&
      state.getCloudAccountId() === accountId
  }

  private isPollingCurrent(generation: number, jobId: string, accountId: string): boolean {
    const state: PdfImportState = PdfImportState.shared()
    return this.pollingActive && this.pageActive && generation === this.pollingGeneration &&
      state.getCloudJobId() === jobId && state.getCloudAccountId() === accountId
  }

  private async requireAccount(context: Context, accountId: string): Promise<void> {
    const session: AccountSessionState = await AccountSessionService.state(context)
    if (!session.signedIn || session.userId.length === 0) {
      throw new Error('请先登录华为账号')
    }
    if (session.userId !== accountId) {
      throw new Error('当前华为账号与云端导入任务不一致')
    }
  }

  private isAccountError(err: Error): boolean {
    return err instanceof Error &&
      (err.message.includes('请先登录') || err.message.includes('账号'))
  }

  private hideJobMetadata(): void {
    this.accountVerified = false
    this.bankName = ''
    this.subject = ''
    this.progressCurrent = 0
    this.progressTotal = 0
    this.statusLabel = '账号验证中'
    this.serverStatus = '正在验证账号'
  }

  private labelForStatus(status: CloudImportStatus): string {
    if (status === CloudImportStatus.UPLOADING) {
      return '上传中'
    }
    if (status === CloudImportStatus.QUEUED || status === CloudImportStatus.PROCESSING) {
      return '服务器识别中'
    }
    if (status === CloudImportStatus.REVIEW) {
      return '等待确认'
    }
    if (status === CloudImportStatus.FAILED) {
      return '处理失败'
    }
    if (status === CloudImportStatus.CANCELLED) {
      return '已取消'
    }
    if (status === CloudImportStatus.EXPIRED) {
      return '已过期'
    }
    return '已确认'
  }

  private serverLabelForStatus(status: CloudImportStatus): string {
    if (status === CloudImportStatus.UPLOADING) {
      return '上传中'
    }
    if (status === CloudImportStatus.QUEUED) {
      return '服务器排队中'
    }
    if (status === CloudImportStatus.PROCESSING) {
      return '服务器识别中'
    }
    if (status === CloudImportStatus.REVIEW) {
      return '等待确认'
    }
    if (status === CloudImportStatus.FAILED) {
      return '处理失败'
    }
    if (status === CloudImportStatus.CANCELLED) {
      return '已取消'
    }
    if (status === CloudImportStatus.EXPIRED) {
      return '已过期'
    }
    return '已确认'
  }

  private retryHintForStatus(status: CloudImportStatus): string {
    if (status === CloudImportStatus.UPLOADING) {
      return '上传中断后可从已记录分片继续'
    }
    if (status === CloudImportStatus.QUEUED || status === CloudImportStatus.PROCESSING) {
      return '页面会自动查询服务器进度'
    }
    if (status === CloudImportStatus.REVIEW) {
      return '请继续在线审核识别草稿'
    }
    if (status === CloudImportStatus.FAILED) {
      return '可返回导入页重新创建任务'
    }
    if (status === CloudImportStatus.CANCELLED) {
      return '任务已取消，如需导入请重新创建任务'
    }
    if (status === CloudImportStatus.EXPIRED) {
      return '任务已过期，请重新创建导入任务'
    }
    return '题目文字已经保存'
  }

  private navigateToReview(): void {
    if (!this.pageActive || !this.accountVerified || this.reviewNavigationPending ||
      this.reviewNavigationCompleted) {
      return
    }
    this.stopPolling()
    this.reviewNavigationPending = true
    this.errorMessage = ''
    const options: router.RouterOptions = {
      url: 'pages/PdfImportReviewPage'
    }
    this.getUIContext().getRouter().replaceUrl(options).then(() => {
      this.reviewNavigationCompleted = true
    }).catch(() => {
      this.errorMessage = '审核页面暂不可用，请稍后重试'
      this.retryHint = '点击进入审核可再次尝试'
      this.reviewNavigationPending = false
    })
  }

  private async continueReview(): Promise<void> {
    if (this.actionPending || !this.accountVerified) {
      return
    }
    const state: PdfImportState = PdfImportState.shared()
    const jobId: string = state.getCloudJobId()
    const accountId: string = state.getCloudAccountId()
    if (jobId.length === 0 || accountId.length === 0) {
      this.errorMessage = '云端导入任务信息不完整，请返回重新导入'
      return
    }
    const generation: number = this.flowGeneration
    this.actionPending = true
    try {
      await this.requireAccount(getContext(this), accountId)
      if (!this.pageActive || generation !== this.flowGeneration ||
        state.getCloudJobId() !== jobId || state.getCloudAccountId() !== accountId) {
        return
      }
      this.accountVerified = true
      this.navigateToReview()
    } catch (err) {
      if (!this.pageActive || generation !== this.flowGeneration) {
        return
      }
      this.hideJobMetadata()
      this.errorMessage = this.messageForError(err)
      this.retryHint = '请使用创建此任务的华为账号后重试'
    } finally {
      this.actionPending = false
    }
  }

  private goBack(): void {
    this.pageActive = false
    if (this.flowInFlight) {
      this.flowNeedsRestart = true
    }
    this.flowGeneration++
    this.hideJobMetadata()
    this.stopPolling()
    try {
      this.getUIContext().getRouter().back()
    } catch {
      this.pageActive = true
      this.errorMessage = '暂时无法返回，云端任务仍会保留'
      this.retryHint = '请稍后重试返回或继续查询任务'
      if (!this.flowInFlight) {
        this.startCloudFlow()
      }
    }
  }

  build() {
    Column() {
      AppHeader({
        title: '云端 PDF 导入',
        showBack: true,
        onBack: () => {
          this.goBack()
        }
      })

      Scroll() {
        Column({ space: 16 }) {
          CloudImportStatusCard({
            status: this.statusLabel,
            progressCurrent: this.progressCurrent,
            progressTotal: this.progressTotal,
            errorMessage: this.errorMessage,
            retryHint: this.retryHint,
            serverStatus: this.serverStatus
          })

          if (this.bankName.length > 0 || this.subject.length > 0) {
            Column({ space: 8 }) {
              Text(this.bankName.length > 0 ? this.bankName : '未命名题库')
                .width('100%')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().textPrimary)

              Text(this.subject.length > 0 ? this.subject : '未设置学科')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textCaption)
            }
            .width('100%')
            .padding(18)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(CARD_RADIUS)
          }

          if (this.statusLabel === '等待确认' && this.accountVerified) {
            Button(this.reviewNavigationPending || this.actionPending ? '正在进入审核…' : '进入审核')
              .type(ButtonType.Normal)
              .width('100%')
              .height(52)
              .fontSize(SUBTITLE_FONT_SIZE)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors().onBrand)
              .backgroundColor(this.colors().brand)
              .borderRadius(16)
              .enabled(!this.reviewNavigationPending && !this.actionPending && this.accountVerified)
              .onClick(() => {
                this.continueReview()
              })
          } else if (this.statusLabel === '处理失败' || this.statusLabel === '已取消' ||
            this.statusLabel === '已过期' || this.statusLabel === '已确认') {
            Button('返回导入页')
              .type(ButtonType.Normal)
              .width('100%')
              .height(52)
              .fontSize(SUBTITLE_FONT_SIZE)
              .fontColor(this.colors().onBrand)
              .backgroundColor(this.statusLabel === '处理失败' ? this.colors().error : this.colors().brand)
              .borderRadius(16)
              .onClick(() => {
                this.goBack()
              })
          } else {
            Row({ space: 12 }) {
              Button('返回')
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(50)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textPrimary)
                .backgroundColor(this.colors().cardBackground)
                .borderRadius(15)
                .onClick(() => {
                  this.goBack()
                })

              Button(this.actionPending ? '正在处理…' : '立即刷新')
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(50)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().onBrand)
                .backgroundColor(this.colors().brand)
                .borderRadius(15)
                .enabled(!this.actionPending)
                .onClick(() => {
                  this.retryNow()
                })
            }
            .width('100%')
          }

          Text('离开此页面只会停止进度查询，不会取消服务器任务。')
            .width('100%')
            .fontSize(12)
            .fontColor(this.colors().textCaption)
            .textAlign(TextAlign.Center)
            .lineHeight(19)
        }
        .width('100%')
        .padding({
          left: PAGE_PADDING,
          right: PAGE_PADDING,
          bottom: PAGE_PADDING + SafeAreaUtils.bottom(this.safeAreaInsets)
        })
      }
      .layoutWeight(1)
      .width('100%')
      .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
