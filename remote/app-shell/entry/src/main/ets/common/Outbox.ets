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

const STORE: string = 'dsh_mobile_outbox';
const KEY: string = 'rows';
const MAX_ROWS: number = 40;
const MAX_BYTES: number = 6 * 1024 * 1024;

export interface StashImage {
  mediaType: string;
  name: string;
  /** base64；旧记录可能没有（当时没带图或没存）。 */
  data: string;
}

export interface StashItem {
  /** 会话 id。 */
  s: string;
  /** 正文（可能为空，纯图消息）。 */
  text: string;
  images: StashImage[];
  /** 记录时间（毫秒）。 */
  t: number;
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

  load(): void {
    if (this.loaded) return;
    this.loaded = true;
    try {
      this.open();
      if (this.store !== null) {
        const raw: string = this.store.getSync(KEY, '[]') as string;
        const arr: StashItem[] = JSON.parse(raw === '' ? '[]' : raw) as StashItem[];
        this.rows = Array.isArray(arr) ? arr : [];
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

  private save(): void {
    try {
      this.open();
      if (this.store === null) return;
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
      this.store.putSync(KEY, JSON.stringify(this.rows));
      this.store.flush();
    } catch (e) {
    }
  }

  /** 发出去时记一条（只有跑着的时候才可能真的排队，但一律记：对账会自动清掉已发出的）。 */
  remember(sessionId: string, text: string, images: StashImage[]): void {
    this.load();
    const body: string = text.trim();
    if (body === '' && images.length === 0) return;
    this.rows.push({ s: sessionId, text: body, images: images, t: Date.now() });
    this.bump();
    this.save();
    console.info('DSH_OUTBOX remember sid=' + sessionId + ' len=' + body.length +
      ' rows=' + this.rows.length + ' store=' + (this.store === null ? 'null' : 'ok'));
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
    for (let i = 0; i < this.rows.length; i++) {
      const r: StashItem = this.rows[i];
      if (r.s !== sessionId) {
        keep.push(r);
        continue;
      }
      let hit: boolean = false;
      for (let k = 0; k < seenTexts.length; k++) {
        if (seenTexts[k] !== '' && seenTexts[k] === r.text) {
          hit = true;
          break;
        }
      }
      if (!hit) keep.push(r);
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
}

export const Outbox = new OutboxStore();
