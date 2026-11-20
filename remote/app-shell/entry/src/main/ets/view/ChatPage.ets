import { Api, Message, SessionStats, TokenUsage, CatalogGroup, CatalogModel, EffortRef, ModelRef, ImageRef, AgentRef } from '../common/Api';
import { ImagePart, pickImages } from '../common/Images';
import { FilePart, pickFiles, readFile } from '../common/Files';
import { Tokens } from '../common/Tokens';
import { Mat } from '../common/Mat';
import { Haptics } from '../common/Haptics';
import { NavFx, NavFxSink } from '../common/NavFx';
import pasteboard from '@ohos.pasteboard';
import window from '@ohos.window';
import { KeyboardAvoidMode as KbMode } from '@ohos.arkui.UIContext';
import promptAction from '@ohos.promptAction';
import { ChatParam } from '../common/Types';
import { MdBlock, MdSeg, parseMd, parseInline } from '../common/Md';
import { texToText, looksLikeTex } from '../common/TeX';

interface DockItem {
  id: number;
  text: string;
}

interface Seg {
  t: string;
  b: boolean;
  c: boolean;
}

/** 去掉行首的 # / > 标记，把 - 和 * 列表换成圆点，压掉多余空行。 */
function cleanLines(src: string): string {
  const out: string[] = [];
  const lines: string[] = src.split('\n');
  for (let i = 0; i < lines.length; i++) {
    let l: string = lines[i];
    l = l.replace(/^#{1,6}\s+/, '');
    l = l.replace(/^>\s?/, '');
    l = l.replace(/^\s*[-*]\s+/, '· ');
    out.push(l);
  }
  return out.join('\n').replace(/\n{3,}/g, '\n\n');
}

/** 行内公式换成可读文字，货币符号等不满足条件的原样保留。 */
function mathify(raw: string): string {
  let s: string = raw;
  s = s.replace(/\\\((.+?)\\\)/g, (all: string, body: string): string => {
    return looksLikeTex(body) ? texToText(body) : all;
  });
  s = s.replace(/\$([^$\n]{1,300})\$/g, (all: string, body: string): string => {
    return looksLikeTex(body) ? texToText(body) : all;
  });
  return s;
}

/** 把 **粗体** 与 `行内代码` 切成片段，其余原样。 */
function inlineSegs(raw: string, out: Seg[]): void {
  const text: string = mathify(raw);
  const re: RegExp = /(\*\*[^*\n]+\*\*|`[^`\n]+`)/g;
  let last: number = 0;
  let m: RegExpExecArray | null = re.exec(text);
  while (m !== null) {
    if (m.index > last) {
      out.push({ t: text.slice(last, m.index), b: false, c: false });
    }
    const tok: string = m[0];
    if (tok.startsWith('**')) {
      out.push({ t: tok.slice(2, tok.length - 2), b: true, c: false });
    } else {
      out.push({ t: tok.slice(1, tok.length - 1), b: false, c: true });
    }
    last = m.index + tok.length;
    m = re.exec(text);
  }
  if (last < text.length) {
    out.push({ t: text.slice(last), b: false, c: false });
  }
}

function segments(src: string): Seg[] {
  const out: Seg[] = [];
  const parts: string[] = src.split('```');
  for (let i = 0; i < parts.length; i++) {
    let p: string = parts[i];
    if (i % 2 === 1) {
      const nl: number = p.indexOf('\n');
      if (nl >= 0) {
        p = p.slice(nl + 1);
      }
      ut_push(out, { t: p.trim(), b: false, c: true });
    } else {
      inlineSegs(cleanLines(p), out);
    }
  }
  return out;
}

function ut_push(arr: Seg[], s: Seg): void {
  arr.push(s);
}
function fmtNum(n: number): string {
  if (n >= 1000000000) return (n / 1000000000).toFixed(2) + 'B';
  if (n >= 1000000) return (n / 1000000).toFixed(2) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
  return '' + n;
}

function cmpRate(t: TokenUsage): string {
  const cached = t.cacheReadTokens;
  const total = t.uncachedInputTokens + cached;
  if (total <= 0) return '-';
  return Math.round((cached / total) * 100) + '%';
}


@Component
export struct ChatPage {
  api: Api = new Api('', '');
  param: ChatParam = { id: '', title: '' };
  @Consume('stack') stack: NavPathStack;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('themeDark') themeDark: boolean = true;
  // 键盘高度：改用 NONE 模式自己抬输入区，否则系统会把整页往上顶、顶栏跟着跑掉。
  @State private kbH: number = 0;
  // 先攒着：选好的图片/文件跟着下一条文字一起发，不再选完就单独发一轮。
  @State private pendImgs: ImagePart[] = [];
  @State private pendFiles: FilePart[] = [];
  private kwWin: window.Window | null = null;
  private kwCb: ((h: number) => void) | null = null;
  @State private msgs: Message[] = [];
  @State private total: number = 0;
  @State private loading: boolean = true;
  /** 上面还有更早的历史没取过来 */
  @State private hasMore: boolean = false;
  @State private loadingMore: boolean = false;
  @State private err: string = '';
  @State private draft: string = '';
  @State private sending: boolean = false;
  @State private running: boolean = false;
  // 生成中按发送时先停在这里：可改、可删、可插队
  @State private dock: DockItem[] = [];
  private dockSeq: number = 1;
  private scroller: Scroller = new Scroller();
  @State private stats: SessionStats | null = null;
  @State private statsOn: boolean = false;
  @State private groups: CatalogGroup[] = [];
  @State private groupsLoaded: boolean = false;
  @State private modelOn: boolean = false;
  /** 展示用的模型名（目录里的 name，不是 id） */
  @State private curModel: string = '';
  /** 选择器比较用的模型 id，跟展示名分开存，否则「当前」标记永远不亮 */
  @State private curModelId: string = '';
  @State private curEffort: string = '';
  @State private curProvider: string = '';
  @State private moreOn: boolean = false;
  @State private renaming: boolean = false;
  /** 改名后标题要立刻跟着变，param 不是状态变量，改它不会重绘 */
  @State private titleNow: string = '';
  /** 新会话日志还没落盘时的重试次数 */
  private retried: number = 0;
  @State private renameText: string = '';
  @State private toast: string = '';
  /** 轮询句柄：0 表示没在轮询。 */
  private poller: number = 0;
  @State private agents: AgentRef[] = [];
  /** 转场状态：由 Navigation 的 customNavContentTransition 按 navDestinationId 驱动。 */
  @State private fxTx: string = '0%';
  @State private fxOp: number = 1;
  @State private fxSc: number = 1;
  /** 生成中三点动画当前亮的那颗 */
  @State private dotOn: number = 0;
  private dotTimer: number = 0;
  /** 页面是否还在栈上：异步回调返回后要先查这个，避免给已销毁的页面写状态 */
  private alive: boolean = false;
  /** 代次：每次进出页面 +1，旧请求的结果一律丢弃 */
  private gen: number = 0;
  /** 新会话 404 时的重试句柄，离页要清掉 */
  private retryTimer: number = 0;
  private fxId: string = '';
  private fxSink: NavFxSink | undefined = undefined;

  /** 键盘弹出时只抬输入区，顶栏钉住不动。 */
  private pinKeyboard(): void {
    try {
      this.getUIContext().setKeyboardAvoidMode(KbMode.NONE);
    } catch (e) {
      console.info('DSH_KB avoid mode skipped: ' + JSON.stringify(e));
    }
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      this.kwWin = w;
      this.kwCb = (h: number) => {
        const vp: number = h > 0 ? px2vp(h) : 0;
        if (Math.abs(vp - this.kbH) > 0.5) {
          this.kbH = vp;
        }
      };
      w.on('keyboardHeightChange', this.kwCb);
    }).catch((e: Error) => {
      console.info('DSH_KB window failed: ' + e.message);
    });
  }

  private unpinKeyboard(): void {
    if (this.kwWin !== null && this.kwCb !== null) {
      this.kwWin.off('keyboardHeightChange', this.kwCb);
    }
    this.kwWin = null;
    this.kwCb = null;
    this.kbH = 0;
    try {
      this.getUIContext().setKeyboardAvoidMode(KbMode.OFFSET);
    } catch (e) {
      console.info('DSH_KB restore skipped: ' + JSON.stringify(e));
    }
  }

  aboutToAppear(): void {
    this.alive = true;
    this.gen++;
    this.pinKeyboard();
    this.titleNow = this.param.title;
    // 让外壳的完成通知知道「这个会话正开着」，别给自己正在看的会话弹通知
    AppStorage.setOrCreate('openSession', this.param.id);
    this.curModel = this.param.model ?? '';
    this.curEffort = this.param.effort ?? '';
    this.load();
    this.loadModels();
    this.loadAgents();
    // 这个会话可能在电脑上被别的入口继续推进，手机端不能只靠手动刷新
    this.startPolling();
    this.dotTimer = setInterval(() => {
      if (this.running) {
        this.dotOn = (this.dotOn + 1) % 3;
      }
    }, 380);
  }

  /** 这个会话的子智能体：放在聊天页顶部一条横向成员条里。 */
  private async loadAgents(): Promise<void> {
    try {
      const rows = await this.api.sessions();
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].id === this.param.id) {
          const a = rows[i].agents;
          if (a !== undefined && a.subagents.length > 0) {
            this.agents = a.subagents;
          }
          break;
        }
      }
    } catch (e) {
      // 拿不到就不显示成员条，不影响聊天
    }
  }

  aboutToDisappear(): void {
    this.unpinKeyboard();
    AppStorage.setOrCreate('openSession', '');
    // 代次 +1 让在飞的请求结果全部作废，重试也要停
    this.alive = false;
    this.gen++;
    if (this.retryTimer !== 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = 0;
    }
    this.stopPolling();
    if (this.dotTimer !== 0) {
      clearInterval(this.dotTimer);
      this.dotTimer = 0;
    }
    const s = this.fxSink;
    if (s !== undefined) {
      NavFx.unregister(this.fxId, s);
    }
  }

  /** 把本页的转场状态登记给 Navigation。 */
  private bindFx(id: string): void {
    const sink: NavFxSink = {
      apply: (tx: string, op: number, sc: number): void => {
        this.fxTx = tx;
        this.fxOp = op;
        this.fxSc = sc;
      }
    };
    this.fxId = id;
    this.fxSink = sink;
    NavFx.register(id, sink);
  }

  private startPolling(): void {
    this.stopPolling();
    this.schedulePoll(1200);
  }

  /** 生成中 1.2 秒拉一次（看起来像在流式吐字），空闲时退到 4 秒省电。 */
  private schedulePoll(ms: number): void {
    if (!this.alive) return;
    this.poller = setTimeout(() => {
      this.pollOnce();
    }, ms);
  }

  private stopPolling(): void {
    if (this.poller !== 0) {
      clearTimeout(this.poller);
      this.poller = 0;
    }
  }

  /** 只取新消息追加，避免每 4 秒搬几十 KB 还把滚动位置打回底部。 */
  private async pollOnce(): Promise<void> {
    if (!this.alive) return;
    if (this.sending || this.loading) {
      this.schedulePoll(1200);
      return;
    }
    const g: number = this.gen;
    const last: number = this.msgs.length > 0 ? this.msgs[this.msgs.length - 1].seq : 0;
    try {
      const r = await this.api.messagesSince(this.param.id, last);
      // 请求飞行途中用户可能已经退出（或换了一轮），此时既不能写状态也不能再排拍子
      if (!this.alive || g !== this.gen) return;
      const was: boolean = this.running;
      this.running = r.running === true;
      if (was && !this.running && this.dock.length > 0) {
        this.flushDock();
      }
      // 轮询能拿到数据就说明日志回来了，把之前那次重试失败的红字清掉
      if (this.err !== '') {
        this.err = '';
      }
      if (r.total !== this.total || r.messages.length > 0) {
        const grown: Message[] = this.msgs.concat(this.freshOnly(r.messages));
        this.msgs = grown;
        this.total = r.total;
        this.stats = r.stats ?? null;
        setTimeout(() => {
          this.scroller.scrollEdge(Edge.Bottom);
        }, 80);
      }
    } catch (e) {
      // 轮询失败不打扰用户，等下一次
    }
    this.schedulePoll(this.running ? 1200 : 4000);
  }

  private async load(): Promise<void> {
    const g: number = this.gen;
    try {
      const r = await this.api.messages(this.param.id, 60);
      if (!this.alive || g !== this.gen) return;
      this.msgs = r.messages;
      this.total = r.total;
      this.stats = r.stats ?? null;
      this.running = r.running === true;
      this.hasMore = r.messages.length < r.total;
      this.err = '';
      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 80);
    } catch (e) {
      const msg: string = (e as Error).message;
      // 刚新建的会话，宿主那边日志文件还没落盘，会先 404 一次；这不算错误，
      // 空着等轮询把内容接上就行，别给用户糊一屏红字。
      if (!this.alive || g !== this.gen) return;
      if (msg.indexOf('session log not found') >= 0 && this.retried < 6) {
        this.retried++;
        this.err = '';
        this.retryTimer = setTimeout(() => {
          this.retryTimer = 0;
          if (this.alive) this.load();
        }, 500);
      } else {
        this.err = msg;
      }
    } finally {
      this.loading = false;
    }
  }

  /** 只保留本地还没有的 seq：load() 与轮询并发时，同一条消息不能出现两次。 */
  private freshOnly(incoming: Message[]): Message[] {
    if (this.msgs.length === 0) return incoming;
    let maxSeq: number = this.msgs[this.msgs.length - 1].seq;
    const out: Message[] = [];
    for (const m of incoming) {
      if (m.seq > maxSeq) {
        out.push(m);
        maxSeq = m.seq;
      }
    }
    return out;
  }

  /** 向上补一页更早的历史，接在现有消息前面。 */
  private async loadOlder(): Promise<void> {
    if (this.loadingMore || this.msgs.length === 0) return;
    this.loadingMore = true;
    try {
      const oldest: number = this.msgs[0].seq;
      const r = await this.api.messagesBefore(this.param.id, oldest, 60);
      if (r.messages.length === 0) {
        this.hasMore = false;
      } else {
        this.msgs = r.messages.concat(this.msgs);
        this.hasMore = this.msgs.length < r.total;
      }
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.loadingMore = false;
    }
  }

  /** 电脑管理里选的「忙碌时发送」：queue 排队等这轮跑完，steer 插话替掉。 */
  private sendMode(): string {
    const m = AppStorage.get<string>('sendMode');
    return m === 'steer' ? 'steer' : 'queue';
  }

  private async send(): Promise<void> {
    const text = this.draft.trim();
    if ((text === '' && !this.hasPend()) || this.sending) return;
    if (this.running && text !== '') {
      // 生成中：不打断当前轮，先停泊，等用户插队或这一轮结束后自动补发
      this.dock = this.dock.concat([{ id: this.dockSeq++, text: text }]);
      this.draft = '';
      Haptics.tap();
      this.toast = '已放入待发送';
      setTimeout(() => {
        this.toast = '';
      }, 2000);
      return;
    }
    Haptics.soft();
    this.sending = true;
    const imgs: ImagePart[] = this.pendImgs;
    const files: FilePart[] = this.pendFiles;
    this.draft = '';
    try {
      if (imgs.length > 0) {
        // 图片和文字一起进同一条消息（服务端 content = [text, ...image]）。
        const n = await this.api.uploadImages(this.param.id, text, imgs);
        this.toast = '已发送 ' + String(n) + ' 张图片';
      } else if (files.length > 0) {
        const n = await this.api.uploadFiles(this.param.id, text, files);
        this.toast = '已上传 ' + String(n) + ' 个文件';
      } else {
        await this.api.send(this.param.id, text, this.sendMode());
      }
      this.pendImgs = [];
      this.pendFiles = [];
      if (this.toast !== '') {
        setTimeout(() => {
          this.toast = '';
        }, 2400);
      }
      await this.load();
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.sending = false;
    }
  }

  private dropDock(id: number): void {
    this.dock = this.dock.filter((it: DockItem) => it.id !== id);
    Haptics.soft();
  }

  private editDock(it: DockItem): void {
    this.draft = it.text;
    this.dock = this.dock.filter((d: DockItem) => d.id !== it.id);
    Haptics.tap();
  }

  /** 立刻插话：用 steer 直接送进当前这一轮。 */
  private async jumpDock(it: DockItem): Promise<void> {
    this.dock = this.dock.filter((d: DockItem) => d.id !== it.id);
    Haptics.tap();
    try {
      await this.api.send(this.param.id, it.text, 'steer');
      await this.load();
    } catch (e) {
      this.err = (e as Error).message;
      this.dock = this.dock.concat([it]);
    }
  }

  /** 这一轮跑完后，把停泊里最早的一条按设置的模式补发出去。 */
  private async flushDock(): Promise<void> {
    if (this.dock.length === 0 || this.running || this.sending) return;
    const first: DockItem = this.dock[0];
    this.dock = this.dock.filter((d: DockItem) => d.id !== first.id);
    try {
      await this.api.send(this.param.id, first.text, this.sendMode());
      await this.load();
    } catch (e) {
      this.err = (e as Error).message;
      this.dock = this.dock.concat([first]);
    }
  }

  /** 打开系统相册选图，先挂到输入框上方，等用户点发送再和文字一起发。 */
  private async pickAttach(): Promise<void> {
    if (this.sending) return;
    try {
      const room: number = 9 - this.pendImgs.length - this.pendFiles.length;
      if (room <= 0) {
        this.toast = '一次最多 9 个附件';
        setTimeout(() => {
          this.toast = '';
        }, 2000);
        return;
      }
      const parts: ImagePart[] = await pickImages(room);
      if (parts.length === 0) {
        return;
      }
      this.pendImgs = this.pendImgs.concat(parts);
      Haptics.tap();
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  /** 打开系统文件选择器，同样只挂到待发列表，发送时一起传到电脑。 */
  private async pickAttachFile(): Promise<void> {
    if (this.sending) return;
    try {
      const room: number = 9 - this.pendImgs.length - this.pendFiles.length;
      if (room <= 0) {
        this.toast = '一次最多 9 个附件';
        setTimeout(() => {
          this.toast = '';
        }, 2000);
        return;
      }
      const uris: string[] = await pickFiles(room);
      if (uris.length === 0) {
        return;
      }
      const parts: FilePart[] = [];
      for (const uri of uris) {
        const one = readFile(uri);
        if (one !== undefined) {
          parts.push(one);
        }
      }
      if (parts.length === 0) {
        this.err = '选中的文件为空或超过 8 MB';
        return;
      }
      this.pendFiles = this.pendFiles.concat(parts);
      Haptics.tap();
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  private hasPend(): boolean {
    return this.pendImgs.length > 0 || this.pendFiles.length > 0;
  }

  private dropImg(i: number): void {
    const next: ImagePart[] = [];
    for (let k = 0; k < this.pendImgs.length; k++) {
      if (k !== i) next.push(this.pendImgs[k]);
    }
    this.pendImgs = next;
  }

  private dropFile(i: number): void {
    const next: FilePart[] = [];
    for (let k = 0; k < this.pendFiles.length; k++) {
      if (k !== i) next.push(this.pendFiles[k]);
    }
    this.pendFiles = next;
  }

  /** 让服务端停止这一轮；不受理时把原因留在错误条上。 */
  private async doStop(): Promise<void> {
    this.moreOn = false;
    try {
      const ok = await this.api.stop(this.param.id);
      if (!ok) {
        this.err = '这一轮已经不在了，或服务端没有受理';
      }
      await this.load();
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  private async doRename(): Promise<void> {
    const t = this.renameText.trim();
    if (t === '') {
      this.err = '名字不能为空';
      return;
    }
    try {
      await this.api.rename(this.param.id, t);
      this.titleNow = t;
      this.renaming = false;
      this.moreOn = false;
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  /** 长按气泡复制：手机上最常见的「我想把这段发给别人」。 */
  private copyMessage(m: Message): void {
    if (m.text === '') return;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, m.text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '已复制', duration: 1400 });
      }).catch(() => {
        promptAction.showToast({ message: '复制失败', duration: 1600 });
      });
    } catch (e) {
      promptAction.showToast({ message: '复制失败', duration: 1600 });
    }
  }

  /** 行内片段：粗体 / 行内代码 */
  @Builder
  mdText(segs: MdSeg[], size: number, lineH: number) {
    Text() {
      ForEach(segs, (s: MdSeg, i: number) => {
        Span(s.t)
          .fontWeight(s.b ? FontWeight.Bold : FontWeight.Normal)
          .fontFamily(s.c ? 'monospace' : 'HarmonyOS Sans')
          .fontColor(s.c ? Tokens.accent : Tokens.fg)
      }, (s: MdSeg, i: number) => i + '_' + s.t.length + (s.b ? 'b' : '') + (s.c ? 'c' : ''))
    }
    .fontSize(size)
    .lineHeight(lineH)
    .width('100%')
  }

  /** 表格：首行淡蓝底，单元格细线，可横向滚动 */
  /** 独立公式：居中、等宽感，两侧留白，避免跟正文黏在一起。 */
  @Builder
  mdMath(b: MdBlock) {
    Row() {
      Text(b.text)
        .fontSize(15)
        .lineHeight(26)
        .fontColor(Tokens.fg)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 6, bottom: 10 })
  }

  @Builder
  mdTable(b: MdBlock) {
    Scroll() {
      Column() {
        Row() {
          ForEach(b.head, (h: string, ci: number) => {
            Text() {
              ForEach(parseInline(h), (s: MdSeg, si: number) => {
                Span(s.t)
                  .fontWeight(s.b ? FontWeight.Bold : FontWeight.Medium)
                  .fontFamily(s.c ? 'monospace' : 'HarmonyOS Sans')
                  .fontColor(s.c ? Tokens.accent : Tokens.fg)
              }, (s: MdSeg, si: number) => 'th' + ci + '_' + si)
            }
            .fontSize(12.5)
            .width(150)
            .padding(8)
            .border({ width: 0.5, color: Tokens.line })
            .backgroundColor(Tokens.accentSoft)
          }, (h: string, ci: number) => 'th' + ci)
        }
        ForEach(b.rows, (r: string[], ri: number) => {
          Row() {
            ForEach(r, (c: string, ci: number) => {
              Text() {
                ForEach(parseInline(c), (s: MdSeg, si: number) => {
                  Span(s.t)
                    .fontWeight(s.b ? FontWeight.Bold : FontWeight.Normal)
                    .fontFamily(s.c ? 'monospace' : 'HarmonyOS Sans')
                    .fontColor(s.c ? Tokens.accent : Tokens.fg)
                }, (s: MdSeg, si: number) => 'td' + ri + '_' + ci + '_' + si)
              }
              .fontSize(12.5)
              .width(150)
              .padding(8)
              .border({ width: 0.5, color: Tokens.line })
            }, (c: string, ci: number) => 'td' + ri + '_' + ci)
          }
        }, (r: string[], ri: number) => 'tr' + ri)
      }
      .alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .borderRadius(12)
    .border({ width: 0.5, color: Tokens.line })
    .margin({ top: 8, bottom: 4 })
  }

  @Builder
  mdBlock(b: MdBlock, idx: number) {
    if (b.kind === 'h1') {
      this.mdText(b.segs, 19, 27)
    } else if (b.kind === 'h2') {
      this.mdText(b.segs, 17, 25)
    } else if (b.kind === 'h3') {
      this.mdText(b.segs, 15.5, 23)
    } else if (b.kind === 'bullet') {
      Row() {
        Text('·')
          .fontSize(15)
          .fontColor(Tokens.accent)
          .width(12)
        this.mdText(b.segs, 15, 24)
      }
      .alignItems(VerticalAlign.Top)
      .padding({ left: 2 })
    } else if (b.kind === 'quote') {
      Row() {
        Row()
          .width(3)
          .height('100%')
          .backgroundColor(Tokens.accent)
          .borderRadius(2)
          .margin({ right: 10 })
        this.mdText(b.segs, 14.5, 23)
      }
      .alignItems(VerticalAlign.Top)
      .margin({ top: 4, bottom: 4 })
    } else if (b.kind === 'code') {
      Column() {
        Text(b.text)
          .fontSize(12.5)
          .fontFamily('monospace')
          .fontColor(Tokens.fg)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .padding(12)
      .backgroundColor(Tokens.surface2)
      .borderRadius(12)
      .margin({ top: 6, bottom: 6 })
      .width('100%')
    } else if (b.kind === 'table') {
      this.mdTable(b)
    } else if (b.kind === 'math') {
      this.mdMath(b)
    } else {
      this.mdText(b.segs, 15, 24)
    }
  }

  @Builder
  bubble(m: Message) {
    if (m.role === 'user') {
      // 用户气泡：右侧蓝底白字，右下角收小一点，形成「指向自己」的方向感
      Column() {
      Row() {
        Column() {
          if (m.images !== undefined && m.images.length > 0) {
            Column({ space: 8 }) {
              ForEach(m.images, (img: ImageRef) => {
                Image(this.api.attachmentUrl(img))
                  .width(this.imageWidth(img))
                  .height(this.imageHeight(img))
                  .objectFit(ImageFit.Contain)
                  .borderRadius(14)
                  .backgroundColor(Tokens.surface2)
                  .alt($r('app.media.app_icon'))
              }, (img: ImageRef) => img.id)
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ bottom: m.text !== '' ? 8 : 0 })
          }
          if (m.text !== '') {
            Text() {
              ForEach(parseMd(m.text), (b: MdBlock, i: number) => {
                if (i > 0) {
                  Span('\n')
                }
                Span(b.text)
              }, (b: MdBlock, i: number) => 'u' + i)
            }
            .fontSize(15)
            .lineHeight(24)
            .fontColor('#FFFFFF')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 15, right: 15, top: 11, bottom: 11 })
        .constraintSize({ maxWidth: 300 })
        .backgroundColor(Tokens.accent)
        .borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 })
        .shadow({ radius: 16, color: Tokens.accentSoft, offsetY: 6 })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)

      Row() {
        Image($r('app.media.ic_copy'))
          .width(14)
          .height(14)
          .fillColor(Tokens.dim2)
          .objectFit(ImageFit.Contain)
        Text('复制')
          .fontSize(11)
          .fontColor(Tokens.dim2)
          .margin({ left: 4 })
      }
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .margin({ top: 6 })
      .borderRadius(10)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
      .onClick(() => {
        this.copyMessage(m);
      })
      }
      .width('100%')
      .alignItems(HorizontalAlign.End)
      .margin({ bottom: 20 })
    } else {
      // 助手气泡：模型名 + 头像在上，正文装在卡片里
      Column() {
        Row() {
          Image($r('app.media.app_icon'))
            .width(20)
            .height(20)
            .borderRadius(6)
            .objectFit(ImageFit.Cover)
            .margin({ right: 7 })
          Text(this.curModel !== '' ? this.curModel : 'DSH')
            .fontSize(11)
            .fontColor(Tokens.dim2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .margin({ bottom: 6 })

        Column() {
          if (m.images !== undefined && m.images.length > 0) {
            Column({ space: 8 }) {
              ForEach(m.images, (img: ImageRef) => {
                Image(this.api.attachmentUrl(img))
                  .width(this.imageWidth(img))
                  .height(this.imageHeight(img))
                  .objectFit(ImageFit.Contain)
                  .borderRadius(14)
                  .backgroundColor(Tokens.surface2)
                  .alt($r('app.media.app_icon'))
              }, (img: ImageRef) => img.id)
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ bottom: m.text !== '' ? 8 : 0 })
          }
          if (m.text !== '') {
            ForEach(parseMd(m.text), (b: MdBlock, i: number) => {
              this.mdBlock(b, i)
            }, (b: MdBlock, i: number) => 'b' + i + '_' + b.kind + b.text.length)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(Tokens.surface)
        .borderRadius(20)
        .border({ width: 1, color: Tokens.lineSoft })
        .width('100%')

        Row() {
          Image($r('app.media.ic_copy'))
            .width(14)
            .height(14)
            .fillColor(Tokens.dim2)
            .objectFit(ImageFit.Contain)
          Text('复制')
            .fontSize(11)
            .fontColor(Tokens.dim2)
            .margin({ left: 4 })
        }
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .margin({ top: 6 })
        .borderRadius(10)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.copyMessage(m);
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 20 })
    }
  }

  /** 生成中的占位气泡：三颗点依次亮，配合 1.2 秒轮询看起来像在吐字。 */
  @Builder
  typingBubble() {
    Column() {
      Row() {
        Image($r('app.media.app_icon'))
          .width(20)
          .height(20)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .margin({ right: 7 })
        Text(this.curModel !== '' ? this.curModel : 'DSH')
          .fontSize(11)
          .fontColor(Tokens.dim2)
      }
      .width('100%')
      .margin({ bottom: 6 })

      Row({ space: 5 }) {
        ForEach([0, 1, 2], (i: number) => {
          Circle()
            .width(6)
            .height(6)
            .fill(Tokens.accent)
            .opacity(this.dotOn === i ? 1 : 0.28)
        }, (i: number) => 'dot' + i)
      }
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .backgroundColor(Tokens.surface)
      .borderRadius(18)
      .border({ width: 1, color: Tokens.lineSoft })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 20 })
  }

  /** 按原始宽高比算出图片宽度（上限 280vp），高度随之收放。 */
  private imageWidth(img: ImageRef): number {
    return img.width > 0 && img.height > 0 && img.width < 280 ? img.width : 280;
  }

  private imageHeight(img: ImageRef): number {
    if (img.width > 0 && img.height > 0) {
      const w: number = this.imageWidth(img);
      return Math.round((w * img.height) / img.width);
    }
    return 180;
  }

  /** 用目录里的展示名换掉裸 id，找不到就原样返回。 */
  private labelOf(id: string): string {
    for (const g of this.groups) {
      for (const m of g.models) {
        if (m.id === id) return m.name;
      }
    }
    return id;
  }

  private async loadModels(): Promise<void> {
    try {
      const c = await this.api.models(this.param.id);
      this.groups = c.groups ?? [];
      this.groupsLoaded = true;
      const cur: ModelRef | null = c.current;
      if (cur !== null && cur !== undefined && (cur.model ?? '') !== '') {
        this.curModelId = cur.model ?? '';
        this.curModel = this.labelOf(cur.model ?? '');
        this.curEffort = cur.reasoningEffort ?? '';
        this.curProvider = cur.provider ?? '';
      } else {
        // 目录没给 current 时（会话还没选过模型），退到会话行里记录的真实模型，
        // 否则顶部一直显示「共 N 条」，跟 CubeAgent 的副标题对不上。
        try {
          const rows = await this.api.sessions();
          for (const r of rows) {
            if (r.id === this.param.id && r.model !== undefined && r.model !== null) {
              this.curModelId = r.model.model;
              this.curModel = this.labelOf(r.model.model);
              this.curEffort = r.model.reasoningEffort ?? '';
              this.curProvider = r.model.provider;
              break;
            }
          }
        } catch (e2) {
        }
      }
    } catch (e) {
      this.err = (e as Error).message;
      this.groupsLoaded = true;
    }
  }

  private openModels(): void {
    this.modelOn = true;
    if (!this.groupsLoaded) {
      this.loadModels();
    }
  }

  private async pick(g: string, m: string, effort: string, name: string): Promise<void> {
    try {
      await this.api.selectModel(this.param.id, g, m, effort);
      this.curModelId = m;
      this.curModel = this.labelOf(m);
      this.curEffort = effort;
      this.modelOn = false;
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  @Builder
  modelSheet() {
    Column() {
      Blank()
        .width('100%')
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.modelOn = false;
        })
      Column() {
        Row() {
          Text('更换模型')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
          Text('关闭')
            .fontSize(13)
            .fontColor(Tokens.dim)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.modelOn = false;
            })
        }
        .width('100%')
        .padding({ bottom: 10 })

        if (!this.groupsLoaded) {
          Row() {
            LoadingProgress().width(18).height(18).color(Tokens.dim2)
            Text('读取模型目录…').fontSize(13).fontColor(Tokens.dim2).margin({ left: 8 })
          }
          .height(80)
        } else {
          Scroll() {
            Column() {
              ForEach(this.groups, (g: CatalogGroup) => {
                Column() {
                  Text(g.name)
                    .fontSize(11)
                    .fontColor(Tokens.dim2)
                    .letterSpacing(1.2)
                    .width('100%')
                    .margin({ top: 14, bottom: 8 })
                  ForEach(g.models, (m: CatalogModel) => {
                    Column() {
                      Row() {
                        Text(m.name)
                          .fontSize(15)
                          .fontColor(Tokens.fg)
                          .layoutWeight(1)
                        if (this.curModelId === m.id) {
                          Text('当前')
                            .fontSize(10)
                            .fontColor(Tokens.accent)
                            .borderRadius(999)
                            .border({ width: 1, color: Tokens.accent })
                            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                        }
                      }
                      .width('100%')

                      if (m.efforts.length > 0) {
                        Row() {
                          ForEach(m.efforts, (e: EffortRef) => {
                            Text(e.name)
                              .fontSize(11)
                              .fontColor(this.curModelId === m.id && this.curEffort === e.id ? Tokens.accentInk : Tokens.dim)
                              .backgroundColor(this.curModelId === m.id && this.curEffort === e.id ? Tokens.accent : Tokens.surface3)
                              .borderRadius(999)
                              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                              .margin({ right: 6 })
                              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                              .onClick(() => {
                                Haptics.tap();
                                this.pick(g.id, m.id, e.id, m.name);
                              })
                          }, (e: EffortRef) => e.id)
                        }
                        .width('100%')
                        .margin({ top: 9 })
                      }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .padding({ top: 10, bottom: 10 })
                    .width('100%')
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                    .onClick(() => {
                      this.pick(g.id, m.id, m.defaultEffort, m.name);
                    })
                  }, (m: CatalogModel) => m.id)
                }
                .width('100%')
              }, (g: CatalogGroup) => g.id)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('92%')
      .padding({ left: 20, right: 20, top: 18, bottom: 10 })
      .backgroundColor(Tokens.surface)
      .borderRadius({ topLeft: 28, topRight: 28 })
      .border({ width: 1, color: Tokens.line })
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 60 })))
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
  }

  @Builder
  kvRow(k: string, v: string) {
    Row() {
      Text(k)
        .fontSize(13)
        .fontColor(Tokens.dim)
        .layoutWeight(1)
      Text(v)
        .fontSize(13.5)
        .fontColor(Tokens.fg)
    }
    .width('100%')
    .padding({ top: 7, bottom: 7 })
  }

  @Builder
  moreSheet() {
    Column() {
      Blank()
        .width('100%')
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.moreOn = false;
          this.renaming = false;
        })

      Column() {
        Row() {
          Text('会话操作')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
          Text('关闭')
            .fontSize(13)
            .fontColor(Tokens.dim)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.moreOn = false;
              this.renaming = false;
            })
        }
        .width('100%')
        .padding({ bottom: 8 })

        if (this.renaming) {
          TextInput({ text: this.renameText, placeholder: '新的会话名字' })
            .fontSize(14)
            .fontColor(Tokens.fg)
            .placeholderColor(Tokens.dim2)
            .backgroundColor(Tokens.surface2)
            .borderRadius(14)
            .height(44)
            .onChange((v: string) => {
              this.renameText = v;
            })
          Row() {
            Text('取消')
              .fontSize(14)
              .fontColor(Tokens.dim)
              .padding({ top: 12, bottom: 4 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
              .onClick(() => {
                this.renaming = false;
              })
            Blank()
            Text('保存')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.accent)
              .padding({ top: 12, bottom: 4 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
              .onClick(() => {
                this.doRename();
              })
          }
          .width('100%')
        } else {
          Text('停止生成')
            .width('100%')
            .fontSize(15)
            .fontColor(Tokens.fg)
            .padding({ top: 14, bottom: 14 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.doStop();
            })
          Divider()
            .color(Tokens.lineSoft)
          Text('重命名会话')
            .width('100%')
            .fontSize(15)
            .fontColor(Tokens.fg)
            .padding({ top: 14, bottom: 14 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.renameText = this.titleNow;
              this.renaming = true;
            })
          Divider()
            .color(Tokens.lineSoft)
          Text('上传文件')
            .width('100%')
            .fontSize(15)
            .fontColor(Tokens.fg)
            .padding({ top: 14, bottom: 14 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.moreOn = false;
              this.pickAttachFile();
            })
          Divider()
            .color(Tokens.lineSoft)
          Text('预设与权限')
            .width('100%')
            .fontSize(15)
            .fontColor(Tokens.fg)
            .padding({ top: 14, bottom: 14 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.moreOn = false;
              const p: ChatParam = { id: this.param.id, title: this.param.title };
              this.stack.pushPathByName('presets', p);
            })
          Divider()
            .color(Tokens.lineSoft)
          Text('刷新')
            .width('100%')
            .fontSize(15)
            .fontColor(Tokens.fg)
            .padding({ top: 14, bottom: 14 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.moreOn = false;
              this.load();
            })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 26 })
      .backgroundColor(Tokens.surface)
      .borderRadius({ topLeft: 22, topRight: 22 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  statsSheet() {
    Column() {
      Blank()
        .width('100%')
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.statsOn = false;
        })
      Column() {
        Row() {
          Text('运行统计')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
          Text('关闭')
            .fontSize(13)
            .fontColor(Tokens.dim)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.statsOn = false;
            })
        }
        .width('100%')
        .padding({ bottom: 6 })

        if (this.stats === null) {
          Row() {
            Text('这个会话还没有统计数据').fontSize(13).fontColor(Tokens.dim2)
          }
          .height(70)
        } else {
          this.kvRow('轮次', '' + this.stats.turns)
          this.kvRow('步骤', '' + this.stats.steps)
          this.kvRow('工具调用', '' + this.stats.toolCalls)
          this.kvRow('输入（未缓存）', fmtNum(this.stats.tokens.uncachedInputTokens))
          this.kvRow('缓存读取', fmtNum(this.stats.tokens.cacheReadTokens))
          this.kvRow('输出', fmtNum(this.stats.tokens.outputTokens))
          Divider().color(Tokens.line).margin({ top: 8, bottom: 8 })
          this.kvRow('Token 合计', fmtNum(this.stats.tokens.uncachedInputTokens + this.stats.tokens.cacheReadTokens + this.stats.tokens.outputTokens))
          this.kvRow('缓存命中率', cmpRate(this.stats.tokens))
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 28 })
      .backgroundColor(Tokens.surface)
      .borderRadius({ topLeft: 24, topRight: 24 })
      .border({ width: 1, color: Tokens.line })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
  }

  @Builder
  headerBar() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(26)
          .fontColor(Tokens.fg)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .borderRadius(999)
          .backgroundColor(Tokens.glassFloat)
          .backdropBlur(18)
          .border({ width: 1, color: Tokens.glassLine })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => this.stack.pop())

        Row() {
          Column() {
            Text(this.titleNow !== '' ? this.titleNow : '会话')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.fg)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.curModel !== '' ? this.curModel : (this.loading ? '加载中…' : ('共 ' + this.total + ' 条')))
              .fontSize(10.5)
              .fontColor(Tokens.dim)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 1 })
          }
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 14, right: 14 })
        }
        .height(46)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .margin({ left: 8, right: 8 })
        .backgroundColor(Tokens.glassFloat)
        .backdropBlur(18)
        .borderRadius(999)
        .border({ width: 1, color: Tokens.glassLine })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
        .onClick(() => {
          this.openModels();
        })

        Text('▤')
          .fontSize(15)
          .fontColor(Tokens.dim)
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .borderRadius(999)
          .backgroundColor(Tokens.glassFloat)
          .backdropBlur(18)
          .border({ width: 1, color: Tokens.glassLine })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => {
            this.statsOn = true;
          })

        Text('⋯')
          .fontSize(16)
          .fontColor(Tokens.dim)
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .borderRadius(999)
          .backgroundColor(Tokens.glassFloat)
          .backdropBlur(18)
          .border({ width: 1, color: Tokens.glassLine })
          .margin({ left: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => {
            this.moreOn = true;
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12 })

      // 顶部成员条：这个会话的子智能体（横向滚动，不单独成页）
      if (this.agents.length > 0) {
        Scroll() {
          Row() {
            Text('智能体')
              .fontSize(10.5)
              .fontColor(Tokens.dim2)
              .margin({ right: 8 })
            ForEach(this.agents, (a: AgentRef) => {
              Row() {
                Text(a.label)
                  .fontSize(11.5)
                  .fontColor(Tokens.fg)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (a.mode === 'continuable') {
                  Text('·')
                    .fontSize(11.5)
                    .fontColor(Tokens.accent)
                    .margin({ left: 3 })
                }
              }
              .constraintSize({ maxWidth: 168 })
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .margin({ right: 6 })
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(999)
            }, (a: AgentRef) => a.id)
          }
          .padding({ left: 16, right: 8, top: 6, bottom: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
    }
    .width('100%')
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        // 底色画成栈里的第一层，而不是 NavDestination 的 backgroundColor：
        // NavDestination 自带不透明底色时，子节点的 backgroundEffect 会糊到那层底色上，
        // 看起来就是"完全没模糊"。
        Row()
          .width('100%')
          .height('100%')
          .backgroundColor(this.themeBg)
          .hitTestBehavior(HitTestMode.None)

        // 顶部一层极淡的蓝光，跟列表页保持同一套沉浸感
        Row()
          .width('100%')
          .height(220)
          .linearGradient({
            angle: 180,
            colors: [[Tokens.accentGlow, 0.0], ['#00000000', 1.0]]
          })
          .position({ x: 0, y: 0 })
          .hitTestBehavior(HitTestMode.None)

          List({ space: 0, scroller: this.scroller }) {
            // 顶部留白用占位项而不是 padding：padding 会裁掉列表视口，
            // 正文就永远滚不到顶栏玻璃底下，背景模糊没有内容可糊。
            ListItem() {
              Row()
                .width('100%')
                .height(104)
            }
            if (this.hasMore) {
              ListItem() {
                Row() {
                  Text(this.loadingMore ? '正在取更早的消息…' : '↑ 加载更早的消息')
                    .fontSize(12.5)
                    .fontColor(this.loadingMore ? Tokens.dim2 : Tokens.accent)
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 6, bottom: 16 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                .onClick(() => {
                  this.loadOlder();
                })
              }
            }
            ForEach(this.msgs, (m: Message) => {
              ListItem() {
                this.bubble(m)
              }
              .transition(TransitionEffect.OPACITY
                .combine(TransitionEffect.translate({ y: 14 }))
                .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
                .animation({ duration: 320, curve: Curve.Friction }))
            }, (m: Message) => '' + m.seq + m.role)
            if (this.running) {
              ListItem() {
                this.typingBubble()
              }
              .transition(TransitionEffect.OPACITY
                .animation({ duration: 200, curve: Curve.EaseOut }))
            }
            // 底部留白同理，让最后一条也能滚到输入区玻璃底下
            ListItem() {
              Row()
                .width('100%')
                .height(200 + this.kbH)
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: 14, right: 14 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)

        // 顶栏做成浮层压在列表上：系统材质的标题栏拿不到浮动效果，
        // 这里保留自绘胶囊，用原生背景模糊给它一块跟着应用主题走的玻璃底。
        Column() {
          Column() {
            this.headerBar()
          }
          .width('100%')
          .padding({ top: 46, bottom: 8 })
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: this.themeDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
          })
          .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .hitTestBehavior(HitTestMode.Transparent)


          // 底部：玻璃胶囊条 + 输入行 + 免责声明
          Column() {
            Column() {
            if (this.err !== '' || this.toast !== '') {
              Text(this.err !== '' ? this.err : this.toast)
                .fontSize(11.5)
                .fontColor(this.err !== '' ? Tokens.err : Tokens.ok)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ left: 4, bottom: 6 })
            }

            // 停泊区：生成中点发送先落在这里，可改、可删、可插队
            if (this.dock.length > 0) {
              Column({ space: 6 }) {
                ForEach(this.dock, (it: DockItem) => {
                  Column() {
                    Row() {
                      Text('待发送')
                        .fontSize(10)
                        .fontColor(Tokens.accent)
                        .backgroundColor(Tokens.accentSoft)
                        .borderRadius(6)
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      Blank()
                      Text('插队')
                        .fontSize(11)
                        .fontColor(Tokens.accent)
                        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                        .borderRadius(8)
                        .onClick(() => {
                          this.jumpDock(it);
                        })
                      Text('×')
                        .fontSize(14)
                        .fontColor(Tokens.dim)
                        .padding({ left: 8, right: 2, top: 2, bottom: 2 })
                        .onClick(() => {
                          this.dropDock(it.id);
                        })
                    }
                    .width('100%')

                    Text(it.text)
                      .fontSize(13)
                      .fontColor(Tokens.fg)
                      .maxLines(3)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                      .margin({ top: 2 })
                      .onClick(() => {
                        this.editDock(it);
                      })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .padding({ left: 10, right: 8, top: 7, bottom: 8 })
                  .backgroundColor(Tokens.glassBar)
                  .borderRadius(14)
                  .border({ width: 1, color: Tokens.glassLine })
                }, (it: DockItem) => 'dk' + it.id)
              }
              .width('100%')
              .margin({ bottom: 8 })
            }

            // 待发送附件：选好的图片/文件挂在这里，点 × 可以摘掉
            if (this.hasPend()) {
              Scroll() {
                Row({ space: 8 }) {
                  ForEach(this.pendImgs, (it: ImagePart, i: number) => {
                    Row() {
                      Text(it.name !== '' ? it.name : ('图片 ' + String(i + 1)))
                        .fontSize(11)
                        .fontColor(Tokens.fg)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .constraintSize({ maxWidth: 132 })
                      Text('×')
                        .fontSize(13)
                        .fontColor(Tokens.dim)
                        .margin({ left: 6 })
                    }
                    .padding({ left: 10, right: 9, top: 6, bottom: 6 })
                    .backgroundColor(Tokens.glassBar)
                    .borderRadius(14)
                    .border({ width: 1, color: Tokens.glassLine })
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                    .onClick(() => {
                      this.dropImg(i);
                    })
                  }, (it: ImagePart, i: number) => 'i' + String(i) + it.name)
                  ForEach(this.pendFiles, (it: FilePart, i: number) => {
                    Row() {
                      Text(it.name)
                        .fontSize(11)
                        .fontColor(Tokens.fg)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .constraintSize({ maxWidth: 132 })
                      Text('×')
                        .fontSize(13)
                        .fontColor(Tokens.dim)
                        .margin({ left: 6 })
                    }
                    .padding({ left: 10, right: 9, top: 6, bottom: 6 })
                    .backgroundColor(Tokens.glassBar)
                    .borderRadius(14)
                    .border({ width: 1, color: Tokens.glassLine })
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                    .onClick(() => {
                      this.dropFile(i);
                    })
                  }, (it: FilePart, i: number) => 'f' + String(i) + it.name)
                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
              .margin({ bottom: 8 })
            }


            Row() {
              Text('＋')
                .fontSize(18)
                .fontColor(Tokens.dim)
                .width(34)
                .height(34)
                .textAlign(TextAlign.Center)
                .borderRadius(999)
                .backgroundColor(Tokens.surface3)
                .margin({ right: 6 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                .onClick(() => {
                  this.pickAttach();
                })
              TextInput({ placeholder: '发消息或问点什么…', text: this.draft })
                .placeholderColor(Tokens.dim2)
                .fontColor(Tokens.fg)
                .fontSize(15)
                .height(40)
                .backgroundColor(Color.Transparent)
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.draft = v;
                })
                .onSubmit(() => this.send())
              if (this.running) {
                // 正在生成时，发送键变成停止键——手机上不该为了停一轮去翻菜单。
                Text('■')
                  .fontSize(13)
                  .fontColor(Tokens.fg)
                  .width(36)
                  .height(36)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(Tokens.surface3)
                  .borderRadius(999)
                  .margin({ left: 8 })
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                  .onClick(() => this.doStop())
              } else {
                Text(this.sending ? '···' : '↑')
                  .fontSize(16)
                  .fontColor(Tokens.accentInk)
                  .width(36)
                  .height(36)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.draft.trim() === '' && !this.hasPend() ? Tokens.surface3 : Tokens.accent)
                  .borderRadius(999)
                  .margin({ left: 8 })
                  .shadow({
                    radius: this.draft.trim() === '' && !this.hasPend() ? 0 : 16,
                    color: Tokens.accentSoft,
                    offsetY: 4
                  })
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                  .onClick(() => this.send())
              }
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .backgroundColor(Tokens.glassBar)
            .borderRadius(28)
            .border({ width: 1, color: Tokens.glassLine })
            .shadow({ radius: 20, color: Tokens.shadow, offsetY: 6 })

            Text('内容由 AI 生成，请仔细甄别')
              .fontSize(10)
              .fontColor(Tokens.dim2)
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 9, bottom: 2 })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 14, bottom: 18 })
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
              colorMode: this.themeDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
            })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          .padding({ bottom: this.kbH })
          .hitTestBehavior(HitTestMode.Transparent)


        if (this.modelOn) {
          this.modelSheet()
        }
        if (this.statsOn) {
          this.statsSheet()
        }
        if (this.moreOn) {
          this.moreSheet()
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(this.themeBg)
    .mode(NavDestinationMode.STANDARD)
    .onReady((context: NavDestinationContext) => {
      const id: string | undefined = context.navDestinationId;
      if (id !== undefined && id !== '') {
        this.bindFx(id);
      }
    })
    .translate({ x: this.fxTx })
    .opacity(this.fxOp)
    .scale({ x: this.fxSc, y: this.fxSc })
  }
}
