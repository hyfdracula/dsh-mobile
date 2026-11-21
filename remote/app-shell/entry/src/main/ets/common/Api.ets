import http from '@ohos.net.http';
import { ImagePart } from './Images';
import { FilePart } from './Files';

/** 会话行（对应 GET /api/sessions 的 sessions[]） */
export interface SessionRow {
  id: string;
  title: string;
  updatedAt: number;
  cwd: string;
  running: boolean;
  /** 宿主有挂起的提问/审批：会话卡片标黄「等你回答」。 */
  asking?: boolean;
  archived?: boolean;
  pinned?: boolean;
  agents?: AgentSummary;
  model?: ModelRef;
  context?: ContextUsage | null;
}

export interface TokenUsage {
  uncachedInputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

export interface SessionStats {
  turns: number;
  steps: number;
  toolCalls: number;
  tokens: TokenUsage;
}

/** 消息里的一张图片：只带摘要，字节由 /api/attachments 单独取 */
export interface ImageRef {
  id: string;
  mediaType: string;
  width: number;
  height: number;
  name: string;
}

/** 一轮的结局，挂在那一轮最后一条回复上（宿主 turn/end 的 reason）。 */
export interface GoalView {
  id?: string;
  objective?: string;
  phase?: string;
  revision?: number;
  roundsStarted?: number;
  maxGoalRounds?: number;
  activation?: string;
}

interface GoalResp {
  ok?: boolean;
  sessionId?: string;
  goal?: GoalView | null;
}

export interface TurnInfo {
  status: string;
  ms: number;
  tokensIn: number;
  tokensOut: number;
  atSeq: number;
  finishedAt?: number;
}

export interface Message {
  role: string;
  text: string;
  time: number;
  seq: number;
  images?: ImageRef[];
  turn?: TurnInfo;
}

/** 上下文占用：宿主 token-meter 投影（used 为下一次请求的 prompt 估算，window 为路由容量）。 */
export interface ContextUsage {
  used: number;
  window: number;
}

/** 电脑端待发送队列里的一条（真正躺在 DSH 宿主里的，不是手机上假排的） */
export interface QueueTextBody {
  text: string;
}

/** 宿主队列里一条消息内的图片（只有元信息，字节走 /queue-image）。 */
export interface QueueImage {
  mediaType: string;
  name?: string;
}

export interface QueuedItem {
  id: string;
  text: string;
  at: number;
  index: number;
  images?: QueueImage[];
}

export interface AskOption {
  label: string;
  description?: string;
}

export interface AskQuestion {
  id: string;
  prompt?: string;
  header?: string;
  detail?: string;
  options?: AskOption[];
  multiSelect?: boolean;
}

export interface PendingAsk {
  callId: string;
  questions: AskQuestion[];
  state: string;
  /** 题卡编号由手机网关合成（宿主这次提问没有带 callId），回答时原样回传即可。 */
  synthetic?: boolean;
}

export interface AskAnswer {
  id: string;
  selected: string[];
  custom?: string;
}

export interface AnswerBody {
  callId: string;
  answers: AskAnswer[];
}

export interface AskState {
  active: PendingAsk[];
  settled: Object[];
}

export interface MessagesResult {
  total: number;
  messages: Message[];
  context?: ContextUsage | null;
  stats?: SessionStats;
  firstSeq?: number;
  running?: boolean;
  /** 最后一轮的结束原因（completed / aborted / interrupted / error …） */
  lastTurn?: string;
  queue?: QueuedItem[];
  questions?: AskState;
}

export interface ModelRef {
  provider: string;
  model: string;
  reasoningEffort?: string;
}

export interface AgentRef {
  id: string;
  label: string;
  mode: string;
  createdAt: number;
}

/** 会话携带的智能体概况（子智能体 + 团队任务数） */
export interface AgentSummary {
  enabled: number;
  tasks: number;
  subagents: AgentRef[];
}

export interface ApiInfo {
  ok: boolean;
  version: string;
  host: string;
  port: number;
}

interface SessionsResp {
  ok: boolean;
  sessions: SessionRow[];
}

export interface PreviewRow {
  id: string;
  preview: string;
  count: number;
}

interface PreviewsResp {
  ok: boolean;
  previews: PreviewRow[];
}

interface MessagesResp {
  ok: boolean;
  sessionId: string;
  total: number;
  messages: Message[];
  stats?: SessionStats;
  context?: ContextUsage | null;
  running?: boolean;
  firstSeq?: number;
  lastTurn?: string;
  queue?: QueuedItem[];
  questions?: AskState;
}

interface PresenceBody {
  online: boolean;
}

interface PresenceResp {
  ok?: boolean;
  online?: boolean;
  ttlMs?: number;
}

interface InfoResp {
  ok: boolean;
  version: string;
  host: string;
  port: number;
  addresses?: string[];
}

interface RawResult {
  code: number;
  text: string;
}

/** 服务端出错时回的那一小段 JSON，只需要 error。 */
interface QueueOrderBody {
  ids: string[];
}

interface QueueOrderResp {
  ok?: boolean;
  moved?: number;
}

interface ErrBody {
  error?: string;
}

/**
 * dsh-mobile 的 HTTP 客户端。
 *
 * 两个入口：局域网地址（同一个 Wi-Fi 时最快）与公网隧道地址（在外面时唯一可用）。
 * 首次请求前先探一次局域网 /health，通了就用局域网，否则用隧道；
 * 之后如果请求连续失败（换网、隧道抖动），会重置选择并重新探测一次。
 *
 * 另：隧道域名在 Cloudflare 边缘有多个 anycast IP，个别网络下其中一个不可达，
 * 单次请求会直接超时，所以网络类失败最多重试 3 次（HTTP 4xx/5xx 不重试）。
 */
export class Api {
  token: string;
  /** true 时跳过局域网探测，强制走隧道入口。 */
  forceWan: boolean = false;
  /**
   * 同一个 Wi-Fi 下自动改走局域网直连。用户可以在 设置 → 连接 里关掉：
   * 关掉后只走配对的公网地址（隧道），不再试探局域网。
   */
  autoLan: boolean = true;
  private lanBase: string;
  private wanBase: string;
  private chosen: string = '';
  /** 已经走隧道时，下一次在后台重探局域网的时间（人一走进家里就自动切回来） */
  private nextLanProbe: number = 0;
  /** 局域网探针失败后的冷却截止时间：人在外面时每次都白等 1.5 秒太亏。 */
  private lanDownUntil: number = 0;

  constructor(wanBase: string, token: string, lanBase: string = '') {
    this.wanBase = wanBase.replace(/\/+$/, '');
    this.lanBase = lanBase.replace(/\/+$/, '');
    this.token = token;
  }

  /** 当前实际使用的入口，供界面展示。 */
  currentBase(): string {
    return this.chosen !== '' ? this.chosen : this.wanBase;
  }

  /**
   * 一张图片的直链。
   * @param img - 消息里带的图片摘要
   * @returns 带令牌的完整 URL，<Image> 组件直接可用
   */
  attachmentUrl(img: ImageRef): string {
    const mt: string = img.mediaType !== '' ? img.mediaType : 'image/png';
    return this.currentBase() + '/api/attachments/' + img.id + '?t=' + encodeURIComponent(this.token) +
      '&m=' + encodeURIComponent(mt);
  }

  /** 切换连接偏好；清掉已选入口让下一次请求重新探测。 */
  setForceWan(v: boolean): void {
    this.forceWan = v;
    this.chosen = '';
  }

  setAutoLan(v: boolean): void {
    this.autoLan = v;
    this.chosen = '';
  }

  isLan(): boolean {
    return this.lanBase !== '' && this.chosen === this.lanBase;
  }

  /**
   * 就地换地址与令牌。
   * 子组件持有的都是同一个 Api 引用，非装饰成员不会跟着父组件重建刷新，
   * 所以配对成功后必须改这个对象本身，而不是在 Index 里 new 一个新的。
   * @param lanBase - 已配对电脑自己报的局域网地址；留空表示不再拿旧地址试探，
   *   否则换一台电脑后会把新令牌先发给原来那个 IP 上的设备。
   */
  rebase(wanBase: string, token: string, lanBase: string = ''): void {
    this.wanBase = wanBase.replace(/\/+$/, '');
    this.lanBase = lanBase.replace(/\/+$/, '');
    this.token = token;
    this.chosen = '';
    this.lanDownUntil = 0;
    console.info('DSH_BASE rebase ' + this.wanBase + ' lan=' + (this.lanBase !== '' ? this.lanBase : '-'));
  }

  private async rawGet(url: string, timeoutMs: number, auth: boolean): Promise<RawResult> {
    const req = http.createHttp();
    try {
      const header: Record<string, string> = { 'Content-Type': 'application/json; charset=utf-8' };
      if (auth) {
        header['Authorization'] = 'Bearer ' + this.token;
      }
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs + 4000
      };
      const res = await req.request(url, opts);
      return { code: res.responseCode as number, text: (res.result as string) ?? '' };
    } finally {
      req.destroy();
    }
  }

  /** 选一次入口：局域网探得通就走局域网，否则走隧道。 */
  private async ensureBase(): Promise<string> {
    if (this.chosen !== '') {
      return this.chosen;
    }
    if (this.forceWan || !this.autoLan) {
      this.chosen = this.wanBase;
      console.info('DSH_BASE wan (forced) ' + this.wanBase);
      return this.chosen;
    }
    if (this.lanBase !== '' && Date.now() >= this.lanDownUntil) {
      try {
        // 探针要带令牌：/health 是免鉴权的，只探它会在换了令牌后误判局域网可用，
        // 随后每个业务请求都 401。所以用 /api/info 探，200 才算这个入口真能用。
        const r = await this.rawGet(this.lanBase + '/api/info', 800, true);
        if (r.code === 200 || r.code === 401 || r.code === 403) {
          this.chosen = this.lanBase;
          this.lanDownUntil = 0;
          console.info('DSH_BASE lan ' + this.lanBase);
          return this.chosen;
        }
      } catch (e) {
        this.lanDownUntil = Date.now() + 60000;
        console.info('DSH_BASE lan probe failed: ' + (e as Error).message);
      }
    }
    this.chosen = this.wanBase;
    console.info('DSH_BASE wan ' + this.wanBase);
    this.scheduleLanProbe();
    return this.chosen;
  }

  /**
   * 立刻重新选一次入口。回前台、换电脑、点「重新连接」时调，
   * 免得用户在同一个 Wi-Fi 下还要等一轮后台探活才换回局域网。
   */
  async poke(): Promise<void> {
    // 配置还没读进来（onPageShow 可能早于 loadCfg）时什么都别定，否则 chosen 会被设成空串
    if (this.wanBase === '') {
      return;
    }
    this.chosen = '';
    this.lanDownUntil = 0;
    this.nextLanProbe = 0;
    if (this.autoLan && !this.forceWan && this.lanBase !== '') {
      try {
        const r = await this.rawGet(this.lanBase + '/api/info', 900, true);
        if (r.code === 200) {
          this.chosen = this.lanBase;
          console.info('DSH_BASE poke lan ' + this.lanBase);
          return;
        }
        console.info('DSH_BASE poke lan http ' + String(r.code));
      } catch (e) {
        console.info('DSH_BASE poke lan failed: ' + (e as Error).message);
      }
    }
    this.chosen = this.wanBase;
    console.info('DSH_BASE poke wan ' + this.wanBase);
  }

  /**
   * 已经用着隧道时，每隔一分钟在后台静默探一次局域网：
   * 人从外面回到家，下一次请求就会自动换回局域网直连，不用手动重连。
   */
  private scheduleLanProbe(): void {
    if (!this.autoLan || this.forceWan || this.lanBase === '') {
      return;
    }
    const now = Date.now();
    if (now < this.nextLanProbe) {
      return;
    }
    this.nextLanProbe = now + 15000;
    this.rawGet(this.lanBase + '/api/info', 800, true).then((r) => {
      if (r.code === 200) {
        this.chosen = this.lanBase;
        this.lanDownUntil = 0;
        console.info('DSH_BASE switch lan ' + this.lanBase);
      } else {
        this.lanDownUntil = Date.now() + 60000;
      }
    }).catch(() => {
      this.lanDownUntil = Date.now() + 60000;
    });
  }

  /**
   * 把方法名映射成 http.RequestMethod。
   * 旧写法只区分 POST 与 GET，把 PATCH 静默降级成 GET，导致重命名必定 404。
   */
  private methodOf(method: string): http.RequestMethod {
    if (method === 'POST') {
      return http.RequestMethod.POST;
    }
    if (method === 'PATCH') {
      return http.RequestMethod.PATCH;
    }
    if (method === 'PUT') {
      return http.RequestMethod.PUT;
    }
    if (method === 'DELETE') {
      return http.RequestMethod.DELETE;
    }
    return http.RequestMethod.GET;
  }

  /**
   * 把服务端返回揉成一句人话。
   * 隧道挂掉时 Cloudflare 会回一整页 HTML（HTTP 530），直接透出去会糊满聊天页，
   * 所以 HTML 一律换成固定说法；JSON 里的 error 字段保留，方便对号入座。
   */
  private friendly(code: number, text: string, path: string): string {
    const body: string = (text ?? '').trim();
    const lower: string = body.toLowerCase();
    const html: boolean = lower.startsWith('<!doctype html') || lower.startsWith('<html') || lower.includes('<html');
    console.info('DSH_API_ERR ' + path + ' code=' + String(code));
    if (code === 401) {
      return '这台电脑不认这个令牌了，去设置里重新配对';
    }
    if (body.startsWith('{')) {
      try {
        const obj: ErrBody = JSON.parse(body) as ErrBody;
        const msg: string = obj.error !== undefined ? obj.error : '';
        if (msg !== '') {
          return (code >= 500 ? '电脑端出错（HTTP ' + String(code) + '）：' : '请求被拒（HTTP ' + String(code) + '）：') + msg;
        }
      } catch (e) {
        // 不是合法 JSON，退回通用说法
      }
    }
    if (code >= 500) {
      return html ? '连不上电脑（隧道 HTTP ' + String(code) + '），稍后自动重试'
        : '电脑端出错（HTTP ' + String(code) + '）';
    }
    const tail: string = html ? '' : body.slice(0, 80);
    return '请求失败（HTTP ' + String(code) + '）' + (tail !== '' ? '：' + tail : '');
  }

  private async once<T>(path: string, method: string, payload?: string): Promise<T> {
    const base = await this.ensureBase();
    const req = http.createHttp();
    // 隧道首包可能是冷路径（Cloudflare 边缘回源 5–20 秒），局域网则是毫秒级，
    // 所以超时按入口分开给：公网给足，局域网保持灵敏。
    const connectMs: number = this.isLan() ? 5000 : 18000;
    try {
      const opts: http.HttpRequestOptions = {
        method: this.methodOf(method),
        header: {
          'Authorization': 'Bearer ' + this.token,
          'Content-Type': 'application/json; charset=utf-8'
        },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: connectMs,
        readTimeout: connectMs + 8000,
        extraData: payload
      };
      const res = await req.request(base + path, opts);
      const code = res.responseCode as number;
      const text = res.result as string;
      console.info('DSH_API ' + method + ' ' + path + ' -> ' + code + ' len=' + (text ? text.length : 0));
      if (code < 200 || code >= 300) {
        throw new Error(this.friendly(code, text, path));
      }
      return JSON.parse(text) as T;
    } finally {
      req.destroy();
    }
  }

  private async call<T>(path: string, method: string, payload?: string): Promise<T> {
    const attempts = 3;
    let last: Error = new Error('unknown');
    for (let i = 1; i <= attempts; i++) {
      try {
        return await this.once<T>(path, method, payload);
      } catch (e) {
        last = e as Error;
        const msg = last.message ?? '';
        console.error('DSH_API_FAIL ' + method + ' ' + path + ' try=' + i + ' :: ' + msg);
        if (msg.startsWith('连不上电脑') || msg.startsWith('电脑端出错')) {
          // 5xx：隧道回源失败很常见，换一个入口再试一次（同一个 Wi-Fi 下就会落到局域网）。
          this.chosen = '';
          this.lanDownUntil = 0;
          if (i < attempts) {
            await this.sleep(500 * i);
            continue;
          }
          break;
        }
        if (msg.startsWith('请求') || msg.startsWith('这台电脑')) {
          break;
        }
        // 网络类失败：重置入口选择，下一轮重新探测（可能已经从 Wi-Fi 切到移动网络）
        this.chosen = '';
        if (i === attempts) {
          break;
        }
        await this.sleep(220 * i);
      }
    }
    throw last;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(() => resolve(), ms));
  }

  /**
   * 告诉电脑「我现在在线」。
   *
   * 手机在前台时每几秒打一次，电脑据此把 ask_user_question 的卡片交给手机；
   * 退到后台时发 online:false，电脑立刻恢复「桌面回答」。
   */
  /** 谁来回答提问：'phone' 手机为主 / 'desktop' 电脑为主。旧插件上会 404。 */
  async answerMode(): Promise<string> {
    const r: AnswerModeResp = await this.call<AnswerModeResp>('/api/answer-mode', 'GET');
    return r.mode !== undefined ? r.mode : 'phone';
  }

  async setAnswerMode(mode: string): Promise<string> {
    const body: AnswerModeBody = { mode: mode };
    const r: AnswerModeResp = await this.call<AnswerModeResp>('/api/answer-mode', 'POST', JSON.stringify(body));
    return r.mode !== undefined ? r.mode : mode;
  }

  async presence(online: boolean, sessionId: string = ''): Promise<void> {
    const q: string = sessionId === '' ? '' : '?sessionId=' + encodeURIComponent(sessionId);
    try {
      await this.call<PresenceResp>('/api/presence' + q, 'POST', JSON.stringify({ online: online } as PresenceBody));
    } catch (e) {
      // 探活失败不该打扰界面：网络抖动、重启都会命中这里。
      console.info('DSH_PRESENCE fail ' + (e as Error).message);
    }
  }
  async info(): Promise<ApiInfo> {
    const r = await this.call<InfoResp>('/api/info', 'GET');
    return { ok: r.ok, version: r.version, host: r.host, port: r.port };
  }

  async sessions(): Promise<SessionRow[]> {
    const r = await this.call<SessionsResp>('/api/sessions', 'GET');
    return r.sessions ?? [];
  }

  /** 会话列表的一行摘要：只读日志尾部，几十毫秒级。 */
  async previews(ids: string[]): Promise<PreviewRow[]> {
    if (ids.length === 0) return [];
    const q = '/api/sessions/previews?ids=' + encodeURIComponent(ids.join(','));
    const r = await this.call<PreviewsResp>(q, 'GET');
    return r.previews ?? [];
  }

  async messages(id: string, limit: number): Promise<MessagesResult> {
    const r = await this.call<MessagesResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/messages?limit=' + limit, 'GET');
    return { total: r.total, messages: r.messages ?? [], stats: r.stats, context: r.context, running: r.running, firstSeq: r.firstSeq, lastTurn: r.lastTurn, queue: r.queue, questions: r.questions };
  }

  /** 只取 seq 大于 since 的新消息；轮询用，避免每次都搬几十 KB。 */
  async messagesSince(id: string, since: number): Promise<MessagesResult> {
    const r = await this.call<MessagesResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/messages?since=' + since, 'GET');
    return { total: r.total, messages: r.messages ?? [], stats: r.stats, context: r.context, running: r.running, firstSeq: r.firstSeq, lastTurn: r.lastTurn, queue: r.queue, questions: r.questions };
  }

  /** 取比 before 更早的一页，用于向上翻历史。 */
  async messagesBefore(id: string, before: number, limit: number = 60): Promise<MessagesResult> {
    const r = await this.call<MessagesResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/messages?before=' + before + '&limit=' + limit, 'GET');
    return { total: r.total, messages: r.messages ?? [], stats: r.stats, context: r.context, running: r.running, firstSeq: r.firstSeq, lastTurn: r.lastTurn, queue: r.queue, questions: r.questions };
  }

  /**
   * mode 只在会话正跑着一轮时才有区别：
   * queue=排到下一轮（不打断），steer=插话（替掉当前轮）。
   * 空闲会话不管传什么都只能 steer，插件侧会自己纠正。
   */
  async send(id: string, text: string, mode: string = ''): Promise<void> {
    const body: SendBody = { text: text };
    if (mode === 'steer' || mode === 'queue') {
      body.mode = mode;
    }
    await this.call<object>('/api/sessions/' + encodeURIComponent(id) + '/send', 'POST',
      JSON.stringify(body));
  }

  /** 从电脑端队列里撤掉一条。 */
  async queueDrop(id: string, itemId: string): Promise<void> {
    await this.call<object>(
      '/api/sessions/' + encodeURIComponent(id) + '/queue/' + encodeURIComponent(itemId) + '/drop',
      'POST', '{}');
  }

  /** 改一条待发送的文字。 */
  /** 重排宿主队列：宿主没有 move，插件侧按目标顺序全删重排 */
  async queueReorder(id: string, ids: string[]): Promise<void> {
    const body: QueueOrderBody = { ids: ids };
    await this.call<QueueOrderResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/queue/reorder', 'POST', JSON.stringify(body));
  }

  async queueEdit(id: string, itemId: string, text: string): Promise<void> {
    await this.call<object>(
      '/api/sessions/' + encodeURIComponent(id) + '/queue/' + encodeURIComponent(itemId) + '/edit',
      'POST', JSON.stringify({ text: text } as QueueTextBody));
  }

  /** 插队：立刻把它送进电脑，抢在当前轮前面。 */
  async queueFire(id: string, itemId: string): Promise<void> {
    await this.call<object>(
      '/api/sessions/' + encodeURIComponent(id) + '/queue/' + encodeURIComponent(itemId) + '/fire',
      'POST', '{}');
  }

  async answerQuestions(id: string, callId: string, answers: AskAnswer[]): Promise<void> {
    await this.call<object>(
      '/api/sessions/' + encodeURIComponent(id) + '/questions/answer',
      'POST', JSON.stringify({ callId: callId, answers: answers } as AnswerBody));
  }

  async models(id: string): Promise<Catalog> {
    const r = await this.call<ModelsResp>('/api/models?sessionId=' + encodeURIComponent(id), 'GET');
    return r.catalog;
  }

  async selectModel(id: string, provider: string, model: string, effort: string): Promise<void> {
    const body: ModelBody = { provider: provider, model: model };
    if (effort !== '') {
      body.reasoningEffort = effort;
    }
    await this.call<object>('/api/sessions/' + encodeURIComponent(id) + '/model', 'POST',
      JSON.stringify(body));
  }
  /** 让正在跑的会话停下；返回服务端是否受理。 */
  async stop(id: string): Promise<boolean> {
    const r = await this.call<StopResp>('/api/sessions/' + encodeURIComponent(id) + '/stop', 'POST',
      '{}');
    return r.accepted === true;
  }

  /** 新建一个空会话；返回新会话 id（失败返回空串）。 */
  async createSession(cwd: string): Promise<string> {
    const body: CreateBody = { cwd: cwd };
    const r = await this.call<CreateResp>('/api/sessions', 'POST', JSON.stringify(body));
    return r.sessionId === undefined ? '' : r.sessionId;
  }

  /** 宿主提供的 Agent 预设目录（instructions/tools 组合）。 */
  async presets(): Promise<PresetsResp> {
    return await this.call<PresetsResp>('/api/presets', 'GET');
  }

  /** 某个会话可以选的权限预设。 */
  async permissions(id: string): Promise<PermsResp> {
    return await this.call<PermsResp>(
      '/api/permissions?sessionId=' + encodeURIComponent(id), 'GET');
  }

  /** 切换预设；返回 'session'（只影响本会话）或 'global'（会话已开过轮，落成默认值）。 */
  async selectPreset(id: string, presetId: string): Promise<string> {
    const body: PresetBody = { presetId: presetId };
    const r = await this.call<PresetResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/preset', 'POST', JSON.stringify(body));
    return r.scope === undefined ? 'session' : r.scope;
  }

  /** 切换权限；返回服务端读回的当前值。 */
  async setPermission(id: string, permission: string): Promise<string> {
    const body: PermBody = { permission: permission };
    const r = await this.call<PermResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/permission', 'POST', JSON.stringify(body));
    return r.current === undefined ? permission : r.current;
  }

  async rename(id: string, title: string): Promise<void> {
    const body: RenameBody = { title: title };
    await this.call<object>('/api/sessions/' + encodeURIComponent(id), 'PATCH',
      JSON.stringify(body));
  }

  /** 归档会话；宿主拒绝时会先停掉在跑的那一轮再归档。 */
  async archive(id: string): Promise<boolean> {
    const r = await this.call<ArchiveResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/archive', 'POST');
    return r.ok === true;
  }

  /** 从归档里取回会话。 */
  async unarchive(id: string): Promise<boolean> {
    const r = await this.call<ArchiveResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/unarchive', 'POST');
    return r.ok === true;
  }

  /** 置顶 / 取消置顶（走宿主 workspaceRegistry）。 */
  async pin(id: string, pinned: boolean): Promise<boolean> {
    const body: PinBody = { pinned: pinned };
    const r = await this.call<PinResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/pin', 'POST', JSON.stringify(body));
    return r.ok === true;
  }

  /** 把选中的图片连同说明发进会话；返回服务端受理的图片数量。 */
  async uploadImages(id: string, text: string, images: ImagePart[], mode: string = ''): Promise<number> {
    const body: ImagesBody = { text: text, images: images };
    if (mode === 'steer' || mode === 'queue') body.mode = mode;
    const r = await this.call<ImagesResp>('/api/sessions/' + encodeURIComponent(id) + '/images', 'POST',
      JSON.stringify(body));
    return r.count === undefined ? 0 : r.count;
  }

  /** 队列里那条消息的第 i 张图的地址（带令牌，可直接给 Image 用）。 */
  queueImageUrl(id: string, itemId: string, index: number, mediaType: string): string {
    const mt: string = mediaType !== '' ? mediaType : 'image/png';
    return this.currentBase() + '/api/sessions/' + encodeURIComponent(id) + '/queue-image?item=' +
      encodeURIComponent(itemId) + '&i=' + String(index) + '&t=' + encodeURIComponent(this.token) +
      '&m=' + encodeURIComponent(mt);
  }

  /**
   * 文字 + 图片 + 文件合成一条消息发出（本轮在跑就进宿主队列）。
   * 分开调 /images 与 /files 会变成两条队列项，用户看到的是「一条图文」被拆成两条。
   */
  async sendOutbox(id: string, text: string, images: ImagePart[], files: FilePart[],
    mode: string = ''): Promise<number> {
    const body: OutboxBody = { text: text, images: images, files: files };
    if (mode === 'steer' || mode === 'queue') body.mode = mode;
    const r = await this.call<OutboxResp>('/api/sessions/' + encodeURIComponent(id) + '/outbox', 'POST',
      JSON.stringify(body));
    return r.parts === undefined ? 0 : r.parts;
  }

  /** 把选中的文件传到电脑上，再把落地路径写进会话；返回服务端受理的文件数量。 */
  async uploadFiles(id: string, text: string, files: FilePart[], mode: string = ''): Promise<number> {
    const body: FilesBody = { text: text, files: files };
    if (mode === 'steer' || mode === 'queue') body.mode = mode;
    const r = await this.call<FilesResp>('/api/sessions/' + encodeURIComponent(id) + '/files', 'POST',
      JSON.stringify(body));
    return r.count === undefined ? 0 : r.count;
  }

  /**
   * 分叉会话：把截至 atSeq（含）的事件前缀复制成一个独立会话。
   * atSeq 省略时由宿主取最近一个已完成轮次的边界。返回新会话的 id。
   */
  async fork(id: string, atSeq: number = -1): Promise<string> {
    const body: ForkBody = {};
    if (atSeq >= 0) body.atSeq = atSeq;
    const r = await this.call<ForkResp>('/api/sessions/' + encodeURIComponent(id) + '/fork', 'POST',
      JSON.stringify(body));
    return r.sessionId === undefined ? '' : r.sessionId;
  }

  /** 电脑上装了哪些插件：按 profile 分组，bundles 里列出的算「已启用」。 */
  async hostPlugins(): Promise<HostPluginGroup[]> {
    const r = await this.call<HostPluginsResp>('/api/host/plugins', 'GET');
    return r.groups === undefined ? [] : r.groups;
  }

  /** 电脑上的定时任务（自动化）。字段已由电脑端归一。 */
  async hostSchedules(): Promise<HostTaskRow[]> {
    const r = await this.call<HostSchedulesResp>('/api/host/schedules', 'GET');
    return r.items === undefined ? [] : r.items;
  }

  /** 会话工作目录下的一层文件。 */
  async fsList(id: string, path: string): Promise<FsListing> {
    const q: string = path === '' ? '' : '?path=' + encodeURIComponent(path);
    const r = await this.call<FsResp>('/api/sessions/' + encodeURIComponent(id) + '/fs' + q, 'GET');
    return {
      root: r.root === undefined ? '' : r.root,
      path: r.path === undefined ? '' : r.path,
      entries: r.entries === undefined ? [] : r.entries,
      more: r.more === true
    };
  }

  /** 文本文件内容（电脑端上限 512 KB，二进制会被拒）。 */
  /** 智能体团队：成员与共享任务板（读会话日志里的 team/* 事件）。 */
  async team(id: string): Promise<TeamResp> {
    const r = await this.call<TeamResp>('/api/sessions/' + encodeURIComponent(id) + '/team', 'GET');
    return r;
  }

  /** 切换当前会话的智能体协作；返回电脑端读回的值。 */
  /** 这个会话当前的目标（goal），没有就是 null。 */
  async goal(id: string): Promise<GoalView | null> {
    const r = await this.call<GoalResp>('/api/sessions/' + encodeURIComponent(id) + '/goal', 'GET');
    return r.goal === undefined ? null : r.goal;
  }

  /** 目标操作：pause / resume / complete / clear / edit。 */
  async goalAction(id: string, action: string, patch: string = ''): Promise<GoalView | null> {
    let payload: string = '{"action":"' + action + '"}';
    if (patch !== '') {
      payload = '{"action":"' + action + '",' + patch + '}';
    }
    const r = await this.call<GoalResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/goal/action', 'POST', payload);
    return r.goal === undefined ? null : r.goal;
  }

  async teamMode(id: string, enabled: boolean): Promise<boolean> {
    const body: TeamModeBody = { enabled: enabled };
    const r = await this.call<TeamModeResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/team/mode', 'POST', JSON.stringify(body));
    return r.enabled === true;
  }

  async fsFile(id: string, path: string): Promise<FsFile> {
    const r = await this.call<FsFileResp>('/api/sessions/' + encodeURIComponent(id) + '/fs/file?path=' +
      encodeURIComponent(path), 'GET');
    return {
      name: r.name === undefined ? '' : r.name,
      size: r.size === undefined ? 0 : r.size,
      text: r.text === undefined ? '' : r.text
    };
  }

  /** 图片文件的直链（带令牌，<Image> 可直接用）。 */
  fsRawUrl(id: string, path: string): string {
    return this.currentBase() + '/api/sessions/' + encodeURIComponent(id) + '/fs/raw?path=' +
      encodeURIComponent(path) + '&t=' + encodeURIComponent(this.token);
  }
}

interface ForkBody {
  atSeq?: number;
}

interface ForkResp {
  ok?: boolean;
  sessionId?: string;
}

interface FilesBody {
  text: string;
  files: FilePart[];
  mode?: string;
}

interface FilesResp {
  ok: boolean;
  count: number;
  bytes: number;
}

interface OutboxBody {
  text: string;
  images: ImagePart[];
  files: FilePart[];
  mode?: string;
}

interface OutboxResp {
  ok: boolean;
  parts: number;
  queued?: boolean;
}

interface ImagesBody {
  text: string;
  images: ImagePart[];
  mode?: string;
}

interface ImagesResp {
  ok: boolean;
  count: number;
  bytes: number;
}

interface StopResp {
  ok: boolean;
  accepted: boolean;
}

interface CreateBody {
  cwd: string;
}

interface CreateResp {
  ok: boolean;
  sessionId?: string;
}

interface RenameBody {
  title: string;
}

interface ModelBody {
  provider: string;
  model: string;
  reasoningEffort?: string;
}

export interface EffortRef {
  id: string;
  name: string;
}

export interface CatalogModel {
  id: string;
  name: string;
  description: string;
  efforts: EffortRef[];
  defaultEffort: string;
}

export interface CatalogGroup {
  id: string;
  name: string;
  models: CatalogModel[];
}

export interface Catalog {
  current: ModelRef | null;
  routable: boolean;
  groups: CatalogGroup[];
}

interface ModelsResp {
  ok: boolean;
  sessionId: string;
  catalog: Catalog;
}

export interface PresetRow {
  id: string;
  name: string;
  description: string;
  isDefault: boolean;
  broken: string;
}

export interface PermRow {
  value: string;
  name: string;
  description: string;
}

export interface PresetsResp {
  ok: boolean;
  presets: PresetRow[];
  current: string;
  unavailable: boolean;
}

export interface PermsResp {
  ok: boolean;
  presets: PermRow[];
  current: string;
  defaultPreset: string;
  unavailable: boolean;
}

interface PresetBody {
  presetId: string;
}

interface PresetResp {
  ok: boolean;
  selected?: string;
  scope?: string;
}

interface PermBody {
  permission: string;
}

interface PermResp {
  ok: boolean;
  preset?: string;
  current?: string;
}

interface ArchiveResp {
  ok: boolean;
  sessionId?: string;
  archived?: boolean;
  cancelledFirst?: boolean;
  via?: string;
}

interface PinBody {
  pinned: boolean;
}

interface PinResp {
  ok: boolean;
  sessionId?: string;
  pinned?: boolean;
  via?: string;
}

interface SendBody {
  text: string;
  mode?: string;
}

export interface HostPluginRow {
  name: string;
  version: string;
  enabled: boolean;
  local: boolean;
}

export interface HostPluginGroup {
  profile: string;
  items: HostPluginRow[];
}

interface HostPluginsResp {
  ok?: boolean;
  groups?: HostPluginGroup[];
}

export interface HostTaskRow {
  id: string;
  title: string;
  kind: string;
  when: string;
  active: boolean;
  sessionId: string;
}

interface HostSchedulesResp {
  ok?: boolean;
  source?: string;
  items?: HostTaskRow[];
}

export interface FsEntry {
  name: string;
  dir: boolean;
  size: number;
  mtime: number;
}

export interface FsListing {
  root: string;
  path: string;
  entries: FsEntry[];
  more: boolean;
  /** 会话没有工作目录时，宿主退回了它自己的当前目录 */
  fallback?: boolean;
}

interface FsResp {
  ok?: boolean;
  root?: string;
  path?: string;
  entries?: FsEntry[];
  more?: boolean;
  fallback?: boolean;
}

export interface TeamMemberRow {
  id: string;
  name: string;
  description: string;
  phase: string;
  error: string;
}

export interface TeamTaskRow {
  id: string;
  revision: number;
  subject: string;
  description: string;
  status: string;
  ownerName: string;
  ownerId: string;
}

export interface TeamResp {
  ok?: boolean;
  sessionId?: string;
  enabled?: boolean;
  sawMode?: boolean;
  members?: TeamMemberRow[];
  tasks?: TeamTaskRow[];
}

interface TeamModeBody {
  enabled: boolean;
}

interface TeamModeResp {
  ok?: boolean;
  enabled?: boolean;
}

export interface FsFile {
  name: string;
  size: number;
  text: string;
}

interface FsFileResp {
  ok?: boolean;
  name?: string;
  size?: number;
  text?: string;
}

interface AnswerModeBody {
  mode: string;
}

interface AnswerModeResp {
  ok?: boolean;
  mode?: string;
}
