import { webview } from '@kit.ArkWeb';
import { Api } from '../../common/Api';
import { Tokens } from '../../common/Tokens';
import { EmptyState } from '../../common/Widgets';
import { copyText } from '../../common/Clipboard';
import { Haptics } from '../../common/Haptics';
import { Toast } from '../../common/Toast';
import { GATEWAY_404_HINT, GATEWAY_404_TITLE, isGateway404 } from './ExtrasCommon';

/**
 * 已授权本机开发服端口实时 WebView 预览面板（R9）：
 * - 调用 api.loopbackPorts() 获取电脑端白名单放行端口
 * - 未配置时以 EmptyState 指引前往「手机连接 -> 本机开发服端口白名单」添加如 3000 / 5173
 * - 先 await api.signLoopback(port)，再通过 @kit.ArkWeb Web 组件实时预览，支持前进/后退/刷新与复制代理链接
 */
@Component
export struct LoopbackPreviewView {
  api: Api = new Api('', '');
  @Prop @Watch('onReload') reloadTick: number = 0;
  @Prop topPad: number = 140;

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private loading: boolean = true;
  @State private signing: boolean = false;
  @State private missing404: boolean = false;
  @State private err: string = '';
  @State private ports: number[] = [];
  @State private selectedPort: number = 0;
  @State private subPath: string = '/';
  @State private activeUrl: string = '';

  private webCtrl: webview.WebviewController = new webview.WebviewController();
  private webReady: boolean = false;

  aboutToAppear(): void {
    void this.loadPorts();
  }

  onReload(): void {
    if (this.selectedPort > 0 && this.activeUrl !== '') {
      void this.openPort(this.selectedPort, this.subPath);
    } else {
      void this.loadPorts();
    }
  }

  private async loadPorts(): Promise<void> {
    this.loading = true;
    this.missing404 = false;
    this.err = '';
    try {
      const got: number[] = await this.api.loopbackPorts();
      this.ports = got;
      if (got.length > 0) {
        const targetPort: number = (this.selectedPort > 0 && got.indexOf(this.selectedPort) >= 0)
          ? this.selectedPort
          : got[0];
        this.selectedPort = targetPort;
        await this.openPort(targetPort, this.subPath);
      } else {
        this.selectedPort = 0;
        this.activeUrl = '';
      }
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      if (isGateway404(msg)) {
        this.missing404 = true;
      } else {
        this.err = msg !== '' ? msg : '获取本机开发服端口失败';
      }
    } finally {
      this.loading = false;
    }
  }

  private async openPort(port: number, rawSub: string): Promise<void> {
    if (port <= 0 || this.signing) {
      return;
    }
    this.signing = true;
    this.err = '';
    try {
      const signed: boolean = await this.api.signLoopback(port);
      if (!signed) {
        this.err = '无法获取端口 :' + String(port) + ' 的访问签名，请确认电脑端已放行该端口并重启生效';
        return;
      }
      const cleanSub: string = rawSub.trim() === '' ? '/' : (rawSub.trim().startsWith('/') ? rawSub.trim() : '/' + rawSub.trim());
      const url: string = this.api.loopbackUrl(port, cleanSub);
      if (url === '') {
        this.err = '预览代理地址生成失败，请稍后重试';
        return;
      }
      this.selectedPort = port;
      this.subPath = cleanSub;
      this.activeUrl = url;
      if (this.webReady) {
        try {
          this.webCtrl.loadUrl(url);
        } catch (e) {
        }
      }
    } catch (e) {
      this.err = (e as Error).message ?? '打开预览失败';
    } finally {
      this.signing = false;
    }
  }

  private goBack(): void {
    Haptics.tap();
    try {
      if (this.webReady && this.webCtrl.accessBackward()) {
        this.webCtrl.backward();
      }
    } catch (e) {
    }
  }

  private goForward(): void {
    Haptics.tap();
    try {
      if (this.webReady && this.webCtrl.accessForward()) {
        this.webCtrl.forward();
      }
    } catch (e) {
    }
  }

  private reloadWeb(): void {
    Haptics.tap();
    if (this.selectedPort > 0) {
      void this.openPort(this.selectedPort, this.subPath);
    }
  }

  private async copyProxyLink(): Promise<void> {
    if (this.selectedPort <= 0) {
      return;
    }
    const signed: boolean = await this.api.signLoopback(this.selectedPort);
    if (!signed) {
      Toast.err('获取预览签名失败');
      return;
    }
    const url: string = this.api.loopbackUrl(this.selectedPort, this.subPath);
    if (url !== '') {
      await copyText(url, '已复制预览代理链接');
    }
  }

  build() {
    Column() {
      if (this.loading) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18).color(Tokens.accent)
          Text('检测本机授权端口...')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: this.topPad + 36 })
      } else if (this.missing404) {
        Column() {
          EmptyState({
            icon: $r('app.media.ic_pc'),
            title: GATEWAY_404_TITLE,
            hint: GATEWAY_404_HINT
          })
        }
        .padding({ top: this.topPad })
      } else if (this.ports.length === 0) {
        Column() {
          EmptyState({
            icon: $r('app.media.ic_pc'),
            title: '暂未放行本机预览端口',
            hint: '请在电脑端「手机连接 -> 本机开发服端口白名单」添加端口（如 3000 / 5173），保存后点下方按钮刷新即可实时预览',
            action: '刷新端口列表',
            onAction: () => {
              void this.loadPorts();
            }
          })
        }
        .padding({ top: this.topPad })
      } else {
        Column() {
          // 第一行：端口切换胶囊 + 子路径输入框 + 跳转
          Row({ space: 6 }) {
            Scroll() {
              Row({ space: 6 }) {
                ForEach(this.ports, (p: number) => {
                  Text(':' + String(p))
                    .fontSize(Tokens.fsFoot)
                    .fontFamily('monospace')
                    .fontWeight(this.selectedPort === p ? FontWeight.Medium : FontWeight.Normal)
                    .fontColor(this.selectedPort === p ? Tokens.accentInk : Tokens.fg)
                    .backgroundColor(this.selectedPort === p ? Tokens.accent : Tokens.surface)
                    .border({ width: 1, color: this.selectedPort === p ? Tokens.accent : Tokens.lineSoft })
                    .borderRadius(Tokens.rPill)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                    .onClick(() => {
                      Haptics.tap();
                      void this.openPort(p, this.subPath);
                    })
                }, (p: number) => 'port-' + String(p))
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .constraintSize({ maxWidth: '48%' })

            TextInput({
              text: this.subPath,
              placeholder: '/子路径'
            })
              .fontSize(Tokens.fsFoot)
              .fontFamily('monospace')
              .fontColor(Tokens.fg)
              .placeholderColor(Tokens.dim2)
              .backgroundColor(Tokens.surface)
              .border({ width: 1, color: Tokens.lineSoft })
              .borderRadius(Tokens.rPill)
              .height(32)
              .layoutWeight(1)
              .padding({ left: 10, right: 8 })
              .onChange((v: string) => {
                this.subPath = v;
              })
              .onSubmit(() => {
                void this.openPort(this.selectedPort, this.subPath);
              })

            Text(this.signing ? '...' : '打开')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.accentInk)
              .backgroundColor(Tokens.accent)
              .borderRadius(Tokens.rPill)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                Haptics.tap();
                void this.openPort(this.selectedPort, this.subPath);
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 第二行：后退 / 前进 / 刷新 / 复制代理链接
          Row({ space: 8 }) {
            Text('< 后退')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.fg)
              .backgroundColor(Tokens.surface)
              .border({ width: 1, color: Tokens.lineSoft })
              .borderRadius(Tokens.rPill)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                this.goBack();
              })

            Text('前进 ›')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.fg)
              .backgroundColor(Tokens.surface)
              .border({ width: 1, color: Tokens.lineSoft })
              .borderRadius(Tokens.rPill)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                this.goForward();
              })

            Text('\u21bb 刷新')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.fg)
              .backgroundColor(Tokens.surface)
              .border({ width: 1, color: Tokens.lineSoft })
              .borderRadius(Tokens.rPill)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                this.reloadWeb();
              })

            Blank()

            Text('复制代理链接')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.accent)
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(Tokens.rPill)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                void this.copyProxyLink();
              })
          }
          .width('100%')
          .margin({ top: 8, bottom: 8 })
          .alignItems(VerticalAlign.Center)

          if (this.err !== '') {
            Text(this.err)
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.err)
              .width('100%')
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .backgroundColor(Tokens.surface)
              .borderRadius(Tokens.rSm)
              .margin({ bottom: 8 })
          }

          if (this.activeUrl !== '') {
            Column() {
              Web({ src: this.activeUrl, controller: this.webCtrl })
                .javaScriptAccess(true)
                .domStorageAccess(true)
                .mixedMode(MixedMode.Compatible)
                .zoomAccess(true)
                .onControllerAttached(() => {
                  this.webReady = true;
                })
                .width('100%')
                .height('100%')
            }
            .width('100%')
            .layoutWeight(1)
            .borderRadius(Tokens.rMd)
            .clip(true)
            .border({ width: 1, color: Tokens.lineSoft })
          } else {
            EmptyState({
              icon: $r('app.media.ic_pc'),
              title: '选择端口开始实时预览',
              hint: '确认电脑端开发服已在对应端口监听后点击打开'
            })
          }
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: 960 })
        .padding({ left: 16, right: 16, top: this.topPad, bottom: this.bottomInset + 12 })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
