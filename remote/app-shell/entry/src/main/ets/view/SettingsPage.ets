import curves from '@ohos.curves';
import preferences from '@ohos.data.preferences';
import notificationManager from '@ohos.notificationManager';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import pasteboard from '@ohos.pasteboard';
import { Api, ApiInfo, SessionRow } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { ago } from '../common/Format';
import { PairPage } from './PairPage';
import { StoragePage } from './StoragePage';
import { FeedbackPage } from './FeedbackPage';
import { Notifier } from '../common/Notifier';
import { Machines, Machine } from '../common/Machines';
import { Drafts } from '../common/Drafts';
import { Outbox } from '../common/Outbox';
import { Marks } from '../common/Marks';
import { Haptics } from '../common/Haptics';
import { Toast } from '../common/Toast';
import { PageHeader, TopFade } from '../common/Chrome';
import { DeviceCard } from './DeviceCard';
import { AboutPanel } from './AboutPanel';
import { DataStoragePanel } from './DataStoragePanel';
import { AppearancePanel } from './AppearancePanel';
import { MachineList } from './MachineList';
import { ConnectForm } from './ConnectForm';
import { AgentSetupCard } from './AgentSetupCard';
import { NotifyPanel } from './NotifyPanel';
import { RowSwitch } from '../common/Widgets';

/** @Builder 按引用传参：整体传对象才会随状态刷新。 */
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

const NAV_ROWS: NavRow[] = [
  { id: 'connect', name: '连接', hint: '电脑、配对与网络', color: '' },
  { id: 'appearance', name: '外观与交互', hint: '主题、字号、触感与动效', color: '' },
  { id: 'notify', name: '通知', hint: '完成提醒与系统权限', color: '' },
  { id: 'data', name: '数据与存储', hint: '缓存、应用数据与导出', color: '' },
  { id: 'about', name: '关于与支持', hint: '版本、诊断、反馈与许可', color: '' }
];
/**
 * 设置：一级是分组列表，二级是各分组详情（返回箭头回到一级）。
 */


@Component
export struct SettingsPage {
  api: Api = new Api('', '');
  @Prop @Watch('onConnProp') wanBase: string = '';
  @Prop @Watch('onConnProp') token0: string = '';
  /** 启动时 loadCfg 是异步的：设置页可能先建好，地址/令牌要等 prop 到达再回填。 */
  private onConnProp(): void {
    if (this.editBase === '' && this.wanBase !== '') {
      this.editBase = this.wanBase;
    }
    if (this.editToken === '' && this.token0 !== '') {
      this.editToken = this.token0;
    }
  }
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
  /** 重命名电脑的小表单：长按电脑行进入。 */
  @State private renameOn: boolean = false;
  @State private renameId: string = '';
  @State private renameName: string = '';
  /** 应用数据条数：进入「数据与存储」时刷新。 */
  @State private draftN: number = 0;
  @State private outN: number = 0;
  @State private markN: number = 0;
  onPickMachine: (id: string) => void = () => {};
  onRemoveMachine: (id: string) => void = () => {};
  onAddMachine: (wan: string, token: string, name: string) => void = () => {};
  themeMode: string = 'auto';
  systemDark: boolean = true;
  onTheme: (m: string) => void = () => {};
  forceWan: boolean = false;
  /** 设置 → 连接：网络策略 auto / lan / wan。 */
  @Prop netMode: string = 'auto';
  onNetMode: (m: string) => void = () => {};
  /** 设置 → 连接：「自动切换局域网」（@Prop：父组件改了这个开关要能跟着刷新） */
  @Prop autoLan: boolean = true;
  // @Watch：父级那份真实值一变就把本地显示同步过来。
  // 只在 aboutToAppear 里抄一次的话，从别的页面改过之后回到这里显示的就是旧值。
  @Prop @Watch('onHapticsProp') haptics: boolean = true;
  // Toggle 是受控组件：只读父级传进来的 haptics 的话，用户点一下界面不会变，
  // 离开再回来又被父级初值顶回去（用户报的「关了以后出来再回去又显示打开」）。
  @State private hapticsUi: boolean = true;
  /** 沉浸光感的界面态：与父级 hdsOn 同步，点一下立刻生效。 */
  @State private hdsUi: boolean = true;
  /** 回车发送：关掉后回车只换行。 */
  @State private enterSendUi: boolean = true;
  /** 正文字号倍率：0.92 / 1 / 1.08。 */
  @State private textScaleUi: number = 1;

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
  /** 应用内开关：回合结束提醒 / 仅后台提醒（系统权限之外的细分）。 */
  @State private notifyDone: boolean = true;
  @State private notifyBgOnly: boolean = true;
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
  /** Index 的返回键与切 tab 都通过这个信号让本页真正 pop 二级栈。 */
  @StorageLink('settingsBack') @Watch('onSettingsBack') settingsBack: number = 0;
  @State private subDrag: number = 0;
  /** 连接方式轮询：入口由 Api 在后台自己换，界面跟着对齐。 */
  private linkTimer: number = -1;
  private subStack: NavPathStack = new NavPathStack();

  private onSettingsBack(): void {
    if (this.sub !== '') {
      this.closeSub();
    }
  }

  aboutToAppear(): void {
    this.hapticsUi = this.haptics;
    this.hdsUi = this.hdsOn;
    this.refreshDataCounts();
    const es: boolean | undefined = AppStorage.get<boolean>('enterSend');
    this.enterSendUi = es !== undefined ? es : true;
    const ts: number | undefined = AppStorage.get<number>('textScale');
    this.textScaleUi = ts !== undefined && ts > 0 ? ts : 1;
    this.readVersion();
    AppStorage.setOrCreate('settingsSub', this.sub);
    this.refreshNotifyState();
    const nd: boolean | undefined = AppStorage.get<boolean>('notifyDone');
    const nb: boolean | undefined = AppStorage.get<boolean>('notifyBgOnly');
    this.notifyDone = nd !== undefined ? nd : true;
    this.notifyBgOnly = nb !== undefined ? nb : true;
    this.editBase = this.wanBase;
    this.editToken = this.token0;
    this.load();
    // 入口会在后台自己切换（离开 Wi-Fi 降到隧道、回到家又换回局域网），
    // 顶部那句「已连接 · 局域网/公网」必须跟着真实入口走，不能是打开页面那一刻的快照。
    this.linkTimer = setInterval(() => {
      const lan: boolean = this.api.isLan();
      if (lan !== this.lan) {
        this.lan = lan;
      }
    }, 2000);
  }

  aboutToDisappear(): void {
    if (this.linkTimer >= 0) {
      clearInterval(this.linkTimer);
      this.linkTimer = -1;
    }
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
  netChip(label: string, mode: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.netMode === mode ? Tokens.accentInk : Tokens.dim)
      .backgroundColor(this.netMode === mode ? Tokens.accent : Tokens.surface2)
      .borderRadius(Tokens.rPill)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .margin({ right: 8 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
      .onClick(() => {
        if (this.netMode === mode) {
          return;
        }
        Haptics.tap();
        this.onNetMode(mode);
      })
  }

  @Builder
  modeChip(label: string, mode: string) {
    Text(label)
      .fontSize(13)
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
  card(title: string) {
    Text(title)
      .fontSize(11)
      .fontColor(Tokens.dim2)
      .letterSpacing(1.6)
      .margin({ left: 6, bottom: 8 })
  }

  /** 每个设置分组一个手绘矢量图标：字形符号在不同字体下粗细乱跳，索性自己画。 */
  @Builder
  navIcon(id: string) {
    Stack() {
      if (id === 'connect') {
        Image($r('app.media.ic_set_pc'))
          .width(18)
          .height(18)
          .fillColor(Tokens.navIconInk)
          .objectFit(ImageFit.Contain)
      } else if (id === 'appearance') {
        Image($r('app.media.ic_set_look'))
          .width(18)
          .height(18)
          .fillColor(Tokens.navIconInk)
          .objectFit(ImageFit.Contain)
      } else if (id === 'notify') {
        Image($r('app.media.ic_set_bell'))
          .width(18)
          .height(18)
          .fillColor(Tokens.navIconInk)
          .objectFit(ImageFit.Contain)
      } else if (id === 'data') {
        Image($r('app.media.ic_set_disk'))
          .width(18)
          .height(18)
          .fillColor(Tokens.navIconInk)
          .objectFit(ImageFit.Contain)
      } else {
        Image($r('app.media.ic_gear'))
          .width(18)
          .height(18)
          .fillColor(Tokens.navIconInk)
          .objectFit(ImageFit.Contain)
      }
    }
    .width(32)
    .height(32)
    .borderRadius(10)
    .backgroundColor(Tokens.navIconBg)
    .alignContent(Alignment.Center)
  }

  @Builder
  navRow(r: NavRow, last: boolean) {
    Row() {
      this.navIcon(r.id)
      Column() {
        Text(r.name)
          .fontSize(15)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (r.hint !== '') {
          Text(r.hint)
            .fontSize(12)
            .fontColor(Tokens.dim2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
      Text('›')
        .fontSize(17)
        .fontColor(Tokens.dim2)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(() => {
      if (r.id === 'connect') {
        this.loadAnswerMode();
        this.loadDeviceCount();
      }
      Haptics.tap();
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
        .borderRadius(14)
      Column() {
        Text(this.info !== null ? this.info.host : '连接中…')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.loading ? '检测中…' : (this.err === '' ? (this.lan ? '已连接 · 局域网' : '已连接 · 公网') : '未连接'))
          .fontSize(12)
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
          .borderRadius(6)
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

      Row() {
        Text(this.verText)
          .fontSize(12)
          .fontColor(Tokens.dim2)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('›')
          .fontSize(17)
          .fontColor(Tokens.dim2)
      }
      .width('100%')
      .padding({ top: 20, bottom: 10 })
      .onClick(() => {
        Haptics.tap();
        this.subStack.pushPathByName('about', null);
      })
      .accessibilityText('关于与支持')
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
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(Tokens.dim2)
      .textAlign(TextAlign.Center)
      .width(15)
      .height(15)
      .borderRadius(10)
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
        .fontSize(13)
        .fontColor(dim ? Tokens.dim : Tokens.fg)
      this.hintDot(key, text)
    }
    .alignItems(VerticalAlign.Center)
  }

  // ---------- 二级：外观 ----------

  

  // ---------- 二级：连接 ----------

  /** 「电脑」区：已经配对的几台，点一行就切过去；右边 × 忘了它。 */
  @Builder
  machineBlock() {
    Text('电脑')
      .fontSize(11)
      .fontColor(Tokens.dim2)
      .letterSpacing(1.6)
      .margin({ left: 6, top: 18, bottom: 8 })
    Column() {
      MachineList({
        onPick: (id: string) => {
          this.onPickMachine(id);
          Toast.ok('已切换电脑');
        },
        onRemove: (id: string) => {
          this.confirmRemoveMachine(id);
        },
        onRename: (id: string, name: string) => {
          this.renameId = id;
          this.renameName = name;
          this.renameOn = true;
        }
      })
    }
    .width('100%')
    .bindSheet($$this.renameOn, this.renameMachineSheet(), {
      height: '34%',
      dragBar: true,
      showClose: true,
      backgroundColor: Tokens.surface,
      maskColor: '#33000000',
      onDisappear: () => {
        this.renameOn = false;
      }
    })

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
      .fontSize(13)
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
        .fontSize(13)
        .borderRadius(Tokens.rInput)
        .backgroundColor(Tokens.surface2)
        .margin({ bottom: 10 })
        .onChange((v: string) => {
          this.addName = v;
        })
      TextInput({ text: this.addBase, placeholder: 'https://dsh.example.com 或 192.168.1.3:8901' })
        .height(44)
        .fontSize(13)
        .borderRadius(Tokens.rInput)
        .backgroundColor(Tokens.surface2)
        .margin({ bottom: 10 })
        .onChange((v: string) => {
          this.addBase = v;
        })
      TextInput({ text: this.addToken, placeholder: '访问令牌' })
        .type(InputType.Password)
        .height(44)
        .fontSize(13)
        .borderRadius(Tokens.rInput)
        .backgroundColor(Tokens.surface2)
        .onChange((v: string) => {
          this.addToken = v;
        })

      Row() {
        Text('取消')
          .fontSize(13)
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
          .fontSize(13)
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
              Toast.err('地址和令牌都要填');
              return;
            }
            Haptics.tap();
            this.addOn = false;
            this.onAddMachine(b, t, this.addName.trim());
            Toast.ok('已添加并切换');
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: 18 })
  }

  /** 长按电脑行 → 重命名。只改显示名，不动地址与令牌。 */
  @Builder
  renameMachineSheet() {
    Column() {
      Text('重命名这台电脑')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(Tokens.fg)
        .margin({ bottom: 14 })
      TextInput({ text: this.renameName, placeholder: '给这台电脑起个名字' })
        .height(44)
        .fontSize(13)
        .borderRadius(Tokens.rInput)
        .backgroundColor(Tokens.surface2)
        .onChange((v: string) => {
          this.renameName = v;
        })
      Row() {
        Text('取消')
          .fontSize(13)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
          .height(46)
          .textAlign(TextAlign.Center)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.surface2)
          .onClick(() => {
            this.renameOn = false;
          })
        Text('保存')
          .fontSize(13)
          .fontColor(Tokens.accentInk)
          .layoutWeight(1)
          .height(46)
          .textAlign(TextAlign.Center)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.accent)
          .margin({ left: 10 })
          .onClick(() => {
            const name: string = this.renameName.trim();
            if (name === '') {
              Toast.err('名字不能为空');
              return;
            }
            Haptics.tap();
            Machines.rename(this.renameId, name);
            this.renameOn = false;
            Toast.ok('已重命名');
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: 18 })
  }

  /** 忘记一台电脑需要确认：会清掉它的地址与令牌。 */
  private confirmRemoveMachine(id: string): void {
    Haptics.tap();
    AlertDialog.show({
      title: '忘记这台电脑',
      message: '会从这台手机上删掉它的地址与令牌；电脑端不受影响。',
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '忘记',
        fontColor: Tokens.err,
        action: () => {
          this.onRemoveMachine(id);
        }
      }
    });
  }

  /** 「这台电脑」：名称/地址/插件版本/会话数 + 重连 + 移除。 */
  @Builder


  @Builder


  @Builder
  connectSub() {
    Column() {

      this.machineBlock()

      // 这两项以前塞在「公网地址」卡片里、地址和令牌下面，不填公网信息就像用不了。
      // 其实它们跟公网无关，独立成一张卡，任何时候都能切。
      Column() {
        Column() {
          Row() {
            this.hintTitle('网络策略', '同一个 Wi-Fi 下优先走局域网：最快，也不耗公网流量。仅局域网不会回退隧道；仅公网强制走隧道。', 'lan', false)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          Row() {
            this.netChip('自动', 'auto')
            this.netChip('仅局域网', 'lan')
            this.netChip('仅公网', 'wan')
          }
          .width('100%')
          .margin({ top: 10 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(HorizontalAlign.Start)

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

      AgentSetupCard()

      Text('连接地址')
        .fontSize(11)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.6)
        .margin({ left: 6, top: 18, bottom: 8 })
      ConnectForm({
        base: $editBase,
        token: $editToken,
        saved: this.saved,
        onSave: (): void => {
          this.doSave();
        }
      })

      // ---------- 在外网怎么用 ----------
      Row() {
        Text('在外网也能用')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text(this.tunnelOpen ? '收起' : '怎么弄')
          .fontSize(12)
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

      DeviceCard({
        name: this.machineName,
        base: this.base,
        pluginVersion: this.info !== null ? this.info.version : '',
        sessions: this.devCount,
        onReconnect: (): void => {
          this.load();
          this.loadDeviceCount();
        },
        onRemove: (): void => {
          AlertDialog.show({
            title: '移除此电脑',
            message: '会清掉这台手机和它的配对信息，回到配对向导。电脑端不受影响。',
            primaryButton: { value: '取消', action: () => {} },
            secondaryButton: {
              value: '移除',
              fontColor: Tokens.err,
              action: () => {
                this.closeSub();
                this.onReset();
              }
            }
          });
        }
      })
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
          .fontSize(12)
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
          .fontSize(12)
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
          .fontSize(11)
          .fontColor(Tokens.dim2)
          .lineHeight(16)
          .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(12)
      .backgroundColor(Tokens.accentSoft)
      .borderRadius(14)
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
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.accentInk)
          .width(18)
          .height(18)
          .borderRadius(10)
          .textAlign(TextAlign.Center)
          .backgroundColor(Tokens.accent)
        Text(title)
          .fontSize(12)
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
              .fontSize(11)
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
        .borderRadius(10)
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

  private refreshDataCounts(): void {
    this.draftN = Drafts.count();
    this.outN = Outbox.countAll();
    this.markN = Marks.count();
  }

  private confirmClearData(what: string): void {
    Haptics.tap();
    const label: string = what === 'draft' ? '草稿' : (what === 'outbox' ? '待发送' : '阅读标记');
    AlertDialog.show({
      title: '清空' + label,
      message: what === 'draft' ? '所有会话里没发出去的草稿都会删掉。'
        : (what === 'outbox' ? '重启后还没重发的影子消息会删掉，已经发出去的不受影响。'
          : '所有会话卡片上的「已完成 / 已中断」标记会清掉。'),
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '清空',
        fontColor: Tokens.err,
        action: () => {
          if (what === 'draft') {
            Drafts.clearAll();
          } else if (what === 'outbox') {
            Outbox.clearAll();
          } else {
            Marks.clearAll();
          }
          this.refreshDataCounts();
          Toast.ok('已清空' + label);
        }
      }
    });
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

  private async saveNotifyPref(key: string, v: boolean): Promise<void> {
    AppStorage.setOrCreate(key, v);
    try {
      const p = await preferences.getPreferences(getContext(this), 'dsh_mobile_cfg');
      await p.put(key, v ? '1' : '0');
      await p.flush();
    } catch (e) {
      console.info('DSH_NOTIFY pref save failed :: ' + (e as Error).message);
    }
  }

  private async saveTextScale(v: number): Promise<void> {
    try {
      const p = await preferences.getPreferences(getContext(this), 'dsh_mobile_cfg');
      await p.put('textScale', String(v));
      await p.flush();
    } catch (e) {
      console.info('DSH_CFG textScale save failed :: ' + (e as Error).message);
    }
  }

  private async saveEnterSend(v: boolean): Promise<void> {
    try {
      const p = await preferences.getPreferences(getContext(this), 'dsh_mobile_cfg');
      await p.put('enterSend', v ? '1' : '0');
      await p.flush();
    } catch (e) {
      console.info('DSH_CFG enterSend save failed :: ' + (e as Error).message);
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

  

  // ---------- 二级：关于 ----------

  

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
      if (name === 'feedback') {
        // 反馈自带整页（头部 + 滚动 + 四个屏），不套外层的内边距与滚动容器
        FeedbackPage({
          onExit: () => {
            this.closeSub();
          }
        })
      } else {
      Column() {
        // 存储空间 / 电脑管理自带滚动容器，外面再套一层 List 会把它们的高度压塌，
        // 表现成页面下半截出现一块白板（用户报的「很大的遮罩」）。这两页直接铺进去。
        if (name === 'storage') {
          this.subBody(name)
        } else if (name === 'connect' || name === 'appearance' || name === 'notify' || name === 'data' || name === 'about') {
          // 连接 / 外观 / 通知同一套：内容滚到标题下淡出，38 玻璃返回 + 20 标题常驻。
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

            TopFade({ fadeHeight: 96 })
            PageHeader({
              title: name === 'connect' ? '电脑' : (name === 'appearance' ? '外观' : (name === 'notify' ? '通知' : (name === 'data' ? '数据与存储' : '关于与支持'))),
              rightKind: name === 'connect' ? 'icon' : 'none',
              rightIcon: $r('app.media.ic_scan'),
              onBack: () => {
                this.closeSub();
              },
              onRight: () => {
                this.pairEntry = 'scan';
                this.subStack.pushPathByName('pair', null);
              }
            })
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
    }
    .hideTitleBar(true)
    .backgroundColor(this.themeBg)
    .onBackPressed(() => {
      // 反馈有「入口 / 提交 / 我的 / 详情」四屏：先在屏内退格，入口屏才关掉整页
      if (name === 'feedback') {
        const at: string | undefined = AppStorage.get<string>('fbStage');
        if (at !== undefined && at !== 'entry') {
          const n: number | undefined = AppStorage.get<number>('fbBack');
          AppStorage.setOrCreate('fbBack', (n === undefined ? 0 : n) + 1);
          return true;
        }
      }
      return false;
    })
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
    if (name === 'pair') {
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
      AppearancePanel({
        themeMode: this.themeMode,
        haptics: this.hapticsUi,
        hds: this.hdsUi,
        enterSend: this.enterSendUi,
        textScale: this.textScaleUi,
        onTheme: (m: string): void => {
          this.onTheme(m);
        },
        onHaptics: (v: boolean): void => {
          this.hapticsUi = v;
          this.onHaptics(v);
        },
        onHds: (v: boolean): void => {
          this.hdsUi = v;
          this.onHds(v);
        },
        onEnterSend: (v: boolean): void => {
          this.enterSendUi = v;
          AppStorage.setOrCreate('enterSend', v);
          this.saveEnterSend(v);
        },
        onTextScale: (v: number): void => {
          this.textScaleUi = v;
          AppStorage.setOrCreate('textScale', v);
          this.saveTextScale(v);
        }
      })
    } else if (name === 'notify') {
      NotifyPanel({
        done: this.notifyDone,
        bgOnly: this.notifyBgOnly,
        allowed: this.notifyOn,
        onDone: (v: boolean): void => {
          this.notifyDone = v;
          this.saveNotifyPref('notifyDone', v);
        },
        onBgOnly: (v: boolean): void => {
          this.notifyBgOnly = v;
          this.saveNotifyPref('notifyBgOnly', v);
        },
        onOpenSettings: (): void => {
          this.openNotifySettings();
        },
        onTest: (): void => {
          this.refreshNotifyState();
          Notifier.done('测试通知', '能看到这条，说明这台手机的通知是通的', 990001);
        },
        onClearUnread: (): void => {
          this.clearUnread();
        }
      })
    } else if (name === 'storage') {
      StoragePage({
        onExit: () => {
          this.closeSub();
        }
      })
    } else if (name === 'connect') {
      this.connectSub()
    } else if (name === 'data') {
      DataStoragePanel({
          draftN: this.draftN,
          outN: this.outN,
          markN: this.markN,
          onStorage: (): void => {
            this.subStack.pushPathByName('storage', null);
          },
          onClear: (what: string): void => {
            this.confirmClearData(what);
          }
        })
    } else {
      AboutPanel({
        rows: [
          { k: '客户端', v: this.verText, mono: false },
          { k: '连接插件', v: this.info !== null ? (this.info.version + ' · ' + this.info.host) : '未连接', mono: false },
          { k: '端口', v: this.info !== null ? String(this.info.port) : '—', mono: true },
          { k: '数据', v: '只在你的手机与电脑之间', mono: false }
        ],
        onFeedback: (): void => {
          this.subStack.pushPathByName('feedback', null);
        },
        onLicense: (): void => {
          Toast.info('许可清单见 GitHub 仓库 README');
        }
      })
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
