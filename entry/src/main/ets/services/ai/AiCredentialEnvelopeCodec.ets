import { util } from '@kit.ArkTS'
import { HuksCipherText } from './HuksAesGcmCipher'

export class AiCredentialRecord {
  digest: string
  envelope: string

  constructor(digest: string, envelope: string) {
    this.digest = digest
    this.envelope = envelope
  }
}

export class AiCredentialRecordCodec {
  static encode(value: AiCredentialRecord): string {
    return '1~' + value.digest + '~' + value.envelope
  }

  static decode(value: string): AiCredentialRecord {
    const parts: Array<string> = value.split('~')
    if (parts.length !== 3 || parts[0] !== '1' || parts[1].length === 0 || parts[2].length === 0) {
      throw new Error('AI credential record is invalid')
    }
    const base64: util.Base64Helper = new util.Base64Helper()
    let digestBytes: Uint8Array | null = null
    try {
      digestBytes = base64.decodeSync(parts[1], util.Type.BASIC)
      if (digestBytes.length !== 32 ||
        base64.encodeToStringSync(digestBytes, util.Type.BASIC) !== parts[1]) {
        throw new Error('AI credential record is invalid')
      }
    } finally {
      if (digestBytes !== null) digestBytes.fill(0)
    }
    return new AiCredentialRecord(parts[1], parts[2])
  }
}

export class AiCredentialEnvelopeCodec {
  static encode(value: HuksCipherText): string {
    const base64: util.Base64Helper = new util.Base64Helper()
    return '1.' + base64.encodeToStringSync(value.nonce, util.Type.BASIC) + '.' +
      base64.encodeToStringSync(value.ciphertext, util.Type.BASIC) + '.' +
      base64.encodeToStringSync(value.tag, util.Type.BASIC)
  }

  static decode(value: string): HuksCipherText {
    const parts: Array<string> = value.split('.')
    if (parts.length !== 4 || parts[0] !== '1') {
      throw new Error('AI credential envelope is invalid')
    }
    const base64: util.Base64Helper = new util.Base64Helper()
    const nonce: Uint8Array = base64.decodeSync(parts[1], util.Type.BASIC)
    const ciphertext: Uint8Array = base64.decodeSync(parts[2], util.Type.BASIC)
    const tag: Uint8Array = base64.decodeSync(parts[3], util.Type.BASIC)
    if (nonce.length !== 12 || ciphertext.length === 0 || tag.length !== 16 ||
      base64.encodeToStringSync(nonce, util.Type.BASIC) !== parts[1] ||
      base64.encodeToStringSync(ciphertext, util.Type.BASIC) !== parts[2] ||
      base64.encodeToStringSync(tag, util.Type.BASIC) !== parts[3]) {
      throw new Error('AI credential envelope is invalid')
    }
    return new HuksCipherText(nonce, ciphertext, tag)
  }
}
