import preferences from '@ohos.data.preferences';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import common from '@ohos.app.ability.common';
import { Configuration } from '@ohos.app.ability.Configuration';
import curves from '@ohos.curves';
import { Api } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { ChatParam } from '../common/Types';
import { applyTheme, resolveDark, THEME_AUTO } from '../common/Theme';
import { ChatPage } from '../view/ChatPage';
import { AgentsPage } from '../view/AgentsPage';
import { SettingsPage } from '../view/SettingsPage';
import { PresetsPage } from '../view/PresetsPage';
import { PairPage } from '../view/PairPage';
import { ShellPage } from '../view/ShellPage';
import { Haptics } from '../common/Haptics';
import { Machines } from '../common/Machines';
import { NavFx } from '../common/NavFx';

// 首次启动没有内置地址与令牌：先在「配对这台电脑」里扫码或输 6 位码，
// 配对成功后地址与令牌写进本机 preferences，之后的启动都从这里读。
export const DEFAULT_BASE: string = '';
export const DEFAULT_TOKEN: string = '';
export const LAN_BASE: string = '';

const PREF_STORE: string = 'dsh_mobile_cfg';

@Entry
@Component
struct Index {
  @Provide('stack') stack: NavPathStack = new NavPathStack();
  /** 全屏看图的地址：聊天页写，这里负责铺满整屏盖住标题栏 */
  @StorageLink('bigImg') bigImg: string = '';
  @State private wanBase: string = DEFAULT_BASE;
  @State private token: string = DEFAULT_TOKEN;
  @State private api: Api = new Api(DEFAULT_BASE, DEFAULT_TOKEN, LAN_BASE);
  @State private themeMode: string = THEME_AUTO;
  @State private forceWan: boolean = false;
  /** 设置 → 连接 里的「自动切换局域网」开关，默认开 */
  @State private autoLan: boolean = true;
  /** 当前连着的电脑名字（多台电脑共用同一套界面，切换时整体换地址与令牌）。 */
  @State private machineName: string = '';
  @State private haptics: boolean = true;
  @State private hdsOn: boolean = true;
  @StorageLink('themeRev') themeRev: number = 0;
  /** 每次重建导航栈自增，40ms 延迟里若已变化就放弃回填 */
  private navRev: number = 0;
  /** 在线心跳定时器，-1 表示没在跑 */
  private presenceTimer: number = -1;

  /**
   * 从系统设置返回时会走这里：发一个信号让「通知」页重新读一次开关，
   * 否则用户在系统里打开了通知，回到应用还显示「现在没开」。
   */
  onPageShow(): void {
    AppStorage.setOrCreate('notifyProbe', Date.now());
    this.startPresence();
    // 回到前台先重选一次入口：从外面回到家、或切了 Wi-Fi，这一步就能立刻换回局域网
    void this.refreshLan();
    AppStorage.setOrCreate('fgProbe', Date.now());
  }

  onPageHide(): void {
    this.stopPresence(true);
  }

  /**
   * 回前台时的入口自愈：先探一次局域网；走隧道时顺手问一次 /api/info，
   * 把电脑自报的地址合进候选再探一次——电脑换了 IP 只有这条路能学到，
   * 以前 info() 只在「电脑」页里调，用户不进那页就永远停在公网上。
   */
  private async refreshLan(): Promise<void> {
    await this.api.poke();
    if (!this.autoLan || this.forceWan || this.token === '') {
      return;
    }
    // 已经在局域网直连就不用再折腾
    if (this.api.isLan()) {
      return;
    }
    try {
      await this.api.info();
    } catch (e) {
      return;
    }
    if (!this.autoLan || this.forceWan) {
      return;
    }
    if (!this.api.isLan() && this.api.lanCandidates().length > 0) {
      await this.api.poke();
    }
  }

  /**
   * 在线心跳：电脑端据此决定 ask_user_question 卡片归谁。
   *
   * 在前台每 3 秒一次；电脑端 15 秒没收到就算离线，恢复成桌面回答。
   * 退到后台立刻发 online:false，不等超时。
   */
  private startPresence(): void {
    if (this.presenceTimer >= 0) {
      return;
    }
    void this.api.presence(true);
    this.presenceTimer = setInterval(() => {
      void this.api.presence(true);
    }, 3000);
  }

  private stopPresence(say: boolean): void {
    if (this.presenceTimer >= 0) {
      clearInterval(this.presenceTimer);
      this.presenceTimer = -1;
    }
    if (say) {
      void this.api.presence(false);
    }
  }

  aboutToAppear(): void {
    AppStorage.setOrCreate('settingsSub', '');
    this.applyThemeNow();
    this.loadCfg();
  }

  /**
   * 系统返回键：设置里进了二级菜单就先退回一级，别直接退出应用。
   * 其余情况交给 Navigation 自己弹栈。
   */
  onBackPress(): boolean {
    const sub = AppStorage.get<string>('settingsSub');
    if (sub !== undefined && sub !== '') {
      AppStorage.setOrCreate('settingsSub', '');
      Haptics.soft();
      return true;
    }
    return false;
  }

  private systemDark(): boolean {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const cfg: Configuration = ctx.config;
      return cfg.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (e) {
      return true;
    }
  }

  private applyThemeNow(): void {
    applyTheme(this.themeMode, this.systemDark());
  }

  /**
   * 这个地址是不是只在家里能通（局域网/回环）。
   * 用来把「公网地址」和「局域网地址」分开存：配对是在局域网里做的，
   * 电脑报回来的 base 往往是 192.168.x，一旦被当成公网地址存下来，
   * 人离开家以后就没有任何可回退的地址了。
   */
  private isLanUrl(u: string): boolean {
    if (u === '') {
      return false;
    }
    const s = u.replace(/^https?:\/\//i, '').replace(/\/.*$/, '');
    const host = (s.indexOf('[') === 0 ? s.substring(1).split(']')[0] : s.split(':')[0]).toLowerCase();
    if (host === 'localhost' || host === '::1' || host === '0.0.0.0') {
      return true;
    }
    if (host.startsWith('127.') || host.startsWith('10.') || host.startsWith('192.168.') || host.startsWith('fe80') ||
      host.startsWith('fc') || host.startsWith('fd')) {
      return true;
    }
    if (host.startsWith('172.')) {
      const second = Number(host.split('.')[1]);
      if (second >= 16 && second <= 31) {
        return true;
      }
    }
    return false;
  }

  private async loadCfg(): Promise<void> {
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      let b = await p.get('base', DEFAULT_BASE) as string;
      let t = await p.get('token', DEFAULT_TOKEN) as string;
      let t0FromMachine: string = '';
      const th = await p.get('theme', THEME_AUTO) as string;
      const fw = await p.get('forceWan', '0') as string;
      const al = await p.get('autoLan', '') as string;
      const hp = await p.get('haptics', '1') as string;
      const hd = await p.get('hdsOn', '1') as string;
      // 隐源光感现已不再提供开关，历史上被关掉的用户一律回到开启态，避免永久无法恢复
      this.hdsOn = true;
      const lan = await p.get('lan', '') as string;
      // 「忙碌时发送」的偏好已废弃：运行中一律排队，由输入区按钮单独决定插队
      AppStorage.setOrCreate('sendMode', 'queue');
      this.haptics = hp === '1';
      Haptics.enabled = this.haptics;
      this.hdsOn = hd !== '0';
      AppStorage.setOrCreate('hdsOn', true);
      this.forceWan = fw === '1';
      // 老用户只有 forceWan，没有 autoLan：用它推出默认值
      this.autoLan = al === '' ? (fw !== '1') : al === '1';
      // 旧版本把局域网地址写进了 base（配对时电脑报回来的就是它），
      // 人离开家就再也连不上：这里把它降级成局域网候选，公网地址回退到默认隧道。
      let lanSaved: string = lan;
      if (b === '' && lanSaved === '' && DEFAULT_BASE !== '') {
        b = DEFAULT_BASE;
      }
      if (this.isLanUrl(b)) {
        lanSaved = lanSaved !== '' ? lanSaved : b;
        b = DEFAULT_BASE !== '' ? DEFAULT_BASE : '';
        console.info('DSH_CFG migrate lan-in-base -> ' + lanSaved);
      }
      // 没有公网隧道时（开源版默认），局域网地址就是唯一可用地址
      if (b === '' && lanSaved !== '') {
        b = lanSaved;
        console.info('DSH_CFG base from lan -> ' + b);
      }
      // 多电脑：有机器列表时以「当前这台」为准，单机配置只在第一次迁移时用
      const cur = Machines.active();
      if (cur !== null) {
        b = cur.wan;
        t0FromMachine = cur.token;
        lanSaved = cur.lan.length > 0 ? cur.lan[0] : '';
        console.info('DSH_MACH restore ' + cur.name + ' ' + cur.wan);
      } else if (b !== '' && t !== '') {
        Machines.upsert(b, t, lanSaved !== '' ? [lanSaved] : [], '', true);
      }
      if (b !== '' && t0FromMachine !== '') {
        t = t0FromMachine;
      }
      if (b !== '' && t !== '') {
        this.wanBase = b;
        this.token = t;
        this.api.rebase(b, t, lanSaved, cur !== null ? cur.lan : (lanSaved !== '' ? [lanSaved] : []));
        this.api.setForceWan(this.forceWan);
        this.api.setAutoLan(this.autoLan);
        this.machineName = Machines.displayName();
        console.info('DSH_CFG loaded base=' + b + ' forceWan=' + this.forceWan + ' autoLan=' + this.autoLan + ' lan=' + (lanSaved !== '' ? lanSaved : '-'));
      }
      if (th !== this.themeMode) {
        this.themeMode = th;
        this.applyThemeNow();
      }
    } catch (e) {
      console.error('DSH_CFG load failed :: ' + (e as Error).message);
    }
  }

  private async saveCfg(b: string, t: string, lan: string[] = [], name: string = ''): Promise<void> {
    // 先切内存里的连接再落盘：claim 已经把一次性配对码消费掉了，
    // 若存储失败就什么都不做，用户看到「配对成功」却还连着旧电脑。
    // 公网地址与局域网地址必须分开存：配对是在局域网里做的，电脑报回来的
    // base 是 192.168.x，直接当公网地址存下来，人一离开家就没有回退地址了。
    let lanOne: string = lan.length > 0 ? lan[0] : '';
    let wan: string = b;
    if (this.isLanUrl(b)) {
      lanOne = lanOne !== '' ? lanOne : b;
      wan = this.isLanUrl(this.wanBase) || this.wanBase === '' ? DEFAULT_BASE : this.wanBase;
    }
    // 开源版没有默认公网隧道：配对只给出局域网地址时，它就当 base 存下来，
    // 否则重启后 base 为空，应用会退回配对向导（token 还在也没用）。
    if (wan === '' && lanOne !== '') {
      wan = lanOne;
    }
    // 局域网候选要「只增不减」：保存地址时调用方传的是空数组，
    // 旧实现会把候选整组清掉，之后 probeLan 没有地址可试，手机就永久停在公网了。
    // 但候选只属于一台电脑：换电脑（令牌不同）时把上一台的地址带过去，
    // 探针就会带着新令牌去敲旧地址，甚至直接选中旧电脑，所以只在同一台机器上沿用。
    const prev = Machines.active();
    const lanAll: string[] = [];
    if (lanOne !== '') {
      lanAll.push(lanOne);
    }
    if (prev !== null && t !== '' && prev.token === t) {
      for (let i = 0; i < prev.lan.length; i++) {
        if (lanAll.indexOf(prev.lan[i]) < 0) {
          lanAll.push(prev.lan[i]);
        }
      }
      const known: string[] = this.api.lanCandidates();
      for (let i = 0; i < known.length; i++) {
        if (lanAll.indexOf(known[i]) < 0) {
          lanAll.push(known[i]);
        }
      }
    }
    this.wanBase = wan;
    this.token = t;
    this.api.rebase(wan, t, lanOne, lanAll);
    this.machineName = Machines.upsert(wan, t, lanAll, name, true).name;
    AppStorage.setOrCreate('listDirty', Date.now());
    this.api.setForceWan(this.forceWan);
    this.api.setAutoLan(this.autoLan);
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      await p.put('base', wan);
      await p.put('token', t);
      await p.put('lan', lanOne);
      await p.flush();
      console.info('DSH_CFG saved base=' + wan + ' lan=' + (lanOne !== '' ? lanOne : '-'));
    } catch (e) {
      console.error('DSH_CFG save failed :: ' + (e as Error).message);
    }
  }

  /** 切到另一台已配对的电脑：地址、令牌、当前名一起换。 */
  private async switchMachine(id: string): Promise<void> {
    const m = Machines.activate(id);
    if (m === null) {
      return;
    }
    this.wanBase = m.wan;
    this.token = m.token;
    this.machineName = m.name;
    this.api.rebase(m.wan, m.token, m.lan.length > 0 ? m.lan[0] : '', m.lan);
    this.api.setForceWan(this.forceWan);
    this.api.setAutoLan(this.autoLan);
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      await p.put('base', m.wan);
      await p.put('token', m.token);
      await p.put('lan', m.lan.length > 0 ? m.lan[0] : '');
      await p.flush();
    } catch (e) {
      console.error('DSH_MACH switch save fail :: ' + (e as Error).message);
    }
    console.info('DSH_MACH switch ' + m.name + ' ' + m.wan);
    AppStorage.setOrCreate('listDirty', Date.now());
  }

  /** 忘掉一台电脑；删的是当前这台时自动切到剩下的第一台。 */
  private async removeMachine(id: string): Promise<void> {
    Machines.remove(id);
    const cur = Machines.active();
    if (cur !== null) {
      await this.switchMachine(cur.id);
    } else {
      this.machineName = '';
    }
  }

  private async saveAutoLan(v: boolean): Promise<void> {
    this.autoLan = v;
    this.api.setAutoLan(v);
    // 关掉自动切换就等于强制走隧道；重新打开时要把这个状态清掉，否则还是只走隧道
    if (!v) {
      this.forceWan = true;
      this.api.setForceWan(true);
    } else {
      this.forceWan = false;
      this.api.setForceWan(false);
    }
    console.info('DSH_CFG autoLan=' + v);
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      await p.put('autoLan', v ? '1' : '0');
      await p.put('forceWan', v ? '0' : '1');
      await p.flush();
    } catch (e) {
      console.error('DSH_CFG autoLan save failed :: ' + (e as Error).message);
    }
  }

  private async saveWan(v: boolean): Promise<void> {
    this.forceWan = v;
    this.api.setForceWan(v);
    console.info('DSH_CFG forceWan=' + v);
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      await p.put('forceWan', v ? '1' : '0');
      await p.flush();
    } catch (e) {
      console.error('DSH_CFG forceWan save failed :: ' + (e as Error).message);
    }
  }

  private async saveTheme(mode: string): Promise<void> {
    this.themeMode = mode;
    this.applyThemeNow();
    this.rebuildNav();
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      await p.put('theme', mode);
      await p.flush();
    } catch (e) {
      console.error('DSH_THEME save failed :: ' + (e as Error).message);
    }
  }

  /** 换主题后让被压栈的页面用新配色重建，但不把用户送回首页 */
  private rebuildNav(): void {
    try {
      // getAllPathName() 只含压栈页面，首页不是其中一项，所以不能假设第 0 项是首页
      const names: string[] = this.stack.getAllPathName();
      if (names.length === 0) {
        return;
      }
      const params: Object[] = [];
      for (let i = 0; i < names.length; i++) {
        params.push(this.stack.getParamByIndex(i) as ChatParam);
      }
      // 重建不该播转场：清栈和重压栈都关掉动画
      this.stack.clear(false);
      const rev: number = ++this.navRev;
      setTimeout(() => {
        // 这 40ms 里用户可能已经自己点了新页面：那就别再把旧栈压回去
        if (rev !== this.navRev || this.stack.getAllPathName().length !== 0) {
          return;
        }
        for (let i = 0; i < names.length; i++) {
          if (names[i].length === 0) {
            continue;
          }
          this.stack.pushPathByName(names[i], params[i], false);
        }
      }, 40);
    } catch (e) {
      console.error('DSH_THEME rebuild nav failed :: ' + (e as Error).message);
    }
  }

  /** 连点开关时只让最后一次落盘，避免旧值后到覆盖新值 */
  private hapticsSeq: number = 0;

  private async saveHaptics(v: boolean): Promise<void> {
    this.haptics = v;
    Haptics.enabled = v;
    const seq: number = ++this.hapticsSeq;
    if (v) Haptics.soft();
    console.info('DSH_HAP enabled=' + v + ' seq=' + seq);
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      if (seq !== this.hapticsSeq) {
        return;
      }
      await p.put('haptics', v ? '1' : '0');
      await p.flush();
    } catch (e) {
      console.error('DSH_HAP save failed :: ' + (e as Error).message);
    }
  }

  /** 沉浸光感开关：关掉后所有系统材质退回普通底色，并立即重建界面。 */
  private async saveHds(v: boolean): Promise<void> {
    this.hdsOn = v;
    AppStorage.setOrCreate('hdsOn', v);
    if (v) Haptics.soft();
    console.info('DSH_HDS switch=' + v);
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      await p.put('hdsOn', v ? '1' : '0');
      await p.flush();
    } catch (e) {
      console.error('DSH_HDS save failed :: ' + (e as Error).message);
    }
  }

  /** 转场两端：普通页面用 navDestinationId，首页（index -1）用固定键。 */
  private fxIdOf(info: NavContentInfo): string {
    const id: string | undefined = info.navDestinationId;
    if (id !== undefined && id !== '') {
      return id;
    }
    return info.index === -1 ? NavFx.HOME : '';
  }

  /**
   * 自制 push/pop 转场：新页从右侧整屏滑入，旧页同时左移并压暗一点，
   * 形成前后层叠的深度；返回时反向播。系统默认转场在两端同步淡入，
   * 观感上像「翻页」，这里是「推进」。
   */
  private navTransition(from: NavContentInfo, to: NavContentInfo,
      operation: NavigationOperation): NavigationAnimatedTransition | undefined {
    if (operation === NavigationOperation.REPLACE) {
      return undefined;
    }
    if (from.mode === NavDestinationMode.DIALOG || to.mode === NavDestinationMode.DIALOG) {
      return undefined;
    }
    const fromId: string = this.fxIdOf(from);
    const toId: string = this.fxIdOf(to);
    // 有一端没注册（例如宿主自己压进来的页面、onReady 还没跑回来）就退回系统默认，
    // 避免只动一半：新页正常滑入却被当成「已就位」，或旧页移开后没人复位
    if (fromId === '' || toId === '' || !NavFx.has(fromId) || !NavFx.has(toId)) {
      return undefined;
    }
    const isPush: boolean = operation === NavigationOperation.PUSH;
    const anim: NavigationAnimatedTransition = {
      timeout: 1000,
      transition: (proxy: NavigationTransitionProxy) => {
        const tag: string = isPush ? 'push' : 'pop';
        console.info('DSH_NAV start ' + tag + ' from=' + fromId + ' to=' + toId);
        if (isPush) {
          NavFx.apply(fromId, '0%', 1, 1);
          NavFx.apply(toId, '100%', 1, 1);
        } else {
          NavFx.apply(fromId, '0%', 1, 1);
          NavFx.apply(toId, '-8%', 0.82, 0.992);
        }
        let finished: boolean = false;
        const done = (): void => {
          if (finished) {
            return;
          }
          finished = true;
          console.info('DSH_NAV finish ' + tag);
          proxy.finishTransition();
        };
        this.getUIContext().animateTo({
          duration: isPush ? 420 : 380,
          // 鸿蒙原生的观感是「先快后慢、末尾轻轻收住」，比线性更容易读
          curve: curves.cubicBezierCurve(0.2, 0.72, 0.32, 1),
          onFinish: done
        }, () => {
          if (isPush) {
            NavFx.apply(fromId, '-8%', 0.82, 0.992);
            NavFx.apply(toId, '0%', 1, 1);
          } else {
            NavFx.apply(fromId, '100%', 1, 1);
            NavFx.apply(toId, '0%', 1, 1);
          }
        });
      }
    };
    return anim;
  }

  @Builder
  pageMap(name: string, param: ChatParam) {
    if (name === 'chat') {
      ChatPage({ api: this.api, param: param })
    } else if (name === 'agents') {
      AgentsPage({ api: this.api })
    } else if (name === 'presets') {
      PresetsPage({ api: this.api, param: param })
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
    Navigation(this.stack) {
      Stack() {
        ForEach([this.themeRev], (rev: number) => {
          ShellPage({
            api: this.api,
            wanBase: this.wanBase,
            token0: this.token,
            themeMode: this.themeMode,
            systemDark: this.systemDark(),
            forceWan: this.forceWan,
          autoLan: this.autoLan,
            haptics: this.haptics,
            defaultLan: LAN_BASE,
            onReset: () => {
              this.saveCfg(DEFAULT_BASE, DEFAULT_TOKEN, [LAN_BASE]);
            },
            onSave: (b: string, t: string) => {
              this.saveCfg(b, t, []);
            },
            machineName: this.machineName,
            onPickMachine: (id: string) => {
              this.switchMachine(id);
            },
            onRemoveMachine: (id: string) => {
              this.removeMachine(id);
            },
            onAddMachine: (wan: string, token: string, name: string) => {
              this.saveCfg(wan, token, [], name);
            },
            onSaveLan: (b: string, t: string, lan: string[]) => {
              this.saveCfg(b, t, lan);
            },
            onTheme: (m: string) => {
              this.saveTheme(m);
            },
            onAutoLan: (v: boolean) => {
            this.saveAutoLan(v);
          },
          onWan: (v: boolean) => {
              this.saveWan(v);
            },
            onHaptics: (v: boolean) => {
              this.saveHaptics(v);
            },
            onHds: (v: boolean) => {
              this.saveHds(v);
            }
          })
        }, (rev: number) => 'shell-' + rev)

        // 还没配对过：整屏做成连接向导
        if (this.token === '') {
          PairPage({
            api: this.api,
            defaultBase: '',
            onExit: () => {
            },
            onPaired: (b: string, t: string, host: string, lan: string[]) => {
              this.saveCfg(b, t, lan, host);
            }
          })
            .width('100%')
            .height('100%')
            .backgroundColor(Tokens.bg)
        }
      }
      .width('100%')
      .height('100%')
    }
    .navDestination(this.pageMap)
    // 页面转场交给系统：原生推入（新页右侧滑入、旧页视差左移+压暗、左缘右滑跟手返回）
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
    .backgroundColor(this.themeMode === '' ? Tokens.bg : Tokens.bg)
    .width('100%')
    .height('100%')

    // 全屏看图：挂在 Navigation 外面，才能盖住状态栏和标题栏
    if (this.bigImg !== '') {
      Stack({ alignContent: Alignment.Center }) {
        Row()
          .width('100%')
          .height('100%')
          .backgroundColor('#F2000000')
        Image(this.bigImg)
          .width('100%')
          .objectFit(ImageFit.Contain)
      }
      .width('100%')
      .height('100%')
      .onClick(() => {
        this.bigImg = '';
      })
      .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
    }
    }
    .width('100%')
    .height('100%')
  }
}
