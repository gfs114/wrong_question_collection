export type OcrVoidResolver = () => void

export class OcrRecognitionOperation {
  private lifecycle: OcrLifecycleState
  private completed: boolean = false

  constructor(lifecycle: OcrLifecycleState) {
    this.lifecycle = lifecycle
  }

  complete(): void {
    if (this.completed) {
      return
    }
    this.completed = true
    this.lifecycle.finishRecognition()
  }
}

export class OcrLifecycleState {
  private state: string = 'idle'
  private activeRecognitionCount: number = 0
  private recognitionIdlePromise: Promise<void> | null = null
  private recognitionIdleResolver: OcrVoidResolver | null = null

  currentState(): string {
    return this.state
  }

  startInitialization(): void {
    if (this.state !== 'idle') {
      throw new Error('OCR 生命周期无法开始初始化')
    }
    this.state = 'initializing'
  }

  finishInitialization(succeeded: boolean): void {
    if (this.state !== 'initializing') {
      throw new Error('OCR 初始化完成状态无效')
    }
    this.state = succeeded ? 'ready' : 'idle'
  }

  requireReady(): void {
    if (this.state !== 'ready') {
      throw new Error('端侧文字识别服务尚未就绪')
    }
  }

  requireIdle(): void {
    if (this.state !== 'idle') {
      throw new Error('端侧文字识别服务尚未释放')
    }
  }

  beginRecognition(): OcrRecognitionOperation {
    this.requireReady()
    this.activeRecognitionCount++
    return new OcrRecognitionOperation(this)
  }

  finishRecognition(): void {
    if (this.activeRecognitionCount <= 0) {
      throw new Error('OCR 识别操作计数无效')
    }
    this.activeRecognitionCount--
    if (this.activeRecognitionCount === 0 && this.recognitionIdleResolver !== null) {
      const resolver: OcrVoidResolver = this.recognitionIdleResolver
      this.recognitionIdleResolver = null
      this.recognitionIdlePromise = null
      resolver()
    }
  }

  async beginRelease(): Promise<void> {
    if (this.state !== 'ready') {
      throw new Error('OCR 生命周期无法开始释放')
    }
    this.state = 'releasing'
    if (this.activeRecognitionCount > 0) {
      if (this.recognitionIdlePromise === null) {
        this.recognitionIdlePromise = new Promise<void>((resolve: OcrVoidResolver): void => {
          this.recognitionIdleResolver = resolve
        })
      }
      const pendingRecognition: Promise<void> = this.recognitionIdlePromise
      await pendingRecognition
    }
    if (this.state !== 'releasing' || this.activeRecognitionCount !== 0) {
      throw new Error('OCR 释放等待状态无效')
    }
  }

  finishRelease(succeeded: boolean): void {
    if (this.state !== 'releasing' || this.activeRecognitionCount !== 0) {
      throw new Error('OCR 释放完成状态无效')
    }
    this.state = succeeded ? 'idle' : 'ready'
  }
}
