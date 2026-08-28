import { router } from '@kit.ArkUI'
import { AppHeader } from '../components/AppHeader'
import { EmptyState } from '../components/EmptyState'
import { QuestionBankCard } from '../components/QuestionBankCard'
import {
  BODY_FONT_SIZE,
  CARD_GAP,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_TEXT_CAPTION,
  PAGE_PADDING
} from '../constants/AppTheme'
import { QuestionBankSummary } from '../models/QuestionBank'
import { QuestionBankService } from '../services/QuestionBankService'
import {
  QuestionImageCleanupError,
  QuestionImageService
} from '../services/QuestionImageService'
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
    this.loadBanks(token)
  }

  private async loadBanks(token: number): Promise<void> {
    try {
      const banks: Array<QuestionBankSummary> = await QuestionBankService.listBanks()
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

  private openImportPage(): void {
    if (this.navigationPending || this.dialogPending || this.deletingBankId.length > 0) {
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
    this.dialogPending = true
    try {
      this.getUIContext().showAlertDialog({
        title: '删除题库？',
        message: '“' + bank.bankName + '”及其关联错题将从本机删除。',
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

  private async persistBankDeletion(bankId: string): Promise<void> {
    let imagePaths: Array<string> = new Array<string>()
    try {
      imagePaths = await QuestionBankService.deleteBank(bankId)
    } catch {
      if (this.deletingBankId !== bankId) {
        return
      }
      this.deletingBankId = ''
      this.showToast('删除题库失败，请稍后重试')
      return
    }
    let cleanupFailed: boolean = false
    try {
      await QuestionImageService.deletePaths(getContext(this), imagePaths)
    } catch (err) {
      cleanupFailed = true
      if (err instanceof QuestionImageCleanupError) {
        QuestionImageService.rememberCleanupDebt(err.paths)
      }
    }
    if (this.deletingBankId !== bankId) {
      return
    }
    this.deletingBankId = ''
    if (cleanupFailed) {
      this.showToast('题库已删除，部分缓存稍后清理')
    } else {
      this.showToast('题库已删除')
    }
    this.hasRequested = false
    this.refreshWhenActive()
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  build() {
    Column() {
      AppHeader({
        title: '我的题库',
        actionLabel: '导入题库',
        showAction: true,
        onAction: () => {
          this.openImportPage()
        }
      })

      if (this.loading) {
        Column({ space: 14 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(COLOR_PRIMARY)

          Text('正在加载题库')
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
      } else if (this.banks.length === 0) {
        EmptyState({
          glyph: '书',
          title: '还没有题库',
          description: '点击右上角导入你的第一个题库',
          actionLabel: '导入题库',
          showAction: true,
          onAction: () => {
            this.openImportPage()
          }
        })
        .layoutWeight(1)
      } else {
        List({ space: CARD_GAP }) {
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
