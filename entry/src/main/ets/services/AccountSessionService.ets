import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import {
  AccountSessionState,
  AccountSessionTiming,
  LoginResult,
  SessionTokens
} from '../models/AccountSession'
import { ApiHttpError } from '../models/ApiModels'
import { ApiHttpClient } from './ApiHttpClient'
import { AccountRefreshCredential, AccountSessionStore } from './AccountSessionStore'
import { CloudCacheService } from './CloudCacheService'

const PREFERENCES_NAME: string = 'account_metadata'
const USER_ID_KEY: string = 'user_id'
const DEVICE_ID_KEY: string = 'device_id'
const DEVICE_NAME_KEY: string = 'device_name'

interface RefreshBody {
  refreshToken: string
}

export class AccountSessionService {
  private static accessTokenValue: string = ''
  private static accessTokenExpiresAt: number = 0
  private static accessTokenAccountId: string = ''
  private static refreshInFlight: Promise<string> | null = null
  private static signingOut: boolean = false
  private static accountOperationTail: Promise<void> = Promise.resolve()

  static async installLogin(context: Context, result: LoginResult,
    deviceName: string): Promise<AccountSessionState> {
    if (AccountSessionService.signingOut) {
      throw new Error('账号正在退出，请稍后重试')
    }
    const userId: string = result.userId
    const deviceId: string = result.deviceId
    const accessToken: string = result.accessToken
    const refreshToken: string = result.refreshToken
    const expiresInSeconds: number = result.expiresInSeconds
    const savedDeviceName: string = deviceName
    return AccountSessionService.runAccountExclusive(async (): Promise<AccountSessionState> => {
      AccountSessionService.clearMemory()
      const credential: AccountRefreshCredential = new AccountRefreshCredential(userId, refreshToken)
      await AccountSessionStore.saveRefreshCredential(credential)
      const store: preferences.Preferences =
        await preferences.getPreferences(context, PREFERENCES_NAME)
      await store.put(USER_ID_KEY, userId)
      await store.put(DEVICE_ID_KEY, deviceId)
      await store.put(DEVICE_NAME_KEY, savedDeviceName)
      await store.flush()
      await AccountSessionService.installTokens(context, accessToken, expiresInSeconds, credential)
      return {
        signedIn: true,
        userId: userId,
        deviceName: savedDeviceName
      }
    })
  }

  static async restore(context: Context): Promise<void> {
    const current: AccountSessionState = await AccountSessionService.state(context)
    if (!current.signedIn) {
      AccountSessionService.clearMemory()
      return
    }
    await AccountSessionService.refresh(context)
  }

  static async accessToken(context: Context): Promise<string> {
    if (AccountSessionService.signingOut) {
      return ''
    }
    const current: AccountSessionState = await AccountSessionService.state(context)
    if (!current.signedIn) {
      AccountSessionService.clearMemory()
      return ''
    }
    if (AccountSessionService.accessTokenAccountId === current.userId &&
      AccountSessionTiming.isFresh(AccountSessionService.accessTokenExpiresAt, Date.now()) &&
      AccountSessionService.accessTokenValue.length > 0) {
      return AccountSessionService.accessTokenValue
    }
    return AccountSessionService.refresh(context)
  }

  static async requireAccount(context: Context, expectedAccountId: string): Promise<void> {
    if (expectedAccountId.trim().length === 0) {
      throw new Error('Expected account cannot be empty')
    }
    const current: AccountSessionState = await AccountSessionService.state(context)
    if (!current.signedIn || current.userId !== expectedAccountId) {
      throw new Error('当前账号与导入会话不一致')
    }
  }

  /**
   * Runs a cache-only action in the account mutation lane. The action must not
   * request or refresh tokens because those operations use the same lane.
   */
  static async runExpectedAccountLocalExclusive<T>(context: Context,
    expectedAccountId: string, action: () => Promise<T>): Promise<T> {
    const accountId: string = expectedAccountId
    if (accountId.trim().length === 0) {
      throw new Error('Expected account cannot be empty')
    }
    if (AccountSessionService.signingOut) {
      throw new Error('账号正在退出，请稍后重试')
    }
    return AccountSessionService.runAccountExclusive(async (): Promise<T> => {
      const current: AccountSessionState = await AccountSessionService.state(context)
      if (!current.signedIn || current.userId !== accountId) {
        throw new Error('当前账号与导入会话不一致')
      }
      return action()
    })
  }

  static async accessTokenForAccount(context: Context,
    expectedAccountId: string): Promise<string> {
    await AccountSessionService.requireAccount(context, expectedAccountId)
    const accessToken: string = await AccountSessionService.accessToken(context)
    await AccountSessionService.requireAccount(context, expectedAccountId)
    if (accessToken.length === 0 ||
      AccountSessionService.accessTokenAccountId !== expectedAccountId) {
      throw new Error('当前账号令牌与导入会话不一致')
    }
    return accessToken
  }

  static async refreshForAccount(context: Context, expectedAccountId: string): Promise<string> {
    await AccountSessionService.requireAccount(context, expectedAccountId)
    const accessToken: string = await AccountSessionService.refresh(context)
    await AccountSessionService.requireAccount(context, expectedAccountId)
    if (accessToken.length === 0 ||
      AccountSessionService.accessTokenAccountId !== expectedAccountId) {
      throw new Error('刷新后的账号令牌与导入会话不一致')
    }
    return accessToken
  }

  static async refresh(context: Context): Promise<string> {
    if (AccountSessionService.signingOut) {
      return ''
    }
    const active: Promise<string> | null = AccountSessionService.refreshInFlight
    if (active !== null) {
      return active
    }
    const started: Promise<string> = AccountSessionService.performRefresh(context)
    AccountSessionService.refreshInFlight = started
    try {
      return await started
    } finally {
      if (AccountSessionService.refreshInFlight === started) {
        AccountSessionService.refreshInFlight = null
      }
    }
  }

  static async signOut(context: Context): Promise<void> {
    if (AccountSessionService.signingOut) {
      return
    }
    AccountSessionService.signingOut = true
    try {
      const activeRefresh: Promise<string> | null = AccountSessionService.refreshInFlight
      if (activeRefresh !== null) {
        try {
          await activeRefresh
        } catch {
        }
      }
      await AccountSessionService.runAccountExclusive(async (): Promise<void> =>
        AccountSessionService.performSignOutExclusive(context))
    } finally {
      AccountSessionService.signingOut = false
    }
  }

  private static async performSignOutExclusive(context: Context): Promise<void> {
    const session: AccountSessionState = await AccountSessionService.state(context)
    const credential: AccountRefreshCredential | null = await AccountSessionStore.refreshCredential()
    if (session.signedIn && credential !== null && credential.ownerAccountId === session.userId) {
      try {
        const body: RefreshBody = { refreshToken: credential.refreshToken }
        await ApiHttpClient.post<void>('/v1/auth/logout', body)
      } catch {
      }
    }
    await AccountSessionStore.clearSession()
    AccountSessionService.clearMemory()
    try {
      if (session.userId.length > 0) {
        await CloudCacheService.clearAccountTextCache(session.userId)
      }
    } finally {
      await AccountSessionService.clearMetadata(context)
    }
  }

  static async state(context: Context): Promise<AccountSessionState> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const userId: preferences.ValueType = await store.get(USER_ID_KEY, '')
    const deviceName: preferences.ValueType = await store.get(DEVICE_NAME_KEY, '')
    const credential: AccountRefreshCredential | null = await AccountSessionStore.refreshCredential()
    return {
      signedIn: credential !== null && typeof userId === 'string' &&
        userId.length > 0 && credential.ownerAccountId === userId,
      userId: typeof userId === 'string' ? userId : '',
      deviceName: typeof deviceName === 'string' ? deviceName : ''
    }
  }

  static async deviceKey(): Promise<string> {
    return AccountSessionStore.deviceKey()
  }

  private static async performRefresh(context: Context): Promise<string> {
    return AccountSessionService.runAccountExclusive(async (): Promise<string> =>
      AccountSessionService.performRefreshExclusive(context))
  }

  private static async performRefreshExclusive(context: Context): Promise<string> {
    const accountId: string = await AccountSessionService.metadataUserId(context)
    const credential: AccountRefreshCredential | null = await AccountSessionStore.refreshCredential()
    if (credential === null || accountId.length === 0 || credential.ownerAccountId !== accountId) {
      AccountSessionService.clearMemory()
      return ''
    }
    try {
      const body: RefreshBody = { refreshToken: credential.refreshToken }
      const tokens: SessionTokens = await ApiHttpClient.post<SessionTokens>('/v1/auth/refresh', body)
      const currentAccountId: string = await AccountSessionService.metadataUserId(context)
      const currentCredential: AccountRefreshCredential | null =
        await AccountSessionStore.refreshCredential()
      if (currentAccountId !== accountId || currentCredential === null ||
        currentCredential.ownerAccountId !== accountId ||
        currentCredential.refreshToken !== credential.refreshToken) {
        throw new Error('账号在令牌刷新期间发生变化')
      }
      const rotated: AccountRefreshCredential =
        new AccountRefreshCredential(accountId, tokens.refreshToken)
      await AccountSessionStore.saveRefreshCredential(rotated)
      await AccountSessionService.installTokens(context, tokens.accessToken,
        tokens.expiresInSeconds, rotated)
      return tokens.accessToken
    } catch (err) {
      if (err instanceof ApiHttpError && err.statusCode === 401) {
        await AccountSessionStore.clearSession()
        if (!AccountSessionService.signingOut) {
          await AccountSessionService.clearMetadata(context)
        }
        AccountSessionService.clearMemory()
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('Session refresh failed')
    }
  }

  private static async installTokens(context: Context, accessToken: string,
    expiresInSeconds: number, credential: AccountRefreshCredential): Promise<void> {
    const accountId: string = await AccountSessionService.metadataUserId(context)
    const stored: AccountRefreshCredential | null = await AccountSessionStore.refreshCredential()
    if (stored === null || stored.ownerAccountId !== accountId ||
      credential.ownerAccountId !== accountId || stored.refreshToken !== credential.refreshToken) {
      AccountSessionService.clearMemory()
      throw new Error('当前账号与安全凭据不一致，请重新登录')
    }
    AccountSessionService.accessTokenValue = accessToken
    AccountSessionService.accessTokenExpiresAt =
      AccountSessionTiming.expiresAt(Date.now(), expiresInSeconds)
    AccountSessionService.accessTokenAccountId = accountId
  }

  private static clearMemory(): void {
    AccountSessionService.accessTokenValue = ''
    AccountSessionService.accessTokenExpiresAt = 0
    AccountSessionService.accessTokenAccountId = ''
  }

  private static async runAccountExclusive<T>(action: () => Promise<T>): Promise<T> {
    const previous: Promise<void> = AccountSessionService.accountOperationTail
    let release: () => void = (): void => {}
    const gate: Promise<void> = new Promise<void>((resolve): void => {
      release = resolve
    })
    AccountSessionService.accountOperationTail = previous.then((): Promise<void> => gate,
      (): Promise<void> => gate)
    try {
      await previous
    } catch {
    }
    try {
      return await action()
    } finally {
      release()
    }
  }

  private static async metadataUserId(context: Context): Promise<string> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const userId: preferences.ValueType = await store.get(USER_ID_KEY, '')
    return typeof userId === 'string' ? userId : ''
  }

  private static async clearMetadata(context: Context): Promise<void> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    await store.delete(USER_ID_KEY)
    await store.delete(DEVICE_ID_KEY)
    await store.delete(DEVICE_NAME_KEY)
    await store.flush()
  }
}
