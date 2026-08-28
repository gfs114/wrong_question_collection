import { textRecognition } from '@kit.CoreVisionKit'
import { image } from '@kit.ImageKit'
import { OcrLine } from '../models/PdfImportModels'
import { OcrLifecycleState, OcrRecognitionOperation } from '../utils/OcrLifecycleState'

export class OnDeviceOcrService {
  private static instance: OnDeviceOcrService = new OnDeviceOcrService()
  private static initializePromise: Promise<void> | null = null
  private static releasePromise: Promise<void> | null = null
  private lifecycle: OcrLifecycleState = new OcrLifecycleState()

  private constructor() {
  }

  static shared(): OnDeviceOcrService {
    return OnDeviceOcrService.instance
  }

  async initialize(): Promise<void> {
    while (true) {
      const state: string = this.lifecycle.currentState()
      if (state === 'ready') {
        this.lifecycle.requireReady()
        return
      }
      if (state === 'initializing') {
        const pendingInitialization: Promise<void> | null = OnDeviceOcrService.initializePromise
        if (pendingInitialization === null) {
          throw new Error('端侧文字识别初始化状态异常')
        }
        await pendingInitialization
        this.lifecycle.requireReady()
        return
      }
      if (state === 'releasing') {
        const pendingRelease: Promise<void> | null = OnDeviceOcrService.releasePromise
        if (pendingRelease === null) {
          throw new Error('端侧文字识别释放状态异常')
        }
        try {
          await pendingRelease
        } catch (err) {
          if (this.lifecycle.currentState() !== 'ready') {
            throw new Error(OnDeviceOcrService.errorMessage(err, '端侧文字识别释放失败'))
          }
        }
        continue
      }
      if (state !== 'idle') {
        throw new Error('端侧文字识别生命周期状态异常')
      }
      this.lifecycle.startInitialization()
      const transition: Promise<void> = this.performInitialize()
      OnDeviceOcrService.initializePromise = transition
      try {
        await transition
      } finally {
        if (OnDeviceOcrService.initializePromise === transition) {
          OnDeviceOcrService.initializePromise = null
        }
      }
      this.lifecycle.requireReady()
      return
    }
  }

  async recognize(pixelMap: image.PixelMap, pageNumber: number): Promise<Array<OcrLine>> {
    await this.waitUntilReady()
    const operation: OcrRecognitionOperation = this.lifecycle.beginRecognition()
    try {
      const visionInfo: textRecognition.VisionInfo = {
        pixelMap: pixelMap
      }
      const configuration: textRecognition.TextRecognitionConfiguration = {
        isDirectionDetectionSupported: true
      }
      let result: textRecognition.TextRecognitionResult
      try {
        result = await textRecognition.recognizeText(visionInfo, configuration)
      } catch (err) {
        throw new Error('端侧文字识别失败：' + OnDeviceOcrService.errorMessage(err, '未知错误'))
      }
      const lines: Array<OcrLine> = new Array<OcrLine>()
      const blocks: Array<textRecognition.TextBlock> = result.blocks
      for (let blockIndex: number = 0; blockIndex < blocks.length; blockIndex++) {
        const block: textRecognition.TextBlock = blocks[blockIndex]
        for (let lineIndex: number = 0; lineIndex < block.lines.length; lineIndex++) {
          const line: textRecognition.TextLine = block.lines[lineIndex]
          const value: string = line.value.trim()
          if (value.length === 0 || line.cornerPoints.length === 0) {
            continue
          }
          let left: number = line.cornerPoints[0].x
          let top: number = line.cornerPoints[0].y
          let right: number = line.cornerPoints[0].x
          let bottom: number = line.cornerPoints[0].y
          for (let pointIndex: number = 1; pointIndex < line.cornerPoints.length; pointIndex++) {
            const point: textRecognition.PixelPoint = line.cornerPoints[pointIndex]
            left = Math.min(left, point.x)
            top = Math.min(top, point.y)
            right = Math.max(right, point.x)
            bottom = Math.max(bottom, point.y)
          }
          if (!Number.isFinite(left) || !Number.isFinite(top) || !Number.isFinite(right) ||
            !Number.isFinite(bottom) || right <= left || bottom <= top) {
            continue
          }
          lines.push(new OcrLine(value, pageNumber, left, top, right, bottom))
        }
      }
      return lines
    } finally {
      operation.complete()
    }
  }

  async release(): Promise<void> {
    while (true) {
      const state: string = this.lifecycle.currentState()
      if (state === 'idle') {
        this.lifecycle.requireIdle()
        return
      }
      if (state === 'initializing') {
        const pendingInitialization: Promise<void> | null = OnDeviceOcrService.initializePromise
        if (pendingInitialization === null) {
          throw new Error('端侧文字识别初始化状态异常')
        }
        try {
          await pendingInitialization
        } catch (err) {
          if (this.lifecycle.currentState() === 'idle') {
            this.lifecycle.requireIdle()
            return
          }
          throw new Error(OnDeviceOcrService.errorMessage(err, '端侧文字识别初始化失败'))
        }
        continue
      }
      if (state === 'releasing') {
        const pendingRelease: Promise<void> | null = OnDeviceOcrService.releasePromise
        if (pendingRelease === null) {
          throw new Error('端侧文字识别释放状态异常')
        }
        try {
          await pendingRelease
        } catch (err) {
          if (this.lifecycle.currentState() !== 'ready') {
            throw new Error('端侧文字识别释放状态异常')
          }
          throw new Error(OnDeviceOcrService.errorMessage(err, '端侧文字识别释放失败'))
        }
        this.lifecycle.requireIdle()
        return
      }
      if (state !== 'ready') {
        throw new Error('端侧文字识别生命周期状态异常')
      }
      const transition: Promise<void> = this.performRelease()
      OnDeviceOcrService.releasePromise = transition
      try {
        await transition
      } finally {
        if (OnDeviceOcrService.releasePromise === transition) {
          OnDeviceOcrService.releasePromise = null
        }
      }
      this.lifecycle.requireIdle()
      return
    }
  }

  private async waitUntilReady(): Promise<void> {
    while (true) {
      const state: string = this.lifecycle.currentState()
      if (state === 'ready') {
        this.lifecycle.requireReady()
        return
      }
      if (state === 'initializing') {
        const pendingInitialization: Promise<void> | null = OnDeviceOcrService.initializePromise
        if (pendingInitialization === null) {
          throw new Error('端侧文字识别初始化状态异常')
        }
        await pendingInitialization
        this.lifecycle.requireReady()
        return
      }
      if (state === 'releasing') {
        const pendingRelease: Promise<void> | null = OnDeviceOcrService.releasePromise
        if (pendingRelease === null) {
          throw new Error('端侧文字识别释放状态异常')
        }
        try {
          await pendingRelease
        } catch (err) {
          if (this.lifecycle.currentState() !== 'ready') {
            throw new Error(OnDeviceOcrService.errorMessage(err, '端侧文字识别释放失败'))
          }
        }
        continue
      }
      throw new Error('端侧文字识别服务尚未初始化')
    }
  }

  private async performInitialize(): Promise<void> {
    try {
      const initialized: boolean = await textRecognition.init()
      if (!initialized) {
        throw new Error('端侧文字识别服务初始化失败')
      }
      this.lifecycle.finishInitialization(true)
    } catch (err) {
      this.lifecycle.finishInitialization(false)
      throw new Error(OnDeviceOcrService.errorMessage(err, '端侧文字识别服务初始化失败'))
    }
  }

  private async performRelease(): Promise<void> {
    let releaseError: string = ''
    await this.lifecycle.beginRelease()
    try {
      if (this.lifecycle.currentState() !== 'releasing') {
        throw new Error('端侧文字识别释放状态异常')
      }
    } finally {
      try {
        await textRecognition.release()
        this.lifecycle.finishRelease(true)
      } catch (err) {
        if (this.lifecycle.currentState() === 'releasing') {
          this.lifecycle.finishRelease(false)
        }
        releaseError = OnDeviceOcrService.errorMessage(err, '端侧文字识别服务释放失败')
      }
    }
    if (releaseError.length > 0) {
      throw new Error(releaseError)
    }
  }

  private static errorMessage(err: Error, fallback: string): string {
    return err instanceof Error && err.message.length > 0 ? err.message : fallback
  }
}
