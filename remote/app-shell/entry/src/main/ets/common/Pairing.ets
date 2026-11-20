import http from '@ohos.net.http';

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
  version: string;
  port: number;
  qr: string;
  lan?: string[];
  error: string;
  code: string;
  left: number;
}

/** 二维码里装的东西：电脑地址 + 当前 6 位码。 */
export interface PairLink {
  base: string;
  code: string;
}

interface RawResp {
  status: number;
  body: string;
}

interface CodeBody {
  code: string;
}

export class Pairing {
  /** 补协议、去尾斜杠：用户手输 "192.168.1.10:8901" 也能连。 */
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
    const parts = query.split('&');
    for (let i = 0; i < parts.length; i++) {
      const eq = parts[i].indexOf('=');
      if (eq < 0) {
        continue;
      }
      const k = parts[i].substring(0, eq);
      const v = decodeURIComponent(parts[i].substring(eq + 1));
      if (k === 'b') {
        base = v;
      } else if (k === 'c') {
        code = v;
      }
    }
    if (base === '' || code === '') {
      return null;
    }
    return { base: Pairing.normalizeBase(base), code: code };
  }

  private static async req(base: string, path: string, method: string, payload: string): Promise<RawResp> {
    const client = http.createHttp();
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
      return { status: resp.responseCode, body: resp.result as string };
    } finally {
      client.destroy();
    }
  }

  /** 探一台电脑：拿到名字、版本与它对外的局域网地址。 */
  static async info(base: string): Promise<PairInfo> {
    const r = await Pairing.req(Pairing.normalizeBase(base), '/api/pair/info', 'GET', '');
    if (r.status !== 200) {
      throw new Error('这台电脑没有开启手机连接（HTTP ' + r.status + '）');
    }
    const o = JSON.parse(r.body) as PairInfo;
    if (o.ok !== true) {
      throw new Error('返回内容不是手机连接接口');
    }
    return o;
  }

  /** 用 6 位码换令牌。码错会带着剩余次数回来，方便直接显示。 */
  static async claim(base: string, code: string): Promise<PairClaim> {
    const body: CodeBody = { code: code.trim() };
    const r = await Pairing.req(Pairing.normalizeBase(base), '/api/pair/claim', 'POST', JSON.stringify(body));
    let o: PairClaim;
    try {
      o = JSON.parse(r.body) as PairClaim;
    } catch (e) {
      throw new Error('电脑返回了看不懂的内容（HTTP ' + r.status + '）');
    }
    if (r.status === 200 && o.ok === true) {
      return o;
    }
    if (r.status === 401) {
      const left = typeof o.left === 'number' ? o.left : 0;
      throw new Error(left > 0 ? ('配对码不对，还能试 ' + left + ' 次') : '配对码不对');
    }
    if (r.status === 403) {
      throw new Error('电脑上关掉了允许连接，先打开再配对');
    }
    if (r.status === 429) {
      throw new Error('试错太多次，等 5 分钟再试');
    }
    throw new Error('配对失败（HTTP ' + r.status + '）');
  }
}
