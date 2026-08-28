export class PdfStorageError extends Error {
  readonly diagnostic: string

  constructor(diagnostic: string = '') {
    super('本地空间不足或图片保存失败')
    this.diagnostic = diagnostic
  }
}
