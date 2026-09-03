import { Context } from '@kit.AbilityKit'
import { EmptyState } from '../components/EmptyState'
import { HuaweiAccountCard } from '../components/HuaweiAccountCard'
import { LegacyMigrationCard } from '../components/LegacyMigrationCard'
import { SectionTitle } from '../components/SectionTitle'
import { StatCard } from '../components/StatCard'
import {
  BODY_FONT_SIZE,
  CARD_GAP,
  CARD_RADIUS,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE,
  TAB_BAR_CLEARANCE,
  themePalette
} from '../constants/AppTheme'
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

@Component
export struct MinePage {
  @Prop @Watch('onActiveChanged') active: boolean = false
  @Prop @Watch('onRefreshVersionChanged') refreshVersion: number = 0
  @StorageProp('darkMode') darkMode: boolean = false
  @StorageProp('themeMode') themeMode: ThemeMode = ThemeMode.SYSTEM
  @State statistics: Statistics = new Statistics(0, 0, 0, 0)
  @State loading: boolean = false
  @State errorMessage: string = ''
  @State clearing: boolean = false
  @State dialogPending: boolean = false
  @State signingIn: boolean = false
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

  private statColumnsTemplate(): string {
    if (this.windowSizeClass === WindowSizeClass.EXPANDED) {
      return '1fr 1fr 1fr 1fr'
    }
    return '1fr 1fr'
  }

  private statRowsTemplate(): string {
    if (this.windowSizeClass === WindowSizeClass.EXPANDED) {
      return '112vp'
    }
    return '112vp 112vp'
  }

  private statGridHeight(): number {
    if (this.windowSizeClass === WindowSizeClass.EXPANDED) {
      return 112
    }
    return 236
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

  @Builder
  private HeaderCard() {
    Column({ space: 10 }) {
      Text('人')
        .width(72)
        .height(72)
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().brand)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.colors().pageBackground)
        .borderRadius(36)

      Text('学习中心')
        .fontSize(SUBTITLE_FONT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().textPrimary)

      Text('整理错题，让每次复习更有方向')
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.colors().textCaption)
    }
    .width('100%')
    .padding({ top: 22, bottom: 22 })
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  private AccountSection() {
    SectionTitle({ title: '账号' })

    HuaweiAccountCard({
      signedIn: this.authState.signedIn,
      userId: this.authState.userId,
      deviceName: this.authState.deviceName,
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

    Grid() {
      GridItem() {
        StatCard({
          label: '题库数量',
          value: this.statistics.bankCount,
          glyph: '书',
          accentColor: this.colors().brand
        })
      }

      GridItem() {
        StatCard({
          label: '错题数量',
          value: this.statistics.wrongCount,
          glyph: '错',
          accentColor: this.colors().error
        })
      }

      GridItem() {
        StatCard({
          label: '已掌握',
          value: this.statistics.masteredCount,
          glyph: '✓',
          accentColor: this.colors().successText
        })
      }

      GridItem() {
        StatCard({
          label: '待复习',
          value: this.statistics.pendingCount,
          glyph: '复',
          accentColor: this.colors().error
        })
      }
    }
    .columnsTemplate(this.statColumnsTemplate())
    .rowsTemplate(this.statRowsTemplate())
    .columnsGap(CARD_GAP)
    .rowsGap(CARD_GAP)
    .height(this.statGridHeight())
  }

  @Builder
  private SettingsSection() {
    SectionTitle({ title: '设置' })

    Column() {
      Row({ space: 12 }) {
        Text('数')
          .width(36)
          .height(36)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().brand)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.colors().pageBackground)
          .borderRadius(18)
        Text('数据管理')
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.colors().textPrimary)
        Blank()
        Text('›')
          .fontSize(24)
          .fontColor(this.colors().textCaption)
      }
      .width('100%')
      .height(60)

      Button() {
        Row({ space: 12 }) {
          Text('清')
            .width(36)
            .height(36)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().error)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.colors().pageBackground)
            .borderRadius(18)
          Text(this.clearing ? '正在清空…' : '清空错题')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textPrimary)
          Blank()
          Text('›')
            .fontSize(24)
            .fontColor(this.colors().textCaption)
        }
        .width('100%')
        .height(60)
      }
      .type(ButtonType.Normal)
      .width('100%')
      .height(60)
      .padding(0)
      .backgroundColor(this.colors().cardBackground)
      .enabled(!this.clearing && !this.dialogPending)
      .accessibilityText('清空错题')
      .onClick(() => {
        this.confirmClear()
      })

      Button() {
        Row({ space: 12 }) {
          Text('深')
            .width(36)
            .height(36)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().brand)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.colors().pageBackground)
            .borderRadius(18)
          Text('深色模式')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textPrimary)
          Blank()
          Text(this.modeLabel())
            .fontSize(13)
            .fontColor(this.colors().textCaption)
            .margin({ right: 6 })
          Text('›')
            .fontSize(24)
            .fontColor(this.colors().textCaption)
        }
        .width('100%')
        .height(60)
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

      Button() {
        Row({ space: 12 }) {
          Text('关')
            .width(36)
            .height(36)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().successText)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.colors().pageBackground)
            .borderRadius(18)
          Text('关于应用')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textPrimary)
          Blank()
          Text('›')
            .fontSize(24)
            .fontColor(this.colors().textCaption)
        }
        .width('100%')
        .height(60)
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
    .borderRadius(CARD_RADIUS)
  }

  build() {
    Column() {
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
        .height('100%')
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
        .height('100%')
      } else {
        Scroll() {
          Column({ space: CARD_GAP }) {
            this.HeaderCard()

            if (this.windowSizeClass === WindowSizeClass.EXPANDED) {
              this.StatsSection()

              Row({ space: CARD_GAP }) {
                Column({ space: CARD_GAP }) {
                  this.AccountSection()

                  if (this.showMigrationCard()) {
                    this.MigrationSection()
                  }
                }
                .layoutWeight(1)

                Column({ space: CARD_GAP }) {
                  this.SettingsSection()
                }
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            } else {
              this.AccountSection()

              if (this.showMigrationCard()) {
                this.MigrationSection()
              }

              this.StatsSection()

              this.SettingsSection()
            }
          }
          .width('100%')
          .padding({
            left: PAGE_PADDING,
            right: PAGE_PADDING,
            top: 16,
            bottom: TAB_BAR_CLEARANCE
          })
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: this.contentMaxWidth() })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
