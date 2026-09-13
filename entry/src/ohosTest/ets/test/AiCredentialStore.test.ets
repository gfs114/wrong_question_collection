import { describe, it, expect } from '@ohos/hypium'
import { Context } from '@kit.AbilityKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { preferences } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { huks } from '@kit.UniversalKeystoreKit'
import { AiImportError, AiImportErrorCode } from '../../../main/ets/models/ai/AiProviderConfig'
import { AiCredentialEnvelopeCodec, AiCredentialRecord, AiCredentialRecordCodec } from
  '../../../main/ets/services/ai/AiCredentialEnvelopeCodec'
import { AiCredentialStore } from '../../../main/ets/services/ai/AiCredentialStore'
import { HuksAesGcmCipher } from '../../../main/ets/services/ai/HuksAesGcmCipher'
import { Utf8Utils } from '../../../main/ets/utils/Utf8Utils'

const ALIAS: string = 'wrongquestion.ai.credentials.aes.v1'

async function credentialRecord(context: Context): Promise<string> {
  const store: preferences.Preferences = await preferences.getPreferences(context, 'ai_credentials')
  const raw: preferences.ValueType = await store.get('credential_record', '')
  return typeof raw === 'string' ? raw : ''
}

async function envelope(context: Context): Promise<string> {
  const raw: string = await credentialRecord(context)
  return raw.length === 0 ? '' : AiCredentialRecordCodec.decode(raw).envelope
}

async function replaceEnvelope(context: Context, value: string): Promise<void> {
  const current: AiCredentialRecord = AiCredentialRecordCodec.decode(await credentialRecord(context))
  const store: preferences.Preferences = await preferences.getPreferences(context, 'ai_credentials')
  await store.put('credential_record',
    AiCredentialRecordCodec.encode(new AiCredentialRecord(current.digest, value)))
  await store.flush()
}

async function sha256(value: string): Promise<string> {
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

async function replaceEnvelopeWithFreshDigest(context: Context, value: string): Promise<string> {
  const digest: string = await sha256(value)
  const recordText: string = AiCredentialRecordCodec.encode(new AiCredentialRecord(digest, value))
  const store: preferences.Preferences = await preferences.getPreferences(context, 'ai_credentials')
  await store.put('credential_record', recordText)
  await store.flush()
  return recordText
}

function mutateSegment(value: string, segmentIndex: number): string {
  const parts: Array<string> = value.split('.')
  const segment: string = parts[segmentIndex]
  const first: string = segment.charAt(0) === 'A' ? 'B' : 'A'
  parts[segmentIndex] = first + segment.substring(1)
  return parts.join('.')
}

async function expectMissingKey(context: Context): Promise<void> {
  let code: string = ''
  try {
    await AiCredentialStore.withCredential<void>(context,
      async (_credential: Uint8Array): Promise<void> => {})
  } catch (err) {
    if (err instanceof AiImportError) code = err.code
  }
  expect(code).assertEqual(AiImportErrorCode.MISSING_API_KEY)
  expect((await credentialRecord(context)).length).assertEqual(0)
}

export default function aiCredentialStoreTest(): void {
  describe('aiCredentialStore', () => {
    it('round trips Unicode without plaintext preferences', 0, async () => {
      const context: Context = getContext()
      const secret: string = 'sk-device-only-数学'
      await AiCredentialStore.clear(context)
      try {
        await AiCredentialStore.save(context, secret)
        let recovered: string = ''
        await AiCredentialStore.withCredential<void>(context,
          async (bytes: Uint8Array): Promise<void> => { recovered = Utf8Utils.decode(bytes) })
        const store: preferences.Preferences = await preferences.getPreferences(context, 'ai_credentials')
        const raw: preferences.ValueType = await store.get('credential_record', '')
        expect(recovered).assertEqual(secret)
        expect(typeof raw === 'string' && raw.indexOf(secret) < 0).assertTrue()
        await AiCredentialStore.clear(context)
        expect(await AiCredentialStore.hasCredential(context)).assertFalse()
      } finally {
        await AiCredentialStore.clear(context)
      }
    })

    it('uses a fresh nonce on every save', 0, async () => {
      const context: Context = getContext()
      await AiCredentialStore.clear(context)
      try {
        await AiCredentialStore.save(context, 'sk-first')
        const firstNonce: string = (await envelope(context)).split('.')[1]
        await AiCredentialStore.save(context, 'sk-second')
        const secondNonce: string = (await envelope(context)).split('.')[1]
        expect(firstNonce === secondNonce).assertFalse()
      } finally {
        await AiCredentialStore.clear(context)
      }
    })

    it('rejects one-character tampering in nonce, ciphertext, and tag', 0, async () => {
      const context: Context = getContext()
      await AiCredentialStore.clear(context)
      try {
        for (let segmentIndex: number = 1; segmentIndex <= 3; segmentIndex++) {
          await AiCredentialStore.clear(context)
          await AiCredentialStore.save(context, 'sk-tamper-check')
          await replaceEnvelope(context, mutateSegment(await envelope(context), segmentIndex))
          await expectMissingKey(context)
        }
      } finally {
        await AiCredentialStore.clear(context)
      }
    })

    it('clears an envelope whose device key is missing', 0, async () => {
      const context: Context = getContext()
      await AiCredentialStore.clear(context)
      try {
        await AiCredentialStore.save(context, 'sk-stale')
        await HuksAesGcmCipher.deleteKey()
        expect(await AiCredentialStore.hasCredential(context)).assertFalse()
        expect((await credentialRecord(context)).length).assertEqual(0)
      } finally {
        await AiCredentialStore.clear(context)
      }
    })

    it('does not export the device AES key', 0, async () => {
      const context: Context = getContext()
      await AiCredentialStore.clear(context)
      try {
        await AiCredentialStore.save(context, 'sk-non-exportable')
        let rejected: boolean = false
        try {
          await huks.exportKeyItem(ALIAS, { properties: [] })
        } catch {
          rejected = true
        }
        expect(rejected).assertTrue()
      } finally {
        await AiCredentialStore.clear(context)
      }
    })

    it('preserves a valid record when HUKS rejects authenticated tampering', 0, async () => {
      const context: Context = getContext()
      await AiCredentialStore.clear(context)
      try {
        await AiCredentialStore.save(context, 'sk-authentication-check')
        const mutated: string = mutateSegment(await envelope(context), 2)
        const parsed = AiCredentialEnvelopeCodec.decode(mutated)
        parsed.nonce.fill(0)
        parsed.ciphertext.fill(0)
        parsed.tag.fill(0)
        const recordText: string = await replaceEnvelopeWithFreshDigest(context, mutated)
        let rejected: boolean = false
        try {
          await AiCredentialStore.withCredential<void>(context,
            async (_credential: Uint8Array): Promise<void> => {})
        } catch {
          rejected = true
        }
        expect(rejected).assertTrue()
        expect(await credentialRecord(context)).assertEqual(recordText)
      } finally {
        await AiCredentialStore.clear(context)
      }
    })
  })
}
