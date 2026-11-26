/**
 * L5 一键免密打开电脑端完整网页控制台代理：
 * - `POST /api/web-console/grant`（Bearer 鉴权）：签发 60 秒一次性随机票据（内存上限 16）；
 * - `GET /api/web-console/enter?g=<grant>`（免 Bearer）：原子消费一次性票据并种下 30 分钟 HttpOnly Cookie，302 跳转至 `/api/web-console/proxy/`；
 * - `ALL /api/web-console/proxy` 与 `/api/web-console/proxy/*`（校验 `dsh_wc` Cookie）：透明反向代理到本地 DSH Web GUI 并自动注入本地认证 Cookie；
 * - `handleUpgrade`：支持 `/api/web-console/proxy/*` 的 WebSocket 双向隧道转发。
 */
import { randomBytes } from 'node:crypto'
import { request as httpRequest, type IncomingMessage, type ServerResponse } from 'node:http'
import { request as httpsRequest } from 'node:https'
import { connect as netConnect, type Socket } from 'node:net'
import { connect as tlsConnect } from 'node:tls'
import type { Duplex } from 'node:stream'
import { send } from '../http-util.ts'
import { record } from '../state.ts'

export interface DshWebBrowserAuth {
  authenticatedUrl(origin: string): string
  authorizeIndex(
    request: { headers: Record<string, string>; url: string; method: string },
    response: { writeHead(status: number, headers?: Readonly<Record<string, string | string[]>>): void; end(): void },
  ): boolean
  requestRejection?(request: { headers: Record<string, string> }): number | undefined
}

export interface DshWebRuntime {
  origin: URL
  auth: DshWebBrowserAuth | null
}

const CORDIS_ORIGINAL = Symbol.for('cordis.original')
const GRANT_TTL_MS = 60_000
const GRANT_CAP = 16
const SESSION_TTL_MS = 30 * 60 * 1000
const SESSION_CAP = 32
const PROXY_PREFIX = '/api/web-console/proxy'

function getOptionalService(ctx: any, name: string): any {
  if (!ctx || typeof ctx.get !== 'function') return null
  try {
    const val = ctx.get(name, false)
    if (val !== undefined && val !== null) return val
  } catch {
    // fall through
  }
  try {
    const val = ctx.get(name)
    return val === undefined ? null : val
  } catch {
    return null
  }
}

function unwrapOriginal(obj: unknown): unknown {
  if (obj === null || typeof obj !== 'object') return obj
  try {
    return Reflect.get(obj, CORDIS_ORIGINAL) ?? obj
  } catch {
    return obj
  }
}

function extractBrowserAuth(candidate: any): DshWebBrowserAuth | null {
  if (candidate === null || candidate === undefined || typeof candidate !== 'object') return null
  const targets = [candidate, candidate.auth, candidate.browserAuth]
  for (const t of targets) {
    if (
      t !== null
      && t !== undefined
      && typeof t === 'object'
      && typeof t.authenticatedUrl === 'function'
      && typeof t.authorizeIndex === 'function'
    ) {
      return t as DshWebBrowserAuth
    }
  }
  return null
}

/** 解析本地 DSH Web GUI 上游地址与认证实例。 */
export function resolveDshWebRuntime(ctx: any): DshWebRuntime | null {
  const webServer = getOptionalService(ctx, 'webServer')
  if (webServer === null || typeof webServer.getOrigin !== 'function') return null
  let rawOrigin: unknown
  try {
    rawOrigin = webServer.getOrigin()
  } catch {
    return null
  }
  if (rawOrigin === null || rawOrigin === undefined || String(rawOrigin).trim() === '') return null
  let origin: URL
  try {
    origin = rawOrigin instanceof URL ? new URL(rawOrigin.href) : new URL(String(rawOrigin))
  } catch {
    return null
  }
  if (origin.protocol !== 'http:' && origin.protocol !== 'https:') return null

  const connection = getOptionalService(ctx, 'connection')
  const auth = extractBrowserAuth(connection) ?? extractBrowserAuth(webServer)
  return { origin, auth }
}

function exchangeLocalCookie(runtime: DshWebRuntime): string {
  const { origin, auth } = runtime
  if (auth === null) return ''
  const bootstrap = new URL(auth.authenticatedUrl(origin.href))
  let cookie = ''
  auth.authorizeIndex(
    { method: 'GET', url: `/${bootstrap.search}`, headers: { host: origin.host } },
    {
      writeHead(status, headers) {
        if (status >= 200 && status < 400 && headers !== undefined) {
          const raw = headers['set-cookie'] ?? headers['Set-Cookie']
          const first = Array.isArray(raw) ? raw[0] : raw
          if (typeof first === 'string' && first.length > 0) {
            cookie = first.split(';')[0] ?? ''
          }
        }
      },
      end() {},
    },
  )
  if (cookie === '') {
    throw new Error('无法换取本地 DSH 网页控制台认证 Cookie')
  }
  if (typeof auth.requestRejection === 'function') {
    const rejected = auth.requestRejection({ headers: { host: origin.host, cookie } })
    if (rejected !== undefined) {
      throw new Error(`本地 DSH 网页控制台认证被拒绝 (${String(rejected)})`)
    }
  }
  return cookie
}

function parseCookies(cookieHeader: string | undefined): Record<string, string> {
  if (typeof cookieHeader !== 'string' || cookieHeader === '') return {}
  const out: Record<string, string> = {}
  for (const seg of cookieHeader.split(';')) {
    const eq = seg.indexOf('=')
    if (eq <= 0) continue
    const k = seg.slice(0, eq).trim()
    const v = seg.slice(eq + 1).trim()
    if (k !== '') out[k] = v
  }
  return out
}

export interface WebConsoleRoutesBundle {
  isReady: () => boolean
  isBypassPath: (path: string, method: string) => boolean
  tryHandle: (req: IncomingMessage, res: ServerResponse, url: URL, path: string, method: string) => Promise<boolean>
  handleUpgrade: (req: IncomingMessage, socket: Duplex, head: Buffer) => boolean
  dispose: () => void
}

export function createWebConsoleRoutes(deps: {
  ctx: any
  logFile: string
}): WebConsoleRoutesBundle {
  const grants = new Map<string, { expiresAt: number }>()
  const sessions = new Map<string, { expiresAt: number }>()
  const activeSockets = new Set<Duplex>()

  let cachedAuth: { originHref: string; authRef: unknown; cookie: string } | null = null

  const pruneGrants = (now: number): void => {
    for (const [k, v] of grants) {
      if (v.expiresAt <= now) grants.delete(k)
    }
    while (grants.size > GRANT_CAP) {
      const oldest = grants.keys().next().value
      if (oldest === undefined) break
      grants.delete(oldest)
    }
  }

  const pruneSessions = (now: number): void => {
    for (const [k, v] of sessions) {
      if (v.expiresAt <= now) sessions.delete(k)
    }
    while (sessions.size > SESSION_CAP) {
      const oldest = sessions.keys().next().value
      if (oldest === undefined) break
      sessions.delete(oldest)
    }
  }

  const hasValidSessionCookie = (req: IncomingMessage): boolean => {
    const now = Date.now()
    pruneSessions(now)
    const cookies = parseCookies(req.headers.cookie)
    const sid = cookies.dsh_wc ?? ''
    if (sid === '') return false
    const hit = sessions.get(sid)
    if (hit === undefined || hit.expiresAt <= now) {
      if (hit !== undefined) sessions.delete(sid)
      return false
    }
    return true
  }

  const resolveUpstream = (): { origin: URL; cookie: string } | null => {
    const runtime = resolveDshWebRuntime(deps.ctx)
    if (runtime === null) return null
    const authRef = runtime.auth === null ? null : unwrapOriginal(runtime.auth)
    if (
      cachedAuth !== null
      && cachedAuth.originHref === runtime.origin.href
      && cachedAuth.authRef === authRef
    ) {
      if (
        runtime.auth === null
        || typeof runtime.auth.requestRejection !== 'function'
        || runtime.auth.requestRejection({ headers: { host: runtime.origin.host, cookie: cachedAuth.cookie } }) === undefined
      ) {
        return { origin: runtime.origin, cookie: cachedAuth.cookie }
      }
    }
    try {
      const cookie = exchangeLocalCookie(runtime)
      cachedAuth = { originHref: runtime.origin.href, authRef, cookie }
      return { origin: runtime.origin, cookie }
    } catch {
      cachedAuth = null
      return null
    }
  }

  const isReady = (): boolean => resolveDshWebRuntime(deps.ctx) !== null

  /** `/api/web-console/enter` 与 `/api/web-console/proxy*` 使用自有票据或 `dsh_wc` Cookie 鉴权，免 Bearer。 */
  const isBypassPath = (path: string, method: string): boolean => {
    if (path === '/api/web-console/enter' && method === 'GET') return true
    if (path === PROXY_PREFIX || path.startsWith(`${PROXY_PREFIX}/`)) return true
    return false
  }

  const tryHandle = async (
    req: IncomingMessage,
    res: ServerResponse,
    url: URL,
    path: string,
    method: string,
  ): Promise<boolean> => {
    // 1) POST /api/web-console/grant（Bearer 鉴权后调用）
    if (path === '/api/web-console/grant' && method === 'POST') {
      if (!isReady()) {
        send(res, 503, { error: '电脑端网页控制台未就绪' })
        return true
      }
      const now = Date.now()
      pruneGrants(now)
      while (grants.size >= GRANT_CAP) {
        const oldest = grants.keys().next().value
        if (oldest === undefined) break
        grants.delete(oldest)
      }
      const grant = randomBytes(24).toString('base64url')
      grants.set(grant, { expiresAt: now + GRANT_TTL_MS })
      await record(deps.logFile, '200 POST web-console/grant')
      send(res, 200, {
        ok: true,
        grant,
        path: `/api/web-console/enter?g=${grant}`,
        expiresIn: Math.floor(GRANT_TTL_MS / 1000),
      })
      return true
    }

    // 2) GET /api/web-console/enter?g=<grant>（免 Bearer，一次性消费防重放）
    if (path === '/api/web-console/enter' && method === 'GET') {
      const now = Date.now()
      pruneGrants(now)
      const g = (url.searchParams.get('g') ?? '').trim()
      const entry = g !== '' ? grants.get(g) : undefined
      if (g !== '') grants.delete(g)
      if (entry === undefined || entry.expiresAt <= now) {
        send(res, 401, { error: '网页控制台授权票据无效或已过期，请重新点击打开' })
        return true
      }
      pruneSessions(now)
      while (sessions.size >= SESSION_CAP) {
        const oldest = sessions.keys().next().value
        if (oldest === undefined) break
        sessions.delete(oldest)
      }
      const sid = randomBytes(24).toString('base64url')
      sessions.set(sid, { expiresAt: now + SESSION_TTL_MS })
      await record(deps.logFile, '302 GET web-console/enter -> /api/web-console/proxy/')
      res.writeHead(302, {
        'set-cookie': `dsh_wc=${sid}; Path=${PROXY_PREFIX}; HttpOnly; SameSite=Lax; Max-Age=1800`,
        location: `${PROXY_PREFIX}/`,
        'cache-control': 'no-store',
      })
      res.end()
      return true
    }

    // 3) ALL /api/web-console/proxy 与 /api/web-console/proxy/*
    if (path === PROXY_PREFIX || path.startsWith(`${PROXY_PREFIX}/`)) {
      if (!hasValidSessionCookie(req)) {
        send(res, 401, { error: '网页控制台会话已过期，请重新从手机端打开' })
        return true
      }
      if (path === PROXY_PREFIX && method === 'GET') {
        res.writeHead(302, {
          location: `${PROXY_PREFIX}/${url.search}`,
          'cache-control': 'no-store',
        })
        res.end()
        return true
      }
      const upstream = resolveUpstream()
      if (upstream === null) {
        send(res, 503, { error: '电脑端网页控制台未就绪' })
        return true
      }
      const { origin, cookie } = upstream
      const stripped = path.slice(PROXY_PREFIX.length) || '/'
      const upstreamPath = `${stripped}${url.search}`

      const forwardHeaders: Record<string, string | string[]> = {}
      for (const [k, v] of Object.entries(req.headers)) {
        if (v === undefined) continue
        const lower = k.toLowerCase()
        if (
          lower === 'host'
          || lower === 'authorization'
          || lower === 'cookie'
          || lower === 'connection'
          || lower === 'forwarded'
          || lower.startsWith('x-forwarded-')
        ) {
          continue
        }
        if (lower === 'origin') {
          forwardHeaders[k] = origin.origin
          continue
        }
        if (lower === 'referer' && typeof v === 'string') {
          try {
            const refUrl = new URL(v)
            if (refUrl.pathname.startsWith(PROXY_PREFIX)) {
              const refSub = refUrl.pathname.slice(PROXY_PREFIX.length) || '/'
              forwardHeaders[k] = `${origin.origin}${refSub}${refUrl.search}`
              continue
            }
          } catch {
            // drop invalid referer
          }
          continue
        }
        forwardHeaders[k] = v
      }
      forwardHeaders.host = origin.host
      if (cookie !== '') forwardHeaders.cookie = cookie

      const reqFn = origin.protocol === 'https:' ? httpsRequest : httpRequest
      const portNum = origin.port !== '' ? Number(origin.port) : (origin.protocol === 'https:' ? 443 : 80)

      await new Promise<void>((resolveDone) => {
        const proxyReq = reqFn(
          {
            hostname: origin.hostname,
            port: portNum,
            method,
            path: upstreamPath,
            headers: forwardHeaders,
            timeout: 30_000,
          },
          (proxyRes) => {
            const status = proxyRes.statusCode ?? 502
            const outHeaders: Record<string, string | string[]> = {}
            for (const [hk, hv] of Object.entries(proxyRes.headers)) {
              if (hv === undefined) continue
              const lower = hk.toLowerCase()
              if (
                lower === 'transfer-encoding'
                || lower === 'connection'
                || lower === 'set-cookie'
                || lower === 'x-frame-options'
                || lower === 'content-security-policy'
                || lower === 'content-security-policy-report-only'
                || lower === 'location'
              ) {
                continue
              }
              outHeaders[hk] = hv
            }

            const rawLoc = proxyRes.headers.location
            if (typeof rawLoc === 'string' && rawLoc.length > 0 && status >= 300 && status < 400) {
              try {
                const resolved = new URL(rawLoc, `${origin.origin}${upstreamPath}`)
                if (resolved.origin === origin.origin) {
                  resolved.searchParams.delete('token')
                  const qs = resolved.searchParams.toString()
                  outHeaders.location = `${PROXY_PREFIX}${resolved.pathname}${qs !== '' ? `?${qs}` : ''}`
                } else {
                  outHeaders.location = rawLoc
                }
              } catch {
                // ignore malformed location
              }
            }

            res.writeHead(status, outHeaders)
            if (method === 'HEAD') {
              proxyRes.resume()
              res.end()
              resolveDone()
              return
            }
            proxyRes.on('error', () => {
              res.destroy()
              resolveDone()
            })
            res.on('close', () => {
              proxyRes.destroy()
              resolveDone()
            })
            proxyRes.pipe(res)
            proxyRes.on('end', () => resolveDone())
          },
        )

        proxyReq.on('timeout', () => {
          proxyReq.destroy(new Error('upstream timeout'))
        })
        proxyReq.on('error', (err) => {
          send(res, 502, { error: `电脑端网页控制台代理连接失败：${err.message}` })
          resolveDone()
        })
        res.on('close', () => {
          if (!res.writableEnded) proxyReq.destroy()
        })
        if (method === 'GET' || method === 'HEAD') {
          proxyReq.end()
        } else {
          req.pipe(proxyReq)
        }
      })
      return true
    }

    return false
  }

  /** 支持 `/api/web-console/proxy/*` 的 WebSocket 透明代理升级。 */
  const handleUpgrade = (req: IncomingMessage, socket: Duplex, head: Buffer): boolean => {
    let url: URL
    try {
      url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)
    } catch {
      return false
    }
    const path = url.pathname
    if (!(path === PROXY_PREFIX || path.startsWith(`${PROXY_PREFIX}/`))) {
      return false
    }

    const rejectSocket = (statusLine: string): void => {
      try {
        socket.write(`HTTP/1.1 ${statusLine}\r\nConnection: close\r\n\r\n`)
      } catch {
        // ignore
      }
      socket.destroy()
    }

    if (!hasValidSessionCookie(req)) {
      rejectSocket('401 Unauthorized')
      return true
    }

    const upstream = resolveUpstream()
    if (upstream === null) {
      rejectSocket('503 Service Unavailable')
      return true
    }

    const { origin, cookie } = upstream
    const stripped = path.slice(PROXY_PREFIX.length) || '/'
    const upstreamPath = `${stripped}${url.search}`
    const portNum = origin.port !== '' ? Number(origin.port) : (origin.protocol === 'https:' ? 443 : 80)

    const upstreamSocket: Socket = origin.protocol === 'https:'
      ? tlsConnect({ host: origin.hostname, port: portNum, servername: origin.hostname })
      : netConnect({ host: origin.hostname, port: portNum })

    activeSockets.add(socket)
    activeSockets.add(upstreamSocket)

    const cleanup = (): void => {
      activeSockets.delete(socket)
      activeSockets.delete(upstreamSocket)
      if (!socket.destroyed) socket.destroy()
      if (!upstreamSocket.destroyed) upstreamSocket.destroy()
    }

    upstreamSocket.on('connect', () => {
      const headerLines: string[] = [`${req.method ?? 'GET'} ${upstreamPath} HTTP/1.1`, `Host: ${origin.host}`]
      for (let i = 0; i < req.rawHeaders.length; i += 2) {
        const name = req.rawHeaders[i]
        const value = req.rawHeaders[i + 1]
        if (name === undefined || value === undefined) continue
        const lower = name.toLowerCase()
        if (
          lower === 'host'
          || lower === 'cookie'
          || lower === 'authorization'
          || lower === 'forwarded'
          || lower.startsWith('x-forwarded-')
        ) {
          continue
        }
        if (lower === 'origin') {
          headerLines.push(`Origin: ${origin.origin}`)
          continue
        }
        headerLines.push(`${name}: ${value}`)
      }
      if (cookie !== '') {
        headerLines.push(`Cookie: ${cookie}`)
      }
      upstreamSocket.write(`${headerLines.join('\r\n')}\r\n\r\n`)
      if (head.length > 0) {
        upstreamSocket.write(head)
      }
      upstreamSocket.pipe(socket)
      socket.pipe(upstreamSocket)
    })

    upstreamSocket.on('error', () => {
      rejectSocket('502 Bad Gateway')
      cleanup()
    })
    socket.on('error', cleanup)
    upstreamSocket.on('close', cleanup)
    socket.on('close', cleanup)
    return true
  }

  const dispose = (): void => {
    grants.clear()
    sessions.clear()
    for (const s of [...activeSockets]) {
      try {
        s.destroy()
      } catch {
        // ignore
      }
    }
    activeSockets.clear()
  }

  return { isReady, isBypassPath, tryHandle, handleUpgrade, dispose }
}
