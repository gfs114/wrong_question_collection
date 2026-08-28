import { Context } from '@kit.AbilityKit'
import { pdfService } from '@kit.PDFKit'
import { image } from '@kit.ImageKit'
import { PdfImportLimits } from '../constants/PdfImportLimits'
import {
  OcrPage,
  PageCrop,
  PdfFileSelection,
  PdfImportProgress,
  PdfImportSettings,
  PdfPageFailure,
  PdfPageRangeValidation,
  PdfQuestionDraft
} from '../models/PdfImportModels'
import { PdfImportValidator } from '../utils/PdfImportValidator'
import { PdfSuccessfulPageParser } from '../utils/PdfSuccessfulPageParser'
import { OnDeviceOcrService } from './OnDeviceOcrService'
import { QuestionImageService } from './QuestionImageService'
import { PdfStorageError } from './PdfStorageError'

export type PdfImportProgressCallback = (progress: PdfImportProgress) => void
export type PdfImportCancellationCheck = () => boolean

export class PdfImportRunResult {
  drafts: Array<PdfQuestionDraft>
  failures: Array<PdfPageFailure>

  constructor(drafts: Array<PdfQuestionDraft>, failures: Array<PdfPageFailure>) {
    this.drafts = drafts.slice()
    this.failures = failures.slice()
  }
}

export class PdfImportCancelledError extends Error {
  constructor(message: string = 'PDF 导入已取消') {
    super(message)
  }
}

export class PdfImportCleanupError extends Error {
  readonly paths: Array<string>

  constructor(message: string, paths: Array<string>) {
    super(message)
    this.paths = paths.slice()
  }
}

export class PdfImportCancelledCleanupError extends PdfImportCancelledError {
  readonly paths: Array<string>

  constructor(message: string, paths: Array<string>) {
    super(message)
    this.paths = paths.slice()
  }
}

class PdfImportResourceError extends Error {
  constructor(message: string) {
    super(message)
  }
}

class RenderedPageInfo {
  pageNumber: number
  imageInfo: image.ImageInfo

  constructor(pageNumber: number, imageInfo: image.ImageInfo) {
    this.pageNumber = pageNumber
    this.imageInfo = imageInfo
  }
}

class CropJob {
  draftIndex: number
  cropIndex: number
  crop: PageCrop
  path: string

  constructor(draftIndex: number, cropIndex: number, crop: PageCrop) {
    this.draftIndex = draftIndex
    this.cropIndex = cropIndex
    this.crop = crop
    this.path = ''
  }
}

class PdfImportInputSnapshot {
  uri: string
  pageCount: number
  startPage: number
  endPage: number

  constructor(selection: PdfFileSelection, settings: PdfImportSettings) {
    this.uri = selection.uri
    this.pageCount = selection.pageCount
    this.startPage = settings.startPage
    this.endPage = settings.endPage
  }
}

export class PdfImportCoordinator {
  private static taskSequence: number = 0
  private static runInProgress: boolean = false

  static async run(context: Context, selection: PdfFileSelection, settings: PdfImportSettings,
    progressCallback: PdfImportProgressCallback,
    isCancelled: PdfImportCancellationCheck): Promise<PdfImportRunResult> {
    if (PdfImportCoordinator.runInProgress) {
      throw new Error('已有 PDF 导入任务正在运行')
    }
    PdfImportCoordinator.runInProgress = true
    try {
      const snapshot: PdfImportInputSnapshot = new PdfImportInputSnapshot(selection, settings)
      return await PdfImportCoordinator.runSnapshot(context, snapshot, progressCallback, isCancelled)
    } finally {
      PdfImportCoordinator.runInProgress = false
    }
  }

  private static async runSnapshot(context: Context, snapshot: PdfImportInputSnapshot,
    progressCallback: PdfImportProgressCallback,
    isCancelled: PdfImportCancellationCheck): Promise<PdfImportRunResult> {
    const validation: PdfPageRangeValidation = PdfImportValidator.validatePageRange(
      snapshot.startPage, snapshot.endPage, snapshot.pageCount)
    if (!validation.valid) {
      throw new Error(validation.message)
    }
    const totalPages: number = validation.selectedPageCount
    const pdfDocument: pdfService.PdfDocument = new pdfService.PdfDocument()
    const ocrService: OnDeviceOcrService = OnDeviceOcrService.shared()
    const ocrPages: Array<OcrPage> = new Array<OcrPage>()
    const renderedPageInfos: Array<RenderedPageInfo> = new Array<RenderedPageInfo>()
    const failures: Array<PdfPageFailure> = new Array<PdfPageFailure>()
    const createdPaths: Array<string> = new Array<string>()
    const cleanupFailures: Array<string> = new Array<string>()
    let ocrInitialized: boolean = false
    let processingSucceeded: boolean = false
    let resultReady: boolean = false
    let result: PdfImportRunResult | null = null
    let primaryError: Error | null = null
    let createdPathCleanupFailed: boolean = false
    try {
      PdfImportCoordinator.throwIfCancelled(isCancelled)
      progressCallback(new PdfImportProgress('opening', 0, totalPages, 0, 0, '正在打开 PDF'))
      PdfImportCoordinator.throwIfCancelled(isCancelled)
      if (pdfDocument.isEncrypted(snapshot.uri)) {
        throw new Error('不支持加密 PDF')
      }
      const parseResult: pdfService.ParseResult = pdfDocument.loadDocument(snapshot.uri)
      PdfImportCoordinator.throwIfCancelled(isCancelled)
      if (parseResult !== pdfService.ParseResult.PARSE_SUCCESS) {
        throw new Error('PDF 文件无法解析')
      }
      if (pdfDocument.getPageCount() !== snapshot.pageCount) {
        throw new Error('PDF 页数与选择时不一致')
      }
      await ocrService.initialize()
      ocrInitialized = true
      PdfImportCoordinator.throwIfCancelled(isCancelled)
      let processedPageCount: number = 0
      for (let pageNumber: number = snapshot.startPage; pageNumber <= snapshot.endPage; pageNumber++) {
        PdfImportCoordinator.throwIfCancelled(isCancelled)
        progressCallback(new PdfImportProgress('recognizing', pageNumber, totalPages, processedPageCount,
          0, '正在识别第 ' + pageNumber.toString() + ' 页'))
        PdfImportCoordinator.throwIfCancelled(isCancelled)
        let page: pdfService.PdfPage | null = null
        let fullPixelMap: image.PixelMap | null = null
        let candidatePage: OcrPage | null = null
        let candidateInfo: image.ImageInfo | null = null
        let pageFailureMessage: string = ''
        let cancellationMessage: string = ''
        let resourceFailureMessage: string = ''
        let resourceFatalError: Error | null = null
        try {
          page = pdfDocument.getPage(pageNumber - 1)
          fullPixelMap = await PdfImportCoordinator.renderOcrPixelMap(page)
          PdfImportCoordinator.throwIfCancelled(isCancelled)
          const fullImageInfo: image.ImageInfo = await fullPixelMap.getImageInfo()
          PdfImportCoordinator.validateImageInfo(fullImageInfo)
          PdfImportCoordinator.throwIfCancelled(isCancelled)
          const lines = await ocrService.recognize(fullPixelMap, pageNumber)
          PdfImportCoordinator.throwIfCancelled(isCancelled)
          candidatePage = new OcrPage(pageNumber, fullImageInfo.size.width, fullImageInfo.size.height, lines)
          candidateInfo = fullImageInfo
        } catch (pageErr) {
          if (pageErr instanceof PdfImportResourceError) {
            resourceFailureMessage = PdfImportCoordinator.appendDiagnostic(resourceFailureMessage, pageErr.message)
          } else if (pageErr instanceof PdfImportCancelledError) {
            cancellationMessage = pageErr.message
          } else {
            pageFailureMessage = PdfImportCoordinator.errorMessage(pageErr, '页面识别失败')
          }
        } finally {
          if (fullPixelMap !== null) {
            const pixelMapToRelease: image.PixelMap = fullPixelMap
            fullPixelMap = null
            try {
              await pixelMapToRelease.release()
            } catch (releaseErr) {
              const diagnostic: string = PdfImportCoordinator.errorMessage(releaseErr, '完整页面图像释放失败')
              resourceFailureMessage = PdfImportCoordinator.appendDiagnostic(resourceFailureMessage, diagnostic)
            }
          }
          if (page !== null) {
            const pageToRelease: pdfService.PdfPage = page
            page = null
            try {
              pageToRelease.release()
            } catch (releaseErr) {
              const diagnostic: string = PdfImportCoordinator.errorMessage(releaseErr, 'PDF 页面释放失败')
              resourceFailureMessage = PdfImportCoordinator.appendDiagnostic(resourceFailureMessage, diagnostic)
            }
          }
        }
        if (resourceFailureMessage.length > 0) {
          resourceFatalError = new Error(resourceFailureMessage)
        }
        if (resourceFatalError !== null) {
          let resourceMessage: string = resourceFatalError.message
          if (cancellationMessage.length > 0) {
            resourceMessage = PdfImportCoordinator.appendDiagnostic(cancellationMessage, resourceMessage)
            throw new PdfImportCancelledError(resourceMessage)
          }
          resourceMessage = PdfImportCoordinator.appendDiagnostic(pageFailureMessage, resourceMessage)
          resourceFatalError = new Error(resourceMessage)
          throw resourceFatalError
        }
        if (cancellationMessage.length > 0) {
          throw new PdfImportCancelledError(cancellationMessage)
        }
        if (pageFailureMessage.length > 0 || candidatePage === null || candidateInfo === null) {
          const message: string = pageFailureMessage.length > 0 ? pageFailureMessage : '页面识别结果不完整'
          failures.push(new PdfPageFailure(pageNumber, '第 ' + pageNumber.toString() + ' 页识别失败：' + message))
        } else {
          ocrPages.push(candidatePage)
          renderedPageInfos.push(new RenderedPageInfo(pageNumber, candidateInfo))
        }
        processedPageCount++
        progressCallback(new PdfImportProgress('recognizing', pageNumber, totalPages, processedPageCount,
          0, '已处理第 ' + pageNumber.toString() + ' 页'))
      }
      PdfImportCoordinator.throwIfCancelled(isCancelled)
      if (ocrPages.length === 0 && failures.length > 0) {
        throw new Error('所选页面均识别失败')
      }
      const drafts: Array<PdfQuestionDraft> = PdfSuccessfulPageParser.parse(
        ocrPages, snapshot.startPage, snapshot.endPage)
      if (drafts.length === 0 && failures.length > 0) {
        throw new Error('所选页面均识别失败')
      }
      const cropJobs: Array<CropJob> = PdfImportCoordinator.createCropJobs(drafts)
      progressCallback(new PdfImportProgress('cropping', 0, totalPages, processedPageCount, drafts.length,
        '正在生成题目图片'))
      let cropError: Error | null = null
      let cropCleanupError: string = ''
      const taskId: string = PdfImportCoordinator.createTaskId()
      try {
        let jobIndex: number = 0
        while (jobIndex < cropJobs.length && cropCleanupError.length === 0) {
          PdfImportCoordinator.throwIfCancelled(isCancelled)
          const cropPageNumber: number = cropJobs[jobIndex].crop.pageNumber
          let cropPage: pdfService.PdfPage | null = null
          try {
            const activeCropPage: pdfService.PdfPage = pdfDocument.getPage(cropPageNumber - 1)
            cropPage = activeCropPage
            while (jobIndex < cropJobs.length && cropJobs[jobIndex].crop.pageNumber === cropPageNumber) {
              PdfImportCoordinator.throwIfCancelled(isCancelled)
              const job: CropJob = cropJobs[jobIndex]
              const pageInfo: image.ImageInfo | null = PdfImportCoordinator.findPageInfo(
                renderedPageInfos, job.crop.pageNumber)
              if (pageInfo === null) {
                throw new Error('缺少第 ' + job.crop.pageNumber.toString() + ' 页的渲染信息')
              }
              progressCallback(new PdfImportProgress('cropping', job.crop.pageNumber, totalPages, processedPageCount,
                drafts.length, '正在生成第 ' + job.crop.pageNumber.toString() + ' 页题图'))
              const draft: PdfQuestionDraft = drafts[job.draftIndex]
              const path: string = await QuestionImageService.saveCrop(context, activeCropPage, pageInfo, job.crop,
                taskId, draft.localId, job.cropIndex)
              job.path = path
              createdPaths.push(path)
              jobIndex++
              PdfImportCoordinator.throwIfCancelled(isCancelled)
            }
          } finally {
            if (cropPage !== null) {
              try {
                const pageToRelease: pdfService.PdfPage = cropPage
                cropPage = null
                pageToRelease.release()
              } catch (releaseErr) {
                cropCleanupError = PdfImportCoordinator.appendDiagnostic(cropCleanupError,
                  PdfImportCoordinator.errorMessage(releaseErr, '裁剪页面释放失败'))
              }
            }
          }
        }
      } catch (cropErr) {
        cropError = PdfImportCoordinator.toError(cropErr, '题图生成失败')
      }
      if (cropError !== null || cropCleanupError.length > 0) {
        const cropMessage: string = cropError !== null ? cropError.message : '题图生成资源释放失败'
        const combinedMessage: string = PdfImportCoordinator.appendDiagnostic(cropMessage, cropCleanupError)
      if (cropError instanceof PdfImportCancelledError) {
        throw new PdfImportCancelledError(combinedMessage)
      }
      if (cropError instanceof PdfStorageError) {
        const storageDiagnostic: string = cropError.diagnostic.length > 0 ?
          cropError.diagnostic : '题图生成失败'
        const mergedDiagnostic: string =
          PdfImportCoordinator.appendDiagnostic(storageDiagnostic, cropCleanupError)
        throw new PdfStorageError(mergedDiagnostic)
      }
        throw new Error(combinedMessage)
      }
      PdfImportCoordinator.appendCropPaths(drafts, cropJobs)
      PdfImportCoordinator.throwIfCancelled(isCancelled)
      result = new PdfImportRunResult(drafts, failures)
      processingSucceeded = true
      resultReady = true
    } catch (err) {
      primaryError = PdfImportCoordinator.toError(err, 'PDF 导入失败')
    } finally {
      if (ocrInitialized) {
        try {
          await ocrService.release()
        } catch (releaseErr) {
          cleanupFailures.push(PdfImportCoordinator.errorMessage(releaseErr, '文字识别服务释放失败'))
        }
      }
      try {
        pdfDocument.releaseDocument()
      } catch (releaseErr) {
        cleanupFailures.push(PdfImportCoordinator.errorMessage(releaseErr, 'PDF 文档释放失败'))
      }
      if (!processingSucceeded || cleanupFailures.length > 0) {
        try {
          await QuestionImageService.deletePaths(context, createdPaths)
        } catch (cleanupErr) {
          createdPathCleanupFailed = true
          cleanupFailures.push(PdfImportCoordinator.errorMessage(cleanupErr, '题图缓存清理失败'))
        }
      }
    }
    if (primaryError !== null || cleanupFailures.length > 0) {
      let message: string = primaryError !== null ? primaryError.message : 'PDF 导入资源清理失败'
      if (cleanupFailures.length > 0) {
        message = PdfImportCoordinator.appendDiagnostic(message, cleanupFailures.join('；'))
      }
      if (createdPathCleanupFailed) {
        if (primaryError instanceof PdfImportCancelledError) {
          throw new PdfImportCancelledCleanupError(message, createdPaths)
        }
        throw new PdfImportCleanupError(message, createdPaths)
      }
      if (primaryError instanceof PdfImportCancelledError) {
        throw new PdfImportCancelledError(message)
      }
      if (primaryError instanceof PdfStorageError) {
        throw new PdfStorageError(primaryError.diagnostic)
      }
      throw new Error(message)
    }
    if (!resultReady || result === null) {
      throw new Error('PDF 导入未生成结果')
    }
    try {
      PdfImportCoordinator.throwIfCancelled(isCancelled)
      progressCallback(new PdfImportProgress('complete', snapshot.endPage, totalPages, totalPages,
        result.drafts.length, 'PDF 识别完成'))
    } catch (progressErr) {
      const completionError: Error = PdfImportCoordinator.toError(progressErr, 'PDF 完成进度通知失败')
      let completionCleanupError: string = ''
      let completionCleanupFailed: boolean = false
      try {
        await QuestionImageService.deletePaths(context, createdPaths)
      } catch (cleanupErr) {
        completionCleanupFailed = true
        completionCleanupError = PdfImportCoordinator.errorMessage(cleanupErr, '题图缓存清理失败')
      }
      const completionMessage: string = PdfImportCoordinator.appendDiagnostic(
        completionError.message, completionCleanupError)
      if (completionCleanupFailed) {
        if (completionError instanceof PdfImportCancelledError) {
          throw new PdfImportCancelledCleanupError(completionMessage, createdPaths)
        }
        throw new PdfImportCleanupError(completionMessage, createdPaths)
      }
      if (completionError instanceof PdfImportCancelledError) {
        throw new PdfImportCancelledError(completionMessage)
      }
      if (completionError instanceof PdfStorageError) {
        throw new PdfStorageError(completionError.diagnostic)
      }
      throw new Error(completionMessage)
    }
    return result
  }

  private static async renderOcrPixelMap(page: pdfService.PdfPage): Promise<image.PixelMap> {
    let originalPixelMap: image.PixelMap | null = page.getPagePixelMap()
    let operationError: string = ''
    let resourceFailureMessage: string = ''
    try {
      const originalInfo: image.ImageInfo = await originalPixelMap.getImageInfo()
      PdfImportCoordinator.validateImageInfo(originalInfo)
      const originalWidth: number = originalInfo.size.width
      const originalHeight: number = originalInfo.size.height
      const longEdge: number = Math.max(originalWidth, originalHeight)
      if (longEdge <= PdfImportLimits.MAX_RENDER_LONG_EDGE) {
        const resultPixelMap: image.PixelMap = originalPixelMap
        originalPixelMap = null
        return resultPixelMap
      }
      const renderScale: number = PdfImportLimits.MAX_RENDER_LONG_EDGE / longEdge
      const bitmapWidth: number = Math.max(1, Math.floor(originalWidth * renderScale))
      const bitmapHeight: number = Math.max(1, Math.floor(originalHeight * renderScale))
      const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix()
      const options: pdfService.PixelOptions = new pdfService.PixelOptions()
      const originalToRelease: image.PixelMap = originalPixelMap
      originalPixelMap = null
      let originalReleaseMessage: string = ''
      try {
        matrix.x = 0
        matrix.y = 0
        matrix.width = page.getWidth()
        matrix.height = page.getHeight()
        matrix.rotate = 0
        options.isGray = false
        options.drawAnnotations = true
        options.isTransparent = false
      } finally {
        try {
          await originalToRelease.release()
        } catch (releaseErr) {
          originalReleaseMessage = PdfImportCoordinator.errorMessage(releaseErr, '原始页面图像释放失败')
        }
      }
      if (originalReleaseMessage.length > 0) {
        const resourceError: PdfImportResourceError = new PdfImportResourceError(originalReleaseMessage)
        throw resourceError
      }
      return page.getAreaPixelMapWithOptions(matrix, bitmapWidth, bitmapHeight, options)
    } catch (err) {
      if (err instanceof PdfImportResourceError) {
        resourceFailureMessage = PdfImportCoordinator.appendDiagnostic(resourceFailureMessage, err.message)
      } else {
        operationError = PdfImportCoordinator.errorMessage(err, 'PDF 页面渲染失败')
      }
    } finally {
      if (originalPixelMap !== null) {
        const failedOriginal: image.PixelMap = originalPixelMap
        originalPixelMap = null
        try {
          await failedOriginal.release()
        } catch (releaseErr) {
          resourceFailureMessage = PdfImportCoordinator.appendDiagnostic(resourceFailureMessage,
            PdfImportCoordinator.errorMessage(releaseErr, '原始页面图像释放失败'))
        }
      }
    }
    if (resourceFailureMessage.length > 0) {
      const combinedMessage: string = PdfImportCoordinator.appendDiagnostic(operationError, resourceFailureMessage)
      const resourceError: PdfImportResourceError = new PdfImportResourceError(combinedMessage)
      throw resourceError
    }
    throw new Error(operationError.length > 0 ? operationError : 'PDF 页面渲染失败')
  }

  private static createCropJobs(drafts: Array<PdfQuestionDraft>): Array<CropJob> {
    const jobs: Array<CropJob> = new Array<CropJob>()
    for (let draftIndex: number = 0; draftIndex < drafts.length; draftIndex++) {
      const draft: PdfQuestionDraft = drafts[draftIndex]
      for (let cropIndex: number = 0; cropIndex < draft.crops.length; cropIndex++) {
        jobs.push(new CropJob(draftIndex, cropIndex, draft.crops[cropIndex]))
      }
    }
    jobs.sort((first: CropJob, second: CropJob): number => {
      if (first.crop.pageNumber !== second.crop.pageNumber) {
        return first.crop.pageNumber - second.crop.pageNumber
      }
      if (first.draftIndex !== second.draftIndex) {
        return first.draftIndex - second.draftIndex
      }
      return first.cropIndex - second.cropIndex
    })
    return jobs
  }

  private static createTaskId(): string {
    PdfImportCoordinator.taskSequence++
    if (!Number.isSafeInteger(PdfImportCoordinator.taskSequence) || PdfImportCoordinator.taskSequence > 999999999) {
      PdfImportCoordinator.taskSequence = 1
    }
    return Date.now().toString() + '_' + PdfImportCoordinator.taskSequence.toString()
  }

  private static appendCropPaths(drafts: Array<PdfQuestionDraft>, jobs: Array<CropJob>): void {
    for (let draftIndex: number = 0; draftIndex < drafts.length; draftIndex++) {
      const draft: PdfQuestionDraft = drafts[draftIndex]
      for (let cropIndex: number = 0; cropIndex < draft.crops.length; cropIndex++) {
        const job: CropJob | null = PdfImportCoordinator.findCropJob(jobs, draftIndex, cropIndex)
        if (job === null || job.path.length === 0) {
          throw new Error('题图生成结果不完整')
        }
        draft.imagePaths.push(job.path)
      }
    }
  }

  private static findCropJob(jobs: Array<CropJob>, draftIndex: number, cropIndex: number): CropJob | null {
    for (let index: number = 0; index < jobs.length; index++) {
      if (jobs[index].draftIndex === draftIndex && jobs[index].cropIndex === cropIndex) {
        return jobs[index]
      }
    }
    return null
  }

  private static findPageInfo(infos: Array<RenderedPageInfo>, pageNumber: number): image.ImageInfo | null {
    for (let index: number = 0; index < infos.length; index++) {
      if (infos[index].pageNumber === pageNumber) {
        return infos[index].imageInfo
      }
    }
    return null
  }

  private static validateImageInfo(info: image.ImageInfo): void {
    if (!Number.isFinite(info.size.width) || !Number.isFinite(info.size.height) ||
      info.size.width <= 0 || info.size.height <= 0) {
      throw new Error('页面图像尺寸无效')
    }
  }

  private static throwIfCancelled(isCancelled: PdfImportCancellationCheck): void {
    if (isCancelled()) {
      throw new PdfImportCancelledError()
    }
  }

  private static toError(err: Error, fallback: string): Error {
    if (err instanceof PdfImportCancelledError) {
      return err
    }
    if (err instanceof Error) {
      return err
    }
    return new Error(fallback)
  }

  private static errorMessage(err: Error, fallback: string): string {
    return err instanceof Error && err.message.length > 0 ? err.message : fallback
  }

  private static appendDiagnostic(primary: string, diagnostic: string): string {
    if (diagnostic.length === 0) {
      return primary
    }
    return primary.length > 0 ? primary + '；' + diagnostic : diagnostic
  }
}
