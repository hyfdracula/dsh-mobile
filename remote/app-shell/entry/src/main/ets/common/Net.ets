import connection from '@ohos.net.connection';
import { BusinessError } from '@kit.BasicServicesKit';
import { LinkLog } from './LinkLog';

/**
 * 网络连通与传输类型监听：
 * 冷启动读取真实系统默认网络，支持 stop() 注销监听，bearer 集合去重防风暴。
 */
export class Net {
  private static started: boolean = false;
  private static conn: connection.NetConnection | null = null;
  private static lastBearerSig: string = '';

  private static bearerSignature(caps?: connection.NetCapabilities): string {
    try {
      let c: connection.NetCapabilities | undefined = caps;
      if (c === undefined) {
        const net: connection.NetHandle | undefined = connection.getDefaultNetSync();
        if (net === undefined || net.netId === 0) {
          return 'none';
        }
        c = connection.getNetCapabilitiesSync(net);
      }
      const raw: number[] = c.bearerTypes !== undefined ? c.bearerTypes.slice() : [];
      // 过滤 VPN 虚拟网卡抖动噪音：存在物理网卡（Wi-Fi/蜂窝/以太网）时仅按物理承载判断网络切换
      const phys: number[] = [];
      for (let i = 0; i < raw.length; i++) {
        if (raw[i] !== connection.NetBearType.BEARER_VPN) {
          phys.push(raw[i]);
        }
      }
      const list: number[] = phys.length > 0 ? phys : raw;
      list.sort((a: number, b: number) => a - b);
      return list.length > 0 ? list.join(',') : 'none';
    } catch (e) {
      return '';
    }
  }

  private static checkInitialOnline(): boolean {
    try {
      const hasNet: boolean = connection.hasDefaultNetSync();
      if (!hasNet) {
        return false;
      }
      const net: connection.NetHandle | undefined = connection.getDefaultNetSync();
      return net !== undefined && net.netId !== 0;
    } catch (e) {
      return true;
    }
  }

  static start(): void {
    if (Net.started) {
      return;
    }
    Net.started = true;
    AppStorage.setOrCreate('online', Net.checkInitialOnline());
    Net.lastBearerSig = Net.bearerSignature();
    try {
      const nc: connection.NetConnection = connection.createNetConnection();
      nc.on('netAvailable', () => {
        Net.set(true);
        const sig: string = Net.bearerSignature();
        if (sig !== '' && sig !== Net.lastBearerSig) {
          Net.lastBearerSig = sig;
          AppStorage.setOrCreate('netBearerTick', Date.now());
        }
      });
      nc.on('netCapabilitiesChange', (data: connection.NetCapabilityInfo) => {
        const sig: string = Net.bearerSignature(data !== undefined ? data.netCap : undefined);
        if (sig !== '' && sig !== Net.lastBearerSig) {
          Net.lastBearerSig = sig;
          AppStorage.setOrCreate('netBearerTick', Date.now());
        }
      });
      nc.on('netLost', () => {
        Net.lastBearerSig = 'none';
        Net.set(false);
      });
      nc.register((err: BusinessError) => {
        if (err) {
          console.info('AM_NET register failed: ' + err.message);
        }
      });
      Net.conn = nc;
    } catch (e) {
      console.info('AM_NET start failed: ' + (e as BusinessError).message);
    }
  }

  static stop(): void {
    if (!Net.started) {
      return;
    }
    Net.started = false;
    if (Net.conn !== null) {
      try {
        Net.conn.unregister(() => {});
      } catch (e) {
      }
      Net.conn = null;
    }
  }

  private static set(v: boolean): void {
    const prev: boolean | undefined = AppStorage.get<boolean>('online');
    if (prev === v) {
      return;
    }
    AppStorage.setOrCreate('online', v);
    LinkLog.record('NET', v ? 'online=true' : 'online=false');
    if (v) {
      AppStorage.setOrCreate('listDirty', Date.now());
    }
  }

  static isOnline(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>('online');
    return v === undefined ? true : v;
  }

  static isCellularOnly(): boolean {
    try {
      const net: connection.NetHandle | undefined = connection.getDefaultNetSync();
      if (net === undefined || net.netId === 0) {
        return false;
      }
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
      const bearers: number[] = caps.bearerTypes ?? [];
      let hasCellular: boolean = false;
      for (let i = 0; i < bearers.length; i++) {
        const b: number = bearers[i];
        if (b === connection.NetBearType.BEARER_WIFI ||
          b === connection.NetBearType.BEARER_ETHERNET ||
          b === connection.NetBearType.BEARER_VPN) {
          return false;
        }
        if (b === connection.NetBearType.BEARER_CELLULAR) {
          hasCellular = true;
        }
      }
      return hasCellular;
    } catch (e) {
      return false;
    }
  }
}
