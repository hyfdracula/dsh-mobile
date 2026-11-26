import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Adaptive } from '../common/Adaptive';
import { AppCtx } from '../common/AppCtx';
import { Drafts } from '../common/Drafts';
import { Marks } from '../common/Marks';
import { Net } from '../common/Net';
import { SafeArea } from '../common/SafeArea';

const TAG: string = 'AgentMobile';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onCreate');
    AppCtx.bindAbility(this.context);
    if (this.context.config !== undefined && this.context.config.colorMode !== undefined) {
      AppStorage.setOrCreate('sysDark',
        this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    }
    this.takeSession(want);
  }

  /** 通知点击（应用已在后台时走这里） */
  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onNewWant');
    this.takeSession(want);
  }

  /** 系统深浅色变更时同步到 AppStorage，供跟随系统主题实时刷新 */
  onConfigurationUpdate(newConfig: Configuration): void {
    if (newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ||
      newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      const isDark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      AppStorage.setOrCreate('sysDark', isDark);
      AppStorage.setOrCreate('sysConfigTick', Date.now());
    }
  }

  /**
   * 同步写入通知跳转的 sessionId，由 ShellPage 在挂载及 @Watch 时消费，避免定时竞态。
   */
  private takeSession(want: Want): void {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return;
    }
    const raw: Object | undefined = params.sessionId;
    const id: string = raw === undefined ? '' : String(raw).trim();
    if (id === '') {
      return;
    }
    AppStorage.setOrCreate('openSessionReq', id + '|' + Date.now());
    hilog.info(0x0000, TAG, 'open session from notification');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    AppCtx.bindAbility(this.context);
    void this.setupWindow(windowStage);
  }

  private async setupWindow(windowStage: window.WindowStage): Promise<void> {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      AppCtx.bindWindow(win);
      try {
        await win.setWindowLayoutFullScreen(true);
      } catch (e) {
        hilog.error(0x0000, TAG, 'layoutFullScreen failed: %{public}s', JSON.stringify(e));
      }
      SafeArea.attach(win);
      Adaptive.attach(win);
      win.setWindowSystemBarEnable(['status']).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'barEnable failed: %{public}s', JSON.stringify(e));
      });
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(0x0000, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
          return;
        }
        AppCtx.bindWindow(win);
        SafeArea.attach(win);
        Adaptive.attach(win);
        SafeArea.setKeyboardResize(win);
      });
    } catch (err) {
      hilog.error(0x0000, TAG, 'window setup failed: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    Drafts.flush();
    Marks.flush();
    Adaptive.detach();
    SafeArea.detach();
    Net.stop();
    AppCtx.clearWindow();
    hilog.info(0x0000, TAG, 'Ability onDestroy');
  }
}
