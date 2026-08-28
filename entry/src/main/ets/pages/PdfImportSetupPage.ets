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
  PdfImportSettings,
  PdfPageRangeValidation
} from '../models/PdfImportModels'
import { PdfImportService } from '../services/PdfImportService'
import { PdfImportState } from '../utils/PdfImportState'
import { PdfImportValidator } from '../utils/PdfImportValidator'

@Entry
@Component
struct PdfImportSetupPage {
  @State bankName: string = ''
  @State subject: string = ''
  @State startPageText: string = ''
  @State endPageText: string = ''
  @State errorMessage: string = ''
  @State fileName: string = ''
  @State pageCount: number = 0
  @State customSubject: boolean = false
  @State selectionReady: boolean = false
  @State navigating: boolean = false
  @State cleaning: boolean = false
  @State cleanupPending: boolean = false
  private subjects: Array<string> = ['数学', '语文', '英语', '物理', '化学', '其他']

  aboutToAppear(): void {
    const selection: PdfFileSelection | null = PdfImportState.shared().getSelection()
    if (selection === null) {
      this.selectionReady = false
      this.errorMessage = '未找到已选择的 PDF，请返回重新选择'
      return
    }
    this.fileName = selection.fileName
    this.pageCount = Number.isFinite(selection.pageCount) && Number.isSafeInteger(selection.pageCount) &&
      selection.pageCount > 0 ? selection.pageCount : 0
    this.bankName = PdfImportValidator.bankNameFromFileName(selection.fileName)
    this.startPageText = selection.startPage.toString()
    this.endPageText = selection.endPage.toString()
    this.selectionReady = true
    this.errorMessage = ''
  }

  onBackPress(): boolean {
    this.leaveImport()
    return true
  }

  private selectSubject(value: string): void {
    if (this.navigating || this.cleaning || this.cleanupPending) {
      return
    }
    this.customSubject = value === '其他'
    this.subject = this.customSubject ? '' : value
    this.errorMessage = ''
  }

  private isSubjectSelected(value: string): boolean {
    if (value === '其他') {
      return this.customSubject
    }
    return !this.customSubject && this.subject === value
  }

  private isPositiveIntegerText(value: string): boolean {
    if (value.length === 0) {
      return false
    }
    for (let index: number = 0; index < value.length; index++) {
      const code: number = value.charCodeAt(index)
      if (code < 48 || code > 57) {
        return false
      }
    }
    return true
  }

  private selectedPageCount(): number {
    if (!this.isPositiveIntegerText(this.startPageText) ||
      !this.isPositiveIntegerText(this.endPageText)) {
      return 0
    }
    const startPage: number = Number.parseInt(this.startPageText, 10)
    const endPage: number = Number.parseInt(this.endPageText, 10)
    if (!Number.isFinite(startPage) || !Number.isFinite(endPage) ||
      !Number.isSafeInteger(startPage) || !Number.isSafeInteger(endPage) || endPage < startPage) {
      return 0
    }
    const selectedCount: number = endPage - startPage + 1
    return Number.isSafeInteger(selectedCount) && selectedCount > 0 ? selectedCount : 0
  }

  private startRecognition(): void {
    if (this.navigating || this.cleaning || this.cleanupPending) {
      return
    }
    const state: PdfImportState = PdfImportState.shared()
    const selection: PdfFileSelection | null = state.getSelection()
    if (selection === null) {
      this.errorMessage = '未找到已选择的 PDF，请返回重新选择'
      return
    }
    const trimmedBankName: string = this.bankName.trim()
    const trimmedSubject: string = this.subject.trim()
    if (trimmedBankName.length === 0) {
      this.errorMessage = '请填写题库名'
      return
    }
    if (trimmedSubject.length === 0) {
      this.errorMessage = '请选择或填写科目'
      return
    }
    if (!this.isPositiveIntegerText(this.startPageText) ||
      !this.isPositiveIntegerText(this.endPageText)) {
      this.errorMessage = '页码必须是从 1 开始的正整数'
      return
    }
    const startPage: number = Number.parseInt(this.startPageText, 10)
    const endPage: number = Number.parseInt(this.endPageText, 10)
    const validation: PdfPageRangeValidation = PdfImportValidator.validatePageRange(
      startPage, endPage, selection.pageCount)
    if (!validation.valid) {
      this.errorMessage = validation.message
      return
    }
    const settings: PdfImportSettings = new PdfImportSettings(
      trimmedBankName, trimmedSubject, startPage, endPage)
    state.setSettings(settings)
    state.clearCancelRequest()
    this.errorMessage = ''
    this.navigating = true
    const options: router.RouterOptions = {
      url: 'pages/PdfImportProgressPage'
    }
    this.getUIContext().getRouter().pushUrl(options).catch(() => {
      this.errorMessage = '识别页面暂不可用，请稍后重试'
    }).finally(() => {
      this.navigating = false
    })
  }

  private async leaveImport(): Promise<void> {
    if (this.navigating || this.cleaning) {
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
      this.errorMessage = 'PDF 临时文件清理失败，请重试，或稍后清理并返回'
      this.cleaning = false
      return
    }
    this.cleanupPending = false
    await this.navigateBack()
  }

  private async abandonAndLeave(): Promise<void> {
    if (this.navigating || this.cleaning || !this.cleanupPending) {
      return
    }
    this.cleaning = true
    const selection: PdfFileSelection | null = PdfImportState.shared().getSelection()
    if (selection !== null) {
      PdfImportService.abandonTemporaryPdf(selection.uri)
    }
    await this.navigateBack()
  }

  private async navigateBack(): Promise<void> {
    try {
      this.getUIContext().getRouter().back()
      PdfImportState.shared().reset()
    } catch {
      this.errorMessage = '导入页面暂不可用，PDF 导入信息仍已保留'
    } finally {
      this.cleaning = false
    }
  }

  build() {
    Column() {
      AppHeader({
        title: 'PDF 导入设置',
        showBack: true,
        onBack: () => {
          this.leaveImport()
        }
      })

      if (!this.selectionReady) {
        Column({ space: 18 }) {
          Text(this.errorMessage)
            .fontSize(BODY_FONT_SIZE)
            .fontColor(COLOR_DANGER)
            .textAlign(TextAlign.Center)

          Button('返回导入')
            .type(ButtonType.Normal)
            .height(48)
            .backgroundColor(COLOR_PRIMARY)
            .fontColor('#FFFFFF')
            .borderRadius(14)
            .onClick(() => {
              this.leaveImport()
            })
        }
        .layoutWeight(1)
        .width('100%')
        .padding(PAGE_PADDING)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 16 }) {
            Column({ space: 8 }) {
              Text(this.fileName)
                .width('100%')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_TEXT_PRIMARY)
                .maxLines(2)

              Text('共 ' + this.pageCount.toString() + ' 页')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_TEXT_CAPTION)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(18)
            .backgroundColor(COLOR_CARD_BG)
            .borderRadius(CARD_RADIUS)

            Column({ space: 10 }) {
              Text('题库名')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_TEXT_PRIMARY)

              TextInput({ placeholder: '请输入题库名', text: this.bankName })
                .width('100%')
                .height(50)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_TEXT_PRIMARY)
                .backgroundColor(COLOR_PAGE_BG)
                .borderRadius(14)
                .onChange((value: string) => {
                  this.bankName = value
                  this.errorMessage = ''
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(18)
            .backgroundColor(COLOR_CARD_BG)
            .borderRadius(CARD_RADIUS)

            Column({ space: 12 }) {
              Text('选择科目')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_TEXT_PRIMARY)

              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.subjects, (item: string) => {
                  Button(item)
                    .type(ButtonType.Normal)
                    .height(42)
                    .margin({ right: 8, bottom: 8 })
                    .padding({ left: 18, right: 18 })
                    .fontSize(BODY_FONT_SIZE)
                    .fontColor(this.isSubjectSelected(item) ? '#FFFFFF' : COLOR_TEXT_PRIMARY)
                    .backgroundColor(this.isSubjectSelected(item) ? COLOR_PRIMARY : COLOR_PAGE_BG)
                    .borderRadius(21)
                    .onClick(() => {
                      this.selectSubject(item)
                    })
                }, (item: string): string => item)
              }
              .width('100%')

              if (this.customSubject) {
                TextInput({ placeholder: '请输入科目', text: this.subject })
                  .width('100%')
                  .height(50)
                  .fontSize(BODY_FONT_SIZE)
                  .fontColor(COLOR_TEXT_PRIMARY)
                  .backgroundColor(COLOR_PAGE_BG)
                  .borderRadius(14)
                  .onChange((value: string) => {
                    this.subject = value
                    this.errorMessage = ''
                  })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(18)
            .backgroundColor(COLOR_CARD_BG)
            .borderRadius(CARD_RADIUS)

            Column({ space: 12 }) {
              Row({ space: 12 }) {
                Column({ space: 8 }) {
                  Text('起始页')
                    .fontSize(BODY_FONT_SIZE)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(COLOR_TEXT_PRIMARY)

                  TextInput({ placeholder: '1', text: this.startPageText })
                    .width('100%')
                    .height(48)
                    .type(InputType.Number)
                    .backgroundColor(COLOR_PAGE_BG)
                    .borderRadius(14)
                    .onChange((value: string) => {
                      this.startPageText = value
                      this.errorMessage = ''
                    })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Column({ space: 8 }) {
                  Text('结束页')
                    .fontSize(BODY_FONT_SIZE)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(COLOR_TEXT_PRIMARY)

                  TextInput({ placeholder: this.pageCount.toString(), text: this.endPageText })
                    .width('100%')
                    .height(48)
                    .type(InputType.Number)
                    .backgroundColor(COLOR_PAGE_BG)
                    .borderRadius(14)
                    .onChange((value: string) => {
                      this.endPageText = value
                      this.errorMessage = ''
                    })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')

              Text('已选 ' + this.selectedPageCount().toString() + ' 页 / 共 ' + this.pageCount.toString() + ' 页')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_TEXT_CAPTION)

              Text('单次最多识别 20 页')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_PRIMARY)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(18)
            .backgroundColor(COLOR_CARD_BG)
            .borderRadius(CARD_RADIUS)

            if (this.errorMessage.length > 0) {
              Text(this.errorMessage)
                .width('100%')
                .padding(14)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_DANGER)
                .backgroundColor('#FFF2F2')
                .borderRadius(14)
            }

            if (this.cleanupPending) {
              Button('稍后清理并返回')
                .type(ButtonType.Normal)
                .width('100%')
                .height(50)
                .fontColor(COLOR_PRIMARY)
                .backgroundColor(COLOR_CARD_BG)
                .border({ width: 1, color: COLOR_PRIMARY })
                .borderRadius(15)
                .enabled(!this.cleaning)
                .onClick(() => {
                  this.abandonAndLeave()
                })
            }

            Button(this.navigating ? '正在进入识别…' : '开始识别')
              .type(ButtonType.Normal)
              .width('100%')
              .height(52)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .backgroundColor(COLOR_PRIMARY)
              .borderRadius(16)
              .enabled(!this.navigating && !this.cleaning && !this.cleanupPending)
              .onClick(() => {
                this.startRecognition()
              })
          }
          .width('100%')
          .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: PAGE_PADDING })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_PAGE_BG)
  }
}
