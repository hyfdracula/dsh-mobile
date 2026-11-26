import { bundleManager, common, Want } from '@kit.AbilityKit';
import { display, promptAction, UIContext, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 全局 Ability 与 UI 上下文桥接中心（API 18+ 现代化入口）：
 * 在 EntryAbility 生命周期绑定后，集中提供 UIAbilityContext、UIContext、
 * 弹窗、轻提示、系统浏览器跳转、像素换算与动态包名查询，彻底消除已废弃的全局调用。
 */
export class AppCtx {
  private static abilityCtx: common.UIAbilityContext | null = null;
  private static uiCtx: UIContext | null = null;
  private static mainWin: window.Window | null = null;
  private static cachedBundleName: string = '';

  static bindAbility(ctx: common.UIAbilityContext): void {
    AppCtx.abilityCtx = ctx;
    if (ctx.abilityInfo !== undefined && ctx.abilityInfo.bundleName !== '') {
      AppCtx.cachedBundleName = ctx.abilityInfo.bundleName;
    }
  }

  static bindWindow(win: window.Window): void {
    AppCtx.mainWin = win;
    try {
      const ui: UIContext = win.getUIContext();
      if (ui !== undefined && ui !== null) {
        AppCtx.uiCtx = ui;
      }
    } catch (e) {
      // loadContent 完成前 UIContext 尚未就绪
    }
  }

  static bindUi(ui: UIContext): void {
    AppCtx.uiCtx = ui;
  }

  static clearWindow(): void {
    AppCtx.mainWin = null;
    AppCtx.uiCtx = null;
  }

  static ability(): common.UIAbilityContext {
    if (AppCtx.abilityCtx === null) {
      throw new Error('AppCtx.abilityCtx not initialized');
    }
    return AppCtx.abilityCtx;
  }

  static abilityOrNull(): common.UIAbilityContext | null {
    return AppCtx.abilityCtx;
  }

  static ui(): UIContext | null {
    if (AppCtx.uiCtx !== null) {
      return AppCtx.uiCtx;
    }
    if (AppCtx.mainWin !== null) {
      try {
        const ui: UIContext = AppCtx.mainWin.getUIContext();
        if (ui !== undefined && ui !== null) {
          AppCtx.uiCtx = ui;
          return ui;
        }
      } catch (e) {
      }
    }
    return null;
  }

  static bundleName(): string {
    if (AppCtx.cachedBundleName !== '') {
      return AppCtx.cachedBundleName;
    }
    if (AppCtx.abilityCtx !== null && AppCtx.abilityCtx.abilityInfo !== undefined &&
      AppCtx.abilityCtx.abilityInfo.bundleName !== '') {
      AppCtx.cachedBundleName = AppCtx.abilityCtx.abilityInfo.bundleName;
      return AppCtx.cachedBundleName;
    }
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.name !== '') {
        AppCtx.cachedBundleName = info.name;
        return AppCtx.cachedBundleName;
      }
    } catch (e) {
    }
    return '';
  }

  static abilityName(): string {
    if (AppCtx.abilityCtx !== null && AppCtx.abilityCtx.abilityInfo !== undefined &&
      AppCtx.abilityCtx.abilityInfo.name !== '') {
      return AppCtx.abilityCtx.abilityInfo.name;
    }
    return 'EntryAbility';
  }

  static px2vp(px: number): number {
    if (!Number.isFinite(px) || px <= 0) {
      return 0;
    }
    const ui: UIContext | null = AppCtx.ui();
    if (ui !== null) {
      try {
        const v: number = ui.px2vp(px);
        if (Number.isFinite(v) && v > 0) {
          return v;
        }
      } catch (e) {
      }
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      if (d !== undefined && d.densityPixels > 0) {
        return px / d.densityPixels;
      }
    } catch (e) {
    }
    return px / 3.25;
  }

  static showToast(message: string, duration: number = 1800): void {
    const ui: UIContext | null = AppCtx.ui();
    if (ui === null) {
      return;
    }
    try {
      ui.getPromptAction().showToast({ message: message, duration: duration });
    } catch (e) {
    }
  }

  static confirm(
    title: string,
    message: string,
    confirmText: string,
    onConfirm: () => void,
    destructive: boolean = false,
    cancelText: string = '取消'
  ): void {
    const ui: UIContext | null = AppCtx.ui();
    if (ui === null) {
      return;
    }
    const btnColor: string = destructive ? '#DC3545' : '#2F6BFF';
    const options: promptAction.ShowDialogOptions = {
      title: title,
      message: message,
      buttons: [
        { text: cancelText, color: '#6B7486' },
        { text: confirmText, color: btnColor }
      ]
    };
    ui.getPromptAction().showDialog(options).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        onConfirm();
      }
    }).catch((_e: BusinessError) => {
    });
  }

  static async openSystemUrl(url: string): Promise<boolean> {
    if (AppCtx.abilityCtx === null || url.trim() === '') {
      return false;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url.trim()
    };
    try {
      await AppCtx.abilityCtx.startAbility(want);
      return true;
    } catch (e) {
      return false;
    }
  }
}
