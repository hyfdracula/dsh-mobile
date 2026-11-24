/**
 * 反馈：入口 → 提交反馈 / 我的反馈 → 工单详情。
 *
 * 为什么是一个组件里分四屏而不是四个 NavDestination：
 * 反馈是设置里的一个一级菜单，二级页已经是 NavDestination；再往里压三层会让
 * 返回手势与「回到设置」的语义变复杂。这里用一个 `stage` 状态切屏，返回键自己处理：
 * 非入口屏退一格，入口屏交给设置页关掉这一层。
 */

import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { Toast } from '../common/Toast';
import { Notifier } from '../common/Notifier';
import { Api } from '../common/Api';
import { Net } from '../common/Net';
import {
  FEEDBACK_KINDS, UPLOADS, UploadSpec, Ticket, FeedbackKind, NewTicket,
  TicketFile, TicketReply, envLine, submit, mine, detail, upload, ticketText,
  statusText, sizeText, timeText, notifyPref, setNotifyPref, contactPref, setContactPref
} from '../common/Feedback';

/** QQ 群：给国内用户一个不用账号的直达通道。 */
const QQ_GROUP: string = '1131519744';

/** 一条待上传的附件。 */
interface Pending {
  spec: UploadSpec;
  path: string;
  name: string;
  size: number;
}

@Component
export struct FeedbackPage {
  onExit: () => void = () => {};

  @State @Watch('onStage') private stage: string = 'entry';
  /** 设置页的 NavDestination 用它判断返回键要不要退一格。 */
  @StorageLink('fbBack') @Watch('onFbBack') private fbBack: number = 0;
  @State private busy: boolean = false;
  @State private err: string = '';
  @State private note: string = '';

  // 提交页
  @State private kind: string = 'bug';
  @State private text: string = '';
  @State private contact: string = '';
  @State private notifyOn: boolean = true;
  @State private pend: Pending[] = [];

  // 我的反馈
  @State private rows: Ticket[] = [];
  @State private loaded: boolean = false;

  // 详情
  @State private cur: Ticket | null = null;

  private themeBg(): string {
    return Tokens.isDark ? Tokens.bg : '#F7F8FA';
  }

  /** 当前屏同步给外层，返回键才知道该退一格还是关闭整页。 */
  private onStage(): void {
    AppStorage.setOrCreate('fbStage', this.stage);
  }

  private onFbBack(): void {
    if (this.fbBack > 0) {
      this.back();
    }
  }

  aboutToAppear(): void {
    AppStorage.setOrCreate('fbStage', this.stage);
    this.notifyOn = notifyPref();
    this.contact = contactPref();
  }

  /** 返回：先退屏，入口屏才真的退出。 */
  private back(): void {
    Haptics.tap();
    if (this.stage === 'submit' || this.stage === 'mine') {
      this.stage = 'entry';
      this.err = '';
      this.note = '';
      return;
    }
    if (this.stage === 'detail') {
      this.stage = 'mine';
      return;
    }
    this.onExit();
  }

  private toast(msg: string): void {
    Toast.info(msg);
  }

  private async copy(t: string, what: string): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, t);
      await pasteboard.getSystemPasteboard().setData(data);
      Haptics.tap();
      this.toast(what + '已复制');
    } catch (e) {
      this.toast('复制失败');
    }
  }

  /** 诊断信息：环境 + 在线状态 + 最近几次请求失败，贴进工单就够复现了。 */
  private copyDiag(): void {
    const parts: string[] = [];
    parts.push(envLine());
    parts.push('网络：' + (Net.isOnline() ? '在线' : '离线'));
    const errs: string[] = Api.recentErrors();
    if (errs.length === 0) {
      parts.push('最近错误：无');
    } else {
      parts.push('最近错误：');
      for (let i = 0; i < errs.length; i++) {
        parts.push('  ' + errs[i]);
      }
    }
    this.copy(parts.join('\n'), '诊断信息');
  }

  /** 相册里挑截图 / 录屏（限 1 个视频）。 */
  private async pickMedia(video: boolean): Promise<string[]> {
    const picker2: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    const opt: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    opt.MIMEType = video ? photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE
      : photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    opt.maxSelectNumber = video ? 1 : 3;
    const picked: photoAccessHelper.PhotoSelectResult = await picker2.select(opt);
    return picked.photoUris === undefined ? [] : picked.photoUris;
  }

  /** 文件里挑日志与样本。 */
  private async pickDoc(): Promise<string[]> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    const vp: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext());
    const uris: string[] = await vp.select(options);
    return uris === undefined || uris === null ? [] : uris;
  }

  private nameOf(uri: string): string {
    const cut: number = uri.lastIndexOf('/');
    const tail: string = cut >= 0 ? uri.slice(cut + 1) : uri;
    return tail.length > 80 ? tail.slice(tail.length - 80) : tail;
  }

  private countOf(kind: string): number {
    let n: number = 0;
    for (let i = 0; i < this.pend.length; i++) {
      if (this.pend[i].spec.kind === kind) {
        n++;
      }
    }
    return n;
  }

  private addPending(spec: UploadSpec, paths: string[]): void {
    const next: Pending[] = this.pend.slice();
    for (let i = 0; i < paths.length; i++) {
      next.push({ spec: spec, path: paths[i], name: this.nameOf(paths[i]), size: 0 });
    }
    this.pend = next;
  }

  private async addShot(): Promise<void> {
    if (this.countOf('screenshot') >= 3) {
      this.toast('最多 3 张截图');
      return;
    }
    try {
      const uris: string[] = await this.pickMedia(false);
      if (uris.length > 0) {
        this.addPending(UPLOADS[0], uris);
      }
    } catch (e) {
      this.toast('打不开相册');
    }
  }

  private async addVideo(): Promise<void> {
    if (this.countOf('video') >= 1) {
      this.toast('最多 1 段录屏');
      return;
    }
    try {
      const uris: string[] = await this.pickMedia(true);
      if (uris.length > 0) {
        this.addPending(UPLOADS[1], uris);
      }
    } catch (e) {
      this.toast('打不开相册');
    }
  }

  private async addLog(): Promise<void> {
    if (this.countOf('log') >= 1) {
      this.toast('最多 1 个日志文件');
      return;
    }
    try {
      const uris: string[] = await this.pickDoc();
      if (uris.length > 0) {
        this.addPending(UPLOADS[2], uris);
      }
    } catch (e) {
      this.toast('打不开文件管理');
    }
  }

  private dropPending(i: number): void {
    if (i < 0 || i >= this.pend.length) {
      return;
    }
    const next: Pending[] = this.pend.slice();
    next.splice(i, 1);
    this.pend = next;
    Haptics.tap();
  }

  /** 提交：先建单，再逐个上传附件。 */
  private async doSubmit(): Promise<void> {
    if (this.busy) {
      return;
    }
    const body: string = this.text.trim();
    if (body === '') {
      this.toast('写点什么再提交');
      return;
    }
    this.busy = true;
    this.err = '';
    this.note = '';
    let id: string = '';
    try {
      const t: NewTicket = {
        kind: this.kind,
        body: body,
        env: envLine(),
        contact: this.contact.trim(),
        notify: this.notifyOn
      };
      id = await submit(t);
      setNotifyPref(this.notifyOn);
      setContactPref(this.contact.trim());
      let failed: string = '';
      for (let i = 0; i < this.pend.length; i++) {
        const one: Pending = this.pend[i];
        try {
          await upload(id, one.spec, one.path, one.name);
        } catch (e) {
          failed = one.spec.label + ' 没传上去：' + (e as BusinessError).message;
        }
      }
      this.text = '';
      this.pend = [];
      this.rows = [];
      this.loaded = false;
      await this.loadMine();
      await this.openDetail(id);
      this.note = failed === '' ? '已提交，工单 ' + id : '已提交，但 ' + failed;
      if (this.notifyOn) {
        await Notifier.ensure();
      }
    } catch (e) {
      this.err = (e as BusinessError).message;
    } finally {
      this.busy = false;
    }
  }

  private async loadMine(): Promise<void> {
    this.busy = true;
    this.err = '';
    try {
      this.rows = await mine();
      this.loaded = true;
    } catch (e) {
      this.err = (e as BusinessError).message;
    } finally {
      this.busy = false;
    }
  }

  private async openDetail(id: string): Promise<void> {
    this.busy = true;
    this.note = '';
    try {
      this.cur = await detail(id);
      this.stage = 'detail';
    } catch (e) {
      this.err = (e as BusinessError).message;
    } finally {
      this.busy = false;
    }
  }

  // ---------------------------------------------------------------- 视图

  @Builder
  fbFade() {
    Row()
      .width('100%')
      // 54 的状态栏内距 + 56 的标题栏高 = 110；渐变必须盖住整条标题栏，
      // 否则内容会从标题文字下面透出来（96 高时正好差 14px）。
      .height(132)
      .linearGradient({
        angle: 180,
        colors: [[this.themeBg(), 0.0], [this.themeBg(), 0.66], ['#00' + this.themeBg().slice(1), 1.0]]
      })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  fbHeader(title: string) {
    Row() {
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
        this.back();
      })
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ left: 12 })
      Blank()
      if (this.busy) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(Tokens.accent)
      }
    }
    .width('100%')
    .height(56)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  card(title: string) {
    Column() {
      Text(title)
        .fontSize(13)
        .fontColor(Tokens.dim)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .borderRadius(Tokens.rCard)
    .backgroundColor(Tokens.surface)
    .border({ width: 1, color: Tokens.lineSoft })
  }

  /** 入口：提交反馈 / 我的反馈 / QQ 群。 */
  @Builder
  entryBody() {
    Column() {
      Text('遇到问题、想加点功能，都可以在这里说。电脑没开也能提。')
        .fontSize(13)
        .fontColor(Tokens.dim)
        .width('100%')
        .margin({ bottom: 16 })

      this.entryRow('提交反馈', '写描述、贴截图，直接进来提', () => {
        Haptics.tap();
        this.note = '';
        this.err = '';
        this.stage = 'submit';
      })
      this.entryRow('我的反馈', '看我提过的工单和处理进度', () => {
        Haptics.tap();
        this.stage = 'mine';
        this.loadMine();
      })
      this.entryRow('QQ 群 ' + QQ_GROUP, '直接进群说，最快', () => {
        Haptics.tap();
        this.copy(QQ_GROUP, '群号');
      })

      Text('提交的内容只有我能看到，不含账号、对话内容、密钥与本地文件。')
        .fontSize(11)
        .fontColor(Tokens.dim2)
        .width('100%')
        .margin({ top: 18 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  entryRow(title: string, sub: string, act: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(Tokens.fg)
          .width('100%')
        if (sub !== '') {
          Text(sub)
            .fontSize(12)
            .fontColor(Tokens.dim2)
            .width('100%')
            .margin({ top: 3 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('›')
        .fontSize(15)
        .fontColor(Tokens.dim2)
    }
    .width('100%')
    .padding({ left: 16, right: 14, top: 14, bottom: 14 })
    .margin({ bottom: 10 })
    .borderRadius(Tokens.rCard)
    .backgroundColor(Tokens.surface)
    .border({ width: 1, color: Tokens.lineSoft })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(act)
  }

  /** 提交页。 */
  @Builder
  submitBody() {
    Column() {
      Text('反馈类型')
        .fontSize(13)
        .fontColor(Tokens.dim)
        .width('100%')
        .margin({ bottom: 8 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(FEEDBACK_KINDS, (k: FeedbackKind) => {
          Text(k.name)
            .fontSize(13)
            .fontColor(this.kind === k.id ? Tokens.accentInk : Tokens.dim)
            .backgroundColor(this.kind === k.id ? Tokens.accent : Tokens.surface2)
            .borderRadius(999)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .margin({ right: 8, bottom: 8 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              this.kind = k.id;
            })
        }, (k: FeedbackKind) => k.id)
      }
      .width('100%')

      TextArea({ placeholder: '说说发生了什么：在哪一步、看到什么、你期待什么。第一行会自动当标题。', text: this.text })
        .fontSize(13)
        .lineHeight(21)
        .padding(12)
        .backgroundColor(Tokens.surface)
        .borderRadius(20)
        .border({ width: 1, color: Tokens.lineSoft })
        .constraintSize({ minHeight: 132, maxHeight: 260 })
        .barState(BarState.Auto)
        .margin({ top: 6 })
        .onChange((v: string) => {
          this.text = v;
        })
      Row() {
        Blank()
        Text(this.text.length + ' / 10000')
          .fontSize(11)
          .fontColor(this.text.length > 10000 ? Tokens.err : Tokens.dim2)
      }
      .width('100%')
      .margin({ top: 4, bottom: 16 })

      Text('附件')
        .fontSize(13)
        .fontColor(Tokens.dim)
        .width('100%')
        .margin({ bottom: 8 })
      Row() {
        this.attachBtn('添加截图', 'screenshot', () => {
          this.addShot();
        })
        this.attachBtn('日志与样本', 'log', () => {
          this.addLog();
        })
        this.attachBtn('录屏', 'video', () => {
          this.addVideo();
        })
      }
      .width('100%')

      if (this.pend.length > 0) {
        Column() {
          ForEach(this.pend, (p: Pending, i: number) => {
            Row() {
              Text(p.spec.label)
                .fontSize(11)
                .fontColor(Tokens.accentInk)
                .backgroundColor(Tokens.accent)
                .borderRadius(999)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              Text(p.name)
                .fontSize(12)
                .fontColor(Tokens.fg)
                .margin({ left: 8 })
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('×')
                .fontSize(15)
                .fontColor(Tokens.dim2)
                .padding({ left: 8, right: 2 })
                .onClick(() => {
                  this.dropPending(i);
                })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
          }, (p: Pending, i: number) => p.spec.kind + i + p.name)
        }
        .width('100%')
        .margin({ top: 8 })
      }

      // 运行环境：只告诉开发者版本与机型，方便复现
      Column() {
        Row() {
          Text('运行环境')
            .fontSize(13)
            .fontColor(Tokens.fg)
          Blank()
          Text('自动附带')
            .fontSize(11)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        Text(envLine())
          .fontSize(11)
          .fontColor(Tokens.dim)
          .width('100%')
          .margin({ top: 5 })
        Text('不含账号、对话内容、密钥与本地文件。')
          .fontSize(11)
          .fontColor(Tokens.dim2)
          .width('100%')
          .margin({ top: 3 })
        Text('复制诊断信息')
          .fontSize(12)
          .fontColor(Tokens.accent)
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .margin({ top: 9 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
          .onClick(() => {
            this.copyDiag();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .margin({ top: 16 })
      .borderRadius(Tokens.rCard)
      .backgroundColor(Tokens.surface)
      .border({ width: 1, color: Tokens.lineSoft })

      Row() {
        Column() {
          Text('工单有新动态时通知我')
            .fontSize(13)
            .fontColor(Tokens.fg)
            .width('100%')
          Text('回复或状态变化时提醒你，可随时关闭。')
            .fontSize(11)
            .fontColor(Tokens.dim2)
            .width('100%')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.notifyOn })
          .selectedColor(Tokens.accent)
          .onChange((on: boolean) => {
            this.notifyOn = on;
            setNotifyPref(on);
          })
      }
      .width('100%')
      .padding(14)
      .margin({ top: 10 })
      .borderRadius(Tokens.rCard)
      .backgroundColor(Tokens.surface)
      .border({ width: 1, color: Tokens.lineSoft })

      Column() {
        Row() {
          Text('联系方式')
            .fontSize(13)
            .fontColor(Tokens.fg)
          Text('选填')
            .fontSize(11)
            .fontColor(Tokens.dim2)
            .backgroundColor(Tokens.surface2)
            .borderRadius(999)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .margin({ left: 6 })
        }
        .width('100%')
        TextInput({ placeholder: 'QQ／邮箱，需要补充信息时联系你', text: this.contact })
          .fontSize(13)
          .backgroundColor(Color.Transparent)
          .padding({ left: 0, right: 0, top: 6, bottom: 6 })
          .onChange((v: string) => {
            this.contact = v;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .margin({ top: 10 })
      .borderRadius(Tokens.rCard)
      .backgroundColor(Tokens.surface)
      .border({ width: 1, color: Tokens.lineSoft })

      if (this.err !== '') {
        Text(this.err)
          .fontSize(12)
          .fontColor(Tokens.err)
          .width('100%')
          .margin({ top: 10 })
      }

      Text(this.busy ? '提交中…' : '提交反馈')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.accentInk)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(48)
        .borderRadius(999)
        .backgroundColor(this.busy ? Tokens.surface3 : Tokens.accentStrong)
        .margin({ top: 16 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          this.doSubmit();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  attachBtn(label: string, kind: string, act: () => void) {
    Row() {
      Text('+')
        .fontSize(13)
        .fontColor(Tokens.accent)
      Text(label)
        .fontSize(12)
        .fontColor(Tokens.dim)
        .margin({ left: 4 })
      if (this.countOf(kind) > 0) {
        Text('' + this.countOf(kind))
          .fontSize(11)
          .fontColor(Tokens.accentInk)
          .backgroundColor(Tokens.accent)
          .borderRadius(999)
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .margin({ left: 5 })
      }
    }
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .margin({ right: 8 })
    .borderRadius(999)
    .backgroundColor(Tokens.surface)
    .border({ width: 1, color: Tokens.lineSoft })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .onClick(act)
  }

  /** 我的反馈列表。 */
  @Builder
  mineBody() {
    Column() {
      if (this.rows.length === 0) {
        Column() {
          Text(this.loaded ? '还没有提过反馈。' : '正在读取…')
            .fontSize(13)
            .fontColor(Tokens.dim)
          if (this.loaded) {
            Text('去「提交反馈」写一条')
              .fontSize(13)
              .fontColor(Tokens.accent)
              .margin({ top: 10 })
              .onClick(() => {
                this.stage = 'submit';
              })
          }
        }
        .width('100%')
        .padding({ top: 60 })
      } else {
        ForEach(this.rows, (t: Ticket) => {
          Column() {
            Row() {
              Text(t.id)
                .fontSize(11)
                .fontColor(Tokens.dim2)
              Blank()
              Text(statusText(t.status))
                .fontSize(11)
                .fontColor(t.status === 'done' ? Tokens.ok : (t.status === 'wontfix' ? Tokens.dim2 : Tokens.accent))
                .backgroundColor(t.status === 'done' ? '#1A3DDC97' : Tokens.surface2)
                .borderRadius(999)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            }
            .width('100%')
            Text(t.title)
              .fontSize(13)
              .fontColor(Tokens.fg)
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })
            Text(kindName(t.kind) + ' · ' + timeText(t.created_at) + (t.replies.length > 0 ? ' · ' + t.replies.length + ' 条回复' : ''))
              .fontSize(11)
              .fontColor(Tokens.dim2)
              .width('100%')
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .margin({ bottom: 10 })
          .borderRadius(Tokens.rCard)
          .backgroundColor(Tokens.surface)
          .border({ width: 1, color: Tokens.lineSoft })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
          .onClick(() => {
            Haptics.tap();
            this.openDetail(t.id);
          })
        }, (t: Ticket) => t.id)
      }
      if (this.err !== '') {
        Text(this.err)
          .fontSize(12)
          .fontColor(Tokens.err)
          .width('100%')
          .margin({ top: 10 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 详情。 */
  @Builder
  detailBody() {
    Column() {
      if (this.cur !== null) {
        Column() {
          Row() {
            Text(this.cur.id)
              .fontSize(11)
              .fontColor(Tokens.dim2)
            Blank()
            Text(statusText(this.cur.status))
              .fontSize(11)
              .fontColor(this.cur.status === 'done' ? Tokens.ok : Tokens.accent)
              .backgroundColor(Tokens.surface2)
              .borderRadius(999)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          }
          .width('100%')
          Text(this.cur.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
            .width('100%')
            .margin({ top: 8 })
          if (this.cur.body.trim() !== this.cur.title.trim()) {
            Text(this.cur.body)
              .fontSize(13)
              .lineHeight(21)
              .fontColor(Tokens.fg)
              .width('100%')
              .margin({ top: 10 })
              .copyOption(CopyOptions.LocalDevice)
          }
          Text('运行环境：' + this.cur.env)
            .fontSize(11)
            .fontColor(Tokens.dim2)
            .width('100%')
            .margin({ top: 10 })
          Text('提交于 ' + timeText(this.cur.created_at))
            .fontSize(11)
            .fontColor(Tokens.dim2)
            .width('100%')
            .margin({ top: 3 })
          if (this.cur.files.length > 0) {
            Row() {
              ForEach(this.cur.files, (f: TicketFile) => {
                Text(f.name + ' · ' + sizeText(f.size))
                  .fontSize(11)
                  .fontColor(Tokens.dim)
                  .backgroundColor(Tokens.surface2)
                  .borderRadius(10)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .margin({ right: 6, top: 8 })
                  .maxLines(1)
              }, (f: TicketFile) => f.name)
            }
            .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .borderRadius(Tokens.rCard)
        .backgroundColor(Tokens.surface)
        .border({ width: 1, color: Tokens.lineSoft })

        Text('处理记录')
          .fontSize(13)
          .fontColor(Tokens.dim)
          .width('100%')
          .margin({ top: 16, bottom: 8 })
        if (this.cur.replies.length === 0) {
          Text('还没有回复。')
            .fontSize(12)
            .fontColor(Tokens.dim2)
            .width('100%')
        } else {
          ForEach(this.cur.replies, (r: TicketReply) => {
            Column() {
              Row() {
                Text(r.author === 'admin' ? '我' : '用户')
                  .fontSize(11)
                  .fontColor(r.author === 'admin' ? Tokens.accentInk : Tokens.dim)
                  .backgroundColor(r.author === 'admin' ? Tokens.accent : Tokens.surface2)
                  .borderRadius(999)
                  .padding({ left: 7, right: 7, top: 1, bottom: 1 })
                Text(timeText(r.at))
                  .fontSize(11)
                  .fontColor(Tokens.dim2)
                  .margin({ left: 8 })
                Blank()
              }
              .width('100%')
              Text(r.text)
                .fontSize(13)
                .lineHeight(20)
                .fontColor(Tokens.fg)
                .width('100%')
                .margin({ top: 6 })
                .copyOption(CopyOptions.LocalDevice)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(12)
            .margin({ bottom: 8 })
            .borderRadius(14)
            .backgroundColor(Tokens.surface2)
          }, (r: TicketReply, i: number) => '' + r.at + i)
        }

        Row() {
          Text('复制工单')
            .fontSize(13)
            .fontColor(Tokens.fg)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(44)
            .borderRadius(999)
            .backgroundColor(Tokens.surface2)
            .margin({ right: 8 })
            .onClick(() => {
              if (this.cur !== null) {
                this.copy(ticketText(this.cur), '工单');
              }
            })
          Text('刷新')
            .fontSize(13)
            .fontColor(Tokens.accentInk)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(44)
            .borderRadius(999)
            .backgroundColor(Tokens.accentStrong)
            .onClick(() => {
              if (this.cur !== null) {
                this.openDetail(this.cur.id);
              }
            })
        }
        .width('100%')
        .margin({ top: 16 })
      }
      if (this.note !== '') {
        Text(this.note)
          .fontSize(12)
          .fontColor(Tokens.ok)
          .width('100%')
          .margin({ top: 12 })
      }
      if (this.err !== '') {
        Text(this.err)
          .fontSize(12)
          .fontColor(Tokens.err)
          .width('100%')
          .margin({ top: 12 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private titleOf(): string {
    if (this.stage === 'submit') {
      return '提交反馈';
    }
    if (this.stage === 'mine') {
      return '我的反馈';
    }
    if (this.stage === 'detail') {
      return '工单详情';
    }
    return '反馈';
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Top }) {
        List() {
          ListItem() {
            Column() {
              if (this.stage === 'submit') {
                this.submitBody()
              } else if (this.stage === 'mine') {
                this.mineBody()
              } else if (this.stage === 'detail') {
                this.detailBody()
              } else {
                this.entryBody()
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 118, bottom: 120 })
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)

        this.fbFade()
        Column() {
          this.fbHeader(this.titleOf())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 54 })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg())
  }
}

/** 类型的中文名。 */
function kindName(kind: string): string {
  for (let i = 0; i < FEEDBACK_KINDS.length; i++) {
    if (FEEDBACK_KINDS[i].id === kind) {
      return FEEDBACK_KINDS[i].name;
    }
  }
  return kind;
}
