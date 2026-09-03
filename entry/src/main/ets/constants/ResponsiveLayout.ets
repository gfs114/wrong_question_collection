import { Context } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { BusinessError } from '@kit.BasicServicesKit'
import { CONTENT_MAX_WIDTH } from './AppTheme'

/**
 * 统一窗口尺寸分类。依据华为官方栅格系统默认断点
 * （HarmonyOS 栅格布局文档：xs [0,320)、sm [320,600)、md [600,840)、lg [840,+∞)，
 * 默认断点数组为 ['320vp', '600vp', '840vp']）合并为三档：
 * - COMPACT  窗口宽度 < 600vp（官方 xs + sm）：单列、小 padding、卡片 100% 宽。
 * - MEDIUM   600vp <= 窗口宽度 < 840vp（官方 md）：单列为主，内容宽度放宽，统计区可多列。
 * - EXPANDED 窗口宽度 >= 840vp（官方 lg 及以上）：充分利用宽屏，部分区域双列或 Grid。
 */
export enum WindowSizeClass {
  COMPACT,
  MEDIUM,
  EXPANDED
}

export class ResponsiveLayout {
  /** 官方默认断点：MEDIUM 起点 600vp、EXPANDED 起点 840vp。 */
  static readonly BREAKPOINT_MEDIUM: number = 600
  static readonly BREAKPOINT_EXPANDED: number = 840
  /** EXPANDED 档内容区上限，避免文字行被无限拉长。 */
  static readonly EXPANDED_CONTENT_MAX_WIDTH: number = 1160

  static classify(windowWidthVp: number): WindowSizeClass {
    if (windowWidthVp >= ResponsiveLayout.BREAKPOINT_EXPANDED) {
      return WindowSizeClass.EXPANDED
    }
    if (windowWidthVp >= ResponsiveLayout.BREAKPOINT_MEDIUM) {
      return WindowSizeClass.MEDIUM
    }
    return WindowSizeClass.COMPACT
  }

  static isCompact(sizeClass: WindowSizeClass): boolean {
    return sizeClass === WindowSizeClass.COMPACT
  }

  static isExpanded(sizeClass: WindowSizeClass): boolean {
    return sizeClass === WindowSizeClass.EXPANDED
  }

  static contentMaxWidth(sizeClass: WindowSizeClass): number {
    if (ResponsiveLayout.isCompact(sizeClass)) {
      return CONTENT_MAX_WIDTH
    }
    return ResponsiveLayout.EXPANDED_CONTENT_MAX_WIDTH
  }
}

/**
 * 官方窗口尺寸监听封装（window.on('windowSizeChange')）。
 * 窗口拖动、1:1/18:9 切换、全屏、分屏、横竖屏都会触发官方事件，
 * 回调参数为换算成 vp 的窗口宽度；stop() 必须在组件 aboutToDisappear 中调用。
 */
export class WindowSizeObserver {
  private callback: (windowWidthVp: number) => void
  private windowInstance: window.Window | undefined = undefined
  private startToken: number = 0
  private sizeListener: (size: window.Size) => void = (size: window.Size): void => {
    this.onWindowSizeChanged(size)
  }

  constructor(callback: (windowWidthVp: number) => void) {
    this.callback = callback
  }

  start(context: Context): void {
    this.startToken = this.startToken + 1
    const token: number = this.startToken
    window.getLastWindow(context, (err: BusinessError, win: window.Window): void => {
      if (err.code !== 0) {
        return
      }
      if (token !== this.startToken) {
        return
      }
      this.windowInstance = win
      const rect: window.Rect = win.getWindowProperties().windowRect
      const size: window.Size = { width: rect.width, height: rect.height }
      this.onWindowSizeChanged(size)
      this.windowInstance.on('windowSizeChange', this.sizeListener)
    })
  }

  stop(): void {
    this.startToken = this.startToken + 1
    if (this.windowInstance === undefined) {
      return
    }
    this.windowInstance.off('windowSizeChange', this.sizeListener)
    this.windowInstance = undefined
  }

  private onWindowSizeChanged(size: window.Size): void {
    this.callback(px2vp(size.width))
  }
}
