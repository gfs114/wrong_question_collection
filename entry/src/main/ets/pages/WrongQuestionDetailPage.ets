import { EmptyState } from '../components/EmptyState'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { ResponsiveLayout, WindowSizeClass, WindowSizeObserver } from '../constants/ResponsiveLayout'
import { AccountSessionState } from '../models/AccountSession'
import { WrongQuestionListItem } from '../models/WrongQuestion'
import { AccountSessionService } from '../services/AccountSessionService'
import { CloudQuestionRepository } from '../services/CloudQuestionRepository'
import { ConnectivityPolicy } from '../services/ConnectivityPolicy'
import { AppColors } from '../theme/AppColors'
import { DateUtils } from '../utils/DateUtils'
import { NavigationState } from '../utils/NavigationState'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

@Entry
@Component
struct WrongQuestionDetailPage {
  @State detail: WrongQuestionListItem = new WrongQuestionListItem('', '', '', '', 0, false, '', '',
    new Array<string>(), '', '', '', '')
  @State loading: boolean = true
  @State found: boolean = false
  @State mastered: boolean = false
  @State marking: boolean = false
  @State removing: boolean = false
  @State dialogPending: boolean = false
  @State errorMessage: string = ''
  @State signedIn: boolean = false
  @State offline: boolean = false
  @State syncFailed: boolean = false
  @State accountId: string = ''
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = {
    top: 0, left: 0, right: 0, bottom: 0
  }
  @StorageProp('darkMode') darkMode: boolean = false
  @State windowSizeClass: WindowSizeClass = WindowSizeClass.COMPACT
  private requestToken: number = 0
  private sizeObserver?: WindowSizeObserver

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  aboutToAppear(): void {
    this.sizeObserver = new WindowSizeObserver((windowWidthVp: number): void => {
      this.applyWindowSizeClass(windowWidthVp)
    })
    this.sizeObserver.start(getContext(this))
    this.loadDetail()
  }

  aboutToDisappear(): void {
    if (this.sizeObserver !== undefined) {
      this.sizeObserver.stop()
      this.sizeObserver = undefined
    }
  }

  private applyWindowSizeClass(windowWidthVp: number): void {
    const sizeClass: WindowSizeClass = ResponsiveLayout.classify(windowWidthVp)
    if (sizeClass !== this.windowSizeClass) {
      this.windowSizeClass = sizeClass
    }
  }

  private contentMaxWidth(): number {
    if (this.windowSizeClass === WindowSizeClass.COMPACT) {
      return CONTENT_MAX_WIDTH
    }
    return ResponsiveLayout.EXPANDED_CONTENT_MAX_WIDTH
  }

  private goBack(): void {
    if (this.removing) {
      return
    }
    try {
      this.getUIContext().getRouter().back()
    } catch {
    }
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

  private loadDetail(): void {
    this.requestToken = this.requestToken + 1
    const token: number = this.requestToken
    const wrongId: string = NavigationState.shared().selectedWrongQuestionId
    this.loading = true
    this.found = false
    this.mastered = false
    this.errorMessage = ''
    this.fetchDetail(token, wrongId)
  }

  private async fetchDetail(token: number, wrongId: string): Promise<void> {
    if (wrongId.length === 0) {
      if (token === this.requestToken) {
        this.errorMessage = '未找到所选错题'
        this.loading = false
      }
      return
    }
    const session: AccountSessionState = await AccountSessionService.state(getContext(this))
    if (token !== this.requestToken || wrongId !== NavigationState.shared().selectedWrongQuestionId) {
      return
    }
    this.signedIn = session.signedIn
    this.accountId = session.userId
    if (!this.signedIn) {
      this.errorMessage = '请先登录华为账号后查看错题'
      this.loading = false
      return
    }
    try {
      await CloudQuestionRepository.refresh(this.accountId, getContext(this))
      if (token !== this.requestToken || wrongId !== NavigationState.shared().selectedWrongQuestionId) {
        return
      }
      this.offline = false
      this.syncFailed = false
    } catch (err) {
      if (token !== this.requestToken || wrongId !== NavigationState.shared().selectedWrongQuestionId) {
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
      const detail: WrongQuestionListItem | null =
        await CloudQuestionRepository.cachedWrongDetail(this.accountId, wrongId)
      if (token !== this.requestToken || wrongId !== NavigationState.shared().selectedWrongQuestionId) {
        return
      }
      if (detail === null) {
        this.errorMessage = '该错题不存在或已被移出'
        this.loading = false
        return
      }
      this.detail = detail
      this.mastered = detail.mastered
      this.found = true
      this.loading = false
    } catch {
      if (token !== this.requestToken) {
        return
      }
      this.errorMessage = '错题详情加载失败，请稍后重试'
      this.loading = false
    }
  }

  private markMastered(): void {
    if (!this.found || this.mastered || this.marking || this.removing) {
      return
    }
    if (!this.canMutate()) {
      this.showToast(ConnectivityPolicy.mutationBlockedMessage(this.signedIn, !this.offline))
      return
    }
    this.marking = true
    this.persistMastered(this.detail.id, this.requestToken)
  }

  private async persistMastered(wrongId: string, token: number): Promise<void> {
    try {
      await CloudQuestionRepository.setWrongState(wrongId, 'mastered', getContext(this))
      if (token !== this.requestToken || wrongId !== this.detail.id) {
        return
      }
      this.mastered = true
      this.marking = false
      this.showToast('已标记为掌握')
    } catch {
      if (token !== this.requestToken || wrongId !== this.detail.id) {
        return
      }
      this.marking = false
      this.showToast('标记失败，请检查网络后重试')
    }
  }

  private confirmRemove(): void {
    if (!this.found || this.marking || this.removing || this.dialogPending) {
      return
    }
    if (!this.canMutate()) {
      this.showToast(ConnectivityPolicy.mutationBlockedMessage(this.signedIn, !this.offline))
      return
    }
    this.dialogPending = true
    try {
      this.getUIContext().showAlertDialog({
        title: '移出错题本？',
        message: '确定要将这道题从云端错题本移出吗？',
        autoCancel: false,
        primaryButton: {
          value: '移出',
          action: () => {
            this.dialogPending = false
            this.removeWrongQuestion()
          }
        },
        secondaryButton: {
          value: '取消',
          action: () => {
            this.dialogPending = false
          }
        }
      })
    } catch {
      this.dialogPending = false
      this.showToast('暂时无法打开确认窗口')
    }
  }

  private removeWrongQuestion(): void {
    if (this.removing) {
      return
    }
    this.removing = true
    this.persistRemoval(this.detail.id, this.requestToken)
  }

  private async persistRemoval(wrongId: string, token: number): Promise<void> {
    try {
      await CloudQuestionRepository.setWrongState(wrongId, 'removed', getContext(this))
      if (token !== this.requestToken || wrongId !== this.detail.id) {
        return
      }
      this.removing = false
      this.showToast('已移出错题本')
      this.goBack()
    } catch {
      if (token !== this.requestToken || wrongId !== this.detail.id) {
        return
      }
      this.removing = false
      this.showToast('移出失败，请检查网络后重试')
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  private typeLabel(): string {
    return this.detail.type === 'single_choice' ? '单选题' : '未知题型'
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

          Text('正在加载错题详情')
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
            this.loadDetail()
          }
        })
        .layoutWeight(1)
      } else if (this.found) {
        Scroll() {
          Column({ space: 14 }) {
            Column({ space: 12 }) {
              Row({ space: 8 }) {
                Text(this.typeLabel())
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.colors().brand)

                Text(this.mastered ? '已掌握' : '待复习')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.mastered ? this.colors().successText : this.colors().textCaption)

                Blank()
              }
              .width('100%')

              Text(this.detail.question)
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
              ForEach(this.detail.options, (option: string, index: number) => {
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
              }, (option: string, index: number): string => this.detail.id + '_' + index.toString())
            }
            .width('100%')

            Column({ space: 10 }) {
              Text('正确答案')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().textPrimary)

              Text(this.detail.answer)
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().successText)

              Text('题目解析')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors().textPrimary)
                .margin({ top: 8 })

              Text(this.detail.analysis.length === 0 ? '暂无解析' : this.detail.analysis)
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

            Column({ space: 8 }) {
              Text('题库：' + this.detail.bankName)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textCaption)
              Text('学科：' + this.detail.subject)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textCaption)
              Text('加入时间：' + DateUtils.formatDateTime(this.detail.addTime))
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textCaption)
              if (this.detail.userAnswer.length > 0) {
                Text('你的答案：' + this.detail.userAnswer)
                  .fontSize(BODY_FONT_SIZE)
                  .fontColor(this.colors().textCaption)
              }
              Text('修改将同步到云端，离线时仅可查看缓存')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(this.colors().textCaption)
                .margin({ top: 4 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(20)
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(CARD_RADIUS)
          }
          .width('100%')
          .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 18 })
        }
        .layoutWeight(1)
        .width('100%')
        .constraintSize({ maxWidth: this.contentMaxWidth() })
        .scrollBar(BarState.Off)

        Row({ space: 10 }) {
          Button() {
            Text(this.mastered ? '已掌握' : this.marking ? '正在标记…' : '标记为已掌握')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors().onBrand)
          }
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(48)
          .backgroundColor(this.mastered || this.marking || !this.canMutate() ?
            this.colors().disabled : this.colors().brand)
          .borderRadius(14)
          .enabled(!this.mastered && !this.marking && !this.removing && !this.dialogPending &&
            this.canMutate())
          .onClick(() => {
            this.markMastered()
          })

          Button() {
            Text(this.removing ? '正在移出…' : '移出错题本')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors().error)
          }
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(48)
          .backgroundColor(this.colors().cardBackground)
          .borderRadius(14)
          .enabled(!this.marking && !this.removing && !this.dialogPending && this.canMutate())
          .onClick(() => {
            this.confirmRemove()
          })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.contentMaxWidth() })
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
    .title('错题详情', {
      barStyle: BarStyle.STANDARD
    })
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(false)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
  }
}
