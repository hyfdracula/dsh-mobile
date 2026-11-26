import fs from '@ohos.file.fs';
import { Message } from './Api';
import { AppCtx } from './AppCtx';

/** 一个会话最近一次拉到的样子：冷启动先拿它铺屏，再去要新的。 */
export interface ChatSnapshot {
  at: number;
  total: number;
  running: boolean;
  lastTurn: string;
  messages: Message[];
}

interface CacheMeta {
  name: string;
  mtime: number;
}

const KEEP: number = 60;
const MAX_MSGS: number = 200;

function dirOf(): string {
  const d: string = AppCtx.ability().filesDir + '/msgs';
  try {
    if (!fs.accessSync(d)) {
      fs.mkdirSync(d);
    }
  } catch (e) {
  }
  return d;
}

/** 将含 `codex:` / `claude:` 等冒号或斜杠的会话 ID 映射为安全文件名。 */
function safeStem(id: string): string {
  return encodeURIComponent(id).replace(/%/g, '_');
}

function pathOf(id: string): string {
  return dirOf() + '/' + safeStem(id) + '.json';
}

function legacyPathOf(id: string): string {
  if (id.indexOf('/') >= 0 || id.indexOf('\\') >= 0 || id.indexOf(':') >= 0) {
    return '';
  }
  return dirOf() + '/' + id + '.json';
}

/** 超出 KEEP 的旧文件按 mtime 数组精确排序删掉，避免同秒 mtime 碰撞漏删。 */
function prune(): void {
  try {
    const dir: string = dirOf();
    const names: string[] = fs.listFileSync(dir);
    if (names.length <= KEEP) {
      return;
    }
    const items: CacheMeta[] = [];
    for (let i = 0; i < names.length; i++) {
      const n: string = names[i];
      if (!n.endsWith('.json')) {
        continue;
      }
      try {
        const st = fs.statSync(dir + '/' + n);
        items.push({ name: n, mtime: st.mtime });
      } catch (e) {
      }
    }
    if (items.length <= KEEP) {
      return;
    }
    items.sort((a: CacheMeta, b: CacheMeta) => a.mtime - b.mtime);
    const drop: number = items.length - KEEP;
    for (let i = 0; i < drop; i++) {
      try {
        fs.unlinkSync(dir + '/' + items[i].name);
      } catch (e) {
      }
    }
  } catch (e) {
  }
}

export class ChatCache {
  static read(id: string): ChatSnapshot | null {
    try {
      let p: string = pathOf(id);
      if (!fs.accessSync(p)) {
        const leg: string = legacyPathOf(id);
        if (leg !== '' && fs.accessSync(leg)) {
          p = leg;
        } else {
          return null;
        }
      }
      const raw: string = fs.readTextSync(p);
      if (raw === '') {
        return null;
      }
      const s: ChatSnapshot = JSON.parse(raw) as ChatSnapshot;
      if (s.messages === undefined || s.messages.length === 0) {
        return null;
      }
      return s;
    } catch (e) {
      return null;
    }
  }

  static write(id: string, messages: Message[], total: number, running: boolean, lastTurn: string): void {
    const p: string = pathOf(id);
    const tmp: string = p + '.tmp.' + String(Date.now());
    let f: fs.File | null = null;
    try {
      const tail: Message[] = messages.length > MAX_MSGS ? messages.slice(messages.length - MAX_MSGS) : messages;
      const s: ChatSnapshot = {
        at: Date.now(),
        total: total,
        running: running,
        lastTurn: lastTurn,
        messages: tail
      };
      f = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(s));
      fs.closeSync(f);
      f = null;
      fs.renameSync(tmp, p);
      prune();
    } catch (e) {
      try {
        fs.unlinkSync(tmp);
      } catch (e2) {
      }
    } finally {
      if (f !== null) {
        try {
          fs.closeSync(f);
        } catch (e3) {
        }
      }
    }
  }

  static drop(id: string): void {
    try {
      fs.unlinkSync(pathOf(id));
    } catch (e) {
    }
    const leg: string = legacyPathOf(id);
    if (leg !== '') {
      try {
        fs.unlinkSync(leg);
      } catch (e) {
      }
    }
  }
}
