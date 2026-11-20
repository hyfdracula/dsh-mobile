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
  @State private wanBase: string = DEFAULT_BASE;
  @State private token: string = DEFAULT_TOKEN;
  @State private api: Api = new Api(DEFAULT_BASE, DEFAULT_TOKEN, LAN_BASE);
  @State private themeMode: string = THEME_AUTO;
  @State private forceWan: boolean = false;
  @State private haptics: boolean = true;
  @StorageLink('themeRev') themeRev: number = 0;
  /** 每次重建导航栈自增，40ms 延迟里若已变化就放弃回填 */
  private navRev: number = 0;

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
      const t = await p.get('token', DEFAULT_TOKEN) as string;
      const th = await p.get('theme', THEME_AUTO) as string;
      const fw = await p.get('forceWan', '0') as string;
      const hp = await p.get('haptics', '1') as string;
      const sm = await p.get('sendMode', 'queue') as string;
      const lan = await p.get('lan', '') as string;
      AppStorage.setOrCreate('sendMode', sm === 'steer' ? 'steer' : 'queue');
      this.haptics = hp === '1';
      Haptics.enabled = this.haptics;
      this.forceWan = fw === '1';
      // 旧版本把局域网地址写进了 base（配对时电脑报回来的就是它），
      // 人离开家就再也连不上：这里把它降级成局域网候选，公网地址回退到默认隧道。
      let lanSaved: string = lan;
      if (this.isLanUrl(b)) {
        lanSaved = lanSaved !== '' ? lanSaved : b;
        b = DEFAULT_BASE;
        console.info('DSH_CFG migrate lan-in-base -> ' + lanSaved);
      }
      if (b !== '' && t !== '') {
        this.wanBase = b;
        this.token = t;
        this.api.rebase(b, t, lanSaved);
        this.api.setForceWan(this.forceWan);
        console.info('DSH_CFG loaded base=' + b + ' forceWan=' + this.forceWan + ' lan=' + (lanSaved !== '' ? lanSaved : '-'));
      }
      if (th !== this.themeMode) {
        this.themeMode = th;
        this.applyThemeNow();
      }
    } catch (e) {
      console.error('DSH_CFG load failed :: ' + (e as Error).message);
    }
  }

  private async saveCfg(b: string, t: string, lan: string[] = []): Promise<void> {
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
    this.wanBase = wan;
    this.token = t;
    this.api.rebase(wan, t, lanOne);
    this.api.setForceWan(this.forceWan);
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

  private async saveHaptics(v: boolean): Promise<void> {
    this.haptics = v;
    Haptics.enabled = v;
    if (v) Haptics.soft();
    console.info('DSH_HAP enabled=' + v);
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      await p.put('haptics', v ? '1' : '0');
      await p.flush();
    } catch (e) {
      console.error('DSH_HAP save failed :: ' + (e as Error).message);
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
            haptics: this.haptics,
            defaultLan: LAN_BASE,
            onReset: () => {
              this.saveCfg(DEFAULT_BASE, DEFAULT_TOKEN, [LAN_BASE]);
            },
            onSave: (b: string, t: string) => {
              this.saveCfg(b, t, []);
            },
            onSaveLan: (b: string, t: string, lan: string[]) => {
              this.saveCfg(b, t, lan);
            },
            onTheme: (m: string) => {
              this.saveTheme(m);
            },
            onWan: (v: boolean) => {
              this.saveWan(v);
            },
            onHaptics: (v: boolean) => {
              this.saveHaptics(v);
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
              this.saveCfg(b, t, lan);
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
    .customNavContentTransition((from: NavContentInfo, to: NavContentInfo,
        operation: NavigationOperation): NavigationAnimatedTransition | undefined => {
      return this.navTransition(from, to, operation);
    })
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
    .backgroundColor(this.themeMode === '' ? Tokens.bg : Tokens.bg)
    .width('100%')
    .height('100%')
  }
}
