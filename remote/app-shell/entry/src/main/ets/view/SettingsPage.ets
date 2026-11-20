import curves from '@ohos.curves';
import { Api, ApiInfo } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { PairPage } from './PairPage';
import { PcPage } from './PcPage';

/** @Builder 按引用传参：整体传对象才会随状态刷新。 */
interface ThemeOpt {
  id: string;
  name: string;
}

interface KVParam {
  k: string;
  v: string;
  mono: boolean;
}

interface NavRow {
  id: string;
  icon: string;
  name: string;
  hint: string;
}

interface ActionRow {
  k: string;
  v: string;
  mono: boolean;
}

const THEMES: ThemeOpt[] = [
  { id: 'dark', name: '深色' },
  { id: 'light', name: '浅色' },
  { id: 'auto', name: '跟随系统' }
];

const NAV_ROWS: NavRow[] = [
  { id: 'pc', icon: '⌂', name: '电脑管理', hint: '连接实况与设备设置' },
  { id: 'pair', icon: '▣', name: '配对这台电脑', hint: '扫码或 6 位配对码' },
  { id: 'appearance', icon: '◐', name: '外观', hint: '主题与显示' },
  { id: 'connect', icon: '⇄', name: '连接', hint: '服务器地址与令牌' },
  { id: 'data', icon: '◍', name: '数据与缓存', hint: '本地存储与清理' },
  { id: 'about', icon: 'ⓘ', name: '关于', hint: '版本与协议' }
];

/**
 * 设置：一级是分组列表，二级是各分组详情（返回箭头回到一级）。
 */
@Component
export struct SettingsPage {
  api: Api = new Api('', '');
  wanBase: string = '';
  token0: string = '';
  onSave: (b: string, t: string) => void = () => {};
  /** 配对成功回调：除了地址与令牌，还要带上电脑自己报的局域网地址 */
  onSaveLan: (b: string, t: string, lan: string[]) => void = () => {};
  themeMode: string = 'auto';
  systemDark: boolean = true;
  onTheme: (m: string) => void = () => {};
  forceWan: boolean = false;
  haptics: boolean = true;
  onHaptics: (v: boolean) => void = () => {};
  onWan: (v: boolean) => void = () => {};
  /** 配对向导里「手动输入电脑IP」的预填值：本机局域网地址 */
  defaultLan: string = '';
  /** 移除此电脑：回到出厂配置 */
  onReset: () => void = () => {};
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @State private info: ApiInfo | null = null;
  @State private base: string = '';
  @State private lan: boolean = false;
  @State private err: string = '';
  @State private loading: boolean = true;
  @State private editBase: string = '';
  @State private editToken: string = '';
  @State private saved: string = '';
  /**
   * 二级菜单的当前分组。用 AppStorage 存，是为了让 Index 的 onBackPress 能看见它：
   * 不共享出去的话，二级页面按返回键会被当成「首页」直接退出应用。
   */
  @StorageLink('settingsSub') sub: string = '';

  aboutToAppear(): void {
    AppStorage.setOrCreate('settingsSub', this.sub);
    this.editBase = this.wanBase;
    this.editToken = this.token0;
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      this.info = await this.api.info();
      this.base = this.api.currentBase();
      this.lan = this.api.isLan();
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private maskToken(token: string): string {
    if (token.length <= 10) return token;
    return token.slice(0, 6) + '…' + token.slice(token.length - 4);
  }

  private themeLabel(): string {
    if (this.themeMode === 'auto') return this.systemDark ? '跟随系统 · 深色' : '跟随系统 · 浅色';
    return this.themeMode === 'dark' ? '深色' : '浅色';
  }

  private doSave(): void {
    const b = this.editBase.trim();
    const t = this.editToken.trim();
    if (b === '' || t === '') {
      this.saved = '不能为空';
      return;
    }
    this.onSave(b, t);
    this.saved = '已保存';
    setTimeout(() => {
      this.saved = '';
      this.load();
    }, 600);
  }

  // ---------- 通用件 ----------

  @Builder
  subHeader(title: string) {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor(Tokens.fg)
        .width(40)
        .textAlign(TextAlign.Start)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.sub = '';
        })
      Column() {
        Text('设置')
          .fontSize(11)
          .fontColor(Tokens.dim2)
        Text(title)
          .fontSize(19)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .margin({ top: 1 })
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
    }
    .width('100%')
    .height(52)
    .margin({ bottom: 10 })
  }

  @Builder
  kv($$: KVParam) {
    Row() {
      Text($$.k)
        .fontSize(13.5)
        .fontColor(Tokens.dim)
        .width(88)
      Text($$.v)
        .fontSize(13.5)
        .fontColor(Tokens.fg)
        .fontFamily($$.mono ? 'monospace' : 'HarmonyOS Sans')
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  card(title: string) {
    Text(title)
      .fontSize(10.5)
      .fontColor(Tokens.dim2)
      .letterSpacing(1.6)
      .margin({ left: 6, bottom: 8 })
  }

  @Builder
  navRow(r: NavRow, last: boolean) {
    Row() {
      Text(r.icon)
        .fontSize(15)
        .fontColor(Tokens.accent)
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .backgroundColor(Tokens.accentSoft)
        .borderRadius(9)
      Column() {
        Text(r.name)
          .fontSize(14.5)
          .fontColor(Tokens.fg)
        Text(r.hint)
          .fontSize(11)
          .fontColor(Tokens.dim2)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
      Text('›')
        .fontSize(18)
        .fontColor(Tokens.dim2)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .onClick(() => {
      this.sub = r.id;
    })
  }

  // ---------- 一级列表 ----------

  @Builder
  deviceCard() {
    Row() {
      Image($r('app.media.app_icon'))
        .width(44)
        .height(44)
        .borderRadius(12)
      Column() {
        Text(this.info !== null ? this.info.host : '连接中…')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.loading ? '检测中…' : (this.err === '' ? (this.lan ? '局域网直连 · 8901' : '公网隧道 · 已连接') : '未连接'))
          .fontSize(11.5)
          .fontColor(this.err === '' ? Tokens.ok : Tokens.err)
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
      if (this.err === '') {
        Row()
          .width(7)
          .height(7)
          .borderRadius(4)
          .backgroundColor(Tokens.ok)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Tokens.glassStrong)
    .border({ width: 1, color: Tokens.glassLine })
    .borderRadius(Tokens.rGroup)
  }

  @Builder
  rootList() {
    Column() {
      this.deviceCard()

      Column() {
        ForEach(NAV_ROWS, (r: NavRow, i: number) => {
          this.navRow(r, i === NAV_ROWS.length - 1)
          if (i < NAV_ROWS.length - 1) {
            Divider().color(Tokens.lineSoft).margin({ left: 56 })
          }
        }, (r: NavRow) => r.id)
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .margin({ top: 18 })

    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ---------- 二级：外观 ----------

  @Builder
  appearanceSub() {
    Column() {
      this.subHeader('外观')
      Column() {
        Row() {
          Text('主题')
            .fontSize(13.5)
            .fontColor(Tokens.dim)
            .layoutWeight(1)
          Row() {
            ForEach(THEMES, (o: ThemeOpt) => {
              Text(o.name)
                .fontSize(11.5)
                .fontColor(this.themeMode === o.id ? Tokens.accentInk : Tokens.dim)
                .backgroundColor(this.themeMode === o.id ? Tokens.accent : Tokens.surface3)
                .borderRadius(999)
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .margin({ left: 6 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                .onClick(() => {
                  this.onTheme(o.id);
                })
            }, (o: ThemeOpt) => o.id)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(VerticalAlign.Center)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        Row() {
          Column() {
            Text('触感反馈')
              .fontSize(13.5)
              .fontColor(Tokens.dim)
            Text('点击、归档、发送时轻振')
              .fontSize(10.5)
              .fontColor(Tokens.dim2)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.haptics })
            .selectedColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onChange((v: boolean) => {
              this.onHaptics(v);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .margin({ top: 10 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ---------- 二级：连接 ----------

  @Builder
  connectSub() {
    Column() {
      this.subHeader('连接')

      Column() {
        this.kv({ k: '方式', v: this.loading ? '检测中…' : (this.lan ? '局域网直连' : '公网隧道'), mono: false })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.kv({ k: '地址', v: this.base !== '' ? this.base : '—', mono: false })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.kv({ k: '令牌', v: this.maskToken(this.api.token), mono: true })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.kv({ k: '状态', v: this.err === '' ? '已连接' : ('失败 · ' + this.err), mono: false })
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)

      Text('公网地址')
        .fontSize(10.5)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.6)
        .margin({ left: 6, top: 18, bottom: 8 })
      Column() {
        Column() {
          Text('隧道域名')
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
            .margin({ bottom: 6 })
          TextInput({ text: this.editBase, placeholder: 'https://your-tunnel.example.com' })
            .height(44)
            .fontSize(13.5)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Tokens.surface2)
            .onChange((v: string) => {
              this.editBase = v;
            })
          Text('访问令牌')
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
            .margin({ top: 12, bottom: 6 })
          TextInput({ text: this.editToken, placeholder: '访问令牌' })
            .type(InputType.Password)
            .height(44)
            .fontSize(13.5)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Tokens.surface2)
            .onChange((v: string) => {
              this.editToken = v;
            })
          Row() {
            Text('只用公网隧道')
              .fontSize(13.5)
              .fontColor(Tokens.fg)
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.forceWan })
              .selectedColor(Tokens.accent)
              .onChange((on: boolean) => {
                this.onWan(on);
              })
          }
          .width('100%')
          .margin({ top: 14 })
          .alignItems(VerticalAlign.Center)

          Row() {
            Text(this.saved)
              .fontSize(11.5)
              .fontColor(Tokens.ok)
              .layoutWeight(1)
            Button(this.saved === '已保存' ? '已保存' : '保存并重连')
              .fontSize(13)
              .height(38)
              .padding({ left: 18, right: 18 })
              .backgroundColor(Tokens.accent)
              .fontColor(Tokens.accentInk)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
              .onClick(() => {
                this.doSave();
              })
          }
          .width('100%')
          .margin({ top: 14 })
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(16)
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ---------- 二级：数据 ----------

  @Builder
  dataSub() {
    Column() {
      this.subHeader('数据与缓存')
      Column() {
        this.kv({ k: '本地设置', v: '服务器地址 · 令牌 · 主题', mono: false })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.kv({ k: '消息', v: '不落地，每次从电脑读取', mono: false })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.kv({ k: '缓存', v: '仅本次运行的内存', mono: false })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.kv({ k: '上传文件', v: '保存在电脑 .dsh/mobile-uploads', mono: false })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.kv({ k: '归档', v: '与桌面控制台共享同一份数据', mono: false })
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .margin({ top: 10 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ---------- 二级：关于 ----------

  @Builder
  aboutSub() {
    Column() {
      this.subHeader('关于')
      Column() {
        this.kv({ k: '客户端', v: 'dsh-mobile 原生 0.1.0', mono: false })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.kv({ k: '服务端', v: this.info !== null ? ('插件 0.1.0 · 设备 ' + this.info.host) : '插件 0.1.0', mono: false })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.kv({ k: '端口', v: '8901', mono: true })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.kv({ k: '数据', v: '只在你的手机与电脑之间', mono: false })
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .margin({ top: 10 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack() {
      // 一级：设置根页
      Column() {
        Text('设置')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.fg)
          .margin({ bottom: 16 })
          .width('100%')
          .textAlign(TextAlign.Start)

        List() {
          ListItem() {
            Column() {
              this.rootList()
            }
            .width('100%')
            .padding({ bottom: 110 })
            .alignItems(HorizontalAlign.Start)
          }
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 58 })
      .alignItems(HorizontalAlign.Start)
      .opacity(this.sub === '' ? 1 : 0)
      .scale({ x: this.sub === '' ? 1 : 0.97, y: this.sub === '' ? 1 : 0.97 })
      .animation({ duration: 320, curve: curves.springCurve(0.62, 0.86, 240, 18) })

      // 二级：整页滑入，顶部左上角是「设置 · 页名」
      if (this.sub !== '') {
        Column() {
          List() {
            ListItem() {
              Column() {
                if (this.sub === 'pc') {
                  PcPage({
                    api: this.api,
                    wanBase: this.wanBase,
                    defaultLan: this.defaultLan,
                    onExit: () => {
                      this.sub = '';
                    },
                    onRemove: () => {
                      this.sub = '';
                      this.onReset();
                    }
                  })
                } else if (this.sub === 'pair') {
                  PairPage({
                    api: this.api,
                    defaultBase: this.defaultLan,
                    onExit: () => {
                      this.sub = '';
                    },
                    onPaired: (b: string, t: string, host: string, lan: string[]) => {
                      this.sub = '';
                      this.onSaveLan(b, t, lan);
                    }
                  })
                } else if (this.sub === 'appearance') {
                  this.appearanceSub()
                } else if (this.sub === 'connect') {
                  this.connectSub()
                } else if (this.sub === 'data') {
                  this.dataSub()
                } else {
                  this.aboutSub()
                }
              }
              .width('100%')
              .padding({ bottom: 110 })
              .alignItems(HorizontalAlign.Start)
            }
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16, top: 54 })
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(this.themeBg)
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ x: '100%' }))
          .animation({ duration: 380, curve: curves.springCurve(0.55, 0.9, 240, 18) }))
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.TopStart)
  }
}
