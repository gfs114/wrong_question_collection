import { Context } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'
import { util } from '@kit.ArkTS'
import { MathContentView } from '../components/MathContentView'
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
import { AppColors } from '../theme/AppColors'
import { PdfImportState } from '../utils/PdfImportState'
import { MathContentUtils } from '../utils/MathContentUtils'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

import { AiQuestionType } from '../models/ai/AiImportModels'
import { AiImportError, AiImportErrorMessages } from '../models/ai/AiProviderConfig'
import { PdfReviewAdapter, PdfReviewSession, PdfReviewQuestion, PdfReviewOption,
  PdfReviewImage, PdfReviewFailure, PdfReviewSource, PdfReviewSaveStage,
  PdfReviewSavePolicy } from '../services/review/PdfReviewModels'
import { PdfReviewSessionStore } from '../services/review/PdfReviewSession'
import { CloudPdfReviewAdapter } from '../services/review/CloudPdfReviewAdapter'
import { AiPdfReviewAdapter } from '../services/review/AiPdfReviewAdapter'

@Entry
@Component
struct PdfImportReviewPage {
  @State session: PdfReviewSession | null = null
  @State draftQuestions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
  @State failures: Array<PdfReviewFailure> = new Array<PdfReviewFailure>()
  @State previewDraftQuestionId: string = ''
  @State bankName: string = ''
  @State subject: string = ''
  @State loading: boolean = true
  @State pending: boolean = false
  @State authoritativeStatePending: boolean = false
  @State navigationPending: boolean = false
  @State confirmationComplete: boolean = false
  @State artifactExpired: boolean = false
  @State errorMessage: string = ''
  @State windowSizeClass: WindowSizeClass = WindowSizeClass.COMPACT
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = {
    top: 0, left: 0, right: 0, bottom: 0
  }
  @StorageProp('darkMode') darkMode: boolean = false
  private initialized: boolean = false
  private confirmedBankId: string = ''
  private adapter: PdfReviewAdapter | null = null
  private sizeObserver?: WindowSizeObserver

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  aboutToAppear(): void {
    this.startWindowObserver()
    if (this.initialized) return
    this.initialized = true
    this.adapter = PdfImportState.shared().getReviewSessionId().length > 0 ?
      new AiPdfReviewAdapter() : new CloudPdfReviewAdapter()
    this.loadDraft()
  }

  onPageShow(): void {
    this.startWindowObserver()
  }

  onPageHide(): void {
    this.stopWindowObserver()
  }

  onBackPress(): boolean {
    this.returnToImportPage()
    return true
  }

  private async loadDraft(): Promise<void> {
    if (this.pending || this.navigationPending || this.adapter === null) return
    this.loading = true
    this.errorMessage = ''
    try {
      const session: PdfReviewSession = await this.adapter.load(getContext(this))
      this.applySession(session)
      this.authoritativeStatePending = false
    } catch {
      this.authoritativeStatePending = true
      this.errorMessage = '审核状态暂时无法确认，请切回导入账号后重新加载'
    } finally {
      this.loading = false
    }
  }

  private applySession(session: PdfReviewSession): void {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    this.session = snapshot
    this.draftQuestions = snapshot.questions
    this.failures = snapshot.failures
    this.bankName = snapshot.bankName
    this.subject = snapshot.subject
    this.confirmedBankId = snapshot.bankUuid
    this.confirmationComplete = snapshot.saveStage === PdfReviewSaveStage.COMPLETE
    this.artifactExpired = snapshot.source === PdfReviewSource.CLOUD &&
      PdfImportState.shared().getCloudArtifactExpired()
  }

  private canEdit(): boolean {
    return !this.loading && !this.pending && !this.navigationPending &&
      !this.authoritativeStatePending && this.session !== null &&
      PdfReviewSavePolicy.canEdit(this.session.saveStage)
  }

  private isAiReview(): boolean {
    return this.session !== null && this.session.source === PdfReviewSource.AI
  }

  private textSaveStarted(): boolean {
    return this.session !== null && this.session.saveStage !== PdfReviewSaveStage.DRAFT
  }

  private persistEdits(snapshot: PdfReviewSession): void {
    if (this.adapter === null) return
    this.adapter.persist(PdfReviewSessionStore.copyOf(snapshot))
    this.applySession(snapshot)
  }

  private replaceQuestion(draftQuestionId: string, type: AiQuestionType, questionText: string,
    options: Array<PdfReviewOption>, answer: string, analysis: string): void {
    if (!this.canEdit() || this.session === null) return
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(this.session)
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) return
    const replacement: PdfReviewQuestion = snapshot.questions[index]
    replacement.type = type
    replacement.question = questionText
    replacement.options = options.map((option: PdfReviewOption): PdfReviewOption =>
      new PdfReviewOption(option.key, option.value))
    replacement.answer = answer
    replacement.analysis = analysis
    this.persistEdits(snapshot)
    if (this.previewDraftQuestionId === draftQuestionId && !this.hasMathContent(replacement)) {
      this.previewDraftQuestionId = ''
    }
  }

  private updateType(draftQuestionId: string, value: AiQuestionType): void {
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) {
      return
    }
    const source: PdfReviewQuestion = this.draftQuestions[index]
    this.replaceQuestion(draftQuestionId, value, source.question, source.options,
      source.answer, source.analysis)
  }

  private updateQuestionText(draftQuestionId: string, value: string): void {
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) {
      return
    }
    const source: PdfReviewQuestion = this.draftQuestions[index]
    this.replaceQuestion(draftQuestionId, source.type, value, source.options,
      source.answer, source.analysis)
  }

  private updateOption(draftQuestionId: string, optionKey: string, value: string): void {
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) {
      return
    }
    const source: PdfReviewQuestion = this.draftQuestions[index]
    const options: Array<PdfReviewOption> = source.options.map(
      (option: PdfReviewOption): PdfReviewOption =>
        new PdfReviewOption(option.key, option.key === optionKey ? value : option.value))
    this.replaceQuestion(draftQuestionId, source.type, source.question, options,
      source.answer, source.analysis)
  }

  private updateAnswer(draftQuestionId: string, value: string): void {
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) {
      return
    }
    const source: PdfReviewQuestion = this.draftQuestions[index]
    this.replaceQuestion(draftQuestionId, source.type, source.question, source.options,
      value, source.analysis)
  }

  private updateAnalysis(draftQuestionId: string, value: string): void {
    const index: number = this.findQuestionIndex(draftQuestionId)
    if (index < 0) {
      return
    }
    const source: PdfReviewQuestion = this.draftQuestions[index]
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

  private async saveReview(): Promise<void> {
    if (this.pending || this.loading || this.navigationPending || this.authoritativeStatePending ||
      this.session === null || this.adapter === null) return
    if (PdfReviewSavePolicy.canEdit(this.session.saveStage)) {
      const message: string = this.validateDraft()
      if (message.length > 0) {
        this.errorMessage = message
        return
      }
    }
    const working: PdfReviewSession = PdfReviewSessionStore.copyOf(this.session)
    this.pending = true
    this.errorMessage = ''
    let success: boolean = false
    try {
      this.adapter.persist(working)
      const saved: PdfReviewSession = await this.adapter.save(getContext(this), working)
      this.applySession(saved)
      success = saved.saveStage === PdfReviewSaveStage.COMPLETE
      if (!success) this.errorMessage = '题目保存已开始，请重试完成文字和原题图片保存'
    } catch {
      if (working.source === PdfReviewSource.AI) {
        if (!await this.reconcileReviewState()) return
      } else {
        this.applySession(working)
      }
      this.errorMessage = this.textSaveStarted() ?
        '题目保存已开始，原题图片或保存收尾未完成，请重试' : '题目保存失败，请重试'
    } finally {
      this.pending = false
    }
    if (success) {
      this.showToast('题目已保存')
      await this.navigateToImportPage()
    }
  }

  private async reconcileReviewState(): Promise<boolean> {
    this.authoritativeStatePending = true
    try {
      if (this.adapter !== null) {
        const authoritative: PdfReviewSession = await this.adapter.load(getContext(this))
        this.applySession(authoritative)
        this.authoritativeStatePending = false
        return true
      }
    } catch {
    }
    this.errorMessage = '审核状态暂时无法确认，请切回导入账号后重新加载'
    return false
  }

  private async retryFailure(pageNumber: number): Promise<void> {
    if (!this.canEdit() || !this.isAiReview() || this.session === null || this.adapter === null) return
    this.pending = true
    this.errorMessage = ''
    try {
      const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(this.session)
      this.adapter.persist(snapshot)
      const updated: PdfReviewSession = await this.adapter.retryPage(getContext(this), snapshot, pageNumber)
      this.applySession(updated)
      this.previewDraftQuestionId = ''
    } catch (err) {
      if (!await this.reconcileReviewState()) return
      this.errorMessage = err instanceof AiImportError ?
        AiImportErrorMessages.forCode(err.code) : '本页重试失败'
    } finally {
      this.pending = false
    }
  }

  private async addManualQuestion(failure: PdfReviewFailure): Promise<void> {
    if (!this.canEdit() || !this.isAiReview() || this.session === null) return
    const id: string = util.generateRandomUUID()
    const images: Array<PdfReviewImage> = new Array<PdfReviewImage>()
    if (failure.evidencePath.length > 0) {
      images.push(new PdfReviewImage('', failure.evidencePath, '', 0, 'image/jpeg', 0))
    }
    const question: PdfReviewQuestion = new PdfReviewQuestion(id, id, '', AiQuestionType.UNKNOWN, '',
      new Array<PdfReviewOption>(), '', '', failure.pageNumber, failure.pageNumber, 0, true, images)
    await this.resolveFailure(failure.pageNumber, question)
  }

  private async discardFailure(pageNumber: number): Promise<void> {
    await this.resolveFailure(pageNumber, null)
  }

  private async resolveFailure(pageNumber: number, replacement: PdfReviewQuestion | null): Promise<void> {
    if (!this.canEdit() || !this.isAiReview() || this.session === null || this.adapter === null) return
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(this.session)
    this.pending = true
    this.errorMessage = ''
    try {
      const updated: PdfReviewSession = await this.adapter.discardFailure(
        getContext(this), snapshot, pageNumber, replacement)
      this.applySession(updated)
    } catch (err) {
      if (!await this.reconcileReviewState()) return
      this.errorMessage = err instanceof AiImportError ?
        AiImportErrorMessages.forCode(err.code) : '本页处理失败，请重试'
    } finally {
      this.pending = false
    }
  }

  private nullableText(value: string | null): string {
    return value === null ? '' : value
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

  private hasMathContent(question: PdfReviewQuestion): boolean {
    if (MathContentUtils.containsMath(question.question)) {
      return true
    }
    for (const option of question.options) {
      if (MathContentUtils.containsMath(option.value)) return true
    }
    return MathContentUtils.containsMath(this.nullableText(question.answer)) ||
      MathContentUtils.containsMath(this.nullableText(question.analysis))
  }

  private toggleMathPreview(draftQuestionId: string): void {
    if (!this.canEdit()) return
    this.previewDraftQuestionId = this.previewDraftQuestionId === draftQuestionId ? '' : draftQuestionId
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
    return this.windowSizeClass === WindowSizeClass.EXPANDED ?
      ResponsiveLayout.EXPANDED_CONTENT_MAX_WIDTH : CONTENT_MAX_WIDTH
  }

  @Builder
  private MathFieldPreview(label: string, content: string) {
    if (MathContentUtils.containsMath(content)) {
      Column({ space: 6 }) {
        Text(label)
          .width('100%')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textCaption)

        MathContentView({
          content: content,
          fontSize: BODY_FONT_SIZE,
          fontWeight: 400,
          textColor: this.colors().textPrimary,
          lineHeight: 22
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(12)
      .backgroundColor(this.colors().inputBackground)
      .borderRadius(10)
    }
  }

  @Builder
  private DraftMathPreview(question: PdfReviewQuestion) {
    Column({ space: 8 }) {
      Text('公式预览')
        .width('100%')
        .fontSize(BODY_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().textPrimary)

      this.MathFieldPreview('题干', question.question)

      ForEach(question.options, (option: PdfReviewOption) => {
        this.MathFieldPreview('选项 ' + option.key, option.value)
      }, (option: PdfReviewOption): string => question.draftQuestionId + '_preview_' + option.key)

      this.MathFieldPreview('答案', this.nullableText(question.answer))
      this.MathFieldPreview('解析', this.nullableText(question.analysis))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(this.colors().pageBackground)
    .borderRadius(12)
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  private returnToImportPage(): void {
    if (this.pending || this.loading || this.navigationPending) return
    if (this.authoritativeStatePending) {
      this.errorMessage = '审核状态暂时无法确认，请重新加载审核状态后再返回'
      return
    }
    if (this.session === null || !PdfReviewSavePolicy.canAbandon(this.session.saveStage)) {
      this.navigateToImportPage()
      return
    }
    this.navigationPending = true
    try {
      this.getUIContext().showAlertDialog({
        title: '放弃本次导入？',
        message: '放弃后将删除本次导入的本地草稿缓存。',
        autoCancel: false,
        primaryButton: {
          value: '继续编辑',
          action: (): void => { this.navigationPending = false }
        },
        secondaryButton: {
          value: '放弃导入',
          action: (): void => { this.abandonReview() }
        },
        cancel: (): void => { this.navigationPending = false }
      })
    } catch {
      this.navigationPending = false
      this.errorMessage = '退出确认暂不可用，请重试'
    }
  }

  private async abandonReview(): Promise<void> {
    if (this.pending || this.loading || this.authoritativeStatePending ||
      this.session === null || this.adapter === null ||
      !PdfReviewSavePolicy.canAbandon(this.session.saveStage)) return
    this.pending = true
    try {
      await this.adapter.abandon(getContext(this), PdfReviewSessionStore.copyOf(this.session))
      this.session = null
      this.pending = false
      this.navigationPending = false
      await this.navigateToImportPage()
    } catch {
      this.errorMessage = '放弃导入失败，请重试'
      this.pending = false
      this.navigationPending = false
    }
  }

  private async navigateToImportPage(): Promise<void> {
    if (this.pending || this.navigationPending) return
    this.navigationPending = true
    const options: router.RouterOptions = { url: 'pages/ImportBankPage' }
    try {
      await this.getUIContext().getRouter().replaceUrl(options)
    } catch {
      this.navigationPending = false
      this.errorMessage = '导入页面暂不可用，请重试返回'
    }
  }

  @Builder
  private FieldLabel(label: string): void {
    Text(label)
      .width('100%')
      .fontSize(UiStyle.DETAIL_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.colors().textSecondary)
  }

  @Builder
  private BankSummary(): void {
    Row({ space: 16 }) {
      Column({ space: 6 }) {
        Text(this.bankName)
          .width('100%')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('学科：' + this.subject)
          .width('100%')
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.colors().textCaption)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 4 }) {
        Text(this.draftQuestions.length.toString())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(UiStyle.action(this.darkMode))
        Text('待复核题目')
          .fontSize(12)
          .fontColor(this.colors().textCaption)
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding(18)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: 1, color: this.colors().divider })
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  private SourceEvidence(question: PdfReviewQuestion, questionIndex: number): void {
    Column({ space: 10 }) {
      this.FieldLabel('原题')
      ForEach(question.images, (image: PdfReviewImage) => {
        if (image.localPath.length > 0) {
          Image('file://' + image.localPath)
            .width('100%')
            .height(this.windowSizeClass === WindowSizeClass.EXPANDED ? 300 : 220)
            .objectFit(ImageFit.Contain)
            .backgroundColor(this.colors().inputBackground)
            .border({ width: 1, color: this.colors().divider })
            .borderRadius(UiStyle.CONTROL_RADIUS)
            .accessibilityText('第 ' + (questionIndex + 1).toString() + ' 题原图')
        }
      }, (image: PdfReviewImage): string =>
        question.draftQuestionId + '_image_' + image.sortOrder.toString())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TypeButton(question: PdfReviewQuestion, label: string, type: AiQuestionType): void {
    Button(label)
      .type(ButtonType.Normal)
      .width(this.windowSizeClass === WindowSizeClass.COMPACT ? '48%' : '24%')
      .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
      .margin({ bottom: 8 })
      .fontSize(UiStyle.DETAIL_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor(question.type === type ?
        UiStyle.onAction(this.darkMode) : this.colors().textPrimary)
      .backgroundColor(question.type === type ?
        UiStyle.action(this.darkMode) : this.colors().chipBackground)
      .border({ width: 1, color: question.type === type ?
        UiStyle.action(this.darkMode) : this.colors().divider })
      .borderRadius(UiStyle.CONTROL_RADIUS)
      .enabled(this.canEdit())
      .accessibilityText('题型：' + label)
      .accessibilitySelected(question.type === type)
      .onClick(() => { this.updateType(question.draftQuestionId, type) })
  }

  @Builder
  private TypeSelector(question: PdfReviewQuestion): void {
    Column({ space: 8 }) {
      this.FieldLabel('题型')
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        this.TypeButton(question, '单选', AiQuestionType.SINGLE_CHOICE)
        this.TypeButton(question, '填空', AiQuestionType.BLANK)
        this.TypeButton(question, '解答', AiQuestionType.SHORT_ANSWER)
        this.TypeButton(question, '待确认', AiQuestionType.UNKNOWN)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private QuestionEditor(question: PdfReviewQuestion): void {
    Column({ space: 14 }) {
      this.TypeSelector(question)

      Column({ space: 8 }) {
        this.FieldLabel('题干')
        TextArea({ placeholder: '请输入题干', text: question.question })
          .width('100%')
          .constraintSize({ minHeight: 120 })
          .fontSize(UiStyle.BODY_SIZE)
          .fontColor(this.colors().textPrimary)
          .backgroundColor(this.colors().inputBackground)
          .border({ width: 1, color: this.colors().divider })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(this.canEdit())
          .onChange((value: string) => {
            this.updateQuestionText(question.draftQuestionId, value)
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 8 }) {
        this.FieldLabel('识别选项')
        if (question.options.length === 0) {
          Text('暂无选项')
            .width('100%')
            .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
            .padding({ left: 14, right: 14, top: 13, bottom: 13 })
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textSecondary)
            .backgroundColor(this.colors().inputBackground)
            .border({ width: 1, color: this.colors().divider })
            .borderRadius(UiStyle.CONTROL_RADIUS)
        } else {
          ForEach(question.options, (option: PdfReviewOption) => {
            TextInput({ placeholder: '选项 ' + option.key, text: option.value })
              .width('100%')
              .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
              .fontSize(UiStyle.BODY_SIZE)
              .fontColor(this.colors().textPrimary)
              .backgroundColor(this.colors().inputBackground)
              .border({ width: 1, color: this.colors().divider })
              .borderRadius(UiStyle.CONTROL_RADIUS)
              .enabled(this.canEdit())
              .accessibilityText('选项 ' + option.key)
              .onChange((value: string) => {
                this.updateOption(question.draftQuestionId, option.key, value)
              })
          }, (option: PdfReviewOption): string =>
            question.draftQuestionId + '_option_' + option.key)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 8 }) {
        this.FieldLabel('答案')
        TextInput({ placeholder: '答案（选填）', text: this.nullableText(question.answer) })
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontSize(UiStyle.BODY_SIZE)
          .fontColor(this.colors().textPrimary)
          .backgroundColor(this.colors().inputBackground)
          .border({ width: 1, color: this.colors().divider })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(this.canEdit())
          .onChange((value: string) => {
            this.updateAnswer(question.draftQuestionId, value)
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 8 }) {
        this.FieldLabel('解析')
        TextArea({ placeholder: '解析（选填）', text: this.nullableText(question.analysis) })
          .width('100%')
          .constraintSize({ minHeight: 104 })
          .fontSize(UiStyle.BODY_SIZE)
          .fontColor(this.colors().textPrimary)
          .backgroundColor(this.colors().inputBackground)
          .border({ width: 1, color: this.colors().divider })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(this.canEdit())
          .onChange((value: string) => {
            this.updateAnalysis(question.draftQuestionId, value)
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.hasMathContent(question)) {
        Button(this.previewDraftQuestionId === question.draftQuestionId ?
          '收起公式预览' : '预览公式')
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontSize(UiStyle.DETAIL_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiStyle.action(this.darkMode))
          .backgroundColor(this.colors().chipBackground)
          .border({ width: 1, color: this.colors().divider })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(this.canEdit())
          .onClick(() => { this.toggleMathPreview(question.draftQuestionId) })

        if (this.previewDraftQuestionId === question.draftQuestionId) {
          this.DraftMathPreview(question)
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private QuestionCard(question: PdfReviewQuestion, questionIndex: number): void {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('第 ' + (questionIndex + 1).toString() + ' 题')
            .width('100%')
            .fontSize(SUBTITLE_FONT_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().textPrimary)
          Text('页码 ' + question.pageStart.toString() + '–' +
            question.pageEnd.toString() + ' · 置信度 ' +
            Math.round(question.confidence * 100).toString() + '%')
            .width('100%')
            .fontSize(12)
            .fontColor(this.colors().textSecondary)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.typeLabel(question.type))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(question.type === 'unknown' ?
            UiStyle.errorText(this.darkMode) : UiStyle.action(this.darkMode))
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.windowSizeClass === WindowSizeClass.EXPANDED && question.images.length > 0) {
        Row({ space: 20 }) {
          Column() {
            this.SourceEvidence(question, questionIndex)
          }
          .layoutWeight(4)
          .alignItems(HorizontalAlign.Start)

          Column() {
            this.QuestionEditor(question)
          }
          .layoutWeight(6)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      } else {
        Column({ space: 14 }) {
          if (question.images.length > 0) {
            this.SourceEvidence(question, questionIndex)
          }
          this.QuestionEditor(question)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      if (question.reviewRequired) {
        Text('需要人工复核')
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .padding({ left: 14, right: 14, top: 13, bottom: 13 })
          .fontSize(UiStyle.DETAIL_SIZE)
          .fontColor(UiStyle.errorText(this.darkMode))
          .backgroundColor(this.colors().errorSoft)
          .border({ width: 1, color: UiStyle.errorText(this.darkMode) })
          .borderRadius(UiStyle.CONTROL_RADIUS)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(18)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: 1, color: this.colors().divider })
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  private FailureActions(failure: PdfReviewFailure): void {
    if (this.windowSizeClass === WindowSizeClass.COMPACT) {
      Column({ space: 10 }) {
        Button('重试识别')
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontColor(UiStyle.onAction(this.darkMode))
          .backgroundColor(UiStyle.action(this.darkMode))
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(this.canEdit())
          .onClick(() => { this.retryFailure(failure.pageNumber) })
        Button('手动新增题目')
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontColor(UiStyle.action(this.darkMode))
          .backgroundColor(this.colors().cardBackground)
          .border({ width: 1, color: UiStyle.action(this.darkMode) })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(this.canEdit())
          .onClick(() => { this.addManualQuestion(failure) })
        Button('放弃本页')
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontColor(UiStyle.errorText(this.darkMode))
          .backgroundColor(this.colors().cardBackground)
          .border({ width: 1, color: UiStyle.errorText(this.darkMode) })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(this.canEdit())
          .onClick(() => { this.discardFailure(failure.pageNumber) })
      }
      .width('100%')
    } else {
      Row({ space: 10 }) {
        Button('重试识别')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontColor(UiStyle.onAction(this.darkMode))
          .backgroundColor(UiStyle.action(this.darkMode))
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(this.canEdit())
          .onClick(() => { this.retryFailure(failure.pageNumber) })
        Button('手动新增题目')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontColor(UiStyle.action(this.darkMode))
          .backgroundColor(this.colors().cardBackground)
          .border({ width: 1, color: UiStyle.action(this.darkMode) })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(this.canEdit())
          .onClick(() => { this.addManualQuestion(failure) })
        Button('放弃本页')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontColor(UiStyle.errorText(this.darkMode))
          .backgroundColor(this.colors().cardBackground)
          .border({ width: 1, color: UiStyle.errorText(this.darkMode) })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(this.canEdit())
          .onClick(() => { this.discardFailure(failure.pageNumber) })
      }
      .width('100%')
    }
  }

  @Builder
  private FailureSummary(failure: PdfReviewFailure): void {
    Column({ space: 8 }) {
      Text('第 ' + failure.pageNumber.toString() + ' 页识别未完成')
        .width('100%')
        .fontSize(SUBTITLE_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(UiStyle.errorText(this.darkMode))
      Text(AiImportErrorMessages.forCode(failure.code))
        .width('100%')
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textSecondary)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private FailureCard(failure: PdfReviewFailure): void {
    Column({ space: 14 }) {
      if (this.windowSizeClass === WindowSizeClass.EXPANDED && failure.evidencePath.length > 0) {
        Row({ space: 18 }) {
          Image('file://' + failure.evidencePath)
            .width(240)
            .height(200)
            .objectFit(ImageFit.Contain)
            .backgroundColor(this.colors().inputBackground)
            .border({ width: 1, color: this.colors().divider })
            .borderRadius(UiStyle.CONTROL_RADIUS)
            .accessibilityText('第 ' + failure.pageNumber.toString() + ' 页原图')

          Column({ space: 14 }) {
            this.FailureSummary(failure)
            this.FailureActions(failure)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      } else {
        this.FailureSummary(failure)
        if (failure.evidencePath.length > 0) {
          Image('file://' + failure.evidencePath)
          .width('100%')
          .height(180)
          .objectFit(ImageFit.Contain)
          .backgroundColor(this.colors().inputBackground)
          .border({ width: 1, color: this.colors().divider })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .accessibilityText('第 ' + failure.pageNumber.toString() + ' 页原图')
        }
        this.FailureActions(failure)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(18)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: 1, color: UiStyle.errorText(this.darkMode) })
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  private ReviewSectionHeader(title: string, summary: string): void {
    Row({ space: 12 }) {
      Text(title)
        .fontSize(SUBTITLE_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().textPrimary)
      Text(summary)
        .layoutWeight(1)
        .fontSize(UiStyle.DETAIL_SIZE)
        .fontColor(this.colors().textCaption)
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private LoadingState(): void {
    Column({ space: 16 }) {
      LoadingProgress()
        .width(42)
        .height(42)
        .color(UiStyle.action(this.darkMode))
      Text('正在读取识别草稿')
        .fontSize(UiStyle.BODY_SIZE)
        .fontColor(this.colors().textSecondary)
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private CompletedState(): void {
    Column({ space: 12 }) {
      Text('题目已保存')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(UiStyle.action(this.darkMode))
      Text('题库标识：' + this.confirmedBankId)
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textCaption)
      Text('题目已保存，可返回导入页继续使用。')
        .fontSize(UiStyle.BODY_SIZE)
        .fontColor(this.colors().textPrimary)
    }
    .layoutWeight(1)
    .width('100%')
    .padding(PAGE_PADDING)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private RecoveryState(): void {
    Column({ space: 14 }) {
      Text('审核状态需要重新确认')
        .fontSize(SUBTITLE_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().textPrimary)
      Text('当前编辑与返回操作已锁定，重新加载后可继续处理。')
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textSecondary)
        .textAlign(TextAlign.Center)
      Button('重新加载审核状态')
        .type(ButtonType.Normal)
        .width('100%')
        .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
        .fontColor(UiStyle.onAction(this.darkMode))
        .backgroundColor(UiStyle.action(this.darkMode))
        .borderRadius(UiStyle.CONTROL_RADIUS)
        .enabled(!this.pending && !this.loading && !this.navigationPending)
        .onClick(() => { this.loadDraft() })
    }
    .layoutWeight(1)
    .width('100%')
    .constraintSize({ maxWidth: UiStyle.CONTENT_WIDTH })
    .padding(PAGE_PADDING)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private EmptyReviewState(): void {
    Column({ space: 14 }) {
      Text('暂时无法显示识别草稿')
        .fontSize(SUBTITLE_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().textPrimary)
      Text('可以重新读取草稿；不会重新执行识别。')
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textSecondary)
      Button(this.pending ? '正在重试…' : '重新读取草稿')
        .type(ButtonType.Normal)
        .width('100%')
        .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
        .fontColor(UiStyle.onAction(this.darkMode))
        .backgroundColor(UiStyle.action(this.darkMode))
        .borderRadius(UiStyle.CONTROL_RADIUS)
        .enabled(!this.pending && !this.loading && !this.navigationPending)
        .onClick(() => { this.loadDraft() })
    }
    .layoutWeight(1)
    .width('100%')
    .constraintSize({ maxWidth: UiStyle.CONTENT_WIDTH })
    .padding(PAGE_PADDING)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private ReviewContent(): void {
    if (this.loading) {
      this.LoadingState()
    } else if (this.confirmationComplete) {
      this.CompletedState()
    } else if (this.authoritativeStatePending) {
      this.RecoveryState()
    } else if (this.draftQuestions.length === 0 && this.failures.length === 0 && !this.textSaveStarted()) {
      this.EmptyReviewState()
    } else {
      Column({ space: 12 }) {
        this.BankSummary()
        List({ space: 14 }) {
          if (this.isAiReview() && this.failures.length > 0) {
            ListItem() {
              this.ReviewSectionHeader('待处理页',
                this.failures.length.toString() + ' 页需要人工处理')
            }
            ForEach(this.failures, (failure: PdfReviewFailure) => {
              ListItem() {
                this.FailureCard(failure)
              }
            }, (failure: PdfReviewFailure): string => failure.pageNumber.toString())
          }
          if (this.draftQuestions.length > 0) {
            ListItem() {
              this.ReviewSectionHeader('已识别题目',
                this.draftQuestions.length.toString() + ' 题 · 请逐题核对')
            }
            ForEach(this.draftQuestions, (question: PdfReviewQuestion, questionIndex: number) => {
              ListItem() {
                this.QuestionCard(question, questionIndex)
              }
            }, (question: PdfReviewQuestion): string => question.draftQuestionId)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
      .layoutWeight(1)
      .width('100%')
      .constraintSize({ maxWidth: this.contentMaxWidth() })
      .align(Alignment.Top)
      .padding({ top: 12, left: PAGE_PADDING, right: PAGE_PADDING })
    }
  }

  @Builder
  private StatusNotices(): void {
    Column({ space: 8 }) {
      if (this.artifactExpired) {
        Text('原题图片已过期，文字仍可使用')
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .padding({ left: 16, right: 16, top: 13, bottom: 13 })
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.colors().warningText)
          .backgroundColor(this.colors().warning)
          .border({ width: 1, color: this.colors().warningText })
          .borderRadius(UiStyle.CONTROL_RADIUS)
      }
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .padding({ left: 16, right: 16, top: 13, bottom: 13 })
          .fontSize(BODY_FONT_SIZE)
          .fontColor(UiStyle.errorText(this.darkMode))
          .backgroundColor(this.colors().errorSoft)
          .border({ width: 1, color: UiStyle.errorText(this.darkMode) })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .accessibilityText('审核提示：' + this.errorMessage)
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: this.contentMaxWidth() })
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 8 })
  }

  @Builder
  private BottomAction(): void {
    Column({ space: 8 }) {
      if (this.confirmationComplete) {
        if (this.errorMessage.length > 0) {
          Button('重试完成保存')
            .type(ButtonType.Normal)
            .width('100%')
            .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
            .fontColor(UiStyle.action(this.darkMode))
            .backgroundColor(this.colors().cardBackground)
            .border({ width: 1, color: UiStyle.action(this.darkMode) })
            .borderRadius(UiStyle.CONTROL_RADIUS)
            .enabled(!this.pending && !this.navigationPending && !this.authoritativeStatePending)
            .onClick(() => { this.saveReview() })
        }
        Button(this.navigationPending ? '正在返回…' : '返回导入页')
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontColor(UiStyle.onAction(this.darkMode))
          .backgroundColor(UiStyle.action(this.darkMode))
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(!this.navigationPending)
          .onClick(() => { this.returnToImportPage() })
      } else if (!this.loading && !this.authoritativeStatePending &&
        (this.draftQuestions.length > 0 || this.failures.length > 0 || this.textSaveStarted())) {
        if (this.textSaveStarted()) {
          Text('保存已开始；请重试完成文字和原题图片保存。')
            .width('100%')
            .fontSize(12)
            .fontColor(this.colors().textCaption)
        }
        Button(this.pending ? '正在处理…' :
          !this.textSaveStarted() ? '确认题目并保存原图' : '重试保存原题图片')
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontSize(UiStyle.BODY_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiStyle.onAction(this.darkMode))
          .backgroundColor(UiStyle.action(this.darkMode))
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(!this.pending && !this.navigationPending && !this.authoritativeStatePending)
          .accessibilityText(!this.textSaveStarted() ?
            '确认全部题目并保存原图' : '重试保存原题图片')
          .onClick(() => { this.saveReview() })
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: this.contentMaxWidth() })
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 10, bottom: 12 })
  }

  build() {
    Navigation() {
      Column() {
        this.ReviewContent()
        this.StatusNotices()
        this.BottomAction()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)
    }
    .title('题目识别复核', {
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
