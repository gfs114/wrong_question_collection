import { router } from '@kit.ArkUI'
import { EmptyState } from '../components/EmptyState'
import { SectionTitle } from '../components/SectionTitle'
import { StatRow, StatCell } from '../components/StatRow'
import { WrongQuestionCard } from '../components/WrongQuestionCard'
import {
  BODY_FONT_SIZE,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  TAB_BAR_CLEARANCE,
  themePalette
} from '../constants/AppTheme'
import {
  CHIP_RADIUS,
  EDITORIAL_CARD_GAP,
  HAIRLINE,
  PAGE_TITLE_SIZE
} from '../constants/EditorialStyle'
import { ResponsiveLayout, WindowSizeClass, WindowSizeObserver } from '../constants/ResponsiveLayout'
import { AccountSessionState } from '../models/AccountSession'
import { Statistics } from '../models/Statistics'
import { WrongQuestionSummary } from '../models/WrongQuestion'
import { AccountSessionService } from '../services/AccountSessionService'
import { CloudQuestionRepository } from '../services/CloudQuestionRepository'
import { ConnectivityPolicy } from '../services/ConnectivityPolicy'
import { AppColors } from '../theme/AppColors'
import { DateUtils } from '../utils/DateUtils'
import { NavigationState } from '../utils/NavigationState'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

const WRONG_FEED_TOP_GAP: number = 10

class WrongCardRow {
  left: WrongQuestionSummary
  right: WrongQuestionSummary | null

  constructor(left: WrongQuestionSummary, right: WrongQuestionSummary | null) {
    this.left = left
    this.right = right
  }
}

@Component
export struct WrongQuestionsPage {
  @Prop @Watch('onActiveChanged') active: boolean = false
  @Prop @Watch('onRefreshVersionChanged') refreshVersion: number = 0
  @StorageProp('darkMode') darkMode: boolean = false
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = { top: 0, left: 0, right: 0, bottom: 0 }
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
  @State windowSizeClass: WindowSizeClass = WindowSizeClass.COMPACT
  private hasRequested: boolean = false
  private requestedVersion: number = -1
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
    this.refreshWhenActive()
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

  private pageTopGap(): number {
    return SafeAreaUtils.top(this.safeAreaInsets) + WRONG_FEED_TOP_GAP
  }

  // 编辑风统计：一张纸张卡 + 竖细线分隔；error 只留给「待复习」这个唯一需要行动的数字。
  private statCells(): Array<StatCell> {
    const cells: Array<StatCell> = new Array<StatCell>()
    cells.push(new StatCell('全部错题', this.statistics.wrongCount.toString(), this.colors().textPrimary))
    cells.push(new StatCell('已掌握', this.statistics.masteredCount.toString(), this.colors().textPrimary))
    cells.push(new StatCell('待复习', this.statistics.pendingCount.toString(), this.colors().error))
    return cells
  }

  private wrongRows(): Array<WrongCardRow> {
    const rows: Array<WrongCardRow> = new Array<WrongCardRow>()
    for (let index: number = 0; index < this.items.length; index += 2) {
      const right: WrongQuestionSummary | null =
        index + 1 < this.items.length ? this.items[index + 1] : null
      rows.push(new WrongCardRow(this.items[index], right))
    }
    return rows
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

  // 编辑风学科 chips：选中 = brandSoft + brand，未选中 = 纸底 + 细线描边（不再是实心胶囊）。
  @Builder
  private SubjectChip(label: string, value: string, selected: boolean) {
    Button() {
      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(selected ? this.colors().brand : this.colors().textSecondary)
        .textAlign(TextAlign.Center)
        .maxLines(2)
    }
    .type(ButtonType.Normal)
    .constraintSize({ minHeight: 48 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(selected ? this.colors().brandSoft : this.colors().cardBackground)
    .border({
      width: HAIRLINE,
      color: selected ? this.colors().brandSoft : this.colors().divider
    })
    .borderRadius(CHIP_RADIUS)
    .enabled(!this.loading)
    .accessibilityText('按学科筛选：' + label)
    .accessibilitySelected(selected)
    .onClick(() => {
      this.selectSubject(value)
    })
  }

  @Builder
  private StatusBanner() {
    Row() {
      Text(this.bannerMessage())
        .fontSize(13)
        .fontColor(this.colors().warningText)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(this.colors().warning)
  }

  @Builder
  private WrongCard(item: WrongQuestionSummary) {
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

  @Builder
  private PageTitle() {
    Column({ space: 12 }) {
      Text('错题')
        .fontSize(PAGE_TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .letterSpacing(2)
        .fontColor(this.colors().textPrimary)

      Divider()
        .strokeWidth(HAIRLINE)
        .color(this.colors().divider)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 6 })
  }

  build() {
    Column() {
      Column() {
        this.PageTitle()
      }
      .width('100%')
      .constraintSize({ maxWidth: this.contentMaxWidth() })
      .padding({
        top: this.pageTopGap(),
        left: PAGE_PADDING + SafeAreaUtils.left(this.safeAreaInsets),
        right: PAGE_PADDING + SafeAreaUtils.right(this.safeAreaInsets)
      })

      if (this.loading) {
        Column() {
          if (this.bannerMessage().length > 0) {
            this.StatusBanner()
          }

          Column({ space: 14 }) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color(this.colors().brand)

            Text('正在整理错题')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(this.colors().textCaption)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
      } else if (this.errorMessage.length > 0) {
        Column() {
          if (this.bannerMessage().length > 0) {
            this.StatusBanner()
          }

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
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        List({ space: EDITORIAL_CARD_GAP }) {
          if (this.bannerMessage().length > 0) {
            ListItem() {
              this.StatusBanner()
            }
          }

          ListItem() {
            StatRow({ cells: this.statCells() })
          }

          ListItem() {
            Scroll() {
              Row({ space: 8 }) {
                this.SubjectChip('全部', '', this.selectedSubject.length === 0)

                ForEach(this.subjects, (subject: string) => {
                  this.SubjectChip(subject, subject, this.selectedSubject === subject)
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
              EmptyState({
                glyph: '✓',
                title: '暂无错题',
                description: '做题时可以将不会的题加入错题本',
                fillAvailable: false
              })
            }
          } else if (this.windowSizeClass === WindowSizeClass.EXPANDED) {
            ForEach(this.wrongRows(), (row: WrongCardRow) => {
              ListItem() {
                Row({ space: EDITORIAL_CARD_GAP }) {
                  Column() {
                    this.WrongCard(row.left)
                  }
                  .layoutWeight(1)

                  if (row.right === null) {
                    Column()
                      .layoutWeight(1)
                  } else {
                    Column() {
                      this.WrongCard(row.right)
                    }
                    .layoutWeight(1)
                  }
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              }
            }, (row: WrongCardRow): string => row.left.id)
          } else {
            ForEach(this.items, (item: WrongQuestionSummary) => {
              ListItem() {
                this.WrongCard(item)
              }
            }, (item: WrongQuestionSummary): string => item.id)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .constraintSize({ maxWidth: this.contentMaxWidth() })
        .contentEndOffset(TAB_BAR_CLEARANCE)
        .padding({
          left: PAGE_PADDING + SafeAreaUtils.left(this.safeAreaInsets),
          right: PAGE_PADDING + SafeAreaUtils.right(this.safeAreaInsets)
        })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
