import { Context } from '@kit.AbilityKit'
import { AccountSessionState } from '../models/AccountSession'
import {
  CloudSyncResult,
  SyncDisplayState
} from '../models/SyncModels'
import { AccountSessionService } from './AccountSessionService'
import { CloudQuestionRepository } from './CloudQuestionRepository'

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
    CloudSyncService.displayStateValue = SyncDisplayState.SYNCING
    try {
      // Server-first refresh: pulls the authoritative operation stream into
      // the account cloud cache. The legacy outbox push/pull main flow is
      // retired; residual outbox rows and the v5 tables stay untouched for
      // migration recovery.
      await CloudQuestionRepository.refresh(session.userId, context)
      CloudSyncService.displayStateValue = SyncDisplayState.SYNCED
      return new CloudSyncResult(SyncDisplayState.SYNCED, 0, 0)
    } catch (err) {
      CloudSyncService.displayStateValue = SyncDisplayState.FAILED
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Cloud synchronization failed')
    }
  }
}
