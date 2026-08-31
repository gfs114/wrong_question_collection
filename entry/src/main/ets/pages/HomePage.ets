import { AppHeader } from '../components/AppHeader'
import { EmptyState } from '../components/EmptyState'
import { HomeOverviewCard } from '../components/HomeOverviewCard'
import { HomeRecentSection } from '../components/HomeRecentSection'
import {
  BODY_FONT_SIZE,
  CARD_GAP,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY,
  PAGE_PADDING
} from '../constants/AppTheme'
import { AccountSessionState } from '../models/AccountSession'
import { HomeDashboardSnapshot } from '../models/HomeDashboard'
import { QuestionBankSummary } from '../models/QuestionBank'
import { Statistics } from '../models/Statistics'
import { WrongQuestionSummary } from '../models/WrongQuestion'
import { AccountSessionService } from '../services/AccountSessionService'
import { CloudQuestionRepository } from '../services/CloudQuestionRepository'
import { ConnectivityPolicy } from '../services/ConnectivityPolicy'

@Component
export struct HomePage {
  @Prop @Watch('onActiveChanged') active: boolean = false
  @Prop @Watch('onRefreshVersionChanged') refreshVersion: number = 0
  @State dashboard: HomeDashboardSnapshot = new HomeDashboardSnapshot(
    new Statistics(0, 0, 0, 0), new Array<QuestionBankSummary>(), new Array<WrongQuestionSummary>())
  @State loading: boolean = false
  @State errorMessage: string = ''
  @State signedIn: boolean = false
  @State offline: boolean = false
  @State accountId: string = ''
  @Prop syncLabel: string = '本地模式'
  onSelectTab: (index: number) => void = () => {
  }
  onStartImport: () => void = () => {
  }
  onStartReview: () => void = () => {
  }
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
    } catch {
      if (token !== this.requestToken) {
        return
      }
      this.offline = true
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
    if (this.offline) {
      return '离线浏览：当前仅可查看缓存，修改需联网'
    }
    return ''
  }

  private canMutate(): boolean {
    return ConnectivityPolicy.canMutate(this.signedIn, !this.offline)
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

  build() {
    Column() {
      AppHeader({ title: '首页' })

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

          Text('正在整理学习进度')
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
            Column({ space: 4 }) {
              Text('今天也要稳稳进步')
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_TEXT_PRIMARY)

              Text('复习一点，掌握就多一点')
                .fontSize(BODY_FONT_SIZE)
                .fontColor(COLOR_TEXT_CAPTION)

              Text(this.syncLabel)
                .fontSize(12)
                .fontColor(COLOR_PRIMARY)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          ListItem() {
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

          ListItem() {
            Button() {
              Row({ space: 10 }) {
                Text('+')
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                Text('导入资料')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
              }
            }
            .type(ButtonType.Normal)
            .width('100%')
            .height(54)
            .fontColor('#FFFFFF')
            .backgroundColor(this.canMutate() ? COLOR_PRIMARY : '#8E99AA')
            .borderRadius(18)
            .enabled(this.canMutate())
            .onClick(() => {
              this.onStartImport()
            })
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
          } else {
            ListItem() {
              HomeRecentSection({
                title: '最近书籍',
                emptyText: '还没有导入书籍',
                items: this.bankLabels(),
                onOpen: (index: number) => {
                  this.onSelectTab(1)
                }
              })
            }

            ListItem() {
              HomeRecentSection({
                title: '最近错题',
                emptyText: '还没有收集错题',
                items: this.wrongQuestionLabels(),
                onOpen: (index: number) => {
                  this.onSelectTab(2)
                }
              })
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 112 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_PAGE_BG)
  }
}
