import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import {
  CloudBankCache,
  CloudCachePage,
  CloudCacheState,
  CloudQuestionCache,
  CloudWrongCache,
  DeviceQuestionImage
} from '../models/CloudCacheModels'
import { AccountSessionState } from '../models/AccountSession'
import { ApiHttpError } from '../models/ApiModels'
import { Question } from '../models/Question'
import { QuestionBank, QuestionBankSummary } from '../models/QuestionBank'
import { QuestionImage } from '../models/QuestionImage'
import { Statistics } from '../models/Statistics'
import {
  RemoteSyncOperation,
  SyncEntityType,
  SyncOperationType,
  SyncOutboxOperation,
  SyncPushBody,
  SyncPushOperation,
  SyncPullResponse,
  SyncPushResponse,
  SyncSequence
} from '../models/SyncModels'
import { WrongQuestionListItem, WrongQuestionSummary } from '../models/WrongQuestion'
import { CloudCacheService } from './CloudCacheService'
import { DeviceImageStore } from './DeviceImageStore'
import { SyncPayloadFactory } from './SyncPayloadFactory'
import { AccountSessionService } from './AccountSessionService'
import { ApiHttpClient } from './ApiHttpClient'

const PULL_LIMIT: number = 100
const PUSH_BATCH_LIMIT: number = 100

const EMPTY_PAYLOAD: object = JSON.parse('{}')

class CloudCacheSnapshot {
  banks: Map<string, CloudBankCache>
  questions: Map<string, CloudQuestionCache>
  wrongQuestions: Map<string, CloudWrongCache>

  constructor(banks: Map<string, CloudBankCache>, questions: Map<string, CloudQuestionCache>,
    wrongQuestions: Map<string, CloudWrongCache>) {
    this.banks = banks
    this.questions = questions
    this.wrongQuestions = wrongQuestions
  }
}

/**
 * Server-authoritative in-memory snapshot of the whole account stream. It is
 * produced from GET /v1/sync/pull without touching the local cloud cache and
 * is used by the legacy migration to verify uploaded text before the cache
 * is updated.
 */
export class AuthoritativeSnapshot {
  banks: Map<string, CloudBankCache>
  questions: Map<string, CloudQuestionCache>
  wrongQuestions: Map<string, CloudWrongCache>
  cursor: string

  constructor(banks: Map<string, CloudBankCache>, questions: Map<string, CloudQuestionCache>,
    wrongQuestions: Map<string, CloudWrongCache>, cursor: string) {
    this.banks = banks
    this.questions = questions
    this.wrongQuestions = wrongQuestions
    this.cursor = cursor
  }
}

/**
 * Server-first repository for normal question data.
 *
 * Reads come from the account-scoped read-only cloud cache. Every mutation
 * sends exactly one synchronous operation to POST /v1/sync/push, waits for
 * the server, and only then applies the authoritative returned operation to
 * the cache. It never writes a speculative local mutation and never inserts
 * into sync_outbox. Cache refresh uses GET /v1/sync/pull with the account
 * cursor and keeps the previous cache intact on any failure.
 */
export class CloudQuestionRepository {
  static async listCachedBanks(accountId: string): Promise<Array<QuestionBankSummary>> {
    const banks: Array<CloudBankCache> = await CloudCacheService.banks(accountId)
    const summaries: Array<QuestionBankSummary> = new Array<QuestionBankSummary>()
    for (let index: number = 0; index < banks.length; index++) {
      const bank: CloudBankCache = banks[index]
      summaries.push(new QuestionBankSummary(
        bank.bankUuid, bank.bankName, bank.subject, bank.questionCount, bank.updateTime, false))
    }
    return summaries
  }

  static async listCachedQuestions(accountId: string, bankUuid: string): Promise<Array<Question>> {
    const cached: Array<CloudQuestionCache> = await CloudCacheService.questions(accountId, bankUuid)
    const questions: Array<Question> = new Array<Question>()
    for (let index: number = 0; index < cached.length; index++) {
      questions.push(await CloudQuestionRepository.toQuestion(accountId, cached[index]))
    }
    return questions
  }

  static async cachedQuestion(accountId: string, questionUuid: string): Promise<Question | null> {
    const cached: CloudQuestionCache | null = await CloudCacheService.question(accountId, questionUuid)
    if (cached === null) {
      return null
    }
    return CloudQuestionRepository.toQuestion(accountId, cached)
  }

  static async containsWrong(accountId: string, questionUuid: string): Promise<boolean> {
    const wrong: Array<CloudWrongCache> = await CloudCacheService.wrongQuestions(accountId)
    for (let index: number = 0; index < wrong.length; index++) {
      if (wrong[index].questionUuid === questionUuid) {
        return true
      }
    }
    return false
  }

  static async statistics(accountId: string): Promise<Statistics> {
    const banks: Array<CloudBankCache> = await CloudCacheService.banks(accountId)
    const wrong: Array<CloudWrongCache> = await CloudCacheService.wrongQuestions(accountId)
    let masteredCount: number = 0
    for (let index: number = 0; index < wrong.length; index++) {
      if (wrong[index].status === 'mastered') {
        masteredCount++
      }
    }
    return new Statistics(banks.length, wrong.length, masteredCount, wrong.length - masteredCount)
  }

  static async listCachedWrongQuestions(accountId: string): Promise<Array<WrongQuestionSummary>> {
    const banks: Array<CloudBankCache> = await CloudCacheService.banks(accountId)
    const bankNames: Map<string, string> = new Map<string, string>()
    for (let index: number = 0; index < banks.length; index++) {
      bankNames.set(banks[index].bankUuid, banks[index].bankName)
    }
    const wrong: Array<CloudWrongCache> = await CloudCacheService.wrongQuestions(accountId)
    const items: Array<WrongQuestionSummary> = new Array<WrongQuestionSummary>()
    for (let index: number = 0; index < wrong.length; index++) {
      const item: CloudWrongCache = wrong[index]
      const question: CloudQuestionCache | null =
        await CloudCacheService.question(accountId, item.questionUuid)
      const bankName: string = bankNames.get(item.bankUuid) === undefined ? '' :
        bankNames.get(item.bankUuid) as string
      items.push(new WrongQuestionSummary(
        item.questionUuid, item.questionUuid, item.bankUuid, item.subject, item.updateTime,
        item.status === 'mastered', question === null ? '' : question.content, bankName))
    }
    return items
  }

  static async cachedWrongDetail(accountId: string,
    questionUuid: string): Promise<WrongQuestionListItem | null> {
    const banks: Array<CloudBankCache> = await CloudCacheService.banks(accountId)
    let bankName: string = ''
    const wrong: Array<CloudWrongCache> = await CloudCacheService.wrongQuestions(accountId)
    let item: CloudWrongCache | null = null
    for (let index: number = 0; index < wrong.length; index++) {
      if (wrong[index].questionUuid === questionUuid) {
        item = wrong[index]
        break
      }
    }
    if (item === null) {
      return null
    }
    for (let index: number = 0; index < banks.length; index++) {
      if (banks[index].bankUuid === item.bankUuid) {
        bankName = banks[index].bankName
        break
      }
    }
    const question: CloudQuestionCache | null =
      await CloudCacheService.question(accountId, questionUuid)
    if (question === null) {
      return null
    }
    return new WrongQuestionListItem(
      questionUuid, questionUuid, item.bankUuid, item.subject, item.updateTime,
      item.status === 'mastered', item.userAnswer, question.content,
      CloudQuestionRepository.parseOptions(question.optionsJson), question.answer, question.analysis,
      bankName, question.type)
  }

  /**
   * Pulls the account's incremental operations from the server using the
   * account cursor and replaces the cloud cache in one authoritative write.
   * On any failure the previous cache is left untouched.
   */
  static async refresh(accountId: string, context: Context): Promise<void> {
    const accessToken: string = await AccountSessionService.accessToken(context)
    if (accessToken.length === 0) {
      throw new Error('请先登录华为账号')
    }
    const state: CloudCacheState | null = await CloudCacheService.state(accountId)
    const startCursor: string = state === null ? '0' : state.cursor
    const operations: Array<RemoteSyncOperation> = new Array<RemoteSyncOperation>()
    let cursor: string = startCursor
    let hasMore: boolean = true
    while (hasMore) {
      const response: SyncPullResponse =
        await CloudQuestionRepository.authorizedPull(accessToken, cursor, context)
      for (let index: number = 0; index < response.operations.length; index++) {
        operations.push(response.operations[index])
      }
      cursor = response.nextCursor
      hasMore = response.hasMore
    }
    if (operations.length === 0) {
      return
    }
    const snapshot: CloudCacheSnapshot = await CloudQuestionRepository.loadSnapshot(accountId)
    CloudQuestionRepository.applyOrdered(accountId, snapshot, operations)
    await CloudQuestionRepository.saveSnapshot(accountId, snapshot, cursor)
  }

  /**
   * Pulls the full authoritative operation stream for the account from
   * cursor 0 and reduces it to an in-memory snapshot WITHOUT writing the
   * local cloud cache. Legacy migration uses this to verify uploaded text
   * against the server before the cache is updated.
   */
  static async pullAuthoritativeSnapshot(accountId: string,
    context: Context): Promise<AuthoritativeSnapshot> {
    const accessToken: string = await AccountSessionService.accessToken(context)
    if (accessToken.length === 0) {
      throw new Error('请先登录华为账号')
    }
    const operations: Array<RemoteSyncOperation> = new Array<RemoteSyncOperation>()
    let cursor: string = '0'
    let hasMore: boolean = true
    while (hasMore) {
      const response: SyncPullResponse =
        await CloudQuestionRepository.authorizedPull(accessToken, cursor, context)
      for (let index: number = 0; index < response.operations.length; index++) {
        operations.push(response.operations[index])
      }
      cursor = response.nextCursor
      hasMore = response.hasMore
    }
    const snapshot: CloudCacheSnapshot = new CloudCacheSnapshot(
      new Map<string, CloudBankCache>(),
      new Map<string, CloudQuestionCache>(),
      new Map<string, CloudWrongCache>())
    CloudQuestionRepository.applyOrdered(accountId, snapshot, operations)
    return new AuthoritativeSnapshot(snapshot.banks, snapshot.questions, snapshot.wrongQuestions, cursor)
  }

  /**
   * Sends the edited question as one synchronous upsert operation and applies
   * the server-returned authoritative operation to the cache. The local cache
   * is never modified before the server accepts the operation.
   */
  static async updateQuestion(question: Question, context: Context): Promise<void> {
    if (question.id.trim().length === 0) {
      throw new Error('题目标识无效')
    }
    if (question.bankId.trim().length === 0) {
      throw new Error('题目所属题库标识无效')
    }
    const accountId: string = await CloudQuestionRepository.requireSignedIn(context)
    const payload: object = JSON.parse(SyncPayloadFactory.questionPayload(question, question.bankId)) as object
    await CloudQuestionRepository.pushOne(context, accountId, SyncEntityType.QUESTION, question.id,
      SyncOperationType.UPSERT, payload)
  }

  /**
   * Changes the wrong-question state on the server first. status is one of
   * 'pending', 'mastered', or 'removed' (removed deletes the wrong-question
   * row on the server).
   */
  static async setWrongState(questionUuid: string, status: string, context: Context): Promise<void> {
    if (questionUuid.trim().length === 0) {
      throw new Error('题目标识无效')
    }
    const accountId: string = await CloudQuestionRepository.requireSignedIn(context)
    if (status === 'removed') {
      await CloudQuestionRepository.pushOne(context, accountId, SyncEntityType.WRONG_QUESTION,
        questionUuid, SyncOperationType.DELETE, EMPTY_PAYLOAD)
      return
    }
    const payload: object =
      JSON.parse(SyncPayloadFactory.wrongQuestionPayload(status === 'mastered')) as object
    await CloudQuestionRepository.pushOne(context, accountId, SyncEntityType.WRONG_QUESTION,
      questionUuid, SyncOperationType.UPSERT, payload)
  }

  /**
   * Deletes a question bank on the server first, then refreshes the cache so
   * the bank, its questions, and its wrong-question rows disappear together.
   */
  static async deleteBank(bankUuid: string, context: Context): Promise<void> {
    if (bankUuid.trim().length === 0) {
      throw new Error('题库标识无效')
    }
    const accountId: string = await CloudQuestionRepository.requireSignedIn(context)
    await CloudQuestionRepository.pushOne(context, accountId, SyncEntityType.QUESTION_BANK,
      bankUuid, SyncOperationType.DELETE, EMPTY_PAYLOAD)
  }

  /**
   * Creates a JSON-imported bank server-first: one bank upsert followed by
   * one upsert per question, all pushed through /v1/sync/push in bounded
   * batches. Only after the server acknowledges every operation are the
   * returned authoritative operations applied to the account cache.
   */
  static async createBank(bank: QuestionBank, context: Context): Promise<string> {
    if (bank.bankName.trim().length === 0) {
      throw new Error('题库名不能为空')
    }
    const accountId: string = await CloudQuestionRepository.requireSignedIn(context)
    const bankUuid: string = util.generateRandomUUID()
    const operations: Array<SyncPushOperation> = new Array<SyncPushOperation>()
    operations.push(new SyncPushOperation(new SyncOutboxOperation(
      util.generateRandomUUID(), SyncEntityType.QUESTION_BANK, bankUuid, SyncOperationType.UPSERT,
      SyncPayloadFactory.bankPayload(bank.bankName, bank.subject), Date.now())))
    for (let index: number = 0; index < bank.questions.length; index++) {
      const question: Question = bank.questions[index]
      const questionUuid: string = util.generateRandomUUID()
      operations.push(new SyncPushOperation(new SyncOutboxOperation(
        util.generateRandomUUID(), SyncEntityType.QUESTION, questionUuid, SyncOperationType.UPSERT,
        SyncPayloadFactory.questionPayload(question, bankUuid), Date.now())))
    }
    const applied: Array<RemoteSyncOperation> =
      await CloudQuestionRepository.pushOperations(context, operations)
    const snapshot: CloudCacheSnapshot = await CloudQuestionRepository.loadSnapshot(accountId)
    CloudQuestionRepository.applyOrdered(accountId, snapshot, applied)
    await CloudQuestionRepository.saveSnapshot(accountId, snapshot,
      CloudQuestionRepository.maxSequence(applied))
    return bankUuid
  }

  /**
   * Clears every wrong-question row on the server first with one bounded
   * push, then applies the authoritative returned operations to the cache.
   * The legacy wrong_question table is never touched here.
   */
  static async clearWrongQuestions(context: Context): Promise<void> {
    const accountId: string = await CloudQuestionRepository.requireSignedIn(context)
    const wrong: Array<CloudWrongCache> = await CloudCacheService.wrongQuestions(accountId)
    const operations: Array<SyncPushOperation> = new Array<SyncPushOperation>()
    for (let index: number = 0; index < wrong.length; index++) {
      operations.push(new SyncPushOperation(new SyncOutboxOperation(
        util.generateRandomUUID(), SyncEntityType.WRONG_QUESTION, wrong[index].questionUuid,
        SyncOperationType.DELETE, JSON.stringify(EMPTY_PAYLOAD), Date.now())))
    }
    if (operations.length === 0) {
      return
    }
    const applied: Array<RemoteSyncOperation> =
      await CloudQuestionRepository.pushOperations(context, operations)
    const snapshot: CloudCacheSnapshot = await CloudQuestionRepository.loadSnapshot(accountId)
    CloudQuestionRepository.applyOrdered(accountId, snapshot, applied)
    await CloudQuestionRepository.saveSnapshot(accountId, snapshot,
      CloudQuestionRepository.maxSequence(applied))
  }

  private static async pushOperations(context: Context,
    operations: Array<SyncPushOperation>): Promise<Array<RemoteSyncOperation>> {
    const applied: Array<RemoteSyncOperation> = new Array<RemoteSyncOperation>()
    let offset: number = 0
    while (offset < operations.length) {
      const remaining: number = operations.length - offset
      const size: number = remaining < PUSH_BATCH_LIMIT ? remaining : PUSH_BATCH_LIMIT
      const batch: Array<SyncPushOperation> = operations.slice(offset, offset + size)
      const response: SyncPushResponse = await CloudQuestionRepository.authorizedPush(
        new SyncPushBody(batch), context)
      if (response.operations.length !== batch.length) {
        throw new Error('服务器未确认全部同步操作')
      }
      for (let index: number = 0; index < response.operations.length; index++) {
        applied.push(response.operations[index])
      }
      offset += size
    }
    return applied
  }

  private static async authorizedPush(body: SyncPushBody, context: Context,
    retried: boolean = false): Promise<SyncPushResponse> {
    const accessToken: string = await AccountSessionService.accessToken(context)
    if (accessToken.length === 0) {
      throw new Error('请先登录华为账号')
    }
    try {
      return await ApiHttpClient.authorizedPost<SyncPushResponse>('/v1/sync/push', body, accessToken)
    } catch (err) {
      if (!retried && err instanceof ApiHttpError && err.statusCode === 401) {
        const refreshed: string = await AccountSessionService.refresh(context)
        return ApiHttpClient.authorizedPost<SyncPushResponse>('/v1/sync/push', body, refreshed)
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('同步操作提交失败')
    }
  }

  private static async pushOne(context: Context, accountId: string, entityType: SyncEntityType,
    entityUuid: string, operationType: SyncOperationType, payload: object,
    retried: boolean = false): Promise<void> {
    const accessToken: string = await AccountSessionService.accessToken(context)
    if (accessToken.length === 0) {
      throw new Error('请先登录华为账号')
    }
    const source: SyncOutboxOperation = new SyncOutboxOperation(
      util.generateRandomUUID(), entityType, entityUuid, operationType,
      JSON.stringify(payload), Date.now())
    const body: SyncPushBody = new SyncPushBody([new SyncPushOperation(source)])
    let response: SyncPushResponse
    try {
      response = await ApiHttpClient.authorizedPost<SyncPushResponse>('/v1/sync/push', body, accessToken)
    } catch (err) {
      if (!retried && err instanceof ApiHttpError && err.statusCode === 401) {
        const refreshed: string = await AccountSessionService.refresh(context)
        await CloudQuestionRepository.pushOne(context, accountId, entityType, entityUuid,
          operationType, payload, true)
        return
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('同步操作提交失败')
    }
    if (response.operations.length === 0) {
      throw new Error('服务器未确认同步操作')
    }
    const snapshot: CloudCacheSnapshot = await CloudQuestionRepository.loadSnapshot(accountId)
    CloudQuestionRepository.applyOrdered(accountId, snapshot, response.operations)
    await CloudQuestionRepository.saveSnapshot(accountId, snapshot,
      CloudQuestionRepository.maxSequence(response.operations))
  }

  private static async authorizedPull(accessToken: string, cursor: string, context: Context,
    retried: boolean = false): Promise<SyncPullResponse> {
    try {
      return await ApiHttpClient.authorizedGet<SyncPullResponse>(
        '/v1/sync/pull?cursor=' + encodeURIComponent(cursor) + '&limit=' + PULL_LIMIT.toString(),
        accessToken)
    } catch (err) {
      if (!retried && err instanceof ApiHttpError && err.statusCode === 401) {
        const refreshed: string = await AccountSessionService.refresh(context)
        return CloudQuestionRepository.authorizedPull(refreshed, cursor, context, true)
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('云端同步拉取失败')
    }
  }

  private static async requireSignedIn(context: Context): Promise<string> {
    const session: AccountSessionState = await AccountSessionService.state(context)
    if (!session.signedIn || session.userId.trim().length === 0) {
      throw new Error('请先登录华为账号')
    }
    return session.userId
  }

  private static async loadSnapshot(accountId: string): Promise<CloudCacheSnapshot> {
    const banks: Map<string, CloudBankCache> = new Map<string, CloudBankCache>()
    const questions: Map<string, CloudQuestionCache> = new Map<string, CloudQuestionCache>()
    const cachedBanks: Array<CloudBankCache> = await CloudCacheService.banks(accountId)
    for (let index: number = 0; index < cachedBanks.length; index++) {
      const bank: CloudBankCache = cachedBanks[index]
      banks.set(bank.bankUuid, bank)
      const bankQuestions: Array<CloudQuestionCache> =
        await CloudCacheService.questions(accountId, bank.bankUuid)
      for (let questionIndex: number = 0; questionIndex < bankQuestions.length; questionIndex++) {
        questions.set(bankQuestions[questionIndex].questionUuid, bankQuestions[questionIndex])
      }
    }
    const wrongQuestions: Map<string, CloudWrongCache> = new Map<string, CloudWrongCache>()
    const cachedWrong: Array<CloudWrongCache> = await CloudCacheService.wrongQuestions(accountId)
    for (let index: number = 0; index < cachedWrong.length; index++) {
      wrongQuestions.set(cachedWrong[index].questionUuid, cachedWrong[index])
    }
    return new CloudCacheSnapshot(banks, questions, wrongQuestions)
  }

  private static applyOrdered(accountId: string, snapshot: CloudCacheSnapshot,
    operations: Array<RemoteSyncOperation>): void {
    const ordered: Array<RemoteSyncOperation> = operations.slice()
    ordered.sort((left: RemoteSyncOperation, right: RemoteSyncOperation): number =>
      SyncSequence.compare(left.serverSequence, right.serverSequence))
    for (let index: number = 0; index < ordered.length; index++) {
      CloudQuestionRepository.applyOperation(accountId, snapshot, ordered[index])
    }
  }

  private static applyOperation(accountId: string, snapshot: CloudCacheSnapshot,
    operation: RemoteSyncOperation): void {
    if (operation.entityType === SyncEntityType.QUESTION_BANK) {
      CloudQuestionRepository.applyBank(accountId, snapshot, operation)
    } else if (operation.entityType === SyncEntityType.QUESTION) {
      CloudQuestionRepository.applyQuestion(accountId, snapshot, operation)
    } else if (operation.entityType === SyncEntityType.WRONG_QUESTION) {
      CloudQuestionRepository.applyWrongQuestion(accountId, snapshot, operation)
    }
  }

  private static applyBank(accountId: string, snapshot: CloudCacheSnapshot,
    operation: RemoteSyncOperation): void {
    const existing: CloudBankCache | undefined = snapshot.banks.get(operation.entityId)
    if (operation.operationType === SyncOperationType.DELETE) {
      if (existing === undefined) {
        return
      }
      snapshot.banks.delete(operation.entityId)
      const removedKeys: Array<string> = new Array<string>()
      snapshot.questions.forEach((question: CloudQuestionCache, key: string) => {
        if (question.bankUuid === operation.entityId) {
          removedKeys.push(key)
        }
      })
      for (let index: number = 0; index < removedKeys.length; index++) {
        snapshot.questions.delete(removedKeys[index])
        snapshot.wrongQuestions.delete(removedKeys[index])
      }
      return
    }
    const name: string = operation.payload.name === undefined || operation.payload.name === null ?
      '云端题库' : operation.payload.name
    const subject: string = operation.payload.subject === undefined || operation.payload.subject === null ?
      '未分类' : operation.payload.subject
    const questionCount: number = existing === undefined ? 0 : existing.questionCount
    snapshot.banks.set(operation.entityId, new CloudBankCache(
      accountId, operation.entityId, name, subject, questionCount,
      operation.serverSequence, Date.now()))
  }

  private static applyQuestion(accountId: string, snapshot: CloudCacheSnapshot,
    operation: RemoteSyncOperation): void {
    const existing: CloudQuestionCache | undefined = snapshot.questions.get(operation.entityId)
    if (operation.operationType === SyncOperationType.DELETE) {
      if (existing !== undefined) {
        snapshot.questions.delete(operation.entityId)
        snapshot.wrongQuestions.delete(operation.entityId)
      }
      return
    }
    const bankUuid: string = operation.payload.bankClientId === undefined ||
      operation.payload.bankClientId === null ?
      (existing === undefined ? '' : existing.bankUuid) : operation.payload.bankClientId
    const type: string = operation.payload.type === undefined || operation.payload.type === null ?
      'unclassified' : operation.payload.type
    const content: string = operation.payload.question === undefined || operation.payload.question === null ?
      '未命名题目' : operation.payload.question
    const answer: string = operation.payload.answer === undefined || operation.payload.answer === null ?
      '' : operation.payload.answer
    const analysis: string = operation.payload.analysis === undefined || operation.payload.analysis === null ?
      '' : operation.payload.analysis
    const sortOrder: number = existing === undefined ?
      CloudQuestionRepository.nextSortOrder(snapshot, bankUuid) : existing.sortOrder
    snapshot.questions.set(operation.entityId, new CloudQuestionCache(
      accountId, operation.entityId, bankUuid, type, content,
      CloudQuestionRepository.optionsJson(operation.payload.options), answer, analysis,
      operation.serverSequence, sortOrder))
  }

  private static applyWrongQuestion(accountId: string, snapshot: CloudCacheSnapshot,
    operation: RemoteSyncOperation): void {
    const existing: CloudWrongCache | undefined = snapshot.wrongQuestions.get(operation.entityId)
    if (operation.operationType === SyncOperationType.DELETE) {
      if (existing !== undefined) {
        snapshot.wrongQuestions.delete(operation.entityId)
      }
      return
    }
    const question: CloudQuestionCache | undefined = snapshot.questions.get(operation.entityId)
    const bankUuid: string = question === undefined ?
      (existing === undefined ? '' : existing.bankUuid) : question.bankUuid
    let subject: string = existing === undefined ? '' : existing.subject
    if (bankUuid.length > 0) {
      const bank: CloudBankCache | undefined = snapshot.banks.get(bankUuid)
      if (bank !== undefined) {
        subject = bank.subject
      }
    }
    const status: string = operation.payload.status === undefined || operation.payload.status === null ?
      'pending' : operation.payload.status
    const userAnswer: string = ''
    snapshot.wrongQuestions.set(operation.entityId, new CloudWrongCache(
      accountId, operation.entityId, bankUuid, subject, status, userAnswer,
      operation.serverSequence, Date.now()))
  }

  private static async saveSnapshot(accountId: string, snapshot: CloudCacheSnapshot,
    cursor: string): Promise<void> {
    const banks: Array<CloudBankCache> = new Array<CloudBankCache>()
    const questions: Array<CloudQuestionCache> = new Array<CloudQuestionCache>()
    const wrongQuestions: Array<CloudWrongCache> = new Array<CloudWrongCache>()
    snapshot.banks.forEach((bank: CloudBankCache) => {
      let count: number = 0
      snapshot.questions.forEach((question: CloudQuestionCache) => {
        if (question.bankUuid === bank.bankUuid) {
          count++
        }
      })
      banks.push(new CloudBankCache(
        bank.accountId, bank.bankUuid, bank.bankName, bank.subject, count,
        bank.serverVersion, bank.updateTime))
    })
    snapshot.questions.forEach((question: CloudQuestionCache) => {
      questions.push(question)
    })
    snapshot.wrongQuestions.forEach((item: CloudWrongCache) => {
      wrongQuestions.push(item)
    })
    await CloudCacheService.replacePage(accountId,
      new CloudCachePage(cursor, Date.now(), banks, questions, wrongQuestions))
  }

  private static maxSequence(operations: Array<RemoteSyncOperation>): string {
    const ordered: Array<RemoteSyncOperation> = operations.slice()
    ordered.sort((left: RemoteSyncOperation, right: RemoteSyncOperation): number =>
      SyncSequence.compare(left.serverSequence, right.serverSequence))
    return ordered[ordered.length - 1].serverSequence
  }

  private static nextSortOrder(snapshot: CloudCacheSnapshot, bankUuid: string): number {
    let maximum: number = -1
    snapshot.questions.forEach((question: CloudQuestionCache) => {
      if (question.bankUuid === bankUuid && question.sortOrder > maximum) {
        maximum = question.sortOrder
      }
    })
    return maximum + 1
  }

  private static optionsJson(options: Record<string, string> | null | undefined): string {
    if (options === undefined || options === null) {
      return '[]'
    }
    const keys: Array<string> = Object.keys(options)
    keys.sort((left: string, right: string): number => Number(left) - Number(right))
    const values: Array<string> = new Array<string>()
    for (let index: number = 0; index < keys.length; index++) {
      values.push(options[keys[index]])
    }
    return JSON.stringify(values)
  }

  private static parseOptions(optionsJson: string): Array<string> {
    if (optionsJson.trim().length === 0) {
      return new Array<string>()
    }
    try {
      const parsed: Array<string> = JSON.parse(optionsJson) as Array<string>
      return parsed
    } catch {
      return new Array<string>()
    }
  }

  private static async toQuestion(accountId: string, cached: CloudQuestionCache): Promise<Question> {
    const images: Array<DeviceQuestionImage> =
      await DeviceImageStore.images(accountId, cached.questionUuid)
    const questionImages: Array<QuestionImage> = new Array<QuestionImage>()
    for (let index: number = 0; index < images.length; index++) {
      questionImages.push(new QuestionImage(
        cached.questionUuid + '_image_' + index.toString(), cached.questionUuid,
        images[index].sortOrder, images[index].imagePath, images[index].sortOrder))
    }
    return new Question(
      cached.questionUuid, cached.bankUuid, cached.type, cached.content,
      CloudQuestionRepository.parseOptions(cached.optionsJson), cached.answer, cached.analysis,
      0, 0, 'confirmed', questionImages)
  }
}
