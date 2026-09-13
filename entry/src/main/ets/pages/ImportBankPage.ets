import { Context } from '@kit.AbilityKit'
import {
  BODY_FONT_SIZE,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { SHEET_RADIUS } from '../constants/EditorialStyle'
import { UiStyle } from '../constants/UiStyle'
import { ImportErrorCode, ImportResult } from '../models/ImportResult'
import { AccountSessionState } from '../models/AccountSession'
import { PdfFileSelection } from '../models/PdfImportModels'
import { AccountSessionService } from '../services/AccountSessionService'
import { ImportService } from '../services/ImportService'
import { PdfImportService } from '../services/PdfImportService'
import { AppColors } from '../theme/AppColors'
import { PdfImportState } from '../utils/PdfImportState'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

const JSON_BANK_EXAMPLE: string = `{
  "bankName": "数学错题示例",
  "subject": "数学",
  "questions": [
    {
      "id": "q-001",
      "type": "single_choice",
      "question": "2 + 3 = ?",
      "options": ["A. 4", "B. 5", "C. 6"],
      "answer": "B",
      "analysis": "2 + 3 = 5。"
    }
  ]
}`

@Entry
@Component
struct ImportBankPage {
  @State importing: boolean = false
  @State pdfSelecting: boolean = false
  @State errorMessage: string = ''
  @State jsonHelpExpanded: boolean = false
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = {
    top: 0, left: 0, right: 0, bottom: 0
  }
  @StorageProp('darkMode') darkMode: boolean = false

  private colors(): AppColors {
    return themePalette(this.darkMode)
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
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      this.showToast('暂时无法获取应用上下文')
      return
    }
    AccountSessionService.state(hostContext)
      .then((session: AccountSessionState) => {
        if (!session.signedIn) {
          this.showToast('请先登录华为账号')
          return
        }
        this.importing = true
        this.errorMessage = ''
        this.importBank()
      })
      .catch(() => {
        this.showToast('导入失败，请稍后重试')
      })
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
    if (this.importing || this.pdfSelecting) return
    this.pdfSelecting = true
    this.errorMessage = ''
    try {
      const context: Context = getContext(this)
      const selection: PdfFileSelection | null = await PdfImportService.selectPdf(context)
      if (selection === null) return
      const state: PdfImportState = PdfImportState.shared()
      const previous: PdfFileSelection | null = state.getSelection()
      if (previous !== null && previous.uri !== selection.uri) {
        try {
          await PdfImportService.removeTemporaryPdf(previous.uri)
        } catch {
          const removed: boolean = await this.releaseUnpublishedSelection(selection)
          this.errorMessage = removed ? '上一次 PDF 临时文件清理失败，请重试' :
            '上一次 PDF 临时文件清理失败；新文件已登记稍后清理'
          return
        }
      }
      state.reset()
      state.setSelection(selection)
      try {
        await this.getUIContext().getRouter().pushUrl({ url: 'pages/PdfAiImportSetupPage' })
      } catch {
        state.reset()
        const removed: boolean = await this.releaseUnpublishedSelection(selection)
        this.errorMessage = removed ? 'AI PDF 导入设置页面暂不可用，请重试' :
          'AI PDF 导入设置页面暂不可用；临时文件已登记稍后清理'
      }
    } catch (err) {
      this.errorMessage = this.messageForPdfError(err)
    } finally {
      this.pdfSelecting = false
    }
  }

  private async releaseUnpublishedSelection(selection: PdfFileSelection): Promise<boolean> {
    return await PdfImportService.removeOrAbandonTemporaryPdf(selection.uri)
  }

  private messageForPdfError(err: Error): string {
    let message: string = ''
    if (err instanceof Error) {
      message = err.message
    }
    if (message.includes('已有 PDF 选择任务')) {
      return '正在选择 PDF，请稍候'
    }
    if (message.includes('大小') || message.includes('超过限制')) {
      return 'PDF 文件不能超过 200 MB'
    }
    if (message.includes('暂存') || message.includes('空间')) {
      return 'PDF 暂存失败，请检查本地空间'
    }
    if (message.includes('选择') || message.includes('picker')) {
      return 'PDF 导入失败，请重新选择文件'
    }
    return 'PDF 导入失败，请重新选择文件'
  }

  build() {
    Navigation() {
      Column() {
        Scroll() {
          Column({ space: UiStyle.GROUP_GAP }) {
            Column({ space: 8 }) {
              Text('选择资料来源')
                .width('100%')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().textPrimary)

              Text('PDF 和结构化 JSON 题库均可导入')
                .width('100%')
                .fontSize(UiStyle.DETAIL_SIZE)
                .fontColor(this.colors().textCaption)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: 12 }) {
              Row() {
                Text('PDF 资料')
                  .fontSize(SUBTITLE_FONT_SIZE)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.colors().textPrimary)

                Blank()

                Text('推荐')
                  .fontSize(12)
                  .fontColor(UiStyle.action(this.darkMode))
              }
              .width('100%')

              Text('选择文件后设置页码，再进行 AI 识别；识别完成后逐题审核并保存。')
                .width('100%')
                .fontSize(UiStyle.DETAIL_SIZE)
                .fontColor(this.colors().textCaption)
                .lineHeight(22)

              Button() {
                Text(this.pdfSelecting ? '正在选择…' : '导入 PDF')
                  .fontSize(UiStyle.BODY_SIZE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(UiStyle.onAction(this.darkMode))
              }
              .type(ButtonType.Normal)
              .width('100%')
              .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
              .backgroundColor(UiStyle.action(this.darkMode))
              .borderRadius(UiStyle.CONTROL_RADIUS)
              .enabled(!this.pdfSelecting && !this.importing)
              .accessibilityText(this.pdfSelecting ? '正在选择 PDF' : '导入 PDF')
              .onClick(() => {
                this.selectPdf()
              })
            }
            .width('100%')
            .padding(20)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(this.colors().cardBackground)
            .border({ width: 1, color: this.colors().divider })
            .borderRadius(SHEET_RADIUS)

            if (this.importing) {
              Row({ space: 12 }) {
                LoadingProgress()
                  .width(24)
                  .height(24)
                  .color(UiStyle.action(this.darkMode))

                Text('正在读取并导入题库…')
                  .fontSize(BODY_FONT_SIZE)
                  .fontColor(this.colors().textCaption)
              }
              .width('100%')
              .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
              .padding({ left: 16, right: 16 })
              .justifyContent(FlexAlign.Center)
              .backgroundColor(this.colors().cardBackground)
              .borderRadius(UiStyle.CONTROL_RADIUS)
            }

            if (this.errorMessage.length > 0) {
              Text(this.errorMessage)
                .width('100%')
                .constraintSize({ minHeight: 48 })
                .padding({ left: 16, right: 16, top: 13, bottom: 13 })
                .fontSize(BODY_FONT_SIZE)
                .fontColor(UiStyle.errorText(this.darkMode))
                .backgroundColor(this.colors().errorSoft)
                .borderRadius(UiStyle.CONTROL_RADIUS)
                .accessibilityText('导入失败：' + this.errorMessage)
            }

            Column({ space: 12 }) {
              Row() {
                Text('已有结构化题库')
                  .fontSize(SUBTITLE_FONT_SIZE)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.colors().textPrimary)

                Blank()

                Text('仅支持单选题')
                  .fontSize(12)
                  .fontColor(UiStyle.action(this.darkMode))
              }
              .width('100%')

              Text('选择 JSON 文件可直接导入已有题库。')
                .width('100%')
                .fontSize(UiStyle.DETAIL_SIZE)
                .fontColor(this.colors().textCaption)

              Button() {
                Text(this.importing ? '正在导入…' : '选择 JSON 文件')
                  .fontSize(UiStyle.BODY_SIZE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(UiStyle.action(this.darkMode))
              }
              .type(ButtonType.Normal)
              .width('100%')
              .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
              .backgroundColor(this.colors().cardBackground)
              .border({ width: 1, color: UiStyle.action(this.darkMode) })
              .borderRadius(UiStyle.CONTROL_RADIUS)
              .enabled(!this.importing && !this.pdfSelecting)
              .accessibilityText(this.importing ? '正在导入题库' : '选择 JSON 文件')
              .onClick(() => {
                this.startImport()
              })

              Button() {
                Row({ space: 12 }) {
                  Text('JSON 格式与示例')
                    .fontSize(UiStyle.DETAIL_SIZE)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.colors().textPrimary)

                  Blank()

                  Text(this.jsonHelpExpanded ? '收起' : '展开')
                    .fontSize(UiStyle.DETAIL_SIZE)
                    .fontColor(UiStyle.action(this.darkMode))
                }
                .width('100%')
              }
              .type(ButtonType.Normal)
              .width('100%')
              .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
              .padding({ left: 14, right: 14 })
              .backgroundColor(this.colors().inputBackground)
              .borderRadius(UiStyle.CONTROL_RADIUS)
              .accessibilityText(this.jsonHelpExpanded ?
                '收起 JSON 格式与示例' : '展开 JSON 格式与示例')
              .onClick(() => {
                this.jsonHelpExpanded = !this.jsonHelpExpanded
              })

              if (this.jsonHelpExpanded) {
                Divider()
                  .color(this.colors().divider)

                Text('JSON 格式说明')
                  .fontSize(UiStyle.DETAIL_SIZE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.colors().textPrimary)

                Text('文件需要包含题库名称 bankName、学科 subject 和题目数组 questions。每道题需包含 id、type、question、options、answer 与 analysis。')
                  .width('100%')
                  .fontSize(UiStyle.DETAIL_SIZE)
                  .fontColor(this.colors().textCaption)
                  .lineHeight(22)

                Text('type 请填写 single_choice，answer 使用与选项对应的字母。文件编码需为 UTF-8。')
                  .width('100%')
                  .fontSize(UiStyle.DETAIL_SIZE)
                  .fontColor(this.colors().textCaption)
                  .lineHeight(22)

                Divider()
                  .color(this.colors().divider)

                Text('JSON 示例')
                  .fontSize(UiStyle.DETAIL_SIZE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.colors().textPrimary)

                Text('以下内容可直接保存为 UTF-8 编码的 .json 文件后导入。')
                  .width('100%')
                  .fontSize(UiStyle.DETAIL_SIZE)
                  .fontColor(this.colors().textCaption)
                  .lineHeight(22)

                Text(JSON_BANK_EXAMPLE)
                  .width('100%')
                  .padding(16)
                  .fontSize(13)
                  .fontFamily('monospace')
                  .fontColor(this.colors().textSecondary)
                  .lineHeight(20)
                  .backgroundColor(this.colors().inputBackground)
                  .borderRadius(UiStyle.CONTROL_RADIUS)
                  .accessibilityText('JSON 题库示例：' + JSON_BANK_EXAMPLE)
              }
            }
            .width('100%')
            .padding(20)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(this.colors().cardBackground)
            .border({ width: 1, color: this.colors().divider })
            .borderRadius(SHEET_RADIUS)
          }
          .width('100%')
          .align(Alignment.Top)
          .padding({
            top: PAGE_PADDING,
            left: PAGE_PADDING,
            right: PAGE_PADDING,
            bottom: PAGE_PADDING + SafeAreaUtils.bottom(this.safeAreaInsets)
          })
        }
        .layoutWeight(1)
        .width('100%')
        .constraintSize({ maxWidth: UiStyle.CONTENT_WIDTH })
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)
    }
    .title('导入题库', {
      barStyle: BarStyle.STANDARD
    })
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(false)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .padding({
      top: SafeAreaUtils.top(this.safeAreaInsets),
      left: SafeAreaUtils.left(this.safeAreaInsets),
      right: SafeAreaUtils.right(this.safeAreaInsets)
    })
  }
}
