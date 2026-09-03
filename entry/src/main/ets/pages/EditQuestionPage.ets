import { QuestionSourceImages } from '../components/QuestionSourceImages'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  themePalette
} from '../constants/AppTheme'
import { AccountSessionState } from '../models/AccountSession'
import { Question } from '../models/Question'
import { QuestionImage } from '../models/QuestionImage'
import { AccountSessionService } from '../services/AccountSessionService'
import { CloudQuestionRepository } from '../services/CloudQuestionRepository'
import { ConnectivityPolicy } from '../services/ConnectivityPolicy'
import { AppColors } from '../theme/AppColors'
import { NavigationState } from '../utils/NavigationState'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

@Entry
@Component
struct EditQuestionPage {
  @State currentQuestion: Question = new Question('', '', '', '', new Array<string>(), '', '')
  @State sourceImages: Array<QuestionImage> = new Array<QuestionImage>()
  @State questionType: string = 'unclassified'
  @State questionText: string = ''
  @State options: Array<string> = new Array<string>()
  @State answer: string = ''
  @State analysis: string = ''
  @State loading: boolean = false
  @State found: boolean = false
  @State pending: boolean = false
  @State navigationPending: boolean = false
  @State errorMessage: string = ''
  @State signedIn: boolean = false
  @State offline: boolean = false
  @State syncFailed: boolean = false
  @State accountId: string = ''
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = {
    top: 0, left: 0, right: 0, bottom: 0
  }
  @StorageProp('darkMode') darkMode: boolean = false
  private requestToken: number = 0

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  aboutToAppear(): void {
    this.loadSelectedQuestion()
  }

  onBackPress(): boolean {
    return this.pending || this.navigationPending
  }

  private bannerMessage(): string {
    if (!this.signedIn) {
      return '未登录：仅可浏览缓存数据，修改需先登录'
    }
    if (this.syncFailed) {
      return '同步失败：正在显示本地缓存'
    }
    if (this.offline) {
      return '离线浏览：当前处于只读状态，仅可查看缓存'
    }
    return ''
  }

  private canMutate(): boolean {
    return ConnectivityPolicy.canMutate(this.signedIn, !this.offline)
  }

  private loadSelectedQuestion(): void {
    if (this.pending || this.navigationPending) {
      return
    }
    this.requestToken = this.requestToken + 1
    const token: number = this.requestToken
    const questionId: string = NavigationState.shared().selectedQuestionId
    this.loading = true
    this.found = false
    this.errorMessage = ''
    this.loadQuestion(token, questionId)
  }

  private async loadQuestion(token: number, questionId: string): Promise<void> {
    if (questionId.length === 0) {
      if (token === this.requestToken) {
        this.loading = false
        this.errorMessage = '未找到要编辑的题目'
      }
      return
    }
    const session: AccountSessionState = await AccountSessionService.state(getContext(this))
    if (token !== this.requestToken || questionId !== NavigationState.shared().selectedQuestionId) {
      return
    }
    this.signedIn = session.signedIn
    this.accountId = session.userId
    if (!this.signedIn) {
      this.loading = false
      this.errorMessage = '请先登录华为账号后编辑题目'
      return
    }
    try {
      await CloudQuestionRepository.refresh(this.accountId, getContext(this))
      if (token !== this.requestToken || questionId !== NavigationState.shared().selectedQuestionId) {
        return
      }
      this.offline = false
      this.syncFailed = false
    } catch (err) {
      if (token !== this.requestToken || questionId !== NavigationState.shared().selectedQuestionId) {
        return
      }
      if (err instanceof Error && ConnectivityPolicy.isOfflineError(err)) {
        this.offline = true
        this.syncFailed = false
      } else {
        this.offline = false
        this.syncFailed = true
      }
    }
    try {
      const question: Question | null =
        await CloudQuestionRepository.cachedQuestion(this.accountId, questionId)
      if (token !== this.requestToken || questionId !== NavigationState.shared().selectedQuestionId) {
        return
      }
      if (question === null) {
        this.loading = false
        this.errorMessage = '该题目不存在或已被删除'
        return
      }
      this.currentQuestion = question
      this.sourceImages = question.images.slice()
      this.questionType = question.type
      this.questionText = question.question
      this.options = question.options.slice()
      this.answer = question.answer
      this.analysis = question.analysis
      this.loading = false
      this.found = true
    } catch {
      if (token !== this.requestToken || questionId !== NavigationState.shared().selectedQuestionId) {
        return
      }
      this.loading = false
      this.errorMessage = '题目加载失败，请稍后重试'
    }
  }

  private updateOption(index: number, value: string): void {
    if (index < 0 || index >= this.options.length || this.pending || this.navigationPending) {
      return
    }
    const nextOptions: Array<string> = this.options.slice()
    nextOptions[index] = value
    this.options = nextOptions
  }

  private selectType(value: string): void {
    if (this.pending || this.navigationPending) {
      return
    }
    this.questionType = value
  }

  private async saveQuestion(): Promise<void> {
    if (this.pending || this.navigationPending || this.loading || !this.found) {
      return
    }
    if (this.questionText.trim().length === 0) {
      this.showToast('题干不能为空')
      return
    }
    const session: AccountSessionState = await AccountSessionService.state(getContext(this))
    this.signedIn = session.signedIn
    this.accountId = session.userId
    if (!this.signedIn) {
      this.showToast('未登录，无法保存修改，请先登录')
      return
    }
    if (this.offline) {
      this.showToast('离线浏览：当前处于只读状态，无法保存')
      return
    }
    this.pending = true
    const token: number = this.requestToken
    const questionId: string = this.currentQuestion.id
    const updatedQuestion: Question = new Question(
      questionId,
      this.currentQuestion.bankId,
      this.questionType,
      this.questionText,
      this.options.slice(),
      this.answer,
      this.analysis,
      this.currentQuestion.sourcePageStart,
      this.currentQuestion.sourcePageEnd,
      this.currentQuestion.reviewState,
      this.sourceImages.slice())
    try {
      await CloudQuestionRepository.updateQuestion(updatedQuestion, getContext(this))
      if (token !== this.requestToken || questionId !== NavigationState.shared().selectedQuestionId) {
        return
      }
      this.currentQuestion = updatedQuestion
      this.pending = false
      this.showToast('修改已保存')
      this.navigationPending = true
      try {
        this.getUIContext().getRouter().back()
      } catch {
        this.navigationPending = false
        this.errorMessage = '修改已保存，请重试返回题目详情'
      }
    } catch {
      if (token !== this.requestToken || questionId !== NavigationState.shared().selectedQuestionId) {
        return
      }
      this.pending = false
      this.showToast('保存失败，请检查网络后重试')
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  build() {
    Navigation() {
      Column() {
        if (this.bannerMessage().length > 0) {
        Row() {
          Text(this.bannerMessage())
            .fontSize(13)
            .fontColor(this.colors().warningText)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.colors().warning)
      }

      if (this.loading) {
        Column({ space: 14 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(this.colors().brand)

          Text('正在加载题目')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMessage.length > 0 && !this.found) {
        Column({ space: 18 }) {
          Text(this.errorMessage)
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)
            .textAlign(TextAlign.Center)

          Button('重新加载')
            .height(44)
            .fontColor(this.colors().onBrand)
            .backgroundColor(this.colors().brand)
            .onClick(() => {
              this.loadSelectedQuestion()
            })
        }
        .layoutWeight(1)
        .width('100%')
        .padding(PAGE_PADDING)
        .justifyContent(FlexAlign.Center)
      } else if (this.found) {
        Scroll() {
          Column({ space: 14 }) {
            QuestionSourceImages({ images: this.sourceImages })

            Column({ space: 12 }) {
              Text('题型')
                .width('100%')
                .fontSize(BODY_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().textPrimary)

              Row({ space: 8 }) {
                Button('单选')
                  .layoutWeight(1)
                  .height(38)
                  .fontColor(this.questionType === 'single_choice' ?
                    this.colors().onBrand : this.colors().brand)
                  .backgroundColor(this.questionType === 'single_choice' ?
                    this.colors().brand : this.colors().chipBackground)
                  .enabled(!this.pending && !this.navigationPending)
                  .onClick(() => {
                    this.selectType('single_choice')
                  })

                Button('填空')
                  .layoutWeight(1)
                  .height(38)
                  .fontColor(this.questionType === 'fill_blank' ?
                    this.colors().onBrand : this.colors().brand)
                  .backgroundColor(this.questionType === 'fill_blank' ?
                    this.colors().brand : this.colors().chipBackground)
                  .enabled(!this.pending && !this.navigationPending)
                  .onClick(() => {
                    this.selectType('fill_blank')
                  })

                Button('解答')
                  .layoutWeight(1)
                  .height(38)
                  .fontColor(this.questionType === 'short_answer' ?
                    this.colors().onBrand : this.colors().brand)
                  .backgroundColor(this.questionType === 'short_answer' ?
                    this.colors().brand : this.colors().chipBackground)
                  .enabled(!this.pending && !this.navigationPending)
                  .onClick(() => {
                    this.selectType('short_answer')
                  })

                Button('待确认')
                  .layoutWeight(1)
                  .height(38)
                  .fontColor(this.questionType === 'unclassified' ?
                    this.colors().onBrand : this.colors().brand)
                  .backgroundColor(this.questionType === 'unclassified' ?
                    this.colors().brand : this.colors().chipBackground)
                  .enabled(!this.pending && !this.navigationPending)
                  .onClick(() => {
                    this.selectType('unclassified')
                  })
              }
              .width('100%')

              TextArea({ placeholder: '请输入题干', text: this.questionText })
                .width('100%')
                .height(112)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textPrimary)
                .backgroundColor(this.colors().inputBackground)
                .enabled(!this.pending && !this.navigationPending)
                .onChange((value: string) => {
                  this.questionText = value
                })

              ForEach(this.options, (option: string, index: number) => {
                TextInput({ placeholder: '选项 ' + String.fromCharCode(65 + index), text: option })
                  .width('100%')
                  .height(46)
                  .fontSize(BODY_FONT_SIZE)
                  .fontColor(this.colors().textPrimary)
                  .backgroundColor(this.colors().inputBackground)
                  .enabled(!this.pending && !this.navigationPending)
                  .onChange((value: string) => {
                    this.updateOption(index, value)
                  })
              }, (option: string, index: number): string =>
                this.currentQuestion.id + '_option_' + index.toString())

              TextInput({ placeholder: '答案（选填）', text: this.answer })
                .width('100%')
                .height(46)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textPrimary)
                .backgroundColor(this.colors().inputBackground)
                .enabled(!this.pending && !this.navigationPending)
                .onChange((value: string) => {
                  this.answer = value
                })

              TextArea({ placeholder: '解析（选填）', text: this.analysis })
                .width('100%')
                .height(100)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textPrimary)
                .backgroundColor(this.colors().inputBackground)
                .enabled(!this.pending && !this.navigationPending)
                .onChange((value: string) => {
                  this.analysis = value
                })
            }
            .width('100%')
            .padding(18)
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(CARD_RADIUS)

            if (this.errorMessage.length > 0) {
              Text(this.errorMessage)
                .width('100%')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().error)
            }
          }
          .width('100%')
          .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 18 })
        }
        .layoutWeight(1)
        .width('100%')
        .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
        .scrollBar(BarState.Off)

        Button('保存修改')
          .width('100%')
          .height(50)
          .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
          .margin({
            left: PAGE_PADDING,
            right: PAGE_PADDING,
            top: 10,
            bottom: 14 + SafeAreaUtils.bottom(this.safeAreaInsets)
          })
          .fontSize(BODY_FONT_SIZE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().onBrand)
          .backgroundColor(this.pending || this.navigationPending || !this.canMutate() ?
            this.colors().disabled : this.colors().brand)
          .borderRadius(14)
          .enabled(!this.pending && !this.navigationPending && this.canMutate())
          .onClick(() => {
            this.saveQuestion()
          })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
    }
    .title('编辑题目', {
      barStyle: BarStyle.STANDARD
    })
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(false)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
  }
}
