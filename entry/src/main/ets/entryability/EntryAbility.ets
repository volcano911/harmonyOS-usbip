import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x3200;
const TAG = 'UsbIp';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index');
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowSystemBarProperties({
        statusBarColor: '#F2F2F7',
        statusBarContentColor: '#000000',
        navigationBarColor: '#F2F2F7',
        navigationBarContentColor: '#000000',
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
    }
  }

  onForeground(): void {
  }

  onBackground(): void {
  }
}
