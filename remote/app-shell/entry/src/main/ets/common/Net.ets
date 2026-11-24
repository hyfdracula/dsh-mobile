import connection from '@ohos.net.connection';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 网络状态：只维护一个「现在有没有网」的布尔，写进 AppStorage 供各页订阅。
 *
 * 没有它的时候，离线只能靠请求超时才发现：用户发出去的消息转圈十几秒才报错，
 * 列表也一直显示「已连接」。有了它，离线横幅与发送失败的兜底都能立刻出现。
 */
export class Net {
  private static started: boolean = false;
  private static conn: connection.NetConnection | null = null;

  static start(): void {
    if (Net.started) {
      return;
    }
    Net.started = true;
    try {
      const nc: connection.NetConnection = connection.createNetConnection();
      nc.on('netAvailable', () => {
        Net.set(true);
      });
      nc.on('netLost', () => {
        Net.set(false);
      });
      nc.register((err: BusinessError) => {
        if (err) {
          console.info('DSH_NET register failed: ' + err.message);
        }
      });
      Net.conn = nc;
    } catch (e) {
      console.info('DSH_NET start failed: ' + (e as BusinessError).message);
    }
    // 拿不到事件就先按在线处理，避免一启动就误报离线。
    AppStorage.setOrCreate('online', true);
  }

  private static set(v: boolean): void {
    const prev: boolean | undefined = AppStorage.get<boolean>('online');
    if (prev === v) {
      return;
    }
    AppStorage.setOrCreate('online', v);
    // 恢复联网时让列表立刻补一次：离线期间的轮询都被跳过了。
    if (v) {
      AppStorage.setOrCreate('listDirty', Date.now());
    }
    console.info('DSH_NET online=' + String(v));
  }

  static isOnline(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>('online');
    return v === undefined ? true : v;
  }
}
