import vibrator from '@ohos.vibrator';

/**
 * 触感反馈。
 * 用时长很短的 time 型振动模拟「轻点」，不依赖 effectId。
 * 全局开关由设置页控制，Index 启动时从 preferences 读入。
 */
export class Haptics {
  static enabled: boolean = true;

  /** 普通点击 */
  static tap(): void {
    Haptics.fire(10);
  }

  /** 明确的操作确认（发送、归档、切换主题等） */
  static soft(): void {
    Haptics.fire(16);
  }

  /** 长按 */
  static long(): void {
    Haptics.fire(24);
  }

  private static fire(ms: number): void {
    if (!Haptics.enabled) return;
    try {
      vibrator.startVibration(
        { type: 'time', duration: ms },
        { id: 0, usage: 'unknown' }
      ).catch((e: Error) => {
        console.error('DSH_HAP fail :: ' + e.message);
      });
    } catch (e) {
      console.error('DSH_HAP throw :: ' + (e as Error).message);
    }
  }
}
