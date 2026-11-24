/**
 * 重启前的「待发送」保险单据。
 *
 * 宿主把排队消息放在进程内存里，重启就没了。手机上这里留一份影子：发出去的同时记一条，
 * 之后每次读会话都拿影子与真实队列/消息对账——真发出去了就把影子删掉；如果宿主重启
 * 把队列丢了，影子还在，聊天页就把它们列成「因重启未发出」让人一键重发。
 *
 * 只做本地记录，不发网络请求：图片字节直接取自发送前挂在输入框上的那份。
 */
import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';

const STORE: string = 'dsh_mobile_outbox';
const KEY: string = 'rows';
const FILE_NAME: string = 'outbox.json';
const MAX_ROWS: number = 40;
const MAX_BYTES: number = 6 * 1024 * 1024;

export interface StashImage {
  mediaType: string;
  name: string;
  /** base64；旧记录可能没有（当时没带图或没存）。 */
  data: string;
}

/** 聊天记录里已出现的「带图用户消息」：时间 + 图片数，用来核销纯图影子。 */
export interface SeenImage {
  at: number;
  count: number;
}

export interface StashItem {
  /** 会话 id。 */
  s: string;
  /** 正文（可能为空，纯图消息）。 */
  text: string;
  images: StashImage[];
  /** 记录时间（毫秒）。 */
  t: number;
  /** 首次提交用的幂等键与路由：重发复用同一身份，宿主不会再收一条。 */
  key?: string;
  kind?: string;
}

class OutboxStore {
  private rows: StashItem[] = [];
  private loaded: boolean = false;
  private store: preferences.Preferences | null = null;
  private ver: number = 0;

  private open(): void {
    if (this.store !== null) return;
    try {
      const host = getContext() as common.UIAbilityContext;
      const opts: preferences.Options = { name: STORE };
      this.store = preferences.getPreferencesSync(host, opts);
    } catch (e) {
      this.store = null;
    }
  }

  /** 影子队列存文件而不是 preferences：preferences 单值放不下 6MB，超限 putSync 会静默丢整队。 */
  private filePath(): string {
    try {
      const ctx = getContext() as common.UIAbilityContext;
      return ctx.filesDir + '/' + FILE_NAME;
    } catch (e) {
      return '';
    }
  }

  load(): void {
    if (this.loaded) return;
    this.loaded = true;
    // 先读文件；文件不存在再退回旧版 preferences 并迁移一次。
    const path: string = this.filePath();
    if (path !== '') {
      try {
        const raw: string = fs.readTextSync(path);
        if (raw !== '') {
          const arr: StashItem[] = JSON.parse(raw) as StashItem[];
          this.rows = Array.isArray(arr) ? arr : [];
          this.bump();
          return;
        }
      } catch (e) {
        // 文件不存在或损坏：走下面的 preferences 迁移
      }
    }
    try {
      this.open();
      if (this.store !== null) {
        const raw: string = this.store.getSync(KEY, '[]') as string;
        const arr: StashItem[] = JSON.parse(raw === '' ? '[]' : raw) as StashItem[];
        this.rows = Array.isArray(arr) ? arr : [];
        if (this.rows.length > 0) {
          this.save();
          // 迁移成功就把旧键清掉：否则文件读失败时旧队列会整队复活，重复/丢消息都可能。
          this.store.putSync(KEY, '[]');
          this.store.flush();
          console.info('DSH_OUTBOX migrated ' + String(this.rows.length) + ' -> file');
        }
      }
    } catch (e) {
      this.rows = [];
    }
    this.bump();
  }

  private bump(): void {
    this.ver = this.ver + 1;
    AppStorage.setOrCreate('outboxVer', this.ver);
  }

  private save(): boolean {
    // 超量的先丢最早的，再按体积裁一次
    while (this.rows.length > MAX_ROWS) {
      this.rows.shift();
    }
    let bytes: number = 0;
    for (let i = this.rows.length - 1; i >= 0; i--) {
      bytes += JSON.stringify(this.rows[i]).length;
      if (bytes > MAX_BYTES) {
        this.rows.splice(i, 1);
      }
    }
    const payload: string = JSON.stringify(this.rows);
    const path: string = this.filePath();
    if (path !== '') {
      // 先写临时文件再改名：原地截断写到一半断电/被杀，会留下半个 JSON，
      // 下次读失败又退回旧 preferences，队列就会出现「复活 / 丢一半」。
      const tmp: string = path + '.tmp';
      try {
        const f = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(f.fd, payload);
        fs.closeSync(f);
        fs.renameSync(tmp, path);
        return true;
      } catch (e) {
        console.info('DSH_OUTBOX atomic write failed: ' + JSON.stringify(e));
        try {
          fs.unlinkSync(tmp);
        } catch (e2) {
        }
      }
    }
    // 文件写不了才退回 preferences（旧设备兜底，超过 8KB 会失败，但至少不静默）
    try {
      this.open();
      if (this.store === null) {
        console.info('DSH_OUTBOX lost: no file, no preferences');
        return false;
      }
      this.store.putSync(KEY, payload);
      this.store.flush();
      return true;
    } catch (e) {
      console.info('DSH_OUTBOX prefs write failed: ' + JSON.stringify(e));
      return false;
    }
  }

  /** 发出去时记一条（只有跑着的时候才可能真的排队，但一律记：对账会自动清掉已发出的）。 */
  remember(sessionId: string, text: string, images: StashImage[], key: string = '',
    kind: string = ''): boolean {
    this.load();
    const body: string = text.trim();
    if (body === '' && images.length === 0) return true;
    this.rows.push({ s: sessionId, text: body, images: images, t: Date.now(), key: key, kind: kind });
    this.bump();
    const ok: boolean = this.save();
    console.info('DSH_OUTBOX remember sid=' + sessionId + ' len=' + body.length +
      ' rows=' + this.rows.length + ' saved=' + String(ok));
    return ok;
  }

  /** 某会话还挂着的影子（按记录顺序，旧的在前）。 */
  mine(sessionId: string): StashItem[] {
    const out: StashItem[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].s === sessionId) out.push(this.rows[i]);
    }
    return out;
  }

  /** 对账：这些正文已经在聊天记录里出现了，说明真发出去了，影子可以删。 */
  settle(sessionId: string, seenTexts: string[]): void {
    this.load();
    const before: number = this.rows.length;
    const keep: StashItem[] = [];
    // 一对一核销：每条已出现的正文最多销掉一条影子。以前是「只要出现过就全删」，
    // 历史上发过同样一句话时，会把刚排队的新消息一起销掉。
    const used: boolean[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const r: StashItem = this.rows[i];
      if (r.s !== sessionId) {
        keep.push(r);
        continue;
      }
      let hit: number = -1;
      if (r.text !== '') {
        for (let k = 0; k < seenTexts.length; k++) {
          if (!used[k] && seenTexts[k] !== '' && seenTexts[k] === r.text) {
            hit = k;
            break;
          }
        }
      }
      if (hit >= 0) {
        used[hit] = true;
        continue;
      }
      keep.push(r);
    }
    if (keep.length !== before) {
      this.rows = keep;
      this.bump();
      this.save();
    }
  }

  /**
   * 纯图片影子的核销：正文是空的，按文字对不上，只能看「之后有没有一条图片数足够的用户消息」。
   * 时间上留 60 秒余量（设备时钟与服务端可能有点差），数量必须不少于影子里的图片数。
   */
  settleImages(sessionId: string, seen: SeenImage[]): void {
    this.load();
    const before: number = this.rows.length;
    const keep: StashItem[] = [];
    // 一对一：一条已出现的带图消息最多核销一条影子，避免历史图文把多条新待发一起抹掉。
    const used: boolean[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const r: StashItem = this.rows[i];
      if (r.s !== sessionId || r.text !== '' || r.images.length === 0) {
        keep.push(r);
        continue;
      }
      let hit: boolean[] | null = null;
      for (let k = 0; k < seen.length; k++) {
        if (used[k]) {
          continue;
        }
        if (seen[k].count >= r.images.length && seen[k].at >= r.t - 60_000 && seen[k].at <= r.t + 600_000) {
          hit = [true];
          used[k] = true;
          break;
        }
      }
      if (hit !== null) {
        continue;
      }
      keep.push(r);
    }
    if (keep.length !== before) {
      this.rows = keep;
      this.bump();
      this.save();
    }
  }

  drop(sessionId: string, items: StashItem[]): void {
    this.load();
    const keep: StashItem[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const r: StashItem = this.rows[i];
      let hit: boolean = false;
      for (let k = 0; k < items.length; k++) {
        const it: StashItem = items[k];
        if (r.s === it.s && r.t === it.t) {
          hit = true;
          break;
        }
      }
      if (!hit) keep.push(r);
    }
    this.rows = keep;
    this.bump();
    this.save();
  }

  clear(sessionId: string): void {
    this.load();
    this.rows = this.rows.filter((r: StashItem) => r.s !== sessionId);
    this.bump();
    this.save();
  }

  /** 全机待发条数：设置里的「应用数据」用它显示与清理。 */
  countAll(): number {
    this.load();
    return this.rows.length;
  }

  clearAll(): void {
    this.load();
    this.rows = [];
    this.bump();
    this.save();
  }
}

export const Outbox = new OutboxStore();
