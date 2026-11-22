import curves from '@ohos.curves';
import notificationManager from '@ohos.notificationManager';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import pasteboard from '@ohos.pasteboard';
import { Api, ApiInfo, SessionRow } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { PairPage } from './PairPage';
import { PcPage } from './PcPage';
import { StoragePage } from './StoragePage';
import { Notifier } from '../common/Notifier';
import { Machines, Machine } from '../common/Machines';
import { Haptics } from '../common/Haptics';
import { promptAction } from '@kit.ArkUI';

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
  name: string;
  hint: string;
  /** 图标底色：CubeAgent 那种实色小方块 */
  color: string;
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
  { id: 'connect', name: '电脑', hint: '', color: '#2F6BFF' },
  { id: 'appearance', name: '外观', hint: '', color: '#8E6BFF' },
  { id: 'notify', name: '通知', hint: '', color: '#F2A23C' },
  { id: 'storage', name: '存储空间', hint: '', color: '#2EC27E' }
];

/**
 * 设置：一级是分组列表，二级是各分组详情（返回箭头回到一级）。
 */
/**
 * 已配对的电脑列表。
 * 单独做成组件：它挂在 NavDestination 的二级页里，而二级页的内容不会因为
 * 父级 @State 变化重新构建，所以「当前这台」的高亮必须由组件自己的
 * @StorageLink 驱动，切换后才会立刻变。
 */
@Component
struct MachineList {
  @StorageLink('machinesVer') ver: number = 0;
  onPick: (id: string) => void = () => {};
  onRemove: (id: string) => void = () => {};

  @Builder
  row(m: Machine) {
    Row() {
      Column() {
        Row() {
          Text(m.name)
            .fontSize(13.5)
            .fontColor(Tokens.fg)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (m.id === Machines.activeId()) {
            Text('当前')
              .fontSize(9.5)
              .fontColor(Tokens.accent)
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(999)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .margin({ left: 6 })
          }
        }
        .width('100%')
        Text(m.wan)
          .fontSize(10.5)
          .fontColor(Tokens.dim2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (Machines.list().length > 1) {
        Text('×')
          .fontSize(17)
          .fontColor(Tokens.dim2)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .borderRadius(999)
          .onClick(() => {
            Haptics.tap();
            this.onRemove(m.id);
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 10, bottom: 10 })
    .borderRadius(Tokens.rGroup)
    .backgroundColor(m.id === Machines.activeId() ? Tokens.accentSoft : Tokens.surface2)
    .margin({ bottom: 8 })
    .onClick(() => {
      Haptics.tap();
      this.onPick(m.id);
    })
  }

  build() {
    Column() {
      ForEach(Machines.list(), (m: Machine) => {
        this.row(m)
      }, (m: Machine) => m.id + '@' + m.at)
    }
    .width('100%')
  }
}

@Component
export struct SettingsPage {
  api: Api = new Api('', '');
  wanBase: string = '';
  token0: string = '';
  onSave: (b: string, t: string) => void = () => {};
  /** 配对成功回调：除了地址与令牌，还要带上电脑自己报的局域网地址 */
  onSaveLan: (b: string, t: string, lan: string[]) => void = () => {};
  @Prop machineName: string = '';
  /** 电脑列表变化时刷新（Machines 里每次写入都会 bump 这个值） */
  @StorageLink('machinesVer') machinesVer: number = 0;
  /** 从连接页进入配对页时的落点：code / scan / guide */
  @State private pairEntry: string = '';
  /** 「手动添加」小表单：另一台电脑的地址 + 令牌 */
  @State private addOn: boolean = false;
  @State private addBase: string = '';
  @State private addToken: string = '';
  @State private addName: string = '';
  onPickMachine: (id: string) => void = () => {};
  onRemoveMachine: (id: string) => void = () => {};
  onAddMachine: (wan: string, token: string, name: string) => void = () => {};
  themeMode: string = 'auto';
  systemDark: boolean = true;
  onTheme: (m: string) => void = () => {};
  forceWan: boolean = false;
  /** 设置 → 连接：「自动切换局域网」（@Prop：父组件改了这个开关要能跟着刷新） */
  @Prop autoLan: boolean = true;
  // @Watch：父级那份真实值一变就把本地显示同步过来。
  // 只在 aboutToAppear 里抄一次的话，从别的页面改过之后回到这里显示的就是旧值。
  @Prop @Watch('onHapticsProp') haptics: boolean = true;
  // Toggle 是受控组件：只读父级传进来的 haptics 的话，用户点一下界面不会变，
  // 离开再回来又被父级初值顶回去（用户报的「关了以后出来再回去又显示打开」）。
  @State private hapticsUi: boolean = true;

  private onHapticsProp(): void {
    if (this.hapticsUi !== this.haptics) {
      this.hapticsUi = this.haptics;
    }
  }
  /** 当前展开的是哪一条「!」说明（同一时刻只开一个） */
  @State private popId: string = '';
  onHaptics: (v: boolean) => void = () => {};
  hdsOn: boolean = true;
  onHds: (v: boolean) => void = () => {};
  onWan: (v: boolean) => void = () => {};
  onAutoLan: (v: boolean) => void = () => {};
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
  /** 系统通知是否已开（这个页面要能一眼看见并一键去开） */
  @State private notifyOn: boolean = false;
  /** 复制成功的临时提示。 */
  @State private copyTip: string = '';
  /** 版本号取自应用包信息（AppScope/app.json5 的 versionName），与 GitHub Release 保持一致。 */
  @State private verText: string = 'DSH Mobile';
  /** 谁来回答模型的提问：'phone' 手机为主/ 'desktop' 电脑为主（存在电脑上） */
  @State private answerMode: string = 'phone';
  @State private answerBusy: boolean = false;
  /** 这台电脑的会话数（-1 表示还没取到） */
  @State private devCount: number = -1;
  /** 应用回到前台时 Index 会 bump 这个值，用来重新读通知开关 */
  @StorageLink('notifyProbe') @Watch('onNotifyProbe') notifyProbe: number = 0;
  /** 隧道教程是否展开 */
  @State private tunnelOpen: boolean = false;
  /**
   * 二级菜单的当前分组。用 AppStorage 存，是为了让 Index 的 onBackPress 能看见它：
   * 不共享出去的话，二级页面按返回键会被当成「首页」直接退出应用。
   */
  @StorageLink('settingsSub') sub: string = '';
  @State private subDrag: number = 0;
  private subStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.hapticsUi = this.haptics;
    this.readVersion();
    AppStorage.setOrCreate('settingsSub', this.sub);
    this.refreshNotifyState();
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

  /** 顶部同色渐变：内容滚上来时在标题下面淡出，替掉原来那块不透明遮罩 */
  @Builder
  topFade() {
    Row()
      .width('100%')
      .height(124)
      .linearGradient({
        angle: 180,
        colors: [[this.themeBg, 0.0], [this.themeBg, 0.58], ['#00' + this.themeBg.slice(1), 1.0]],
      })
      .hitTestBehavior(HitTestMode.None)
  }

  /** 设置页标题：浮在渐变上，不占布局高度 */
  @Builder
  rootHeader() {
    Row() {
      Text('设置')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(Tokens.fg)
      Blank()
    }
    .width('100%')
    .height(44)
    .padding({ left: 16, right: 16 })
    .margin({ top: 46 })
    .alignItems(VerticalAlign.Center)
  }

  /** 二级页顶部同色渐变：滚上来的内容在浮动标题下面淡出，不留硬边。 */
  /** 悬浮标题行：父级已经留好状态栏高度，这里不再加外边距。 */
  /** 扫码钮：和返回键同款玻璃，放在标题行右端，随标题一起悬浮，不跟着内容滚走。 */
  @Builder
  headerScanButton() {
    Stack() {
      Image($r('app.media.ic_scan'))
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
      Haptics.tap();
      this.pairEntry = 'scan';
      this.subStack.pushPathByName('pair', null);
    })
  }

  @Builder
  floatingHeader(title: string, scan: boolean) {
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
        Haptics.tap();
        this.closeSub();
      })
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ left: 12 })
      Blank()
      if (scan) {
        this.headerScanButton()
      }
    }
    .width('100%')
    .height(56)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  subFade() {
    Row()
      .width('100%')
      .height(96)
      .linearGradient({
        angle: 180,
        colors: [[this.themeBg, 0.0], [this.themeBg, 0.58], ['#00' + this.themeBg.slice(1), 1.0]]
      })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  subHeader(title: string) {
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
        Haptics.tap();
        this.closeSub();
      })
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ left: 12 })
      Blank()
    }
    .width('100%')
    .height(56)
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 12 })
  }

  /** 谁来回答提问的两个选项 */
  @Builder
  modeChip(label: string, mode: string) {
    Text(label)
      .fontSize(12.5)
      .fontColor(this.answerMode === mode ? Tokens.accentInk : Tokens.dim)
      .backgroundColor(this.answerMode === mode ? Tokens.accent : Tokens.surface2)
      .borderRadius(999)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .margin({ right: 8 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
      .onClick(() => {
        if (this.answerBusy || this.answerMode === mode) {
          return;
        }
        Haptics.tap();
        this.setAnswerMode(mode);
      })
  }

  private async loadDeviceCount(): Promise<void> {
    try {
      const rows: SessionRow[] = await this.api.sessions();
      this.devCount = rows.length;
    } catch (e) {
      this.devCount = -1;
    }
  }

  private async loadAnswerMode(): Promise<void> {
    try {
      const m: string = await this.api.answerMode();
      if (m === 'phone' || m === 'desktop') {
        this.answerMode = m;
      }
    } catch (e) {
      // 旧插件没这个路由：默认手机为主，不报错
    }
  }

  private async setAnswerMode(mode: string): Promise<void> {
    const old: string = this.answerMode;
    this.answerMode = mode;
    this.answerBusy = true;
    try {
      const m: string = await this.api.setAnswerMode(mode);
      this.answerMode = (m === 'desktop' || m === 'phone') ? m : mode;
    } catch (e) {
      this.answerMode = old;
      this.saved = '改不了：' + (e as Error).message;
    } finally {
      this.answerBusy = false;
    }
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

  /** 每个设置分组一个手绘矢量图标：字形符号在不同字体下粗细乱跳，索性自己画。 */
  @Builder
  navIcon(id: string) {
    if (id === 'connect') {
      Image($r('app.media.ic_set_pc'))
        .width(18)
        .height(18)
        .fillColor('#FFFFFF')
        .objectFit(ImageFit.Contain)
    } else if (id === 'appearance') {
      Image($r('app.media.ic_set_look'))
        .width(18)
        .height(18)
        .fillColor('#FFFFFF')
        .objectFit(ImageFit.Contain)
    } else if (id === 'notify') {
      Image($r('app.media.ic_set_bell'))
        .width(18)
        .height(18)
        .fillColor('#FFFFFF')
        .objectFit(ImageFit.Contain)
    } else {
      Image($r('app.media.ic_set_disk'))
        .width(18)
        .height(18)
        .fillColor('#FFFFFF')
        .objectFit(ImageFit.Contain)
    }
  }

  @Builder
  navRow(r: NavRow, last: boolean) {
    Row() {
      Stack() {
        this.navIcon(r.id)
      }
      .width(30)
      .height(30)
      .borderRadius(9)
      .backgroundColor(r.color)
      Text(r.name)
        .fontSize(14.5)
        .fontColor(Tokens.fg)
        .layoutWeight(1)
        .margin({ left: 12 })
      Text('›')
        .fontSize(18)
        .fontColor(Tokens.dim2)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 16, bottom: 16 })
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .onClick(() => {
      if (r.id === 'connect') {
        this.loadAnswerMode();
        this.loadDeviceCount();
      }
      this.subStack.pushPathByName(r.id, null);
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
        Text(this.loading ? '检测中…' : (this.err === '' ? (this.lan ? '已连接 · 局域网' : '已连接 · 公网') : '未连接'))
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
            Divider().color(Tokens.lineSoft).margin({ left: 58 })
          }
        }, (r: NavRow) => r.id)
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .margin({ top: 18 })

      Text(this.verText)
        .fontSize(10.5)
        .fontColor(Tokens.dim2)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 22 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ---------- 标题注解：小感叹号 + 点击弹出说明 ----------

  /**
   * 标题后的小感叹号。以前解释性文字压在标题下面当小字，占地方又抢视线；
   * 现在收进一个「!」，想知道的点一下，不点也看得懂标题。
   */
  @Builder
  hintDot(key: string, text: string) {
    Text('!')
      .fontSize(9.5)
      .fontWeight(FontWeight.Medium)
      .fontColor(Tokens.dim2)
      .textAlign(TextAlign.Center)
      .width(15)
      .height(15)
      .borderRadius(8)
      .border({ width: 1, color: Tokens.isDark ? '#59FFFFFF' : '#33000000' })
      .margin({ left: 6 })
      .bindPopup(this.popId === key, {
        builder: this.hintPop(text),
        placement: Placement.Bottom,
        popupColor: Color.Transparent,
        enableArrow: false,
        radius: 16,
        offset: { x: 0, y: 4 },
        onStateChange: (e) => {
          if (!e.isVisible && this.popId === key) {
            this.popId = '';
          }
        }
      })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .onClick(() => {
        Haptics.tap();
        this.popId = this.popId === key ? '' : key;
      })
  }

  @Builder
  hintPop(text: string) {
    Text(text)
      .fontSize(12)
      .lineHeight(18)
      .fontColor(Tokens.fg)
      .width(232)
      .padding(12)
      .backgroundColor(Tokens.isDark ? '#F21B1F27' : '#F7FFFFFF')
      .borderRadius(14)
      .backdropBlur(20)
      .border({ width: 1, color: Tokens.isDark ? '#33FFFFFF' : '#D9FFFFFF' })
      .shadow({ radius: 20, color: Tokens.isDark ? '#40000000' : '#26000000', offsetY: 6 })
  }

  @Builder
  hintTitle(title: string, text: string, key: string, dim: boolean) {
    Row() {
      Text(title)
        .fontSize(13.5)
        .fontColor(dim ? Tokens.dim : Tokens.fg)
      this.hintDot(key, text)
    }
    .alignItems(VerticalAlign.Center)
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
          Row() {
            this.hintTitle('触感反馈', '点击、归档、发送时轻轻振一下。', 'haptics', true)
          }
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.hapticsUi })
            .selectedColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onChange((v: boolean) => {
              this.hapticsUi = v;
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

  /** 「电脑」区：已经配对的几台，点一行就切过去；右边 × 忘了它。 */
  @Builder
  machineBlock() {
    Text('电脑')
      .fontSize(10.5)
      .fontColor(Tokens.dim2)
      .letterSpacing(1.6)
      .margin({ left: 6, top: 18, bottom: 8 })
    Column() {
      MachineList({
        onPick: (id: string) => {
          this.onPickMachine(id);
          promptAction.showToast({ message: '已切换电脑', duration: 1600 });
        },
        onRemove: (id: string) => {
          this.onRemoveMachine(id);
        }
      })
    }
    .width('100%')

    Row() {
      this.addMachineChip('新手引导', 'guide')
      this.addMachineChip('手动添加', 'manual')
    }
    .width('100%')
    .margin({ top: 2, bottom: 4 })
    .bindSheet($$this.addOn, this.addMachineSheet(), {
      height: '58%',
      dragBar: true,
      showClose: true,
      backgroundColor: Tokens.surface,
      maskColor: '#33000000',
      onDisappear: () => {
        this.addOn = false;
      }
    })
  }

  @Builder
  addMachineChip(label: string, entry: string) {
    Text(label)
      .fontSize(12.5)
      .fontColor(Tokens.accent)
      .backgroundColor(Tokens.accentSoft)
      .borderRadius(999)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .margin({ right: 8 })
      .onClick(() => {
        Haptics.tap();
        if (entry === 'manual') {
          this.addBase = '';
          this.addToken = '';
          this.addName = '';
          this.addOn = true;
          return;
        }
        this.pairEntry = entry;
        this.subStack.pushPathByName('pair', null);
      })
  }

  @Builder
  addMachineSheet() {
    Column() {
      Row() {
        Text('添加电脑')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.fg)
        this.hintDot('add', '填这台电脑的地址和令牌；同一台电脑不用重复加。')
      }
      .margin({ bottom: 14 })

      TextInput({ text: this.addName, placeholder: '名字（可留空）' })
        .height(44)
        .fontSize(13.5)
        .borderRadius(Tokens.rInput)
        .backgroundColor(Tokens.surface2)
        .margin({ bottom: 10 })
        .onChange((v: string) => {
          this.addName = v;
        })
      TextInput({ text: this.addBase, placeholder: 'https://dsh.example.com 或 192.168.1.3:8901' })
        .height(44)
        .fontSize(13.5)
        .borderRadius(Tokens.rInput)
        .backgroundColor(Tokens.surface2)
        .margin({ bottom: 10 })
        .onChange((v: string) => {
          this.addBase = v;
        })
      TextInput({ text: this.addToken, placeholder: '访问令牌' })
        .type(InputType.Password)
        .height(44)
        .fontSize(13.5)
        .borderRadius(Tokens.rInput)
        .backgroundColor(Tokens.surface2)
        .onChange((v: string) => {
          this.addToken = v;
        })

      Row() {
        Text('取消')
          .fontSize(14)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
          .height(46)
          .textAlign(TextAlign.Center)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.surface2)
          .onClick(() => {
            this.addOn = false;
          })
        Text('添加并切换')
          .fontSize(14)
          .fontColor(Tokens.accentInk)
          .layoutWeight(1)
          .height(46)
          .textAlign(TextAlign.Center)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.accent)
          .margin({ left: 10 })
          .onClick(() => {
            const b: string = this.addBase.trim();
            const t: string = this.addToken.trim();
            if (b === '' || t === '') {
              promptAction.showToast({ message: '地址和令牌都要填', duration: 1600 });
              return;
            }
            Haptics.tap();
            this.addOn = false;
            this.onAddMachine(b, t, this.addName.trim());
            promptAction.showToast({ message: '已添加并切换', duration: 1600 });
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: 18 })
  }

  /** 「这台电脑」：名称/地址/插件版本/会话数 + 重连 + 移除。 */
  @Builder
  deviceBlock() {
    Text('这台电脑')
      .fontSize(10.5)
      .fontColor(Tokens.dim2)
      .letterSpacing(1.6)
      .margin({ left: 6, top: 18, bottom: 8 })
    Column() {
      this.devRow('名称', this.machineName !== '' ? this.machineName : '—', false)
      Divider().color(Tokens.lineSoft).margin({ left: 16 })
      this.devRow('地址', this.base, true)
      Divider().color(Tokens.lineSoft).margin({ left: 16 })
      this.devRow('连接插件', this.info !== null ? this.info.version : '—', false)
      Divider().color(Tokens.lineSoft).margin({ left: 16 })
      this.devRow('会话', this.devCount >= 0 ? (String(this.devCount) + ' 个') : '—', false)
      Divider().color(Tokens.lineSoft).margin({ left: 16 })

      Row() {
        Text('重新连接')
          .fontSize(14)
          .fontColor(Tokens.accent)
          .layoutWeight(1)
        Text('›')
          .fontSize(18)
          .fontColor(Tokens.dim2)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 15, bottom: 15 })
      .alignItems(VerticalAlign.Center)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        Haptics.tap();
        this.load();
        this.loadDeviceCount();
      })

      Divider().color(Tokens.lineSoft).margin({ left: 16 })

      Row() {
        Text('移除此电脑')
          .fontSize(14)
          .fontColor(Tokens.err)
          .layoutWeight(1)
        Text('›')
          .fontSize(18)
          .fontColor(Tokens.dim2)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 15, bottom: 15 })
      .alignItems(VerticalAlign.Center)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        Haptics.tap();
        AlertDialog.show({
          title: '移除此电脑',
          message: '会清掉这台手机和它的配对信息，回到配对向导。电脑端不受影响。',
          primaryButton: {
            value: '取消',
            action: () => {}
          },
          secondaryButton: {
            value: '移除',
            fontColor: Tokens.err,
            action: () => {
              this.closeSub();
              this.onReset();
            }
          }
        });
      })
    }
    .width('100%')
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rGroup)
    .clip(true)
  }

  @Builder
  devRow(label: string, value: string, mono: boolean) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(Tokens.dim)
        .width(84)
      Text(value)
        .fontSize(13)
        .fontColor(Tokens.fg)
        .fontFamily(mono ? 'monospace' : 'sans-serif')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  connectSub() {
    Column() {

      this.machineBlock()

      // 这两项以前塞在「公网地址」卡片里、地址和令牌下面，不填公网信息就像用不了。
      // 其实它们跟公网无关，独立成一张卡，任何时候都能切。
      Column() {
        Row() {
          Row() {
            this.hintTitle('自动切换局域网', '同一个 Wi-Fi 下优先走局域网直连：最快，也不耗公网流量；关掉就只走公网隧道。', 'lan', false)
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          Toggle({ type: ToggleType.Switch, isOn: this.autoLan })
            .selectedColor(Tokens.accent)
            .onChange((on: boolean) => {
              this.onAutoLan(on);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(VerticalAlign.Center)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Column() {
          Row() {
            this.hintTitle('谁来回答提问', '手机为主：你在手机上时选择题直接弹到手机；电脑为主：始终由电脑回答，手机不接选择题。', 'answer', false)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          Row() {
            this.modeChip('手机为主', 'phone')
            this.modeChip('电脑为主', 'desktop')
          }
          .width('100%')
          .margin({ top: 10 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .margin({ top: 12 })

      Text('公网地址')
        .fontSize(10.5)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.6)
        .margin({ left: 6, top: 18, bottom: 8 })
      Column() {
        Column() {
          Text('地址')
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
      // ---------- 在外网怎么用 ----------
      Row() {
        Text('在外网也能用')
          .fontSize(13.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text(this.tunnelOpen ? '收起' : '怎么弄')
          .fontSize(11.5)
          .fontColor(Tokens.accent)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            this.tunnelOpen = !this.tunnelOpen;
          })
      }
      .width('100%')
      .padding(16)
      .onClick(() => {
        this.tunnelOpen = !this.tunnelOpen;
      })

      if (this.tunnelOpen) {
        this.tunnelGuide()
      }

      this.deviceBlock()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 底部导航是浮起来的，最后一块内容要留出它的高度
    .padding({ bottom: 110 })
  }

  /**
   * Cloudflare Tunnel 教程：给「出了家门还想用」的那一步。
   * 命令都写全路径，照着粘就行；只在第一次要配，之后 cloudflared 自己开机起。
   */
  /**
   * Cloudflare Tunnel 教程：给「出了家门还想用」的那一步。
   * 命令都在 Cloudflare 官方文档里能对上（winget 包名、tunnel login/create/route/run、
   * service install），config.yml 用 %USERPROFILE%\.cloudflared\config.yml 这一份。
   */
  @Builder
  tunnelGuide() {
    Column() {
      Row() {
        Text('电脑上装一个 Cloudflare 隧道，手机在 4G/5G 下也能连回来。')
          .fontSize(11.5)
          .fontColor(Tokens.dim2)
          .lineHeight(18)
          .layoutWeight(1)
        Text(this.copyTip === '已复制全部命令' ? '已复制' : '复制全部')
          .fontSize(11)
          .fontColor(Tokens.accent)
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(999)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            this.copyText(this.tunnelScript(), '已复制全部命令');
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      this.guideStep('1', '装 cloudflared（Windows，管理员 PowerShell）',
        'winget install --id Cloudflare.cloudflared\ncloudflared --version')
      this.guideStep('2', '登录 Cloudflare（浏览器里选域名授权）', 'cloudflared tunnel login')
      this.guideStep('3', '建隧道，记下它的 UUID', 'cloudflared tunnel create dsh\ncloudflared tunnel list')
      this.guideStep('4', '把域名指到隧道', 'cloudflared tunnel route dns dsh dsh.你的域名.com')
      this.guideStep('5', '写配置文件 %USERPROFILE%\\.cloudflared\\config.yml',
        'tunnel: <第 3 步的 UUID>\ncredentials-file: C:\\Users\\你\\.cloudflared\\<第 3 步的 UUID>.json\ningress:\n  - hostname: dsh.你的域名.com\n    service: http://127.0.0.1:8901\n  - service: http_status:404')
      this.guideStep('6', '先在窗口里手动跑一次，确认能打开', 'cloudflared tunnel run dsh')
      this.guideStep('7', '确认没问题再装成服务（开机自启）', 'cloudflared service install\nsc query cloudflared')

      Column() {
        Text('回到这个 App')
          .fontSize(11.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
        Text('把 https://dsh.你的域名.com 填进上面「地址」，令牌填电脑端插件面板上那串；' +
          '电脑端面板要允许远程访问。在家连同一个 Wi-Fi 时会自动走局域网，出门走隧道。')
          .fontSize(11)
          .fontColor(Tokens.dim2)
          .lineHeight(17)
          .margin({ top: 4 })
        Text('第 7 步服务读不到配置时，用管理员 PowerShell 换成：' +
          'cloudflared service install --config "C:\\Users\\你\\.cloudflared\\config.yml"')
          .fontSize(10.5)
          .fontColor(Tokens.dim2)
          .lineHeight(16)
          .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(12)
      .backgroundColor(Tokens.accentSoft)
      .borderRadius(12)
      .margin({ top: 10 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 16 })
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rGroup)
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 8 })
  }

  /** 一整套命令，供「复制全部」用（占位符保持原样，粘到终端后逐项替换）。 */
  private tunnelScript(): string {
    return 'winget install --id Cloudflare.cloudflared\n' +
      'cloudflared --version\n' +
      'cloudflared tunnel login\n' +
      'cloudflared tunnel create dsh\n' +
      'cloudflared tunnel list\n' +
      'cloudflared tunnel route dns dsh dsh.你的域名.com\n' +
      '# 下面这段写进 %USERPROFILE%\\.cloudflared\\config.yml，<UUID> 换成第 3 步的隧道 ID\n' +
      'tunnel: <UUID>\n' +
      'credentials-file: C:\\Users\\你\\.cloudflared\\<UUID>.json\n' +
      'ingress:\n' +
      '  - hostname: dsh.你的域名.com\n' +
      '    service: http://127.0.0.1:8901\n' +
      '  - service: http_status:404\n' +
      'cloudflared tunnel run dsh\n' +
      'cloudflared service install\n' +
      'sc query cloudflared';
  }

  private copyText(text: string, tip: string): void {
    if (text === '') {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.copyTip = tip;
        setTimeout(() => {
          this.copyTip = '';
        }, 1600);
      }).catch(() => {
        this.copyTip = '复制失败';
      });
    } catch (e) {
      console.info('DSH_COPY failed ' + JSON.stringify(e));
      this.copyTip = '复制失败';
    }
  }

  @Builder
  guideStep(n: string, title: string, cmd: string) {
    Column() {
      Row() {
        Text(n)
          .fontSize(10.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.accentInk)
          .width(18)
          .height(18)
          .borderRadius(9)
          .textAlign(TextAlign.Center)
          .backgroundColor(Tokens.accent)
        Text(title)
          .fontSize(11.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Column() {
          ForEach(cmd.split('\n'), (line: string, idx: number) => {
            Text(line)
              .fontSize(10.5)
              .fontColor(Tokens.dim)
              .fontFamily('monospace')
              .lineHeight(16)
              .width('100%')
          }, (line: string, idx: number) => String(idx) + line)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          Image($r('app.media.ic_copy'))
            .width(13)
            .height(13)
            .fillColor(Tokens.accent)
        }
        .width(24)
        .height(24)
        .borderRadius(7)
        .backgroundColor(Tokens.surface3)
        .justifyContent(FlexAlign.Center)
        .margin({ left: 6 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => {
          this.copyText(cmd, '已复制');
        })
      }
      .width('100%')
      .padding(10)
      .margin({ top: 6 })
      .backgroundColor(Tokens.surface2)
      .borderRadius(10)
      .alignItems(VerticalAlign.Top)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 12 })
  }

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

  // ---------- 二级：通知 ----------

  private onNotifyProbe(): void {
    this.refreshNotifyState();
  }

  /**
   * 系统那个通知半模态页关掉时不会回调我们（openNotificationSettings 在打开时就 resolve），
   * 所以打开后短时轮询几轮，用户在里面把开关拨开后，这边的状态能自己追上。
   */
  private notifyTimer: number = -1;

  private watchNotifyState(times: number = 24): void {
    if (this.notifyTimer >= 0) {
      clearInterval(this.notifyTimer);
      this.notifyTimer = -1;
    }
    let left = times;
    this.notifyTimer = setInterval(() => {
      left = left - 1;
      this.refreshNotifyState();
      if (left <= 0) {
        clearInterval(this.notifyTimer);
        this.notifyTimer = -1;
      }
    }, 800);
  }

  /** 清掉本应用发出的通知，并把桌面角标归零。 */
  private clearUnread(): void {
    Haptics.tap();
    notificationManager.cancelAll((err: Error) => {
      if (err) {
        console.info('DSH_NOTIFY clear fail ' + err.message);
      } else {
        console.info('DSH_NOTIFY cleared all');
      }
    });
    notificationManager.setBadgeNumber(0).catch((e: Error) => {
      console.info('DSH_NOTIFY badge fail ' + e.message);
    });
    this.refreshNotifyState();
  }

  private readVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.verText = 'DSH Mobile v' + info.versionName;
    } catch (e) {
      console.info('DSH_VER read failed: ' + JSON.stringify(e));
      this.verText = 'DSH Mobile';
    }
  }

  private async refreshNotifyState(): Promise<void> {
    try {
      this.notifyOn = await notificationManager.isNotificationEnabled();
    } catch (e) {
      console.info('DSH_NOTIFY state failed :: ' + (e as Error).message);
    }
  }

  /**
   * 一键去开通知：先跳系统设置里本应用的通知页，跳不过去再退回系统授权弹窗。
   */
  private async openNotifySettings(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    // 首选：系统自带的「本应用通知设置」半模态页，点一下就到开关跟前
    try {
      await notificationManager.openNotificationSettings(ctx);
      console.info('DSH_NOTIFY opened notification settings');
      this.refreshNotifyState();
      this.watchNotifyState();
      return;
    } catch (e) {
      console.info('DSH_NOTIFY openNotificationSettings failed :: ' + (e as Error).message);
    }
    // 退一步：系统授权弹窗
    try {
      await notificationManager.requestEnableNotification(ctx);
      console.info('DSH_NOTIFY requested enable');
      this.refreshNotifyState();
      return;
    } catch (e) {
      console.info('DSH_NOTIFY request failed :: ' + (e as Error).message);
    }
    // 最后：跳应用详情页（那一页里有「通知」入口）
    try {
      const want: Want = {
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility',
        uri: 'application_info_entry',
        parameters: { pushParams: 'com.dsh.mobile' }
      };
      await ctx.startAbility(want);
      console.info('DSH_NOTIFY opened app info');
    } catch (e) {
      console.info('DSH_NOTIFY deeplink failed :: ' + (e as Error).message);
    }
  }

  @Builder
  notifySub() {
    Column() {
      this.subHeader('通知')
      Column() {
        Row() {
          Column() {
            Text('会话结束通知')
              .fontSize(15)
              .fontColor(Tokens.fg)
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Circle()
            .width(8)
            .height(8)
            .fill(this.notifyOn ? Tokens.ok : Tokens.dim2)
            .margin({ right: 6 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 16 })
        .alignItems(VerticalAlign.Center)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Text(this.notifyOn ? '重新打开系统通知设置' : '打开系统通知设置')
            .fontSize(14)
            .fontColor(Tokens.accent)
            .layoutWeight(1)
          Text('›')
            .fontSize(18)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 15, bottom: 15 })
        .alignItems(VerticalAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          this.openNotifySettings();
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Text('发一条测试通知')
            .fontSize(14)
            .fontColor(Tokens.accent)
            .layoutWeight(1)
          Text('›')
            .fontSize(18)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 15, bottom: 15 })
        .alignItems(VerticalAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          // 排查用：能收到就说明「允许通知 + 横幅」都通了，收不到就是系统那侧拦的
          this.refreshNotifyState();
          Notifier.done('测试通知', '能看到这条，说明这台手机的通知是通的', 990001);
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Row() {
            Text('清除未读提醒')
              .fontSize(14)
              .fontColor(Tokens.accent)
            this.hintDot('unread', '清掉通知栏里没点开的消息，以及桌面图标上的角标数字。')
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          Text('›')
            .fontSize(18)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(VerticalAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          this.clearUnread();
        })
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

  /** 真实 NavDestination push：返回时同时收起栈与共享状态。 */
  private closeSub(): void {
    this.sub = '';
    if (this.subStack.size() > 0) {
      this.subStack.pop();
    }
  }

  @Builder
  subDest(name: string) {
    NavDestination() {
      Column() {
        // 存储空间 / 电脑管理自带滚动容器，外面再套一层 List 会把它们的高度压塌，
        // 表现成页面下半截出现一块白板（用户报的「很大的遮罩」）。这两页直接铺进去。
        if (name === 'storage' || name === 'pc') {
          this.subBody(name)
        } else if (name === 'connect') {
          // 连接页和「存储空间」同一套：内容滚到标题下面淡出，标题+返回一直悬浮
          Stack({ alignContent: Alignment.Top }) {
            List() {
              ListItem() {
                Column() {
                  this.subBody(name)
                }
                .width('100%')
                .padding({ bottom: 110 })
                .alignItems(HorizontalAlign.Start)
              }
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .padding({ top: 56 })

            this.subFade()
            this.floatingHeader('电脑', true)
          }
          .width('100%')
          .height('100%')
        } else {
          List() {
            ListItem() {
              Column() {
                this.subBody(name)
              }
              .width('100%')
              .padding({ bottom: 110 })
              .alignItems(HorizontalAlign.Start)
            }
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 54 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.themeBg)
    }
    .hideTitleBar(true)
    .backgroundColor(this.themeBg)
    .onShown(() => {
      this.sub = name;
      // 二级页出现时刷一次：题目回答者偏好、这台电脑的会话数都靠网络，得等页面真正显示再取
      if (name === 'connect') {
        this.loadAnswerMode();
        this.loadDeviceCount();
      }
    })
    .onHidden(() => {
      this.sub = '';
    })
  }

  @Builder
  subBody(name: string) {
    if (name === 'pc') {
      PcPage({
        api: this.api,
        wanBase: this.wanBase,
        defaultLan: this.defaultLan,
        onExit: () => {
          this.closeSub();
        },
        onRemove: () => {
          this.closeSub();
          this.onReset();
        }
      })
    } else if (name === 'pair') {
      PairPage({
        api: this.api,
        defaultBase: this.defaultLan,
        entry: this.pairEntry,
        onExit: () => {
          this.closeSub();
        },
        onPaired: (b: string, t: string, host: string, lan: string[]) => {
          this.closeSub();
          this.onSaveLan(b, t, lan);
        }
      })
    } else if (name === 'appearance') {
      this.appearanceSub()
    } else if (name === 'notify') {
      this.notifySub()
    } else if (name === 'storage') {
      StoragePage({
        onExit: () => {
          this.closeSub();
        }
      })
    } else if (name === 'connect') {
      this.connectSub()
    } else if (name === 'data') {
      this.dataSub()
    } else {
      this.aboutSub()
    }
  }

  build() {
    Navigation(this.subStack) {
      // 内容铺满整屏、标题浮在上面：和首页 headerBlock 同一套设计语言
      Stack({ alignContent: Alignment.Top }) {
        List() {
          ListItem() {
            Column() {
              this.rootList()
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 104, bottom: 110 })
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)

        this.topFade()
        this.rootHeader()
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.subDest)
    .width('100%')
    .height('100%')
  }
}
