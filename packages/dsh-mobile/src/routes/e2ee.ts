/**
 * L6 端到端加密信封（`Noise_IK_25519_ChaChaPoly_SHA256`）与已配对设备管理路由：
 * - `POST /api/e2ee/handshake`：核验设备撤销与公钥绑定，执行 Noise_IK 握手并建立加密会话 `sid`；
 * - `POST /api/e2ee/rpc`：按单会话串行互斥锁解密 RPC 信封、经内部分发器执行并加密返回；
 * - `GET /api/e2ee/devices`、`POST /api/e2ee/devices/revoke`：查看已配对设备与立即撤销/恢复授权。
 */
import { randomBytes } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import {
  decodeBase64Flexible,
  keysEqual,
  NoiseResponder,
  type NoiseCipherState,
} from '../crypto/noise.ts'
import { readJson, send } from '../http-util.ts'
import {
  pairedDevices,
  record,
  resolveE2eeKeypair,
  resolveHostId,
  setDeviceRevoked,
  upsertPairedDevice,
  type PairedDeviceRecord,
} from '../state.ts'

const SESSION_CAP = 32
const SESSION_IDLE_MS = 30 * 60 * 1000
const LAST_SEEN_THROTTLE_MS = 60 * 1000
const MAX_RPC_BODY_BYTES = 24 * 1024 * 1024
const ALLOWED_INNER_METHODS = new Set(['GET', 'HEAD', 'POST', 'PATCH', 'PUT', 'DELETE'])

export interface InternalDispatchRequest {
  method: string
  path: string
  body?: unknown
  idem?: string
  outerReq: IncomingMessage
}

export interface InternalDispatchResult {
  status: number
  body: unknown
}

interface E2eeSessionEntry {
  sid: string
  deviceId: string
  recvCipher: NoiseCipherState
  sendCipher: NoiseCipherState
  updatedAt: number
  lastPersistedSeenAt: number
  chain: Promise<void>
}

export interface E2eeRoutesBundle {
  tryHandle: (req: IncomingMessage, res: ServerResponse, url: URL, path: string, method: string) => Promise<boolean>
  revokeDevice: (deviceId: string, revoked: boolean) => { ok: true; devices: PairedDeviceRecord[] } | { ok: false; error: string }
  dispose: () => void
}

export function createE2eeRoutes(deps: {
  dispatchInternal: (req: InternalDispatchRequest) => Promise<InternalDispatchResult>
  logFile: string
}): E2eeRoutesBundle {
  const sessions = new Map<string, E2eeSessionEntry>()

  const evictSession = (sid: string): void => {
    const existing = sessions.get(sid)
    if (existing !== undefined) {
      sessions.delete(sid)
      existing.recvCipher.destroy()
      existing.sendCipher.destroy()
    }
  }

  const pruneSessions = (now: number): void => {
    for (const [sid, entry] of sessions) {
      if (now - entry.updatedAt > SESSION_IDLE_MS) {
        evictSession(sid)
      }
    }
    while (sessions.size > SESSION_CAP) {
      const oldest = sessions.keys().next().value
      if (oldest === undefined) break
      evictSession(oldest)
    }
  }

  const evictDeviceSessions = (deviceId: string): number => {
    let removed = 0
    for (const [sid, entry] of [...sessions]) {
      if (entry.deviceId === deviceId) {
        evictSession(sid)
        removed += 1
      }
    }
    return removed
  }

  const isDeviceRevoked = (deviceId: string): boolean => {
    const found = pairedDevices().find((d) => d.deviceId === deviceId)
    return found?.revoked === true
  }

  const revokeDevice = (
    deviceId: string,
    revoked: boolean,
  ): { ok: true; devices: PairedDeviceRecord[] } | { ok: false; error: string } => {
    const cleanId = deviceId.trim()
    if (cleanId === '') return { ok: false, error: 'deviceId 不能为空' }
    const updated = setDeviceRevoked(cleanId, revoked)
    if (!updated.ok) return { ok: false, error: '未找到指定设备' }
    if (revoked) {
      evictDeviceSessions(cleanId)
    }
    return { ok: true, devices: updated.devices }
  }

  /** 单会话串行互斥锁：防止并发 RPC 乱序导致 Noise Nonce 失步。 */
  const withSessionMutex = async <T>(entry: E2eeSessionEntry, fn: () => Promise<T>): Promise<T> => {
    let release!: () => void
    const prev = entry.chain
    entry.chain = new Promise<void>((resolve) => {
      release = resolve
    })
    await prev
    try {
      return await fn()
    } finally {
      release()
    }
  }

  const tryHandle = async (
    req: IncomingMessage,
    res: ServerResponse,
    _url: URL,
    path: string,
    method: string,
  ): Promise<boolean> => {
    if (path === '/api/e2ee/handshake' && method === 'POST') {
      const body = await readJson(req, 64 * 1024)
      const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : ''
      const deviceName = typeof body.deviceName === 'string' ? body.deviceName.trim().slice(0, 64) : ''
      const pubKeyStr = typeof body.pubKey === 'string' ? body.pubKey.trim() : ''
      const msg1Str = typeof body.msg1 === 'string' ? body.msg1.trim() : ''

      if (deviceId === '' || deviceId.length > 128) {
        send(res, 400, { error: 'deviceId 不合法' })
        return true
      }

      let pubKeyBuf: Buffer
      let msg1Buf: Buffer
      try {
        pubKeyBuf = decodeBase64Flexible(pubKeyStr)
        msg1Buf = decodeBase64Flexible(msg1Str)
      } catch {
        send(res, 400, { error: 'pubKey 或 msg1 不是有效的 Base64 编码' })
        return true
      }
      if (pubKeyBuf.length !== 32 || msg1Buf.length < 96) {
        send(res, 400, { error: 'pubKey 必须为 32 字节且 msg1 长度合法' })
        return true
      }
      const canonicalPub = pubKeyBuf.toString('base64')

      const existing = pairedDevices().find((d) => d.deviceId === deviceId)
      if (existing !== undefined) {
        if (existing.revoked === true) {
          await record(deps.logFile, `403 E2EE handshake revoked device=${deviceId}`)
          send(res, 403, { error: '此设备已被电脑端撤销授权', code: 'DEVICE_REVOKED' })
          return true
        }
        let existingPubBuf: Buffer | null = null
        try {
          existingPubBuf = decodeBase64Flexible(existing.pubKey)
        } catch {
          existingPubBuf = null
        }
        if (existingPubBuf === null || !keysEqual(existingPubBuf, pubKeyBuf)) {
          await record(deps.logFile, `403 E2EE handshake key-mismatch device=${deviceId}`)
          send(res, 403, {
            error: '设备公钥变更，请重新配对或先在电脑端移除旧设备',
            code: 'DEVICE_KEY_MISMATCH',
          })
          return true
        }
      }

      const hostId = resolveHostId()
      const { priv, pub } = resolveE2eeKeypair()
      const prologue = Buffer.from(`dsh-mobile-e2ee-v1:${hostId}:${deviceId}`, 'utf8')

      let accepted: ReturnType<NoiseResponder['accept']>
      try {
        const responder = new NoiseResponder({
          localStaticPriv: priv,
          localStaticPub: pub,
          prologue,
        })
        accepted = responder.accept(msg1Buf)
      } catch (err) {
        await record(deps.logFile, `401 E2EE handshake failed device=${deviceId}: ${err instanceof Error ? err.message : String(err)}`)
        send(res, 401, { error: '端到端加密握手失败', code: 'E2EE_HANDSHAKE_FAILED' })
        return true
      }

      if (!keysEqual(accepted.remoteStatic, pubKeyBuf)) {
        accepted.recvCipher.destroy()
        accepted.sendCipher.destroy()
        await record(deps.logFile, `403 E2EE handshake static-key-mismatch device=${deviceId}`)
        send(res, 403, {
          error: '设备公钥变更，请重新配对或先在电脑端移除旧设备',
          code: 'DEVICE_KEY_MISMATCH',
        })
        return true
      }

      const now = Date.now()
      upsertPairedDevice({
        deviceId,
        pubKey: canonicalPub,
        name: deviceName !== '' ? deviceName : (existing?.name ?? '未命名设备'),
        createdAt: existing?.createdAt ?? now,
        lastSeenAt: now,
        revoked: false,
      })

      pruneSessions(now)
      while (sessions.size >= SESSION_CAP) {
        const oldest = sessions.keys().next().value
        if (oldest === undefined) break
        evictSession(oldest)
      }

      const sid = randomBytes(18).toString('base64url')
      sessions.set(sid, {
        sid,
        deviceId,
        recvCipher: accepted.recvCipher,
        sendCipher: accepted.sendCipher,
        updatedAt: now,
        lastPersistedSeenAt: now,
        chain: Promise.resolve(),
      })

      await record(deps.logFile, `200 E2EE handshake device=${deviceId}`)
      send(res, 200, {
        ok: true,
        sid,
        hostId,
        msg2: accepted.msg2.toString('base64'),
      })
      return true
    }

    if (path === '/api/e2ee/rpc' && method === 'POST') {
      const body = await readJson(req, MAX_RPC_BODY_BYTES)
      const sid = typeof body.sid === 'string' ? body.sid.trim() : ''
      const ctStr = typeof body.ct === 'string' ? body.ct.trim() : ''
      if (sid === '' || ctStr === '') {
        send(res, 400, { error: 'sid 与 ct 不能为空' })
        return true
      }

      const now = Date.now()
      pruneSessions(now)
      const session = sessions.get(sid)
      if (session === undefined || isDeviceRevoked(session.deviceId)) {
        if (session !== undefined) evictSession(sid)
        send(res, 401, { error: '加密会话已过期', code: 'E2EE_SESSION_EXPIRED' })
        return true
      }

      let ctBuf: Buffer
      try {
        ctBuf = decodeBase64Flexible(ctStr)
      } catch {
        send(res, 400, { error: 'ct 不是有效的 Base64 编码' })
        return true
      }

      await withSessionMutex(session, async () => {
        // 进入互斥锁后再次校验会话有效性与撤销状态。
        if (!sessions.has(sid) || isDeviceRevoked(session.deviceId)) {
          evictSession(sid)
          send(res, 401, { error: '加密会话已过期', code: 'E2EE_SESSION_EXPIRED' })
          return
        }

        let plainBuf: Buffer
        try {
          plainBuf = session.recvCipher.decrypt(ctBuf)
        } catch {
          // fail-closed：一旦出现篡改、重放或失步，立刻作废该加密会话强制重新握手。
          evictSession(sid)
          await record(deps.logFile, `401 E2EE rpc decrypt failed device=${session.deviceId}`)
          send(res, 401, { error: '加密会话校验失败，请重新握手', code: 'E2EE_SESSION_EXPIRED' })
          return
        }

        let inner: Record<string, unknown>
        try {
          const parsed: unknown = JSON.parse(plainBuf.toString('utf8'))
          if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
            throw new Error('not an object')
          }
          inner = parsed as Record<string, unknown>
        } catch {
          const errCipher = session.sendCipher.encrypt(
            Buffer.from(JSON.stringify({ status: 400, body: { error: '内部 RPC 负载必须是 JSON 对象' } }), 'utf8'),
          )
          send(res, 200, { ok: true, ct: errCipher.toString('base64') })
          return
        }

        const innerMethod = typeof inner.method === 'string' ? inner.method.trim().toUpperCase() : 'GET'
        const innerPath = typeof inner.path === 'string' ? inner.path.trim() : ''
        const innerIdem = typeof inner.idem === 'string' ? inner.idem.trim() : undefined

        let result: InternalDispatchResult
        if (!ALLOWED_INNER_METHODS.has(innerMethod) || !innerPath.startsWith('/')) {
          result = { status: 400, body: { error: '内部请求 method 或 path 不合法' } }
        } else if (innerPath === '/api/e2ee' || innerPath.startsWith('/api/e2ee/')) {
          result = { status: 403, body: { error: '禁止递归调用 /api/e2ee/* 接口' } }
        } else {
          try {
            result = await deps.dispatchInternal({
              method: innerMethod,
              path: innerPath,
              body: inner.body,
              idem: innerIdem,
              outerReq: req,
            })
          } catch (err) {
            result = {
              status: 500,
              body: { error: err instanceof Error ? err.message : String(err) },
            }
          }
        }

        const doneNow = Date.now()
        session.updatedAt = doneNow
        // 维护 LRU 顺序
        sessions.delete(sid)
        sessions.set(sid, session)
        if (doneNow - session.lastPersistedSeenAt >= LAST_SEEN_THROTTLE_MS) {
          session.lastPersistedSeenAt = doneNow
          const currentDev = pairedDevices().find((d) => d.deviceId === session.deviceId)
          if (currentDev !== undefined && currentDev.revoked !== true) {
            upsertPairedDevice({ ...currentDev, lastSeenAt: doneNow })
          }
        }

        const outPlain = Buffer.from(JSON.stringify({ status: result.status, body: result.body }), 'utf8')
        const outCt = session.sendCipher.encrypt(outPlain)
        send(res, 200, { ok: true, ct: outCt.toString('base64') })
      })
      return true
    }

    if (path === '/api/e2ee/devices' && method === 'GET') {
      send(res, 200, {
        ok: true,
        hostId: resolveHostId(),
        e2eePub: resolveE2eeKeypair().pub,
        devices: pairedDevices(),
      })
      return true
    }

    if (path === '/api/e2ee/devices/revoke' && method === 'POST') {
      const body = await readJson(req)
      const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : ''
      if (deviceId === '' || typeof body.revoked !== 'boolean') {
        send(res, 400, { error: 'deviceId 必须非空且 revoked 必须为布尔值' })
        return true
      }
      const resRevoke = revokeDevice(deviceId, body.revoked)
      if (!resRevoke.ok) {
        send(res, 404, { error: resRevoke.error })
        return true
      }
      await record(deps.logFile, `200 E2EE device revoke device=${deviceId} revoked=${String(body.revoked)}`)
      send(res, 200, {
        ok: true,
        deviceId,
        revoked: body.revoked,
        devices: resRevoke.devices,
      })
      return true
    }

    return false
  }

  const dispose = (): void => {
    for (const sid of [...sessions.keys()]) {
      evictSession(sid)
    }
  }

  return { tryHandle, revokeDevice, dispose }
}
