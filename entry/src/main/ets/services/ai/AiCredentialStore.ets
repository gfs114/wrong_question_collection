import { Context } from '@kit.AbilityKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { preferences } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { AiImportError, AiImportErrorCode } from '../../models/ai/AiProviderConfig'
import { AiCredentialEnvelopeCodec, AiCredentialRecord, AiCredentialRecordCodec } from
  './AiCredentialEnvelopeCodec'
import { HuksAesGcmCipher, HuksCipherText } from './HuksAesGcmCipher'

const PREFERENCES_NAME: string = 'ai_credentials'
const CREDENTIAL_RECORD_KEY: string = 'credential_record'

export class AiCredentialStore {
  private static operationTail: Promise<void> = Promise.resolve()

  static async save(context: Context, apiKey: string): Promise<void> {
    await AiCredentialStore.runExclusive<void>(
      (): Promise<void> => AiCredentialStore.saveLocked(context, apiKey))
  }

  static async hasCredential(context: Context): Promise<boolean> {
    return AiCredentialStore.runExclusive<boolean>(
      (): Promise<boolean> => AiCredentialStore.hasCredentialLocked(context))
  }

  /**
   * The callback runs while the store lock is held and must not call AiCredentialStore again.
   */
  static async withCredential<T>(context: Context,
    action: (credential: Uint8Array) => Promise<T>): Promise<T> {
    return AiCredentialStore.runExclusive<T>(
      (): Promise<T> => AiCredentialStore.withCredentialLocked<T>(context, action))
  }

  static async clear(context: Context): Promise<void> {
    await AiCredentialStore.runExclusive<void>(
      (): Promise<void> => AiCredentialStore.clearLocked(context))
  }

  private static async runExclusive<T>(action: () => Promise<T>): Promise<T> {
    const run: Promise<T> = AiCredentialStore.operationTail.then(action, action)
    AiCredentialStore.operationTail = run.then(
      (_value: T): void => {},
      (): void => {})
    return run
  }

  private static async saveLocked(context: Context, apiKey: string): Promise<void> {
    const normalized: string = apiKey.trim()
    if (normalized.length === 0) {
      throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
    }
    const encoder: util.TextEncoder = new util.TextEncoder('utf-8')
    const plainText: Uint8Array = encoder.encodeInto(normalized)
    let encrypted: HuksCipherText | null = null
    try {
      encrypted = await HuksAesGcmCipher.encrypt(plainText)
      const envelope: string = AiCredentialEnvelopeCodec.encode(encrypted)
      const digest: string = await AiCredentialStore.envelopeDigest(envelope)
      const recordText: string = AiCredentialRecordCodec.encode(new AiCredentialRecord(digest, envelope))
      const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
      // One put replaces a self-contained record. If flush fails, Preferences may expose either the old or new record;
      // both remain internally consistent under the unchanged HUKS key.
      await store.put(CREDENTIAL_RECORD_KEY, recordText)
      await store.flush()
    } finally {
      plainText.fill(0)
      if (encrypted !== null) {
        encrypted.nonce.fill(0)
        encrypted.ciphertext.fill(0)
        encrypted.tag.fill(0)
      }
    }
  }

  private static async hasCredentialLocked(context: Context): Promise<boolean> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const rawRecord: preferences.ValueType = await store.get(CREDENTIAL_RECORD_KEY, '')
    if (typeof rawRecord !== 'string') {
      await AiCredentialStore.clearRecord(store)
      return false
    }
    if (rawRecord.length === 0) return false
    let record: AiCredentialRecord | null = null
    let encrypted: HuksCipherText | null = null
    try {
      record = AiCredentialRecordCodec.decode(rawRecord)
      encrypted = AiCredentialEnvelopeCodec.decode(record.envelope)
    } catch {
      await AiCredentialStore.clearRecord(store)
      return false
    }
    try {
      if (!await AiCredentialStore.matchesEnvelopeDigest(record.envelope, record.digest)) {
        await AiCredentialStore.clearRecord(store)
        return false
      }
      if (!await HuksAesGcmCipher.hasKey()) {
        await AiCredentialStore.clearRecord(store)
        return false
      }
      return true
    } finally {
      encrypted.nonce.fill(0)
      encrypted.ciphertext.fill(0)
      encrypted.tag.fill(0)
    }
  }

  private static async withCredentialLocked<T>(context: Context,
    action: (credential: Uint8Array) => Promise<T>): Promise<T> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const rawRecord: preferences.ValueType = await store.get(CREDENTIAL_RECORD_KEY, '')
    if (typeof rawRecord !== 'string' || rawRecord.length === 0) {
      await AiCredentialStore.clearRecord(store)
      throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
    }
    let record: AiCredentialRecord | null = null
    let encrypted: HuksCipherText | null = null
    try {
      record = AiCredentialRecordCodec.decode(rawRecord)
      encrypted = AiCredentialEnvelopeCodec.decode(record.envelope)
    } catch {
      await AiCredentialStore.clearRecord(store)
      throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
    }
    try {
      if (!await AiCredentialStore.matchesEnvelopeDigest(record.envelope, record.digest) ||
        !await HuksAesGcmCipher.hasKey()) {
        await AiCredentialStore.clearRecord(store)
        throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
      }
      return await AiCredentialStore.decryptAndUse<T>(encrypted, action)
    } finally {
      encrypted.nonce.fill(0)
      encrypted.ciphertext.fill(0)
      encrypted.tag.fill(0)
    }
  }

  private static async decryptAndUse<T>(encrypted: HuksCipherText,
    action: (credential: Uint8Array) => Promise<T>): Promise<T> {
    const plainText: Uint8Array = await HuksAesGcmCipher.decrypt(encrypted)
    try {
      return await action(plainText)
    } finally {
      plainText.fill(0)
    }
  }

  private static async clearLocked(context: Context): Promise<void> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    await AiCredentialStore.clearRecord(store)
    await HuksAesGcmCipher.deleteKey()
  }

  // This digest detects local preference corruption only; AES-GCM remains the authentication boundary.
  private static async envelopeDigest(value: string): Promise<string> {
    const encoder: util.TextEncoder = new util.TextEncoder('utf-8')
    const valueBytes: Uint8Array = encoder.encodeInto(value)
    let digestBytes: Uint8Array | null = null
    try {
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256')
      const input: cryptoFramework.DataBlob = { data: valueBytes }
      await md.update(input)
      const result: cryptoFramework.DataBlob = await md.digest()
      digestBytes = result.data
      const base64: util.Base64Helper = new util.Base64Helper()
      return base64.encodeToStringSync(digestBytes, util.Type.BASIC)
    } finally {
      valueBytes.fill(0)
      if (digestBytes !== null) digestBytes.fill(0)
    }
  }

  private static async matchesEnvelopeDigest(envelope: string, digest: string): Promise<boolean> {
    return await AiCredentialStore.envelopeDigest(envelope) === digest
  }

  private static async clearRecord(store: preferences.Preferences): Promise<void> {
    await store.delete(CREDENTIAL_RECORD_KEY)
    await store.flush()
  }
}
