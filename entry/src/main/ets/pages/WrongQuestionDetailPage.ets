import { AppHeader } from '../components/AppHeader'
import { EmptyState } from '../components/EmptyState'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  COLOR_CARD_BG,
  COLOR_DANGER,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_SUCCESS_TEXT,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE
} from '../constants/AppTheme'
import { WrongQuestionListItem } from '../models/WrongQuestion'
import { WrongQuestionService } from '../services/WrongQuestionService'
import { DateUtils } from '../utils/DateUtils'
import { NavigationState } from '../utils/NavigationState'

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
  private requestToken: number = 0

  aboutToAppear(): void {
    this.loadDetail()
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
    try {
      const detail: WrongQuestionListItem | null = await WrongQuestionService.getDetail(wrongId)
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
    this.marking = true
    this.persistMastered(this.detail.id, this.requestToken)
  }

  private async persistMastered(wrongId: string, token: number): Promise<void> {
    try {
      await WrongQuestionService.markMastered(wrongId)
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
      this.showToast('标记失败，请稍后重试')
    }
  }

  private confirmRemove(): void {
    if (!this.found || this.marking || this.removing || this.dialogPending) {
      return
    }
    this.dialogPending = true
    try {
      this.getUIContext().showAlertDialog({
        title: '移出错题本？',
        message: '确定要将这道题移出错题本吗？',
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
      await WrongQuestionService.remove(wrongId)
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
      this.showToast('移出失败，请稍后重试')
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
    Column() {
      AppHeader({
        title: '错题详情',
        showBack: true,
        onBack: () => {
          this.goBack()
        }
      })

      if (this.loading) {
        Column({ space: 14 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(COLOR_PRIMARY)

          Text('正在加载错题详情')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(COLOR_TEXT_CAPTION)
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
                  .fontColor(COLOR_PRIMARY)

                Text(this.mastered ? '已掌握' : '待复习')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.mastered ? COLOR_SUCCESS_TEXT : COLOR_TEXT_CAPTION)

                Blank()
              }
              .width('100%')

              Text(this.detail.question)
                .width('100%')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_TEXT_PRIMARY)
                .lineHeight(28)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(20)
            .backgroundColor(COLOR_CARD_BG)
            .borderRadius(CARD_RADIUS)

            Column({ space: 10 }) {
              ForEach(this.detail.options, (option: string, index: number) => {
                Row({ space: 12 }) {
                  Text(String.fromCharCode(65 + index))
                    .width(36)
                    .height(36)
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(COLOR_PRIMARY)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(COLOR_PAGE_BG)
                    .borderRadius(18)

                  Text(option)
                    .layoutWeight(1)
                    .fontSize(BODY_FONT_SIZE)
                    .fontColor(COLOR_TEXT_PRIMARY)
                    .lineHeight(22)
                }
                .width('100%')
                .padding({ left: 12, right: 14, top: 10, bottom: 10 })
                .backgroundColor(COLOR_CARD_BG)
                .borderRadius(16)
              }, (option: string, index: number): string => this.detail.id + '_' + index.toString())
            }
            .width('100%')

            Column({ space: 10 }) {
              Text('正确答案')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_TEXT_PRIMARY)

              Text(this.detail.answer)
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_SUCCESS_TEXT)

              Text('题目解析')
                .fontSize(SUBTITLE_FONT_SIZE)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_TEXT_PRIMARY)
                .margin({ top: 8 })

              Text(this.detail.analysis.length === 0 ? '暂无解析' : this.detail.analysis)
                .width('100%')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_TEXT_CAPTION)
                .lineHeight(23)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(20)
            .backgroundColor(COLOR_CARD_BG)
            .borderRadius(CARD_RADIUS)

            Column({ space: 8 }) {
              Text('题库：' + this.detail.bankName)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_TEXT_CAPTION)
              Text('学科：' + this.detail.subject)
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_TEXT_CAPTION)
              Text('加入时间：' + DateUtils.formatDateTime(this.detail.addTime))
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_TEXT_CAPTION)
              if (this.detail.userAnswer.length > 0) {
                Text('你的答案：' + this.detail.userAnswer)
                  .fontSize(BODY_FONT_SIZE)
                  .fontColor(COLOR_TEXT_CAPTION)
              }
              Text('所有操作仅影响本机数据')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_TEXT_CAPTION)
                .margin({ top: 4 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(20)
            .backgroundColor(COLOR_CARD_BG)
            .borderRadius(CARD_RADIUS)
          }
          .width('100%')
          .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 18 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)

        Row({ space: 10 }) {
          Button() {
            Text(this.mastered ? '已掌握' : this.marking ? '正在标记…' : '标记为已掌握')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
          }
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(48)
          .backgroundColor(this.mastered || this.marking ? '#8E99AA' : COLOR_PRIMARY)
          .borderRadius(14)
          .enabled(!this.mastered && !this.marking && !this.removing && !this.dialogPending)
          .onClick(() => {
            this.markMastered()
          })

          Button() {
            Text(this.removing ? '正在移出…' : '移出错题本')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_DANGER)
          }
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(48)
          .backgroundColor(COLOR_CARD_BG)
          .borderRadius(14)
          .enabled(!this.marking && !this.removing && !this.dialogPending)
          .onClick(() => {
            this.confirmRemove()
          })
        }
        .width('100%')
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 10, bottom: 14 })
        .backgroundColor(COLOR_PAGE_BG)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_PAGE_BG)
  }
}
