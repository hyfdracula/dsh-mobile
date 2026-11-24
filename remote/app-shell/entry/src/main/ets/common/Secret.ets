import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 访问令牌的加密存储（Asset Store Kit）。
 *
 * 以前令牌明文躺在 preferences 里：应用备份、被 root 的手机、adb 拉数据都能直接读到。
 * 这里把「当前这台电脑的令牌」放进系统资产库（受设备锁保护、不参与普通备份），
 * preferences 只作为旧版本迁移与 Asset 不可用时的回退。
 *
 * 只存当前这台：多电脑各自的令牌仍在 Machines 的 JSON 里，等协议 v2 一并迁。
 */
const ALIAS: string = 'dsh_mobile_primary_token';
const LABEL: string = 'DSH Mobile access token';

function toBytes(s: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i) & 0xff;
  }
  return out;
}

function fromBytes(b: Uint8Array): string {
  let s: string = '';
  for (let i = 0; i < b.length; i++) {
    s += String.fromCharCode(b[i]);
  }
  return s;
}

export class Secret {
  /** 机器 id → 稳定别名：id 里可能有冒号/斜杠，先压成 hex。 */
  private static aliasFor(machineId: string): string {
    let h = 2166136261;
    for (let i = 0; i < machineId.length; i++) {
      h ^= machineId.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return 'dsh_mobile_machine_' + (h >>> 0).toString(16);
  }

  /** 按机器保存令牌（多电脑场景），每台一个 alias。 */
  static saveFor(machineId: string, token: string): boolean {
    if (token === '' || machineId === '') {
      return false;
    }
    return Secret.write(Secret.aliasFor(machineId), token);
  }

  static loadFor(machineId: string): string {
    if (machineId === '') {
      return '';
    }
    return Secret.read(Secret.aliasFor(machineId));
  }

  static removeFor(machineId: string): void {
    if (machineId === '') {
      return;
    }
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(Secret.aliasFor(machineId)));
    try {
      asset.removeSync(query);
    } catch (e) {
      // 没有就没有
    }
  }

  private static write(alias: string, token: string): boolean {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(alias));
    const upd: asset.AssetMap = new Map();
    upd.set(asset.Tag.SECRET, toBytes(token));
    try {
      asset.updateSync(query, upd);
      return true;
    } catch (e) {
      // NOT_FOUND：第一次写，走 add
    }
    const add: asset.AssetMap = new Map();
    add.set(asset.Tag.SECRET, toBytes(token));
    add.set(asset.Tag.ALIAS, toBytes(alias));
    add.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    add.set(asset.Tag.DATA_LABEL_NORMAL_1, toBytes(LABEL));
    try {
      asset.addSync(add);
      console.info('DSH_SECRET saved ' + alias.substring(0, 18));
      return true;
    } catch (e) {
      console.info('DSH_SECRET save failed: ' + (e as BusinessError).message);
      return false;
    }
  }

  private static read(alias: string): string {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const rows: Array<asset.AssetMap> = asset.querySync(query);
      if (rows.length === 0) {
        return '';
      }
      const v: asset.Value | undefined = rows[0].get(asset.Tag.SECRET);
      return v === undefined || v === null ? '' : fromBytes(v as Uint8Array);
    } catch (e) {
      return '';
    }
  }

  /** 写入或覆盖当前令牌；Asset 不可用时静默放弃，调用方仍写着 preferences。 */
  static save(token: string): boolean {
    if (token === '') {
      return false;
    }
    return Secret.write(ALIAS, token);
  }

  /** 读回令牌；没有或资产库不可用时返回空串，让调用方用 preferences 的旧值。 */
  static load(): string {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(ALIAS));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const rows: Array<asset.AssetMap> = asset.querySync(query);
      if (rows.length === 0) {
        return '';
      }
      const v: asset.Value | undefined = rows[0].get(asset.Tag.SECRET);
      if (v === undefined || v === null) {
        return '';
      }
      return fromBytes(v as Uint8Array);
    } catch (e) {
      console.info('DSH_SECRET load failed: ' + (e as BusinessError).message);
      return '';
    }
  }
}
