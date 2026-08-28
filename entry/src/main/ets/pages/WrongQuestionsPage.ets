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
import { Statistics } from '../models/Statistics'
import { WrongQuestionFilter, WrongQuestionSummary } from '../models/WrongQuestion'
import { StatisticsService } from '../services/StatisticsService'
import { WrongQuestionService } from '../services/WrongQuestionService'
import { DateUtils } from '../utils/DateUtils'
import { NavigationState } from '../utils/NavigationState'

const PAGE_SIZE: number = 50

@Component
export struct WrongQuestionsPage {
  @Prop @Watch('onActiveChanged') active: boolean = false
  @Prop @Watch('onRefreshVersionChanged') refreshVersion: number = 0
  @State statistics: Statistics = new Statistics(0, 0, 0, 0)
  @State subjects: Array<string> = new Array<string>()
  @State selectedSubject: string = ''
  @State items: Array<WrongQuestionSummary> = new Array<WrongQuestionSummary>()
  @State loading: boolean = false
  @State loadingMore: boolean = false
  @State hasMore: boolean = false
  @State errorMessage: string = ''
  @State navigationPending: boolean = false
  private hasRequested: boolean = false
  private requestedVersion: number = -1
  private requestToken: number = 0
  private nextOffset: number = 0

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
    this.loadingMore = false
    this.hasMore = false
    this.items = new Array<WrongQuestionSummary>()
    this.nextOffset = 0
    this.errorMessage = ''
    this.loadContent(token)
  }

  private async loadContent(token: number): Promise<void> {
    try {
      const statistics: Statistics = await StatisticsService.load()
      const subjects: Array<string> = await WrongQuestionService.listSubjects()
      if (this.selectedSubject.length > 0 && !this.containsSubject(subjects, this.selectedSubject)) {
        this.selectedSubject = ''
      }
      const filter: WrongQuestionFilter = new WrongQuestionFilter(this.selectedSubject)
      const items: Array<WrongQuestionSummary> = await WrongQuestionService.listSummaries(
        filter, PAGE_SIZE + 1, 0)
      if (token !== this.requestToken) {
        return
      }
      this.statistics = statistics
      this.subjects = subjects
      this.items = this.takeVisiblePage(items)
      this.nextOffset = this.items.length
      this.hasMore = items.length > PAGE_SIZE
      this.loading = false
    } catch (err) {
      if (token !== this.requestToken) {
        return
      }
      this.errorMessage = '错题数据加载失败，请稍后重试'
      this.loading = false
    }
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

  private takeVisiblePage(items: Array<WrongQuestionSummary>): Array<WrongQuestionSummary> {
    const page: Array<WrongQuestionSummary> = new Array<WrongQuestionSummary>()
    const count: number = items.length > PAGE_SIZE ? PAGE_SIZE : items.length
    for (let index: number = 0; index < count; index++) {
      page.push(items[index])
    }
    return page
  }

  private mergeUnique(items: Array<WrongQuestionSummary>,
    nextPage: Array<WrongQuestionSummary>): Array<WrongQuestionSummary> {
    const merged: Array<WrongQuestionSummary> = items.slice()
    const ids: Set<string> = new Set<string>()
    for (let index: number = 0; index < items.length; index++) {
      ids.add(items[index].id)
    }
    for (let index: number = 0; index < nextPage.length; index++) {
      const item: WrongQuestionSummary = nextPage[index]
      if (!ids.has(item.id)) {
        ids.add(item.id)
        merged.push(item)
      }
    }
    return merged
  }

  private loadMore(): void {
    if (this.loading || this.loadingMore || !this.hasMore) {
      return
    }
    const token: number = this.requestToken
    const offset: number = this.nextOffset
    this.loadingMore = true
    this.loadMorePage(token, offset)
  }

  private async loadMorePage(token: number, offset: number): Promise<void> {
    try {
      const filter: WrongQuestionFilter = new WrongQuestionFilter(this.selectedSubject)
      const items: Array<WrongQuestionSummary> = await WrongQuestionService.listSummaries(
        filter, PAGE_SIZE + 1, offset)
      if (token !== this.requestToken) {
        return
      }
      const nextPage: Array<WrongQuestionSummary> = this.takeVisiblePage(items)
      this.items = this.mergeUnique(this.items, nextPage)
      this.nextOffset = offset + nextPage.length
      this.hasMore = items.length > PAGE_SIZE
      this.loadingMore = false
    } catch (err) {
      if (token !== this.requestToken) {
        return
      }
      this.loadingMore = false
      this.showToast('加载更多失败，请稍后重试')
    }
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

            if (this.hasMore) {
              ListItem() {
                Button() {
                  Text(this.loadingMore ? '正在加载...' : '加载更多')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                }
                .type(ButtonType.Normal)
                .width('100%')
                .height(48)
                .backgroundColor(COLOR_PRIMARY)
                .borderRadius(16)
                .enabled(!this.loadingMore)
                .onClick(() => {
                  this.loadMore()
                })
              }
            }
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
