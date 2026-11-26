import preferences from '@ohos.data.preferences';
import { AppCtx } from '../AppCtx';
import { LinkLog } from '../LinkLog';
import { Secret } from '../Secret';
import {
  fromBase64Flexible,
  randomBytes,
  toBase64,
  toBase64Url,
  utf8Decode,
  utf8Encode,
  uuidV7
} from './Bytes';
import { NoiseIkInitiator } from './NoiseIk';
import { x25519Public } from './X25519';

const PRIV_ALIAS: string = 'dsh_mobile_e2ee_priv';
const DEVICE_ID_ALIAS: string = 'dsh_mobile_device_id';
const FALLBACK_STORE: string = 'dsh_mobile_e2ee';

export interface E2eeRawHttpResp {
  code: number;
  text: string;
}

export interface E2eeHttpCaller {
  rawPostJson: (path: string, payload: string, extraReadMs?: number) => Promise<E2eeRawHttpResp>;
}

interface HandshakeReqBody {
  deviceId: string;
  deviceName: string;
  pubKey: string;
  msg1: string;
}

interface HandshakeRespBody {
  ok?: boolean;
  sid?: string;
  hostId?: string;
  msg2?: string;
  error?: string;
  code?: string;
}

interface RpcEnvelopeReq {
  sid: string;
  ct: string;
}

interface RpcEnvelopeResp {
  ok?: boolean;
  ct?: string;
  error?: string;
  code?: string;
}

interface RpcInnerReq {
  method: string;
  path: string;
  body?: string;
  idem?: string;
}

interface RpcInnerResp {
  status: number;
  body: Object | null;
}

export interface E2eeRpcResult {
  fallback: boolean;
  status: number;
  text: string;
}

interface DeviceIdentity {
  deviceId: string;
  priv: Uint8Array;
  pub: Uint8Array;
}

let cachedIdentity: DeviceIdentity | null = null;

function fallbackPref(): preferences.Preferences | null {
  try {
    const ctx = AppCtx.ability();
    const opts: preferences.Options = { name: FALLBACK_STORE };
    return preferences.getPreferencesSync(ctx, opts);
  } catch (e) {
    return null;
  }
}

function readPersistent(alias: string): string {
  const sec: string = Secret.loadKey(alias);
  if (sec !== '') {
    return sec;
  }
  const pref = fallbackPref();
  if (pref !== null) {
    try {
      const v: string = pref.getSync(alias, '') as string;
      if (v !== '') {
        if (Secret.saveKey(alias, v)) {
          pref.putSync(alias, '');
          pref.flushSync();
        }
        return v;
      }
    } catch (e) {
    }
  }
  return '';
}

function writePersistent(alias: string, val: string): void {
  if (Secret.saveKey(alias, val)) {
    return;
  }
  const pref = fallbackPref();
  if (pref !== null) {
    try {
      pref.putSync(alias, val);
      pref.flushSync();
    } catch (e) {
    }
  }
}

function loadDeviceIdentity(): DeviceIdentity {
  if (cachedIdentity !== null) {
    return cachedIdentity;
  }
  let deviceId: string = readPersistent(DEVICE_ID_ALIAS);
  if (deviceId === '') {
    deviceId = uuidV7();
    writePersistent(DEVICE_ID_ALIAS, deviceId);
  }
  let priv: Uint8Array | null = null;
  const rawPriv: string = readPersistent(PRIV_ALIAS);
  if (rawPriv !== '') {
    try {
      const dec: Uint8Array = fromBase64Flexible(rawPriv);
      if (dec.length === 32) {
        priv = dec;
      }
    } catch (e) {
      priv = null;
    }
  }
  if (priv === null) {
    priv = randomBytes(32);
    writePersistent(PRIV_ALIAS, toBase64Url(priv));
  }
  const pub: Uint8Array = x25519Public(priv);
  cachedIdentity = { deviceId: deviceId, priv: priv, pub: pub };
  return cachedIdentity;
}

const MAX_E2EE_LANES: number = 3;

/** 单条 Noise_IK 加密通道：通道内部严格串行以保持 Nonce 同步，通道间可并行消除公网队头阻塞。 */
class E2eeLane {
  sid: string = '';
  noise: NoiseIkInitiator | null = null;
  queueLen: number = 0;
  private chain: Promise<void> = Promise.resolve();

  isActive(): boolean {
    return this.sid !== '' && this.noise !== null && this.noise.isComplete();
  }

  reset(): void {
    if (this.noise !== null) {
      this.noise.destroy();
      this.noise = null;
    }
    this.sid = '';
  }

  async withMutex<T>(fn: () => Promise<T>): Promise<T> {
    this.queueLen++;
    let release: () => void = (): void => {};
    const prev: Promise<void> = this.chain;
    this.chain = new Promise<void>((resolve: () => void) => {
      release = resolve;
    });
    await prev;
    try {
      return await fn();
    } finally {
      this.queueLen--;
      release();
    }
  }
}

/**
 * 端到端加密会话管理器（L6）：
 * - 持久化本机 32 字节 X25519 密钥对与随机 deviceId（Asset Store + 降级偏好）；
 * - 维护最多 3 条按需扩展的 `Noise_IK_25519_ChaChaPoly_SHA256` 并发加密通道，消除高延迟公网下的单队列队头阻塞；
 * - 每条通道内部通过串行 Promise 互斥锁保证发包/收包 Nonce 严格单调递增不乱序；
 * - 遇到 401 `E2EE_SESSION_EXPIRED` 自动重握手并重试；旧宿主返回 404 时无缝回退直连。
 */
export class E2eeClient {
  private hostId: string = '';
  private hostPubB64: string = '';
  private lanes: E2eeLane[] = [new E2eeLane()];
  private unsupported: boolean = false;
  private epoch: number = 0;

  static deviceId(): string {
    return loadDeviceIdentity().deviceId;
  }

  static publicKeyBase64(): string {
    return toBase64(loadDeviceIdentity().pub);
  }

  configure(hostId: string, hostPubB64: string): void {
    const cleanHid: string = hostId.trim();
    const cleanPub: string = hostPubB64.trim();
    if (cleanHid === this.hostId && cleanPub === this.hostPubB64) {
      return;
    }
    this.hostId = cleanHid;
    this.hostPubB64 = cleanPub;
    this.reset(true);
  }

  configuredHostId(): string {
    return this.hostId;
  }

  configuredPub(): string {
    return this.hostPubB64;
  }

  isConfigured(): boolean {
    return this.hostId !== '' && this.hostPubB64 !== '';
  }

  isActive(): boolean {
    for (let i = 0; i < this.lanes.length; i++) {
      if (this.lanes[i].isActive()) {
        return true;
      }
    }
    return false;
  }

  isUnsupported(): boolean {
    return this.unsupported;
  }

  reset(clearUnsupported: boolean = false): void {
    this.epoch++;
    for (let i = 0; i < this.lanes.length; i++) {
      this.lanes[i].reset();
    }
    this.lanes = [new E2eeLane()];
    if (clearUnsupported) {
      this.unsupported = false;
    }
  }

  private pickLane(allowExpand: boolean): E2eeLane {
    // 1. 优先选一条已经握手好且空闲的通道（0 额外握手开销）
    for (let i = 0; i < this.lanes.length; i++) {
      const l: E2eeLane = this.lanes[i];
      if (l.queueLen === 0 && l.isActive()) {
        return l;
      }
    }
    // 2. 其次选一条尚未初始化且空闲的通道
    for (let i = 0; i < this.lanes.length; i++) {
      const l: E2eeLane = this.lanes[i];
      if (l.queueLen === 0) {
        return l;
      }
    }
    // 3. 常规业务并发时按需扩容（最多 3 条并发通道）；后台心跳不主动扩容
    if (allowExpand && this.lanes.length < MAX_E2EE_LANES) {
      const extra: E2eeLane = new E2eeLane();
      this.lanes.push(extra);
      return extra;
    }
    // 4. 全部忙碌则选排队最短的通道
    let best: E2eeLane = this.lanes[0];
    for (let i = 1; i < this.lanes.length; i++) {
      if (this.lanes[i].queueLen < best.queueLen) {
        best = this.lanes[i];
      }
    }
    return best;
  }

  private async handshakeLaneUnlocked(
    lane: E2eeLane,
    caller: E2eeHttpCaller,
    hostId: string,
    hostPubB64: string
  ): Promise<boolean> {
    const cleanHid: string = hostId.trim();
    const cleanPub: string = hostPubB64.trim();
    if (cleanHid === '' || cleanPub === '') {
      return false;
    }
    const myEpoch: number = this.epoch;
    this.hostId = cleanHid;
    this.hostPubB64 = cleanPub;
    lane.reset();

    let remotePub: Uint8Array;
    try {
      remotePub = fromBase64Flexible(cleanPub);
    } catch (e) {
      LinkLog.record('E2EE', 'invalid host e2eePub encoding');
      this.unsupported = true;
      return false;
    }
    if (remotePub.length !== 32) {
      LinkLog.record('E2EE', 'invalid host e2eePub len=' + String(remotePub.length));
      this.unsupported = true;
      return false;
    }

    const id: DeviceIdentity = loadDeviceIdentity();
    const prologue: Uint8Array = utf8Encode('dsh-mobile-e2ee-v1:' + cleanHid + ':' + id.deviceId);
    const initiator: NoiseIkInitiator = new NoiseIkInitiator(
      id.priv,
      id.pub,
      remotePub,
      prologue,
      (n: number): Uint8Array => randomBytes(n)
    );
    const msg1: Uint8Array = initiator.writeHandshake(new Uint8Array(0));

    const body: HandshakeReqBody = {
      deviceId: id.deviceId,
      deviceName: 'HarmonyOS',
      pubKey: toBase64(id.pub),
      msg1: toBase64(msg1)
    };
    const bodyText: string = JSON.stringify(body);
    let resp: E2eeRawHttpResp;
    try {
      resp = await caller.rawPostJson('/api/e2ee/handshake', bodyText, 8000);
    } catch (e) {
      if (this.epoch !== myEpoch) {
        initiator.destroy();
        lane.reset();
        return false;
      }
      // 隧道偶发首次 TLS 握手抖动，握手接口完全幂等，自动补试一次
      LinkLog.record('E2EE', 'handshake net err -> retry once');
      resp = await caller.rawPostJson('/api/e2ee/handshake', bodyText, 10000);
    }
    if (this.epoch !== myEpoch) {
      initiator.destroy();
      lane.reset();
      return false;
    }
    if (resp.code === 404) {
      initiator.destroy();
      this.unsupported = true;
      LinkLog.record('E2EE', 'host returned 404 on handshake -> fallback direct');
      return false;
    }
    let parsed: HandshakeRespBody | null = null;
    try {
      parsed = JSON.parse(resp.text) as HandshakeRespBody;
    } catch (e) {
      parsed = null;
    }
    if (resp.code === 403) {
      initiator.destroy();
      const errCode: string = parsed !== null && parsed.code !== undefined ? parsed.code : '';
      const errText: string = parsed !== null && parsed.error !== undefined ? parsed.error : '设备未获加密授权';
      if (errCode === 'DEVICE_REVOKED' || errCode === 'DEVICE_KEY_MISMATCH') {
        LinkLog.record('E2EE', 'handshake rejected code=' + errCode);
        throw new Error('这台电脑拒绝了此设备：' + errText);
      }
      throw new Error(errText);
    }
    if (resp.code < 200 || resp.code >= 300 || parsed === null || parsed.ok !== true ||
      parsed.sid === undefined || parsed.sid === '' || parsed.msg2 === undefined || parsed.msg2 === '') {
      initiator.destroy();
      LinkLog.record('E2EE', 'handshake failed HTTP ' + String(resp.code));
      return false;
    }

    try {
      const msg2Bytes: Uint8Array = fromBase64Flexible(parsed.msg2);
      initiator.readHandshake(msg2Bytes);
    } catch (e) {
      initiator.destroy();
      LinkLog.record('E2EE', 'handshake msg2 verify failed: ' + ((e as Error).message ?? ''));
      return false;
    }

    if (this.epoch !== myEpoch) {
      initiator.destroy();
      lane.reset();
      return false;
    }
    lane.sid = parsed.sid;
    lane.noise = initiator;
    this.unsupported = false;
    LinkLog.record('E2EE', 'handshake ok host=' + cleanHid.slice(0, 12));
    return true;
  }

  /** 对外握手入口（加锁防并发重复握手）。 */
  async handshake(caller: E2eeHttpCaller, hostId: string, hostPubB64: string): Promise<boolean> {
    const lane: E2eeLane = this.lanes[0];
    return await lane.withMutex<boolean>(async (): Promise<boolean> => {
      return await this.handshakeLaneUnlocked(lane, caller, hostId, hostPubB64);
    });
  }

  /** 加密一条内部 RPC 明文负载。调用前应确保已完成握手。 */
  encryptRpc(innerJson: string, lane?: E2eeLane): string {
    const target: E2eeLane = lane !== undefined ? lane : this.lanes[0];
    if (target.noise === null || !target.noise.isComplete()) {
      throw new Error('E2EE session not established');
    }
    const ct: Uint8Array = target.noise.encrypt(utf8Encode(innerJson));
    return toBase64(ct);
  }

  /** 解密一条服务端返回的加密 RPC 负载。 */
  decryptRpc(ctB64: string, lane?: E2eeLane): string {
    const target: E2eeLane = lane !== undefined ? lane : this.lanes[0];
    if (target.noise === null || !target.noise.isComplete()) {
      throw new Error('E2EE session not established');
    }
    const plain: Uint8Array = target.noise.decrypt(fromBase64Flexible(ctB64));
    return utf8Decode(plain);
  }

  /**
   * 通过 `/api/e2ee/rpc` 发送并解密一次常规 API 请求：
   * - 按需分配最多 3 条并发加密通道，单通道内串行保序；
   * - 若通道尚未握手先自动握手；
   * - 若服务端返回 401 `E2EE_SESSION_EXPIRED` 自动重握手重试一次；
   * - 若旧宿主不支持（404）返回 `{ fallback: true }` 供传输层无缝退回直连。
   */
  async callRpc(
    caller: E2eeHttpCaller,
    path: string,
    method: string,
    payload?: string,
    idem?: string,
    extraReadMs: number = 8000
  ): Promise<E2eeRpcResult> {
    const isBackground: boolean = path === '/api/presence';
    const lane: E2eeLane = this.pickLane(!isBackground);
    const myEpoch: number = this.epoch;
    const upperMethod: string = method.toUpperCase();
    const isIdempotent: boolean = upperMethod === 'GET' || upperMethod === 'HEAD' ||
      upperMethod === 'OPTIONS' || (idem !== undefined && idem !== '');
    return await lane.withMutex<E2eeRpcResult>(async (): Promise<E2eeRpcResult> => {
      if (this.epoch !== myEpoch) {
        throw new Error('连接已切换');
      }
      if (!this.isConfigured() || this.unsupported) {
        return { fallback: true, status: 0, text: '' };
      }

      for (let attempt = 0; attempt < 2; attempt++) {
        if (this.epoch !== myEpoch) {
          throw new Error('连接已切换');
        }
        if (!lane.isActive()) {
          const ok: boolean = await this.handshakeLaneUnlocked(lane, caller, this.hostId, this.hostPubB64);
          if (this.epoch !== myEpoch) {
            throw new Error('连接已切换');
          }
          if (!ok) {
            return { fallback: true, status: 0, text: '' };
          }
        }

        const innerReq: RpcInnerReq = { method: method, path: path };
        if (payload !== undefined) {
          innerReq.body = payload;
        }
        if (idem !== undefined && idem !== '') {
          innerReq.idem = idem;
        }

        let ctB64: string = '';
        try {
          ctB64 = this.encryptRpc(JSON.stringify(innerReq), lane);
        } catch (e) {
          lane.reset();
          if (attempt === 0) {
            continue;
          }
          return { fallback: true, status: 0, text: '' };
        }

        const envReq: RpcEnvelopeReq = { sid: lane.sid, ct: ctB64 };
        let resp: E2eeRawHttpResp;
        try {
          resp = await caller.rawPostJson('/api/e2ee/rpc', JSON.stringify(envReq), extraReadMs);
        } catch (e) {
          lane.reset();
          if (this.epoch !== myEpoch) {
            throw new Error('连接已切换');
          }
          throw new Error((e as Error).message ?? 'network error');
        }
        if (this.epoch !== myEpoch) {
          lane.reset();
          throw new Error('连接已切换');
        }

        if (resp.code === 404) {
          this.reset(false);
          this.unsupported = true;
          LinkLog.record('E2EE', 'rpc 404 -> fallback direct');
          return { fallback: true, status: 0, text: '' };
        }

        if (resp.code === 401) {
          let errObj: RpcEnvelopeResp | null = null;
          try {
            errObj = JSON.parse(resp.text) as RpcEnvelopeResp;
          } catch (e) {
            errObj = null;
          }
          if (errObj !== null && errObj.code === 'E2EE_SESSION_EXPIRED' && attempt === 0) {
            LinkLog.record('E2EE', 'session expired -> re-handshake');
            lane.reset();
            continue;
          }
          lane.reset();
          return { fallback: false, status: 401, text: resp.text };
        }

        if (resp.code < 200 || resp.code >= 300) {
          lane.reset();
          return { fallback: false, status: resp.code, text: resp.text };
        }

        let envResp: RpcEnvelopeResp;
        try {
          envResp = JSON.parse(resp.text) as RpcEnvelopeResp;
        } catch (e) {
          lane.reset();
          throw new Error('加密信封响应格式异常');
        }
        if (envResp.ct === undefined || envResp.ct === '') {
          lane.reset();
          throw new Error('加密信封缺少密文负载');
        }

        let plainText: string = '';
        try {
          plainText = this.decryptRpc(envResp.ct, lane);
        } catch (e) {
          lane.reset();
          LinkLog.record('E2EE', 'rpc decrypt failed -> reset lane');
          if (attempt === 0 && isIdempotent) {
            continue;
          }
          throw new Error('端到端加密响应校验失败');
        }

        let innerResp: RpcInnerResp;
        try {
          innerResp = JSON.parse(plainText) as RpcInnerResp;
        } catch (e) {
          throw new Error('端到端加密内层负载格式异常');
        }
        const status: number = typeof innerResp.status === 'number' ? innerResp.status : 200;
        let bodyText: string = '';
        if (innerResp.body === null || innerResp.body === undefined) {
          bodyText = '{}';
        } else if (typeof innerResp.body === 'string') {
          bodyText = innerResp.body;
        } else {
          bodyText = JSON.stringify(innerResp.body);
        }
        return { fallback: false, status: status, text: bodyText };
      }
      return { fallback: true, status: 0, text: '' };
    });
  }
}
