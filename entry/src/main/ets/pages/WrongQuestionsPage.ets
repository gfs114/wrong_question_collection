import { router } from '@kit.ArkUI'
import { AppHeader } from '../components/AppHeader'
import { EmptyState } from '../components/EmptyState'
import { SectionTitle } from '../components/SectionTitle'
import { StatCard } from '../components/StatCard'
import { WrongQuestionCard } from '../components/WrongQuestionCard'
import {
  BODY_FONT_SIZE,
  CARD_GAP,
  COLOR_DANGER,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_SUCCESS_TEXT,
  COLOR_TEXT_CAPTION,
  PAGE_PADDING
} from '../constants/AppTheme'
import { AccountSessionState } from '../models/AccountSession'
import { Statistics } from '../models/Statistics'
import { WrongQuestionSummary } from '../models/WrongQuestion'
import { AccountSessionService } from '../services/AccountSessionService'
import { CloudQuestionRepository } from '../services/CloudQuestionRepository'
import { ConnectivityPolicy } from '../services/ConnectivityPolicy'
import { DateUtils } from '../utils/DateUtils'
import { NavigationState } from '../utils/NavigationState'

@Component
export struct WrongQuestionsPage {
  @Prop @Watch('onActiveChanged') active: boolean = false
  @Prop @Watch('onRefreshVersionChanged') refreshVersion: number = 0
  @State statistics: Statistics = new Statistics(0, 0, 0, 0)
  @State subjects: Array<string> = new Array<string>()
  @State selectedSubject: string = ''
  @State items: Array<WrongQuestionSummary> = new Array<WrongQuestionSummary>()
  @State loading: boolean = false
  @State errorMessage: string = ''
  @State navigationPending: boolean = false
  @State signedIn: boolean = false
  @State offline: boolean = false
  @State syncFailed: boolean = false
  @State accountId: string = ''
  private hasRequested: boolean = false
  private requestedVersion: number = -1
  private requestToken: number = 0

  aboutToAppear(): void {
    this.refreshWhenActive()
  }

  onActiveChanged(): void {
    this.refreshWhenActive()
  }

  onRefreshVersionChanged(): void {
    this.refreshWhenActive()
  }

  private refreshWhenActive(): void {
    if (!this.active) {
      this.hasRequested = false
      this.requestedVersion = -1
      return
    }
    if (this.hasRequested && this.requestedVersion === this.refreshVersion) {
      return
    }
    this.hasRequested = true
    this.requestedVersion = this.refreshVersion
    this.requestToken = this.requestToken + 1
    const token: number = this.requestToken
    this.loading = true
    this.items = new Array<WrongQuestionSummary>()
    this.errorMessage = ''
    this.loadContent(token)
  }

  private async loadContent(token: number): Promise<void> {
    const session: AccountSessionState = await AccountSessionService.state(getContext(this))
    if (token !== this.requestToken) {
      return
    }
    this.signedIn = session.signedIn
    this.accountId = session.userId
    if (!this.signedIn) {
      this.statistics = new Statistics(0, 0, 0, 0)
      this.subjects = new Array<string>()
      this.items = new Array<WrongQuestionSummary>()
      this.loading = false
      return
    }
    try {
      await CloudQuestionRepository.refresh(this.accountId, getContext(this))
      if (token !== this.requestToken) {
        return
      }
      this.offline = false
      this.syncFailed = false
    } catch (err) {
      if (token !== this.requestToken) {
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
      const statistics: Statistics = await CloudQuestionRepository.statistics(this.accountId)
      const items: Array<WrongQuestionSummary> =
        await CloudQuestionRepository.listCachedWrongQuestions(this.accountId)
      const subjects: Array<string> = this.deriveSubjects(items)
      if (token !== this.requestToken) {
        return
      }
      if (this.selectedSubject.length > 0 && !this.containsSubject(subjects, this.selectedSubject)) {
        this.selectedSubject = ''
      }
      this.statistics = statistics
      this.subjects = subjects
      this.items = this.filterBySubject(items)
      this.loading = false
    } catch (err) {
      if (token !== this.requestToken) {
        return
      }
      this.errorMessage = '错题数据加载失败，请稍后重试'
      this.loading = false
    }
  }

  private deriveSubjects(items: Array<WrongQuestionSummary>): Array<string> {
    const subjects: Array<string> = new Array<string>()
    for (let index: number = 0; index < items.length; index++) {
      const subject: string = items[index].subject
      if (subject.length > 0 && !this.containsSubject(subjects, subject)) {
        subjects.push(subject)
      }
    }
    subjects.sort()
    return subjects
  }

  private filterBySubject(items: Array<WrongQuestionSummary>): Array<WrongQuestionSummary> {
    if (this.selectedSubject.length === 0) {
      return items.slice()
    }
    const filtered: Array<WrongQuestionSummary> = new Array<WrongQuestionSummary>()
    for (let index: number = 0; index < items.length; index++) {
      if (items[index].subject === this.selectedSubject) {
        filtered.push(items[index])
      }
    }
    return filtered
  }

  private retry(): void {
    this.hasRequested = false
    this.refreshWhenActive()
  }

  private containsSubject(subjects: Array<string>, expected: string): boolean {
    for (let index: number = 0; index < subjects.length; index++) {
      if (subjects[index] === expected) {
        return true
      }
    }
    return false
  }

  private selectSubject(subject: string): void {
    if (this.selectedSubject === subject || this.loading) {
      return
    }
    this.selectedSubject = subject
    this.hasRequested = false
    this.refreshWhenActive()
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

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  private openWrongQuestion(wrongId: string): void {
    if (this.navigationPending) {
      return
    }
    this.navigationPending = true
    NavigationState.shared().selectWrongQuestion(wrongId)
    const options: router.RouterOptions = {
      url: 'pages/WrongQuestionDetailPage'
    }
    this.getUIContext().getRouter().pushUrl(options).catch(() => {
      this.showToast('错题详情暂不可用')
    }).finally(() => {
      this.navigationPending = false
    })
  }

  build() {
    Column() {
      AppHeader({ title: '错题收集' })

      if (this.bannerMessage().length > 0) {
        Row() {
          Text(this.bannerMessage())
            .fontSize(13)
            .fontColor('#8A5A00')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor('#FFF4D6')
      }

      if (this.loading) {
        Column({ space: 14 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(COLOR_PRIMARY)

          Text('正在整理错题')
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
            this.retry()
          }
        })
        .layoutWeight(1)
      } else {
        List({ space: CARD_GAP }) {
          ListItem() {
            Grid() {
              GridItem() {
                StatCard({
                  label: '全部错题',
                  value: this.statistics.wrongCount,
                  glyph: '全',
                  accentColor: COLOR_PRIMARY
                })
              }

              GridItem() {
                StatCard({
                  label: '已掌握',
                  value: this.statistics.masteredCount,
                  glyph: '✓',
                  accentColor: COLOR_SUCCESS_TEXT
                })
              }

              GridItem() {
                StatCard({
                  label: '待复习',
                  value: this.statistics.pendingCount,
                  glyph: '复',
                  accentColor: COLOR_DANGER
                })
              }
            }
            .columnsTemplate('1fr 1fr 1fr')
            .columnsGap(8)
            .height(112)
          }

          ListItem() {
            Scroll() {
              Row({ space: 8 }) {
                Button() {
                  Text('全部')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.selectedSubject.length === 0 ? '#FFFFFF' : COLOR_TEXT_CAPTION)
                }
                .type(ButtonType.Normal)
                .height(40)
                .padding({ left: 18, right: 18 })
                .backgroundColor(this.selectedSubject.length === 0 ? COLOR_PRIMARY : '#FFFFFF')
                .borderRadius(20)
                .onClick(() => {
                  this.selectSubject('')
                })

                ForEach(this.subjects, (subject: string) => {
                  Button() {
                    Text(subject)
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.selectedSubject === subject ? '#FFFFFF' : COLOR_TEXT_CAPTION)
                  }
                  .type(ButtonType.Normal)
                  .height(40)
                  .padding({ left: 18, right: 18 })
                  .backgroundColor(this.selectedSubject === subject ? COLOR_PRIMARY : '#FFFFFF')
                  .borderRadius(20)
                  .onClick(() => {
                    this.selectSubject(subject)
                  })
                }, (subject: string): string => subject)
              }
            }
            .width('100%')
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
          }

          ListItem() {
            SectionTitle({
              title: this.selectedSubject.length === 0 ? '最近错题' : this.selectedSubject + '错题',
              detail: this.items.length.toString() + ' 道',
              showDetail: true
            })
          }

          if (this.items.length === 0) {
            ListItem() {
              Column() {
                EmptyState({
                  glyph: '✓',
                  title: '暂无错题',
                  description: '做题时可以将不会的题加入错题本'
                })
              }
              .width('100%')
              .height(260)
            }
          } else {
            ForEach(this.items, (item: WrongQuestionSummary) => {
              ListItem() {
                WrongQuestionCard({
                  subject: item.subject,
                  bankName: item.bankName,
                  questionText: item.question,
                  mastered: item.mastered,
                  addTimeText: DateUtils.formatDate(item.addTime),
                  onOpen: () => {
                    this.openWrongQuestion(item.id)
                  }
                })
              }
            }, (item: WrongQuestionSummary): string => item.id)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: PAGE_PADDING })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_PAGE_BG)
  }
}
