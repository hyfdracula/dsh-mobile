import preferences from '@ohos.data.preferences';
import { AppCtx } from './AppCtx';
import { Notifier } from './Notifier';

const STORE: string = 'dsh_mobile_unread';
const KEY: string = 'ids';
const MAX_IDS: number = 200;

/**
 * 未读会话精确状态源：
 * 按活跃主机作用域隔离未读标识（`<machineId>::<sessionId>`），兼容旧版未带作用域条目；
 * 持久化到 dsh_mobile_unread，实时同步 AppStorage 与桌面角标。
 */
export class Unread {
  private static set: Set<string> | null = null;
  private static store: preferences.Preferences | null = null;
  private static ver: number = 0;

  private static currentScope(scopeKey?: string): string {
    if (scopeKey !== undefined && scopeKey.trim() !== '') {
      return scopeKey.trim();
    }
    const stored: string | undefined = AppStorage.get<string>('activeMachineId');
    return stored !== undefined ? stored.trim() : '';
  }

  private static scopeOfEntry(raw: string): string {
    const idx: number = raw.indexOf('::');
    return idx >= 0 ? raw.substring(0, idx) : '';
  }

  private static sidOfEntry(raw: string): string {
    const idx: number = raw.indexOf('::');
    return idx >= 0 ? raw.substring(idx + 2) : raw;
  }

  private static keyFor(id: string, scopeKey?: string): string {
    const s: string = Unread.currentScope(scopeKey);
    return s !== '' ? s + '::' + id : id;
  }

  private static matchesScope(raw: string, scope: string): boolean {
    const es: string = Unread.scopeOfEntry(raw);
    return es === scope || (scope !== '' && es === '');
  }

  private static ensure(): void {
    if (Unread.set !== null) {
      return;
    }
    Unread.set = new Set<string>();
    try {
      const host = AppCtx.ability();
      const opts: preferences.Options = { name: STORE };
      const p: preferences.Preferences = preferences.getPreferencesSync(host, opts);
      Unread.store = p;
      const raw: string = p.getSync(KEY, '') as string;
      if (raw !== '') {
        const list: string[] = JSON.parse(raw) as string[];
        if (Array.isArray(list)) {
          for (let i = 0; i < list.length; i++) {
            const id: string = list[i];
            if (typeof id === 'string' && id !== '') {
              Unread.set.add(id);
            }
          }
        }
      }
    } catch (e) {
      console.info('DSH_UNREAD load failed: ' + JSON.stringify(e));
    }
    const curCnt: number = Unread.countForScope();
    AppStorage.setOrCreate('unreadTotalCount', Unread.set.size);
    AppStorage.setOrCreate('unreadCount', curCnt);
    AppStorage.setOrCreate('unreadVer', Unread.ver);
    void Notifier.syncBadge(Unread.set.size);
  }

  private static countForScope(): number {
    if (Unread.set === null) {
      return 0;
    }
    const scope: string = Unread.currentScope();
    const seen: Set<string> = new Set<string>();
    Unread.set.forEach((raw: string) => {
      if (Unread.matchesScope(raw, scope)) {
        seen.add(Unread.sidOfEntry(raw));
      }
    });
    return seen.size;
  }

  private static allRaw(): string[] {
    const out: string[] = [];
    if (Unread.set === null) {
      return out;
    }
    Unread.set.forEach((v: string) => {
      out.push(v);
    });
    return out;
  }

  private static persistAndSync(): void {
    const rawList: string[] = Unread.allRaw();
    if (Unread.store !== null) {
      try {
        Unread.store.putSync(KEY, JSON.stringify(rawList));
        Unread.store.flushSync();
      } catch (e) {
        console.info('DSH_UNREAD save failed: ' + JSON.stringify(e));
      }
    }
    Unread.ver++;
    const curCnt: number = Unread.countForScope();
    const totalCnt: number = Unread.set === null ? 0 : Unread.set.size;
    AppStorage.setOrCreate('unreadTotalCount', totalCnt);
    AppStorage.setOrCreate('unreadCount', curCnt);
    AppStorage.setOrCreate('unreadVer', Unread.ver);
    void Notifier.syncBadge(totalCnt);
  }

  static refresh(): void {
    Unread.ensure();
    Unread.ver++;
    const curCnt: number = Unread.countForScope();
    const totalCnt: number = Unread.set === null ? 0 : Unread.set.size;
    AppStorage.setOrCreate('unreadTotalCount', totalCnt);
    AppStorage.setOrCreate('unreadCount', curCnt);
    AppStorage.setOrCreate('unreadVer', Unread.ver);
    void Notifier.syncBadge(totalCnt);
  }

  static has(id: string): boolean {
    if (id === '') {
      return false;
    }
    Unread.ensure();
    if (Unread.set === null) {
      return false;
    }
    return Unread.set.has(Unread.keyFor(id)) || Unread.set.has(id);
  }

  static count(): number {
    Unread.ensure();
    return Unread.countForScope();
  }

  static ids(): string[] {
    Unread.ensure();
    const out: string[] = [];
    const seen: Set<string> = new Set<string>();
    if (Unread.set === null) {
      return out;
    }
    const scope: string = Unread.currentScope();
    Unread.set.forEach((v: string) => {
      if (Unread.matchesScope(v, scope)) {
        const sid: string = Unread.sidOfEntry(v);
        if (!seen.has(sid)) {
          seen.add(sid);
          out.push(sid);
        }
      }
    });
    return out;
  }

  /** 将指定会话标记为未读（绑定当前主机作用域）。 */
  static markUnread(id: string, scopeKey?: string): void {
    if (id === '') {
      return;
    }
    Unread.ensure();
    const k: string = Unread.keyFor(id, scopeKey);
    if (Unread.set === null || Unread.set.has(k)) {
      return;
    }
    Unread.set.add(k);
    while (Unread.set.size > MAX_IDS) {
      const first: string | undefined = Unread.set.values().next().value;
      if (first === undefined) {
        break;
      }
      Unread.set.delete(first);
    }
    Unread.persistAndSync();
  }

  /** 点开或已读指定会话：移除当前主机及遗留未读并撤回对应通知、同步角标。 */
  static markRead(id: string, scopeKey?: string): void {
    if (id === '') {
      return;
    }
    Unread.ensure();
    void Notifier.cancelSession(id);
    if (Unread.set === null) {
      return;
    }
    const k: string = Unread.keyFor(id, scopeKey);
    let dirty: boolean = false;
    if (Unread.set.has(k)) {
      Unread.set.delete(k);
      dirty = true;
    }
    if (k !== id && Unread.set.has(id)) {
      Unread.set.delete(id);
      dirty = true;
    }
    if (!dirty) {
      return;
    }
    Unread.persistAndSync();
  }

  /**
   * 仅在指定主机作用域内修剪已归档或已删除会话的未读红点与通知，不误伤其他主机。
   */
  static pruneToVisible(visibleIds: Set<string>, scopeKey?: string): void {
    Unread.ensure();
    if (Unread.set === null || Unread.set.size === 0) {
      return;
    }
    const scope: string = Unread.currentScope(scopeKey);
    const staleRaw: string[] = [];
    Unread.set.forEach((raw: string) => {
      const es: string = Unread.scopeOfEntry(raw);
      if (es === scope) {
        const sid: string = Unread.sidOfEntry(raw);
        if (!visibleIds.has(sid)) {
          staleRaw.push(raw);
        }
      }
    });
    if (staleRaw.length === 0) {
      return;
    }
    for (let i = 0; i < staleRaw.length; i++) {
      const raw: string = staleRaw[i];
      Unread.set.delete(raw);
      void Notifier.cancelSession(Unread.sidOfEntry(raw));
    }
    Unread.persistAndSync();
  }

  /** 清空全部未读红点、撤回全部通知并将桌面角标归零。 */
  static clearAll(): void {
    Unread.ensure();
    if (Unread.set !== null) {
      Unread.set.clear();
    }
    void Notifier.cancelAll();
    Unread.persistAndSync();
  }
}
