import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { PdfImportSettings } from '../../models/PdfImportModels'
import {
  AiImportError,
  AiImportErrorCode,
  AiProviderConfig,
  AiProviderConfigValidator
} from '../../models/ai/AiProviderConfig'
import { AiQuestionDraft, EncodedPdfPage } from '../../models/ai/AiImportModels'
import { PdfImportService } from '../PdfImportService'
import {
  PdfReviewFailure,
  PdfReviewImage,
  PdfReviewOption,
  PdfReviewQuestion,
  PdfReviewSaveStage,
  PdfReviewSession,
  PdfReviewSource
} from '../review/PdfReviewModels'
import { PdfReviewSessionStore } from '../review/PdfReviewSession'
import { AiCredentialStore } from './AiCredentialStore'
import { AiProviderConfigStore } from './AiProviderConfigStore'
import { AiProviderAdapter, AiProviderRequest } from './AiProviderAdapter'
import { AiQuestionResponseParser } from './AiQuestionResponseParser'
import { AiVisionTransport, AiVisionTransportPort } from './AiVisionTransport'
import { MathQuestionPromptBuilder } from './MathQuestionPromptBuilder'
import { OpenAiCompatibleAdapter } from './OpenAiCompatibleAdapter'
import {
  PdfPageImageEncoder,
  PdfPageImageEncoderPort,
  PdfRenderSessionPort
} from './PdfPageImageEncoder'

export type AiProgressCallback = (currentPage: number, totalPages: number,
  processedPages: number, questionCount: number, stage: string) => void

export interface AiCredentialAccessPort {
  run(context: Context, action: AiCredentialAction, config?: AiProviderConfig): Promise<string>
}

export interface AiCredentialAction {
  execute(credential: Uint8Array): Promise<string>
}

export interface AiQuestionParserPort {
  parse(content: string, pageNumber: number): Array<AiQuestionDraft>
}

export interface PdfTemporaryFileCleanupPort {
  remove(pdfPath: string): Promise<void>
}

export class PdfAiImportRequest {
  sessionId: string
  accountId: string
  pdfPath: string
  settings: PdfImportSettings
  config: AiProviderConfig

  constructor(sessionId: string, accountId: string, pdfPath: string,
    settings: PdfImportSettings, config: AiProviderConfig) {
    this.sessionId = sessionId
    this.accountId = accountId
    this.pdfPath = pdfPath
    this.settings = settings
    this.config = config
  }
}

class StoredCredentialAccess implements AiCredentialAccessPort {
  async run(context: Context, action: AiCredentialAction, config?: AiProviderConfig): Promise<string> {
    if (config === undefined) throw new AiImportError(AiImportErrorCode.CONFIG_NOT_SAVED)
    return AiProviderConfigStore.withUsableConfig<string>(context, config, (): Promise<string> =>
      AiCredentialStore.withCredential<string>(context,
        (credential: Uint8Array): Promise<string> => action.execute(credential)))
  }
}

class StrictQuestionParser implements AiQuestionParserPort {
  parse(content: string, pageNumber: number): Array<AiQuestionDraft> {
    return AiQuestionResponseParser.parse(content, pageNumber)
  }
}

class DefaultPdfTemporaryFileCleanup implements PdfTemporaryFileCleanupPort {
  private completedPaths: Set<string> = new Set<string>()

  async remove(pdfPath: string): Promise<void> {
    if (this.completedPaths.has(pdfPath)) return
    await PdfImportService.removeTemporaryPdf(pdfPath)
    this.completedPaths.add(pdfPath)
  }
}

class TransportCredentialAction implements AiCredentialAction {
  private transport: AiVisionTransportPort
  private request: AiProviderRequest
  private requestKey: string
  private dispatchGuard: () => void

  constructor(transport: AiVisionTransportPort, request: AiProviderRequest, requestKey: string,
    dispatchGuard: () => void) {
    this.transport = transport
    this.request = request
    this.requestKey = requestKey
    this.dispatchGuard = dispatchGuard
  }

  execute(credential: Uint8Array): Promise<string> {
    this.dispatchGuard()
    return this.transport.postJson(this.request.endpoint, credential, this.request.body, this.requestKey)
  }
}

class ActiveCoordinatorRequest {
  generation: number
  requestKey: string

  constructor(generation: number, requestKey: string) {
    this.generation = generation
    this.requestKey = requestKey
  }
}

class ProcessedAiPage {
  questions: Array<PdfReviewQuestion>
  previousTail: string
  attemptId: string

  constructor(questions: Array<PdfReviewQuestion>, previousTail: string, attemptId: string) {
    this.questions = questions
    this.previousTail = previousTail
    this.attemptId = attemptId
  }
}

enum PageAttemptCleanupPolicy {
  RETAIN_PAGE = 'retain_page',
  REMOVE_ATTEMPT = 'remove_attempt'
}

class PageProcessingError extends AiImportError {
  evidencePath: string
  attemptId: string
  cleanupFailed: boolean

  constructor(code: AiImportErrorCode, evidencePath: string, attemptId: string,
    cleanupFailed: boolean) {
    super(code)
    this.evidencePath = evidencePath
    this.attemptId = attemptId
    this.cleanupFailed = cleanupFailed
    if (cleanupFailed) {
      this.message = this.message + '；本次页面临时文件清理失败'
    }
  }
}

export class AiImportCleanupRequiredError extends AiImportError {
  constructor(code: AiImportErrorCode) {
    super(code)
    this.message = this.message + '；本次页面临时文件清理失败'
  }
}

class SecondaryCleanupAiImportError extends AiImportError {
  constructor(primary: AiImportError) {
    super(primary.code)
    this.message = primary.message + '；后续清理也失败'
  }
}

export class PdfAiImportCoordinator {
  private renderer: PdfPageImageEncoderPort
  private credentials: AiCredentialAccessPort
  private adapter: AiProviderAdapter
  private transport: AiVisionTransportPort
  private parser: AiQuestionParserPort
  private pdfCleanup: PdfTemporaryFileCleanupPort
  private generation: number = 0
  private requestSequence: number = 0
  private operationTail: Promise<void> = Promise.resolve()
  private activeRequest: ActiveCoordinatorRequest | null = null

  constructor(renderer: PdfPageImageEncoderPort, credentials: AiCredentialAccessPort,
    adapter: AiProviderAdapter, transport: AiVisionTransportPort, parser: AiQuestionParserPort,
    pdfCleanup: PdfTemporaryFileCleanupPort = new DefaultPdfTemporaryFileCleanup()) {
    this.renderer = renderer
    this.credentials = credentials
    this.adapter = adapter
    this.transport = transport
    this.parser = parser
    this.pdfCleanup = pdfCleanup
  }

  static createDefault(): PdfAiImportCoordinator {
    return new PdfAiImportCoordinator(new PdfPageImageEncoder(), new StoredCredentialAccess(),
      new OpenAiCompatibleAdapter(), new AiVisionTransport(), new StrictQuestionParser())
  }

  cancel(): void {
    this.beginGeneration()
  }

  async discard(context: Context, request: PdfAiImportRequest): Promise<void> {
    const generation: number = this.beginGeneration()
    await this.runExclusive<void>((): Promise<void> =>
      this.executeDiscard(context, request, generation))
  }

  run(context: Context, request: PdfAiImportRequest,
    onProgress: AiProgressCallback): Promise<PdfReviewSession> {
    const generation: number = this.beginGeneration()
    return this.runExclusive<PdfReviewSession>((): Promise<PdfReviewSession> =>
      this.executeRun(context, request, onProgress, generation))
  }

  async retryPage(context: Context, session: PdfReviewSession, pageNumber: number,
    config: AiProviderConfig): Promise<PdfReviewSession> {
    if (session.saveStage !== PdfReviewSaveStage.DRAFT ||
      session.source !== PdfReviewSource.AI || !Number.isSafeInteger(pageNumber) ||
      pageNumber < 1 || session.sessionId.length === 0 || session.pdfPath.length === 0) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
    let representedPage: boolean = false
    for (let index: number = 0; index < session.questions.length; index++) {
      const question: PdfReviewQuestion = session.questions[index]
      if (question.pageStart === pageNumber && question.pageEnd === pageNumber) {
        representedPage = true
      }
    }
    for (let index: number = 0; index < session.failures.length; index++) {
      if (session.failures[index].pageNumber === pageNumber) {
        representedPage = true
      }
    }
    if (!representedPage) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
    const generation: number = this.beginGeneration()
    return this.runExclusive<PdfReviewSession>((): Promise<PdfReviewSession> =>
      this.executeRetry(context, session, pageNumber, config, generation))
  }

  async discardFailure(context: Context, session: PdfReviewSession, pageNumber: number,
    replacement: PdfReviewQuestion | null): Promise<PdfReviewSession> {
    const snapshot: PdfReviewSession = PdfReviewSessionStore.copyOf(session)
    if (replacement !== null) snapshot.questions.push(replacement)
    const copied: PdfReviewSession = PdfReviewSessionStore.copyOf(snapshot)
    const question: PdfReviewQuestion | null = replacement === null ? null :
      copied.questions[copied.questions.length - 1]
    return this.runExclusive<PdfReviewSession>((): Promise<PdfReviewSession> =>
      this.executeFailureRemoval(context, copied, pageNumber, question))
  }

  private async executeFailureRemoval(context: Context, session: PdfReviewSession,
    pageNumber: number, replacement: PdfReviewQuestion | null): Promise<PdfReviewSession> {
    const current: PdfReviewSession | null = PdfReviewSessionStore.get(session.sessionId)
    if (current === null || current.source !== PdfReviewSource.AI ||
      current.accountId !== session.accountId || current.bankUuid !== session.bankUuid ||
      current.saveStage !== PdfReviewSaveStage.DRAFT ||
      !Number.isSafeInteger(pageNumber) || pageNumber < 1) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
    const updated: PdfReviewSession = PdfReviewSessionStore.copyOf(current)
    const removedPaths: Set<string> = new Set<string>()
    let found: boolean = false
    updated.failures = updated.failures.filter((failure: PdfReviewFailure): boolean => {
      if (failure.pageNumber !== pageNumber) return true
      found = true
      if (failure.evidencePath.length > 0) removedPaths.add(failure.evidencePath)
      return false
    })
    if (!found) return PdfReviewSessionStore.copyOf(current)
    if (replacement !== null) {
      if (replacement.pageStart !== pageNumber || replacement.pageEnd !== pageNumber ||
        updated.questions.some((question: PdfReviewQuestion): boolean =>
          question.questionUuid === replacement.questionUuid)) {
        throw new AiImportError(AiImportErrorCode.INVALID_JSON)
      }
      removedPaths.forEach((path: string): void => {
        if (!replacement.images.some((image: PdfReviewImage): boolean => image.localPath === path)) {
          replacement.images.push(new PdfReviewImage('', path, '', 0, 'image/jpeg',
            replacement.images.length))
        }
      })
      updated.questions.push(replacement)
    }
    const retainedPaths: Set<string> = new Set<string>()
    for (const question of updated.questions) {
      for (const image of question.images) retainedPaths.add(image.localPath)
    }
    for (const failure of updated.failures) retainedPaths.add(failure.evidencePath)
    const obsolete: Array<string> = new Array<string>()
    removedPaths.forEach((path: string): void => {
      if (!retainedPaths.has(path)) obsolete.push(path)
    })
    for (const path of obsolete) {
      try {
        await this.renderer.cleanupEvidence(context, current.sessionId, path)
      } catch {
        throw PdfAiImportCoordinator.withCleanupFailure(
          new AiImportError(AiImportErrorCode.INVALID_JSON))
      }
    }
    PdfReviewSessionStore.put(updated)
    return PdfReviewSessionStore.copyOf(updated)
  }

  private async executeDiscard(context: Context, request: PdfAiImportRequest,
    generation: number): Promise<void> {
    this.requireGeneration(generation)
    let firstError: AiImportError | null = null
    let secondaryCleanupFailed: boolean = false
    try {
      await this.renderer.cleanupSession(context, request.sessionId)
    } catch (err) {
      firstError = PdfAiImportCoordinator.normalizeError(err)
    }
    try {
      await this.pdfCleanup.remove(request.pdfPath)
    } catch (err) {
      if (firstError === null) {
        firstError = PdfAiImportCoordinator.normalizeError(err)
      } else {
        secondaryCleanupFailed = true
      }
    }
    if (firstError !== null) {
      throw secondaryCleanupFailed ?
        PdfAiImportCoordinator.withSecondaryCleanupFailure(firstError) : firstError
    }
    PdfReviewSessionStore.remove(request.sessionId)
    this.requireGeneration(generation)
  }

  private async executeRun(context: Context, request: PdfAiImportRequest,
    onProgress: AiProgressCallback, generation: number): Promise<PdfReviewSession> {
    this.requireGeneration(generation)
    const config: AiProviderConfig = AiProviderConfigValidator.normalize(request.config)
    const renderSession: PdfRenderSessionPort = this.renderer.open(request.pdfPath)
    const questions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
    const failures: Array<PdfReviewFailure> = new Array<PdfReviewFailure>()
    const stableIds: Map<string, string> = new Map<string, string>()
    const successfulAttempts: Array<string> = new Array<string>()
    const retainedFailureAttempts: Array<string> = new Array<string>()
    let previousTail: string = ''
    let operationError: AiImportError | null = null
    try {
      const pageCount: number = renderSession.pageCount()
      this.validateRange(request.settings, pageCount)
      const totalPages: number = request.settings.endPage - request.settings.startPage + 1
      for (let pageNumber: number = request.settings.startPage;
        pageNumber <= request.settings.endPage; pageNumber++) {
        this.requireGeneration(generation)
        onProgress(pageNumber, totalPages, pageNumber - request.settings.startPage,
          questions.length, '正在识别第 ' + pageNumber.toString() + ' 页')
        try {
          const processed: ProcessedAiPage = await this.processPage(context, renderSession,
            request.sessionId, pageNumber, config, previousTail, generation, stableIds,
            PageAttemptCleanupPolicy.RETAIN_PAGE)
          successfulAttempts.push(processed.attemptId)
          this.requireGeneration(generation)
          for (let index: number = 0; index < processed.questions.length; index++) {
            this.requireGeneration(generation)
            questions.push(processed.questions[index])
          }
          previousTail = processed.previousTail
        } catch (err) {
          if (err instanceof PageProcessingError &&
            (err.evidencePath.length > 0 || err.cleanupFailed)) {
            retainedFailureAttempts.push(err.attemptId)
          }
          if (generation !== this.generation) {
            if (err instanceof AiImportError && err.code === AiImportErrorCode.CANCELLED) {
              throw err
            }
            throw new AiImportError(AiImportErrorCode.CANCELLED)
          }
          if (err instanceof PageProcessingError) {
            if (err.cleanupFailed) {
              throw err
            }
          }
          const failure: AiImportError = PdfAiImportCoordinator.normalizeError(err)
          const evidencePath: string = err instanceof PageProcessingError ? err.evidencePath : ''
          failures.push(new PdfReviewFailure(pageNumber, failure.code, failure.message, evidencePath))
        }
        this.requireGeneration(generation)
        onProgress(pageNumber, totalPages, pageNumber - request.settings.startPage + 1,
          questions.length, '已完成第 ' + pageNumber.toString() + ' 页')
      }
    } catch (err) {
      operationError = PdfAiImportCoordinator.normalizeError(err)
    } finally {
      try {
        renderSession.close()
      } catch {
        if (operationError === null) {
          operationError = new AiImportError(AiImportErrorCode.INVALID_JSON)
        }
      }
    }
    if (operationError !== null) {
      const successfulCleanupFailed: boolean = await this.cleanupAttemptsAndReport(
        context, request.sessionId, successfulAttempts)
      const failureCleanupFailed: boolean = await this.cleanupAttemptsAndReport(
        context, request.sessionId, retainedFailureAttempts)
      throw successfulCleanupFailed || failureCleanupFailed ?
        PdfAiImportCoordinator.withCleanupFailure(operationError) :
        PdfAiImportCoordinator.withoutCleanupFailure(operationError)
    }
    this.requireGeneration(generation)
    const session: PdfReviewSession = new PdfReviewSession(request.sessionId, PdfReviewSource.AI,
      util.generateRandomUUID(), request.settings.bankName, request.settings.subject, request.pdfPath,
      request.accountId, questions, failures, PdfReviewSaveStage.DRAFT)
    try {
      PdfReviewSessionStore.put(session)
      const stored: PdfReviewSession | null = PdfReviewSessionStore.get(session.sessionId)
      if (stored === null) {
        throw new AiImportError(AiImportErrorCode.INVALID_JSON)
      }
      return stored
    } catch (err) {
      PdfReviewSessionStore.remove(session.sessionId)
      const primary: AiImportError = PdfAiImportCoordinator.normalizeError(err)
      const successfulCleanupFailed: boolean = await this.cleanupAttemptsAndReport(
        context, request.sessionId, successfulAttempts)
      const failureCleanupFailed: boolean = await this.cleanupAttemptsAndReport(
        context, request.sessionId, retainedFailureAttempts)
      throw successfulCleanupFailed || failureCleanupFailed ?
        PdfAiImportCoordinator.withCleanupFailure(primary) :
        PdfAiImportCoordinator.withoutCleanupFailure(primary)
    }
  }

  private async executeRetry(context: Context, session: PdfReviewSession, pageNumber: number,
    config: AiProviderConfig, generation: number): Promise<PdfReviewSession> {
    this.requireGeneration(generation)
    const normalizedConfig: AiProviderConfig = AiProviderConfigValidator.normalize(config)
    const renderSession: PdfRenderSessionPort = this.renderer.open(session.pdfPath)
    let processed: ProcessedAiPage | null = null
    let operationError: AiImportError | null = null
    try {
      if (pageNumber > renderSession.pageCount()) {
        throw new AiImportError(AiImportErrorCode.INVALID_JSON)
      }
      const stableIds: Map<string, string> = new Map<string, string>()
      for (let index: number = 0; index < session.questions.length; index++) {
        const question: PdfReviewQuestion = session.questions[index]
        if (question.pageStart === pageNumber && question.pageEnd === pageNumber) {
          stableIds.set(question.draftQuestionId, question.questionUuid)
        }
      }
      processed = await this.processPage(context, renderSession, session.sessionId,
        pageNumber, normalizedConfig, '', generation, stableIds,
        PageAttemptCleanupPolicy.REMOVE_ATTEMPT)
      this.requireGeneration(generation)
    } catch (err) {
      operationError = PdfAiImportCoordinator.normalizeError(err)
    } finally {
      try {
        renderSession.close()
      } catch {
        if (operationError === null) {
          operationError = new AiImportError(AiImportErrorCode.INVALID_JSON)
        }
      }
    }
    if (operationError !== null) {
      let cleanupFailed: boolean = false
      if (processed !== null) {
        cleanupFailed = await this.cleanupAttemptAndReport(
          context, session.sessionId, processed.attemptId)
      } else if (operationError instanceof PageProcessingError && operationError.cleanupFailed) {
        cleanupFailed = await this.cleanupAttemptAndReport(
          context, session.sessionId, operationError.attemptId)
      }
      throw cleanupFailed ? PdfAiImportCoordinator.withCleanupFailure(operationError) :
        PdfAiImportCoordinator.withoutCleanupFailure(operationError)
    }
    if (processed === null) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
    this.requireGeneration(generation)
    const nextQuestions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
    const supersededEvidence: Set<string> = new Set<string>()
    for (let index: number = 0; index < session.questions.length; index++) {
      const question: PdfReviewQuestion = session.questions[index]
      if (question.pageStart !== pageNumber || question.pageEnd !== pageNumber) {
        nextQuestions.push(question)
      } else {
        for (let imageIndex: number = 0; imageIndex < question.images.length; imageIndex++) {
          const path: string = question.images[imageIndex].localPath
          if (path.length > 0) supersededEvidence.add(path)
        }
      }
    }
    for (let index: number = 0; index < processed.questions.length; index++) {
      nextQuestions.push(processed.questions[index])
    }
    nextQuestions.sort((left: PdfReviewQuestion, right: PdfReviewQuestion): number => {
      if (left.pageStart !== right.pageStart) return left.pageStart - right.pageStart
      return left.draftQuestionId.localeCompare(right.draftQuestionId)
    })
    const nextFailures: Array<PdfReviewFailure> = new Array<PdfReviewFailure>()
    for (let index: number = 0; index < session.failures.length; index++) {
      const failure: PdfReviewFailure = session.failures[index]
      if (failure.pageNumber !== pageNumber) {
        nextFailures.push(failure)
      } else if (failure.evidencePath.length > 0) {
        supersededEvidence.add(failure.evidencePath)
      }
    }
    const updated: PdfReviewSession = new PdfReviewSession(session.sessionId, session.source,
      session.bankUuid, session.bankName, session.subject, session.pdfPath, session.accountId,
      nextQuestions, nextFailures, session.saveStage)
    this.requireGeneration(generation)
    let stored: PdfReviewSession | null = null
    try {
      PdfReviewSessionStore.put(updated)
      stored = PdfReviewSessionStore.get(updated.sessionId)
      if (stored === null) {
        throw new AiImportError(AiImportErrorCode.INVALID_JSON)
      }
    } catch (err) {
      const primary: AiImportError = PdfAiImportCoordinator.normalizeError(err)
      try {
        PdfReviewSessionStore.put(session)
      } catch {
      }
      const cleanupFailed: boolean = await this.cleanupAttemptAndReport(
        context, session.sessionId, processed.attemptId)
      throw cleanupFailed ? PdfAiImportCoordinator.withCleanupFailure(primary) :
        PdfAiImportCoordinator.withoutCleanupFailure(primary)
    }
    if (stored === null) throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    const retainedEvidence: Set<string> = new Set<string>()
    for (let index: number = 0; index < stored.questions.length; index++) {
      const images: Array<PdfReviewImage> = stored.questions[index].images
      for (let imageIndex: number = 0; imageIndex < images.length; imageIndex++) {
        retainedEvidence.add(images[imageIndex].localPath)
      }
    }
    for (let index: number = 0; index < stored.failures.length; index++) {
      retainedEvidence.add(stored.failures[index].evidencePath)
    }
    const obsoleteEvidence: Array<string> = new Array<string>()
    supersededEvidence.forEach((path: string): void => {
      if (!retainedEvidence.has(path)) obsoleteEvidence.push(path)
    })
    const evidenceCleanupFailed: boolean = await this.cleanupEvidenceAndReport(
      context, session.sessionId, obsoleteEvidence)
    if (evidenceCleanupFailed) {
      throw PdfAiImportCoordinator.withCleanupFailure(
        new AiImportError(AiImportErrorCode.INVALID_JSON))
    }
    return stored
  }

  private async processPage(context: Context, renderSession: PdfRenderSessionPort,
    sessionId: string, pageNumber: number, config: AiProviderConfig, previousTail: string,
    generation: number, stableIds: Map<string, string>,
    cleanupPolicy: PageAttemptCleanupPolicy): Promise<ProcessedAiPage> {
    let encoded: EncodedPdfPage | null = null
    let providerRequest: AiProviderRequest | null = null
    let rawResponse: string = ''
    let assistantContent: string = ''
    let active: ActiveCoordinatorRequest | null = null
    let result: ProcessedAiPage | null = null
    let operationError: AiImportError | null = null
    let discardPageEvidence: boolean = false
    const attemptId: string = util.generateRandomUUID()
    try {
      this.requireGeneration(generation)
      encoded = await renderSession.encodePage(context, pageNumber - 1, sessionId, attemptId)
      this.requireGeneration(generation)
      const prompt: string = MathQuestionPromptBuilder.build(pageNumber,
        renderSession.pageCount(), previousTail)
      providerRequest = this.adapter.buildRequest(config, prompt, encoded.jpegBase64)
      const requestKey: string = this.nextRequestKey(sessionId, pageNumber, generation)
      const requestState: ActiveCoordinatorRequest =
        new ActiveCoordinatorRequest(generation, requestKey)
      active = requestState
      this.activeRequest = requestState
      try {
        rawResponse = await this.credentials.run(context,
          new TransportCredentialAction(this.transport, providerRequest, requestKey,
            (): void => this.requireDispatch(requestState, generation)), config)
      } finally {
        this.clearActiveRequest(requestState)
      }
      this.requireGeneration(generation)
      assistantContent = this.adapter.extractAssistantContent(rawResponse)
      this.requireGeneration(generation)
      const parsed: Array<AiQuestionDraft> = this.parser.parse(assistantContent, pageNumber)
      this.requireGeneration(generation)
      if (parsed.length === 0) {
        throw new AiImportError(AiImportErrorCode.NO_QUESTIONS)
      }
      const pageQuestions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
      let pageEvidenceReferenced: boolean = false
      for (let index: number = 0; index < parsed.length; index++) {
        const source: AiQuestionDraft = parsed[index]
        const draftQuestionId: string = sessionId + ':' + pageNumber.toString() + ':' +
          index.toString()
        const stableId: string | undefined = stableIds.get(draftQuestionId)
        const questionUuid: string = stableId === undefined ? util.generateRandomUUID() : stableId
        const evidence: string = source.bboxUsable ?
          await renderSession.cropEvidence(context, pageNumber - 1, sessionId,
            draftQuestionId, source.bbox, attemptId) : encoded.evidencePath
        pageEvidenceReferenced = pageEvidenceReferenced || evidence === encoded.evidencePath
        this.requireGeneration(generation)
        const options: Array<PdfReviewOption> = new Array<PdfReviewOption>()
        for (let optionIndex: number = 0; optionIndex < source.options.length; optionIndex++) {
          options.push(new PdfReviewOption(source.options[optionIndex].key,
            source.options[optionIndex].value))
        }
        const images: Array<PdfReviewImage> = new Array<PdfReviewImage>()
        images.push(new PdfReviewImage('', evidence, '', 0, 'image/jpeg', 0))
        pageQuestions.push(new PdfReviewQuestion(draftQuestionId, questionUuid, source.label,
          source.type, source.question, options, source.answer, source.analysis,
          pageNumber, pageNumber, 1, !source.bboxUsable, images))
      }
      if (!pageEvidenceReferenced && encoded.evidencePath.length > 0) {
        discardPageEvidence = true
        await this.renderer.cleanupEvidence(context, sessionId, encoded.evidencePath)
      }
      this.requireGeneration(generation)
      let nextTail: string = previousTail
      if (parsed.length > 0) {
        const lastQuestion: string = parsed[parsed.length - 1].question
        nextTail = lastQuestion.substring(Math.max(0, lastQuestion.length - 1000))
      }
      result = new ProcessedAiPage(pageQuestions, nextTail, attemptId)
    } catch (err) {
      operationError = PdfAiImportCoordinator.normalizeError(err)
    } finally {
      rawResponse = ''
      assistantContent = ''
      if (active !== null) {
        this.clearActiveRequest(active)
      }
      if (providerRequest !== null) {
        try {
          providerRequest.release()
        } catch {
          if (operationError === null) {
            operationError = new AiImportError(AiImportErrorCode.INVALID_JSON)
          }
        }
      }
      if (encoded !== null) {
        try {
          encoded.releaseTransientText()
        } catch {
          if (operationError === null) {
            operationError = new AiImportError(AiImportErrorCode.INVALID_JSON)
          }
        }
      }
    }
    if (result === null) {
      if (operationError === null) {
        operationError = new AiImportError(AiImportErrorCode.INVALID_JSON)
      }
    }
    if (operationError !== null) {
      const evidencePath: string = encoded === null ? '' : encoded.evidencePath
      const retainPage: boolean = cleanupPolicy === PageAttemptCleanupPolicy.RETAIN_PAGE &&
        !discardPageEvidence && operationError.code !== AiImportErrorCode.CANCELLED &&
        evidencePath.length > 0
      const cleanupFailed: boolean = retainPage ?
        await this.cleanupAttemptCropsAndReport(context, sessionId, attemptId) :
        await this.cleanupAttemptAndReport(context, sessionId, attemptId)
      throw new PageProcessingError(operationError.code,
        retainPage ? evidencePath : '', attemptId, cleanupFailed)
    }
    if (result === null) throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    return result
  }

  private async cleanupAttemptsAndReport(context: Context, sessionId: string,
    attemptIds: Array<string>): Promise<boolean> {
    let cleanupFailed: boolean = false
    for (let index: number = 0; index < attemptIds.length; index++) {
      const currentFailed: boolean = await this.cleanupAttemptAndReport(
        context, sessionId, attemptIds[index])
      cleanupFailed = cleanupFailed || currentFailed
    }
    return cleanupFailed
  }

  private async cleanupAttemptAndReport(context: Context, sessionId: string,
    attemptId: string): Promise<boolean> {
    try {
      await this.renderer.cleanupAttempt(context, sessionId, attemptId)
      return false
    } catch {
      return true
    }
  }

  private async cleanupAttemptCropsAndReport(context: Context, sessionId: string,
    attemptId: string): Promise<boolean> {
    try {
      await this.renderer.cleanupAttemptCrops(context, sessionId, attemptId)
      return false
    } catch {
      return true
    }
  }

  private async cleanupEvidenceAndReport(context: Context, sessionId: string,
    evidencePaths: Array<string>): Promise<boolean> {
    let cleanupFailed: boolean = false
    for (let index: number = 0; index < evidencePaths.length; index++) {
      try {
        await this.renderer.cleanupEvidence(context, sessionId, evidencePaths[index])
      } catch {
        cleanupFailed = true
      }
    }
    return cleanupFailed
  }

  private validateRange(settings: PdfImportSettings, pageCount: number): void {
    if (!Number.isSafeInteger(settings.startPage) || !Number.isSafeInteger(settings.endPage) ||
      settings.startPage < 1 || settings.endPage < settings.startPage ||
      settings.endPage > pageCount) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
  }

  private beginGeneration(): number {
    this.generation++
    const active: ActiveCoordinatorRequest | null = this.activeRequest
    if (active !== null) {
      this.activeRequest = null
      this.transport.cancel(active.requestKey)
    }
    return this.generation
  }

  private requireGeneration(generation: number): void {
    if (generation !== this.generation) {
      throw new AiImportError(AiImportErrorCode.CANCELLED)
    }
  }

  private requireDispatch(request: ActiveCoordinatorRequest, generation: number): void {
    if (generation !== this.generation || this.activeRequest !== request ||
      request.generation !== generation) {
      throw new AiImportError(AiImportErrorCode.CANCELLED)
    }
  }

  private nextRequestKey(sessionId: string, pageNumber: number, generation: number): string {
    this.requestSequence++
    return sessionId + ':' + pageNumber.toString() + ':' + generation.toString() + ':' +
      this.requestSequence.toString()
  }

  private clearActiveRequest(request: ActiveCoordinatorRequest): void {
    if (this.activeRequest === request) {
      this.activeRequest = null
    }
  }

  private runExclusive<T>(action: () => Promise<T>): Promise<T> {
    const run: Promise<T> = this.operationTail.then(action, action)
    this.operationTail = run.then(
      (_value: T): void => {},
      (): void => {})
    return run
  }

  private static withCleanupFailure(primary: AiImportError): AiImportError {
    if (primary instanceof AiImportCleanupRequiredError) {
      return primary
    }
    return new AiImportCleanupRequiredError(primary.code)
  }

  private static withoutCleanupFailure(primary: AiImportError): AiImportError {
    if (primary instanceof AiImportCleanupRequiredError ||
      (primary instanceof PageProcessingError && primary.cleanupFailed)) {
      return new AiImportError(primary.code)
    }
    return primary
  }

  private static withSecondaryCleanupFailure(primary: AiImportError): AiImportError {
    return new SecondaryCleanupAiImportError(primary)
  }

  private static normalizeError(err: Error): AiImportError {
    if (err instanceof AiImportError) {
      return err
    }
    return new AiImportError(AiImportErrorCode.INVALID_JSON)
  }
}
