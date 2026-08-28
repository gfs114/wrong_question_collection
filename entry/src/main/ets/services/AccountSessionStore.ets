import { asset } from '@kit.AssetStoreKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'

const ASSET_NOT_FOUND: number = 24000002
const REFRESH_TOKEN_ALIAS: string = 'wqc_refresh_token'
const DEVICE_KEY_ALIAS: string = 'wqc_device_key'

export class AccountSessionStore {
  static async refreshToken(): Promise<string> {
    return AccountSessionStore.read(REFRESH_TOKEN_ALIAS)
  }

  static async saveRefreshToken(value: string): Promise<void> {
    await AccountSessionStore.write(REFRESH_TOKEN_ALIAS, value)
  }

  static async deviceKey(): Promise<string> {
    const existing: string = await AccountSessionStore.read(DEVICE_KEY_ALIAS)
    if (existing.length > 0) {
      return existing
    }
    const generated: string = util.generateRandomUUID()
    await AccountSessionStore.write(DEVICE_KEY_ALIAS, generated)
    return generated
  }

  static async clearSession(): Promise<void> {
    await AccountSessionStore.remove(REFRESH_TOKEN_ALIAS)
  }

  private static bytes(value: string): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder()
    return encoder.encodeInto(value)
  }

  private static stringValue(value: Uint8Array): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
    return decoder.decodeToString(value)
  }

  private static query(alias: string): asset.AssetMap {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>()
    query.set(asset.Tag.ALIAS, AccountSessionStore.bytes(alias))
    return query
  }

  private static async write(alias: string, value: string): Promise<void> {
    const attributes: asset.AssetMap = AccountSessionStore.query(alias)
    attributes.set(asset.Tag.SECRET, AccountSessionStore.bytes(value))
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED)
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER)
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE)
    await asset.add(attributes)
  }

  private static async read(alias: string): Promise<string> {
    const query: asset.AssetMap = AccountSessionStore.query(alias)
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
    try {
      const results: Array<asset.AssetMap> = await asset.query(query)
      if (results.length === 0) {
        return ''
      }
      const value: asset.Value | undefined = results[0].get(asset.Tag.SECRET)
      if (value instanceof Uint8Array) {
        return AccountSessionStore.stringValue(value)
      }
      return ''
    } catch (err) {
      const businessError: BusinessError = err as BusinessError
      if (businessError.code === ASSET_NOT_FOUND) {
        return ''
      }
      throw new Error('Secure session value could not be read')
    }
  }

  private static async remove(alias: string): Promise<void> {
    try {
      await asset.remove(AccountSessionStore.query(alias))
    } catch (err) {
      const businessError: BusinessError = err as BusinessError
      if (businessError.code !== ASSET_NOT_FOUND) {
        throw new Error('Secure session value could not be removed')
      }
    }
  }
}
