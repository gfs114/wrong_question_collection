import { Context } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'
import { pasteboard } from '@kit.BasicServicesKit'
import deviceInfo from '@ohos.deviceInfo'
import * as BuildProfile from 'BuildProfile'
import { EmptyState } from '../components/EmptyState'
import { HuaweiAccountCard } from '../components/HuaweiAccountCard'
import { LegacyMigrationCard } from '../components/LegacyMigrationCard'
import { SectionTitle } from '../components/SectionTitle'
import { StatRow, StatCell } from '../components/StatRow'
import {
  BODY_FONT_SIZE,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  TAB_BAR_CLEARANCE,
  themePalette
} from '../constants/AppTheme'
import {
  BADGE_GLYPH_SIZE,
  BADGE_RADIUS,
  BADGE_SIZE,
  EDITORIAL_SECTION_GAP,
  HAIRLINE,
  PAGE_TITLE_SIZE,
  SHEET_RADIUS
} from '../constants/EditorialStyle'
import { ResponsiveLayout, WindowSizeClass, WindowSizeObserver } from '../constants/ResponsiveLayout'
import { Statistics } from '../models/Statistics'
import { AccountSessionState } from '../models/AccountSession'
import { SyncDisplayState } from '../models/SyncModels'
import {
  LegacyMigrationStage,
  LegacyMigrationState
} from '../models/LegacyMigrationModels'
import { StatisticsService } from '../services/StatisticsService'
import { AccountSessionService } from '../services/AccountSessionService'
import { HuaweiLoginService } from '../services/HuaweiLoginService'
import { CloudSyncService } from '../services/CloudSyncService'
import { CloudQuestionRepository } from '../services/CloudQuestionRepository'
import { LegacyCloudMigrationService } from '../services/LegacyCloudMigrationService'
import { AppColors } from '../theme/AppColors'
import { ThemeManager, ThemeMode } from '../theme/ThemeManager'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

const MINE_FEED_TOP_GAP: number = 10

@Component
export struct MinePage {
  @Prop @Watch('onActiveChanged') active: boolean = false
  @Prop @Watch('onRefreshVersionChanged') refreshVersion: number = 0
  @StorageProp('darkMode') darkMode: boolean = false
  @StorageProp('themeMode') themeMode: ThemeMode = ThemeMode.SYSTEM
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = { top: 0, left: 0, right: 0, bottom: 0 }
  @State statistics: Statistics = new Statistics(0, 0, 0, 0)
  @State loading: boolean = false
  @State errorMessage: string = ''
  @State clearing: boolean = false
  @State dialogPending: boolean = false
  @State signingIn: boolean = false
  @State copyingTestToken: boolean = false
  @State authState: AccountSessionState = { signedIn: false, userId: '', deviceName: '' }
  @State migrationState: LegacyMigrationState = new LegacyMigrationState(
    '', LegacyMigrationStage.UNCLAIMED, new Array<string>(), '', new Array<string>(),
    new Array<string>(), new Array<string>(), 0, 0, 0, '', '', 0)
  @State migrationBusy: boolean = false
  @Prop syncState: SyncDisplayState = SyncDisplayState.LOCAL
  @State windowSizeClass: WindowSizeClass = WindowSizeClass.COMPACT
  onSyncRequested: () => void = () => {
  }
  onSessionChanged: () => void = () => {
  }
  private hasRequested: boolean = false
  private requestedVersion: number = -1
  private requestToken: number = 0
  private sizeObserver?: WindowSizeObserver

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  private modeLabel(): string {
    return ThemeManager.modeLabel(this.themeMode)
  }

  aboutToAppear(): void {
    this.sizeObserver = new WindowSizeObserver((windowWidthVp: number): void => {
      this.applyWindowSizeClass(windowWidthVp)
    })
    this.sizeObserver.start(getContext(this))
    this.refreshWhenActive()
    this.loadAuthState()
    this.loadMigrationState()
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
    return SafeAreaUtils.top(this.safeAreaInsets) + MINE_FEED_TOP_GAP
  }

  // 编辑风统计：一张纸张卡 + 竖细线分隔（与首页概览卡底部三统计同一套比例）。
  private statCells(): Array<StatCell> {
    const cells: Array<StatCell> = new Array<StatCell>()
    cells.push(new StatCell('题库数量', this.statistics.bankCount.toString(), this.colors().textPrimary))
    cells.push(new StatCell('错题数量', this.statistics.wrongCount.toString(), this.colors().textPrimary))
    cells.push(new StatCell('已掌握', this.statistics.masteredCount.toString(), this.colors().successText))
    cells.push(new StatCell('待复习', this.statistics.pendingCount.toString(), this.colors().error))
    return cells
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
    this.loadStatistics(token)
  }

  private async loadStatistics(token: number): Promise<void> {
    try {
      const statistics: Statistics = await StatisticsService.load()
      if (token !== this.requestToken) {
        return
      }
      this.statistics = statistics
      this.loading = false
    } catch (err) {
      if (token !== this.requestToken) {
        return
      }
      this.errorMessage = '学习数据加载失败，请稍后重试'
      this.loading = false
    }
  }

  private retry(): void {
    this.hasRequested = false
    this.refreshWhenActive()
  }

  private loadAuthState(): void {
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      return
    }
    AccountSessionService.state(hostContext)
      .then((state: AccountSessionState) => {
        this.authState = state
        this.loadMigrationState()
      })
      .catch(() => {
      })
  }

  private loadMigrationState(): void {
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      return
    }
    LegacyCloudMigrationService.overview(hostContext)
      .then((state: LegacyMigrationState) => {
        this.migrationState = state
      })
      .catch(() => {
      })
  }

  private showMigrationCard(): boolean {
    return this.migrationState.totalBanks > 0 ||
      this.migrationState.stage !== LegacyMigrationStage.UNCLAIMED
  }

  private confirmMigration(): void {
    if (this.migrationBusy || this.dialogPending) {
      return
    }
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      this.showToast('暂时无法获取应用上下文')
      return
    }
    if (!this.authState.signedIn) {
      this.showToast('请先登录华为账号')
      return
    }
    this.dialogPending = true
    try {
      this.getUIContext().showAlertDialog({
        title: '迁移本机旧数据？',
        message: '共 ' + this.migrationState.totalBanks.toString() + ' 个题库、' +
          this.migrationState.totalQuestions.toString() + ' 道题目、' +
          this.migrationState.totalImages.toString() + ' 张本机题图。' +
          '文字将上传并绑定到当前登录的华为账号，本机数据不会被删除。',
        autoCancel: false,
        primaryButton: {
          value: '开始迁移',
          action: () => {
            this.dialogPending = false
            this.persistMigration(hostContext)
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

  private persistMigration(context: Context): void {
    if (this.migrationBusy) {
      return
    }
    this.migrationBusy = true
    LegacyCloudMigrationService.claim(context)
      .then((state: LegacyMigrationState) => {
        this.migrationState = state
        return LegacyCloudMigrationService.run(context)
      })
      .then((state: LegacyMigrationState) => {
        this.migrationState = state
        this.migrationBusy = false
        if (state.stage === LegacyMigrationStage.COMPLETED) {
          this.showToast('旧数据迁移完成')
        } else if (state.stage === LegacyMigrationStage.FAILED) {
          this.showToast('迁移失败，可稍后重试')
        }
      })
      .catch(() => {
        this.migrationBusy = false
        this.showToast('迁移启动失败，请稍后重试')
        this.loadMigrationState()
      })
  }

  private retryMigration(): void {
    if (this.migrationBusy || this.dialogPending) {
      return
    }
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      this.showToast('暂时无法获取应用上下文')
      return
    }
    if (!this.authState.signedIn) {
      this.showToast('请先登录华为账号')
      return
    }
    this.migrationBusy = true
    LegacyCloudMigrationService.run(hostContext)
      .then((state: LegacyMigrationState) => {
        this.migrationState = state
        this.migrationBusy = false
        if (state.stage === LegacyMigrationStage.COMPLETED) {
          this.showToast('旧数据迁移完成')
        }
      })
      .catch(() => {
        this.migrationBusy = false
        this.showToast('迁移启动失败，请稍后重试')
        this.loadMigrationState()
      })
  }

  private exchangeAuthorizationCode(authorizationCode: string): void {
    if (this.signingIn || this.dialogPending) {
      return
    }
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      this.showToast('暂时无法获取应用上下文')
      return
    }
    this.signingIn = true
    HuaweiLoginService.exchange(hostContext, authorizationCode, 'HarmonyOS device')
      .then((state: AccountSessionState) => {
        this.signingIn = false
        this.authState = state
        this.showToast('华为账号登录成功')
        this.onSessionChanged()
      })
      .catch(() => {
        this.signingIn = false
        this.showToast('登录失败，请稍后重试')
      })
  }

  private handleLoginError(code: number): void {
    if (HuaweiLoginService.isUserCanceled(code)) {
      return
    }
    this.showToast('华为账号登录失败，请稍后重试')
  }

  private signOut(): void {
    if (this.signingIn || this.dialogPending) {
      return
    }
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      this.showToast('暂时无法获取应用上下文')
      return
    }
    this.dialogPending = true
    try {
      this.getUIContext().showAlertDialog({
        title: '退出登录？',
        message: '退出后本机保留离线数据，云端同步将在下次登录时恢复。',
        autoCancel: false,
        primaryButton: {
          value: '退出',
          action: () => {
            this.dialogPending = false
            this.persistSignOut(hostContext)
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

  private persistSignOut(hostContext: Context): void {
    AccountSessionService.signOut(hostContext)
      .then(() => {
        this.authState = { signedIn: false, userId: '', deviceName: '' }
        this.showToast('已退出登录')
        this.loadMigrationState()
        this.onSessionChanged()
      })
      .catch(() => {
        this.showToast('退出失败，请稍后重试')
      })
  }

  private confirmClear(): void {
    if (this.clearing || this.dialogPending) {
      return
    }
    if (!this.authState.signedIn) {
      this.showToast('请先登录华为账号')
      return
    }
    this.dialogPending = true
    try {
      this.getUIContext().showAlertDialog({
        title: '清空全部错题？',
        message: '此操作将删除该账号的全部错题记录，无法撤销。',
        autoCancel: false,
        primaryButton: {
          value: '清空',
          action: () => {
            this.dialogPending = false
            this.clearWrongQuestions()
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

  private clearWrongQuestions(): void {
    if (this.clearing) {
      return
    }
    this.clearing = true
    this.persistClear()
  }

  private async persistClear(): Promise<void> {
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      this.clearing = false
      this.showToast('暂时无法获取应用上下文')
      return
    }
    try {
      // 清空错题是服务器优先写操作：先提交 /v1/sync/push，成功后才更新账号缓存。
      await CloudQuestionRepository.clearWrongQuestions(hostContext)
      this.clearing = false
      this.showToast('已清空错题')
      this.hasRequested = false
      this.refreshWhenActive()
    } catch {
      this.clearing = false
      this.showToast('清空失败，请稍后重试')
    }
  }

  private copyTestToken(): void {
    if (this.copyingTestToken) {
      return
    }
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      this.showToast('暂时无法获取测试 Token')
      return
    }
    this.copyingTestToken = true
    this.copyTestTokenSafely(hostContext).catch(() => {
      this.copyingTestToken = false
      this.showToast('暂时无法获取测试 Token')
    })
  }

  private async copyTestTokenSafely(context: Context): Promise<void> {
    try {
      const session: AccountSessionState = await AccountSessionService.state(context)
      if (!session.signedIn) {
        this.showToast('请先登录华为账号')
        return
      }
      const token: string = await AccountSessionService.accessToken(context)
      if (token.length === 0) {
        this.showToast('暂时无法获取测试 Token')
        return
      }
      try {
        const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, token)
        await pasteboard.getSystemPasteboard().setData(data)
      } catch {
        this.showToast('复制失败，请重试')
        return
      }
      this.showToast('测试 Token 已复制')
    } catch {
      this.showToast('暂时无法获取测试 Token')
    } finally {
      this.copyingTestToken = false
    }
  }

  private showAbout(): void {
    if (this.dialogPending || this.clearing) {
      return
    }
    this.dialogPending = true
    try {
      this.getUIContext().showAlertDialog({
        title: '关于应用',
        message: '错题收集 v1.0.0\n登录后题库与错题文字数据将同步到云端；PDF 原文件和题图始终保存在本机。',
        autoCancel: false,
        primaryButton: {
          value: '知道了',
          action: () => {
            this.dialogPending = false
          }
        }
      })
    } catch {
      this.dialogPending = false
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  private selectThemeMode(): void {
    if (this.dialogPending || this.clearing) {
      return
    }
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      this.showToast('暂时无法获取应用上下文')
      return
    }
    try {
      this.getUIContext().showActionSheet({
        title: '深色模式',
        message: '选择应用主题模式',
        sheets: [
          {
            title: '跟随系统',
            action: () => {
              ThemeManager.setMode(hostContext, ThemeMode.SYSTEM)
            }
          },
          {
            title: '浅色模式',
            action: () => {
              ThemeManager.setMode(hostContext, ThemeMode.LIGHT)
            }
          },
          {
            title: '深色模式',
            action: () => {
              ThemeManager.setMode(hostContext, ThemeMode.DARK)
            }
          }
        ]
      })
    } catch {
      this.showToast('暂时无法打开主题选择')
    }
  }

  // 设置 / 开发辅助共用的一行：方形书签 + 文案 + 右侧值 / 箭头。
  @Builder
  private SettingRow(glyph: string, label: string, accent: string, value: string, showChevron: boolean) {
    Row({ space: 12 }) {
      Text(glyph)
        .width(BADGE_SIZE)
        .height(BADGE_SIZE)
        .fontSize(BADGE_GLYPH_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(accent)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.colors().brandSoft)
        .borderRadius(BADGE_RADIUS)

      Text(label)
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textPrimary)
        .layoutWeight(1)

      if (value.length > 0) {
        Text(value)
          .fontSize(13)
          .fontColor(this.colors().textCaption)
          .margin({ right: 6 })
      }

      if (showChevron) {
        Text('›')
          .fontSize(22)
          .fontColor(this.colors().textCaption)
      }
    }
    .width('100%')
    .height(60)
  }

  private currentDeviceName(): string {
    const marketName: string = deviceInfo.marketName.trim()
    if (marketName.length > 0) {
      return marketName
    }
    const productModel: string = deviceInfo.productModel.trim()
    if (productModel.length > 0) {
      return productModel
    }
    return 'HarmonyOS 设备'
  }

  @Builder
  private LearningAccountSection() {
    HuaweiAccountCard({
      signedIn: this.authState.signedIn,
      userId: this.authState.userId,
      deviceName: this.currentDeviceName(),
      signingIn: this.signingIn,
      syncLabel: CloudSyncService.label(this.syncState),
      syncing: this.syncState === SyncDisplayState.SYNCING,
      onAuthorizationCode: (authorizationCode: string) => {
        this.exchangeAuthorizationCode(authorizationCode)
      },
      onLoginError: (code: number) => {
        this.handleLoginError(code)
      },
      onSignOut: () => {
        this.signOut()
      },
      onSync: () => {
        this.onSyncRequested()
      }
    })
  }

  @Builder
  private MigrationSection() {
    SectionTitle({ title: '旧数据迁移' })

    LegacyMigrationCard({
      state: this.migrationState,
      signedIn: this.authState.signedIn,
      busy: this.migrationBusy,
      onStart: () => {
        this.confirmMigration()
      },
      onRetry: () => {
        this.retryMigration()
      }
    })
  }

  @Builder
  private StatsSection() {
    SectionTitle({ title: '学习概览' })

    StatRow({ cells: this.statCells() })
  }

  @Builder
  private SettingsSection() {
    SectionTitle({ title: '设置' })

    Column() {
      Button() {
        this.SettingRow('AI', 'AI 识别设置', this.colors().brand, '', true)
      }
      .type(ButtonType.Normal)
      .width('100%').height(60).padding(0)
      .backgroundColor(this.colors().cardBackground)
      .enabled(!this.clearing && !this.dialogPending)
      .accessibilityText('AI 识别设置')
      .onClick(() => {
        if (this.clearing || this.dialogPending) return
        router.pushUrl({ url: 'pages/AiRecognitionSettingsPage' }).catch(() => {})
      })

      Divider()
        .strokeWidth(HAIRLINE)
        .color(this.colors().divider)

      Button() {
        this.SettingRow('深', '深色模式', this.colors().brand, this.modeLabel(), true)
      }
      .type(ButtonType.Normal)
      .width('100%')
      .height(60)
      .padding(0)
      .backgroundColor(this.colors().cardBackground)
      .enabled(!this.dialogPending)
      .accessibilityText('深色模式')
      .onClick(() => {
        this.selectThemeMode()
      })

      Divider()
        .strokeWidth(HAIRLINE)
        .color(this.colors().divider)

      Button() {
        this.SettingRow('关', '关于应用', this.colors().successText, '', true)
      }
      .type(ButtonType.Normal)
      .width('100%')
      .height(60)
      .padding(0)
      .backgroundColor(this.colors().cardBackground)
      .enabled(!this.clearing && !this.dialogPending)
      .accessibilityText('关于应用')
      .onClick(() => {
        this.showAbout()
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(SHEET_RADIUS)
    .border({ width: HAIRLINE, color: this.colors().divider })
    .clip(true)
  }

  @Builder
  private DataManagementSection() {
    SectionTitle({ title: '数据与隐私' })

    Column() {
      Button() {
        Row({ space: 12 }) {
          Text('清')
            .width(BADGE_SIZE)
            .height(BADGE_SIZE)
            .fontSize(BADGE_GLYPH_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().error)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.colors().brandSoft)
            .borderRadius(BADGE_RADIUS)

          Column({ space: 3 }) {
            Text(this.clearing ? '正在清空…' : '清空错题')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(this.colors().error)

            Text('永久删除当前账号的全部错题记录')
              .fontSize(13)
              .fontColor(this.colors().textCaption)
              .maxLines(2)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text(this.clearing ? '处理中' : '清空')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().error)
        }
        .width('100%')
        .constraintSize({ minHeight: 72 })
        .padding({ top: 10, bottom: 10 })
      }
      .type(ButtonType.Normal)
      .width('100%')
      .padding(0)
      .backgroundColor(this.colors().cardBackground)
      .enabled(!this.clearing && !this.dialogPending)
      .accessibilityText('清空错题，永久删除当前账号的全部错题记录')
      .onClick(() => {
        this.confirmClear()
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(SHEET_RADIUS)
    .border({ width: HAIRLINE, color: this.colors().divider })
  }

  @Builder
  private DebugToolsSection() {
    SectionTitle({ title: '开发辅助' })

    Column() {
      Button() {
        Row({ space: 12 }) {
          Text('测')
            .width(BADGE_SIZE)
            .height(BADGE_SIZE)
            .fontSize(BADGE_GLYPH_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().brand)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.colors().brandSoft)
            .borderRadius(BADGE_RADIUS)

          Column({ space: 2 }) {
            Text(this.copyingTestToken ? '正在复制…' : '复制测试 Token')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(this.colors().textPrimary)
            Text('仅用于服务器 E2E 测试')
              .fontSize(13)
              .fontColor(this.colors().textCaption)
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          Text('›')
            .fontSize(22)
            .fontColor(this.colors().textCaption)
        }
        .width('100%')
        .height(68)
      }
      .type(ButtonType.Normal)
      .width('100%')
      .height(68)
      .padding(0)
      .backgroundColor(this.colors().cardBackground)
      .enabled(!this.copyingTestToken && !this.dialogPending)
      .accessibilityText('复制测试 Token，仅用于服务器 E2E 测试')
      .onClick(() => {
        this.copyTestToken()
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(SHEET_RADIUS)
    .border({ width: HAIRLINE, color: this.colors().divider })
  }

  @Builder
  private PageTitle() {
    Column({ space: 12 }) {
      Text('我的')
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
        Column({ space: 14 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(this.colors().brand)

          Text('正在加载学习数据')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)
        }
        .width('100%')
        .layoutWeight(1)
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
        .width('100%')
        .layoutWeight(1)
      } else {
        Scroll() {
          Column({ space: EDITORIAL_SECTION_GAP }) {
            this.LearningAccountSection()

            this.StatsSection()

            if (this.windowSizeClass === WindowSizeClass.EXPANDED) {
              Row({ space: EDITORIAL_SECTION_GAP }) {
                Column({ space: EDITORIAL_SECTION_GAP }) {
                  if (this.showMigrationCard()) {
                    this.MigrationSection()
                  }

                  this.DataManagementSection()
                }
                .layoutWeight(1)

                Column({ space: EDITORIAL_SECTION_GAP }) {
                  this.SettingsSection()

                  if (BuildProfile.DEBUG) {
                    this.DebugToolsSection()
                  }
                }
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            } else {
              if (this.showMigrationCard()) {
                this.MigrationSection()
              }

              this.SettingsSection()

              this.DataManagementSection()

              if (BuildProfile.DEBUG) {
                this.DebugToolsSection()
              }
            }
          }
          .width('100%')
          .padding({
            left: PAGE_PADDING + SafeAreaUtils.left(this.safeAreaInsets),
            right: PAGE_PADDING + SafeAreaUtils.right(this.safeAreaInsets),
            top: 16,
            bottom: TAB_BAR_CLEARANCE
          })
        }
        .width('100%')
        .layoutWeight(1)
        .constraintSize({ maxWidth: this.contentMaxWidth() })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
