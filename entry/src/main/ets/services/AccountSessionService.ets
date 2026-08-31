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
import { AccountSessionStore } from './AccountSessionStore'
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
  private static refreshInFlight: Promise<string> | null = null
  private static signingOut: boolean = false

  static async installLogin(context: Context, result: LoginResult,
    deviceName: string): Promise<AccountSessionState> {
    await AccountSessionService.installTokens(result)
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    await store.put(USER_ID_KEY, result.userId)
    await store.put(DEVICE_ID_KEY, result.deviceId)
    await store.put(DEVICE_NAME_KEY, deviceName)
    await store.flush()
    return {
      signedIn: true,
      userId: result.userId,
      deviceName: deviceName
    }
  }

  static async restore(context: Context): Promise<void> {
    const refreshToken: string = await AccountSessionStore.refreshToken()
    if (refreshToken.length === 0) {
      AccountSessionService.clearMemory()
      return
    }
    await AccountSessionService.refresh(context)
  }

  static async accessToken(context: Context): Promise<string> {
    if (AccountSessionService.signingOut) {
      return ''
    }
    if (AccountSessionTiming.isFresh(AccountSessionService.accessTokenExpiresAt, Date.now()) &&
      AccountSessionService.accessTokenValue.length > 0) {
      return AccountSessionService.accessTokenValue
    }
    return AccountSessionService.refresh(context)
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
      const session: AccountSessionState = await AccountSessionService.state(context)
      const activeRefresh: Promise<string> | null = AccountSessionService.refreshInFlight
      if (activeRefresh !== null) {
        try {
          await activeRefresh
        } catch {
        }
      }
      const refreshToken: string = await AccountSessionStore.refreshToken()
      if (refreshToken.length > 0) {
        try {
          const body: RefreshBody = { refreshToken: refreshToken }
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
    } finally {
      AccountSessionService.signingOut = false
    }
  }

  static async state(context: Context): Promise<AccountSessionState> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const userId: preferences.ValueType = await store.get(USER_ID_KEY, '')
    const deviceName: preferences.ValueType = await store.get(DEVICE_NAME_KEY, '')
    const refreshToken: string = await AccountSessionStore.refreshToken()
    return {
      signedIn: refreshToken.length > 0,
      userId: typeof userId === 'string' ? userId : '',
      deviceName: typeof deviceName === 'string' ? deviceName : ''
    }
  }

  static async deviceKey(): Promise<string> {
    return AccountSessionStore.deviceKey()
  }

  private static async performRefresh(context: Context): Promise<string> {
    const refreshToken: string = await AccountSessionStore.refreshToken()
    if (refreshToken.length === 0) {
      AccountSessionService.clearMemory()
      return ''
    }
    try {
      const body: RefreshBody = { refreshToken: refreshToken }
      const tokens: SessionTokens = await ApiHttpClient.post<SessionTokens>('/v1/auth/refresh', body)
      await AccountSessionService.installTokens(tokens)
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

  private static async installTokens(tokens: SessionTokens): Promise<void> {
    await AccountSessionStore.saveRefreshToken(tokens.refreshToken)
    AccountSessionService.accessTokenValue = tokens.accessToken
    AccountSessionService.accessTokenExpiresAt =
      AccountSessionTiming.expiresAt(Date.now(), tokens.expiresInSeconds)
  }

  private static clearMemory(): void {
    AccountSessionService.accessTokenValue = ''
    AccountSessionService.accessTokenExpiresAt = 0
  }

  private static async clearMetadata(context: Context): Promise<void> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    await store.delete(USER_ID_KEY)
    await store.delete(DEVICE_ID_KEY)
    await store.delete(DEVICE_NAME_KEY)
    await store.flush()
  }
}
