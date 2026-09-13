export class AiImportLimits {
  static readonly MAX_IMAGE_LONG_EDGE: number = 2200
  static readonly JPEG_QUALITY_STEPS: Array<number> = [82, 75, 68, 60]
  static readonly MAX_JPEG_BYTES: number = 4 * 1024 * 1024
  static readonly MAX_REQUEST_BYTES: number = 6 * 1024 * 1024
  static readonly MAX_RESPONSE_BYTES: number = 2 * 1024 * 1024
  static readonly MAX_QUESTIONS_PER_PAGE: number = 50
  static readonly MAX_LABEL_LENGTH: number = 32
  static readonly MAX_QUESTION_LENGTH: number = 20000
  static readonly MAX_OPTION_LENGTH: number = 2000
  static readonly MAX_ANSWER_LENGTH: number = 20000
  static readonly MAX_ANALYSIS_LENGTH: number = 40000
  static readonly MAX_PREVIOUS_CONTEXT_LENGTH: number = 1000
  static readonly MIN_BBOX_EDGE: number = 8
  static readonly CONNECT_TIMEOUT_MS: number = 15000
  static readonly READ_TIMEOUT_MS: number = 90000
}
