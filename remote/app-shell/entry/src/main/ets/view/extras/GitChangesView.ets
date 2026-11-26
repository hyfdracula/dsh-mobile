import { Api, GitDiffResp, GitFileRow, GitStatusResp } from '../../common/Api';
import { Tokens } from '../../common/Tokens';
import { EmptyState } from '../../common/Widgets';
import { copyText } from '../../common/Clipboard';
import { Haptics } from '../../common/Haptics';
import { Toast } from '../../common/Toast';
import { GATEWAY_404_HINT, GATEWAY_404_TITLE, isGateway404 } from './ExtrasCommon';

interface DiffLineVm {
  idx: number;
  kind: string;
  text: string;
}

const MAX_RENDER_DIFF_LINES: number = 600;

/**
 * 工作区 Git 分支状态与红绿 Unified Diff 审阅面板（G5）：
 * - 调用 api.gitStatus(sessionId) 展示分支、ahead/behind、已暂存/未暂存变更文件及 M/A/D/?? 色标
 * - 点击任一文件调用 api.gitDiff(sessionId, path, staged) 展开 Unified Diff 查看器
 * - + 新增行淡绿底、- 删除行淡红底、@@ 块头淡蓝底，支持等宽横向滚动与一键复制 Diff
 */
@Component
export struct GitChangesView {
  api: Api = new Api('', '');
  @Prop sessionId: string = '';
  @Prop @Watch('onReload') reloadTick: number = 0;
  @Prop topPad: number = 140;

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private busy: boolean = false;
  @State private missing404: boolean = false;
  @State private err: string = '';
  @State private isRepo: boolean = true;
  @State private branch: string = '';
  @State private ahead: number = 0;
  @State private behind: number = 0;
  @State private stagedFiles: GitFileRow[] = [];
  @State private unstagedFiles: GitFileRow[] = [];

  @State private activeKey: string = '';
  @State private diffLoading: boolean = false;
  @State private diffErr: string = '';
  @State private diffRaw: string = '';
  @State private diffTruncated: boolean = false;
  @State private diffLines: DiffLineVm[] = [];
  @State private diffClippedLocally: boolean = false;

  aboutToAppear(): void {
    void this.loadStatus();
  }

  onReload(): void {
    void this.loadStatus();
  }

  private rowKeyOf(row: GitFileRow): string {
    return (row.staged ? 'S:' : 'U:') + row.path;
  }

  private async loadStatus(): Promise<void> {
    if (this.sessionId === '') {
      return;
    }
    this.busy = true;
    this.missing404 = false;
    try {
      const r: GitStatusResp = await this.api.gitStatus(this.sessionId);
      this.isRepo = r.isRepo === true;
      this.branch = r.branch;
      this.ahead = r.ahead;
      this.behind = r.behind;
      const staged: GitFileRow[] = [];
      const unstaged: GitFileRow[] = [];
      for (let i = 0; i < r.files.length; i++) {
        if (r.files[i].staged) {
          staged.push(r.files[i]);
        } else {
          unstaged.push(r.files[i]);
        }
      }
      this.stagedFiles = staged;
      this.unstagedFiles = unstaged;
      this.err = '';
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      if (isGateway404(msg)) {
        this.missing404 = true;
        this.err = '';
      } else {
        this.err = msg;
      }
    } finally {
      this.busy = false;
    }
  }

  private parseUnifiedDiff(raw: string): DiffLineVm[] {
    if (raw === '') {
      return [];
    }
    const lines: string[] = raw.replace(/\r\n/g, '\n').split('\n');
    const limit: number = lines.length > MAX_RENDER_DIFF_LINES ? MAX_RENDER_DIFF_LINES : lines.length;
    this.diffClippedLocally = lines.length > MAX_RENDER_DIFF_LINES;
    const out: DiffLineVm[] = [];
    for (let i = 0; i < limit; i++) {
      const line: string = lines[i];
      let kind: string = 'ctx';
      if (line.startsWith('@@')) {
        kind = 'hunk';
      } else if (line.startsWith('diff ') || line.startsWith('index ') ||
        line.startsWith('---') || line.startsWith('+++')) {
        kind = 'meta';
      } else if (line.startsWith('+')) {
        kind = 'add';
      } else if (line.startsWith('-')) {
        kind = 'del';
      }
      out.push({ idx: i, kind: kind, text: line === '' ? ' ' : line });
    }
    return out;
  }

  private async toggleDiff(row: GitFileRow): Promise<void> {
    Haptics.tap();
    const key: string = this.rowKeyOf(row);
    if (this.activeKey === key) {
      this.activeKey = '';
      return;
    }
    this.activeKey = key;
    this.diffLoading = true;
    this.diffErr = '';
    this.diffRaw = '';
    this.diffLines = [];
    this.diffTruncated = false;
    this.diffClippedLocally = false;
    try {
      const r: GitDiffResp = await this.api.gitDiff(this.sessionId, row.path, row.staged);
      if (this.activeKey !== key) {
        return;
      }
      this.diffRaw = r.diff;
      this.diffTruncated = r.truncated === true;
      this.diffLines = this.parseUnifiedDiff(r.diff);
    } catch (e) {
      const msg: string = (e as Error).message ?? '读取 Diff 失败';
      if (this.activeKey === key) {
        this.diffErr = msg;
        Toast.err(msg);
      }
    } finally {
      if (this.activeKey === key) {
        this.diffLoading = false;
      }
    }
  }

  private statusTag(status: string): string {
    const s: string = status.trim();
    return s !== '' ? s : 'M';
  }

  private statusInk(status: string): string {
    const s: string = status.trim().toUpperCase();
    if (s === 'A') {
      return Tokens.doneInk;
    }
    if (s === 'D') {
      return Tokens.err;
    }
    if (s === '??' || s === 'U') {
      return Tokens.intrInk;
    }
    if (s === 'M') {
      return Tokens.runInk;
    }
    return Tokens.askInk;
  }

  private statusBg(status: string): string {
    const s: string = status.trim().toUpperCase();
    if (s === 'A') {
      return Tokens.doneBg;
    }
    if (s === 'D') {
      return this.themeDark ? '#24FF5C5C' : '#16DC3545';
    }
    if (s === '??' || s === 'U') {
      return Tokens.intrBg;
    }
    if (s === 'M') {
      return Tokens.runBg;
    }
    return Tokens.askBg;
  }

  private lineInk(kind: string): string {
    if (kind === 'add') {
      return Tokens.doneInk;
    }
    if (kind === 'del') {
      return Tokens.err;
    }
    if (kind === 'hunk') {
      return Tokens.runInk;
    }
    if (kind === 'meta') {
      return Tokens.dim2;
    }
    return Tokens.fg;
  }

  private lineBg(kind: string): ResourceColor {
    if (kind === 'add') {
      return this.themeDark ? '#223DDC97' : '#180F9D63';
    }
    if (kind === 'del') {
      return this.themeDark ? '#24FF5C5C' : '#18DC3545';
    }
    if (kind === 'hunk') {
      return this.themeDark ? '#243B6EF6' : '#162F6BFF';
    }
    return Color.Transparent;
  }

  @Builder
  private diffViewerCard() {
    Column() {
      Row() {
        Text(this.diffTruncated || this.diffClippedLocally
          ? 'Unified Diff（长文件已截断预览，复制可取完整返回）'
          : 'Unified Diff')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.diffRaw !== '') {
          Text('复制 Diff')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.accent)
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rPill)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              void copyText(this.diffRaw, '已复制 Diff');
            })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 10, top: 8, bottom: 8 })
      .border({ width: { bottom: 1 }, color: Tokens.lineSoft })
      .alignItems(VerticalAlign.Center)

      if (this.diffLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(16).height(16).color(Tokens.accent)
          Text('加载变更对比...')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .padding(14)
      } else if (this.diffErr !== '') {
        Text(this.diffErr)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.err)
          .width('100%')
          .padding(12)
      } else if (this.diffLines.length === 0) {
        Text('暂无文本差异（可能为二进制文件、空文件或权限变更）')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .width('100%')
          .padding(12)
      } else {
        Scroll() {
          Column() {
            ForEach(this.diffLines, (ln: DiffLineVm) => {
              Text(ln.text)
                .fontSize(Tokens.fsFoot)
                .lineHeight(18)
                .fontFamily('monospace')
                .fontColor(this.lineInk(ln.kind))
                .backgroundColor(this.lineBg(ln.kind))
                .padding({ left: 10, right: 14, top: 1, bottom: 1 })
                .constraintSize({ minWidth: '100%' })
            }, (ln: DiffLineVm) => String(ln.idx) + ':' + ln.kind)
          }
          .alignItems(HorizontalAlign.Start)
          .constraintSize({ minWidth: '100%' })
          .padding({ top: 6, bottom: 6 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Auto)
        .width('100%')
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .margin({ bottom: 8 })
    .backgroundColor(Tokens.surface2)
    .borderRadius(Tokens.rMd)
    .border({ width: 1, color: Tokens.lineSoft })
  }

  @Builder
  private fileGroupSection(title: string, rows: GitFileRow[]) {
    if (rows.length > 0) {
      Row() {
        Text(title)
          .fontSize(Tokens.fsFoot)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.dim)
        Text(String(rows.length))
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .margin({ left: 6 })
        Blank()
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 8, bottom: 6 })

      ForEach(rows, (r: GitFileRow) => {
        Column() {
          Row() {
            Text(this.statusTag(r.status))
              .fontSize(Tokens.fsCaption)
              .fontFamily('monospace')
              .fontWeight(FontWeight.Bold)
              .fontColor(this.statusInk(r.status))
              .backgroundColor(this.statusBg(r.status))
              .borderRadius(Tokens.rXs)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ right: 10 })

            Text(r.path)
              .fontSize(Tokens.fsFoot)
              .fontFamily('monospace')
              .fontColor(Tokens.fg)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            Text(this.activeKey === this.rowKeyOf(r) ? '收起' : 'Diff ›')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.accent)
              .margin({ left: 8 })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 11, bottom: 11 })
          .margin({ bottom: 6 })
          .backgroundColor(Tokens.surface)
          .borderRadius(Tokens.rMd)
          .border({
            width: 1,
            color: this.activeKey === this.rowKeyOf(r) ? Tokens.accent : Tokens.lineSoft
          })
          .alignItems(VerticalAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
          .onClick(() => {
            void this.toggleDiff(r);
          })

          if (this.activeKey === this.rowKeyOf(r)) {
            this.diffViewerCard()
          }
        }
        .width('100%')
      }, (r: GitFileRow) => this.rowKeyOf(r) + ':' + r.status)
    }
  }

  build() {
    Scroll() {
      Column() {
        if (this.busy) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18).color(Tokens.accent)
            Text('读取 Git 状态...')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim2)
          }
          .width('100%')
          .padding({ top: 8, bottom: 12 })
        }

        if (this.err !== '') {
          Text(this.err)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.err)
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor(Tokens.surface)
            .borderRadius(Tokens.rMd)
            .margin({ bottom: 10 })
        }

        if (this.missing404) {
          EmptyState({
            icon: $r('app.media.ic_fork'),
            title: GATEWAY_404_TITLE,
            hint: GATEWAY_404_HINT
          })
        } else if (!this.isRepo && !this.busy) {
          EmptyState({
            icon: $r('app.media.ic_fork'),
            title: '当前工作区不是 Git 仓库',
            hint: '在包含 .git 的项目目录下开启会话，即可在此查看分支状态与代码差异'
          })
        } else {
          // 顶部分支与同步状态卡
          Row() {
            Image($r('app.media.ic_fork'))
              .width(17)
              .height(17)
              .fillColor(Tokens.accent)
              .objectFit(ImageFit.Contain)
              .margin({ right: 8 })

            Text(this.branch !== '' ? this.branch : 'HEAD')
              .fontSize(Tokens.fsBodyLg)
              .fontFamily('monospace')
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.fg)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            if (this.ahead > 0) {
              Text('领先 ' + String(this.ahead))
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.doneInk)
                .backgroundColor(Tokens.doneBg)
                .borderRadius(Tokens.rPill)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .margin({ left: 6 })
            }
            if (this.behind > 0) {
              Text('落后 ' + String(this.behind))
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.intrInk)
                .backgroundColor(Tokens.intrBg)
                .borderRadius(Tokens.rPill)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .margin({ left: 6 })
            }
            Text(String(this.stagedFiles.length + this.unstagedFiles.length) + ' 个变更')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.dim2)
              .margin({ left: 8 })
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor(Tokens.surface)
          .borderRadius(Tokens.rMd)
          .border({ width: 1, color: Tokens.lineSoft })
          .margin({ bottom: 10 })
          .alignItems(VerticalAlign.Center)

          if (this.stagedFiles.length === 0 && this.unstagedFiles.length === 0 && !this.busy) {
            EmptyState({
              icon: $r('app.media.ic_fork'),
              title: '工作区干净，暂无未提交变更',
              hint: '智能体修改或新建文件后，点击右上角刷新即可逐文件查看红绿对比'
            })
          } else {
            this.fileGroupSection('已暂存变更', this.stagedFiles)
            this.fileGroupSection('未暂存变更', this.unstagedFiles)
          }
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 820 })
      .padding({ left: 16, right: 16, top: this.topPad, bottom: this.bottomInset + 32 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }
}
