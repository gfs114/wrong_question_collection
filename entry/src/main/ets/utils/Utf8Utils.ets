import { util } from '@kit.ArkTS'

export class Utf8Utils {
  static validate(content: Uint8Array): void {
    let index: number = 0
    while (index < content.length) {
      const first: number = content[index]
      if (first <= 0x7F) {
        index += 1
      } else if (first >= 0xC2 && first <= 0xDF) {
        Utf8Utils.requireByte(content, index + 1, 0x80, 0xBF)
        index += 2
      } else if (first === 0xE0) {
        Utf8Utils.requireByte(content, index + 1, 0xA0, 0xBF)
        Utf8Utils.requireByte(content, index + 2, 0x80, 0xBF)
        index += 3
      } else if ((first >= 0xE1 && first <= 0xEC) || (first >= 0xEE && first <= 0xEF)) {
        Utf8Utils.requireByte(content, index + 1, 0x80, 0xBF)
        Utf8Utils.requireByte(content, index + 2, 0x80, 0xBF)
        index += 3
      } else if (first === 0xED) {
        Utf8Utils.requireByte(content, index + 1, 0x80, 0x9F)
        Utf8Utils.requireByte(content, index + 2, 0x80, 0xBF)
        index += 3
      } else if (first === 0xF0) {
        Utf8Utils.requireByte(content, index + 1, 0x90, 0xBF)
        Utf8Utils.requireByte(content, index + 2, 0x80, 0xBF)
        Utf8Utils.requireByte(content, index + 3, 0x80, 0xBF)
        index += 4
      } else if (first >= 0xF1 && first <= 0xF3) {
        Utf8Utils.requireByte(content, index + 1, 0x80, 0xBF)
        Utf8Utils.requireByte(content, index + 2, 0x80, 0xBF)
        Utf8Utils.requireByte(content, index + 3, 0x80, 0xBF)
        index += 4
      } else if (first === 0xF4) {
        Utf8Utils.requireByte(content, index + 1, 0x80, 0x8F)
        Utf8Utils.requireByte(content, index + 2, 0x80, 0xBF)
        Utf8Utils.requireByte(content, index + 3, 0x80, 0xBF)
        index += 4
      } else {
        throw new TypeError('Invalid UTF-8 data')
      }
    }
  }

  static decode(content: Uint8Array): string {
    Utf8Utils.validate(content)
    const options: util.TextDecoderOptions = {
      fatal: true
    }
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', options)
    return decoder.decodeToString(content)
  }

  private static requireByte(content: Uint8Array, index: number, minimum: number, maximum: number): void {
    if (index >= content.length) {
      throw new TypeError('Invalid UTF-8 data')
    }
    const value: number = content[index]
    if (value < minimum || value > maximum) {
      throw new TypeError('Invalid UTF-8 data')
    }
  }
}
