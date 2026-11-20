import curves from '@ohos.curves';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { Api } from '../common/Api';
import { Mat } from '../common/Mat';
import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { NavFx, NavFxSink } from '../common/NavFx';
import { Notifier } from '../common/Notifier';
import { SessionList } from './SessionList';
import { SettingsPage } from './SettingsPage';

/**
 * 两栏外壳：会话 / 设置。
 * 底栏是悬浮胶囊（毛玻璃 + 投影），选中项图标与文字同时变蓝。
 */
@Component
export struct ShellPage {
  api: Api = new Api('', '');
  wanBase: string = '';
  token0: string = '';
  themeMode: string = 'auto';
  systemDark: boolean = true;
  forceWan: boolean = false;
  haptics: boolean = true;
  defaultLan: string = '';
  onReset: () => void = () => {};
  onSave: (b: string, t: string) => void = () => {};
  onSaveLan: (b: string, t: string, lan: string[]) => void = () => {};
  onTheme: (m: string) => void = () => {};
  onWan: (v: boolean) => void = () => {};
  onHaptics: (v: boolean) => void = () => {};
  @State private idx: number = 0;
  @State private pressIdx: number = -1;
  // 列表页开了重命名弹窗时把底栏收掉，弹窗和蒙层才能盖全屏
  @StorageLink('sheetOpen') sheetOpen: boolean = false;
  private tc: TabsController = new TabsController();
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  /** 转场状态：首页没有 navDestinationId，用 NavFx.HOME 注册给 Navigation 驱动。 */
  @State private fxTx: string = '0%';
  @State private fxOp: number = 1;
  @State private fxSc: number = 1;
  private fxSink: NavFxSink | undefined = undefined;
  /** 通知巡检：会话 id → 上次看到的 updatedAt；同一会话的通知冷却时间 */
  private lastSeen: Map<string, number> = new Map<string, number>();
  private lastNote: Map<string, number> = new Map<string, number>();
  /** 正在盯的会话（id → 标题）：这些每 3 秒单独问一次 running，几秒的任务也不会漏 */
  private watching: Map<string, string> = new Map<string, string>();
  private watchTimer: number = 0;
  private watchBusy: boolean = false;
  private tickN: number = 0;

  aboutToAppear(): void {
    const sink: NavFxSink = {
      apply: (tx: string, op: number, sc: number): void => {
        this.fxTx = tx;
        this.fxOp = op;
        this.fxSc = sc;
      }
    };
    this.fxSink = sink;
    NavFx.register(NavFx.HOME, sink);
    // 先探一次沉浸光感材质能力，日志里能直接看出设备支不支持、算力档位是多少
    try {
      const sup: boolean = uiMaterial.isImmersiveMaterialSupported();
      const lv: string = String(uiMaterial.getGlobalMaterialLevel());
      const st: string = String(uiMaterial.getMaterialInfo().state);
      console.info('DSH_MAT supported=' + sup + ' level=' + lv + ' state=' + st);
    } catch (e) {
      console.info('DSH_MAT probe failed: ' + JSON.stringify(e));
    }
    // 任务完成通知：外壳常驻，聊天页压栈或被切走时也能盯着
    Notifier.ensure();
    this.scanSessions(true);
    this.watchTimer = setInterval(() => {
      this.tickN++;
      // 每 4 拍（12 秒）扫一次全表；盯着的那几个每拍都问，几秒的小任务也能抓到
      if (this.tickN % 4 === 0) {
        this.scanSessions(false);
      }
      this.checkWatching();
    }, 3000);
  }

  /**
   * 扫一遍会话表。updatedAt 变了且已经不跑 → 它刚跑完，直接通知；
   * 还在跑 → 放进 watching 由更快的拍子盯 running。
   * baseline=true 只记基线，避免刚启动把历史会话当成「刚完成」。
   */
  private async scanSessions(baseline: boolean): Promise<void> {
    if (this.watchBusy) {
      return;
    }
    this.watchBusy = true;
    try {
      const rows = await this.api.sessions();
      const open: string = this.openId();
      let changedN: number = 0;
      for (let i = 0; i < rows.length; i++) {
        const row = rows[i];
        const prev = this.lastSeen.get(row.id);
        const changed: boolean = prev !== undefined && row.updatedAt > prev;
        if (changed) {
          changedN++;
        }
        if (!baseline && changed && row.id !== open) {
          const title: string = row.title !== '' ? row.title : '未命名会话';
          if (row.running === true) {
            this.watching.set(row.id, title);
          } else {
            this.notifyDone(row.id, title);
          }
        }
        this.lastSeen.set(row.id, row.updatedAt);
      }
      console.info('DSH_NOTIFY scan rows=' + rows.length + ' changed=' + changedN + ' watching=' + this.watching.size);
    } catch (e) {
      // 后台巡检失败不打扰用户
    }
    this.watchBusy = false;
  }

  /** 被盯住的会话：一问到 running 变 false 就通知并放开。 */
  private async checkWatching(): Promise<void> {
    if (this.watching.size === 0) {
      return;
    }
    const ids: string[] = [];
    this.watching.forEach((v: string, k: string) => {
      ids.push(k);
    });
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      try {
        const r = await this.api.messages(id, 1);
        console.info('DSH_NOTIFY watch id=' + id + ' running=' + String(r.running));
        if (r.running === false) {
          let title: string = '';
          const t = this.watching.get(id);
          if (t !== undefined) {
            title = t;
          }
          this.watching.delete(id);
          if (this.openId() !== id) {
            this.notifyDone(id, title !== '' ? title : '会话');
          }
        }
      } catch (e) {
        this.watching.delete(id);
      }
    }
  }

  private openId(): string {
    const o = AppStorage.get<string>('openSession');
    return o !== undefined ? o : '';
  }

  /** 同一会话 6 秒内只发一条：扫描与盯梢两条路可能同时命中同一次完成。 */
  private notifyDone(id: string, title: string): void {
    const now: number = Date.now();
    let noted: number = 0;
    const n = this.lastNote.get(id);
    if (n !== undefined) {
      noted = n;
    }
    if (now - noted <= 6000) {
      return;
    }
    this.lastNote.set(id, now);
    console.info('DSH_NOTIFY turn finished session=' + id);
    Notifier.done('任务完成', '「' + title + '」已经回复，点开看看', this.noteId(id));
  }

  /**
   * 给每个会话算一个稳定的通知 id：只用 id.length 取模会让等长 id 互相覆盖，
   * 后完成的会话把前一条通知顶掉，用户只看到最后一条。
   */
  private noteId(id: string): number {
    let h: number = 0;
    for (let i = 0; i < id.length; i++) {
      h = (h * 31 + id.charCodeAt(i)) % 100000;
    }
    return 1000 + h;
  }

  aboutToDisappear(): void {
    if (this.watchTimer !== 0) {
      clearInterval(this.watchTimer);
      this.watchTimer = 0;
    }
    const s = this.fxSink;
    if (s !== undefined) {
      NavFx.unregister(NavFx.HOME, s);
    }
  }

  private tint(i: number): string {
    return this.idx === i ? Tokens.accent : Tokens.dim2;
  }

  /** 会话图标：对话气泡 */
  @Builder
  iconChat(on: boolean) {
    Image($r('app.media.ic_chat'))
      .width(23)
      .height(23)
      .fillColor(this.tint(0))
      .objectFit(ImageFit.Contain)
  }

  /** 设置图标：齿轮 */
  @Builder
  iconSettings(on: boolean) {
    Image($r('app.media.ic_gear'))
      .width(23)
      .height(23)
      .fillColor(this.tint(1))
      .objectFit(ImageFit.Contain)
  }

  /**
   * 系统沉浸光感材质（HarmonyOS 6 / API 26）。
   * 只在 Navigation/NavDestination 标题栏与 Tabs 底部 TabBar 里生效，所以底栏必须走 Tabs
   * 自己的 tabBar，自绘浮层再漂亮也拿不到。设备不支持时退回空材质，外观与之前一致。
   */
  private mat(): uiMaterial.Material {
    return Mat.bar();
  }

  /** 底栏单个胶囊：材质铺在容器上，选中态用一层半透明蓝压在最上层（材质会覆盖 backgroundColor）。 */
  /**
   * 底部导航的内容。外层的胶囊和材质交给 Tabs 的浮动样式
   * （barFloatingStyle + systemMaterial）来画：一块底板、一条材质，
   * 两个 tab 只是里面的内容，所以天然是连起来的，不会接缝。
   */
  @Builder
  tabPill(i: number, label: string) {
    Stack() {
      // 按压高亮：白色一层，跟 QQ/微信那样，不用蓝底
      if (this.pressIdx === i) {
        Row()
          .width('100%')
          .height('100%')
          .borderRadius(18)
          .backgroundColor('#26FFFFFF')
          .hitTestBehavior(HitTestMode.None)
      }
      Column() {
        if (i === 0) {
          this.iconChat(this.idx === 0)
        } else {
          this.iconSettings(this.idx === 1)
        }
        Text(label)
          .fontSize(11)
          .fontWeight(this.idx === i ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.tint(i))
          .margin({ top: 4 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .scale({
        x: this.pressIdx === i ? 0.82 : 1,
        y: this.pressIdx === i ? 0.82 : 1
      })
      // 松手会弹过头一点，像被按下去又弹回来
      .animation({ duration: 420, curve: curves.springCurve(0.42, 0.62, 200, 12) })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 6, right: 6, top: 6, bottom: 6 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) this.pressIdx = i;
      else if (e.type === TouchType.Up || e.type === TouchType.Cancel) this.pressIdx = -1;
    })
    .onClick(() => {
      Haptics.tap();
      this.idx = i;
      this.tc.changeIndex(i);
    })
  }

  /** 顶部极淡蓝光，营造沉浸感 */
  @Builder
  topGlow() {
    Row()
      .width('100%')
      .height(220)
      .linearGradient({
        angle: 180,
        colors: [[Tokens.accentGlow, 0.0], ['#00000000', 1.0]]
      })
      .position({ x: 0, y: 0 })
      .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Tabs({ barPosition: BarPosition.End, index: this.idx, controller: this.tc }) {
        TabContent() {
          SessionList({ api: this.api })
        }
        .tabBar(this.tabPill(0, '会话'))

        TabContent() {
          SettingsPage({
            api: this.api,
            wanBase: this.wanBase,
            token0: this.token0,
            themeMode: this.themeMode,
            systemDark: this.systemDark,
            forceWan: this.forceWan,
            haptics: this.haptics,
            defaultLan: this.defaultLan,
            onReset: () => {
              this.onReset();
            },
            onSave: (b: string, t: string) => {
              this.onSave(b, t);
            },
            onSaveLan: (b: string, t: string, lan: string[]) => {
              this.onSaveLan(b, t, lan);
            },
            onTheme: (m: string) => {
              this.onTheme(m);
            },
            onWan: (v: boolean) => {
              this.onWan(v);
            },
            onHaptics: (v: boolean) => {
              this.onHaptics(v);
            }
          })
        }
        .tabBar(this.tabPill(1, '设置'))
      }
      .barHeight(this.sheetOpen ? 0 : 64)
      .barFloatingStyle({
        // 浮岛宽度按屏幕算：320vp 是这套图上的可用宽度，留 16vp 边距。
        barWidth: { smallBarWidth: 288, mediumBarWidth: 288, largeBarWidth: 288 },
        barBottomMargin: 18,
        systemMaterial: this.mat()
      })
      .barMode(BarMode.Fixed)
      // 内容从底栏背后穿过去，材质才有东西可以折射
      .barOverlap(true)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .scrollable(false)
      .animationDuration(0)
      .divider({ strokeWidth: 0 })
      .onChange((i: number) => {
        this.idx = i;
        // 切走设置页时把二级页状态清掉，否则按返回键会被隐藏的设置页吞掉
        if (i !== 1) {
          AppStorage.setOrCreate('settingsSub', '');
        }
      })
      .width('100%')
      .height('100%')

    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
    .translate({ x: this.fxTx })
    .opacity(this.fxOp)
    .scale({ x: this.fxSc, y: this.fxSc })
  }
}
