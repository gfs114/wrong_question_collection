import { router } from '@kit.ArkUI'
import { AppHeader } from '../components/AppHeader'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  COLOR_CARD_BG,
  COLOR_DANGER,
  COLOR_PAGE_BG,
  COLOR_PRIMARY,
  COLOR_TEXT_PRIMARY,
  PAGE_PADDING,
  SUBTITLE_FONT_SIZE
} from '../constants/AppTheme'
import { PdfFileSelection, PdfImportSettings, PdfPageFailure, PdfQuestionDraft } from '../models/PdfImportModels'
import { Question } from '../models/Question'
import { QuestionBank } from '../models/QuestionBank'
import { QuestionImage } from '../models/QuestionImage'
import {
  PdfBankSaveUncertainError,
  QuestionBankService
} from '../services/QuestionBankService'
import {
  QuestionImageCleanupError,
  QuestionImageRollbackError,
  QuestionImageService
} from '../services/QuestionImageService'
import { PdfImportService } from '../services/PdfImportService'
import { PdfStorageError } from '../services/PdfStorageError'
import { IdUtils } from '../utils/IdUtils'
import { NavigationState } from '../utils/NavigationState'
import { PdfImportState } from '../utils/PdfImportState'

@Entry
@Component
struct PdfImportReviewPage {
  @State drafts: Array<PdfQuestionDraft> = new Array<PdfQuestionDraft>()
  @State failures: Array<PdfPageFailure> = new Array<PdfPageFailure>()
  @State pending: boolean = false
  @State dialogOpen: boolean = false
  @State discarding: boolean = false
  @State cleanupPending: boolean = false
  @State rollbackPending: boolean = false
  @State databaseRecoveryPending: boolean = false
  @State discardCompleted: boolean = false
  @State navigationRetryPending: boolean = false
  @State saveCompleted: boolean = false
  @State postSavePdfCleanupPending: boolean = false
  @State errorMessage: string = ''
  private initialized: boolean = false
  private savedBankId: string = ''
  private postSavePdfPath: string = ''
  private postSaveWarning: string = ''
  private successfulSaveFinalized: boolean = false
  private cleanupPaths: Array<string> = new Array<string>()
  private cleanupPdfPath: string = ''
  private rollbackBankId: string = ''
  private rollbackCachePaths: Array<string> = new Array<string>()
  private rollbackCommittedPaths: Array<string> = new Array<string>()
  private recoveryBank: QuestionBank | null = null
  private recoveryBankId: string = ''
  private recoveryCachePaths: Array<string> = new Array<string>()
  private recoveryCommittedPaths: Array<string> = new Array<string>()

  aboutToAppear(): void {
    if (this.initialized) {
      return
    }
    this.initialized = true
    this.drafts = PdfImportState.shared().getDrafts()
    this.failures = PdfImportState.shared().getFailures()
    if (this.drafts.length === 0) {
      this.errorMessage = '没有可审核的识别题目'
    }
  }

  onBackPress(): boolean {
    this.discardImport()
    return true
  }

  private replaceDraft(localId: string, type: string, question: string, options: Array<string>,
    answer: string, analysis: string): void {
    const index: number = this.findDraftIndex(localId)
    if (index < 0) {
      return
    }
    const source: PdfQuestionDraft = this.drafts[index]
    const replacement: PdfQuestionDraft = new PdfQuestionDraft(
      source.localId, type, question, options.slice(), answer, analysis, source.sourcePageStart,
      source.sourcePageEnd, source.reviewState, source.crops.slice(), source.imagePaths.slice())
    const nextDrafts: Array<PdfQuestionDraft> = this.drafts.slice()
    nextDrafts.splice(index, 1, replacement)
    this.drafts = nextDrafts
    PdfImportState.shared().setDrafts(nextDrafts)
  }

  private updateQuestionText(localId: string, value: string): void {
    const index: number = this.findDraftIndex(localId)
    if (index < 0) {
      return
    }
    const draft: PdfQuestionDraft = this.drafts[index]
    this.replaceDraft(localId, draft.type, value, draft.options, draft.answer, draft.analysis)
  }

  private updateOption(localId: string, optionIndex: number, value: string): void {
    const index: number = this.findDraftIndex(localId)
    if (index < 0) {
      return
    }
    const draft: PdfQuestionDraft = this.drafts[index]
    if (optionIndex < 0 || optionIndex >= draft.options.length) {
      return
    }
    const options: Array<string> = draft.options.slice()
    options.splice(optionIndex, 1, value)
    this.replaceDraft(localId, draft.type, draft.question, options, draft.answer, draft.analysis)
  }

  private updateAnswer(localId: string, value: string): void {
    const index: number = this.findDraftIndex(localId)
    if (index < 0) {
      return
    }
    const draft: PdfQuestionDraft = this.drafts[index]
    this.replaceDraft(localId, draft.type, draft.question, draft.options, value, draft.analysis)
  }

  private updateAnalysis(localId: string, value: string): void {
    const index: number = this.findDraftIndex(localId)
    if (index < 0) {
      return
    }
    const draft: PdfQuestionDraft = this.drafts[index]
    this.replaceDraft(localId, draft.type, draft.question, draft.options, draft.answer, value)
  }

  private updateType(localId: string, value: string): void {
    const index: number = this.findDraftIndex(localId)
    if (index < 0) {
      return
    }
    const draft: PdfQuestionDraft = this.drafts[index]
    this.replaceDraft(localId, value, draft.question, draft.options, draft.answer, draft.analysis)
  }

  private findDraftIndex(localId: string): number {
    for (let index: number = 0; index < this.drafts.length; index++) {
      if (this.drafts[index].localId === localId) {
        return index
      }
    }
    return -1
  }

  private confirmDeleteDraft(localId: string): void {
    if (this.pending || this.discarding || this.dialogOpen || this.saveCompleted || this.rollbackPending ||
      this.databaseRecoveryPending || this.discardCompleted) {
      return
    }
    this.dialogOpen = true
    try {
      this.getUIContext().showAlertDialog({
        title: '删除此题',
        message: '删除后将同时清理这道题的识别图片，是否继续？',
        autoCancel: false,
        primaryButton: {
          value: '删除',
          action: () => {
            this.dialogOpen = false
            this.deleteDraft(localId)
          }
        },
        secondaryButton: {
          value: '取消',
          action: () => {
            this.dialogOpen = false
          }
        }
      })
    } catch {
      this.dialogOpen = false
      this.errorMessage = '删除确认窗口暂不可用'
    }
  }

  private async deleteDraft(localId: string): Promise<void> {
    if (this.pending || this.discarding || this.saveCompleted || this.rollbackPending ||
      this.databaseRecoveryPending || this.discardCompleted) {
      return
    }
    const index: number = this.findDraftIndex(localId)
    if (index < 0) {
      return
    }
    const draft: PdfQuestionDraft = this.drafts[index]
    this.pending = true
    this.errorMessage = ''
    try {
      await QuestionImageService.deletePaths(getContext(this), draft.imagePaths)
      const nextDrafts: Array<PdfQuestionDraft> = this.drafts.slice()
      nextDrafts.splice(index, 1)
      this.drafts = nextDrafts
      PdfImportState.shared().setDrafts(nextDrafts)
    } catch {
      this.errorMessage = '题目图片删除失败，请重试'
    } finally {
      this.pending = false
    }
  }

  private validateDrafts(): string {
    if (this.drafts.length === 0) {
      return '请至少保留一道题目'
    }
    for (let index: number = 0; index < this.drafts.length; index++) {
      const draft: PdfQuestionDraft = this.drafts[index]
      const fallbackHasImage: boolean = draft.type === 'unclassified' && draft.imagePaths.length > 0
      if (draft.question.trim().length === 0 &&
        (draft.type !== 'unclassified' || !fallbackHasImage)) {
        return '第 ' + (index + 1).toString() + ' 题缺少题干，请补充后保存'
      }
    }
    return ''
  }

  private collectLocalImagePaths(): Array<string> {
    const paths: Array<string> = new Array<string>()
    for (let draftIndex: number = 0; draftIndex < this.drafts.length; draftIndex++) {
      const draft: PdfQuestionDraft = this.drafts[draftIndex]
      for (let imageIndex: number = 0; imageIndex < draft.imagePaths.length; imageIndex++) {
        paths.push(draft.imagePaths[imageIndex])
      }
    }
    return paths
  }

  private draftsWithCommittedImagePaths(committedPaths: Array<string>): Array<PdfQuestionDraft> {
    const committedDrafts: Array<PdfQuestionDraft> = new Array<PdfQuestionDraft>()
    let committedIndex: number = 0
    for (let draftIndex: number = 0; draftIndex < this.drafts.length; draftIndex++) {
      const draft: PdfQuestionDraft = this.drafts[draftIndex]
      const imagePaths: Array<string> = new Array<string>()
      for (let imageIndex: number = 0; imageIndex < draft.imagePaths.length; imageIndex++) {
        if (committedIndex >= committedPaths.length) {
          throw new Error('已提交题图数量不足')
        }
        imagePaths.push(committedPaths[committedIndex])
        committedIndex++
      }
      committedDrafts.push(new PdfQuestionDraft(
        draft.localId, draft.type, draft.question, draft.options.slice(), draft.answer, draft.analysis,
        draft.sourcePageStart, draft.sourcePageEnd, draft.reviewState, draft.crops.slice(), imagePaths))
    }
    if (committedIndex !== committedPaths.length) {
      throw new Error('已提交题图数量不匹配')
    }
    return committedDrafts
  }

  private async saveBank(): Promise<void> {
    if (this.pending || this.discarding || this.dialogOpen || this.rollbackPending ||
      this.databaseRecoveryPending || this.discardCompleted) {
      return
    }
    if (this.saveCompleted) {
      await this.navigateToSavedBank()
      return
    }
    const validationMessage: string = this.validateDrafts()
    if (validationMessage.length > 0) {
      this.errorMessage = validationMessage
      return
    }
    const settings: PdfImportSettings | null = PdfImportState.shared().getSettings()
    if (settings === null) {
      this.errorMessage = 'PDF 导入设置已失效，请重新导入'
      return
    }
    this.pending = true
    this.errorMessage = ''
    const bankId: string = IdUtils.create('bank_')
    const cachePaths: Array<string> = this.collectLocalImagePaths()
    let committedPaths: Array<string> = new Array<string>()
    let bank: QuestionBank | null = null
    try {
      committedPaths = await QuestionImageService.commitImages(getContext(this), bankId, cachePaths)
    } catch (err) {
      if (err instanceof QuestionImageRollbackError) {
        this.rollbackPending = true
        this.rollbackBankId = err.bankId
        this.rollbackCachePaths = err.cachePaths.slice()
        this.rollbackCommittedPaths = err.committedPaths.slice()
        this.errorMessage = err.debtRegistered ? '部分题图待恢复，请先重试清理' :
          '题图恢复记录保存失败，页面已冻结，请勿退出并重试恢复'
        this.pending = false
        return
      }
      this.errorMessage = err instanceof PdfStorageError ? '本地空间不足或图片保存失败' :
        'PDF 导入失败，请重新选择文件'
      this.pending = false
      return
    }
    try {
      const committedDrafts: Array<PdfQuestionDraft> = this.draftsWithCommittedImagePaths(committedPaths)
      const questions: Array<Question> = new Array<Question>()
      for (let draftIndex: number = 0; draftIndex < committedDrafts.length; draftIndex++) {
        const draft: PdfQuestionDraft = committedDrafts[draftIndex]
        const images: Array<QuestionImage> = new Array<QuestionImage>()
        for (let imageIndex: number = 0; imageIndex < draft.imagePaths.length; imageIndex++) {
          const committedPath: string = draft.imagePaths[imageIndex]
          const pageNumber: number = imageIndex < draft.crops.length ?
            draft.crops[imageIndex].pageNumber : draft.sourcePageStart
          images.push(new QuestionImage(
            'image_' + draft.localId + '_' + imageIndex.toString(), draft.localId, pageNumber,
            committedPath, imageIndex))
        }
        const storedType: string = draft.type === 'unclassified' ? 'unclassified' : draft.type
        const storedReviewState: string = draft.type === 'unclassified' ? 'needs_review' : 'confirmed'
        questions.push(new Question(
          draft.localId, bankId, storedType, draft.question, draft.options.slice(), draft.answer,
          draft.analysis, draft.sourcePageStart, draft.sourcePageEnd, storedReviewState, images))
      }
      bank = new QuestionBank(
        bankId, settings.bankName, settings.subject, questions.length, Date.now(), false, questions)
      await QuestionBankService.savePdfBank(bank, bankId)
    } catch (err) {
      if (err instanceof PdfBankSaveUncertainError && bank !== null) {
        await this.resolveUncertainSave(bank, bankId, cachePaths, committedPaths)
        return
      }
      try {
        await QuestionImageService.rollbackCommittedImages(
          getContext(this), bankId, cachePaths, committedPaths)
      } catch (rollbackErr) {
        this.rollbackPending = true
        this.rollbackBankId = bankId
        this.rollbackCachePaths = cachePaths.slice()
        this.rollbackCommittedPaths = committedPaths.slice()
        this.errorMessage = rollbackErr instanceof QuestionImageRollbackError && !rollbackErr.debtRegistered ?
          '题图恢复记录保存失败，页面已冻结，请勿退出并重试恢复' :
          '题库保存失败，部分题图待恢复，请先重试清理'
        this.pending = false
        return
      }
      this.errorMessage = '题库保存失败，请稍后重试'
      this.pending = false
      return
    }
    await this.completeSuccessfulSave(bankId)
  }

  private async completeSuccessfulSave(bankId: string): Promise<void> {
    this.saveCompleted = true
    this.savedBankId = bankId
    const ownershipFinished: boolean = await this.finishSuccessfulPdfOwnership()
    if (!ownershipFinished) {
      this.postSavePdfCleanupPending = true
      this.pending = false
      return
    }
    await this.finalizeSuccessfulSave()
  }

  private async finishSuccessfulPdfOwnership(): Promise<boolean> {
    const selection: PdfFileSelection | null = PdfImportState.shared().getSelection()
    if (selection === null) {
      this.errorMessage = '题库已保存，但 PDF 临时文件信息已丢失'
      return false
    }
    this.postSavePdfPath = selection.uri
    try {
      await PdfImportService.removeTemporaryPdf(selection.uri)
      this.postSavePdfPath = ''
      this.postSaveWarning = ''
      return true
    } catch {
      try {
        PdfImportService.abandonTemporaryPdf(selection.uri)
        this.postSavePdfPath = ''
        this.postSaveWarning = 'PDF 临时文件将在下次选择 PDF 时继续清理'
        return true
      } catch {
        this.postSavePdfPath = selection.uri
        this.errorMessage = '题库已保存，但 PDF 临时文件清理和稍后处理均失败'
        return false
      }
    }
  }

  private async finalizeSuccessfulSave(): Promise<void> {
    if (this.successfulSaveFinalized) {
      await this.navigateToSavedBank()
      return
    }
    this.successfulSaveFinalized = true
    this.postSavePdfCleanupPending = false
    PdfImportState.shared().reset()
    this.showToast('题库导入成功')
    if (this.postSaveWarning.length > 0) {
      this.showToast(this.postSaveWarning)
    }
    NavigationState.shared().selectBank(this.savedBankId)
    const options: router.RouterOptions = {
      url: 'pages/QuestionListPage'
    }
    try {
      await this.getUIContext().getRouter().replaceUrl(options)
    } catch {
      this.errorMessage = '题库已保存，题目列表暂不可用，请重试进入'
    } finally {
      this.pending = false
    }
  }

  private async retryPostSavePdfCleanup(): Promise<void> {
    if (this.pending || !this.postSavePdfCleanupPending || this.postSavePdfPath.length === 0) {
      return
    }
    this.pending = true
    this.errorMessage = ''
    try {
      await PdfImportService.removeTemporaryPdf(this.postSavePdfPath)
      this.postSavePdfPath = ''
      this.postSaveWarning = ''
      await this.finalizeSuccessfulSave()
    } catch {
      this.postSavePdfCleanupPending = true
      this.errorMessage = '题库已保存，PDF 临时文件清理仍失败，请重试或稍后处理'
      this.pending = false
    }
  }

  private async deferPostSavePdfCleanup(): Promise<void> {
    if (this.pending || !this.postSavePdfCleanupPending || this.postSavePdfPath.length === 0) {
      return
    }
    this.pending = true
    this.errorMessage = ''
    try {
      PdfImportService.abandonTemporaryPdf(this.postSavePdfPath)
      this.postSavePdfPath = ''
      this.postSaveWarning = 'PDF 临时文件将在下次选择 PDF 时继续清理'
      await this.finalizeSuccessfulSave()
    } catch {
      this.postSavePdfCleanupPending = true
      this.errorMessage = '题库已保存，PDF 临时文件稍后处理登记失败，请重试'
      this.pending = false
    }
  }

  private async resolveUncertainSave(bank: QuestionBank, bankId: string, cachePaths: Array<string>,
    committedPaths: Array<string>): Promise<void> {
    try {
      const resolution: string = await QuestionBankService.resolvePdfBankSave(bank, bankId)
      if (resolution === 'committed') {
        this.clearDatabaseRecovery()
        await this.completeSuccessfulSave(bankId)
        return
      }
      if (resolution === 'absent') {
        this.clearDatabaseRecovery()
        try {
          await QuestionImageService.rollbackCommittedImages(
            getContext(this), bankId, cachePaths, committedPaths)
          this.errorMessage = '未发现已保存题库，题图已恢复，可重新保存'
        } catch (rollbackErr) {
          this.rollbackPending = true
          this.rollbackBankId = bankId
          this.rollbackCachePaths = cachePaths.slice()
          this.rollbackCommittedPaths = committedPaths.slice()
          this.errorMessage = rollbackErr instanceof QuestionImageRollbackError && !rollbackErr.debtRegistered ?
            '题图恢复记录保存失败，页面已冻结，请勿退出并重试恢复' :
            '数据库未保存，部分题图待恢复，请先重试清理'
        }
        this.pending = false
        return
      }
      this.setDatabaseRecovery(bank, bankId, cachePaths, committedPaths,
        '数据库中存在不完整题库，请重新核验保存状态')
    } catch {
      this.setDatabaseRecovery(bank, bankId, cachePaths, committedPaths,
        '数据库保存状态暂无法核验，请重试')
    }
  }

  private setDatabaseRecovery(bank: QuestionBank, bankId: string, cachePaths: Array<string>,
    committedPaths: Array<string>, message: string): void {
    this.databaseRecoveryPending = true
    this.recoveryBank = bank
    this.recoveryBankId = bankId
    this.recoveryCachePaths = cachePaths.slice()
    this.recoveryCommittedPaths = committedPaths.slice()
    this.errorMessage = message
    this.pending = false
  }

  private clearDatabaseRecovery(): void {
    this.databaseRecoveryPending = false
    this.recoveryBank = null
    this.recoveryBankId = ''
    this.recoveryCachePaths = new Array<string>()
    this.recoveryCommittedPaths = new Array<string>()
  }

  private async retryDatabaseRecovery(): Promise<void> {
    if (this.pending || !this.databaseRecoveryPending || this.recoveryBank === null) {
      return
    }
    this.pending = true
    await this.resolveUncertainSave(
      this.recoveryBank,
      this.recoveryBankId,
      this.recoveryCachePaths,
      this.recoveryCommittedPaths)
  }

  private async retryRollback(): Promise<void> {
    if (this.pending || !this.rollbackPending) {
      return
    }
    this.pending = true
    this.errorMessage = ''
    try {
      await QuestionImageService.rollbackCommittedImages(
        getContext(this), this.rollbackBankId, this.rollbackCachePaths, this.rollbackCommittedPaths)
      this.rollbackPending = false
      this.rollbackBankId = ''
      this.rollbackCachePaths = new Array<string>()
      this.rollbackCommittedPaths = new Array<string>()
      this.errorMessage = '题图已恢复，可重新保存题库'
    } catch (rollbackErr) {
      this.errorMessage = rollbackErr instanceof QuestionImageRollbackError && !rollbackErr.debtRegistered ?
        '题图恢复记录保存失败，请保持当前页面并重试' : '题图仍未完全恢复，请重试'
    } finally {
      this.pending = false
    }
  }

  private async navigateToSavedBank(): Promise<void> {
    if (this.pending || this.savedBankId.length === 0) {
      return
    }
    this.pending = true
    NavigationState.shared().selectBank(this.savedBankId)
    const options: router.RouterOptions = {
      url: 'pages/QuestionListPage'
    }
    try {
      await this.getUIContext().getRouter().replaceUrl(options)
    } catch {
      this.errorMessage = '题库已保存，题目列表暂不可用，请重试进入'
    } finally {
      this.pending = false
    }
  }

  private async discardImport(): Promise<void> {
    if (this.navigationRetryPending || this.discardCompleted) {
      this.retryDiscardNavigation()
      return
    }
    if (this.pending || this.discarding || this.dialogOpen || this.saveCompleted || this.rollbackPending ||
      this.databaseRecoveryPending) {
      if (this.databaseRecoveryPending) {
        this.errorMessage = '请先重新核验数据库保存状态'
      } else if (this.rollbackPending) {
        this.errorMessage = '请先完成题图恢复再返回'
      }
      return
    }
    this.dialogOpen = true
    try {
      this.getUIContext().showAlertDialog({
        title: '丢弃识别结果',
        message: '返回后将删除尚未保存的题目和图片，是否继续？',
        autoCancel: false,
        primaryButton: {
          value: '丢弃',
          action: () => {
            this.dialogOpen = false
            this.performDiscard()
          }
        },
        secondaryButton: {
          value: '继续审核',
          action: () => {
            this.dialogOpen = false
          }
        }
      })
    } catch {
      this.dialogOpen = false
      this.errorMessage = '丢弃确认窗口暂不可用'
    }
  }

  private async performDiscard(): Promise<void> {
    if (this.pending || this.discarding) {
      return
    }
    this.discarding = true
    this.pending = true
    this.errorMessage = ''
    const selection: PdfFileSelection | null = PdfImportState.shared().getSelection()
    const paths: Array<string> = this.collectDraftImagePaths()
    this.cleanupPaths = paths.slice()
    this.cleanupPdfPath = selection === null ? '' : selection.uri
    try {
      await QuestionImageService.deletePaths(getContext(this), paths)
      this.cleanupPaths = new Array<string>()
    } catch (err) {
      if (err instanceof QuestionImageCleanupError) {
        this.cleanupPaths = err.paths.slice()
      }
    }
    if (selection !== null) {
      try {
        await PdfImportService.removeTemporaryPdf(selection.uri)
        this.cleanupPdfPath = ''
      } catch {
      }
    }
    if (this.cleanupPaths.length > 0 || this.cleanupPdfPath.length > 0) {
      this.cleanupPending = true
      this.errorMessage = '识别缓存清理失败，请重试；识别结果仍已保留'
      this.discarding = false
      this.pending = false
      return
    }
    this.cleanupPending = false
    this.cleanupPaths = new Array<string>()
    this.cleanupPdfPath = ''
    this.discardCompleted = true
    this.drafts = new Array<PdfQuestionDraft>()
    this.failures = new Array<PdfPageFailure>()
    PdfImportState.shared().reset()
    await this.navigateAfterDiscard()
  }

  private async retryDiscardCleanup(): Promise<void> {
    if (this.pending || this.discarding || !this.cleanupPending) {
      return
    }
    this.discarding = true
    this.pending = true
    this.errorMessage = ''
    if (this.cleanupPaths.length > 0) {
      try {
        await QuestionImageService.deletePaths(getContext(this), this.cleanupPaths)
        this.cleanupPaths = new Array<string>()
      } catch (err) {
        if (err instanceof QuestionImageCleanupError) {
          this.cleanupPaths = err.paths.slice()
        }
      }
    }
    if (this.cleanupPdfPath.length > 0) {
      try {
        await PdfImportService.removeTemporaryPdf(this.cleanupPdfPath)
        this.cleanupPdfPath = ''
      } catch {
      }
    }
    if (this.cleanupPaths.length > 0 || this.cleanupPdfPath.length > 0) {
      this.errorMessage = '识别缓存清理失败，请重试；识别结果仍已保留'
      this.discarding = false
      this.pending = false
      return
    }
    this.cleanupPending = false
    this.discardCompleted = true
    this.drafts = new Array<PdfQuestionDraft>()
    this.failures = new Array<PdfPageFailure>()
    PdfImportState.shared().reset()
    await this.navigateAfterDiscard()
  }

  private async rememberDebtAndDiscard(): Promise<void> {
    if (this.pending || this.discarding || !this.cleanupPending) {
      return
    }
    this.discarding = true
    this.pending = true
    if (this.cleanupPaths.length > 0) {
      QuestionImageService.rememberCleanupDebt(this.cleanupPaths)
    }
    if (this.cleanupPdfPath.length > 0) {
      try {
        PdfImportService.abandonTemporaryPdf(this.cleanupPdfPath)
      } catch {
        this.errorMessage = 'PDF 临时文件稍后清理登记失败，识别结果仍已保留'
        this.discarding = false
        this.pending = false
        return
      }
    }
    this.cleanupPaths = new Array<string>()
    this.cleanupPdfPath = ''
    this.discardCompleted = true
    this.drafts = new Array<PdfQuestionDraft>()
    this.failures = new Array<PdfPageFailure>()
    PdfImportState.shared().reset()
    await this.navigateAfterDiscard()
  }

  private async navigateAfterDiscard(): Promise<void> {
    if (!this.discardCompleted) {
      return
    }
    const options: router.RouterOptions = {
      url: 'pages/ImportBankPage'
    }
    try {
      await this.getUIContext().getRouter().replaceUrl(options)
      this.navigationRetryPending = false
    } catch {
      this.navigationRetryPending = true
      this.errorMessage = '识别结果已丢弃，请重试返回导入页面'
    } finally {
      this.discarding = false
      this.pending = false
    }
  }

  private retryDiscardNavigation(): void {
    if (this.pending || !this.discardCompleted) {
      return
    }
    this.pending = true
    this.navigateAfterDiscard()
  }

  private collectDraftImagePaths(): Array<string> {
    const drafts: Array<PdfQuestionDraft> = PdfImportState.shared().getDrafts()
    const paths: Array<string> = new Array<string>()
    for (let draftIndex: number = 0; draftIndex < drafts.length; draftIndex++) {
      const draft: PdfQuestionDraft = drafts[draftIndex]
      for (let pathIndex: number = 0; pathIndex < draft.imagePaths.length; pathIndex++) {
        const path: string = draft.imagePaths[pathIndex]
        if (paths.indexOf(path) < 0) {
          paths.push(path)
        }
      }
    }
    return paths
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch {
    }
  }

  private typeLabel(type: string): string {
    if (type === 'single_choice') {
      return '单选题'
    }
    if (type === 'fill_blank') {
      return '填空题'
    }
    if (type === 'short_answer') {
      return '解答题'
    }
    return '待确认'
  }

  build() {
    Column() {
      AppHeader({
        title: '识别结果',
        showBack: true,
        onBack: () => {
          this.discardImport()
        }
      })

      if (this.failures.length > 0 && !this.discardCompleted) {
        Column({ space: 6 }) {
          Text('部分页面识别失败，请检查标记页')
            .width('100%')
            .fontSize(BODY_FONT_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_DANGER)
          ForEach(this.failures, (failure: PdfPageFailure) => {
            Text(failure.message)
              .width('100%')
              .fontSize(12)
              .fontColor(COLOR_TEXT_PRIMARY)
          }, (failure: PdfPageFailure): string => failure.pageNumber.toString())
        }
        .width('100%')
        .padding(14)
        .margin({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 10 })
        .backgroundColor('#FFF7E8')
        .borderRadius(14)
      }

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .width('100%')
          .constraintSize({ minHeight: 48 })
          .padding({ left: 16, right: 16, top: 13, bottom: 13 })
          .margin({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 10 })
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.errorMessage === '题图已恢复，可重新保存题库' ? COLOR_PRIMARY : COLOR_DANGER)
          .backgroundColor(this.errorMessage === '题图已恢复，可重新保存题库' ? '#EEF5FF' : '#FFF2F2')
          .borderRadius(14)
      }

      if (this.navigationRetryPending) {
        Column({ space: 16 }) {
          Text('识别结果已丢弃，请重试返回导入页面')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(COLOR_TEXT_PRIMARY)
          Button(this.pending ? '正在返回…' : '重试返回导入页面')
            .width('100%')
            .height(52)
            .fontColor('#FFFFFF')
            .backgroundColor(COLOR_PRIMARY)
            .enabled(!this.pending)
            .onClick(() => { this.retryDiscardNavigation() })
        }
        .layoutWeight(1)
        .width('100%')
        .padding(PAGE_PADDING)
        .justifyContent(FlexAlign.Center)
      } else if (this.postSavePdfCleanupPending) {
        Column({ space: 16 }) {
          Text('题库已保存，请完成 PDF 临时文件清理后进入题目列表。')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(COLOR_TEXT_PRIMARY)
          Button(this.pending ? '正在清理…' : '重试清理并完成')
            .width('100%')
            .height(52)
            .fontColor('#FFFFFF')
            .backgroundColor(COLOR_PRIMARY)
            .enabled(!this.pending)
            .onClick(() => { this.retryPostSavePdfCleanup() })
          Button('稍后处理')
            .width('100%')
            .height(48)
            .fontColor(COLOR_PRIMARY)
            .backgroundColor(COLOR_CARD_BG)
            .border({ width: 1, color: COLOR_PRIMARY })
            .enabled(!this.pending)
            .onClick(() => { this.deferPostSavePdfCleanup() })
        }
        .layoutWeight(1)
        .width('100%')
        .padding(PAGE_PADDING)
        .justifyContent(FlexAlign.Center)
      } else if (this.databaseRecoveryPending) {
        Column({ space: 16 }) {
          Text('保存状态需要重新核验，核验完成前不会移动或删除题图。')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(COLOR_TEXT_PRIMARY)
          Button(this.pending ? '正在核验…' : '重新核验保存状态')
            .width('100%')
            .height(52)
            .fontColor('#FFFFFF')
            .backgroundColor(COLOR_PRIMARY)
            .enabled(!this.pending)
            .onClick(() => { this.retryDatabaseRecovery() })
        }
        .layoutWeight(1)
        .width('100%')
        .padding(PAGE_PADDING)
        .justifyContent(FlexAlign.Center)
      } else {
      List({ space: 14 }) {
        ForEach(this.drafts, (draft: PdfQuestionDraft, draftIndex: number) => {
          ListItem() {
            Column({ space: 14 }) {
              Row() {
                Text('第 ' + (draftIndex + 1).toString() + ' 题')
                  .fontSize(SUBTITLE_FONT_SIZE)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(COLOR_TEXT_PRIMARY)
                Blank()
                Text(this.typeLabel(draft.type))
                  .fontSize(12)
                  .fontColor(draft.type === 'unclassified' ? COLOR_DANGER : COLOR_PRIMARY)
              }
              .width('100%')

              ForEach(draft.imagePaths, (imagePath: string) => {
                Image('file://' + imagePath)
                  .width('100%')
                  .height(180)
                  .objectFit(ImageFit.Contain)
                  .backgroundColor('#F0F3F8')
                  .borderRadius(12)
              }, (imagePath: string): string => imagePath)

              Row({ space: 6 }) {
                Button('单选').layoutWeight(1).height(38)
                  .fontColor(draft.type === 'single_choice' ? '#FFFFFF' : COLOR_PRIMARY)
                  .backgroundColor(draft.type === 'single_choice' ? COLOR_PRIMARY : '#EEF5FF')
                  .enabled(!this.pending && !this.discarding && !this.saveCompleted && !this.rollbackPending)
                  .onClick(() => { this.updateType(draft.localId, 'single_choice') })
                Button('填空').layoutWeight(1).height(38)
                  .fontColor(draft.type === 'fill_blank' ? '#FFFFFF' : COLOR_PRIMARY)
                  .backgroundColor(draft.type === 'fill_blank' ? COLOR_PRIMARY : '#EEF5FF')
                  .enabled(!this.pending && !this.discarding && !this.saveCompleted && !this.rollbackPending)
                  .onClick(() => { this.updateType(draft.localId, 'fill_blank') })
                Button('解答').layoutWeight(1).height(38)
                  .fontColor(draft.type === 'short_answer' ? '#FFFFFF' : COLOR_PRIMARY)
                  .backgroundColor(draft.type === 'short_answer' ? COLOR_PRIMARY : '#EEF5FF')
                  .enabled(!this.pending && !this.discarding && !this.saveCompleted && !this.rollbackPending)
                  .onClick(() => { this.updateType(draft.localId, 'short_answer') })
                Button('待确认').layoutWeight(1).height(38)
                  .fontColor(draft.type === 'unclassified' ? '#FFFFFF' : COLOR_PRIMARY)
                  .backgroundColor(draft.type === 'unclassified' ? COLOR_PRIMARY : '#EEF5FF')
                  .enabled(!this.pending && !this.discarding && !this.saveCompleted && !this.rollbackPending)
                  .onClick(() => { this.updateType(draft.localId, 'unclassified') })
              }
              .width('100%')

              TextArea({ placeholder: '请输入题干', text: draft.question })
                .width('100%').height(108).fontSize(BODY_FONT_SIZE).fontColor(COLOR_TEXT_PRIMARY)
                .backgroundColor('#F7F9FC')
                .enabled(!this.pending && !this.discarding && !this.saveCompleted && !this.rollbackPending)
                .onChange((value: string) => { this.updateQuestionText(draft.localId, value) })

              ForEach(draft.options, (option: string, optionIndex: number) => {
                TextInput({ placeholder: '选项 ' + String.fromCharCode(65 + optionIndex), text: option })
                  .width('100%').height(46).fontSize(BODY_FONT_SIZE).fontColor(COLOR_TEXT_PRIMARY)
                  .backgroundColor('#F7F9FC')
                  .enabled(!this.pending && !this.discarding && !this.saveCompleted && !this.rollbackPending)
                  .onChange((value: string) => { this.updateOption(draft.localId, optionIndex, value) })
              }, (option: string, optionIndex: number): string =>
                draft.localId + '_option_' + optionIndex.toString())

              TextInput({ placeholder: '答案（选填）', text: draft.answer })
                .width('100%').height(46).fontSize(BODY_FONT_SIZE).fontColor(COLOR_TEXT_PRIMARY)
                .backgroundColor('#F7F9FC')
                .enabled(!this.pending && !this.discarding && !this.saveCompleted && !this.rollbackPending)
                .onChange((value: string) => { this.updateAnswer(draft.localId, value) })

              TextArea({ placeholder: '解析（选填）', text: draft.analysis })
                .width('100%').height(96).fontSize(BODY_FONT_SIZE).fontColor(COLOR_TEXT_PRIMARY)
                .backgroundColor('#F7F9FC')
                .enabled(!this.pending && !this.discarding && !this.saveCompleted && !this.rollbackPending)
                .onChange((value: string) => { this.updateAnalysis(draft.localId, value) })

              Button('删除此题').width('100%').height(44).fontColor(COLOR_DANGER)
                .backgroundColor('#FFF2F2')
                .enabled(!this.pending && !this.discarding && !this.saveCompleted && !this.rollbackPending)
                .onClick(() => { this.confirmDeleteDraft(draft.localId) })
            }
            .width('100%').padding(18).backgroundColor(COLOR_CARD_BG).borderRadius(CARD_RADIUS)
          }
        }, (draft: PdfQuestionDraft): string => draft.localId)
      }
      .layoutWeight(1).width('100%').padding({ left: PAGE_PADDING, right: PAGE_PADDING })
      .scrollBar(BarState.Off)

      Column({ space: 10 }) {
        if (this.rollbackPending) {
          Button(this.pending ? '正在恢复…' : '重试题图恢复')
            .width('100%').height(50).fontColor(COLOR_PRIMARY).backgroundColor(COLOR_CARD_BG)
            .border({ width: 1, color: COLOR_PRIMARY }).enabled(!this.pending)
            .onClick(() => { this.retryRollback() })
        } else {
          Button(this.pending ? '正在保存…' : this.saveCompleted ? '进入题目列表' : '保存题库')
            .width('100%').height(52).fontColor('#FFFFFF').backgroundColor(COLOR_PRIMARY)
            .borderRadius(16).enabled(!this.pending && !this.discarding && !this.dialogOpen)
            .onClick(() => { this.saveBank() })
        }
        if (this.cleanupPending) {
          Button(this.pending ? '正在清理…' : '重试清理')
            .width('100%').height(46).fontColor('#FFFFFF').backgroundColor(COLOR_PRIMARY)
            .enabled(!this.pending && !this.discarding)
            .onClick(() => { this.retryDiscardCleanup() })
          Button('稍后清理并返回')
            .width('100%').height(46).fontColor(COLOR_PRIMARY).backgroundColor(COLOR_CARD_BG)
            .border({ width: 1, color: COLOR_PRIMARY }).enabled(!this.pending && !this.discarding)
            .onClick(() => { this.rememberDebtAndDiscard() })
        }
      }
      .width('100%').padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 12, bottom: PAGE_PADDING })
      }
    }
    .width('100%').height('100%').backgroundColor(COLOR_PAGE_BG)
  }
}
