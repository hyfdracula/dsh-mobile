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
  archived?: boolean;
  pinned?: boolean;
  agents?: AgentSummary;
  model?: ModelRef;
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

export interface Message {
  role: string;
  text: string;
  time: number;
  seq: number;
  images?: ImageRef[];
}

export interface MessagesResult {
  total: number;
  messages: Message[];
  stats?: SessionStats;
  firstSeq?: number;
  running?: boolean;
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
  running?: boolean;
  firstSeq?: number;
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
  private lanBase: string;
  private wanBase: string;
  private chosen: string = '';
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
    if (this.forceWan) {
      this.chosen = this.wanBase;
      console.info('DSH_BASE wan (forced) ' + this.wanBase);
      return this.chosen;
    }
    if (this.lanBase !== '' && Date.now() >= this.lanDownUntil) {
      try {
        // 探针要带令牌：/health 是免鉴权的，只探它会在换了令牌后误判局域网可用，
        // 随后每个业务请求都 401。所以用 /api/info 探，200 才算这个入口真能用。
        const r = await this.rawGet(this.lanBase + '/api/info', 1500, true);
        if (r.code === 200) {
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
    return this.chosen;
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
        throw new Error('HTTP ' + code + (text ? ' ' + text.slice(0, 120) : ''));
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
        if (msg.startsWith('HTTP ')) {
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
    return { total: r.total, messages: r.messages ?? [], stats: r.stats, running: r.running, firstSeq: r.firstSeq };
  }

  /** 只取 seq 大于 since 的新消息；轮询用，避免每次都搬几十 KB。 */
  async messagesSince(id: string, since: number): Promise<MessagesResult> {
    const r = await this.call<MessagesResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/messages?since=' + since, 'GET');
    return { total: r.total, messages: r.messages ?? [], stats: r.stats, running: r.running, firstSeq: r.firstSeq };
  }

  /** 取比 before 更早的一页，用于向上翻历史。 */
  async messagesBefore(id: string, before: number, limit: number = 60): Promise<MessagesResult> {
    const r = await this.call<MessagesResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/messages?before=' + before + '&limit=' + limit, 'GET');
    return { total: r.total, messages: r.messages ?? [], stats: r.stats, running: r.running, firstSeq: r.firstSeq };
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
  async uploadImages(id: string, text: string, images: ImagePart[]): Promise<number> {
    const body: ImagesBody = { text: text, images: images };
    const r = await this.call<ImagesResp>('/api/sessions/' + encodeURIComponent(id) + '/images', 'POST',
      JSON.stringify(body));
    return r.count === undefined ? 0 : r.count;
  }

  /** 把选中的文件传到电脑上，再把落地路径写进会话；返回服务端受理的文件数量。 */
  async uploadFiles(id: string, text: string, files: FilePart[]): Promise<number> {
    const body: FilesBody = { text: text, files: files };
    const r = await this.call<FilesResp>('/api/sessions/' + encodeURIComponent(id) + '/files', 'POST',
      JSON.stringify(body));
    return r.count === undefined ? 0 : r.count;
  }
}

interface FilesBody {
  text: string;
  files: FilePart[];
}

interface FilesResp {
  ok: boolean;
  count: number;
  bytes: number;
}

interface ImagesBody {
  text: string;
  images: ImagePart[];
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

