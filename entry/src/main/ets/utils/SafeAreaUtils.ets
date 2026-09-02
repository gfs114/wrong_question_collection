/**
 * Safe-area inset shape maintained by the framework under the AppStorage key
 * 'safeAreaInsets' (values in vp). Declared locally because this SDK version
 * does not expose a global SafeAreaInsets type.
 */
export interface SafeAreaInsets {
  top: Length
  left: Length
  right: Length
  bottom: Length
}

/**
 * Safe-area inset extraction helpers for the immersive full-screen layout.
 *
 * The framework maintains the AppStorage key 'safeAreaInsets'. Components bind
 * it with @StorageProp('safeAreaInsets') and convert the Length fields into
 * plain numbers here, so paddings can adapt to the status bar, the
 * navigation/gesture bar and cutouts without hard-coded device-specific
 * values.
 */
export class SafeAreaUtils {
  static top(insets: SafeAreaInsets): number {
    const value: Length = insets.top
    return typeof value === 'number' ? value : 0
  }

  static bottom(insets: SafeAreaInsets): number {
    const value: Length = insets.bottom
    return typeof value === 'number' ? value : 0
  }
}
