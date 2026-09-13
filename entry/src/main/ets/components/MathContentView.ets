import { webview } from '@kit.ArkWeb'
import { themePalette } from '../constants/AppTheme'
import { MathContentUtils } from '../utils/MathContentUtils'

class MathContentBridge {
  private content: string = ''
  private fontSize: number = 16
  private fontWeight: number = 400
  private textColor: string = ''
  private lineHeight: number = 24
  private generation: number = 0
  private successCallback: (generation: number, height: number) => void =
    (_generation: number, _height: number): void => {}
  private failureCallback: (generation: number) => void = (_generation: number): void => {}

  bind(successCallback: (generation: number, height: number) => void,
    failureCallback: (generation: number) => void): void {
    this.successCallback = successCallback
    this.failureCallback = failureCallback
  }

  update(content: string, fontSize: number, fontWeight: number, textColor: string, lineHeight: number,
    generation: number): void {
    this.content = content
    this.fontSize = fontSize
    this.fontWeight = fontWeight
    this.textColor = textColor
    this.lineHeight = lineHeight
    this.generation = generation
  }

  getContent(): string {
    return this.content
  }

  getFontSize(): number {
    return this.fontSize
  }

  getFontWeight(): number {
    return this.fontWeight
  }

  getTextColor(): string {
    return this.textColor
  }

  getLineHeight(): number {
    return this.lineHeight
  }

  getGeneration(): number {
    return this.generation
  }

  reportSuccess(generation: number, height: number): void {
    this.successCallback(generation, height)
  }

  reportFailure(generation: number): void {
    this.failureCallback(generation)
  }
}

@Component
export struct MathContentView {
  @Prop @Watch('onContentChanged') content: string = ''
  @Prop @Watch('onStyleChanged') fontSize: number = 16
  @Prop @Watch('onStyleChanged') fontWeight: number = 400
  @Prop @Watch('onStyleChanged') textColor: string = ''
  @Prop @Watch('onStyleChanged') lineHeight: number = 24
  @StorageProp('darkMode') @Watch('onStyleChanged') darkMode: boolean = false
  @State webHeight: number = 24
  @State renderReady: boolean = false
  @State renderFailed: boolean = false
  private controller: webview.WebviewController = new webview.WebviewController()
  private bridge: MathContentBridge = new MathContentBridge()
  private pageReady: boolean = false
  private lastContainsMath: boolean = false
  private renderGeneration: number = 0

  aboutToAppear(): void {
    this.bridge.bind(
      (generation: number, height: number): void => {
        this.handleRenderSuccess(generation, height)
      },
      (generation: number): void => {
        this.handleRenderFailure(generation)
      }
    )
    this.lastContainsMath = MathContentUtils.containsMath(this.content)
    this.webHeight = this.safeLineHeight()
    this.advanceGeneration()
    this.updateBridge()
  }

  aboutToDisappear(): void {
    this.advanceGeneration()
  }

  private resolvedTextColor(): string {
    return this.textColor.length > 0 ? this.textColor : themePalette(this.darkMode).textPrimary
  }

  private safeLineHeight(): number {
    return this.lineHeight > 0 ? this.lineHeight : 24
  }

  private advanceGeneration(): void {
    this.renderGeneration++
  }

  private updateBridge(): void {
    this.bridge.update(
      this.content,
      this.fontSize > 0 ? this.fontSize : 16,
      this.fontWeight > 0 ? this.fontWeight : 400,
      this.resolvedTextColor(),
      this.safeLineHeight(),
      this.renderGeneration
    )
  }

  private onContentChanged(): void {
    const containsMath: boolean = MathContentUtils.containsMath(this.content)
    if (containsMath !== this.lastContainsMath) {
      this.pageReady = false
    }
    this.lastContainsMath = containsMath
    this.renderReady = false
    this.renderFailed = false
    this.webHeight = this.safeLineHeight()
    this.advanceGeneration()
    this.updateBridge()
    if (containsMath && this.pageReady) {
      this.requestRender()
    }
  }

  private onStyleChanged(): void {
    this.advanceGeneration()
    this.updateBridge()
    if (this.lastContainsMath && this.pageReady && !this.renderFailed) {
      this.renderReady = false
      this.requestRender()
    }
  }

  private requestRender(): void {
    const generation: number = this.renderGeneration
    this.controller.runJavaScript('window.renderMathContent()').catch((): void => {
      this.handleRenderFailure(generation)
    })
  }

  private handleRenderSuccess(generation: number, height: number): void {
    if (generation !== this.renderGeneration || !this.lastContainsMath || this.renderFailed || height <= 0) {
      return
    }
    this.webHeight = Math.max(Math.ceil(height), this.safeLineHeight())
    this.renderReady = true
  }

  private handleRenderFailure(generation: number): void {
    if (generation !== this.renderGeneration) {
      return
    }
    this.pageReady = false
    this.renderReady = false
    this.renderFailed = true
  }

  private interceptNavigation(event: OnLoadInterceptEvent): boolean {
    const requestUrl: string = event.data.getRequestUrl()
    return !requestUrl.startsWith('resource://rawfile/math/')
  }

  @Builder
  private NativeFallback() {
    Text(this.content)
      .width('100%')
      .fontSize(this.fontSize)
      .fontWeight(this.fontWeight)
      .fontColor(this.resolvedTextColor())
      .lineHeight(this.safeLineHeight())
  }

  build() {
    if (!MathContentUtils.containsMath(this.content) || this.renderFailed) {
      this.NativeFallback()
    } else {
      Stack({ alignContent: Alignment.TopStart }) {
        if (!this.renderReady) {
          this.NativeFallback()
        }

        Web({
          src: $rawfile('math/math-content.html'),
          controller: this.controller
        })
          .width('100%')
          .height(this.webHeight)
          .opacity(this.renderReady ? 1 : 0)
          .backgroundColor(Color.Transparent)
          .javaScriptAccess(true)
          .fileAccess(false)
          .onlineImageAccess(false)
          .domStorageAccess(false)
          .geolocationAccess(false)
          .mixedMode(MixedMode.None)
          .zoomAccess(false)
          .horizontalScrollBarAccess(false)
          .verticalScrollBarAccess(false)
          .javaScriptProxy({
            object: this.bridge,
            name: 'mathBridge',
            methodList: [
              'getContent',
              'getFontSize',
              'getFontWeight',
              'getTextColor',
              'getLineHeight',
              'getGeneration',
              'reportSuccess',
              'reportFailure'
            ],
            controller: this.controller
          })
          .onControllerAttached((): void => {
            this.updateBridge()
          })
          .onPageEnd((): void => {
            this.pageReady = true
            this.updateBridge()
            this.requestRender()
          })
          .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
            return this.interceptNavigation(event)
          })
          .onErrorReceive((): void => {
            this.handleRenderFailure(this.renderGeneration)
          })
      }
      .width('100%')
    }
  }
}
