import { Context } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { pdfService } from '@kit.PDFKit'
import fs, { ListFileOptions } from '@ohos.file.fs'
import picker from '@ohos.file.picker'
import { PdfImportLimits } from '../constants/PdfImportLimits'
import { PdfFileSelection } from '../models/PdfImportModels'
import { PdfImportValidator } from '../utils/PdfImportValidator'
import { PdfStorageError } from './PdfStorageError'

export class PdfImportService {
  private static readonly stagedPaths: Array<string> = new Array<string>()
  private static readonly stagedCacheDirs: Array<string> = new Array<string>()
  private static readonly orphanPaths: Array<string> = new Array<string>()
  private static readonly orphanCacheDirs: Array<string> = new Array<string>()
  private static selectionInProgress: boolean = false

  static async selectPdf(context: Context): Promise<PdfFileSelection | null> {
    if (PdfImportService.selectionInProgress) {
      throw new Error('已有 PDF 选择任务正在进行')
    }
    PdfImportService.selectionInProgress = true
    let tempPath: string = ''
    let candidate: PdfFileSelection | null = null
    try {
      await PdfImportService.cleanupStalePdfs(context.cacheDir)
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions()
      options.fileSuffixFilters = ['PDF文件|.pdf']
      options.maxSelectNumber = 1
      const selectedUris: Array<string> = await documentPicker.select(options)
      if (selectedUris.length === 0) {
        return null
      }
      const sourceUri: string = selectedUris[0]
      const sourceFile: fs.File = await fs.open(sourceUri, fs.OpenMode.READ_ONLY)
      try {
        const fileInfo: fs.Stat = await fs.stat(sourceFile.fd)
        if (!PdfImportValidator.validateFileSize(fileInfo.size)) {
          throw new Error('PDF 文件大小无效或超过限制')
        }
        tempPath = context.cacheDir + '/staged_pdf_' + Date.now().toString() + '.pdf'
        let totalCopied: number = 0
        try {
          const targetFile: fs.File = await fs.open(tempPath,
            fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW)
          try {
            const buffer: ArrayBuffer = new ArrayBuffer(64 * 1024)
            while (true) {
              const bytesRead: number = await fs.read(sourceFile.fd, buffer)
              if (!Number.isFinite(bytesRead) || !Number.isInteger(bytesRead) ||
                bytesRead < 0 || bytesRead > buffer.byteLength) {
                throw new Error('PDF 读取返回了无效字节数')
              }
              if (bytesRead === 0) {
                break
              }
              const nextTotal: number = totalCopied + bytesRead
              if (!Number.isSafeInteger(nextTotal) || nextTotal > PdfImportLimits.MAX_FILE_BYTES) {
                throw new Error('PDF 文件在读取期间超过大小限制')
              }
              let writtenBytes: number = 0
              while (writtenBytes < bytesRead) {
                const writeBuffer: ArrayBuffer = buffer.slice(writtenBytes, bytesRead)
                const currentWrite: number = await fs.write(targetFile.fd, writeBuffer)
                if (currentWrite <= 0) {
                  throw new Error('PDF 暂存写入失败')
                }
                writtenBytes += currentWrite
              }
              totalCopied = nextTotal
            }
          } finally {
            await fs.close(targetFile)
          }
        } catch (stagingErr) {
          if (stagingErr instanceof Error && stagingErr.message.includes('超过大小限制')) {
            throw stagingErr
          }
          throw new PdfStorageError(PdfImportService.errorMessage(stagingErr, 'PDF 暂存失败'))
        }
        if (totalCopied <= 0 || totalCopied !== fileInfo.size) {
          throw new Error('PDF 文件在读取期间发生变化')
        }
        const stagedInfo: fs.Stat = await fs.lstat(tempPath)
        if (stagedInfo.isSymbolicLink() || !stagedInfo.isFile()) {
          throw new Error('PDF 暂存文件类型无效')
        }
        if (!PdfImportValidator.validateFileSize(stagedInfo.size) || stagedInfo.size !== totalCopied) {
          throw new Error('PDF 暂存文件大小不一致')
        }
        const pdfDocument: pdfService.PdfDocument = new pdfService.PdfDocument()
        let pageCount: number = 0
        try {
          if (pdfDocument.isEncrypted(tempPath)) {
            throw new Error('不支持加密 PDF')
          }
          const parseResult: pdfService.ParseResult = pdfDocument.loadDocument(tempPath)
          if (parseResult !== pdfService.ParseResult.PARSE_SUCCESS) {
            throw new Error('PDF 文件无法解析')
          }
          pageCount = pdfDocument.getPageCount()
          if (pageCount <= 0) {
            throw new Error('PDF 不包含可导入页面')
          }
        } finally {
          pdfDocument.releaseDocument()
        }
        const fileName: string = PdfImportService.resolveFileName(sourceUri, sourceFile.name)
        candidate = new PdfFileSelection(tempPath, fileName, totalCopied, pageCount,
          1, Math.min(20, pageCount))
      } finally {
        await fs.close(sourceFile)
      }
      if (candidate === null) {
        throw new Error('PDF 选择结果未生成')
      }
      PdfImportService.registerStagedPath(candidate.uri, context.cacheDir)
      return candidate
    } catch (err) {
      const primaryError: Error = err instanceof Error ? err : new Error('PDF 导入失败')
      const primaryMessage: string = primaryError.message
      if (tempPath.length > 0) {
        PdfImportService.unregisterStagedPath(tempPath)
        try {
          await PdfImportService.cleanupFailedTemporaryPdf(context.cacheDir, tempPath)
        } catch (cleanupErr) {
          let cleanupMessage: string = '未知清理错误'
          if (cleanupErr instanceof Error) {
            cleanupMessage = cleanupErr.message
          }
          if (primaryError instanceof PdfStorageError) {
            throw new PdfStorageError(primaryError.diagnostic + '；临时文件清理失败：' + cleanupMessage)
          }
          throw new Error(primaryMessage + '；临时文件清理失败：' + cleanupMessage)
        }
      }
      throw primaryError
    } finally {
      PdfImportService.selectionInProgress = false
    }
  }

  static async removeTemporaryPdf(path: string): Promise<void> {
    const cacheDir: string = PdfImportService.registeredCacheDir(path)
    if (cacheDir.length === 0) {
      throw new Error('PDF 临时文件不属于当前导入任务')
    }
    if (!PdfImportService.isDirectTemporaryPdfPath(cacheDir, path)) {
      throw new Error('PDF 临时文件路径无效')
    }
    try {
      if (!(await PdfImportService.validateExistingTemporaryPdf(cacheDir, path))) {
        PdfImportService.unregisterStagedPath(path)
        PdfImportService.unregisterOrphanPath(path)
        return
      }
      await fs.unlink(path)
      PdfImportService.unregisterStagedPath(path)
      PdfImportService.unregisterOrphanPath(path)
    } catch (err) {
      if (err instanceof Error) {
        throw err
      }
      throw new Error('PDF 临时文件删除失败')
    }
  }

  static abandonTemporaryPdf(path: string): void {
    const stagedIndex: number = PdfImportService.stagedPaths.indexOf(path)
    if (stagedIndex < 0) {
      if (PdfImportService.isRegisteredOrphanPath(path)) {
        return
      }
      throw new Error('PDF 临时文件不属于当前导入任务')
    }
    if (stagedIndex >= PdfImportService.stagedCacheDirs.length) {
      throw new Error('PDF 临时文件不属于当前导入任务')
    }
    const cacheDir: string = PdfImportService.stagedCacheDirs[stagedIndex]
    if (!PdfImportService.isDirectTemporaryPdfPath(cacheDir, path)) {
      throw new Error('PDF 临时文件路径无效')
    }
    PdfImportService.registerOrphanPath(path, cacheDir)
    PdfImportService.unregisterStagedPath(path)
  }

  private static async cleanupStalePdfs(cacheDir: string): Promise<void> {
    const options: ListFileOptions = {
      recursion: false
    }
    await PdfImportService.pruneMissingOrphanPaths(cacheDir)
    let names: Array<string>
    try {
      await PdfImportService.validateCacheDirectory(cacheDir)
      names = await fs.listFile(cacheDir, options)
    } catch (err) {
      if (err instanceof Error) {
        throw new Error('PDF 遗留临时文件清理失败：' + err.message)
      }
      throw new Error('PDF 遗留临时文件清理失败')
    }
    for (const name of names) {
      if (!PdfImportService.isTemporaryPdfName(name)) {
        continue
      }
      const path: string = cacheDir + '/' + name
      if (PdfImportService.stagedPaths.indexOf(path) >= 0) {
        continue
      }
      try {
        const candidateInfo: fs.Stat | null = await PdfImportService.lstatIfPresent(path)
        if (candidateInfo === null) {
          PdfImportService.unregisterOrphanPath(path)
          continue
        }
        if (candidateInfo.isSymbolicLink() || !candidateInfo.isFile()) {
          PdfImportService.unregisterOrphanPath(path)
          continue
        }
        await fs.unlink(path)
        PdfImportService.unregisterOrphanPath(path)
      } catch (cleanupErr) {
        PdfImportService.registerOrphanPath(path, cacheDir)
        continue
      }
    }
  }

  private static async cleanupFailedTemporaryPdf(cacheDir: string, path: string): Promise<void> {
    try {
      if (!(await PdfImportService.validateExistingTemporaryPdf(cacheDir, path))) {
        PdfImportService.unregisterOrphanPath(path)
        return
      }
      await fs.unlink(path)
      PdfImportService.unregisterOrphanPath(path)
    } catch (err) {
      PdfImportService.registerOrphanPath(path, cacheDir)
      if (err instanceof Error) {
        throw err
      }
      throw new Error('PDF 临时文件删除失败')
    }
  }

  private static registerStagedPath(path: string, cacheDir: string): void {
    if (!PdfImportService.isDirectTemporaryPdfPath(cacheDir, path)) {
      throw new Error('PDF 暂存路径不属于缓存目录')
    }
    if (PdfImportService.stagedPaths.indexOf(path) < 0) {
      PdfImportService.stagedPaths.push(path)
      PdfImportService.stagedCacheDirs.push(cacheDir)
    }
  }

  private static unregisterStagedPath(path: string): void {
    const index: number = PdfImportService.stagedPaths.indexOf(path)
    if (index >= 0) {
      PdfImportService.stagedPaths.splice(index, 1)
      PdfImportService.stagedCacheDirs.splice(index, 1)
    }
  }

  private static registeredCacheDir(path: string): string {
    const index: number = PdfImportService.stagedPaths.indexOf(path)
    if (index >= 0 && index < PdfImportService.stagedCacheDirs.length) {
      return PdfImportService.stagedCacheDirs[index]
    }
    const orphanIndex: number = PdfImportService.orphanPaths.indexOf(path)
    if (orphanIndex >= 0 && orphanIndex < PdfImportService.orphanCacheDirs.length) {
      return PdfImportService.orphanCacheDirs[orphanIndex]
    }
    return ''
  }

  private static registerOrphanPath(path: string, cacheDir: string): void {
    if (!PdfImportService.isDirectTemporaryPdfPath(cacheDir, path)) {
      throw new Error('PDF 遗留临时文件路径无效')
    }
    if (PdfImportService.orphanPaths.indexOf(path) < 0) {
      PdfImportService.orphanPaths.push(path)
      PdfImportService.orphanCacheDirs.push(cacheDir)
    }
  }

  private static unregisterOrphanPath(path: string): void {
    const index: number = PdfImportService.orphanPaths.indexOf(path)
    if (index >= 0) {
      PdfImportService.orphanPaths.splice(index, 1)
      PdfImportService.orphanCacheDirs.splice(index, 1)
    }
  }

  private static isRegisteredOrphanPath(path: string): boolean {
    const index: number = PdfImportService.orphanPaths.indexOf(path)
    if (index < 0 || index >= PdfImportService.orphanCacheDirs.length) {
      return false
    }
    return PdfImportService.isDirectTemporaryPdfPath(PdfImportService.orphanCacheDirs[index], path)
  }

  private static async pruneMissingOrphanPaths(cacheDir: string): Promise<void> {
    try {
      const cachePrefix: string = cacheDir + '/'
      const paths: Array<string> = PdfImportService.orphanPaths.slice()
      for (const path of paths) {
        if (PdfImportService.stagedPaths.indexOf(path) >= 0) {
          continue
        }
        if (!path.startsWith(cachePrefix)) {
          continue
        }
        const name: string = path.substring(cachePrefix.length)
        if (!PdfImportService.isTemporaryPdfName(name)) {
          continue
        }
        try {
          if ((await PdfImportService.lstatIfPresent(path)) === null) {
            PdfImportService.unregisterOrphanPath(path)
          }
        } catch (err) {
          PdfImportService.registerOrphanPath(path, cacheDir)
          continue
        }
      }
    } catch {
      return
    }
  }

  private static resolveFileName(uri: string, fallback: string): string {
    let encodedName: string = fallback
    if (encodedName.length === 0) {
      const slashIndex: number = uri.lastIndexOf('/')
      encodedName = slashIndex >= 0 ? uri.substring(slashIndex + 1) : ''
    }
    const queryIndex: number = encodedName.indexOf('?')
    if (queryIndex >= 0) {
      encodedName = encodedName.substring(0, queryIndex)
    }
    if (encodedName.length === 0) {
      return fallback.length > 0 ? fallback : 'selected.pdf'
    }
    try {
      const decodedName: string = decodeURIComponent(encodedName)
      return decodedName.length > 0 ? decodedName : fallback
    } catch (err) {
      return fallback.length > 0 ? fallback : 'selected.pdf'
    }
  }

  private static isTemporaryPdfName(name: string): boolean {
    const prefix: string = 'staged_pdf_'
    const suffix: string = '.pdf'
    if (!name.startsWith(prefix) || !name.endsWith(suffix)) {
      return false
    }
    const digitStart: number = prefix.length
    const digitEnd: number = name.length - suffix.length
    if (digitStart >= digitEnd) {
      return false
    }
    for (let index: number = digitStart; index < digitEnd; index++) {
      const code: number = name.charCodeAt(index)
      if (code < 48 || code > 57) {
        return false
      }
    }
    return true
  }

  private static isDirectTemporaryPdfPath(cacheDir: string, path: string): boolean {
    const prefix: string = cacheDir + '/'
    if (!path.startsWith(prefix) || path.length <= prefix.length || path.indexOf('\\') >= 0 ||
      path.indexOf(String.fromCharCode(0)) >= 0) {
      return false
    }
    const name: string = path.substring(prefix.length)
    return name.indexOf('/') < 0 && name.indexOf('\\') < 0 && PdfImportService.isTemporaryPdfName(name)
  }

  private static async validateExistingTemporaryPdf(cacheDir: string, path: string): Promise<boolean> {
    if (!PdfImportService.isDirectTemporaryPdfPath(cacheDir, path)) {
      throw new Error('PDF 临时文件路径超出缓存目录')
    }
    await PdfImportService.validateCacheDirectory(cacheDir)
    const fileInfo: fs.Stat | null = await PdfImportService.lstatIfPresent(path)
    if (fileInfo === null) {
      return false
    }
    if (fileInfo.isSymbolicLink() || !fileInfo.isFile()) {
      throw new Error('PDF 临时文件不是普通文件')
    }
    return true
  }

  private static async validateCacheDirectory(cacheDir: string): Promise<void> {
    const cacheInfo: fs.Stat | null = await PdfImportService.lstatIfPresent(cacheDir)
    if (cacheInfo === null || cacheInfo.isSymbolicLink() || !cacheInfo.isDirectory()) {
      throw new Error('PDF 缓存目录类型无效')
    }
  }

  private static async lstatIfPresent(path: string): Promise<fs.Stat | null> {
    return new Promise<fs.Stat | null>((resolve, reject): void => {
      fs.lstat(path, (err: BusinessError, info: fs.Stat): void => {
        if (err) {
          if (err.code === 13900002) {
            resolve(null)
            return
          }
          reject(new Error(err.message.length > 0 ? err.message : '文件状态读取失败'))
          return
        }
        resolve(info)
      })
    })
  }

  private static errorMessage(err: Error, fallback: string): string {
    return err instanceof Error && err.message.length > 0 ? err.message : fallback
  }
}
