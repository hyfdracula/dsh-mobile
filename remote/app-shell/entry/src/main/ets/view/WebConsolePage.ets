import preferences from '@ohos.data.preferences';
import { webview } from '@kit.ArkWeb';
import { Api, WebConsoleGrantResp } from '../common/Api';
import { AppCtx } from '../common/AppCtx';
import { PageHeader } from '../common/Chrome';
import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { EmptyState, RowSwitch, SheetHeader } from '../common/Widgets';

const UNAVAILABLE_HINT: string = '请确认电脑端服务与网页控制台运行后重试';
const PREF_STORE: string = 'dsh_mobile_cfg';
const STYLE_ID: string = 'am-wc-mobile-compat';
const DESKTOP_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

const GENERIC_MOBILE_CSS: string =
  '@media (max-width:768px){' +
  'html,body{max-width:100vw!important;overflow-x:hidden!important;-webkit-text-size-adjust:100%;}' +
  'pre,code,table{max-width:100%!important;overflow-x:auto!important;}' +
  '[role="dialog"],[aria-modal="true"]{max-width:96vw!important;max-height:92vh!important;box-sizing:border-box!important;}' +
  '}';

/**
 * 电脑完整网页控制台：
 * 进入时向网关申请一次性免密票据并通过 @kit.ArkWeb 渲染；
 * 提供通用可选「移动端适配增强」与「自动收起推广浮层」开关、桌面 UA 切换、以及系统浏览器打开。
 */
@Component
export struct WebConsolePage {
  api: Api = new Api('', '');
  @Prop hostName: string = '';
  onExit: () => void = () => {};

  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('wcMobileCompat') wcMobileCompat: boolean = false;
  @StorageLink('wcAutoDismissPromo') wcAutoDismissPromo: boolean = false;

  @State private loading: boolean = true;
  @State private pageLoading: boolean = false;
  @State private enterUrl: string = '';
  @State private errTitle: string = '';
  @State private errHint: string = '';
  @State private canBack: boolean = false;
  @State private canForward: boolean = false;
  @State private browserBusy: boolean = false;
  @State private desktopMode: boolean = false;
  @State private optionsOpen: boolean = false;

  private webCtrl: webview.WebviewController = new webview.WebviewController();
  private webReady: boolean = false;
  private defaultUa: string = '';
  private loadSeq: number = 0;
  private pendingTimers: number[] = [];

  aboutToAppear(): void {
    void this.requestGrant();
  }

  aboutToDisappear(): void {
    this.loadSeq++;
    this.clearTimers();
  }

  private scheduleTimer(fn: () => void, ms: number): void {
    const id: number = setTimeout(() => {
      const idx: number = this.pendingTimers.indexOf(id);
      if (idx >= 0) {
        this.pendingTimers.splice(idx, 1);
      }
      fn();
    }, ms);
    this.pendingTimers.push(id);
  }

  private clearTimers(): void {
    for (let i = 0; i < this.pendingTimers.length; i++) {
      clearTimeout(this.pendingTimers[i]);
    }
    this.pendingTimers = [];
  }

  private subtitleText(): string {
    if (this.hostName !== '') {
      return this.hostName;
    }
    const base: string = this.api.currentBase();
    return base !== '' ? base : '未连接';
  }

  private is404Error(msg: string): boolean {
    return msg.indexOf('HTTP 404') >= 0 || msg.indexOf('404 Not Found') >= 0 || msg.indexOf('404') >= 0;
  }

  private is503Error(msg: string): boolean {
    const low: string = msg.toLowerCase();
    return msg.indexOf('HTTP 503') >= 0 || msg.indexOf('503') >= 0 ||
      low.indexOf('unavailable') >= 0 || msg.indexOf('未启动') >= 0;
  }

  private async saveOptionFlag(key: string, v: boolean): Promise<void> {
    AppStorage.setOrCreate(key, v);
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put(key, v ? '1' : '0');
      await p.flush();
    } catch (e) {
    }
    this.applyOptionalScripts();
  }

  private async requestGrant(): Promise<void> {
    const seq: number = ++this.loadSeq;
    this.loading = true;
    this.errTitle = '';
    this.errHint = '';
    try {
      const res: WebConsoleGrantResp = await this.api.webConsoleGrant();
      if (seq !== this.loadSeq) {
        return;
      }
      if (!res.ok || res.enterUrl === '') {
        this.enterUrl = '';
        this.errTitle = '电脑端控制台暂不可用';
        this.errHint = UNAVAILABLE_HINT;
        return;
      }
      this.enterUrl = res.enterUrl;
      this.pageLoading = true;
      if (this.webReady) {
        try {
          this.webCtrl.loadUrl(res.enterUrl);
        } catch (e) {
        }
      }
    } catch (e) {
      if (seq !== this.loadSeq) {
        return;
      }
      const msg: string = (e as Error).message !== undefined ? (e as Error).message : '';
      this.enterUrl = '';
      if (this.is404Error(msg)) {
        this.errTitle = '电脑端网关暂未支持免密控制台';
        this.errHint = UNAVAILABLE_HINT;
      } else if (this.is503Error(msg)) {
        this.errTitle = '电脑端桌面控制台未运行';
        this.errHint = UNAVAILABLE_HINT;
      } else {
        this.errTitle = '暂时无法打开电脑完整控制台';
        this.errHint = msg !== '' ? msg + '。' + UNAVAILABLE_HINT : UNAVAILABLE_HINT;
      }
    } finally {
      if (seq === this.loadSeq) {
        this.loading = false;
      }
    }
  }

  private syncNavState(): void {
    if (!this.webReady) {
      return;
    }
    try {
      this.canBack = this.webCtrl.accessBackward();
      this.canForward = this.webCtrl.accessForward();
    } catch (e) {
      this.canBack = false;
      this.canForward = false;
    }
  }

  private goBack(): void {
    Haptics.tap();
    if (!this.webReady) {
      return;
    }
    try {
      if (this.webCtrl.accessBackward()) {
        this.webCtrl.backward();
        this.scheduleTimer(() => {
          this.syncNavState();
        }, 120);
      }
    } catch (e) {
    }
  }

  private goForward(): void {
    Haptics.tap();
    if (!this.webReady) {
      return;
    }
    try {
      if (this.webCtrl.accessForward()) {
        this.webCtrl.forward();
        this.scheduleTimer(() => {
          this.syncNavState();
        }, 120);
      }
    } catch (e) {
    }
  }

  private reloadConsole(): void {
    Haptics.tap();
    if (this.errTitle !== '' || this.enterUrl === '' || !this.webReady) {
      void this.requestGrant();
      return;
    }
    try {
      this.pageLoading = true;
      this.webCtrl.refresh();
    } catch (e) {
      void this.requestGrant();
    }
  }

  private applyOptionalScripts(): void {
    if (!this.webReady) {
      return;
    }
    const compatOn: string = this.wcMobileCompat && !this.desktopMode ? 'true' : 'false';
    const promoOn: string = this.wcAutoDismissPromo ? 'true' : 'false';
    const cssJson: string = JSON.stringify(GENERIC_MOBILE_CSS);
    const idJson: string = JSON.stringify(STYLE_ID);
    const js: string =
      '(function(){' +
      'var sid=' + idJson + ';' +
      'var ex=document.getElementById(sid);' +
      'if(' + compatOn + '){' +
      'if(!ex){ex=document.createElement("style");ex.id=sid;if(document.head)document.head.appendChild(ex);}' +
      'ex.textContent=' + cssJson + ';' +
      '}else if(ex&&ex.parentNode){ex.parentNode.removeChild(ex);}' +
      'if(' + promoOn + '){' +
      'var nodes=document.querySelectorAll("[role=\\"dialog\\"],[aria-modal=\\"true\\"],.modal");' +
      'for(var i=0;i<nodes.length;i++){' +
      'var n=nodes[i];var cs=window.getComputedStyle?getComputedStyle(n):null;' +
      'var z=cs?parseInt(cs.zIndex,10):0;if(!(z>=50))continue;' +
      'var txt=(n.innerText||"").toLowerCase();' +
      'if(txt.indexOf("github")<0&&txt.indexOf("star")<0&&txt.indexOf("赞赏")<0&&txt.indexOf("推广")<0)continue;' +
      'var btns=n.querySelectorAll("button,[role=\\"button\\"],a");' +
      'for(var j=0;j<btns.length;j++){' +
      'var b=btns[j];var bt=(b.innerText||b.getAttribute("aria-label")||"").trim().toLowerCase();' +
      'if(bt==="×"||bt==="✕"||bt==="关闭"||bt==="稍后"||bt.indexOf("以后")>=0||bt==="close"||bt==="dismiss"||bt.indexOf("no thanks")>=0){' +
      'try{b.click();}catch(e){}break;' +
      '}' +
      '}' +
      '}' +
      '}' +
      '})()';
    try {
      this.webCtrl.runJavaScript(js);
    } catch (e) {
    }
  }

  private toggleViewportMode(): void {
    Haptics.tap();
    this.desktopMode = !this.desktopMode;
    if (this.webReady) {
      try {
        if (this.desktopMode) {
          this.webCtrl.setCustomUserAgent(DESKTOP_UA);
        } else if (this.defaultUa !== '') {
          this.webCtrl.setCustomUserAgent(this.defaultUa);
        }
        this.pageLoading = true;
        this.webCtrl.refresh();
      } catch (e) {
      }
    }
    Toast.info(this.desktopMode ? '已切换为桌面版视图' : '已切换为移动版视图');
  }

  private async openInBrowser(): Promise<void> {
    if (this.browserBusy) {
      return;
    }
    Haptics.tap();
    this.browserBusy = true;
    try {
      let targetUrl: string = '';
      let sec: number = 60;
      try {
        const res: WebConsoleGrantResp = await this.api.webConsoleGrant();
        if (res.ok && res.enterUrl !== '') {
          targetUrl = res.enterUrl;
          sec = res.expiresIn > 0 ? res.expiresIn : 60;
        }
      } catch (e) {
      }
      if (targetUrl === '') {
        targetUrl = this.api.currentBase();
      }
      if (targetUrl === '') {
        Toast.info('当前未连接有效主机地址');
        return;
      }
      const opened: boolean = await AppCtx.openSystemUrl(targetUrl);
      if (!opened) {
        await copyText(targetUrl, '未能调起系统浏览器，已复制链接（' + String(sec) + ' 秒内有效）');
      }
    } finally {
      this.browserBusy = false;
    }
  }

  @Builder
  optionsSheetView() {
    Column({ space: 12 }) {
      SheetHeader({
        title: '网页兼容与显示选项',
        subtitle: '按需开启的通用浏览增强（默认关闭）',
        onClose: () => {
          this.optionsOpen = false;
        }
      })

      Column() {
        RowSwitch({
          title: '移动端适配增强',
          hint: '注入通用窄屏响应式样式，改善横向溢出与弹窗宽度',
          value: this.wcMobileCompat,
          onChanged: (v: boolean) => {
            void this.saveOptionFlag('wcMobileCompat', v);
          }
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        RowSwitch({
          title: '自动收起推广浮层',
          hint: '在页面加载完成后尝试关闭高层级 Star/推广类外部弹窗',
          value: this.wcAutoDismissPromo,
          onChanged: (v: boolean) => {
            void this.saveOptionFlag('wcAutoDismissPromo', v);
          }
        })
      }
      .width('100%')
      .backgroundColor(Tokens.surface2)
      .borderRadius(Tokens.rGroup)
      .clip(true)
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 16, bottom: this.bottomInset + 22 })
  }

  build() {
    Column() {
      Column() {
        PageHeader({
          title: '电脑完整控制台',
          subtitle: this.subtitleText(),
          padTop: true,
          rightKind: 'glyph',
          rightGlyph: '\u21bb',
          onBack: () => {
            this.onExit();
          },
          onRight: () => {
            this.reloadConsole();
          }
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .backgroundColor(Tokens.surface)

      Divider().color(Tokens.lineSoft)

      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(30)
            .height(30)
            .color(Tokens.accent)
          Text('正在申请电脑端免密会话…')
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.errTitle !== '') {
        Column() {
          EmptyState({
            icon: $r('app.media.ic_pc'),
            title: this.errTitle,
            hint: this.errHint,
            action: '重试打开',
            onAction: () => {
              void this.requestGrant();
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        Stack({ alignContent: Alignment.Top }) {
          Web({ src: this.enterUrl, controller: this.webCtrl })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .mixedMode(MixedMode.Compatible)
            .metaViewport(!this.desktopMode)
            .overviewModeAccess(this.desktopMode)
            .initialScale(this.desktopMode ? 45 : 100)
            .zoomAccess(true)
            .onControllerAttached(() => {
              this.webReady = true;
              try {
                this.defaultUa = this.webCtrl.getUserAgent();
                if (this.desktopMode) {
                  this.webCtrl.setCustomUserAgent(DESKTOP_UA);
                }
              } catch (e) {
              }
            })
            .onPageBegin(() => {
              this.clearTimers();
              this.pageLoading = true;
              this.applyOptionalScripts();
            })
            .onPageEnd(() => {
              this.pageLoading = false;
              this.syncNavState();
              this.applyOptionalScripts();
              this.scheduleTimer(() => {
                this.applyOptionalScripts();
              }, 700);
            })
            .width('100%')
            .height('100%')

          if (this.pageLoading) {
            Row({ space: 6 }) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color(Tokens.accent)
              Text('正在加载电脑端控制台…')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim)
            }
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .margin({ top: 10 })
            .backgroundColor(Tokens.popBg)
            .border({ width: 1, color: Tokens.lineSoft })
            .borderRadius(Tokens.rPill)
          }
        }
        .width('100%')
        .layoutWeight(1)

        Divider().color(Tokens.lineSoft)

        Row({ space: 8 }) {
          Text('‹ 后退')
            .fontSize(Tokens.fsCaption)
            .fontColor(this.canBack ? Tokens.fg : Tokens.dim2)
            .backgroundColor(Tokens.surface2)
            .border({ width: 1, color: Tokens.lineSoft })
            .borderRadius(Tokens.rPill)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .opacity(this.canBack ? 1 : 0.48)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              if (this.canBack) {
                this.goBack();
              }
            })

          Text('前进 ›')
            .fontSize(Tokens.fsCaption)
            .fontColor(this.canForward ? Tokens.fg : Tokens.dim2)
            .backgroundColor(Tokens.surface2)
            .border({ width: 1, color: Tokens.lineSoft })
            .borderRadius(Tokens.rPill)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .opacity(this.canForward ? 1 : 0.48)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              if (this.canForward) {
                this.goForward();
              }
            })

          Text(this.desktopMode ? '移动版' : '桌面版')
            .fontSize(Tokens.fsCaption)
            .fontColor(this.desktopMode ? Tokens.accent : Tokens.fg)
            .backgroundColor(this.desktopMode ? Tokens.accentSoft : Tokens.surface2)
            .border({ width: 1, color: this.desktopMode ? Tokens.accentSoft : Tokens.lineSoft })
            .borderRadius(Tokens.rPill)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              this.toggleViewportMode();
            })

          Text('兼容选项')
            .fontSize(Tokens.fsCaption)
            .fontColor(this.wcMobileCompat || this.wcAutoDismissPromo ? Tokens.accent : Tokens.fg)
            .backgroundColor(this.wcMobileCompat || this.wcAutoDismissPromo ? Tokens.accentSoft : Tokens.surface2)
            .border({ width: 1, color: Tokens.lineSoft })
            .borderRadius(Tokens.rPill)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              this.optionsOpen = true;
            })
            .bindSheet($$this.optionsOpen, this.optionsSheetView(),
              Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => {
                this.optionsOpen = false;
              }))

          Blank()

          Text(this.browserBusy ? '打开中…' : '浏览器打开')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.accent)
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rPill)
            .padding({ left: 11, right: 11, top: 6, bottom: 6 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              void this.openInBrowser();
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 8, bottom: this.bottomInset + 8 })
        .backgroundColor(Tokens.surface)
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
  }
}
