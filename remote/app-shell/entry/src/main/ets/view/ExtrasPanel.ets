import { common } from '@kit.AbilityKit';
import { Api, FsEntry, HostPluginGroup, HostPluginRow, HostTaskRow, TeamMemberRow, TeamTaskRow } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { Saver } from '../common/Saver';

/**
 * 聊天页右上角的三块「电脑侧」信息：插件、自动化任务、工作区文件。
 * 全部走同一个面板壳，靠 mode 切换内容；数据都来自电脑端插件的新路由。
 */
@Component
export struct ExtrasPanel {
  /** plugins | schedules | team | files */
  @Prop @Watch('onMode') mode: string = 'plugins';
  @Prop sessionId: string = '';
  api: Api = new Api('', '');
  onExit: () => void = () => {};

  @State private busy: boolean = false;
  @State private err: string = '';
  @State private groups: HostPluginGroup[] = [];
  @State private tasks: HostTaskRow[] = [];
  @State private members: TeamMemberRow[] = [];
  @State private teamTasks: TeamTaskRow[] = [];
  @State private teamOn: boolean = false;
  @State private sawMode: boolean = false;
  @State private root: string = '';
  /** 会话没有工作目录时，显示的是宿主自己的目录 */
  @State private rootFallback: boolean = false;
  @State private path: string = '';
  @State private entries: FsEntry[] = [];
  @State private more: boolean = false;
  @State private viewerOn: boolean = false;
  @State private viewerName: string = '';
  /** 正在看的文本文件在工作区里的相对路径：保存时要拿它拼下载直链 */
  @State private viewerPath: string = '';
  @State private viewerText: string = '';
  @State private imageOn: boolean = false;
  @State private imagePath: string = '';
  /** 正在保存到手机：发一次请求就锁住按钮，避免连点堆出多个下载任务 */
  @State private saving: boolean = false;
  /** 跟设置二级页同一套：顶部渐变用当前页面底色，深浅色切换时跟着变 */
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  /** 正在请求的任务 id：同一时刻只让一条任务显示「处理中」 */
  @State private acting: string = '';
  /** 正在写清单的插件（profile '/' 名字）：写的时候把开关停住，避免连点写两次 */
  @State private pluginBusy: string = '';
  /** 插件开关的提示条：改完要重启宿主才生效 */
  @State private notice: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onMode(): void {
    this.viewerOn = false;
    this.imageOn = false;
    this.saving = false;
    this.err = '';
    this.load();
  }

  private title(): string {
    if (this.mode === 'schedules') return '自动化任务';
    if (this.mode === 'team') return '智能体团队';
    if (this.mode === 'files') return '工作区文件';
    return '插件';
  }

  private load(): void {
    if (this.mode === 'schedules') {
      this.loadSchedules();
    } else if (this.mode === 'team') {
      this.loadTeam();
    } else if (this.mode === 'files') {
      this.loadFiles(this.path);
    } else {
      this.loadPlugins();
    }
  }

  private async loadPlugins(): Promise<void> {
    this.busy = true;
    try {
      this.groups = await this.api.hostPlugins();
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.busy = false;
    }
  }

  private async loadSchedules(): Promise<void> {
    this.busy = true;
    try {
      this.tasks = await this.api.hostSchedules();
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.busy = false;
    }
  }

  private async loadTeam(): Promise<void> {
    this.busy = true;
    try {
      const r = await this.api.team(this.sessionId);
      this.members = r.members ?? [];
      this.teamTasks = r.tasks ?? [];
      this.teamOn = r.enabled === true;
      this.sawMode = r.sawMode === true;
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.busy = false;
    }
  }

  private phaseText(phase: string): string {
    if (phase === 'active') return '在跑';
    if (phase === 'provisioning') return '准备中';
    if (phase === 'failed') return '失败';
    return phase;
  }

  private phaseColor(phase: string): string {
    if (phase === 'active') return Tokens.accent;
    if (phase === 'failed') return Tokens.err;
    return Tokens.dim2;
  }

  private taskText(status: string): string {
    if (status === 'in_progress') return '进行中';
    if (status === 'completed') return '已完成';
    if (status === 'pending') return '待开始';
    return status;
  }

  private taskColor(status: string): string {
    if (status === 'in_progress') return Tokens.accent;
    if (status === 'completed') return Tokens.ok;
    return Tokens.dim2;
  }

  private async loadFiles(target: string): Promise<void> {
    this.busy = true;
    try {
      const r = await this.api.fsList(this.sessionId, target);
      this.root = r.root;
      this.rootFallback = r.fallback === true;
      this.path = r.path;
      this.entries = r.entries;
      this.more = r.more;
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.busy = false;
    }
  }

  private up(): void {
    const p: string = this.path;
    if (p === '') return;
    const cut: number = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
    this.loadFiles(cut <= 0 ? '' : p.substring(0, cut));
  }

  private join(dir: string): string {
    if (this.path === '') return dir;
    const tail: string = this.path.endsWith('\\') || this.path.endsWith('/') ? '' : '\\';
    return this.path + tail + dir;
  }

  private shortName(name: string): string {
    const at: number = name.lastIndexOf('/');
    return at >= 0 ? name.substring(at + 1) : name;
  }

  private isImage(name: string): boolean {
    const n: string = name.toLowerCase();
    return n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.webp') ||
      n.endsWith('.gif') || n.endsWith('.bmp') || n.endsWith('.svg');
  }

  private sizeText(b: number): string {
    if (b >= 1024 * 1024) return (b / (1024 * 1024)).toFixed(1) + ' MB';
    if (b >= 1024) return (b / 1024).toFixed(1) + ' KB';
    return String(b) + ' B';
  }

  private whenText(iso: string): string {
    if (iso === '') return '';
    const d = new Date(iso);
    const t: number = d.getTime();
    if (isNaN(t)) return iso;
    const pad = (n: number): string => n < 10 ? '0' + String(n) : String(n);
    return String(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  /** 把宿主那边的 kind 翻成中文，省得界面上出现 at / after 这种原始值。 */
  private kindText(kind: string): string {
    if (kind === 'at') return '定时';
    if (kind === 'after') return '延时';
    if (kind === 'every') return '周期';
    if (kind === 'daily') return '每天';
    if (kind === 'weekly') return '每周';
    if (kind === 'cron') return '计划';
    if (kind === 'rrule') return '规则';
    return kind === '' ? '定时' : kind;
  }

  private async openEntry(e: FsEntry): Promise<void> {
    if (e.dir) {
      this.loadFiles(this.join(e.name));
      return;
    }
    const full: string = this.join(e.name);
    if (this.isImage(e.name)) {
      this.imagePath = full;
      this.imageOn = true;
      this.saving = false;
      return;
    }
    this.busy = true;
    try {
      const f = await this.api.fsFile(this.sessionId, full);
      this.viewerName = f.name;
      this.viewerPath = full;
      this.viewerText = f.text;
      this.viewerOn = true;
      this.saving = false;
      this.err = '';
    } catch (err) {
      this.err = (err as Error).message;
    } finally {
      this.busy = false;
    }
  }

  /** 取路径里的文件名，两种分隔符都认：电脑那边给的是反斜杠。 */
  private fileName(p: string): string {
    const cut: number = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
    return cut >= 0 ? p.substring(cut + 1) : p;
  }

  /** 把正在看的文件存到手机：先下到沙箱缓存，再交给系统选择器挑保存位置。 */
  private async saveFile(targetPath: string, targetName: string): Promise<void> {
    if (this.saving || targetPath === '') {
      return;
    }
    Haptics.tap();
    this.saving = true;
    this.err = '';
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const url: string = this.api.fsDownloadUrl(this.sessionId, targetPath);
      const saved: boolean = await Saver.save(ctx, url, targetName);
      if (saved) {
        this.getUIContext().getPromptAction().showToast({ message: '已保存到手机', duration: 1600 });
      }
    } catch (e) {
      // 查看器盖在面板上面，光写 this.err 用户看不见，同时弹一条提示
      const reason: string = (e as Error).message;
      this.err = reason;
      this.getUIContext().getPromptAction().showToast({ message: reason, duration: 2600 });
    } finally {
      this.saving = false;
    }
  }

  /** 任务动作点完之后的一句话提示。 */
  private actText(action: string): string {
    if (action === 'pause') return '已暂停';
    if (action === 'resume') return '已恢复';
    if (action === 'run') return '已经让电脑立刻跑这一次';
    if (action === 'delete') return '已删除';
    return '已处理';
  }

  /** 对一条自动化任务发动作；成功后重读列表，失败就把电脑端的说法显示出来。 */
  private async act(id: string, action: string): Promise<void> {
    if (this.acting !== '') {
      return;
    }
    Haptics.tap();
    this.acting = id;
    try {
      await this.api.scheduleAction(id, action);
      await this.loadSchedules();
      this.getUIContext().getPromptAction().showToast({ message: this.actText(action), duration: 1600 });
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.acting = '';
    }
  }

  /** 删除要先确认：任务删掉就再也不触发了。 */
  private confirmDelete(t: HostTaskRow): void {
    Haptics.tap();
    AlertDialog.show({
      title: '删除这条任务',
      message: '删掉之后它不会再触发，已经产生的记录不受影响。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Tokens.err,
        action: () => {
          this.act(t.id, 'delete');
        }
      }
    });
  }

  /** 只改本地列表里某个插件的 enabled，其它字段原样保留（整组换新数组才会重绘）。 */
  private setPluginEnabled(profile: string, name: string, enabled: boolean): void {
    const next: HostPluginGroup[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      const g: HostPluginGroup = this.groups[i];
      if (g.profile !== profile) {
        next.push(g);
        continue;
      }
      const items: HostPluginRow[] = [];
      for (let j = 0; j < g.items.length; j++) {
        const it: HostPluginRow = g.items[j];
        if (it.name === name) {
          const row: HostPluginRow = {
            name: it.name,
            version: it.version,
            enabled: enabled,
            local: it.local
          };
          items.push(row);
        } else {
          items.push(it);
        }
      }
      const group: HostPluginGroup = { profile: g.profile, items: items };
      next.push(group);
    }
    this.groups = next;
  }

  /** 插件开关：写 profile 清单，写完必须重启宿主才生效。 */
  private async togglePlugin(profile: string, row: HostPluginRow, enabled: boolean): Promise<void> {
    // 状态回写时 Toggle 可能再报一次 onChange，值和当前一致就忽略
    if (row.enabled === enabled) {
      return;
    }
    if (this.pluginBusy !== '') {
      return;
    }
    Haptics.tap();
    this.pluginBusy = profile + '/' + row.name;
    try {
      const changed: boolean = await this.api.pluginToggle(profile, row.name, enabled);
      this.setPluginEnabled(profile, row.name, enabled);
      this.err = '';
      const label: string = this.shortName(row.name);
      if (changed) {
        this.notice = '已' + (enabled ? '启用' : '停用') + '「' + label + '」，重启电脑端宿主后生效';
      } else {
        this.notice = '「' + label + '」本来就是' + (enabled ? '启用' : '停用') + '状态';
      }
    } catch (e) {
      this.err = (e as Error).message;
      // 写失败就把开关拨回点之前的位置
      this.setPluginEnabled(profile, row.name, !enabled);
    } finally {
      this.pluginBusy = '';
    }
  }

  /** 这个 profile 里已启用的插件数，显示在分组标题右边。 */
  private enabledCount(g: HostPluginGroup): number {
    let n: number = 0;
    for (let i = 0; i < g.items.length; i++) {
      if (g.items[i].enabled) {
        n = n + 1;
      }
    }
    return n;
  }

  /** 悬浮返回钮：面板打开时聊天页标题栏被藏掉，返回由它负责。 */
  @Builder
  private backButton() {
    Stack() {
      Image($r('app.media.ic_back'))
        .width(20)
        .height(20)
        .fillColor(Tokens.fg)
        .objectFit(ImageFit.Contain)
    }
    .width(38)
    .height(38)
    .borderRadius(999)
    .backgroundColor(Tokens.isDark ? '#3DFFFFFF' : '#8CFFFFFF')
    .backdropBlur(22)
    .border({ width: 1, color: Tokens.isDark ? '#40FFFFFF' : '#D9FFFFFF' })
    .shadow({ radius: 14, color: Tokens.isDark ? '#40000000' : '#26000000', offsetY: 4 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .onClick(() => {
      Haptics.tap();
      this.onExit();
    })
  }

  /** 右侧同一颗玻璃钮：刷新当前面板的数据。 */
  @Builder
  private refreshButton() {
    Stack() {
      Text('↻')
        .fontSize(18)
        .fontColor(Tokens.fg)
    }
    .width(38)
    .height(38)
    .borderRadius(999)
    .backgroundColor(Tokens.isDark ? '#3DFFFFFF' : '#8CFFFFFF')
    .backdropBlur(22)
    .border({ width: 1, color: Tokens.isDark ? '#40FFFFFF' : '#D9FFFFFF' })
    .shadow({ radius: 14, color: Tokens.isDark ? '#40000000' : '#26000000', offsetY: 4 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .onClick(() => {
      Haptics.tap();
      this.load();
    })
  }

  /** 悬浮标题行：父级已经留好状态栏高度，这里不再加外边距。 */
  @Builder
  private floatingHeader() {
    Row() {
      this.backButton()
      Text(this.title())
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ left: 12 })
      Blank()
      this.refreshButton()
    }
    .width('100%')
    .height(56)
    .alignItems(VerticalAlign.Center)
  }

  /** 顶部同色渐变：滚上来的内容在浮动标题下面淡出，不留硬边。 */
  @Builder
  private topFade() {
    Row()
      .width('100%')
      .height(76)
      .linearGradient({
        angle: 180,
        colors: [[this.themeBg, 0.0], [this.themeBg, 0.58], ['#00' + this.themeBg.slice(1), 1.0]]
      })
      .hitTestBehavior(HitTestMode.None)
  }

  /** 插件开关之后贴在最上面的提示：清单已经写了，但宿主没重启不会生效。 */
  @Builder
  private noticeBar() {
    if (this.notice !== '') {
      Row() {
        Text(this.notice)
          .fontSize(11.5)
          .fontColor(Tokens.accent)
          .layoutWeight(1)
        Text('知道了')
          .fontSize(11.5)
          .fontColor(Tokens.dim2)
          .padding({ left: 12, top: 2, bottom: 2 })
          .onClick(() => {
            this.notice = '';
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(Tokens.accentGlass)
      .borderRadius(12)
      .margin({ bottom: 10 })
    }
  }

  @Builder
  private emptyBox(text: string) {
    Column() {
      Text(text)
        .fontSize(13)
        .fontColor(Tokens.dim2)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 40, bottom: 40 })
  }

  @Builder
  private pluginRows(g: HostPluginGroup) {
    Row() {
      Text(g.profile)
        .fontSize(11.5)
        .fontColor(Tokens.dim2)
        .layoutWeight(1)
      Text(String(this.enabledCount(g)) + ' / ' + String(g.items.length) + ' 已启用')
        .fontSize(10.5)
        .fontColor(Tokens.dim2)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 14, bottom: 8 })

    ForEach(g.items, (it: HostPluginRow) => {
      Row() {
        Column() {
          Text(this.shortName(it.name))
            .fontSize(14)
            .fontColor(Tokens.fg)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.pluginSub(it))
            .fontSize(11)
            .fontColor(Tokens.dim2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ right: 12 })

        Toggle({ type: ToggleType.Switch, isOn: it.enabled })
          .selectedColor(this.pluginBusy === g.profile + '/' + it.name ? Tokens.dim2 : Tokens.accent)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onChange((v: boolean) => {
            this.togglePlugin(g.profile, it, v);
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 11, bottom: 11 })
      .margin({ bottom: 6 })
      .backgroundColor(Tokens.surface)
      .borderRadius(12)
    }, (it: HostPluginRow) => g.profile + '/' + it.name + '/' + String(it.enabled))
  }

  /** 插件行的副标题：本地包只露出目录名，别让长 link 路径把右边的开关挤歪。 */
  private pluginSub(it: HostPluginRow): string {
    if (!it.local) return it.version;
    const raw: string = it.version.indexOf('link:') === 0 ? it.version.substring(5) : it.version;
    const cut: number = Math.max(raw.lastIndexOf('/'), raw.lastIndexOf('\\'));
    const tail: string = cut >= 0 ? raw.substring(cut + 1) : raw;
    return '本地链接 · ' + (tail === '' ? '工作区' : tail);
  }

  /** 一条自动化任务：上行标题 + 状态，下行类型 / 时间，右下是三个动作。 */
  @Builder
  private taskRow(it: HostTaskRow) {
    Column() {
      Row() {
        Text(it.title)
          .fontSize(14)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(it.active ? '启用' : '暂停')
          .fontSize(10.5)
          .fontColor(it.active ? Tokens.accent : Tokens.dim2)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(it.active ? Tokens.accentGlass : Tokens.chip)
          .borderRadius(999)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row() {
        Text(this.kindText(it.kind))
          .fontSize(11)
          .fontColor(Tokens.dim2)
        Text(this.whenText(it.when))
          .fontSize(11)
          .fontColor(Tokens.dim2)
          .margin({ left: 8 })
        Blank()
        if (this.acting === it.id) {
          Text('处理中')
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
        } else {
          Row() {
            Text(it.active ? '暂停' : '恢复')
              .fontSize(11.5)
              .fontColor(Tokens.accent)
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Tokens.accentGlass)
          .borderRadius(999)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            this.act(it.id, it.active ? 'pause' : 'resume');
          })

          Row() {
            Text('立即')
              .fontSize(11.5)
              .fontColor(Tokens.fg)
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Tokens.chip)
          .borderRadius(999)
          .margin({ left: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            this.act(it.id, 'run');
          })

          Row() {
            Image($r('app.media.ic_trash'))
              .width(15)
              .height(15)
              .fillColor(Tokens.dim)
          }
          .width(30)
          .height(26)
          .justifyContent(FlexAlign.Center)
          .margin({ left: 4 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            this.confirmDelete(it);
          })
        }
      }
      .width('100%')
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .margin({ bottom: 6 })
    .backgroundColor(Tokens.surface)
    .borderRadius(12)
  }

  @Builder
  private taskRows() {
    ForEach(this.tasks, (it: HostTaskRow) => {
      this.taskRow(it);
    }, (it: HostTaskRow) => it.id + '/' + String(it.active) + '/' + it.when)
  }

  @Builder
  private teamRows() {
    Row() {
      Text(this.sawMode ? (this.teamOn ? '团队协作已开' : '团队协作没开') : '这个会话没有团队记录')
        .fontSize(12)
        .fontColor(this.teamOn ? Tokens.accent : Tokens.dim2)
      Blank()
      Text(this.members.length > 0 ? this.members.length + ' 名成员' : '')
        .fontSize(11)
        .fontColor(Tokens.dim2)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 2, bottom: 10 })

    if (this.members.length > 0) {
      Text('成员')
        .fontSize(11.5)
        .fontColor(Tokens.dim2)
        .width('100%')
        .padding({ left: 4, bottom: 8 })
      ForEach(this.members, (m: TeamMemberRow) => {
        Column() {
          Row() {
            Text(m.name === '' ? m.id : m.name)
              .fontSize(14)
              .fontColor(Tokens.fg)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.phaseText(m.phase))
              .fontSize(11)
              .fontColor(this.phaseColor(m.phase))
          }
          .width('100%')

          if (m.description !== '') {
            Text(m.description)
              .fontSize(11.5)
              .fontColor(Tokens.dim2)
              .width('100%')
              .margin({ top: 4 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (m.error !== '') {
            Text(m.error)
              .fontSize(11)
              .fontColor(Tokens.err)
              .width('100%')
              .margin({ top: 4 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .margin({ bottom: 6 })
        .backgroundColor(Tokens.surface)
        .borderRadius(12)
      }, (m: TeamMemberRow) => m.id + m.phase)
    }

    if (this.teamTasks.length > 0) {
      Text('任务板')
        .fontSize(11.5)
        .fontColor(Tokens.dim2)
        .width('100%')
        .padding({ left: 4, top: 10, bottom: 8 })
      ForEach(this.teamTasks, (t: TeamTaskRow) => {
        Column() {
          Text(t.subject === '' ? t.id : t.subject)
            .fontSize(14)
            .fontColor(Tokens.fg)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            Text(this.taskText(t.status))
              .fontSize(11)
              .fontColor(this.taskColor(t.status))
            if (t.ownerName !== '') {
              Text(t.ownerName)
                .fontSize(11)
                .fontColor(Tokens.dim2)
                .margin({ left: 10 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            Blank()
            Text('#' + String(t.revision))
              .fontSize(10.5)
              .fontColor(Tokens.dim2)
          }
          .width('100%')
          .margin({ top: 6 })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .margin({ bottom: 6 })
        .backgroundColor(Tokens.surface)
        .borderRadius(12)
      }, (t: TeamTaskRow) => t.id + String(t.revision) + t.status)
    }
  }

  @Builder
  private fileRows() {
    if (this.root !== '') {
      Text(this.root)
        .fontSize(11)
        .fontColor(Tokens.dim2)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 4, bottom: 6 })
    }
    Text(this.path === '' ? (this.rootFallback ? '（这个会话没有工作目录，显示电脑当前目录）' : '（工作区根目录）') : this.path)
      .fontSize(12)
      .fontColor(Tokens.fg)
      .width('100%')
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 4, bottom: 8 })

    if (this.path !== '') {
      Row() {
        Text('↑')
          .fontSize(15)
          .fontColor(Tokens.dim)
          .width(26)
          .textAlign(TextAlign.Center)
        Text('上一级')
          .fontSize(14)
          .fontColor(Tokens.dim)
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 10, bottom: 10 })
      .margin({ bottom: 6 })
      .backgroundColor(Tokens.surface)
      .borderRadius(12)
      .onClick(() => {
        this.up();
      })
    }

    ForEach(this.entries, (e: FsEntry) => {
      Row() {
        Text(e.dir ? '▸' : (this.isImage(e.name) ? '◫' : '·'))
          .fontSize(14)
          .fontColor(e.dir ? Tokens.accent : Tokens.dim2)
          .width(26)
          .textAlign(TextAlign.Center)
        Column() {
          Text(e.name)
            .fontSize(14)
            .fontColor(Tokens.fg)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (!e.dir) {
            Text(this.sizeText(e.size))
              .fontSize(11)
              .fontColor(Tokens.dim2)
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(e.dir ? '›' : '')
          .fontSize(16)
          .fontColor(Tokens.dim2)
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 10, bottom: 10 })
      .margin({ bottom: 6 })
      .backgroundColor(Tokens.surface)
      .borderRadius(12)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        this.openEntry(e);
      })
    }, (e: FsEntry) => e.name + (e.dir ? '/d' : '/f'))

    if (this.more) {
      Text('这个目录内容较多，只显示前 400 项')
        .fontSize(11)
        .fontColor(Tokens.dim2)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 6 })
    }
  }

  build() {
    Stack() {
      // 顶部一套跟设置二级页完全一致：内容滚到标题下面淡出，标题 + 玻璃返回钮固定不动。
      Stack({ alignContent: Alignment.Top }) {
        List() {
          ListItem() {
            Column() {
              this.noticeBar()

              if (this.busy) {
                Row() {
                  LoadingProgress()
                    .width(18)
                    .height(18)
                    .color(Tokens.dim)
                  Text('读取中')
                    .fontSize(12)
                    .fontColor(Tokens.dim2)
                    .margin({ left: 8 })
                }
                .width('100%')
                .padding({ top: 4, bottom: 12 })
              }

              if (this.err !== '') {
                Row() {
                  Text(this.err)
                    .fontSize(12)
                    .fontColor(Tokens.err)
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .backgroundColor(Tokens.surface)
                .borderRadius(12)
                .margin({ bottom: 10 })
              }

              if (this.mode === 'plugins' && this.groups.length === 0 && !this.busy && this.err === '') {
                this.emptyBox('没有读到已安装的插件')
              }
              if (this.mode === 'schedules' && this.tasks.length === 0 && !this.busy && this.err === '') {
                this.emptyBox('这台电脑上还没有自动化任务')
              }
              if (this.mode === 'team' && this.members.length === 0 && this.teamTasks.length === 0 &&
                !this.busy && this.err === '') {
                this.emptyBox('这个会话还没开团队协作。\n在电脑端打开会话菜单里的「智能体团队」并开启，成员和任务才会出现。')
              }

              if (this.mode === 'plugins') {
                ForEach(this.groups, (g: HostPluginGroup) => {
                  this.pluginRows(g);
                }, (g: HostPluginGroup) => g.profile)
              } else if (this.mode === 'schedules') {
                this.taskRows();
              } else if (this.mode === 'team') {
                this.teamRows();
              } else {
                this.fileRows();
              }
            }
            .width('100%')
            .padding({ bottom: 110 })
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .padding({ top: 68 })

        this.topFade()
        this.floatingHeader()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 36 })

      if (this.viewerOn) {
        this.viewerOverlay()
      }
      if (this.imageOn) {
        this.imageOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
  }

  /** 查看器右上角的「保存」胶囊；保存中换成转圈并自己把点击锁住。 */
  @Builder
  private saveButton(label: string, targetPath: string, targetName: string) {
    Row() {
      if (this.saving) {
        LoadingProgress()
          .width(13)
          .height(13)
          .color(Tokens.dim2)
        Text('保存中')
          .fontSize(12.5)
          .fontColor(Tokens.dim2)
          .margin({ left: 4 })
      } else {
        Text(label)
          .fontSize(12.5)
          .fontColor(Tokens.fg)
      }
    }
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .backgroundColor(this.saving ? Tokens.surface2 : Tokens.chip)
    .borderRadius(Tokens.rPill)
    .margin({ right: 8 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .onClick(() => {
      this.saveFile(targetPath, targetName);
    })
  }

  @Builder
  private viewerOverlay() {
    Column() {
      Row() {
        Text(this.viewerName)
          .fontSize(14)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.saveButton('保存', this.viewerPath, this.viewerName)
        Text('关闭')
          .fontSize(13)
          .fontColor(Tokens.accent)
          .padding({ left: 12, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.viewerOn = false;
          })
      }
      .width('100%')
      .padding({ top: 88, left: 18, right: 12, bottom: 8 })

      Scroll() {
        Text(this.viewerText)
          .fontSize(12)
          .fontColor(Tokens.fg)
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 20 })
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    // 打开面板时聊天页标题栏被藏掉，这里自己躲开状态栏
    .padding({ top: 40 })
    .backgroundColor(Tokens.bg)
  }

  @Builder
  private imageOverlay() {
    Column() {
      Row() {
        Text(this.fileName(this.imagePath))
          .fontSize(13)
          .fontColor(Tokens.dim2)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.saveButton('保存到手机', this.imagePath, this.fileName(this.imagePath))
        Text('关闭')
          .fontSize(13)
          .fontColor(Tokens.dim2)
          .padding({ left: 10, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.imageOn = false;
          })
      }
      .width('100%')
      .padding({ top: 48, left: 18, right: 12, bottom: 6 })

      // 点图片关闭：整块都挂点击会连保存一起关掉，所以只挂在图片上
      Image(this.api.fsRawUrl(this.sessionId, this.imagePath))
        .width('100%')
        .layoutWeight(1)
        .objectFit(ImageFit.Contain)
        .onClick(() => {
          this.imageOn = false;
        })

      Text('点图片关闭')
        .fontSize(12)
        .fontColor(Tokens.dim2)
        .padding({ top: 10, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
