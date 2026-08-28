import { router } from '@kit.ArkUI'
import { MainBottomNavigation } from '../components/MainBottomNavigation'
import {
  BODY_FONT_SIZE,
  COLOR_CARD_BG,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY
} from '../constants/AppTheme'
import { MainTabIndex } from '../models/MainTab'
import { CloudSyncResult, SyncDisplayState } from '../models/SyncModels'
import { AppBootstrapService } from '../services/AppBootstrapService'
import { CloudSyncService } from '../services/CloudSyncService'
import { BooksPage } from './BooksPage'
import { HomePage } from './HomePage'
import { MinePage } from './MinePage'
import { WrongQuestionsPage } from './WrongQuestionsPage'

@Entry
@Component
struct Index {
  @State ready: boolean = false
  @State startupError: string = ''
  @State selectedIndex: number = MainTabIndex.HOME
  @State refreshVersion: number = 0
  @State navigationPending: boolean = false
  @State syncState: SyncDisplayState = SyncDisplayState.LOCAL
  private bootstrapToken: number = 0
  private pageShown: boolean = false

  aboutToAppear(): void {
    this.initialize()
  }

  onPageShow(): void {
    if (!this.pageShown) {
      this.pageShown = true
      return
    }
    this.refreshVersion = this.refreshVersion + 1
    this.synchronize()
  }

  private initialize(): void {
    this.bootstrapToken = this.bootstrapToken + 1
    const token: number = this.bootstrapToken
    this.ready = false
    this.startupError = ''
    this.bootstrap(token)
  }

  private async bootstrap(token: number): Promise<void> {
    try {
      await AppBootstrapService.initialize(getContext(this))
      if (token !== this.bootstrapToken) {
        return
      }
      this.ready = true
      this.synchronize()
    } catch (err) {
      if (token !== this.bootstrapToken) {
        return
      }
      this.startupError = '本地数据初始化失败，请重启应用'
      this.ready = false
    }
  }

  private synchronize(): void {
    const hostContext = this.getUIContext().getHostContext()
    if (hostContext === undefined) {
      return
    }
    this.syncState = SyncDisplayState.SYNCING
    CloudSyncService.syncNow(hostContext)
      .then((result: CloudSyncResult) => {
        this.syncState = result.state
        if (result.pushedCount > 0 || result.pulledCount > 0) {
          this.refreshVersion = this.refreshVersion + 1
        }
      })
      .catch(() => {
        this.syncState = SyncDisplayState.FAILED
      })
  }

  private selectTab(index: number): void {
    if (index < MainTabIndex.HOME || index > MainTabIndex.MINE) {
      return
    }
    this.selectedIndex = index
  }

  private openImportPage(): void {
    if (this.navigationPending) {
      return
    }
    this.navigationPending = true
    const options: router.RouterOptions = {
      url: 'pages/ImportBankPage'
    }
    this.getUIContext().getRouter().pushUrl(options).catch(() => {
      this.showToast('导入页面暂不可用')
    }).finally(() => {
      this.navigationPending = false
    })
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  build() {
    Stack() {
      if (this.ready) {
        Stack({ alignContent: Alignment.Bottom }) {
          Stack() {
            HomePage({
              active: this.selectedIndex === MainTabIndex.HOME,
              refreshVersion: this.refreshVersion,
              syncLabel: CloudSyncService.label(this.syncState),
              onSelectTab: (index: number) => {
                this.selectTab(index)
              },
              onStartImport: () => {
                this.openImportPage()
              },
              onStartReview: () => {
                this.selectTab(MainTabIndex.WRONG_QUESTIONS)
              }
            })
            .visibility(this.selectedIndex === MainTabIndex.HOME ? Visibility.Visible : Visibility.Hidden)

            BooksPage({
              active: this.selectedIndex === MainTabIndex.BOOKS,
              refreshVersion: this.refreshVersion
            })
            .visibility(this.selectedIndex === MainTabIndex.BOOKS ? Visibility.Visible : Visibility.Hidden)

            WrongQuestionsPage({
              active: this.selectedIndex === MainTabIndex.WRONG_QUESTIONS,
              refreshVersion: this.refreshVersion
            })
            .visibility(this.selectedIndex === MainTabIndex.WRONG_QUESTIONS ?
              Visibility.Visible : Visibility.Hidden)

            MinePage({
              active: this.selectedIndex === MainTabIndex.MINE,
              refreshVersion: this.refreshVersion,
              syncState: this.syncState,
              onSyncRequested: () => {
                this.synchronize()
              },
              onSessionChanged: () => {
                this.synchronize()
              }
            })
            .visibility(this.selectedIndex === MainTabIndex.MINE ? Visibility.Visible : Visibility.Hidden)
          }
          .width('100%')
          .height('100%')

          MainBottomNavigation({
            selectedIndex: this.selectedIndex,
            onSelect: (index: number) => {
              this.selectTab(index)
            }
          })
        }
        .width('100%')
        .height('100%')
      } else {
        Column({ space: 16 }) {
          if (this.startupError.length === 0) {
            LoadingProgress()
              .width(44)
              .height(44)
              .color(COLOR_PRIMARY)

            Text('正在准备本地数据')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(COLOR_TEXT_CAPTION)
          } else {
            Text('!')
              .width(64)
              .height(64)
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_PRIMARY)
              .textAlign(TextAlign.Center)
              .backgroundColor(COLOR_CARD_BG)
              .borderRadius(32)

            Text(this.startupError)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_TEXT_PRIMARY)
              .textAlign(TextAlign.Center)

            Button() {
              Text('重新初始化')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
            }
            .type(ButtonType.Normal)
            .height(48)
            .padding({ left: 24, right: 24 })
            .backgroundColor(COLOR_PRIMARY)
            .borderRadius(16)
            .onClick(() => {
              this.initialize()
            })
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 32, right: 32 })
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_PAGE_BG)
  }
}
