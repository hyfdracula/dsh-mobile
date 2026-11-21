import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { Message } from './Api';

/** 一个会话最近一次拉到的样子：冷启动先拿它铺屏，再去要新的。 */
export interface ChatSnapshot {
  at: number;
  total: number;
  running: boolean;
  lastTurn: string;
  messages: Message[];
}

/** 每个会话一份，最多留这么多份；按最后访问时间淘汰。 */
const KEEP: number = 60;
/** 一份里最多存这么多条消息，够铺满首屏就行。 */
const MAX_MSGS: number = 40;

function dirOf(): string {
  const ctx = getContext() as common.UIAbilityContext;
  const d: string = ctx.filesDir + '/msgs';
  try {
    if (!fs.accessSync(d)) {
      fs.mkdirSync(d);
    }
  } catch (e) {
  }
  return d;
}

function pathOf(id: string): string {
  return dirOf() + '/' + id + '.json';
}

/** 超出 KEEP 的旧文件按 mtime 删掉。 */
function prune(): void {
  try {
    const dir: string = dirOf();
    const names: string[] = fs.listFileSync(dir);
    if (names.length <= KEEP) {
      return;
    }
    const rows: number[] = [];
    const map: Map<number, string> = new Map<number, string>();
    for (const n of names) {
      if (!n.endsWith('.json')) {
        continue;
      }
      try {
        const st = fs.statSync(dir + '/' + n);
        const t: number = st.mtime * 1000;
        rows.push(t);
        map.set(t, n);
      } catch (e) {
      }
    }
    rows.sort((a: number, b: number) => a - b);
    const drop: number = rows.length - KEEP;
    for (let i = 0; i < drop; i++) {
      const n: string | undefined = map.get(rows[i]);
      if (n !== undefined) {
        try {
          fs.unlinkSync(dir + '/' + n);
        } catch (e) {
        }
      }
    }
  } catch (e) {
  }
}

export class ChatCache {
  /** 读不到 / 文件坏了都返回 null，调用方照常走网络。 */
  static read(id: string): ChatSnapshot | null {
    try {
      const p: string = pathOf(id);
      if (!fs.accessSync(p)) {
        return null;
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
    try {
      const tail: Message[] = messages.length > MAX_MSGS ? messages.slice(messages.length - MAX_MSGS) : messages;
      const s: ChatSnapshot = {
        at: Date.now(),
        total: total,
        running: running,
        lastTurn: lastTurn,
        messages: tail
      };
      const p: string = pathOf(id);
      const f = fs.openSync(p, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(s));
      fs.closeSync(f);
      prune();
    } catch (e) {
    }
  }

  static drop(id: string): void {
    try {
      fs.unlinkSync(pathOf(id));
    } catch (e) {
    }
  }
}
