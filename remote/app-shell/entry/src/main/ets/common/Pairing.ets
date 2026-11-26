import http from '@ohos.net.http';
import { LinkLog } from './LinkLog';

/**
 * 配对客户端：直连一台还没配置过的电脑，用 6 位码换令牌。
 *
 * 和 Api 分开是有原因的：配对时手机还不知道该信任谁，端上是随机的，
 * 令牌也还没拿到，所以这里既不做局域网/公网择优，也不做重试与缓存。
 */
export interface PairInfo {
  ok: boolean;
  name: string;
  version: string;
  host: string;
  hostId?: string;
  e2eePub?: string;
  e2ee?: boolean;
  port: number;
  lan: string[];
  publicUrl: string;
  needCode: boolean;
}

export interface PairClaim {
  ok: boolean;
  token: string;
  base: string;
  host: string;
  hostId?: string;
  e2eePub?: string;
  e2ee?: boolean;
  version: string;
  port: number;
  qr: string;
  lan?: string[];
  /** 这次真正连上的地址，配对成功后用它保存。 */
  usedBase: string;
  error: string;
  code: string;
  left: number;
}

/** 二维码里装的东西：电脑地址 + 当前 6 位码。 */
export interface PairLink {
  base: string;
  code: string;
  /** 同一个二维码里附带的备选地址：首个连不上时依次再试。 */
  alts: string[];
}

interface RawResp {
  status: number;
  body: string;
}

/**
 * 对面**答了**（码错 / 被拒 / 限流）时抛这个，和「根本没连上」区分开。
 * 只有没连上才值得换下一个地址；答过的服务器再拿同一个一次性码去撞别处没有意义。
 */
export class PairError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

interface CodeBody {
  code: string;
}

export class Pairing {
  /** 补协议、去尾斜杠：用户手输 "192.168.1.3:8901" 也能连。 */
  static normalizeBase(input: string): string {
    let b = input.trim();
    if (b === '') {
      return '';
    }
    if (b.indexOf('://') < 0) {
      b = 'http://' + b;
    }
    while (b.length > 0 && b.charAt(b.length - 1) === '/') {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  /** 解析 dshmobile://pair?b=<地址>&c=<码>。 */
  static parseLink(text: string): PairLink | null {
    const s = text.trim();
    if (s.indexOf('dshmobile://pair') !== 0) {
      return null;
    }
    const q = s.indexOf('?');
    if (q < 0) {
      return null;
    }
    const query = s.substring(q + 1);
    let base = '';
    let code = '';
    const alts: string[] = [];
    const parts = query.split('&');
    for (let i = 0; i < parts.length; i++) {
      const eq = parts[i].indexOf('=');
      if (eq < 0) {
        continue;
      }
      const k = parts[i].substring(0, eq);
      let v = parts[i].substring(eq + 1);
      try {
        v = decodeURIComponent(v);
      } catch (e) {
        continue;
      }
      if (k === 'b') {
        base = v;
      } else if (k === 'c') {
        code = v;
      } else if (k === 'a' && v !== '') {
        alts.push(Pairing.normalizeBase(v));
      }
    }
    if (base === '' || code === '') {
      return null;
    }
    return { base: Pairing.normalizeBase(base), code: code, alts: alts };
  }

  private static async req(base: string, path: string, method: string, payload: string): Promise<RawResp> {
    const client = http.createHttp();
    const t0: number = Date.now();
    try {
      const opts: http.HttpRequestOptions = {
        method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: { 'Content-Type': 'application/json' },
        connectTimeout: 3000,
        readTimeout: 6000,
        expectDataType: http.HttpDataType.STRING
      };
      if (method === 'POST') {
        opts.extraData = payload;
      }
      const resp = await client.request(base + path, opts);
      const ms: number = Date.now() - t0;
      LinkLog.record('PAIR', method + ' ' + base + path + ' -> ' + String(resp.responseCode) + ' (' + String(ms) + 'ms)');
      return { status: resp.responseCode, body: resp.result as string };
    } catch (e) {
      const ms: number = Date.now() - t0;
      LinkLog.record('PAIR', method + ' ' + base + path + ' FAIL (' + String(ms) + 'ms) ' + ((e as Error).message ?? ''));
      throw new Error((e as Error).message ?? 'network error');
    } finally {
      client.destroy();
    }
  }

  /** 探一台电脑：拿到名字、版本与它对外的局域网地址。 */
  static async info(base: string): Promise<PairInfo> {
    const r = await Pairing.req(Pairing.normalizeBase(base), '/api/pair/info', 'GET', '');
    if (r.status < 200 || r.status >= 300) {
      throw new Error('这台电脑没有开启手机连接（HTTP ' + r.status + '）');
    }
    let o: PairInfo;
    try {
      o = JSON.parse(r.body) as PairInfo;
    } catch (e) {
      throw new Error('连接地址返回的不是有效响应（HTTP ' + r.status + '），请核对端口或隧道');
    }
    if (o.ok !== true) {
      throw new Error('返回内容不是手机连接接口');
    }
    return o;
  }

  /**
   * 用 6 位码换令牌，按顺序试多个地址。
   *
   * 二维码里除了首个地址，还可能带几个备选（其它网卡、公网隧道）。只有当某个
   * 地址**真的连不上**时才换下一个；一旦对面答了（码错 / 被拒 / 限流），
   * 就说明路是通的，立刻把它的答复抛出去，别拿同一个码去撞别处的服务器。
   */
  static async claimAny(bases: readonly string[], code: string,
    onStage?: (stage: number, detail: string) => void): Promise<PairClaim> {
    const tried: string[] = [];
    let last: string = '';
    for (let i = 0; i < bases.length; i++) {
      const one = Pairing.normalizeBase(bases[i]);
      if (one === '' || tried.indexOf(one) >= 0) {
        continue;
      }
      tried.push(one);
      if (onStage !== undefined) {
        onStage(0, '正在尝试 ' + one + ' (' + String(tried.length) + '/' + String(bases.length) + ')');
      }
      try {
        const res: PairClaim = await Pairing.claim(one, code);
        if (onStage !== undefined) {
          onStage(1, '已验证配对码 · ' + one);
        }
        return res;
      } catch (e) {
        const msg = (e as Error).message;
        if (e instanceof PairError) {
          // 对面答了：说明路是通的，把这个答复原样交给界面，别去撞下一个地址
          console.info('DSH_PAIR reject ' + one + ' status=' + e.status);
          throw new PairError(e.status, e.message);
        }
        last = msg;
        console.info('DSH_PAIR unreachable ' + one + ' :: ' + msg);
      }
    }
    throw new Error(
      '连不上这台电脑（试了 ' + tried.length + ' 个地址，最后一个：' + last + '）。' +
        '检查：①手机和电脑连的是同一个 Wi-Fi；②电脑防火墙放行 DSH（端口 8901）；' +
        '③或者让电脑打开公网访问，重新扫一次。'
    );
  }

  /** 用 6 位码换令牌。码错会带着剩余次数回来，方便直接显示。 */
  static async claim(base: string, code: string): Promise<PairClaim> {
    const body: CodeBody = { code: code.trim() };
    const r = await Pairing.req(Pairing.normalizeBase(base), '/api/pair/claim', 'POST', JSON.stringify(body));
    let o: PairClaim;
    try {
      o = JSON.parse(r.body) as PairClaim;
    } catch (e) {
      throw new PairError(r.status, '无法解析电脑返回（HTTP ' + r.status + '），隧道或端口可能未就绪');
    }
    if (r.status >= 200 && r.status < 300 && o.ok === true) {
      o.usedBase = Pairing.normalizeBase(base);
      return o;
    }
    if (r.status === 401) {
      const left = typeof o.left === 'number' ? o.left : 0;
      throw new PairError(r.status, left > 0 ? ('配对码不对，还能试 ' + left + ' 次') : '配对码不对');
    }
    if (r.status === 403) {
      throw new PairError(r.status, '电脑上关掉了允许连接，先打开再配对');
    }
    if (r.status === 429) {
      throw new PairError(r.status, '试错太多次，等 5 分钟再试');
    }
    throw new PairError(r.status, '配对失败（HTTP ' + r.status + '）');
  }
}
