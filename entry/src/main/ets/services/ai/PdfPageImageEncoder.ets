import { Context } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { image } from '@kit.ImageKit'
import { pdfService } from '@kit.PDFKit'
import { util } from '@kit.ArkTS'
import fs from '@ohos.file.fs'
import { AiImportLimits } from '../../constants/AiImportLimits'
import { AiBoundingBox, EncodedPdfPage } from '../../models/ai/AiImportModels'

export class PdfPageOutputSize {
  width: number
  height: number

  constructor(width: number, height: number) {
    this.width = width
    this.height = height
  }
}

export class PdfPageSizing {
  static calculate(width: number, height: number): PdfPageOutputSize {
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      throw new Error('PDF 页面尺寸无效')
    }
    const scale: number = Math.min(1,
      AiImportLimits.MAX_IMAGE_LONG_EDGE / Math.max(width, height))
    return new PdfPageOutputSize(Math.max(1, Math.round(width * scale)),
      Math.max(1, Math.round(height * scale)))
  }
}

export class JpegQualityPolicy {
  static steps(): Array<number> {
    return AiImportLimits.JPEG_QUALITY_STEPS.slice()
  }

  static accepts(byteLength: number): boolean {
    return byteLength > 0 && byteLength <= AiImportLimits.MAX_JPEG_BYTES
  }

  static retriesAfterPackError(code: number): boolean {
    return code === 62980106
  }
}

export interface PdfRenderSessionPort {
  pageCount(): number
  encodePage(context: Context, pageIndex: number, sessionId: string,
    attemptId?: string): Promise<EncodedPdfPage>
  cropEvidence(context: Context, pageIndex: number, sessionId: string,
    questionId: string, box: AiBoundingBox, attemptId?: string): Promise<string>
  close(): void
}

export interface PdfPageImageEncoderPort {
  open(pdfPath: string): PdfRenderSessionPort
  cleanupSession(context: Context, sessionId: string): Promise<void>
  cleanupAttempt(context: Context, sessionId: string, attemptId: string): Promise<void>
  cleanupAttemptCrops(context: Context, sessionId: string, attemptId: string): Promise<void>
  cleanupEvidence(context: Context, sessionId: string, evidencePath: string): Promise<void>
}

export class PdfPageImageEncoder implements PdfPageImageEncoderPort {
  open(pdfPath: string): PdfRenderSessionPort {
    return new PdfRenderSession(pdfPath)
  }

  async cleanupSession(context: Context, sessionId: string): Promise<void> {
    await PdfRenderSession.cleanupOwnedCache(context, sessionId)
  }

  async cleanupAttempt(context: Context, sessionId: string, attemptId: string): Promise<void> {
    await PdfRenderSession.cleanupOwnedAttempt(context, sessionId, attemptId)
  }

  async cleanupAttemptCrops(context: Context, sessionId: string, attemptId: string): Promise<void> {
    await PdfRenderSession.cleanupOwnedAttemptCrops(context, sessionId, attemptId)
  }

  async cleanupEvidence(context: Context, sessionId: string,
    evidencePath: string): Promise<void> {
    await PdfRenderSession.cleanupOwnedEvidence(context, sessionId, evidencePath)
  }
}

class StagedEvidenceFile {
  tempPath: string
  finalPath: string
  temporaryCreated: boolean = false
  committed: boolean = false

  constructor(tempPath: string, finalPath: string) {
    this.tempPath = tempPath
    this.finalPath = finalPath
  }
}

class PdfRenderSession implements PdfRenderSessionPort {
  // ~ is excluded by the identifier grammar, so session ownership cannot collide with a longer identifier.
  private static readonly OWNERSHIP_SEPARATOR: string = '~'
  private static readonly ATTEMPT_MARKER: string = 'attempt'
  private static tempSequence: number = 0
  private document: pdfService.PdfDocument = new pdfService.PdfDocument()
  private activeOperations: number = 0
  private closeRequested: boolean = false
  private closed: boolean = false

  constructor(pdfPath: string) {
    try {
      if (this.document.loadDocument(pdfPath) !== pdfService.ParseResult.PARSE_SUCCESS) {
        throw new Error('PDF 页面无法读取')
      }
      const count: number = this.document.getPageCount()
      if (!Number.isSafeInteger(count) || count <= 0) {
        throw new Error('PDF 不包含可识别页面')
      }
    } catch (err) {
      let operationError: string = PdfRenderSession.errorMessage(err, 'PDF 页面无法读取')
      try {
        this.document.releaseDocument()
        this.closed = true
      } catch (releaseErr) {
        operationError = PdfRenderSession.appendDiagnostic(operationError,
          PdfRenderSession.errorMessage(releaseErr, 'PDF 文档资源释放失败'))
      }
      throw new Error(operationError)
    }
  }

  pageCount(): number {
    this.ensureOpen()
    return this.document.getPageCount()
  }

  private static async packBounded(packer: image.ImagePacker,
    pixelMap: image.PixelMap): Promise<Uint8Array> {
    const qualities: Array<number> = JpegQualityPolicy.steps()
    for (let index: number = 0; index < qualities.length; index++) {
      const option: image.PackingOption = {
        format: 'image/jpeg',
        quality: qualities[index],
        bufferSize: AiImportLimits.MAX_JPEG_BYTES + 1
      }
      let output: ArrayBuffer
      try {
        output = await packer.packToData(pixelMap, option)
      } catch (err) {
        if (JpegQualityPolicy.retriesAfterPackError(err.code)) {
          continue
        }
        if (err instanceof Error) {
          throw err
        }
        throw new Error('页面图片编码失败')
      }
      const candidate: Uint8Array = new Uint8Array(output)
      if (JpegQualityPolicy.accepts(candidate.byteLength)) {
        return candidate
      }
      candidate.fill(0)
    }
    throw new Error('页面图片超过识别大小限制')
  }

  async encodePage(context: Context, pageIndex: number, sessionId: string,
    attemptId?: string): Promise<EncodedPdfPage> {
    this.beginOperation()
    const pageNumber: number = pageIndex + 1
    const artifactAttemptId: string = attemptId === undefined ? '' : attemptId
    let staged: StagedEvidenceFile | null = null
    let page: pdfService.PdfPage | null = null
    let pixelMap: image.PixelMap | null = null
    let packer: image.ImagePacker | null = null
    let jpeg: Uint8Array | null = null
    let encodedPage: EncodedPdfPage | null = null
    let operationError: string = ''
    try {
      this.ensurePageIndex(pageIndex)
      PdfRenderSession.validateIdentifier(sessionId)
      PdfRenderSession.validateOptionalAttemptId(artifactAttemptId)
      await PdfRenderSession.validateCacheDirectory(context.cacheDir)
      const finalPath: string = context.cacheDir + '/' +
        PdfRenderSession.pageEvidenceName(sessionId, pageNumber, artifactAttemptId)
      const tempPath: string = PdfRenderSession.createPageTempPath(
        context.cacheDir, sessionId, pageNumber, artifactAttemptId)
      const pageStaging: StagedEvidenceFile = new StagedEvidenceFile(tempPath, finalPath)
      staged = pageStaging
      await PdfRenderSession.ensureDestinationAbsent(pageStaging.finalPath)
      page = this.document.getPage(pageIndex)
      const size: PdfPageOutputSize = PdfPageSizing.calculate(page.getWidth(), page.getHeight())
      const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix()
      matrix.x = 0
      matrix.y = 0
      matrix.width = page.getWidth()
      matrix.height = page.getHeight()
      matrix.rotate = 0
      const pixelOptions: pdfService.PixelOptions = new pdfService.PixelOptions()
      pixelOptions.isGray = false
      pixelOptions.drawAnnotations = true
      pixelOptions.isTransparent = false
      pixelMap = page.getAreaPixelMapWithOptions(matrix, size.width, size.height, pixelOptions)
      packer = image.createImagePacker()
      jpeg = await PdfRenderSession.packBounded(packer, pixelMap)
      await PdfRenderSession.stagePageToFile(context.cacheDir, pageStaging, jpeg)
      const base64: string = await new util.Base64Helper().encodeToString(jpeg, util.Type.BASIC)
      encodedPage = new EncodedPdfPage(pageNumber, size.width, size.height, base64, finalPath)
    } catch (err) {
      operationError = PdfRenderSession.errorMessage(err, 'PDF 页面图像生成失败')
    } finally {
      if (jpeg !== null) {
        jpeg.fill(0)
      }
      if (packer !== null) {
        try {
          await packer.release()
        } catch (releaseErr) {
          operationError = PdfRenderSession.appendDiagnostic(operationError,
            PdfRenderSession.errorMessage(releaseErr, '图像编码器释放失败'))
        }
      }
      if (pixelMap !== null) {
        try {
          await pixelMap.release()
        } catch (releaseErr) {
          operationError = PdfRenderSession.appendDiagnostic(operationError,
            PdfRenderSession.errorMessage(releaseErr, '页面像素资源释放失败'))
        }
      }
      if (page !== null) {
        try {
          page.release()
        } catch (releaseErr) {
          operationError = PdfRenderSession.appendDiagnostic(operationError,
            PdfRenderSession.errorMessage(releaseErr, 'PDF 页面资源释放失败'))
        }
      }
      try {
        this.finishOperation()
      } catch (finishErr) {
        operationError = PdfRenderSession.appendDiagnostic(operationError,
          PdfRenderSession.errorMessage(finishErr, 'PDF 延迟关闭失败'))
      }
    }
    if (operationError.length === 0) {
      if (staged === null || encodedPage === null) {
        operationError = 'PDF 页面图像未生成'
      } else {
        try {
          await PdfRenderSession.commitStagedFile(context.cacheDir, staged)
        } catch (commitErr) {
          operationError = PdfRenderSession.errorMessage(commitErr, '页面证据提交失败')
        }
      }
    }
    if (operationError.length > 0) {
      if (encodedPage !== null) {
        encodedPage.releaseTransientText()
      }
      if (staged !== null && staged.temporaryCreated && !staged.committed) {
        try {
          await PdfRenderSession.cleanupStagedFile(context.cacheDir, staged,
            PdfRenderSession.isOwnedPageTemporary(context.cacheDir, staged.tempPath,
              sessionId, pageNumber, artifactAttemptId))
        } catch (cleanupErr) {
          operationError = PdfRenderSession.appendDiagnostic(operationError,
            PdfRenderSession.errorMessage(cleanupErr, '页面证据临时文件清理失败'))
        }
      }
      throw new Error(operationError)
    }
    if (encodedPage === null) {
      throw new Error('PDF 页面图像未生成')
    }
    return encodedPage
  }

  async cropEvidence(context: Context, pageIndex: number, sessionId: string,
    questionId: string, box: AiBoundingBox, attemptId?: string): Promise<string> {
    this.beginOperation()
    const artifactAttemptId: string = attemptId === undefined ? '' : attemptId
    let staged: StagedEvidenceFile | null = null
    let page: pdfService.PdfPage | null = null
    let operationError: string = ''
    try {
      this.ensurePageIndex(pageIndex)
      PdfRenderSession.validateIdentifier(sessionId)
      PdfRenderSession.validateIdentifier(questionId)
      PdfRenderSession.validateOptionalAttemptId(artifactAttemptId)
      PdfRenderSession.validateBoundingBox(box)
      await PdfRenderSession.validateCacheDirectory(context.cacheDir)
      const finalPath: string = context.cacheDir + '/' +
        PdfRenderSession.cropEvidenceName(sessionId, questionId, artifactAttemptId)
      const tempPath: string = PdfRenderSession.createCropTempPath(
        context.cacheDir, sessionId, questionId, artifactAttemptId)
      const cropStaging: StagedEvidenceFile = new StagedEvidenceFile(tempPath, finalPath)
      staged = cropStaging
      await PdfRenderSession.ensureDestinationAbsent(cropStaging.finalPath)
      page = this.document.getPage(pageIndex)
      const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix()
      matrix.x = page.getWidth() * box.x1 / 1000
      matrix.y = page.getHeight() * (1000 - box.y2) / 1000
      matrix.width = page.getWidth() * (box.x2 - box.x1) / 1000
      matrix.height = page.getHeight() * (box.y2 - box.y1) / 1000
      matrix.rotate = 0
      await PdfRenderSession.stageCropToFile(context.cacheDir, cropStaging, page, matrix)
    } catch (err) {
      operationError = PdfRenderSession.errorMessage(err, '题目证据生成失败')
    } finally {
      if (page !== null) {
        try {
          page.release()
        } catch (releaseErr) {
          operationError = PdfRenderSession.appendDiagnostic(operationError,
            PdfRenderSession.errorMessage(releaseErr, 'PDF 页面资源释放失败'))
        }
      }
      try {
        this.finishOperation()
      } catch (finishErr) {
        operationError = PdfRenderSession.appendDiagnostic(operationError,
          PdfRenderSession.errorMessage(finishErr, 'PDF 延迟关闭失败'))
      }
    }
    if (operationError.length === 0) {
      if (staged === null) {
        operationError = '题目证据未生成'
      } else {
        try {
          await PdfRenderSession.commitStagedFile(context.cacheDir, staged)
        } catch (commitErr) {
          operationError = PdfRenderSession.errorMessage(commitErr, '题目证据提交失败')
        }
      }
    }
    if (operationError.length > 0) {
      if (staged !== null && staged.temporaryCreated && !staged.committed) {
        try {
          await PdfRenderSession.cleanupStagedFile(context.cacheDir, staged,
            PdfRenderSession.isOwnedCropTemporary(context.cacheDir, staged.tempPath,
              sessionId, questionId, artifactAttemptId))
        } catch (cleanupErr) {
          operationError = PdfRenderSession.appendDiagnostic(operationError,
            PdfRenderSession.errorMessage(cleanupErr, '题目证据临时文件清理失败'))
        }
      }
      throw new Error(operationError)
    }
    if (staged === null) {
      throw new Error('题目证据未生成')
    }
    return staged.finalPath
  }

  private beginOperation(): void {
    if (this.closed || this.closeRequested) {
      throw new Error('PDF 渲染会话已关闭')
    }
    this.activeOperations++
  }

  private finishOperation(): void {
    if (this.activeOperations <= 0) {
      throw new Error('PDF 渲染会话资源计数无效')
    }
    this.activeOperations--
    if (this.activeOperations === 0 && this.closeRequested && !this.closed) {
      this.releaseDocumentForClose()
    }
  }

  private releaseDocumentForClose(): void {
    this.document.releaseDocument()
    this.closed = true
  }

  close(): void {
    if (this.closed) {
      return
    }
    this.closeRequested = true
    if (this.activeOperations === 0) {
      this.releaseDocumentForClose()
    }
  }

  static async cleanupOwnedCache(context: Context, sessionId: string): Promise<void> {
    PdfRenderSession.validateIdentifier(sessionId)
    await PdfRenderSession.validateCacheDirectory(context.cacheDir)
    const names: Array<string> = await fs.listFile(context.cacheDir)
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index]
      if (!PdfRenderSession.isOwnedPageName(name, sessionId) &&
        !PdfRenderSession.isOwnedCropName(name, sessionId)) {
        continue
      }
      const path: string = context.cacheDir + '/' + name
      const info: fs.Stat | null = await PdfRenderSession.lstatIfPresent(path)
      if (info === null || info.isSymbolicLink() || !info.isFile()) {
        continue
      }
      await PdfRenderSession.verifyParentIdentity(context.cacheDir, path)
      await PdfRenderSession.unlinkIfPresent(path)
    }
  }

  static async cleanupOwnedAttempt(context: Context, sessionId: string,
    attemptId: string): Promise<void> {
    PdfRenderSession.validateIdentifier(sessionId)
    PdfRenderSession.validateIdentifier(attemptId)
    await PdfRenderSession.validateCacheDirectory(context.cacheDir)
    const names: Array<string> = await fs.listFile(context.cacheDir)
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index]
      if (!PdfRenderSession.isOwnedAttemptPageName(name, sessionId, attemptId) &&
        !PdfRenderSession.isOwnedAttemptCropName(name, sessionId, attemptId)) {
        continue
      }
      const path: string = context.cacheDir + '/' + name
      const info: fs.Stat | null = await PdfRenderSession.lstatIfPresent(path)
      if (info === null || info.isSymbolicLink() || !info.isFile()) {
        continue
      }
      await PdfRenderSession.verifyParentIdentity(context.cacheDir, path)
      await PdfRenderSession.unlinkIfPresent(path)
    }
  }

  static async cleanupOwnedAttemptCrops(context: Context, sessionId: string,
    attemptId: string): Promise<void> {
    PdfRenderSession.validateIdentifier(sessionId)
    PdfRenderSession.validateIdentifier(attemptId)
    await PdfRenderSession.validateCacheDirectory(context.cacheDir)
    const names: Array<string> = await fs.listFile(context.cacheDir)
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index]
      if (!PdfRenderSession.isOwnedAttemptCropName(name, sessionId, attemptId)) {
        continue
      }
      const path: string = context.cacheDir + '/' + name
      const info: fs.Stat | null = await PdfRenderSession.lstatIfPresent(path)
      if (info === null || info.isSymbolicLink() || !info.isFile()) {
        continue
      }
      await PdfRenderSession.verifyParentIdentity(context.cacheDir, path)
      await PdfRenderSession.unlinkIfPresent(path)
    }
  }

  static async cleanupOwnedEvidence(context: Context, sessionId: string,
    evidencePath: string): Promise<void> {
    PdfRenderSession.validateIdentifier(sessionId)
    await PdfRenderSession.validateCacheDirectory(context.cacheDir)
    const name: string = PdfRenderSession.directChildName(context.cacheDir, evidencePath)
    if (name.length === 0 || (!PdfRenderSession.isOwnedPageName(name, sessionId) &&
      !PdfRenderSession.isOwnedCropName(name, sessionId))) {
      throw new Error('证据清理路径所有权无效')
    }
    const info: fs.Stat | null = await PdfRenderSession.lstatIfPresent(evidencePath)
    if (info === null) {
      return
    }
    if (info.isSymbolicLink() || !info.isFile()) {
      throw new Error('证据清理目标不是普通文件')
    }
    await PdfRenderSession.verifyParentIdentity(context.cacheDir, evidencePath)
    await PdfRenderSession.unlinkIfPresent(evidencePath)
  }

  private ensureOpen(): void {
    if (this.closed || this.closeRequested) {
      throw new Error('PDF 渲染会话已关闭')
    }
  }

  private ensurePageIndex(pageIndex: number): void {
    const count: number = this.document.getPageCount()
    if (!Number.isSafeInteger(pageIndex) || pageIndex < 0 || pageIndex >= count) {
      throw new Error('PDF 页码无效')
    }
  }

  private static validateIdentifier(value: string): void {
    if (!/^[A-Za-z0-9._:-]{1,160}$/.test(value)) {
      throw new Error('AI 导入会话标识无效')
    }
  }

  private static validateOptionalAttemptId(attemptId: string): void {
    if (attemptId.length > 0) {
      PdfRenderSession.validateIdentifier(attemptId)
    }
  }

  private static validateBoundingBox(box: AiBoundingBox): void {
    if (!Number.isFinite(box.x1) || !Number.isFinite(box.y1) || !Number.isFinite(box.x2) ||
      !Number.isFinite(box.y2) || box.x1 < 0 || box.y1 < 0 || box.x2 > 1000 || box.y2 > 1000 ||
      box.x2 <= box.x1 || box.y2 <= box.y1) {
      throw new Error('题目证据区域无效')
    }
  }

  private static async stagePageToFile(cacheDir: string, staged: StagedEvidenceFile,
    bytes: Uint8Array): Promise<void> {
    if (!JpegQualityPolicy.accepts(bytes.byteLength) ||
      PdfRenderSession.directChildName(cacheDir, staged.tempPath).length === 0) {
      throw new Error('页面证据临时文件无效')
    }
    const existingTemporary: fs.Stat | null = await PdfRenderSession.lstatIfPresent(staged.tempPath)
    if (existingTemporary !== null) {
      throw new Error('页面证据临时文件已存在')
    }
    let file: fs.File | null = null
    let operationError: string = ''
    try {
      file = await fs.open(staged.tempPath,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW)
      staged.temporaryCreated = true
      let written: number = 0
      while (written < bytes.byteLength) {
        const remaining: Uint8Array = bytes.slice(written)
        let currentWrite: number = 0
        try {
          currentWrite = await fs.write(file.fd, remaining.buffer)
        } finally {
          remaining.fill(0)
        }
        if (!Number.isSafeInteger(currentWrite) || currentWrite <= 0 ||
          currentWrite > remaining.byteLength) {
          throw new Error('页面证据写入失败')
        }
        written += currentWrite
      }
      await fs.fsync(file.fd)
    } catch (err) {
      operationError = PdfRenderSession.errorMessage(err, '页面证据写入失败')
    } finally {
      if (file !== null) {
        try {
          await fs.close(file)
        } catch (closeErr) {
          operationError = PdfRenderSession.appendDiagnostic(operationError,
            PdfRenderSession.errorMessage(closeErr, '页面证据临时文件关闭失败'))
        }
      }
    }
    if (operationError.length > 0) {
      throw new Error(operationError)
    }
    const info: fs.Stat = await fs.lstat(staged.tempPath)
    if (info.isSymbolicLink() || !info.isFile() || info.size !== bytes.byteLength) {
      throw new Error('页面证据临时文件校验失败')
    }
    await PdfRenderSession.verifyParentIdentity(cacheDir, staged.tempPath)
  }

  private static async stageCropToFile(cacheDir: string, staged: StagedEvidenceFile,
    page: pdfService.PdfPage, matrix: pdfService.PdfMatrix): Promise<void> {
    if (PdfRenderSession.directChildName(cacheDir, staged.tempPath).length === 0) {
      throw new Error('题目证据临时文件无效')
    }
    const existingTemporary: fs.Stat | null = await PdfRenderSession.lstatIfPresent(staged.tempPath)
    if (existingTemporary !== null) {
      throw new Error('题目证据临时文件已存在')
    }
    const outputSize: PdfPageOutputSize = PdfPageSizing.calculate(matrix.width, matrix.height)
    const pixelOptions: pdfService.PixelOptions = new pdfService.PixelOptions()
    pixelOptions.isGray = false
    pixelOptions.drawAnnotations = true
    pixelOptions.isTransparent = false
    let cropPixelMap: image.PixelMap | null = null
    let packer: image.ImagePacker | null = null
    let temporaryFile: fs.File | null = null
    let operationError: string = ''
    try {
      cropPixelMap = page.getAreaPixelMapWithOptions(
        matrix, outputSize.width, outputSize.height, pixelOptions)
      packer = image.createImagePacker()
      temporaryFile = await fs.open(staged.tempPath,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW)
      staged.temporaryCreated = true
      const packingOption: image.PackingOption = {
        format: 'image/jpeg',
        quality: 82
      }
      await packer.packToFile(cropPixelMap, temporaryFile.fd, packingOption)
      await fs.fsync(temporaryFile.fd)
    } catch (err) {
      operationError = PdfRenderSession.errorMessage(err, '题目证据生成失败')
    } finally {
      if (temporaryFile !== null) {
        const fileToClose: fs.File = temporaryFile
        temporaryFile = null
        try {
          await fs.close(fileToClose)
        } catch (closeErr) {
          operationError = PdfRenderSession.appendDiagnostic(operationError,
            PdfRenderSession.errorMessage(closeErr, '题目证据文件关闭失败'))
        }
      }
      if (packer !== null) {
        try {
          await packer.release()
        } catch (releaseErr) {
          operationError = PdfRenderSession.appendDiagnostic(operationError,
            PdfRenderSession.errorMessage(releaseErr, '题目证据编码器释放失败'))
        }
      }
      if (cropPixelMap !== null) {
        try {
          await cropPixelMap.release()
        } catch (releaseErr) {
          operationError = PdfRenderSession.appendDiagnostic(operationError,
            PdfRenderSession.errorMessage(releaseErr, '题目证据像素资源释放失败'))
        }
      }
    }
    if (operationError.length > 0) {
      throw new Error(operationError)
    }
    const temporaryInfo: fs.Stat = await fs.lstat(staged.tempPath)
    if (temporaryInfo.isSymbolicLink() || !temporaryInfo.isFile() || temporaryInfo.size <= 0) {
      throw new Error('题目证据临时文件校验失败')
    }
    await PdfRenderSession.verifyParentIdentity(cacheDir, staged.tempPath)
  }

  private static async commitStagedFile(cacheDir: string, staged: StagedEvidenceFile): Promise<void> {
    if (!staged.temporaryCreated || staged.committed) {
      throw new Error('证据文件暂存状态无效')
    }
    await PdfRenderSession.verifyParentIdentity(cacheDir, staged.tempPath)
    await PdfRenderSession.verifyParentIdentity(cacheDir, staged.finalPath)
    const temporaryInfo: fs.Stat = await fs.lstat(staged.tempPath)
    if (temporaryInfo.isSymbolicLink() || !temporaryInfo.isFile() || temporaryInfo.size <= 0) {
      throw new Error('证据临时文件类型无效')
    }
    const existingFinal: fs.Stat | null = await PdfRenderSession.lstatIfPresent(staged.finalPath)
    if (existingFinal !== null) {
      throw new Error('证据目标文件已存在')
    }
    await fs.moveFile(staged.tempPath, staged.finalPath, 1)
    staged.committed = true
  }

  private static async cleanupStagedFile(cacheDir: string, staged: StagedEvidenceFile,
    ownedTemporary: boolean): Promise<void> {
    if (!staged.temporaryCreated || staged.committed) {
      return
    }
    if (!ownedTemporary) {
      throw new Error('证据临时文件所有权无效')
    }
    await PdfRenderSession.removeOwnedOrdinaryFile(cacheDir, staged.tempPath)
  }

  private static createPageTempPath(cacheDir: string, sessionId: string, pageNumber: number,
    attemptId: string = ''): string {
    PdfRenderSession.validateIdentifier(sessionId)
    PdfRenderSession.validateOptionalAttemptId(attemptId)
    if (!Number.isSafeInteger(pageNumber) || pageNumber <= 0) {
      throw new Error('PDF 页码无效')
    }
    const sequence: number = PdfRenderSession.nextTempSequence()
    const baseName: string = PdfRenderSession.pageEvidenceName(sessionId, pageNumber, attemptId)
    return cacheDir + '/' + baseName.substring(0, baseName.length - '.jpg'.length) +
      PdfRenderSession.OWNERSHIP_SEPARATOR + 'tmp' +
      PdfRenderSession.OWNERSHIP_SEPARATOR + Date.now().toString() +
      PdfRenderSession.OWNERSHIP_SEPARATOR + sequence.toString() + '.jpg'
  }

  private static createCropTempPath(cacheDir: string, sessionId: string, questionId: string,
    attemptId: string = ''): string {
    PdfRenderSession.validateIdentifier(sessionId)
    PdfRenderSession.validateIdentifier(questionId)
    PdfRenderSession.validateOptionalAttemptId(attemptId)
    const sequence: number = PdfRenderSession.nextTempSequence()
    const baseName: string = PdfRenderSession.cropEvidenceName(sessionId, questionId, attemptId)
    return cacheDir + '/' + baseName.substring(0, baseName.length - '.jpg'.length) +
      PdfRenderSession.OWNERSHIP_SEPARATOR + 'tmp' + PdfRenderSession.OWNERSHIP_SEPARATOR +
      Date.now().toString() + PdfRenderSession.OWNERSHIP_SEPARATOR + sequence.toString() + '.jpg'
  }

  private static nextTempSequence(): number {
    PdfRenderSession.tempSequence++
    if (!Number.isSafeInteger(PdfRenderSession.tempSequence) || PdfRenderSession.tempSequence > 999999999) {
      PdfRenderSession.tempSequence = 1
    }
    return PdfRenderSession.tempSequence
  }

  private static pageEvidenceName(sessionId: string, pageNumber: number,
    attemptId: string = ''): string {
    PdfRenderSession.validateIdentifier(sessionId)
    PdfRenderSession.validateOptionalAttemptId(attemptId)
    if (!Number.isSafeInteger(pageNumber) || pageNumber <= 0) {
      throw new Error('PDF 页码无效')
    }
    if (attemptId.length > 0) {
      return 'ai_import_page_' + sessionId + PdfRenderSession.OWNERSHIP_SEPARATOR +
        PdfRenderSession.ATTEMPT_MARKER + PdfRenderSession.OWNERSHIP_SEPARATOR + attemptId +
        PdfRenderSession.OWNERSHIP_SEPARATOR + pageNumber.toString() + '.jpg'
    }
    return 'ai_import_page_' + sessionId + PdfRenderSession.OWNERSHIP_SEPARATOR +
      pageNumber.toString() + '.jpg'
  }

  private static cropEvidenceName(sessionId: string, questionId: string,
    attemptId: string = ''): string {
    PdfRenderSession.validateIdentifier(sessionId)
    PdfRenderSession.validateIdentifier(questionId)
    PdfRenderSession.validateOptionalAttemptId(attemptId)
    if (attemptId.length > 0) {
      return 'ai_import_crop_' + sessionId + PdfRenderSession.OWNERSHIP_SEPARATOR +
        PdfRenderSession.ATTEMPT_MARKER + PdfRenderSession.OWNERSHIP_SEPARATOR + attemptId +
        PdfRenderSession.OWNERSHIP_SEPARATOR + questionId + '.jpg'
    }
    return 'ai_import_crop_' + sessionId + PdfRenderSession.OWNERSHIP_SEPARATOR + questionId + '.jpg'
  }

  private static isOwnedPageName(name: string, sessionId: string): boolean {
    PdfRenderSession.validateIdentifier(sessionId)
    const pagePrefix: string = 'ai_import_page_' + sessionId + PdfRenderSession.OWNERSHIP_SEPARATOR
    if (!name.startsWith(pagePrefix)) {
      return false
    }
    const suffix: string = name.substring(pagePrefix.length)
    return /^[1-9][0-9]*\.jpg$/.test(suffix) ||
      /^[1-9][0-9]*~tmp~[0-9]+~[1-9][0-9]*\.jpg$/.test(suffix) ||
      /^attempt~[A-Za-z0-9._:-]{1,160}~[1-9][0-9]*\.jpg$/.test(suffix) ||
      /^attempt~[A-Za-z0-9._:-]{1,160}~[1-9][0-9]*~tmp~[0-9]+~[1-9][0-9]*\.jpg$/.test(suffix)
  }

  private static isOwnedCropName(name: string, sessionId: string): boolean {
    PdfRenderSession.validateIdentifier(sessionId)
    const cropPrefix: string = 'ai_import_crop_' + sessionId + PdfRenderSession.OWNERSHIP_SEPARATOR
    if (!name.startsWith(cropPrefix)) {
      return false
    }
    const suffix: string = name.substring(cropPrefix.length)
    return /^[A-Za-z0-9._:-]{1,160}\.jpg$/.test(suffix) ||
      /^[A-Za-z0-9._:-]{1,160}~tmp~[0-9]+~[1-9][0-9]*\.jpg$/.test(suffix) ||
      /^attempt~[A-Za-z0-9._:-]{1,160}~[A-Za-z0-9._:-]{1,160}\.jpg$/.test(suffix) ||
      /^attempt~[A-Za-z0-9._:-]{1,160}~[A-Za-z0-9._:-]{1,160}~tmp~[0-9]+~[1-9][0-9]*\.jpg$/.test(suffix)
  }

  private static isOwnedPageTemporary(cacheDir: string, path: string,
    sessionId: string, pageNumber: number, attemptId: string = ''): boolean {
    PdfRenderSession.validateIdentifier(sessionId)
    PdfRenderSession.validateOptionalAttemptId(attemptId)
    const finalName: string = PdfRenderSession.pageEvidenceName(sessionId, pageNumber, attemptId)
    const prefix: string = finalName.substring(0, finalName.length - '.jpg'.length) +
      PdfRenderSession.OWNERSHIP_SEPARATOR + 'tmp' + PdfRenderSession.OWNERSHIP_SEPARATOR
    const name: string = PdfRenderSession.directChildName(cacheDir, path)
    if (!name.startsWith(prefix)) {
      return false
    }
    const suffix: string = name.substring(prefix.length)
    return /^[0-9]+~[1-9][0-9]*\.jpg$/.test(suffix)
  }

  private static isOwnedCropTemporary(cacheDir: string, path: string,
    sessionId: string, questionId: string, attemptId: string = ''): boolean {
    PdfRenderSession.validateIdentifier(sessionId)
    PdfRenderSession.validateIdentifier(questionId)
    PdfRenderSession.validateOptionalAttemptId(attemptId)
    const finalName: string = PdfRenderSession.cropEvidenceName(sessionId, questionId, attemptId)
    const prefix: string = finalName.substring(0, finalName.length - '.jpg'.length) +
      PdfRenderSession.OWNERSHIP_SEPARATOR + 'tmp' + PdfRenderSession.OWNERSHIP_SEPARATOR
    const name: string = PdfRenderSession.directChildName(cacheDir, path)
    if (!name.startsWith(prefix)) {
      return false
    }
    const suffix: string = name.substring(prefix.length)
    return /^[0-9]+~[1-9][0-9]*\.jpg$/.test(suffix)
  }

  private static isOwnedAttemptPageName(name: string, sessionId: string,
    attemptId: string): boolean {
    PdfRenderSession.validateIdentifier(sessionId)
    PdfRenderSession.validateIdentifier(attemptId)
    const prefix: string = 'ai_import_page_' + sessionId + PdfRenderSession.OWNERSHIP_SEPARATOR +
      PdfRenderSession.ATTEMPT_MARKER + PdfRenderSession.OWNERSHIP_SEPARATOR + attemptId +
      PdfRenderSession.OWNERSHIP_SEPARATOR
    if (!name.startsWith(prefix)) {
      return false
    }
    const suffix: string = name.substring(prefix.length)
    return /^[1-9][0-9]*\.jpg$/.test(suffix) ||
      /^[1-9][0-9]*~tmp~[0-9]+~[1-9][0-9]*\.jpg$/.test(suffix)
  }

  private static isOwnedAttemptCropName(name: string, sessionId: string,
    attemptId: string): boolean {
    PdfRenderSession.validateIdentifier(sessionId)
    PdfRenderSession.validateIdentifier(attemptId)
    const prefix: string = 'ai_import_crop_' + sessionId + PdfRenderSession.OWNERSHIP_SEPARATOR +
      PdfRenderSession.ATTEMPT_MARKER + PdfRenderSession.OWNERSHIP_SEPARATOR + attemptId +
      PdfRenderSession.OWNERSHIP_SEPARATOR
    if (!name.startsWith(prefix)) {
      return false
    }
    const suffix: string = name.substring(prefix.length)
    return /^[A-Za-z0-9._:-]{1,160}\.jpg$/.test(suffix) ||
      /^[A-Za-z0-9._:-]{1,160}~tmp~[0-9]+~[1-9][0-9]*\.jpg$/.test(suffix)
  }

  private static async ensureDestinationAbsent(path: string): Promise<void> {
    const existing: fs.Stat | null = await PdfRenderSession.lstatIfPresent(path)
    if (existing !== null) {
      throw new Error('证据目标文件已存在')
    }
  }

  private static async removeOwnedOrdinaryFile(cacheDir: string, path: string): Promise<void> {
    if (PdfRenderSession.directChildName(cacheDir, path).length === 0) {
      throw new Error('缓存清理路径无效')
    }
    await PdfRenderSession.verifyParentIdentity(cacheDir, path)
    const info: fs.Stat | null = await PdfRenderSession.lstatIfPresent(path)
    if (info === null) {
      return
    }
    if (info.isSymbolicLink() || !info.isFile()) {
      throw new Error('缓存清理目标不是普通文件')
    }
    await PdfRenderSession.unlinkIfPresent(path)
  }

  private static async validateCacheDirectory(path: string): Promise<void> {
    const info: fs.Stat | null = await PdfRenderSession.lstatIfPresent(path)
    if (info === null || info.isSymbolicLink() || !info.isDirectory()) {
      throw new Error('AI 导入缓存目录无效')
    }
  }

  private static directChildName(cacheDir: string, path: string): string {
    const prefix: string = cacheDir + '/'
    if (!path.startsWith(prefix) || path.indexOf('\\') >= 0 ||
      path.indexOf(String.fromCharCode(0)) >= 0) {
      return ''
    }
    const name: string = path.substring(prefix.length)
    if (name.length === 0 || name.indexOf('/') >= 0 || name === '.' || name === '..') {
      return ''
    }
    return name
  }

  private static async verifyParentIdentity(cacheDir: string, path: string): Promise<void> {
    const childName: string = PdfRenderSession.directChildName(cacheDir, path)
    if (childName.length === 0) {
      throw new Error('缓存清理路径无效')
    }
    const candidateParent: string = path.substring(0, path.length - childName.length - 1)
    const cacheLinkInfo: fs.Stat = await fs.lstat(cacheDir)
    const cacheInfo: fs.Stat = await fs.stat(cacheDir)
    const candidateParentLinkInfo: fs.Stat = await fs.lstat(candidateParent)
    const candidateParentInfo: fs.Stat = await fs.stat(candidateParent)
    if (cacheLinkInfo.isSymbolicLink() || !cacheLinkInfo.isDirectory() || !cacheInfo.isDirectory() ||
      candidateParentLinkInfo.isSymbolicLink() || !candidateParentLinkInfo.isDirectory() ||
      !candidateParentInfo.isDirectory() || cacheLinkInfo.ino !== cacheInfo.ino ||
      candidateParentLinkInfo.ino !== candidateParentInfo.ino || cacheInfo.ino !== candidateParentInfo.ino) {
      throw new Error('缓存清理父目录身份无效')
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
          reject(new Error(PdfRenderSession.errorMessage(err, '文件状态读取失败')))
          return
        }
        resolve(info)
      })
    })
  }

  private static async unlinkIfPresent(path: string): Promise<void> {
    return new Promise<void>((resolve, reject): void => {
      fs.unlink(path, (err: BusinessError): void => {
        if (err) {
          if (err.code === 13900002) {
            resolve()
            return
          }
          reject(new Error(PdfRenderSession.errorMessage(err, '文件删除失败')))
          return
        }
        resolve()
      })
    })
  }

  private static appendDiagnostic(primary: string, diagnostic: string): string {
    return primary.length > 0 ? primary + '；' + diagnostic : diagnostic
  }

  private static errorMessage(err: Error, fallback: string): string {
    return err instanceof Error && err.message.length > 0 ? err.message : fallback
  }
}
