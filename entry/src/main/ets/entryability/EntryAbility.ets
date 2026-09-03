import { AbilityConstant, common, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { HdsMaterialPolicy } from '../constants/HdsMaterialPolicy';
import { AppColors } from '../theme/AppColors';
import { ThemeManager } from '../theme/ThemeManager';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    ThemeManager.initialize(this.context, () => {
      this.applySystemBars()
    })
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    try {
      this.mainWindow = windowStage.getMainWindowSync();
      this.mainWindow.setWindowLayoutFullScreen(true);
      this.mainWindow.setWindowSystemBarEnable(['status', 'navigation']);
      this.applySystemBars();
      HdsMaterialPolicy.logDeviceSupport();
      hilog.info(DOMAIN, 'testTag', '%{public}s', 'Immersive window layout enabled.');
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to enable immersive layout. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    const systemDark: boolean =
      newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
    ThemeManager.onSystemDarkChanged(systemDark)
    this.applySystemBars()
  }

  private applySystemBars(): void {
    if (this.mainWindow === undefined) {
      return
    }
    const colors: AppColors = ThemeManager.palette(ThemeManager.effectiveDark())
    try {
      this.mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: colors.statusBarIcon,
        navigationBarContentColor: colors.statusBarIcon
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to apply system bars. Cause: %{public}s', JSON.stringify(err));
    }
  }
}
