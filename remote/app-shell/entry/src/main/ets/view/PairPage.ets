import common from '@ohos.app.ability.common';
import pasteboard from '@ohos.pasteboard';
import scanBarcode from '@hms.core.scan.scanBarcode';
import { Api } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { Pairing, PairClaim, PairLink } from '../common/Pairing';

/**
 * 配对向导：对齐桌面端控制台的「第 1 步电脑端准备 / 第 2 步扫码连接」。
 * 两步都留在设置里，进来一次就能走完，不用记地址与令牌。
 */
@Component
export struct PairPage {
  api: Api = new Api('', '');
  defaultBase: string = '';
  /** 从「设置 → 连接」直接进来时的落点：code / scan / guide；空串按向导从头走 */
  @Prop entry: string = '';
  onExit: () => void = () => {};
  onPaired: (base: string, token: string, host: string, lan: string[]) => void = () => {};
  @State private step: number = 1;
  @State private code: string = '';
  @State private manual: string = '';
  @State private showManual: boolean = false;
  @State private busy: boolean = false;
  @State private err: string = '';
  @State private okMsg: string = '';
  @State private hint: string = '';

  aboutToAppear(): void {
    // 手动输入留空：预填会让用户先删一遍，反而更容易输错
    this.manual = '';
    if (this.entry === 'code' || this.entry === 'scan') {
      this.step = 2;
    }
    if (this.entry === 'scan') {
      // 扫码是系统半模态，等这一页真正上屏再拉起来
      setTimeout(() => {
        this.scan();
      }, 260);
    }
  }

  private async doClaim(base: string, code: string): Promise<void> {
    const b = Pairing.normalizeBase(base);
    const c = code.trim();
    if (b === '') {
      this.err = '先填电脑地址';
      return;
    }
    if (c.length !== 6) {
      this.err = '配对码是 6 位数字';
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.err = '';
    this.okMsg = '正在连 ' + b + ' …';
    try {
      const r: PairClaim = await Pairing.claim(b, c);
      this.okMsg = '配对成功 · ' + (r.host !== undefined ? r.host : '');
      console.info('DSH_PAIR ok base=' + b + ' host=' + r.host);
      Haptics.tap();
      await this.wait(320);
      this.onPaired(b, r.token, r.host, r.lan !== undefined ? r.lan : []);
    } catch (e) {
      const msg = (e as Error).message;
      this.err = msg;
      this.okMsg = '';
      console.error('DSH_PAIR fail base=' + b + ' :: ' + msg);
    } finally {
      this.busy = false;
    }
  }

  private async wait(ms: number): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private async scan(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.err = '';
    Haptics.soft();
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const res = await scanBarcode.startScanForResult(ctx);
      const raw: string = res.originalValue;
      console.info('DSH_PAIR scan raw len=' + raw.length);
      const link: PairLink | null = Pairing.parseLink(raw);
      if (link === null) {
        // 也可能扫到「面板上别的二维码」，直接把内容当地址再要一次码
        this.err = '这个二维码不是配对码，用下面的 6 位码更稳';
        return;
      }
      this.hint = '已扫到 ' + link.base;
      this.step = 2;
      await this.doClaim(link.base, link.code);
    } catch (e) {
      const msg = (e as Error).message;
      this.err = '打开扫码失败：' + msg;
      console.error('DSH_PAIR scan fail :: ' + msg);
    }
  }

  private async copyCmd(): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
      'dsh plugin --profile desktop add link:<插件目录>');
      await pasteboard.getSystemPasteboard().setData(data);
      Haptics.tap();
      this.hint = '已复制插件名';
    } catch (e) {
      this.hint = '复制失败，手动记一下：dsh plugin --profile desktop add link:<插件目录>';
    }
  }

  // ---------- 通用件 ----------

  @Builder
  backRow(title: string) {
    Row() {
      Stack() {
        Image($r('app.media.ic_back'))
          .width(21)
          .height(21)
          .fillColor(Tokens.fg)
          .objectFit(ImageFit.Contain)
      }
      .width(40)
      .height(40)
      .borderRadius(999)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .onClick(() => {
        Haptics.soft();
        this.onExit();
      })
      Text(title)
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ left: 2 })
      Blank()
    }
    .width('100%')
    .height(52)
    .margin({ bottom: 10 })
  }

  @Builder
  progress() {
    Row() {
      Row()
        .layoutWeight(1)
        .height(4)
        .borderRadius(2)
        .backgroundColor(Tokens.accent)
      Row()
        .layoutWeight(1)
        .height(4)
        .borderRadius(2)
        .backgroundColor(this.step >= 2 ? Tokens.accent : Tokens.surface3)
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ top: 6, bottom: 10 })
  }

  /** 读 this.step 而不是收参数：@Builder 的值传参不会随状态刷新。 */
  @Builder
  stepText() {
    Row() {
      Text(this.step === 1 ? '第一步 · 在电脑上' : '第二步 · 用手机连')
        .fontSize(11.5)
        .fontColor(Tokens.dim2)
        .layoutWeight(1)
    }
    .width('100%')
    .margin({ bottom: 14 })
  }

  @Builder
  head(big: string, sub: string) {
    Column() {
      Text(big)
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor(Tokens.fg)
      Text(sub)
        .fontSize(12)
        .fontColor(Tokens.dim2)
        .margin({ top: 8 })
        .lineHeight(18)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ bottom: 16 })
  }

  @Builder
  stepCard(n: number, tone: string, title: string, body: string) {
    Row() {
      Text('' + n)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(tone === Tokens.accent ? Tokens.fg : Tokens.dim)
        .width(26)
        .height(26)
        .borderRadius(13)
        .textAlign(TextAlign.Center)
        .backgroundColor(tone)
      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
        Text(body)
          .fontSize(11.5)
          .fontColor(Tokens.dim2)
          .margin({ top: 4 })
          .lineHeight(17)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding(14)
    .alignItems(VerticalAlign.Top)
    .backgroundColor(Tokens.surface2)
    .borderRadius(Tokens.rCard)
  }

  @Builder
  cmdBlock() {
    Row() {
      Text('$')
        .fontSize(12)
        .fontColor(Tokens.ok)
        .fontFamily('monospace')
      Text('  dsh plugin --profile desktop\n  add link:<插件目录>')
        .fontSize(11.5)
        .fontColor(Tokens.fg)
        .fontFamily('monospace')
        .layoutWeight(1)
      Text('复制')
        .fontSize(11)
        .fontColor(Tokens.accent)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .backgroundColor(Tokens.accentSoft)
        .borderRadius(Tokens.rPill)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => {
          this.copyCmd();
        })
    }
    .width('100%')
    .padding({ left: 12, right: 10, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Tokens.bgEl)
    .border({ width: 1, color: Tokens.lineSoft })
    .borderRadius(14)
    .margin({ top: 10 })
  }

  private btnText(kind: string): string {
    if (kind === 'next') {
      return '电脑好了，下一步 ›';
    }
    if (kind === 'scan') {
      return this.busy ? '连接中…' : '打开扫一扫';
    }
    return this.busy ? '连接中…' : '连接';
  }

  private btnOn(kind: string): boolean {
    if (kind === 'next') {
      return true;
    }
    if (kind === 'scan') {
      return !this.busy;
    }
    return !this.busy && this.code.length === 6;
  }

  /** kind 是静态字符串，真正的可变状态在函数里读，避免值传参不刷新。 */
  @Builder
  primaryBtn(kind: string, tap: () => void) {
    Text(this.btnText(kind))
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor(Tokens.accentInk)
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(48)
      .borderRadius(Tokens.rPill)
      .backgroundColor(this.btnOn(kind) ? Tokens.accentStrong : Tokens.surface3)
      .opacity(this.btnOn(kind) ? 1 : 0.6)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
      .margin({ top: 12 })
      .onClick(() => {
        if (this.btnOn(kind)) {
          tap();
        }
      })
  }

  @Builder
  errLine() {
    if (this.err !== '') {
      Text(this.err)
        .fontSize(11.5)
        .fontColor(Tokens.err)
        .width('100%')
        .margin({ top: 10 })
        .lineHeight(17)
    } else if (this.okMsg !== '') {
      Text(this.okMsg)
        .fontSize(11.5)
        .fontColor(Tokens.ok)
        .width('100%')
        .margin({ top: 10 })
        .lineHeight(17)
    } else if (this.hint !== '') {
      Text(this.hint)
        .fontSize(11.5)
        .fontColor(Tokens.dim2)
        .width('100%')
        .margin({ top: 10 })
        .lineHeight(17)
    }
  }

  // ---------- 第 1 步 ----------

  @Builder
  stepOne() {
    Column() {
      this.head('先把电脑准备好', '三件事，做完手机就能连上来。')

      this.stepCard(1, Tokens.ok, '给电脑装上「DSH 手机连接」插件',
        '插件包随 App 发布页一起提供。解压后在电脑上执行下面的命令，装完重启 DSH 自动加载。')
      this.cmdBlock()
      Row().height(10)

      this.stepCard(2, Tokens.accent, '重启 DSH',
        '退出并重新打开 DSH，插件加载生效，不会丢失会话记录。')
      Row().height(10)

      this.stepCard(3, Tokens.surface3, '打开电脑上的连接面板',
        '在 DSH 里打开「设置 → 手机连接」，面板里有二维码和 6 位一次性配对码。')

      this.primaryBtn('next', () => {
        Haptics.tap();
        this.err = '';
        this.okMsg = '';
        this.step = 2;
      })
      this.errLine()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ---------- 第 2 步 ----------

  @Builder
  scanCard() {
    Column() {
      Row() {
        Text('▣')
          .fontSize(14)
          .fontColor(Tokens.accent)
          .width(34)
          .height(34)
          .borderRadius(11)
          .textAlign(TextAlign.Center)
          .backgroundColor(Tokens.accentSoft)
        Text('扫一扫')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .margin({ left: 10 })
        Blank()
        Text('最快')
          .fontSize(10.5)
          .fontColor(Tokens.accent)
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.primaryBtn('scan', () => {
        this.scan();
      })
      Text('对着电脑 DSH 面板上的二维码扫一下，扫完直接连上。')
        .fontSize(11)
        .fontColor(Tokens.dim2)
        .width('100%')
        .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rCard)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  codeCard() {
    Column() {
      Row() {
        Text('#')
          .fontSize(14)
          .fontColor(Tokens.dim)
          .width(34)
          .height(34)
          .borderRadius(11)
          .textAlign(TextAlign.Center)
          .backgroundColor(Tokens.surface3)
        Text('配对码')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .margin({ left: 10 })
        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      TextInput({ text: this.code, placeholder: '6 位数字' })
        .type(InputType.Number)
        .maxLength(6)
        .fontSize(20)
        .letterSpacing(8)
        .textAlign(TextAlign.Center)
        .height(50)
        .backgroundColor(Tokens.surface2)
        .borderRadius(Tokens.rInput)
        .margin({ top: 12 })
        .onChange((v: string) => {
          this.code = v;
        })

      this.primaryBtn('code', () => {
        this.doClaim(this.manual !== '' ? this.manual : this.defaultBase, this.code);
      })
      Text('把电脑端「设置 → 手机连接」面板上显示的 6 位码填到上面。')
        .fontSize(11)
        .fontColor(Tokens.dim2)
        .width('100%')
        .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rCard)
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  @Builder
  helpCard() {
    Column() {
      Row() {
        Text('?')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.dim)
          .width(22)
          .height(22)
          .borderRadius(11)
          .textAlign(TextAlign.Center)
          .backgroundColor(Tokens.surface3)
        Text('连不上？')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .margin({ left: 8 })
        Blank()
        Text(this.showManual ? '收起' : '手动输入电脑IP')
          .fontSize(11)
          .fontColor(Tokens.accent)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            this.showManual = !this.showManual;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.showManual) {
        TextInput({ text: this.manual, placeholder: '电脑地址，例如 192.168.1.10:8901' })
          .fontSize(14)
          .height(46)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rInput)
          .margin({ top: 10 })
          .onChange((v: string) => {
            this.manual = v;
          })
      }

      Text('· 手机和电脑连的是同一个 WiFi（别用手机流量）；同一 WiFi 也可能互相隔离\n' +
        '· 电脑 DSH 需常驻；配对码用过一次就作废，过期回面板重新看\n' +
        '· 异地首次配对：先在电脑端「设置 → 手机连接」里打开「公网访问」\n' +
        '· 想在家门外也能用：配对完进 设置 → 连接，里面写了怎么开隧道')
        .fontSize(11)
        .fontColor(Tokens.dim2)
        .lineHeight(18)
        .width('100%')
        .margin({ top: 10 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Tokens.surface2)
    .borderRadius(Tokens.rCard)
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  @Builder
  stepTwo() {
    Column() {
      this.head('扫一下就连上', '扫电脑面板上的二维码，或手输 6 位配对码。')
      this.scanCard()
      this.codeCard()
      this.helpCard()
      this.errLine()
      Text('上一步')
        .fontSize(13)
        .fontColor(Tokens.dim)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 18, bottom: 8 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
        .onClick(() => {
          this.err = '';
          this.okMsg = '';
          this.step = 1;
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      this.backRow('连接电脑')
      this.progress()
      this.stepText()
      if (this.step === 1) {
        this.stepOne()
      } else {
        this.stepTwo()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .transition(TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ x: this.step === 1 ? -16 : 16 }))
      .animation({ duration: 240, curve: Curve.EaseOut }))
  }
}
