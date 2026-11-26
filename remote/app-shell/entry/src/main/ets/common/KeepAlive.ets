import { common } from '@kit.AbilityKit';

/**
 * 后台保活占位控制器：
 * 上架版本已移除 KEEP_BACKGROUND_RUNNING / DATA_TRANSFER 长时后台任务声明，
 * 任务状态同步统一由应用返回前台时的 fgResumeFromBg 补扫与主动拉取承担。
 */
export class KeepAlive {
  static bind(_ctx: common.UIAbilityContext): void {
  }

  static isActive(): boolean {
    return false;
  }

  static async start(): Promise<void> {
  }

  static async stop(): Promise<void> {
  }
}
