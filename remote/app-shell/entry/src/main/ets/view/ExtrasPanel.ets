import { Api, FsEntry, HostPluginGroup, HostPluginRow, HostTaskRow, TeamMemberRow, TeamTaskRow } from '../common/Api';
import { Tokens } from '../common/Tokens';

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
  @State private viewerText: string = '';
  @State private imageOn: boolean = false;
  @State private imagePath: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onMode(): void {
    this.viewerOn = false;
    this.imageOn = false;
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

  private async openEntry(e: FsEntry): Promise<void> {
    if (e.dir) {
      this.loadFiles(this.join(e.name));
      return;
    }
    const full: string = this.join(e.name);
    if (this.isImage(e.name)) {
      this.imagePath = full;
      this.imageOn = true;
      return;
    }
    this.busy = true;
    try {
      const f = await this.api.fsFile(this.sessionId, full);
      this.viewerName = f.name;
      this.viewerText = f.text;
      this.viewerOn = true;
      this.err = '';
    } catch (err) {
      this.err = (err as Error).message;
    } finally {
      this.busy = false;
    }
  }

  @Builder
  private head() {
    Row() {
      Stack() {
        Text('‹')
          .fontSize(26)
          .fontColor(Tokens.fg)
      }
      .width(40)
      .height(40)
      .borderRadius(999)
      .backgroundColor(Tokens.glassFaint)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .onClick(() => {
        this.onExit();
      })

      Text(this.title())
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ left: 12 })
        .layoutWeight(1)

      Text('↻')
        .fontSize(18)
        .fontColor(Tokens.dim)
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .borderRadius(999)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => {
          this.load();
        })
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4, bottom: 10 })
    .alignItems(VerticalAlign.Center)
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
    Text(g.profile)
      .fontSize(11.5)
      .fontColor(Tokens.dim2)
      .width('100%')
      .padding({ left: 4, top: 14, bottom: 8 })

    ForEach(g.items, (it: HostPluginRow) => {
      Row() {
        Column() {
          Text(this.shortName(it.name))
            .fontSize(14)
            .fontColor(Tokens.fg)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(it.version)
            .fontSize(11)
            .fontColor(Tokens.dim2)
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(it.enabled ? '已启用' : '未启用')
          .fontSize(11)
          .fontColor(it.enabled ? Tokens.ok : Tokens.dim2)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(it.enabled ? '#1F3DDC97' : Tokens.chip)
          .borderRadius(999)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .margin({ bottom: 6 })
      .backgroundColor(Tokens.surface)
      .borderRadius(12)
    }, (it: HostPluginRow) => g.profile + '/' + it.name)
  }

  @Builder
  private taskRows() {
    ForEach(this.tasks, (it: HostTaskRow) => {
      Column() {
        Text(it.title)
          .fontSize(14)
          .fontColor(Tokens.fg)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Text(it.kind === '' ? '定时' : it.kind)
            .fontSize(11)
            .fontColor(Tokens.dim2)
          Text(this.whenText(it.when))
            .fontSize(11)
            .fontColor(Tokens.dim2)
            .margin({ left: 10 })
          Blank()
          Text(it.active ? '启用' : '暂停')
            .fontSize(11)
            .fontColor(it.active ? Tokens.accent : Tokens.dim2)
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .margin({ bottom: 6 })
      .backgroundColor(Tokens.surface)
      .borderRadius(12)
    }, (it: HostTaskRow) => it.id + it.when)
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
      Column() {
        this.head()

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
          .padding({ top: 20 })
        }

        if (this.err !== '') {
          Column() {
            Text(this.err)
              .fontSize(12)
              .fontColor(Tokens.err)
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding({ top: 24, left: 12, right: 12 })
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

        Scroll() {
          Column() {
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
            Blank().height(80)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 96, bottom: 8 })
      .backgroundColor(Tokens.bg)
      .alignItems(HorizontalAlign.Start)

      if (this.viewerOn) {
        this.viewerOverlay()
      }
      if (this.imageOn) {
        this.imageOverlay()
      }
    }
    .width('100%')
    .height('100%')
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
      Image(this.api.fsRawUrl(this.sessionId, this.imagePath))
        .width('100%')
        .layoutWeight(1)
        .objectFit(ImageFit.Contain)
      Text('点任意处关闭')
        .fontSize(12)
        .fontColor(Tokens.dim2)
        .padding({ top: 10, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .onClick(() => {
      this.imageOn = false;
    })
  }
}
