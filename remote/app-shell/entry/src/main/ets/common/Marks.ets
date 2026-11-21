import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';

const STORE: string = 'dsh_mobile_marks';
const KEY: string = 'rows';
/** 只留最近这么多个会话的结果标记，避免 preferences 无限长大。 */
const LIMIT: number = 120;

interface MarkRow {
  id: string;
  s: string;
  t: number;
}

/**
 * 会话结果标记：宿主没有「中断」这个状态，只能由应用侧推断后记住。
 * 一轮跑完时看日志末条是 user 还是 assistant：user 说明这一轮被打断，
 * assistant 才算真的完成。标记只用于列表卡片的颜色，不参与任何业务判断。
 */
export class Marks {
  private static mem: Map<string, string> | null = null;
  private static store: preferences.Preferences | null = null;
  private static timer: number = 0;
  private static ver: number = 0;

  private static ensure(): void {
    if (Marks.mem !== null) {
      return;
    }
    Marks.mem = new Map<string, string>();
    try {
      const host = getContext() as common.UIAbilityContext;
      const opts: preferences.Options = { name: STORE };
      const p: preferences.Preferences = preferences.getPreferencesSync(host, opts);
      Marks.store = p;
      const raw: string = p.getSync(KEY, '') as string;
      if (raw !== '') {
        const rows: MarkRow[] = JSON.parse(raw) as MarkRow[];
        for (let i = 0; i < rows.length; i++) {
          const s: string = rows[i].s;
          if (s === 'done' || s === 'interrupted') {
            Marks.mem.set(rows[i].id, s);
          }
        }
      }
    } catch (e) {
      console.info('DSH_MARK load failed: ' + JSON.stringify(e));
    }
  }

  static get(id: string): string {
    Marks.ensure();
    if (Marks.mem === null) {
      return '';
    }
    const v: string | undefined = Marks.mem.get(id);
    return v === undefined ? '' : v;
  }

  /** 记录一轮的结果；同一结果不重复写，避免每 3 秒刷新一次界面。 */
  static set(id: string, s: string): void {
    Marks.ensure();
    if (Marks.mem === null) {
      return;
    }
    if (Marks.mem.get(id) === s) {
      return;
    }
    Marks.mem.delete(id);
    Marks.mem.set(id, s);
    while (Marks.mem.size > LIMIT) {
      const first: string | undefined = Marks.mem.keys().next().value;
      if (first === undefined) {
        break;
      }
      Marks.mem.delete(first);
    }
    Marks.bump();
  }

  /** 会话重新跑起来时清掉旧结果，卡片回到「进行中」的蓝。 */
  static clear(id: string): void {
    Marks.ensure();
    if (Marks.mem === null) {
      return;
    }
    if (!Marks.mem.has(id)) {
      return;
    }
    Marks.mem.delete(id);
    Marks.bump();
  }

  private static bump(): void {
    Marks.ver = Marks.ver + 1;
    AppStorage.setOrCreate('marksVer', Marks.ver);
    if (Marks.timer !== 0) {
      clearTimeout(Marks.timer);
    }
    Marks.timer = setTimeout(() => {
      Marks.flush();
    }, 500);
  }

  /** 立刻落盘（离页、退到后台时用）。 */
  static flush(): void {
    if (Marks.mem === null || Marks.store === null) {
      return;
    }
    if (Marks.timer !== 0) {
      clearTimeout(Marks.timer);
      Marks.timer = 0;
    }
    const rows: MarkRow[] = [];
    const it = Marks.mem.entries();
    let step: IteratorResult<[string, string], undefined> = it.next();
    while (!step.done) {
      const row: MarkRow = { id: step.value[0], s: step.value[1], t: Date.now() };
      rows.push(row);
      step = it.next();
    }
    try {
      Marks.store.putSync(KEY, JSON.stringify(rows));
      Marks.store.flushSync();
    } catch (e) {
      console.info('DSH_MARK save failed: ' + JSON.stringify(e));
    }
  }
}
