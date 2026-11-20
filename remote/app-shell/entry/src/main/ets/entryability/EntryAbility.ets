import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'DshMobile';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {

    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).then(() => {
        hilog.info(0x0000, TAG, 'layoutFullScreen ok');
      }).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'layoutFullScreen failed: %{public}s', JSON.stringify(e));
      });
      win.setWindowSystemBarEnable([]).then(() => {
        hilog.info(0x0000, TAG, 'barEnable ok');
      }).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'barEnable failed: %{public}s', JSON.stringify(e));
      });
      win.setWindowKeepScreenOn(true).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'keepScreenOn failed: %{public}s', JSON.stringify(e));
      });
      hilog.info(0x0000, TAG, 'window setup done');
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(0x0000, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(0x0000, TAG, 'loadContent ok');
      });
    } catch (err) {
      hilog.error(0x0000, TAG, 'window setup failed: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onDestroy');
  }
}
