import { util } from '@kit.ArkTS'
import { AiImportLimits } from '../../constants/AiImportLimits'
import { AiImportError, AiImportErrorCode, AiProviderConfig } from '../../models/ai/AiProviderConfig'
import { AiProviderAdapter, AiProviderRequest } from './AiProviderAdapter'

const MAX_NESTING_DEPTH: number = 64

class OpenAiResponseReader {
  private text: string
  private index: number = 0

  constructor(text: string) {
    this.text = text
  }

  readFirstContent(): string {
    let content: string = ''
    let choicesSeen: boolean = false
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      this.expect(':')
      if (key === 'choices') {
        if (choicesSeen) this.invalid()
        choicesSeen = true
        content = this.readChoices()
      } else {
        this.skipValue(0)
      }
      if (!this.nextIs('}')) {
        this.expect(',')
        if (this.nextIs('}')) this.invalid()
      }
    }
    this.expect('}')
    this.skipWhitespace()
    if (!choicesSeen || content.trim().length === 0 || this.index !== this.text.length) this.invalid()
    return content
  }

  private readChoices(): string {
    let content: string = ''
    let index: number = 0
    this.expect('[')
    while (!this.nextIs(']')) {
      if (index === 0) content = this.readChoice()
      else this.skipValue(0)
      index++
      if (!this.nextIs(']')) {
        this.expect(',')
        if (this.nextIs(']')) this.invalid()
      }
    }
    this.expect(']')
    if (index === 0) this.invalid()
    return content
  }

  private readChoice(): string {
    let content: string = ''
    let messageSeen: boolean = false
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      this.expect(':')
      if (key === 'message') {
        if (messageSeen) this.invalid()
        messageSeen = true
        content = this.readMessage()
      } else {
        this.skipValue(0)
      }
      if (!this.nextIs('}')) {
        this.expect(',')
        if (this.nextIs('}')) this.invalid()
      }
    }
    this.expect('}')
    if (!messageSeen) this.invalid()
    return content
  }

  private readMessage(): string {
    let content: string = ''
    let contentSeen: boolean = false
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      this.expect(':')
      if (key === 'content') {
        if (contentSeen) this.invalid()
        contentSeen = true
        content = this.readString()
      } else {
        this.skipValue(0)
      }
      if (!this.nextIs('}')) {
        this.expect(',')
        if (this.nextIs('}')) this.invalid()
      }
    }
    this.expect('}')
    if (!contentSeen || content.trim().length === 0) this.invalid()
    return content
  }

  private nextIs(character: string): boolean {
    this.skipWhitespace()
    return this.peek() === character
  }

  private invalid(): never {
    throw new AiImportError(AiImportErrorCode.INVALID_JSON)
  }

  private skipWhitespace(): void {
    while (this.index < this.text.length) {
      const character: string = this.text.charAt(this.index)
      if (character !== ' ' && character !== '\t' && character !== '\n' && character !== '\r') {
        return
      }
      this.index++
    }
  }

  private peek(): string {
    if (this.index >= this.text.length) {
      return ''
    }
    return this.text.charAt(this.index)
  }

  private expect(character: string): void {
    this.skipWhitespace()
    if (this.peek() !== character) {
      this.invalid()
    }
    this.index++
  }

  private readString(): string {
    this.skipWhitespace()
    if (this.peek() !== '"') {
      this.invalid()
    }
    this.index++
    let value: string = ''
    while (this.index < this.text.length) {
      const character: string = this.text.charAt(this.index)
      this.index++
      if (character === '"') {
        return value
      }
      if (character.charCodeAt(0) < 32) {
        this.invalid()
      }
      if (character !== '\\') {
        value += character
        continue
      }
      if (this.index >= this.text.length) {
        this.invalid()
      }
      const escaped: string = this.text.charAt(this.index)
      this.index++
      switch (escaped) {
        case '"':
          value += '"'
          break
        case '\\':
          value += '\\'
          break
        case '/':
          value += '/'
          break
        case 'b':
          value += '\b'
          break
        case 'f':
          value += '\f'
          break
        case 'n':
          value += '\n'
          break
        case 'r':
          value += '\r'
          break
        case 't':
          value += '\t'
          break
        case 'u':
          value += this.readUnicode()
          break
        default:
          this.invalid()
      }
    }
    this.invalid()
  }

  private readUnicode(): string {
    let code: number = 0
    for (let offset: number = 0; offset < 4; offset++) {
      if (this.index >= this.text.length) {
        this.invalid()
      }
      const digit: number = this.hexValue(this.text.charAt(this.index))
      if (digit < 0) {
        this.invalid()
      }
      code = code * 16 + digit
      this.index++
    }
    return String.fromCharCode(code)
  }

  private hexValue(character: string): number {
    const code: number = character.charCodeAt(0)
    if (code >= 48 && code <= 57) {
      return code - 48
    }
    if (code >= 65 && code <= 70) {
      return code - 55
    }
    if (code >= 97 && code <= 102) {
      return code - 87
    }
    return -1
  }

  private skipValue(depth: number): void {
    this.skipWhitespace()
    const character: string = this.peek()
    if (character === '"') {
      this.readString()
    } else if (character === '{') {
      this.skipObject(depth + 1)
    } else if (character === '[') {
      this.skipArray(depth + 1)
    } else if (character === '-' || (character >= '0' && character <= '9')) {
      this.skipNumber()
    } else if (character === 't') {
      this.skipLiteral('true')
    } else if (character === 'f') {
      this.skipLiteral('false')
    } else if (character === 'n') {
      this.skipLiteral('null')
    } else {
      this.invalid()
    }
  }

  private skipObject(depth: number): void {
    if (depth > MAX_NESTING_DEPTH) {
      this.invalid()
    }
    this.expect('{')
    this.skipWhitespace()
    if (this.peek() === '}') {
      this.index++
      return
    }
    while (true) {
      this.readString()
      this.expect(':')
      this.skipValue(depth)
      this.skipWhitespace()
      const separator: string = this.peek()
      if (separator === '}') {
        this.index++
        return
      }
      this.expect(',')
    }
  }

  private skipArray(depth: number): void {
    if (depth > MAX_NESTING_DEPTH) {
      this.invalid()
    }
    this.expect('[')
    this.skipWhitespace()
    if (this.peek() === ']') {
      this.index++
      return
    }
    while (true) {
      this.skipValue(depth)
      this.skipWhitespace()
      const separator: string = this.peek()
      if (separator === ']') {
        this.index++
        return
      }
      this.expect(',')
    }
  }

  private skipNumber(): void {
    if (this.peek() === '-') {
      this.index++
    }
    const firstDigit: string = this.peek()
    if (firstDigit === '0') {
      this.index++
      const nextCharacter: string = this.peek()
      if (nextCharacter >= '0' && nextCharacter <= '9') {
        this.invalid()
      }
    } else {
      this.skipDigits()
    }
    if (this.peek() === '.') {
      this.index++
      this.skipDigits()
    }
    const exponent: string = this.peek()
    if (exponent === 'e' || exponent === 'E') {
      this.index++
      const sign: string = this.peek()
      if (sign === '+' || sign === '-') {
        this.index++
      }
      this.skipDigits()
    }
  }

  private skipDigits(): void {
    const firstDigit: string = this.peek()
    if (firstDigit < '0' || firstDigit > '9') {
      this.invalid()
    }
    while (this.index < this.text.length) {
      const character: string = this.peek()
      if (character < '0' || character > '9') {
        return
      }
      this.index++
    }
  }

  private skipLiteral(literal: string): void {
    for (let offset: number = 0; offset < literal.length; offset++) {
      if (this.text.charAt(this.index + offset) !== literal.charAt(offset)) {
        this.invalid()
      }
    }
    this.index += literal.length
  }
}

export class OpenAiCompatibleAdapter implements AiProviderAdapter {
  buildRequest(config: AiProviderConfig, prompt: string, jpegBase64: string): AiProviderRequest {
    const endpoint: string = config.baseUrl + '/chat/completions'
    const responseFormat: string = config.supportsStructuredOutput ?
      ',"response_format":{"type":"json_object"}' : ''
    const body: string = '{"model":' + JSON.stringify(config.model) + ',"stream":false,' +
      '"messages":[' +
      '{"role":"system","content":' + JSON.stringify(prompt) + '},' +
      '{"role":"user","content":[' +
      '{"type":"text","text":"识别这一页数学题并按 system schema 返回。"},' +
      '{"type":"image_url","image_url":{"url":' +
      JSON.stringify('data:image/jpeg;base64,' + jpegBase64) + '}}]}]' + responseFormat + '}'
    const bytes: Uint8Array = new util.TextEncoder('utf-8').encodeInto(body)
    try {
      if (bytes.length > AiImportLimits.MAX_REQUEST_BYTES) {
        throw new AiImportError(AiImportErrorCode.RESPONSE_TOO_LARGE)
      }
      return new AiProviderRequest(endpoint, body)
    } finally {
      bytes.fill(0)
    }
  }

  extractAssistantContent(response: string): string {
    const content: string = new OpenAiResponseReader(response).readFirstContent()
    if (content.trim().length === 0) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
    return content
  }
}
