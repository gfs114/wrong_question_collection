import { EmptyState } from '../components/EmptyState'
import { HomeOverviewCard } from '../components/HomeOverviewCard'
import { HomeRecentSection } from '../components/HomeRecentSection'
import {
  BODY_FONT_SIZE,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  TAB_BAR_CLEARANCE,
  themePalette
} from '../constants/AppTheme'
import {
  EDITORIAL_SECTION_GAP,
  HAIRLINE
} from '../constants/EditorialStyle'
import { ResponsiveLayout, WindowSizeClass, WindowSizeObserver } from '../constants/ResponsiveLayout'
import { AccountSessionState } from '../models/AccountSession'
import { HomeDashboardSnapshot } from '../models/HomeDashboard'
import { QuestionBankSummary } from '../models/QuestionBank'
import { Statistics } from '../models/Statistics'
import { WrongQuestionSummary } from '../models/WrongQuestion'
import { AccountSessionService } from '../services/AccountSessionService'
import { CloudQuestionRepository } from '../services/CloudQuestionRepository'
import { ConnectivityPolicy } from '../services/ConnectivityPolicy'
import { AppColors } from '../theme/AppColors'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

/**
 * 首页顶部呼吸间距（vp）。
 * 首页在沉浸式全屏（setWindowLayoutFullScreen）下没有 Navigation 标题，内容直接从窗口顶端开始，
 * 所以顶部让位由真实窗口避让区（EntryAbility 发布的 safeAreaInsets）提供，
 * 这里只是避让区之下的一点编辑风留白 —— 换机型、换窗口模式都会自动跟随。
 */
const HOME_FEED_TOP_GAP: number = 10

/** 报头标题「今日」的字号；本地星期表避免引入新依赖。 */
const MASTHEAD_TITLE_SIZE: number = 30
const WEEKDAYS: Array<string> = ['日', '一', '二', '三', '四', '五', '六']

@Component
export struct HomePage {
  @Prop @Watch('onActiveChanged') active: boolean = false
  @Prop @Watch('onRefreshVersionChanged') refreshVersion: number = 0
  @StorageProp('darkMode') darkMode: boolean = false
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = { top: 0, left: 0, right: 0, bottom: 0 }
  @State dashboard: HomeDashboardSnapshot = new HomeDashboardSnapshot(
    new Statistics(0, 0, 0, 0), new Array<QuestionBankSummary>(), new Array<WrongQuestionSummary>())
  @State loading: boolean = false
  @State errorMessage: string = ''
  @State signedIn: boolean = false
  @State offline: boolean = false
  @State syncFailed: boolean = false
  @State accountId: string = ''
  @Prop syncLabel: string = '本地模式'
  @State windowSizeClass: WindowSizeClass = WindowSizeClass.COMPACT
  onSelectTab: (index: number) => void = () => {
  }
  onStartImport: () => void = () => {
  }
  onStartReview: () => void = () => {
  }
  onOpenAiSettings: () => void = () => {
  }
  private hasRequested: boolean = false
  private requestedVersion: number = -1
  private requestToken: number = 0
  private sizeObserver?: WindowSizeObserver

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  // 顶部留白 = 真实窗口避让区（状态栏 / 挖孔）+ 编辑风呼吸间距。
  private topGap(): number {
    return SafeAreaUtils.top(this.safeAreaInsets) + HOME_FEED_TOP_GAP
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
    this.errorMessage = ''
    this.loadDashboard(token)
  }

  private async loadDashboard(token: number): Promise<void> {
    const session: AccountSessionState = await AccountSessionService.state(getContext(this))
    if (token !== this.requestToken) {
      return
    }
    this.signedIn = session.signedIn
    this.accountId = session.userId
    if (!this.signedIn) {
      this.dashboard = new HomeDashboardSnapshot(
        new Statistics(0, 0, 0, 0), new Array<QuestionBankSummary>(),
        new Array<WrongQuestionSummary>())
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
      const banks: Array<QuestionBankSummary> =
        await CloudQuestionRepository.listCachedBanks(this.accountId)
      const wrongQuestions: Array<WrongQuestionSummary> =
        await CloudQuestionRepository.listCachedWrongQuestions(this.accountId)
      if (token !== this.requestToken) {
        return
      }
      this.dashboard = new HomeDashboardSnapshot(statistics, banks, wrongQuestions)
      this.loading = false
    } catch (err) {
      if (token !== this.requestToken) {
        return
      }
      this.errorMessage = '首页数据加载失败，请稍后重试'
      this.loading = false
    }
  }

  private retry(): void {
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

  private bankLabels(): Array<string> {
    const labels: Array<string> = new Array<string>()
    for (let index: number = 0; index < this.dashboard.recentBanks.length; index++) {
      const bank: QuestionBankSummary = this.dashboard.recentBanks[index]
      labels.push(bank.bankName + ' · ' + bank.questionCount.toString() + ' 题')
    }
    return labels
  }

  private wrongQuestionLabels(): Array<string> {
    const labels: Array<string> = new Array<string>()
    for (let index: number = 0; index < this.dashboard.recentWrongQuestions.length; index++) {
      const item: WrongQuestionSummary = this.dashboard.recentWrongQuestions[index]
      labels.push(item.subject + ' · ' + item.question)
    }
    return labels
  }

  private hasLearningData(): boolean {
    return this.dashboard.statistics.bankCount > 0 || this.dashboard.statistics.wrongCount > 0
  }

  // 本地日期行：形如「9 月 10 日 · 星期三」，只用本机时钟与本地星期表。
  private todayLabel(): string {
    const now: Date = new Date()
    return (now.getMonth() + 1).toString() + ' 月 ' + now.getDate().toString() + ' 日 · 星期' +
      WEEKDAYS[now.getDay()]
  }

  // 报头：左侧「今日」大号字 + 日期行，右侧同步状态胶囊，下方一条细线收口。
  @Builder
  private Masthead() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 4 }) {
          Text('今日')
            .fontSize(MASTHEAD_TITLE_SIZE)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(2)
            .fontColor(this.colors().textPrimary)

          Text(this.todayLabel())
            .fontSize(13)
            .letterSpacing(1)
            .fontColor(this.colors().textCaption)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.syncLabel)
          .fontSize(11)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.colors().brand)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.colors().brandSoft)
          .borderRadius(11)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Divider()
        .strokeWidth(HAIRLINE)
        .color(this.colors().divider)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private QuickEntry(symbol: Resource, label: string, action: () => void) {
    Column({ space: 6 }) {
      Stack() {
        Column()
          .width(48)
          .height(48)
          .backgroundColor(this.colors().brandSoft)
          .borderRadius(14)

        SymbolGlyph(symbol)
          .fontSize(22)
          .fontColor([this.colors().brand])
      }
      .width(48)
      .height(48)

      Text(label)
        .fontSize(12)
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.colors().textSecondary)
    }
    .layoutWeight(1)
    .constraintSize({ minHeight: 80 })
    .onClick(() => {
      action()
    })
    .accessibilityText(label)
  }

  // 快捷入口只保留三个真实目的地；导入统一由底栏中间动作承担，空数据时另有情境化引导。
  @Builder
  private QuickEntryRow() {
    Row({ space: 12 }) {
      this.QuickEntry($r('sys.symbol.wand_and_stars'), 'AI 设置', () => {
        this.onOpenAiSettings()
      })
      this.QuickEntry($r('sys.symbol.books_vertical_fill'), '查看题库', () => {
        this.onSelectTab(1)
      })
      this.QuickEntry($r('sys.symbol.exclamationmark_circle_fill'), '查看错题', () => {
        this.onSelectTab(2)
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
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
  private OverviewCard() {
    HomeOverviewCard({
      pendingCount: this.dashboard.statistics.pendingCount,
      wrongCount: this.dashboard.statistics.wrongCount,
      masteredCount: this.dashboard.statistics.masteredCount,
      masteryRate: this.dashboard.masteryRate,
      reviewLabel: '今日待复习',
      wrongLabel: '错题总数',
      masteredLabel: '已掌握',
      masteryLabel: '掌握率',
      reviewActionLabel: '开始复习',
      onStartReview: () => {
        this.onStartReview()
      }
    })
  }

  @Builder
  private RecentBooks() {
    HomeRecentSection({
      title: '最近书籍',
      emptyText: '还没有导入书籍',
      items: this.bankLabels(),
      actionLabel: '查看题库列表',
      onViewAll: () => {
        this.onSelectTab(1)
      }
    })
  }

  @Builder
  private RecentWrongQuestions() {
    HomeRecentSection({
      title: '最近错题',
      emptyText: '还没有收集错题',
      items: this.wrongQuestionLabels(),
      actionLabel: '查看错题列表',
      onViewAll: () => {
        this.onSelectTab(2)
      }
    })
  }

  build() {
    Column() {
      if (this.loading) {
        Column() {
          if (this.bannerMessage().length > 0) {
            Column() {
              this.StatusBanner()
            }
            .width('100%')
            .padding({ top: this.topGap() })
          }

          Column({ space: 14 }) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color(this.colors().brand)

            Text('正在整理学习进度')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(this.colors().textCaption)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height('100%')
      } else if (this.errorMessage.length > 0) {
        Column() {
          if (this.bannerMessage().length > 0) {
            Column() {
              this.StatusBanner()
            }
            .width('100%')
            .padding({ top: this.topGap() })
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
        .height('100%')
      } else {
        List({ space: EDITORIAL_SECTION_GAP }) {
          if (this.bannerMessage().length > 0) {
            ListItem() {
              this.StatusBanner()
            }
          }

          ListItem() {
            this.Masthead()
          }

          ListItem() {
            this.QuickEntryRow()
          }

          ListItem() {
            this.OverviewCard()
          }

          if (!this.hasLearningData()) {
            ListItem() {
              EmptyState({
                glyph: '书',
                title: '暂无学习数据',
                description: '先导入一份 PDF 或题目，首页会自动汇总你的学习进度',
                actionLabel: '导入资料',
                showAction: true,
                onAction: () => {
                  this.onStartImport()
                }
              })
            }
          } else if (this.windowSizeClass === WindowSizeClass.EXPANDED) {
            ListItem() {
              Row({ space: EDITORIAL_SECTION_GAP }) {
                Column() {
                  this.RecentBooks()
                }
                .layoutWeight(1)

                Column() {
                  this.RecentWrongQuestions()
                }
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
          } else {
            ListItem() {
              this.RecentBooks()
            }

            ListItem() {
              this.RecentWrongQuestions()
            }
          }
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: this.contentMaxWidth() })
        .contentEndOffset(TAB_BAR_CLEARANCE)
        .padding({
          top: this.topGap(),
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
