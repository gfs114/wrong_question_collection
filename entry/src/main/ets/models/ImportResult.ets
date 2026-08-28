export class ImportErrorCode {
  static readonly SUCCESS: string = 'success'
  static readonly CANCELLED: string = 'cancelled'
  static readonly FORMAT_ERROR: string = 'format_error'
  static readonly READ_ERROR: string = 'read_error'
  static readonly SAVE_ERROR: string = 'save_error'

  code: string

  constructor(code: string) {
    this.code = code
  }
}

export class ImportResult {
  success: boolean
  cancelled: boolean
  errorCode: ImportErrorCode
  bankId: string
  message: string

  constructor(success: boolean, cancelled: boolean, errorCode: ImportErrorCode,
    bankId: string, message: string) {
    this.success = success
    this.cancelled = cancelled
    this.errorCode = errorCode
    this.bankId = bankId
    this.message = message
  }

  static success(bankId: string): ImportResult {
    return new ImportResult(true, false, new ImportErrorCode(ImportErrorCode.SUCCESS), bankId, '')
  }

  static cancelled(): ImportResult {
    return new ImportResult(false, true, new ImportErrorCode(ImportErrorCode.CANCELLED), '', '')
  }

  static formatError(message: string): ImportResult {
    return new ImportResult(false, false, new ImportErrorCode(ImportErrorCode.FORMAT_ERROR), '', message)
  }

  static readError(message: string): ImportResult {
    return new ImportResult(false, false, new ImportErrorCode(ImportErrorCode.READ_ERROR), '', message)
  }

  static saveError(message: string): ImportResult {
    return new ImportResult(false, false, new ImportErrorCode(ImportErrorCode.SAVE_ERROR), '', message)
  }
}
