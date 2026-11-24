/**
 * HTTP 小工具：令牌比较、地址枚举、读 JSON 体、回 JSON。
 *
 * 从 index.ts 拆出来，插件主干只留路由与业务；这些函数没有闭包状态，
 * 放这里能被单独阅读与复用。
 */
import type { IncomingMessage, ServerResponse } from 'node:http'
import { networkInterfaces } from 'node:os'
import { timingSafeEqual } from 'node:crypto'

/** 普通请求体上限 1 MiB；上传走更大的显式限额。 */
export const DEFAULT_BODY_BYTES = 1 << 20

export function lanAddresses(): string[] {
  const out: string[] = []
  const nets = networkInterfaces()
  for (const entries of Object.values(nets)) {
    if (entries === undefined) continue
    for (const entry of entries) {
      if (entry.internal) continue
      const v4 = entry.family === 'IPv4'
      const v6 = entry.family === 'IPv6'
      if (v4) {
        out.push(entry.address)
        continue
      }
      if (v6 && !entry.address.startsWith('fe80')) out.push(entry.address)
    }
  }
  return out
}

export function tokenMatches(given: string, expected: string): boolean {
  if (given.length === 0 || expected.length === 0) return false
  const a = Buffer.from(given, 'utf8')
  const b = Buffer.from(expected, 'utf8')
  if (a.length !== b.length) return false
  return timingSafeEqual(a, b)
}

export function presentedToken(req: IncomingMessage, url: URL): string {
  const header = req.headers.authorization
  if (typeof header === 'string' && header.toLowerCase().startsWith('bearer ')) {
    return header.slice(7).trim()
  }
  const query = url.searchParams.get('t')
  return query === null ? '' : query.trim()
}

export async function readJson(req: IncomingMessage, limit: number = DEFAULT_BODY_BYTES): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as string)
    size += buf.length
    if (size > limit) throw new Error('body too large')
    chunks.push(buf)
  }
  if (size === 0) return {}
  const text = Buffer.concat(chunks).toString('utf8')
  const parsed: unknown = JSON.parse(text)
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('body must be a JSON object')
  return parsed as Record<string, unknown>
}

export const send = (res: ServerResponse, status: number, body: unknown): void => {
    const text = typeof body === 'string' ? body : JSON.stringify(body)
    res.writeHead(status, {
      'content-type': typeof body === 'string' ? 'text/plain; charset=utf-8' : 'application/json; charset=utf-8',
      'content-length': String(Buffer.byteLength(text)),
        'access-control-allow-origin': '*',
      'access-control-allow-headers': 'authorization,content-type',
      'access-control-allow-methods': 'GET,POST,PATCH,OPTIONS',
      'cache-control': 'no-store',
    })
    res.end(text)
  }
