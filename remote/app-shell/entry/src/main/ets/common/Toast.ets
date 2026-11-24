import { promptAction } from '@kit.ArkUI';

/**
 * 全 App 唯一的轻提示出口。
 *
 * 以前每个页面各写 promptAction.showToast，时长从 1400 到 2600 有八种；
 * 聊天页还有 12 条自绘提示永不消失。现在只保留三种语义：
 * - ok：操作成功（1800）
 * - info：中性说明（1800）
 * - err：失败原因（2600）
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
    try {
      promptAction.showToast({ message: msg, duration: duration });
    } catch (e) {
      console.info('DSH_TOAST failed: ' + JSON.stringify(e));
    }
  }
}
