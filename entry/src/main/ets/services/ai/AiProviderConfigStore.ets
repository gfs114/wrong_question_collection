import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import {
  AiImportError,
  AiImportErrorCode,
  AiProviderConfig,
  AiProviderConfigValidator
} from '../../models/ai/AiProviderConfig'

const PREFERENCES_NAME: string = 'ai_provider_config'
const PROVIDER_KEY: string = 'provider_id'
const MODEL_KEY: string = 'model'
const BASE_URL_KEY: string = 'base_url'
const UPDATE_PENDING_KEY: string = 'credential_update_pending'

export class AiProviderConfigStore {
  private static stateTail: Promise<void> = Promise.resolve()
  private static updateTail: Promise<void> = Promise.resolve()
  private static updateUncertain: boolean = false

  static async runUpdateExclusive<T>(action: () => Promise<T>): Promise<T> {
    const run: Promise<T> = AiProviderConfigStore.updateTail.then(action, action)
    AiProviderConfigStore.updateTail = run.then((_value: T): void => {}, (): void => {})
    return run
  }

  private static async runStateExclusive<T>(action: () => Promise<T>): Promise<T> {
    const run: Promise<T> = AiProviderConfigStore.stateTail.then(action, action)
    AiProviderConfigStore.stateTail = run.then((_value: T): void => {}, (): void => {})
    return run
  }

  static sameConfig(left: AiProviderConfig | null, right: AiProviderConfig): boolean {
    return left !== null && left.providerId === right.providerId &&
      left.model === right.model && left.baseUrl === right.baseUrl
  }

  static sameCredentialScope(left: AiProviderConfig | null, right: AiProviderConfig): boolean {
    if (left === null) return false
    const normalizedLeft: AiProviderConfig = AiProviderConfigValidator.normalize(left)
    const normalizedRight: AiProviderConfig = AiProviderConfigValidator.normalize(right)
    return normalizedLeft.providerId === normalizedRight.providerId &&
      normalizedLeft.baseUrl === normalizedRight.baseUrl
  }

  static async isCredentialUpdatePending(context: Context): Promise<boolean> {
    return AiProviderConfigStore.runStateExclusive<boolean>(
      (): Promise<boolean> => AiProviderConfigStore.pendingLocked(context))
  }

  private static async pendingLocked(context: Context): Promise<boolean> {
    if (AiProviderConfigStore.updateUncertain) return true
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    return await store.get(UPDATE_PENDING_KEY, false) !== false
  }

  static async beginCredentialUpdate(context: Context): Promise<void> {
    await AiProviderConfigStore.runStateExclusive<void>(async (): Promise<void> => {
      AiProviderConfigStore.updateUncertain = true
      const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
      await store.put(UPDATE_PENDING_KEY, true)
      await store.flush()
    })
  }

  static async completeCredentialUpdate(context: Context): Promise<void> {
    await AiProviderConfigStore.runStateExclusive<void>(async (): Promise<void> => {
      AiProviderConfigStore.updateUncertain = true
      const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
      try {
        await store.put(UPDATE_PENDING_KEY, false)
        await store.flush()
        AiProviderConfigStore.updateUncertain = false
      } catch {
        try {
          await store.put(UPDATE_PENDING_KEY, true)
          await store.flush()
        } catch {}
        throw new AiImportError(AiImportErrorCode.CREDENTIAL_UPDATE_PENDING)
      }
    })
  }

  static async loadUsable(context: Context): Promise<AiProviderConfig | null> {
    return AiProviderConfigStore.runStateExclusive<AiProviderConfig | null>(async (): Promise<AiProviderConfig | null> => {
      if (await AiProviderConfigStore.pendingLocked(context)) {
        throw new AiImportError(AiImportErrorCode.CREDENTIAL_UPDATE_PENDING)
      }
      return AiProviderConfigStore.loadLocked(context)
    })
  }

  static async requireUsable(context: Context, expected: AiProviderConfig): Promise<AiProviderConfig> {
    return AiProviderConfigStore.withUsableConfig<AiProviderConfig>(context, expected,
      async (): Promise<AiProviderConfig> => AiProviderConfigValidator.normalize(expected))
  }

  static async withUsableConfig<T>(context: Context, expected: AiProviderConfig,
    action: () => Promise<T>): Promise<T> {
    const normalized: AiProviderConfig = AiProviderConfigValidator.normalize(expected)
    return AiProviderConfigStore.runStateExclusive<T>(async (): Promise<T> => {
      if (await AiProviderConfigStore.pendingLocked(context)) {
        throw new AiImportError(AiImportErrorCode.CREDENTIAL_UPDATE_PENDING)
      }
      const saved: AiProviderConfig | null = await AiProviderConfigStore.loadLocked(context)
      if (!AiProviderConfigStore.sameConfig(saved, normalized)) {
        throw new AiImportError(AiImportErrorCode.CONFIG_NOT_SAVED)
      }
      return action()
    })
  }

  static async load(context: Context): Promise<AiProviderConfig | null> {
    return AiProviderConfigStore.runStateExclusive<AiProviderConfig | null>(
      (): Promise<AiProviderConfig | null> => AiProviderConfigStore.loadLocked(context))
  }

  private static async loadLocked(context: Context): Promise<AiProviderConfig | null> {
    const store: preferences.Preferences =
      await preferences.getPreferences(context, PREFERENCES_NAME)
    const providerValue: preferences.ValueType = await store.get(PROVIDER_KEY, '')
    const modelValue: preferences.ValueType = await store.get(MODEL_KEY, '')
    const baseUrlValue: preferences.ValueType = await store.get(BASE_URL_KEY, '')
    if (typeof providerValue !== 'string' || providerValue.length === 0 ||
      typeof modelValue !== 'string' || typeof baseUrlValue !== 'string') {
      return null
    }
    const providerId: string = providerValue
    const config: AiProviderConfig = new AiProviderConfig(providerId, modelValue, baseUrlValue)
    return AiProviderConfigValidator.normalize(config)
  }

  static async save(context: Context, config: AiProviderConfig): Promise<AiProviderConfig> {
    const snapshot: AiProviderConfig = AiProviderConfigValidator.normalize(config)
    return AiProviderConfigStore.runStateExclusive<AiProviderConfig>(
      (): Promise<AiProviderConfig> => AiProviderConfigStore.saveLocked(context, snapshot))
  }

  private static async saveLocked(context: Context, config: AiProviderConfig): Promise<AiProviderConfig> {
    const normalized: AiProviderConfig = AiProviderConfigValidator.normalize(config)
    const store: preferences.Preferences =
      await preferences.getPreferences(context, PREFERENCES_NAME)
    await store.put(PROVIDER_KEY, normalized.providerId)
    await store.put(MODEL_KEY, normalized.model)
    await store.put(BASE_URL_KEY, normalized.baseUrl)
    await store.flush()
    return normalized
  }

  static async clear(context: Context): Promise<void> {
    await AiProviderConfigStore.runStateExclusive<void>(async (): Promise<void> => {
      const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
      await store.delete(PROVIDER_KEY)
      await store.delete(MODEL_KEY)
      await store.delete(BASE_URL_KEY)
      await store.flush()
    })
  }
}
