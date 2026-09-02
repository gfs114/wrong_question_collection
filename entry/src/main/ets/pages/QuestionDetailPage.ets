import { router } from '@kit.ArkUI'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { AppHeader } from '../components/AppHeader'
import { EmptyState } from '../components/EmptyState'
import { QuestionSourceImages } from '../components/QuestionSourceImages'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { AccountSessionState } from '../models/AccountSession'
import { Question } from '../models/Question'
import { AccountSessionService } from '../services/AccountSessionService'
import { CloudQuestionRepository } from '../services/CloudQuestionRepository'
import { ConnectivityPolicy } from '../services/ConnectivityPolicy'
import { AppColors } from '../theme/AppColors'
import { NavigationState } from '../utils/NavigationState'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

@Entry
@Component
struct QuestionDetailPage {
  @State currentQuestion: Question = new Question('', '', '', '', new Array<string>(), '', '')
  @State loading: boolean = false
  @State found: boolean = false
  @State isWrong: boolean = false
  @State adding: boolean = false
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

  onPageShow(): void {
    this.loadCurrentQuestion()
    this.logEasySplitState()
  }

  private logEasySplitState(): void {
    try {
      if (this.getUIContext().isEasySplit()) {
        hilog.info(0x0000, 'WQC_EASYGO', 'QuestionDetailPage is running in easy split mode')
      }
    } catch {
    }
  }

  private goBack(): void {
    if (this.navigationPending || this.adding) {
      return
    }
    this.getUIContext().getRouter().back()
  }

  private bannerMessage(): string {
    if (!this.signedIn) {
      return '未登录：仅可浏览缓存数据，修改需先登录'
    }
    if (this.syncFailed) {
      return '同步失败：正在显示本地缓存'
    }
    if (this.offline) {
      return '离线浏览：当前仅可查看缓存，修改需联网'
    }
    return ''
  }

  private canMutate(): boolean {
    return ConnectivityPolicy.canMutate(this.signedIn, !this.offline)
  }

  private openEditor(): void {
    if (this.navigationPending || this.loading || this.adding || !this.found) {
      return
    }
    const questionId: string = NavigationState.shared().selectedQuestionId
    if (questionId.length === 0 || questionId !== this.currentQuestion.id) {
      this.showToast('未找到要编辑的题目')
      return
    }
    this.navigationPending = true
    const options: router.RouterOptions = {
      url: 'pages/EditQuestionPage'
    }
    this.getUIContext().getRouter().pushUrl(options).catch(() => {
      this.showToast('题目编辑暂不可用')
    }).finally(() => {
      this.navigationPending = false
    })
  }

  private loadCurrentQuestion(): void {
    this.requestToken = this.requestToken + 1
    const token: number = this.requestToken
    const questionId: string = NavigationState.shared().selectedQuestionId
    this.loading = true
    this.found = false
    this.isWrong = false
    this.adding = false
    this.errorMessage = ''
    this.loadQuestion(token, questionId)
  }

  private async loadQuestion(token: number, questionId: string): Promise<void> {
    if (questionId.length === 0) {
      if (token === this.requestToken) {
        this.errorMessage = '未找到所选题目'
        this.loading = false
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
      this.errorMessage = '请先登录华为账号后查看题目'
      this.loading = false
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
        this.errorMessage = '该题目不存在或已被删除'
        this.loading = false
        return
      }
      const isWrong: boolean = await CloudQuestionRepository.containsWrong(this.accountId, questionId)
      if (token !== this.requestToken || questionId !== NavigationState.shared().selectedQuestionId) {
        return
      }
      this.currentQuestion = question
      this.isWrong = isWrong
      this.found = true
      this.loading = false
    } catch {
      if (token !== this.requestToken || questionId !== NavigationState.shared().selectedQuestionId) {
        return
      }
      this.errorMessage = '题目详情加载失败，请稍后重试'
      this.loading = false
    }
  }

  private canMove(delta: number): boolean {
    const state: NavigationState = NavigationState.shared()
    const nextIndex: number = state.questionIndex + delta
    return nextIndex >= 0 && nextIndex < state.orderedIds.length
  }

  private move(delta: number): void {
    if (this.loading || this.adding || this.navigationPending || !this.canMove(delta)) {
      return
    }
    NavigationState.shared().moveQuestion(delta)
    this.loadCurrentQuestion()
  }

  private addToWrongQuestions(): void {
    if (this.adding || this.navigationPending || this.isWrong || !this.found) {
      return
    }
    if (!this.canMutate()) {
      this.showToast(ConnectivityPolicy.mutationBlockedMessage(this.signedIn, !this.offline))
      return
    }
    this.adding = true
    const token: number = this.requestToken
    const questionId: string = this.currentQuestion.id
    this.addWrongQuestion(token, questionId)
  }

  private async addWrongQuestion(token: number, questionId: string): Promise<void> {
    try {
      await CloudQuestionRepository.setWrongState(questionId, 'pending', getContext(this))
      if (token !== this.requestToken || questionId !== NavigationState.shared().selectedQuestionId) {
        return
      }
      this.isWrong = true
      this.adding = false
      this.showToast('已加入错题本')
    } catch {
      if (token !== this.requestToken || questionId !== NavigationState.shared().selectedQuestionId) {
        return
      }
      this.adding = false
      this.showToast('加入错题失败，请检查网络后重试')
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  build() {
    Column() {
      AppHeader({
        title: '题目详情',
        showBack: true,
        onBack: () => {
          this.goBack()
        }
      })

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

          Text('正在加载题目详情')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMessage.length > 0) {
        EmptyState({
          glyph: '!',
          title: '加载失败',
          description: this.errorMessage,
          actionLabel: '重新加载',
          showAction: true,
          onAction: () => {
            this.loadCurrentQuestion()
          }
        })
        .layoutWeight(1)
      } else if (this.found) {
        Scroll() {
          Column({ space: 14 }) {
            QuestionSourceImages({
              images: this.currentQuestion.images
            })

            Column({ space: 14 }) {
              Text(this.currentQuestion.getTypeLabel())
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.colors().brand)

              Text(this.currentQuestion.question)
                .width('100%')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().textPrimary)
                .lineHeight(28)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(20)
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(CARD_RADIUS)

            Column({ space: 10 }) {
              ForEach(this.currentQuestion.options, (option: string, index: number) => {
                Row({ space: 12 }) {
                  Text(String.fromCharCode(65 + index))
                    .width(36)
                    .height(36)
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.colors().brand)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(this.colors().pageBackground)
                    .borderRadius(18)

                  Text(option)
                    .layoutWeight(1)
                    .fontSize(BODY_FONT_SIZE)
                    .fontColor(this.colors().textPrimary)
                    .lineHeight(22)
                }
                .width('100%')
                .padding({ left: 12, right: 14, top: 10, bottom: 10 })
                .backgroundColor(this.colors().cardBackground)
                .borderRadius(16)
              }, (option: string, index: number): string => this.currentQuestion.id + '_' + index.toString())
            }
            .width('100%')

            Column({ space: 10 }) {
              Text('正确答案')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().textPrimary)

              Text(this.currentQuestion.answer.length === 0 ? '未填写' : this.currentQuestion.answer)
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().successText)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(20)
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(CARD_RADIUS)

            Column({ space: 10 }) {
              Text('题目解析')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().textPrimary)

              Text(this.currentQuestion.analysis.length === 0 ? '暂无解析' : this.currentQuestion.analysis)
                .width('100%')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textCaption)
                .lineHeight(23)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(20)
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(CARD_RADIUS)

            Button('编辑题目')
              .width('100%')
              .height(48)
              .fontSize(BODY_FONT_SIZE)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors().onBrand)
              .backgroundColor(this.colors().brand)
              .borderRadius(14)
              .enabled(!this.navigationPending && !this.adding)
              .onClick(() => {
                this.openEditor()
              })
          }
          .width('100%')
          .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 18 })
        }
        .layoutWeight(1)
        .width('100%')
        .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
        .scrollBar(BarState.Off)

        Row({ space: 8 }) {
          Button() {
            Text('上一题')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.canMove(-1) && !this.adding ? this.colors().brand : this.colors().textCaption)
          }
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(48)
          .backgroundColor(this.colors().cardBackground)
          .borderRadius(14)
          .enabled(this.canMove(-1) && !this.adding)
          .onClick(() => {
            this.move(-1)
          })

          Button() {
            Text(this.isWrong ? '已加入错题' : this.adding ? '正在加入…' : '加入错题')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors().onBrand)
          }
          .type(ButtonType.Normal)
          .layoutWeight(1.35)
          .height(48)
          .backgroundColor(this.isWrong || this.adding ? this.colors().disabled : this.colors().brand)
          .borderRadius(14)
          .enabled(!this.isWrong && !this.adding && this.canMutate())
          .onClick(() => {
            this.addToWrongQuestions()
          })

          Button() {
            Text('下一题')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.canMove(1) && !this.adding ? this.colors().brand : this.colors().textCaption)
          }
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(48)
          .backgroundColor(this.colors().cardBackground)
          .borderRadius(14)
          .enabled(this.canMove(1) && !this.adding)
          .onClick(() => {
            this.move(1)
          })
        }
        .width('100%')
        .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
        .padding({
          left: PAGE_PADDING,
          right: PAGE_PADDING,
          top: 10,
          bottom: 14 + SafeAreaUtils.bottom(this.safeAreaInsets)
        })
        .backgroundColor(this.colors().pageBackground)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
