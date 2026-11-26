import preferences from '@ohos.data.preferences';
import { AppCtx } from './AppCtx';
import { isLanUrl } from './ApiUtil';
import { LinkLog } from './LinkLog';
import { Secret } from './Secret';

/**
 * 一台已经配对过的电脑。
 * 一个手机可以同时记着多台，切换时只换「当前这台」的地址与令牌，
 * 会话列表、聊天页都跟着换过去。
 */
export interface Machine {
  /** 稳定标识：优先用配对时电脑报的 host，没有就用公网地址 */
  id: string;
  /** 显示名，默认取 host（局域网 IP:端口或主机名） */
  name: string;
  /** 公网/隧道入口（仅当无公网地址时暂存局域网地址） */
  wan: string;
  /** 局域网候选地址（同一个 Wi-Fi 下优先走这个） */
  lan: string[];
  token: string;
  /** 最后一次使用时间，用来排序 */
  at: number;
  /** 宿主持久设备 ID（用于同机公网/局域网自动去重合并与 E2EE 会话绑定） */
  hostId?: string;
  /** 宿主 X25519 静态公钥（Base64URL，用于 Noise_IK 端到端加密） */
  e2eePub?: string;
  /** 用户是否手动重命名过（true 时合并刷新不覆盖自定义名称） */
  customName?: boolean;
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

function trimUrl(raw: string): string {
  const s: string = raw.trim();
  let end: number = s.length;
  while (end > 0 && s.charAt(end - 1) === '/') {
    end -= 1;
  }
  return s.substring(0, end);
}

function hostOf(base: string): string {
  let s: string = trimUrl(base);
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

function normalizeLanList(list: string[] | undefined): string[] {
  const out: string[] = [];
  if (list === undefined || list === null) {
    return out;
  }
  for (let i = 0; i < list.length; i++) {
    const u: string = trimUrl(list[i]);
    if (u !== '' && out.indexOf(u) < 0) {
      out.push(u);
    }
  }
  return out;
}

function tokenOfRow(row: Machine): string {
  const sec: string = Secret.loadFor(row.id);
  if (sec !== '') {
    return sec;
  }
  return row.token !== undefined ? row.token : '';
}

function allUrlsOf(wan: string, lan: string[]): string[] {
  const out: string[] = [];
  const w: string = trimUrl(wan);
  if (w !== '') {
    out.push(w);
  }
  for (let i = 0; i < lan.length; i++) {
    const u: string = trimUrl(lan[i]);
    if (u !== '' && out.indexOf(u) < 0) {
      out.push(u);
    }
  }
  return out;
}

function hasUrlOverlap(aWan: string, aLan: string[], bWan: string, bLan: string[]): boolean {
  const urlsA: string[] = allUrlsOf(aWan, aLan);
  const urlsB: string[] = allUrlsOf(bWan, bLan);
  for (let i = 0; i < urlsA.length; i++) {
    if (urlsB.indexOf(urlsA[i]) >= 0) {
      return true;
    }
  }
  return false;
}

function sameMachineRow(a: Machine, b: Machine): boolean {
  const hidA: string = a.hostId !== undefined ? a.hostId.trim() : '';
  const hidB: string = b.hostId !== undefined ? b.hostId.trim() : '';
  if (hidA !== '' && hidB !== '') {
    return hidA === hidB;
  }
  const tokA: string = tokenOfRow(a);
  const tokB: string = tokenOfRow(b);
  if (tokA !== '' && tokB !== '' && tokA === tokB) {
    return true;
  }
  if (hasUrlOverlap(a.wan, a.lan, b.wan, b.lan)) {
    return true;
  }
  return false;
}

function mergeUrlsInto(target: Machine, incomingWan: string, incomingLan: string[]): void {
  const curWan: string = trimUrl(target.wan);
  const newWan: string = trimUrl(incomingWan);
  const curLan: string[] = normalizeLanList(target.lan);
  const newLan: string[] = normalizeLanList(incomingLan);

  // 非局域网公网地址保留在 wan，所有局域网地址去重并入 lan[]
  let bestWan: string = '';
  if (newWan !== '' && !isLanUrl(newWan)) {
    bestWan = newWan;
  } else if (curWan !== '' && !isLanUrl(curWan)) {
    bestWan = curWan;
  } else {
    for (let i = 0; i < newLan.length; i++) {
      if (!isLanUrl(newLan[i])) {
        bestWan = newLan[i];
        break;
      }
    }
    if (bestWan === '') {
      for (let i = 0; i < curLan.length; i++) {
        if (!isLanUrl(curLan[i])) {
          bestWan = curLan[i];
          break;
        }
      }
    }
  }

  const lanMerged: string[] = [];
  const pushLan = (u: string): void => {
    if (u !== '' && isLanUrl(u) && lanMerged.indexOf(u) < 0) {
      lanMerged.push(u);
    }
  };
  if (newWan !== '' && isLanUrl(newWan)) {
    pushLan(newWan);
  }
  for (let i = 0; i < newLan.length; i++) {
    pushLan(newLan[i]);
  }
  if (curWan !== '' && isLanUrl(curWan)) {
    pushLan(curWan);
  }
  for (let i = 0; i < curLan.length; i++) {
    pushLan(curLan[i]);
  }

  if (bestWan === '') {
    if (newWan !== '') {
      bestWan = newWan;
    } else if (curWan !== '') {
      bestWan = curWan;
    } else if (lanMerged.length > 0) {
      bestWan = lanMerged[0];
    }
  }

  target.wan = bestWan;
  target.lan = lanMerged;
}

function looksDefaultName(row: Machine): boolean {
  if (row.customName === true) {
    return false;
  }
  const n: string = row.name !== undefined ? row.name.trim() : '';
  if (n === '' || n === row.id || n === hostOf(row.wan) || n === row.wan) {
    return true;
  }
  return false;
}

/**
 * 扫描并合并历史分裂记录（同 hostId、同 Secret 令牌或重叠地址）。
 * 返回是否发生了合并。
 */
function dedupeRows(): boolean {
  if (rows.length <= 1) {
    return false;
  }
  // 优先保留当前激活项、带公网地址项以及最近使用项
  const sorted: Machine[] = rows.slice();
  sorted.sort((a: Machine, b: Machine) => {
    const aAct: number = a.id === activeId ? 1 : 0;
    const bAct: number = b.id === activeId ? 1 : 0;
    if (aAct !== bAct) {
      return bAct - aAct;
    }
    const aWan: number = a.wan !== '' && !isLanUrl(a.wan) ? 1 : 0;
    const bWan: number = b.wan !== '' && !isLanUrl(b.wan) ? 1 : 0;
    if (aWan !== bWan) {
      return bWan - aWan;
    }
    return b.at - a.at;
  });

  const kept: Machine[] = [];
  let changed: boolean = false;
  for (let i = 0; i < sorted.length; i++) {
    const cand: Machine = sorted[i];
    let hit: Machine | null = null;
    for (let j = 0; j < kept.length; j++) {
      if (sameMachineRow(kept[j], cand)) {
        hit = kept[j];
        break;
      }
    }
    if (hit === null) {
      kept.push(cand);
      continue;
    }
    changed = true;
    const keepTok: string = tokenOfRow(hit);
    const dupTok: string = tokenOfRow(cand);
    const bestTok: string = keepTok !== '' ? keepTok : dupTok;

    mergeUrlsInto(hit, cand.wan, cand.lan);
    if ((hit.hostId === undefined || hit.hostId === '') && cand.hostId !== undefined && cand.hostId !== '') {
      hit.hostId = cand.hostId;
    }
    if ((hit.e2eePub === undefined || hit.e2eePub === '') && cand.e2eePub !== undefined && cand.e2eePub !== '') {
      hit.e2eePub = cand.e2eePub;
    }
    if (cand.customName === true && hit.customName !== true && cand.name !== '') {
      hit.name = cand.name;
      hit.customName = true;
    } else if (looksDefaultName(hit) && cand.name !== '' && !looksDefaultName(cand)) {
      hit.name = cand.name;
    }
    if (cand.at > hit.at) {
      hit.at = cand.at;
    }
    if (bestTok !== '') {
      hit.token = Secret.saveFor(hit.id, bestTok) ? '' : bestTok;
    }
    if (cand.id !== hit.id) {
      Secret.removeFor(cand.id);
    }
    if (activeId === cand.id) {
      activeId = hit.id;
    }
  }
  if (changed) {
    rows = kept;
    console.info('DSH_MACH deduped -> count=' + String(rows.length));
  }
  return changed;
}

function getPref(): preferences.Preferences | null {
  try {
    const host = AppCtx.ability();
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
      let dirty: boolean = false;
      for (let i = 0; i < rows.length; i++) {
        rows[i].wan = trimUrl(rows[i].wan !== undefined ? rows[i].wan : '');
        rows[i].lan = normalizeLanList(rows[i].lan);
        // 旧版本把每台电脑的令牌明文写在这里：迁进 Asset Store，然后把明文清掉。
        if (rows[i].token !== undefined && rows[i].token !== '') {
          if (Secret.saveFor(rows[i].id, rows[i].token)) {
            rows[i].token = '';
            dirty = true;
          }
        }
      }
      if (dedupeRows()) {
        dirty = true;
      }
      if (dirty) {
        flush();
      } else {
        AppStorage.setOrCreate('activeMachineId', activeId);
      }
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
    p.flushSync();
  } catch (e) {
    console.error('DSH_MACH write fail ' + JSON.stringify(e));
  }
  ver++;
  AppStorage.setOrCreate('machinesVer', ver);
  AppStorage.setOrCreate('activeMachineId', activeId);
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

  /** 按优先级查找是否为同一台已配对电脑；hostId 不同视为另一台电脑绝不合并。 */
  private static findMatch(wan: string, token: string, lan: string[], hostId: string): Machine | null {
    const hid: string = hostId.trim();
    if (hid !== '') {
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].hostId !== undefined && rows[i].hostId === hid) {
          return rows[i];
        }
      }
    }
    const hostMismatch = (r: Machine): boolean => {
      const rh: string = r.hostId !== undefined ? r.hostId.trim() : '';
      return hid !== '' && rh !== '' && rh !== hid;
    };
    if (token !== '') {
      for (let i = 0; i < rows.length; i++) {
        if (!hostMismatch(rows[i]) && tokenOfRow(rows[i]) === token) {
          return rows[i];
        }
      }
    }
    for (let i = 0; i < rows.length; i++) {
      if (!hostMismatch(rows[i]) && hasUrlOverlap(rows[i].wan, rows[i].lan, wan, lan)) {
        return rows[i];
      }
    }
    const h: string = hostOf(wan);
    if (h !== '') {
      for (let i = 0; i < rows.length; i++) {
        if (!hostMismatch(rows[i]) && rows[i].id === h) {
          return rows[i];
        }
      }
    }
    return null;
  }

  /**
   * 新增或合并更新一台电脑（F08 / L6）：
   * 按 hostId -> 同 Secret 令牌 -> 地址交集 -> hostOf(wan) 顺序自动去重合并，
   * 保留非局域网地址在 wan、所有局域网地址去重并入 lan[]。
   */
  static upsertEx(
    wan: string,
    token: string,
    lan: string[],
    name: string = '',
    activate: boolean = true,
    hostId: string = '',
    e2eePub: string = ''
  ): Machine {
    load();
    const normWan: string = trimUrl(wan);
    const normLan: string[] = normalizeLanList(lan);
    const cleanHostId: string = hostId.trim();
    const cleanPub: string = e2eePub.trim();
    const cleanName: string = name.trim();
    const now: number = Date.now();

    let found: Machine | null = Machines.findMatch(normWan, token, normLan, cleanHostId);
    if (found !== null) {
      mergeUrlsInto(found, normWan, normLan);
      if (token !== '') {
        found.token = Secret.saveFor(found.id, token) ? '' : token;
      }
      const oldHid: string = found.hostId !== undefined ? found.hostId.trim() : '';
      const oldPub: string = found.e2eePub !== undefined ? found.e2eePub.trim() : '';
      if (cleanHostId !== '') {
        found.hostId = cleanHostId;
      }
      if (cleanPub !== '') {
        if (oldPub !== '' && oldPub !== cleanPub && (oldHid === '' || cleanHostId === '' || oldHid === cleanHostId)) {
          LinkLog.record('E2EE', 'host pubkey mismatch ignored');
          AppStorage.setOrCreate('e2eeKeyMismatch', found.name !== '' ? found.name : found.id);
        } else {
          found.e2eePub = cleanPub;
        }
      }
      if (cleanName !== '' && found.customName !== true) {
        found.name = cleanName;
      } else if (found.name === '') {
        found.name = cleanName !== '' ? cleanName : found.id;
      }
      found.at = now;
    } else {
      const temp: Machine = {
        id: '',
        name: '',
        wan: '',
        lan: [],
        token: '',
        at: now
      };
      mergeUrlsInto(temp, normWan, normLan);
      const idBase: string = hostOf(temp.wan);
      const id: string = idBase !== '' ? idBase : (cleanHostId !== '' ? cleanHostId : temp.wan);
      const stored: string = token !== '' ? (Secret.saveFor(id, token) ? '' : token) : '';
      temp.id = id;
      temp.name = cleanName !== '' ? cleanName : id;
      temp.token = stored;
      if (cleanHostId !== '') {
        temp.hostId = cleanHostId;
      }
      if (cleanPub !== '') {
        temp.e2eePub = cleanPub;
      }
      rows.push(temp);
      found = temp;
    }

    if (activate) {
      activeId = found.id;
    }
    dedupeRows();
    flush();
    return found;
  }

  /** 新增或更新一台电脑（向后兼容旧签名，委托给 upsertEx）。 */
  static upsert(wan: string, token: string, lan: string[], name: string = '', activate: boolean = true): Machine {
    return Machines.upsertEx(wan, token, lan, name, activate, '', '');
  }

  /** 回写 /api/info 探测到的 hostId / e2eePub / 新局域网候选并触发同机去重。 */
  static updateMeta(id: string, hostId: string, e2eePub: string, lanAdd: string[] = []): Machine | null {
    load();
    let target: Machine | null = null;
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === id) {
        target = rows[i];
        break;
      }
    }
    if (target === null) {
      return null;
    }
    let changed: boolean = false;
    const cleanHid: string = hostId.trim();
    const cleanPub: string = e2eePub.trim();
    const oldHid: string = target.hostId !== undefined ? target.hostId.trim() : '';
    const oldPub: string = target.e2eePub !== undefined ? target.e2eePub.trim() : '';
    if (cleanHid !== '' && target.hostId !== cleanHid) {
      target.hostId = cleanHid;
      changed = true;
    }
    if (cleanPub !== '') {
      if (oldPub !== '' && oldPub !== cleanPub && (oldHid === '' || cleanHid === '' || oldHid === cleanHid)) {
        LinkLog.record('E2EE', 'host pubkey mismatch ignored');
        AppStorage.setOrCreate('e2eeKeyMismatch', target.name !== '' ? target.name : target.id);
      } else if (target.e2eePub !== cleanPub) {
        target.e2eePub = cleanPub;
        changed = true;
      }
    }
    if (lanAdd.length > 0) {
      const beforeCount: number = target.lan.length;
      mergeUrlsInto(target, '', lanAdd);
      if (target.lan.length !== beforeCount) {
        changed = true;
      }
    }
    if (dedupeRows()) {
      changed = true;
    }
    if (changed) {
      flush();
    }
    return Machines.active() !== null && activeId === target.id ? Machines.active() : target;
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
    const trimmed: string = name.trim();
    if (trimmed === '') {
      return;
    }
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === id) {
        rows[i].name = trimmed;
        rows[i].customName = true;
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
    Secret.removeFor(id);
    if (activeId === id) {
      activeId = rows.length > 0 ? rows[0].id : '';
    }
    flush();
  }
}
