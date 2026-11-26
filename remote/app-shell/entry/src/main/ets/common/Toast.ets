import { AppCtx } from './AppCtx';

/**
 * 全 App 唯一的轻提示出口：基于当前绑定窗口 UIContext.getPromptAction().showToast。
 */
export class Toast {
  static ok(msg: string): void {
    Toast.show(msg, 1800);
  }

  static info(msg: string): void {
    Toast.show(msg, 1800);
  }

  static err(msg: string): void {
    Toast.show(msg, 2600);
  }

  static show(msg: string, duration: number): void {
    AppCtx.showToast(msg, duration);
  }
}
