import { Context } from '@kit.AbilityKit'
import { AccountSessionState } from '../models/AccountSession'
import { ApiHttpError } from '../models/ApiModels'
import {
  CloudSyncResult,
  SyncDisplayState,
  SyncOutboxOperation,
  SyncPullResponse,
  SyncPushBody,
  SyncPushOperation,
  SyncPushResponse
} from '../models/SyncModels'
import { AccountSessionService } from './AccountSessionService'
import { ApiHttpClient } from './ApiHttpClient'
import { RemoteOperationApplier } from './RemoteOperationApplier'
import { SyncOutboxService } from './SyncOutboxService'

export class CloudSyncService {
  private static syncInFlight: Promise<CloudSyncResult> | null = null
  private static displayStateValue: SyncDisplayState = SyncDisplayState.LOCAL

  static displayState(): SyncDisplayState {
    return CloudSyncService.displayStateValue
  }

  static label(state: SyncDisplayState): string {
    if (state === SyncDisplayState.SYNCING) {
      return '同步中'
    }
    if (state === SyncDisplayState.SYNCED) {
      return '已同步'
    }
    if (state === SyncDisplayState.PENDING) {
      return '待同步'
    }
    if (state === SyncDisplayState.FAILED) {
      return '同步失败'
    }
    return '本地模式'
  }

  static async syncNow(context: Context): Promise<CloudSyncResult> {
    const active: Promise<CloudSyncResult> | null = CloudSyncService.syncInFlight
    if (active !== null) {
      return active
    }
    const started: Promise<CloudSyncResult> = CloudSyncService.run(context)
    CloudSyncService.syncInFlight = started
    try {
      return await started
    } finally {
      if (CloudSyncService.syncInFlight === started) {
        CloudSyncService.syncInFlight = null
      }
    }
  }

  private static async run(context: Context): Promise<CloudSyncResult> {
    const session: AccountSessionState = await AccountSessionService.state(context)
    if (!session.signedIn) {
      CloudSyncService.displayStateValue = SyncDisplayState.LOCAL
      return new CloudSyncResult(SyncDisplayState.LOCAL)
    }
    const userId: string = session.userId
    CloudSyncService.displayStateValue = SyncDisplayState.SYNCING
    let pushedCount: number = 0
    let pulledCount: number = 0
    try {
      while (true) {
        const pending: Array<SyncOutboxOperation> = await SyncOutboxService.pending(100)
        if (pending.length === 0) {
          break
        }
        const pushOperations: Array<SyncPushOperation> = new Array<SyncPushOperation>()
        const operationIds: Array<string> = new Array<string>()
        for (let index: number = 0; index < pending.length; index++) {
          pushOperations.push(new SyncPushOperation(pending[index]))
          operationIds.push(pending[index].operationId)
        }
        const body: SyncPushBody = new SyncPushBody(pushOperations)
        await CloudSyncService.authorizedPost<SyncPushResponse>('/v1/sync/push', body, context)
        await SyncOutboxService.acknowledge(operationIds)
        pushedCount += operationIds.length
      }

      let cursor: string = await SyncOutboxService.cursor(userId)
      let hasMore: boolean = true
      while (hasMore) {
        const response: SyncPullResponse = await CloudSyncService.authorizedGet<SyncPullResponse>(
          '/v1/sync/pull?cursor=' + encodeURIComponent(cursor) + '&limit=100', context)
        await RemoteOperationApplier.apply(userId, response.operations, response.nextCursor)
        pulledCount += response.operations.length
        cursor = response.nextCursor
        hasMore = response.hasMore
      }
      CloudSyncService.displayStateValue = SyncDisplayState.SYNCED
      return new CloudSyncResult(SyncDisplayState.SYNCED, pushedCount, pulledCount)
    } catch (err) {
      CloudSyncService.displayStateValue = SyncDisplayState.FAILED
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Cloud synchronization failed')
    }
  }

  private static async authorizedPost<T>(path: string, body: object, context: Context,
    retried: boolean = false): Promise<T> {
    const accessToken: string = await AccountSessionService.accessToken(context)
    try {
      return await ApiHttpClient.authorizedPost<T>(path, body, accessToken)
    } catch (err) {
      if (!retried && err instanceof ApiHttpError && err.statusCode === 401) {
        const refreshed: string = await AccountSessionService.refresh(context)
        return ApiHttpClient.authorizedPost<T>(path, body, refreshed)
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Authorized cloud request failed')
    }
  }

  private static async authorizedGet<T>(path: string, context: Context,
    retried: boolean = false): Promise<T> {
    const accessToken: string = await AccountSessionService.accessToken(context)
    try {
      return await ApiHttpClient.authorizedGet<T>(path, accessToken)
    } catch (err) {
      if (!retried && err instanceof ApiHttpError && err.statusCode === 401) {
        const refreshed: string = await AccountSessionService.refresh(context)
        return ApiHttpClient.authorizedGet<T>(path, refreshed)
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Authorized cloud request failed')
    }
  }
}
