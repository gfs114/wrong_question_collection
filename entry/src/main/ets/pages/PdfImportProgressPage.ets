import { router } from '@kit.ArkUI'
import { AppHeader } from '../components/AppHeader'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  COLOR_CARD_BG,
  COLOR_DANGER,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE
} from '../constants/AppTheme'
import {
  PdfFileSelection,
  PdfImportProgress,
  PdfImportSettings
} from '../models/PdfImportModels'
import {
  PdfImportCancelledCleanupError,
  PdfImportCancelledError,
  PdfImportCleanupError,
  PdfImportCoordinator,
  PdfImportRunResult
} from '../services/PdfImportCoordinator'
import { PdfImportService } from '../services/PdfImportService'
import { QuestionImageService } from '../services/QuestionImageService'
import { PdfStorageError } from '../services/PdfStorageError'
import { PdfImportState } from '../utils/PdfImportState'

@Entry
@Component
struct PdfImportProgressPage {
  @State progressMessage: string = '正在准备识别'
  @State currentPage: number = 0
  @State totalPages: number = 0
  @State processedPageCount: number = 0
  @State questionCount: number = 0
  @State cancelDisabled: boolean = false
  @State errorMessage: string = ''
  @State running: boolean = false
  @State failed: boolean = false
  @State completed: boolean = false
  @State cleanupPending: boolean = false
  @State cleaning: boolean = false
  @State cancelled: boolean = false
  @State reviewNavigationPending: boolean = false
  private started: boolean = false
  private reviewNavigationCompleted: boolean = false
  private cleanupPaths: Array<string> = new Array<string>()
  private cleanupMode: string = ''
  private cleanupResolvedMessage: string = ''

  aboutToAppear(): void {
    if (this.started) {
      return
    }
    this.started = true
    this.runImport().catch((err: Error) => {
      this.handleRunEscape(err)
    })
  }

  onBackPress(): boolean {
    this.goBack()
    return true
  }

  private startRun(): void {
    if (this.started || this.running) {
      return
    }
    this.started = true
    this.runImport().catch((err: Error) => {
      this.handleRunEscape(err)
    })
  }

  private handleRunEscape(err: Error): void {
    this.running = false
    this.failed = true
    this.errorMessage = this.messageForError(err)
  }

  private async runImport(): Promise<void> {
    const state: PdfImportState = PdfImportState.shared()
    const selection: PdfFileSelection | null = state.getSelection()
    const settings: PdfImportSettings | null = state.getSettings()
    if (selection === null || settings === null) {
      this.running = false
      this.failed = true
      this.errorMessage = 'PDF 导入信息不完整，请返回重新选择'
      return
    }
    this.running = true
    this.failed = false
    this.completed = false
    this.cleanupPending = false
    this.cleanupPaths = new Array<string>()
    this.cleanupMode = ''
    this.cleanupResolvedMessage = ''
    this.cancelled = false
    this.cancelDisabled = false
    this.errorMessage = ''
    this.progressMessage = '正在准备识别'
    this.totalPages = settings.endPage - settings.startPage + 1
    try {
      const result: PdfImportRunResult = await PdfImportCoordinator.run(
        getContext(this), selection, settings,
        (progress: PdfImportProgress): void => {
          this.currentPage = progress.currentPage
          this.totalPages = progress.totalPages
          this.processedPageCount = progress.processedPageCount
          this.questionCount = progress.questionCount
          if (progress.stage === 'recognizing' && progress.currentPage > 0) {
            this.progressMessage = '正在识别第 ' + progress.currentPage.toString() + ' 页'
          } else {
            this.progressMessage = progress.message
          }
        },
        (): boolean => PdfImportState.shared().isCancelRequested())
      state.setDrafts(result.drafts)
      state.setFailures(result.failures)
      this.questionCount = result.drafts.length
      this.running = false
      this.cancelDisabled = true
      this.completed = true
      this.progressMessage = 'PDF 识别完成'
      this.navigateToReview()
    } catch (err) {
      this.running = false
      this.cancelDisabled = true
      if (err instanceof PdfImportCancelledCleanupError) {
        this.handleStructuredCleanupError(err, true)
        return
      }
      if (err instanceof PdfImportCleanupError) {
        this.handleStructuredCleanupError(err, false)
        return
      }
      if (err instanceof PdfImportCancelledError) {
        this.cancelled = true
        this.progressMessage = '识别已取消'
        this.cleaning = true
        try {
          await PdfImportService.removeTemporaryPdf(selection.uri)
        } catch {
          this.cleaning = false
          this.failed = true
          this.cleanupPending = true
          this.cleanupMode = 'cancelled-pdf'
          this.errorMessage = '识别已取消，但 PDF 临时文件清理失败，请重试清理'
          return
        }
        await this.navigateToImportBank()
        return
      }
      this.failed = true
      this.cleanupResolvedMessage = this.messageForError(err)
      this.errorMessage = this.cleanupResolvedMessage
      this.progressMessage = 'PDF 识别失败'
      this.cleaning = true
      try {
        await PdfImportService.removeTemporaryPdf(selection.uri)
      } catch {
        this.cleaning = false
        this.cleanupPending = true
        this.cleanupMode = 'fatal-pdf'
        this.errorMessage = this.cleanupResolvedMessage + '；PDF 临时文件清理失败，请重试清理'
        return
      }
      await this.navigateToImportBank()
    }
  }

  private cancelImport(): void {
    if (!this.running || this.cancelDisabled) {
      return
    }
    PdfImportState.shared().requestCancel()
    this.cancelDisabled = true
    this.progressMessage = '正在取消识别，请稍候…'
  }

  private retryImport(): void {
    if (this.running || this.cleaning || this.completed || this.cleanupPending) {
      return
    }
    PdfImportState.shared().clearCancelRequest()
    this.errorMessage = ''
    this.started = false
    this.running = false
    this.failed = false
    this.cancelled = false
    this.cancelDisabled = false
    this.startRun()
  }

  private retryCleanup(): void {
    if (this.running || this.cleaning || !this.cleanupPending) {
      return
    }
    this.cleaning = true
    this.errorMessage = ''
    this.finishCleanup().catch((err: Error) => {
      this.cleaning = false
      if (this.cleanupMode === 'fatal-images' || this.cleanupMode === 'cancelled-images') {
        this.errorMessage = '题图缓存清理失败，请释放存储空间后重试'
      } else {
        this.errorMessage = this.messageForCleanupError(err)
      }
    })
  }

  private async finishCleanup(): Promise<void> {
    const selection: PdfFileSelection | null = PdfImportState.shared().getSelection()
    if (selection === null) {
      this.cleaning = false
      this.errorMessage = 'PDF 临时文件信息已丢失，请返回导入页'
      return
    }
    if (this.cleanupMode === 'fatal-images' || this.cleanupMode === 'cancelled-images') {
      await QuestionImageService.deletePaths(getContext(this), this.cleanupPaths)
      this.cleanupPaths = new Array<string>()
      if (this.cleanupMode === 'fatal-images') {
        this.cleanupMode = 'fatal-pdf'
      } else {
        this.cleanupMode = 'cancelled-pdf'
      }
    }
    try {
      await PdfImportService.removeTemporaryPdf(selection.uri)
    } catch (err) {
      if (this.cancelled) {
        this.cleanupMode = 'cancelled-pdf'
      } else {
        this.cleanupMode = 'fatal-pdf'
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('PDF 临时文件清理失败')
    }
    this.cleanupPending = false
    this.cleaning = false
    if (this.cancelled) {
      await this.navigateToImportBank()
      return
    }
    await this.navigateToImportBank()
  }

  private handleStructuredCleanupError(
    err: PdfImportCleanupError | PdfImportCancelledCleanupError, cancelled: boolean): void {
    this.failed = true
    this.cancelled = cancelled
    this.cleanupPending = true
    this.cleanupPaths = err.paths.slice()
    this.cleanupMode = cancelled ? 'cancelled-images' : 'fatal-images'
    this.cleanupResolvedMessage = this.messageForErrorMessage(err.message)
    this.progressMessage = cancelled ? '识别已取消' : 'PDF 识别失败'
    this.errorMessage = this.cleanupResolvedMessage + '；题图清理失败，请重试或登记稍后清理'
  }

  private async abandonCleanupAndContinue(): Promise<void> {
    if (this.running || this.cleaning || !this.cleanupPending) {
      return
    }
    this.cleaning = true
    if (this.cleanupPaths.length > 0) {
      QuestionImageService.rememberCleanupDebt(this.cleanupPaths)
    }
    const selection: PdfFileSelection | null = PdfImportState.shared().getSelection()
    if (selection === null) {
      this.cleaning = false
      this.errorMessage = 'PDF 临时文件信息已丢失，无法登记稍后清理'
      return
    }
    try {
      PdfImportService.abandonTemporaryPdf(selection.uri)
    } catch {
      this.cleaning = false
      this.errorMessage = 'PDF 临时文件登记失败，请重试清理或再次稍后处理'
      return
    }
    await this.navigateToImportBank()
  }

  private continueReview(): void {
    if (!this.completed || this.cleanupPending || this.cleaning) {
      return
    }
    this.navigateToReview()
  }

  private async navigateToReview(): Promise<void> {
    if (this.reviewNavigationPending || this.reviewNavigationCompleted) {
      return
    }
    this.reviewNavigationPending = true
    this.errorMessage = ''
    const options: router.RouterOptions = {
      url: 'pages/PdfImportReviewPage'
    }
    try {
      await this.getUIContext().getRouter().replaceUrl(options)
      this.reviewNavigationCompleted = true
    } catch {
      this.errorMessage = '审核页面暂不可用，请稍后重试'
      this.reviewNavigationPending = false
    }
  }

  private goBack(): void {
    if (this.running) {
      this.cancelImport()
      return
    }
    if (this.completed) {
      if (this.cleanupPending) {
        this.retryCleanup()
      } else {
        this.continueReview()
      }
      return
    }
    this.leaveImport()
  }

  private async leaveImport(): Promise<void> {
    if (this.running || this.cleaning) {
      return
    }
    this.cleaning = true
    this.errorMessage = ''
    const selection: PdfFileSelection | null = PdfImportState.shared().getSelection()
    try {
      if (selection !== null) {
        await PdfImportService.removeTemporaryPdf(selection.uri)
      }
    } catch {
      this.cleanupPending = true
      this.cleanupMode = 'fatal-pdf'
      this.errorMessage = 'PDF 临时文件清理失败，请重试，或稍后清理并返回'
      this.cleaning = false
      return
    }
    await this.navigateToImportBank()
  }

  private async navigateToImportBank(): Promise<void> {
    const options: router.RouterOptions = {
      url: 'pages/ImportBankPage'
    }
    try {
      await this.getUIContext().getRouter().replaceUrl(options)
      PdfImportState.shared().reset()
    } catch {
      this.failed = true
      this.errorMessage = '导入页面暂不可用，PDF 导入信息仍已保留'
    } finally {
      this.cleaning = false
    }
  }

  private messageForCleanupError(err: Error): string {
    if (err instanceof Error && err.message.length > 0) {
      return 'PDF 临时文件清理失败，请释放存储空间后重试'
    }
    return 'PDF 临时文件清理失败，请重试'
  }

  private messageForError(err: Error): string {
    if (err instanceof PdfStorageError) {
      return '本地空间不足或图片保存失败'
    }
    return this.messageForErrorMessage(err.message)
  }

  private messageForErrorMessage(message: string): string {
    if ((message.includes('OCR') || message.includes('文字识别') || message.includes('textRecognition')) &&
      (message.includes('不支持') || message.includes('初始化') || message.includes('能力'))) {
      return '当前设备不支持端侧文字识别，请使用鸿蒙真机重试'
    }
    if (message.includes('加密')) {
      return '暂不支持加密 PDF'
    }
    if (message.includes('解析') || message.includes('损坏') || message.includes('页数与选择时不一致')) {
      return 'PDF 文件损坏或格式不受支持'
    }
    if (message.includes('所选页面均识别失败')) {
      return '部分页面识别失败，请检查标记页'
    }
    if (message.includes('页面识别失败')) {
      return '部分页面识别失败，请检查标记页'
    }
    if (message.startsWith('本地空间不足或图片保存失败')) {
      return '本地空间不足或图片保存失败'
    }
    return 'PDF 导入失败，请重新选择文件'
  }

  build() {
    Column() {
      AppHeader({
        title: 'PDF 识别',
        showBack: true,
        onBack: () => {
          this.goBack()
        }
      })

      Column({ space: 18 }) {
        Column({ space: 16 }) {
          if (this.running) {
            LoadingProgress()
              .width(52)
              .height(52)
              .color(COLOR_PRIMARY)
          } else {
            Text(this.completed ? '✓' : this.failed ? '!' : '…')
              .width(52)
              .height(52)
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.failed ? COLOR_DANGER : COLOR_PRIMARY)
              .textAlign(TextAlign.Center)
              .backgroundColor(COLOR_PAGE_BG)
              .borderRadius(26)
          }

          Text(this.progressMessage)
            .width('100%')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_TEXT_PRIMARY)
            .textAlign(TextAlign.Center)

          Text('已处理 ' + this.processedPageCount.toString() + ' / ' + this.totalPages.toString() + ' 页')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(COLOR_TEXT_CAPTION)

          if (this.currentPage > 0) {
            Text('当前第 ' + this.currentPage.toString() + ' 页 · 已识别 ' +
              this.questionCount.toString() + ' 道题')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(COLOR_TEXT_CAPTION)
          }
        }
        .width('100%')
        .padding(24)
        .backgroundColor(COLOR_CARD_BG)
        .borderRadius(CARD_RADIUS)

        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .width('100%')
            .padding(16)
            .fontSize(BODY_FONT_SIZE)
            .fontColor(COLOR_DANGER)
            .lineHeight(22)
            .backgroundColor('#FFF2F2')
            .borderRadius(14)
        }

        if (this.running) {
          Button(this.cancelDisabled ? '正在取消…' : '取消识别')
            .type(ButtonType.Normal)
            .width('100%')
            .height(50)
            .fontSize(SUBTITLE_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_DANGER)
            .backgroundColor(COLOR_CARD_BG)
            .border({ width: 1, color: COLOR_DANGER })
            .borderRadius(15)
            .enabled(!this.cancelDisabled)
            .onClick(() => {
              this.cancelImport()
            })
        } else if (this.cleanupPending) {
          Column({ space: 12 }) {
            Button(this.cleaning ? '正在清理…' : '重试清理')
              .type(ButtonType.Normal)
              .width('100%')
              .height(50)
              .fontSize(SUBTITLE_FONT_SIZE)
              .fontColor('#FFFFFF')
              .backgroundColor(COLOR_PRIMARY)
              .borderRadius(15)
              .enabled(!this.cleaning)
              .onClick(() => {
                this.retryCleanup()
              })

            Button(this.completed ? '稍后清理并继续审核' : '稍后清理并返回')
              .type(ButtonType.Normal)
              .width('100%')
              .height(50)
              .fontSize(SUBTITLE_FONT_SIZE)
              .fontColor(COLOR_PRIMARY)
              .backgroundColor(COLOR_CARD_BG)
              .border({ width: 1, color: COLOR_PRIMARY })
              .borderRadius(15)
              .enabled(!this.cleaning)
              .onClick(() => {
                this.abandonCleanupAndContinue()
              })
          }
          .width('100%')
        } else if (this.completed) {
          Button(this.reviewNavigationPending ? '正在进入审核…' : '继续审核')
            .type(ButtonType.Normal)
            .width('100%')
            .height(50)
            .fontSize(SUBTITLE_FONT_SIZE)
            .fontColor('#FFFFFF')
            .backgroundColor(COLOR_PRIMARY)
            .borderRadius(15)
            .enabled(!this.reviewNavigationPending && !this.cleaning)
            .onClick(() => {
              this.continueReview()
            })
        } else if (this.cancelled) {
          Button('返回导入页')
            .type(ButtonType.Normal)
            .width('100%')
            .height(50)
            .fontSize(SUBTITLE_FONT_SIZE)
            .fontColor('#FFFFFF')
            .backgroundColor(COLOR_PRIMARY)
            .borderRadius(15)
            .onClick(() => {
              this.leaveImport()
            })
        } else if (this.failed) {
          Row({ space: 12 }) {
            Button('返回')
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .height(50)
              .fontColor(COLOR_TEXT_PRIMARY)
              .backgroundColor(COLOR_CARD_BG)
              .borderRadius(15)
              .onClick(() => {
                this.leaveImport()
              })

            Button('重试识别')
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .height(50)
              .fontColor('#FFFFFF')
              .backgroundColor(COLOR_PRIMARY)
              .borderRadius(15)
              .onClick(() => {
                this.retryImport()
              })
          }
          .width('100%')
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: PAGE_PADDING })
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_PAGE_BG)
  }
}
