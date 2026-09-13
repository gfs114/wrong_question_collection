import { display, window } from '@kit.ArkUI'
import { hilog } from '@kit.PerformanceAnalysisKit'

/**
 * Safe-area inset shape maintained under the AppStorage key 'safeAreaInsets'
 * (values in vp). Declared locally because this SDK version does not expose a
 * global SafeAreaInsets type.
 */
export interface SafeAreaInsets {
  top: Length
  left: Length
  right: Length
  bottom: Length
}

const DOMAIN = 0x0000

/**
 * Safe-area inset helpers for the immersive full-screen layout.
 *
 * SafeAreaUtils.publishFromWindow() reads the real window avoid areas (status
 * bar, cutout, gesture indicator), converts them from px to vp, and publishes
 * them to AppStorage. Components bind the key with
 * @StorageProp('safeAreaInsets') and convert the Length fields into plain
 * numbers here, so paddings adapt to the device, the window mode and
 * orientation without hard-coded device-specific values.
 */
export class SafeAreaUtils {
  /** AppStorage key shared by every @StorageProp('safeAreaInsets') binding. */
  static readonly STORAGE_KEY: string = 'safeAreaInsets'

  static top(insets: SafeAreaInsets): number {
    const value: Length = insets.top
    return typeof value === 'number' ? value : 0
  }

  static bottom(insets: SafeAreaInsets): number {
    const value: Length = insets.bottom
    return typeof value === 'number' ? value : 0
  }

  static left(insets: SafeAreaInsets): number {
    const value: Length = insets.left
    return typeof value === 'number' ? value : 0
  }

  static right(insets: SafeAreaInsets): number {
    const value: Length = insets.right
    return typeof value === 'number' ? value : 0
  }

  private static toVp(px: number, density: number): number {
    if (density <= 0) {
      return 0
    }
    return Math.round(px / density)
  }

  /**
   * Publishes the main window avoid areas so every bound page clears the
   * status bar, the cutout and the gesture indicator on any device or window
   * mode. Safe to call repeatedly: rotation, freeform resize and window-mode
   * switches republish through the window events registered in EntryAbility.
   */
  static publishFromWindow(win: window.Window | undefined): void {
    if (win === undefined) {
      return
    }
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels
      const system: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
      const cutout: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT)
      const indicator: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)
      const insets: SafeAreaInsets = {
        top: SafeAreaUtils.toVp(Math.max(system.topRect.height, cutout.topRect.height), density),
        left: SafeAreaUtils.toVp(Math.max(system.leftRect.width, cutout.leftRect.width), density),
        right: SafeAreaUtils.toVp(Math.max(system.rightRect.width, cutout.rightRect.width), density),
        bottom: SafeAreaUtils.toVp(Math.max(system.bottomRect.height, indicator.bottomRect.height), density)
      }
      AppStorage.setOrCreate(SafeAreaUtils.STORAGE_KEY, insets)
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'Failed to publish safe-area insets. Cause: %{public}s',
        JSON.stringify(err))
    }
  }
}
