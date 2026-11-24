import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';

const STORE: string = 'dsh_mobile_drafts';
const KEY: string = 'rows';
/** 只留最近这么多个会话的草稿，避免 preferences 无限长大。 */
const LIMIT: number = 60;

interface DraftRow {
  id: string;
  text: string;
}

/**
 * 输入框草稿：按会话 id 存，切走再回来（甚至杀掉进程重启）都还在。
 * 内存里一份做即时读取，preferences 里一份做持久化；写入合并 500ms 一次。
 */
export class Drafts {
  private static mem: Map<string, string> | null = null;
  private static store: preferences.Preferences | null = null;
  private static timer: number = 0;

  private static ensure(): void {
    if (Drafts.mem !== null) {
      return;
    }
    Drafts.mem = new Map<string, string>();
    try {
      const host = getContext() as common.UIAbilityContext;
      const opts: preferences.Options = { name: STORE };
      const p: preferences.Preferences = preferences.getPreferencesSync(host, opts);
      Drafts.store = p;
      const raw: string = p.getSync(KEY, '') as string;
      if (raw !== '') {
        const rows: DraftRow[] = JSON.parse(raw) as DraftRow[];
        for (let i = 0; i < rows.length; i++) {
          if (rows[i].text !== '') {
            Drafts.mem.set(rows[i].id, rows[i].text);
          }
        }
      }
    } catch (e) {
      console.info('DSH_DRAFT load failed: ' + JSON.stringify(e));
    }
  }

  static get(id: string): string {
    Drafts.ensure();
    if (Drafts.mem === null) {
      return '';
    }
    const v: string | undefined = Drafts.mem.get(id);
    return v === undefined ? '' : v;
  }

  static set(id: string, text: string): void {
    Drafts.ensure();
    if (Drafts.mem === null) {
      return;
    }
    if (text.trim() === '') {
      Drafts.mem.delete(id);
    } else {
      // 重新 set 会把它挪到 Map 末尾，清旧的从头部删就够
      Drafts.mem.delete(id);
      Drafts.mem.set(id, text);
    }
    while (Drafts.mem.size > LIMIT) {
      const first: string | undefined = Drafts.mem.keys().next().value;
      if (first === undefined) {
        break;
      }
      Drafts.mem.delete(first);
    }
    if (Drafts.timer !== 0) {
      clearTimeout(Drafts.timer);
    }
    Drafts.timer = setTimeout(() => {
      Drafts.flush();
    }, 500);
  }

  /** 草稿条数：设置里的「应用数据」用它显示与清理。 */
  static count(): number {
    Drafts.ensure();
    return Drafts.mem === null ? 0 : Drafts.mem.size;
  }

  static clearAll(): void {
    Drafts.ensure();
    if (Drafts.mem === null) {
      return;
    }
    Drafts.mem.clear();
    Drafts.flush();
  }

  /** 立刻落盘（离页、退到后台时用）。 */
  static flush(): void {
    if (Drafts.mem === null || Drafts.store === null) {
      return;
    }
    if (Drafts.timer !== 0) {
      clearTimeout(Drafts.timer);
      Drafts.timer = 0;
    }
    const rows: DraftRow[] = [];
    const it = Drafts.mem.entries();
    let step: IteratorResult<[string, string], undefined> = it.next();
    while (!step.done) {
      const row: DraftRow = { id: step.value[0], text: step.value[1] };
      rows.push(row);
      step = it.next();
    }
    try {
      Drafts.store.putSync(KEY, JSON.stringify(rows));
      Drafts.store.flushSync();
    } catch (e) {
      console.info('DSH_DRAFT save failed: ' + JSON.stringify(e));
    }
  }
}
