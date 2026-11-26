/**
 * 统一发消息核心、per-session 异步互斥锁、宿主待发队列读写（含编辑保图）与幂等重放缓存。
 */
import { randomBytes } from 'node:crypto'
import { mkdir, writeFile } from 'node:fs/promises'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { join } from 'node:path'
import { HttpError, send } from './http-util.ts'
import { projectSessions } from './projections.ts'
import { dshHome, record } from './state.ts'

export const MAX_UPLOAD_BYTES = 36 << 20
export const MAX_IMAGES = 9
export const MAX_FILES = 9
export const IMAGE_TYPES = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif'])

/**
 * Per-session 异步队列互斥锁：包裹同一会话的发送、入队、重排、编辑、删除与插队，
 * 杜绝并发 `reorder` / `edit` / `send` 交叉读写宿主队列导致丢项或乱序。
 */
const sessionLocks = new Map<string, Promise<void>>()

export async function withSessionLock<T>(sessionId: string, fn: () => Promise<T>): Promise<T> {
  const prev = sessionLocks.get(sessionId) ?? Promise.resolve()
  let release!: () => void
  const gate = new Promise<void>((resolve) => {
    release = resolve
  })
  const chained = prev.then(() => gate, () => gate)
  sessionLocks.set(sessionId, chained)
  await prev.catch(() => undefined)
  try {
    return await fn()
  } finally {
    release()
    if (sessionLocks.get(sessionId) === chained) {
      sessionLocks.delete(sessionId)
    }
  }
}

/** 根据会话当前是否运行决定有效投递模式（空闲会话一律走 `steer` 启动新轮次）。 */
export async function pickMode(
  ctl: { list: (query: unknown, signal: AbortSignal) => unknown },
  sessionId: string,
  requested: 'queue' | 'steer',
): Promise<{ mode: 'queue' | 'steer'; running: boolean; known: boolean }> {
  let known = false
  let running = false
  try {
    const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(15000)))
    for (const row of projectSessions(listed)) {
      if (row.id === sessionId) {
        known = true
        running = row.running === true
        break
      }
    }
  } catch {
    // 列表探测失败不阻断发送。
  }
  return { mode: running ? requested : 'steer', running, known }
}

/** 读取宿主指定会话的状态快照。 */
export async function hostState(ctl: any, sessionId: string): Promise<any> {
  if (!ctl || typeof ctl.state !== 'function') return null
  try {
    return await Promise.resolve(ctl.state({ sessionId }, AbortSignal.timeout(8000)))
  } catch {
    return null
  }
}

/** 读取宿主当前排队中的消息项列表。 */
export async function hostQueued(ctl: any, sessionId: string): Promise<any[]> {
  const st = await hostState(ctl, sessionId)
  const q = st && Array.isArray(st.queue) ? st.queue : []
  return q.filter((it: any) => it !== null && typeof it === 'object' && it.placement === 'queued')
}

function hostText(it: any): string {
  const parts = it && Array.isArray(it.content) ? it.content : []
  return parts
    .filter((p: any) => p !== null && typeof p === 'object' && p.type === 'text')
    .map((p: any) => String(p.text ?? ''))
    .join(' ')
    .trim()
}

function hostImages(it: any): Record<string, unknown>[] {
  const parts = it && Array.isArray(it.content) ? it.content : []
  const out: Record<string, unknown>[] = []
  for (const p of parts) {
    if (p === null || typeof p !== 'object' || p.type !== 'image') continue
    const mediaType = String(p.mediaType ?? 'image/png')
    const name = String(p.name ?? '')
    out.push(name === '' ? { mediaType } : { mediaType, name })
  }
  return out
}

/** 构造返回给手机端的待发送队列视图。 */
export async function hostQueueView(ctl: any, sessionId: string): Promise<Record<string, unknown>[]> {
  const list = await hostQueued(ctl, sessionId)
  return list.map((it: any, i: number) => ({
    id: String(it.id),
    text: hostText(it),
    at: 0,
    index: i + 1,
    images: hostImages(it),
  }))
}

/** 向宿主排队区压入一条待发送消息并返回新生成的队列项 ID。 */
export async function hostEnqueue(
  ctl: any,
  sessionId: string,
  content: Record<string, unknown>[],
): Promise<string> {
  const before = new Set((await hostQueued(ctl, sessionId)).map((x: any) => String(x.id)))
  await Promise.resolve(
    ctl.prompt(
      {
        requestId: randomBytes(16).toString('hex'),
        sessionId,
        mode: 'queue',
        content,
      },
      AbortSignal.timeout(30000),
    ),
  )
  const after = await hostQueued(ctl, sessionId)
  const fresh = after.find((x: any) => !before.has(String(x.id)))
  return fresh === undefined ? '' : String(fresh.id)
}

/** 调用宿主 `updateQueue` 修改、移除或插队执行一条排队项。 */
export async function hostMutate(
  ctl: any,
  sessionId: string,
  itemId: string,
  action: Record<string, unknown>,
): Promise<boolean> {
  if (!ctl || typeof ctl.updateQueue !== 'function') return false
  try {
    await Promise.resolve(
      ctl.updateQueue({ sessionId, itemId, action }, AbortSignal.timeout(20000)),
    )
    return true
  } catch {
    return false
  }
}

/**
 * 构造排队项编辑后的 `content`：保留原排队项中所有非 `text` 内容块（如图片/文件 part），
 * 仅替换文本块，避免编辑文字时丢失已附带的图片或附件。
 */
export async function buildEditedQueueContent(
  ctl: any,
  sessionId: string,
  itemId: string,
  newText: string,
): Promise<Record<string, unknown>[]> {
  const listed = await hostQueued(ctl, sessionId)
  const existing = listed.find((x: any) => String(x.id) === itemId)
  const oldParts = existing && Array.isArray(existing.content) ? existing.content : []
  const nextContent: Record<string, unknown>[] = []
  let placedText = false
  for (const part of oldParts) {
    if (part === null || typeof part !== 'object') continue
    const p = part as Record<string, unknown>
    if (p.type === 'text') {
      if (!placedText) {
        nextContent.push({ type: 'text', text: newText })
        placedText = true
      }
    } else {
      nextContent.push(p)
    }
  }
  if (!placedText) {
    nextContent.unshift({ type: 'text', text: newText })
  }
  return nextContent
}

/** 校验并构造图片消息块列表。 */
export function parseImageParts(
  raw: unknown[],
  requireNonEmpty: boolean,
): { parts: Record<string, unknown>[]; bytes: number } {
  if (requireNonEmpty && raw.length === 0) {
    throw new HttpError(400, 'images is empty')
  }
  if (raw.length > MAX_IMAGES) {
    throw new HttpError(400, `at most ${String(MAX_IMAGES)} images per request`)
  }
  const parts: Record<string, unknown>[] = []
  let bytes = 0
  for (const item of raw) {
    if (item === null || typeof item !== 'object') {
      throw new HttpError(400, 'each image must be an object')
    }
    const img = item as Record<string, unknown>
    const mediaType = String(img.mediaType ?? '').toLowerCase()
    if (!IMAGE_TYPES.has(mediaType)) {
      throw new HttpError(400, `unsupported image type: ${mediaType}`)
    }
    const data = String(img.data ?? '')
    if (data.length === 0) {
      throw new HttpError(400, 'image data is empty')
    }
    bytes += Math.floor((data.length * 3) / 4)
    const part: Record<string, unknown> = { type: 'image', mediaType, data }
    const name = String(img.name ?? '').trim().slice(0, 80)
    if (name !== '') part.name = name
    parts.push(part)
  }
  return { parts, bytes }
}

/** 将手机上传的附件落盘到 `<dshHome>/mobile-uploads/<YYYYMMDD>/` 并返回说明文本。 */
export async function saveMobileFiles(
  raw: unknown[],
  requireNonEmpty = false,
): Promise<{ saved: Record<string, unknown>[]; bytes: number; text: string }> {
  if (requireNonEmpty && raw.length === 0) {
    throw new HttpError(400, 'files is empty')
  }
  if (raw.length > MAX_FILES) {
    throw new HttpError(400, `at most ${String(MAX_FILES)} files per request`)
  }
  const saved: Record<string, unknown>[] = []
  if (raw.length === 0) return { saved, bytes: 0, text: '' }
  const stamp = new Date()
  const day = `${String(stamp.getFullYear())}${String(stamp.getMonth() + 1).padStart(2, '0')}${String(stamp.getDate()).padStart(2, '0')}`
  const dir = join(dshHome(), 'mobile-uploads', day)
  await mkdir(dir, { recursive: true })
  let bytes = 0
  for (const item of raw) {
    if (item === null || typeof item !== 'object') {
      throw new HttpError(400, 'each file must be an object')
    }
    const f = item as Record<string, unknown>
    const data = String(f.data ?? '')
    if (data.length === 0) {
      throw new HttpError(400, 'file data is empty')
    }
    const safe = String(f.name ?? 'file')
      .replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_')
      .trim()
      .slice(0, 120) || 'file'
    const target = join(dir, `${String(Date.now())}-${randomBytes(2).toString('hex')}-${safe}`)
    const buf = Buffer.from(data, 'base64')
    await writeFile(target, buf)
    bytes += buf.length
    saved.push({ name: safe, path: target, bytes: buf.length })
  }
  const lines = saved.map((s) => `- ${String(s.path)}`)
  return { saved, bytes, text: `已保存到这台机器：\n${lines.join('\n')}` }
}

export interface DispatchOutcome {
  queued: boolean
  mode: 'queue' | 'steer'
  running: boolean
  known: boolean
  item: string
  queue: Record<string, unknown>[]
  result: unknown
}

/**
 * 统一发消息核心函数：供 `/send`、`/images`、`/files`、`/outbox` 共同复用，
 * 内部加 `withSessionLock(sessionId)` 保证同一会话投递与队列读取的串行一致性。
 */
export async function dispatchSessionMessage(
  ctl: any,
  sessionId: string,
  content: Record<string, unknown>[],
  requestedMode: 'queue' | 'steer',
  timeoutMs: number,
  logFile: string,
  logTag: string,
): Promise<DispatchOutcome> {
  return withSessionLock(sessionId, async () => {
    const { mode, running, known } = await pickMode(ctl, sessionId, requestedMode)
    if (mode === 'queue' && running) {
      const itemId = await hostEnqueue(ctl, sessionId, content)
      const queue = await hostQueueView(ctl, sessionId)
      await record(logFile, `200 POST ${logTag} session=${sessionId} mode=queue host=${itemId} parts=${String(content.length)}`)
      return {
        queued: true,
        mode: 'queue',
        running: true,
        known,
        item: itemId,
        queue,
        result: null,
      }
    }
    const result = await Promise.resolve(
      ctl.prompt(
        {
          requestId: randomBytes(16).toString('hex'),
          sessionId,
          mode,
          content,
        },
        AbortSignal.timeout(timeoutMs),
      ),
    )
    await record(
      logFile,
      `200 POST ${logTag} session=${sessionId} mode=${mode} busy=${String(running)} known=${String(known)} parts=${String(content.length)}`,
    )
    return {
      queued: false,
      mode,
      running,
      known,
      item: '',
      queue: [],
      result: result ?? null,
    }
  })
}

/** 写请求幂等重放缓存（10 分钟、上限 200 条）与并发在途防重。 */
export interface IdempotencyStore {
  replayHit: (req: IncomingMessage, res: ServerResponse, route: string, hash: string) => boolean
  inflightBusy: (key: string) => boolean
  inflightHold: (res: ServerResponse, key: string) => void
  replayPut: (key: string, status: number, body: unknown, route: string, hash: string) => void
}

export function createIdempotencyStore(): IdempotencyStore {
  const replay = new Map<string, { at: number; status: number; text: string; route: string; hash: string }>()
  const inflight = new Map<string, number>()

  const inflightBusy = (key: string): boolean => {
    const at = inflight.get(key)
    if (at === undefined) return false
    if (Date.now() - at > 120_000) {
      inflight.delete(key)
      return false
    }
    return true
  }

  const inflightHold = (res: ServerResponse, key: string): void => {
    inflight.set(key, Date.now())
    res.on('finish', () => inflight.delete(key))
  }

  const replayGet = (key: string) => {
    const hit = replay.get(key)
    if (hit === undefined) return null
    if (Date.now() - hit.at > 10 * 60 * 1000) {
      replay.delete(key)
      return null
    }
    return hit
  }

  const replayPut = (key: string, status: number, body: unknown, route: string, hash: string): void => {
    if (key === '' || status < 200 || status >= 300) return
    const text = typeof body === 'string' ? body : JSON.stringify(body)
    replay.delete(key)
    replay.set(key, { at: Date.now(), status, text, route, hash })
    while (replay.size > 200) {
      const first = replay.keys().next().value
      if (first === undefined) break
      replay.delete(first)
    }
  }

  const replayHit = (req: IncomingMessage, res: ServerResponse, route: string, hash: string): boolean => {
    const key = String(req.headers['idempotency-key'] ?? '')
    if (key === '') return false
    const hit = replayGet(key)
    if (hit === null) return false
    if (hit.route !== route || hit.hash !== hash) {
      send(res, 409, { error: 'idempotency key reused with a different request' })
      return true
    }
    res.writeHead(hit.status, {
      'content-type': 'application/json; charset=utf-8',
      'content-length': String(Buffer.byteLength(hit.text)),
      'access-control-allow-origin': '*',
      'cache-control': 'no-store',
      'x-idempotent-replay': '1',
    })
    res.end(hit.text)
    return true
  }

  return { replayHit, inflightBusy, inflightHold, replayPut }
}
