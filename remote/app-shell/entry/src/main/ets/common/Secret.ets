import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { utf8Decode, utf8Encode } from './crypto/Bytes';

/**
 * 访问令牌与敏感凭据的系统资产安全存储（Asset Store Kit）。
 */
const ALIAS: string = 'dsh_mobile_primary_token';
const LABEL: string = 'Agent Mobile access token';
const ERR_NOT_FOUND: number = 24000002;

export class Secret {
  private static aliasFor(machineId: string): string {
    let h = 2166136261;
    for (let i = 0; i < machineId.length; i++) {
      h ^= machineId.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return 'dsh_mobile_machine_' + (h >>> 0).toString(16);
  }

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
    Secret.removeAlias(Secret.aliasFor(machineId));
  }

  static clear(): void {
    Secret.removeAlias(ALIAS);
  }

  private static removeAlias(alias: string): void {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, utf8Encode(alias));
    try {
      asset.removeSync(query);
    } catch (e) {
      const be = e as BusinessError;
      if (be !== undefined && be.code !== ERR_NOT_FOUND) {
        console.info('AM_SECRET remove failed code=' + String(be.code));
      }
    }
  }

  private static write(alias: string, token: string): boolean {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, utf8Encode(alias));
    const upd: asset.AssetMap = new Map();
    upd.set(asset.Tag.SECRET, utf8Encode(token));
    try {
      asset.updateSync(query, upd);
      return true;
    } catch (e) {
      const be = e as BusinessError;
      if (be !== undefined && be.code !== ERR_NOT_FOUND) {
        console.info('AM_SECRET update failed code=' + String(be.code));
      }
    }
    const add: asset.AssetMap = new Map();
    add.set(asset.Tag.SECRET, utf8Encode(token));
    add.set(asset.Tag.ALIAS, utf8Encode(alias));
    add.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    add.set(asset.Tag.DATA_LABEL_NORMAL_1, utf8Encode(LABEL));
    try {
      asset.addSync(add);
      return true;
    } catch (e) {
      console.info('AM_SECRET save failed: ' + (e as BusinessError).message);
      return false;
    }
  }

  private static read(alias: string): string {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, utf8Encode(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const rows: Array<asset.AssetMap> = asset.querySync(query);
      if (rows.length === 0) {
        return '';
      }
      const v: asset.Value | undefined = rows[0].get(asset.Tag.SECRET);
      return v === undefined || v === null ? '' : utf8Decode(v as Uint8Array);
    } catch (e) {
      const be = e as BusinessError;
      if (be !== undefined && be.code !== ERR_NOT_FOUND) {
        console.info('AM_SECRET read failed code=' + String(be.code));
      }
      return '';
    }
  }

  static saveKey(alias: string, value: string): boolean {
    if (alias === '' || value === '') {
      return false;
    }
    return Secret.write(alias, value);
  }

  static loadKey(alias: string): string {
    if (alias === '') {
      return '';
    }
    return Secret.read(alias);
  }

  static save(token: string): boolean {
    if (token === '') {
      return false;
    }
    return Secret.write(ALIAS, token);
  }

  static load(): string {
    return Secret.read(ALIAS);
  }
}
