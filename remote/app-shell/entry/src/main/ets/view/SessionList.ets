import curves from '@ohos.curves';
import pasteboard from '@ohos.pasteboard';
import { Api, PreviewRow, SessionRow } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { ChatParam } from '../common/Types';

function ago(ms: number): string {
  const d = Date.now() - ms;
  if (d < 60_000) return '刚刚';
  if (d < 3_600_000) return Math.floor(d / 60_000) + ' 分钟前';
  if (d < 86_400_000) return Math.floor(d / 3_600_000) + ' 小时前';
  if (d < 172_800_000) return '昨天';
  return Math.floor(d / 86_400_000) + ' 天前';
}

function dayKey(ms: number): string {
  const now = new Date();
  const t = new Date(ms);
  const a = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const b = new Date(t.getFullYear(), t.getMonth(), t.getDate()).getTime();
  const diff = Math.round((a - b) / 86_400_000);
  if (diff <= 0) return '今天';
  if (diff === 1) return '昨天';
  return '更早';
}

function wsOf(cwd: string): string {
  const parts = cwd.split(/[\\/]/).filter((s: string) => s.length > 0);
  return parts.length > 0 ? parts[parts.length - 1] : '默认';
}

interface RowModel {
  kind: string;
  label: string;
  key: string;
  row: SessionRow;
}

interface WsOpt {
  id: string;
  name: string;
  count: number;
}

/**
 * 摘要只当一行纯文本看，把 Markdown 记号压掉，别让卡片里出现 `#`、`**`、`|`。
 * @param text 服务端给的原始摘要
 * @returns 压平后的一行
 */
function plainPreview(text: string): string {
  return text
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/#{1,6}\s*/g, '')
    .replace(/\*\*([^*]*)\*\*/g, '$1')
    .replace(/^>\s?/g, '')
    .replace(/\|/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** 单个会话卡片：标题 + 摘要 + 时间 + 回复数 + ⋮ */
@Component
export struct SessionTile {
  // 必须是 @Prop：普通成员不会因为父级换了新数据而重绘，
  // 之前表现为「改名后列表还是旧标题、时间停在 xx 分钟前」。
  @Prop row: SessionRow = { id: '', title: '', updatedAt: 0, cwd: '', running: false };
  @Prop preview: string = '';
  @Prop count: number = 0;
  @Prop selMode: boolean = false;
  @Prop selected: boolean = false;
  onTap: () => void = () => {};
  onMore: () => void = () => {};
  onRename: () => void = () => {};
  onPin: () => void = () => {};
  onMulti: () => void = () => {};
  onArchive: () => void = () => {};
  onCopy: () => void = () => {};
  @StorageLink('themeDark') themeDark: boolean = true;
  @State private pressed: boolean = false;

  /** 右侧 ⋮ 的菜单 */
  @Builder
  tileMenu() {
    Menu() {
      MenuItem({ content: '多选' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.onMulti();
        })
      MenuItem({ content: '重命名' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.onRename();
        })
      MenuItem({ content: this.row.pinned === true ? '取消置顶' : '置顶' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.onPin();
        })
      MenuItem({ content: '归档' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.onArchive();
        })
      MenuItem({ content: '复制会话 ID' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.onCopy();
        })
    }
  }

  build() {
    Row() {
      if (this.selMode) {
        Text(this.selected ? 'OK' : '')
          .width(24)
          .height(24)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .borderRadius(12)
          .backgroundColor(this.selected ? Tokens.accent : Tokens.chip)
          .border({ width: 1, color: this.selected ? Tokens.accent : Tokens.glassLine })
          .margin({ right: 10 })
      }
      Column() {
        Row() {
          Text(this.row.title === '' ? '(untitled)' : this.row.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.row.pinned === true) {
            Text('置顶')
              .fontSize(10)
              .fontColor(Tokens.accent)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(999)
              .margin({ left: 6 })
          }
          if (this.row.running === true) {
            Text('运行中')
              .fontSize(10)
              .fontColor(Tokens.ok)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .backgroundColor('#1A3DDC97')
              .borderRadius(999)
              .margin({ left: 6 })
          }
        }
        .width('100%')

        if (this.preview !== '') {
          Text(this.preview)
            .fontSize(13)
            .fontColor(Tokens.dim)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 5 })
            .width('100%')
        }

        Row() {
          Text(ago(this.row.updatedAt))
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
          Text(wsOf(this.row.cwd))
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
            .margin({ left: 10 })
          Blank()
          if (this.count > 0) {
            Text(String(this.count))
              .fontSize(11.5)
              .fontColor(Tokens.dim2)
          }
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('⋮')
        .width(34)
        .height(34)
        .borderRadius(17)
        .textAlign(TextAlign.Center)
        .fontSize(17)
        .fontColor(Tokens.dim2)
        .bindMenu(this.tileMenu())
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 12, bottom: 12 })
    .borderRadius(Tokens.rCard)
    .backgroundColor(this.pressed ? Tokens.surface2 : Tokens.glassStrong)
    .border({ width: 1, color: Tokens.glassLine })
    .scale({ x: this.pressed ? 0.972 : 1, y: this.pressed ? 0.972 : 1 })
    .shadow({
      radius: this.pressed ? 10 : 0,
      color: Tokens.accentGlow,
      offsetY: 2
    })
    .animation({ duration: 300, curve: curves.springCurve(0.66, 0.9, 220, 16) })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .onClick(() => {
      this.pressed = false;
      this.onTap();
    })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressed = true;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}

/** 第一栏：会话列表（工作区胶囊 + 搜索 + 日期分组 + 左滑操作 + 悬浮新建） */
@Component
export struct SessionList {
  api: Api = new Api('', '');
  @Consume('stack') stack: NavPathStack;
  @State private rows: SessionRow[] = [];
  @State private previews: PreviewRow[] = [];
  @State private loading: boolean = true;
  @State private err: string = '';
  @State private q: string = '';
  @State private searching: boolean = false;
  @State private ws: string = '';
  @State private enter: boolean = false;
  @State private creating: boolean = false;
  @State private toast: string = '';
  @State private refreshing: boolean = false;
  @State private scrollY: number = 0;
  @State private selMode: boolean = false;
  @State private selIds: string[] = [];
  // 重命名弹窗盖住底部 Tab：置位时让 ShellPage 把 Tab 栏收掉
  @State @Watch('syncSheet') private renameOn: boolean = false;

  private syncSheet(): void {
    AppStorage.setOrCreate('sheetOpen', this.renameOn);
  }
  @State private renameId: string = '';
  @State private renameText: string = '';
  @StorageLink('themeBg') themeBg: string = Tokens.bg;

  aboutToAppear(): void {
    console.info('DSH_LIST aboutToAppear');
    this.load();
    setTimeout(() => {
      this.enter = true;
    }, 40);
  }

  private async load(): Promise<void> {
    try {
      this.err = '';
      const rows = await this.api.sessions();
      const live = rows.filter((r: SessionRow) => r.archived !== true);
      this.rows = live.sort((a: SessionRow, b: SessionRow) => b.updatedAt - a.updatedAt);
      console.info('DSH_LIST rows=' + this.rows.length);
      this.loadPreviews();
    } catch (e) {
      this.err = (e as Error).message;
      console.error('DSH_LIST fail :: ' + this.err);
    } finally {
      this.loading = false;
    }
  }

  private async loadPreviews(): Promise<void> {
    try {
      const ids: string[] = this.rows.slice(0, 40).map((r: SessionRow) => r.id);
      const got = await this.api.previews(ids);
      this.previews = got;
      console.info('DSH_LIST previews=' + got.length);
    } catch (e) {
      console.info('DSH_LIST previews skipped :: ' + (e as Error).message);
    }
  }

  private previewOf(id: string): string {
    for (let i = 0; i < this.previews.length; i++) {
      if (this.previews[i].id === id) return plainPreview(this.previews[i].preview);
    }
    return '';
  }

  private countOf(id: string): number {
    for (let i = 0; i < this.previews.length; i++) {
      if (this.previews[i].id === id) {
        return this.previews[i].count === undefined ? 0 : this.previews[i].count;
      }
    }
    return 0;
  }

  private runningCount(): number {
    let n = 0;
    this.rows.forEach((r: SessionRow) => {
      if (r.running) n++;
    });
    return n;
  }

  private weekCount(): number {
    const cut = Date.now() - 7 * 86_400_000;
    let n = 0;
    this.rows.forEach((r: SessionRow) => {
      if (r.updatedAt >= cut) n++;
    });
    return n;
  }

  private workspaces(): WsOpt[] {
    const map = new Map<string, number>();
    this.rows.forEach((r: SessionRow) => {
      const k = wsOf(r.cwd);
      map.set(k, (map.get(k) ?? 0) + 1);
    });
    const list: WsOpt[] = [{ id: '', name: '全部工作区', count: this.rows.length }];
    map.forEach((v: number, k: string) => {
      list.push({ id: k, name: k, count: v });
    });
    return list;
  }

  /**
   * 行的 key 里必须带上会变的内容（标题/时间/运行态）。
   * ArkUI 的 ForEach 只按 key 复用子组件，而子组件的 @Prop 又只认「父级状态变量」，
   * 这里的数据是方法现算的，不换 key 就不会重绘——改名后列表停在旧标题就是这么来的。
   */
  private rowKey(r: SessionRow): string {
    // 摘要/条数是异步后到的，同样得进 key，否则卡片会一直空着（见 §六.20）
    return r.id + '|' + r.title + '|' + r.updatedAt + '|' + (r.running ? '1' : '0')
      + '|' + (r.pinned === true ? '1' : '0')
      + '|' + this.countOf(r.id) + '|' + (this.previewOf(r.id) === '' ? '0' : '1');
  }

  private models(): RowModel[] {
    const kw = this.q.trim().toLowerCase();
    const out: RowModel[] = [];
    let lastDay = '';
    // 置顶的排最前，单独成组
    const pinned = this.rows.filter((r: SessionRow) => r.pinned === true);
    const rest = this.rows.filter((r: SessionRow) => r.pinned !== true);
    if (pinned.length > 0) {
      out.push({ kind: 'head', label: '置顶', key: 'h-pin', row: pinned[0] });
      pinned.forEach((r: SessionRow) => {
        if (this.ws !== '' && wsOf(r.cwd) !== this.ws) return;
        if (kw !== '' && (r.title === '' ? '(untitled)' : r.title).toLowerCase().indexOf(kw) < 0) return;
        out.push({ kind: 'row', label: '', key: this.rowKey(r), row: r });
      });
    }
    rest.forEach((r: SessionRow) => {
      if (this.ws !== '' && wsOf(r.cwd) !== this.ws) return;
      if (kw !== '') {
        const t = (r.title === '' ? '(untitled)' : r.title).toLowerCase();
        if (t.indexOf(kw) < 0) return;
      }
      const d = dayKey(r.updatedAt);
      if (d !== lastDay) {
        lastDay = d;
        out.push({ kind: 'head', label: d, key: 'h-' + d, row: r });
      }
      out.push({ kind: 'row', label: '', key: this.rowKey(r), row: r });
    });
    return out;
  }

  private flash(msg: string): void {
    this.toast = msg;
    setTimeout(() => {
      this.toast = '';
    }, 2200);
  }

  private async newSession(): Promise<void> {
    if (this.creating) return;
    this.creating = true;
    try {
      const cwd = this.rows.length > 0 ? this.rows[0].cwd : '';
      const id = await this.api.createSession(cwd);
      const p: ChatParam = { id: id, title: '新会话' };
      this.stack.pushPathByName('chat', p);
      this.flash('已新建会话');
    } catch (e) {
      this.flash('新建失败：' + (e as Error).message);
    } finally {
      this.creating = false;
    }
  }

  private async doPin(r: SessionRow): Promise<void> {
    const want = r.pinned !== true;
    Haptics.soft();
    try {
      await this.api.pin(r.id, want);
      this.rows = this.rows.map((x: SessionRow) => {
        if (x.id !== r.id) return x;
        const y: SessionRow = { id: x.id, title: x.title, updatedAt: x.updatedAt, cwd: x.cwd, running: x.running, archived: x.archived, pinned: want, agents: x.agents, model: x.model };
        return y;
      });
      this.flash(want ? '已置顶' : '已取消置顶');
    } catch (e) {
      this.flash((want ? '置顶失败：' : '取消失败：') + (e as Error).message);
    }
  }

  private async doArchive(r: SessionRow): Promise<void> {
    Haptics.soft();
    try {
      await this.api.archive(r.id);
      this.rows = this.rows.filter((x: SessionRow) => x.id !== r.id);
      this.flash('已归档「' + (r.title === '' ? '(untitled)' : r.title) + '」');
    } catch (e) {
      this.flash('归档失败：' + (e as Error).message);
    }
  }

  /** 多选：进入/退出 */
  private toggleSelMode(): void {
    this.selMode = !this.selMode;
    if (!this.selMode) this.selIds = [];
  }

  private isSelected(id: string): boolean {
    return this.selIds.indexOf(id) >= 0;
  }

  private toggleSel(id: string): void {
    if (this.isSelected(id)) {
      this.selIds = this.selIds.filter((x: string) => x !== id);
    } else {
      this.selIds = this.selIds.concat([id]);
    }
  }

  /** 批量归档选中的会话 */
  private async archiveSelected(): Promise<void> {
    const ids: string[] = this.selIds;
    if (ids.length === 0) {
      this.flash('先选几个会话');
      return;
    }
    let ok = 0;
    for (let i = 0; i < ids.length; i++) {
      try {
        await this.api.archive(ids[i]);
        ok++;
      } catch (e) {
        console.error('DSH_ARCH fail ' + ids[i] + ' :: ' + (e as Error).message);
      }
    }
    this.rows = this.rows.filter((x: SessionRow) => ids.indexOf(x.id) < 0);
    this.flash('已归档 ' + ok + ' 个');
    this.selMode = false;
    this.selIds = [];
  }

  /** 重命名弹层 */
  private openRename(r: SessionRow): void {
    this.renameId = r.id;
    this.renameText = r.title;
    this.renameOn = true;
  }

  private async doRename(): Promise<void> {
    const title: string = this.renameText.trim();
    if (title === '') {
      this.flash('标题不能为空');
      return;
    }
    try {
      await this.api.rename(this.renameId, title);
      this.rows = this.rows.map((x: SessionRow) => {
        if (x.id !== this.renameId) return x;
        const next: SessionRow = { id: x.id, title: title, updatedAt: x.updatedAt, cwd: x.cwd, running: x.running };
        next.pinned = x.pinned;
        next.archived = x.archived;
        return next;
      });
      this.renameOn = false;
      this.flash('已重命名');
      // 本地先改一份立刻可见，再从服务端对齐（分组、时间、置顶可能一起变）
      this.load();
    } catch (e) {
      this.flash('重命名失败：' + (e as Error).message);
    }
  }

  /** 复制会话 ID，方便在电脑上定位 */
  private copyId(r: SessionRow): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, r.id);
      pasteboard.getSystemPasteboard().setData(data);
      this.flash('已复制会话 ID');
    } catch (e) {
      this.flash('复制失败：' + (e as Error).message);
    }
  }

  @Builder
  wsMenu() {
    Menu() {
      ForEach(this.workspaces(), (o: WsOpt) => {
        MenuItem({ content: o.name + ' · ' + o.count })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            this.ws = o.id;
          })
      }, (o: WsOpt) => 'ws-' + o.id)
    }
  }

  /** 左滑露出的操作：置顶 / 归档 */
  @Builder
  swipeActions(r: SessionRow) {
    Row() {
      Text(r.pinned === true ? '取消置顶' : '置顶')
        .fontSize(12.5)
        .fontColor('#FFFFFF')
        .width(64)
        .height(52)
        .textAlign(TextAlign.Center)
        .borderRadius(14)
        .backgroundColor(Tokens.accentStrong)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.doPin(r);
        })
      Text('归档')
        .fontSize(12.5)
        .fontColor('#FFFFFF')
        .width(64)
        .height(52)
        .textAlign(TextAlign.Center)
        .borderRadius(14)
        .backgroundColor(Tokens.dim)
        .margin({ left: 8 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.doArchive(r);
        })
    }
    .padding({ left: 8, right: 8 })
  }

  /** 右侧 ⋮ 菜单 */
  @Builder
  rowMenu(r: SessionRow) {
    Menu() {
      MenuItem({ content: '重命名' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.openRename(r);
        })
      MenuItem({ content: r.pinned === true ? '取消置顶' : '置顶' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.doPin(r);
        })
      MenuItem({ content: '多选' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          if (!this.selMode) this.toggleSelMode();
          this.toggleSel(r.id);
        })
      MenuItem({ content: '归档' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.doArchive(r);
        })
      MenuItem({ content: '复制会话 ID' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.copyId(r);
        })
    }
  }

  /** 重命名弹层 */
  @Builder
  renameSheet() {
    Column() {
      Blank()
      Column() {
        Text('重命名会话')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .margin({ bottom: 14 })
        TextInput({ text: this.renameText, placeholder: '会话标题' })
          .fontSize(14)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .backgroundColor(Tokens.surface2)
          .borderRadius(14)
          .height(46)
          .onChange((v: string) => {
            this.renameText = v;
          })
        Row() {
          Text('取消')
            .fontSize(15)
            .fontColor(Tokens.dim)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .height(46)
            .borderRadius(14)
            .backgroundColor(Tokens.surface2)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.renameOn = false;
            })
          Text('保存')
            .fontSize(15)
            .fontColor(Tokens.accentInk)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .height(46)
            .borderRadius(14)
            .backgroundColor(Tokens.accent)
            .margin({ left: 10 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.doRename();
            })
        }
        .width('100%')
        .margin({ top: 14 })
      }
      .width('100%')
      .padding(18)
      .backgroundColor(Tokens.surface)
      .borderRadius({ topLeft: 26, topRight: 26 })
      .border({ width: 1, color: Tokens.glassLine })
      .margin({ bottom: 104 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .onClick(() => {
      this.renameOn = false;
    })
  }

  /** 列表页顶部整块：工作区胶囊 + 搜索 + 统计。整块是浮层，列表从它底下滚过去。 */
  @Builder
  headerBlock() {
    Column() {
        // 顶部：工作区胶囊 + 搜索
        if (this.selMode) {
          Row() {
            Text('已选 ' + this.selIds.length)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.fg)
            Blank()
            Text('取消')
              .fontSize(14)
              .fontColor(Tokens.dim)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .backgroundColor(Tokens.glassStrong)
              .border({ width: 1, color: Tokens.glassLine })
              .borderRadius(999)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
              .onClick(() => {
                this.selMode = false;
                this.selIds = [];
              })
            Text('归档选中')
              .fontSize(14)
              .fontColor(Tokens.accentInk)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .backgroundColor(this.selIds.length > 0 ? Tokens.accent : Tokens.chip)
              .borderRadius(999)
              .margin({ left: 10 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
              .onClick(() => {
                this.archiveSelected();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 34, bottom: 6 })
        } else {
        if (this.searching) {
          // 搜索气泡：点开后整条顶栏收成一颗输入胶囊，退出时缩回去
          Row() {
            Image($r('app.media.ic_search'))
              .width(17)
              .height(17)
              .fillColor(Tokens.accent)
              .objectFit(ImageFit.Contain)
              .margin({ left: 16, right: 10 })
            TextInput({ placeholder: '搜索会话', text: this.q })
              .fontSize(14)
              .fontColor(Tokens.fg)
              .placeholderColor(Tokens.dim2)
              .backgroundColor(Color.Transparent)
              .height(46)
              .layoutWeight(1)
              .padding({ left: 0, right: 4 })
              .onChange((v: string) => {
                this.q = v;
              })
            Text('取消')
              .fontSize(13)
              .fontColor(Tokens.dim)
              .padding({ left: 8, right: 16 })
              .onClick(() => {
                Haptics.tap();
                this.q = '';
                this.searching = false;
              })
          }
          .width('100%')
          .height(46)
          .margin({ left: 16, right: 16, top: 34 })
          .backgroundColor(Tokens.glassFloat)
          .backdropBlur(18)
          .borderRadius(23)
          .border({ width: 1, color: Tokens.glassLine })
          .shadow({ radius: 20, color: Tokens.shadow, offsetY: 6 })
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.scale({ x: 0.86, y: 0.86 }))
            .animation({ duration: 300, curve: curves.springCurve(0.62, 0.86, 220, 16) }))
        } else {
        Row() {
          Row() {
            Text(this.ws === '' ? '全部工作区' : this.ws)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.fg)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Image($r('app.media.ic_down'))
              .width(15)
              .height(15)
              .margin({ left: 4 })
              .fillColor(Tokens.dim2)
              .objectFit(ImageFit.Contain)
          }
          .padding({ left: 15, right: 15, top: 10, bottom: 10 })
          .backgroundColor(Tokens.glassBar)
          .border({ width: 1, color: Tokens.glassLine })
          .borderRadius(999)
          .bindMenu(this.wsMenu())

          Blank()

          Stack() {
            Image($r('app.media.ic_search'))
              .width(19)
              .height(19)
              .fillColor(Tokens.fg)
              .objectFit(ImageFit.Contain)
          }
          .width(42)
          .height(42)
          .borderRadius(21)
          .backgroundColor(Tokens.glassStrong)
          .border({ width: 1, color: Tokens.glassLine })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => {
            Haptics.tap();
            this.searching = true;
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 34, bottom: 6 })
        }
        }

        // 统计细条（随滚动淡出）
        Row() {
          Text(this.rows.length + ' 会话')
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
          Text(' · ')
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
          Text(this.runningCount() + ' 运行中')
            .fontSize(11.5)
            .fontColor(this.runningCount() > 0 ? Tokens.ok : Tokens.dim2)
          Text(' · ')
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
          Text(this.weekCount() + ' 本周')
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
          Blank()
          if (this.toast !== '') {
            Text(this.toast)
              .fontSize(11)
              .fontColor(Tokens.accent)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .padding({ left: 18, right: 16, bottom: 6 })
        .opacity(1 - Math.min(this.scrollY / 140, 1) * 0.85)
        .translate({ y: -Math.min(this.scrollY / 140, 1) * 8 })
        .animation({ duration: 160, curve: Curve.EaseOut })
    }
    .width('100%')
    .padding({ top: 6 })
    .backgroundColor('#' + 'E6' + this.themeBg.slice(1))
    .backdropBlur(18)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // 头部（工作区/搜索/统计）改成浮层，见 headerBlock()

        if (this.loading) {
          Row() {
            Text('读取会话…')
              .fontSize(12.5)
              .fontColor(Tokens.dim2)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 150 })
        } else if (this.err !== '') {
          Column() {
            Text('读取失败')
              .fontSize(14)
              .fontColor(Tokens.err)
            Text(this.err)
              .fontSize(11.5)
              .fontColor(Tokens.dim2)
              .margin({ top: 6 })
            Text('重试')
              .fontSize(13)
              .fontColor(Tokens.accent)
              .margin({ top: 12 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
              .onClick(() => {
                this.loading = true;
                this.load();
              })
          }
          .width('100%')
          .padding({ top: 40 })
        } else {
          Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 8 }) {
            ListItem() {
              Row().width('100%').height(118)
            }
            ForEach(this.models(), (m: RowModel, idx: number) => {              ListItem() {
                if (m.kind === 'head') {
                  Row() {
                    Text(m.label)
                      .fontSize(11.5)
                      .fontColor(Tokens.dim2)
                      .letterSpacing(1.2)
                  }
                  .width('100%')
                  .padding({ left: 6, top: 10, bottom: 2 })
                } else {
                  SessionTile({
                    row: m.row,
                    preview: this.previewOf(m.row.id),
                    count: this.countOf(m.row.id),
                    selMode: this.selMode,
                    selected: this.isSelected(m.row.id),
                    onTap: () => {
                      if (this.selMode) {
                        this.toggleSel(m.row.id);
                        return;
                      }
                      Haptics.tap();
                      const p: ChatParam = { id: m.row.id, title: m.row.title };
                      this.stack.pushPathByName('chat', p);
                    },
                    onMore: () => {
                      this.doPin(m.row);
                    },
                    onRename: () => {
                      this.openRename(m.row);
                    },
                    onPin: () => {
                      this.doPin(m.row);
                    },
                    onMulti: () => {
                      if (!this.selMode) this.toggleSelMode();
                      this.toggleSel(m.row.id);
                    },
                    onArchive: () => {
                      this.doArchive(m.row);
                    },
                    onCopy: () => {
                      this.copyId(m.row);
                    }
                  })
                  .bindContextMenu(this.rowMenu(m.row), ResponseType.LongPress)
                }
              }
              .swipeAction({ end: this.swipeActions(m.row), edgeEffect: SwipeEdgeEffect.Spring })
              .opacity(this.enter ? 1 : 0)
              .translate({ x: this.enter ? 0 : 14 })
              .animation({
                duration: 300,
                curve: curves.springMotion(0.36, 1.0),
                delay: Math.min(idx, 10) * 18
              })
            }, (m: RowModel) => m.key)
          }
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .contentEndOffset(220)
          .onScroll((x: number, y: number) => {
            this.scrollY = y;
          })
          }
          .width('100%')
          .height('100%')
          .layoutWeight(1)
          .onRefreshing(() => {
            this.refreshing = true;
            this.load().finally(() => {
              this.refreshing = false;
            });
          })
        }
      }
      .width('100%')
      .height('100%')

      this.headerBlock()

      // 右下角悬浮新建（毛玻璃）
      Column() {
        Stack() {
          Text(this.creating ? '…' : '＋')
            .fontSize(30)
            .fontColor(Tokens.fg)
            .textAlign(TextAlign.Center)
            .width(58)
            .height(58)
        }
        .width(58)
        .height(58)
        .borderRadius(29)
        .backgroundColor(Tokens.glassFloat)
        .backdropBlur(18)
        .border({ width: 1, color: Tokens.glassLine })
        .shadow({ radius: 18, color: Tokens.shadow, offsetY: 8 })
        .margin({ right: 22, bottom: 96 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          Haptics.tap();
          this.newSession();
        })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)

      if (this.renameOn) {
        this.renameSheet()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
    // 从聊天页退回来时列表并不会重建，标题/运行状态得自己对齐一次
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number) => {
      if (isVisible && ratio > 0.5 && !this.loading) {
        this.load();
      }
    })
  }
}
