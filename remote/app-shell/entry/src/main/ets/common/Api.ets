import http from '@ohos.net.http';
import { classifyError, friendlyError, httpMethodOf, newIdemKey, sleep } from './ApiUtil';
import { ImagePart } from './Images';
import { FilePart } from './Files';

import { SessionRow, TokenUsage, SessionStats, ImageRef, GoalView, GoalResp, TurnInfo, Message, ContextUsage, QueueTextBody, QueueImage, QueuedItem, AskOption, AskQuestion, PendingAsk, AskAnswer, AnswerBody, AskState, TurnErr, MessagesResult, ModelRef, AgentRef, AgentSummary, ApiInfo, SessionsResp, PreviewRow, PreviewsResp, MessagesResp, PresenceBody, PresenceResp, InfoResp, RawResult, QueueOrderBody, QueueOrderResp, ErrBody, FsWriteBody, FsDeleteBody, RawSignBody, RawSignResp, SignBody, SignItem, SignResp, ForkBody, ForkResp, FilesBody, FilesResp, OutboxBody, OutboxResp, ImagesBody, ImagesResp, StopResp, CreateBody, CreateResp, RenameBody, ModelBody, EffortRef, CatalogModel, CatalogGroup, Catalog, ModelsResp, PresetRow, PermRow, PresetsResp, PermsResp, PresetBody, PresetResp, PermBody, PermResp, ArchiveResp, PinBody, PinResp, SendBody, HostPluginRow, HostPluginGroup, HostPluginsResp, HostTaskRow, HostSchedulesResp, HostTaskActionBody, HostPluginToggleBody, HostPluginToggleResp, FsEntry, FsListing, FsResp, TeamMemberRow, TeamTaskRow, TeamResp, TeamModeBody, TeamModeResp, FsFile, FsFileResp, AnswerModeBody, AnswerModeResp } from './ApiTypes';
export { SessionRow, TokenUsage, SessionStats, ImageRef, GoalView, TurnInfo, Message, ContextUsage, QueueTextBody, QueueImage, QueuedItem, AskOption, AskQuestion, PendingAsk, AskAnswer, AnswerBody, AskState, TurnErr, MessagesResult, ModelRef, AgentRef, AgentSummary, ApiInfo, PreviewRow, EffortRef, CatalogModel, CatalogGroup, Catalog, PresetRow, PermRow, PresetsResp, PermsResp, HostPluginRow, HostPluginGroup, HostTaskRow, FsEntry, FsListing, TeamMemberRow, TeamTaskRow, TeamResp, FsFile } from './ApiTypes';

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
  /** 最近几次请求失败：反馈页「复制诊断信息」带上它，复现问题不用再让用户翻日志。 */
  private static errRing: string[] = [];

  static noteError(msg: string): void {
    const t: Date = new Date();
    const hh: string = (t.getHours() < 10 ? '0' : '') + t.getHours();
    const mm: string = (t.getMinutes() < 10 ? '0' : '') + t.getMinutes();
    Api.errRing.push(hh + ':' + mm + ' ' + msg);
    while (Api.errRing.length > 8) {
      Api.errRing.shift();
    }
  }

  static recentErrors(): string[] {
    return Api.errRing.slice();
  }

  /** 一条逻辑消息的幂等键：同一次发送的重试复用同一个键，宿主只提交一次。 */
  static newIdemKey(): string {
    return newIdemKey();
  }

  /**
   * 错误分类：UI 与重试策略共用一处判断，不要再各自 startsWith 猜。
   * net=断网/超时，http=电脑端返回错误，auth=令牌不对，parse=返回不是 JSON，
   * nobase=还没配对，other=其余。
   */
  static kind(msg: string): string {
    return classifyError(msg);
  }

  token: string;
  /** true 时跳过局域网探测，强制走隧道入口。 */
  forceWan: boolean = false;
  /** 仅局域网：探不到也不回退隧道（「自动 / 仅局域网 / 仅公网」里的中间档）。 */
  lanOnly: boolean = false;
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
  /**
   * 这台电脑可能的局域网地址。配对时只知道一个，电脑换了 IP、或者有多个网卡时
   * 那一个就不通了；每次拿到 /api/info 都把它自报的 address 合进来，逐个试。
   */
  private lanCands: string[] = [];

  constructor(wanBase: string, token: string, lanBase: string = '') {
    this.wanBase = wanBase.replace(/\/+$/, '');
    this.lanBase = lanBase.replace(/\/+$/, '');
    this.token = token;
  }

  /** 当前实际使用的入口，供界面展示。 */
  currentBase(): string {
    return this.chosen !== '' ? this.chosen : this.wanBase;
  }

  /** 图片短签名缓存：id → "e=...&sig=..."，以及过期时刻（秒）。 */
  private attSig: Map<string, string> = new Map<string, string>();
  private attExp: Map<string, number> = new Map<string, number>();

  /**
   * 向宿主换一批图片短签名（5 分钟有效）。
   * 失败不抛：退回旧的 ?t= 直链，图片照样能显示。
   */
  async signAttachments(ids: string[]): Promise<void> {
    const need: string[] = [];
    const nowSec: number = Math.floor(Date.now() / 1000);
    for (let i = 0; i < ids.length && need.length < 64; i++) {
      const id: string = ids[i];
      // 过期（或 60 秒内到期）的也要重新换签，否则去掉 ?t= 回退后图片会在 5 分钟后变空白。
      const exp: number = this.attExp.get(id) ?? 0;
      if (!this.attSig.has(id) || exp <= nowSec + 60) {
        need.push(id);
      }
    }
    if (need.length === 0) {
      return;
    }
    try {
      const r = await this.call<SignResp>('/api/attachments/sign', 'POST',
        JSON.stringify({ ids: need } as SignBody));
      const items: SignItem[] = r.items === undefined ? [] : r.items;
      for (let i = 0; i < items.length; i++) {
        this.attSig.set(items[i].id, 'e=' + items[i].e + '&sig=' + items[i].sig);
        const e: number = Number(items[i].e);
        this.attExp.set(items[i].id, Number.isFinite(e) ? e : 0);
      }
    } catch (e) {
      console.info('DSH_ATT_SIGN skipped :: ' + (e as Error).message);
    }
  }

  /**
   * 一张图片的直链。
   * @param img - 消息里带的图片摘要
   * @returns 优先短签名，拿不到就退回带令牌的直链，<Image> 直接可用
   */
  attachmentUrl(img: ImageRef): string {
    const mt: string = img.mediaType !== '' ? img.mediaType : 'image/png';
    const sig: string | undefined = this.attSig.get(img.id);
    // 过期前 30 秒就当它失效，让下一次 load 重新换签。
    // 没有签名就返回空串，调用方不渲染图片：不再把长期令牌塞回 URL（协议 v2 起）。
    if (sig !== undefined && (this.attExp.get(img.id) ?? 0) > Math.floor(Date.now() / 1000) + 30) {
      return this.currentBase() + '/api/attachments/' + img.id + '?' + sig + '&m=' + encodeURIComponent(mt);
    }
    return '';
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

  setLanOnly(v: boolean): void {
    this.lanOnly = v;
    this.chosen = '';
  }

  isLan(): boolean {
    // 候选地址可能有多个（多网卡 / 电脑换过 IP），从第二个候选连上时 chosen 不等于 lanBase，
    // 旧写法会把它当成公网入口，连接超时被拉到 18 秒。这里只区分「是不是隧道」。
    if (this.chosen === '') {
      return false;
    }
    if (this.chosen !== this.wanBase) {
      return true;
    }
    // 没有公网隧道时 wanBase 本身就是局域网地址（配对只给出内网 IP），
    // 那时 chosen === wanBase 也仍然是直连，不能算成隧道，否则超时按 18 秒算。
    return Api.looksLan(this.wanBase);
  }

  /** 地址看着像内网直连（10./192.168./172.16-31.、回环，或没有点的主机名）。 */
  private static looksLan(base: string): boolean {
    if (base === '') {
      return false;
    }
    const noScheme: string = base.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, '');
    const cut: number = noScheme.indexOf('/');
    const hostPort: string = cut >= 0 ? noScheme.substring(0, cut) : noScheme;
    const colon: number = hostPort.indexOf(':');
    const host: string = colon >= 0 ? hostPort.substring(0, colon) : hostPort;
    if (host === '') {
      return false;
    }
    if (host === 'localhost') {
      return true;
    }
    if (/^\d+\.\d+\.\d+\.\d+$/.test(host)) {
      if (host.startsWith('10.') || host.startsWith('192.168.') || host.startsWith('127.')) {
        return true;
      }
      const m: RegExpMatchArray | null = host.match(/^172\.(\d+)\./);
      if (m !== null) {
        const n: number = Number.parseInt(m[1], 10);
        return n >= 16 && n <= 31;
      }
      return false;
    }
    return host.indexOf('.') < 0;
  }

  /** 当前这台电脑已知的局域网候选地址，供设置页展示与排查。 */
  lanCandidates(): string[] {
    const out: string[] = [];
    if (this.lanBase !== '') {
      out.push(this.lanBase);
    }
    for (let i = 0; i < this.lanCands.length; i++) {
      if (out.indexOf(this.lanCands[i]) < 0) {
        out.push(this.lanCands[i]);
      }
    }
    return out;
  }

  /** 正在走的入口是不是隧道（界面用来显示「局域网直连 / 公网隧道」）。 */
  onWan(): boolean {
    if (this.chosen === '') {
      return true;
    }
    return !this.isLan();
  }

  /**
   * 就地换地址与令牌。
   * 子组件持有的都是同一个 Api 引用，非装饰成员不会跟着父组件重建刷新，
   * 所以配对成功后必须改这个对象本身，而不是在 Index 里 new 一个新的。
   * @param lanBase - 已配对电脑自己报的局域网地址；留空表示不再拿旧地址试探，
   *   否则换一台电脑后会把新令牌先发给原来那个 IP 上的设备。
   */
  rebase(wanBase: string, token: string, lanBase: string = '', lanList: string[] = []): void {
    this.wanBase = wanBase.replace(/\/+$/, '');
    this.lanBase = lanBase.replace(/\/+$/, '');
    this.lanCands = [];
    if (this.lanBase !== '') {
      this.lanCands.push(this.lanBase);
    }
    // 旧候选一起带过来：只留一个地址的话，电脑换了 IP 就再也没机会试新的了。
    for (let i = 0; i < lanList.length; i++) {
      const one: string = lanList[i].replace(/\/+$/, '');
      if (one !== '' && this.lanCands.indexOf(one) < 0) {
        this.lanCands.push(one);
      }
    }
    this.token = token;
    this.chosen = '';
    this.lanDownUntil = 0;
    // 换电脑/换令牌后旧签名全部作废：它们是用上一台电脑的令牌签的。
    this.attSig.clear();
    this.attExp.clear();
    this.rawSig.clear();
    this.rawExp.clear();
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

  /** 把 /api/info 自报的地址合进候选（只取 IPv4，跳过回环） */
  private seedLan(addresses: string[] | undefined, port: number): void {
    if (addresses === undefined || addresses.length === 0 || port <= 0) {
      return;
    }
    for (let i = 0; i < addresses.length; i++) {
      const a: string = addresses[i];
      // 跳过 IPv6（这里只按 IPv4 拼地址，IPv6 需要方括号且家中多半走不通）
      if (a.indexOf(':') >= 0 || a === '127.0.0.1' || a === '') {
        continue;
      }
      const base: string = 'http://' + a + ':' + String(port);
      if (this.lanCands.indexOf(base) < 0) {
        this.lanCands.push(base);
      }
    }
    // 配对时记下的那个排最前：它通常是这台电脑真正在用的网卡
    if (this.lanBase !== '') {
      const at: number = this.lanCands.indexOf(this.lanBase);
      if (at > 0) {
        this.lanCands.splice(at, 1);
        this.lanCands.unshift(this.lanBase);
      }
    }
  }

  /**
   * 挨个试候选地址，返回第一个能用的；都不通返回空串。
   * 用 /api/info 探（带令牌）：/health 免鉴权，换了令牌时会误判可用。
   */
  private async probeLan(timeoutMs: number): Promise<string> {
    const list: string[] = this.lanCandidates();
    if (list.length === 0) {
      return '';
    }
    // 并发探，但第一个命中就立刻返回：串行时第一个候选（常常是电脑换 IP 前的旧地址）
    // 要等满超时；而等全部落地又会因为某个候选超时白等到超时，用户已经在走隧道了。
    let settle: (hit: string) => void = (hit: string): void => {
      // 占位，真正的 resolver 在 Promise 构造里赋值
    };
    const firstHit: Promise<string> = new Promise<string>((resolve: (hit: string) => void): void => {
      settle = resolve;
    });
    let left: number = list.length;
    let done: boolean = false;
    const finish = (hit: string): void => {
      if (!done) {
        done = true;
        settle(hit);
      }
    };
    const leave = (): void => {
      left--;
      if (left === 0) {
        finish('');
      }
    };
    for (let i = 0; i < list.length; i++) {
      const one: string = list[i];
      this.rawGet(one + '/api/info', timeoutMs, true)
        .then((r: RawResult): void => {
          if (r.code === 200 || r.code === 401 || r.code === 403) {
            finish(one);
          }
          leave();
        })
        .catch((): void => {
          leave();
        });
    }
    const hit: string = await firstHit;
    if (hit !== '') {
      this.lanBase = hit;
      this.lanDownUntil = 0;
      const at: number = this.lanCands.indexOf(hit);
      if (at > 0) {
        this.lanCands.splice(at, 1);
        this.lanCands.unshift(hit);
      }
      console.info('DSH_BASE lan ' + hit);
      return hit;
    }
    console.info('DSH_BASE lan miss all n=' + String(list.length));
    return '';
  }

  /**
   * 手动重新探测局域网一次（设置页的「重新探测」用）。
   * 与 poke 的区别：无视冷却、无限等待前把 wan 先记住，探完返回结果供界面展示。
   * @returns 命中的局域网地址，空串表示这次没探到
   */
  async probeNow(): Promise<string> {
    if (this.wanBase === '' || this.forceWan || !this.autoLan) {
      return '';
    }
    const hit: string = await this.probeLan(2000);
    this.chosen = hit !== '' ? hit : this.wanBase;
    if (hit === '') {
      this.scheduleLanProbe();
    }
    return hit;
  }

  /** 选一次入口：局域网探得通就走局域网，否则走隧道。 */
  private async ensureBase(): Promise<string> {
    if (this.chosen !== '') {
      return this.chosen;
    }
    if (this.lanOnly) {
      if (Date.now() >= this.lanDownUntil) {
        const hit: string = await this.probeLan(1500);
        if (hit !== '') {
          this.chosen = hit;
          console.info('DSH_BASE lan-only ' + hit);
          return this.chosen;
        }
        this.lanDownUntil = Date.now() + 15000;
      }
      // 只走局域网：宁可失败也不回退隧道；没有候选地址时给出可读错误。
      this.chosen = this.lanBase !== '' ? this.lanBase : (this.lanCands.length > 0 ? this.lanCands[0] : '');
      if (this.chosen === '') {
        throw new Error('现在是「仅局域网」模式，但这台电脑没有可用的局域网地址；到「连接」里切回自动，或先在同一 Wi-Fi 下配对');
      }
      this.scheduleLanProbe();
      return this.chosen;
    }
    if (this.forceWan || !this.autoLan) {
      this.chosen = this.wanBase;
      console.info('DSH_BASE wan (forced) ' + this.wanBase);
      return this.chosen;
    }
    if (Date.now() >= this.lanDownUntil) {
      // 探针要带令牌：/health 是免鉴权的，只探它会在换了令牌后误判局域网可用，
      // 随后每个业务请求都 401。所以用 /api/info 探，200 才算这个入口真能用。
      const hit: string = await this.probeLan(1500);
      if (hit !== '') {
        this.chosen = hit;
        return this.chosen;
      }
      this.lanDownUntil = Date.now() + 60000;
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
    if (this.lanOnly) {
      const hit: string = await this.probeLan(2000);
      this.chosen = hit !== '' ? hit : (this.lanBase !== '' ? this.lanBase : (this.lanCands.length > 0 ? this.lanCands[0] : ''));
      this.scheduleLanProbe();
      console.info('DSH_BASE poke lan-only ' + (this.chosen !== '' ? this.chosen : '-'));
      return;
    }
    if (this.autoLan && !this.forceWan) {
      const hit: string = await this.probeLan(2000);
      if (hit !== '') {
        this.chosen = hit;
        console.info('DSH_BASE poke lan ' + hit);
        return;
      }
    }
    this.chosen = this.wanBase;
    console.info('DSH_BASE poke wan ' + this.wanBase);
    // 没探到也要留一条后台重探的路：否则 chosen 非空，ensureBase 直接返回，
    // 这一次前台就再也不会试局域网（用户切回 WiFi 也不会自愈）。
    this.scheduleLanProbe();
  }

  /**
   * 已经用着隧道时，每隔一分钟在后台静默探一次局域网：
   * 人从外面回到家，下一次请求就会自动换回局域网直连，不用手动重连。
   */
  private scheduleLanProbe(): void {
    if (!this.autoLan || this.forceWan) {
      return;
    }
    const now = Date.now();
    if (now < this.nextLanProbe) {
      return;
    }
    this.nextLanProbe = now + 15000;
    this.probeLan(1500).then((hit: string) => {
      if (hit !== '') {
        this.chosen = hit;
        this.lanDownUntil = 0;
        console.info('DSH_BASE switch lan ' + hit);
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
    return httpMethodOf(method);
  }

  /**
   * 把服务端返回揉成一句人话。
   * 隧道挂掉时 Cloudflare 会回一整页 HTML（HTTP 530），直接透出去会糊满聊天页，
   * 所以 HTML 一律换成固定说法；JSON 里的 error 字段保留，方便对号入座。
   */
  private friendly(code: number, text: string, path: string): string {
    return friendlyError(code, text, path);
  }

  private async once<T>(path: string, method: string, payload?: string, idem?: string): Promise<T> {
    // 首帧时页面可能先于 Index.loadCfg 发起请求：等一小会儿让地址就位，
    // 否则会拿空 base 拼出非法 URL，再被当成网络错误重试三次。
    for (let i = 0; i < 15 && this.wanBase === ''; i++) {
      await this.sleep(100);
    }
    if (this.wanBase === '') {
      throw new Error('还没连上电脑：先在「连接」里配对或填写地址');
    }
    const base = await this.ensureBase();
    const req = http.createHttp();
    // 隧道首包可能是冷路径（Cloudflare 边缘回源 5–20 秒），局域网则是毫秒级，
    // 所以超时按入口分开给：公网给足，局域网保持灵敏。
    // 局域网要么毫秒级答，要么根本不在了：等 2.2 秒还没连上就当作「Wi-Fi 掉了」，
    // 别用 5 秒把这个判断拖到用户明显感觉到卡。隧道仍然给足 18 秒（冷回源很慢）。
    const connectMs: number = this.isLan() ? 2200 : 18000;
    try {
      const header: Record<string, string> = {
        'Authorization': 'Bearer ' + this.token,
        'Content-Type': 'application/json; charset=utf-8'
      };
      if (idem !== undefined && idem !== '') {
        header['Idempotency-Key'] = idem;
      }
      const opts: http.HttpRequestOptions = {
        method: this.methodOf(method),
        header: header,
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
      let parsed: T;
      try {
        parsed = JSON.parse(text) as T;
      } catch (e) {
        // 200 但返回的不是 JSON：多半是隧道边缘页 / 劫持页。不要把它当断网重试三次。
        throw new Error('响应格式不对（HTTP ' + String(code) + '）：可能被网络劫持或隧道返回了错误页');
      }
      return parsed;
    } finally {
      req.destroy();
    }
  }

  private async call<T>(path: string, method: string, payload?: string, idem?: string): Promise<T> {
    // 读请求总是可重试；写请求目前仍只尝试一次。
    // 客户端已经会带 Idempotency-Key（宿主 v2 按 key 去重），但旧宿主会忽略这个头，
    // 所以自动重试要等宿主升级后再打开，否则老版本上会重复发送。
    const attempts = method === 'GET' ? 3 : 1;
    let last: Error = new Error('unknown');
    for (let i = 1; i <= attempts; i++) {
      try {
        return await this.once<T>(path, method, payload, idem);
      } catch (e) {
        last = e as Error;
        const msg = last.message ?? '';
        console.error('DSH_API_FAIL ' + method + ' ' + path + ' try=' + i + ' :: ' + msg);
        Api.noteError(method + ' ' + path + ' :: ' + msg);
        if (msg.startsWith('连不上电脑') || msg.startsWith('电脑端出错')) {
          // 5xx：隧道回源失败很常见，换一个入口再试一次（同一个 Wi-Fi 下就会落到局域网）。
          this.chosen = '';
          this.lanDownUntil = 0;
          if (i < attempts) {
            // 指数退避 + 一点抖动：隧道抖动时错开重试，别三下都撞在同一秒。
            await this.sleep(450 * i * i + Math.floor(Math.random() * 120));
            continue;
          }
          break;
        }
        if (msg.startsWith('请求') || msg.startsWith('这台电脑') || msg.startsWith('响应格式') || msg.startsWith('还没连上')) {
          break;
        }
        // 网络类失败：如果刚才走的是局域网，那基本就是离开了 Wi-Fi。直接降到公网入口，
        // 并把局域网冷却一段时间——否则下一轮 ensureBase 又要白探 1.5 秒才回落，
        // 用户在外面要看着「转圈」等好几秒。
        if (this.lanOnly) {
          // 仅局域网模式不允许降级：清掉入口，下一轮仍只探局域网。
          this.chosen = '';
          this.lanDownUntil = 0;
        } else if (this.isLan()) {
          this.lanDownUntil = Date.now() + 45000;
          this.chosen = this.wanBase;
          console.info('DSH_BASE demote lan -> wan after ' + msg);
        } else {
          // 走隧道也失败了：重置入口，下一轮重新选（可能刚好走进 Wi-Fi）
          this.chosen = '';
        }
        if (i === attempts) {
          break;
        }
        await this.sleep(i === 1 ? 80 : 220 * i);
      }
    }
    throw last;
  }

  private sleep(ms: number): Promise<void> {
    return sleep(ms);
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
    // 电脑自报的地址比配对时记的那一个更全：换了 IP / 多网卡时靠它兜底
    this.seedLan(r.addresses, r.port);
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
    return { total: r.total, messages: r.messages ?? [], stats: r.stats, context: r.context, running: r.running, firstSeq: r.firstSeq, lastTurn: r.lastTurn, lastErr: r.lastErr, queue: r.queue, questions: r.questions };
  }

  /** 只取 seq 大于 since 的新消息；轮询用，避免每次都搬几十 KB。 */
  async messagesSince(id: string, since: number): Promise<MessagesResult> {
    const r = await this.call<MessagesResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/messages?since=' + since, 'GET');
    return { total: r.total, messages: r.messages ?? [], stats: r.stats, context: r.context, running: r.running, firstSeq: r.firstSeq, lastTurn: r.lastTurn, lastErr: r.lastErr, queue: r.queue, questions: r.questions };
  }

  /** 取比 before 更早的一页，用于向上翻历史。 */
  async messagesBefore(id: string, before: number, limit: number = 60): Promise<MessagesResult> {
    const r = await this.call<MessagesResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/messages?before=' + before + '&limit=' + limit, 'GET');
    return { total: r.total, messages: r.messages ?? [], stats: r.stats, context: r.context, running: r.running, firstSeq: r.firstSeq, lastTurn: r.lastTurn, lastErr: r.lastErr, queue: r.queue, questions: r.questions };
  }

  /**
   * mode 只在会话正跑着一轮时才有区别：
   * queue=排到下一轮（不打断），steer=插话（替掉当前轮）。
   * 空闲会话不管传什么都只能 steer，插件侧会自己纠正。
   */
  async send(id: string, text: string, mode: string = '', idem: string = ''): Promise<void> {
    const body: SendBody = { text: text };
    if (mode === 'steer' || mode === 'queue') {
      body.mode = mode;
    }
    await this.call<object>('/api/sessions/' + encodeURIComponent(id) + '/send', 'POST',
      JSON.stringify(body), idem);
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
    mode: string = '', idem: string = ''): Promise<number> {
    const body: OutboxBody = { text: text, images: images, files: files };
    if (mode === 'steer' || mode === 'queue') body.mode = mode;
    const r = await this.call<OutboxResp>('/api/sessions/' + encodeURIComponent(id) + '/outbox', 'POST',
      JSON.stringify(body), idem);
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

  /**
   * 对一条自动化任务做动作：
   * pause 暂停、resume 恢复、run 立即执行、delete 删除。
   * 电脑端不支持时抛错（HTTP 501 会带原因），调用方把消息显示出来即可。
   */
  async scheduleAction(id: string, action: string): Promise<void> {
    const body: HostTaskActionBody = { action: action };
    await this.call<object>(
      '/api/host/schedules/' + encodeURIComponent(id) + '/action', 'POST', JSON.stringify(body));
  }

  /**
   * 开关某个 profile 里的插件，电脑端会写回 package.json 的 dsh.profile.bundles。
   * 返回 true 表示清单真的改了（需要重启宿主才生效），false 表示本来就是那个状态。
   */
  async pluginToggle(profile: string, name: string, enabled: boolean): Promise<boolean> {
    const body: HostPluginToggleBody = { profile: profile, name: name, enabled: enabled };
    const r = await this.call<HostPluginToggleResp>('/api/host/plugins/toggle', 'POST', JSON.stringify(body));
    return r.changed === true;
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

  /** 工作区图片的短签名缓存：`sid|path` → `e=..&sig=..`，以及过期时刻（秒）。 */
  private rawSig: Map<string, string> = new Map<string, string>();
  private rawExp: Map<string, number> = new Map<string, number>();

  /** 给一张工作区图片换 5 分钟签名；失败不抛，调用方退回带令牌的直链。 */
  async signFsRaw(id: string, path: string): Promise<void> {
    const key: string = id + '|' + path;
    const nowSec: number = Math.floor(Date.now() / 1000);
    if (this.rawSig.has(key) && (this.rawExp.get(key) ?? 0) > nowSec + 60) {
      return;
    }
    try {
      const r = await this.call<RawSignResp>(
        '/api/sessions/' + encodeURIComponent(id) + '/fs/sign', 'POST',
        JSON.stringify({ path: path } as RawSignBody));
      if (r.sig !== undefined && r.e !== undefined) {
        this.rawSig.set(key, 'e=' + r.e + '&sig=' + r.sig);
        const e: number = Number(r.e);
        this.rawExp.set(key, Number.isFinite(e) ? e : 0);
      }
    } catch (e) {
      console.info('DSH_RAW_SIGN skipped :: ' + (e as Error).message);
    }
  }

  /** 图片文件的直链：优先短签名，拿不到退回旧 ?t=。 */
  fsRawUrl(id: string, path: string): string {
    const sig: string | undefined = this.rawSig.get(id + '|' + path);
    if (sig !== undefined && (this.rawExp.get(id + '|' + path) ?? 0) > Math.floor(Date.now() / 1000) + 30) {
      return this.currentBase() + '/api/sessions/' + encodeURIComponent(id) + '/fs/raw?path=' +
        encodeURIComponent(path) + '&' + sig;
    }
    // 与附件一致：拿不到签名就不给直链，避免把长期令牌写进 URL。
    return '';
  }

  /** 任意文件的下载直链：不带令牌，调用方用 Authorization 请求头（Saver 已支持）。 */
  fsDownloadUrl(id: string, path: string): string {
    return this.currentBase() + '/api/sessions/' + encodeURIComponent(id) + '/fs/download?path=' +
      encodeURIComponent(path);
  }

  /** 给 Saver 用的 bearer 值；只用于下载请求头，不进 URL。 */
  bearer(): string {
    return 'Bearer ' + this.token;
  }

  /** 重命名工作区里的文件/目录（同目录内换名）。 */
  async fsRename(id: string, path: string, to: string): Promise<void> {
    await this.call<object>('/api/sessions/' + encodeURIComponent(id) + '/fs/rename', 'POST',
      JSON.stringify({ path: path, to: to } as FsWriteBody));
  }

  /** 删除工作区里的文件，或空目录。 */
  async fsDelete(id: string, path: string): Promise<void> {
    await this.call<object>('/api/sessions/' + encodeURIComponent(id) + '/fs/delete', 'POST',
      JSON.stringify({ path: path } as FsDeleteBody));
  }
}
