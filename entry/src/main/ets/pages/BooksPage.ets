import { router } from '@kit.ArkUI'
import { EmptyState } from '../components/EmptyState'
import { QuestionBankCard } from '../components/QuestionBankCard'
import {
  BODY_FONT_SIZE,
  CARD_GAP,
  CONTENT_MAX_WIDTH,
  PAGE_PADDING,
  TAB_BAR_CLEARANCE,
  themePalette
} from '../constants/AppTheme'
import { AccountSessionState } from '../models/AccountSession'
import { QuestionBankSummary } from '../models/QuestionBank'
import { AccountSessionService } from '../services/AccountSessionService'
import { CloudQuestionRepository } from '../services/CloudQuestionRepository'
import { ConnectivityPolicy } from '../services/ConnectivityPolicy'
import { AppColors } from '../theme/AppColors'
import { DateUtils } from '../utils/DateUtils'
import { NavigationState } from '../utils/NavigationState'

@Component
export struct BooksPage {
  @Prop @Watch('onActiveChanged') active: boolean = false
  @Prop @Watch('onRefreshVersionChanged') refreshVersion: number = 0
  @State banks: Array<QuestionBankSummary> = new Array<QuestionBankSummary>()
  @State loading: boolean = false
  @State errorMessage: string = ''
  @State navigationPending: boolean = false
  @State dialogPending: boolean = false
  @State deletingBankId: string = ''
  @State signedIn: boolean = false
  @State offline: boolean = false
  @State syncFailed: boolean = false
  @State accountId: string = ''
  @StorageProp('darkMode') darkMode: boolean = false
  private hasRequested: boolean = false
  private requestedVersion: number = -1
  private requestToken: number = 0

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

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
    this.loadBanks(token)
  }

  private async loadBanks(token: number): Promise<void> {
    const session: AccountSessionState = await AccountSessionService.state(getContext(this))
    if (token !== this.requestToken) {
      return
    }
    this.signedIn = session.signedIn
    this.accountId = session.userId
    if (!this.signedIn) {
      this.banks = new Array<QuestionBankSummary>()
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
      const banks: Array<QuestionBankSummary> =
        await CloudQuestionRepository.listCachedBanks(this.accountId)
      if (token !== this.requestToken) {
        return
      }
      this.banks = banks
      this.loading = false
    } catch (err) {
      if (token !== this.requestToken) {
        return
      }
      this.errorMessage = '题库加载失败，请稍后重试'
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

  private canMutate(): boolean {
    return ConnectivityPolicy.canMutate(this.signedIn, !this.offline)
  }

  private openImportPage(): void {
    if (this.navigationPending || this.dialogPending || this.deletingBankId.length > 0) {
      return
    }
    if (!this.canMutate()) {
      this.showToast(ConnectivityPolicy.mutationBlockedMessage(this.signedIn, !this.offline))
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

  private openBank(bankId: string): void {
    if (this.navigationPending || this.dialogPending || this.deletingBankId.length > 0) {
      return
    }
    this.navigationPending = true
    NavigationState.shared().selectBank(bankId)
    const options: router.RouterOptions = {
      url: 'pages/QuestionListPage'
    }
    this.getUIContext().getRouter().pushUrl(options).catch(() => {
      this.showToast('题目列表暂不可用')
    }).finally(() => {
      this.navigationPending = false
    })
  }

  private confirmDelete(bank: QuestionBankSummary): void {
    if (this.navigationPending || this.dialogPending || this.deletingBankId.length > 0) {
      return
    }
    if (!this.canMutate()) {
      this.showToast(ConnectivityPolicy.mutationBlockedMessage(this.signedIn, !this.offline))
      return
    }
    this.dialogPending = true
    try {
      this.getUIContext().showAlertDialog({
        title: '删除题库？',
        message: '“' + bank.bankName + '”将从云端删除，本机缓存同步移除。',
        autoCancel: false,
        primaryButton: {
          value: '删除',
          action: () => {
            this.dialogPending = false
            this.deleteBank(bank.id)
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

  private deleteBank(bankId: string): void {
    if (this.deletingBankId.length > 0) {
      return
    }
    this.deletingBankId = bankId
    this.persistBankDeletion(bankId)
  }

  private async persistBankDeletion(bankUuid: string): Promise<void> {
    try {
      await CloudQuestionRepository.deleteBank(bankUuid, getContext(this))
    } catch {
      if (this.deletingBankId !== bankUuid) {
        return
      }
      this.deletingBankId = ''
      this.showToast('删除题库失败，请检查网络后重试')
      return
    }
    if (this.deletingBankId !== bankUuid) {
      return
    }
    this.deletingBankId = ''
    this.showToast('题库已删除')
    this.hasRequested = false
    this.refreshWhenActive()
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
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

  build() {
    Column() {
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

            Text('正在加载题库')
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
        .height('100%')
      } else if (this.banks.length === 0) {
        Column() {
          if (this.bannerMessage().length > 0) {
            this.StatusBanner()
          }

          EmptyState({
            glyph: '书',
            title: this.signedIn ? '还没有题库' : '未登录',
            description: this.signedIn ? '点击右上角导入你的第一个题库' : '登录后即可查看云端题库与离线缓存',
            actionLabel: this.signedIn ? '导入题库' : '去登录',
            showAction: this.signedIn,
            onAction: () => {
              if (this.signedIn) {
                this.openImportPage()
              }
            }
          })
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
      } else {
        List({ space: CARD_GAP }) {
          if (this.bannerMessage().length > 0) {
            ListItem() {
              this.StatusBanner()
            }
          }

          ForEach(this.banks, (bank: QuestionBankSummary) => {
            ListItem() {
              QuestionBankCard({
                bankName: bank.bankName,
                subject: bank.subject,
                questionCount: bank.questionCount,
                createDate: DateUtils.formatDate(bank.createTime),
                deleting: this.deletingBankId === bank.id || this.dialogPending,
                onOpen: () => {
                  this.openBank(bank.id)
                },
                onDelete: () => {
                  this.confirmDelete(bank)
                }
              })
            }
          }, (bank: QuestionBankSummary): string => bank.id)
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
        .contentEndOffset(TAB_BAR_CLEARANCE)
        .padding({
          left: PAGE_PADDING,
          right: PAGE_PADDING
        })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
