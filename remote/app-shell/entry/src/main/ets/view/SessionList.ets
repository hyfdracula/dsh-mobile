import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import curves from '@ohos.curves';
import pasteboard from '@ohos.pasteboard';
import { Api, PreviewRow, SessionRow } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { Machines, Machine } from '../common/Machines';
import { Marks } from '../common/Marks';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { BlurStrategy, HdsNavDestination, HdsNavigationTitleBarOptions, HdsNavigationBackgroundStyle, HdsNavigationTitleBarStyle, HdsNavigation, ScrollEffectOptions, TitleBarContentOptions, TitleBarStyleOptions, hdsMaterial } from '@kit.UIDesignKit';
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

/** 单个会话卡片：点按进入会话，右侧 ⋮ 呼出菜单，不参与多选 */
@Component
export struct SessionTile {
  // 必须是 @Prop：普通成员不会因为父级换了新数据而重绘，
  // 之前表现为「改名后列表还是旧标题、时间停在 xx 分钟前」。
  @Prop row: SessionRow = { id: '', title: '', updatedAt: 0, cwd: '', running: false };
  @Prop preview: string = '';
  @Prop count: number = 0;
  /** 归档视图里 ⋮ 菜单的第三项改成「恢复」，与左滑操作保持一致 */
  @Prop archivedView: boolean = false;

  onTap: () => void = () => {};
  onRename: () => void = () => {};
  onPin: () => void = () => {};
  onArchive: () => void = () => {};
  onCopyId: () => void = () => {};
  onFork: () => void = () => {};
  @StorageLink('themeDark') themeDark: boolean = true;
  // 状态标记（done / interrupted）存在 Marks 里，靠这个版本号触发重绘
  @StorageLink('marksVer') marksVer: number = 0;
  /** 系统点击反馈由 clickEffect 负责，卡片自己不再维护按压态 */
  @State private pressed: boolean = false;
  /** 点 ⋮ 时先把这一行存进来，菜单 builder 就不用带参数绑定了 */
  @State private menuRow: SessionRow = { id: '', title: '', updatedAt: 0, cwd: '', running: false };
  /** 点 ⋮ 的时刻：万一这次点击继续冒泡，别让卡片把它当成「进入会话」 */
  private menuAt: number = 0;

  /** 卡片状态：asking 黄、running 蓝、中断 红、完成 绿、其余无色。 */
  private glowKind(): string {
    // 在等你回答时这一轮仍算 running，但用户看到的应该是「该我了」的黄色，所以 asking 优先于 running。
    if (this.row.asking === true) {
      return 'asking';
    }
    if (this.row.running === true) {
      return 'running';
    }
    const m: string = Marks.get(this.row.id);
    if (m === 'interrupted') {
      return 'interrupted';
    }
    if (m === 'done') {
      return 'done';
    }
    return '';
  }

  private glowBg(): string {
    const k: string = this.glowKind();
    // 底色跟着主题走：原生卡片是不透明的，状态只用淡淡的色相标出来
    const dark: boolean = Tokens.isDark;
    if (k === 'running') {
      return dark ? '#182235' : '#EAF2FF';
    }
    if (k === 'asking') {
      return dark ? '#2A2418' : '#FFF6E5';
    }
    if (k === 'interrupted') {
      return dark ? '#2A1A1A' : '#FFEDED';
    }
    if (k === 'done') {
      return dark ? '#152A20' : '#EAF9F0';
    }
    return dark ? Tokens.surface : '#FFFFFF';
  }

  private glowEdge(): string {
    const k: string = this.glowKind();
    if (k === 'running') {
      return '#803B82F6';
    }
    if (k === 'asking') {
      return '#80F5A623';
    }
    if (k === 'interrupted') {
      return '#80FF3B30';
    }
    if (k === 'done') {
      return '#8034C759';
    }
    return Tokens.isDark ? Tokens.lineSoft : '#E8EAF0';
  }

  private glowShadow(): string {
    const k: string = this.glowKind();
    if (k === 'running') {
      return '#4D3B82F6';
    }
    if (k === 'asking') {
      return '#4DF5A623';
    }
    if (k === 'interrupted') {
      return '#4DFF3B30';
    }
    if (k === 'done') {
      return '#4D34C759';
    }
    return Tokens.accentGlow;
  }

  private hasGlow(): boolean {
    return this.glowKind() !== '';
  }

  /**
   * 菜单针对哪一行：点 ⋮ 时已经把 row 写进 menuRow；
   * 若菜单先于点击回调构建，则回退到卡片自己的 row，两者永远是同一行。
   */
  private menuSource(): SessionRow {
    return this.menuRow.id === '' ? this.row : this.menuRow;
  }

  /** 卡片右侧 ⋮ 呼出的菜单：重命名 / 置顶 / 归档 / 复制 ID / 分叉 */
  @Builder
  tileMenuBuilder() {
    Menu() {
      MenuItem({ content: '重命名' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.onRename();
        })
      MenuItem({ content: this.menuSource().pinned === true ? '取消置顶' : '置顶' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.onPin();
        })
      MenuItem({ content: this.archivedView ? '恢复' : '归档' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.onArchive();
        })
      MenuItem({ content: '复制会话 ID' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.onCopyId();
        })
      MenuItem({ content: '分叉会话' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.onFork();
        })
    }
  }

  build() {
    Row() {
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
              .margin({ left: 8 })
          }
        }
        .width('100%')

        Row() {
          Text(ago(this.row.updatedAt))
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
          Text(wsOf(this.row.cwd))
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
            .margin({ left: 10 })
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // 右侧 ⋮：点开菜单前先把本行存进 @State，菜单 builder 无参
      Text('⋮')
        .fontSize(18)
        .fontColor(Tokens.dim)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .borderRadius(16)
        .margin({ left: 4 })
        .accessibilityText('会话菜单')
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => {
          this.menuAt = Date.now();
          this.menuRow = this.row;
        })
        .bindMenu(this.tileMenuBuilder())
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding({ left: 12, right: 8, top: 12, bottom: 12 })
    .borderRadius(Tokens.rCard)
    .backgroundColor(this.glowBg())
    .border({
      width: this.hasGlow() ? 1.2 : 1,
      color: this.glowEdge()
    })
    // 原生观感：不自己画按压缩放/弹簧，交给 ListItem 的系统点击反馈；
    // 状态色仍靠一圈细边表示，但不加阴影，避免像「浮起来的自绘卡片」。
    .shadow({
      radius: this.hasGlow() ? 10 : 0,
      color: this.glowShadow(),
      offsetY: 0
    })
    .onClick(() => {
      // 刚点过 ⋮ 就不要再进会话
      if (Date.now() - this.menuAt < 350) {
        return;
      }
      this.onTap();
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
  /**
   * 下拉刷新的阶段。刷新圆环只在「正在下拉」和「正在刷新」时画：
   * 以前 refreshArea 无条件渲染，再靠 translate({y:92}) 推到挖孔下面，
   * ArkUI 不裁剪溢出，于是那个转圈永远挂在列表上方 = 用户说的「小地球一直显示」。
   */
  @State private pullState: RefreshStatus = RefreshStatus.Inactive;
  /** 首屏 6 秒还没回来就换成可点的提示，避免一直看着「读取会话…」 */
  @State private loadSlow: boolean = false;
  /** 首屏请求的起始时刻，轮询据此判断是否已被卡死 */
  private loadStart: number = 0;
  private slowTimer: number = -1;
  private loadGen: number = 0;
  /** 换了电脑（设置 → 连接）或分叉出新会话时，列表整份重读 */
  @StorageLink('listDirty') @Watch('onListDirty') listDirty: number = 0;

  /** 通知点击要求直达某个会话：id|时间戳，消费后清空。 */
  @StorageLink('openSessionReq') @Watch('onOpenReq') openReq: string = '';

  private onOpenReq(): void {
    const raw: string = this.openReq;
    if (raw === '') {
      return;
    }
    this.openReq = '';
    const cut: number = raw.lastIndexOf('|');
    const id: string = cut > 0 ? raw.substring(0, cut) : raw;
    if (id === '') {
      return;
    }
    const row: SessionRow | undefined = this.rows.find((r: SessionRow) => r.id === id);
    const p: ChatParam = { id: id, title: row === undefined ? '' : row.title };
    console.info('DSH_PUSH notify id=' + id);
    this.stack.pushPathByName('chat', p);
  }

  private onListDirty(): void {
    if (this.loading) {
      return;
    }
    this.load();
  }

  /** 首页「换电脑」：当前电脑名与弹层开关（machineName 由 Index 传下来） */
  @Prop machineName: string = '';
  onPickMachine: (id: string) => void = () => {};
  @StorageLink('machinesVer') machinesVer: number = 0;
  @State private devOn: boolean = false;
  // 列表视图设置：分组方式 / 列表状态 / 是否显示归档（照 dsh-console 的分组方式菜单）
  @State private viewOn: boolean = false;
  /** 通知点进来时要打开的会话：EntryAbility 写 AppStorage，这里跳转 */
  @State private groupBy: string = 'time';
  @State private listState: string = 'all';

  @State private err: string = '';
  @State private q: string = '';
  @State private searching: boolean = false;
  /** 搜索胶囊横向展开进度：点搜索时先置 0.12 再置 1，靠隐式动画从按钮处流水般铺开。 */
  @State private searchGrow: number = 1;
  @State private ws: string = '';
  @State private enter: boolean = false;
  @State private creating: boolean = false;
  @State private toast: string = '';
  @State private refreshing: boolean = false;
  @State private scrollY: number = 0;
  // 重命名弹窗盖住底部 Tab：置位时让 ShellPage 把 Tab 栏收掉
  @State @Watch('syncSheet') private renameOn: boolean = false;
  // 新建工作区：填一个名字和父目录，宿主机接受不存在的新目录会自动建出来
  @State @Watch('syncSheet') private wsNewOn: boolean = false;
  @State private wsNewName: string = '';
  @State private wsNewDir: string = '';

  private syncSheet(): void {
    AppStorage.setOrCreate('sheetOpen', this.renameOn || this.wsNewOn);
  }
  /** true 时列表只显示已归档的会话 */
  /** 交给 HDS 标题栏的 bindToScrollable，用来驱动滚动模糊 */
  private scroller: Scroller = new Scroller();
  @State private archivedView: boolean = false;
  /** 折叠起来的日期分组（置顶那组永远展开，不参与折叠） */
  @State private folded: string[] = [];
  @State private renameId: string = '';
  @State private renameText: string = '';
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  /** 上次列表的指纹：轮询时只有真的变了才替换数据，避免无谓重绘 */
  private rowSig: string = '';
  private poll: number = 0;

  aboutToAppear(): void {
    console.info('DSH_LIST aboutToAppear');
    this.loadListView();
    this.load();
    // 列表要能自己更新：会话在跑/跑完/等你回答都会改变卡片颜色，不能只在进页面时读一次
    this.poll = setInterval(() => {
      this.pollRows();
    }, 8000);
    setTimeout(() => {
      this.enter = true;
    }, 40);
  }

  aboutToDisappear(): void {
    if (this.poll !== 0) {
      clearInterval(this.poll);
      this.poll = 0;
    }
  }

  private sigOf(rows: SessionRow[]): string {
    const parts: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      const r: SessionRow = rows[i];
      parts.push(r.id + ':' + r.updatedAt + ':' + (r.running ? '1' : '0') + ':' + (r.asking === true ? '1' : '0'));
    }
    return parts.join(',');
  }

  /** 静默轮询：状态变了才换数据，切到别的页面时也不打扰用户。 */
  private async pollRows(): Promise<void> {
    // 首屏请求卡在隧道里时（半死的长连接），这里要能接管，否则列表永远转圈。
    if (this.loading) {
      if (Date.now() - this.loadStart < 9000) {
        return;
      }
      this.loading = false;
      this.loadSlow = false;
    }
    if (this.renameOn || this.creating) {
      return;
    }
    try {
      const rows = await this.api.sessions();
      const want = this.archivedView;
      const live = rows.filter((r: SessionRow) => (r.archived === true) === want);
      const sorted = live.sort((a: SessionRow, b: SessionRow) => b.updatedAt - a.updatedAt);
      const sig: string = this.sigOf(sorted);
      if (sig === this.rowSig) {
        return;
      }
      this.rowSig = sig;
      this.rows = sorted;
      this.applyListState();
      console.info('DSH_LIST poll rows=' + sorted.length);
      this.loadPreviews();
    } catch (e) {
      // 轮询失败不打断界面
    }
  }

  private async load(): Promise<void> {
    // 6 秒兜底的重试可能与首次请求并发：只让最后一次发出的请求写界面，
    // 否则晚到的失败会把已经成功的列表覆盖成错误页。
    this.loadGen++;
    const gen: number = this.loadGen;
    this.loadStart = Date.now();
    this.armSlow(gen);
    try {
      this.err = '';
      const rows = await this.api.sessions();
      if (gen !== this.loadGen) {
        return;
      }
      const want = this.archivedView;
      const live = rows.filter((r: SessionRow) => (r.archived === true) === want);
      this.rows = live.sort((a: SessionRow, b: SessionRow) => b.updatedAt - a.updatedAt);
      this.rowSig = this.sigOf(this.rows);
      console.info('DSH_LIST rows=' + this.rows.length);
      this.loadPreviews();
    } catch (e) {
      if (gen !== this.loadGen) {
        return;
      }
      this.err = (e as Error).message;
      console.error('DSH_LIST fail :: ' + this.err);
    } finally {
      if (gen === this.loadGen) {
        this.loading = false;
        this.loadSlow = false;
        if (this.slowTimer !== -1) {
          clearTimeout(this.slowTimer);
          this.slowTimer = -1;
        }
      }
    }
  }

  /** 6 秒还没回来就把「读取会话…」换成能点的重试，别让用户干等 */
  private armSlow(gen: number): void {
    if (this.slowTimer !== -1) {
      clearTimeout(this.slowTimer);
    }
    this.slowTimer = setTimeout(() => {
      this.slowTimer = -1;
      if (gen === this.loadGen) {
        this.loadSlow = true;
      }
    }, 6000);
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
      + '|' + (r.asking === true ? '1' : '0') + '|' + Marks.get(r.id)
      + '|' + (r.pinned === true ? '1' : '0')
      + '|' + this.countOf(r.id) + '|' + (this.previewOf(r.id) === '' ? '0' : '1');
  }

  private models(): RowModel[] {
    const kw = this.q.trim().toLowerCase();
    const out: RowModel[] = [];
    let lastDay = '';
    // 置顶的排最前，单独成组
    const pinned = this.archivedView ? [] : this.rows.filter((r: SessionRow) => r.pinned === true);
    const rest = this.archivedView ? this.rows : this.rows.filter((r: SessionRow) => r.pinned !== true);
    const pinnedShown: SessionRow[] = pinned.filter((r: SessionRow) => {
      if (this.ws !== '' && wsOf(r.cwd) !== this.ws) return false;
      if (kw !== '' && (r.title === '' ? '(untitled)' : r.title).toLowerCase().indexOf(kw) < 0) return false;
      return true;
    });
    if (pinnedShown.length > 0) {
      out.push({ kind: 'head', label: '置顶', key: 'h-pin', row: pinnedShown[0] });
      pinnedShown.forEach((r: SessionRow) => {
        out.push({ kind: 'row', label: '', key: this.rowKey(r), row: r });
      });
    }
    rest.forEach((r: SessionRow) => {
      if (this.ws !== '' && wsOf(r.cwd) !== this.ws) return;
      if (kw !== '') {
        const t = (r.title === '' ? '(untitled)' : r.title).toLowerCase();
        if (t.indexOf(kw) < 0) return;
      }
      // 归档视图不按日期分堆：就按宿主给的顺序一条条排下来
      if (this.archivedView) {
        out.push({ kind: 'row', label: '', key: this.rowKey(r), row: r });
        return;
      }
      if (this.groupBy === 'ws') {
        const g = this.groupName(r.cwd);
        if (g !== lastDay) {
          lastDay = g;
          out.push({ kind: 'head', label: g, key: 'h-w-' + g + (this.isFolded(g) ? '-c' : '-o'), row: r });
        }
        if (this.isFolded(g)) return;
        out.push({ kind: 'row', label: '', key: this.rowKey(r), row: r });
        return;
      }
      const d = dayKey(r.updatedAt);
      if (d !== lastDay) {
        lastDay = d;
        out.push({ kind: 'head', label: d, key: 'h-' + d + (this.isFolded(d) ? '-c' : '-o'), row: r });
      }
      // 折叠的分组只留标题，卡片全部收起来
      if (this.isFolded(d)) return;
      out.push({ kind: 'row', label: '', key: this.rowKey(r), row: r });
    });
    return out;
  }

  /** 工作区分组的组名：路径末段，拿不到就给「其他」 */
  private groupName(cwd: string): string {
    const w: string = wsOf(cwd);
    const parts: string[] = w.split('\\');
    const last: string = parts.length > 0 ? parts[parts.length - 1] : w;
    return last !== '' ? last : '其他';
  }

  /** 按当前设置重算折叠：全打开 / 只开第一组 / 全关 */
  private applyListState(): void {
    if (this.listState === 'all') {
      this.folded = [];
      return;
    }
    const labels: string[] = this.groupLabels();
    if (this.listState === 'none') {
      this.folded = labels;
      return;
    }
    const rest: string[] = labels.length > 1 ? labels.slice(1) : [];
    this.folded = rest;
  }

  /** 当前分组下所有组标题（不含置顶） */
  private groupLabels(): string[] {
    const out: string[] = [];
    if (this.groupBy === 'ws') {
      this.rows.forEach((r: SessionRow) => {
        if (r.pinned === true && !this.archivedView) return;
        const g: string = this.groupName(r.cwd);
        if (out.indexOf(g) < 0) {
          out.push(g);
        }
      });
      return out;
    }
    this.rows.forEach((r: SessionRow) => {
      if (r.pinned === true && !this.archivedView) return;
      const d: string = dayKey(r.updatedAt);
      if (out.indexOf(d) < 0) {
        out.push(d);
      }
    });
    return out;
  }

  private async loadListView(): Promise<void> {
    try {
      const host = getContext() as common.UIAbilityContext;
      const opts: preferences.Options = { name: 'dsh_mobile_listview' };
      const p: preferences.Preferences = preferences.getPreferencesSync(host, opts);
      const g: string = p.getSync('groupBy', 'time') as string;
      const st: string = p.getSync('listState', 'all') as string;
      this.groupBy = g === 'ws' ? 'ws' : 'time';
      this.listState = st === 'first' || st === 'none' ? st : 'all';
    } catch (e) {
      console.info('DSH_VIEW load failed: ' + JSON.stringify(e));
    }
  }

  private saveListView(): void {
    try {
      const host = getContext() as common.UIAbilityContext;
      const opts: preferences.Options = { name: 'dsh_mobile_listview' };
      const p: preferences.Preferences = preferences.getPreferencesSync(host, opts);
      p.putSync('groupBy', this.groupBy);
      p.putSync('listState', this.listState);
      p.flushSync();
    } catch (e) {
      console.info('DSH_VIEW save failed: ' + JSON.stringify(e));
    }
  }

  private setGroupBy(g: string): void {
    Haptics.tap();
    this.groupBy = g;
    this.viewOn = false;
    this.saveListView();
    this.applyListState();
  }

  private setListState(st: string): void {
    Haptics.tap();
    this.listState = st;
    this.viewOn = false;
    this.saveListView();
    this.applyListState();
  }

  private toggleArchivedFromMenu(): void {
    Haptics.tap();
    this.viewOn = false;
    if (this.archivedView) {
      this.exitArchived();
      return;
    }
    this.archivedView = true;
    this.loading = true;
    this.load();
  }

  private markAllRead(): void {
    Haptics.tap();
    this.viewOn = false;
    Marks.clearAll();
  }

  private isFolded(label: string): boolean {
    return this.folded.indexOf(label) >= 0;
  }

  private toggleFold(label: string): void {
    Haptics.tap();
    this.folded = this.isFolded(label)
      ? this.folded.filter((s: string) => s !== label)
      : this.folded.concat([label]);
  }

  private flash(msg: string): void {
    this.toast = msg;
    setTimeout(() => {
      this.toast = '';
    }, 2200);
  }

  /** 建会话时可选的工作区：当前筛选的、最近用过的，去重保序。 */
  private wsChoices(): string[] {
    const out: string[] = [];
    const push = (p: string): void => {
      const one: string = this.tidyPath(p);
      if (one !== '' && out.indexOf(one) < 0) out.push(one);
    };
    if (this.ws !== '') push(this.baseDir());
    for (let i = 0; i < this.rows.length && out.length < 8; i++) {
      if (this.rows[i].archived !== true) push(this.rows[i].cwd);
    }
    return out;
  }

  private async newSessionIn(dir: string): Promise<void> {
    if (this.creating) return;
    this.creating = true;
    try {
      const cwd: string = dir !== '' ? dir : (this.rows.length > 0 ? this.rows[0].cwd : '');
      const id = await this.api.createSession(cwd);
      const p: ChatParam = { id: id, title: '新会话' };
      this.stack.pushPathByName('chat', p);
      this.flash('已在该工作区新建会话');
    } catch (e) {
      this.flash('新建失败：' + (e as Error).message);
    } finally {
      this.creating = false;
    }
  }

  @State private wsPickOn: boolean = false;

  @Builder
  wsPickBody() {
    Column() {
      Row() {
        Text('新建会话')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.fg)
        Blank()
        Text('×')
          .fontSize(19)
          .fontColor(Tokens.dim)
          .textAlign(TextAlign.Center)
          .width(38)
          .height(38)
          .borderRadius(999)
          .onClick(() => {
            this.wsPickOn = false;
          })
      }
      .width('100%')
      .height(56)

      Text('选一个工作区')
        .fontSize(11.5)
        .fontColor(Tokens.dim2)
        .width('100%')

      List({ space: 8 }) {
        ForEach(this.wsChoices(), (d: string) => {
          ListItem() {
            Row({ space: 10 }) {
              Text('▥')
                .fontSize(13)
                .fontColor(Tokens.accent)
                .width(30)
                .height(30)
                .textAlign(TextAlign.Center)
                .borderRadius(9)
                .backgroundColor(Tokens.accentSoft)
              Text(this.wsLabel(d))
                .fontSize(14)
                .fontColor(Tokens.fg)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text('›')
                .fontSize(15)
                .fontColor(Tokens.dim2)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .borderRadius(14)
            .backgroundColor(Tokens.surface)
            .onClick(() => {
              this.wsPickOn = false;
              void this.newSessionIn(d);
            })
          }
        }, (d: string) => d)

        ListItem() {
          Row({ space: 10 }) {
            Text('+')
              .fontSize(15)
              .fontColor(Tokens.accent)
              .width(30)
              .height(30)
              .textAlign(TextAlign.Center)
              .borderRadius(9)
              .backgroundColor(Tokens.accentSoft)
            Text('另建一个工作区…')
              .fontSize(14)
              .fontColor(Tokens.fg)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .borderRadius(14)
          .backgroundColor(Tokens.surface)
          .onClick(() => {
            this.wsPickOn = false;
            this.openWsNew();
          })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .margin({ top: 10 })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 6, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

    /** 只显示路径末尾两段，太长了菜单里看不清 */
  private wsLabel(d: string): string {
    const parts: string[] = d.split('\\');
    if (parts.length <= 1) return d;
    if (parts.length === 2) return parts[1];
    return parts[parts.length - 2] + '\\' + parts[parts.length - 1];
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
        const y: SessionRow = { id: x.id, title: x.title, updatedAt: x.updatedAt, cwd: x.cwd, running: x.running, asking: x.asking, archived: x.archived, pinned: want, agents: x.agents, model: x.model };
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

  private async doUnarchive(r: SessionRow): Promise<void> {
    Haptics.soft();
    try {
      await this.api.unarchive(r.id);
      this.rows = this.rows.filter((x: SessionRow) => x.id !== r.id);
      this.flash('已恢复「' + (r.title === '' ? '(untitled)' : r.title) + '」');
    } catch (e) {
      this.flash('恢复失败：' + (e as Error).message);
    }
  }

  /** 分叉会话：宿主按最近一个已完成轮次的边界复制出一个新会话（Api.fork 的 atSeq 省略） */
  private async doFork(r: SessionRow): Promise<void> {
    Haptics.soft();
    try {
      const id: string = await this.api.fork(r.id);
      if (id === '') {
        this.flash('分叉失败');
        return;
      }
      Haptics.tap();
      this.flash('已分叉「' + (r.title === '' ? '(untitled)' : r.title) + '」');
      // 新会话要出现在列表里，重新拉一遍
      this.load();
    } catch (e) {
      this.flash('分叉失败：' + (e as Error).message);
    }
  }

  /** 从「已归档对话」退回正常列表：清掉归档标记、重拉一次 */
  private exitArchived(): void {
    if (!this.archivedView) {
      return;
    }
    this.archivedView = false;
    this.loading = true;
    this.load();
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
        const next: SessionRow = { id: x.id, title: title, updatedAt: x.updatedAt, cwd: x.cwd, running: x.running, asking: x.asking };
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
      // 新工作区就是宿主机上的一层新目录：建一个会话指向它，列表里自然多一项
      MenuItem({ content: '＋ 新建工作区' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          Haptics.tap();
          this.openWsNew();
        })
    }
  }

  /** 新建工作区弹层 */
  private openWsNew(): void {
    this.wsNewName = '';
    this.wsNewDir = this.baseDir();
    this.wsNewOn = true;
  }

  /**
   * 新工作区默认建在哪：优先当前筛选的那个工作区目录本身，
   * 其次最近一条未归档会话的目录，最后才退到 Documents。
   */
  private baseDir(): string {
    const live: SessionRow[] = this.rows.filter((r: SessionRow) => r.archived !== true && r.cwd !== undefined && r.cwd !== '');
    for (const r of live) {
      const p: string = this.tidyPath(r.cwd);
      if (this.ws !== '' && wsOf(p) === this.ws) return p;
    }
    for (const r of live) {
      const p: string = this.tidyPath(r.cwd);
      if (p !== '') return p;
    }
    return 'C:\\Users\\19161\\Documents';
  }

  /** 宿主里可能存着带重复分隔符的路径（历史会话），显示与拼接前先压成单个 */
  private tidyPath(p: string): string {
    let out: string = p.replace(/\\\\/g, '\\');
    while (out.indexOf('\\\\') >= 0) {
      out = out.replace(/\\\\/g, '\\');
    }
    return out;
  }

  /** 父目录 + 名字拼成宿主机上的路径；名字不许带分隔符 */
  private wsPath(): string {
    const name: string = this.wsNewName.trim().replace(/[\\/:*?"<>|]/g, '');
    let dir: string = this.tidyPath(this.wsNewDir.trim());
    if (dir === '') dir = 'C:\\Users\\19161\\Documents';
    while (dir.length > 1 && (dir.endsWith('\\') || dir.endsWith('/'))) {
      dir = dir.substring(0, dir.length - 1);
    }
    if (name === '') return '';
    return dir + '\\' + name;
  }

  private async doCreateWs(): Promise<void> {
    const path: string = this.wsPath();
    if (path === '') {
      this.flash('工作区名字不能为空');
      return;
    }
    Haptics.tap();
    try {
      const id: string = await this.api.createSession(path);
      this.wsNewOn = false;
      this.ws = wsOf(path);
      this.flash('已新建工作区「' + wsOf(path) + '」');
      await this.load();
      if (id !== '') {
        const p: ChatParam = { id: id, title: '新会话' };
        this.stack.pushPathByName('chat', p);
      }
    } catch (e) {
      this.flash('新建工作区失败：' + (e as Error).message);
    }
  }

  /** 已归档视图里，工作区胶囊换成「已归档对话」，点开第一条就是返回 */
  @Builder
  archivedMenu() {
    Menu() {
      MenuItem({ content: '返回会话列表' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          Haptics.tap();
          this.exitArchived();
        })
      MenuItem({ content: '全部工作区' })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          Haptics.tap();
          this.ws = '';
          this.exitArchived();
        })
    }
  }

  /** 分组标题不参与左滑，用空动作占位 */
  @Builder
  noSwipe() {
  }

  /** 左滑露出的操作：置顶 / 归档，高度与会话卡片对齐 */
  @Builder
  swipeActions(r: SessionRow) {
    Row() {
      Text(r.pinned === true ? '取消置顶' : '置顶')
        .fontSize(12.5)
        .fontColor('#FFFFFF')
        .width(58)
        .height(58)
        .textAlign(TextAlign.Center)
        .borderRadius(14)
        .backgroundColor(Tokens.accentStrong)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.doPin(r);
        })
      Text(this.archivedView ? '恢复' : '归档')
        .fontSize(12.5)
        .fontColor('#FFFFFF')
        .width(58)
        .height(58)
        .textAlign(TextAlign.Center)
        .borderRadius(14)
        .backgroundColor(this.archivedView ? Tokens.accentStrong : Tokens.err)
        .margin({ left: 8 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          if (this.archivedView) {
            this.doUnarchive(r);
          } else {
            this.doArchive(r);
          }
        })
    }
    .height(60)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 8, right: 0 })
  }

  /** 长按卡片弹出的上下文菜单（不含多选、不含分叉） */
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

  @Builder
  wsNewSheet() {
    Column() {
      Blank()
      Column() {
        Text('新建工作区')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .margin({ bottom: 14 })
        TextInput({ text: this.wsNewName, placeholder: '工作区名字，例如 my-project' })
          .fontSize(14)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .backgroundColor(Tokens.surface2)
          .borderRadius(14)
          .height(46)
          .onChange((v: string) => {
            this.wsNewName = v;
          })
        TextInput({ text: this.wsNewDir, placeholder: '放在哪个目录下' })
          .fontSize(12.5)
          .fontColor(Tokens.dim)
          .placeholderColor(Tokens.dim2)
          .backgroundColor(Tokens.surface2)
          .borderRadius(14)
          .height(46)
          .margin({ top: 10 })
          .onChange((v: string) => {
            this.wsNewDir = v;
          })
        // 建完实际落在这台电脑的哪个目录，先给用户看一眼
        Text(this.wsPath() === '' ? '会在电脑上新建这个目录' : this.wsPath())
          .fontSize(11.5)
          .fontColor(Tokens.dim2)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 8, left: 2 })
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
              this.wsNewOn = false;
            })
          Text(this.creating ? '创建中…' : '创建')
            .fontSize(15)
            .fontColor(Tokens.accentInk)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .height(46)
            .borderRadius(14)
            .backgroundColor(this.wsPath() === '' ? Tokens.surface3 : Tokens.accent)
            .margin({ left: 10 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.doCreateWs();
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
    .onClick(() => {
      this.wsNewOn = false;
    })
  }

  /** 列表页顶部整块：工作区胶囊 + 搜索 + 统计。整块是浮层，列表从它底下滚过去。 */
  /** 「192.168.1.3:8901」这种名字只留主机部分，胶囊里不占地方 */
  private devShort(): string {
    let n: string = this.machineName !== '' ? this.machineName : Machines.displayName();
    n = n.replace('http://', '').replace('https://', '');
    const cut: number = n.indexOf('/');
    if (cut > 0) {
      n = n.substring(0, cut);
    }
    // 去掉端口：胶囊里只留主机，够认得出来
    const colon: number = n.lastIndexOf(':');
    if (colon > 0 && n.indexOf(']') < colon) {
      n = n.substring(0, colon);
    }
    return n;
  }

  @Builder
  devSheet() {
    Column() {
      // 顶部留够空间：系统那个 × 在右上角，标题贴太近会和第一张卡片撞在一起
      Text('切换电脑')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .width('100%')
        .padding({ left: 20, right: 20, top: 34, bottom: 14 })

      List({ space: 10 }) {
        ForEach(Machines.list(), (m: Machine) => {
          ListItem() {
            Row() {
              Column() {
                Text(m.name !== '' ? m.name : m.id)
                  .fontSize(15)
                  .fontColor(Tokens.fg)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(m.wan)
                  .fontSize(11)
                  .fontColor(Tokens.dim2)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (Machines.activeId() === m.id) {
                Text('当前')
                  .fontSize(11)
                  .fontColor(Tokens.accent)
                  .backgroundColor(Tokens.accentSoft)
                  .borderRadius(999)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .backgroundColor(Tokens.surface2)
            .borderRadius(14)
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              Haptics.tap();
              this.devOn = false;
              if (Machines.activeId() !== m.id) {
                this.onPickMachine(m.id);
              }
            })
          }
        }, (m: Machine) => m.id + '@' + String(m.at))
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: 16, right: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.surface)
  }

  /** 菜单里的一行：左侧标题，选中时右侧一个勾 */
  @Builder
  viewOpt(label: string, on: boolean, act: () => void) {
    Row() {
      Text(label)
        .fontSize(13.5)
        .fontColor(Tokens.fg)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (on) {
        Text('✓')
          .fontSize(13)
          .fontColor(Tokens.accent)
      }
    }
    .width('100%')
    .height(38)
    .padding({ left: 12, right: 12 })
    .borderRadius(9)
    .backgroundColor(on ? (Tokens.isDark ? '#26FFFFFF' : '#99FFFFFF') : Color.Transparent)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(act)
  }

  @Builder
  viewHead(label: string) {
    Text(label)
      .fontSize(10.5)
      .fontColor(Tokens.dim2)
      .width('100%')
      .padding({ left: 12, top: 8, bottom: 4 })
  }

  /** 分组方式菜单：结构照 dsh-console */
  @Builder
  viewMenu() {
    Column() {
      this.viewHead('分组方式')
      this.viewOpt('按时间排列（今天／昨天／更早）', this.groupBy === 'time', (): void => {
        this.setGroupBy('time');
      })
      this.viewOpt('按工作区', this.groupBy === 'ws', (): void => {
        this.setGroupBy('ws');
      })
      Divider().color(Tokens.lineSoft).margin({ top: 6, bottom: 2 })
      this.viewHead('筛选会话')
      this.viewOpt('显示已归档的会话', this.archivedView, (): void => {
        if (!this.archivedView) {
          this.toggleArchivedFromMenu();
        } else {
          this.viewOn = false;
        }
      })
      this.viewOpt('隐藏已归档的会话', !this.archivedView, (): void => {
        if (this.archivedView) {
          this.toggleArchivedFromMenu();
        } else {
          this.viewOn = false;
        }
      })
      Divider().color(Tokens.lineSoft).margin({ top: 6, bottom: 2 })
      this.viewHead('列表状态')
      this.viewOpt('默认全打开', this.listState === 'all', (): void => {
        this.setListState('all');
      })
      this.viewOpt('默认打开第一列', this.listState === 'first', (): void => {
        this.setListState('first');
      })
      this.viewOpt('默认关闭', this.listState === 'none', (): void => {
        this.setListState('none');
      })
      Divider().color(Tokens.lineSoft).margin({ top: 6, bottom: 2 })
      this.viewHead('已完成')
      this.viewOpt('全部标为已读', false, (): void => {
        this.markAllRead();
      })
    }
    .width(268)
    .padding({ left: 6, right: 6, top: 8, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.isDark ? '#E6171B22' : '#F2FFFFFF')
    .backdropBlur(24)
    .borderRadius(18)
    .border({ width: 1, color: Tokens.isDark ? '#33FFFFFF' : '#D9FFFFFF' })
    .shadow({ radius: 26, color: Tokens.shadow, offsetY: 10 })
  }

  /** 下拉刷新区域：整块下移到摄像头开孔以下（默认位置在 0，会被挖孔挡住） */
  @Builder
  refreshArea() {
    Row({ space: 8 }) {
      // 关键：空闲时这里什么都不画。Refresh 的 builder 区域是常驻节点，
      // 画了就一直在（再叠加下面的 translate 位移，就变成列表上方那个不走的圆环）。
      if (this.refreshing || this.pullState === RefreshStatus.Drag ||
        this.pullState === RefreshStatus.OverDrag) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(Tokens.dim2)
        Text(this.refreshing ? '正在刷新' : '松开刷新')
          .fontSize(11.5)
          .fontColor(Tokens.dim2)
      }
    }
    .width('100%')
    // Refresh 给指示器的高度就是下拉距离，超过就被裁掉；所以用位移把它整体推到挖孔下方。
    // 横向排（转圈 + 文字）比竖排矮，位移后不会被裁掉文字。
    .translate({ y: 92 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  headerBlock() {
    Column() {
        // 顶部：工作区胶囊 + 搜索
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
                this.searchGrow = 0.12;
                setTimeout(() => {
                  this.searching = false;
                  this.searchGrow = 1;
                }, 200);
              })
          }
          .width('100%')
          .height(46)
          .margin({ left: 0, right: 0, top: 0 })
          .backgroundColor(Tokens.glassFloat)
          .backdropBlur(18)
          .borderRadius(23)
          .border({ width: 1, color: Tokens.pillEdge })
          .shadow({ radius: 20, color: Tokens.shadow, offsetY: 6 })
          .systemMaterial(Mat.whiteOn(this.matOn()))
          // 流水式展开：只横向缩放、高度不动，原点钉在右侧搜索按钮的 x 上，没有回弹
          .scale({ x: this.searchGrow, y: 1, centerX: 370, centerY: '50%' })
          .opacity(this.searchGrow <= 0.12 ? 0 : 1)
          .animation({ duration: 440, curve: curves.cubicBezierCurve(0.16, 0.9, 0.26, 1.0) })
        } else {
        Row() {
          Row() {
            Text(this.archivedView ? '已归档对话' : (this.ws === '' ? '全部工作区' : this.ws))
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
          .padding({ left: 15, right: 15 })
          .height(42)
          .backgroundColor(Tokens.glassBar)
          .border({ width: 1, color: Tokens.pillEdge })
          .borderRadius(999)
          .constraintSize({ minWidth: 120, minHeight: 42 })
          .shadow({ radius: 12, color: Tokens.accentGlow, offsetY: 2 })
          .systemMaterial(Mat.whiteOn(this.matOn()))
          .bindMenu(this.archivedView ? this.archivedMenu() : this.wsMenu())

          Blank()

          // 换电脑：圆形电脑图标，紧挨着已归档按钮（不占地方，也不用写地址）
          Stack() {
            Image($r('app.media.ic_pc'))
              .width(19)
              .height(19)
              .fillColor(this.machinesVer > 0 ? Tokens.accent : Tokens.fg)
              .objectFit(ImageFit.Contain)
          }
          .width(42)
          .height(42)
          .borderRadius(21)
          .margin({ right: 10 })
          .backgroundColor(Tokens.glassStrong)
          .border({ width: 1, color: Tokens.pillEdge })
          .shadow({ radius: 12, color: Tokens.accentGlow, offsetY: 2 })
          .systemMaterial(Mat.whiteOn(this.matOn()))
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .accessibilityText('切换电脑')
          .onClick(() => {
            Haptics.tap();
            this.devOn = true;
          })
          .bindSheet($$this.devOn, this.devSheet(), {
            height: '42%',
            dragBar: true,
            showClose: true,
            backgroundColor: Tokens.surface,
            maskColor: '#33000000',
            onDisappear: () => {
              this.devOn = false;
            }
          })

          // 分组方式：照 dsh-console 的菜单（分组 / 筛选 / 列表状态 / 全部标为已读）
          Stack() {
            Image($r('app.media.ic_group'))
              .width(19)
              .height(19)
              .fillColor(this.archivedView ? Tokens.accent : Tokens.fg)
              .objectFit(ImageFit.Contain)
          }
          .width(42)
          .height(42)
          .borderRadius(21)
          .backgroundColor(Tokens.glassStrong)
          .border({ width: 1, color: Tokens.pillEdge })
          .shadow({ radius: 12, color: Tokens.accentGlow, offsetY: 2 })
          .systemMaterial(Mat.whiteOn(this.matOn()))
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .accessibilityText('分组方式')
          .onClick(() => {
            Haptics.tap();
            this.viewOn = true;
          })
          .bindPopup(this.viewOn, {
            builder: this.viewMenu(),
            placement: Placement.Bottom,
            popupColor: Color.Transparent,
            enableArrow: false,
            radius: 18,
            offset: { x: 0, y: 6 },
            transition: TransitionEffect.OPACITY
              .combine(TransitionEffect.scale({ x: 0.94, y: 0.94, centerX: '100%', centerY: '0%' }))
              .animation({ duration: 180, curve: Curve.EaseOut }),
            onStateChange: (e) => {
              if (!e.isVisible) {
                this.viewOn = false;
              }
            }
          })

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
          .border({ width: 1, color: Tokens.pillEdge })
          .shadow({ radius: 12, color: Tokens.accentGlow, offsetY: 2 })
          .margin({ left: 10 })
          .systemMaterial(Mat.whiteOn(this.matOn()))
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => {
            Haptics.tap();
            this.searchGrow = 0.12;
            this.searching = true;
            setTimeout(() => {
              this.searchGrow = 1;
            }, 40);
          })
        }
        .width('100%')
        .height(42)
        .padding({ left: 16, right: 16 })
        // 非搜索态淡出，和搜索胶囊的展开错开一点，看得到「让位」
        .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
        }
    }
    .width('100%')
    .padding({ top: 45 })
  }

  /** HDS 标题栏：容器本身不画底板（用户要求控件直接浮在列表上），材质只挂在三个控件上 */
  private listTitle(): HdsNavigationTitleBarOptions {
    const stack: CustomBuilder = (): void => {
      this.headerBlock();
    };
    const content: TitleBarContentOptions = { stackBuilder: stack };
    const style: TitleBarStyleOptions = {};
    // 同样不要整条底板
    const bgStyle: HdsNavigationBackgroundStyle = {};
    bgStyle.backgroundColor = Color.Transparent;
    bgStyle.blurRadius = 0;
    // 标题栏下面那条泛白/泛灰的整块遮罩就是它：额外遮罩高度清零
    bgStyle.maskExtraHeight = 0;
    const origStyle: HdsNavigationTitleBarStyle = {};
    origStyle.backgroundStyle = bgStyle;
    style.originalStyle = origStyle;
    // 标题栏自带的模糊带：彻底关掉，让内容直接从胶囊后面穿过
    style.blurStrategy = BlurStrategy.DISABLE;
    // 关键：HDS 标题栏默认开启滚动特效（COMMON_BLUR + 默认底色），滚动后会画出一条
    // 半透明遮罩带。scrollEffectStyle 未设时用的是系统默认样式，所以必须显式关掉。
    const eff: ScrollEffectOptions = {};
    eff.enableScrollEffect = false;
    style.scrollEffectOpts = eff;
    // 双保险：即使系统仍走滚动样式，也用同一套透明底色
    style.scrollEffectStyle = origStyle;
    const opts: HdsNavigationTitleBarOptions = { content: content, style: style };
    return opts;
  }

  /** 沉浸光感是否生效：设备支持 + 设置里的开关开着 */
  private matOn(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>('hdsOn');
    if (v === false) {
      return false;
    }
    return this.hdsOn();
  }

  private hdsOn(): boolean {
    try {
      return hdsMaterial.getSystemMaterialTypes().indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
    } catch (e) {
      console.warn('DSH_HDS list probe failed: ' + (e as Error).message);
      return false;
    }
  }

  build() {
    HdsNavDestination() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // 头部（工作区/搜索/统计）改成浮层，见 headerBlock()

        if (this.loading) {
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              LoadingProgress().width(20).height(20).color(Tokens.accent)
              Text(this.loadSlow ? '还没连上电脑' : '读取会话…')
                .fontSize(12.5)
                .fontColor(Tokens.dim2)
            }
            .justifyContent(FlexAlign.Center)
            if (this.loadSlow) {
              Text('点这里重试')
                .fontSize(13)
                .fontColor(Tokens.accent)
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .borderRadius(Tokens.rPill)
                .backgroundColor(Tokens.surface2)
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                .onClick(() => {
                  Haptics.tap();
                  this.loading = true;
                  this.loadSlow = false;
                  void this.load();
                })
            }
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: this.searching ? 92 : 150 })
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
          Refresh({ refreshing: $$this.refreshing, builder: this.refreshArea() }) {
          List({ space: 8, scroller: this.scroller }) {
            ListItem() {
              Row().width('100%').height(85)
            }
            ForEach(this.models(), (m: RowModel, idx: number) => {
              if (m.kind === 'head') {
                ListItem() {
                  Row() {
                    Text(m.label)
                      .fontSize(11.5)
                      .fontColor(Tokens.dim2)
                      .letterSpacing(1.2)
                    Blank()
                    // 日期分组可折叠：两笔的箭头，展开朝下，收起转成朝右
                    if (m.label !== '置顶') {
                      Path()
                        .commands('M0 0 L5 5 L10 0')
                        .stroke(Tokens.dim2)
                        .strokeWidth(1.6)
                        .strokeLineCap(LineCapStyle.Round)
                        .fill(Color.Transparent)
                        .width(11)
                        .height(6)
                        .rotate({ angle: this.isFolded(m.label) ? -90 : 0 })
                        .animation({ duration: 180, curve: Curve.EaseInOut })
                    }
                  }
                  .width('100%')
                  .padding({ left: 6, right: 6, top: 10, bottom: 2 })
                  .onClick(() => {
                    if (m.label !== '置顶') this.toggleFold(m.label);
                  })
                }
              } else {
                ListItem() {
                  SessionTile({
                    row: m.row,
                    preview: this.previewOf(m.row.id),
                    count: this.countOf(m.row.id),
                    archivedView: this.archivedView,
                    onTap: () => {
                      Haptics.tap();
                      const p: ChatParam = { id: m.row.id, title: m.row.title };
                      this.stack.pushPathByName('chat', p);
                    },
                    onRename: () => {
                      this.openRename(m.row);
                    },
                    onPin: () => {
                      this.doPin(m.row);
                    },
                    onArchive: () => {
                      if (this.archivedView) {
                        this.doUnarchive(m.row);
                      } else {
                        this.doArchive(m.row);
                      }
                    },
                    onCopyId: () => {
                      this.copyId(m.row);
                    },
                    onFork: () => {
                      this.doFork(m.row);
                    }
                  })
                  .bindContextMenu(this.rowMenu(m.row), ResponseType.LongPress)
                }
                // 只有会话卡片能左右滑，分组标题根本不挂这个手势
                .swipeAction({ end: this.swipeActions(m.row), edgeEffect: SwipeEdgeEffect.Spring })
              }            }, (m: RowModel) => m.key)
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
          .onStateChange((st: RefreshStatus) => {
            this.pullState = st;
          })
          .onRefreshing(() => {
            this.refreshing = true;
            this.load().finally(() => {
              this.refreshing = false;
              // 收尾可能是 Done 而不是 Inactive，不归位的话指示器条件会一直成立
              this.pullState = RefreshStatus.Inactive;
            });
          })
        }
      }
      .width('100%')
      .height('100%')

      // 顶部渐隐：HDS 标题栏的滚动遮罩已关掉（enableScrollEffect=false），
      // 这里只留一层从页面底色到透明的渐变，让上滑内容在状态栏附近淡出，
      // 避免卡片文字和时钟/电量叠在一起；不是遮罩板，没有任何硬边界。
      Row()
        .width('100%')
        .height(96)
        .linearGradient({
          angle: 180,
          colors: [[this.themeBg, 0.0], [this.themeBg, 0.55], ['#00' + this.themeBg.slice(1), 1.0]]
        })
        .position({ x: 0, y: 0 })
        .hitTestBehavior(HitTestMode.None)
        .visibility(this.refreshing ? Visibility.Hidden : Visibility.Visible)

      // 右下角悬浮新建：白色半透明 + 背后模糊，做出沉浸光感的玻璃钮
      Column() {
        Stack() {
          // 顶部一层极淡的高光，模拟光从上来
          Row()
            .width('100%')
            .height('100%')
            .borderRadius(29)
            .linearGradient({
              angle: 160,
              colors: [[Tokens.isDark ? '#33FFFFFF' : '#B3FFFFFF', 0.0], ['#00FFFFFF', 0.62]],
            })
            .hitTestBehavior(HitTestMode.None)
          Text(this.creating ? '…' : '＋')
            .fontSize(30)
            .fontColor(Tokens.isDark ? '#F2FFFFFF' : Tokens.fg)
            .textAlign(TextAlign.Center)
            .width(58)
            .height(58)
        }
        .width(58)
        .height(58)
        .borderRadius(29)
        .backgroundColor(Tokens.isDark ? '#3DFFFFFF' : '#8CFFFFFF')
        .backdropBlur(Tokens.isDark ? 20 : 26)
        .border({ width: 1, color: Tokens.isDark ? '#40FFFFFF' : '#D9FFFFFF' })
        .shadow({ radius: 20, color: Tokens.isDark ? '#40000000' : '#33000000', offsetY: 8 })
        .margin({ right: 22, bottom: 132 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .bindSheet($$this.wsPickOn, this.wsPickBody(), {
          height: '42%',
          dragBar: true,
          showClose: false,
          backgroundColor: Tokens.sheetWarm,
          blurStyle: BlurStyle.COMPONENT_THICK,
          maskColor: '#33000000'
        })
        .onClick(() => {
          Haptics.tap();
          this.wsPickOn = true;
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

      if (this.wsNewOn) {
        this.wsNewSheet()
      }
    }
    .width('100%')
    .height('100%')
    // 从聊天页退回来时列表并不会重建，标题/运行状态得自己对齐一次
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number) => {
      if (isVisible && ratio > 0.5 && !this.loading) {
        this.load();
      }
    })
    }
    .hideTitleBar(false)
    .titleBar(this.listTitle())
    .hideBackButton(true)
    .bindToScrollable([this.scroller])
    .backgroundColor(this.themeBg)
  }
}
