import { Api, FsEntry, FsFile, FsListing, FsUploadItem, FsUploadResp } from '../../common/Api';
import { AppCtx } from '../../common/AppCtx';
import { Mat } from '../../common/Mat';
import { Tokens } from '../../common/Tokens';
import { EmptyState } from '../../common/Widgets';
import { bytes, stamp } from '../../common/Format';
import { copyText } from '../../common/Clipboard';
import { Saver } from '../../common/Saver';
import { FilePart, pickFiles, readFile } from '../../common/Files';
import { Haptics } from '../../common/Haptics';
import { Toast } from '../../common/Toast';
import { GATEWAY_404_HINT, GATEWAY_404_TITLE, isGateway404, isImageFileName, splitFileLeaf } from './ExtrasCommon';

/**
 * 工作区文件管理与预览面板（K4 / G6 / I4 / U5）：
 * - fallback 提示横幅
 * - 搜索过滤、排序、新建文件夹（api.fsMkdir）、上传手机文件（pickFiles + api.fsUpload）
 * - nextOffset 分页「加载更多」
 * - 避让键盘的 bindSheet(FIT_CONTENT) 重命名与新建目录弹窗
 * - 等宽横向可滚文本代码查看器，顶栏支持「复制全文」(copyText) 与「保存到手机」(Saver.saveText)
 */
@Component
export struct WorkspaceFilesView {
  api: Api = new Api('', '');
  @Prop sessionId: string = '';
  @Prop @Watch('onReload') reloadTick: number = 0;
  @Prop topPad: number = 140;

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private busy: boolean = false;
  @State private loadingMore: boolean = false;
  @State private fsBusy: boolean = false;
  @State private uploading: boolean = false;
  @State private saving: boolean = false;
  @State private missing404: boolean = false;
  @State private err: string = '';

  @State private rootPath: string = '';
  @State private rootFallback: boolean = false;
  @State private dirPath: string = '';
  @State private entries: FsEntry[] = [];
  @State private more: boolean = false;
  @State private nextOffset: number = 0;

  @State private fsQuery: string = '';
  @State private fsSort: string = 'name';

  @State private mkdirOn: boolean = false;
  @State private mkdirName: string = '';

  @State private renameOn: boolean = false;
  @State private renameTarget: string = '';
  @State private renameName: string = '';

  @State private viewerOn: boolean = false;
  @State private viewerName: string = '';
  @State private viewerPath: string = '';
  @State private viewerText: string = '';
  @State private viewerBinary: boolean = false;

  @State private imageOn: boolean = false;
  @State private imagePath: string = '';

  aboutToAppear(): void {
    void this.loadDir('');
  }

  onReload(): void {
    void this.loadDir(this.dirPath);
  }

  private sepOfHost(): string {
    if (this.rootPath.indexOf('\\') >= 0 || this.dirPath.indexOf('\\') >= 0) {
      return '\\';
    }
    return '/';
  }

  private joinRel(leaf: string): string {
    if (this.dirPath === '') {
      return leaf;
    }
    const sep: string = this.sepOfHost();
    const hasTrailing: boolean = this.dirPath.endsWith('/') || this.dirPath.endsWith('\\');
    return hasTrailing ? (this.dirPath + leaf) : (this.dirPath + sep + leaf);
  }

  private upDir(): void {
    if (this.dirPath === '') {
      return;
    }
    const cut: number = Math.max(this.dirPath.lastIndexOf('/'), this.dirPath.lastIndexOf('\\'));
    void this.loadDir(cut <= 0 ? '' : this.dirPath.substring(0, cut));
  }

  private async loadDir(target: string): Promise<void> {
    if (this.sessionId === '') {
      return;
    }
    this.busy = true;
    this.missing404 = false;
    try {
      const r: FsListing = await this.api.fsList(this.sessionId, target, 0, 200);
      this.rootPath = r.root;
      this.rootFallback = r.fallback === true;
      this.dirPath = r.path;
      this.entries = r.entries;
      this.more = r.more === true;
      this.nextOffset = r.nextOffset !== undefined ? r.nextOffset : r.entries.length;
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

  private async loadMoreEntries(): Promise<void> {
    if (!this.more || this.loadingMore || this.sessionId === '') {
      return;
    }
    Haptics.tap();
    this.loadingMore = true;
    try {
      const r: FsListing = await this.api.fsList(this.sessionId, this.dirPath, this.nextOffset, 200);
      this.entries = this.entries.concat(r.entries);
      this.more = r.more === true;
      this.nextOffset = r.nextOffset !== undefined ? r.nextOffset : this.entries.length;
    } catch (e) {
      Toast.err((e as Error).message);
    } finally {
      this.loadingMore = false;
    }
  }

  private filteredEntries(): FsEntry[] {
    const kw: string = this.fsQuery.trim().toLowerCase();
    const out: FsEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      const e: FsEntry = this.entries[i];
      if (kw === '' || e.name.toLowerCase().indexOf(kw) >= 0) {
        out.push(e);
      }
    }
    out.sort((a: FsEntry, b: FsEntry) => {
      if (a.dir !== b.dir) {
        return a.dir ? -1 : 1;
      }
      if (this.fsSort === 'time') {
        return b.mtime - a.mtime;
      }
      if (this.fsSort === 'size') {
        return b.size - a.size;
      }
      const x: string = a.name.toLowerCase();
      const y: string = b.name.toLowerCase();
      return x < y ? -1 : (x > y ? 1 : 0);
    });
    return out;
  }

  private async doMkdir(): Promise<void> {
    const name: string = this.mkdirName.trim().replace(/[\\/:*?"<>|]/g, '');
    if (name === '' || this.fsBusy) {
      return;
    }
    Haptics.tap();
    this.fsBusy = true;
    try {
      await this.api.fsMkdir(this.sessionId, this.joinRel(name));
      this.mkdirOn = false;
      this.mkdirName = '';
      Toast.ok('已新建文件夹「' + name + '」');
      await this.loadDir(this.dirPath);
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      Toast.err(isGateway404(msg) ? (GATEWAY_404_TITLE + '，' + GATEWAY_404_HINT) : msg);
    } finally {
      this.fsBusy = false;
    }
  }

  private async pickAndUpload(): Promise<void> {
    if (this.uploading || this.sessionId === '') {
      return;
    }
    Haptics.tap();
    try {
      const uris: string[] = await pickFiles(9);
      if (uris.length === 0) {
        return;
      }
      this.uploading = true;
      const items: FsUploadItem[] = [];
      let skipped: number = 0;
      for (let i = 0; i < uris.length; i++) {
        const part: FilePart | undefined = await readFile(uris[i]);
        if (part === undefined) {
          skipped++;
          continue;
        }
        items.push({ name: part.name, data: part.data });
      }
      if (items.length === 0) {
        Toast.err('所选文件为空或超过单文件 8 MB 上限');
        return;
      }
      const res: FsUploadResp = await this.api.fsUpload(this.sessionId, this.dirPath, items);
      const savedCount: number = res.saved.length > 0 ? res.saved.length : items.length;
      Toast.ok('已上传 ' + String(savedCount) + ' 个文件' + (skipped > 0 ? ('（跳过 ' + String(skipped) + ' 个超大文件）') : ''));
      await this.loadDir(this.dirPath);
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      Toast.err(isGateway404(msg) ? (GATEWAY_404_TITLE + '，' + GATEWAY_404_HINT) : msg);
    } finally {
      this.uploading = false;
    }
  }

  private async doRename(): Promise<void> {
    const next: string = this.renameName.trim().replace(/[\\/:*?"<>|]/g, '');
    if (next === '' || this.fsBusy) {
      return;
    }
    Haptics.tap();
    this.fsBusy = true;
    try {
      await this.api.fsRename(this.sessionId, this.renameTarget, this.joinRel(next));
      this.renameOn = false;
      Toast.ok('已重命名');
      await this.loadDir(this.dirPath);
    } catch (e) {
      Toast.err((e as Error).message);
    } finally {
      this.fsBusy = false;
    }
  }

  private confirmDelete(e: FsEntry): void {
    Haptics.tap();
    AppCtx.confirm(
      e.dir ? '删除空文件夹' : '删除文件',
      e.dir ? '仅允许删除空文件夹；非空目录请先清理内部文件。' : ('确定删除「' + e.name + '」？此操作不可撤销。'),
      '删除',
      () => {
        void this.doDelete(this.joinRel(e.name));
      },
      true
    );
  }

  private async doDelete(target: string): Promise<void> {
    if (this.fsBusy) {
      return;
    }
    this.fsBusy = true;
    try {
      await this.api.fsDelete(this.sessionId, target);
      Toast.ok('已删除');
      await this.loadDir(this.dirPath);
    } catch (e) {
      Toast.err((e as Error).message);
    } finally {
      this.fsBusy = false;
    }
  }

  private async openEntry(e: FsEntry): Promise<void> {
    if (e.dir) {
      Haptics.tap();
      await this.loadDir(this.joinRel(e.name));
      return;
    }
    Haptics.tap();
    const full: string = this.joinRel(e.name);
    if (isImageFileName(e.name)) {
      await this.api.signFsRaw(this.sessionId, full);
      this.imagePath = full;
      this.imageOn = true;
      this.viewerOn = false;
      this.saving = false;
      return;
    }
    if (e.size > 512 * 1024) {
      this.viewerName = splitFileLeaf(full);
      this.viewerPath = full;
      this.viewerText = '';
      this.viewerBinary = true;
      this.viewerOn = true;
      this.imageOn = false;
      this.saving = false;
      return;
    }
    this.busy = true;
    try {
      const f: FsFile = await this.api.fsFile(this.sessionId, full);
      this.viewerName = f.name !== '' ? f.name : splitFileLeaf(full);
      this.viewerPath = full;
      this.viewerText = f.text;
      this.viewerBinary = false;
      this.viewerOn = true;
      this.imageOn = false;
      this.saving = false;
      this.err = '';
    } catch (err) {
      const msg: string = (err as Error).message ?? '';
      if (msg.indexOf('415') >= 0 || msg.indexOf('413') >= 0 || msg.indexOf('binary') >= 0 ||
        msg.indexOf('二进制') >= 0 || msg.indexOf('too large') >= 0) {
        this.viewerName = splitFileLeaf(full);
        this.viewerPath = full;
        this.viewerText = '';
        this.viewerBinary = true;
        this.viewerOn = true;
        this.imageOn = false;
        this.saving = false;
      } else {
        Toast.err(msg);
      }
    } finally {
      this.busy = false;
    }
  }

  private async saveTextViewerToPhone(): Promise<void> {
    if (this.saving) {
      return;
    }
    Haptics.tap();
    this.saving = true;
    try {
      const ok: boolean = await Saver.saveText(AppCtx.ability(), this.viewerText, this.viewerName);
      if (ok) {
        Toast.ok('已保存到手机');
      }
    } catch (e) {
      Toast.err((e as Error).message);
    } finally {
      this.saving = false;
    }
  }

  private async downloadBinaryToPhone(targetPath: string, targetName: string): Promise<void> {
    if (this.saving || targetPath === '') {
      return;
    }
    Haptics.tap();
    this.saving = true;
    try {
      const url: string = this.api.fsDownloadUrl(this.sessionId, targetPath);
      const ok: boolean = await Saver.save(AppCtx.ability(), url, targetName, this.api.bearer());
      if (ok) {
        Toast.ok('已保存到手机');
      }
    } catch (e) {
      Toast.err((e as Error).message);
    } finally {
      this.saving = false;
    }
  }

  @Builder
  private rowActionMenu(e: FsEntry) {
    Menu() {
      if (!e.dir) {
        MenuItem({ content: '保存到手机' })
          .onClick(() => {
            void this.downloadBinaryToPhone(this.joinRel(e.name), e.name);
          })
      }
      MenuItem({ content: '重命名' })
        .onClick(() => {
          this.renameTarget = this.joinRel(e.name);
          this.renameName = e.name;
          this.renameOn = true;
        })
      MenuItem({ content: '删除' })
        .onClick(() => {
          this.confirmDelete(e);
        })
    }
  }

  @Builder
  private mkdirSheetBody() {
    Scroll() {
      Column({ space: 12 }) {
        Text('新建文件夹')
          .fontSize(Tokens.fsTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .width('100%')
        TextInput({ text: this.mkdirName, placeholder: '输入文件夹名称' })
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rInput)
          .height(44)
          .onChange((v: string) => {
            this.mkdirName = v;
          })
          .onSubmit(() => {
            void this.doMkdir();
          })
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.dim)
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rInput)
            .height(44)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .onClick(() => {
              this.mkdirOn = false;
            })
          Text(this.fsBusy ? '创建中...' : '创建')
            .fontSize(Tokens.fsBodyLg)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accentInk)
            .backgroundColor(Tokens.accent)
            .borderRadius(Tokens.rInput)
            .height(44)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .onClick(() => {
              void this.doMkdir();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: this.bottomInset + 18 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .backgroundColor(Color.Transparent)
  }

  @Builder
  private renameSheetBody() {
    Scroll() {
      Column({ space: 12 }) {
        Text('重命名')
          .fontSize(Tokens.fsTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .width('100%')
        TextInput({ text: this.renameName, placeholder: '输入新名称' })
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .backgroundColor(Mat.subCardBg(this.hdsOn))
          .border(Mat.subCardBorder(this.hdsOn))
          .borderRadius(Tokens.rInput)
          .height(44)
          .onChange((v: string) => {
            this.renameName = v;
          })
          .onSubmit(() => {
            void this.doRename();
          })
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.dim)
            .backgroundColor(Mat.subCardBg(this.hdsOn))
            .border(Mat.subCardBorder(this.hdsOn))
            .borderRadius(Tokens.rInput)
            .height(44)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .onClick(() => {
              this.renameOn = false;
            })
          Text(this.fsBusy ? '保存中...' : '保存')
            .fontSize(Tokens.fsBodyLg)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accentInk)
            .backgroundColor(Tokens.accent)
            .borderRadius(Tokens.rInput)
            .height(44)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .onClick(() => {
              void this.doRename();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: this.bottomInset + 18 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .backgroundColor(Color.Transparent)
  }

  @Builder
  private textOrBinaryViewer() {
    Column() {
      Row({ space: 8 }) {
        Text('< 返回目录')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.accent)
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            Haptics.tap();
            this.viewerOn = false;
          })

        Text(this.viewerName)
          .fontSize(Tokens.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        if (!this.viewerBinary) {
          Text('复制全文')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.fg)
            .backgroundColor(Tokens.chip)
            .borderRadius(Tokens.rPill)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              void copyText(this.viewerText, '已复制全文');
            })
        }

        Text(this.saving ? '保存中...' : '保存到手机')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.accentInk)
          .backgroundColor(this.saving ? Tokens.surface3 : Tokens.accent)
          .borderRadius(Tokens.rPill)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            if (this.viewerBinary) {
              void this.downloadBinaryToPhone(this.viewerPath, this.viewerName);
            } else {
              void this.saveTextViewerToPhone();
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.viewerBinary) {
        EmptyState({
          icon: $r('app.media.ic_set_disk'),
          title: '二进制或超大文件无法内嵌预览',
          hint: '请点击右上角「保存到手机」下载后使用其他应用打开',
          action: this.saving ? '正在保存...' : '保存到手机',
          onAction: () => {
            void this.downloadBinaryToPhone(this.viewerPath, this.viewerName);
          }
        })
      } else {
        Scroll() {
          Scroll() {
            Text(this.viewerText)
              .fontSize(Tokens.fsFoot)
              .lineHeight(19)
              .fontFamily('monospace')
              .fontColor(Tokens.fg)
              .copyOption(CopyOptions.LocalDevice)
              .textAlign(TextAlign.Start)
              .padding(14)
              .constraintSize({ minWidth: '100%' })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
          .align(Alignment.TopStart)
        }
        .layoutWeight(1)
        .width('100%')
        .margin({ left: 16, right: 16, bottom: this.bottomInset + 16 })
        .backgroundColor(Tokens.surface)
        .borderRadius(Tokens.rMd)
        .border({ width: 1, color: Tokens.lineSoft })
        .align(Alignment.TopStart)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topPad })
  }

  @Builder
  private imageViewer() {
    Column() {
      Row({ space: 8 }) {
        Text('< 返回目录')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.accent)
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => {
            Haptics.tap();
            this.imageOn = false;
          })
        Text(splitFileLeaf(this.imagePath))
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.saving ? '保存中...' : '保存到手机')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.accentInk)
          .backgroundColor(this.saving ? Tokens.surface3 : Tokens.accent)
          .borderRadius(Tokens.rPill)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .onClick(() => {
            void this.downloadBinaryToPhone(this.imagePath, splitFileLeaf(this.imagePath));
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.api.fsRawUrl(this.sessionId, this.imagePath) !== '') {
        Image(this.api.fsRawUrl(this.sessionId, this.imagePath))
          .width('100%')
          .layoutWeight(1)
          .objectFit(ImageFit.Contain)
          .padding({ left: 16, right: 16, bottom: this.bottomInset + 16 })
      } else {
        EmptyState({
          icon: $r('app.media.ic_set_look'),
          title: '图片预览签名未就绪',
          hint: '可直接保存到手机查看，或返回后重新点开'
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topPad })
  }

  build() {
    Stack() {
      if (this.viewerOn) {
        this.textOrBinaryViewer()
      } else if (this.imageOn) {
        this.imageViewer()
      } else {
        Scroll() {
          Column() {
            if (this.rootFallback) {
              Row() {
                Text('当前会话未绑定独立工作目录，正在展示电脑端默认目录')
                  .fontSize(Tokens.fsFoot)
                  .fontColor(Tokens.intrInk)
                  .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 9, bottom: 9 })
              .backgroundColor(Tokens.intrBg)
              .borderRadius(Tokens.rMd)
              .margin({ bottom: 8 })
            }

            if (this.rootPath !== '') {
              Text(this.rootPath + (this.dirPath !== '' ? (this.sepOfHost() + this.dirPath) : ''))
                .fontSize(Tokens.fsCaption)
                .fontFamily('monospace')
                .fontColor(Tokens.dim2)
                .width('100%')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .padding({ left: 4, bottom: 8 })
            }

            // 顶部新建文件夹 + 上传文件 + 排序过滤工具栏
            Row({ space: 8 }) {
              Text('+ 新建文件夹')
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.accent)
                .backgroundColor(Tokens.accentSoft)
                .borderRadius(Tokens.rPill)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                .onClick(() => {
                  Haptics.tap();
                  this.mkdirName = '';
                  this.mkdirOn = true;
                })

              Text(this.uploading ? '上传中...' : '+ 上传手机文件')
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.fg)
                .backgroundColor(Tokens.surface)
                .border({ width: 1, color: Tokens.lineSoft })
                .borderRadius(Tokens.rPill)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                .onClick(() => {
                  void this.pickAndUpload();
                })

              Blank()
            }
            .width('100%')
            .margin({ bottom: 8 })
            .alignItems(VerticalAlign.Center)

            Row({ space: 6 }) {
              TextInput({ placeholder: '过滤当前目录文件...', text: this.fsQuery })
                .height(36)
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.fg)
                .placeholderColor(Tokens.dim2)
                .borderRadius(Tokens.rPill)
                .backgroundColor(Tokens.surface)
                .border({ width: 1, color: Tokens.lineSoft })
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.fsQuery = v;
                })
              ForEach(['name', 'time', 'size'], (k: string) => {
                Text(k === 'name' ? '名称' : (k === 'time' ? '时间' : '大小'))
                  .fontSize(Tokens.fsCaption)
                  .fontColor(this.fsSort === k ? Tokens.accentInk : Tokens.dim)
                  .backgroundColor(this.fsSort === k ? Tokens.accent : Tokens.surface)
                  .borderRadius(Tokens.rPill)
                  .padding({ left: 9, right: 9, top: 6, bottom: 6 })
                  .onClick(() => {
                    Haptics.tap();
                    this.fsSort = k;
                  })
              }, (k: string) => k)
            }
            .width('100%')
            .margin({ bottom: 10 })
            .alignItems(VerticalAlign.Center)

            if (this.dirPath !== '') {
              Row() {
                Text('..')
                  .fontSize(Tokens.fsBody)
                  .fontFamily('monospace')
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Tokens.accent)
                  .width(28)
                Text('返回上一级目录')
                  .fontSize(Tokens.fsBody)
                  .fontColor(Tokens.dim)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .margin({ bottom: 6 })
              .backgroundColor(Tokens.surface)
              .borderRadius(Tokens.rMd)
              .border({ width: 1, color: Tokens.lineSoft })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
              .onClick(() => {
                this.upDir();
              })
            }

            if (this.busy) {
              Row({ space: 8 }) {
                LoadingProgress().width(18).height(18).color(Tokens.accent)
                Text('读取目录中...')
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
                .margin({ bottom: 8 })
            }

            if (this.missing404) {
              EmptyState({
                icon: $r('app.media.ic_set_disk'),
                title: GATEWAY_404_TITLE,
                hint: GATEWAY_404_HINT
              })
            } else if (this.entries.length === 0 && !this.busy && this.err === '') {
              EmptyState({
                icon: $r('app.media.ic_set_disk'),
                title: '这个文件夹是空的',
                hint: '可以新建子文件夹，或从手机选择文件上传到此目录'
              })
            } else if (this.filteredEntries().length === 0 && !this.busy) {
              EmptyState({
                icon: $r('app.media.ic_search'),
                title: '没有匹配的文件',
                hint: '请尝试其他过滤关键词',
                action: '清空过滤',
                onAction: () => {
                  this.fsQuery = '';
                }
              })
            } else {
              ForEach(this.filteredEntries(), (e: FsEntry) => {
                Row() {
                  Stack({ alignContent: Alignment.Center }) {
                    if (e.dir) {
                      Image($r('app.media.ic_set_disk'))
                        .width(16)
                        .height(16)
                        .fillColor(Tokens.accent)
                        .objectFit(ImageFit.Contain)
                    } else if (isImageFileName(e.name)) {
                      Image($r('app.media.ic_set_look'))
                        .width(16)
                        .height(16)
                        .fillColor(Tokens.runInk)
                        .objectFit(ImageFit.Contain)
                    } else {
                      Text('·')
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(Tokens.dim2)
                    }
                  }
                  .width(28)
                  .height(28)
                  .margin({ right: 8 })

                  Column() {
                    Text(e.name)
                      .fontSize(Tokens.fsBody)
                      .fontColor(Tokens.fg)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(e.dir ? '文件夹' : (bytes(e.size) + ' · ' + stamp(e.mtime)))
                      .fontSize(Tokens.fsCaption)
                      .fontColor(Tokens.dim2)
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Text('···')
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Tokens.dim2)
                    .width(34)
                    .height(34)
                    .textAlign(TextAlign.Center)
                    .borderRadius(Tokens.rPill)
                    .bindMenu(this.rowActionMenu(e))

                  if (e.dir) {
                    Text('›')
                      .fontSize(15)
                      .fontColor(Tokens.dim2)
                      .margin({ left: 2 })
                  }
                }
                .width('100%')
                .padding({ left: 10, right: 12, top: 10, bottom: 10 })
                .margin({ bottom: 6 })
                .backgroundColor(Tokens.surface)
                .borderRadius(Tokens.rMd)
                .border({ width: 1, color: Tokens.lineSoft })
                .alignItems(VerticalAlign.Center)
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
                .onClick(() => {
                  void this.openEntry(e);
                })
              }, (e: FsEntry) => e.name + (e.dir ? '/d/' : '/f/') + String(e.mtime) + '/' + String(e.size))

              if (this.more) {
                Row({ space: 6 }) {
                  if (this.loadingMore) {
                    LoadingProgress().width(15).height(15).color(Tokens.accent)
                  }
                  Text(this.loadingMore
                    ? '加载更多中...'
                    : ('加载更多（已显示 ' + String(this.entries.length) + ' 项）'))
                    .fontSize(Tokens.fsFoot)
                    .fontColor(Tokens.accent)
                }
                .width('100%')
                .height(40)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(Tokens.accentSoft)
                .borderRadius(Tokens.rMd)
                .margin({ top: 6 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
                .onClick(() => {
                  void this.loadMoreEntries();
                })
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

      Row()
        .width(0)
        .height(0)
        .bindSheet($$this.mkdirOn, this.mkdirSheetBody(),
          Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => {
            this.mkdirOn = false;
          }))

      Row()
        .width(0)
        .height(0)
        .bindSheet($$this.renameOn, this.renameSheetBody(),
          Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => {
            this.renameOn = false;
          }))
    }
    .width('100%')
    .height('100%')
  }
}
