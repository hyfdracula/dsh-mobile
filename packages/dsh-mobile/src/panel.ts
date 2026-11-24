/**
 * DSH 设置面板用的同源路由：配对状态、二维码、开关，以及本机管理员可见的反馈工单。
 *
 * 从 `index.ts` 拆出来：这些处理不碰手机端 HTTP 监听，只读写配对状态与偏好，
 * 由宿主 web 服务器的 `connection.fetch` 注册。依赖通过 `PanelCtx` 传入，
 * 模块本身不持有插件实例状态。
 */
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export interface PanelPrefs {
  allowLan: boolean
  allowRemote: boolean
  publicUrl: string
}

export interface PanelCtx {
  pairState(): Record<string, unknown>
  rotatePair(): void
  writePair(next: PanelPrefs): void
  pairPayload(base: string, code: string, alts: string[]): string
  record(line: string): Promise<void>
}

export interface PanelBundle {
  routes: readonly Record<string, unknown>[]
}

const PANEL_PREFIX = '/api/dsh-mobile/panel'

/** JSON response for a panel route. */
const panelJson = (status: number, payload: unknown): Response =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })

/** Render the QR as SVG; a missing `qrcode` degrades to a caption, not a 500. */
const qrSvg = async (text: string): Promise<string | null> => {
  try {
    const mod: any = await import('qrcode')
    const code = mod?.default ?? mod
    const svg: unknown = await code.toString(text, { type: 'svg', margin: 1, width: 240, errorCorrectionLevel: 'M' })
    return typeof svg === 'string' ? svg : null
  } catch {
    return null
  }
}

/** Tolerant body reader: a panel POST without JSON is an empty patch. */
const panelBody = async (request: Request): Promise<Record<string, unknown>> => {
  try {
    const text = await request.text()
    if (text.length === 0) return {}
    const parsed: unknown = JSON.parse(text)
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : {}
  } catch {
    return {}
  }
}

const FEEDBACK_BASE = 'https://feedback.juo.de5.net'

const feedbackKey = (): string => {
  try {
    const file = join(homedir(), '.dsh', 'feedback-admin.key')
    if (!existsSync(file)) return ''
    return readFileSync(file, 'utf8').trim()
  } catch {
    return ''
  }
}

interface FeedbackReply {
  code: number
  data: Record<string, unknown>
}

const feedbackCall = async (method: string, path: string, body?: unknown): Promise<FeedbackReply> => {
  const key = feedbackKey()
  try {
    const headers: Record<string, string> = { authorization: `Bearer ${key}` }
    if (body !== undefined) headers['content-type'] = 'application/json; charset=utf-8'
    const res = await fetch(FEEDBACK_BASE + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    const text = await res.text()
    let data: Record<string, unknown> = {}
    try {
      const parsed: unknown = JSON.parse(text)
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        data = parsed as Record<string, unknown>
      }
    } catch {
      data = { raw: text.slice(0, 400) }
    }
    return { code: res.status, data }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return { code: 0, data: { error: message } }
  }
}

export const createPanel = (ctx: PanelCtx): PanelBundle => {
  /** The snapshot the panel renders, with the QR payload and its SVG data URL. */
  const panelSnapshot = (): Record<string, unknown> => {
    const snapshot = ctx.pairState()
    const base = String(snapshot.base ?? '')
    const alts = Array.isArray(snapshot.alts) ? (snapshot.alts as string[]) : []
    const payload = base.length > 0 ? ctx.pairPayload(base, String(snapshot.code ?? ''), alts) : ''
    return { ...snapshot, payload }
  }

  /** Merge one patch into the pairing preferences and answer with the new state. */
  const panelConfig = async (request: Request): Promise<Response> => {
    const body = await panelBody(request)
    const current = ctx.pairState()
    const next: PanelPrefs = {
      allowLan: typeof body.allowLan === 'boolean' ? body.allowLan : Boolean((current as any).allowLan),
      allowRemote: typeof body.allowRemote === 'boolean' ? body.allowRemote : Boolean((current as any).allowRemote),
      publicUrl: typeof body.publicUrl === 'string' ? body.publicUrl.trim() : String((current as any).publicUrl ?? ''),
    }
    ctx.writePair(next)
    await ctx.record(`200 PANEL config lan=${String(next.allowLan)} remote=${String(next.allowRemote)}`)
    return panelJson(200, panelSnapshot())
  }

  /** The QR itself, as an SVG the panel renders in an <img>. */
  const panelQr = async (request: Request): Promise<Response> => {
    const url = new URL(request.url)
    const asked = url.searchParams.get('payload')
    const snapshot = ctx.pairState()
    const base = String(snapshot.base ?? '')
    const alts = Array.isArray(snapshot.alts) ? (snapshot.alts as string[]) : []
    const text = asked !== null && asked.length > 0
      ? asked
      : base.length > 0
        ? ctx.pairPayload(base, String(snapshot.code ?? ''), alts)
        : ''
    if (text.length === 0) {
      return panelJson(409, { error: 'no base url yet', hint: 'turn 局域网直连 on, or set a public url' })
    }
    const svg = await qrSvg(text)
    if (svg === null) {
      return panelJson(503, { error: 'qrcode module missing', hint: 'install qrcode in the plugin package' })
    }
    return new Response(svg, {
      status: 200,
      headers: { 'content-type': 'image/svg+xml; charset=utf-8', 'cache-control': 'no-store' },
    })
  }

  const feedbackState = async (): Promise<Response> => {
    if (feedbackKey() === '') return panelJson(200, { configured: false })
    const list = await feedbackCall('GET', '/v1/admin/tickets?limit=60')
    if (list.code !== 200) {
      return panelJson(list.code === 0 ? 502 : list.code, { configured: true, error: String(list.data.error ?? 'upstream') })
    }
    const sum = await feedbackCall('GET', '/v1/admin/summary')
    const tickets = Array.isArray(list.data.tickets) ? list.data.tickets : []
    return panelJson(200, { configured: true, tickets, summary: sum.data })
  }

  const feedbackReply = async (request: Request): Promise<Response> => {
    const body = await panelBody(request)
    const id = typeof body.id === 'string' ? body.id : ''
    const text = typeof body.text === 'string' ? body.text.trim() : ''
    if (id === '' || text === '') return panelJson(400, { error: 'id and text are required' })
    const status = typeof body.status === 'string' ? body.status : ''
    const payload: Record<string, unknown> = { text }
    if (status !== '') payload.status = status
    const r = await feedbackCall('POST', `/v1/admin/tickets/${encodeURIComponent(id)}/reply`, payload)
    return panelJson(r.code === 0 ? 502 : r.code, r.data)
  }

  const feedbackStatus = async (request: Request): Promise<Response> => {
    const body = await panelBody(request)
    const id = typeof body.id === 'string' ? body.id : ''
    const status = typeof body.status === 'string' ? body.status : ''
    if (id === '' || status === '') return panelJson(400, { error: 'id and status are required' })
    const r = await feedbackCall('POST', `/v1/admin/tickets/${encodeURIComponent(id)}/status`, { status })
    return panelJson(r.code === 0 ? 502 : r.code, r.data)
  }

  const feedbackFile = async (request: Request): Promise<Response> => {
    const key = feedbackKey()
    if (key === '') return panelJson(503, { error: 'no admin key' })
    const url = new URL(request.url)
    const id = url.searchParams.get('id') ?? ''
    const name = url.searchParams.get('name') ?? ''
    if (id === '' || name === '') return panelJson(400, { error: 'id and name are required' })
    try {
      const res = await fetch(
        `${FEEDBACK_BASE}/v1/admin/files/${encodeURIComponent(id)}/${encodeURIComponent(name)}`,
        { headers: { authorization: `Bearer ${key}` } },
      )
      if (!res.ok) return panelJson(res.status, { error: `upstream ${String(res.status)}` })
      const bytes = Buffer.from(await res.arrayBuffer())
      return new Response(bytes, {
        status: 200,
        headers: {
          'content-type': res.headers.get('content-type') ?? 'application/octet-stream',
          'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(name)}`,
          'cache-control': 'no-store',
        },
      })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return panelJson(502, { error: message })
    }
  }

  const routes: readonly Record<string, unknown>[] = [
    { path: `${PANEL_PREFIX}/state`, methods: ['GET'], requestBody: 'buffered', fetch: async () => panelJson(200, panelSnapshot()) },
    { path: `${PANEL_PREFIX}/newcode`, methods: ['POST'], requestBody: 'buffered', fetch: async () => { ctx.rotatePair(); return panelJson(200, panelSnapshot()) } },
    { path: `${PANEL_PREFIX}/config`, methods: ['POST'], requestBody: 'buffered', fetch: async (request: Request) => panelConfig(request) },
    { path: `${PANEL_PREFIX}/qr.svg`, methods: ['GET'], requestBody: 'buffered', fetch: async (request: Request) => panelQr(request) },
    { path: `${PANEL_PREFIX}/feedback/state`, methods: ['GET'], requestBody: 'buffered', fetch: async () => feedbackState() },
    { path: `${PANEL_PREFIX}/feedback/reply`, methods: ['POST'], requestBody: 'buffered', fetch: async (request: Request) => feedbackReply(request) },
    { path: `${PANEL_PREFIX}/feedback/status`, methods: ['POST'], requestBody: 'buffered', fetch: async (request: Request) => feedbackStatus(request) },
    { path: `${PANEL_PREFIX}/feedback/file`, methods: ['GET'], requestBody: 'buffered', fetch: async (request: Request) => feedbackFile(request) },
  ]

  return { routes }
}
