/**
 * 重启前的「待发送」保险单据：基于 AppCtx.ability().filesDir 原子落盘，兼容旧 preferences 迁移。
 */
import preferences from '@ohos.data.preferences';
import fs from '@ohos.file.fs';
import { AppCtx } from './AppCtx';

const STORE: string = 'dsh_mobile_outbox';
const KEY: string = 'rows';
const FILE_NAME: string = 'outbox.json';
const MAX_ROWS: number = 40;
const MAX_BYTES: number = 6 * 1024 * 1024;

export interface StashImage {
  mediaType: string;
  name: string;
  data: string;
}

export interface SeenImage {
  at: number;
  count: number;
}

export interface StashItem {
  s: string;
  text: string;
  images: StashImage[];
  t: number;
  key?: string;
  kind?: string;
}

class OutboxStore {
  private rows: StashItem[] = [];
  private loaded: boolean = false;
  private store: preferences.Preferences | null = null;
  private ver: number = 0;

  private open(): void {
    if (this.store !== null) {
      return;
    }
    try {
      const opts: preferences.Options = { name: STORE };
      this.store = preferences.getPreferencesSync(AppCtx.ability(), opts);
    } catch (e) {
      this.store = null;
    }
  }

  private filePath(): string {
    try {
      return AppCtx.ability().filesDir + '/' + FILE_NAME;
    } catch (e) {
      return '';
    }
  }

  load(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
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
      }
    }
    try {
      this.open();
      if (this.store !== null) {
        const raw: string = this.store.getSync(KEY, '[]') as string;
        const arr: StashItem[] = JSON.parse(raw === '' ? '[]' : raw) as StashItem[];
        this.rows = Array.isArray(arr) ? arr : [];
        if (this.rows.length > 0 && this.save()) {
          this.store.putSync(KEY, '[]');
          this.store.flushSync();
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
      const tmp: string = path + '.tmp';
      let f: fs.File | null = null;
      try {
        f = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(f.fd, payload);
        fs.closeSync(f);
        f = null;
        fs.renameSync(tmp, path);
        return true;
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
    try {
      this.open();
      if (this.store === null) {
        return false;
      }
      this.store.putSync(KEY, payload);
      this.store.flushSync();
      return true;
    } catch (e) {
      return false;
    }
  }

  remember(sessionId: string, text: string, images: StashImage[], key: string = '', kind: string = ''): boolean {
    this.load();
    const body: string = text.trim();
    if (body === '' && images.length === 0) {
      return true;
    }
    this.rows.push({ s: sessionId, text: body, images: images, t: Date.now(), key: key, kind: kind });
    this.bump();
    return this.save();
  }

  mine(sessionId: string): StashItem[] {
    this.load();
    const out: StashItem[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].s === sessionId) {
        out.push(this.rows[i]);
      }
    }
    return out;
  }

  settle(sessionId: string, seenTexts: string[]): void {
    this.load();
    const before: number = this.rows.length;
    const keep: StashItem[] = [];
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

  settleImages(sessionId: string, seen: SeenImage[]): void {
    this.load();
    const before: number = this.rows.length;
    const keep: StashItem[] = [];
    const used: boolean[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const r: StashItem = this.rows[i];
      if (r.s !== sessionId || r.text !== '' || r.images.length === 0) {
        keep.push(r);
        continue;
      }
      let hit: boolean = false;
      for (let k = 0; k < seen.length; k++) {
        if (used[k]) {
          continue;
        }
        if (seen[k].count >= r.images.length && seen[k].at >= r.t - 60_000 && seen[k].at <= r.t + 600_000) {
          hit = true;
          used[k] = true;
          break;
        }
      }
      if (!hit) {
        keep.push(r);
      }
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
        const keyMatch: boolean = it.key === undefined || it.key === '' ||
          r.key === undefined || r.key === '' || r.key === it.key;
        if (r.s === sessionId && r.s === it.s && r.t === it.t && keyMatch) {
          hit = true;
          break;
        }
      }
      if (!hit) {
        keep.push(r);
      }
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
