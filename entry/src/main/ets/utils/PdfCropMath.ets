import { PdfImportLimits } from '../constants/PdfImportLimits'

export class PdfCropOutputSize {
  width: number
  height: number

  constructor(width: number, height: number) {
    this.width = width
    this.height = height
  }
}

export class PdfCropMath {
  static calculate(sourceWidth: number, sourceHeight: number): PdfCropOutputSize {
    if (!Number.isFinite(sourceWidth) || !Number.isFinite(sourceHeight) ||
      sourceWidth <= 0 || sourceHeight <= 0) {
      throw new Error('题图源像素尺寸无效')
    }
    const scale: number = Math.min(1, PdfImportLimits.MAX_SAVED_IMAGE_WIDTH / sourceWidth,
      PdfImportLimits.MAX_RENDER_LONG_EDGE / sourceHeight)
    if (!Number.isFinite(scale) || scale <= 0) {
      throw new Error('题图输出缩放比例无效')
    }
    const width: number = Math.max(1, Math.floor(sourceWidth * scale))
    const height: number = Math.max(1, Math.floor(sourceHeight * scale))
    return new PdfCropOutputSize(width, height)
  }
}
