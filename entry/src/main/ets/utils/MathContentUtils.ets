class MathDelimiterRange {
  openingStart: number
  openingLength: number
  closingStart: number
  closingLength: number

  constructor(openingStart: number, openingLength: number, closingStart: number, closingLength: number) {
    this.openingStart = openingStart
    this.openingLength = openingLength
    this.closingStart = closingStart
    this.closingLength = closingLength
  }
}

export class MathContentUtils {
  static containsMath(content: string): boolean {
    if (content.length === 0) {
      return false
    }
    if (MathContentUtils.hasDelimitedMath(content)) {
      return true
    }
    const commands: Array<string> = [
      '\\frac', '\\sqrt', '\\sum', '\\int', '\\lim', '\\sin', '\\cos', '\\tan',
      '\\log', '\\ln', '\\alpha', '\\beta', '\\theta', '\\pi'
    ]
    for (let index: number = 0; index < commands.length; index++) {
      if (content.indexOf(commands[index]) >= 0) {
        return true
      }
    }
    return MathContentUtils.hasScript(content, '^') || MathContentUtils.hasScript(content, '_')
  }

  static toPlainPreview(content: string): string {
    if (content.length === 0 || !MathContentUtils.containsMath(content)) {
      return content
    }
    const ranges: Array<MathDelimiterRange> = MathContentUtils.delimiterRanges(content)
    if (ranges.length === 0) {
      return MathContentUtils.convertMathFragment(content)
    }
    if (MathContentUtils.hasUnsafeUnpairedSingleDollar(content, ranges)) {
      return content
    }
    let preview: string = ''
    let cursor: number = 0
    for (let index: number = 0; index < ranges.length; index++) {
      const range: MathDelimiterRange = ranges[index]
      preview += content.substring(cursor, range.openingStart)
      const formula: string = content.substring(
        range.openingStart + range.openingLength,
        range.closingStart
      )
      preview += MathContentUtils.convertMathFragment(formula)
      cursor = range.closingStart + range.closingLength
    }
    return preview + content.substring(cursor)
  }

  private static convertMathFragment(content: string): string {
    let preview: string = content
    preview = MathContentUtils.replaceFractions(preview)
    preview = MathContentUtils.replaceSquareRoots(preview)
    preview = MathContentUtils.replaceSymbols(preview)
    return MathContentUtils.replaceScripts(preview)
  }

  private static hasDelimitedMath(content: string): boolean {
    return MathContentUtils.delimiterRanges(content).length > 0
  }

  private static delimiterRanges(content: string): Array<MathDelimiterRange> {
    const ranges: Array<MathDelimiterRange> = new Array<MathDelimiterRange>()
    let index: number = 0
    while (index < content.length) {
      if (MathContentUtils.isEscaped(content, index)) {
        index++
        continue
      }
      let opening: string = ''
      let closing: string = ''
      if (MathContentUtils.startsAt(content, '$$', index)) {
        opening = '$$'
        closing = '$$'
      } else if (MathContentUtils.startsAt(content, '\\(', index)) {
        opening = '\\('
        closing = '\\)'
      } else if (MathContentUtils.startsAt(content, '\\[', index)) {
        opening = '\\['
        closing = '\\]'
      } else if (content.charAt(index) === '$' &&
        content.charAt(index - 1) !== '$' && content.charAt(index + 1) !== '$') {
        opening = '$'
        closing = '$'
      }
      if (opening.length === 0) {
        index++
        continue
      }
      const closingIndex: number = MathContentUtils.findClosingDelimiter(
        content,
        closing,
        index + opening.length
      )
      if (closingIndex <= index + opening.length) {
        index += opening.length
        continue
      }
      if (opening === '$' && MathContentUtils.isLikelyCurrencyRange(content, index, closingIndex)) {
        index++
        continue
      }
      ranges.push(new MathDelimiterRange(index, opening.length, closingIndex, closing.length))
      index = closingIndex + closing.length
    }
    return ranges
  }

  private static startsAt(content: string, token: string, index: number): boolean {
    return index >= 0 && index + token.length <= content.length &&
      content.substring(index, index + token.length) === token
  }

  private static findClosingDelimiter(content: string, closing: string, start: number): number {
    let index: number = content.indexOf(closing, start)
    while (index >= 0) {
      if (!MathContentUtils.isEscaped(content, index)) {
        if (closing !== '$' ||
          (content.charAt(index - 1) !== '$' && content.charAt(index + 1) !== '$')) {
          return index
        }
      }
      index = content.indexOf(closing, index + closing.length)
    }
    return -1
  }

  private static isEscaped(content: string, index: number): boolean {
    let slashCount: number = 0
    let cursor: number = index - 1
    while (cursor >= 0 && content.charAt(cursor) === '\\') {
      slashCount++
      cursor--
    }
    return slashCount % 2 === 1
  }

  private static isLikelyCurrencyRange(content: string, openingIndex: number, closingIndex: number): boolean {
    if (!MathContentUtils.isDigit(content.charAt(openingIndex + 1))) {
      return false
    }
    if (MathContentUtils.isDigit(content.charAt(closingIndex + 1))) {
      return true
    }
    const amountEnd: number = MathContentUtils.currencyAmountEnd(content, openingIndex + 1)
    if (amountEnd >= closingIndex || !MathContentUtils.isCurrencyBoundary(content.charAt(amountEnd))) {
      return false
    }
    if (MathContentUtils.countUnescapedSingleDollars(content, openingIndex + 1) < 2) {
      return false
    }
    if (!MathContentUtils.isCurrencyBoundary(content.charAt(closingIndex + 1))) {
      return true
    }
    const nextDollar: number = MathContentUtils.findClosingDelimiter(content, '$', closingIndex + 1)
    return nextDollar > closingIndex &&
      MathContentUtils.isLikelyFormulaFragment(content.substring(closingIndex + 1, nextDollar))
  }

  private static currencyAmountEnd(content: string, start: number): number {
    let index: number = start
    while (index < content.length) {
      const value: string = content.charAt(index)
      if (MathContentUtils.isDigit(value)) {
        index++
      } else if ((value === '.' || value === ',') && MathContentUtils.isDigit(content.charAt(index + 1))) {
        index++
      } else {
        break
      }
    }
    return index
  }

  private static isCurrencyBoundary(value: string): boolean {
    return value.length === 0 || MathContentUtils.isWhitespace(value) || value === ',' || value === '.' ||
      value === ';' || value === ':' || value === '，' || value === '。' || value === '；' || value === '：' ||
      value === '！' || value === '？' || value === '、'
  }

  private static isLikelyFormulaFragment(content: string): boolean {
    const fragment: string = content.trim()
    if (fragment.length === 0) {
      return false
    }
    const signals: string = '\\^_=+-*/()[]{}!'
    for (let index: number = 0; index < fragment.length; index++) {
      if (signals.indexOf(fragment.charAt(index)) >= 0) {
        return true
      }
    }
    if (fragment.length === 1) {
      return MathContentUtils.isAsciiLetter(fragment) || MathContentUtils.isDigit(fragment)
    }
    return MathContentUtils.isDigit(fragment.charAt(0)) && fragment.indexOf(' ') < 0 &&
      fragment.indexOf('\t') < 0 && fragment.indexOf('\r') < 0 && fragment.indexOf('\n') < 0
  }

  private static hasUnsafeUnpairedSingleDollar(content: string, ranges: Array<MathDelimiterRange>): boolean {
    for (let index: number = 0; index < content.length; index++) {
      if (content.charAt(index) !== '$' || MathContentUtils.isEscaped(content, index) ||
        content.charAt(index - 1) === '$' || content.charAt(index + 1) === '$') {
        continue
      }
      let paired: boolean = false
      for (let rangeIndex: number = 0; rangeIndex < ranges.length; rangeIndex++) {
        const range: MathDelimiterRange = ranges[rangeIndex]
        if ((range.openingLength === 1 && range.openingStart === index) ||
          (range.closingLength === 1 && range.closingStart === index)) {
          paired = true
          break
        }
      }
      if (!paired && !MathContentUtils.isDigit(content.charAt(index + 1))) {
        return true
      }
    }
    return false
  }

  private static countUnescapedSingleDollars(content: string, start: number): number {
    let count: number = 0
    for (let index: number = start; index < content.length; index++) {
      if (content.charAt(index) === '$' && !MathContentUtils.isEscaped(content, index) &&
        content.charAt(index - 1) !== '$' && content.charAt(index + 1) !== '$') {
        count++
      }
    }
    return count
  }

  private static hasScript(content: string, operator: string): boolean {
    let operatorIndex: number = content.indexOf(operator)
    while (operatorIndex >= 0) {
      const baseIndex: number = MathContentUtils.previousNonSpace(content, operatorIndex - 1)
      const valueIndex: number = MathContentUtils.nextNonSpace(content, operatorIndex + 1)
      if (MathContentUtils.hasValidScriptBase(content, baseIndex) &&
        MathContentUtils.hasValidScriptValue(content, valueIndex)) {
        return true
      }
      operatorIndex = content.indexOf(operator, operatorIndex + 1)
    }
    return false
  }

  private static hasValidScriptBase(content: string, baseIndex: number): boolean {
    if (baseIndex < 0) {
      return false
    }
    const base: string = content.charAt(baseIndex)
    if (MathContentUtils.isDigit(base) || base === ')' || base === ']' || base === '}') {
      return true
    }
    if (!MathContentUtils.isAsciiLetter(base)) {
      return false
    }
    const precedingIndex: number = baseIndex - 1
    if (precedingIndex < 0) {
      return true
    }
    const preceding: string = content.charAt(precedingIndex)
    return !MathContentUtils.isAsciiLetter(preceding) && !MathContentUtils.isDigit(preceding) && preceding !== '_'
  }

  private static hasValidScriptValue(content: string, valueIndex: number): boolean {
    if (valueIndex < 0 || valueIndex >= content.length) {
      return false
    }
    const value: string = content.charAt(valueIndex)
    if (value === '{') {
      return MathContentUtils.findClosingBrace(content, valueIndex) > valueIndex + 1
    }
    return MathContentUtils.isAsciiLetter(value) || MathContentUtils.isDigit(value)
  }

  private static previousNonSpace(content: string, start: number): number {
    let index: number = start
    while (index >= 0 && MathContentUtils.isWhitespace(content.charAt(index))) {
      index--
    }
    return index
  }

  private static nextNonSpace(content: string, start: number): number {
    let index: number = start
    while (index < content.length && MathContentUtils.isWhitespace(content.charAt(index))) {
      index++
    }
    return index < content.length ? index : -1
  }

  private static isWhitespace(value: string): boolean {
    return value === ' ' || value === '\t' || value === '\r' || value === '\n'
  }

  private static isAsciiLetter(value: string): boolean {
    if (value.length === 0) {
      return false
    }
    const code: number = value.charCodeAt(0)
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
  }

  private static isDigit(value: string): boolean {
    if (value.length === 0) {
      return false
    }
    const code: number = value.charCodeAt(0)
    return code >= 48 && code <= 57
  }

  private static replaceFractions(content: string): string {
    let result: string = content
    let searchFrom: number = 0
    let commandIndex: number = result.indexOf('\\frac', searchFrom)
    while (commandIndex >= 0) {
      const numeratorStart: number = MathContentUtils.nextNonSpace(result, commandIndex + 5)
      if (numeratorStart < 0 || result.charAt(numeratorStart) !== '{') {
        searchFrom = commandIndex + 5
        commandIndex = result.indexOf('\\frac', searchFrom)
        continue
      }
      const numeratorEnd: number = MathContentUtils.findClosingBrace(result, numeratorStart)
      const denominatorStart: number = MathContentUtils.nextNonSpace(result, numeratorEnd + 1)
      if (numeratorEnd < 0 || denominatorStart < 0 || result.charAt(denominatorStart) !== '{') {
        searchFrom = commandIndex + 5
        commandIndex = result.indexOf('\\frac', searchFrom)
        continue
      }
      const denominatorEnd: number = MathContentUtils.findClosingBrace(result, denominatorStart)
      if (denominatorEnd < 0) {
        searchFrom = commandIndex + 5
        commandIndex = result.indexOf('\\frac', searchFrom)
        continue
      }
      const numerator: string = result.substring(numeratorStart + 1, numeratorEnd)
      const denominator: string = result.substring(denominatorStart + 1, denominatorEnd)
      result = result.substring(0, commandIndex) + '(' + numerator + ')/(' + denominator + ')' +
        result.substring(denominatorEnd + 1)
      searchFrom = 0
      commandIndex = result.indexOf('\\frac', searchFrom)
    }
    return result
  }

  private static replaceSquareRoots(content: string): string {
    let result: string = content
    let searchFrom: number = 0
    let commandIndex: number = result.indexOf('\\sqrt', searchFrom)
    while (commandIndex >= 0) {
      const valueStart: number = MathContentUtils.nextNonSpace(result, commandIndex + 5)
      if (valueStart < 0 || result.charAt(valueStart) !== '{') {
        searchFrom = commandIndex + 5
        commandIndex = result.indexOf('\\sqrt', searchFrom)
        continue
      }
      const valueEnd: number = MathContentUtils.findClosingBrace(result, valueStart)
      if (valueEnd < 0) {
        searchFrom = commandIndex + 5
        commandIndex = result.indexOf('\\sqrt', searchFrom)
        continue
      }
      const value: string = result.substring(valueStart + 1, valueEnd)
      const replacement: string = MathContentUtils.isSimpleRadicand(value) ? '√' + value : '√(' + value + ')'
      result = result.substring(0, commandIndex) + replacement + result.substring(valueEnd + 1)
      searchFrom = 0
      commandIndex = result.indexOf('\\sqrt', searchFrom)
    }
    return result
  }

  private static isSimpleRadicand(value: string): boolean {
    return value.length === 1 && (MathContentUtils.isAsciiLetter(value) || MathContentUtils.isDigit(value))
  }

  private static findClosingBrace(content: string, openingIndex: number): number {
    if (openingIndex < 0 || openingIndex >= content.length || content.charAt(openingIndex) !== '{') {
      return -1
    }
    let depth: number = 0
    for (let index: number = openingIndex; index < content.length; index++) {
      const value: string = content.charAt(index)
      if (value === '{') {
        depth++
      } else if (value === '}') {
        depth--
        if (depth === 0) {
          return index
        }
      }
    }
    return -1
  }

  private static replaceSymbols(content: string): string {
    return content
      .replaceAll('\\leq', '≤')
      .replaceAll('\\geq', '≥')
      .replaceAll('\\neq', '≠')
      .replaceAll('\\cdots', '⋯')
      .replaceAll('\\infty', '∞')
      .replaceAll('\\alpha', 'α')
      .replaceAll('\\beta', 'β')
      .replaceAll('\\theta', 'θ')
      .replaceAll('\\times', '×')
      .replaceAll('\\div', '÷')
      .replaceAll('\\pm', '±')
      .replaceAll('\\sum', '∑')
      .replaceAll('\\int', '∫')
      .replaceAll('\\pi', 'π')
      .replaceAll('\\le', '≤')
      .replaceAll('\\ge', '≥')
      .replaceAll('\\cdot', '·')
      .replaceAll('\\left', '')
      .replaceAll('\\right', '')
      .replaceAll('\\,', '')
  }

  private static replaceScripts(content: string): string {
    let result: string = ''
    let index: number = 0
    while (index < content.length) {
      const current: string = content.charAt(index)
      if (current !== '^' && current !== '_') {
        result += current
        index++
        continue
      }
      const baseIndex: number = MathContentUtils.previousNonSpace(content, index - 1)
      if (baseIndex >= 0 && MathContentUtils.isAsciiLetter(content.charAt(baseIndex)) &&
        !MathContentUtils.hasValidScriptBase(content, baseIndex)) {
        result += current
        index++
        continue
      }
      const valueStart: number = MathContentUtils.nextNonSpace(content, index + 1)
      if (valueStart < 0) {
        result += current
        index++
        continue
      }
      let value: string = ''
      let valueEnd: number = valueStart
      let grouped: boolean = false
      if (content.charAt(valueStart) === '{') {
        const closingBrace: number = MathContentUtils.findClosingBrace(content, valueStart)
        if (closingBrace < 0) {
          result += current
          index++
          continue
        }
        value = content.substring(valueStart + 1, closingBrace)
        valueEnd = closingBrace
        grouped = true
      } else {
        value = content.charAt(valueStart)
      }
      const converted: string = grouped && value.length > 1 ? '' :
        MathContentUtils.convertScriptValue(value, current === '^')
      if (converted.length === 0) {
        result += current
        index++
        continue
      }
      result += converted
      index = valueEnd + 1
    }
    return result
  }

  private static convertScriptValue(value: string, superscript: boolean): string {
    if (value.length === 0) {
      return ''
    }
    let result: string = ''
    for (let index: number = 0; index < value.length; index++) {
      const converted: string = superscript ?
        MathContentUtils.toSuperscript(value.charAt(index)) : MathContentUtils.toSubscript(value.charAt(index))
      if (converted.length === 0) {
        return ''
      }
      result += converted
    }
    return result
  }

  private static toSuperscript(value: string): string {
    if (value === '0') return '⁰'
    if (value === '1') return '¹'
    if (value === '2') return '²'
    if (value === '3') return '³'
    if (value === '4') return '⁴'
    if (value === '5') return '⁵'
    if (value === '6') return '⁶'
    if (value === '7') return '⁷'
    if (value === '8') return '⁸'
    if (value === '9') return '⁹'
    if (value === '+') return '⁺'
    if (value === '-') return '⁻'
    if (value === '=') return '⁼'
    if (value === '(') return '⁽'
    if (value === ')') return '⁾'
    if (value === 'a') return 'ᵃ'
    if (value === 'b') return 'ᵇ'
    if (value === 'c') return 'ᶜ'
    if (value === 'd') return 'ᵈ'
    if (value === 'e') return 'ᵉ'
    if (value === 'f') return 'ᶠ'
    if (value === 'g') return 'ᵍ'
    if (value === 'h') return 'ʰ'
    if (value === 'i') return 'ⁱ'
    if (value === 'j') return 'ʲ'
    if (value === 'k') return 'ᵏ'
    if (value === 'l') return 'ˡ'
    if (value === 'm') return 'ᵐ'
    if (value === 'n') return 'ⁿ'
    if (value === 'o') return 'ᵒ'
    if (value === 'p') return 'ᵖ'
    if (value === 'r') return 'ʳ'
    if (value === 's') return 'ˢ'
    if (value === 't') return 'ᵗ'
    if (value === 'u') return 'ᵘ'
    if (value === 'v') return 'ᵛ'
    if (value === 'w') return 'ʷ'
    if (value === 'x') return 'ˣ'
    if (value === 'y') return 'ʸ'
    if (value === 'z') return 'ᶻ'
    return ''
  }

  private static toSubscript(value: string): string {
    if (value === '0') return '₀'
    if (value === '1') return '₁'
    if (value === '2') return '₂'
    if (value === '3') return '₃'
    if (value === '4') return '₄'
    if (value === '5') return '₅'
    if (value === '6') return '₆'
    if (value === '7') return '₇'
    if (value === '8') return '₈'
    if (value === '9') return '₉'
    if (value === '+') return '₊'
    if (value === '-') return '₋'
    if (value === '=') return '₌'
    if (value === '(') return '₍'
    if (value === ')') return '₎'
    if (value === 'a') return 'ₐ'
    if (value === 'e') return 'ₑ'
    if (value === 'h') return 'ₕ'
    if (value === 'i') return 'ᵢ'
    if (value === 'j') return 'ⱼ'
    if (value === 'k') return 'ₖ'
    if (value === 'l') return 'ₗ'
    if (value === 'm') return 'ₘ'
    if (value === 'n') return 'ₙ'
    if (value === 'o') return 'ₒ'
    if (value === 'p') return 'ₚ'
    if (value === 'r') return 'ᵣ'
    if (value === 's') return 'ₛ'
    if (value === 't') return 'ₜ'
    if (value === 'u') return 'ᵤ'
    if (value === 'v') return 'ᵥ'
    if (value === 'x') return 'ₓ'
    return ''
  }
}
