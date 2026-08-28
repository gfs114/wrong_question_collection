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
import { ImportErrorCode, ImportResult } from '../models/ImportResult'
import { PdfFileSelection, PdfQuestionDraft } from '../models/PdfImportModels'
import { ImportService } from '../services/ImportService'
import { PdfImportService } from '../services/PdfImportService'
import { QuestionImageService } from '../services/QuestionImageService'
import { PdfStorageError } from '../services/PdfStorageError'
import { PdfImportState } from '../utils/PdfImportState'

@Entry
@Component
struct ImportBankPage {
  @State importing: boolean = false
  @State pdfSelecting: boolean = false
  @State errorMessage: string = ''
  @State cleanupWarning: string = ''

  aboutToAppear(): void {
    this.retryImageCleanup()
  }

  private goBack(): void {
    if (this.importing || this.pdfSelecting) {
      return
    }
    try {
      this.getUIContext().getRouter().back()
    } catch {
    }
  }

  onBackPress(): boolean {
    this.goBack()
    return true
  }

  private startImport(): void {
    if (this.importing || this.pdfSelecting) {
      return
    }
    this.importing = true
    this.errorMessage = ''
    this.importBank()
  }

  private async importBank(): Promise<void> {
    let result: ImportResult
    try {
      result = await ImportService.selectAndImport(getContext(this))
    } catch {
      this.errorMessage = '导入失败，请稍后重试'
      this.importing = false
      return
    }
    this.importing = false
    if (result.cancelled) {
      return
    }
    if (result.success) {
      this.showToast('题库导入成功')
      this.goBack()
      return
    }
    this.errorMessage = this.messageFor(result.errorCode.code)
  }

  private messageFor(errorCode: string): string {
    if (errorCode === ImportErrorCode.FORMAT_ERROR) {
      return '题库格式错误，请检查 JSON 文件'
    }
    if (errorCode === ImportErrorCode.READ_ERROR) {
      return '文件读取失败，请重新选择'
    }
    if (errorCode === ImportErrorCode.SAVE_ERROR) {
      return '题库保存失败，请稍后重试'
    }
    return '导入失败，请稍后重试'
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  private async selectPdf(): Promise<void> {
    if (this.importing || this.pdfSelecting) {
      return
    }
    this.pdfSelecting = true
    this.errorMessage = ''
    let selection: PdfFileSelection | null = null
    let selectionStored: boolean = false
    try {
      try {
        await QuestionImageService.retryCleanupDebt(getContext(this), this.activeDraftImagePaths())
        this.cleanupWarning = ''
      } catch {
        this.cleanupWarning = '部分遗留题图清理仍待处理'
      }
      selection = await PdfImportService.selectPdf(getContext(this))
      if (selection === null) {
        return
      }
      const state: PdfImportState = PdfImportState.shared()
      const previousSelection: PdfFileSelection | null = state.getSelection()
      if (previousSelection !== null && previousSelection.uri !== selection.uri) {
        await PdfImportService.removeTemporaryPdf(previousSelection.uri)
      }
      PdfImportState.shared().reset()
      PdfImportState.shared().setSelection(selection)
      selectionStored = true
      const options: router.RouterOptions = {
        url: 'pages/PdfImportSetupPage'
      }
      await this.getUIContext().getRouter().pushUrl(options)
    } catch (err) {
      this.errorMessage = this.messageForPdfError(err)
      let selectedPdfRemoved: boolean = true
      if (selection !== null) {
        try {
          await PdfImportService.removeTemporaryPdf(selection.uri)
        } catch {
          selectedPdfRemoved = false
          this.errorMessage = this.errorMessage + '；PDF 临时文件清理失败，请重试'
        }
      }
      if (selectionStored && selectedPdfRemoved) {
        PdfImportState.shared().reset()
      }
    } finally {
      this.pdfSelecting = false
    }
  }

  private retryImageCleanup(): void {
    QuestionImageService.retryCleanupDebt(getContext(this), this.activeDraftImagePaths()).then(() => {
      this.cleanupWarning = ''
    }).catch(() => {
      this.cleanupWarning = '部分遗留题图清理仍待处理'
    })
  }

  private activeDraftImagePaths(): Array<string> {
    const drafts: Array<PdfQuestionDraft> = PdfImportState.shared().getDrafts()
    const paths: Array<string> = new Array<string>()
    for (let draftIndex: number = 0; draftIndex < drafts.length; draftIndex++) {
      const draft: PdfQuestionDraft = drafts[draftIndex]
      for (let pathIndex: number = 0; pathIndex < draft.imagePaths.length; pathIndex++) {
        const path: string = draft.imagePaths[pathIndex]
        if (paths.indexOf(path) < 0) {
          paths.push(path)
        }
      }
    }
    return paths
  }

  private messageForPdfError(err: Error): string {
    if (err instanceof PdfStorageError) {
      return '本地空间不足或图片保存失败'
    }
    let message: string = ''
    if (err instanceof Error) {
      message = err.message
    }
    if (message.includes('已有 PDF 选择任务')) {
      return '正在选择 PDF，请稍候'
    }
    if (message.includes('加密')) {
      return '暂不支持加密 PDF'
    }
    if (message.includes('解析') || message.includes('页面') || message.includes('损坏')) {
      return 'PDF 文件损坏或格式不受支持'
    }
    if (message.includes('大小') || message.includes('超过限制')) {
      return 'PDF 文件不能超过 200 MB'
    }
    if (message.includes('选择') || message.includes('picker')) {
      return 'PDF 导入失败，请重新选择文件'
    }
    return 'PDF 导入失败，请重新选择文件'
  }

  build() {
    Column() {
      AppHeader({
        title: '导入题库',
        showBack: true,
        onBack: () => {
          this.goBack()
        }
      })

      Scroll() {
        Column({ space: 18 }) {
          Column({ space: 14 }) {
            Row() {
              Text('JSON 格式说明')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_TEXT_PRIMARY)

              Blank()

              Text('仅支持单选题')
                .fontSize(12)
                .fontColor(COLOR_PRIMARY)
            }
            .width('100%')

            Text('文件需要包含题库名称 bankName、学科 subject 和题目数组 questions。每道题需包含 id、type、question、options、answer 与 analysis。')
              .width('100%')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(COLOR_TEXT_CAPTION)
              .lineHeight(22)

            Text('type 请填写 single_choice，answer 使用与选项对应的字母。文件编码需为 UTF-8。')
              .width('100%')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(COLOR_TEXT_CAPTION)
              .lineHeight(22)
          }
          .width('100%')
          .padding(20)
          .backgroundColor(COLOR_CARD_BG)
          .borderRadius(CARD_RADIUS)

          if (this.importing) {
            Row({ space: 12 }) {
              LoadingProgress()
                .width(24)
                .height(24)
                .color(COLOR_PRIMARY)

              Text('正在读取并导入题库…')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_TEXT_CAPTION)
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(COLOR_CARD_BG)
            .borderRadius(16)
          }

          if (this.errorMessage.length > 0) {
            Text(this.errorMessage)
              .width('100%')
              .constraintSize({ minHeight: 48 })
              .padding({ left: 16, right: 16, top: 13, bottom: 13 })
              .fontSize(BODY_FONT_SIZE)
              .fontColor(COLOR_DANGER)
              .backgroundColor('#FFF2F2')
              .borderRadius(14)
              .accessibilityText('导入失败：' + this.errorMessage)
          }

          if (this.cleanupWarning.length > 0) {
            Text(this.cleanupWarning)
              .width('100%')
              .constraintSize({ minHeight: 44 })
              .padding({ left: 16, right: 16, top: 11, bottom: 11 })
              .fontSize(BODY_FONT_SIZE)
              .fontColor(COLOR_TEXT_CAPTION)
              .backgroundColor('#FFF8E8')
              .borderRadius(14)
              .accessibilityText('清理提醒：' + this.cleanupWarning)
          }

          Button() {
            Text(this.importing ? '正在导入…' : '选择 JSON 文件')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
          }
          .type(ButtonType.Normal)
          .width('100%')
          .height(52)
          .backgroundColor(COLOR_PRIMARY)
          .borderRadius(16)
          .enabled(!this.importing && !this.pdfSelecting)
          .accessibilityText(this.importing ? '正在导入题库' : '选择 JSON 文件')
          .onClick(() => {
            this.startImport()
          })

          Button() {
            Text(this.pdfSelecting ? '正在选择…' : '导入 PDF')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_PRIMARY)
          }
          .type(ButtonType.Normal)
          .width('100%')
          .height(52)
          .backgroundColor(COLOR_CARD_BG)
          .border({ width: 1, color: COLOR_PRIMARY })
          .borderRadius(16)
          .enabled(!this.pdfSelecting && !this.importing)
          .accessibilityText(this.pdfSelecting ? '正在选择 PDF' : '导入 PDF')
          .onClick(() => {
            this.selectPdf()
          })
        }
        .width('100%')
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: PAGE_PADDING })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_PAGE_BG)
  }
}
