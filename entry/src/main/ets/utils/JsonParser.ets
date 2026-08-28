import { Question } from '../models/Question'
import { QuestionBank } from '../models/QuestionBank'
import { ImportLimits } from '../constants/ImportLimits'

// 未知字段最多嵌套 64 层。
const MAX_NESTING_DEPTH: number = 64

class JsonReader {
  private text: string
  private index: number = 0

  constructor(text: string) {
    this.text = text
  }

  readBank(): QuestionBank {
    let bankName: string = ''
    let subject: string = ''
    let questions: Array<Question> = new Array<Question>()
    this.expect('{')
    this.skipWhitespace()
    if (this.peek() === '}') {
      this.index++
    } else {
      while (true) {
        const key: string = this.readString()
        this.expect(':')
        switch (key) {
          case 'bankName':
            bankName = this.readString()
            if (bankName.length > ImportLimits.MAX_BANK_NAME_LENGTH) {
              throw new Error('题库名称过长')
            }
            break
          case 'subject':
            subject = this.readString()
            if (subject.length > ImportLimits.MAX_SUBJECT_LENGTH) {
              throw new Error('科目名称过长')
            }
            break
          case 'questions':
            questions = this.readQuestionArray()
            break
          default:
            this.skipValue(0)
            break
        }
        this.skipWhitespace()
        const separator: string = this.peek()
        if (separator === '}') {
          this.index++
          break
        }
        this.expect(',')
      }
    }

    if (bankName.trim().length === 0 || subject.trim().length === 0 || questions.length === 0) {
      throw new Error('题库字段不能为空')
    }
    const sourceIds: Set<string> = new Set<string>()
    for (const question of questions) {
      if (sourceIds.has(question.id)) {
        throw new Error('题目编号不能重复')
      }
      sourceIds.add(question.id)
    }
    return new QuestionBank('', bankName, subject, questions.length, 0, false, questions)
  }

  ensureFinished(): void {
    this.skipWhitespace()
    if (this.index !== this.text.length) {
      throw new Error('JSON 包含多余内容')
    }
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
      throw new Error('JSON 符号不正确')
    }
    this.index++
  }

  private readString(): string {
    this.skipWhitespace()
    if (this.peek() !== '"') {
      throw new Error('JSON 字符串不正确')
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
        throw new Error('JSON 字符串包含控制字符')
      }
      if (character !== '\\') {
        value += character
        continue
      }
      if (this.index >= this.text.length) {
        throw new Error('JSON 转义不完整')
      }
      const escaped: string = this.text.charAt(this.index)
      this.index++
      // 转义逐字符解码。
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
          throw new Error('JSON 转义不正确')
      }
    }
    throw new Error('JSON 字符串未闭合')
  }

  private readUnicode(): string {
    let code: number = 0
    for (let offset: number = 0; offset < 4; offset++) {
      if (this.index >= this.text.length) {
        throw new Error('Unicode 转义不完整')
      }
      const digit: number = this.hexValue(this.text.charAt(this.index))
      if (digit < 0) {
        throw new Error('Unicode 转义不正确')
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

  private readStringArray(): Array<string> {
    const values: Array<string> = new Array<string>()
    this.expect('[')
    this.skipWhitespace()
    if (this.peek() === ']') {
      this.index++
      return values
    }
    while (true) {
      if (values.length >= ImportLimits.MAX_OPTION_COUNT) {
        throw new Error('选项数量过多')
      }
      const value: string = this.readString()
      if (value.length > ImportLimits.MAX_OPTION_LENGTH) {
        throw new Error('选项内容过长')
      }
      values.push(value)
      this.skipWhitespace()
      const separator: string = this.peek()
      if (separator === ']') {
        this.index++
        return values
      }
      this.expect(',')
    }
  }

  private readQuestionArray(): Array<Question> {
    const questions: Array<Question> = new Array<Question>()
    this.expect('[')
    this.skipWhitespace()
    if (this.peek() === ']') {
      this.index++
      return questions
    }
    while (true) {
      if (questions.length >= ImportLimits.MAX_QUESTION_COUNT) {
        throw new Error('题目数量过多')
      }
      questions.push(this.readQuestion())
      this.skipWhitespace()
      const separator: string = this.peek()
      if (separator === ']') {
        this.index++
        return questions
      }
      this.expect(',')
    }
  }

  private readQuestion(): Question {
    let id: string = ''
    let type: string = ''
    let question: string = ''
    let options: Array<string> = new Array<string>()
    let answer: string = ''
    let analysis: string = ''
    let hasAnalysis: boolean = false
    this.expect('{')
    this.skipWhitespace()
    if (this.peek() === '}') {
      this.index++
    } else {
      while (true) {
        const key: string = this.readString()
        this.expect(':')
        switch (key) {
          case 'id':
            id = this.readString()
            break
          case 'type':
            type = this.readString()
            break
          case 'question':
            question = this.readString()
            if (question.length > ImportLimits.MAX_QUESTION_LENGTH) {
              throw new Error('题干内容过长')
            }
            break
          case 'options':
            options = this.readStringArray()
            break
          case 'answer':
            answer = this.readString()
            break
          case 'analysis':
            analysis = this.readString()
            if (analysis.length > ImportLimits.MAX_ANALYSIS_LENGTH) {
              throw new Error('解析内容过长')
            }
            hasAnalysis = true
            break
          default:
            this.skipValue(0)
            break
        }
        this.skipWhitespace()
        const separator: string = this.peek()
        if (separator === '}') {
          this.index++
          break
        }
        this.expect(',')
      }
    }

    const normalizedAnswer: string = answer.trim().toUpperCase()
    if (id.trim().length === 0 || type !== 'single_choice' || question.trim().length === 0 ||
      normalizedAnswer.length !== 1 || !hasAnalysis || options.length < 2) {
      throw new Error('题目字段不正确')
    }
    const answerCode: number = normalizedAnswer.charCodeAt(0)
    if (answerCode < 65 || answerCode > 90) {
      throw new Error('答案字母不正确')
    }
    let matched: boolean = false
    for (const option of options) {
      const normalizedOption: string = option.trim()
      if (normalizedOption.length === 0) {
        throw new Error('选项不能为空')
      }
      if (normalizedOption.startsWith(normalizedAnswer + '.') ||
        normalizedOption.startsWith(normalizedAnswer + '．')) {
        matched = true
      }
    }
    if (!matched) {
      throw new Error('答案与选项不匹配')
    }
    return new Question(id, '', type, question, options, normalizedAnswer, analysis)
  }

  private skipValue(depth: number): void {
    this.skipWhitespace()
    const character: string = this.peek()
    // 未知字段按值类型递归跳过。
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
      throw new Error('JSON 值不正确')
    }
  }

  private skipObject(depth: number): void {
    if (depth > MAX_NESTING_DEPTH) {
      throw new Error('JSON 嵌套层级过深')
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
      throw new Error('JSON 嵌套层级过深')
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
        throw new Error('JSON 数字不正确')
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
      throw new Error('JSON 数字不正确')
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
        throw new Error('JSON 字面量不正确')
      }
    }
    this.index += literal.length
  }
}

export class JsonParser {
  static parse(text: string): QuestionBank {
    const reader: JsonReader = new JsonReader(text)
    const bank: QuestionBank = reader.readBank()
    reader.ensureFinished()
    return bank
  }
}
