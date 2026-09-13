import { Context } from '@kit.AbilityKit'
import { AccountSessionState } from '../../models/AccountSession'
import { AiImportError, AiImportErrorCode, AiProviderConfig } from '../../models/ai/AiProviderConfig'
import { AccountSessionService } from '../AccountSessionService'
import { AiImportSaveService } from '../ai/AiImportSaveService'
import { AiProviderConfigStore } from '../ai/AiProviderConfigStore'
import { PdfAiImportCoordinator } from '../ai/PdfAiImportCoordinator'
import { PdfImportState } from '../../utils/PdfImportState'
import { PdfReviewAdapter, PdfReviewQuestion, PdfReviewSession, PdfReviewSource,
  PdfReviewSavePolicy } from './PdfReviewModels'
import { PdfReviewSessionStore } from './PdfReviewSession'

export class AiPdfReviewAdapter implements PdfReviewAdapter {
  private coordinator: PdfAiImportCoordinator = PdfAiImportCoordinator.createDefault()
  private sessionId: string = ''
  private accountId: string = ''

  async load(context: Context): Promise<PdfReviewSession> {
    const sessionId: string = PdfImportState.shared().getReviewSessionId()
    if (sessionId.length === 0) throw new Error('AI 识别草稿已失效')
    let session: PdfReviewSession | null = await AiImportSaveService.restore(context, sessionId)
    if (session === null) session = PdfReviewSessionStore.get(sessionId)
    if (session === null || session.source !== PdfReviewSource.AI) {
      throw new Error('AI 识别草稿已失效')
    }
    await this.requireAccount(context, session.accountId)
    this.sessionId = sessionId
    this.accountId = session.accountId
    return PdfReviewSessionStore.copyOf(session)
  }

  persist(session: PdfReviewSession): void {
    this.requireSession(session)
    if (!PdfReviewSavePolicy.canEdit(session.saveStage)) return
    PdfReviewSessionStore.put(PdfReviewSessionStore.copyOf(session))
  }

  async save(context: Context, session: PdfReviewSession): Promise<PdfReviewSession> {
    this.requireSession(session)
    await this.requireAccount(context, session.accountId)
    return AiImportSaveService.save(context, session)
  }

  async retryPage(context: Context, session: PdfReviewSession,
    pageNumber: number): Promise<PdfReviewSession> {
    this.requireSession(session)
    if (!PdfReviewSavePolicy.canEdit(session.saveStage)) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
    await this.requireAccount(context, session.accountId)
    const config: AiProviderConfig | null = await AiProviderConfigStore.loadUsable(context)
    if (config === null) throw new AiImportError(AiImportErrorCode.MISSING_MODEL)
    const updated: PdfReviewSession = await this.coordinator.retryPage(
      context, PdfReviewSessionStore.copyOf(session), pageNumber, config)
    await this.requireAccount(context, session.accountId)
    return PdfReviewSessionStore.copyOf(updated)
  }

  async abandon(context: Context, session: PdfReviewSession): Promise<void> {
    this.requireSession(session)
    if (!PdfReviewSavePolicy.canAbandon(session.saveStage)) {
      throw new Error('题目文字已保存，请完成原题图片保存')
    }
    this.coordinator.cancel()
    await AiImportSaveService.abandon(context, PdfReviewSessionStore.copyOf(session))
    PdfImportState.shared().clearReviewSessionId()
  }

  async discardFailure(context: Context, session: PdfReviewSession, pageNumber: number,
    replacement: PdfReviewQuestion | null): Promise<PdfReviewSession> {
    this.requireSession(session)
    const current: PdfReviewSession = await this.load(context)
    this.requireSession(session)
    if (!PdfReviewSavePolicy.canEdit(current.saveStage)) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
    const updated: PdfReviewSession = await this.coordinator.discardFailure(
      context, current, pageNumber, replacement)
    await this.requireAccount(context, session.accountId)
    return PdfReviewSessionStore.copyOf(updated)
  }

  private requireSession(session: PdfReviewSession): void {
    if (session.source !== PdfReviewSource.AI || session.sessionId !== this.sessionId ||
      session.accountId !== this.accountId ||
      PdfImportState.shared().getReviewSessionId() !== this.sessionId) {
      throw new Error('AI 识别草稿已失效')
    }
  }

  private async requireAccount(context: Context, accountId: string): Promise<void> {
    const account: AccountSessionState = await AccountSessionService.state(context)
    if (!account.signedIn || accountId.length === 0 || account.userId !== accountId) {
      throw new Error('当前华为账号与导入任务不一致')
    }
  }
}
