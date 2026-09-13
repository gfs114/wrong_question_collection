import { AiImportLimits } from '../../constants/AiImportLimits'
import { AiImportError, AiImportErrorCode } from '../../models/ai/AiProviderConfig'
import {
  AiBoundingBox,
  AiOption,
  AiQuestionDraft,
  AiQuestionType
} from '../../models/ai/AiImportModels'

const MAX_NESTING_DEPTH: number = 64

class NullableText {
  value: string

  constructor(value: string) {
    this.value = value
  }
}

class ParsedBox {
  value: AiBoundingBox
  present: boolean

  constructor(value: AiBoundingBox, present: boolean) {
    this.value = value
    this.present = present
  }
}

class AiJsonReader {
  private text: string
  private index: number = 0

  constructor(text: string) {
    this.text = text
  }

  readQuestions(pageNumber: number): Array<AiQuestionDraft> {
    let questions: Array<AiQuestionDraft> = new Array<AiQuestionDraft>()
    let hasQuestions: boolean = false
    this.expect('{')
    if (this.nextIs('}')) {
      this.expect('}')
    } else {
      while (true) {
        const key: string = this.readString()
        this.expect(':')
        if (key !== 'questions' || hasQuestions) this.invalidJson()
        questions = this.readQuestionArray(pageNumber)
        hasQuestions = true
        if (this.nextIs('}')) {
          this.expect('}')
          break
        }
        this.expect(',')
        if (this.nextIs('}')) this.invalidJson()
      }
    }
    this.skipWhitespace()
    if (this.index !== this.text.length || !hasQuestions) this.invalidJson()
    if (questions.length === 0) throw new AiImportError(AiImportErrorCode.NO_QUESTIONS)
    return questions
  }

  private readQuestionArray(pageNumber: number): Array<AiQuestionDraft> {
    const values: Array<AiQuestionDraft> = new Array<AiQuestionDraft>()
    this.expect('[')
    if (this.nextIs(']')) {
      this.expect(']')
      return values
    }
    while (true) {
      if (values.length >= AiImportLimits.MAX_QUESTIONS_PER_PAGE) this.invalidJson()
      values.push(this.readQuestion(pageNumber))
      if (this.nextIs(']')) {
        this.expect(']')
        return values
      }
      this.expect(',')
    }
  }

  private readQuestion(pageNumber: number): AiQuestionDraft {
    let label: string = ''
    let typeText: string = ''
    let question: string = ''
    let options: Array<AiOption> = new Array<AiOption>()
    let answer: string = ''
    let analysis: string = ''
    let box: ParsedBox = new ParsedBox(new AiBoundingBox(0, 0, 1000, 1000), false)
    const seen: Array<string> = new Array<string>()
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      if (seen.indexOf(key) >= 0) this.invalidJson()
      seen.push(key)
      this.expect(':')
      if (key === 'label') label = this.readString()
      else if (key === 'type') typeText = this.readString()
      else if (key === 'question') question = this.readString()
      else if (key === 'options') options = this.readOptions()
      else if (key === 'answer') answer = this.readNullableString().value
      else if (key === 'analysis') analysis = this.readNullableString().value
      else if (key === 'bbox') box = this.readBox()
      else this.invalidJson()
      if (!this.nextIs('}')) {
        this.expect(',')
        if (this.nextIs('}')) this.invalidJson()
      }
    }
    this.expect('}')
    const required: Array<string> = ['label', 'type', 'question', 'options', 'answer', 'analysis']
    for (let index: number = 0; index < required.length; index++) {
      if (seen.indexOf(required[index]) < 0) this.invalidJson()
    }
    const type: AiQuestionType = AiQuestionValidation.type(typeText)
    AiQuestionValidation.label(label)
    AiQuestionValidation.text(question, AiImportLimits.MAX_QUESTION_LENGTH, false)
    AiQuestionValidation.text(answer, AiImportLimits.MAX_ANSWER_LENGTH, true)
    AiQuestionValidation.text(analysis, AiImportLimits.MAX_ANALYSIS_LENGTH, true)
    AiQuestionValidation.latex(question)
    AiQuestionValidation.latex(answer)
    AiQuestionValidation.latex(analysis)
    for (let index: number = 0; index < options.length; index++) {
      AiQuestionValidation.text(options[index].value, AiImportLimits.MAX_OPTION_LENGTH, false)
      AiQuestionValidation.latex(options[index].value)
      options[index].value = options[index].value.trim()
    }
    const bboxUsable: boolean = AiQuestionValidation.usableBox(box)
    const bbox: AiBoundingBox = bboxUsable ? box.value : new AiBoundingBox(0, 0, 1000, 1000)
    return new AiQuestionDraft(label.trim(), type, question.trim(), options, answer.trim(),
      analysis.trim(), bbox, bboxUsable, pageNumber)
  }

  private readOptions(): Array<AiOption> {
    if (this.nextLiteral('null')) {
      this.skipLiteral('null')
      return new Array<AiOption>()
    }
    const values: Array<AiOption> = new Array<AiOption>()
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString().trim().toUpperCase()
      if (!/^[A-J]$/.test(key) || values.length >= 10) this.invalidJson()
      for (let index: number = 0; index < values.length; index++) {
        if (values[index].key === key) this.invalidJson()
      }
      this.expect(':')
      values.push(new AiOption(key, this.readString()))
      if (!this.nextIs('}')) {
        this.expect(',')
        if (this.nextIs('}')) this.invalidJson()
      }
    }
    this.expect('}')
    values.sort((left: AiOption, right: AiOption): number => left.key.localeCompare(right.key))
    return values
  }

  private readNullableString(): NullableText {
    if (this.nextLiteral('null')) {
      this.skipLiteral('null')
      return new NullableText('')
    }
    return new NullableText(this.readString())
  }

  private readBox(): ParsedBox {
    let x1: number = 0
    let y1: number = 0
    let x2: number = 1000
    let y2: number = 1000
    const seen: Array<string> = new Array<string>()
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      if (seen.indexOf(key) >= 0) this.invalidJson()
      seen.push(key)
      this.expect(':')
      const value: number = this.readNumber()
      if (key === 'x1') x1 = value
      else if (key === 'y1') y1 = value
      else if (key === 'x2') x2 = value
      else if (key === 'y2') y2 = value
      else this.invalidJson()
      if (!this.nextIs('}')) {
        this.expect(',')
        if (this.nextIs('}')) this.invalidJson()
      }
    }
    this.expect('}')
    return new ParsedBox(new AiBoundingBox(x1, y1, x2, y2), seen.length === 4)
  }

  private readNumber(): number {
    this.skipWhitespace()
    const start: number = this.index
    this.skipNumber()
    const value: number = Number(this.text.substring(start, this.index))
    if (!Number.isFinite(value)) this.invalidJson()
    return value
  }

  private nextIs(character: string): boolean {
    this.skipWhitespace()
    return this.peek() === character
  }

  private nextLiteral(literal: string): boolean {
    this.skipWhitespace()
    return this.text.substring(this.index, this.index + literal.length) === literal
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
    if (this.peek() !== character) this.invalidJson()
    this.index++
  }

  private readString(): string {
    this.skipWhitespace()
    if (this.peek() !== '"') this.invalidJson()
    this.index++
    let value: string = ''
    while (this.index < this.text.length) {
      const character: string = this.text.charAt(this.index)
      this.index++
      if (character === '"') return value
      if (character.charCodeAt(0) < 32) this.invalidJson()
      if (character !== '\\') {
        value += character
        continue
      }
      if (this.index >= this.text.length) this.invalidJson()
      const escaped: string = this.text.charAt(this.index)
      this.index++
      if (escaped === '"') value += '"'
      else if (escaped === '\\') value += '\\'
      else if (escaped === '/') value += '/'
      else if (escaped === 'b') value += '\b'
      else if (escaped === 'f') value += '\f'
      else if (escaped === 'n') value += '\n'
      else if (escaped === 'r') value += '\r'
      else if (escaped === 't') value += '\t'
      else if (escaped === 'u') value += this.readUnicode()
      else this.invalidJson()
    }
    this.invalidJson()
    return ''
  }

  private readUnicode(): string {
    let code: number = 0
    for (let offset: number = 0; offset < 4; offset++) {
      if (this.index >= this.text.length) this.invalidJson()
      const digit: number = this.hexValue(this.text.charAt(this.index))
      if (digit < 0) this.invalidJson()
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
    else this.invalidJson()
  }

  private skipObject(depth: number): void {
    if (depth > MAX_NESTING_DEPTH) this.invalidJson()
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
    if (depth > MAX_NESTING_DEPTH) this.invalidJson()
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
      if (nextCharacter >= '0' && nextCharacter <= '9') this.invalidJson()
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
    if (firstDigit < '0' || firstDigit > '9') this.invalidJson()
    while (this.index < this.text.length) {
      const character: string = this.peek()
      if (character < '0' || character > '9') return
      this.index++
    }
  }

  private skipLiteral(literal: string): void {
    for (let offset: number = 0; offset < literal.length; offset++) {
      if (this.text.charAt(this.index + offset) !== literal.charAt(offset)) this.invalidJson()
    }
    this.index += literal.length
  }

  private invalidJson(): void {
    throw new AiImportError(AiImportErrorCode.INVALID_JSON)
  }
}

class AiQuestionValidation {
  static type(value: string): AiQuestionType {
    if (value === AiQuestionType.SINGLE_CHOICE) return AiQuestionType.SINGLE_CHOICE
    if (value === AiQuestionType.BLANK) return AiQuestionType.BLANK
    if (value === AiQuestionType.SHORT_ANSWER) return AiQuestionType.SHORT_ANSWER
    if (value === AiQuestionType.UNKNOWN) return AiQuestionType.UNKNOWN
    throw new AiImportError(AiImportErrorCode.INVALID_JSON)
  }

  static label(value: string): void {
    const normalized: string = value.trim()
    if (normalized.length < 1 || normalized.length > AiImportLimits.MAX_LABEL_LENGTH ||
      !/^(?:例\s*[0-9]+(?:\.[0-9]+)*|[0-9]+[.．、]?|第\s*[0-9]+\s*题|Q\s*[0-9]+)$/i.test(normalized)) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
  }

  static text(value: string, maximum: number, emptyAllowed: boolean): void {
    if ((!emptyAllowed && value.trim().length === 0) || value.length > maximum ||
      /<\s*\/?\s*(?:script|img|svg|iframe|object|embed|link|meta|style|form|input)\b[^>]*>/i.test(value) ||
      /javascript\s*:/i.test(value) ||
      /\bon[a-z]+\s*=/i.test(value)) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
    for (let index: number = 0; index < value.length; index++) {
      const code: number = value.charCodeAt(index)
      if (code < 32 && code !== 9 && code !== 10 && code !== 13) {
        throw new AiImportError(AiImportErrorCode.INVALID_JSON)
      }
    }
  }

  static usableBox(box: ParsedBox): boolean {
    const value: AiBoundingBox = box.value
    return box.present && Number.isFinite(value.x1) && Number.isFinite(value.y1) &&
      Number.isFinite(value.x2) && Number.isFinite(value.y2) &&
      value.x1 >= 0 && value.y1 >= 0 && value.x2 <= 1000 && value.y2 <= 1000 &&
      value.x2 - value.x1 >= AiImportLimits.MIN_BBOX_EDGE &&
      value.y2 - value.y1 >= AiImportLimits.MIN_BBOX_EDGE
  }

  static latex(value: string): void {
    if (value.indexOf('∫2−x') >= 0 || !AiQuestionValidation.balancedDollars(value) ||
      !AiQuestionValidation.balancedBraces(value) || !AiQuestionValidation.balancedEnvironments(value) ||
      !AiQuestionValidation.validCases(value)) {
      throw new AiImportError(AiImportErrorCode.LATEX_INVALID)
    }
  }

  private static balancedDollars(value: string): boolean {
    let delimiterWidth: number = 0
    for (let index: number = 0; index < value.length; index++) {
      if (value.charAt(index) === '\\') {
        index++
      } else if (value.charAt(index) === '$') {
        const width: number = value.charAt(index + 1) === '$' ? 2 : 1
        if (delimiterWidth === 0) delimiterWidth = width
        else if (delimiterWidth === width) delimiterWidth = 0
        else return false
        if (width === 2) index++
      }
    }
    return delimiterWidth === 0
  }

  private static balancedBraces(value: string): boolean {
    let depth: number = 0
    for (let index: number = 0; index < value.length; index++) {
      const character: string = value.charAt(index)
      if (character === '\\') index++
      else if (character === '{') depth++
      else if (character === '}') {
        depth--
        if (depth < 0) return false
      }
    }
    return depth === 0
  }

  private static balancedEnvironments(value: string): boolean {
    const token: RegExp = /\\(begin|end)\s*\{([A-Za-z*]+)\}/g
    const stack: Array<string> = new Array<string>()
    let match: RegExpExecArray | null = token.exec(value)
    while (match !== null) {
      if (match[1] === 'begin') stack.push(match[2])
      else if (stack.length === 0 || stack.pop() !== match[2]) return false
      match = token.exec(value)
    }
    return stack.length === 0
  }

  private static validCases(value: string): boolean {
    const normalized: string = value.replace(/\\begin\s*\{cases\}/g, '\\begin{cases}')
      .replace(/\\end\s*\{cases\}/g, '\\end{cases}')
    const begin: string = '\\begin{cases}'
    const end: string = '\\end{cases}'
    let offset: number = 0
    while (normalized.indexOf(begin, offset) >= 0) {
      const start: number = normalized.indexOf(begin, offset) + begin.length
      const finish: number = normalized.indexOf(end, start)
      if (finish < 0) return false
      const rows: Array<string> = normalized.substring(start, finish).split('\\\\')
      let nonEmpty: number = 0
      for (let index: number = 0; index < rows.length; index++) {
        if (rows[index].trim().length > 0) {
          nonEmpty++
          if (rows[index].indexOf('&') < 0) return false
        }
      }
      if (nonEmpty === 0) return false
      offset = finish + end.length
    }
    return normalized.indexOf(end, offset) < 0
  }
}

export class AiQuestionResponseParser {
  static parse(response: string, pageNumber: number): Array<AiQuestionDraft> {
    const text: string = AiQuestionResponseParser.unwrapFence(response)
    return new AiJsonReader(text).readQuestions(pageNumber)
  }

  private static unwrapFence(response: string): string {
    const trimmed: string = response.trim()
    if (!trimmed.startsWith('```')) return trimmed
    const match: RegExpMatchArray | null = trimmed.match(/^```(?:json)?[ \t]*\r?\n([\s\S]*)\r?\n```$/i)
    if (match === null) throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    return match[1].trim()
  }
}
