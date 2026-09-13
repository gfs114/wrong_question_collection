import { huks } from '@kit.UniversalKeystoreKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'

const KEY_ALIAS: string = 'wrongquestion.ai.credentials.aes.v1'
const NONCE_LENGTH: number = 12
const TAG_LENGTH: number = 16
const AAD_TEXT: string = 'wrongquestion.ai.credentials.v1'

export class HuksCipherText {
  nonce: Uint8Array
  ciphertext: Uint8Array
  tag: Uint8Array

  constructor(nonce: Uint8Array, ciphertext: Uint8Array, tag: Uint8Array) {
    this.nonce = nonce
    this.ciphertext = ciphertext
    this.tag = tag
  }
}

export class HuksAesGcmCipher {
  private static keyCreation: Promise<void> | null = null

  static async encrypt(plainText: Uint8Array): Promise<HuksCipherText> {
    await HuksAesGcmCipher.ensureKey()
    const random: cryptoFramework.Random = cryptoFramework.createRandom()
    const blob: cryptoFramework.DataBlob = await random.generateRandom(NONCE_LENGTH)
    const nonce: Uint8Array = blob.data
    const options: huks.HuksOptions = {
      properties: HuksAesGcmCipher.operationProperties(
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce, null),
      inData: plainText
    }
    const output: Uint8Array = await HuksAesGcmCipher.finish(options)
    try {
      if (output.length <= TAG_LENGTH) {
        throw new Error('AI credential encryption failed')
      }
      return new HuksCipherText(nonce.slice(), output.slice(0, output.length - TAG_LENGTH),
        output.slice(output.length - TAG_LENGTH))
    } finally {
      output.fill(0)
    }
  }

  static async decrypt(value: HuksCipherText): Promise<Uint8Array> {
    if (value.nonce.length !== NONCE_LENGTH || value.tag.length !== TAG_LENGTH ||
      value.ciphertext.length === 0) {
      throw new Error('AI credential envelope is invalid')
    }
    await HuksAesGcmCipher.ensureKey()
    const options: huks.HuksOptions = {
      properties: HuksAesGcmCipher.operationProperties(
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, value.nonce, value.tag),
      inData: value.ciphertext
    }
    return HuksAesGcmCipher.finish(options)
  }

  static async hasKey(): Promise<boolean> {
    return huks.hasKeyItem(KEY_ALIAS, { properties: [] })
  }

  /**
   * Test-facing key removal. Production callers must coordinate deletion through AiCredentialStore.clear().
   */
  static async deleteKey(): Promise<void> {
    if (await HuksAesGcmCipher.hasKey()) {
      await huks.deleteKeyItem(KEY_ALIAS, { properties: [] })
    }
  }

  private static async ensureKey(): Promise<void> {
    if (await HuksAesGcmCipher.hasKey()) return
    if (HuksAesGcmCipher.keyCreation === null) {
      HuksAesGcmCipher.keyCreation = HuksAesGcmCipher.generateKey()
    }
    const pending: Promise<void> | null = HuksAesGcmCipher.keyCreation
    if (pending === null) throw new Error('AI credential key creation failed')
    try {
      await pending
    } finally {
      if (HuksAesGcmCipher.keyCreation === pending) {
        HuksAesGcmCipher.keyCreation = null
      }
    }
  }

  private static async generateKey(): Promise<void> {
    if (await HuksAesGcmCipher.hasKey()) return
    const options: huks.HuksOptions = {
      properties: [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
        {
          tag: huks.HuksTag.HUKS_TAG_PURPOSE,
          value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT |
            huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
        }
      ]
    }
    await huks.generateKeyItem(KEY_ALIAS, options)
  }

  private static operationProperties(purpose: number, nonce: Uint8Array,
    tag: Uint8Array | null): Array<huks.HuksParam> {
    const encoder: util.TextEncoder = new util.TextEncoder('utf-8')
    const properties: Array<huks.HuksParam> = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
      { tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: encoder.encodeInto(AAD_TEXT) }
    ]
    if (tag !== null) {
      properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag })
    }
    return properties
  }

  private static async finish(options: huks.HuksOptions): Promise<Uint8Array> {
    let handle: number = -1
    let finished: boolean = false
    try {
      const session: huks.HuksSessionHandle = await huks.initSession(KEY_ALIAS, options)
      handle = session.handle
      const result: huks.HuksReturnResult = await huks.finishSession(handle, options)
      finished = true
      if (result.outData === undefined) {
        throw new Error('AI credential operation failed')
      }
      return result.outData
    } finally {
      if (handle >= 0 && !finished) {
        try {
          await huks.abortSession(handle, { properties: [] })
        } catch {
        }
      }
    }
  }
}
