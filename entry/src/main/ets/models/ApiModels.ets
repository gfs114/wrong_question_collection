export interface ApiErrorPayload {
  code: string
  message: string
}

export class ApiHttpError extends Error {
  readonly statusCode: number
  readonly code: string

  constructor(message: string, statusCode: number, code: string) {
    super(message)
    this.statusCode = statusCode
    this.code = code
  }
}
