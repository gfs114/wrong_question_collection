import { Context } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { relationalStore } from '@kit.ArkData'
import { pdfService } from '@kit.PDFKit'
import { image } from '@kit.ImageKit'
import fs, { ListFileOptions } from '@ohos.file.fs'
import { PdfImportLimits } from '../constants/PdfImportLimits'
import { PageCrop } from '../models/PdfImportModels'
import { PdfCropMath, PdfCropOutputSize } from '../utils/PdfCropMath'
import { ImageWriteOwnership } from '../utils/ImageWriteOwnership'
import { DatabaseService } from './DatabaseService'
import { PdfStorageError } from './PdfStorageError'

class ImageMoveRecord {
  sourcePath: string
  finalPath: string

  constructor(sourcePath: string, finalPath: string) {
    this.sourcePath = sourcePath
    this.finalPath = finalPath
  }
}

export class QuestionImageRollbackError extends Error {
  readonly bankId: string
  readonly cachePaths: Array<string>
  readonly committedPaths: Array<string>
  readonly debtRegistered: boolean

  constructor(message: string, bankId: string, cachePaths: Array<string>, committedPaths: Array<string>,
    debtRegistered: boolean = true) {
    super(message)
    this.bankId = bankId
    this.cachePaths = cachePaths.slice()
    this.committedPaths = committedPaths.slice()
    this.debtRegistered = debtRegistered
  }
}

class RollbackDebtRecord {
  finalPath: string
  cachePath: string
  bankId: string

  constructor(finalPath: string, cachePath: string, bankId: string) {
    this.finalPath = finalPath
    this.cachePath = cachePath
    this.bankId = bankId
  }
}

export class QuestionImageCleanupError extends Error {
  readonly paths: Array<string>

  constructor(message: string, paths: Array<string>) {
    super(message)
    this.paths = paths.slice()
  }
}

export class QuestionImageService {
  private static tempSequence: number = 0
  private static readonly cleanupDebtPaths: Array<string> = new Array<string>()
  private static cleanupTransition: Promise<void> | null = null

  static rememberCleanupDebt(paths: Array<string>): void {
    for (let index: number = 0; index < paths.length; index++) {
      const path: string = paths[index]
      if (QuestionImageService.cleanupDebtPaths.indexOf(path) < 0) {
        QuestionImageService.cleanupDebtPaths.push(path)
      }
    }
  }

  static async retryCleanupDebt(context: Context,
    activePaths: Array<string> = new Array<string>()): Promise<void> {
    const runningTransition: Promise<void> | null = QuestionImageService.cleanupTransition
    if (runningTransition !== null) {
      await runningTransition
      return
    }
    const transition: Promise<void> = QuestionImageService.performCleanupDebtRetry(context, activePaths.slice())
    QuestionImageService.cleanupTransition = transition
    try {
      await transition
    } finally {
      QuestionImageService.cleanupTransition = null
    }
  }

  static async saveCrop(context: Context, page: pdfService.PdfPage, fullImageInfo: image.ImageInfo,
    crop: PageCrop, taskId: string, draftId: string, order: number): Promise<string> {
    const fullImageWidth: number = fullImageInfo.size.width
    const fullImageHeight: number = fullImageInfo.size.height
    const pageWidth: number = page.getWidth()
    const pageHeight: number = page.getHeight()
    QuestionImageService.validateCropInput(fullImageWidth, fullImageHeight, pageWidth, pageHeight, crop)
    if (!Number.isInteger(order) || order < 0) {
      throw new Error('题图序号无效')
    }
    QuestionImageService.validateSafeIdentifier(taskId, '导入任务标识')
    QuestionImageService.validateSafeIdentifier(draftId, '题目标识')
    const targetPath: string = context.cacheDir + '/pdf_question_' + taskId + '_' + draftId + '_' +
      order.toString() + '.jpg'
    const tempPath: string = QuestionImageService.createTempPath(context.cacheDir, taskId, draftId, order)
    const ownership: ImageWriteOwnership = new ImageWriteOwnership(tempPath, targetPath)
    const scaleX: number = pageWidth / fullImageWidth
    const scaleY: number = pageHeight / fullImageHeight
    const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix()
    matrix.x = crop.left * scaleX
    matrix.y = pageHeight - crop.bottom * scaleY
    matrix.width = (crop.right - crop.left) * scaleX
    matrix.height = (crop.bottom - crop.top) * scaleY
    matrix.rotate = 0
    matrix.x = QuestionImageService.clamp(matrix.x, 0, pageWidth)
    matrix.y = QuestionImageService.clamp(matrix.y, 0, pageHeight)
    matrix.width = QuestionImageService.clamp(matrix.width, 0, pageWidth - matrix.x)
    matrix.height = QuestionImageService.clamp(matrix.height, 0, pageHeight - matrix.y)
    if (matrix.width <= 0 || matrix.height <= 0) {
      throw new Error('题图裁剪区域超出 PDF 页面')
    }
    const sourceWidth: number = crop.right - crop.left
    const sourceHeight: number = crop.bottom - crop.top
    const outputSize: PdfCropOutputSize = PdfCropMath.calculate(sourceWidth, sourceHeight)
    const bitmapWidth: number = outputSize.width
    const bitmapHeight: number = outputSize.height
    const pixelOptions: pdfService.PixelOptions = new pdfService.PixelOptions()
    pixelOptions.isGray = false
    pixelOptions.drawAnnotations = true
    pixelOptions.isTransparent = false
    let cropPixelMap: image.PixelMap | null = null
    let packer: image.ImagePacker | null = null
    let temporaryFile: fs.File | null = null
    let operationError: string = ''
    try {
      await QuestionImageService.validateDirectory(context.cacheDir)
      const existingTemporary: fs.Stat | null = await QuestionImageService.lstatIfPresent(tempPath)
      if (existingTemporary !== null) {
        throw new Error('题图临时文件已存在')
      }
      cropPixelMap = page.getAreaPixelMapWithOptions(matrix, bitmapWidth, bitmapHeight, pixelOptions)
      packer = image.createImagePacker()
      temporaryFile = await fs.open(tempPath,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW)
      ownership.markTemporaryCreated()
      const packingOption: image.PackingOption = {
        format: 'image/jpeg',
        quality: PdfImportLimits.JPEG_QUALITY
      }
      await packer.packToFile(cropPixelMap, temporaryFile.fd, packingOption)
    } catch (err) {
      operationError = QuestionImageService.errorMessage(err, '题图生成失败')
    } finally {
      if (temporaryFile !== null) {
        const fileToClose: fs.File = temporaryFile
        temporaryFile = null
        try {
          await fs.close(fileToClose)
        } catch (err) {
          operationError = QuestionImageService.appendDiagnostic(operationError,
            QuestionImageService.errorMessage(err, '题图文件关闭失败'))
        }
      }
      if (packer !== null) {
        try {
          await packer.release()
        } catch (err) {
          operationError = QuestionImageService.appendDiagnostic(operationError,
            QuestionImageService.errorMessage(err, '图像编码器释放失败'))
        }
      }
      if (cropPixelMap !== null) {
        try {
          await cropPixelMap.release()
        } catch (err) {
          operationError = QuestionImageService.appendDiagnostic(operationError,
            QuestionImageService.errorMessage(err, '题图像素资源释放失败'))
        }
      }
    }
    if (operationError.length === 0) {
      try {
        await QuestionImageService.validateDirectory(context.cacheDir)
        await fs.moveFile(tempPath, targetPath, 1)
        ownership.markMoved()
      } catch (err) {
        operationError = QuestionImageService.errorMessage(err, '题图原子提交失败')
      }
    }
    if (operationError.length > 0) {
      const cleanupPath: string = ownership.temporaryCleanupPath()
      if (cleanupPath.length > 0) {
        try {
          if (await QuestionImageService.validateExistingFileChain(context.cacheDir, cleanupPath)) {
            await fs.unlink(cleanupPath)
          }
        } catch (err) {
          QuestionImageService.rememberCleanupDebt([cleanupPath])
          operationError = QuestionImageService.appendDiagnostic(operationError,
            QuestionImageService.errorMessage(err, '残留临时题图删除失败'))
        }
      }
      throw new PdfStorageError(operationError)
    }
    return ownership.resultPath()
  }

  static async commitImages(context: Context, bankId: string, paths: Array<string>): Promise<Array<string>> {
    QuestionImageService.validateSafeIdentifier(bankId, '题库标识')
    const destinationDir: string = context.filesDir + '/question_images/' + bankId
    const records: Array<ImageMoveRecord> = new Array<ImageMoveRecord>()
    const seenPaths: Array<string> = new Array<string>()
    try {
      await QuestionImageService.validateDirectory(context.cacheDir)
      await QuestionImageService.validateDirectory(context.filesDir)
      for (let index: number = 0; index < paths.length; index++) {
        const sourcePath: string = paths[index]
        if (!QuestionImageService.isServiceCachePath(context.cacheDir, sourcePath)) {
          throw new Error('仅可提交本次 PDF 导入生成的缓存题图')
        }
        if (seenPaths.indexOf(sourcePath) >= 0) {
          throw new Error('待提交题图路径重复')
        }
        seenPaths.push(sourcePath)
        if (!(await QuestionImageService.validateExistingFileChain(context.cacheDir, sourcePath))) {
          throw new Error('待提交题图不存在')
        }
        const name: string = sourcePath.substring(context.cacheDir.length + 1)
        records.push(new ImageMoveRecord(sourcePath, destinationDir + '/' + name))
      }
      const committedRoot: string = context.filesDir + '/question_images'
      await QuestionImageService.ensureDirectDirectory(context.filesDir, committedRoot)
      if (records.length > 0) {
        await QuestionImageService.ensureDirectDirectory(committedRoot, destinationDir)
      }
    } catch (err) {
      const primaryMessage: string = QuestionImageService.errorMessage(err, '题图提交准备失败')
      const cleanupMessage: string = await QuestionImageService.removeBankDirectoryIfEmpty(context, bankId)
      const failureMessage: string = cleanupMessage.length > 0 ?
        QuestionImageService.appendDiagnostic(primaryMessage, cleanupMessage) : primaryMessage
      throw new PdfStorageError(failureMessage)
    }
    const moved: Array<ImageMoveRecord> = new Array<ImageMoveRecord>()
    const expectedCommittedPaths: Array<string> = new Array<string>()
    for (let expectedIndex: number = 0; expectedIndex < records.length; expectedIndex++) {
      expectedCommittedPaths.push(records[expectedIndex].finalPath)
    }
    try {
      for (let index: number = 0; index < records.length; index++) {
        const record: ImageMoveRecord = records[index]
        if (!(await QuestionImageService.validateExistingFileChain(context.cacheDir, record.sourcePath))) {
          throw new Error('待提交题图在移动前消失')
        }
        await QuestionImageService.validateExistingDirectoryChain(context.filesDir, destinationDir)
        const existingFinal: fs.Stat | null = await QuestionImageService.lstatIfPresent(record.finalPath)
        if (existingFinal !== null) {
          throw new Error('题图目标路径已存在')
        }
        await fs.moveFile(record.sourcePath, record.finalPath, 1)
        moved.push(record)
      }
    } catch (err) {
      const primaryMessage: string = QuestionImageService.errorMessage(err, '题图提交失败')
      const rollbackErrors: Array<string> = await QuestionImageService.rollbackMoves(
        moved, context.cacheDir, context.filesDir)
      const cleanupMessage: string = await QuestionImageService.removeBankDirectoryIfEmpty(context, bankId)
      let failureMessage: string = primaryMessage
      if (rollbackErrors.length > 0) {
        failureMessage = QuestionImageService.appendDiagnostic(
          failureMessage, '题图回滚失败：' + rollbackErrors.join('；'))
      }
      if (cleanupMessage.length > 0) {
        failureMessage = QuestionImageService.appendDiagnostic(failureMessage, cleanupMessage)
      }
      if (rollbackErrors.length > 0 || cleanupMessage.length > 0) {
        let debtRegistered: boolean = true
        if (rollbackErrors.length > 0) {
          const movedCachePaths: Array<string> = new Array<string>()
          const movedCommittedPaths: Array<string> = new Array<string>()
          for (let movedIndex: number = 0; movedIndex < moved.length; movedIndex++) {
            movedCachePaths.push(moved[movedIndex].sourcePath)
            movedCommittedPaths.push(moved[movedIndex].finalPath)
          }
          try {
            await QuestionImageService.registerRollbackDebt(
              context, bankId, movedCachePaths, movedCommittedPaths)
          } catch (debtErr) {
            debtRegistered = false
            failureMessage = QuestionImageService.appendDiagnostic(failureMessage,
              '回滚恢复记录保存失败：' + QuestionImageService.errorMessage(debtErr, '数据库写入失败'))
          }
        }
        throw new QuestionImageRollbackError(
          failureMessage, bankId, paths, expectedCommittedPaths, debtRegistered)
      }
      throw new PdfStorageError(failureMessage)
    }
    return expectedCommittedPaths
  }

  static async rollbackCommittedImages(context: Context, bankId: string, cachePaths: Array<string>,
    committedPaths: Array<string>): Promise<void> {
    QuestionImageService.validateSafeIdentifier(bankId, '题库标识')
    if (cachePaths.length !== committedPaths.length) {
      throw new QuestionImageRollbackError('题图回滚路径数量不一致', bankId, cachePaths, committedPaths)
    }
    const committedRoot: string = context.filesDir + '/question_images'
    const destinationDir: string = context.filesDir + '/question_images/' + bankId
    const failures: Array<string> = new Array<string>()
    try {
      await QuestionImageService.validateDirectory(context.cacheDir)
      await QuestionImageService.validateDirectory(context.filesDir)
      const committedRootInfo: fs.Stat | null = await QuestionImageService.lstatIfPresent(committedRoot)
      if (committedRootInfo !== null) {
        await QuestionImageService.validateExistingDirectoryChain(context.filesDir, committedRoot)
      }
      const destinationInfo: fs.Stat | null = await QuestionImageService.lstatIfPresent(destinationDir)
      if (destinationInfo !== null) {
        await QuestionImageService.validateExistingDirectoryChain(context.filesDir, destinationDir)
      }
      for (let index: number = 0; index < committedPaths.length; index++) {
        const cachePath: string = cachePaths[index]
        const committedPath: string = committedPaths[index]
        if (!QuestionImageService.isServiceCachePath(context.cacheDir, cachePath) ||
          !QuestionImageService.isDirectServiceImagePath(destinationDir, committedPath) ||
          QuestionImageService.fileName(cachePath) !== QuestionImageService.fileName(committedPath)) {
          failures.push('题图回滚路径不属于当前题库')
          continue
        }
        try {
          const cacheInfo: fs.Stat | null = await QuestionImageService.lstatIfPresent(cachePath)
          const committedInfo: fs.Stat | null = await QuestionImageService.lstatIfPresent(committedPath)
          if (committedInfo === null) {
            if (cacheInfo === null || !(await QuestionImageService.validateExistingFileChain(
              context.cacheDir, cachePath))) {
              failures.push(committedPath + ' 已丢失')
            }
            continue
          }
          if (!(await QuestionImageService.validateExistingFileChain(context.filesDir, committedPath))) {
            failures.push(committedPath + ' 已丢失')
            continue
          }
          if (cacheInfo !== null) {
            failures.push(cachePath + ' 已被占用')
            continue
          }
          await fs.moveFile(committedPath, cachePath, 1)
        } catch (err) {
          failures.push(committedPath + '：' + QuestionImageService.errorMessage(err, '回滚失败'))
        }
      }
      const remainingDestination: fs.Stat | null = await QuestionImageService.lstatIfPresent(destinationDir)
      if (remainingDestination !== null) {
        await QuestionImageService.validateExistingDirectoryChain(context.filesDir, destinationDir)
        await fs.rmdir(destinationDir)
      }
    } catch (err) {
      failures.push(QuestionImageService.errorMessage(err, '题库题图目录删除失败'))
    }
    if (failures.length > 0) {
      let failureMessage: string = '题图回滚失败：' + failures.join('；')
      let debtRegistered: boolean = true
      try {
        await QuestionImageService.registerRollbackDebt(context, bankId, cachePaths, committedPaths)
      } catch (debtErr) {
        debtRegistered = false
        failureMessage = QuestionImageService.appendDiagnostic(failureMessage,
          '回滚恢复记录保存失败：' + QuestionImageService.errorMessage(debtErr, '数据库写入失败'))
      }
      throw new QuestionImageRollbackError(
        failureMessage, bankId, cachePaths, committedPaths, debtRegistered)
    }
    await QuestionImageService.removeRollbackDebt(committedPaths)
  }

  static async deletePaths(context: Context, paths: Array<string>): Promise<void> {
    const seenPaths: Array<string> = new Array<string>()
    const failedPaths: Array<string> = new Array<string>()
    const failures: Array<string> = new Array<string>()
    for (let index: number = 0; index < paths.length; index++) {
      const path: string = paths[index]
      if (seenPaths.indexOf(path) >= 0) {
        continue
      }
      seenPaths.push(path)
      const ownedRoot: string = QuestionImageService.ownedDeletionRoot(context, path)
      if (ownedRoot.length === 0) {
        failedPaths.push(path)
        failures.push(path + '：路径不属于题图存储目录')
        continue
      }
      try {
        const serviceCachePath: boolean = QuestionImageService.isServiceCachePath(context.cacheDir, path)
        if (!serviceCachePath && await QuestionImageService.isQuestionImageReferenced(path)) {
          throw new Error('题图仍被数据库引用')
        }
        const rootInfo: fs.Stat | null = await QuestionImageService.lstatIfPresent(ownedRoot)
        if (rootInfo === null) {
          await QuestionImageService.removePersistentCleanupDebt(path)
          QuestionImageService.removeCleanupDebt([path])
          continue
        }
        const exists: boolean = await QuestionImageService.validateExistingFileChain(ownedRoot, path)
        if (exists) {
          await fs.unlink(path)
        }
        await QuestionImageService.removeEmptyCommittedBankDirectory(context, path)
        await QuestionImageService.removePersistentCleanupDebt(path)
        QuestionImageService.removeCleanupDebt([path])
      } catch (err) {
        failedPaths.push(path)
        failures.push(path + '：' + QuestionImageService.errorMessage(err, '删除失败'))
      }
    }
    if (failures.length > 0) {
      throw new QuestionImageCleanupError('题图清理失败：' + failures.join('；'), failedPaths)
    }
  }

  private static async rollbackMoves(moved: Array<ImageMoveRecord>, cacheDir: string,
    filesDir: string): Promise<Array<string>> {
    const failures: Array<string> = new Array<string>()
    for (let index: number = moved.length - 1; index >= 0; index--) {
      const record: ImageMoveRecord = moved[index]
      try {
        if (!(await QuestionImageService.validateExistingFileChain(filesDir, record.finalPath))) {
          failures.push(record.finalPath + ' 已丢失')
          continue
        }
        await QuestionImageService.validateDirectory(cacheDir)
        const restoredSource: fs.Stat | null = await QuestionImageService.lstatIfPresent(record.sourcePath)
        if (restoredSource !== null) {
          failures.push(record.sourcePath + ' 已被占用')
          continue
        }
        await fs.moveFile(record.finalPath, record.sourcePath, 1)
      } catch (err) {
        failures.push(record.finalPath + '：' + QuestionImageService.errorMessage(err, '回滚失败'))
      }
    }
    return failures
  }

  private static async removeBankDirectoryIfEmpty(context: Context, bankId: string): Promise<string> {
    try {
      QuestionImageService.validateSafeIdentifier(bankId, '题库标识')
      await QuestionImageService.validateDirectory(context.filesDir)
      const destinationDir: string = context.filesDir + '/question_images/' + bankId
      const destinationInfo: fs.Stat | null = await QuestionImageService.lstatIfPresent(destinationDir)
      if (destinationInfo === null) {
        return ''
      }
      await QuestionImageService.validateExistingDirectoryChain(context.filesDir, destinationDir)
      const options: ListFileOptions = {
        recursion: false
      }
      const names: Array<string> = await fs.listFile(destinationDir, options)
      if (names.length > 0) {
        return '题库题图目录仍包含未恢复文件'
      }
      await fs.rmdir(destinationDir)
      return ''
    } catch (err) {
      return QuestionImageService.errorMessage(err, '题库题图目录清理失败')
    }
  }

  private static removeCleanupDebt(paths: Array<string>): void {
    for (let pathIndex: number = 0; pathIndex < paths.length; pathIndex++) {
      const path: string = paths[pathIndex]
      const debtIndex: number = QuestionImageService.cleanupDebtPaths.indexOf(path)
      if (debtIndex >= 0) {
        QuestionImageService.cleanupDebtPaths.splice(debtIndex, 1)
      }
    }
  }

  private static async listPersistentCleanupDebt(): Promise<Array<string>> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT path FROM question_image_cleanup_debt ORDER BY create_time ASC, path ASC')
    const paths: Array<string> = new Array<string>()
    try {
      while (resultSet.goToNextRow()) {
        paths.push(resultSet.getString(0))
      }
      return paths
    } finally {
      resultSet.close()
    }
  }

  private static async removePersistentCleanupDebt(path: string): Promise<void> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates('question_image_cleanup_debt')
    predicates.equalTo('path', path)
    await store.delete(predicates)
  }

  private static async registerRollbackDebt(context: Context, bankId: string, cachePaths: Array<string>,
    committedPaths: Array<string>): Promise<void> {
    QuestionImageService.validateSafeIdentifier(bankId, '题库标识')
    if (cachePaths.length !== committedPaths.length) {
      throw new Error('回滚恢复记录数量不一致')
    }
    const destinationDir: string = context.filesDir + '/question_images/' + bankId
    for (let index: number = 0; index < committedPaths.length; index++) {
      if (!QuestionImageService.isDirectServiceImagePath(context.cacheDir, cachePaths[index]) ||
        !QuestionImageService.isDirectServiceImagePath(destinationDir, committedPaths[index]) ||
        QuestionImageService.fileName(cachePaths[index]) !== QuestionImageService.fileName(committedPaths[index])) {
        throw new Error('回滚恢复记录路径无效')
      }
    }
    if (committedPaths.length === 0) {
      return
    }
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const transaction: relationalStore.Transaction = await store.createTransaction()
    try {
      const createTime: number = Date.now()
      for (let index: number = 0; index < committedPaths.length; index++) {
        const args: Array<relationalStore.ValueType> = [committedPaths[index], cachePaths[index], bankId, createTime]
        await transaction.execute(
          'INSERT OR REPLACE INTO question_image_rollback_debt(final_path, cache_path, bank_id, create_time) ' +
          'VALUES (?, ?, ?, ?)', args)
      }
      await transaction.commit()
    } catch (err) {
      try {
        await transaction.rollback()
      } catch {
      }
      if (err instanceof Error) {
        throw err
      }
      throw new Error('回滚恢复记录保存失败')
    }
  }

  private static async listRollbackDebt(): Promise<Array<RollbackDebtRecord>> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT final_path, cache_path, bank_id FROM question_image_rollback_debt ' +
      'ORDER BY create_time ASC, final_path ASC')
    const records: Array<RollbackDebtRecord> = new Array<RollbackDebtRecord>()
    try {
      while (resultSet.goToNextRow()) {
        records.push(new RollbackDebtRecord(
          resultSet.getString(0), resultSet.getString(1), resultSet.getString(2)))
      }
      return records
    } finally {
      resultSet.close()
    }
  }

  private static async removeRollbackDebt(finalPaths: Array<string>): Promise<void> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    for (let index: number = 0; index < finalPaths.length; index++) {
      const predicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates('question_image_rollback_debt')
      predicates.equalTo('final_path', finalPaths[index])
      await store.delete(predicates)
    }
  }

  private static async performRollbackDebtRetry(context: Context): Promise<void> {
    const records: Array<RollbackDebtRecord> = await QuestionImageService.listRollbackDebt()
    const failures: Array<string> = new Array<string>()
    for (let index: number = 0; index < records.length; index++) {
      const record: RollbackDebtRecord = records[index]
      const destinationDir: string = context.filesDir + '/question_images/' + record.bankId
      try {
        QuestionImageService.validateSafeIdentifier(record.bankId, '题库标识')
        if (!QuestionImageService.isDirectServiceImagePath(context.cacheDir, record.cachePath) ||
          !QuestionImageService.isDirectServiceImagePath(destinationDir, record.finalPath) ||
          QuestionImageService.fileName(record.cachePath) !== QuestionImageService.fileName(record.finalPath)) {
          throw new Error('回滚恢复记录路径无效')
        }
        const finalInfo: fs.Stat | null = await QuestionImageService.lstatIfPresent(record.finalPath)
        const cacheInfo: fs.Stat | null = await QuestionImageService.lstatIfPresent(record.cachePath)
        if (finalInfo !== null && await QuestionImageService.isQuestionImageReferenced(record.finalPath)) {
          throw new Error('已提交题图仍被数据库引用')
        }
        if (finalInfo !== null && cacheInfo === null) {
          if (!(await QuestionImageService.validateExistingFileChain(context.filesDir, record.finalPath))) {
            throw new Error('已提交题图已丢失')
          }
          await QuestionImageService.validateDirectory(context.cacheDir)
          await fs.moveFile(record.finalPath, record.cachePath, 1)
          await QuestionImageService.removeEmptyCommittedBankDirectory(context, record.finalPath)
          await QuestionImageService.removeRollbackDebt([record.finalPath])
          continue
        }
        if (finalInfo === null && cacheInfo !== null) {
          if (!(await QuestionImageService.validateExistingFileChain(context.cacheDir, record.cachePath))) {
            throw new Error('缓存题图已丢失')
          }
          await QuestionImageService.removeRollbackDebt([record.finalPath])
          continue
        }
        if (finalInfo !== null && cacheInfo !== null) {
          throw new Error('回滚两端文件同时存在')
        }
        if (finalInfo === null && cacheInfo === null) {
          throw new Error('回滚两端文件均不存在')
        }
      } catch (err) {
        failures.push(record.finalPath + '：' + QuestionImageService.errorMessage(err, '回滚恢复失败'))
      }
    }
    if (failures.length > 0) {
      throw new Error('题图回滚恢复失败：' + failures.join('；'))
    }
  }

  private static async isQuestionImageReferenced(path: string): Promise<boolean> {
    const store: relationalStore.RdbStore = DatabaseService.getStore()
    const args: Array<relationalStore.ValueType> = [path]
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT COUNT(*) FROM question_image WHERE image_path = ?', args)
    try {
      if (!resultSet.goToFirstRow()) {
        throw new Error('题图引用状态读取失败')
      }
      return resultSet.getLong(0) > 0
    } finally {
      resultSet.close()
    }
  }

  private static async removeEmptyCommittedBankDirectory(context: Context, path: string): Promise<void> {
    const committedRoot: string = context.filesDir + '/question_images'
    if (!QuestionImageService.isNormalizedDescendant(path, committedRoot)) {
      return
    }
    const relative: string = path.substring(committedRoot.length + 1)
    const parts: Array<string> = relative.split('/')
    if (parts.length !== 2 || !QuestionImageService.isCleanupCandidateName(parts[1])) {
      throw new Error('已提交题图路径层级无效')
    }
    const bankId: string = parts[0]
    QuestionImageService.validateSafeIdentifier(bankId, '题库标识')
    await QuestionImageService.validateDirectory(context.filesDir)
    const rootInfo: fs.Stat | null = await QuestionImageService.lstatIfPresent(committedRoot)
    if (rootInfo === null) {
      return
    }
    await QuestionImageService.validateExistingDirectoryChain(context.filesDir, committedRoot)
    const bankDirectory: string = committedRoot + '/' + bankId
    const directoryInfo: fs.Stat | null = await QuestionImageService.lstatIfPresent(bankDirectory)
    if (directoryInfo === null) {
      return
    }
    if (QuestionImageService.isSymbolicLink(directoryInfo) || !QuestionImageService.isDirectory(directoryInfo)) {
      throw new Error('题库题图目录类型无效')
    }
    const options: ListFileOptions = {
      recursion: false
    }
    const entries: Array<string> = await fs.listFile(bankDirectory, options)
    if (entries.length === 0) {
      await fs.rmdir(bankDirectory)
    }
  }

  private static async performCleanupDebtRetry(context: Context, activePaths: Array<string>): Promise<void> {
    const options: ListFileOptions = {
      recursion: false
    }
    await QuestionImageService.performRollbackDebtRetry(context)
    await QuestionImageService.validateDirectory(context.cacheDir)
    const candidatePaths: Array<string> = QuestionImageService.cleanupDebtPaths.slice()
    const persistentPaths: Array<string> = await QuestionImageService.listPersistentCleanupDebt()
    for (let persistentIndex: number = 0; persistentIndex < persistentPaths.length; persistentIndex++) {
      const path: string = persistentPaths[persistentIndex]
      if (candidatePaths.indexOf(path) < 0) {
        candidatePaths.push(path)
      }
    }
    const names: Array<string> = await fs.listFile(context.cacheDir, options)
    for (const name of names) {
      if (!QuestionImageService.isCleanupCandidateName(name)) {
        continue
      }
      const path: string = context.cacheDir + '/' + name
      if (candidatePaths.indexOf(path) < 0) {
        candidatePaths.push(path)
      }
    }
    const failures: Array<string> = new Array<string>()
    for (let index: number = 0; index < candidatePaths.length; index++) {
      const path: string = candidatePaths[index]
      const serviceCachePath: boolean = QuestionImageService.isServiceCachePath(context.cacheDir, path)
      const ownedRoot: string = serviceCachePath ? context.cacheDir :
        QuestionImageService.ownedDeletionRoot(context, path)
      if (activePaths.indexOf(path) >= 0) {
        continue
      }
      try {
        if (ownedRoot.length === 0) {
          throw new Error('清理债务路径不属于题图存储目录')
        }
        if (!serviceCachePath && await QuestionImageService.isQuestionImageReferenced(path)) {
          failures.push(path + '：题图仍被数据库引用')
          continue
        }
        if (!serviceCachePath) {
          const rootInfo: fs.Stat | null = await QuestionImageService.lstatIfPresent(ownedRoot)
          if (rootInfo === null) {
            await QuestionImageService.removePersistentCleanupDebt(path)
            QuestionImageService.removeCleanupDebt([path])
            continue
          }
          if (!(await QuestionImageService.validateExistingFileChain(ownedRoot, path))) {
            await QuestionImageService.removeEmptyCommittedBankDirectory(context, path)
            await QuestionImageService.removePersistentCleanupDebt(path)
            QuestionImageService.removeCleanupDebt([path])
            continue
          }
        }
        const info: fs.Stat | null = await QuestionImageService.lstatIfPresent(path)
        if (info === null) {
          await QuestionImageService.removeEmptyCommittedBankDirectory(context, path)
          await QuestionImageService.removePersistentCleanupDebt(path)
          QuestionImageService.removeCleanupDebt([path])
          continue
        }
        if (QuestionImageService.isSymbolicLink(info) || !QuestionImageService.isFile(info)) {
          throw new Error('清理目标不是普通文件')
        }
        await fs.unlink(path)
        await QuestionImageService.removeEmptyCommittedBankDirectory(context, path)
        await QuestionImageService.removePersistentCleanupDebt(path)
        QuestionImageService.removeCleanupDebt([path])
      } catch (err) {
        QuestionImageService.rememberCleanupDebt([path])
        failures.push(path + '：' + QuestionImageService.errorMessage(err, '删除失败'))
      }
    }
    if (failures.length > 0) {
      throw new Error('题图缓存清理失败：' + failures.join('；'))
    }
  }

  private static createTempPath(cacheDir: string, taskId: string, draftId: string, order: number): string {
    QuestionImageService.tempSequence++
    if (!Number.isSafeInteger(QuestionImageService.tempSequence) ||
      QuestionImageService.tempSequence > 999999999) {
      QuestionImageService.tempSequence = 1
    }
    return cacheDir + '/pdf_question_' + taskId + '_' + draftId + '_' + order.toString() + '_tmp_' +
      Date.now().toString() + '_' + QuestionImageService.tempSequence.toString() + '.jpg'
  }

  private static validateCropInput(fullImageWidth: number, fullImageHeight: number, pageWidth: number,
    pageHeight: number, crop: PageCrop): void {
    if (!Number.isFinite(fullImageWidth) || !Number.isFinite(fullImageHeight) ||
      fullImageWidth <= 0 || fullImageHeight <= 0) {
      throw new Error('完整页面图像尺寸无效')
    }
    if (!Number.isFinite(pageWidth) || !Number.isFinite(pageHeight) || pageWidth <= 0 || pageHeight <= 0) {
      throw new Error('PDF 页面尺寸无效')
    }
    if (!Number.isFinite(crop.left) || !Number.isFinite(crop.top) || !Number.isFinite(crop.right) ||
      !Number.isFinite(crop.bottom) || crop.left < 0 || crop.top < 0 || crop.right > fullImageWidth ||
      crop.bottom > fullImageHeight || crop.right <= crop.left || crop.bottom <= crop.top) {
      throw new Error('题图裁剪区域无效')
    }
  }

  private static validateSafeIdentifier(value: string, label: string): void {
    if (value.length === 0) {
      throw new Error(label + '无效')
    }
    if (!QuestionImageService.isSafeIdentifierValue(value)) {
      throw new Error(label + '包含不安全字符')
    }
  }

  private static isSafeIdentifierValue(value: string): boolean {
    if (value.length === 0) {
      return false
    }
    for (let index: number = 0; index < value.length; index++) {
      if (!QuestionImageService.isSafeIdentifierCode(value.charCodeAt(index))) {
        return false
      }
    }
    return true
  }

  private static isSafeIdentifierCode(code: number): boolean {
    return code >= 48 && code <= 57 || code >= 65 && code <= 90 || code >= 97 && code <= 122 ||
      code === 45 || code === 95
  }

  private static isServiceCachePath(cacheDir: string, path: string): boolean {
    if (!QuestionImageService.isNormalizedDescendant(path, cacheDir)) {
      return false
    }
    const name: string = path.substring(cacheDir.length + 1)
    return QuestionImageService.isCleanupCandidateName(name)
  }

  private static isDirectServiceImagePath(directory: string, path: string): boolean {
    if (!QuestionImageService.isNormalizedDescendant(path, directory)) {
      return false
    }
    const name: string = path.substring(directory.length + 1)
    return name.indexOf('/') < 0 && QuestionImageService.isCleanupCandidateName(name)
  }

  private static fileName(path: string): string {
    const separatorIndex: number = path.lastIndexOf('/')
    return separatorIndex >= 0 ? path.substring(separatorIndex + 1) : path
  }

  private static isCleanupCandidateName(name: string): boolean {
    if (name.indexOf('/') >= 0 || name.indexOf('\\') >= 0 || !name.startsWith('pdf_question_') ||
      !name.endsWith('.jpg')) {
      return false
    }
    const safeEnd: number = name.length - 4
    if (safeEnd <= 'pdf_question_'.length) {
      return false
    }
    for (let index: number = 0; index < safeEnd; index++) {
      const code: number = name.charCodeAt(index)
      if (!QuestionImageService.isSafeIdentifierCode(code)) {
        return false
      }
    }
    return true
  }

  private static ownedDeletionRoot(context: Context, path: string): string {
    const committedRoot: string = context.filesDir + '/question_images'
    if (QuestionImageService.isDirectServiceImagePath(context.cacheDir, path)) {
      return context.cacheDir
    }
    if (!QuestionImageService.isNormalizedDescendant(path, committedRoot)) {
      return ''
    }
    const relative: string = path.substring(committedRoot.length + 1)
    const parts: Array<string> = relative.split('/')
    if (parts.length !== 2 || !QuestionImageService.isSafeIdentifierValue(parts[0]) ||
      !QuestionImageService.isCleanupCandidateName(parts[1])) {
      return ''
    }
    return context.filesDir
  }

  private static async lstatIfPresent(path: string): Promise<fs.Stat | null> {
    return new Promise<fs.Stat | null>((resolve, reject): void => {
      fs.lstat(path, (err: BusinessError, info: fs.Stat): void => {
        if (err) {
          if (err.code === 13900002) {
            resolve(null)
            return
          }
          reject(new Error(QuestionImageService.errorMessage(err, '文件状态读取失败')))
          return
        }
        resolve(info)
      })
    })
  }

  private static async validateDirectory(path: string): Promise<void> {
    const info: fs.Stat | null = await QuestionImageService.lstatIfPresent(path)
    if (info === null) {
      throw new Error('受信目录不存在')
    }
    if (QuestionImageService.isSymbolicLink(info) || !QuestionImageService.isDirectory(info)) {
      throw new Error('受信目录类型无效')
    }
  }

  private static async validateExistingFileChain(root: string, path: string): Promise<boolean> {
    if (!QuestionImageService.isNormalizedDescendant(path, root)) {
      throw new Error('文件路径超出受信目录')
    }
    await QuestionImageService.validateDirectory(root)
    const relative: string = path.substring(root.length + 1)
    const parts: Array<string> = relative.split('/')
    let currentPath: string = root
    for (let index: number = 0; index < parts.length; index++) {
      currentPath += '/' + parts[index]
      const info: fs.Stat | null = await QuestionImageService.lstatIfPresent(currentPath)
      if (info === null) {
        return false
      }
      if (QuestionImageService.isSymbolicLink(info)) {
        throw new Error('文件路径包含符号链接')
      }
      if (index < parts.length - 1 && !QuestionImageService.isDirectory(info)) {
        throw new Error('文件路径中间节点不是目录')
      }
      if (index === parts.length - 1 && !QuestionImageService.isFile(info)) {
        throw new Error('目标不是普通文件')
      }
    }
    return true
  }

  private static async validateExistingDirectoryChain(root: string, path: string): Promise<void> {
    if (!QuestionImageService.isNormalizedDescendant(path, root)) {
      throw new Error('目录路径超出受信目录')
    }
    await QuestionImageService.validateDirectory(root)
    const relative: string = path.substring(root.length + 1)
    const parts: Array<string> = relative.split('/')
    let currentPath: string = root
    for (let index: number = 0; index < parts.length; index++) {
      currentPath += '/' + parts[index]
      const info: fs.Stat | null = await QuestionImageService.lstatIfPresent(currentPath)
      if (info === null || QuestionImageService.isSymbolicLink(info) ||
        !QuestionImageService.isDirectory(info)) {
        throw new Error('目录路径包含不安全节点')
      }
    }
  }

  private static async ensureDirectDirectory(parent: string, path: string): Promise<void> {
    await QuestionImageService.validateDirectory(parent)
    if (!QuestionImageService.isNormalizedDescendant(path, parent) ||
      path.substring(parent.length + 1).indexOf('/') >= 0) {
      throw new Error('内部目录路径无效')
    }
    let info: fs.Stat | null = await QuestionImageService.lstatIfPresent(path)
    if (info === null) {
      try {
        await fs.mkdir(path)
        info = await fs.lstat(path)
      } catch (err) {
        throw new Error(QuestionImageService.errorMessage(err, '内部目录创建失败'))
      }
    }
    if (QuestionImageService.isSymbolicLink(info) || !QuestionImageService.isDirectory(info)) {
      throw new Error('内部目录类型无效')
    }
  }

  private static isSymbolicLink(info: fs.Stat): boolean {
    try {
      return info.isSymbolicLink()
    } catch (err) {
      throw new Error(QuestionImageService.errorMessage(err, '符号链接状态读取失败'))
    }
  }

  private static isDirectory(info: fs.Stat): boolean {
    try {
      return info.isDirectory()
    } catch (err) {
      throw new Error(QuestionImageService.errorMessage(err, '目录状态读取失败'))
    }
  }

  private static isFile(info: fs.Stat): boolean {
    try {
      return info.isFile()
    } catch (err) {
      throw new Error(QuestionImageService.errorMessage(err, '文件状态读取失败'))
    }
  }

  private static isNormalizedDescendant(path: string, root: string): boolean {
    const prefix: string = root + '/'
    if (!path.startsWith(prefix) || path.length <= prefix.length || path.indexOf('\\') >= 0 ||
      path.indexOf(String.fromCharCode(0)) >= 0) {
      return false
    }
    const relative: string = path.substring(prefix.length)
    if (relative.startsWith('/') || relative.endsWith('/') || relative.indexOf('//') >= 0 ||
      relative === '.' || relative === '..' || relative.startsWith('../') || relative.endsWith('/..') ||
      relative.indexOf('/../') >= 0 || relative.startsWith('./') || relative.endsWith('/.') ||
      relative.indexOf('/./') >= 0) {
      return false
    }
    return true
  }

  private static clamp(value: number, minimum: number, maximum: number): number {
    if (value < minimum) {
      return minimum
    }
    if (value > maximum) {
      return maximum
    }
    return value
  }

  private static appendDiagnostic(primary: string, diagnostic: string): string {
    return primary.length > 0 ? primary + '；' + diagnostic : diagnostic
  }

  private static errorMessage(err: Error, fallback: string): string {
    return err instanceof Error && err.message.length > 0 ? err.message : fallback
  }
}
