/**
 * 宿主扩展能力路由：
 * - `GET /api/host/plugins`、`POST /api/host/plugins/toggle`
 * - `GET / POST /api/host/plugins/settings`（R5 插件配置读写，屏蔽 dsh-mobile 与敏感字段）
 * - `GET /api/host/schedules`、`POST /api/host/schedules/:id/action`
 * - `GET /api/loopback/ports`、`POST /api/loopback/sign`、`GET|HEAD /api/loopback/:port/...`（R9 本机开发服预览代理）
 */
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { request as httpRequest, type IncomingMessage, type ServerResponse } from 'node:http'
import { join, resolve } from 'node:path'
import { readJson, send, tokenMatches } from '../http-util.ts'
import { normalizeScheduleTask } from '../projections.ts'
import { atomicWriteSync, dshHome, previewPorts, record } from '../state.ts'

const PROFILE_DIR_NAME = /^[A-Za-z0-9._-]{1,64}$/
const BUNDLE_NAME = /^(@[A-Za-z0-9._-]{1,64}\/)?[A-Za-z0-9._-]{1,120}$/
const CONFIG_KEY_RE = /^[A-Za-z0-9._-]{1,64}$/
const SENSITIVE_KEY_RE = /token|key|secret|password/i

export interface PluginSettingField {
  key: string
  kind: 'boolean' | 'string' | 'number'
  value: string
}

function isSelfMobilePlugin(name: string, rowId = ''): boolean {
  const lower = name.toLowerCase()
  return (
    lower === '@deepseek-ai/dsh-mobile'
    || lower === 'dsh-mobile'
    || lower.endsWith('/dsh-mobile')
    || rowId.toLowerCase() === 'mobile'
  )
}

/** 解析单行 YAML 标量值（仅接受安全扁平 boolean / number / string，拒绝 `!!js` 与复杂容器）。 */
function parseYamlScalar(rawVal: string): { kind: 'boolean' | 'string' | 'number'; value: string } | null {
  let v = rawVal.trim()
  if (v === '') return { kind: 'string', value: '' }
  if (v.startsWith('!!') || v.startsWith('[') || v.startsWith('{') || v === '|' || v === '>' || v === '>-' || v === '|-') {
    return null
  }
  // 去掉行尾注释（非引号包裹时）
  if (!v.startsWith('"') && !v.startsWith('\'')) {
    const hashAt = v.indexOf(' #')
    if (hashAt >= 0) v = v.slice(0, hashAt).trim()
  }
  if (v === 'true' || v === 'false') {
    return { kind: 'boolean', value: v }
  }
  if (/^-?(?:0|[1-9]\d*)(?:\.\d+)?$/.test(v)) {
    const n = Number(v)
    if (Number.isFinite(n)) return { kind: 'number', value: String(n) }
  }
  if (v.startsWith('\'') && v.endsWith('\'') && v.length >= 2) {
    return { kind: 'string', value: v.slice(1, -1).replace(/''/g, '\'') }
  }
  if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) {
    try {
      const parsed: unknown = JSON.parse(v)
      if (typeof parsed === 'string') return { kind: 'string', value: parsed }
    } catch {
      return { kind: 'string', value: v.slice(1, -1) }
    }
  }
  return { kind: 'string', value: v }
}

function formatYamlScalar(kind: 'boolean' | 'string' | 'number', rawValue: unknown): string {
  if (kind === 'boolean') {
    if (typeof rawValue === 'boolean') return String(rawValue)
    const s = String(rawValue).trim().toLowerCase()
    if (s !== 'true' && s !== 'false') throw new Error('布尔配置项的值只能为 true 或 false')
    return s
  }
  if (kind === 'number') {
    const n = typeof rawValue === 'number' ? rawValue : Number(String(rawValue).trim())
    if (!Number.isFinite(n)) throw new Error('数值配置项必须是有效数字')
    return String(n)
  }
  const str = String(rawValue ?? '')
  if (/[\r\n]/.test(str)) throw new Error('字符串配置项不支持多行换行')
  return `'${str.replace(/'/g, '\'\'')}'`
}

interface ParsedPatchRow {
  id: string
  name: string
  startLine: number
  endLine: number
  itemIndent: number
  configLine: number
  configIndent: number
  scalars: Map<string, { kind: 'boolean' | 'string' | 'number'; value: string; lineIndex: number }>
  rawKeys: Set<string>
}

/**
 * 解析 `cordis.patch.yml` 中的条目及其 `config:` 块（同时支持顶层 `- id: xxx` 与 `- insert:` 内嵌条目）。
 */
function parseCordisPatchRows(text: string): { lines: string[]; rows: ParsedPatchRow[] } {
  const lines = text.replace(/\r\n/g, '\n').split('\n')
  const rows: ParsedPatchRow[] = []

  const unquoteSimple = (s: string): string => {
    const t = s.trim().replace(/\s+#.*$/, '')
    if ((t.startsWith('\'') && t.endsWith('\'')) || (t.startsWith('"') && t.endsWith('"'))) {
      return t.slice(1, -1)
    }
    return t
  }

  let i = 0
  while (i < lines.length) {
    const line = lines[i] as string
    const dashMatch = /^(\s*)-\s+(.*)$/.exec(line)
    if (dashMatch === null) {
      i += 1
      continue
    }
    const itemIndent = (dashMatch[1] ?? '').length
    const firstRest = (dashMatch[2] ?? '').trim()

    if (/^insert\s*:\s*(?:#.*)?$/.test(firstRest)) {
      i += 1
      continue
    }

    // 找到该列表项的结束行（遇到小于等于 itemIndent 的非空非注释行结束）
    let endLine = i + 1
    while (endLine < lines.length) {
      const probe = lines[endLine] as string
      const trimmed = probe.trim()
      if (trimmed === '' || trimmed.startsWith('#')) {
        endLine += 1
        continue
      }
      const indent = (probe.match(/^\s*/)?.[0] ?? '').length
      if (indent <= itemIndent) break
      endLine += 1
    }

    let id = ''
    let name = ''
    let configLine = -1
    let configIndent = itemIndent + 2
    const scalars = new Map<string, { kind: 'boolean' | 'string' | 'number'; value: string; lineIndex: number }>()
    const rawKeys = new Set<string>()

    const firstKv = /^([A-Za-z0-9._-]+)\s*:\s*(.*)$/.exec(firstRest)
    if (firstKv !== null) {
      const k = firstKv[1] ?? ''
      const v = firstKv[2] ?? ''
      if (k === 'id') id = unquoteSimple(v)
      else if (k === 'name') name = unquoteSimple(v)
    }

    const propIndent = itemIndent + 2
    for (let j = i + 1; j < endLine; j += 1) {
      const sub = lines[j] as string
      const trimmed = sub.trim()
      if (trimmed === '' || trimmed.startsWith('#')) continue
      const indent = (sub.match(/^\s*/)?.[0] ?? '').length
      if (indent === propIndent) {
        const kv = /^([A-Za-z0-9._-]+)\s*:\s*(.*)$/.exec(trimmed)
        if (kv !== null) {
          const k = kv[1] ?? ''
          const v = kv[2] ?? ''
          if (k === 'id') id = unquoteSimple(v)
          else if (k === 'name') name = unquoteSimple(v)
          else if (k === 'config' && (v.trim() === '' || v.trim().startsWith('#'))) {
            configLine = j
          }
        }
      }
    }

    if (configLine >= 0) {
      let detectedIndent = -1
      for (let j = configLine + 1; j < endLine; j += 1) {
        const sub = lines[j] as string
        const trimmed = sub.trim()
        if (trimmed === '' || trimmed.startsWith('#')) continue
        const indent = (sub.match(/^\s*/)?.[0] ?? '').length
        if (indent <= propIndent) break
        if (detectedIndent < 0) detectedIndent = indent
        if (indent !== detectedIndent) continue
        const kv = /^([A-Za-z0-9._-]+)\s*:\s*(.*)$/.exec(trimmed)
        if (kv === null) continue
        const key = kv[1] ?? ''
        const valText = kv[2] ?? ''
        rawKeys.add(key)
        const parsed = parseYamlScalar(valText)
        if (parsed !== null) {
          scalars.set(key, { ...parsed, lineIndex: j })
        }
      }
      configIndent = detectedIndent > propIndent ? detectedIndent : propIndent + 2
    }

    if (id !== '' || name !== '') {
      rows.push({
        id,
        name,
        startLine: i,
        endLine,
        itemIndent,
        configLine,
        configIndent,
        scalars,
        rawKeys,
      })
    }
    i = endLine
  }

  return { lines, rows }
}

/** 定位已安装插件包自身的 `cordis.patch.yml` 并提取其默认 row `id` 与初始标量配置。 */
function inspectInstalledPluginMeta(
  profileDir: string,
  pkgName: string,
  depSpec: string,
): { rowId: string; defaults: Map<string, { kind: 'boolean' | 'string' | 'number'; value: string }> } {
  const defaults = new Map<string, { kind: 'boolean' | 'string' | 'number'; value: string }>()
  const candidates: string[] = []
  if (depSpec.startsWith('link:')) {
    candidates.push(resolve(profileDir, depSpec.slice('link:'.length)))
  }
  candidates.push(join(profileDir, 'node_modules', ...pkgName.split('/')))

  for (const dir of candidates) {
    const patchFile = join(dir, 'cordis.patch.yml')
    if (!existsSync(patchFile)) continue
    try {
      const raw = readFileSync(patchFile, 'utf8')
      const { rows } = parseCordisPatchRows(raw)
      const matched = rows.find((r) => r.name === pkgName) ?? rows[0]
      if (matched !== undefined) {
        for (const [k, v] of matched.scalars) {
          defaults.set(k, { kind: v.kind, value: v.value })
        }
        return { rowId: matched.id, defaults }
      }
    } catch {
      // ignore unreadable plugin patch
    }
  }

  // 回退推导常见 rowId（如 `@deepseek-ai/dsh-market` -> `market`）
  const short = pkgName.includes('/') ? (pkgName.split('/').pop() ?? pkgName) : pkgName
  const derived = short.startsWith('dsh-') ? short.slice(4) : short
  return { rowId: derived, defaults }
}

export function createHostExtrasRoutes(deps: {
  service: (name: string) => any
  sigOf: (kind: string, value: string, exp: string) => string
  sigTtlSec: number
  logFile: string
}): {
  tryHandle: (req: IncomingMessage, res: ServerResponse, url: URL, path: string, method: string) => Promise<boolean>
  isLoopbackAuthorized: (req: IncomingMessage, url: URL, path: string, method: string) => boolean
  setLoopbackCookieIfSigned: (res: ServerResponse, url: URL, path: string) => void
} {
  /** 校验 `/api/loopback/:port/...` 是否携带有效的 5 分钟短签名（查询参数或同路径限定 Cookie）。 */
  const verifyLoopbackSig = (portStr: string, exp: string, sig: string): boolean => {
    if (exp === '' || sig === '') return false
    const expN = Number(exp)
    if (!Number.isFinite(expN) || expN < Math.floor(Date.now() / 1000)) return false
    return tokenMatches(deps.sigOf('loopback', portStr, exp), sig.toLowerCase())
  }

  const parseCookies = (cookieHeader: string | undefined): Record<string, string> => {
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

  const isLoopbackAuthorized = (req: IncomingMessage, url: URL, path: string, method: string): boolean => {
    if (method !== 'GET' && method !== 'HEAD') return false
    const m = /^\/api\/loopback\/(\d+)(?:\/|$)/.exec(path)
    if (m === null) return false
    const portStr = m[1] as string
    const portNum = Number.parseInt(portStr, 10)
    if (!previewPorts().includes(portNum)) return false

    const qExp = url.searchParams.get('e') ?? ''
    const qSig = url.searchParams.get('sig') ?? ''
    if (verifyLoopbackSig(portStr, qExp, qSig)) return true

    const cookies = parseCookies(req.headers.cookie)
    const tokenCookie = cookies[`dsh_lb_${portStr}`] ?? ''
    const dot = tokenCookie.indexOf('.')
    if (dot > 0) {
      const cExp = tokenCookie.slice(0, dot)
      const cSig = tokenCookie.slice(dot + 1)
      if (verifyLoopbackSig(portStr, cExp, cSig)) return true
    }
    return false
  }

  const setLoopbackCookieIfSigned = (res: ServerResponse, url: URL, path: string): void => {
    const m = /^\/api\/loopback\/(\d+)(?:\/|$)/.exec(path)
    if (m === null) return
    const portStr = m[1] as string
    const qExp = url.searchParams.get('e') ?? ''
    const qSig = (url.searchParams.get('sig') ?? '').toLowerCase()
    if (verifyLoopbackSig(portStr, qExp, qSig)) {
      res.setHeader(
        'set-cookie',
        `dsh_lb_${portStr}=${qExp}.${qSig}; Path=/api/loopback/${portStr}; Max-Age=${String(deps.sigTtlSec)}; HttpOnly; SameSite=Lax`,
      )
    }
  }

  const tryHandle = async (
    req: IncomingMessage,
    res: ServerResponse,
    url: URL,
    path: string,
    method: string,
  ): Promise<boolean> => {
    // --- R9: 已授权本机开发服预览代理 ----------------------------------------
    if (path === '/api/loopback/ports' && method === 'GET') {
      send(res, 200, { ok: true, ports: previewPorts() })
      return true
    }

    if (path === '/api/loopback/sign' && method === 'POST') {
      const body = await readJson(req)
      const portNum = Number(body.port)
      if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
        send(res, 400, { error: 'port 必须是 1..65535 的整数' })
        return true
      }
      if (!previewPorts().includes(portNum)) {
        send(res, 403, { error: `端口 ${String(portNum)} 未在电脑端授权预览白名单中` })
        return true
      }
      const exp = String(Math.floor(Date.now() / 1000) + deps.sigTtlSec)
      const sig = deps.sigOf('loopback', String(portNum), exp)
      send(res, 200, { ok: true, port: portNum, e: exp, sig })
      return true
    }

    const loopbackMatch = /^\/api\/loopback\/(\d+)(\/.*)?$/.exec(path)
    if (loopbackMatch !== null) {
      if (method !== 'GET' && method !== 'HEAD') {
        send(res, 405, { error: '本机预览代理仅允许 GET 与 HEAD 请求' })
        return true
      }
      const portNum = Number.parseInt(loopbackMatch[1] as string, 10)
      if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535 || !previewPorts().includes(portNum)) {
        send(res, 403, { error: `端口 ${String(portNum)} 未在电脑端授权预览白名单中` })
        return true
      }

      setLoopbackCookieIfSigned(res, url, path)

      const subPath = loopbackMatch[2] && loopbackMatch[2].length > 0 ? loopbackMatch[2] : '/'
      const cleanParams = new URLSearchParams(url.searchParams)
      cleanParams.delete('t')
      cleanParams.delete('e')
      cleanParams.delete('sig')
      const qs = cleanParams.toString()
      const upstreamPath = qs === '' ? subPath : `${subPath}?${qs}`

      const forwardHeaders: Record<string, string | string[]> = {}
      for (const [k, v] of Object.entries(req.headers)) {
        if (v === undefined) continue
        const lower = k.toLowerCase()
        if (
          lower === 'host'
          || lower === 'authorization'
          || lower === 'connection'
          || lower === 'cookie'
        ) {
          continue
        }
        forwardHeaders[k] = v
      }
      forwardHeaders.host = `127.0.0.1:${String(portNum)}`

      await new Promise<void>((resolveDone) => {
        const proxyReq = httpRequest(
          {
            host: '127.0.0.1',
            port: portNum,
            method,
            path: upstreamPath,
            headers: forwardHeaders,
            timeout: 15000,
          },
          (proxyRes) => {
            const status = proxyRes.statusCode ?? 502
            const rawLoc = proxyRes.headers.location
            const outHeaders: Record<string, string | string[]> = {}
            for (const [hk, hv] of Object.entries(proxyRes.headers)) {
              if (hv === undefined) continue
              const lower = hk.toLowerCase()
              if (lower === 'transfer-encoding' || lower === 'connection' || lower === 'location') continue
              outHeaders[hk] = hv
            }

            if (typeof rawLoc === 'string' && rawLoc.length > 0 && status >= 300 && status < 400) {
              try {
                const resolved = new URL(rawLoc, `http://127.0.0.1:${String(portNum)}${upstreamPath}`)
                const rHost = resolved.hostname.toLowerCase()
                const rPort = resolved.port === '' ? (resolved.protocol === 'https:' ? 443 : 80) : Number(resolved.port)
                if (
                  resolved.protocol !== 'http:'
                  || (rHost !== '127.0.0.1' && rHost !== 'localhost')
                  || rPort !== portNum
                ) {
                  proxyRes.resume()
                  send(res, 502, { error: '已拦截本机开发服向外部主机或非授权端口的重定向' })
                  resolveDone()
                  return
                }
                outHeaders.location = `/api/loopback/${String(portNum)}${resolved.pathname}${resolved.search}`
              } catch {
                proxyRes.resume()
                send(res, 502, { error: '无效的上游重定向地址' })
                resolveDone()
                return
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
          send(res, 502, { error: `无法连接本机端口 ${String(portNum)}：${err.message}` })
          resolveDone()
        })
        res.on('close', () => {
          if (!res.writableEnded) proxyReq.destroy()
        })
        proxyReq.end()
      })
      return true
    }

    // --- 已安装插件列表与启停开关 --------------------------------------------
    if (path === '/api/host/plugins' && method === 'GET') {
      const profilesDir = join(dshHome(), 'profiles')
      const groups: Array<{ profile: string; items: Array<{ name: string; version: string; enabled: boolean; local: boolean }> }> = []
      let profiles: string[] = []
      try {
        profiles = readdirSync(profilesDir)
      } catch {
        profiles = []
      }
      for (const profile of profiles) {
        let raw = ''
        try {
          raw = readFileSync(join(profilesDir, profile, 'package.json'), 'utf8')
        } catch {
          continue
        }
        let bag: Record<string, unknown>
        try {
          bag = JSON.parse(raw) as Record<string, unknown>
        } catch {
          continue
        }
        const depsMap: Record<string, string> =
          typeof bag.dependencies === 'object' && bag.dependencies !== null
            ? (bag.dependencies as Record<string, string>)
            : {}
        const dsh: Record<string, unknown> =
          typeof bag.dsh === 'object' && bag.dsh !== null ? (bag.dsh as Record<string, unknown>) : {}
        const prof: Record<string, unknown> =
          typeof dsh.profile === 'object' && dsh.profile !== null ? (dsh.profile as Record<string, unknown>) : {}
        const bundles = Array.isArray(prof.bundles) ? (prof.bundles as unknown[]).map((x) => String(x)) : []
        const items = Object.keys(depsMap).map((dep) => {
          const version = String(depsMap[dep] ?? '')
          return { name: dep, version, enabled: bundles.indexOf(dep) >= 0, local: version.startsWith('link:') }
        })
        items.sort((a, b) => (a.enabled === b.enabled ? a.name.localeCompare(b.name) : a.enabled ? -1 : 1))
        groups.push({ profile, items })
      }
      send(res, 200, { ok: true, groups })
      return true
    }

    if (path === '/api/host/plugins/toggle' && method === 'POST') {
      let body: Record<string, unknown>
      try {
        body = await readJson(req)
      } catch (error) {
        const status = typeof (error as { status?: unknown }).status === 'number' ? (error as { status: number }).status : 400
        send(res, status, { error: `请求体不是合法 JSON：${error instanceof Error ? error.message : String(error)}` })
        return true
      }
      const profile = String(body.profile ?? '').trim()
      const name = String(body.name ?? '').trim()
      if (!PROFILE_DIR_NAME.test(profile)) {
        send(res, 400, { error: 'profile 名字不合法' })
        return true
      }
      if (!BUNDLE_NAME.test(name)) {
        send(res, 400, { error: '插件名不合法' })
        return true
      }
      if (typeof body.enabled !== 'boolean') {
        send(res, 400, { error: 'enabled 必须是布尔值' })
        return true
      }
      const enabled = body.enabled
      const file = join(dshHome(), 'profiles', profile, 'package.json')
      let raw = ''
      try {
        raw = readFileSync(file, 'utf8')
      } catch {
        send(res, 404, { error: `找不到 profile ${profile} 的 package.json` })
        return true
      }
      let bag: Record<string, unknown>
      try {
        bag = JSON.parse(raw) as Record<string, unknown>
      } catch {
        send(res, 500, { error: `profile ${profile} 的 package.json 不是合法 JSON，先手动修好再开开关` })
        return true
      }
      const depsMap: Record<string, unknown> =
        typeof bag.dependencies === 'object' && bag.dependencies !== null
          ? (bag.dependencies as Record<string, unknown>)
          : {}
      if (typeof depsMap[name] !== 'string') {
        send(res, 400, { error: `${name} 不在 profile ${profile} 的依赖里，这里只能开关已安装的插件` })
        return true
      }
      const dsh: Record<string, unknown> =
        typeof bag.dsh === 'object' && bag.dsh !== null ? (bag.dsh as Record<string, unknown>) : {}
      const prof: Record<string, unknown> =
        typeof dsh.profile === 'object' && dsh.profile !== null ? (dsh.profile as Record<string, unknown>) : {}
      const current = Array.isArray(prof.bundles) ? (prof.bundles as unknown[]).map((x) => String(x)) : []
      const present = current.indexOf(name) >= 0
      if (present === enabled) {
        await record(deps.logFile, `200 POST plugin-toggle ${profile}/${name} enabled=${String(enabled)} changed=false`)
        send(res, 200, { ok: true, profile, name, enabled, changed: false, restartRequired: false })
        return true
      }
      const nextBundles = enabled ? current.concat([name]) : current.filter((x) => x !== name)
      bag.dsh = { ...dsh, profile: { ...prof, bundles: nextBundles } }
      const text = `${JSON.stringify(bag, null, 2)}\n`
      try {
        writeFileSync(`${file}.bak`, raw, 'utf8')
        atomicWriteSync(file, text)
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        await record(deps.logFile, `500 POST plugin-toggle ${profile}/${name} write failed: ${message}`)
        send(res, 500, { error: `写 profile 清单失败：${message}` })
        return true
      }
      await record(deps.logFile, `200 POST plugin-toggle ${profile}/${name} enabled=${String(enabled)} changed=true`)
      send(res, 200, { ok: true, profile, name, enabled, changed: true, restartRequired: true })
      return true
    }

    // --- R5: 宿主插件配置动态读写 --------------------------------------------
    if (path === '/api/host/plugins/settings' && (method === 'GET' || method === 'POST')) {
      const body = method === 'POST' ? await readJson(req) : {}
      const profile = String(method === 'GET' ? (url.searchParams.get('profile') ?? '') : (body.profile ?? '')).trim()
      const pkgName = String(method === 'GET' ? (url.searchParams.get('name') ?? '') : (body.name ?? '')).trim()

      if (!PROFILE_DIR_NAME.test(profile)) {
        send(res, 400, { error: 'profile 名字不合法' })
        return true
      }
      if (!BUNDLE_NAME.test(pkgName)) {
        send(res, 400, { error: '插件包名不合法' })
        return true
      }

      if (isSelfMobilePlugin(pkgName)) {
        if (method === 'POST') {
          send(res, 403, { error: '禁止修改 dsh-mobile 自身配置' })
          return true
        }
        send(res, 200, { ok: true, writable: false, fields: [] })
        return true
      }

      const profileDir = join(dshHome(), 'profiles', profile)
      const pkgJsonFile = join(profileDir, 'package.json')
      if (!existsSync(pkgJsonFile)) {
        send(res, 404, { error: `找不到 profile ${profile}` })
        return true
      }
      let depSpec = ''
      try {
        const bag = JSON.parse(readFileSync(pkgJsonFile, 'utf8')) as Record<string, unknown>
        const depsMap = (bag.dependencies ?? {}) as Record<string, unknown>
        if (typeof depsMap[pkgName] === 'string') depSpec = depsMap[pkgName] as string
      } catch {
        send(res, 500, { error: `读取 profile ${profile} 的 package.json 失败` })
        return true
      }
      if (depSpec === '') {
        send(res, 404, { error: `插件 ${pkgName} 未安装在 profile ${profile} 中` })
        return true
      }

      const meta = inspectInstalledPluginMeta(profileDir, pkgName, depSpec)
      if (isSelfMobilePlugin(pkgName, meta.rowId)) {
        if (method === 'POST') {
          send(res, 403, { error: '禁止修改 dsh-mobile 自身配置' })
          return true
        }
        send(res, 200, { ok: true, writable: false, fields: [] })
        return true
      }

      const patchFile = join(profileDir, 'cordis.patch.yml')
      const patchRaw = existsSync(patchFile) ? readFileSync(patchFile, 'utf8') : ''
      const parsedPatch = parseCordisPatchRows(patchRaw)
      const matchedRow = parsedPatch.rows.find(
        (r) => (r.name !== '' && r.name === pkgName) || (meta.rowId !== '' && r.id === meta.rowId),
      )

      if (matchedRow !== undefined && isSelfMobilePlugin(matchedRow.name, matchedRow.id)) {
        if (method === 'POST') {
          send(res, 403, { error: '禁止修改 dsh-mobile 自身配置' })
          return true
        }
        send(res, 200, { ok: true, writable: false, fields: [] })
        return true
      }

      const buildMergedFields = (row: ParsedPatchRow | undefined): PluginSettingField[] => {
        const merged = new Map<string, PluginSettingField>()
        for (const [k, v] of meta.defaults) {
          if (SENSITIVE_KEY_RE.test(k)) continue
          merged.set(k, { key: k, kind: v.kind, value: v.value })
        }
        if (row !== undefined) {
          for (const [k, v] of row.scalars) {
            if (SENSITIVE_KEY_RE.test(k)) continue
            merged.set(k, { key: k, kind: v.kind, value: v.value })
          }
        }
        return Array.from(merged.values())
      }

      const writable = meta.rowId !== '' || matchedRow !== undefined
      if (method === 'GET') {
        send(res, 200, { ok: true, writable, fields: buildMergedFields(matchedRow) })
        return true
      }

      if (!writable) {
        send(res, 400, { error: '无法确定该插件在 cordis.patch.yml 中的条目 id，暂不支持自动写入' })
        return true
      }

      // 支持 `{ fields: [{ key, kind?, value }] }` 或 `{ values / config / patch: { k: v } }`
      const incomingUpdates: Array<{ key: string; kindHint?: 'boolean' | 'string' | 'number'; rawValue: unknown }> = []
      if (Array.isArray(body.fields)) {
        for (const item of body.fields) {
          if (item === null || typeof item !== 'object') continue
          const f = item as Record<string, unknown>
          const k = String(f.key ?? '').trim()
          const kh = f.kind === 'boolean' || f.kind === 'number' || f.kind === 'string' ? f.kind : undefined
          incomingUpdates.push({ key: k, kindHint: kh, rawValue: f.value })
        }
      } else {
        const mapSource = (body.values ?? body.config ?? body.patch) as unknown
        if (mapSource !== null && typeof mapSource === 'object' && !Array.isArray(mapSource)) {
          for (const [k, v] of Object.entries(mapSource as Record<string, unknown>)) {
            incomingUpdates.push({ key: k.trim(), rawValue: v })
          }
        }
      }

      const currentFields = buildMergedFields(matchedRow)
      const currentByKey = new Map(currentFields.map((f) => [f.key, f]))
      const formattedUpdates = new Map<string, string>()

      for (const up of incomingUpdates) {
        if (!CONFIG_KEY_RE.test(up.key)) {
          send(res, 400, { error: `配置键名不合法：${up.key}` })
          return true
        }
        if (SENSITIVE_KEY_RE.test(up.key)) {
          send(res, 403, { error: `禁止读取或修改敏感密钥字段：${up.key}` })
          return true
        }
        if (matchedRow !== undefined && matchedRow.rawKeys.has(up.key) && !matchedRow.scalars.has(up.key)) {
          send(res, 400, { error: `字段 ${up.key} 为动态表达式或复杂结构，不支持扁平覆盖` })
          return true
        }
        const inferredKind: 'boolean' | 'string' | 'number' =
          up.kindHint
          ?? currentByKey.get(up.key)?.kind
          ?? (typeof up.rawValue === 'boolean'
            ? 'boolean'
            : typeof up.rawValue === 'number'
              ? 'number'
              : 'string')
        try {
          formattedUpdates.set(up.key, formatYamlScalar(inferredKind, up.rawValue))
        } catch (err) {
          send(res, 400, { error: err instanceof Error ? err.message : String(err) })
          return true
        }
      }

      if (formattedUpdates.size > 0) {
        let nextLines: string[]
        if (matchedRow === undefined) {
          const baseLines = patchRaw.trim().length === 0 ? [] : parsedPatch.lines.slice()
          if (baseLines.length > 0 && baseLines[baseLines.length - 1] !== '') baseLines.push('')
          baseLines.push(`- id: ${meta.rowId}`)
          baseLines.push('  config:')
          // 把未在更新列表中的安全默认项一并显式写入（cordis patch 整块替换目标 row 的 config）
          for (const [dk, dv] of meta.defaults) {
            if (!formattedUpdates.has(dk) && !SENSITIVE_KEY_RE.test(dk)) {
              baseLines.push(`    ${dk}: ${formatYamlScalar(dv.kind, dv.value)}`)
            }
          }
          for (const [uk, uv] of formattedUpdates) {
            baseLines.push(`    ${uk}: ${uv}`)
          }
          nextLines = baseLines
        } else if (matchedRow.configLine < 0) {
          nextLines = parsedPatch.lines.slice()
          const propPad = ' '.repeat(matchedRow.itemIndent + 2)
          const cfgPad = ' '.repeat(matchedRow.itemIndent + 4)
          const inserted = [`${propPad}config:`]
          for (const [dk, dv] of meta.defaults) {
            if (!formattedUpdates.has(dk) && !SENSITIVE_KEY_RE.test(dk)) {
              inserted.push(`${cfgPad}${dk}: ${formatYamlScalar(dv.kind, dv.value)}`)
            }
          }
          for (const [uk, uv] of formattedUpdates) {
            inserted.push(`${cfgPad}${uk}: ${uv}`)
          }
          nextLines.splice(matchedRow.endLine, 0, ...inserted)
        } else {
          nextLines = parsedPatch.lines.slice()
          const cfgPad = ' '.repeat(matchedRow.configIndent)
          const toAppend: string[] = []
          for (const [uk, uv] of formattedUpdates) {
            const existingScalar = matchedRow.scalars.get(uk)
            if (existingScalar !== undefined) {
              nextLines[existingScalar.lineIndex] = `${cfgPad}${uk}: ${uv}`
            } else {
              toAppend.push(`${cfgPad}${uk}: ${uv}`)
            }
          }
          if (toAppend.length > 0) {
            // 插在 config 块最后一行标量之后
            let insertAt = matchedRow.configLine + 1
            for (const s of matchedRow.scalars.values()) {
              if (s.lineIndex + 1 > insertAt) insertAt = s.lineIndex + 1
            }
            nextLines.splice(insertAt, 0, ...toAppend)
          }
        }

        const outYaml = `${nextLines.join('\n').replace(/\n+$/, '')}\n`
        try {
          if (existsSync(patchFile)) {
            writeFileSync(`${patchFile}.bak`, patchRaw, 'utf8')
          }
          atomicWriteSync(patchFile, outYaml)
        } catch (err) {
          send(res, 500, { error: `写入 cordis.patch.yml 失败：${err instanceof Error ? err.message : String(err)}` })
          return true
        }
      }

      const reloaded = parseCordisPatchRows(existsSync(patchFile) ? readFileSync(patchFile, 'utf8') : '')
      const updatedRow = reloaded.rows.find(
        (r) => (r.name !== '' && r.name === pkgName) || (meta.rowId !== '' && r.id === meta.rowId),
      )
      await record(deps.logFile, `200 POST plugins/settings ${profile}/${pkgName} keys=${String(formattedUpdates.size)}`)
      send(res, 200, {
        ok: true,
        writable: true,
        restartRequired: formattedUpdates.size > 0,
        fields: buildMergedFields(updatedRow),
      })
      return true
    }

    // --- 宿主定时任务列表与动作 ----------------------------------------------
    if (path === '/api/host/schedules' && method === 'GET') {
      const svc = deps.service('schedule')
      if (svc !== null && typeof svc.list === 'function') {
        const page: unknown = await Promise.resolve((svc.list as (arg: unknown) => unknown)({ limit: 100 }))
        const bag = (page !== null && typeof page === 'object' ? page : {}) as Record<string, unknown>
        const rows = Array.isArray(bag.items) ? (bag.items as unknown[]) : []
        send(res, 200, { ok: true, source: 'service', items: rows.map(normalizeScheduleTask) })
        return true
      }
      let raw = ''
      try {
        raw = readFileSync(join(dshHome(), 'storages', 'schedule.json'), 'utf8')
      } catch (err) {
        send(res, 503, { error: `scheduled tasks unavailable: ${err instanceof Error ? err.message : String(err)}` })
        return true
      }
      let items: unknown[] = []
      try {
        const bag = JSON.parse(raw) as { tables?: { tasks?: Record<string, unknown> } }
        const table = (bag.tables !== undefined && bag.tables.tasks !== undefined ? bag.tables.tasks : {}) as Record<string, unknown>
        items = Object.keys(table).map((key) => normalizeScheduleTask(table[key]))
      } catch (err) {
        send(res, 500, { error: `cannot read scheduled tasks: ${err instanceof Error ? err.message : String(err)}` })
        return true
      }
      send(res, 200, { ok: true, source: 'file', items })
      return true
    }

    const scheduleActionMatch = /^\/api\/host\/schedules\/([^/]+)\/action$/.exec(path)
    if (scheduleActionMatch !== null && method === 'POST') {
      let body: Record<string, unknown>
      try {
        body = await readJson(req)
      } catch (error) {
        const status = typeof (error as { status?: unknown }).status === 'number' ? (error as { status: number }).status : 400
        send(res, status, { error: `请求体不是合法 JSON：${error instanceof Error ? error.message : String(error)}` })
        return true
      }
      const action = String(body.action ?? '').trim()
      if (action !== 'pause' && action !== 'resume' && action !== 'run' && action !== 'delete') {
        send(res, 400, { error: 'action 只能是 pause、resume、run 或 delete' })
        return true
      }
      let id = ''
      try {
        id = decodeURIComponent(scheduleActionMatch[1] as string)
      } catch {
        send(res, 400, { error: '任务 id 编码不合法' })
        return true
      }
      if (id === '') {
        send(res, 400, { error: '任务 id 不能为空' })
        return true
      }
      const svc = deps.service('schedule')
      if (svc === null) {
        send(res, 503, { error: '这台电脑没有挂载自动化任务（schedule 服务不可用）' })
        return true
      }
      const canEdit = typeof svc.edit === 'function'
      const canRun = typeof svc.run === 'function'
      const attempts: Array<{ label: string; call: () => Promise<unknown> }> = []
      if (action === 'run') {
        if (canRun) attempts.push({ label: 'run', call: () => Promise.resolve(svc.run({ id })) })
        if (canEdit) attempts.push({ label: 'edit.run', call: () => Promise.resolve(svc.edit({ id, action: 'run' })) })
      } else if (action === 'delete') {
        if (canEdit) {
          attempts.push({ label: 'edit.delete', call: () => Promise.resolve(svc.edit({ id, action: 'delete' })) })
        }
      } else {
        const wantResume = action === 'resume'
        if (canEdit) {
          attempts.push({
            label: 'edit.update',
            call: () => Promise.resolve(svc.edit({ id, action: 'update', patch: { active: wantResume } })),
          })
          attempts.push({ label: `edit.${action}`, call: () => Promise.resolve(svc.edit({ id, action })) })
        }
      }
      if (attempts.length === 0) {
        await record(deps.logFile, `501 POST schedule-action id=${id} action=${action} unsupported`)
        send(res, 501, {
          error: '这台电脑的定时任务服务不支持这个操作（缺少 edit / run 方法），升级 DSH 后再试',
          action,
          unsupported: true,
        })
        return true
      }
      let result: unknown = undefined
      let used = ''
      const failures: string[] = []
      for (const attempt of attempts) {
        try {
          result = await attempt.call()
          used = attempt.label
          break
        } catch (error) {
          const coded = typeof (error as { code?: unknown }).code === 'string' ? String((error as { code: string }).code) : ''
          const message = error instanceof Error ? error.message : String(error)
          failures.push(`${attempt.label}: ${message}`)
          const retryable = coded === 'schedule/input-invalid'
            || /unknown action|invalid|not supported|unsupported/i.test(message)
          if (!retryable) {
            const archived = coded === 'schedule/target-archived' || message.indexOf('schedule/target-archived') >= 0
            const status = archived ? 409 : 500
            const readable = archived
              ? '这个任务的目标会话已归档，先在电脑上恢复那个会话再试'
              : `电脑端拒绝了这个操作：${message}`
            await record(deps.logFile, `${String(status)} POST schedule-action id=${id} action=${action} code=${coded} err=${message}`)
            send(res, status, { error: readable, action })
            return true
          }
        }
      }
      if (used === '') {
        const detail = failures.length > 0 ? failures[failures.length - 1] : '没有可用的方法'
        await record(deps.logFile, `501 POST schedule-action id=${id} action=${action} none-of: ${failures.join(' | ')}`)
        send(res, 501, {
          error: `这台电脑的定时任务服务没有接受这个操作，升级 DSH 后再试（${String(detail)}）`,
          action,
          unsupported: true,
          tried: failures,
        })
        return true
      }
      const bag = (result !== null && typeof result === 'object' ? result : {}) as Record<string, unknown>
      const code = typeof bag.code === 'string' ? bag.code : ''
      if (code === 'schedule_not_found') {
        await record(deps.logFile, `404 POST schedule-action id=${id} action=${action} not-found`)
        send(res, 404, { error: '这个任务在电脑上已经不存在了，刷新列表看看', action })
        return true
      }
      if (code === 'schedule_conflict') {
        await record(deps.logFile, `409 POST schedule-action id=${id} action=${action} conflict`)
        send(res, 409, { error: '任务刚被别处改过，刷新列表再试一次', action })
        return true
      }
      if (code === 'schedule_execution_pending') {
        await record(deps.logFile, `409 POST schedule-action id=${id} action=${action} pending`)
        send(res, 409, { error: '这个任务正在执行，稍等一会儿再点「立即」', action, pending: true })
        return true
      }
      if (bag.deleted === true) {
        await record(deps.logFile, `200 POST schedule-action id=${id} action=${action} via=${used} deleted`)
        send(res, 200, { ok: true, action, id, via: used, deleted: true })
        return true
      }
      await record(deps.logFile, `200 POST schedule-action id=${id} action=${action} via=${used}`)
      send(res, 200, { ok: true, action, id, via: used, item: normalizeScheduleTask(result) })
      return true
    }

    return false
  }

  return { tryHandle, isLoopbackAuthorized, setLoopbackCookieIfSigned }
}
