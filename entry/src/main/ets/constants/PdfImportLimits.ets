export class PdfImportLimits {
  static readonly MAX_FILE_BYTES: number = 200 * 1024 * 1024
  static readonly MAX_SELECTED_PAGES: number = 20
  static readonly MIN_PAGE_NUMBER: number = 1
  static readonly MAX_RENDER_LONG_EDGE: number = 2200
  static readonly MAX_SAVED_IMAGE_WIDTH: number = 1440
  static readonly JPEG_QUALITY: number = 88
  static readonly PAGE_TOP_MARGIN_RATIO: number = 0.04
  static readonly PAGE_BOTTOM_MARGIN_RATIO: number = 0.96
}
