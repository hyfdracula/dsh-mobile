import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import wantAgent from '@ohos.app.ability.wantAgent';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'DshMobile';

export default class EntryAbility extends UIAbility {
  /** 后台长时任务是否已启动，避免重复申请 */
  private keeping: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onCreate');
    this.takeSession(want);
  }

  /** 通知点击（应用已在后台时走这里） */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onNewWant');
    this.takeSession(want);
  }

  /**
   * 从通知的 want 里取出会话 id，交给界面跳转。
   * AppStorage 在 onCreate 早期可能还没建好，所以延后一拍写。
   */
  private takeSession(want: Want): void {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return;
    }
    const raw: Object | undefined = params.sessionId;
    const id: string = raw === undefined ? '' : String(raw);
    if (id === '') {
      return;
    }
    setTimeout(() => {
      AppStorage.setOrCreate('openSession', id);
      hilog.info(0x0000, TAG, 'open session from notification: %{public}s', id);
    }, 200);
  }

  /**
   * 退到后台时申请长时任务。
   *
   * 通知依赖 12 秒一次的轮询来发现「跑完了」，而应用退到后台后 JS 定时器会被
   * 冻结。拉起 DATA_TRANSFER 长时任务可以让轮询继续跑，任务完成时照常弹通知。
   */
  onBackground(): void {
    this.startKeepAlive();
  }

  onForeground(): void {
    this.stopKeepAlive();
  }

  private async startKeepAlive(): Promise<void> {
    if (this.keeping) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: 'com.dsh.mobile',
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 7,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: object = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent
      );
      this.keeping = true;
      hilog.info(0x0000, TAG, 'keepAlive start ok');
    } catch (e) {
      hilog.error(0x0000, TAG, 'keepAlive start failed: %{public}s', JSON.stringify(e));
    }
  }

  private async stopKeepAlive(): Promise<void> {
    if (!this.keeping) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      hilog.info(0x0000, TAG, 'keepAlive stop ok');
    } catch (e) {
      hilog.error(0x0000, TAG, 'keepAlive stop failed: %{public}s', JSON.stringify(e));
    }
    this.keeping = false;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {

    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).then(() => {
        hilog.info(0x0000, TAG, 'layoutFullScreen ok');
      }).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'layoutFullScreen failed: %{public}s', JSON.stringify(e));
      });
      win.setWindowSystemBarEnable(['status']).then(() => {
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
