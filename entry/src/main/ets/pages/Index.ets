import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit'
import { router } from '@kit.ArkUI'
import {
  BODY_FONT_SIZE,
  themePalette
} from '../constants/AppTheme'
import { HdsMaterialPolicy, HdsMaterialSelection } from '../constants/HdsMaterialPolicy'
import { MainTabIndex } from '../models/MainTab'
import { CloudSyncResult, SyncDisplayState } from '../models/SyncModels'
import { AppBootstrapService } from '../services/AppBootstrapService'
import { CloudSyncService } from '../services/CloudSyncService'
import { AppColors } from '../theme/AppColors'
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
  @StorageProp('darkMode') darkMode: boolean = false
  @State hdsMaterialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.ADAPTIVE
  @State hdsMaterialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE
  private bootstrapToken: number = 0
  private pageShown: boolean = false

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  aboutToAppear(): void {
    this.initialize()
    const selection: HdsMaterialSelection = HdsMaterialPolicy.resolve()
    this.hdsMaterialType = selection.materialType
    this.hdsMaterialLevel = selection.materialLevel
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

  private titleFor(index: number): string {
    if (index === MainTabIndex.BOOKS) {
      return '题库'
    }
    if (index === MainTabIndex.WRONG_QUESTIONS) {
      return '错题'
    }
    if (index === MainTabIndex.MINE) {
      return '我的'
    }
    return '首页'
  }

  private importToolbarItems(): Array<ToolbarItem> {
    const items: Array<ToolbarItem> = new Array<ToolbarItem>()
    if (this.selectedIndex !== MainTabIndex.BOOKS) {
      return items
    }
    const item: ToolbarItem = {
      value: '导入题库',
      action: () => {
        this.openImportPage()
      }
    }
    items.push(item)
    return items
  }

  @Builder
  private TabBarItem(index: number, label: string, symbol: Resource) {
    Column({ space: 4 }) {
      SymbolGlyph(symbol)
        .fontSize(24)
        .fontWeight(this.selectedIndex === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor([this.selectedIndex === index ? this.colors().brand : this.colors().navInactive])

      Text(label)
        .fontSize(11)
        .fontWeight(this.selectedIndex === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.selectedIndex === index ? this.colors().brand : this.colors().navInactive)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private TabContents() {
    TabContent() {
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
    }
    .tabBar(this.TabBarItem(MainTabIndex.HOME, '首页', $r('sys.symbol.house_fill')))

    TabContent() {
      BooksPage({
        active: this.selectedIndex === MainTabIndex.BOOKS,
        refreshVersion: this.refreshVersion
      })
    }
    .tabBar(this.TabBarItem(MainTabIndex.BOOKS, '题库', $r('sys.symbol.book')))

    TabContent() {
      WrongQuestionsPage({
        active: this.selectedIndex === MainTabIndex.WRONG_QUESTIONS,
        refreshVersion: this.refreshVersion
      })
    }
    .tabBar(this.TabBarItem(MainTabIndex.WRONG_QUESTIONS, '错题',
      $r('sys.symbol.exclamationmark_circle_fill')))

    TabContent() {
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
    }
    .tabBar(this.TabBarItem(MainTabIndex.MINE, '我的', $r('sys.symbol.person_fill')))
  }

  build() {
    Navigation() {
      if (this.ready) {
        HdsTabs({ barPosition: BarPosition.End, index: this.selectedIndex }) {
          this.TabContents()
        }
        .barOverlap(true)
        .barFloatingStyle({
          barBottomMargin:23,
          systemMaterialEffect: {
            materialType: this.hdsMaterialType,
            materialLevel: this.hdsMaterialLevel
          }
        })
        .onChange((index: number) => {
          this.selectTab(index)
        })
        .width('100%')
        .height('100%')
      } else {
        Column({ space: 16 }) {
          if (this.startupError.length === 0) {
            LoadingProgress()
              .width(44)
              .height(44)
              .color(this.colors().brand)

            Text('正在准备本地数据')
              .fontSize(BODY_FONT_SIZE)
              .fontColor(this.colors().textCaption)
          } else {
            Text('!')
              .width(64)
              .height(64)
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.colors().brand)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.colors().cardBackground)
              .borderRadius(32)

            Text(this.startupError)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.colors().textPrimary)
              .textAlign(TextAlign.Center)

            Button() {
              Text('重新初始化')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.colors().onBrand)
            }
            .type(ButtonType.Normal)
            .height(48)
            .padding({ left: 24, right: 24 })
            .backgroundColor(this.colors().brand)
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
        .backgroundColor(this.colors().pageBackground)
      }
    }
    .title(this.titleFor(this.selectedIndex), {
      barStyle: BarStyle.STACK
    })
    .toolbarConfiguration(this.importToolbarItems(), { barStyle: BarStyle.STANDARD })
    .hideToolBar(this.selectedIndex !== MainTabIndex.BOOKS)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
  }
}
