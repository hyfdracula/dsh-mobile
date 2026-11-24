import curves from '@ohos.curves';
import { inputMethod } from '@kit.IMEKit';
import { BlurStrategy, HdsNavDestination, HdsNavigationTitleBarOptions, HdsNavigationBackgroundStyle, HdsNavigationTitleBarStyle, ScrollEffectOptions, ScrollEffectType, SystemMaterialParams, TitleBarContentOptions, TitleBarStyleOptions, hdsMaterial } from '@kit.UIDesignKit';
import { Api, AskAnswer, AskOption, AskQuestion, AskState, ContextUsage, Message, PendingAsk, QueuedItem, QueueImage, SessionStats, TokenUsage, CatalogGroup, CatalogModel, EffortRef, ModelRef, ImageRef, AgentRef, MessagesResult, TurnInfo, TurnErr, GoalView } from '../common/Api';
import { Outbox, StashItem, StashImage, SeenImage as OutboxSeenImage } from '../common/Outbox';
import { ChatCache, ChatSnapshot } from '../common/Cache';
import { ImagePart, pickImages, fromUris } from '../common/Images';
import { cameraPicker } from '@kit.CameraKit';
import { camera } from '@kit.CameraKit';
import { common } from '@kit.AbilityKit';
import { FilePart, pickFiles, readFile } from '../common/Files';
import { Tokens } from '../common/Tokens';
import { clock, dayLabel, num, sameDay } from '../common/Format';
import { Drafts } from '../common/Drafts';
import { Marks } from '../common/Marks';
import { ExtrasPanel } from './ExtrasPanel';
import { TypingBubble } from './TypingBubble';
import { PendingImages } from './PendingImages';
import { AttachMenu } from './AttachMenu';
import { MdBody } from './MdBody';
import { MessageImages } from './MessageImages';
import { PendingBoard, PendRow } from './PendingBoard';
import { Net } from '../common/Net';
import { Mat } from '../common/Mat';
import { Haptics } from '../common/Haptics';
import { Toast } from '../common/Toast';
import { Saver } from '../common/Saver';
import { buildSessionMarkdown } from '../common/ExportMd';
import pasteboard from '@ohos.pasteboard';
import window from '@ohos.window';
import { KeyboardAvoidMode as KbMode } from '@ohos.arkui.UIContext';
import { ChatParam } from '../common/Types';
import { MdBlock, MdSeg, parseMd, parseInline } from '../common/Md';

/** 错误卡标题：告诉用户是哪一类问题，而不只是「出错了」。 */
function errTitle(msg: string): string {
  const k: string = Api.kind(msg);
  if (k === 'net') {
    return '网络';
  }
  if (k === 'auth') {
    return '访问令牌';
  }
  if (k === 'parse') {
    return '返回格式';
  }
  if (k === 'nobase') {
    return '未连接';
  }
  if (k === 'http') {
    return '电脑端';
  }
  return '未知';
}

function cmpRate(t: TokenUsage): string {
  const cached = t.cacheReadTokens;
  const total = t.uncachedInputTokens + cached;
  if (total <= 0) return '-';
  return Math.round((cached / total) * 100) + '%';
}


@Component
export struct ChatPage {
  api: Api = new Api('', '');
  param: ChatParam = { id: '', title: '' };
  @Consume('stack') stack: NavPathStack;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('themeDark') themeDark: boolean = true;
  // 键盘高度：改用 NONE 模式自己抬输入区，否则系统会把整页往上顶、顶栏跟着跑掉。
  @State private kbH: number = 0;
  // 先攒着：选好的图片/文件跟着下一条文字一起发，不再选完就单独发一轮。
  @State private pendImgs: ImagePart[] = [];
  @State private pendFiles: FilePart[] = [];
  private kwWin: window.Window | null = null;
  private kwCb: ((h: number) => void) | null = null;
  /** keyboardHeightChange 的原始上报（vp）。个别系统面板会把它当键盘高度报上来，不能全信。 */
  private kwRep: number = 0;
  /** avoidArea 报的底边遮挡高度（vp），这是系统权威值。 */
  private kwAvoid: number = 0;
  private kwAvoidSeen: boolean = false;
  private kwAvoidCb: ((data: window.AvoidAreaOptions) => void) | null = null;
  /** 窗口高度（vp），用来给键盘高度兜一个上限。 */
  private winH: number = 0;
  @State private msgs: Message[] = [];
  /** 正文字号倍率（外观 → 字号）：只缩放消息正文，不动界面控件。 */
  @StorageLink('textScale') textScale: number = 1;
  /** 网络状态：恢复时自动重发影子消息（影子自带幂等键，不会重复）。 */
  @StorageLink('online') @Watch('onOnline') online: boolean = true;
  /** 发送失败时留住原文，错误卡可以直接重试（附件还在 pendImgs/pendFiles 里）。 */
  private retryText: string = '';
  /** 当前这条待发消息的幂等键：失败重试复用同一个键，宿主不会重复提交。 */
  private pendingKey: string = '';
  /** Markdown 解析缓存：key = seq:文本长度，流式增长时会自然失效。 */
  private mdCache: Map<string, MdBlock[]> = new Map<string, MdBlock[]>();
  @State private total: number = 0;
  @State private loading: boolean = true;
  @State private ctx: ContextUsage | null = null;
  /** 用量构成看哪一段：整个会话还是最近一轮 */
  @State private statsScope: string = 'session';
  // 目标（goal）面板：输入框左下环形用量右侧那个靶心图标打开
  @State private goalOn: boolean = false;
  @State private goal: GoalView | null = null;
  @State private goalBusy: boolean = false;
  @State private goalEdit: boolean = false;
  @State private goalDraft: string = '';
  /** 占用构成按谁算百分比：占已用 / 占窗口 */
  @State private mixScope: string = 'used';
  /** 上面还有更早的历史没取过来 */
  @State private hasMore: boolean = false;
  @State private loadingMore: boolean = false;
  @State private err: string = '';
  @State private draft: string = '';
  @State private sending: boolean = false;
  @State private running: boolean = false;
  // 生成中按发送时先停在这里：可改、可删、可插队
  private scroller: Scroller = new Scroller();
  @State private stats: SessionStats | null = null;
  @State private statsOn: boolean = false;
  @State private groups: CatalogGroup[] = [];
  @State private groupsLoaded: boolean = false;
  @State private modelOn: boolean = false;
  /**
   * 收起时的过渡标志。`transition` 只在组件挂载/卸载时给出场动画，而这两个面板的
   * 卸载发生在同一个 if 翻转里，出场动画来不及跑就被摘掉了；所以收起改成先把
   * translate 推上去（属性动画），300ms 后再真正卸载。
   */
  @State private sheetClosing: boolean = false;
  /** 展示用的模型名（目录里的 name，不是 id） */
  @State private curModel: string = '';
  /** 选择器比较用的模型 id，跟展示名分开存，否则「当前」标记永远不亮 */
  @State private curModelId: string = '';
  @State private curEffort: string = '';
  /** ⋯ 菜单的自绘弹层：显式控制展开原点，贴着按钮右上角长出来。 */
  @State private menuOn: boolean = false;
  /** 导出成 Markdown：文本拼装在 common/ExportMd 里，这里只管时间戳与保存。 */
  private async exportMd(): Promise<void> {
    Haptics.tap();
    const title: string = this.param.title !== '' ? this.param.title : '会话';
    const d: Date = new Date();
    const pad = (n: number): string => n < 10 ? '0' + String(n) : String(n);
    const stamp: string = d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
      pad(d.getHours()) + ':' + pad(d.getMinutes());
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const text: string = buildSessionMarkdown(title, this.param.id, this.msgs, stamp);
      const ok: boolean = await Saver.saveText(ctx, text, title + '.md');
      if (ok) {
        Toast.ok('已导出 Markdown');
      }
    } catch (e) {
      Toast.err('导出失败：' + (e as Error).message);
    }
  }

  /** 本会话消息搜索。 */
  @State private searchOn: boolean = false;
  @State private searchQ: string = '';
  @State private bigEditOn: boolean = false;
  @State private attachOn: boolean = false;
  @State private atBottom: boolean = true;
  // 输入卡实测高度：沉底按钮要靠它上移，否则输入框长高后会压在一起
  @State private inputH: number = 0;
  // 长按气泡弹出的「选择文本」面板
  @State private msgMenuOn: boolean = false;
  @State private menuMsg: Message | null = null;
  /** 选择文本面板看的是渲染后的正文，还是 Markdown 原文 */
  @State private selRaw: boolean = false;
  /** 当前展开的是哪一条「!」说明 */
  @State private setPop: string = '';
  /** 消息流里的错误卡：这一轮的原始报错（422 那种长 body 要能看全、能复制） */
  @State private errCard: string = '';
  @State private errCardCode: string = '';
  @State private queueItems: QueuedItem[] = [];
  /** 重启/中断后仍没发出去的那几条（本地影子，见 common/Outbox.ets）。 */
  @State private rescue: StashItem[] = [];
  @State private rescueBusy: boolean = false;
  /** 当前这一屏来自本地缓存（还没拿到网络结果）。 */
  @State private cached: boolean = false;
  @State private queueEditId: string = '';
  /** 待发送卡片：拖动排序时的源下标，以及跟着手指飘起来的那一行标题 */
  @State private pendH: number = 0;
  @State private dragFrom: number = -1;
  @State private dragTitle: string = '';
  @State private pendBusy: boolean = false;
  /** 全屏看图：和 Index 共享，挂在 Navigation 外层才能盖住标题栏 */
  @StorageLink('bigImg') bigImg: string = '';
  @State private editBuf: string = '';
  @State private asks: PendingAsk[] = [];
  /** 题卡的逐题选择：`callId|questionId` -> 已选标签，全部选完才提交 */
  @State private askSel: Record<string, string[]> = {};
  /** 一次问好几题时，每张题卡各自停在第几题 */
  @State private askAt: Record<string, number> = {};
  @State private renaming: boolean = false;
  /** 右上角三块电脑侧内容：'' 关闭，否则 plugins / schedules / files */
  @State private extrasMode: string = '';
  /** 改名后标题要立刻跟着变，param 不是状态变量，改它不会重绘 */
  @State private titleNow: string = '';
  /** 新会话日志还没落盘时的重试次数 */
  private retried: number = 0;
  @State private renameText: string = '';
  /** 更换模型面板里的「智能体协作」：初值读会话日志里的 team/mode */
  @State private teamOn: boolean = false;
  /** 写回途中禁用开关，避免连点发出两个相反的请求 */
  @State private teamBusy: boolean = false;
  /** 写回序号：拨一次 +1，在飞的旧读取不许再覆盖新结果 */
  private teamSeq: number = 0;
  /** 轮询句柄：0 表示没在轮询。 */
  private poller: number = 0;
  @State private agents: AgentRef[] = [];
  /** 生成中三点动画当前亮的那颗 */
  @State private dotOn: number = 0;
  private dotTimer: number = 0;
  /** 页面是否还在栈上：异步回调返回后要先查这个，避免给已销毁的页面写状态 */
  private alive: boolean = false;
  /** 代次：每次进出页面 +1，旧请求的结果一律丢弃 */
  private gen: number = 0;
  /** 新会话 404 时的重试句柄，离页要清掉 */
  private retryTimer: number = 0;

  /** 键盘弹出时只抬输入区，顶栏钉住不动。 */
  private pinKeyboard(): void {
    try {
      this.getUIContext().setKeyboardAvoidMode(KbMode.NONE);
    } catch (e) {
      console.info('DSH_KB avoid mode skipped: ' + JSON.stringify(e));
    }
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      this.kwWin = w;
      try {
        this.winH = px2vp(w.getWindowProperties().windowRect.height);
      } catch (e) {
        this.winH = 0;
      }
      this.kwCb = (h: number) => {
        this.kwRep = h > 0 ? px2vp(h) : 0;
        this.applyKb();
      };
      w.on('keyboardHeightChange', this.kwCb);
      // 有些系统面板（相册选择器、悬浮键盘）会把自己的高度当成键盘高度报上来，
      // 关掉以后又不会补发 0，输入框就被顶到屏幕中间。avoidArea 是系统真实遮挡区，
      // 有它就取两者较小的那个。
      this.kwAvoidCb = (data: window.AvoidAreaOptions) => {
        const area: window.AvoidArea = data.area;
        const px: number = area === undefined || area.bottomRect === undefined ? 0 : area.bottomRect.height;
        this.kwAvoid = px > 0 ? px2vp(px) : 0;
        this.kwAvoidSeen = true;
        this.applyKb();
      };
      w.on('avoidAreaChange', this.kwAvoidCb);
    }).catch((e: Error) => {
      console.info('DSH_KB window failed: ' + e.message);
    });
  }

  /** 把两路键盘高度收敛成一个可信值：以系统遮挡区为准，再兜一个上限。 */
  private applyKb(): void {
    let vp: number = this.kwRep;
    if (this.kwAvoidSeen) {
      // 键盘真正收起时 avoid 会报 0，此时哪怕 keyboardHeightChange 还留着旧值也不能用
      vp = this.kwAvoid <= 0 ? 0 : Math.min(this.kwAvoid, this.kwRep > 0 ? this.kwRep : this.kwAvoid);
    }
    if (this.winH > 0 && vp > this.winH * 0.65) {
      // 超过屏幕 65% 的遮挡高度在这种布局下一定是错的（输入框会被顶到半屏以上）
      console.info('DSH_KB clamp ' + vp.toFixed(0) + ' rep=' + this.kwRep.toFixed(0)
        + ' avoid=' + this.kwAvoid.toFixed(0) + ' win=' + this.winH.toFixed(0));
      vp = this.winH * 0.6;
    }
    // 键盘本身比"可点击区域"高一点（底部还有手势条/工具栏），全量抵扣会显得离得太远，
    // 统一收 16vp，视觉上才是"贴着键盘"。
    if (vp > 0) {
      vp = vp > 16 ? vp - 16 : 0;
    }
    if (vp < 0) {
      vp = 0;
    }
    if (Math.abs(vp - this.kbH) > 0.5) {
      this.kbH = vp;
    }
  }

  private unpinKeyboard(): void {
    if (this.kwWin !== null && this.kwCb !== null) {
      this.kwWin.off('keyboardHeightChange', this.kwCb);
    }
    if (this.kwWin !== null && this.kwAvoidCb !== null) {
      this.kwWin.off('avoidAreaChange', this.kwAvoidCb);
    }
    this.kwWin = null;
    this.kwCb = null;
    this.kwAvoidCb = null;
    this.kwRep = 0;
    this.kwAvoid = 0;
    this.kwAvoidSeen = false;
    this.kbH = 0;
    try {
      this.getUIContext().setKeyboardAvoidMode(KbMode.OFFSET);
    } catch (e) {
      console.info('DSH_KB restore skipped: ' + JSON.stringify(e));
    }
  }

  aboutToAppear(): void {

    this.alive = true;
    this.gen++;
    this.pinKeyboard();
    this.titleNow = this.param.title;
    // 进去看过了，这个会话的「完成/中断」颜色就该消掉，回到列表不再亮
    Marks.clear(this.param.id);
    // 上一轮没发出去的文字要还在
    this.draft = Drafts.get(this.param.id);
    // 让外壳的完成通知知道「这个会话正开着」，别给自己正在看的会话弹通知
    AppStorage.setOrCreate('openSession', this.param.id);
    this.curModelId = this.param.model ?? '';
    this.curModel = '';
    this.curEffort = this.param.effort ?? '';
    this.load();
    this.loadModels();
    this.loadAgents();
    this.loadTeamMode();
    // 这个会话可能在电脑上被别的入口继续推进，手机端不能只靠手动刷新
    this.startPolling();
    this.dotTimer = setInterval(() => {
      if (this.running) {
        this.dotOn = (this.dotOn + 1) % 3;
      }
    }, 380);
  }

  /** 这个会话的子智能体：放在聊天页顶部一条横向成员条里。 */
  private async loadAgents(): Promise<void> {
    try {
      const rows = await this.api.sessions();
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].id === this.param.id) {
          const a = rows[i].agents;
          if (a !== undefined && a.subagents.length > 0) {
            this.agents = a.subagents;
          }
          break;
        }
      }
    } catch (e) {
      // 拿不到就不显示成员条，不影响聊天
    }
  }

  /** 读本会话的智能体协作开关：电脑端把最后一条 team/mode 事件当作当前值。 */
  private async loadTeamMode(): Promise<void> {
    const seq: number = this.teamSeq;
    const g: number = this.gen;
    try {
      const r = await this.api.team(this.param.id);
      // 读的途中拨过开关、或页面已经离开：这次读到的值作废
      if (!this.alive || g !== this.gen || seq !== this.teamSeq) {
        return;
      }
      this.teamOn = r.enabled === true;
    } catch (e) {
      // 读不到就保持原样：开不了团队不该挡住换模型
    }
  }

  /** 失败后回读一次真实状态；回读也失败就返回 undefined，不假装知道结果。 */
  private async confirmTeamMode(seq: number): Promise<boolean | undefined> {
    const g: number = this.gen;
    try {
      const r = await this.api.team(this.param.id);
      if (!this.alive || g !== this.gen || seq !== this.teamSeq) {
        return undefined;
      }
      return r.enabled === true;
    } catch (e) {
      return undefined;
    }
  }

  /** 拨开关：先按新值上屏，结果以电脑端回读为准，失败要把原因说出来。 */
  private async setTeamMode(v: boolean): Promise<void> {
    if (this.teamBusy) {
      return;
    }
    this.teamBusy = true;
    this.teamOn = v;
    Haptics.tap();
    this.teamSeq++;
    const seq: number = this.teamSeq;
    const g: number = this.gen;
    try {
      const on = await this.api.teamMode(this.param.id, v);
      if (!this.alive || g !== this.gen || seq !== this.teamSeq) {
        return;
      }
      this.teamOn = on;
      this.teamFlash(on ? '智能体协作已开启' : '智能体协作已关闭');
    } catch (e) {
      if (!this.alive || g !== this.gen || seq !== this.teamSeq) {
        return;
      }
      // 电脑端可能已经落盘（先追加事件再持久化），回读一次再决定
      const confirmed = await this.confirmTeamMode(seq);
      if (confirmed !== undefined) {
        this.teamOn = confirmed === true;
        this.teamFlash(confirmed === true ? '智能体协作已开启' : '智能体协作已关闭');
      } else {
        Toast.err('切换结果未确认：' + (e as Error).message);
      }
    } finally {
      this.teamBusy = false;
    }
  }

  /** 团队开关的一次性提示：统一走全 App 的轻提示。 */
  private teamFlash(text: string): void {
    Toast.ok(text);
  }

  aboutToDisappear(): void {
    // 切走（返回列表、切 Tab、被系统回收前）都要把没发的文字存下来
    Drafts.set(this.param.id, this.draft);
    Drafts.flush();
    this.unpinKeyboard();
    AppStorage.setOrCreate('openSession', '');
    // 代次 +1 让在飞的请求结果全部作废，重试也要停
    this.alive = false;
    this.gen++;
    if (this.retryTimer !== 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = 0;
    }
    this.stopPolling();
    if (this.dotTimer !== 0) {
      clearInterval(this.dotTimer);
      this.dotTimer = 0;
    }
  }

  private startPolling(): void {
    this.stopPolling();
    this.schedulePoll(1200);
  }

  /** 生成中 1.2 秒拉一次（看起来像在流式吐字），空闲时退到 4 秒省电。 */
  private schedulePoll(ms: number): void {
    if (!this.alive) return;
    this.poller = setTimeout(() => {
      this.pollOnce();
    }, ms);
  }

  private stopPolling(): void {
    if (this.poller !== 0) {
      clearTimeout(this.poller);
      this.poller = 0;
    }
  }

  /** 只取新消息追加，避免每 4 秒搬几十 KB 还把滚动位置打回底部。 */
  private async pollOnce(): Promise<void> {
    if (!this.alive) return;
    if (this.sending || this.loading) {
      this.schedulePoll(1200);
      return;
    }
    const g: number = this.gen;
    const last: number = this.msgs.length > 0 ? this.msgs[this.msgs.length - 1].seq : 0;
    try {
      const r = await this.api.messagesSince(this.param.id, last);
      // 请求飞行途中用户可能已经退出（或换了一轮），此时既不能写状态也不能再排拍子
      if (!this.alive || g !== this.gen) return;
      this.running = r.running === true;
      this.takeLastErr(r.lastErr);
      this.applyQueue(r.queue === undefined ? [] : r.queue);
        const qs: AskState | undefined = r.questions;
        this.asks = qs === undefined || qs.active === undefined ? [] : qs.active;
      if (r.context !== undefined && r.context !== null) {
        this.ctx = r.context;
      }
      // 轮询能拿到数据就说明日志回来了，把之前那次重试失败的红字清掉
      if (this.err !== '') {
        this.err = '';
      }
      if (r.total !== this.total || r.messages.length > 0) {
        const grown: Message[] = this.msgs.concat(this.freshOnly(r.messages));
        await this.api.signAttachments(this.imageIdsOf(grown));
        this.msgs = grown;
        this.total = r.total;
        this.stats = r.stats ?? null;
        // 只有原本就贴着底部时才跟随新消息；用户上滑回看时页面保持不动
        if (this.atBottom) {
          setTimeout(() => {
            this.scroller.scrollEdge(Edge.Bottom);
          }, 80);
        }
      }
    } catch (e) {
      // 轮询失败不打扰用户，等下一次
    }
    this.schedulePoll(this.running ? 1200 : 4000);
  }

  /** 某道题已经选中的标签（题卡逐题累积，最后一次性提交整批答案） */
  private pickedOf(ask: PendingAsk, q: AskQuestion): string[] {
    const hit: string[] | undefined = this.askSel[ask.callId + '|' + q.id];
    return hit === undefined ? [] : hit;
  }

  /**
   * 记下这一题的选中项；只有这道 ask 的每一题都有答案时才提交整批。
   *
   * 宿主要求“每个 question id 恰好一条”，逐题提交会被拒，所以先攒后发；
   * 多问题题卡上先选的题会一直亮着，等最后一题点完再一起走。
   */
  private async answerAsk(ask: PendingAsk, q: AskQuestion, label: string): Promise<void> {
    Haptics.tap();
    const key = ask.callId + '|' + q.id;
    const cur = this.pickedOf(ask, q);
    let picked: string[] = [label];
    if (q.multiSelect === true) {
      picked = cur.indexOf(label) >= 0 ? cur.filter((x: string) => x !== label) : cur.concat([label]);
    }
    const next: Record<string, string[]> = {};
    const keys = Object.keys(this.askSel);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.askSel[keys[i]];
    }
    next[key] = picked;
    this.askSel = next;
    // 多选题：只记录勾选，绝不自动翻页/提交（否则点第一项就走了，来不及选第二项）。
    if (q.multiSelect === true) {
      return;
    }
    // 单选题：答完自动翻到下一题；最后一题且每题都答过才整批提交。
    const idx = this.askIndex(ask);
    if (idx < ask.questions.length - 1) {
      this.askGo(ask, idx + 1);
      return;
    }
    if (this.askDone(ask) < ask.questions.length) {
      return;
    }
    await this.submitAsk(ask);
  }

  /** 把当前选中项整批交回去；多选/多题都走这里。 */
  private async submitAsk(ask: PendingAsk): Promise<void> {
    const answers: AskAnswer[] = [];
    for (let i = 0; i < ask.questions.length; i++) {
      const one = ask.questions[i];
      const hit: string[] | undefined = this.askSel[ask.callId + '|' + one.id];
      if (hit === undefined || hit.length === 0) {
        return;
      }
      answers.push({ id: one.id, selected: hit });
    }
    try {
      await this.api.answerQuestions(this.param.id, ask.callId, answers);
      this.asks = this.asks.filter((x: PendingAsk) => x.callId !== ask.callId);
      Toast.ok('已回答');
      this.schedulePoll(1200);
    } catch (e) {
      this.err = `${e}`;
    }
  }

  /** 一次问好几题时，题卡只显示当前这一题，答完自动翻下一页（和桌面端一样排队答） */
  private askIndex(ask: PendingAsk): number {
    const n = ask.questions.length;
    if (n <= 1) return 0;
    const at: number | undefined = this.askAt[ask.callId];
    const i = at === undefined ? 0 : at;
    if (i < 0) return 0;
    return i >= n ? n - 1 : i;
  }

  private askGo(ask: PendingAsk, i: number): void {
    const n = ask.questions.length;
    let j = i;
    if (j < 0) j = 0;
    if (j > n - 1) j = n - 1;
    const next: Record<string, number> = {};
    const keys = Object.keys(this.askAt);
    for (let k = 0; k < keys.length; k++) {
      next[keys[k]] = this.askAt[keys[k]];
    }
    next[ask.callId] = j;
    this.askAt = next;
  }

  @Builder askCard(ask: PendingAsk, q: AskQuestion) {
    Column({ space: 8 }) {
      Row() {
        Text(q.header === undefined || q.header === '' ? '等待你的操作' : q.header)
          .fontSize(11).fontColor(Tokens.accent).fontWeight(FontWeight.Medium)
        Blank()
        Text(ask.questions.length > 1
          ? `第 ${this.askIndex(ask) + 1} / ${ask.questions.length} 题`
          : '请选择')
          .fontSize(11).fontColor(Tokens.dim2)
      }.width('100%')
      if (ask.questions.length > 1) {
        // 队列感：一条细进度，走到第几题一眼能看到
        Row() {
          Row()
            .width(`${Math.round(((this.askIndex(ask) + 1) * 100) / ask.questions.length)}%`)
            .height(2.5)
            .borderRadius(6)
            .backgroundColor(Tokens.accent)
        }
        .width('100%')
        .height(2.5)
        .borderRadius(6)
        .backgroundColor(Tokens.surface3)
      }
      Text(q.prompt === undefined ? '' : q.prompt).fontSize(13).fontColor(Tokens.fg).width('100%')
      if (q.detail !== undefined && q.detail !== '') {
        Text(q.detail).fontSize(12).fontColor(Tokens.dim).width('100%')
      }
      ForEach(q.options === undefined ? [] : q.options, (o: AskOption) => {
        Row() {
          Text(o.label)
            .fontSize(13)
            .fontColor(this.pickedOf(ask, q).indexOf(o.label) >= 0 ? Tokens.fg : Tokens.accent)
            .fontWeight(this.pickedOf(ask, q).indexOf(o.label) >= 0 ? FontWeight.Medium : FontWeight.Normal)
          Blank()
          Text(this.pickedOf(ask, q).indexOf(o.label) >= 0 ? '已选' : '>')
            .fontSize(12)
            .fontColor(this.pickedOf(ask, q).indexOf(o.label) >= 0 ? Tokens.accent : Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius(14)
        .backgroundColor(this.pickedOf(ask, q).indexOf(o.label) >= 0 ? Tokens.surface : Tokens.surface3)
        .border({
          width: this.pickedOf(ask, q).indexOf(o.label) >= 0 ? 1 : 0,
          color: Tokens.accent,
        })
        .onClick(() => { void this.answerAsk(ask, q, o.label); })
      }, (o: AskOption) => `${ask.callId}-${q.id}-${o.label}`)
      if (ask.questions.length > 1 || q.multiSelect === true) {
        Row() {
          Text(this.askDone(ask) < ask.questions.length
            ? `还差 ${ask.questions.length - this.askDone(ask)} 题`
            : '都答完了，点右边提交')
            .fontSize(11).fontColor(Tokens.dim2)
          Blank()
          if (ask.questions.length > 1 && this.askIndex(ask) > 0) {
            Text('上一题')
              .fontSize(12).fontColor(Tokens.dim)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(999)
              .backgroundColor(Tokens.surface3)
              .margin({ right: 8 })
              .onClick(() => {
                Haptics.tap();
                this.askGo(ask, this.askIndex(ask) - 1);
              })
          }
          if (ask.questions.length > 1 && this.askIndex(ask) < ask.questions.length - 1) {
            Text('下一题')
              .fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor(this.pickedOf(ask, q).length > 0 ? Tokens.accentInk : Tokens.dim2)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .borderRadius(999)
              .backgroundColor(this.pickedOf(ask, q).length > 0 ? Tokens.accent : Tokens.surface3)
              .onClick(() => {
                if (this.pickedOf(ask, q).length === 0) return;
                Haptics.tap();
                this.askGo(ask, this.askIndex(ask) + 1);
              })
          } else {
            Text('提交')
              .fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor(this.pickedOf(ask, q).length > 0 ? Tokens.accentInk : Tokens.dim2)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .borderRadius(999)
              .backgroundColor(this.pickedOf(ask, q).length > 0 ? Tokens.accent : Tokens.surface3)
              .onClick(() => {
                if (this.pickedOf(ask, q).length > 0) {
                  Haptics.tap();
                  void this.submitAsk(ask);
                }
              })
          }
        }.width('100%').margin({ top: 2 })
      }
    }
    .width('100%')
    .padding(12)
    .margin({ bottom: 8 })
    .borderRadius(20)
    .backgroundColor(Tokens.glassFloat)
    .border({ width: 1, color: Tokens.glassLine })
  }

  /** 这道 ask 已有几题选好了 */
  private askDone(ask: PendingAsk): number {
    let n = 0;
    for (let i = 0; i < ask.questions.length; i++) {
      const hit: string[] | undefined = this.askSel[ask.callId + '|' + ask.questions[i].id];
      if (hit !== undefined && hit.length > 0) n += 1;
    }
    return n;
  }

  private async loadGoal(): Promise<void> {
    try {
      this.goal = await this.api.goal(this.param.id);
    } catch (e) {
      this.err = `${e}`;
    }
  }

  private openGoal(): void {
    this.goalEdit = false;
    this.goalOn = true;
    void this.loadGoal();
  }

  private goalPhaseText(): string {
    const ph: string = this.goal === null || this.goal.phase === undefined ? '' : this.goal.phase;
    if (ph === 'active') return '进行中';
    if (ph === 'paused') return '已暂停';
    if (ph === 'complete') return '已完成';
    if (ph === 'blocked') return '被阻塞';
    return ph === '' ? '未知' : ph;
  }

  private async actGoal(action: string): Promise<void> {
    if (this.goalBusy) {
      return;
    }
    this.goalBusy = true;
    Haptics.tap();
    try {
      const next: GoalView | null = await this.api.goalAction(this.param.id, action);
      this.goal = next;
      this.goalEdit = false;
      Toast.ok(action === 'clear' ? '目标已清除' : '目标已更新');
    } catch (e) {
      this.err = `${e}`;
    } finally {
      this.goalBusy = false;
    }
  }

  private async saveGoalEdit(): Promise<void> {
    const text: string = this.goalDraft.trim();
    if (text === '' || this.goalBusy) {
      return;
    }
    this.goalBusy = true;
    try {
      const patch: string = JSON.stringify({ objective: text }).slice(1, -1);
      this.goal = await this.api.goalAction(this.param.id, 'edit', patch);
      this.goalEdit = false;
      Toast.ok('目标已修改');
    } catch (e) {
      this.err = `${e}`;
    } finally {
      this.goalBusy = false;
    }
  }

  @Builder
  goalActionChip(label: string, action: string, strong: boolean) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(strong ? Tokens.accentInk : Tokens.fg)
      .textAlign(TextAlign.Center)
      .padding({ left: 18, right: 18, top: 9, bottom: 9 })
      .borderRadius(999)
      .backgroundColor(strong ? Tokens.accent : Tokens.surface3)
      .opacity(this.goalBusy ? 0.5 : 1)
      .onClick(() => {
        void this.actGoal(action);
      })
  }

  @Builder
  goalBody() {
    Column() {
      Row() {
        Text('目标')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.fg)
        Blank()
        Text('×')
          .fontSize(20)
          .fontColor(Tokens.dim)
          .textAlign(TextAlign.Center)
          .width(38)
          .height(38)
          .borderRadius(999)
          .onClick(() => {
            this.goalOn = false;
          })
      }
      .width('100%')
      .height(56)

      if (this.goal === null) {
        Column({ space: 8 }) {
          Text('这个会话现在没有目标')
            .fontSize(15)
            .fontColor(Tokens.fg)
          Text('目标由对话里的智能体创建，建好之后可以在这里查看、修改、暂停与继续。')
            .fontSize(12)
            .fontColor(Tokens.dim)
            .lineHeight(19)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ top: 18 })
      } else {
        Text(this.goal.objective === undefined ? '' : this.goal.objective)
          .fontSize(15)
          .fontColor(Tokens.fg)
          .lineHeight(23)
          .width('100%')
        Row({ space: 8 }) {
          Text(this.goalPhaseText())
            .fontSize(11)
            .fontColor(Tokens.accent)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .borderRadius(999)
            .backgroundColor(Tokens.accentSoft)
          Text('第 ' + String(this.goal.roundsStarted === undefined ? 0 : this.goal.roundsStarted) +
            ' / ' + String(this.goal.maxGoalRounds === undefined ? 0 : this.goal.maxGoalRounds) + ' 轮')
            .fontSize(11)
            .fontColor(Tokens.dim)
        }
        .width('100%')
        .margin({ top: 12 })

        if (this.goalEdit) {
          TextInput({ text: this.goalDraft, placeholder: '目标内容' })
            .fontSize(13)
            .fontColor(Tokens.fg)
            .backgroundColor(Tokens.surface3)
            .borderRadius(14)
            .height(46)
            .margin({ top: 14 })
            .onChange((v: string) => {
              this.goalDraft = v;
            })
          Row({ space: 10 }) {
            Blank()
            Text('取消')
              .fontSize(13)
              .fontColor(Tokens.dim)
              .padding({ left: 18, right: 18, top: 9, bottom: 9 })
              .borderRadius(999)
              .backgroundColor(Tokens.surface3)
              .onClick(() => {
                this.goalEdit = false;
              })
            Text('保存')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.accentInk)
              .padding({ left: 18, right: 18, top: 9, bottom: 9 })
              .borderRadius(999)
              .backgroundColor(Tokens.accent)
              .onClick(() => {
                void this.saveGoalEdit();
              })
          }
          .width('100%')
          .margin({ top: 10 })
        } else {
          Row({ space: 10 }) {
            if (this.goal.phase === 'active') {
              this.goalActionChip('暂停', 'pause', false)
            }
            if (this.goal.phase === 'paused') {
              this.goalActionChip('继续', 'resume', true)
            }
            Text('修改')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.fg)
              .padding({ left: 18, right: 18, top: 9, bottom: 9 })
              .borderRadius(999)
              .backgroundColor(Tokens.surface3)
              .onClick(() => {
                this.goalDraft = this.goal === null || this.goal.objective === undefined ? '' : this.goal.objective;
                this.goalEdit = true;
              })
            Blank()
            Text('清除')
              .fontSize(13)
              .fontColor(Tokens.err)
              .padding({ left: 6, right: 2, top: 9, bottom: 9 })
              .onClick(() => {
                void this.actGoal('clear');
              })
          }
          .width('100%')
          .margin({ top: 18 })
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 6, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 待发送的三类东西合成一张表：本地图片、本地文件、宿主队列。顺序就是发送顺序。 */
  private pendRows(): PendRow[] {
    const out: PendRow[] = [];
    for (let i = 0; i < this.pendFiles.length; i++) {
      const it: FilePart = this.pendFiles[i];
      out.push({
        key: 'f' + String(i) + it.name,
        kind: 'file',
        idx: i,
        id: '',
        title: it.name,
        sub: '随下一条消息一起发出',
        thumb: '',
      });
    }
    for (let i = 0; i < this.queueItems.length; i++) {
      const q: QueuedItem = this.queueItems[i];
      const hasImg: boolean = q.images !== undefined && q.images.length > 0;
      let title: string = q.text;
      if (title === '') {
        title = hasImg ? ('图片 ' + String(q.images === undefined ? 0 : q.images.length) + ' 张') : '待发送';
      }
      out.push({
        key: 'q' + q.id,
        kind: 'queue',
        idx: i,
        id: q.id,
        title: title,
        sub: '',
        // 队列缩略图走 ?t= 会泄露长期令牌：先不显示缩略图，只用标题的「图片 N 张」。
        thumb: '',
      });
    }
    return out;
  }

  /** 卡片高度：默认露三行，多出来的在卡片里上下滚 */
  private pendCardHeight(): number {
    const n: number = this.pendingTotal();
    const rows: number = n > 3 ? 3 : n;
    // 一条也要紧凑：行高 46，不再额外留白
    return rows * 42 + 2;
  }

  /** 拖动结束后重排：本地两类按新顺序摆放，宿主队列整体重排（插件侧全删重排）。 */
  private pendMove(from: number, to: number): void {
    const rows: PendRow[] = this.pendRows();
    if (from < 0 || from >= rows.length || to < 0 || to >= rows.length || from === to) {
      return;
    }
    const moved: PendRow[] = rows.slice();
    const one: PendRow[] = moved.splice(from, 1);
    moved.splice(to, 0, one[0]);
    const imgs: ImagePart[] = [];
    const files: FilePart[] = [];
    const ids: string[] = [];
    for (const r of moved) {
      if (r.kind === 'img') {
        if (r.idx >= 0 && r.idx < this.pendImgs.length) {
          imgs.push(this.pendImgs[r.idx]);
        }
      } else if (r.kind === 'file') {
        if (r.idx >= 0 && r.idx < this.pendFiles.length) {
          files.push(this.pendFiles[r.idx]);
        }
      } else {
        ids.push(r.id);
      }
    }
    this.pendImgs = imgs;
    this.pendFiles = files;
    const oldIds: string[] = this.queueItems.map((q: QueuedItem) => q.id);
    if (ids.join(',') === oldIds.join(',')) {
      Haptics.tap();
      return;
    }
    Haptics.tap();
    this.api.queueReorder(this.param.id, ids)
      .then(() => {
        Toast.ok('顺序已更新');
        this.load();
      })
      .catch((e: Error) => {
        Toast.err('排序失败：' + e.message);
      });
  }

  /**
   * 按 id 取队列项。
   * 行里的 idx 是「渲染那一刻」的下标：删掉一条之后旧行的点击回调仍可能触发，
   * 直接 queueItems[idx] 会拿到 undefined，再读 .id 就是一次 JS 崩溃。
   */
  private queueById(id: string): QueuedItem | null {
    for (let i = 0; i < this.queueItems.length; i++) {
      if (this.queueItems[i].id === id) {
        return this.queueItems[i];
      }
    }
    return null;
  }

  /** 单条「立即」：队列里的插队到当前轮前面，本地的那一条立刻发出去 */
  private fireRow(r: PendRow): void {
    if (r.kind === 'queue') {
      const q: QueuedItem | null = this.queueById(r.id);
      if (q === null) {
        return;
      }
      this.doQueueFire(q);
      return;
    }
    this.fireLocal(r.kind, r.idx);
  }

  private async fireLocal(kind: string, idx: number): Promise<void> {
    if (this.pendBusy) {
      return;
    }
    const imgs: ImagePart[] = kind === 'img' && idx < this.pendImgs.length ? [this.pendImgs[idx]] : [];
    const files: FilePart[] = kind === 'file' && idx < this.pendFiles.length ? [this.pendFiles[idx]] : [];
    const text: string = this.draft.trim();
    this.pendBusy = true;
    try {
      Haptics.tap();
      await this.api.sendOutbox(this.param.id, text, imgs, files, 'steer');
      if (text !== '') {
        this.draft = '';
        Drafts.set(this.param.id, '');
      }
      if (kind === 'img' && idx < this.pendImgs.length) {
        this.pendImgs.splice(idx, 1);
      }
      if (kind === 'file' && idx < this.pendFiles.length) {
        this.pendFiles.splice(idx, 1);
      }
      Toast.ok('已经插队发出');
      await this.load();
    } catch (e) {
      Toast.err('发不出去：' + (e as Error).message);
    } finally {
      this.pendBusy = false;
    }
  }

  private dropRow(r: PendRow): void {
    if (r.kind === 'queue') {
      const q: QueuedItem | null = this.queueById(r.id);
      if (q === null) {
        return;
      }
      this.doQueueDrop(q);
      return;
    }
    Haptics.tap();
    if (r.kind === 'img') {
      this.dropImg(r.idx);
    } else {
      this.dropFile(r.idx);
    }
  }

  private async doQueueDrop(q: QueuedItem): Promise<void> {
    try {
      await this.api.queueDrop(this.param.id, q.id);
      this.queueItems = this.queueItems.filter((x: QueuedItem) => x.id !== q.id);
      Haptics.tap();
    } catch (e) {
      this.err = '撤不回来：' + (e as Error).message;
    }
  }

  /** 排队条的总条数：电脑队列 + 本地待发图片 + 待发文件，统一在一个横条里显示 */
  private pendingTotal(): number {
    return this.queueItems.length + this.pendImgs.length + this.pendFiles.length;
  }

  private applyQueue(list: QueuedItem[]): void {
    this.queueItems = list;
  }

  private doQueueEdit(q: QueuedItem): void {
    Haptics.tap();
    this.queueEditId = q.id;
    this.editBuf = q.text;
    this.bigEditOn = true;
  }

  private async saveQueueEdit(): Promise<void> {
    const id: string = this.queueEditId;
    if (id === '') {
      return;
    }
    const text: string = this.editBuf.trim();
    if (text === '') {
      Toast.ok('内容不能为空');
      return;
    }
    try {
      await this.api.queueEdit(this.param.id, id, text);
      const out: QueuedItem[] = [];
      for (let i = 0; i < this.queueItems.length; i++) {
        const x: QueuedItem = this.queueItems[i];
        if (x.id === id) {
          const y: QueuedItem = { id: x.id, text: text, at: x.at, index: x.index };
          out.push(y);
        } else {
          out.push(x);
        }
      }
      this.queueItems = out;
      this.queueEditId = '';
      this.editBuf = '';
      this.bigEditOn = false;
      Toast.ok('已更新');
    } catch (e) {
      Toast.err('更新失败：' + (e as Error).message);
    }
  }

  /** 插队：立刻送进电脑，抢在当前轮前面 */
  private async doQueueFire(q: QueuedItem): Promise<void> {
    try {
      Haptics.tap();
      await this.api.queueFire(this.param.id, q.id);
      this.queueItems = this.queueItems.filter((x: QueuedItem) => x.id !== q.id);
      Toast.ok('已插队');
      this.schedulePoll(1200);
    } catch (e) {
      this.err = '插队失败：' + (e as Error).message;
    }
  }

  /**
   * 跟本地影子对账：真发出去了就删；宿主重启把队列丢了、且上一轮是被打断的，
   * 就把影子列成「未发出」让人一键重发。
   */
  private reconcileRescue(r: MessagesResult): void {
    try {
      Outbox.load();
      const seen: string[] = [];
      for (let i = 0; i < r.messages.length; i++) {
        const m: Message = r.messages[i];
        if (m.role === 'user') {
          seen.push((m.text === undefined ? '' : m.text).trim());
        }
      }
      Outbox.settle(this.param.id, seen);
      // 纯图片消息没有正文：用「之后出现的带图用户消息」核销影子。
      const seenImgs: OutboxSeenImage[] = [];
      for (let i = 0; i < r.messages.length; i++) {
        const m: Message = r.messages[i];
        if (m.role === 'user' && m.images !== undefined && m.images.length > 0) {
          seenImgs.push({ at: m.time, count: m.images.length });
        }
      }
      Outbox.settleImages(this.param.id, seenImgs);
      const q: QueuedItem[] = r.queue === undefined ? [] : r.queue;
      const stash: StashItem[] = Outbox.mine(this.param.id);
      const turn: string = r.lastTurn === undefined ? '' : r.lastTurn;
      // 宿主队列为空而磁盘还有影子，就说明它没被真正收下；不能因为上一轮是 completed 就把入口藏起来。
      console.info('DSH_OUTBOX reconcile sid=' + this.param.id + ' q=' + q.length + ' stash=' + stash.length +
        ' turn=' + turn);
      this.rescue = q.length === 0 ? stash : [];
    } catch (e) {
      console.info('DSH_OUTBOX reconcile failed ' + JSON.stringify(e));
      this.rescue = [];
    }
  }

  private onOnline(): void {
    if (!this.online || this.rescue.length === 0 || this.rescueBusy || this.running) {
      return;
    }
    Toast.info('网络已恢复，正在重发未发出的消息');
    this.resendRescue();
  }

  private async resendRescue(): Promise<void> {
    if (this.rescueBusy || this.rescue.length === 0) {
      return;
    }
    Haptics.tap();
    this.rescueBusy = true;
    const items: StashItem[] = this.rescue;
    try {
      for (let i = 0; i < items.length; i++) {
        const it: StashItem = items[i];
        const imgs: ImagePart[] = [];
        for (let k = 0; k < it.images.length; k++) {
          const im: StashImage = it.images[k];
          if (im.data !== '') {
            // 影子里的图片带着原始字节，直接复用，不用再让用户重选
            imgs.push({ mediaType: im.mediaType, data: im.data, name: im.name });
          }
        }
        // 复用首次提交的幂等身份：宿主若已经收过、只是响应丢了，不会再来一条。
        const key: string = it.key !== undefined && it.key !== '' ? it.key : ('rescue-' + this.param.id + '-' + String(it.t));
        if (it.kind === 'send' && imgs.length === 0) {
          await this.api.send(this.param.id, it.text, 'queue', key);
        } else {
          await this.api.sendOutbox(this.param.id, it.text, imgs, [], 'queue', key);
        }
        // 每条成功就核销：中途失败时，已经发出去的那几条不会在下次重发里再发一遍。
        Outbox.drop(this.param.id, [it]);
        this.rescue = Outbox.mine(this.param.id);
      }
      Toast.ok('已重发 ' + String(items.length) + ' 条');
      this.rescue = Outbox.mine(this.param.id);
      await this.load();
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.rescueBusy = false;
    }
  }

  private async dismissRescue(): Promise<void> {
    Haptics.soft();
    Outbox.clear(this.param.id);
    this.rescue = [];
  }

  private async load(): Promise<void> {
    const g: number = this.gen;
    // 先把上次看到的这一屏铺出来：进会话立刻有内容，网络慢也不会白屏。
    if (this.msgs.length === 0) {
      const snap: ChatSnapshot | null = ChatCache.read(this.param.id);
      if (snap !== null) {
        this.msgs = snap.messages;
        this.total = snap.total;
        this.running = snap.running;
        this.hasMore = snap.messages.length < snap.total;
        this.cached = true;
        this.loading = false;
        // 只有本来就在底部才跟着走：回看历史时重新进来不该被拽到最下面
        if (this.atBottom) {
          setTimeout(() => {
            this.scroller.scrollEdge(Edge.Bottom);
          }, 30);
        }
      }
    }
    const wasBottom: boolean = this.atBottom;
    const beforeTail: string = this.msgs.length === 0 ? '' :
      String(this.msgs[this.msgs.length - 1].seq) + ':' + String(this.msgs[this.msgs.length - 1].text.length);
    try {
      const r = await this.api.messages(this.param.id, 60);
      if (!this.alive || g !== this.gen) return;
      // 先换短签名再上屏：新宿主下 <Image> 的 URL 里不再带长期令牌。
      await this.api.signAttachments(this.imageIdsOf(r.messages));
      this.msgs = r.messages;
      this.total = r.total;
      this.stats = r.stats ?? null;
      this.ctx = r.context === undefined ? null : r.context;
      this.running = r.running === true;
      this.applyQueue(r.queue === undefined ? [] : r.queue);
        const qs: AskState | undefined = r.questions;
        this.asks = qs === undefined || qs.active === undefined ? [] : qs.active;
      this.hasMore = r.messages.length < r.total;
      this.err = '';
      this.takeLastErr(r.lastErr);
      this.cached = false;
      ChatCache.write(this.param.id, r.messages, r.total, r.running === true, r.lastTurn ?? '');
      this.reconcileRescue(r);
      // 只在「本来就在底部」且这一屏确实变了时才补一次滚底。
      // 以前只要在底部就无条件再滚一次，缓存铺屏 + 网络返回连着滚两下 = 界面抽搐。
      // 判据不能只看条数：末条回复在流式变长时条数不变，但内容会顶出视口。
      const afterTail: string = r.messages.length === 0 ? '' :
        String(r.messages[r.messages.length - 1].seq) + ':' +
          String(r.messages[r.messages.length - 1].text.length);
      if (wasBottom && afterTail !== beforeTail) {
        setTimeout(() => {
          this.scroller.scrollEdge(Edge.Bottom);
        }, 80);
      }
    } catch (e) {
      const msg: string = (e as Error).message;
      // 刚新建的会话，宿主那边日志文件还没落盘，会先 404 一次；这不算错误，
      // 空着等轮询把内容接上就行，别给用户糊一屏红字。
      if (!this.alive || g !== this.gen) return;
      if (msg.indexOf('session log not found') >= 0 && this.retried < 6) {
        this.retried++;
        this.err = '';
        this.retryTimer = setTimeout(() => {
          this.retryTimer = 0;
          if (this.alive) this.load();
        }, 500);
      } else if (this.cached) {
        // 有缓存铺着就不弹红字，网络恢复了下一轮自己会补上。
        this.err = '';
        console.info('DSH_CACHE stale ' + this.param.id + ' ' + msg);
      } else {
        this.err = msg;
        this.showErrCard('', msg, Date.now());
      }
    } finally {
      this.loading = false;
    }
  }

  /** 只保留本地还没有的 seq：load() 与轮询并发时，同一条消息不能出现两次。 */
  private freshOnly(incoming: Message[]): Message[] {
    if (this.msgs.length === 0) return incoming;
    let maxSeq: number = this.msgs[this.msgs.length - 1].seq;
    const out: Message[] = [];
    for (const m of incoming) {
      if (m.seq > maxSeq) {
        out.push(m);
        maxSeq = m.seq;
      }
    }
    return out;
  }

  /** 向上补一页更早的历史，接在现有消息前面。 */
  /**
   * 菜单里的「刷新」：把最新内容补进来，但不重建这一列。
   * 直接调 load() 会把 msgs 整个换掉 —— 列表重建、滚动位置丢、在底部时又被拽下去，
   * 用户看到的就是「一刷新就抽搐并沉底」。这里按 seq 就地合并：老消息不动，
   * 新的追加到尾部（界面自然往下延伸），同一条被重写的就地替换，全程不碰滚动条。
   */
  private async refreshSoft(): Promise<void> {
    const g: number = this.gen;
    Haptics.tap();
    try {
      const r = await this.api.messages(this.param.id, 60);
      if (!this.alive || g !== this.gen) return;
      // 先确认服务端这一页还能接得上本地：
      //  - srvLast < localLast：日志被截断/重写过，本地这份已经不属于这个会话了
      //  - srvFirst > localLast + 1：中间有洞（离线太久，服务端只给最新 60 条，补不回来）
      // 两种都交给 load() 整体重建，别把旧内容留在缓存里继续拖下去。
      if (this.msgs.length > 0 && r.messages.length > 0) {
        const localLast: number = this.msgs[this.msgs.length - 1].seq;
        const srvFirst: number = r.messages[0].seq;
        const srvLast: number = r.messages[r.messages.length - 1].seq;
        const stale: boolean = srvLast < localLast;
        const gap: boolean = srvFirst > localLast + 1;
        if (stale || gap) {
          console.info('DSH_REFRESH reload stale=' + String(stale) + ' gap=' + String(gap));
          this.load();
          return;
        }
      }
      const out: Message[] = this.msgs.slice();
      for (let i = 0; i < r.messages.length; i++) {
        const n: Message = r.messages[i];
        if (out.length === 0) {
          out.push(n);
          continue;
        }
        const last: Message = out[out.length - 1];
        if (n.seq === last.seq) {
          out[out.length - 1] = n;
          continue;
        }
        if (n.seq > last.seq) {
          out.push(n);
          continue;
        }
        for (let j = out.length - 1; j >= 0; j--) {
          if (out[j].seq === n.seq) {
            out[j] = n;
            break;
          }
        }
      }
      const grew: boolean = out.length !== this.msgs.length;
      this.msgs = out;
      this.total = r.total;
      this.stats = r.stats ?? null;
      this.ctx = r.context === undefined ? null : r.context;
      this.running = r.running === true;
      this.applyQueue(r.queue === undefined ? [] : r.queue);
      const qs: AskState | undefined = r.questions;
      this.asks = qs === undefined || qs.active === undefined ? [] : qs.active;
      this.hasMore = out.length < r.total;
      this.err = '';
      this.takeLastErr(r.lastErr);
      this.cached = false;
      ChatCache.write(this.param.id, out, r.total, r.running === true, r.lastTurn ?? '');
      this.reconcileRescue(r);
      console.info('DSH_REFRESH soft n=' + String(out.length) + ' grew=' + String(grew));
    } catch (e) {
      const msg: string = (e as Error).message;
      if (!this.alive || g !== this.gen) return;
      this.err = msg;
      this.showErrCard('', msg, Date.now());
    }
  }

  private async loadOlder(): Promise<void> {
    if (this.loadingMore || this.msgs.length === 0) return;
    this.loadingMore = true;
    try {
      const oldest: number = this.msgs[0].seq;
      const r = await this.api.messagesBefore(this.param.id, oldest, 60);
      if (r.messages.length === 0) {
        this.hasMore = false;
      } else {
        await this.api.signAttachments(this.imageIdsOf(r.messages));
        this.msgs = r.messages.concat(this.msgs);
        this.hasMore = this.msgs.length < r.total;
      }
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.loadingMore = false;
    }
  }

  private async send(steerNow: boolean = false): Promise<void> {
    const text = this.draft.trim();
    if ((text === '' && !this.hasPend()) || this.sending) return;
    // 生成中点发送：默认把这条交给电脑端的队列（mode=queue，本轮结束后由宿主自动发出，
    // 电脑的输入区会把它显示成待发送）；点「插队」则用 steer 立刻送进当前这一轮。
    const runningNow: boolean = this.running;
    const mode: string = steerNow ? 'steer' : 'queue';
    // 同一条消息的重试沿用同一个 key；发送成功后清掉，下一条换新 key。
    const idem: string = this.pendingKey !== '' ? this.pendingKey : Api.newIdemKey();
    this.pendingKey = idem;
    const route: string = (this.pendImgs.length > 0 || this.pendFiles.length > 0) ? 'outbox' : 'send';
    // 离线时不要先去撞网络：直接落影子，用户看到「已存在手机上」比转圈十几秒再报错清楚。
    if (!Net.isOnline()) {
      if (this.pendFiles.length > 0) {
        Toast.err('离线时不能发送文件，联网后再试');
        return;
      }
      const stash: StashImage[] = [];
      for (let i = 0; i < this.pendImgs.length; i++) {
        stash.push({ mediaType: this.pendImgs[i].mediaType, name: this.pendImgs[i].name, data: this.pendImgs[i].data });
      }
      const saved: boolean = Outbox.remember(this.param.id, text, stash, idem, route);
      if (!saved) {
        Toast.err('存不进本地，先别发：检查手机存储空间');
        return;
      }
      this.rescue = Outbox.mine(this.param.id);
      this.draft = '';
      this.pendImgs = [];
      this.pendFiles = [];
      Toast.ok('当前离线，消息已存在手机上');
      return;
    }
    Haptics.soft();
    this.sending = true;
    const imgs: ImagePart[] = this.pendImgs;
    const files: FilePart[] = this.pendFiles;
    this.draft = '';
    try {
      if (imgs.length > 0 || files.length > 0) {
        // 一条消息：文字在前，图片与文件跟着走同一条 prompt（服务端 /outbox）。
        // 分成 /images 与 /files 两次请求会变成两条待发送，用户看到的就是被拆开了。
        await this.api.sendOutbox(this.param.id, text, imgs, files, mode, idem);
        const bits: string[] = [];
        if (imgs.length > 0) bits.push(String(imgs.length) + ' 张图片');
        if (files.length > 0) bits.push(String(files.length) + ' 个文件');
        Toast.ok('已发送 ' + bits.join(' + '));
      } else {
        await this.api.send(this.param.id, text, mode, idem);
      }
      if (runningNow) {
        const stashImgs: StashImage[] = [];
        for (let i = 0; i < this.pendImgs.length; i++) {
          stashImgs.push({ mediaType: imgs[i].mediaType, name: imgs[i].name, data: imgs[i].data });
        }
        Outbox.remember(this.param.id, text, stashImgs, idem, route);
      }
      this.pendImgs = [];
      this.pendFiles = [];
      this.pendingKey = '';
      await this.load();
    } catch (e) {
      this.err = (e as Error).message;
      this.retryText = text;
      this.showErrCard('', this.err, Date.now());
      // 失败也要落影子：之前只在「运行中排队」时记，普通断网发送失败就彻底丢了。
      if (text !== '' || imgs.length > 0) {
        const stashImgs: StashImage[] = [];
        for (let i = 0; i < this.pendImgs.length; i++) {
          stashImgs.push({ mediaType: imgs[i].mediaType, name: imgs[i].name, data: imgs[i].data });
        }
        if (Outbox.remember(this.param.id, text, stashImgs, idem, route)) {
          this.rescue = Outbox.mine(this.param.id);
        } else {
          Toast.err('消息没能存到手机本地，请检查存储空间后再重试');
        }
      }
    } finally {
      this.sending = false;
    }
  }


  /** 打开系统相册选图，先挂到输入框上方，等用户点发送再和文字一起发。 */
  private async pickAttach(): Promise<void> {
    if (this.sending) return;
    try {
      const room: number = 9 - this.pendImgs.length - this.pendFiles.length;
      if (room <= 0) {
        Toast.ok('一次最多 9 个附件');
        return;
      }
      const parts: ImagePart[] = await pickImages(room);
      if (parts.length === 0) {
        return;
      }
      this.pendImgs = this.pendImgs.concat(parts);
      Haptics.tap();
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  /** 打开系统文件选择器，同样只挂到待发列表，发送时一起传到电脑。 */
  private async pickAttachFile(): Promise<void> {
    if (this.sending) return;
    try {
      const room: number = 9 - this.pendImgs.length - this.pendFiles.length;
      if (room <= 0) {
        Toast.ok('一次最多 9 个附件');
        return;
      }
      const uris: string[] = await pickFiles(room);
      if (uris.length === 0) {
        return;
      }
      const parts: FilePart[] = [];
      for (const uri of uris) {
        const one = readFile(uri);
        if (one !== undefined) {
          parts.push(one);
        }
      }
      if (parts.length === 0) {
        this.err = '选中的文件为空或超过 8 MB';
        return;
      }
      this.pendFiles = this.pendFiles.concat(parts);
      Haptics.tap();
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  /** 打开系统相机拍一张，同样先挂到待发区。 */
  private async pickCamera(): Promise<void> {
    if (this.sending) return;
    try {
      const room: number = 9 - this.pendImgs.length - this.pendFiles.length;
      if (room <= 0) {
        Toast.ok('一次最多 9 个附件');
        return;
      }
      const profile: cameraPicker.PickerProfile = {
        cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK
      };
      const res: cameraPicker.PickerResult = await cameraPicker.pick(
        getContext(this) as common.UIAbilityContext,
        [cameraPicker.PickerMediaType.PHOTO],
        profile
      );
      if (res.resultCode !== 0 || res.resultUri === '') {
        return;
      }
      const parts: ImagePart[] = fromUris([res.resultUri]);
      if (parts.length === 0) {
        this.err = '拍到的照片读不出来';
        return;
      }
      this.pendImgs = this.pendImgs.concat(parts);
      Haptics.tap();
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  /** 宿主 token-meter 投影的上下文占用；拿不到（老插件）时返回 0。 */
  private ctxUsed(): number {
    const c = this.ctx;
    return c === null ? 0 : c.used;
  }

  private ctxWindow(): number {
    const c = this.ctx;
    return c === null || c.window <= 0 ? 128000 : c.window;
  }

  private ctxPct(): number {
    if (this.ctx === null) {
      return 0;
    }
    return Math.min(100, Math.round(this.ctxUsed() * 100 / this.ctxWindow()));
  }

  @Builder
  usageRing() {
    Stack() {
      Progress({
        value: Math.min(this.ctxUsed(), this.ctxWindow()),
        total: this.ctxWindow(),
        type: ProgressType.Ring
      })
        .style({ strokeWidth: 3.5 })
        .color(Tokens.accent)
        .backgroundColor(Tokens.surface3)
        .width(26)
        .height(26)
      Text(this.ctxPct() + '%')
        .fontSize(11)
        .fontColor(Tokens.dim2)
    }
    .width(32)
    .height(32)
  }

  private hasPend(): boolean {
    return this.pendImgs.length > 0 || this.pendFiles.length > 0;
  }

  private dropImg(i: number): void {
    if (i < 0 || i >= this.pendImgs.length) {
      return;
    }
    const next: ImagePart[] = [];
    for (let k = 0; k < this.pendImgs.length; k++) {
      if (k !== i) next.push(this.pendImgs[k]);
    }
    this.pendImgs = next;
  }

  private dropFile(i: number): void {
    if (i < 0 || i >= this.pendFiles.length) {
      return;
    }
    const next: FilePart[] = [];
    for (let k = 0; k < this.pendFiles.length; k++) {
      if (k !== i) next.push(this.pendFiles[k]);
    }
    this.pendFiles = next;
  }

  /** 让服务端停止这一轮；不受理时把原因留在错误条上。 */
  private async doStop(): Promise<void> {
    try {
      const ok = await this.api.stop(this.param.id);
      if (!ok) {
        this.err = '这一轮已经不在了，或服务端没有受理';
      }
      await this.load();
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  private async doRename(): Promise<void> {
    const t = this.renameText.trim();
    if (t === '') {
      this.err = '名字不能为空';
      return;
    }
    try {
      await this.api.rename(this.param.id, t);
      this.titleNow = t;
      this.renaming = false;
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  /** 长按气泡复制：手机上最常见的「我想把这段发给别人」。 */
  /** 引用：把这条消息前几行塞进草稿，做成引用块 */
  private quoteMessage(m: Message): void {
    const t: string = m.text.trim();
    if (t === '') {
      return;
    }
    const rows: string[] = t.split('\n').slice(0, 6);
    const quote: string = rows.map((x: string) => '> ' + x).join('\n');
    this.draft = this.draft === '' ? quote + '\n\n' : this.draft + '\n' + quote + '\n\n';
    Drafts.set(this.param.id, this.draft);
  }

  /** 选择文本面板里要显示的那段文字 */
  private selText(): string {
    const m: Message | null = this.menuMsg;
    return m === null ? '' : m.text;
  }

  /**
   * 分段控件里的一格。
   * 选中态必须在这里读 this.selRaw：@Builder 的布尔值参数是「首帧快照」，
   * 外面传 !this.selRaw 进来之后就一直不会变，切换时白胶囊会停在原来那一格。
   */
  /** 标题后的小感叹号：说明性文字不再压在标题下面当小字。 */
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
      .bindPopup(this.setPop === key, {
        builder: this.hintPop(text),
        placement: Placement.Bottom,
        popupColor: Color.Transparent,
        enableArrow: false,
        radius: 16,
        offset: { x: 0, y: 4 },
        onStateChange: (e) => {
          if (!e.isVisible && this.setPop === key) {
            this.setPop = '';
          }
        }
      })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .onClick(() => {
        Haptics.tap();
        this.setPop = this.setPop === key ? '' : key;
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
  hintTitle(title: string, text: string, key: string) {
    Row() {
      Text(title)
        .fontSize(13)
        .fontColor(Tokens.fg)
      this.hintDot(key, text)
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  selTab(label: string, which: string, act: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(((which === 'raw') === this.selRaw) ? Tokens.fg : Tokens.dim)
      .fontWeight(((which === 'raw') === this.selRaw) ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(34)
      .borderRadius(Tokens.rPill)
      .backgroundColor(Color.Transparent)
      .animation({ duration: 200, curve: Curve.EaseOut })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
      .onClick(act)
  }

  @Builder
  selBtn(label: string, primary: boolean, act: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(primary ? Tokens.accentInk : Tokens.fg)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(42)
      .borderRadius(Tokens.rPill)
      .backgroundColor(primary ? Tokens.accentStrong : (Tokens.isDark ? '#26FFFFFF' : '#99FFFFFF'))
      .border({ width: 1, color: primary ? Tokens.accentStrong : (Tokens.isDark ? '#33FFFFFF' : '#B3FFFFFF') })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
      .onClick(act)
  }

  /**
   * 长按消息弹出的「选择文本」面板。
   * 以前是三条 52 高的小行，报错和长回答根本看不全；现在整屏铺开、可以长按选中，
   * 上面还能切「正文 / Markdown 原文」，和 CubeAgent 那套选择文本一致。
   */
  @Builder
  selectSheet() {
    Column() {
      Row() {
        Text('选择文本')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text('×')
          .fontSize(24)
          .fontColor(Tokens.dim2)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => {
            this.msgMenuOn = false;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 10, top: 12, bottom: 2 })

      // 白胶囊用位移滑过去，正文用同一组时长与曲线淡入淡出：两处都是
      // 200ms EaseOut，看起来是同一个动作，而不是先硬切再淡入。
      Row() {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('50%')
            .height(34)
            .borderRadius(Tokens.rPill)
            .backgroundColor(Tokens.isDark ? '#3DFFFFFF' : '#FFFFFFFF')
            .shadow({ radius: 6, color: Tokens.isDark ? '#33000000' : '#1A000000', offsetY: 1 })
            .translate({ x: this.selRaw ? '100%' : '0%' })
            .animation({ duration: 200, curve: Curve.EaseOut })
          Row() {
            this.selTab('正文', 'body', (): void => { this.selRaw = false; })
            this.selTab('Markdown 原文', 'raw', (): void => { this.selRaw = true; })
          }
          .width('100%')
        }
        .width('100%')
        .height(40)
        .padding(3)
        .backgroundColor(Tokens.isDark ? '#26FFFFFF' : '#14000000')
        .borderRadius(Tokens.rPill)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8 })

      Scroll() {
        if (this.selRaw) {
          Text(this.selText())
            .fontSize(13)
            .lineHeight(22)
            .fontColor(Tokens.fg)
            .width('100%')
            .textAlign(TextAlign.Start)
            .copyOption(CopyOptions.LocalDevice)
            .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut }))
        } else {
          MdBody({ blocks: parseMd(this.selText()) })
            .width('100%')
          .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut }))
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 20, right: 20, top: 4, bottom: 10 })
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)

      Row({ space: 10 }) {
        this.selBtn('复制全文', true, (): void => {
          this.copyText(this.selText(), '已复制全文');
        })
        this.selBtn('引用全文', false, (): void => {
          const mm: Message | null = this.menuMsg;
          this.msgMenuOn = false;
          if (mm !== null) {
            this.quoteMessage(mm);
          }
        })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 4, bottom: 22 })
    }
    .width('100%')
    .height('100%')
  }

  private copyMessage(m: Message): void {
    this.copyText(m.text, '已复制');
  }

  private copyText(t: string, ok: string): void {
    if (t === '') return;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, t);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        Toast.ok(ok);
      }).catch(() => {
        Toast.err('复制失败');
      });
    } catch (e) {
      Toast.err('复制失败');
    }
  }

  /**
   * 把这一轮的原始报错留在消息流里。
   * 以前只弹一个两行就截断的 toast/红字条，422 那种长 body 根本看不到，
   * 用户拿着「处理失败」三个字什么也查不了。
   */
  private showErrCard(code: string, text: string, at: number): void {
    if (text === '') {
      return;
    }
    this.errCardCode = code;
    this.errCard = text;
    console.info('DSH_ERRCARD code=' + code + ' len=' + text.length + ' at=' + at);
  }

  private dismissErrCard(): void {
    this.errCard = '';
    this.errCardCode = '';
  }

  /** 从 /messages 的 lastErr 同步错误卡；新的一轮已经在跑就把上一轮的报错收起来。 */
  private takeLastErr(le: TurnErr | null | undefined): void {
    if (this.running) {
      if (this.errCard !== '') {
        this.dismissErrCard();
      }
      return;
    }
    if (le === undefined || le === null || le.text === '') {
      return;
    }
    if (le.text === this.errCard) {
      return;
    }
    // 插件侧的 lastErr 是「日志里最后一条 turn/end 的报错」，不管后面有没有成功。
    // 所以这里再判一次时间：错完之后又聊成了的会话，不该一打开就顶一张旧报错卡。
    let lastMark = 0;
    for (let i = 0; i < this.msgs.length; i++) {
      const t = this.msgs[i].time;
      if (t > lastMark) {
        lastMark = t;
      }
    }
    if (lastMark > 0 && le.time > 0 && le.time < lastMark) {
      if (this.errCard !== '') {
        this.dismissErrCard();
      }
      return;
    }
    this.showErrCard(le.code, le.text, le.time);
  }

  /** 消息流末尾的错误卡：状态码 + 完整 body + 一键复制 */
  @Builder
  errCardView() {
    Column({ space: 8 }) {
      Row() {
        Text('这一轮出错了 · ' + errTitle(this.errCard))
          .fontSize(13)
          .fontColor(Tokens.err)
          .layoutWeight(1)
        if (this.errCardCode !== '') {
          Text(this.errCardCode)
            .fontSize(11)
            .fontColor(Tokens.dim)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .backgroundColor(Tokens.isDark ? '#1FFFFFFF' : '#14000000')
            .borderRadius(6)
            .maxLines(1)
        }
        Text('×')
          .fontSize(15)
          .fontColor(Tokens.dim2)
          .width(28)
          .height(22)
          .textAlign(TextAlign.Center)
          .margin({ left: 2 })
          .onClick(() => {
            this.dismissErrCard();
          })
      }
      .width('100%')

      Scroll() {
        Text(this.errCard)
          .fontSize(12)
          .lineHeight(17)
          .fontColor(Tokens.dim)
          .width('100%')
          .textAlign(TextAlign.Start)
          .copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .constraintSize({ maxHeight: 190 })
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)

      Row({ space: 8 }) {
        if (this.retryText !== '') {
          Text('重试')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accentInk)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor(Tokens.accent)
            .borderRadius(Tokens.rPill)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              const t: string = this.retryText;
              this.retryText = '';
              this.dismissErrCard();
              this.draft = t;
              this.send();
            })
        }
        Text('复制报错')
          .fontSize(12)
          .fontColor(Tokens.accent)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.copyText(this.errCard, '已复制报错');
          })
        Text('收起')
          .fontSize(12)
          .fontColor(Tokens.dim2)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(Tokens.rPill)
          .border({ width: 1, color: Tokens.lineSoft })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.dismissErrCard();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(13)
    .backgroundColor(Tokens.isDark ? '#14FF5C5C' : '#0FFF3B30')
    .borderRadius(20)
    .border({ width: 1, color: Tokens.isDark ? '#3DFF5C5C' : '#26FF3B30' })
  }

  /** 这一轮怎么结束的：一句人话。 */
  private turnLabel(t: TurnInfo): string {
    if (t.status === 'completed') {
      return '已完成';
    }
    if (t.status === 'aborted' || t.status === 'interrupted') {
      return '已中断';
    }
    if (t.status === 'error') {
      return '出错';
    }
    if (t.status === 'max-tokens') {
      return '达到输出上限';
    }
    if (t.status === 'blocked') {
      return '受阻';
    }
    return t.status === '' ? '已结束' : t.status;
  }

  /** 状态点的颜色：完成绿、中断/出错红、其余灰。 */
  private turnColor(t: TurnInfo): string {
    if (t.status === 'completed') {
      return Tokens.ok;
    }
    if (t.status === 'aborted' || t.status === 'interrupted' || t.status === 'error') {
      return Tokens.err;
    }
    return Tokens.dim2;
  }

  /** 用时：90 秒 → 1 分 30 秒；纯给脚注看，不追求精确到毫秒。 */
  private durText(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const s: number = Math.round(ms / 1000);
    if (s < 60) {
      return String(s) + ' 秒';
    }
    const m: number = Math.floor(s / 60);
    const rest: number = s % 60;
    return rest === 0 ? String(m) + ' 分钟' : String(m) + ' 分 ' + String(rest) + ' 秒';
  }

  /** 结束时间：epoch ms → 21:32（今天）或 11-20 21:32（更早）。 */
  private clockText(ms: number): string {
    if (ms <= 0) return '';
    const d = new Date(ms);
    const now = new Date();
    const pad = (n: number): string => n < 10 ? '0' + String(n) : String(n);
    const hm: string = pad(d.getHours()) + ':' + pad(d.getMinutes());
    const sameDay: boolean = d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() &&
      d.getDate() === now.getDate();
    return sameDay ? hm : String(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + hm;
  }

  /** 1200 → 1.2K，2300000 → 2.3M。 */
  private tokenText(n: number): string {
    if (n >= 1000000) {
      return (n / 1000000).toFixed(1) + 'M';
    }
    if (n >= 1000) {
      return (n / 1000).toFixed(1) + 'K';
    }
    return String(n);
  }

  /** 分叉：以这条回复为界复制出一个新会话。 */
  private async forkAt(m: Message): Promise<void> {
    const at: number = m.turn !== undefined ? m.turn.atSeq : m.seq;
    try {
      const id: string = await this.api.fork(this.param.id, at);
      if (id === '') {
        Toast.err('分叉失败');
        return;
      }
      Haptics.tap();
      Toast.ok('已分叉，回列表可看到新会话');
      AppStorage.setOrCreate('listDirty', Date.now());
    } catch (e) {
      Toast.err('分叉失败：' + (e as Error).message);
    }
  }

  /** 行内片段：粗体 / 行内代码 */
  

  /**
   * 用户气泡里的正文：以前直接把 Markdown 原文塞进一个 Text，发 **重点**
   * 看到的就是两个星号。这里改走 parseMd 的块与行内片段，粗体与行内代码
   * 在蓝底气泡里也能认出来；整段仍是一个 Text，长按照样能选中复制。
   */
  

  /**
   * 取一个块的行内片段。代码块、独立公式这类块 parseMd 只填 text、segs 为空，
   * 直接按 segs 渲染会把整段内容吞掉，这里退回整段文本。
   */


  /** 表格：首行淡蓝底，单元格细线，可横向滚动 */
  /** 独立公式：居中、等宽感，两侧留白，避免跟正文黏在一起。 */
  

  

  

  private blocksOf(m: Message): MdBlock[] {
    // 同长度的正文替换（例如宿主把某条消息重写）不能命中旧缓存：
    // key 里带上首尾片段，长度相同也能区分。
    const head: string = m.text.length > 8 ? m.text.slice(0, 8) : m.text;
    const tail: string = m.text.length > 8 ? m.text.slice(m.text.length - 8) : '';
    const key: string = String(m.seq) + ':' + String(m.text.length) + ':' + head + ':' + tail;
    const hit: MdBlock[] | undefined = this.mdCache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const blocks: MdBlock[] = parseMd(m.text);
    if (this.mdCache.size > 160) {
      this.mdCache.clear();
    }
    this.mdCache.set(key, blocks);
    return blocks;
  }

  @Builder
  bubble(m: Message) {
    if (m.role === 'user') {
      // 用户气泡：右侧蓝底白字，右下角收小一点，形成「指向自己」的方向感
      Column() {
      Row() {
        Column() {
          if (m.images !== undefined && m.images.length > 0) {
            MessageImages({
              images: m.images,
              api: this.api,
              onTap: (url: string): void => {
                this.bigImg = url;
              }
            })
              .margin({ bottom: m.text !== '' ? 8 : 0 })
          }
          if (m.text !== '') {
            MdBody({ user: true, userText: m.text })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 15, right: 15, top: 11, bottom: 11 })
        .constraintSize({ maxWidth: 300 })
        .backgroundColor(Tokens.accent)
        .borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 })
        .shadow({ radius: 16, color: Tokens.accentSoft, offsetY: 6 })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)

      }
      .width('100%')
      .alignItems(HorizontalAlign.End)
      .margin({ bottom: 20 })
      .gesture(LongPressGesture({ repeat: false, duration: 380 }).onAction(() => {
        Haptics.long();
        this.menuMsg = m;
        this.selRaw = false;
        this.msgMenuOn = true;
      }))
    } else {
      // 助手气泡：模型名 + 头像在上，正文装在卡片里
      Column() {
        Row() {
          Image($r('app.media.app_icon'))
            .width(20)
            .height(20)
            .borderRadius(6)
            .objectFit(ImageFit.Cover)
          // 状态胶囊贴着头像放在左边，右边留白。
          if (m.turn !== undefined) {
            Row() {
              Circle()
                .width(6)
                .height(6)
                .fill(this.turnColor(m.turn))
              Text(this.turnLabel(m.turn) + (m.turn.ms > 0 ? ' · ' + this.durText(m.turn.ms) : ''))
                .fontSize(11)
                .fontColor(this.turnColor(m.turn))
                .margin({ left: 5 })
            }
            .margin({ left: 8 })
          }
          Blank()
        }
        .width('100%')
        .margin({ bottom: 6 })

        Column() {
          if (m.images !== undefined && m.images.length > 0) {
            MessageImages({
              images: m.images,
              api: this.api
            })
              .margin({ bottom: m.text !== '' ? 8 : 0 })
          }
          if (m.text !== '') {
            MdBody({ blocks: this.blocksOf(m) })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(Tokens.surface)
        .borderRadius(20)
        .border({ width: 1, color: Tokens.lineSoft })
        .width('100%')

        Row({ space: 10 }) {
          if (m.turn !== undefined) {
            Text(this.tokenText(m.turn.tokensIn + m.turn.tokensOut) + ' tokens')
              .fontSize(11)
              .fontColor(Tokens.dim2)
          }
          if (m.turn !== undefined && this.clockText(m.turn.finishedAt === undefined ? 0 : m.turn.finishedAt) !== '') {
            Text(this.clockText(m.turn.finishedAt === undefined ? 0 : m.turn.finishedAt))
              .fontSize(11)
              .fontColor(Tokens.dim2)
          }
          if (m.turn !== undefined) {
            // 开新分支放回气泡底下：只要一枚分叉图标，不带文字
            Stack() {
              Image($r('app.media.ic_fork'))
                .width(13)
                .height(13)
                .fillColor(Tokens.dim2)
                .draggable(false)
            }
            .width(26)
            .height(22)
            .borderRadius(Tokens.rPill)
            .backgroundColor(Tokens.isDark ? '#1FFFFFFF' : '#0F000000')
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .accessibilityText('从这里开新分支')
            .onClick(() => {
              Haptics.tap();
              this.forkAt(m);
            })
          }
        }
        .margin({ top: 6 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 20 })
      .gesture(LongPressGesture({ repeat: false, duration: 380 }).onAction(() => {
        Haptics.long();
        this.menuMsg = m;
        this.selRaw = false;
        this.msgMenuOn = true;
      }))
    }
  }

  /** 生成中的占位气泡：三颗点依次亮，配合 1.2 秒轮询看起来像在吐字。 */
  /** 按原始宽高比算出图片宽度（上限 280vp），高度随之收放。 */
  private imageWidth(img: ImageRef): number {
    return img.width > 0 && img.height > 0 && img.width < 280 ? img.width : 280;
  }

  private imageHeight(img: ImageRef): number {
    if (img.width > 0 && img.height > 0) {
      const w: number = this.imageWidth(img);
      return Math.round((w * img.height) / img.width);
    }
    return 180;
  }

  /** 用目录里的展示名换掉裸 id，找不到就原样返回。 */
  private labelOf(id: string): string {
    for (const g of this.groups) {
      for (const m of g.models) {
        if (m.id === id) return m.name;
      }
    }
    return id;
  }

  private async loadModels(): Promise<void> {
    try {
      const c = await this.api.models(this.param.id);
      this.groups = c.groups ?? [];
      this.groupsLoaded = true;
      const cur: ModelRef | null = c.current;
      if (cur !== null && cur !== undefined && (cur.model ?? '') !== '') {
        this.curModelId = cur.model ?? '';
        this.curModel = this.labelOf(cur.model ?? '');
        this.curEffort = cur.reasoningEffort ?? '';
      } else {
        // 目录没给 current 时（会话还没选过模型），退到会话行里记录的真实模型，
        // 否则顶部一直显示「共 N 条」，跟 CubeAgent 的副标题对不上。
        try {
          const rows = await this.api.sessions();
          for (const r of rows) {
            if (r.id === this.param.id && r.model !== undefined && r.model !== null) {
              this.curModelId = r.model.model;
              this.curModel = this.labelOf(r.model.model);
              this.curEffort = r.model.reasoningEffort ?? '';
              break;
            }
          }
        } catch (e2) {
        }
      }
    } catch (e) {
      this.err = (e as Error).message;
      this.groupsLoaded = true;
    }
  }

  /** 当前模型的显示名（目录还没拉到时退回会话里的 id）。 */
  private curModelName(): string {
    for (const g of this.groups) {
      for (const m of g.models) {
        if (m.id === this.curModelId) {
          return m.name;
        }
      }
    }
    return this.curModel !== '' ? this.curModel : '—';
  }

  /** 当前档位的显示名，没有档位就空串。 */
  private curEffortName(): string {
    for (const g of this.groups) {
      for (const m of g.models) {
        if (m.id === this.curModelId) {
          for (const e of m.efforts) {
            if (e.id === this.curEffort) {
              return e.name;
            }
          }
        }
      }
    }
    return '';
  }

  private openModels(): void {
    this.modelOn = true;
    // 面板每次弹出都问一次：电脑端也能改这个开关，别拿旧值糊上去
    this.loadTeamMode();
    if (!this.groupsLoaded) {
      this.loadModels();
    }
  }

  private async pick(g: string, m: string, effort: string, name: string): Promise<void> {
    try {
      await this.api.selectModel(this.param.id, g, m, effort);
      this.curModelId = m;
      this.curModel = this.labelOf(m);
      this.curEffort = effort;
      this.shutSheet();
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  /** 关闭模型 / 运行统计面板：先播收起动画，再卸载，保证进出对称。 */
  private shutSheet(): void {
    if (this.sheetClosing) {
      return;
    }
    this.sheetClosing = true;
    setTimeout(() => {
      this.modelOn = false;
      this.statsOn = false;
      this.sheetClosing = false;
    }, 300);
  }

  private hideKb(): void {
    try {
      inputMethod.getController().stopInputSession();
    } catch (err) {
    }
  }

  /**
   * 模型面板：系统半模态从底部上滑（bindSheet），玻璃底，布局照 CubeAgent 的「选择模型」。
   * 不再自绘遮罩与位移，顶部四个控件保持可见，关闭后立刻回到原位，连续性好。
   */
  @Builder
  modelSheetBody() {
    Column() {
      // 标题行：和「上下文」一模一样，左标题、右图标
      Row() {
        Text('选择模型')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text('×')
          .fontSize(20)
          .fontColor(Tokens.dim)
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .borderRadius(999)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .accessibilityText('关闭')
          .onClick(() => {
            this.modelOn = false;
          })
      }
      .width('100%')
      .padding({ left: 2, right: 2, bottom: 8 })

      Row() {
        Text('当前选择')
          .fontSize(12)
          .fontColor(Tokens.dim2)
        Text(this.curModelName() + (this.curEffortName() !== '' ? ' · ' + this.curEffortName() : ''))
          .fontSize(13)
          .fontColor(Tokens.accent)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(Tokens.accentSoft)
      .borderRadius(14)
      .alignItems(VerticalAlign.Center)

      Row() {
        Row() {
          this.hintTitle('智能体协作', '开启后本轮可以派多个子智能体并行干活。', 'team')
        }
        .alignItems(VerticalAlign.Center)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.teamOn })
          .selectedColor(Tokens.accent)
          .enabled(!this.teamBusy)
          .onChange((v: boolean) => {
            if (v !== this.teamOn) {
              void this.setTeamMode(v);
            }
          })
      }
      .width('100%')
      .padding({ top: 12, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      Divider().color(Tokens.line).margin({ top: 6, bottom: 2 })

      if (!this.groupsLoaded) {
        Row() {
          LoadingProgress().width(18).height(18).color(Tokens.dim2)
          Text('读取模型目录…').fontSize(13).fontColor(Tokens.dim2).margin({ left: 8 })
        }
        .height(90)
      } else {
        Scroll() {
          Column() {
            ForEach(this.groups, (g: CatalogGroup) => {
              Column() {
                Row() {
                  Text(g.name)
                    .fontSize(12)
                    .fontColor(Tokens.dim)
                    .letterSpacing(0.6)
                    .layoutWeight(1)
                  if (g.models.some((m: CatalogModel) => m.id === this.curModelId)) {
                    Text('当前')
                      .fontSize(11)
                      .fontColor(Tokens.accent)
                  }
                }
                .width('100%')
                .margin({ bottom: 6 })
                ForEach(g.models, (m: CatalogModel) => {
                  Column() {
                    Row() {
                      Column() {
                        Text(m.name)
                          .fontSize(15)
                          .fontColor(Tokens.fg)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        if (m.description !== '') {
                          Text(m.description)
                            .fontSize(11)
                            .fontColor(Tokens.dim2)
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                            .margin({ top: 2 })
                        }
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      if (this.curModelId === m.id) {
                        Text('√')
                          .fontSize(15)
                          .fontColor(Tokens.accent)
                      }
                    }
                    .width('100%')

                    if (m.efforts.length > 0) {
                      Row() {
                        ForEach(m.efforts, (e: EffortRef) => {
                          Text(e.name)
                            .fontSize(11)
                            .fontColor(this.curModelId === m.id && this.curEffort === e.id ? Tokens.accentInk : Tokens.dim)
                            .backgroundColor(this.curModelId === m.id && this.curEffort === e.id ? Tokens.accent : Tokens.surface3)
                            .borderRadius(999)
                            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                            .margin({ right: 6 })
                            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                            .onClick(() => {
                              Haptics.tap();
                              this.pick(g.id, m.id, e.id, m.name);
                            })
                        }, (e: EffortRef) => e.id)
                      }
                      .width('100%')
                      .margin({ top: 8 })
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .padding({ top: 10, bottom: 10 })
                  .width('100%')
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
                  .onClick(() => {
                    this.pick(g.id, m.id, m.defaultEffort, m.name);
                  })
                }, (m: CatalogModel) => m.id)
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .backgroundColor(Tokens.surface2)
              .borderRadius(20)
              .margin({ bottom: 12 })
            }, (g: CatalogGroup) => g.id)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 6, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Color.Transparent)
  }

  @Builder
  kvRow(k: string, v: string) {
    Row() {
      Text(k)
        .fontSize(13)
        .fontColor(Tokens.dim)
        .layoutWeight(1)
      Text(v)
        .fontSize(13)
        .fontColor(Tokens.fg)
    }
    .width('100%')
    .padding({ top: 7, bottom: 7 })
  }

  /** 打开右上角那块电脑侧面板（插件 / 自动化任务 / 工作区文件）。 */
  private openExtras(mode: string): void {
    this.hideKb();
    this.extrasMode = mode;
  }

  /** 弹窗里的一行 */
  @Builder
  menuOpt(label: string, act: () => void) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(Tokens.fg)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(38)
    .padding({ left: 12, right: 12 })
    .borderRadius(10)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(() => {
      this.menuOn = false;
      act();
    })
  }

  @Builder
  menuHead(label: string) {
    Text(label)
      .fontSize(11)
      .fontColor(Tokens.dim2)
      .width('100%')
      .padding({ left: 12, top: 8, bottom: 4 })
  }

  /** ⋯ 面板：电脑侧那几块 + 会话操作，样式照首页「分组方式」 */
  @Builder
  chatMenuPanel() {
    Column() {
      this.menuHead('电脑侧')
      this.menuOpt('插件', (): void => { this.openExtras('plugins'); })
      this.menuOpt('自动化任务', (): void => { this.openExtras('schedules'); })
      this.menuOpt('工作区文件', (): void => { this.openExtras('files'); })
      this.menuOpt('智能体团队', (): void => { this.openExtras('team'); })
      Divider().color(Tokens.lineSoft).margin({ top: 6, bottom: 2 })
      this.menuHead('会话')
      this.menuOpt('预设与权限', (): void => {
        const p: ChatParam = { id: this.param.id, title: this.param.title };
        this.stack.pushPathByName('presets', p);
      })
      this.menuOpt('搜索本会话', (): void => {
        this.menuOn = false;
        this.searchQ = '';
        this.searchOn = true;
      })
      this.menuOpt('导出 Markdown', (): void => {
        this.menuOn = false;
        this.exportMd();
      })
      this.menuOpt('刷新', (): void => { this.refreshSoft(); })
    }
    .width(268)
    .padding({ left: 6, right: 6, top: 8, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.isDark ? '#E6171B22' : '#F2FFFFFF')
    .backdropBlur(24)
    .borderRadius(20)
    .border({ width: 1, color: Tokens.isDark ? '#33FFFFFF' : '#D9FFFFFF' })
    .shadow({ radius: 26, color: Tokens.shadow, offsetY: 10 })
  }

  /** 消息里的图片 id（最多 64 个），用于向宿主换短签名直链。 */
  private imageIdsOf(msgs: Message[]): string[] {
    const ids: string[] = [];
    for (let i = 0; i < msgs.length && ids.length < 64; i++) {
      const imgs = msgs[i].images;
      if (imgs === undefined) {
        continue;
      }
      for (let k = 0; k < imgs.length && ids.length < 64; k++) {
        if (ids.indexOf(imgs[k].id) < 0) {
          ids.push(imgs[k].id);
        }
      }
    }
    return ids;
  }

  private searchRows(): Message[] {
    const kw: string = this.searchQ.trim().toLowerCase();
    if (kw === '') {
      return [];
    }
    const out: Message[] = [];
    for (let i = 0; i < this.msgs.length; i++) {
      if (this.msgs[i].text.toLowerCase().indexOf(kw) >= 0) {
        out.push(this.msgs[i]);
      }
    }
    return out;
  }

  private snippet(t: string): string {
    // 搜索结果给人看，不是给解析器看：把 Markdown 记号去掉再压成一行。
    const plain: string = t.replace(/[#*`>|~]/g, ' ').replace(/\s+/g, ' ').trim();
    return plain.length > 90 ? plain.slice(0, 90) + '…' : plain;
  }

  private jumpTo(m: Message): void {
    let idx: number = 0;
    for (let i = 0; i < this.msgs.length; i++) {
      if (this.msgs[i].seq === m.seq) {
        idx = i;
        break;
      }
    }
    this.searchOn = false;
    this.searchQ = '';
    // 列表第 0 项是顶部留白占位；有「加载更早」时还要再加一项。
    const off: number = this.hasMore ? 2 : 1;
    setTimeout(() => {
      try {
        this.scroller.scrollToIndex(idx + off);
      } catch (e) {
        console.info('DSH_SEARCH jump failed: ' + JSON.stringify(e));
      }
    }, 120);
  }

  @Builder
  searchOverlay() {
    Column() {
      Row() {
        Text('取消')
          .fontSize(13)
          .fontColor(Tokens.accent)
          .padding({ right: 10 })
          .onClick(() => {
            this.searchOn = false;
            this.searchQ = '';
          })
        TextInput({ placeholder: '搜索本会话', text: this.searchQ })
          .height(38)
          .fontSize(14)
          .borderRadius(19)
          .backgroundColor(Tokens.surface2)
          .placeholderColor(Tokens.dim2)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.searchQ = v;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.searchQ.trim() === '') {
        Text('输入关键词，搜本会话的正文')
          .fontSize(12)
          .fontColor(Tokens.dim2)
          .margin({ top: 40 })
      } else if (this.searchRows().length === 0) {
        Text('没有匹配的消息')
          .fontSize(13)
          .fontColor(Tokens.dim2)
          .margin({ top: 40 })
      } else {
        List() {
          ForEach(this.searchRows(), (m: Message) => {
            ListItem() {
              Column() {
                Row() {
                  Text(m.role === 'user' ? '你' : '助手')
                    .fontSize(11)
                    .fontColor(m.role === 'user' ? Tokens.accent : Tokens.dim2)
                  Blank()
                  Text(clock(m.time))
                    .fontSize(11)
                    .fontColor(Tokens.dim2)
                }
                .width('100%')
                Text(this.snippet(m.text))
                  .fontSize(13)
                  .fontColor(Tokens.fg)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 3 })
              }
              .width('100%')
              .padding(12)
              .backgroundColor(Tokens.surface)
              .borderRadius(14)
              .margin({ bottom: 8 })
              .alignItems(HorizontalAlign.Start)
              .onClick(() => {
                this.jumpTo(m);
              })
            }
          }, (m: Message) => 'sr' + m.seq)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: 16, right: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
    .padding({ top: 54 })
  }

  /** 重命名的小弹窗：系统菜单里塞不了输入框，单独来一块。 */
  @Builder
  renameDialog() {
    Column() {
      Column() {
        Text('重命名会话')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .width('100%')
          .margin({ bottom: 12 })
        TextInput({ text: this.renameText, placeholder: '新的会话名字' })
          .fontSize(13)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .backgroundColor(Tokens.surface2)
          .borderRadius(14)
          .height(42)
          .onChange((v: string) => {
            this.renameText = v;
          })
        Row() {
          Text('取消')
            .fontSize(13)
            .fontColor(Tokens.dim)
            .padding({ left: 6, right: 6, top: 10, bottom: 4 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              this.renaming = false;
            })
          Blank()
          Text('保存')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accent)
            .padding({ left: 6, right: 6, top: 10, bottom: 4 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              this.doRename();
            })
        }
        .width('100%')
      }
      .width(300)
      .padding({ left: 18, right: 18, top: 16, bottom: 8 })
      .backgroundColor(Tokens.surface)
      .borderRadius(20)
      .border({ width: 1, color: Tokens.lineSoft })
      .shadow({ radius: 28, color: Tokens.shadow, offsetY: 12 })
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
    .transition(TransitionEffect.OPACITY.animation({ duration: 160 }))
    .onClick(() => {
      this.renaming = false;
    })
  }

  /** 长文本编辑：输入框一行看不全时，整块抬起来写。 */
  @Builder
  bigEditor() {
    Column() {
      Row() {
        Text(this.queueEditId === '' ? '编辑消息' : '编辑待发送')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text(this.queueEditId === '' ? '完成' : '取消')
          .fontSize(13)
          .fontColor(this.queueEditId === '' ? Tokens.accent : Tokens.dim)
          .padding({ left: 12, right: 4, top: 8, bottom: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            Haptics.tap();
            this.bigEditOn = false;
            this.queueEditId = '';
            this.editBuf = '';
          })
      }
      .width('100%')
      .padding({ bottom: 10 })

      TextArea({ text: this.queueEditId === '' ? this.draft : this.editBuf, placeholder: '想清楚了再发…' })
        .placeholderColor(Tokens.dim2)
        .fontColor(Tokens.fg)
        .fontSize(15)
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(Tokens.surface3)
        .borderRadius(20)
        .padding(14)
        // 光标行始终留在可视区内：内容超出时 TextArea 会自己往上滚，
        // 前提是它的底边不被键盘盖住（见外层 padding 的 kbH）。
        .barState(BarState.Auto)
        .onChange((v: string) => {
          if (this.queueEditId !== '') {
            this.editBuf = v;
            return;
          }
          this.draft = v;
          Drafts.set(this.param.id, v);
        })

      Row() {
        Blank()
        if (this.queueEditId !== '') {
          Text('保存')
            .fontSize(13)
            .fontColor(Tokens.accentInk)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .backgroundColor(this.editBuf.trim() === '' ? Tokens.surface3 : Tokens.accent)
            .borderRadius(999)
            .margin({ top: 12 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              this.saveQueueEdit();
            })
        } else {
          Text('发送')
            .fontSize(13)
            .fontColor(Tokens.accentInk)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .backgroundColor(this.draft.trim() === '' && !this.hasPend() ? Tokens.surface3 : Tokens.accent)
            .borderRadius(999)
            .margin({ top: 12 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              this.bigEditOn = false;
              this.send();
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    // 键盘高度要从可视高度里扣掉：整页用 KeyboardAvoidMode.NONE 自己排版，
    // 以前这里只留 16，长文本的光标行正好落在键盘底下，写多就「看不见」了。
    .padding({ left: 16, right: 16, top: 68, bottom: 16 + this.kbH })
    .backgroundColor(Tokens.bg)
    .transition(TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: '100%' }))
      .animation({ duration: 300, curve: curves.cubicBezierCurve(0.2, 0.0, 0.2, 1.0) }))
  }

  /** 上下文占比：0 到 100，保留一位小数，够大就不带小数。 */
  private ctxPercent(): number {
    if (this.ctx === null || this.ctx.window <= 0) return 0;
    const p = (this.ctx.used / this.ctx.window) * 100;
    return p < 0 ? 0 : (p > 100 ? 100 : p);
  }

  private ctxPctText(): string {
    const p = this.ctxPercent();
    return p >= 10 ? '' + Math.round(p) : p.toFixed(1);
  }

  private tokenTotal(): number {
    if (this.stats === null) return 0;
    const t = this.stats.tokens;
    return t.uncachedInputTokens + t.cacheReadTokens + t.cacheWriteTokens + t.outputTokens;
  }

  /** 首轮 prompt 的 token 数：系统提示词 + 工具定义 + 第一条消息，用它当「系统与工具」的估算基线。 */
  private baseTokens(): number {
    for (let i = 0; i < this.msgs.length; i++) {
      const t = this.msgs[i].turn;
      if (t !== undefined && t !== null && t.tokensIn > 0) return t.tokensIn;
    }
    return 0;
  }

  /** 上下文里被对话本身占掉的部分（估算）：上一次请求 - 首轮基线。 */
  private msgTokens(): number {
    if (this.ctx === null) return 0;
    const base = this.baseTokens();
    const used = this.ctx.used;
    if (base <= 0 || used <= base) return used;
    return used - base;
  }

  private mixUnit(): number {
    if (this.mixScope === 'window') return this.ctx === null ? 0 : this.ctx.window;
    return this.ctx === null ? 0 : this.ctx.used;
  }

  /** 最近一轮的输入/输出（拿最后一条带 turn 的助手消息）。 */
  private lastTurnIn(): number {
    for (let i = this.msgs.length - 1; i >= 0; i--) {
      const t = this.msgs[i].turn;
      if (t !== undefined && t !== null) return t.tokensIn;
    }
    return 0;
  }

  private lastTurnOut(): number {
    for (let i = this.msgs.length - 1; i >= 0; i--) {
      const t = this.msgs[i].turn;
      if (t !== undefined && t !== null) return t.tokensOut;
    }
    return 0;
  }

  private lastTurnWhen(): string {
    for (let i = this.msgs.length - 1; i >= 0; i--) {
      const t = this.msgs[i].turn;
      if (t !== undefined && t !== null && t.finishedAt !== undefined) return this.clockText(t.finishedAt as number);
    }
    return '';
  }

  /** 一条构成行：色点、名称、右侧数值与占比。 */
  @Builder
  private mixRow(color: string, name: string, value: number, total: number) {
    Row() {
      Circle().width(9).height(9).fill(color)
      Text(name)
        .fontSize(13)
        .fontColor(Tokens.fg)
        .margin({ left: 10 })
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(num(value))
        .fontSize(13)
        .fontColor(Tokens.fg)
      Text(total > 0 ? (Math.round(Math.min(100, (value / total) * 100) * 10) / 10).toFixed(1) + '%' : '-')
        .fontSize(12)
        .fontColor(Tokens.dim2)
        .width(58)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(40)
    .alignItems(VerticalAlign.Center)
  }

  /** 一条明细：左侧标签，右侧数值。 */
  @Builder
  private metaRow(label: string, value: string, strong: boolean) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(strong ? Tokens.fg : Tokens.dim)
        .layoutWeight(1)
      Text(value)
        .fontSize(strong ? 14 : 13)
        .fontWeight(strong ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(strong ? Tokens.fg : Tokens.dim2)
    }
    .width('100%')
    .height(38)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private mixTab(label: string, value: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.mixScope === value ? Tokens.fg : Tokens.dim2)
      .fontWeight(this.mixScope === value ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(999)
      .backgroundColor(this.mixScope === value ? Tokens.surface : Color.Transparent)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
      .onClick(() => {
        this.mixScope = value;
      })
  }

  @Builder
  private scopeTab(label: string, value: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.statsScope === value ? Tokens.fg : Tokens.dim2)
      .fontWeight(this.statsScope === value ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(999)
      .backgroundColor(this.statsScope === value ? Tokens.surface : Color.Transparent)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
      .onClick(() => {
        this.statsScope = value;
      })
  }

  @Builder
  statsBody() {
    Column() {
      Column() {
        // 标题行：左侧大标题，右上角刷新 + 关闭。以前只有刷新，关掉要靠下拉，和别人不一致。
        Row() {
          Text('上下文')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
          Text('↻')
            .fontSize(20)
            .fontColor(Tokens.dim)
            .width(38)
            .height(38)
            .textAlign(TextAlign.Center)
            .borderRadius(999)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .accessibilityText('刷新')
            .onClick(() => {
              Haptics.tap();
              this.load();
            })
          Text('×')
            .fontSize(20)
            .fontColor(Tokens.dim)
            .width(38)
            .height(38)
            .textAlign(TextAlign.Center)
            .borderRadius(999)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .accessibilityText('关闭')
            .onClick(() => {
              this.statsOn = false;
            })
        }
        .width('100%')
        .padding({ left: 2, right: 2, bottom: 10 })

        Scroll() {
          Column({ space: 12 }) {
            // ---------- 卡片一：当前上下文 ----------
            Column() {
              Text('当前上下文')
                .fontSize(12)
                .fontColor(Tokens.dim)
                .width('100%')
              Row() {
                Row() {
                  Text(this.ctxPctText())
                    .fontSize(52)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Tokens.fg)
                  Text('%')
                    .fontSize(20)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Tokens.dim)
                    .margin({ left: 2, bottom: 7 })
                }
                .alignItems(VerticalAlign.Bottom)
                .layoutWeight(1)

                Column() {
                  Text(this.ctx !== null ? ('≈ ' + num(this.ctx.used) + ' / ' + num(this.ctx.window) + ' token')
                    : '还没有上下文用量')
                    .fontSize(12)
                    .fontColor(Tokens.fg)
                  Text(this.ctx !== null ? ('剩余 ≈ ' + num(Math.max(0, this.ctx.window - this.ctx.used)))
                    : '跑一轮之后就有了')
                    .fontSize(12)
                    .fontColor(Tokens.dim2)
                    .margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.End)
              }
              .width('100%')
              .alignItems(VerticalAlign.Bottom)
              .margin({ top: 2, bottom: 14 })

              // 占比条：已用实色、剩余浅色轨道，右端标出窗口大小
              Stack({ alignContent: Alignment.Start }) {
                Row()
                  .width('100%')
                  .height(13)
                  .borderRadius(10)
                  .backgroundColor(Tokens.surface3)
                Row()
                  .width(this.ctxPercent() + '%')
                  .height(13)
                  .borderRadius(10)
                  .backgroundColor(Tokens.accent)
              }
              .width('100%')
              .height(13)
              .clip(true)

              Row() {
                Text('0')
                  .fontSize(11)
                  .fontColor(Tokens.dim2)
                Blank()
                Text('已用 ' + num(this.ctx !== null ? this.ctx.used : 0))
                  .fontSize(11)
                  .fontColor(Tokens.accent)
                Blank()
                Text(this.ctx !== null ? num(this.ctx.window) : '-')
                  .fontSize(11)
                  .fontColor(Tokens.dim2)
              }
              .width('100%')
              .margin({ top: 7 })

              Text('按 ' + (this.curModel !== '' ? this.curModel : '当前模型') + ' 的窗口大小计算，取宿主下一次请求的 prompt 估算；接近满时会自动压缩较早的历史。')
                .fontSize(12)
                .fontColor(Tokens.dim2)
                .lineHeight(17)
                .margin({ top: 12 })
                .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .borderRadius(Tokens.rGroup)
            .backgroundColor(Tokens.accentSoft)
            .alignItems(HorizontalAlign.Start)

            // ---------- 卡片二：占用构成（估） ----------
            Column() {
              Row() {
                Text('占用构成')
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Tokens.fg)
                  .layoutWeight(1)
                Row() {
                  this.mixTab('占已用', 'used')
                  this.mixTab('占窗口', 'window')
                }
                .padding(3)
                .borderRadius(999)
                .backgroundColor(Tokens.surface3)
              }
              .width('100%')
              .padding({ bottom: 4 })

              if (this.ctx === null) {
                Row() {
                  Text('跑一轮之后这里会有上下文构成').fontSize(13).fontColor(Tokens.dim2)
                }
                .height(60)
                .width('100%')
              } else {
                if (this.baseTokens() > 0 && this.baseTokens() < this.ctx.used) {
                  this.mixRow(Tokens.accent, '消息（含附件）', this.msgTokens(), this.mixUnit())
                  this.mixRow('#7AA2FF', '系统与工具', this.baseTokens(), this.mixUnit())
                } else {
                  this.mixRow(Tokens.accent, '全部上下文', this.ctx.used, this.mixUnit())
                }
                if (this.mixScope === 'window') {
                  this.mixRow(Tokens.surface3, '剩余', Math.max(0, this.ctx.window - this.ctx.used), this.mixUnit())
                }
                Divider().color(Tokens.line).margin({ top: 4, bottom: 2 })
                this.metaRow('上下文合计', num(this.ctx.used) + ' / ' + num(this.ctx.window) + ' token', true)
              }

              Text('数值是本地估算：系统与工具取首轮 prompt（含缓存命中），消息部分是当前上下文减掉这个基线；以宿主的 token-meter 为准。')
                .fontSize(12)
                .fontColor(Tokens.dim2)
                .lineHeight(17)
                .margin({ top: 8 })
                .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 12 })
            .borderRadius(Tokens.rGroup)
            .backgroundColor(Tokens.surface)
            .alignItems(HorizontalAlign.Start)

            // ---------- 卡片三：用量明细 ----------
            Column() {
              Row() {
                Text('用量')
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Tokens.fg)
                  .layoutWeight(1)
                Row() {
                  this.scopeTab('本会话', 'session')
                  this.scopeTab('最近一轮', 'turn')
                }
                .padding(3)
                .borderRadius(999)
                .backgroundColor(Tokens.surface3)
              }
              .width('100%')
              .padding({ bottom: 4 })

              if (this.stats === null) {
                Row() {
                  Text('这个会话还没有用量记录').fontSize(13).fontColor(Tokens.dim2)
                }
                .height(56)
                .width('100%')
              } else if (this.statsScope === 'session') {
                this.mixRow(Tokens.accent, '输入（未缓存）', this.stats.tokens.uncachedInputTokens, this.tokenTotal())
                this.mixRow('#7AA2FF', '缓存读取', this.stats.tokens.cacheReadTokens, this.tokenTotal())
                this.mixRow('#A9C0FF', '缓存写入', this.stats.tokens.cacheWriteTokens, this.tokenTotal())
                this.mixRow(Tokens.ok, '输出', this.stats.tokens.outputTokens, this.tokenTotal())
                Divider().color(Tokens.line).margin({ top: 4, bottom: 2 })
                this.metaRow('合计', num(this.tokenTotal()) + ' token', true)
              } else {
                this.mixRow(Tokens.accent, '输入', this.lastTurnIn(), this.lastTurnIn() + this.lastTurnOut())
                this.mixRow(Tokens.ok, '输出', this.lastTurnOut(), this.lastTurnIn() + this.lastTurnOut())
                Divider().color(Tokens.line).margin({ top: 4, bottom: 2 })
                this.metaRow('合计', num(this.lastTurnIn() + this.lastTurnOut()) + ' token', true)
                if (this.lastTurnWhen() !== '') {
                  this.metaRow('完成于', this.lastTurnWhen(), false)
                }
              }

              Divider().color(Tokens.line).margin({ top: 6, bottom: 2 })

              if (this.stats !== null) {
                this.metaRow('轮次', '' + this.stats.turns, false)
                this.metaRow('步骤', '' + this.stats.steps, false)
                this.metaRow('工具调用', '' + this.stats.toolCalls, false)
                this.metaRow('消息', this.msgs.length + (this.hasMore ? '+' : '') + ' 条', false)
                Divider().color(Tokens.line).margin({ top: 4, bottom: 4 })
                this.metaRow('上次请求的 prompt', this.ctx !== null ? '≈ ' + num(this.ctx.used) + ' token' : '-', true)
                this.metaRow('缓存命中率', cmpRate(this.stats.tokens), true)
                this.metaRow('这个会话一共用了', num(this.tokenTotal()) + ' token', true)
              } else {
                Row() {
                  Text('跑一轮之后这里会有明细').fontSize(13).fontColor(Tokens.dim2)
                }
                .height(60)
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .borderRadius(Tokens.rGroup)
            .backgroundColor(Tokens.surface)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ bottom: 20 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .clip(true)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 20, right: 20, top: 6, bottom: 14 })
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height('100%')
  }

  /** 附件菜单的一枚胶囊：点一下选完自动收起，输入法不会掉。 */

  @Builder
  headerBar() {
    Column() {
      Row() {
        Stack() {
          Text('‹')
            .fontSize(15)
            .fontColor(Tokens.fg)
            .textAlign(TextAlign.Center)
        }
        .width(38)
        .height(38)
        .borderRadius(999)
        .systemMaterial(Mat.whiteOn(this.matOn()))
        .border({ width: 1, color: Tokens.glassLine })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => this.stack.pop())

        Row() {
          Column() {
            Text(this.titleNow !== '' ? this.titleNow : '会话')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.fg)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.curModel !== '' ? this.curModel : (this.loading ? '拉取中…' : ''))
              .fontSize(11)
              .fontColor(Tokens.dim)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 1 })
          }
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 14, right: 14 })
        }
        .height(38)
        // 标题胶囊吃掉中间剩余空间：固定宽高会让标题一长就把 ▤ / ⋯ 顶出屏幕，
        // 之前「▤ 摁不了」就是这么来的。
        .layoutWeight(1)
        .constraintSize({ minWidth: 110 })
        .justifyContent(FlexAlign.Center)
        .margin({ left: 8, right: 8 })
        .systemMaterial(Mat.whiteOn(this.matOn()))
        .borderRadius(999)
        .border({ width: 1, color: Tokens.glassLine })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
        .onClick(() => {
          this.hideKb();
          this.openModels();
        })
        .bindSheet($$this.modelOn, this.modelSheetBody(), {
          height: '76%',
          dragBar: true,
          showClose: false,
          backgroundColor: Tokens.sheetWarm,
          blurStyle: BlurStyle.COMPONENT_THICK,
          maskColor: Tokens.scrim,
          onDisappear: () => {
            this.modelOn = false;
          }
        })

        Stack() {
          Text('▤')
            .fontSize(15)
            .fontColor(Tokens.fg)
            .textAlign(TextAlign.Center)
        }
        .width(38)
        .height(38)
        .borderRadius(999)
        .systemMaterial(Mat.whiteOn(this.matOn()))
        .border({ width: 1, color: Tokens.glassLine })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => {
          this.hideKb();
          this.statsOn = true;
        })
        .accessibilityText('运行统计')
        .bindSheet($$this.statsOn, this.statsBody(), {
          height: '76%',
          dragBar: true,
          showClose: false,
          backgroundColor: Tokens.sheetWarm,
          blurStyle: BlurStyle.COMPONENT_THICK,
          maskColor: Tokens.scrim,
          onDisappear: () => {
            this.statsOn = false;
          }
        })

        Stack() {
          Text('⋯')
            .fontSize(15)
            .fontColor(Tokens.fg)
            .textAlign(TextAlign.Center)
        }
        .width(38)
        .height(38)
        .borderRadius(999)
        .systemMaterial(Mat.whiteOn(this.matOn()))
        .border({ width: 1, color: Tokens.glassLine })
        .margin({ left: 8 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onTouch((e: TouchEvent) => {
          if (e.type === TouchType.Down) {
            this.hideKb();
          }
        })
        .onClick(() => {
          Haptics.tap();
          this.menuOn = true;
        })
        // 和首页「分组方式」同一套自绘弹窗：宽度、圆角、行的密度都和那边一致。
        // 顺带修掉「进会话要按两次才退出」：以前 menuOn 置真后没有任何地方收回，
        // onBackPressed 里那句 if (this.menuOn) 每次都先吞掉一次返回。
        .bindPopup(this.menuOn, {
          builder: this.chatMenuPanel(),
          placement: Placement.Bottom,
          popupColor: Color.Transparent,
          enableArrow: false,
          radius: 18,
          offset: { x: 0, y: 6 },
          transition: TransitionEffect.OPACITY
            .combine(TransitionEffect.scale({ x: 0.94, y: 0.94, centerX: '100%', centerY: '0%' }))
            .animation({ duration: 180, curve: Curve.EaseOut }),
          onStateChange: (e) => {
            if (!e.isVisible) {
              this.menuOn = false;
            }
          }
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .padding({ left: 2, right: 8 })

      // 顶部成员条：这个会话的子智能体（横向滚动，不单独成页）
      if (this.agents.length > 0) {
        Scroll() {
          Row() {
            Text('智能体')
              .fontSize(11)
              .fontColor(Tokens.dim2)
              .margin({ right: 8 })
            ForEach(this.agents, (a: AgentRef) => {
              Row() {
                Text(a.label)
                  .fontSize(12)
                  .fontColor(Tokens.fg)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (a.mode === 'continuable') {
                  Text('·')
                    .fontSize(12)
                    .fontColor(Tokens.accent)
                    .margin({ left: 3 })
                }
              }
              .constraintSize({ maxWidth: 168 })
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .margin({ right: 6 })
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(999)
            }, (a: AgentRef) => a.id)
          }
          .padding({ left: 16, right: 8, top: 6, bottom: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
    }
    .width('100%')
  }

  /** HDS 标题栏：内容交给自绘的 headerBar，底板与材质由 HDS 画。 */
  /** 标题栏内容整体下压，别贴着屏幕上沿。 */
  @Builder
  headerPadded() {
    // HDS 标题栏从屏幕最上沿开始画，不会自动让出状态栏；内边距只能加在这里。
    Column() {
      this.headerBar();
    }
    .width('100%')
    .padding({ top: 65, left: 14, right: 6, bottom: 10 })
  }

  private hdsTitle(): HdsNavigationTitleBarOptions {
    const stack: CustomBuilder = (): void => {
      this.headerPadded();
    };
    const content: TitleBarContentOptions = { stackBuilder: stack };
    // 标题栏底板留空：只要几枚自绘胶囊悬浮，不要整条泛白/泛灰的遮挡
    const style: TitleBarStyleOptions = {};
    // 顶栏不要整条底板/遮罩：只要几枚自绘胶囊浮着
    const bgStyle: HdsNavigationBackgroundStyle = {};
    bgStyle.backgroundColor = Color.Transparent;
    bgStyle.blurRadius = 0;
    // 标题栏下面那条泛白/泛灰的整块遮罩就是它：额外遮罩高度清零
    bgStyle.maskExtraHeight = 0;
    const origStyle: HdsNavigationTitleBarStyle = {};
    origStyle.backgroundStyle = bgStyle;
    style.originalStyle = origStyle;
    // 标题栏自带的模糊带：彻底关掉，让内容直接从胶囊后面穿过
    style.blurStrategy = BlurStrategy.DISABLE;
    // 关键：HDS 标题栏默认开启滚动特效（COMMON_BLUR + 默认底色），滚动后会画出一条
    // 半透明遮罩带。scrollEffectStyle 未设时用的是系统默认样式，所以必须显式关掉。
    const eff: ScrollEffectOptions = {};
    eff.enableScrollEffect = false;
    style.scrollEffectOpts = eff;
    // 双保险：即使系统仍走滚动样式，也用同一套透明底色
    style.scrollEffectStyle = origStyle;
    // 往下压一点：贴住状态栏会让顶栏看着像被顶到屏幕上沿
    const opts: HdsNavigationTitleBarOptions = { content: content, style: style };
    return opts;
  }

  /** 设备是否支持 HDS 沉浸材质。 */
  /** 沉浸光感开关：设置里关掉后退回普通底色 */
  private matOn(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>('hdsOn');
    if (v === false) {
      return false;
    }
    return this.hdsMat();
  }

  private hdsMat(): boolean {
    try {
      const types: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
      return types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
    } catch (e) {
      console.info('DSH_HDS probe failed: ' + JSON.stringify(e));
      return false;
    }
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        // 底色画成栈里的第一层，而不是 NavDestination 的 backgroundColor：
        // NavDestination 自带不透明底色时，子节点的 backgroundEffect 会糊到那层底色上，
        // 看起来就是"完全没模糊"。
        Row()
          .width('100%')
          .height('100%')
          .backgroundColor(this.themeBg)
          .hitTestBehavior(HitTestMode.None)

        if (this.loading && this.msgs.length === 0) {
          Column() {
            LoadingProgress()
              .width(46)
              .height(46)
              .color(Tokens.accent)
            Text('正在拉取会话…')
              .fontSize(12)
              .fontColor(Tokens.dim)
              .margin({ top: 10 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .zIndex(5)
          .hitTestBehavior(HitTestMode.None)
          .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
        }

          List({ space: 0, scroller: this.scroller }) {
            // 顶部留白用占位项而不是 padding：padding 会裁掉列表视口，
            // 正文就永远滚不到顶栏玻璃底下，背景模糊没有内容可糊。
            ListItem() {
              Row()
                .width('100%')
                .height(96)
            }
            if (this.hasMore) {
              ListItem() {
                Row() {
                  Text(this.loadingMore ? '正在取更早的消息…' : '↑ 加载更早的消息')
                    .fontSize(13)
                    .fontColor(this.loadingMore ? Tokens.dim2 : Tokens.accent)
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 6, bottom: 16 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                .onClick(() => {
                  this.loadOlder();
                })
              }
            }
            if (!this.loading && this.msgs.length === 0) {
              ListItem() {
                Column() {
                  Image($r('app.media.ic_chat'))
                    .width(44)
                    .height(44)
                    .fillColor(Tokens.dim2)
                    .objectFit(ImageFit.Contain)
                  Text('开始对话')
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Tokens.fg)
                    .margin({ top: 12 })
                  Text('在下面输入，或先用输入框左下角的 ＋ 选张图片')
                    .fontSize(12)
                    .fontColor(Tokens.dim2)
                    .margin({ top: 6 })
                    .textAlign(TextAlign.Center)
                }
                .width('100%')
                .padding({ top: 80, bottom: 40 })
                .alignItems(HorizontalAlign.Center)
              }
            }
            ForEach(this.msgs, (m: Message, i: number) => {
              ListItem() {
                Column() {
                  if (i === 0 || !sameDay(this.msgs[i - 1].time, m.time)) {
                    Text(dayLabel(m.time))
                      .fontSize(11)
                      .fontColor(Tokens.dim2)
                      .backgroundColor(Tokens.chip)
                      .borderRadius(Tokens.rPill)
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .margin({ top: 10, bottom: 8 })
                  }
                  this.bubble(m)
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
              }
              .transition(TransitionEffect.OPACITY
                .combine(TransitionEffect.translate({ y: 14 }))
                .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
                .animation({ duration: 320, curve: Curve.Friction }))
            }, (m: Message) => '' + m.seq + m.role)
            if (this.running) {
              ListItem() {
                TypingBubble({ active: this.dotOn })
              }
              .transition(TransitionEffect.OPACITY
                .animation({ duration: 200, curve: Curve.EaseOut }))
            }
            if (this.errCard !== '') {
              ListItem() {
                this.errCardView()
              }
            }
            // 底部留白同理，让最后一条也能滚到输入区玻璃底下
            ListItem() {
              Row()
                .width('100%')
                .height(200 + this.kbH + this.pendH)
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: 14, right: 14 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          // 只有滚动位置真的到底才跟随新消息。以前 catch 里直接置 true，
          // 一取不到位置就把之后收到的每条消息都往底部拽 = 「强制跳底」。
          .onScroll(() => {
            try {
              this.atBottom = this.scroller.isAtEnd();
            } catch (e) {
              console.info('DSH_SCROLL probe skipped');
            }
          })

          .hitTestBehavior(HitTestMode.Transparent)
          // 长按气泡时把操作面板挂在列表上：系统半模态，毛玻璃底
          .bindSheet($$this.msgMenuOn, this.selectSheet(), {
            height: '92%',
            dragBar: false,
            showClose: false,
            backgroundColor: Tokens.sheetWarm,
            blurStyle: BlurStyle.COMPONENT_THICK,
            maskColor: Tokens.scrim,
            onDisappear: () => {
              this.msgMenuOn = false;
            }
          })


          // 顶栏透明（HDS 的滚动模糊被关掉），内容滚上来会和状态栏文字叠在一起，
          // 这里用一层同色渐变压淡顶部，并且不吃点击。
          Column()
            .width('100%')
            .height(120)
            .linearGradient({ angle: 180, colors: [[this.themeBg, 0.0], [this.themeBg, 0.55], ['#00' + this.themeBg.slice(1), 1.0]] })
            .hitTestBehavior(HitTestMode.None)
            .position({ x: 0, y: 0 })

          // 底部：玻璃胶囊条 + 输入行 + 免责声明
          Stack({ alignContent: Alignment.Bottom }) {
            // 待发送板与输入框是半透明的，底下正文太花会看不清：
            // 贴一层由下往上收的底色，靠下越实，上缘完全透明。
            Row()
              .width('100%')
              .height(this.pendH + 230 + this.kbH)
              .linearGradient({
                angle: 180,
                colors: [['#00' + this.themeBg.slice(1), 0.0], [this.themeBg, 0.72], [this.themeBg, 1.0]]
              })
              .hitTestBehavior(HitTestMode.None)
            Column() {
            if (this.err !== '') {
              Text(this.err)
                .fontSize(12)
                .fontColor(Tokens.err)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ left: 4, bottom: 6 })
            }

            // 电脑端队列：这些是真正在宿主里排着的，本轮结束后由电脑自动发出
            if (this.asks.length > 0) {
          Column({ space: 6 }) {
            ForEach(this.asks, (a: PendingAsk) => {
              this.askCard(a, a.questions[this.askIndex(a)])
            }, (a: PendingAsk) => a.callId + '-' + String(this.askIndex(a)))
          }
          .width('100%')
          .margin({ bottom: 8 })
        }
        // 重启/中断把宿主的队列丢了：本地影子在这里兜底，一键重发
        if (this.rescue.length > 0) {
          Column({ space: 6 }) {
            Row() {
              Text('未发出 ' + String(this.rescue.length))
                .fontSize(11)
                .fontColor(Tokens.err)
                .backgroundColor(Tokens.surface3)
                .borderRadius(10)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              Text(this.rescue[0].text !== '' ? this.rescue[0].text : '（图片消息）')
                .fontSize(12)
                .fontColor(Tokens.dim)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .margin({ left: 8 })
              Text(this.rescueBusy ? '重发中' : '重发')
                .fontSize(12)
                .fontColor(Tokens.accent)
                .padding({ left: 10, right: 8, top: 2, bottom: 2 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                .onClick(() => {
                  this.resendRescue();
                })
              Text('忽略')
                .fontSize(12)
                .fontColor(Tokens.dim)
                .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                .onClick(() => {
                  this.dismissRescue();
                })
            }
            .width('100%')
            .padding({ left: 12, right: 10, top: 8, bottom: 8 })
            .backgroundColor(Tokens.surface2)
            .borderRadius(14)
            Text('这一轮被中断（多半是电脑端重启），这几条还留在手机上，重发会按原顺序再发一遍。')
              .fontSize(11)
              .fontColor(Tokens.dim)
              .width('100%')
              .padding({ left: 4 })
          }
          .width('100%')
          .margin({ bottom: 8 })
        }



            // 候选板：垫在输入框下面，下部被输入框盖住
            if (this.pendFiles.length + this.queueItems.length > 0) {
              PendingBoard({
                rows: this.pendRows(),
                cardH: this.pendCardHeight(),
                onFire: (r: PendRow) => {
                  this.fireRow(r);
                },
                onEdit: (r: PendRow) => {
                  const q: QueuedItem | null = this.queueById(r.id);
                  if (q !== null) {
                    this.doQueueEdit(q);
                  }
                },
                onRemove: (r: PendRow) => {
                  this.dropRow(r);
                },
                onMove: (from: number, to: number) => {
                  this.pendMove(from, to);
                },
                onHeight: (h: number) => {
                  if (Math.abs(h - this.pendH) > 2) {
                    this.pendH = h;
                    if (this.atBottom) {
                      setTimeout(() => { this.scroller.scrollEdge(Edge.Bottom); }, 40);
                    }
                  }
                }
              })
            }

            Column() {
              // 选好的图片直接贴在输入框上方：输入区随之往上撑，点图看大图，左上角叉掉
              if (this.pendImgs.length > 0) {
                PendingImages({
                  images: this.pendImgs,
                  onPreview: (d: string) => {
                    this.bigImg = d;
                  },
                  onRemove: (i: number) => {
                    this.pendImgs.splice(i, 1);
                    this.pendImgs = this.pendImgs.slice();
                  }
                })
              }

              Row() {
                // 多行：高度跟着内容长，三行封顶，再多就靠框内滚动（barState Auto 的滑轨）。
                // 不能设 maxLines：设了就把可视行数钉死、卡片不再长高，文字还会贴死在顶部。
                TextArea({ placeholder: '发消息或问点什么…', text: this.draft })
                  .placeholderColor(Tokens.dim2)
                  .fontColor(Tokens.fg)
                  .fontSize(15)
                  .lineHeight(21)
                  .padding({ left: 12, right: 4, top: 12, bottom: 12 })
                  .backgroundColor(Color.Transparent)
                  .layoutWeight(1)
                  .constraintSize({ minHeight: 46, maxHeight: 87 })
                  .barState(BarState.Auto)
                  .enterKeyType(EnterKeyType.Send)
                  .onChange((v: string) => {
                    this.draft = v;
                    // 改过内容就是另一条消息：重试要用新的幂等键，不能复用上一次的。
                    this.pendingKey = '';
                    Drafts.set(this.param.id, v);
                  })
                  .onSubmit(() => {
                    // 外观 →「回车发送」关掉时，回车只换行；发送走右侧按钮。
                    const enterSend: boolean | undefined = AppStorage.get<boolean>('enterSend');
                    if (enterSend === false) {
                      this.draft = this.draft + '\n';
                      return;
                    }
                    this.send();
                  })
                Row() {
                  Image($r('app.media.ic_expand'))
                    .width(18)
                    .height(18)
                    .fillColor(Tokens.dim)
                    .draggable(false)
                }
                .width(40)
                .height(40)
                .justifyContent(FlexAlign.Center)
                .margin({ left: 2, right: 6 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                .accessibilityText('展开编辑')
                .onClick(() => {
                  Haptics.tap();
                  this.bigEditOn = true;
                })
              }
              .width('100%')

              if (this.attachOn) {
                AttachMenu({
                  onCamera: (): void => {
                    this.attachOn = false;
                    this.pickCamera();
                  },
                  onPhotos: (): void => {
                    this.attachOn = false;
                    this.pickAttach();
                  },
                  onFiles: (): void => {
                    this.attachOn = false;
                    this.pickAttachFile();
                  }
                })

              }

              Row() {
                this.usageRing()
                Stack() {
                  Image($r('app.media.ic_goal'))
                    .width(17)
                    .height(17)
                    .fillColor(Tokens.dim)
                }
                .width(30)
                .height(30)
                .margin({ left: 8 })
                .borderRadius(999)
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                .onClick(() => {
                  Haptics.tap();
                  this.openGoal();
                })
                .bindSheet($$this.goalOn, this.goalBody(), {
                  height: '46%',
                  dragBar: true,
                  showClose: false,
                  backgroundColor: Tokens.sheetWarm,
                  blurStyle: BlurStyle.COMPONENT_THICK,
                  maskColor: Tokens.scrim,
                  onDisappear: () => {
                    this.goalEdit = false;
                  }
                })
                Blank()
                Text('＋')
                  .fontSize(20)
                  .fontColor(Tokens.dim)
                  .width(36)
                  .height(36)
                  .textAlign(TextAlign.Center)
                  .borderRadius(999)
                  .backgroundColor(Color.Transparent)
                  .margin({ left: 8 })
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                  .onClick(() => {
                    Haptics.tap();
                    this.attachOn = !this.attachOn;
                  })
                if (this.running && (this.draft.trim() !== '' || this.hasPend())) {
                  Text('排队')
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                    .padding({ left: 13, right: 13, top: 7, bottom: 7 })
                    .backgroundColor(Tokens.accent)
                    .borderRadius(999)
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                    .margin({ left: 8 })
                    .onClick(() => {
                      Haptics.tap();
                      this.send(false);
                    })
                  Text('插队')
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                    .padding({ left: 13, right: 13, top: 7, bottom: 7 })
                    .backgroundColor(Tokens.err)
                    .borderRadius(999)
                    .shadow({ radius: 12, color: '#4DD4380D', offsetY: 2 })
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                    .margin({ left: 8 })
                    .onClick(() => {
                      Haptics.tap();
                      this.send(true);
                    })
                }
                if (this.running && this.draft.trim() === '' && !this.hasPend()) {
                  // 正在生成时，发送键变成停止键——手机上不该为了停一轮去翻菜单。
                  Text('■')
                    .fontSize(13)
                    .fontColor(Tokens.fg)
                    .width(38)
                    .height(38)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(Color.Transparent)
                    .borderRadius(999)
                    .margin({ left: 14 })
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                    .onClick(() => this.doStop())
                } else if (!this.running) {
                  Text(this.sending ? '···' : '↑')
                    .fontSize(this.draft.trim() === '' && !this.hasPend() ? 18 : 20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.draft.trim() === '' && !this.hasPend() ? Tokens.dim2 : '#FFFFFF')
                    .width(38)
                    .height(38)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(this.draft.trim() === '' && !this.hasPend() ? Color.Transparent : Tokens.accent)
                    .borderRadius(999)
                    .shadow(this.draft.trim() === '' && !this.hasPend()
                      ? { radius: 0, color: Color.Transparent }
                      : { radius: 14, color: Tokens.accentGlow, offsetY: 3 })
                    .animation({ duration: 180, curve: Curve.EaseOut })
                    .margin({ left: 10 })
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                    .onClick(() => this.send())
                }
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            // 输入卡改成更实的雾面：以前几乎全透，正文从卡片底下穿过来，占位符和草稿都难读。
            .backgroundColor(Tokens.isDark ? '#F2161A22' : '#FAFFFFFF')
            .backdropBlur(24)
            // 永远是完整的悬浮圆角矩形：候选板不参与造形，另成一块
            .borderRadius(20)
            .border({ width: 1, color: Tokens.line })
            .shadow({ radius: 26, color: Tokens.shadow, offsetY: 6 })
            .onAreaChange((oldValue: Area, newValue: Area) => {
              const h: number = Number(newValue.height);
              if (h > 0 && Math.abs(h - this.inputH) > 1) {
                this.inputH = h;
              }
            })

            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 12, bottom: 26 + this.kbH })
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.Transparent)


        // 只要不在底部就给出口，待发送板/队列展开时也照常显示；位置由 pendH 让开
        if (!this.atBottom) {
          Stack() {
            Image($r('app.media.ic_down'))
              .width(17)
              .height(17)
              .fillColor(Tokens.fg)
              .draggable(false)
          }
          .width(42)
          .height(42)
          .borderRadius(999)
          .backgroundColor(Tokens.glassFloat)
          .backdropBlur(18)
          .border({ width: 1, color: Tokens.glassTop })
          .shadow({ radius: 18, color: Tokens.shadow, offsetY: 6 })
          // 输入卡实测高度 + 待发送板高度：按钮永远浮在它们上方，不重合
          // 40 = 输入区外层下内距 26 + 输入卡顶边再留 14，避免和玻璃卡边缘/阴影压在一起
          .position({ right: 18, bottom: this.kbH + this.inputH + 40 + this.pendH })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .transition(TransitionEffect.OPACITY.animation({ duration: 160 }))
          .onClick(() => {
            Haptics.tap();
            this.scroller.scrollEdge(Edge.Bottom);
            this.atBottom = true;
          })
        }

        if (this.renaming) {
          this.renameDialog()
        }
        if (this.extrasMode !== '') {
          ExtrasPanel({
            mode: this.extrasMode,
            sessionId: this.param.id,
            api: this.api,
            onExit: () => {
              this.extrasMode = '';
            }
          })
        }
        if (this.bigEditOn) {
          this.bigEditor()
        }
        if (this.searchOn) {
          this.searchOverlay()
        }
      }
      .width('100%')
      .height('100%')
    }
    // 打开三块面板时藏掉聊天页标题栏：面板自带返回键，两个返回键会打架
    .hideTitleBar(this.bigEditOn || this.extrasMode !== '' || this.searchOn)
    .titleBar(this.hdsTitle())
    .padding({ top: 0 })
    .onBackPressed(() => {
      // 面板打开时，返回键先关面板，而不是退出到会话列表
      if (this.extrasMode !== '') {
        this.extrasMode = '';
        return true;
      }
      if (this.searchOn) {
        this.searchOn = false;
        return true;
      }
      if (this.menuOn) {
        this.menuOn = false;
        return true;
      }
      if (this.modelOn || this.statsOn) {
        this.shutSheet();
        return true;
      }
      if (this.bigEditOn) {
        this.bigEditOn = false;
        return true;
      }
      // 交给系统默认返回在这里不一定会 pop（实测第一下没反应，要按两下才退出），
      // 所以自己出栈，返回 true 表示已经处理掉了。栈里只剩这一页时不动，让系统去退应用。
      if (this.stack.size() >= 1) {
        this.stack.pop();
        return true;
      }
      return false;
    })
    .hideBackButton(true)
    .bindToScrollable([this.scroller])
    .backgroundColor(this.themeBg)
    .mode(NavDestinationMode.STANDARD)
  }
}


