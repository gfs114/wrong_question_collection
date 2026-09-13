import { AbilityConstant, common, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { HdsMaterialPolicy } from '../constants/HdsMaterialPolicy';
import { AppColors } from '../theme/AppColors';
import { ThemeManager } from '../theme/ThemeManager';
import { SafeAreaUtils } from '../utils/SafeAreaUtils';
import { AiImportSaveService } from '../services/ai/AiImportSaveService';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined
  private aiImportRecoveryInProgress: boolean = false
  // 避让区变化（旋转、分屏、自由窗口缩放）后重新发布，页面无需各自处理。
  private avoidAreaListener: () => void = () => {
    SafeAreaUtils.publishFromWindow(this.mainWindow)
  }
  private windowSizeListener: () => void = () => {
    SafeAreaUtils.publishFromWindow(this.mainWindow)
  }

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
      // 先发布一次真实避让区（状态栏 / 挖孔 / 手势条），再登记变化监听：
      // 页面通过 @StorageProp('safeAreaInsets') 自动避让，换机型与换窗口模式都不需要改代码。
      SafeAreaUtils.publishFromWindow(this.mainWindow);
      this.mainWindow.on('avoidAreaChange', this.avoidAreaListener);
      this.mainWindow.on('windowSizeChange', this.windowSizeListener);
      this.applySystemBars();
      HdsMaterialPolicy.logDeviceSupport();
      hilog.info(DOMAIN, 'testTag', '%{public}s', 'Immersive window layout enabled.');
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to enable immersive layout. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    if (this.mainWindow !== undefined) {
      this.mainWindow.off('avoidAreaChange', this.avoidAreaListener);
      this.mainWindow.off('windowSizeChange', this.windowSizeListener);
      this.mainWindow = undefined;
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    this.resumePendingAiImports()
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
    // 旋转 / 折叠 / 分屏也会走配置更新，这里再对齐一次避让区。
    SafeAreaUtils.publishFromWindow(this.mainWindow)
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

  private resumePendingAiImports(): void {
    if (this.aiImportRecoveryInProgress) return
    this.aiImportRecoveryInProgress = true
    this.runPendingAiImportRecovery()
  }

  private async runPendingAiImportRecovery(): Promise<void> {
    try {
      await AiImportSaveService.recoverPending(this.context)
    } catch {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Pending AI import recovery deferred.')
    } finally {
      this.aiImportRecoveryInProgress = false
    }
  }
}
