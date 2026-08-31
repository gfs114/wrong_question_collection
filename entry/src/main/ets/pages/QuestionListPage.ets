import { router } from '@kit.ArkUI'
import { AppHeader } from '../components/AppHeader'
import { EmptyState } from '../components/EmptyState'
import { QuestionCard } from '../components/QuestionCard'
import {
  BODY_FONT_SIZE,
  CARD_GAP,
  COLOR_CARD_BG,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_TEXT_CAPTION,
  COLOR_TEXT_PRIMARY,
  PAGE_PADDING
} from '../constants/AppTheme'
import { AccountSessionState } from '../models/AccountSession'
import { Question } from '../models/Question'
import { QuestionBankSummary } from '../models/QuestionBank'
import { AccountSessionService } from '../services/AccountSessionService'
import { CloudQuestionRepository } from '../services/CloudQuestionRepository'
import { ConnectivityPolicy } from '../services/ConnectivityPolicy'
import { NavigationState } from '../utils/NavigationState'

class QuestionListDataSource implements IDataSource {
  private items: Array<Question> = new Array<Question>()
  private listeners: Array<DataChangeListener> = new Array<DataChangeListener>()

  totalCount(): number {
    return this.items.length
  }

  getData(index: number): Question {
    return this.items[index]
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener)
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener)
    if (index >= 0) {
      this.listeners.splice(index, 1)
    }
  }

  replaceAll(items: Array<Question>): void {
    this.items = items.slice()
    for (let index: number = 0; index < this.listeners.length; index++) {
      const listener: DataChangeListener = this.listeners[index]
      listener.onDataReloaded()
    }
  }
}

@Entry
@Component
struct QuestionListPage {
  @State bankName: string = '题目列表'
  @State query: string = ''
  @State questions: Array<Question> = new Array<Question>()
  @State loading: boolean = false
  @State errorMessage: string = ''
  @State navigationPending: boolean = false
  @State signedIn: boolean = false
  @State offline: boolean = false
  @State accountId: string = ''
  private bankId: string = ''
  private cachedBankId: string = ''
  private requestToken: number = 0
  private bankQuestions: Array<Question> = new Array<Question>()
  private readonly questionDataSource: QuestionListDataSource = new QuestionListDataSource()

  onPageShow(): void {
    const selectedBankId: string = NavigationState.shared().selectedBankId
    if (selectedBankId !== this.bankId) {
      this.bankId = selectedBankId
      this.bankName = '题目列表'
      this.query = ''
      this.cachedBankId = ''
    }
    if (this.query.trim().length === 0) {
      this.loadBank()
    } else {
      this.search(this.query)
    }
  }

  private goBack(): void {
    if (this.navigationPending) {
      return
    }
    this.getUIContext().getRouter().back()
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

  private loadBank(): void {
    this.requestToken = this.requestToken + 1
    const token: number = this.requestToken
    this.loading = true
    this.errorMessage = ''
    this.replaceQuestions(new Array<Question>())
    this.loadSelectedBank(token)
  }

  private async loadSelectedBank(token: number): Promise<void> {
    if (this.bankId.length === 0) {
      if (token === this.requestToken) {
        this.errorMessage = '未找到所选题库'
        this.loading = false
      }
      return
    }
    const session: AccountSessionState = await AccountSessionService.state(getContext(this))
    if (token !== this.requestToken) {
      return
    }
    this.signedIn = session.signedIn
    this.accountId = session.userId
    if (!this.signedIn) {
      this.replaceQuestions(new Array<Question>())
      this.loading = false
      return
    }
    await this.refreshCloud(token)
    await this.loadCachedQuestions(token)
  }

  private async refreshCloud(token: number): Promise<void> {
    try {
      await CloudQuestionRepository.refresh(this.accountId, getContext(this))
      if (token === this.requestToken) {
        this.offline = false
      }
    } catch {
      if (token === this.requestToken) {
        this.offline = true
      }
    }
  }

  private async loadCachedQuestions(token: number): Promise<void> {
    try {
      const banks: Array<QuestionBankSummary> =
        await CloudQuestionRepository.listCachedBanks(this.accountId)
      if (token !== this.requestToken) {
        return
      }
      let bankName: string = '题目列表'
      let foundBank: boolean = false
      for (let index: number = 0; index < banks.length; index++) {
        if (banks[index].id === this.bankId) {
          bankName = banks[index].bankName
          foundBank = true
          break
        }
      }
      if (!foundBank) {
        this.errorMessage = '该题库不存在或已被删除'
        this.loading = false
        return
      }
      this.bankName = bankName
      const questions: Array<Question> =
        await CloudQuestionRepository.listCachedQuestions(this.accountId, this.bankId)
      if (token !== this.requestToken) {
        return
      }
      this.bankQuestions = questions.slice()
      this.cachedBankId = this.bankId
      this.replaceQuestions(questions)
      this.loading = false
    } catch {
      if (token !== this.requestToken) {
        return
      }
      this.errorMessage = '题目加载失败，请稍后重试'
      this.loading = false
    }
  }

  private search(value: string): void {
    this.query = value
    this.requestToken = this.requestToken + 1
    const token: number = this.requestToken
    this.loading = true
    this.errorMessage = ''
    this.replaceQuestions(new Array<Question>())
    this.searchQuestions(token, value)
  }

  private async searchQuestions(token: number, value: string): Promise<void> {
    if (this.bankId.length === 0) {
      if (token === this.requestToken) {
        this.errorMessage = '未找到所选题库'
        this.loading = false
      }
      return
    }
    if (this.cachedBankId !== this.bankId || this.bankQuestions.length === 0) {
      const session: AccountSessionState = await AccountSessionService.state(getContext(this))
      if (token !== this.requestToken) {
        return
      }
      this.signedIn = session.signedIn
      this.accountId = session.userId
      if (!this.signedIn) {
        this.replaceQuestions(new Array<Question>())
        this.loading = false
        return
      }
      await this.refreshCloud(token)
      try {
        const questions: Array<Question> =
          await CloudQuestionRepository.listCachedQuestions(this.accountId, this.bankId)
        if (token !== this.requestToken) {
          return
        }
        this.bankQuestions = questions.slice()
        this.cachedBankId = this.bankId
      } catch {
        if (token !== this.requestToken) {
          return
        }
        this.errorMessage = '搜索失败，请稍后重试'
        this.loading = false
        return
      }
    }
    const needle: string = value.trim()
    const filtered: Array<Question> = new Array<Question>()
    for (let index: number = 0; index < this.bankQuestions.length; index++) {
      if (needle.length === 0 || this.bankQuestions[index].question.indexOf(needle) >= 0) {
        filtered.push(this.bankQuestions[index])
      }
    }
    if (token !== this.requestToken) {
      return
    }
    this.replaceQuestions(filtered)
    this.loading = false
  }

  private retry(): void {
    if (this.bankName === '题目列表') {
      this.loadBank()
      return
    }
    this.search(this.query)
  }

  private replaceQuestions(questions: Array<Question>): void {
    this.questions = questions.slice()
    this.questionDataSource.replaceAll(questions)
  }

  private cardTypeLabel(question: Question): string {
    if (question.type === 'unclassified') {
      return '未分类题'
    }
    return question.getTypeLabel()
  }

  private openQuestion(question: Question, index: number): void {
    if (this.navigationPending) {
      return
    }
    const orderedIds: Array<string> = new Array<string>()
    for (let itemIndex: number = 0; itemIndex < this.questions.length; itemIndex++) {
      orderedIds.push(this.questions[itemIndex].id)
    }
    this.navigationPending = true
    NavigationState.shared().selectQuestion(question.id, this.bankId, orderedIds, index)
    const options: router.RouterOptions = {
      url: 'pages/QuestionDetailPage'
    }
    this.getUIContext().getRouter().pushUrl(options).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '题目详情暂不可用' })
    }).finally(() => {
      this.navigationPending = false
    })
  }

  build() {
    Column() {
      AppHeader({
        title: this.bankName,
        showBack: true,
        onBack: () => {
          this.goBack()
        }
      })

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

      Row({ space: 10 }) {
        Text('搜')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_PRIMARY)

        TextInput({ placeholder: '搜索题目内容', text: this.query })
          .layoutWeight(1)
          .height(48)
          .fontSize(BODY_FONT_SIZE)
          .fontColor(COLOR_TEXT_PRIMARY)
          .placeholderColor(COLOR_TEXT_CAPTION)
          .backgroundColor(COLOR_CARD_BG)
          .onChange((value: string) => {
            this.search(value)
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 14, right: 8 })
      .margin({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 14 })
      .backgroundColor(COLOR_CARD_BG)
      .borderRadius(16)

      if (this.loading) {
        Column({ space: 14 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(COLOR_PRIMARY)

          Text(this.query.length === 0 ? '正在加载题目' : '正在搜索题目')
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
      } else if (this.questions.length === 0) {
        EmptyState({
          glyph: '题',
          title: this.query.trim().length === 0 ? '题库中暂无题目' : '没有匹配的题目',
          description: this.query.trim().length === 0 ? '请返回并导入包含题目的题库' : '换个关键词再试试'
        })
        .layoutWeight(1)
      } else {
        List({ space: CARD_GAP }) {
          LazyForEach(this.questionDataSource, (question: Question, index: number) => {
            ListItem() {
              QuestionCard({
                sequence: index + 1,
                typeLabel: this.cardTypeLabel(question),
                questionText: question.question,
                needsReview: question.needsReview(),
                onOpen: () => {
                  this.openQuestion(question, index)
                }
              })
            }
          }, (question: Question): string => question.id)
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
