import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';

/**
 * 一台已经配对过的电脑。
 * 一个手机可以同时记着多台，切换时只换「当前这台」的地址与令牌，
 * 会话列表、聊天页都跟着换过去。
 */
export interface Machine {
  /** 稳定标识：优先用配对时电脑报的 host，没有就用公网地址 */
  id: string;
  /** 显示名，默认取 host（局域网 IP:端口） */
  name: string;
  /** 公网/隧道入口 */
  wan: string;
  /** 局域网候选地址（同一个 Wi-Fi 下优先走这个） */
  lan: string[];
  token: string;
  /** 最后一次使用时间，用来排序 */
  at: number;
}

interface MachineFile {
  rows: Machine[];
  active: string;
}

const STORE: string = 'dsh_mobile_machines';
const KEY: string = 'rows';

let loaded: boolean = false;
let rows: Machine[] = [];
let activeId: string = '';
let ver: number = 0;

function hostOf(base: string): string {
  let s: string = base;
  const i: number = s.indexOf('://');
  if (i >= 0) {
    s = s.substring(i + 3);
  }
  const j: number = s.indexOf('/');
  if (j >= 0) {
    s = s.substring(0, j);
  }
  return s;
}

function getPref(): preferences.Preferences | null {
  try {
    const host = getContext() as common.UIAbilityContext;
    const opts: preferences.Options = { name: STORE };
    return preferences.getPreferencesSync(host, opts);
  } catch (e) {
    console.error('DSH_MACH prefs fail ' + JSON.stringify(e));
    return null;
  }
}

function load(): void {
  if (loaded) {
    return;
  }
  loaded = true;
  const p = getPref();
  if (p === null) {
    return;
  }
  try {
    const raw: string = p.getSync(KEY, '') as string;
    if (raw !== '') {
      const f: MachineFile = JSON.parse(raw) as MachineFile;
      rows = f.rows !== undefined && f.rows !== null ? f.rows : [];
      activeId = f.active !== undefined && f.active !== null ? f.active : '';
    }
  } catch (e) {
    console.error('DSH_MACH parse fail ' + JSON.stringify(e));
    rows = [];
    activeId = '';
  }
}

function flush(): void {
  const p = getPref();
  if (p === null) {
    return;
  }
  const f: MachineFile = { rows: rows, active: activeId };
  try {
    p.putSync(KEY, JSON.stringify(f));
    p.flush();
  } catch (e) {
    console.error('DSH_MACH write fail ' + JSON.stringify(e));
  }
  ver++;
  AppStorage.setOrCreate('machinesVer', ver);
  AppStorage.setOrCreate('machineName', nameOf(activeId));
}

function nameOf(id: string): string {
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].id === id) {
      return rows[i].name;
    }
  }
  return '';
}

export class Machines {
  /** 读取列表（按最后使用时间倒序）。 */
  static list(): Machine[] {
    load();
    const copy: Machine[] = rows.slice();
    copy.sort((a: Machine, b: Machine) => b.at - a.at);
    return copy;
  }

  static active(): Machine | null {
    load();
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === activeId) {
        return rows[i];
      }
    }
    return null;
  }

  static activeId(): string {
    load();
    return activeId;
  }

  static displayName(): string {
    const m = Machines.active();
    return m !== null ? m.name : '';
  }

  /** 新增或更新一台电脑；activate 为真时同时设成当前。 */
  static upsert(wan: string, token: string, lan: string[], name: string = '', activate: boolean = true): Machine {
    load();
    const id: string = hostOf(wan) !== '' ? hostOf(wan) : wan;
    let found: Machine | null = null;
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === id) {
        found = rows[i];
        break;
      }
    }
    const now: number = Date.now();
    if (found !== null) {
      found.wan = wan;
      found.token = token;
      found.lan = lan;
      found.at = now;
      if (name !== '') {
        found.name = name;
      }
    } else {
      const m: Machine = {
        id: id,
        name: name !== '' ? name : id,
        wan: wan,
        lan: lan,
        token: token,
        at: now
      };
      rows.push(m);
      found = m;
    }
    if (activate) {
      activeId = id;
    }
    flush();
    return found;
  }

  static activate(id: string): Machine | null {
    load();
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === id) {
        rows[i].at = Date.now();
        activeId = id;
        flush();
        return rows[i];
      }
    }
    return null;
  }

  static rename(id: string, name: string): void {
    load();
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === id) {
        rows[i].name = name;
      }
    }
    flush();
  }

  static remove(id: string): void {
    load();
    const keep: Machine[] = [];
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id !== id) {
        keep.push(rows[i]);
      }
    }
    rows = keep;
    if (activeId === id) {
      activeId = rows.length > 0 ? rows[0].id : '';
    }
    flush();
  }
}
