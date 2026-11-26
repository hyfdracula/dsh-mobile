import window from '@ohos.window';
import { Api, TerminalOpenResp, TerminalPollResp } from '../../common/Api';
import { AppCtx } from '../../common/AppCtx';
import { Tokens } from '../../common/Tokens';
import { EmptyState } from '../../common/Widgets';
import { copyText } from '../../common/Clipboard';
import { Haptics } from '../../common/Haptics';
import { Toast } from '../../common/Toast';
import { GATEWAY_404_HINT, GATEWAY_404_TITLE, isGateway404, splitFileLeaf } from './ExtrasCommon';

const MAX_TERM_BUFFER: number = 48000;
const QUICK_CMDS: string[] = ['git status', 'ls', 'npm test'];

function cleanTerminalText(raw: string): string {
  if (raw === '') {
    return '';
  }
  return raw
    .replace(/\r\n/g, '\n')
    .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '')
    .replace(/\x1b\][^\x07]*\x07/g, '');
}

/**
 * 远程受控交互式工作区终端视图（R6）：
 * - 调用 api.terminalOpen(sessionId) 打开工作区 Shell
 * - 可见期间每 1200ms 调用 api.terminalPoll(sessionId, seq) 增量追加输出，离开时严格清理定时器
 * - 提供 Ctrl+C (sigint)、清屏、重启终端 (restart) 与快捷命令胶囊 (git status / ls / npm test)
 * - 底部命令输入栏自适应避让软键盘（兼容父页面 RESIZE 与 NONE 两种模式）
 */
@Component
export struct TerminalView {
  api: Api = new Api('', '');
  @Prop sessionId: string = '';
  @Prop @Watch('onReload') reloadTick: number = 0;
  @Prop topPad: number = 140;

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private opening: boolean = true;
  @State private sending: boolean = false;
  @State private missing404: boolean = false;
  @State private err: string = '';
  @State private cwd: string = '';
  @State private running: boolean = false;
  @State private exitCode: number | null = null;
  @State private output: string = '';
  @State private cmdInput: string = '';
  @State private extraKbBottom: number = 0;

  private seq: number = 0;
  private pollTimer: number = -1;
  private polling: boolean = false;
  private termScroller: Scroller = new Scroller();

  private kbWin: window.Window | null = null;
  private kbCb: ((h: number) => void) | null = null;
  private kbRawVp: number = 0;
  private fullHeightVp: number = 0;
  private curHeightVp: number = 0;

  aboutToAppear(): void {
    this.attachKeyboardObserver();
    void this.openTerminal();
    this.pollTimer = setInterval(() => {
      void this.pollOutput();
    }, 1200);
  }

  aboutToDisappear(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    this.detachKeyboardObserver();
  }

  onReload(): void {
    void this.openTerminal();
  }

  private attachKeyboardObserver(): void {
    window.getLastWindow(AppCtx.ability()).then((w: window.Window) => {
      this.kbWin = w;
      this.kbCb = (h: number) => {
        this.kbRawVp = h > 0 ? AppCtx.px2vp(h) : 0;
        this.recalcKeyboardPad();
        if (this.kbRawVp > 0) {
          this.scrollToBottomSoon();
        }
      };
      w.on('keyboardHeightChange', this.kbCb);
    }).catch(() => {
    });
  }

  private detachKeyboardObserver(): void {
    if (this.kbWin !== null && this.kbCb !== null) {
      try {
        this.kbWin.off('keyboardHeightChange', this.kbCb);
      } catch (e) {
      }
    }
    this.kbWin = null;
    this.kbCb = null;
  }

  private recalcKeyboardPad(): void {
    if (this.kbRawVp <= 0) {
      this.extraKbBottom = 0;
      return;
    }
    // 若外层窗口已通过 KeyboardAvoidMode.RESIZE 收缩高度，则无需二次叠加底部避让
    if (this.fullHeightVp > 0 && this.curHeightVp > 0 && (this.fullHeightVp - this.curHeightVp) > 64) {
      this.extraKbBottom = 0;
      return;
    }
    const pad: number = this.kbRawVp - this.bottomInset;
    this.extraKbBottom = pad > 0 ? pad : 0;
  }

  private appendChunk(chunk: string, nextSeq: number): void {
    const cleaned: string = cleanTerminalText(chunk);
    if (cleaned !== '') {
      const combined: string = this.output + cleaned;
      this.output = combined.length > MAX_TERM_BUFFER
        ? combined.substring(combined.length - MAX_TERM_BUFFER)
        : combined;
      this.scrollToBottomSoon();
    }
    if (nextSeq > this.seq) {
      this.seq = nextSeq;
    }
  }

  private scrollToBottomSoon(): void {
    setTimeout(() => {
      try {
        this.termScroller.scrollEdge(Edge.Bottom);
      } catch (e) {
      }
    }, 32);
  }

  private async openTerminal(): Promise<void> {
    if (this.sessionId === '') {
      this.opening = false;
      return;
    }
    this.opening = true;
    this.missing404 = false;
    try {
      const r: TerminalOpenResp = await this.api.terminalOpen(this.sessionId);
      this.cwd = r.cwd;
      this.running = r.running === true;
      this.exitCode = r.exitCode;
      this.seq = r.seq;
      this.output = cleanTerminalText(r.output);
      if (this.output.length > MAX_TERM_BUFFER) {
        this.output = this.output.substring(this.output.length - MAX_TERM_BUFFER);
      }
      this.err = '';
      this.scrollToBottomSoon();
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      if (isGateway404(msg)) {
        this.missing404 = true;
        this.err = '';
      } else {
        this.err = msg;
      }
    } finally {
      this.opening = false;
    }
  }

  private async pollOutput(): Promise<void> {
    if (this.polling || this.opening || this.missing404 || this.sessionId === '') {
      return;
    }
    if (AppStorage.get<boolean>('appFg') === false) {
      return;
    }
    this.polling = true;
    try {
      const r: TerminalPollResp = await this.api.terminalPoll(this.sessionId, this.seq);
      if (r.cwd !== undefined && r.cwd !== '') {
        this.cwd = r.cwd;
      }
      this.running = r.running === true;
      this.exitCode = r.exitCode;
      if (r.seq < this.seq) {
        this.seq = r.seq;
      }
      if (r.output !== undefined && r.output !== '' && r.seq >= this.seq) {
        this.appendChunk(r.output, r.seq);
      }
    } catch (e) {
      // 轮询瞬时抖动静默忽略
    } finally {
      this.polling = false;
    }
  }

  private async runCommandText(cmdLine: string): Promise<void> {
    if (this.sending || this.sessionId === '') {
      return;
    }
    const trimmed: string = cmdLine.trim();
    if (trimmed === '') {
      return;
    }
    Haptics.tap();
    this.sending = true;
    try {
      const payload: string = trimmed + '\n';
      const r: TerminalPollResp = await this.api.terminalInput(this.sessionId, payload, '', false);
      this.running = r.running === true;
      this.exitCode = r.exitCode;
      if (r.output !== undefined && r.output !== '' && r.seq > this.seq) {
        this.appendChunk(r.output, r.seq);
      }
      this.cmdInput = '';
      this.err = '';
      void this.pollOutput();
    } catch (e) {
      const msg: string = (e as Error).message ?? '命令发送失败';
      Toast.err(msg);
    } finally {
      this.sending = false;
    }
  }

  private async sendControlAction(action: string): Promise<void> {
    if (this.sending || this.sessionId === '') {
      return;
    }
    Haptics.tap();
    this.sending = true;
    try {
      if (action === 'restart') {
        this.output = '';
        this.seq = 0;
      }
      const r: TerminalPollResp = await this.api.terminalInput(this.sessionId, '', action, false);
      this.running = r.running === true;
      this.exitCode = r.exitCode;
      if (action === 'restart') {
        this.seq = r.seq;
        this.output = r.output !== undefined ? cleanTerminalText(r.output) : '';
        Toast.ok('已重启工作区终端');
      } else if (action === 'sigint') {
        if (r.output !== undefined && r.output !== '' && r.seq > this.seq) {
          this.appendChunk(r.output, r.seq);
        }
        Toast.info('已发送 Ctrl+C 中断信号');
      }
      this.scrollToBottomSoon();
    } catch (e) {
      Toast.err((e as Error).message);
    } finally {
      this.sending = false;
    }
  }

  private statusSummary(): string {
    if (this.opening) {
      return '连接中...';
    }
    if (this.running) {
      return '运行中';
    }
    if (this.exitCode !== null) {
      return '已退出 (' + String(this.exitCode) + ')';
    }
    return '已就绪';
  }

  build() {
    Column() {
      if (this.missing404) {
        EmptyState({
          icon: $r('app.media.ic_pc'),
          title: GATEWAY_404_TITLE,
          hint: GATEWAY_404_HINT
        })
      } else {
        Column() {
          // 顶部控制按钮行：状态 + Ctrl+C + 清屏 + 重启终端 + 复制输出
          Row({ space: 6 }) {
            Row({ space: 5 }) {
              Row()
                .width(7)
                .height(7)
                .borderRadius(Tokens.rPill)
                .backgroundColor(this.running ? Tokens.doneInk : Tokens.dim2)
              Text(this.statusSummary() + (this.cwd !== '' ? (' · ' + splitFileLeaf(this.cwd)) : ''))
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 132 })
            }
            .layoutWeight(1)
            .alignItems(VerticalAlign.Center)

            Text('Ctrl+C')
              .fontSize(Tokens.fsCaption)
              .fontFamily('monospace')
              .fontColor(Tokens.err)
              .backgroundColor(this.themeDark ? '#24FF5C5C' : '#16DC3545')
              .borderRadius(Tokens.rPill)
              .padding({ left: 9, right: 9, top: 5, bottom: 5 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                void this.sendControlAction('sigint');
              })

            Text('清屏')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.fg)
              .backgroundColor(Tokens.surface)
              .border({ width: 1, color: Tokens.lineSoft })
              .borderRadius(Tokens.rPill)
              .padding({ left: 9, right: 9, top: 5, bottom: 5 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                Haptics.tap();
                this.output = '';
              })

            Text('重启终端')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.accent)
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(Tokens.rPill)
              .padding({ left: 9, right: 9, top: 5, bottom: 5 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                void this.sendControlAction('restart');
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 快捷命令胶囊栏
          Scroll() {
            Row({ space: 8 }) {
              ForEach(QUICK_CMDS, (cmd: string) => {
                Text(cmd)
                  .fontSize(Tokens.fsCaption)
                  .fontFamily('monospace')
                  .fontColor(Tokens.fg)
                  .backgroundColor(Tokens.surface)
                  .border({ width: 1, color: Tokens.lineSoft })
                  .borderRadius(Tokens.rPill)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                  .onClick(() => {
                    void this.runCommandText(cmd);
                  })
              }, (cmd: string) => cmd)

              if (this.output !== '') {
                Text('复制输出')
                  .fontSize(Tokens.fsCaption)
                  .fontColor(Tokens.dim)
                  .backgroundColor(Tokens.surface)
                  .border({ width: 1, color: Tokens.lineSoft })
                  .borderRadius(Tokens.rPill)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                  .onClick(() => {
                    void copyText(this.output, '已复制终端输出');
                  })
              }
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .margin({ top: 8, bottom: 8 })

          if (this.err !== '') {
            Text(this.err)
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.err)
              .width('100%')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(Tokens.surface)
              .borderRadius(Tokens.rSm)
              .margin({ bottom: 8 })
          }

          // 深色等宽终端输出视窗
          Scroll(this.termScroller) {
            Column() {
              Text(this.output !== ''
                ? this.output
                : (this.opening ? '正在启动电脑端受控工作区终端...' : '$ 终端已就绪，点击上方快捷命令或下方输入执行'))
                .fontSize(Tokens.fsFoot)
                .lineHeight(18)
                .fontFamily('monospace')
                .fontColor(this.output !== '' ? '#E6EDF3' : '#7D8590')
                .copyOption(CopyOptions.LocalDevice)
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding(12)
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .width('100%')
          .backgroundColor('#0D1117')
          .borderRadius(Tokens.rMd)
          .border({ width: 1, color: '#263042' })
          .align(Alignment.TopStart)
          .scrollBar(BarState.Auto)

          // 底部命令输入与发送栏
          Row({ space: 8 }) {
            Text('$')
              .fontSize(Tokens.fsBodyLg)
              .fontFamily('monospace')
              .fontWeight(FontWeight.Bold)
              .fontColor(Tokens.accent)
              .margin({ left: 6 })

            TextInput({
              text: this.cmdInput,
              placeholder: '输入 Shell 命令...'
            })
              .fontSize(Tokens.fsBody)
              .fontFamily('monospace')
              .fontColor(Tokens.fg)
              .placeholderColor(Tokens.dim2)
              .backgroundColor(Color.Transparent)
              .height(40)
              .layoutWeight(1)
              .padding({ left: 2, right: 4 })
              .onChange((v: string) => {
                this.cmdInput = v;
              })
              .onSubmit(() => {
                void this.runCommandText(this.cmdInput);
              })

            Text(this.sending ? '发送...' : '执行')
              .fontSize(Tokens.fsBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.cmdInput.trim() !== '' ? Tokens.accentInk : Tokens.dim2)
              .backgroundColor(this.cmdInput.trim() !== '' ? Tokens.accent : Tokens.surface2)
              .borderRadius(Tokens.rPill)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                void this.runCommandText(this.cmdInput);
              })
          }
          .width('100%')
          .padding({ left: 8, right: 6, top: 4, bottom: 4 })
          .margin({ top: 10 })
          .backgroundColor(Tokens.surface)
          .borderRadius(Tokens.rPill)
          .border({ width: 1, color: Tokens.line })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: 860 })
        .padding({
          left: 16,
          right: 16,
          top: this.topPad,
          bottom: this.bottomInset + 12 + this.extraKbBottom
        })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .onAreaChange((_oldVal: Area, newVal: Area) => {
      const h: number = Number(newVal.height);
      if (Number.isFinite(h) && h > 0) {
        this.curHeightVp = h;
        if (this.kbRawVp <= 0 || h > this.fullHeightVp) {
          this.fullHeightVp = h;
        }
        this.recalcKeyboardPad();
      }
    })
  }
}
