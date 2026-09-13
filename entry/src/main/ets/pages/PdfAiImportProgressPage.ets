import { Context } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'
import { util } from '@kit.ArkTS'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { ResponsiveLayout, WindowSizeClass, WindowSizeObserver } from '../constants/ResponsiveLayout'
import { UiStyle } from '../constants/UiStyle'
import { AccountSessionState } from '../models/AccountSession'
import { PdfFileSelection, PdfImportSettings } from '../models/PdfImportModels'
import {
  AiImportError,
  AiImportErrorCode,
  AiImportErrorMessages,
  AiProviderConfig
} from '../models/ai/AiProviderConfig'
import { AccountSessionService } from '../services/AccountSessionService'
import { PdfImportService } from '../services/PdfImportService'
import { AiCredentialStore } from '../services/ai/AiCredentialStore'
import {
  AiImportCleanupRequiredError,
  PdfAiImportCoordinator,
  PdfAiImportRequest
} from '../services/ai/PdfAiImportCoordinator'
import { AiProviderConfigStore } from '../services/ai/AiProviderConfigStore'
import { AppColors } from '../theme/AppColors'
import { PdfImportState } from '../utils/PdfImportState'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

@Entry
@Component
struct PdfAiImportProgressPage {
  private coordinator: PdfAiImportCoordinator = PdfAiImportCoordinator.createDefault()
  private started: boolean = false
  private request: PdfAiImportRequest | null = null
  private selectedPdfPath: string = ''
  private completedSessionId: string = ''
  private cleanupInFlight: boolean = false
  @State currentPage: number = 0
  @State totalPages: number = 0
  @State processedPages: number = 0
  @State questionCount: number = 0
  @State statusText: string = '准备识别'
  @State errorMessage: string = ''
  @State cancelled: boolean = false
  @State running: boolean = true
  @State cancellable: boolean = true
  @State cleanupPending: boolean = false
  @State reviewNavigationFailed: boolean = false
  @State navigationPending: boolean = false
  @State returnNavigationPending: boolean = false
  @State windowSizeClass: WindowSizeClass = WindowSizeClass.COMPACT
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = {
    top: 0, left: 0, right: 0, bottom: 0
  }
  @StorageProp('darkMode') darkMode: boolean = false
  private sizeObserver?: WindowSizeObserver

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  aboutToAppear(): void {
    this.startWindowObserver()
    if (!this.started) {
      this.started = true
      this.startImport()
    }
  }

  onPageShow(): void {
    this.startWindowObserver()
  }

  onPageHide(): void {
    this.stopWindowObserver()
  }

  onBackPress(): boolean {
    if (this.cancellable) {
      this.cancelImport()
      return true
    }
    if (this.completedSessionId.length > 0 || this.cleanupPending || this.navigationPending) {
      this.errorMessage = this.cleanupPending ? '临时文件尚未清理完成，请先重试清理' :
        '识别结果已生成，请进入审核或放弃并清理'
      return true
    }
    if (this.returnNavigationPending) {
      this.returnToImportPage()
      return true
    }
    return false
  }

  private async startImport(): Promise<void> {
    const context: Context = getContext(this)
    const state: PdfImportState = PdfImportState.shared()
    const selection: PdfFileSelection | null = state.getSelection()
    const settings: PdfImportSettings | null = state.getSettings()
    this.running = true
    this.cancellable = true
    this.errorMessage = ''
    try {
      if (selection === null || settings === null) {
        this.running = false
        this.cancellable = false
        this.errorMessage = 'AI 导入配置已失效，请返回重新设置'
        return
      }
      this.selectedPdfPath = selection.uri
      this.totalPages = settings.endPage - settings.startPage + 1
      const config: AiProviderConfig | null = await AiProviderConfigStore.loadUsable(context)
      this.requireNotCancelled()
      if (config === null) {
        this.running = false
        this.cancellable = false
        this.errorMessage = 'AI 导入配置已失效，请返回重新设置'
        return
      }
      const account: AccountSessionState = await AccountSessionService.state(context)
      this.requireNotCancelled()
      if (!account.signedIn || account.userId.length === 0) {
        this.running = false
        this.cancellable = false
        this.errorMessage = 'AI 导入配置已失效，请返回重新设置'
        return
      }
      const hasCredential: boolean = await AiCredentialStore.hasCredential(context)
      this.requireNotCancelled()
      if (!hasCredential) {
        throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
      }
      const sessionId: string = util.generateRandomUUID()
      this.request = new PdfAiImportRequest(
        sessionId, account.userId, selection.uri, settings, config)
      await this.coordinator.run(context, this.request,
        (current: number, total: number, processed: number, count: number, stage: string): void => {
          this.currentPage = current
          this.totalPages = total
          this.processedPages = processed
          this.questionCount = count
          this.statusText = stage
        })
      this.running = false
      this.cancellable = false
      this.completedSessionId = sessionId
      state.setReviewSessionId(sessionId)
      this.statusText = '正在验证账号'
      await this.continueToReview()
    } catch (err) {
      if (this.cancelled || (err instanceof AiImportError && err.code === AiImportErrorCode.CANCELLED)) {
        this.running = false
        this.cancellable = false
        await this.cleanupAndReturn()
        return
      }
      if (err instanceof AiImportCleanupRequiredError) {
        this.running = false
        this.cancellable = false
        await this.cleanupAndReturn()
        return
      }
      this.running = false
      this.cancellable = false
      this.errorMessage = err instanceof AiImportError ?
        AiImportErrorMessages.forCode(err.code) : 'AI 识别失败'
    }
  }

  private requireNotCancelled(): void {
    if (this.cancelled) throw new AiImportError(AiImportErrorCode.CANCELLED)
  }

  private cancelImport(): void {
    if (this.cancelled || !this.cancellable) return
    this.cancelled = true
    this.coordinator.cancel()
    this.statusText = '正在取消'
  }

  private async cleanupAndReturn(): Promise<void> {
    if (this.cleanupInFlight) return
    this.cleanupInFlight = true
    this.cleanupPending = false
    this.reviewNavigationFailed = false
    this.navigationPending = false
    this.running = false
    this.cancellable = false
    this.statusText = '正在清理临时文件'
    const context: Context = getContext(this)
    const state: PdfImportState = PdfImportState.shared()
    try {
      if (this.request !== null) {
        await this.coordinator.discard(context, this.request)
      } else if (this.selectedPdfPath.length > 0) {
        await PdfImportService.removeTemporaryPdf(this.selectedPdfPath)
      }
    } catch {
      this.cleanupInFlight = false
      this.cleanupPending = true
      this.statusText = '清理失败'
      this.errorMessage = '临时文件清理失败，请点击重试清理'
      return
    }
    state.reset()
    this.request = null
    this.selectedPdfPath = ''
    this.completedSessionId = ''
    this.cleanupPending = false
    this.cleanupInFlight = false
    this.statusText = '已清理'
    await this.returnToImportPage()
  }

  private async retryCleanup(): Promise<void> {
    if (!this.cleanupPending || this.cleanupInFlight) return
    await this.cleanupAndReturn()
  }

  private async continueToReview(): Promise<void> {
    if (this.request === null || this.completedSessionId.length === 0 ||
      this.cleanupInFlight || this.navigationPending) return
    this.navigationPending = true
    this.reviewNavigationFailed = false
    this.errorMessage = ''
    this.statusText = '正在验证账号'
    const context: Context = getContext(this)
    let account: AccountSessionState
    try {
      account = await AccountSessionService.state(context)
    } catch {
      this.navigationPending = false
      this.reviewNavigationFailed = true
      this.statusText = '等待进入审核'
      this.errorMessage = '账号状态暂时无法确认，请重新进入审核'
      return
    }
    if (!account.signedIn || account.userId.length === 0 ||
      account.userId !== this.request.accountId) {
      this.navigationPending = false
      this.errorMessage = '当前账号已变化，正在清理本次识别结果'
      await this.cleanupAndReturn()
      return
    }
    this.statusText = '正在进入审核'
    try {
      const reviewOptions: router.RouterOptions = {
        url: 'pages/PdfImportReviewPage'
      }
      await this.getUIContext().getRouter().replaceUrl(reviewOptions)
    } catch {
      this.reviewNavigationFailed = true
      this.statusText = '等待进入审核'
      this.errorMessage = '审核页面暂不可用，请重新进入审核或放弃并清理'
    } finally {
      this.navigationPending = false
    }
  }

  private async retryReviewNavigation(): Promise<void> {
    if (!this.reviewNavigationFailed || this.cleanupInFlight || this.cleanupPending) return
    await this.continueToReview()
  }

  private async abandonCompletedImport(): Promise<void> {
    if (this.completedSessionId.length === 0 || this.cleanupInFlight ||
      this.navigationPending) return
    await this.cleanupAndReturn()
  }

  private returnToSetup(): void {
    if (this.completedSessionId.length > 0 || this.cleanupInFlight ||
      this.cleanupPending || this.navigationPending) return
    this.getUIContext().getRouter().back()
  }

  private async returnToImportPage(): Promise<void> {
    if (this.cleanupInFlight || this.request !== null || this.selectedPdfPath.length > 0) return
    this.returnNavigationPending = false
    try {
      const importOptions: router.RouterOptions = {
        url: 'pages/ImportBankPage'
      }
      await this.getUIContext().getRouter().replaceUrl(importOptions)
    } catch {
      this.returnNavigationPending = true
      this.errorMessage = '清理已完成，请返回导入页'
    }
  }

  private startWindowObserver(): void {
    if (this.sizeObserver !== undefined) return
    this.sizeObserver = new WindowSizeObserver((windowWidthVp: number): void => {
      this.applyWindowSizeClass(windowWidthVp)
    })
    this.sizeObserver.start(getContext(this))
  }

  private stopWindowObserver(): void {
    if (this.sizeObserver === undefined) return
    this.sizeObserver.stop()
    this.sizeObserver = undefined
  }

  private applyWindowSizeClass(windowWidthVp: number): void {
    const sizeClass: WindowSizeClass = ResponsiveLayout.classify(windowWidthVp)
    if (sizeClass !== this.windowSizeClass) this.windowSizeClass = sizeClass
  }

  private contentMaxWidth(): number {
    return this.windowSizeClass === WindowSizeClass.COMPACT ? UiStyle.CONTENT_WIDTH : CONTENT_MAX_WIDTH
  }

  private progressActionMaxWidth(): number {
    return this.windowSizeClass === WindowSizeClass.EXPANDED ? 360 : this.contentMaxWidth()
  }

  private completedPageSummary(): string {
    if (this.totalPages <= 0) return '等待任务初始化'
    return this.processedPages.toString() + ' / ' + this.totalPages.toString() + ' 页'
  }

  @Builder
  private MetricRow(label: string, value: string): void {
    Row({ space: 12 }) {
      Text(label)
        .layoutWeight(1)
        .fontSize(UiStyle.DETAIL_SIZE)
        .fontColor(this.colors().textSecondary)
      Text(value)
        .fontSize(UiStyle.DETAIL_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textPrimary)
    }
    .width('100%')
    .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.colors().inputBackground)
    .border({ width: 1, color: this.colors().divider })
    .borderRadius(UiStyle.CONTROL_RADIUS)
  }

  @Builder
  private MetricTile(label: string, value: string): void {
    Column({ space: 6 }) {
      Text(label)
        .width('100%')
        .fontSize(12)
        .fontColor(this.colors().textCaption)
      Text(value)
        .width('100%')
        .fontSize(UiStyle.BODY_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textPrimary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .constraintSize({ minHeight: 72 })
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(this.colors().inputBackground)
    .border({ width: 1, color: this.colors().divider })
    .borderRadius(UiStyle.CONTROL_RADIUS)
  }

  @Builder
  private ProgressOverview(): void {
    Column({ space: 18 }) {
      Row({ space: 12 }) {
        Column({ space: 6 }) {
          Text('识别进度')
            .width('100%')
            .fontSize(UiStyle.DETAIL_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(UiStyle.action(this.darkMode))
          Text(this.statusText)
            .width('100%')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().textPrimary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.running || this.navigationPending || this.cleanupInFlight) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(UiStyle.action(this.darkMode))
            .accessibilityText('正在处理')
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column({ space: 10 }) {
        Row({ space: 12 }) {
          Text('处理进度')
            .layoutWeight(1)
            .fontSize(UiStyle.DETAIL_SIZE)
            .fontColor(this.colors().textSecondary)
          Text(this.completedPageSummary())
            .fontSize(UiStyle.DETAIL_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().textPrimary)
        }
        .width('100%')

        Progress({
          value: this.processedPages,
          total: Math.max(this.totalPages, 1),
          type: ProgressType.Linear
        })
          .width('100%')
          .height(8)
          .color(UiStyle.action(this.darkMode))
          .backgroundColor(this.colors().inputBackground)
          .accessibilityText('已完成 ' + this.completedPageSummary())
      }
      .width('100%')

      if (this.windowSizeClass === WindowSizeClass.COMPACT) {
        Column({ space: 10 }) {
          this.MetricRow('当前处理', this.currentPage > 0 ?
            '第 ' + this.currentPage.toString() + ' 页' : '等待开始')
          this.MetricRow('已完成页数', this.processedPages.toString() + ' 页')
          this.MetricRow('已识别题目', this.questionCount.toString() + ' 题')
        }
        .width('100%')
      } else {
        Row({ space: 10 }) {
          this.MetricTile('当前处理', this.currentPage > 0 ?
            '第 ' + this.currentPage.toString() + ' 页' : '等待开始')
          this.MetricTile('已完成页数', this.processedPages.toString() + ' 页')
          this.MetricTile('已识别题目', this.questionCount.toString() + ' 题')
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: 1, color: this.colors().divider })
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  private RecognitionNote(): void {
    Text('识别按页串行进行；单页失败会保留在审核页，不会自动重试。')
      .width('100%')
      .fontSize(12)
      .fontColor(this.colors().textCaption)
      .textAlign(TextAlign.Center)
      .lineHeight(19)
  }

  @Builder
  private ContentArea(): void {
    List() {
      ListItem() {
        Column({ space: 16 }) {
          this.ProgressOverview()
          this.RecognitionNote()
        }
        .width('100%')
        .align(Alignment.Top)
        .padding({ top: 16, bottom: 16, left: PAGE_PADDING, right: PAGE_PADDING })
      }
    }
    .layoutWeight(1)
    .width('100%')
    .constraintSize({ maxWidth: this.contentMaxWidth() })
    .scrollBar(BarState.Off)
  }

  @Builder
  private StatusNotice(horizontalPadding: number): void {
    if (this.errorMessage.length > 0) {
      Text(this.errorMessage)
        .width('100%')
        .constraintSize({ maxWidth: this.contentMaxWidth(), minHeight: UiStyle.TOUCH_TARGET })
        .padding({ left: 16, right: 16, top: 13, bottom: 13 })
        .fontSize(BODY_FONT_SIZE)
        .fontColor(UiStyle.errorText(this.darkMode))
        .backgroundColor(this.colors().errorSoft)
        .border({ width: 1, color: UiStyle.errorText(this.darkMode) })
        .borderRadius(UiStyle.CONTROL_RADIUS)
        .accessibilityText('识别提示：' + this.errorMessage)
        .margin({ left: horizontalPadding, right: horizontalPadding, bottom: 10 })
    }
  }

  @Builder
  private PrimaryAction(label: string, accessibilityLabel: string, action: () => void): void {
    Button(label)
      .type(ButtonType.Normal)
      .width('100%')
      .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
      .fontSize(UiStyle.BODY_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor(UiStyle.onAction(this.darkMode))
      .backgroundColor(UiStyle.action(this.darkMode))
      .borderRadius(UiStyle.CONTROL_RADIUS)
      .accessibilityText(accessibilityLabel)
      .onClick(action)
  }

  @Builder
  private ProgressActions(horizontalPadding: number): void {
    Column({ space: 10 }) {
      if (this.cancellable) {
        Button(this.cancelled ? '正在取消…' : '取消识别')
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontSize(UiStyle.BODY_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiStyle.errorText(this.darkMode))
          .backgroundColor(this.colors().cardBackground)
          .border({ width: 1, color: UiStyle.errorText(this.darkMode) })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(!this.cancelled)
          .accessibilityText(this.cancelled ? '正在取消识别' : '取消 AI PDF 识别')
          .onClick(() => { this.cancelImport() })
      } else if (this.cleanupPending) {
        this.PrimaryAction('重试清理', '重试清理本次识别临时文件', (): void => {
          this.retryCleanup()
        })
      } else if (this.reviewNavigationFailed && this.completedSessionId.length > 0) {
        if (this.windowSizeClass === WindowSizeClass.COMPACT) {
          Column({ space: 10 }) {
            Button('放弃并清理')
              .type(ButtonType.Normal)
              .width('100%')
              .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
              .fontSize(UiStyle.BODY_SIZE)
              .fontWeight(FontWeight.Medium)
              .fontColor(UiStyle.errorText(this.darkMode))
              .backgroundColor(this.colors().cardBackground)
              .border({ width: 1, color: UiStyle.errorText(this.darkMode) })
              .borderRadius(UiStyle.CONTROL_RADIUS)
              .accessibilityText('放弃识别结果并清理临时文件')
              .onClick(() => { this.abandonCompletedImport() })
            this.PrimaryAction('重新进入审核', '重新进入题目识别复核页', (): void => {
              this.retryReviewNavigation()
            })
          }
          .width('100%')
        } else {
          Row({ space: 12 }) {
            Button('放弃并清理')
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
              .fontSize(UiStyle.BODY_SIZE)
              .fontWeight(FontWeight.Medium)
              .fontColor(UiStyle.errorText(this.darkMode))
              .backgroundColor(this.colors().cardBackground)
              .border({ width: 1, color: UiStyle.errorText(this.darkMode) })
              .borderRadius(UiStyle.CONTROL_RADIUS)
              .accessibilityText('放弃识别结果并清理临时文件')
              .onClick(() => { this.abandonCompletedImport() })
            Button('重新进入审核')
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
              .fontSize(UiStyle.BODY_SIZE)
              .fontWeight(FontWeight.Medium)
              .fontColor(UiStyle.onAction(this.darkMode))
              .backgroundColor(UiStyle.action(this.darkMode))
              .borderRadius(UiStyle.CONTROL_RADIUS)
              .accessibilityText('重新进入题目识别复核页')
              .onClick(() => { this.retryReviewNavigation() })
          }
          .width('100%')
        }
      } else if (this.returnNavigationPending) {
        this.PrimaryAction('返回导入页', '返回导入题库页', (): void => {
          this.returnToImportPage()
        })
      } else if (!this.running && !this.navigationPending && !this.cleanupInFlight &&
        this.errorMessage.length > 0) {
        this.PrimaryAction('返回重新设置', '返回 AI PDF 导入设置页', (): void => {
          this.returnToSetup()
        })
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: this.progressActionMaxWidth() })
    .alignItems(HorizontalAlign.Center)
    .padding({ left: horizontalPadding, right: horizontalPadding, bottom: 12 })
  }

  @Builder
  private ExpandedStage(): void {
    Column({ space: 16 }) {
      this.ProgressOverview()
      this.RecognitionNote()
      this.StatusNotice(0)
      this.ProgressActions(0)
    }
    .layoutWeight(1)
    .width('100%')
    .constraintSize({ maxWidth: this.contentMaxWidth() })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: PAGE_PADDING, bottom: PAGE_PADDING, left: PAGE_PADDING, right: PAGE_PADDING })
  }

  build() {
    Navigation() {
      Column() {
        if (this.windowSizeClass === WindowSizeClass.EXPANDED) {
          this.ExpandedStage()
        } else {
          this.ContentArea()
          this.StatusNotice(PAGE_PADDING)
          this.ProgressActions(PAGE_PADDING)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)
    }
    .title('AI PDF 识别', {
      barStyle: BarStyle.STANDARD
    })
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(false)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .padding({
      top: SafeAreaUtils.top(this.safeAreaInsets),
      bottom: SafeAreaUtils.bottom(this.safeAreaInsets),
      left: SafeAreaUtils.left(this.safeAreaInsets),
      right: SafeAreaUtils.right(this.safeAreaInsets)
    })
  }
}
