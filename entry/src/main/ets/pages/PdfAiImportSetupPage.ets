import { Context } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'
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
import { PdfFileSelection, PdfImportSettings, PdfPageRangeValidation } from '../models/PdfImportModels'
import { AiPlatform, AiPlatformCatalog } from '../models/ai/AiPlatformCatalog'
import {
  AiImportError,
  AiImportErrorCode,
  AiImportErrorMessages,
  AiProviderConfig
} from '../models/ai/AiProviderConfig'
import { AccountSessionService } from '../services/AccountSessionService'
import { PdfImportService } from '../services/PdfImportService'
import { AiCredentialStore } from '../services/ai/AiCredentialStore'
import { AiProviderConfigStore } from '../services/ai/AiProviderConfigStore'
import { AppColors } from '../theme/AppColors'
import { PdfImportState } from '../utils/PdfImportState'
import { PdfImportValidator } from '../utils/PdfImportValidator'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

@Entry
@Component
struct PdfAiImportSetupPage {
  @State bankName: string = ''
  @State subject: string = ''
  @State startPageText: string = '1'
  @State endPageText: string = '1'
  @State errorMessage: string = ''
  @State fileName: string = ''
  @State fileSize: number = 0
  @State pageCount: number = 0
  @State customSubject: boolean = false
  @State selectionReady: boolean = false
  @State pending: boolean = false
  @State leaving: boolean = false
  @State providerLabel: string = '未配置'
  @State modelLabel: string = '未配置'
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = {
    top: 0, left: 0, right: 0, bottom: 0
  }
  @StorageProp('darkMode') darkMode: boolean = false
  @State windowSizeClass: WindowSizeClass = WindowSizeClass.COMPACT
  private subjects: Array<string> = ['数学', '语文', '英语', '物理', '化学', '其他']
  private sizeObserver?: WindowSizeObserver

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  aboutToAppear(): void {
    this.startWindowObserver()
    const state: PdfImportState = PdfImportState.shared()
    const selection: PdfFileSelection | null = state.getSelection()
    if (selection === null) {
      this.selectionReady = false
      this.errorMessage = 'PDF 选择已失效，请返回重新选择'
      return
    }
    this.fileName = selection.fileName
    this.fileSize = selection.fileSize
    this.pageCount = selection.pageCount
    const settings: PdfImportSettings | null = state.getSettings()
    if (settings === null) {
      this.bankName = PdfImportValidator.bankNameFromFileName(selection.fileName)
      this.startPageText = selection.startPage.toString()
      this.endPageText = selection.endPage.toString()
    } else {
      this.bankName = settings.bankName
      this.subject = settings.subject
      this.startPageText = settings.startPage.toString()
      this.endPageText = settings.endPage.toString()
      this.customSubject = this.subjects.indexOf(settings.subject) < 0
    }
    this.selectionReady = true
    this.errorMessage = ''
    this.loadProviderSummary()
  }

  onBackPress(): boolean {
    this.leaveSetup()
    return true
  }

  // 从「AI 识别设置」返回时页面实例被复用，aboutToAppear 不会重跑；
  // 必须在此重读，否则用户换完平台后卡片仍显示旧平台名，与实际生效配置不一致。
  onPageShow(): void {
    this.startWindowObserver()
    // 选择失效（selectionReady=false）时该屏只靠 errorMessage 传达原因，
    // 不能被 provider 摘要的失败文案覆盖 —— 与 aboutToAppear 的提前 return 保持一致。
    if (!this.selectionReady) return
    this.loadProviderSummary()
  }

  onPageHide(): void {
    this.stopWindowObserver()
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
    if (sizeClass !== this.windowSizeClass) {
      this.windowSizeClass = sizeClass
    }
  }

  private contentMaxWidth(): number {
    if (this.windowSizeClass === WindowSizeClass.COMPACT) return UiStyle.CONTENT_WIDTH
    if (this.windowSizeClass === WindowSizeClass.MEDIUM) return CONTENT_MAX_WIDTH
    return ResponsiveLayout.EXPANDED_CONTENT_MAX_WIDTH
  }

  private pageRangeSummary(): string {
    const startPage: number = Number(this.startPageText)
    const endPage: number = Number(this.endPageText)
    const validation: PdfPageRangeValidation = PdfImportValidator.validatePageRange(
      startPage, endPage, this.pageCount)
    if (!validation.valid) {
      return '可选 1–' + this.pageCount.toString() + ' 页，单次最多 20 页'
    }
    return '将识别第 ' + startPage.toString() + '–' + endPage.toString() +
      ' 页 · 共 ' + (endPage - startPage + 1).toString() + ' 页'
  }

  private providerStateLabel(): string {
    if (this.providerLabel === '配置不可用' || this.modelLabel === '配置不可用') return '需处理'
    if (this.providerLabel === '未配置' || this.modelLabel === '未配置') return '待设置'
    return '已选择'
  }

  private async loadProviderSummary(): Promise<void> {
    try {
      const context: Context = getContext(this)
      const config: AiProviderConfig | null = await AiProviderConfigStore.loadUsable(context)
      if (config === null) {
        this.providerLabel = '未配置'
        this.modelLabel = '未配置'
        return
      }
      const platform: AiPlatform | null = AiPlatformCatalog.find(config.providerId)
      this.providerLabel = platform === null ? '自定义' : platform.nameZh
      this.modelLabel = config.model
    } catch (err) {
      this.providerLabel = '配置不可用'
      this.modelLabel = '配置不可用'
      this.errorMessage = err instanceof AiImportError ?
        AiImportErrorMessages.forCode(err.code) : 'AI 导入配置读取失败'
    }
  }

  private selectSubject(value: string): void {
    if (this.pending || this.leaving) return
    this.customSubject = value === '其他'
    this.subject = this.customSubject ? '' : value
    this.errorMessage = ''
  }

  private isSubjectSelected(value: string): boolean {
    if (value === '其他') return this.customSubject
    return !this.customSubject && this.subject === value
  }

  private async startRecognition(): Promise<void> {
    if (this.pending || this.leaving) return
    const state: PdfImportState = PdfImportState.shared()
    const selection: PdfFileSelection | null = state.getSelection()
    if (selection === null) {
      this.errorMessage = 'PDF 选择已失效，请返回重新选择'
      return
    }
    const startPage: number = Number(this.startPageText)
    const endPage: number = Number(this.endPageText)
    const validation: PdfPageRangeValidation = PdfImportValidator.validatePageRange(
      startPage, endPage, selection.pageCount)
    const normalizedBankName: string = this.bankName.trim()
    const normalizedSubject: string = this.subject.trim()
    if (!validation.valid || normalizedBankName.length === 0 || normalizedSubject.length === 0) {
      this.errorMessage = validation.valid ? '请填写题库名和科目' : validation.message
      return
    }
    if (normalizedBankName.length > 255 || normalizedSubject.length > 64) {
      this.errorMessage = normalizedBankName.length > 255 ?
        '题库名不能超过 255 个字符' : '科目不能超过 64 个字符'
      return
    }
    this.pending = true
    this.errorMessage = ''
    try {
      const context: Context = getContext(this)
      const account: AccountSessionState = await AccountSessionService.state(context)
      if (!account.signedIn || account.userId.length === 0) {
        this.errorMessage = '请先登录华为账号'
        return
      }
      const config: AiProviderConfig | null = await AiProviderConfigStore.loadUsable(context)
      if (config === null) {
        this.errorMessage = '请先配置 AI Provider 和模型'
        return
      }
      if (!await AiCredentialStore.hasCredential(context)) {
        this.errorMessage = AiImportErrorMessages.forCode(AiImportErrorCode.MISSING_API_KEY)
        return
      }
      state.setSettings(new PdfImportSettings(
        normalizedBankName, normalizedSubject, startPage, endPage))
      const options: router.RouterOptions = {
        url: 'pages/PdfAiImportProgressPage'
      }
      await this.getUIContext().getRouter().pushUrl(options)
    } catch (err) {
      this.errorMessage = err instanceof AiImportError ?
        AiImportErrorMessages.forCode(err.code) : 'AI 导入配置读取失败'
    } finally {
      this.pending = false
    }
  }

  private openAiSettings(): void {
    if (this.pending || this.leaving) return
    const options: router.RouterOptions = {
      url: 'pages/AiRecognitionSettingsPage'
    }
    this.getUIContext().getRouter().pushUrl(options).catch(() => {
      this.errorMessage = 'AI 识别设置页面暂不可用'
    })
  }

  private leaveSetup(): void {
    if (this.pending || this.leaving) return
    this.leaving = true
    this.finishLeaving().catch(() => {
      this.errorMessage = 'PDF 临时文件清理失败，请重试'
    }).finally(() => {
      this.leaving = false
    })
  }

  private async finishLeaving(): Promise<void> {
    const state: PdfImportState = PdfImportState.shared()
    const selection: PdfFileSelection | null = state.getSelection()
    if (selection !== null) {
      await PdfImportService.removeTemporaryPdf(selection.uri)
    }
    state.reset()
    this.getUIContext().getRouter().back()
  }

  @Builder
  private SectionTitle(title: string): void {
    Text(title)
      .width('100%')
      .fontSize(SUBTITLE_FONT_SIZE)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.colors().textPrimary)
  }

  @Builder
  private FieldLabel(label: string): void {
    Text(label)
      .fontSize(UiStyle.DETAIL_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.colors().textSecondary)
  }

  @Builder
  private SelectedPdfCard(): void {
    Column({ space: 10 }) {
      this.SectionTitle('已选择 PDF')

      Text(this.fileName)
        .width('100%')
        .fontSize(UiStyle.BODY_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textPrimary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text('文件大小 ' + Math.ceil(this.fileSize / 1024).toString() + ' KB · 总页数 ' +
        this.pageCount.toString() + ' 页')
        .width('100%')
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textCaption)

      Text('PDF 仅在本机逐页转为图片，再由你配置的识别服务处理；单次最多 20 页')
        .width('100%')
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textCaption)
        .lineHeight(21)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: 1, color: this.colors().divider })
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  private RecognitionServiceCard(): void {
    Column({ space: UiStyle.FIELD_GAP }) {
      Row({ space: 12 }) {
        Text('识别服务')
          .layoutWeight(1)
          .fontSize(SUBTITLE_FONT_SIZE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().textPrimary)

        Text(this.providerStateLabel())
          .fontSize(12)
          .fontColor(this.providerStateLabel() === '已选择' ?
            this.colors().successText : UiStyle.errorText(this.darkMode))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column({ space: 6 }) {
        this.FieldLabel('识别平台')
        Text(this.providerLabel)
          .width('100%')
          .fontSize(UiStyle.BODY_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 6 }) {
        this.FieldLabel('识别模型')
        Text(this.modelLabel)
          .width('100%')
          .fontSize(UiStyle.BODY_SIZE)
          .fontColor(this.colors().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Button('调整 AI 设置')
        .type(ButtonType.Normal)
        .width('100%')
        .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
        .fontSize(UiStyle.DETAIL_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiStyle.action(this.darkMode))
        .backgroundColor(this.colors().cardBackground)
        .border({ width: 1, color: UiStyle.action(this.darkMode) })
        .borderRadius(UiStyle.CONTROL_RADIUS)
        .enabled(!this.pending && !this.leaving)
        .accessibilityText('调整 AI 识别平台与模型设置')
        .onClick(() => {
          this.openAiSettings()
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: 1, color: this.colors().divider })
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  private ConfigurationCard(): void {
    Column({ space: UiStyle.FIELD_GAP }) {
      this.SectionTitle('题库信息与识别页码')

      Text('题库信息')
        .width('100%')
        .fontSize(UiStyle.DETAIL_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textSecondary)

      Column({ space: 8 }) {
        this.FieldLabel('题库名')
        TextInput({ placeholder: '请输入题库名', text: this.bankName })
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontSize(UiStyle.BODY_SIZE)
          .fontColor(this.colors().textPrimary)
          .backgroundColor(this.colors().inputBackground)
          .border({ width: 1, color: this.colors().divider })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(!this.pending && !this.leaving)
          .onChange((value: string) => {
            this.bankName = value
            this.errorMessage = ''
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 8 }) {
        this.FieldLabel('选择科目')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.subjects, (item: string) => {
            Button(item)
              .type(ButtonType.Normal)
              .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
              .margin({ right: 8, bottom: 8 })
              .padding({ left: 18, right: 18 })
              .fontSize(BODY_FONT_SIZE)
              .fontColor(this.isSubjectSelected(item) ?
                UiStyle.onAction(this.darkMode) : this.colors().textPrimary)
              .backgroundColor(this.isSubjectSelected(item) ?
                UiStyle.action(this.darkMode) : this.colors().chipBackground)
              .border({ width: 1, color: this.isSubjectSelected(item) ?
                UiStyle.action(this.darkMode) : this.colors().divider })
              .borderRadius(24)
              .enabled(!this.pending && !this.leaving)
              .accessibilityText('科目：' + item)
              .onClick(() => {
                this.selectSubject(item)
              })
          }, (item: string): string => item)
        }
        .width('100%')

        if (this.customSubject) {
          TextInput({ placeholder: '请输入科目', text: this.subject })
            .width('100%')
            .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
            .fontSize(UiStyle.BODY_SIZE)
            .fontColor(this.colors().textPrimary)
            .backgroundColor(this.colors().inputBackground)
            .border({ width: 1, color: this.colors().divider })
            .borderRadius(UiStyle.CONTROL_RADIUS)
            .enabled(!this.pending && !this.leaving)
            .onChange((value: string) => {
              this.subject = value
              this.errorMessage = ''
            })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Divider()
        .color(this.colors().divider)

      Text('识别页码')
        .width('100%')
        .fontSize(UiStyle.DETAIL_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textSecondary)

      Row({ space: 12 }) {
        Column({ space: 8 }) {
          this.FieldLabel('起始页')
          TextInput({ placeholder: '1', text: this.startPageText })
            .type(InputType.Number)
            .width('100%')
            .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
            .fontSize(UiStyle.BODY_SIZE)
            .fontColor(this.colors().textPrimary)
            .backgroundColor(this.colors().inputBackground)
            .border({ width: 1, color: this.colors().divider })
            .borderRadius(UiStyle.CONTROL_RADIUS)
            .enabled(!this.pending && !this.leaving)
            .onChange((value: string) => {
              this.startPageText = value
              this.errorMessage = ''
            })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 8 }) {
          this.FieldLabel('结束页')
          TextInput({ placeholder: '1', text: this.endPageText })
            .type(InputType.Number)
            .width('100%')
            .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
            .fontSize(UiStyle.BODY_SIZE)
            .fontColor(this.colors().textPrimary)
            .backgroundColor(this.colors().inputBackground)
            .border({ width: 1, color: this.colors().divider })
            .borderRadius(UiStyle.CONTROL_RADIUS)
            .enabled(!this.pending && !this.leaving)
            .onChange((value: string) => {
              this.endPageText = value
              this.errorMessage = ''
            })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Text(this.pageRangeSummary())
        .width('100%')
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textCaption)
        .accessibilityText('识别页码摘要：' + this.pageRangeSummary())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: 1, color: this.colors().divider })
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  private ContentArea(): void {
    List() {
      ListItem() {
        Column() {
          if (this.windowSizeClass === WindowSizeClass.EXPANDED) {
            Row({ space: 20 }) {
              Column({ space: 16 }) {
                this.SelectedPdfCard()
                this.RecognitionServiceCard()
              }
              .layoutWeight(4)

              Column() {
                this.ConfigurationCard()
              }
              .layoutWeight(6)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          } else {
            Column({ space: 16 }) {
              this.SelectedPdfCard()
              this.RecognitionServiceCard()
              this.ConfigurationCard()
            }
            .width('100%')
          }
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
  private StatusNotice(): void {
    if (this.errorMessage.length > 0) {
      Text(this.errorMessage)
        .width('100%')
        .constraintSize({ maxWidth: this.contentMaxWidth(), minHeight: UiStyle.TOUCH_TARGET })
        .padding({ left: 16, right: 16, top: 13, bottom: 13 })
        .fontSize(BODY_FONT_SIZE)
        .fontColor(UiStyle.errorText(this.darkMode))
        .backgroundColor(this.colors().errorSoft)
        .border({ width: 1, color: this.colors().error })
        .borderRadius(UiStyle.CONTROL_RADIUS)
        .accessibilityText('错误提示：' + this.errorMessage)
        .margin({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 10 })
    }
  }

  @Builder
  private BottomAction(): void {
    Column({ space: 8 }) {
      Button(this.pending ? '正在准备识别…' : '开始 AI 识别')
        .type(ButtonType.Normal)
        .width('100%')
        .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
        .fontSize(UiStyle.BODY_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiStyle.onAction(this.darkMode))
        .backgroundColor(UiStyle.action(this.darkMode))
        .borderRadius(UiStyle.CONTROL_RADIUS)
        .enabled(!this.pending && !this.leaving)
        .accessibilityText(this.pending ? '正在准备识别' : '开始 AI 识别')
        .onClick(() => {
          this.startRecognition()
        })

      Text('开始后将进入识别进度，识别完成后逐题审核')
        .width('100%')
        .fontSize(12)
        .fontColor(this.colors().textCaption)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .constraintSize({ maxWidth: this.contentMaxWidth() })
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 12 })
  }

  @Builder
  private InvalidSelectionAction(): void {
    Button('返回导入')
      .type(ButtonType.Normal)
      .width('100%')
      .constraintSize({
        maxWidth: this.contentMaxWidth() - PAGE_PADDING * 2,
        minHeight: UiStyle.TOUCH_TARGET
      })
      .fontSize(UiStyle.BODY_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor(UiStyle.onAction(this.darkMode))
      .backgroundColor(UiStyle.action(this.darkMode))
      .borderRadius(UiStyle.CONTROL_RADIUS)
      .enabled(!this.pending && !this.leaving)
      .onClick(() => {
        this.leaveSetup()
      })
  }

  build() {
    Navigation() {
      Column() {
        if (this.selectionReady) {
          this.ContentArea()
        } else {
          Blank()
        }
        this.StatusNotice()
        if (this.selectionReady) {
          this.BottomAction()
        } else {
          this.InvalidSelectionAction()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)
    }
    .title('AI PDF 导入设置', {
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
