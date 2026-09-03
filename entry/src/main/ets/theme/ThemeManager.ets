import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { AppColors } from './AppColors'
import { DarkColors } from './DarkColors'
import { LightColors } from './LightColors'

const DOMAIN: number = 0x0000
const TAG: string = 'WQC_THEME'

export enum ThemeMode {
  SYSTEM = 0,
  LIGHT = 1,
  DARK = 2
}

const MODE_STORAGE_KEY: string = 'themeMode'
const SYSTEM_DARK_STORAGE_KEY: string = 'systemDark'
const DARK_STORAGE_KEY: string = 'darkMode'
const STORE_NAME: string = 'app_settings'
const STORE_MODE_KEY: string = 'themeMode'

export class ThemeManager {
  static palette(dark: boolean): AppColors {
    return dark ? DarkColors.INSTANCE : LightColors.INSTANCE
  }

  static modeLabel(mode: ThemeMode): string {
    if (mode === ThemeMode.LIGHT) {
      return '浅色'
    }
    if (mode === ThemeMode.DARK) {
      return '深色'
    }
    return '跟随系统'
  }

  static isSystemDark(context: common.UIAbilityContext): boolean {
    return context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
  }

  static initialize(context: common.UIAbilityContext, onApplied: () => void): void {
    AppStorage.setOrCreate(SYSTEM_DARK_STORAGE_KEY, ThemeManager.isSystemDark(context))
    preferences.getPreferences(context, STORE_NAME)
      .then((store: preferences.Preferences) => {
        return store.get(STORE_MODE_KEY, ThemeMode.SYSTEM)
      })
      .then((value: preferences.ValueType) => {
        AppStorage.setOrCreate(MODE_STORAGE_KEY, ThemeManager.normalize(value))
        ThemeManager.syncDark()
        ThemeManager.applyColorMode(context, ThemeManager.currentMode())
        onApplied()
      })
      .catch(() => {
        AppStorage.setOrCreate(MODE_STORAGE_KEY, ThemeMode.SYSTEM)
        ThemeManager.syncDark()
        ThemeManager.applyColorMode(context, ThemeMode.SYSTEM)
        onApplied()
      })
  }

  static setMode(context: common.Context, mode: ThemeMode): void {
    AppStorage.setOrCreate(MODE_STORAGE_KEY, mode)
    ThemeManager.syncDark()
    ThemeManager.applyColorMode(context, mode)
    preferences.getPreferences(context, STORE_NAME)
      .then((store: preferences.Preferences) => {
        store.putSync(STORE_MODE_KEY, mode)
        return store.flush()
      })
      .catch(() => {
      })
  }

  static onSystemDarkChanged(systemDark: boolean): void {
    AppStorage.setOrCreate(SYSTEM_DARK_STORAGE_KEY, systemDark)
    ThemeManager.syncDark()
  }

  static currentMode(): ThemeMode {
    const value: number | undefined = AppStorage.get<number>(MODE_STORAGE_KEY)
    return ThemeManager.normalizeNumber(value)
  }

  static effectiveDark(): boolean {
    return AppStorage.get<boolean>(DARK_STORAGE_KEY) === true
  }

  private static normalize(value: preferences.ValueType): ThemeMode {
    if (typeof value === 'number') {
      return ThemeManager.normalizeNumber(value)
    }
    return ThemeMode.SYSTEM
  }

  private static normalizeNumber(value: number | undefined): ThemeMode {
    if (value === ThemeMode.LIGHT || value === ThemeMode.DARK) {
      return value
    }
    return ThemeMode.SYSTEM
  }

  private static syncDark(): void {
    const mode: ThemeMode = ThemeManager.currentMode()
    const systemDark: boolean = AppStorage.get<boolean>(SYSTEM_DARK_STORAGE_KEY) === true
    const dark: boolean = mode === ThemeMode.DARK || (mode === ThemeMode.SYSTEM && systemDark)
    AppStorage.setOrCreate(DARK_STORAGE_KEY, dark)
  }

  private static applyColorMode(context: common.Context, mode: ThemeMode): void {
    try {
      if (mode === ThemeMode.DARK) {
        context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
      } else if (mode === ThemeMode.LIGHT) {
        context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT)
      } else {
        context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET)
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to apply color mode. Cause: %{public}s', JSON.stringify(err))
    }
  }
}
