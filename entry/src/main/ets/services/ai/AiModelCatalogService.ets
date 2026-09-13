import { util } from '@kit.ArkTS'
import { Context } from '@kit.AbilityKit'
import {
  AiImportError, AiImportErrorCode, AiProviderConfigValidator
} from '../../models/ai/AiProviderConfig'
import { AiCredentialStore } from './AiCredentialStore'
import { AiVisionTransport } from './AiVisionTransport'

const MAX_MODEL_LIST_DEPTH: number = 32
const MAX_REMOTE_MODELS: number = 500
const MAX_MODEL_ID_LENGTH: number = 200

export interface AiModelCatalogTransportPort {
  getJson(endpoint: string, credential: Uint8Array, requestKey: string): Promise<string>
}

class AiModelListReader {
  private text: string
  private index: number = 0

  constructor(text: string) {
    this.text = text
  }

  readModels(): Array<string> {
    let dataSeen: boolean = false
    let models: Array<string> = new Array<string>()
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      this.expect(':')
      if (key === 'data') {
        if (dataSeen) this.invalid()
        dataSeen = true
        models = this.readData()
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
    if (!dataSeen || this.index !== this.text.length) this.invalid()
    models.sort()
    return models
  }

  private readData(): Array<string> {
    const models: Array<string> = new Array<string>()
    const seen: Set<string> = new Set<string>()
    this.expect('[')
    while (!this.nextIs(']')) {
      const id: string = this.readModel()
      if (!seen.has(id)) {
        if (models.length >= MAX_REMOTE_MODELS) this.invalid()
        seen.add(id)
        models.push(id)
      }
      if (!this.nextIs(']')) {
        this.expect(',')
        if (this.nextIs(']')) this.invalid()
      }
    }
    this.expect(']')
    return models
  }

  private readModel(): string {
    let id: string = ''
    let idSeen: boolean = false
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      this.expect(':')
      if (key === 'id') {
        if (idSeen) this.invalid()
        idSeen = true
        id = this.readString()
      } else {
        this.skipValue(0)
      }
      if (!this.nextIs('}')) {
        this.expect(',')
        if (this.nextIs('}')) this.invalid()
      }
    }
    this.expect('}')
    if (!idSeen || !AiModelListReader.isSafeModelId(id)) this.invalid()
    return id
  }

  private static isSafeModelId(value: string): boolean {
    if (value.length === 0 || value.length > MAX_MODEL_ID_LENGTH) return false
    for (let index: number = 0; index < value.length; index++) {
      const code: number = value.charCodeAt(index)
      const alphaNumeric: boolean = (code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
      if (alphaNumeric) continue
      const character: string = value.charAt(index)
      if (character !== '-' && character !== '_' && character !== '.' && character !== '/' &&
        character !== ':' && character !== '@') return false
    }
    return true
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
      if (character !== ' ' && character !== '\t' && character !== '\n' && character !== '\r') return
      this.index++
    }
  }

  private peek(): string {
    if (this.index >= this.text.length) return ''
    return this.text.charAt(this.index)
  }

  private expect(character: string): void {
    this.skipWhitespace()
    if (this.peek() !== character) this.invalid()
    this.index++
  }

  private readString(): string {
    this.skipWhitespace()
    if (this.peek() !== '"') this.invalid()
    this.index++
    let value: string = ''
    while (this.index < this.text.length) {
      const character: string = this.text.charAt(this.index)
      this.index++
      if (character === '"') return value
      if (character.charCodeAt(0) < 32) this.invalid()
      if (character !== '\\') {
        value += character
        continue
      }
      if (this.index >= this.text.length) this.invalid()
      const escaped: string = this.text.charAt(this.index)
      this.index++
      switch (escaped) {
        case '"': value += '"'; break
        case '\\': value += '\\'; break
        case '/': value += '/'; break
        case 'b': value += '\b'; break
        case 'f': value += '\f'; break
        case 'n': value += '\n'; break
        case 'r': value += '\r'; break
        case 't': value += '\t'; break
        case 'u': value += this.readUnicode(); break
        default: this.invalid()
      }
    }
    this.invalid()
  }

  private readUnicode(): string {
    let code: number = 0
    for (let offset: number = 0; offset < 4; offset++) {
      if (this.index >= this.text.length) this.invalid()
      const digit: number = this.hexValue(this.text.charAt(this.index))
      if (digit < 0) this.invalid()
      code = code * 16 + digit
      this.index++
    }
    return String.fromCharCode(code)
  }

  private hexValue(character: string): number {
    const code: number = character.charCodeAt(0)
    if (code >= 48 && code <= 57) return code - 48
    if (code >= 65 && code <= 70) return code - 55
    if (code >= 97 && code <= 102) return code - 87
    return -1
  }

  private skipValue(depth: number): void {
    this.skipWhitespace()
    const character: string = this.peek()
    if (character === '"') this.readString()
    else if (character === '{') this.skipObject(depth + 1)
    else if (character === '[') this.skipArray(depth + 1)
    else if (character === '-' || (character >= '0' && character <= '9')) this.skipNumber()
    else if (character === 't') this.skipLiteral('true')
    else if (character === 'f') this.skipLiteral('false')
    else if (character === 'n') this.skipLiteral('null')
    else this.invalid()
  }

  private skipObject(depth: number): void {
    if (depth > MAX_MODEL_LIST_DEPTH) this.invalid()
    this.expect('{')
    if (this.nextIs('}')) {
      this.expect('}')
      return
    }
    while (true) {
      this.readString()
      this.expect(':')
      this.skipValue(depth)
      if (this.nextIs('}')) {
        this.expect('}')
        return
      }
      this.expect(',')
    }
  }

  private skipArray(depth: number): void {
    if (depth > MAX_MODEL_LIST_DEPTH) this.invalid()
    this.expect('[')
    if (this.nextIs(']')) {
      this.expect(']')
      return
    }
    while (true) {
      this.skipValue(depth)
      if (this.nextIs(']')) {
        this.expect(']')
        return
      }
      this.expect(',')
    }
  }

  private skipNumber(): void {
    if (this.peek() === '-') this.index++
    const firstDigit: string = this.peek()
    if (firstDigit === '0') {
      this.index++
      const nextCharacter: string = this.peek()
      if (nextCharacter >= '0' && nextCharacter <= '9') this.invalid()
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
      if (sign === '+' || sign === '-') this.index++
      this.skipDigits()
    }
  }

  private skipDigits(): void {
    const firstDigit: string = this.peek()
    if (firstDigit < '0' || firstDigit > '9') this.invalid()
    while (this.index < this.text.length) {
      const character: string = this.peek()
      if (character < '0' || character > '9') return
      this.index++
    }
  }

  private skipLiteral(literal: string): void {
    for (let offset: number = 0; offset < literal.length; offset++) {
      if (this.text.charAt(this.index + offset) !== literal.charAt(offset)) this.invalid()
    }
    this.index += literal.length
  }
}

export class AiModelListParser {
  static parse(raw: string): Array<string> {
    return new AiModelListReader(raw).readModels()
  }
}

export class AiModelCatalogService {
  private transport: AiModelCatalogTransportPort

  constructor(transport: AiModelCatalogTransportPort = new AiVisionTransport()) {
    this.transport = transport
  }

  async fetchWithApiKey(baseUrl: string, apiKey: string): Promise<Array<string>> {
    let keyText: string = apiKey.trim()
    if (keyText.length === 0) throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
    const credential: Uint8Array = new util.TextEncoder('utf-8').encodeInto(keyText)
    try {
      return await this.fetchWithCredential(baseUrl, credential)
    } finally {
      credential.fill(0)
      keyText = ''
    }
  }

  async fetchWithSavedCredential(context: Context, baseUrl: string): Promise<Array<string>> {
    return AiCredentialStore.withCredential<Array<string>>(context,
      async (credential: Uint8Array): Promise<Array<string>> => this.fetchWithCredential(baseUrl, credential))
  }

  async fetchWithCredential(baseUrl: string, credential: Uint8Array): Promise<Array<string>> {
    const normalizedBaseUrl: string = AiProviderConfigValidator.normalizeBaseUrl(baseUrl)
    const endpoint: string = normalizedBaseUrl + '/models'
    const requestKey: string = 'ai-model-list-' + util.generateRandomUUID()
    let raw: string = ''
    try {
      raw = await this.transport.getJson(endpoint, credential, requestKey)
      return AiModelListParser.parse(raw)
    } catch (err) {
      if (err instanceof AiImportError) throw err
      throw new AiImportError(AiImportErrorCode.NETWORK_UNAVAILABLE)
    } finally {
      raw = ''
    }
  }
}
