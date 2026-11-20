/**
 * dsh-mobile: a standalone HTTP gateway that lets a phone (and its own app)
 * read the session list and post messages into a DSH session.
 *
 * Why this exists: the shipped console plugin owns a paired-app protocol that
 * is tied to its own tunnel and to an account entitlement, and it is a package
 * we do not own. This row is deliberately *parallel* to it -- a second,
 * independent listener on its own port, its own bearer token and no shared
 * state -- so the console keeps working untouched while a phone client can be
 * pointed at a server we control.
 *
 * What it is not: it does not proxy the web GUI, it does not sign anybody in,
 * and it does not read the console's files. Everything goes through the same
 * official plugin services the console uses, which is what makes it safe to
 * run next to it:
 *
 *   ctl.list({}, signal)          -> { items: [...] }
 *   ctl.prompt({ requestId, sessionId, mode, content }, signal)
 *
 * Both come from `ctx.get('sessionController')`. A missing controller turns
 * every session route into a 503 with an explanation instead of a crash: the
 * row stays mounted and `/health` keeps reporting the truth.
 *
 * Security posture: the listener binds 0.0.0.0 because a phone on the same
 * Wi-Fi has to reach it, so *every* route except `/health` requires the bearer
 * token. The token is generated once, persisted 0600 next to the rest of the
 * DSH state, and compared in constant time.
 *
 * @module @deepseek-ai/dsh-mobile
 */

import { randomBytes, randomInt, timingSafeEqual } from 'node:crypto'
import { chmodSync, closeSync, mkdirSync, openSync, readSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { appendFile, mkdir, writeFile } from 'node:fs/promises'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { networkInterfaces, homedir, hostname } from 'node:os'
import { dirname, extname, join, normalize } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as zlib from 'node:zlib'

export const name = 'mobile'

/** Deployment configuration, supplied by the profile patch row. */
export interface Config {
  /** `false` keeps the row mounted but starts no listener. */
  readonly enabled?: boolean
  /** TCP port. Default 8901. */
  readonly port?: number
  /** Bind address. Default `0.0.0.0` so a phone on the LAN can reach it. */
  readonly host?: string
  /**
   * Bearer token. When omitted the token is read from `<dsh home>/dsh-mobile.json`,
   * generated on first run and persisted 0600.
   */
  readonly token?: string
  /** Append-only request record. Defaults to `<dsh home>/dsh-mobile.log`; `''` disables it. */
  readonly logFile?: string
}

const VERSION = '0.1.0'
const MAX_BODY_BYTES = 1 << 20
/** Image bodies are base64 and several may arrive at once: 36 MB of JSON. */
const MAX_UPLOAD_BYTES = 36 << 20
const MAX_IMAGES = 9
/** 一次最多带几个附件文件过来（服务端会落到磁盘再给会话路径）。 */
const MAX_FILES = 9
/** Media types the controller accepts on an image content part. */
const IMAGE_TYPES = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
const DEFAULT_PORT = 8901
/** How long one pairing code stays valid. */
const PAIR_TTL_MS = 15 * 60 * 1000
/** Failed claims allowed per peer before the handshake is throttled. */
const PAIR_FAIL_LIMIT = 8
/** Wrong codes that lock one peer out, and for how long. */
const PAIR_LOCK_MS = 5 * 60 * 1000
/** A phone counts as "connected" while it has been seen this recently. */
const PHONE_ONLINE_MS = 10 * 60 * 1000

/** One live pairing code. */
interface PairCode {
  code: string
  expiresAt: number
}

/** Six digits, zero-padded; `randomInt` is the cryptographic RNG. */
function freshPairCode(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, '0')
}

/** The deep link a QR code carries: base URL plus the live code. */
function pairPayload(base: string, code: string): string {
  return `dshmobile://pair?b=${encodeURIComponent(base)}&c=${encodeURIComponent(code)}`
}

/** Harness home, honouring the `DSH_HOME` override the launchers use. */
function dshHome(): string {
  const override = process.env.DSH_HOME
  return override !== undefined && override.length > 0 ? override : join(homedir(), '.dsh')
}

/** Pairing preferences, persisted next to the token. */
export interface PairPrefs {
  /** Advertise and accept the LAN path (the normal case). */
  allowLan: boolean
  /** Advertise and accept a public tunnel path (off by default). */
  allowRemote: boolean
  /** Public base URL to show on the panel, e.g. `https://dsh.example.net`. */
  publicUrl: string
}

/** Persisted state: the bearer token plus the pairing preferences. */
interface MobileState {
  token: string
  pair?: Partial<PairPrefs>
}

const statePath = (): string => join(dshHome(), 'dsh-mobile.json')

/** Read the persisted state; a missing or corrupt file reads as an empty object. */
function readState(): Partial<MobileState> {
  try {
    const parsed: unknown = JSON.parse(readFileSync(statePath(), 'utf8'))
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return {}
    return parsed as Partial<MobileState>
  } catch {
    return {}
  }
}

/** Merge a patch into the persisted state, keeping the file 0600. */
function writeState(patch: Partial<MobileState>): void {
  const file = statePath()
  const next: Partial<MobileState> = { ...readState(), ...patch }
  try {
    mkdirSync(dirname(file), { recursive: true })
    writeFileSync(file, `${JSON.stringify(next, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 })
    chmodSync(file, 0o600)
  } catch {
    // A read-only home still works: the change lasts for this process only.
  }
}

/** Pairing preferences with the defaults both the panel and the phone assume. */
function pairPrefs(): PairPrefs {
  const raw = readState().pair
  const envPublic = process.env.DSH_MOBILE_PUBLIC_URL
  return {
    // Both default to on so upgrading never breaks a working phone; the two
    // switches exist to cut access off, not to gate the first run.
    allowLan: raw?.allowLan !== false,
    allowRemote: raw?.allowRemote !== false,
    publicUrl:
      typeof raw?.publicUrl === 'string' && raw.publicUrl.length > 0
        ? raw.publicUrl
        : typeof envPublic === 'string'
          ? envPublic
          : '',
  }
}

/**
 * Read the persisted token, generating and saving one on first use.
 * @param fromConfig - explicit token from the patch row, when present.
 * @returns the token to enforce.
 */
function resolveToken(fromConfig: string | undefined): string {
  if (fromConfig !== undefined && fromConfig.length > 0) return fromConfig
  const env = process.env.DSH_MOBILE_TOKEN
  if (env !== undefined && env.length > 0) return env
  const file = statePath()
  try {
    const parsed = JSON.parse(readFileSync(file, 'utf8')) as Partial<MobileState>
    if (typeof parsed.token === 'string' && parsed.token.length >= 16) return parsed.token
  } catch {
    // No state yet, or unreadable: fall through and mint one.
  }
  const token = randomBytes(24).toString('base64url')
  // Merge, so minting a token never drops the pairing preferences beside it.
  writeState({ token })
  return token
}

/**
 * Append one request line; never let diagnostics break the listener.
 * @param file - absolute log path.
 * @param line - message body.
 */
async function record(file: string, line: string): Promise<void> {
  if (file.length === 0) return
  try {
    await mkdir(dirname(file), { recursive: true })
    await appendFile(file, `${new Date().toISOString()} pid=${String(process.pid)} ${line}\n`, 'utf8')
  } catch {
    // Diagnostics only.
  }
}

/** One session as the phone sees it. */
interface SessionRow {
  id: string
  title: string
  updatedAt: number
  cwd: string
  running: boolean
  archived: boolean
  pinned: boolean
  tokens: TokenUsage
  model: ModelRef | null
  agents: AgentSummary
}

interface TokenUsage {
  uncachedInputTokens: number
  outputTokens: number
  cacheReadTokens: number
  cacheWriteTokens: number
}

interface ModelRef {
  provider: string
  model: string
  reasoningEffort: string
}

interface SessionStats {
  turns: number
  steps: number
  toolCalls: number
  tokens: TokenUsage
}

interface AgentRef {
  id: string
  label: string
  mode: string
  createdAt: number
}

interface TeamTask {
  id: string
  subject: string
  status: string
  owner: string
}

interface AgentSummary {
  enabled: boolean
  tasks: TeamTask[]
  subagents: AgentRef[]
}

/** Subagent catalog and shared-task board both sit under `projections.values`. */
function agentsOf(values: Record<string, unknown> | undefined): AgentSummary {
  const catalog = (values?.subagentCatalog ?? []) as Array<Record<string, unknown>>
  const subagents: AgentRef[] = (Array.isArray(catalog) ? catalog : []).map((s) => ({
    id: String(s.id ?? ''),
    label: String(s.label ?? s.description ?? ''),
    mode: String(s.mode ?? ''),
    createdAt: Number(s.createdAt ?? 0) || 0,
  }))
  const team = (values?.agentTeam ?? {}) as Record<string, unknown>
  const rawTasks = (team.tasks ?? []) as Array<Record<string, unknown>>
  const tasks: TeamTask[] = (Array.isArray(rawTasks) ? rawTasks : []).map((t) => ({
    id: String(t.id ?? ''),
    subject: String(t.subject ?? t.title ?? ''),
    status: String(t.status ?? ''),
    owner: String(t.owner ?? ''),
  }))
  return { enabled: team.enabled === true, tasks, subagents }
}

/** Token counters live under `projections.values.tokenUsage`. */
function tokensOf(values: Record<string, unknown> | undefined): TokenUsage {
  const raw = (values?.tokenUsage ?? {}) as Record<string, unknown>
  const num = (v: unknown): number => {
    const n = Number(v ?? 0)
    return Number.isFinite(n) && n > 0 ? n : 0
  }
  return {
    uncachedInputTokens: num(raw.uncachedInputTokens),
    outputTokens: num(raw.outputTokens),
    cacheReadTokens: num(raw.cacheReadTokens),
    cacheWriteTokens: num(raw.cacheWriteTokens),
  }
}

/** The model a session would use next, under `projections.values.modelSelection`. */
function modelOf(values: Record<string, unknown> | undefined): ModelRef | null {
  const selection = (values?.modelSelection ?? {}) as Record<string, unknown>
  const next = (selection.next ?? selection.lastUsed ?? null) as Record<string, unknown> | null
  if (next === null || typeof next !== 'object') return null
  const provider = String(next.provider ?? '')
  const model = String(next.model ?? '')
  if (provider === '' || model === '') return null
  return { provider, model, reasoningEffort: String(next.reasoningEffort ?? '') }
}

/** Pull one raw list row's array container out of whatever shape arrived. */
function rowsOf(payload: unknown): unknown[] {
  if (Array.isArray(payload)) return payload
  if (payload !== null && typeof payload === 'object') {
    const items = (payload as { items?: unknown }).items
    if (Array.isArray(items)) return items
  }
  return []
}

/**
 * Project whatever `sessionController.list` returned onto the phone's shape.
 *
 * The controller does not use `id`: a row carries `sessionId`, and the title
 * lives under `projections.values.title` rather than on the row itself. Both
 * facts are easy to miss and silently produce an empty list, which is exactly
 * what the first version did.
 *
 * Rows are filtered the same way the console filters its own list: subagent
 * shells are not something a phone should be offered.
 * @param payload - raw list result.
 * @returns the rows to expose.
 */
/**
 * Decide which prompt mode to use for one session.
 *
 * `queue` is a no-op for an idle session — the controller parks the message in a
 * mailbox nothing drains — while `steer` starts a turn but can interrupt one
 * that is already running. So an idle session is always steered, and a running
 * one keeps whatever the caller asked for.
 *
 * @param ctl - session controller obtained from the plugin context.
 * @param sessionId - target session.
 * @param requested - mode the caller asked for.
 * @returns the effective mode plus what the list lookup established.
 */
async function pickMode(
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
    // A failed lookup must not fail the send: fall back to what the caller asked.
  }
  return { mode: running ? requested : 'steer', running, known }
}

/**
 * Best-effort "which preset is selected", mirroring what the desktop console
 * reads: the live reference first, then the registry config, then the settings
 * document. Any of them may be lazy, so every step is guarded.
 */
function presetCurrent(svc: Record<string, unknown>): string {
  const norm = (raw: unknown): string => {
    if (raw === null || raw === undefined) return ''
    if (typeof raw === 'function') return ''
    if (typeof raw === 'string') return raw
    if (typeof raw === 'number') return String(raw)
    if (typeof raw === 'object') {
      const o = raw as Record<string, unknown>
      return String(o.id ?? o.name ?? '')
    }
    return ''
  }
  try {
    const v = norm(svc.current ?? svc.selected)
    if (v !== '') return v
  } catch {
    // fall through
  }
  try {
    const v = norm(svc.defaultId)
    if (v !== '') return v
  } catch {
    // fall through
  }
  try {
    const cfg = svc.config as Record<string, unknown> | undefined
    if (cfg !== undefined && cfg !== null) {
      const raw = cfg.selectedDefault
      const v = norm(typeof (raw as { get?: () => unknown })?.get === 'function'
        ? (raw as { get: () => unknown }).get()
        : raw)
      if (v !== '') return v
      const d = norm(cfg.default)
      if (d !== '') return d
    }
  } catch {
    // fall through
  }
  return ''
}

/** Normalise the three shapes `agentPresets` may return into display rows. */
function presetRows(raw: unknown, currentId: string): Record<string, unknown>[] {
  let list: unknown[] = []
  if (Array.isArray(raw)) {
    list = raw
  } else if (raw !== null && typeof raw === 'object') {
    const o = raw as Record<string, unknown>
    if (Array.isArray(o.presets)) list = o.presets as unknown[]
    else if (Array.isArray(o.items)) list = o.items as unknown[]
  }
  const out: Record<string, unknown>[] = []
  for (const item of list) {
    if (item === null || typeof item !== 'object') continue
    const r = item as Record<string, unknown>
    const id = String(r.id ?? '')
    const name = String(r.name ?? '')
    if (id === '' && name === '') continue
    out.push({
      id,
      name: name === '' ? id : name,
      description: String(r.description ?? ''),
      isDefault: r.isDefault === undefined ? (currentId !== '' && id === currentId) : r.isDefault === true,
      broken: r.broken === undefined || r.broken === null ? '' : String(r.broken),
    })
  }
  return out
}

/** Sessions are addressed by id in the URL; the controller wants the row. */
function projectSessions(payload: unknown): SessionRow[] {
  const rows: SessionRow[] = []
  for (const item of rowsOf(payload)) {
    if (item === null || typeof item !== 'object') continue
    const s = item as Record<string, unknown>
    if (s.__blank === true) continue
    if (s.origin !== undefined && s.origin !== null && String(s.origin) === 'subagent') continue
    const id = String(s.sessionId ?? s.id ?? '')
    if (id.length === 0) continue
    const projections = s.projections as { values?: Record<string, unknown> } | undefined
    const projected = projections?.values?.title
    const title =
      typeof projected === 'string' && projected.length > 0
        ? projected
        : typeof s.title === 'string' && s.title.length > 0
          ? s.title
          : '(untitled)'
    const updated = Number(s.updatedAt ?? 0)
    const projectedValues = projections?.values as Record<string, unknown> | undefined
    rows.push({
      id,
      title,
      updatedAt: Number.isFinite(updated) ? updated : 0,
      cwd: String(s.cwd ?? ''),
      running: s.running === true,
      archived: false,
      tokens: tokensOf(projectedValues),
      model: modelOf(projectedValues),
      agents: agentsOf(projectedValues),
    })
  }
  rows.sort((a, b) => b.updatedAt - a.updatedAt)
  return rows
}

interface CatalogModel {
  id: string
  name: string
  description: string
  efforts: Array<{ id: string; name: string }>
  defaultEffort: string
}

interface CatalogGroup {
  id: string
  name: string
  models: CatalogModel[]
}

/**
 * 控制器把模型目录包在 value / catalog 里，同一台机器上还见过字符串形态，
 * 这里统一抹平成 UI 好渲染的形状。
 */
function normalizeCatalog(raw: unknown): {
  current: { provider: string; model: string; reasoningEffort: string } | null
  routable: boolean
  groups: CatalogGroup[]
  failures: Array<{ id: string; name: string; message: string }>
} {
  let value: unknown = raw
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value)
    } catch {
      value = null
    }
  }
  let v = (value ?? {}) as Record<string, unknown>
  if (v.value !== null && typeof v.value === 'object') v = v.value as Record<string, unknown>
  if (v.catalog !== null && typeof v.catalog === 'object') v = v.catalog as Record<string, unknown>

  const currentRaw = v.current as Record<string, unknown> | undefined
  const current =
    currentRaw !== null && typeof currentRaw === 'object'
      ? {
          provider: String(currentRaw.provider ?? ''),
          model: String(currentRaw.model ?? ''),
          reasoningEffort: String(currentRaw.reasoningEffort ?? ''),
        }
      : null

  const groups = ((v.groups ?? []) as Array<Record<string, unknown>>).map((g) => ({
    id: String(g.id ?? ''),
    name: String(g.name ?? g.id ?? ''),
    models: ((g.models ?? []) as Array<Record<string, unknown>>).map((m) => {
      const reasoning = (m.reasoning ?? {}) as Record<string, unknown>
      const efforts = ((reasoning.efforts ?? []) as Array<Record<string, unknown>>).map((e) => ({
        id: String(e.id ?? ''),
        name: String(e.name ?? e.id ?? ''),
      }))
      return {
        id: String(m.id ?? ''),
        name: String(m.name ?? m.id ?? ''),
        description: String(m.description ?? ''),
        efforts,
        defaultEffort: String(reasoning.defaultEffort ?? ''),
      }
    }),
  }))

  const failures = ((v.failures ?? []) as Array<Record<string, unknown>>).map((f) => ({
    id: String(f.id ?? ''),
    name: String(f.name ?? ''),
    message: String(f.message ?? ''),
  }))

  return { current, routable: v.routable !== false, groups, failures }
}

/** One chat row for the phone. */
interface ChatMessage {
  role: 'user' | 'assistant'
  text: string
  time: number
  seq: number
  /** Image parts this message carried; the phone fetches the bytes separately. */
  images?: ImageRef[]
}

/** One image part, resolved to the attachment object the host keeps on disk. */
interface ImageRef {
  id: string
  mediaType: string
  width: number
  height: number
  name: string
}

/**
 * `zlib.zstdDecompressSync` landed in Node 22.15/23.8. Reading it through a
 * narrow cast keeps the plugin loadable on an older host -- the history route
 * then answers 501 instead of taking the whole row down at import time.
 */
const zstdDecompressSync: ((buffer: Buffer) => Buffer) | undefined = (
  zlib as unknown as { zstdDecompressSync?: (buffer: Buffer) => Buffer }
).zstdDecompressSync

/** zstd frame magic; a session log is one frame appended per event. */
const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])

/** Refuse to walk a log past this size; the read is synchronous. */
const MAX_SESSION_BYTES = 160 * 1024 * 1024

/** Decoded history keyed by path, invalidated by size+mtime. */
const historyCache = new Map<
  string,
  { size: number; mtimeMs: number; messages: ChatMessage[]; stats: SessionStats }
>()

/**
 * Locate one session's log on disk.
 *
 * Layout is `<dsh home>/sessions/<project slug>/<id>/session.v4.jsonl.zstd`,
 * and the directory name is the session id exactly as the list reports it --
 * with the historical `session-` prefix present or absent depending on when
 * the session was created, so all spellings are tried.
 * @param id - session id from the list.
 * @returns absolute path, or null.
 */
function findSessionFile(id: string): string | null {
  const root = join(dshHome(), 'sessions')
  let projects: string[]
  try {
    projects = readdirSync(root)
  } catch {
    return null
  }
  const candidates = id.startsWith('session-') ? [id, id.slice('session-'.length)] : [id, `session-${id}`]
  for (const project of projects) {
    for (const name of candidates) {
      const file = join(root, project, name, 'session.v4.jsonl.zstd')
      try {
        if (statSync(file).isFile()) return file
      } catch {
        // Not this project; keep looking.
      }
    }
  }
  return null
}

/**
 * Decode a session log into its event lines.
 *
 * The log is not one compressed document: it is one zstd frame appended per
 * event, and Node's decompressor stops at the first frame boundary. Splitting
 * on the frame magic and decoding each slice is what makes the whole file
 * readable -- a 39 MB log is 19k frames.
 * @param file - absolute path.
 * @returns one JSON string per event line.
 */
function readSessionLines(file: string): string[] {
  if (zstdDecompressSync === undefined) throw new Error('this Node build has no zstd support')
  const size = statSync(file).size
  if (size > MAX_SESSION_BYTES) throw new Error(`session log is ${String(size)} bytes, over the safety cap`)
  const raw = readFileSync(file)
  const starts: number[] = []
  let cursor = 0
  while ((cursor = raw.indexOf(ZSTD_MAGIC, cursor)) !== -1) {
    starts.push(cursor)
    cursor += 4
  }
  if (starts.length === 0) return []
  const parts: Buffer[] = []
  for (let index = 0; index < starts.length; index += 1) {
    const from = starts[index]
    const to = index + 1 < starts.length ? starts[index + 1] : raw.length
    try {
      parts.push(zstdDecompressSync(raw.subarray(from, to)))
    } catch {
      // A torn tail frame is expected while the session is being written.
    }
  }
  return Buffer.concat(parts).toString('utf8').split('\n').filter((line) => line.length > 0)
}

/**
 * Last readable line of a session, without decoding the whole log.
 *
 * The list wants a one-line preview per row; decoding a 39 MB log per row is
 * not an option, so this reads only the tail window and decodes the frames that
 * start inside it. The first frame is usually torn by the seek, hence skipping
 * it.
 * @param file - absolute path of the session log.
 * @returns `{ preview, count }` where count covers the decoded tail only.
 */
function previewOf(file: string): { preview: string; count: number } {
  if (zstdDecompressSync === undefined) return { preview: '', count: 0 }
  let size = 0
  try {
    size = statSync(file).size
  } catch {
    return { preview: '', count: 0 }
  }
  const window = Math.min(size, 96 * 1024)
  if (window < 512) return { preview: '', count: 0 }
  const buf = Buffer.alloc(window)
  let fd: number | undefined
  try {
    fd = openSync(file, 'r')
    readSync(fd, buf, 0, window, size - window)
  } catch {
    return { preview: '', count: 0 }
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd)
      } catch {
        // Nothing useful to do if closing fails.
      }
    }
  }
  const starts: number[] = []
  let cursor = 0
  while ((cursor = buf.indexOf(ZSTD_MAGIC, cursor)) !== -1) {
    starts.push(cursor)
    cursor += 4
  }
  if (starts.length < 2) return { preview: '', count: 0 }
  const texts: string[] = []
  let count = 0
  for (let index = 1; index < starts.length; index += 1) {
    const from = starts[index]
    const to = index + 1 < starts.length ? starts[index + 1] : buf.length
    let decoded = ''
    try {
      decoded = zstdDecompressSync(buf.subarray(from, to)).toString('utf8')
    } catch {
      continue
    }
    for (const raw of decoded.split('\n')) {
      if (raw.length === 0) continue
      let ev: { type?: unknown; data?: { content?: unknown; message?: { content?: unknown } } }
      try {
        ev = JSON.parse(raw) as typeof ev
      } catch {
        continue
      }
      const kind = String(ev.type ?? '')
      if (kind !== 'user/message' && kind !== 'assistant/message') continue
      count += 1
      const content = kind === 'user/message' ? ev.data?.content : ev.data?.message?.content
      const text = textOf(content)
      if (text === '' || text.startsWith('<system-reminder>')) continue
      texts.push(text)
    }
  }
  const last = texts.length > 0 ? texts[texts.length - 1] : ''
  return { preview: plainPreview(last), count }
}

/**
 * Turn a message into one line of plain text for the session list.
 *
 * The list shows a summary, not rendered Markdown, so headings, bold markers,
 * code fences, table pipes and link syntax would otherwise leak into the card.
 * @param text - raw message text, Markdown included.
 * @returns a single flattened line, at most 90 characters.
 */
function plainPreview(text: string): string {
  const flat = text
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/^#{1,6}\s*/gm, '')
    .replace(/^>\s?/gm, '')
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/\*\*([^*]*)\*\*/g, '$1')
    .replace(/\|/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  return flat.slice(0, 90)
}

/** Concatenate the `text` parts of a content array, skipping reasoning. */function textOf(content: unknown): string {
  if (!Array.isArray(content)) return ''
  const out: string[] = []
  for (const part of content) {
    if (part === null || typeof part !== 'object') continue
    const p = part as { type?: unknown; text?: unknown }
    if (p.type === 'text' && typeof p.text === 'string') out.push(p.text)
  }
  return out.join('').trim()
}

/**
 * Pull the image parts out of a message.
 *
 * The host never inlines the bytes: a part carries
 * `attachment: { attachmentId: 'sha256:<hex>', mediaType, width, height, name }`
 * and the object lives under `<dsh home>/attachments/v1/objects/<ab>/<hex>`.
 * Keeping only the digest here means the transcript stays small; the bytes come
 * from the attachment route when the phone actually draws them.
 * @param content - the message's content parts.
 * @returns one ref per image part, in order.
 */
function imagesOf(content: unknown): ImageRef[] {
  if (!Array.isArray(content)) return []
  const out: ImageRef[] = []
  for (const part of content) {
    if (part === null || typeof part !== 'object') continue
    const p = part as { type?: unknown; attachment?: unknown }
    if (p.type !== 'image') continue
    const a = (p.attachment ?? {}) as Record<string, unknown>
    const raw = String(a.attachmentId ?? '')
    const id = raw.startsWith('sha256:') ? raw.slice('sha256:'.length) : raw
    if (!/^[0-9a-f]{8,128}$/i.test(id)) continue
    const width = Number(a.width ?? 0)
    const height = Number(a.height ?? 0)
    out.push({
      id: id.toLowerCase(),
      mediaType: String(a.mediaType ?? 'image/png'),
      width: Number.isFinite(width) && width > 0 ? width : 0,
      height: Number.isFinite(height) && height > 0 ? height : 0,
      name: String(a.name ?? ''),
    })
  }
  return out
}

/**
 * Build the chat transcript from a decoded session.
 *
 * Two facts drive the shaping: the assistant emits one `assistant/message` per
 * streaming update, so only the last one per (turn, step) is the finished
 * text; and `user/message` also carries injected system reminders, which are
 * not something a phone should show back.
 * @param file - absolute path.
 * @returns the transcript in order.
 */
function historyOf(file: string): { messages: ChatMessage[]; stats: SessionStats } {
  const stat = statSync(file)
  const cached = historyCache.get(file)
  if (cached !== undefined && cached.size === stat.size && cached.mtimeMs === stat.mtimeMs) {
    return { messages: cached.messages, stats: cached.stats }
  }

  const messages: ChatMessage[] = []
  const stepAt = new Map<string, number>()
  const stats: SessionStats = {
    turns: 0,
    steps: 0,
    toolCalls: 0,
    tokens: { uncachedInputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 },
  }
  for (const line of readSessionLines(file)) {
    let event: unknown
    try {
      event = JSON.parse(line)
    } catch {
      continue
    }
    if (event === null || typeof event !== 'object') continue
    const ev = event as Record<string, any>
    if (ev.type === 'turn/start') stats.turns += 1
    else if (ev.type === 'step/start') stats.steps += 1
    else if (ev.type === 'tool/call') stats.toolCalls += 1
    else if (ev.type === 'assistant/attempt') accumulateTokens(stats.tokens, ev.data)
    if (ev.type === 'user/message') {
      const source = ev.data?.source
      if (source !== undefined && source !== null && String(source.kind ?? 'user') !== 'user') continue
      const text = textOf(ev.data?.content)
      if (text.length === 0 || text.startsWith('<system-reminder>')) continue
      const images = imagesOf(ev.data?.content)
      const row: ChatMessage = { role: 'user', text, time: Number(ev.time ?? 0), seq: Number(ev.seq ?? 0) }
      if (images.length > 0) row.images = images
      messages.push(row)
      continue
    }
    if (ev.type === 'assistant/message') {
      const text = textOf(ev.data?.message?.content)
      if (text.length === 0) continue
      const row: ChatMessage = {
        role: 'assistant',
        text,
        time: Number(ev.time ?? 0),
        seq: Number(ev.seq ?? 0),
      }
      const key = `${String(ev.data?.turn ?? '')}:${String(ev.data?.step ?? '')}`
      const at = stepAt.get(key)
      if (at !== undefined) messages[at] = row
      else {
        stepAt.set(key, messages.length)
        messages.push(row)
      }
    }
  }
  historyCache.set(file, { size: stat.size, mtimeMs: stat.mtimeMs, messages, stats })
  return { messages, stats }
}

/** Fold one attempt's usage counters into the running totals, if it carries any. */
function accumulateTokens(total: TokenUsage, data: unknown): void {
  if (data === null || typeof data !== 'object') return
  const usage = ((data as Record<string, unknown>).usage ?? data) as Record<string, unknown>
  const num = (v: unknown): number => {
    const n = Number(v ?? 0)
    return Number.isFinite(n) && n > 0 ? n : 0
  }
  total.uncachedInputTokens += num(usage.inputTokens ?? usage.uncachedInputTokens)
  total.outputTokens += num(usage.outputTokens)
  total.cacheReadTokens += num(usage.cacheReadTokens ?? usage.cachedInputTokens)
  total.cacheWriteTokens += num(usage.cacheWriteTokens)
}

/** Every non-internal IPv4 address plus global IPv6, so the operator can see the phone URL. */
function lanAddresses(): string[] {
  const out: string[] = []
  const nets = networkInterfaces()
  for (const entries of Object.values(nets)) {
    if (entries === undefined) continue
    for (const entry of entries) {
      if (entry.internal) continue
      const v4 = entry.family === 'IPv4' || entry.family === 4
      const v6 = entry.family === 'IPv6' || entry.family === 6
      if (v4) {
        out.push(entry.address)
        continue
      }
      if (v6 && !entry.address.startsWith('fe80')) out.push(entry.address)
    }
  }
  return out
}

/** Render a host:port pair with the brackets an IPv6 literal needs in a URL. */
function hostPort(address: string, port: number): string {
  return address.includes(':') ? `[${address}]:${String(port)}` : `${address}:${String(port)}`
}

/**
 * Whether the caller reached us on a LAN-style address.
 *
 * Classification uses the Host header, not the socket peer: a Cloudflare tunnel
 * forwards from 127.0.0.1, so every remote request would otherwise look local
 * and the "allow remote" switch would gate nothing. A missing Host counts as
 * local (curl on this machine, health checks).
 */
function isLocalHostHeader(host: string | undefined): boolean {
  if (typeof host !== 'string' || host.length === 0) return true
  const bracketed = host.startsWith('[') ? host.slice(1, host.indexOf(']') >= 0 ? host.indexOf(']') : undefined) : ''
  const bare = bracketed !== '' ? bracketed : (host.split(':')[0] ?? '')
  if (bare === 'localhost' || bare === '127.0.0.1' || bare === '::1' || bare === '0.0.0.0') return true
  if (bare.includes(':')) return /^f[cd]/i.test(bare) || /^fe80/i.test(bare)
  const parts = bare.split('.').map((part) => Number.parseInt(part, 10))
  if (parts.length !== 4) return false
  if (parts.some((part) => !Number.isFinite(part))) return false
  const a = parts[0] as number
  const b = parts[1] as number
  if (a === 127) return true
  if (a === 10) return true
  if (a === 192 && b === 168) return true
  if (a === 172 && b >= 16 && b <= 31) return true
  return false
}

/**
 * Order LAN candidates by how likely a phone on the same Wi-Fi can use them.
 *
 * A laptop typically has several adapters; Docker, WSL, VirtualBox and QEMU
 * create host-only networks that no phone can reach. They still work as copyable
 * text, but they must not become the address baked into the QR code.
 */
function lanRank(address: string): number {
  if (address.includes(':')) return 9
  if (address.startsWith('192.168.')) return address.startsWith('192.168.56.') ? 6 : 0
  if (address.startsWith('10.')) return address.startsWith('10.0.2.') ? 7 : 1
  if (address.startsWith('172.')) {
    const second = Number.parseInt(address.split('.')[1] ?? '', 10)
    return second >= 16 && second <= 31 ? 5 : 2
  }
  return 3
}

/** Constant-time comparison that tolerates a length mismatch. */
function tokenMatches(given: string, expected: string): boolean {
  if (given.length === 0 || expected.length === 0) return false
  const a = Buffer.from(given, 'utf8')
  const b = Buffer.from(expected, 'utf8')
  if (a.length !== b.length) return false
  return timingSafeEqual(a, b)
}

/** Pull the caller's token out of the Authorization header or `?t=`. */
function presentedToken(req: IncomingMessage, url: URL): string {
  const header = req.headers.authorization
  if (typeof header === 'string' && header.toLowerCase().startsWith('bearer ')) {
    return header.slice(7).trim()
  }
  const query = url.searchParams.get('t')
  return query === null ? '' : query.trim()
}

/** Read and JSON-parse a bounded request body. */
async function readJson(req: IncomingMessage, limit: number = MAX_BODY_BYTES): Promise<Record<string, unknown>> {
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

/**
 * Internals exposed for out-of-process verification of the pure parts
 * (projection and log decoding) against this machine's real files, without
 * having to restart the host to exercise a route.
 */
export const internals = { projectSessions, findSessionFile, historyOf }

/**
 * Mount the listener for as long as this row is mounted.
 * @param ctx - plugin context, used for the service lookup and the lifecycle effect.
 * @param rawConfig - deployment configuration from the profile patch row.
 */
export function apply(ctx: any, rawConfig?: Config): void {
  const enabled = rawConfig?.enabled !== false
  const port = rawConfig?.port ?? DEFAULT_PORT
  const host = rawConfig?.host ?? '::'
  const logFile = rawConfig?.logFile ?? join(dshHome(), 'dsh-mobile.log')
  const token = enabled ? resolveToken(rawConfig?.token) : ''

  if (!enabled) return

  /** Live pairing code: minted lazily, consumed on claim, rotated on demand. */
  let pairCode: PairCode | null = null
  /** Last authenticated request, which is how the panel knows the phone is there. */
  let phoneSeenAt = 0
  /** Wrong-claim counters per peer; a coarse throttle, not an account lock. */
  const pairFails = new Map<string, { n: number; until: number }>()

  /** The current code, extending it when it expired. */
  const ensurePair = (): PairCode => {
    if (pairCode === null || pairCode.expiresAt <= Date.now()) {
      pairCode = { code: freshPairCode(), expiresAt: Date.now() + PAIR_TTL_MS }
      void record(logFile, `pair code minted ttl=${String(PAIR_TTL_MS)}`)
    }
    return pairCode
  }

  /** Throw the current code away and mint a fresh one. */
  const rotatePair = (): PairCode => {
    pairCode = { code: freshPairCode(), expiresAt: Date.now() + PAIR_TTL_MS }
    void record(logFile, 'pair code rotated')
    return pairCode
  }

  /**
   * LAN base URLs a phone on the same network can dial.
   *
   * IPv4 comes first on purpose: a phone gets an IPv4 address from the router,
   * and an IPv6 literal in a QR code is both fragile to type and often
   * unreachable from another device's stack even on the same Wi-Fi.
   */
  const lanBases = (): string[] => {
    const all = lanAddresses()
    const v6 = all.filter((address) => address.includes(':') && !/^f[cd]/.test(address))
    const v4 = all.filter((address) => !address.includes(':')).sort((left, right) => lanRank(left) - lanRank(right))
    return [...v4, ...v6].map((address) => `http://${hostPort(address, port)}`)
  }

  /** Everything the panel and the phone's setup screen show, minus the token. */
  const pairState = (): Record<string, unknown> => {
    const prefs = pairPrefs()
    const pending = ensurePair()
    const lan = lanBases()
    return {
      ok: true,
      host: hostname(),
      version: VERSION,
      port,
      code: pending.code,
      expiresAt: pending.expiresAt,
      allowLan: prefs.allowLan,
      allowRemote: prefs.allowRemote,
      publicUrl: prefs.publicUrl,
      lan,
      /** Base URL a QR should carry right now: LAN first, then the tunnel. */
      base: prefs.allowLan && lan.length > 0 ? (lan[0] as string) : prefs.publicUrl,
      phoneSeenAt,
      phoneOnline: phoneSeenAt > 0 && Date.now() - phoneSeenAt < PHONE_ONLINE_MS,
      sessions: true,
    }
  }

  /** Resolve the controller per request: a later mount must be visible here. */
  const controller = (): any => {
    try {
      return ctx.get('sessionController')
    } catch {
      return undefined
    }
  }

  /** Resolve an optional host service; a missing row is `null`, not an error. */
  const service = (name: string): any => {
    try {
      const found: unknown = ctx.get(name)
      return found === undefined ? null : found
    } catch {
      return null
    }
  }

  /**
   * Sessions the host keeps in its archive. `ctl.list` does not carry that
   * flag, so the registry's set is the only place it lives; `null` means the
   * host has no such set and callers must not hide anything.
   */
  const archivedIds = (): string[] | null => {
    const reg = service('workspaceRegistry')
    if (reg === null) return null
    try {
      const raw = reg.archivedSessionIds
      if (Array.isArray(raw)) return raw.map((x: unknown) => String(x)).filter(Boolean)
      if (raw && typeof raw.has === 'function' && typeof raw.size === 'number') {
        return Array.from(raw as Iterable<unknown>, (x) => String(x)).filter(Boolean)
      }
      return null
    } catch {
      return null
    }
  }

  /** Stamp the archive flag onto rows the controller handed us. */
  const markArchived = (rows: SessionRow[]): SessionRow[] => {
    const set = archivedIds()
    if (set === null) return rows
    const lookup = new Set(set)
    return rows.map((row) => ({ ...row, archived: lookup.has(row.id) }))
  }

  /** Sessions the host keeps pinned to the top of its own list. */
  const pinnedIds = (): string[] | null => {
    const reg = service('workspaceRegistry')
    if (reg === null) return null
    try {
      const raw = reg.pinnedSessionIds
      if (Array.isArray(raw)) return raw.map((x: unknown) => String(x)).filter(Boolean)
      if (raw && typeof raw.has === 'function' && typeof raw.size === 'number') {
        return Array.from(raw as Iterable<unknown>, (x) => String(x)).filter(Boolean)
      }
      return null
    } catch {
      return null
    }
  }

  /** Stamp the pin flag onto rows the controller handed us. */
  const markPinned = (rows: SessionRow[]): SessionRow[] => {
    const set = pinnedIds()
    if (set === null) return rows
    const lookup = new Set(set)
    return rows.map((row) => ({ ...row, pinned: lookup.has(row.id) }))
  }

  const send = (res: ServerResponse, status: number, body: unknown): void => {
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

  /**
   * The phone UI lives in `web/` next to the built `lib/`, deliberately as
   * plain files: editing them takes effect on the next reload, without
   * rebuilding this row or restarting the host.
   */
  const WEB_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', 'web')
  const MIME: Record<string, string> = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.json': 'application/json; charset=utf-8',
    '.woff2': 'font/woff2',
  }

  /** Serve one file under `web/`, refusing anything that escapes it. */
  const serveStatic = (res: ServerResponse, relative: string): void => {
    const target = normalize(join(WEB_ROOT, relative))
    if (!target.startsWith(WEB_ROOT)) {
      send(res, 403, { error: 'forbidden' })
      return
    }
    let body: Buffer
    try {
      body = readFileSync(target)
    } catch {
      send(res, 404, { error: 'not found', path: relative })
      return
    }
    res.writeHead(200, {
      'content-type': MIME[extname(target)] ?? 'application/octet-stream',
      'content-length': String(body.length),
      'cache-control': 'no-store',
    })
    res.end(body)
  }

  const handle = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const started = Date.now()
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)
    const path = url.pathname
    const method = req.method ?? 'GET'

    if (method === 'OPTIONS') {
      send(res, 204, '')
      return
    }

    // Unauthenticated liveness probe: it reveals nothing beyond the fact that
    // the row is mounted, and it is what a phone uses to find the server.
    if (path === '/health') {
      send(res, 200, { ok: true, name: 'dsh-mobile', version: VERSION, pid: process.pid, host: hostname() })
      return
    }

    // Pairing handshake: the one place a phone may talk to the host without a
    // token. It is deliberately narrow — it hands out the token only for a live
    // single-use six-digit code, and a peer that keeps guessing gets throttled.
    if (path === '/api/pair/info') {
      const prefs = pairPrefs()
      send(res, 200, {
        ok: true,
        name: 'dsh-mobile',
        version: VERSION,
        host: hostname(),
        port,
        lan: prefs.allowLan ? lanBases() : [],
        publicUrl: prefs.publicUrl,
        needCode: true,
      })
      return
    }

    if (path === '/api/pair/claim' && method === 'POST') {
      const peer = req.socket.remoteAddress ?? '?'
      const prefs = pairPrefs()
      if (!prefs.allowLan && !prefs.allowRemote) {
        send(res, 403, { error: 'pairing is off', hint: 'turn 允许连接 on in the DSH panel' })
        return
      }
      // Gate on the entry the caller actually used: a tunnel request arrives
      // from 127.0.0.1, so the peer address cannot tell LAN from remote.
      const local = isLocalHostHeader(req.headers.host)
      if (local && !prefs.allowLan) {
        send(res, 403, { error: 'lan pairing is off', hint: 'turn 局域网直连 on in the DSH panel' })
        return
      }
      if (!local && !prefs.allowRemote) {
        send(res, 403, { error: 'remote pairing is off', hint: 'turn 公网访问 on in the DSH panel' })
        return
      }
      const now = Date.now()
      const gate = pairFails.get(peer)
      if (gate !== undefined && gate.until > now) {
        send(res, 429, { error: 'too many wrong codes', retryAt: gate.until })
        return
      }
      // Reserve the attempt before awaiting the body. Reading it first lets
      // concurrent guesses all observe the same count and register as one.
      const expired = gate !== undefined && gate.until !== 0 && gate.until <= now
      const attempt = gate === undefined || expired ? { n: 1, until: 0 } : { n: gate.n + 1, until: 0 }
      pairFails.set(peer, attempt)
      let body: Record<string, unknown>
      try {
        body = await readJson(req)
      } catch {
        send(res, 400, { error: 'body must be a JSON object' })
        return
      }
      const given = String(body.code ?? '').trim()
      const pending = ensurePair()
      if (given.length !== 6 || !tokenMatches(given, pending.code)) {
        const next = { n: attempt.n, until: attempt.n >= PAIR_FAIL_LIMIT ? Date.now() + PAIR_LOCK_MS : 0 }
        pairFails.set(peer, next)
        await record(logFile, `401 PAIR claim bad code from ${peer} n=${String(next.n)}`)
        send(res, 401, {
          error: 'wrong code',
          code: 'bad-code',
          left: Math.max(0, PAIR_FAIL_LIMIT - next.n),
        })
        return
      }
      // The base the phone just used is the one it should keep using, so the
      // caller's own Host header wins over anything we would guess.
      const headerHost = req.headers.host
      const forwarded = req.headers['x-forwarded-proto']
      const scheme = typeof forwarded === 'string' && forwarded.toLowerCase() === 'https' ? 'https' : 'http'
      const base =
        typeof headerHost === 'string' && headerHost.length > 0
          ? `${scheme}://${headerHost}`
          : (lanBases()[0] ?? `http://127.0.0.1:${String(port)}`)
      rotatePair()
      pairFails.delete(peer)
      phoneSeenAt = Date.now()
      await record(logFile, `200 PAIR claim base=${base} from ${peer} local=${String(local)}`)
      send(res, 200, {
        ok: true,
        token,
        base,
        host: hostname(),
        version: VERSION,
        port,
        lan: prefs.allowLan ? lanBases() : [],
        qr: pairPayload(base, pairCode?.code ?? ''),
      })
      return
    }

    if (!tokenMatches(presentedToken(req, url), token)) {
      await record(logFile, `401 ${method} ${path} from ${req.socket.remoteAddress ?? '?'}`)
      send(res, 401, { error: 'unauthorized', hint: 'send Authorization: Bearer <token>, or ?t=<token>' })
      return
    }

    phoneSeenAt = Date.now()

    // A switched-off entry must stop an already-paired phone too, otherwise the
    // panel's switch is decorative. Classification is by Host so the tunnel,
    // which arrives from 127.0.0.1, still counts as remote.
    {
      const prefs = pairPrefs()
      const local = isLocalHostHeader(req.headers.host)
      if (local && !prefs.allowLan) {
        send(res, 403, { error: 'lan access is off', hint: 'turn 局域网直连 on in the DSH panel' })
        return
      }
      if (!local && !prefs.allowRemote) {
        send(res, 403, { error: 'remote access is off', hint: 'turn 公网访问 on in the DSH panel' })
        return
      }
    }

    try {
      if (path === '/' || path === '/index.html') {
        serveStatic(res, 'index.html')
        return
      }

      if (path.startsWith('/app/')) {
        serveStatic(res, path.slice('/app/'.length))
        return
      }

      if (path === '/api/info') {
        send(res, 200, {
          ok: true,
          version: VERSION,
          host: hostname(),
          addresses: lanAddresses(),
          port,
          sessions: true,
          messages: zstdDecompressSync !== undefined,
          send: true,
          stop: true,
          create: true,
          rename: true,
          pin: true,
          images: true,
          files: true,
          attachments: true,
        })
        return
      }

      // Pairing state for an already-paired phone: shows the live code so the
      // app can act as a second screen for the panel, and lets the phone flip
      // the two switches the panel also drives.
      if (path === '/api/pair/state' && method === 'GET') {
        send(res, 200, pairState())
        return
      }

      if (path === '/api/pair/newcode' && method === 'POST') {
        rotatePair()
        send(res, 200, pairState())
        return
      }

      if (path === '/api/pair/config' && method === 'POST') {
        const body = await readJson(req)
        const current = pairPrefs()
        const next: PairPrefs = {
          allowLan: typeof body.allowLan === 'boolean' ? body.allowLan : current.allowLan,
          allowRemote: typeof body.allowRemote === 'boolean' ? body.allowRemote : current.allowRemote,
          publicUrl: typeof body.publicUrl === 'string' ? body.publicUrl.trim() : current.publicUrl,
        }
        writeState({ pair: next })
        await record(logFile, `200 PAIR config lan=${String(next.allowLan)} remote=${String(next.allowRemote)}`)
        send(res, 200, pairState())
        return
      }

      // Images a message carried. The transcript only carries the digest, so
      // the phone pulls the bytes here and caches them itself. Auth is the same
      // bearer token (or ?t=), because <Image> on the phone cannot set headers.
      if (path.startsWith('/api/attachments/') && method === 'GET') {
        const digest = path.slice('/api/attachments/'.length).toLowerCase()
        if (!/^[0-9a-f]{8,128}$/.test(digest)) {
          send(res, 400, { error: 'bad attachment id' })
          return
        }
        const file = join(homedir(), '.dsh', 'attachments', 'v1', 'objects', digest.slice(0, 2), digest)
        let body: Buffer
        try {
          body = readFileSync(file)
        } catch {
          send(res, 404, { error: 'attachment not found', id: digest })
          return
        }
        const asked = String(url.searchParams.get('m') ?? '')
        const type =
          asked === 'image/jpeg' || asked === 'image/webp' || asked === 'image/gif' || asked === 'image/png'
            ? asked
            : 'image/png'
        res.writeHead(200, {
          'content-type': type,
          'content-length': String(body.length),
          'cache-control': 'private, max-age=86400',
        })
        res.end(body)
        return
      }

      // Shape probe: a list that comes back empty has three very different
      // causes (no controller, a different container field, a different id
      // field) and this separates them without another restart.
      if (path === '/api/debug/raw' && method === 'GET') {
        const ctl = controller()
        if (!ctl || typeof ctl.list !== 'function') {
          send(res, 503, { error: 'sessionController unavailable' })
          return
        }
        const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(15000)))
        const rows = rowsOf(listed)
        const first = rows[0]
        send(res, 200, {
          ok: true,
          container: Array.isArray(listed) ? 'array' : typeof listed,
          containerKeys:
            listed !== null && typeof listed === 'object' && !Array.isArray(listed) ? Object.keys(listed) : [],
          count: rows.length,
          firstRowKeys: first !== null && typeof first === 'object' ? Object.keys(first) : [],
          firstRow: first ?? null,
        })
        return
      }

      if (path === '/api/sessions/previews' && method === 'GET') {
      const ids = (url.searchParams.get('ids') ?? '')
        .split(',')
        .map((s) => s.trim())
        .filter((s) => s.length > 0)
        .slice(0, 60)
      const previews: { id: string; preview: string; count: number }[] = []
      for (const id of ids) {
        const file = findSessionFile(id)
        if (file === null) continue
        try {
          const one = previewOf(file)
          if (one.preview !== '') previews.push({ id, preview: one.preview, count: one.count })
        } catch {
          // A session that cannot be read simply has no preview.
        }
      }
      send(res, 200, { ok: true, previews })
      return
    }

    if (path === '/api/sessions' && method === 'GET') {
        const ctl = controller()
        if (!ctl || typeof ctl.list !== 'function') {
          send(res, 503, { error: 'sessionController unavailable', hint: 'is the DSH host fully started?' })
          return
        }
        const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(15000)))
        send(res, 200, { ok: true, sessions: markPinned(markArchived(projectSessions(listed))) })
        return
      }

      const historyMatch = /^\/api\/sessions\/([^/]+)\/messages$/.exec(path)
      if (historyMatch !== null && method === 'GET') {
        const sessionId = decodeURIComponent(historyMatch[1])
        if (zstdDecompressSync === undefined) {
          send(res, 501, { error: 'this Node build has no zstd support' })
          return
        }
        const file = findSessionFile(sessionId)
        if (file === null) {
          send(res, 404, { error: 'session log not found', sessionId })
          return
        }
        const raw = Number(url.searchParams.get('limit') ?? '30')
        const limit = Number.isFinite(raw) ? Math.min(Math.max(Math.trunc(raw), 1), 200) : 30
        // 手机端每几秒轮询一次，让它只取增量：带上 since=<最后一条的 seq>，
        // 返回里就只有比它新的消息，流量从几十 KB 降到几百字节。
        const sinceRaw = Number(url.searchParams.get('since') ?? '0')
        const since = Number.isFinite(sinceRaw) ? Math.max(Math.trunc(sinceRaw), 0) : 0
        // 往上看历史：before=<已知最早一条的 seq>，返回比它更早的一页。
        // 手机端一次只拿最近 60 条，向上翻时才补更早的，避免一次拖 2000 多条。
        const beforeRaw = Number(url.searchParams.get('before') ?? '0')
        const before = Number.isFinite(beforeRaw) ? Math.max(Math.trunc(beforeRaw), 0) : 0
        const { messages: all, stats } = historyOf(file)
        let tokens = stats.tokens
        let running = false
        const ctl = controller()
        if (ctl && typeof ctl.list === 'function') {
          try {
            const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(8000)))
            const row = projectSessions(listed).find((r) => r.id === sessionId)
            if (row !== undefined) {
              tokens = row.tokens
              running = row.running === true
            }
          } catch {
            /* token counters are decorative; keep the event-derived fallback */
          }
        }
        const page = since > 0
          ? all.filter((m) => m.seq > since).slice(0, 200)
          : before > 0
            ? all.filter((m) => m.seq < before).slice(-limit)
            : all.slice(-limit)
        send(res, 200, {
          ok: true,
          sessionId,
          total: all.length,
          firstSeq: all.length > 0 ? all[0].seq : 0,
          messages: page,
          stats: { ...stats, tokens },
          running,
        })
        return
      }

      const modelsMatch = /^\/api\/models$/.exec(path)
      if (modelsMatch !== null && method === 'GET') {
        const ctl = controller()
        if (!ctl || typeof ctl.modelCatalog !== 'function') {
          send(res, 503, { error: 'sessionController.modelCatalog unavailable' })
          return
        }
        const sessionId = url.searchParams.get('sessionId') ?? ''
        if (sessionId === '') {
          send(res, 400, { error: 'sessionId is required' })
          return
        }
        const catalog = await Promise.resolve(ctl.modelCatalog({ sessionId }, AbortSignal.timeout(15000)))
        send(res, 200, { ok: true, sessionId, catalog: normalizeCatalog(catalog) })
        return
      }

      const modelMatch = /^\/api\/sessions\/([^/]+)\/model$/.exec(path)
      if (modelMatch !== null && method === 'POST') {
        const ctl = controller()
        if (!ctl || typeof ctl.selectModel !== 'function') {
          send(res, 503, { error: 'sessionController.selectModel unavailable' })
          return
        }
        const body = await readJson(req)
        const provider = String(body.provider ?? '').trim()
        const model = String(body.model ?? '').trim()
        if (provider === '' || model === '') {
          send(res, 400, { error: 'provider and model are required' })
          return
        }
        const args: Record<string, unknown> = {
          sessionId: decodeURIComponent(modelMatch[1]),
          provider,
          model,
        }
        const effort = String(body.reasoningEffort ?? '').trim()
        if (effort !== '') args.reasoningEffort = effort
        const result = await Promise.resolve(ctl.selectModel(args, AbortSignal.timeout(20000)))
        await record(logFile, `200 POST model provider=${provider} model=${model} effort=${effort}`)
        send(res, 200, { ok: true, result: result ?? null })
        return
      }

      const stopMatch = /^\/api\/sessions\/([^/]+)\/stop$/.exec(path)
      if (stopMatch !== null && method === 'POST') {
        const ctl = controller()
        if (!ctl || typeof ctl.cancel !== 'function') {
          send(res, 503, { error: 'sessionController.cancel unavailable' })
          return
        }
        const sessionId = decodeURIComponent(stopMatch[1])
        const result: unknown = await Promise.resolve(ctl.cancel({ sessionId }))
        let raw: unknown = result
        if (typeof raw === 'string') {
          try { raw = JSON.parse(raw) as unknown } catch { raw = null }
        }
        let accepted = false
        if (raw !== null && typeof raw === 'object') {
          accepted = (raw as Record<string, unknown>).accepted === true
        }
        await record(logFile, `200 POST stop session=${sessionId} accepted=${accepted}`)
        send(res, 200, { ok: true, accepted, result: result ?? null })
        return
      }

      const archiveMatch = /^\/api\/sessions\/([^/]+)\/archive$/.exec(path)
      if (archiveMatch !== null && method === 'POST') {
        const sessionId = decodeURIComponent(archiveMatch[1])
        const ctl = controller()
        const reg = service('workspaceRegistry')
        let cancelledFirst = false
        try {
          if (ctl && typeof ctl.archive === 'function') {
            await Promise.resolve(ctl.archive({ sessionId }))
          } else if (reg && typeof reg.archiveSession === 'function') {
            await Promise.resolve(reg.archiveSession(sessionId))
          } else {
            send(res, 503, { error: 'archiving is unavailable on this host' })
            return
          }
        } catch (err) {
          // The host refuses to archive a session that still owns a turn; the
          // console stops it first, so mirror that instead of failing.
          const message = err instanceof Error ? err.message : String(err)
          if (/active|running|busy/i.test(message) && ctl && typeof ctl.cancel === 'function') {
            await Promise.resolve(ctl.cancel({ sessionId }))
            cancelledFirst = true
            if (typeof ctl.archive === 'function') await Promise.resolve(ctl.archive({ sessionId }))
            else if (reg && typeof reg.archiveSession === 'function') await Promise.resolve(reg.archiveSession(sessionId))
          } else {
            throw err
          }
        }
        await record(logFile, `200 POST archive session=${sessionId} cancelledFirst=${cancelledFirst}`)
        send(res, 200, { ok: true, sessionId, archived: true, cancelledFirst })
        return
      }

      const unarchiveMatch = /^\/api\/sessions\/([^/]+)\/unarchive$/.exec(path)
      if (unarchiveMatch !== null && method === 'POST') {
        const sessionId = decodeURIComponent(unarchiveMatch[1])
        const ctl = controller()
        const reg = service('workspaceRegistry')
        const wc = service('workspaceController')
        const attempts: Array<{ who: string; run: () => Promise<unknown> }> = []
        if (ctl && typeof ctl.unarchive === 'function') {
          attempts.push({ who: 'sessionController.unarchive', run: () => Promise.resolve(ctl.unarchive({ sessionId })) })
        }
        if (reg && typeof reg.unarchiveSession === 'function') {
          attempts.push({ who: 'workspaceRegistry.unarchiveSession', run: () => Promise.resolve(reg.unarchiveSession(sessionId)) })
        }
        if (wc && typeof wc.unarchiveSession === 'function') {
          attempts.push({ who: 'workspaceController.unarchiveSession', run: () => Promise.resolve(wc.unarchiveSession(sessionId)) })
        }
        if (attempts.length === 0) {
          send(res, 503, { error: 'unarchiving is unavailable on this host' })
          return
        }
        let lastError = ''
        for (const attempt of attempts) {
          try {
            await attempt.run()
            await record(logFile, `200 POST unarchive session=${sessionId} via=${attempt.who}`)
            send(res, 200, { ok: true, sessionId, archived: false, via: attempt.who })
            return
          } catch (err) {
            lastError = err instanceof Error ? err.message : String(err)
          }
        }
        send(res, 500, { error: `unarchive failed: ${lastError}` })
        return
      }

      const pinMatch = /^\/api\/sessions\/([^/]+)\/pin$/.exec(path)
      if (pinMatch !== null && method === 'POST') {
        const sessionId = decodeURIComponent(pinMatch[1])
        const body = await readJson(req)
        const want = body.pinned === undefined ? true : body.pinned === true
        const ctl = controller()
        const reg = service('workspaceRegistry')
        const anyCtl = ctl as unknown as Record<string, ((arg: unknown) => unknown) | undefined> | null
        const anyReg = reg as unknown as Record<string, ((arg: unknown) => unknown) | undefined> | null
        const attempts: Array<{ who: string; run: () => Promise<unknown> }> = []
        const ctlFn = anyCtl === null ? undefined : anyCtl[want ? 'pin' : 'unpin']
        if (typeof ctlFn === 'function') {
          attempts.push({
            who: `sessionController.${want ? 'pin' : 'unpin'}`,
            run: () => Promise.resolve(ctlFn.call(ctl, { sessionId })),
          })
        }
        const regFn = anyReg === null ? undefined : anyReg[want ? 'pinSession' : 'unpinSession']
        if (typeof regFn === 'function') {
          attempts.push({
            who: `workspaceRegistry.${want ? 'pinSession' : 'unpinSession'}`,
            run: () => Promise.resolve(regFn.call(reg, sessionId)),
          })
        }
        if (attempts.length === 0) {
          send(res, 503, { error: 'pinning is unavailable on this host' })
          return
        }
        let lastError = ''
        for (const attempt of attempts) {
          try {
            await attempt.run()
            await record(logFile, `200 POST pin session=${sessionId} pinned=${String(want)} via=${attempt.who}`)
            send(res, 200, { ok: true, sessionId, pinned: want, via: attempt.who, ids: pinnedIds() ?? [] })
            return
          } catch (err) {
            lastError = err instanceof Error ? err.message : String(err)
          }
        }
        send(res, 500, { error: `pin failed: ${lastError}` })
        return
      }

      if (path === '/api/sessions' && method === 'POST') {        const ctl = controller()
        if (!ctl || typeof ctl.create !== 'function') {
          send(res, 503, { error: 'sessionController.create unavailable' })
          return
        }
        const body = await readJson(req)
        const cwd = String(body.cwd ?? '').trim()
        const args: Record<string, unknown> = {}
        if (cwd !== '') args.cwd = cwd
        const created: unknown = await Promise.resolve(ctl.create(args))
        let raw: unknown = created
        if (typeof raw === 'string') {
          try { raw = JSON.parse(raw) as unknown } catch { raw = null }
        }
        let sessionId = ''
        if (raw !== null && typeof raw === 'object') {
          const row = raw as Record<string, unknown>
          sessionId = String(row.sessionId ?? row.id ?? '')
        }
        await record(logFile, `200 POST create session=${sessionId}`)
        send(res, 200, { ok: true, sessionId, result: created ?? null })
        return
      }

      const renameMatch = /^\/api\/sessions\/([^/]+)$/.exec(path)
      if (renameMatch !== null && method === 'PATCH') {
        const ctl = controller()
        if (!ctl || typeof ctl.rename !== 'function') {
          send(res, 503, { error: 'sessionController.rename unavailable' })
          return
        }
        const body = await readJson(req)
        const title = String(body.title ?? '').trim()
        if (title === '') {
          send(res, 400, { error: 'title is empty' })
          return
        }
        const sessionId = decodeURIComponent(renameMatch[1])
        await Promise.resolve(ctl.rename({ sessionId, title }))
        await record(logFile, `200 PATCH rename session=${sessionId} title=${title}`)
        send(res, 200, { ok: true, sessionId, title })
        return
      }

      const imagesMatch = /^\/api\/sessions\/([^/]+)\/images$/.exec(path)
      if (imagesMatch !== null && method === 'POST') {
        const ctl = controller()
        if (!ctl || typeof ctl.prompt !== 'function') {
          send(res, 503, { error: 'sessionController.prompt unavailable' })
          return
        }
        const body = await readJson(req, MAX_UPLOAD_BYTES)
        const raw = Array.isArray(body.images) ? body.images : []
        if (raw.length === 0) {
          send(res, 400, { error: 'images is empty' })
          return
        }
        if (raw.length > MAX_IMAGES) {
          send(res, 400, { error: `at most ${String(MAX_IMAGES)} images per request` })
          return
        }
        const parts: Record<string, unknown>[] = []
        let bytes = 0
        for (const item of raw) {
          if (item === null || typeof item !== 'object') {
            send(res, 400, { error: 'each image must be an object' })
            return
          }
          const img = item as Record<string, unknown>
          const mediaType = String(img.mediaType ?? '').toLowerCase()
          if (!IMAGE_TYPES.has(mediaType)) {
            send(res, 400, { error: `unsupported image type: ${mediaType}`, allowed: [...IMAGE_TYPES] })
            return
          }
          const data = String(img.data ?? '')
          if (data.length === 0) {
            send(res, 400, { error: 'image data is empty' })
            return
          }
          bytes += Math.floor((data.length * 3) / 4)
          const part: Record<string, unknown> = { type: 'image', mediaType, data }
          const name = String(img.name ?? '').trim().slice(0, 80)
          if (name !== '') part.name = name
          parts.push(part)
        }
        const sessionId = decodeURIComponent(imagesMatch[1])
        const text = String(body.text ?? '').trim() || '（来自手机）'
        const { mode, running, known } = await pickMode(ctl, sessionId, body.mode === 'steer' ? 'steer' : 'queue')
        const result = await Promise.resolve(
          ctl.prompt(
            {
              requestId: randomBytes(16).toString('hex'),
              sessionId,
              mode,
              content: [{ type: 'text', text }, ...parts],
            },
            AbortSignal.timeout(60000),
          ),
        )
        await record(
          logFile,
          `200 POST images session=${sessionId} n=${String(parts.length)} bytes=${String(bytes)} mode=${mode} busy=${String(running)} known=${String(known)}`,
        )
        send(res, 200, { ok: true, sessionId, count: parts.length, bytes, mode, running, result: result ?? null })
        return
      }

      const filesMatch = /^\/api\/sessions\/([^/]+)\/files$/.exec(path)
      if (filesMatch !== null && method === 'POST') {
        const ctl = controller()
        if (!ctl || typeof ctl.prompt !== 'function') {
          send(res, 503, { error: 'sessionController.prompt unavailable' })
          return
        }
        const body = await readJson(req, MAX_UPLOAD_BYTES)
        const raw = Array.isArray(body.files) ? body.files : []
        if (raw.length === 0) {
          send(res, 400, { error: 'files is empty' })
          return
        }
        if (raw.length > MAX_FILES) {
          send(res, 400, { error: `at most ${String(MAX_FILES)} files per request` })
          return
        }
        // 手机上的文件对这台机器来说是不存在的，所以先落到磁盘，再把路径交给会话，
        // agent 就能像读本地文件一样读它。
        const stamp = new Date()
        const day = `${String(stamp.getFullYear())}${String(stamp.getMonth() + 1).padStart(2, '0')}${String(stamp.getDate()).padStart(2, '0')}`
        const dir = join(homedir(), '.dsh', 'mobile-uploads', day)
        await mkdir(dir, { recursive: true })
        const saved: Record<string, unknown>[] = []
        let bytes = 0
        for (const item of raw) {
          if (item === null || typeof item !== 'object') {
            send(res, 400, { error: 'each file must be an object' })
            return
          }
          const f = item as Record<string, unknown>
          const data = String(f.data ?? '')
          if (data.length === 0) {
            send(res, 400, { error: 'file data is empty' })
            return
          }
          const safe = String(f.name ?? 'file')
            .replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_')
            .trim()
            .slice(0, 120) || 'file'
          const target = join(dir, `${String(Date.now())}-${safe}`)
          const buf = Buffer.from(data, 'base64')
          await writeFile(target, buf)
          bytes += buf.length
          saved.push({ name: safe, path: target, bytes: buf.length })
        }
        const sessionId = decodeURIComponent(filesMatch[1])
        const head = String(body.text ?? '').trim()
        const lines = saved.map((s) => `- ${String(s.path)}`)
        const text = `${head === '' ? '（来自手机）' : head}\n\n已保存到这台机器：\n${lines.join('\n')}`
        const { mode, running, known } = await pickMode(ctl, sessionId, body.mode === 'steer' ? 'steer' : 'queue')
        const result = await Promise.resolve(
          ctl.prompt(
            {
              requestId: randomBytes(16).toString('hex'),
              sessionId,
              mode,
              content: [{ type: 'text', text }],
            },
            AbortSignal.timeout(60000),
          ),
        )
        await record(
          logFile,
          `200 POST files session=${sessionId} n=${String(saved.length)} bytes=${String(bytes)} mode=${mode} busy=${String(running)} known=${String(known)}`,
        )
        send(res, 200, {
          ok: true,
          sessionId,
          count: saved.length,
          bytes,
          files: saved,
          mode,
          running,
          result: result ?? null,
        })
        return
      }

      const sendMatch = /^\/api\/sessions\/([^/]+)\/send$/.exec(path)
      if (sendMatch !== null && method === 'POST') {
        const ctl = controller()
        if (!ctl || typeof ctl.prompt !== 'function') {
          send(res, 503, { error: 'sessionController.prompt unavailable', hint: 'is the DSH host fully started?' })
          return
        }
        const body = await readJson(req)
        const text = String(body.text ?? '').trim()
        if (text.length === 0) {
          send(res, 400, { error: 'text is empty' })
          return
        }
        const requested = body.mode === 'steer' ? 'steer' : 'queue'
        const sessionId = decodeURIComponent(sendMatch[1])

        // 空闲会话用 queue 只会得到 accepted:true，什么都不会发生（控制器把消息塞进
        // 一个永远不会被 drain 的邮箱）。实测只有 steer 才会替空闲会话起一轮。
        // 运行中的会话反过来不能用 steer（会打断当前轮），沿用调用方的 mode。
        const { mode: effective, running, known } = await pickMode(ctl, sessionId, requested)

        const result = await Promise.resolve(
          ctl.prompt(
            {
              requestId: randomBytes(16).toString('hex'),
              sessionId,
              mode: effective,
              content: [{ type: 'text', text }],
            },
            AbortSignal.timeout(20000),
          ),
        )
        await record(
          logFile,
          `200 POST send session=${sessionId} mode=${effective} busy=${running} known=${known} bytes=${String(Buffer.byteLength(text))}`,
        )
        send(res, 200, { ok: true, sessionId, mode: effective, running, result: result ?? null })
        return
      }

      if (path === '/api/presets' && method === 'GET') {
        const svc = service('agentPresets') ?? service('agent-preset-registry')
        if (svc === null) {
          send(res, 200, { ok: true, presets: [], current: '', unavailable: true })
          return
        }
        const raw = typeof svc.remoteExportList === 'function'
          ? await Promise.resolve(svc.remoteExportList())
          : (typeof svc.list === 'function' ? await Promise.resolve(svc.list()) : null)
        const current = presetCurrent(svc)
        send(res, 200, { ok: true, presets: presetRows(raw, current), current, unavailable: false })
        return
      }

      const presetMatch = /^\/api\/sessions\/([^/]+)\/preset$/.exec(path)
      if (presetMatch !== null && method === 'POST') {
        const body = await readJson(req)
        const presetId = String(body.presetId ?? '').trim()
        if (presetId === '') {
          send(res, 400, { error: 'presetId is required' })
          return
        }
        const svc = service('agentPresets') ?? service('agent-preset-registry')
        if (svc === null) {
          send(res, 503, { error: 'agentPresets service unavailable' })
          return
        }
        const sessionId = decodeURIComponent(presetMatch[1])
        const agents = service('agents')
        const agent: unknown = agents !== null && typeof agents.get === 'function' ? agents.get(sessionId) : null
        if (agent !== null && agent !== undefined && typeof svc.select === 'function') {
          try {
            await Promise.resolve(svc.select(agent, presetId))
            await record(logFile, `200 POST preset session=${sessionId} preset=${presetId} scope=session`)
            send(res, 200, { ok: true, selected: presetId, scope: 'session' })
            return
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error)
            // A session that already ran a turn cannot change preset; fall through
            // to the global default the console also uses in that case.
            if (!/already started|locked/.test(message)) throw error
          }
        }
        const settings = service('settings')
        if (settings !== null && typeof settings.update === 'function') {
          await Promise.resolve(settings.update('agent-preset-registry', { selectedDefault: presetId }, undefined))
          await record(logFile, `200 POST preset session=${sessionId} preset=${presetId} scope=global`)
          send(res, 200, { ok: true, selected: presetId, scope: 'global' })
          return
        }
        send(res, 409, { error: 'this session already started a turn and no global default is available' })
        return
      }

      if (path === '/api/permissions' && method === 'GET') {
        const svc = service('permissionPresets')
        if (svc === null || typeof svc.catalog !== 'function') {
          send(res, 200, { ok: true, presets: [], current: '', defaultPreset: '', unavailable: true })
          return
        }
        const cat = svc.catalog() as Record<string, unknown> | null
        const opts = cat !== null && Array.isArray(cat.options) ? (cat.options as unknown[]) : []
        const presets: Record<string, unknown>[] = []
        for (const item of opts) {
          if (item === null || typeof item !== 'object') continue
          const o = item as Record<string, unknown>
          const value = String(o.value ?? '')
          if (value === '') continue
          presets.push({ value, name: String(o.name ?? value), description: String(o.description ?? '') })
        }
        let current = ''
        const sessionId = url.searchParams.get('sessionId') ?? ''
        if (sessionId !== '') {
          const agents = service('agents')
          const agent: unknown = agents !== null && typeof agents.get === 'function' ? agents.get(sessionId) : null
          if (agent !== null && agent !== undefined) {
            const session = (agent as Record<string, unknown>).session
            if (session !== undefined && typeof svc.current === 'function') {
              try {
                current = String(svc.current(session) ?? '')
              } catch {
                current = ''
              }
            }
          }
        }
        send(res, 200, {
          ok: true,
          presets,
          current,
          defaultPreset: String(cat?.defaultPreset ?? ''),
          unavailable: false,
        })
        return
      }

      const permMatch = /^\/api\/sessions\/([^/]+)\/permission$/.exec(path)
      if (permMatch !== null && method === 'POST') {
        const body = await readJson(req)
        const preset = String(body.permission ?? '').trim()
        if (preset === '') {
          send(res, 400, { error: 'permission is required' })
          return
        }
        const svc = service('permissionPresets')
        if (svc === null || typeof svc.set !== 'function') {
          send(res, 503, { error: 'permissionPresets service unavailable' })
          return
        }
        const sessionId = decodeURIComponent(permMatch[1])
        const agents = service('agents')
        const agent: unknown = agents !== null && typeof agents.get === 'function' ? agents.get(sessionId) : null
        if (agent === null || agent === undefined) {
          send(res, 404, { error: `no agent for session ${sessionId}` })
          return
        }
        const session = (agent as Record<string, unknown>).session
        if (session === undefined) {
          send(res, 404, { error: `session ${sessionId} has no session object` })
          return
        }
        svc.set(session, preset)
        let current = preset
        if (typeof svc.current === 'function') {
          try {
            current = String(svc.current(session) ?? preset)
          } catch {
            current = preset
          }
        }
        await record(logFile, `200 POST permission session=${sessionId} preset=${preset} current=${current}`)
        send(res, 200, { ok: true, preset, current })
        return
      }

      send(res, 404, { error: 'not found', path })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      await record(logFile, `500 ${method} ${path} ${message}`)
      send(res, 500, { error: message })
    } finally {
      const q = url.search.slice(0, 40)
      void record(logFile, `${String(res.statusCode)} ${method} ${path}${q} ${String(Date.now() - started)}ms`)
    }
  }

  /**
   * The DSH settings panel is same-origin with the host's web app, not with
   * this listener, so it cannot send the bearer token. These routes are
   * registered on the host web server instead (DSH's own session auth covers
   * them) and expose the same pairing state.
   */
  const PANEL_PREFIX = '/api/dsh-mobile/panel'

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

  /** JSON response for a panel route. */
  const panelJson = (status: number, payload: unknown): Response =>
    new Response(JSON.stringify(payload), {
      status,
      headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
    })

  /** The snapshot the panel renders, with the QR payload and its SVG data URL. */
  const panelSnapshot = (): Record<string, unknown> => {
    const snapshot = pairState()
    const base = String(snapshot.base ?? '')
    const payload = base.length > 0 ? pairPayload(base, String(snapshot.code ?? '')) : ''
    return { ...snapshot, payload }
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

  /** Merge one patch into the pairing preferences and answer with the new state. */
  const panelConfig = async (request: Request): Promise<Response> => {
    const body = await panelBody(request)
    const current = pairPrefs()
    const next: PairPrefs = {
      allowLan: typeof body.allowLan === 'boolean' ? body.allowLan : current.allowLan,
      allowRemote: typeof body.allowRemote === 'boolean' ? body.allowRemote : current.allowRemote,
      publicUrl: typeof body.publicUrl === 'string' ? body.publicUrl.trim() : current.publicUrl,
    }
    writeState({ pair: next })
    await record(logFile, `200 PANEL config lan=${String(next.allowLan)} remote=${String(next.allowRemote)}`)
    return panelJson(200, panelSnapshot())
  }

  /** The QR itself, as an SVG the panel renders in an <img>. */
  const panelQr = async (request: Request): Promise<Response> => {
    const url = new URL(request.url)
    const asked = url.searchParams.get('payload')
    const snapshot = pairState()
    const base = String(snapshot.base ?? '')
    const text = asked !== null && asked.length > 0
      ? asked
      : base.length > 0
        ? pairPayload(base, String(snapshot.code ?? ''))
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

  /** The routes the DSH settings panel talks to, all same-origin with the GUI. */
  const panelRoutes: readonly Record<string, unknown>[] = [
    { path: `${PANEL_PREFIX}/state`, methods: ['GET'], requestBody: 'buffered', fetch: async () => panelJson(200, panelSnapshot()) },
    { path: `${PANEL_PREFIX}/newcode`, methods: ['POST'], requestBody: 'buffered', fetch: async () => { rotatePair(); return panelJson(200, panelSnapshot()) } },
    { path: `${PANEL_PREFIX}/config`, methods: ['POST'], requestBody: 'buffered', fetch: async (request: Request) => panelConfig(request) },
    { path: `${PANEL_PREFIX}/qr.svg`, methods: ['GET'], requestBody: 'buffered', fetch: async (request: Request) => panelQr(request) },
  ]

  try {
    ctx.inject(['connection'], (connCtx: any) => {
      const registry = connCtx?.connection?.fetch
      if (registry === undefined || typeof registry.register !== 'function') {
        void record(logFile, 'panel routes skipped: connection.fetch unavailable')
        return
      }
      for (const route of panelRoutes) {
        try {
          const dispose = registry.register(route)
          connCtx.effect(() => dispose, `dsh-mobile: panel ${String(route.path)}`)
        } catch (error) {
          void record(logFile, `panel route ${String(route.path)} not registered: ${error instanceof Error ? error.message : String(error)}`)
        }
      }
      void record(logFile, 'panel routes registered on connection.fetch')
    })
  } catch (error) {
    void record(logFile, `panel registration failed: ${error instanceof Error ? error.message : String(error)}`)
  }

  const server = createServer((req, res) => {
    void handle(req, res).catch(() => {
      try {
        res.destroy()
      } catch {
        // Nothing left to do.
      }
    })
  })

  ctx.effect(function* () {
    server.on('error', (error: NodeJS.ErrnoException) => {
      void record(logFile, `listen failed on ${host}:${String(port)} ${error.code ?? ''} ${error.message}`)
    })
    server.listen(port, host, () => {
      const urls = lanAddresses().map((a) => `http://${hostPort(a, port)}/?t=<token>`)
      void record(logFile, `listening on ${host}:${String(port)}; urls ${urls.join(' ')}`)
      // stdout reaches the host log during boot; the operator needs the token
      // exactly once, and the file is the durable copy.
      process.stdout.write(`[dsh-mobile] listening on ${host}:${String(port)} token file ${statePath()}\n`)
    })
    yield () => {
      void record(logFile, 'disposing; closing listener')
      server.close()
    }
  }, 'mobile listener')
}
