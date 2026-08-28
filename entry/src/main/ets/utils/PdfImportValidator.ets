import { PdfImportLimits } from '../constants/PdfImportLimits'
import { PdfPageRangeValidation } from '../models/PdfImportModels'

export class PdfImportValidator {
  static bankNameFromFileName(fileName: string): string {
    let bankName: string = fileName.trim()
    if (bankName.toLowerCase().endsWith('.pdf')) {
      bankName = bankName.substring(0, bankName.length - 4).trim()
    }
    return bankName.length > 0 ? bankName : '未命名题库'
  }

  static validateFileSize(fileSize: number): boolean {
    return Number.isFinite(fileSize) && Number.isInteger(fileSize) &&
      fileSize >= 1 && fileSize <= PdfImportLimits.MAX_FILE_BYTES
  }

  static validatePageRange(startPage: number, endPage: number, totalPages: number): PdfPageRangeValidation {
    if (!Number.isInteger(startPage) || !Number.isInteger(endPage) || !Number.isInteger(totalPages) ||
      startPage < PdfImportLimits.MIN_PAGE_NUMBER || endPage < PdfImportLimits.MIN_PAGE_NUMBER ||
      totalPages < PdfImportLimits.MIN_PAGE_NUMBER) {
      return new PdfPageRangeValidation(false, '页码必须是从 1 开始的正整数', 0)
    }
    if (startPage > endPage) {
      return new PdfPageRangeValidation(false, '起始页不能大于结束页', 0)
    }
    const selectedPageCount: number = endPage - startPage + 1
    if (endPage > totalPages) {
      return new PdfPageRangeValidation(false, '结束页不能超过 PDF 总页数', selectedPageCount)
    }
    if (selectedPageCount > PdfImportLimits.MAX_SELECTED_PAGES) {
      return new PdfPageRangeValidation(false, '单次最多识别 20 页', selectedPageCount)
    }
    return new PdfPageRangeValidation(true, '', selectedPageCount)
  }
}
