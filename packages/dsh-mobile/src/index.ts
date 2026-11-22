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
import { chmodSync, closeSync, existsSync, mkdirSync, openSync, readSync, readdirSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { appendFile, mkdir, writeFile } from 'node:fs/promises'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { networkInterfaces, homedir, hostname } from 'node:os'
import { dirname, extname, join, normalize, resolve, sep } from 'node:path'
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
function pairPayload(base: string, code: string, alts: readonly string[] = []): string {
  const extra = alts
    .filter((one) => one.length > 0 && one !== base)
    .slice(0, 4)
    .map((one) => `&a=${encodeURIComponent(one)}`)
    .join('')
  return `dshmobile://pair?b=${encodeURIComponent(base)}&c=${encodeURIComponent(code)}${extra}`
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

/**
 * Who answers `ask_user_question`: the phone while it is present (`phone`, the
 * default) or always the desktop (`desktop`). Persisted next to the token so the
 * choice survives a host restart.
 */
type AnswerMode = 'phone' | 'desktop'

/** Persisted state: the bearer token plus the pairing preferences. */
interface MobileState {
  token: string
  pair?: Partial<PairPrefs>
  /** `phone` (default) or `desktop`; anything else reads as the default. */
  answerMode?: AnswerMode
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

/**
 * Merge a patch into the persisted state, keeping the file 0600.
 *
 * Written to a sibling temp file and renamed into place: a failed write leaves
 * the previous file (and the token in it) intact instead of truncated.
 * @param patch - fields to merge over whatever is on disk (the token survives).
 * @param onError - told about a failed write so the caller can log it.
 * @returns false when the write failed; the process keeps serving either way.
 */
function writeState(patch: Partial<MobileState>, onError?: (error: unknown) => void): boolean {
  const file = statePath()
  const next: Partial<MobileState> = { ...readState(), ...patch }
  const temp = `${file}.${String(process.pid)}.tmp`
  try {
    mkdirSync(dirname(file), { recursive: true })
    writeFileSync(temp, `${JSON.stringify(next, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 })
    renameSync(temp, file)
    chmodSync(file, 0o600)
    return true
  } catch (error) {
    try {
      unlinkSync(temp)
    } catch {
      // Nothing was written, or the rename already consumed it.
    }
    // A read-only home still works: the change lasts for this process only.
    onError?.(error)
    return false
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
 * The answer-mode preference as it stands on disk right now.
 *
 * Read per question rather than cached: flipping the switch on the phone (or
 * hand-editing the file) takes effect on the next card, without a restart.
 */
function answerMode(): AnswerMode {
  return readState().answerMode === 'desktop' ? 'desktop' : 'phone'
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

/**
 * 宿主的一条定时任务记录归一成手机端认识的形状。
 *
 * 两个来源字段名不同：活服务给的是 ScheduleCatalogEntry（`scheduledAt` 加
 * `status`），磁盘上的 `tables.tasks` 行是旧格式。归一之后手机只渲染一种行，
 * 列表和「暂停/恢复/删除」两处共用这里，免得各写一份再慢慢走样。
 * @param raw - 宿主返回的一条任务记录。
 * @returns 手机端的任务行。
 */
function normalizeScheduleTask(raw: unknown): Record<string, unknown> {
  const bag = (raw !== null && typeof raw === 'object' ? raw : {}) as Record<string, unknown>
  const inner = (bag.record !== null && typeof bag.record === 'object' ? bag.record : bag) as Record<string, unknown>
  const target = (inner.target !== null && typeof inner.target === 'object' ? inner.target : {}) as Record<string, unknown>
  const status = String(inner.status ?? '')
  return {
    id: String(inner.id ?? bag.id ?? ''),
    title: String(inner.title ?? inner.name ?? '未命名任务'),
    kind: String(inner.kind ?? inner.type ?? ''),
    when: String(inner.nextRunAt ?? inner.nextAt ?? inner.next ?? inner.scheduledAt ?? inner.when ?? ''),
    active: inner.active === true || status === 'active' || status === 'scheduled',
    status,
    sessionId: String(target.sessionId ?? inner.sessionId ?? ''),
  }
}

/** profile 目录名：只许一层普通名字，挡掉 `..` 之类穿越路径。 */
const PROFILE_DIR_NAME = /^[A-Za-z0-9._-]{1,64}$/

/** 包名（可带 scope）：只用来在 dependencies 里查一项，不做版本解析。 */
const BUNDLE_NAME = /^(@[A-Za-z0-9._-]{1,64}\/)?[A-Za-z0-9._-]{1,120}$/

/** One session as the phone sees it. */
interface SessionRow {
  id: string
  title: string
  updatedAt: number
  cwd: string
  running: boolean
  /** 宿主侧有挂起的提问/审批：手机端用来把会话标成「等你回答」。 */
  asking: boolean
  archived: boolean
  pinned: boolean
  tokens: TokenUsage
  context: ContextUsage | null
  model: ModelRef | null
  agents: AgentSummary
}

/** 上下文占用：宿主 token-meter 的投影值（provider 报的 prompt 大小 + 之后增量估算）。 */
interface ContextUsage {
  used: number
  window: number
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
    // TeamTaskSnapshot 没有 owner 字段，负责人拆在 ownerName / ownerId 两处
    owner: String(t.ownerName ?? t.ownerId ?? ''),
  }))
  return { enabled: team.enabled === true, tasks, subagents }
}

/** One live ask_user_question waiting for a human, mirrored from the host waterfall. */
interface LiveAsk {
  sessionId: string
  callId: string
  questions: AskQuestion[]
  createdAt: number
  /** True when the host sent no `wait.callId` and this plugin minted the id itself. */
  synthetic: boolean
  resolve: (answer: unknown) => void
  delegate: () => void
}

function normalizeQuestions(raw: unknown): AskQuestion[] {
  const list = Array.isArray(raw) ? (raw as Array<Record<string, unknown>>) : []
  return list.map((q) => {
    const optsRaw = Array.isArray(q.options) ? (q.options as Array<Record<string, unknown>>) : []
    const options: AskOption[] = optsRaw
      .map((o) => ({
        label: String(o.label ?? ''),
        description: o.description === undefined ? '' : String(o.description),
      }))
      .filter((o) => o.label !== '')
    const one: AskQuestion = {
      id: String(q.id ?? ''),
      prompt: String(q.question ?? q.prompt ?? ''),
      options,
      multiSelect: q.multiSelect === true,
    }
    if (typeof q.header === 'string' && q.header !== '') one.header = q.header
    if (typeof q.detail === 'string' && q.detail !== '') one.detail = q.detail
    return one
  })
}

/** Copy the phone's answers into the shape the host waterfall resolves with. */
function normalizeAskAnswers(raw: unknown): AskAnswerItem[] {
  const list = Array.isArray(raw) ? (raw as Array<Record<string, unknown>>) : []
  const answers: AskAnswerItem[] = []
  for (const item of list) {
    const id = String(item?.id ?? '')
    if (id === '') continue
    const selectedRaw = Array.isArray(item?.selected) ? (item.selected as unknown[]) : []
    const selected = selectedRaw.map((value) => String(value)).filter((value) => value !== '')
    const one: AskAnswerItem = { id, selected }
    if (typeof item?.custom === 'string' && item.custom !== '') one.custom = item.custom
    answers.push(one)
  }
  return answers
}

/** Token counters live under `projections.values.tokenUsage`. */
function contextOf(values: Record<string, unknown> | undefined): ContextUsage | null {
  const raw = (values?.contextPressure ?? {}) as Record<string, unknown>
  const used = Number(raw.projectedTokens ?? raw.pressureTokens)
  const window = Number(raw.contextWindow)
  if (!Number.isFinite(used) || used <= 0) return null
  if (!Number.isFinite(window) || window <= 0) return null
  return { used: Math.trunc(used), window: Math.trunc(window) }
}

/** Structured questions the model asked, under `projections.values.userQuestions`. */
interface AskOption {
  label: string
  description?: string
}

interface AskQuestion {
  id: string
  prompt?: string
  header?: string
  detail?: string
  options?: AskOption[]
  multiSelect?: boolean
}

interface PendingAsk {
  callId: string
  questions: AskQuestion[]
  state: string
  /** True when `callId` was minted by this plugin instead of the host tool call. */
  synthetic?: boolean
}

/** One answer as the host's `user-questions/request` waterfall expects it. */
interface AskAnswerItem {
  id: string
  selected: string[]
  custom?: string
}

interface AskState {
  active: PendingAsk[]
  settled: Array<Record<string, unknown>>
}

function asksOf(values: Record<string, unknown> | undefined): AskState {
  const raw = (values?.userQuestions ?? {}) as Record<string, unknown>
  const activeRaw = Array.isArray(raw.active) ? (raw.active as Array<Record<string, unknown>>) : []
  const settledRaw = Array.isArray(raw.settled) ? (raw.settled as Array<Record<string, unknown>>) : []
  const active: PendingAsk[] = []
  for (const entry of activeRaw) {
    const callId = String(entry.callId ?? '')
    const list = Array.isArray(entry.questions) ? (entry.questions as Array<Record<string, unknown>>) : []
    if (callId === '' || list.length === 0) continue
    const questions: AskQuestion[] = list.map((q) => {
      const optsRaw = Array.isArray(q.options) ? (q.options as Array<Record<string, unknown>>) : []
      const options: AskOption[] = optsRaw
        .map((o) => ({
          label: String(o.label ?? ''),
          description: o.description === undefined ? '' : String(o.description),
        }))
        .filter((o) => o.label !== '')
      const one: AskQuestion = {
        id: String(q.id ?? ''),
        prompt: String(q.prompt ?? q.question ?? ''),
        options,
        multiSelect: q.multiSelect === true,
      }
      if (typeof q.header === 'string' && q.header !== '') one.header = q.header
      if (typeof q.detail === 'string' && q.detail !== '') one.detail = q.detail
      return one
    })
    active.push({ callId, questions, state: String(entry.state ?? 'open'), synthetic: false })
  }
  return { active, settled: settledRaw }
}

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

/**
 * Sessions are addressed by id in the URL; the controller wants the row.
 * @param liveAsking - 本插件自己按住、尚未作答的提问所在会话（宿主投影里没有）；省略即只看投影。
 */
function projectSessions(payload: unknown, liveAsking?: ReadonlySet<string>): SessionRow[] {
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
      // 手机接管中的提问不在宿主投影里，只按投影算会让等待答题的会话仍然是绿的。
      asking: (liveAsking?.has(id) ?? false) || asksOf(projectedValues).active.length > 0,
      archived: false,
      tokens: tokensOf(projectedValues),
      context: contextOf(projectedValues),
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
  /** Turn outcome, attached to the last reply of a finished turn. */
  turn?: TurnInfo
}

/**
 * How one turn ended, for the phone's per-reply footer.
 *
 * `status` is the host's `turn/end` reason (`completed`, `aborted`,
 * `interrupted`, `error`, `max-tokens`, `blocked`); `atSeq` is that event's seq
 * and doubles as the fork anchor the phone sends back.
 */
interface TurnInfo {
  status: string
  ms: number
  tokensIn: number
  tokensOut: number
  atSeq: number
  /** 这一轮结束的墙上时间（epoch ms），手机端在气泡底部显示「21:32」。 */
  finishedAt: number
  /** 失败时的错误码（宿主 reason.error.code，如 INVALID_REQUEST）。 */
  errCode?: string
  /** 失败时的原文（宿主 reason.error.message）。手机端要能整段看到并复制。 */
  errText?: string
}

/**
 * 一次失败的原文，供手机端在消息流里渲染可复制的错误卡片。
 *
 * 宿主 `turn/end` 的 `reason.error` 里带着真正的失败原因（上游 422 的 JSON、
 * 上下文超限说明等），而手机端以前只拿到 `kind`，所以用户只看到「处理失败」。
 */
interface TurnErr {
  code: string
  text: string
  time: number
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
  {
    size: number
    mtimeMs: number
    messages: ChatMessage[]
    stats: SessionStats
    lastTurn: string
    lastErr: TurnErr | null
  }
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
function historyOf(file: string): {
  messages: ChatMessage[]
  stats: SessionStats
  lastTurn: string
  lastErr: TurnErr | null
} {
  const stat = statSync(file)
  const cached = historyCache.get(file)
  if (cached !== undefined && cached.size === stat.size && cached.mtimeMs === stat.mtimeMs) {
    return {
      messages: cached.messages,
      stats: cached.stats,
      lastTurn: cached.lastTurn,
      lastErr: cached.lastErr,
    }
  }

  const messages: ChatMessage[] = []
  const stepAt = new Map<string, number>()
  const stats: SessionStats = {
    turns: 0,
    steps: 0,
    toolCalls: 0,
    tokens: { uncachedInputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 },
  }
  let lastTurn = ''
  // 最近一次失败的原文；手机端把它渲染成可复制的错误卡片。
  let lastErr: TurnErr | null = null
  // Per-turn bookkeeping for the reply footer: when it started, what it spent,
  // and which row is the turn's final visible reply.
  let turnStart = 0
  let turnIn = 0
  let turnOut = 0
  let turnReplyAt = -1
  for (const line of readSessionLines(file)) {
    let event: unknown
    try {
      event = JSON.parse(line)
    } catch {
      continue
    }
    if (event === null || typeof event !== 'object') continue
    const ev = event as Record<string, any>
    if (ev.type === 'turn/start') {
      stats.turns += 1
      turnStart = Number(ev.time ?? 0)
      turnIn = 0
      turnOut = 0
      turnReplyAt = -1
    }
    // 本轮怎么结束的：completed / aborted / interrupted / error / max-tokens / blocked。
    // 手机端靠它区分「完成」与「中断」，宿主没有单独的 interrupted 状态。
    else if (ev.type === 'turn/end') {
      lastTurn = String(ev.data?.reason?.kind ?? '')
      // 失败原因藏在 reason.error 里；以前整个丢掉，手机端就只剩「处理失败」。
      const rawErr = ev.data?.reason?.error
      let errCode = ''
      let errText = ''
      if (rawErr !== null && typeof rawErr === 'object') {
        errCode = String((rawErr as Record<string, unknown>).code ?? '')
        errText = String((rawErr as Record<string, unknown>).message ?? '')
      } else if (typeof rawErr === 'string') {
        errText = rawErr
      }
      if (errText !== '') {
        lastErr = { code: errCode, text: errText, time: Number(ev.time ?? 0) }
      } else {
        // 后来这一轮成功了：最后一条报错不再代表这个会话的现状。
        lastErr = null
      }
      const row = turnReplyAt >= 0 ? messages[turnReplyAt] : undefined
      if (row !== undefined) {
        const endAt = Number(ev.time ?? 0)
        row.turn = {
          status: lastTurn,
          ms: endAt > turnStart && turnStart > 0 ? endAt - turnStart : 0,
          tokensIn: turnIn,
          tokensOut: turnOut,
          atSeq: Number(ev.seq ?? 0),
          finishedAt: endAt > 0 ? endAt : Date.now(),
        }
        if (errText !== '') {
          row.turn.errCode = errCode
          row.turn.errText = errText
        }
      }
    } else if (ev.type === 'step/start') stats.steps += 1
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
      const usage = ev.data?.usage
      if (usage !== null && typeof usage === 'object') {
        // 每一跳的 inputTokens 都是「整段上下文」，累加会翻好几倍；取最后一跳的输入，
        // 输出按跳累加，才是这一轮真实读了多少、写了多少。
        // inputTokens 只是没命中缓存的那部分，命中缓存的量在 cacheReadTokens 里；
        // 两者相加才是这一跳真正的 prompt 大小（否则手机端会看到「163 tokens」这种假数）。
        const freshIn = Number(usage.inputTokens ?? 0) || 0
        const cachedIn = Number(usage.cacheReadTokens ?? usage.cachedInputTokens ?? 0) || 0
        turnIn = freshIn + cachedIn
        turnOut += Number(usage.outputTokens ?? 0) || 0
      }
      if (text.length === 0) continue
      const row: ChatMessage = {
        role: 'assistant',
        text,
        time: Number(ev.time ?? 0),
        seq: Number(ev.seq ?? 0),
      }
      const key = `${String(ev.data?.turn ?? '')}:${String(ev.data?.step ?? '')}`
      const at = stepAt.get(key)
      if (at !== undefined) {
        messages[at] = row
        turnReplyAt = at
      } else {
        stepAt.set(key, messages.length)
        turnReplyAt = messages.length
        messages.push(row)
      }
    }
  }
  historyCache.set(file, {
    size: stat.size,
    mtimeMs: stat.mtimeMs,
    messages,
    stats,
    lastTurn,
    lastErr,
  })
  return { messages, stats, lastTurn, lastErr }
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

/**
 * Files picked on the phone do not exist on this machine, so /outbox writes them
 * to disk first and hands the paths to the session as one trailing text part.
 * Returns the saved rows plus that text block (empty when nothing was saved).
 */
async function saveMobileFiles(raw: unknown[]): Promise<{ saved: Record<string, unknown>[]; bytes: number; text: string }> {
  const saved: Record<string, unknown>[] = []
  if (raw.length === 0) return { saved, bytes: 0, text: '' }
  const stamp = new Date()
  const day = `${String(stamp.getFullYear())}${String(stamp.getMonth() + 1).padStart(2, '0')}${String(stamp.getDate()).padStart(2, '0')}`
  const dir = join(homedir(), '.dsh', 'mobile-uploads', day)
  await mkdir(dir, { recursive: true })
  let bytes = 0
  for (const item of raw) {
    if (item === null || typeof item !== 'object') throw new Error('each file must be an object')
    const f = item as Record<string, unknown>
    const data = String(f.data ?? '')
    if (data.length === 0) throw new Error('file data is empty')
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
  const lines = saved.map((s) => `- ${String(s.path)}`)
  return { saved, bytes, text: `已保存到这台机器：\n${lines.join('\n')}` }
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
  /** Last phone poll per Session: only a chat somebody is watching holds a question. */
  const phoneSessionAt = new Map<string, number>()
  /** Wrong-claim counters per peer; a coarse throttle, not an account lock. */
  const pairFails = new Map<string, { n: number; until: number }>()

  /**
   * Live `ask_user_question` calls mirrored from the host waterfall.
   *
   * 宿主会依次询问每个答器；这里先把请求按住交给手机，等 ASK_HOLD_MS 到期或
   * signal 被 abort 才 next() 交还桌面答器。phone 模式不看手机在不在线：手机
   * 离线也照样等它（用户要求）。
   *
   * Blocking asks - the default `tool-ask-user` mode - carry no `wait.callId` at
   * all, so the card is only reachable if this listener (a) runs before the
   * desktop answerer, which never calls `next()` once it holds a request, and
   * (b) invents an id the phone can answer with.
   */
  const liveAsks = new Map<string, LiveAsk>()
  /** 手机模式下最多替手机按住一个提问这么久（5 分钟），到期交还桌面。 */
  const ASK_HOLD_MS = 5 * 60 * 1000
  /**
   * 手机在最后一次认证请求之后算「在线」的时长，由 `POST /api/presence` 维持。
   * 现在只用于面板显示和 presence 回包，不再决定提问由谁回答。
   */
  const PRESENCE_TTL_MS = 15 * 1000
  /**
   * 手机接管中的提问按会话归集，供会话列表的 asking 用：宿主投影只反映桌面答器，
   * 看不到 liveAsks。'*' 是宿主没给会话 id 的提问，归不到任何一行，跳过。
   */
  const liveAsking = (): Set<string> => {
    const out = new Set<string>()
    for (const ask of liveAsks.values()) {
      if (ask.sessionId !== '*') out.add(ask.sessionId)
    }
    return out
  }
  /** Bumped for every id minted here, so two asks in one millisecond stay apart. */
  let syntheticSeq = 0
  try {
    ctx.on(
      'user-questions/request',
      (request: any, next: () => Promise<unknown>) => {
        const questions = normalizeQuestions(request?.questions)
        if (questions.length === 0) return next()
        // desktop 模式立即交桌面：即使手机在线，这里也不按住卡片，不铸 id、不等待。
        if (answerMode() === 'desktop') {
          void record(logFile, 'ask desktop-only, delegate')
          return next()
        }
        const agent = request?.agent
        // `request.sessionId` is not part of the host event type; it is kept as a
        // courtesy for hosts that pass it, with the agent session as the source.
        const sessionId = String(request?.sessionId ?? agent?.session?.id ?? '')
        const hostCallId = request?.wait?.callId === undefined ? '' : String(request.wait.callId)
        const synthetic = hostCallId === ''
        let callId = hostCallId
        if (synthetic) {
          syntheticSeq += 1
          const tag = sessionId.replace(/[^0-9A-Za-z]/g, '').slice(0, 8) || 'anon'
          callId = `q-${tag}-${Date.now().toString(36)}-${String(syntheticSeq)}`
        }
        // A timed ask belongs to the host timed answerer: it answers through the
        // `userQuestions` service by callId, so holding it here would leave the
        // phone's reply with nobody to deliver it to.
        if (!synthetic && request?.wait?.timed === true) {
          void record(logFile, `ask timed, delegate session=${sessionId} call=${callId}`)
          return next()
        }
        // An ask with no session still has to reach a phone: park it under '*' so
        // every session's card list offers it, and match it by callId on answer.
        const askSessionId = sessionId === '' ? '*' : sessionId
        // phone 模式不再用 presence 当闸门：手机不在线也先接管并等它，
        // 兜底是 ASK_HOLD_MS 超时与 signal abort（都会 handOver 交还桌面）。
        const signal: AbortSignal | undefined =
          request?.signal !== undefined && typeof request.signal.addEventListener === 'function'
            ? (request.signal as AbortSignal)
            : undefined
        void record(
          logFile,
          `ask pending session=${sessionId} call=${callId} synthetic=${String(synthetic)} q=${String(questions.length)}`,
        )
        return new Promise<unknown>((resolve, reject) => {
          let done = false
          let timer: ReturnType<typeof setTimeout> | undefined
          const cleanup = (): void => {
            if (timer !== undefined) clearTimeout(timer)
            // Only drop the entry this call owns: a reused id must not be evicted.
            if (liveAsks.get(callId) === entry) liveAsks.delete(callId)
            if (signal !== undefined) signal.removeEventListener('abort', onAbort)
          }
          const handOver = (reason: string): void => {
            if (done) return
            done = true
            cleanup()
            void record(logFile, `${reason} session=${sessionId} call=${callId}`)
            void Promise.resolve()
              .then(() => next())
              .then(resolve, reject)
          }
          const onAbort = (): void => handOver('ask aborted')
          if (signal !== undefined) {
            if (signal.aborted) {
              // Cancelled before we could show a card: nothing to answer.
              void record(logFile, `ask already aborted session=${sessionId} call=${callId}`)
              void Promise.resolve()
                .then(() => next())
                .then(resolve, reject)
              return
            }
            signal.addEventListener('abort', onAbort, { once: true })
          }
          // phone 模式不设超时：只要还是手机为主，就一直等手机，直到桌面把模式切回电脑。
          const entry: LiveAsk = {
            sessionId: askSessionId,
            callId,
            questions,
            createdAt: Date.now(),
            synthetic,
            resolve: (answer: unknown) => {
              if (done) return
              done = true
              cleanup()
              void record(logFile, `ask answered session=${sessionId} call=${callId}`)
              resolve(answer)
            },
            delegate: () => handOver('ask delegate'),
          }
          liveAsks.set(callId, entry)
        })
      },
      // The desktop answerer holds a blocking ask and never calls next(), so this
      // listener has to be first in the chain or the phone never sees the card.
      { prepend: true },
    )
    void record(logFile, 'ask hook registered (prepend)')
  } catch (error) {
    void record(logFile, `ask hook skipped: ${String(error)}`)
  }

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
    const primary = prefs.allowLan && lan.length > 0 ? (lan[0] as string) : prefs.publicUrl
    // 手机连不上首个地址时的退路：其它网卡 + 公网隧道。顺序就是尝试顺序。
    const alts = [...lan.slice(1), prefs.allowRemote ? prefs.publicUrl : ''].filter(
      (one) => one.length > 0 && one !== primary,
    )
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
      alts,
      /** Base URL a QR should carry right now: LAN first, then the tunnel. */
      base: primary,
      phoneSeenAt,
      phoneOnline: phoneSeenAt > 0 && Date.now() - phoneSeenAt < PHONE_ONLINE_MS,
      sessions: true,
    }
  }

  /** Resolve the controller per request: a later mount must be visible here. */
  // ---- 手机端发送队列 ----------------------------------------------------
  // 运行中的会话不能直接 steer（会打断当前轮），queue 又只在宿主里躺着看不见。
  // 所以这一层自己排队：先收下（手机和面板都能看到），等会话空下来再逐条 steer 进去，
  // 想插队就立刻 steer 并把它从队里摘掉。
  interface QueuedPrompt {
    id: string
    text: string
    content: Record<string, unknown>[]
    at: number
  }

  const promptQueues = new Map<string, QueuedPrompt[]>()

  // 排队要活得比进程久：宿主重启不应该把用户排着的话丢掉。
  const queueFile = (): string => join(dshHome(), 'queue.json')
  let queueSaveTimer: ReturnType<typeof setTimeout> | undefined

  const flushQueue = (): void => {
    try {
      const out: Record<string, QueuedPrompt[]> = {}
      promptQueues.forEach((list, sid) => {
        if (list.length > 0) out[sid] = list
      })
      writeFileSync(queueFile(), JSON.stringify(out), { mode: 0o600 })
    } catch {
      /* 队列落盘失败不影响发送 */
    }
  }

  const saveQueue = (): void => {
    if (queueSaveTimer !== undefined) clearTimeout(queueSaveTimer)
    queueSaveTimer = setTimeout(() => {
      queueSaveTimer = undefined
      flushQueue()
    }, 200)
  }

  const loadQueue = (): void => {
    try {
      const parsed = JSON.parse(readFileSync(queueFile(), 'utf8')) as Record<string, QueuedPrompt[]>
      for (const sid of Object.keys(parsed)) {
        const list = parsed[sid]
        if (Array.isArray(list) && list.length > 0) promptQueues.set(sid, list)
      }
    } catch {
      /* 首次启动没有队列文件 */
    }
  }

  loadQueue()

  const queueList = (sessionId: string): QueuedPrompt[] => promptQueues.get(sessionId) ?? []

  const queueView = (sessionId: string): Record<string, unknown>[] =>
    queueList(sessionId).map((q, i) => ({ id: q.id, text: q.text, at: q.at, index: i + 1 }))

  const enqueuePrompt = (sessionId: string, text: string, content: Record<string, unknown>[]): QueuedPrompt => {
    const item: QueuedPrompt = { id: randomBytes(8).toString('hex'), text, content, at: Date.now() }
    const list = queueList(sessionId)
    list.push(item)
    promptQueues.set(sessionId, list)
    saveQueue()
    return item
  }

  const dequeueById = (sessionId: string, id: string): QueuedPrompt | null => {
    const list = queueList(sessionId)
    const at = list.findIndex((q) => q.id === id)
    if (at < 0) return null
    const [one] = list.splice(at, 1)
    if (list.length === 0) promptQueues.delete(sessionId)
    else promptQueues.set(sessionId, list)
    saveQueue()
    return one ?? null
  }

  let drainingQueues = false

  /** 每次拍子：把已经空闲的会话的队头送进去（steer，空会话用它才能起一轮）。 */
  const drainQueues = async (): Promise<void> => {
    if (drainingQueues || promptQueues.size === 0) return
    const ctl = controller()
    if (!ctl || typeof ctl.prompt !== 'function') return
    drainingQueues = true
    try {
      for (const sessionId of [...promptQueues.keys()]) {
        const list = queueList(sessionId)
        if (list.length === 0) continue
        const head = list[0]
        if (head === undefined) continue
        const probe = await pickMode(ctl, sessionId, 'queue')
        if (!probe.known || probe.running) continue
        dequeueById(sessionId, head.id)
        try {
          await Promise.resolve(
            ctl.prompt(
              {
                requestId: randomBytes(16).toString('hex'),
                sessionId,
                mode: 'steer',
                content: head.content,
              },
              AbortSignal.timeout(60000),
            ),
          )
          await record(logFile, `200 QUEUE flush session=${sessionId} id=${head.id}`)
        } catch (e) {
          // 送失败就放回队头，下一拍再试
          const back = queueList(sessionId)
          back.unshift(head)
          promptQueues.set(sessionId, back)
          await record(logFile, `500 QUEUE flush session=${sessionId} id=${head.id} err=${(e as Error).message}`)
        }
      }
    } finally {
      drainingQueues = false
    }
  }

  const queueTimer = setInterval(() => {
    void drainQueues()
  }, 2500)
  // 排队交给宿主：桌面版输入区会显示「待发送」，手机端再用 updateQueue 改 / 删 / 插队。
  const hostState = async (ctl: any, sessionId: string): Promise<any> => {
    if (!ctl || typeof ctl.state !== 'function') return null
    try {
      return await Promise.resolve(ctl.state({ sessionId }, AbortSignal.timeout(8000)))
    } catch {
      return null
    }
  }

  const hostQueued = async (ctl: any, sessionId: string): Promise<any[]> => {
    const st = await hostState(ctl, sessionId)
    const q = st && Array.isArray(st.queue) ? st.queue : []
    return q.filter((it: any) => it !== null && typeof it === 'object' && it.placement === 'queued')
  }

  const hostText = (it: any): string => {
    const parts = it && Array.isArray(it.content) ? it.content : []
    return parts
      .filter((p: any) => p !== null && typeof p === 'object' && p.type === 'text')
      .map((p: any) => String(p.text ?? ''))
      .join(' ')
      .trim()
  }

  /** Image parts of one queued prompt, with metadata only: bytes go through /queue-image. */
  const hostImages = (it: any): Record<string, unknown>[] => {
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

  const hostQueueView = async (ctl: any, sessionId: string): Promise<Record<string, unknown>[]> => {
    const list = await hostQueued(ctl, sessionId)
    return list.map((it: any, i: number) => ({
      id: String(it.id),
      text: hostText(it),
      at: 0,
      index: i + 1,
      images: hostImages(it),
    }))
  }

  const hostEnqueue = async (
    ctl: any,
    sessionId: string,
    content: Record<string, unknown>[],
  ): Promise<string> => {
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

  const hostMutate = async (
    ctl: any,
    sessionId: string,
    itemId: string,
    action: Record<string, unknown>,
  ): Promise<boolean> => {
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
   * Context pressure is a SessionProjectionSummaryExcluded value: `ctl.list()`
   * never carries it, so the Ring in the app would read 0% forever. The
   * projection registry keeps the full map, and its snapshot needs the live
   * Session object rather than the id — resolved here, cached briefly because
   * the phone polls this route every few seconds.
   */
  const deepCache = new Map<string, { at: number; value: ContextUsage | null }>()
  const DEEP_TTL_MS = 15000
  const deepContext = (sessionId: string): ContextUsage | null => {
    const hit = deepCache.get(sessionId)
    if (hit !== undefined && Date.now() - hit.at < DEEP_TTL_MS) return hit.value
    let value: ContextUsage | null = null
    try {
      const registry = service('sessionProjections')
      const sessions = service('sessions')
      const live: any = sessions !== null && typeof sessions.get === 'function'
        ? sessions.get(sessionId)
        : undefined
      if (registry !== null && live !== undefined && typeof registry.snapshot === 'function') {
        const snap: any = registry.snapshot(live)
        value = contextOf((snap?.values ?? {}) as Record<string, unknown>)
      }
    } catch (error) {
      void record(logFile, `deep context failed: ${String(error)}`)
    }
    deepCache.set(sessionId, { at: Date.now(), value })
    return value
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
        qr: pairPayload(base, pairCode?.code ?? '', lanBases().slice(1)),
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

      // Presence: the phone pings this every few seconds while it is in the
      // foreground and says `online:false` when it goes away. While it is online
      // it owns every ask_user_question card; once the window lapses the desktop
      // is the answerer again.
      if (path === '/api/presence') {
        let online = true
        if (method === 'POST') {
          const body = await readJson(req).catch(() => undefined)
          if (body !== undefined && typeof body === 'object' && body !== null) {
            const flag = (body as { online?: unknown }).online
            if (flag === false) online = false
          }
        }
        if (online) {
          phoneSeenAt = Date.now()
        } else {
          phoneSeenAt = 0
        }
        send(res, 200, {
          ok: true,
          online,
          ttlMs: PRESENCE_TTL_MS,
          sessionId: String(url.searchParams.get('sessionId') ?? ''),
        })
        return
      }

      // Who answers ask_user_question: `phone` (default) or `desktop`. Persisted
      // next to the token, so the phone's setting survives a host restart.
      if (path === '/api/answer-mode' && method === 'GET') {
        send(res, 200, { ok: true, mode: answerMode() })
        return
      }

      if (path === '/api/answer-mode' && method === 'POST') {
        const body = await readJson(req)
        const wanted = body.mode
        if (wanted !== 'phone' && wanted !== 'desktop') {
          send(res, 400, { error: 'mode must be "phone" or "desktop"' })
          return
        }
        const persisted = writeState({ answerMode: wanted }, (error) => {
          void record(logFile, `answer mode persist failed: ${String(error)}`)
        })
        if (!persisted) {
          // Report the mode that is actually in force, not the one that failed
          // to persist: the hook reads the file, so the old mode still wins.
          await record(logFile, `500 ANSWER wanted=${wanted} persist failed`)
          send(res, 500, { ok: false, error: 'answer mode not saved', mode: answerMode() })
          return
        }
        await record(logFile, `200 ANSWER mode=${wanted}`)
        send(res, 200, { ok: true, mode: wanted })
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
        send(res, 200, { ok: true, sessions: markPinned(markArchived(projectSessions(listed, liveAsking()))) })
        return
      }

      /**
       * Open questions for one Session: the projection knows every recorded
       * ask, and `liveAsks` adds the ones currently blocking a turn.
       */
      const pendingAsks = (listed: unknown, sessionId: string): AskState => {
        const raw = rowsOf(listed).find((item) => {
          const r = item as Record<string, unknown>
          return String(r.sessionId ?? r.id ?? '') === sessionId
        }) as Record<string, unknown> | undefined
        const proj = raw?.projections as { values?: Record<string, unknown> } | undefined
        const fromProjection = asksOf(proj?.values as Record<string, unknown> | undefined)
        const seen = new Set(fromProjection.active.map((a) => a.callId))
        for (const ask of liveAsks.values()) {
          // '*' means the host gave no session id: offer the card everywhere
          // rather than lose a question nobody can answer.
          if (ask.sessionId !== sessionId && ask.sessionId !== '*') continue
          if (seen.has(ask.callId)) continue
          fromProjection.active.push({
            callId: ask.callId,
            questions: ask.questions,
            state: 'open',
            synthetic: ask.synthetic,
          })
        }
        return fromProjection
      }

      const questionsMatch = /^\/api\/sessions\/([^/]+)\/questions$/.exec(path)
      if (questionsMatch !== null && method === 'GET') {
        const sessionId = decodeURIComponent(questionsMatch[1])
        phoneSessionAt.set(sessionId, Date.now())
        const ctl = controller()
        let listed: unknown = []
        if (ctl && typeof ctl.list === 'function') {
          try {
            listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(8000)))
          } catch {
            /* a question may already be live even when the list call fails */
          }
        }
        send(res, 200, { ok: true, sessionId, ...pendingAsks(listed, sessionId) })
        return
      }

      const answerMatch = /^\/api\/sessions\/([^/]+)\/questions\/answer$/.exec(path)
      if (answerMatch !== null && method === 'POST') {
        const sessionId = decodeURIComponent(answerMatch[1])
        const body = await readJson(req, 64 * 1024)
        const callId = String((body as Record<string, unknown>).callId ?? '')
        const answers = normalizeAskAnswers((body as Record<string, unknown>).answers)
        if (callId === '' || answers.length === 0) {
          send(res, 400, { error: 'callId and answers are required' })
          return
        }
        // Lookup is by callId alone: blocking asks minted here have no host id,
        // and an ask parked under '*' still has to be answerable from its chat.
        const live = liveAsks.get(callId)
        if (live === undefined || (live.sessionId !== sessionId && live.sessionId !== '*')) {
          send(res, 409, { error: 'this question is no longer waiting', callId })
          return
        }
        const synthetic = live.synthetic
        live.resolve({ answers })
        send(res, 200, { ok: true, callId, synthetic, answered: answers.length })
        return
      }

      const historyMatch = /^\/api\/sessions\/([^/]+)\/messages$/.exec(path)
      if (historyMatch !== null && method === 'GET') {
        const sessionId = decodeURIComponent(historyMatch[1])
        // 手机正在看这个会话：记下时间，只有刚被手机轮询过的会话才由手机接管选择题。
        phoneSessionAt.set(sessionId, Date.now())
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
        const { messages: all, stats, lastTurn, lastErr } = historyOf(file)
        let tokens = stats.tokens
        let running = false
        let context: ContextUsage | null = null
        const ctl = controller()
        let listed: unknown = []
        if (ctl && typeof ctl.list === 'function') {
          try {
            listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(8000)))
            const row = projectSessions(listed).find((r) => r.id === sessionId)
            if (row !== undefined) {
              tokens = row.tokens
              running = row.running === true
              context = row.context
              if (context === null) context = deepContext(sessionId)
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
          // 最后一轮的结束原因：completed / aborted / interrupted / error …
          lastTurn,
          // 最近一次失败的原文（code + 整段 message），手机端据此渲染可复制的错误卡片
          lastErr,
          context,
          running,
          queue: await hostQueueView(ctl, sessionId),
          questions: pendingAsks(listed, sessionId),
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
        if (!(ctl && typeof ctl.archive === 'function') && !(reg && typeof reg.archiveSession === 'function')) {
          send(res, 503, { error: 'archiving is unavailable on this host' })
          return
        }
        // `stopActivity` is the host's own admission switch: without it a session
        // that still owns a turn is refused as `workspace/session-active`.
        const archiveCall = async (stopActivity: boolean): Promise<void> => {
          if (ctl && typeof ctl.archive === 'function') {
            await Promise.resolve(ctl.archive({ sessionId, stopActivity }))
            return
          }
          await Promise.resolve(reg.archiveSession(sessionId, { stopActivity }))
        }
        let cancelledFirst = false
        let stoppedFirst = false
        try {
          await archiveCall(false)
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err)
          if (/session-active|active|running|busy/i.test(message)) {
            try {
              await archiveCall(true)
              stoppedFirst = true
            } catch (err2) {
              // Older hosts ignore `stopActivity`, so cancel the turn first.
              if (ctl && typeof ctl.cancel === 'function') {
                await Promise.resolve(ctl.cancel({ sessionId }))
                cancelledFirst = true
                await archiveCall(false)
              } else {
                throw err2
              }
            }
          } else {
            throw err
          }
        }
        await record(logFile, `200 POST archive session=${sessionId} stoppedFirst=${stoppedFirst} cancelledFirst=${cancelledFirst}`)
        send(res, 200, { ok: true, sessionId, archived: true, stoppedFirst, cancelledFirst })
        return
      }

      // 分叉：把源会话截至 atSeq（含）的事件前缀复制成一个独立会话。
      // atSeq 省略时宿主取「最近一个已完成轮次」的边界；给了就按该事件精确切。
      const forkMatch = /^\/api\/sessions\/([^/]+)\/fork$/.exec(path)
      if (forkMatch !== null && method === 'POST') {
        const sessionId = decodeURIComponent(forkMatch[1])
        const ctl = controller()
        if (!(ctl && typeof ctl.fork === 'function')) {
          send(res, 503, { error: 'forking is unavailable on this host' })
          return
        }
        const body = await readJson(req)
        const raw = body.atSeq
        const atSeq = typeof raw === 'number' && Number.isFinite(raw) && raw >= 0 ? raw : undefined
        try {
          const out = await Promise.resolve(ctl.fork(atSeq === undefined ? { sessionId } : { sessionId, atSeq }))
          const child = typeof out === 'string' ? out : String((out as Record<string, unknown> | null)?.sessionId ?? '')
          if (child === '') {
            send(res, 500, { error: 'host returned no session for the fork' })
            return
          }
          await record(logFile, `200 POST fork session=${sessionId} at=${String(atSeq ?? 'latest')} child=${child}`)
          send(res, 200, { ok: true, sessionId: child, atSeq: atSeq ?? null })
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err)
          await record(logFile, `500 POST fork session=${sessionId} at=${String(atSeq ?? 'latest')} err=${message}`)
          send(res, 500, { error: message })
        }
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
        if (mode === 'queue' && running) {
          const itemId = await hostEnqueue(ctl, sessionId, [{ type: 'text', text }, ...parts])
          await record(logFile, `200 POST images session=${sessionId} mode=queue host=${itemId} n=${String(parts.length)}`)
          send(res, 200, {
            ok: true,
            sessionId,
            mode: 'queue',
            queued: true,
            item: itemId,
            count: parts.length,
            queue: await hostQueueView(ctl, sessionId),
          })
          return
        }

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

      const queueImgMatch = /^\/api\/sessions\/([^/]+)\/queue-image$/.exec(path)
      if (queueImgMatch !== null && method === 'GET') {
        const sessionId = decodeURIComponent(queueImgMatch[1])
        const itemId = String(url.searchParams.get('item') ?? '')
        const index = Number.parseInt(String(url.searchParams.get('i') ?? '0'), 10)
        const ctl = controller()
        const list = ctl === null ? [] : await hostQueued(ctl, sessionId)
        const item = list.find((x: any) => String(x.id) === itemId)
        const parts = item && Array.isArray(item.content) ? item.content : []
        const images = parts.filter((p: any) => p !== null && typeof p === 'object' && p.type === 'image')
        const pick = images[Number.isFinite(index) ? index : 0]
        if (pick === undefined) {
          send(res, 404, { error: 'queued image not found' })
          return
        }
        const mediaType = String(pick.mediaType ?? 'image/png').toLowerCase()
        const buf = Buffer.from(String(pick.data ?? ''), 'base64')
        res.writeHead(200, { 'Content-Type': IMAGE_TYPES.has(mediaType) ? mediaType : 'image/png', 'Content-Length': String(buf.length), 'Cache-Control': 'no-store' })
        res.end(buf)
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
        if (mode === 'queue' && running) {
          const itemId = await hostEnqueue(ctl, sessionId, [{ type: 'text', text }])
          await record(logFile, `200 POST files session=${sessionId} mode=queue host=${itemId} n=${String(saved.length)}`)
          send(res, 200, {
            ok: true,
            sessionId,
            mode: 'queue',
            queued: true,
            item: itemId,
            count: saved.length,
            files: saved,
            queue: await hostQueueView(ctl, sessionId),
          })
          return
        }
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

      const queueMatch = /^\/api\/sessions\/([^/]+)\/queue$/.exec(path)
      if (queueMatch !== null) {
        const sessionId = decodeURIComponent(queueMatch[1])
        if (method === 'GET') {
          const ctl = controller()
          send(res, 200, { ok: true, sessionId, queue: await hostQueueView(ctl, sessionId) })
          return
        }
        if (method === 'POST') {
          const ctl = controller()
          if (!ctl || typeof ctl.prompt !== 'function') {
            send(res, 503, { error: 'sessionController.prompt unavailable' })
            return
          }
          const body = await readJson(req)
          const text = String(body.text ?? '').trim()
          if (text.length === 0) {
            send(res, 400, { error: 'text is empty' })
            return
          }
          const itemId = await hostEnqueue(ctl, sessionId, [{ type: 'text', text }])
          await record(logFile, `200 QUEUE push session=${sessionId} host=${itemId}`)
          send(res, 200, {
            ok: true,
            sessionId,
            item: itemId,
            queue: await hostQueueView(ctl, sessionId),
          })
          return
        }
      }

      // 重排「待发送」：宿主没有 move，只能按目标顺序先全删、再按序重新入队。
      // 图片字节就存在 queue item 的 content 里，所以能原样搬过去。
      const queueOrderMatch = /^\/api\/sessions\/([^/]+)\/queue\/reorder$/.exec(path)
      if (queueOrderMatch !== null && method === 'POST') {
        const sessionId = decodeURIComponent(queueOrderMatch[1])
        const ctl = controller()
        if (!ctl || typeof ctl.prompt !== 'function' || typeof ctl.updateQueue !== 'function') {
          send(res, 503, { error: 'sessionController queue API unavailable' })
          return
        }
        const body = await readJson(req)
        const wanted = Array.isArray(body.ids) ? body.ids.map((x: unknown) => String(x)) : []
        const listed = await hostQueued(ctl, sessionId)
        const byId = new Map<string, any>()
        for (const it of listed) {
          byId.set(String((it as any).id), it)
        }
        const unique = new Set<string>(wanted)
        if (wanted.length !== listed.length || unique.size !== wanted.length
          || wanted.some((id: string) => !byId.has(id))) {
          send(res, 400, {
            error: 'ids must cover every queued item exactly once',
            queue: await hostQueueView(ctl, sessionId),
          })
          return
        }
        for (const it of listed) {
          await hostMutate(ctl, sessionId, String((it as any).id), { kind: 'remove' })
        }
        let moved = 0
        for (const id of wanted) {
          const it = byId.get(id)
          const content = it && Array.isArray(it.content) ? it.content : []
          if (content.length === 0) continue
          await hostEnqueue(ctl, sessionId, content as Record<string, unknown>[])
          moved++
        }
        await record(logFile, `200 QUEUE reorder session=${sessionId} n=${moved}`)
        send(res, 200, { ok: true, sessionId, moved, queue: await hostQueueView(ctl, sessionId) })
        return
      }

      const queueItemMatch = /^\/api\/sessions\/([^/]+)\/queue\/([^/]+)\/(drop|fire|edit)$/.exec(path)
      if (queueItemMatch !== null && method === 'POST') {
        const sessionId = decodeURIComponent(queueItemMatch[1])
        const itemId = decodeURIComponent(queueItemMatch[2])
        const action = queueItemMatch[3]
        const ctl = controller()
        if (!ctl || typeof ctl.updateQueue !== 'function') {
          send(res, 503, {
            error: 'sessionController.updateQueue unavailable',
            hint: 'restart the DSH host so the queue API is loaded',
          })
          return
        }
        let mutation: Record<string, unknown>
        if (action === 'edit') {
          const body = await readJson(req)
          const text = String(body.text ?? '').trim()
          if (text.length === 0) {
            send(res, 400, { error: 'text is empty' })
            return
          }
          mutation = { kind: 'edit', content: [{ type: 'text', text }] }
        } else if (action === 'drop') {
          mutation = { kind: 'remove' }
        } else {
          mutation = { kind: 'steer' }
        }
        const mutated = await hostMutate(ctl, sessionId, itemId, mutation)
        await record(logFile, `QUEUE ${action} session=${sessionId} id=${itemId} ok=${String(mutated)}`)
        if (!mutated) {
          send(res, 409, {
            error: 'queue item is no longer pending',
            queue: await hostQueueView(ctl, sessionId),
          })
          return
        }
        send(res, 200, {
          ok: true,
          sessionId,
          item: itemId,
          dropped: action === 'drop',
          fired: action === 'fire',
          queue: await hostQueueView(ctl, sessionId),
        })
        return
      }

      const outboxMatch = /^\/api\/sessions\/([^/]+)\/outbox$/.exec(path)
      if (outboxMatch !== null && method === 'POST') {
        const ctl = controller()
        if (!ctl || typeof ctl.prompt !== 'function') {
          send(res, 503, { error: 'sessionController.prompt unavailable' })
          return
        }
        const body = await readJson(req, MAX_UPLOAD_BYTES)
        const rawImgs = Array.isArray(body.images) ? body.images : []
        const rawFiles = Array.isArray(body.files) ? body.files : []
        if (rawImgs.length > MAX_IMAGES) {
          send(res, 400, { error: `at most ${String(MAX_IMAGES)} images per request` })
          return
        }
        if (rawFiles.length > MAX_FILES) {
          send(res, 400, { error: `at most ${String(MAX_FILES)} files per request` })
          return
        }
        const text = String(body.text ?? '').trim()
        const content: Record<string, unknown>[] = []
        if (text !== '') content.push({ type: 'text', text })
        for (const item of rawImgs) {
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
          const part: Record<string, unknown> = { type: 'image', mediaType, data }
          const name = String(img.name ?? '').trim().slice(0, 80)
          if (name !== '') part.name = name
          content.push(part)
        }
        const savedFiles = await saveMobileFiles(rawFiles)
        if (savedFiles.text !== '') content.push({ type: 'text', text: savedFiles.text })
        if (content.length === 0) {
          send(res, 400, { error: 'nothing to send' })
          return
        }
        const sessionId = decodeURIComponent(outboxMatch[1])
        const { mode, running, known } = await pickMode(ctl, sessionId, body.mode === 'steer' ? 'steer' : 'queue')
        if (mode === 'queue' && running) {
          const itemId = await hostEnqueue(ctl, sessionId, content)
          await record(logFile, `200 POST outbox session=${sessionId} mode=queue host=${itemId} parts=${String(content.length)}`)
          send(res, 200, {
            ok: true,
            sessionId,
            mode: 'queue',
            queued: true,
            item: itemId,
            parts: content.length,
            queue: await hostQueueView(ctl, sessionId),
          })
          return
        }
        const result = await Promise.resolve(
          ctl.prompt(
            { requestId: randomBytes(16).toString('hex'), sessionId, mode, content },
            AbortSignal.timeout(120000),
          ),
        )
        await record(logFile, `200 POST outbox session=${sessionId} mode=${mode} parts=${String(content.length)} known=${String(known)}`)
        send(res, 200, { ok: true, sessionId, mode, running, parts: content.length, result: result ?? null })
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
        // 手机刚在这个会话里发过消息：紧接着模型可能就要提问，先记一笔，
        // 免得首轮轮询还没跟上就把题卡推给了桌面。
        phoneSessionAt.set(sessionId, Date.now())

        // 空闲会话用 queue 只会得到 accepted:true，什么都不会发生（控制器把消息塞进
        // 一个永远不会被 drain 的邮箱）。实测只有 steer 才会替空闲会话起一轮。
        // 运行中的会话反过来不能用 steer（会打断当前轮），沿用调用方的 mode。
        const { mode: effective, running, known } = await pickMode(ctl, sessionId, requested)

        if (effective === 'queue' && running) {
          // 交给宿主排队（桌面版输入区能看到「待发送」），手机端改 / 删 / 插队走
          // sessionController.updateQueue。
          const itemId = await hostEnqueue(ctl, sessionId, [{ type: 'text', text }])
          await record(logFile, `200 POST send session=${sessionId} mode=queue host=${itemId}`)
          send(res, 200, {
            ok: true,
            sessionId,
            mode: 'queue',
            queued: true,
            item: itemId,
            queue: await hostQueueView(ctl, sessionId),
          })
          return
        }

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

      // --- Host extras: installed plugins -------------------------------------
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
          const deps: Record<string, string> =
            typeof bag.dependencies === 'object' && bag.dependencies !== null
              ? (bag.dependencies as Record<string, string>)
              : {}
          const dsh: Record<string, unknown> =
            typeof bag.dsh === 'object' && bag.dsh !== null ? (bag.dsh as Record<string, unknown>) : {}
          const prof: Record<string, unknown> =
            typeof dsh.profile === 'object' && dsh.profile !== null ? (dsh.profile as Record<string, unknown>) : {}
          const bundles = Array.isArray(prof.bundles) ? (prof.bundles as unknown[]).map((x) => String(x)) : []
          const items = Object.keys(deps).map((dep) => {
            const version = String(deps[dep] ?? '')
            return { name: dep, version, enabled: bundles.indexOf(dep) >= 0, local: version.startsWith('link:') }
          })
          items.sort((a, b) => (a.enabled === b.enabled ? a.name.localeCompare(b.name) : a.enabled ? -1 : 1))
          groups.push({ profile, items })
        }
        send(res, 200, { ok: true, groups })
        return
      }

      // --- Host extras: enable or disable one installed plugin ---------------
      // 开关写的是 profile 自己的包清单（`dsh.profile.bundles`），宿主只在启动时读
      // 一次，所以改完必然要重启宿主才生效：响应里 `restartRequired` 明说不含糊，
      // 手机端照着提示，不假装立刻生效。
      if (path === '/api/host/plugins/toggle' && method === 'POST') {
        let body: Record<string, unknown> = {}
        try {
          body = await readJson(req)
        } catch (error) {
          send(res, 400, { error: `请求体不是合法 JSON：${error instanceof Error ? error.message : String(error)}` })
          return
        }
        const profile = String(body.profile ?? '').trim()
        const name = String(body.name ?? '').trim()
        if (!PROFILE_DIR_NAME.test(profile)) {
          send(res, 400, { error: 'profile 名字不合法' })
          return
        }
        if (!BUNDLE_NAME.test(name)) {
          send(res, 400, { error: '插件名不合法' })
          return
        }
        if (typeof body.enabled !== 'boolean') {
          send(res, 400, { error: 'enabled 必须是布尔值' })
          return
        }
        const enabled = body.enabled
        const file = join(dshHome(), 'profiles', profile, 'package.json')
        let raw = ''
        try {
          raw = readFileSync(file, 'utf8')
        } catch {
          send(res, 404, { error: `找不到 profile ${profile} 的 package.json` })
          return
        }
        let bag: Record<string, unknown>
        try {
          bag = JSON.parse(raw) as Record<string, unknown>
        } catch {
          send(res, 500, { error: `profile ${profile} 的 package.json 不是合法 JSON，先手动修好再开开关` })
          return
        }
        const deps: Record<string, unknown> =
          typeof bag.dependencies === 'object' && bag.dependencies !== null
            ? (bag.dependencies as Record<string, unknown>)
            : {}
        if (typeof deps[name] !== 'string') {
          // 只列 dependencies 里的包，所以这里大多意味着别人刚改过清单。
          send(res, 400, { error: `${name} 不在 profile ${profile} 的依赖里，这里只能开关已安装的插件` })
          return
        }
        const dsh: Record<string, unknown> =
          typeof bag.dsh === 'object' && bag.dsh !== null ? (bag.dsh as Record<string, unknown>) : {}
        const prof: Record<string, unknown> =
          typeof dsh.profile === 'object' && dsh.profile !== null ? (dsh.profile as Record<string, unknown>) : {}
        const current = Array.isArray(prof.bundles) ? (prof.bundles as unknown[]).map((x) => String(x)) : []
        const present = current.indexOf(name) >= 0
        if (present === enabled) {
          // 已经在要的状态：不碰文件，也不误导用户去重启。
          await record(logFile, `200 POST plugin-toggle ${profile}/${name} enabled=${String(enabled)} changed=false`)
          send(res, 200, { ok: true, profile, name, enabled, changed: false, restartRequired: false })
          return
        }
        const nextBundles = enabled ? current.concat([name]) : current.filter((x) => x !== name)
        // 只换 bundles 这一个字段，其余键与顺序照原样写回。
        bag.dsh = { ...dsh, profile: { ...prof, bundles: nextBundles } }
        const text = `${JSON.stringify(bag, null, 2)}\n`
        const temp = `${file}.${String(process.pid)}.tmp`
        try {
          // 先留一份原样备份：手改坏的清单还有得救。
          writeFileSync(`${file}.bak`, raw, 'utf8')
          writeFileSync(temp, text, 'utf8')
          renameSync(temp, file)
        } catch (error) {
          try {
            unlinkSync(temp)
          } catch {
            // 临时文件没写成，或已被 rename 消费。
          }
          const message = error instanceof Error ? error.message : String(error)
          await record(logFile, `500 POST plugin-toggle ${profile}/${name} write failed: ${message}`)
          send(res, 500, { error: `写 profile 清单失败：${message}` })
          return
        }
        await record(logFile, `200 POST plugin-toggle ${profile}/${name} enabled=${String(enabled)} changed=true`)
        send(res, 200, { ok: true, profile, name, enabled, changed: true, restartRequired: true })
        return
      }

      // --- Host extras: agent team --------------------------------------------
      // The Team service has no list method: membership and the task board are
      // Session-log events, so the log is the only durable source. Latest record
      // per id wins (tasks carry a revision), and the panel stays read-only.
      const teamMatch = /^\/api\/sessions\/([^/]+)\/team$/.exec(path)
      if (teamMatch !== null && method === 'GET') {
        const sessionId = decodeURIComponent(teamMatch[1])
        const file = findSessionFile(sessionId)
        if (file === null) {
          send(res, 404, { error: 'session log not found' })
          return
        }
        let enabled = false
        let sawMode = false
        const members = new Map<string, Record<string, unknown>>()
        const tasks = new Map<string, Record<string, unknown>>()
        let lines: string[] = []
        try {
          lines = readSessionLines(file)
        } catch (error) {
          send(res, 500, { error: `cannot read session log: ${String(error)}` })
          return
        }
        for (const line of lines) {
          let ev: any
          try {
            ev = JSON.parse(line)
          } catch {
            continue
          }
          const type = String(ev?.type ?? '')
          if (type === 'team/mode') {
            sawMode = true
            enabled = ev?.data?.enabled === true
            continue
          }
          if (type === 'team/member') {
            const member = ev?.data?.member
            if (member !== null && typeof member === 'object') {
              members.set(String(member.id ?? ''), {
                id: String(member.id ?? ''),
                name: String(member.name ?? ''),
                description: String(member.description ?? ''),
                phase: String(member.phase ?? ''),
                error: String(member.error ?? '')
              })
            }
            continue
          }
          if (type === 'team/task') {
            const task = ev?.data?.task
            if (task !== null && typeof task === 'object') {
              const id = String(task.id ?? '')
              const seen = tasks.get(id)
              const revision = Number(task.revision ?? 0)
              if (seen === undefined || Number(seen.revision ?? -1) <= revision) {
                tasks.set(id, {
                  id,
                  revision,
                  subject: String(task.subject ?? ''),
                  description: String(task.description ?? ''),
                  status: String(task.status ?? 'pending'),
                  ownerName: String(task.ownerName ?? ''),
                  ownerId: String(task.ownerId ?? '')
                })
              }
            }
          }
        }
        const taskRows = Array.from(tasks.values())
          .filter((task) => task.status !== 'deleted')
          .sort((a, b) => {
            const rank = (s: unknown): number =>
              s === 'in_progress' ? 0 : s === 'pending' ? 1 : s === 'completed' ? 2 : 3
            const delta = rank(a.status) - rank(b.status)
            return delta !== 0 ? delta : String(a.subject).localeCompare(String(b.subject))
          })
        send(res, 200, {
          ok: true,
          sessionId,
          enabled,
          sawMode,
          members: Array.from(members.values()),
          tasks: taskRows
        })
        return
      }

      // Team mode is the one Team write the phone needs. The host service takes
      // the live root Agent (not a session id) and flushes the Session itself, so
      // both halves have to run in-process here; a missing Agent is a retryable
      // 503 rather than a thrown route.
      const teamModeMatch = /^\/api\/sessions\/([^/]+)\/team\/mode$/.exec(path)
      if (teamModeMatch !== null && method === 'POST') {
        let body: Record<string, unknown> = {}
        try {
          body = await readJson(req)
        } catch (error) {
          send(res, 400, { error: `请求体不是合法 JSON：${error instanceof Error ? error.message : String(error)}` })
          return
        }
        const rawEnabled = body.enabled
        if (typeof rawEnabled !== 'boolean') {
          send(res, 400, { error: 'enabled 必须是布尔值' })
          return
        }
        const enabled = rawEnabled
        const sessionId = decodeURIComponent(teamModeMatch[1])
        const svc = service('agentTeams')
        if (svc === null || typeof svc.setEnabled !== 'function') {
          send(res, 503, { error: '这台电脑没有挂载智能体团队（agentTeams 服务不可用）' })
          return
        }
        const agents = service('agents')
        const agent: unknown = agents !== null && typeof agents.get === 'function' ? agents.get(sessionId) : null
        if (agent === null || agent === undefined) {
          send(res, 503, { error: '这个会话在电脑上没有打开：先在电脑端点开它一次，再回来切换' })
          return
        }
        try {
          // setEnabled 先追加 team/mode 事件、再 await 宿主自己 flush；flush 不吃
          // AbortSignal，所以这里不假装有硬超时，等待上限交给手机端 readTimeout。
          // 它内部用到 this.ctx，必须保留服务实例作为 receiver。
          const change = svc.setEnabled as (a: unknown, v: boolean) => unknown
          await Promise.resolve(change.call(svc, agent, enabled))
        } catch (error) {
          const code = typeof (error as { code?: unknown }).code === 'string' ? String((error as { code: string }).code) : ''
          const message = error instanceof Error ? error.message : String(error)
          // Only the tree root may switch: a subagent Session answers TEAM_LEAD_REQUIRED.
          const status = code === 'TEAM_LEAD_REQUIRED' ? 409 : 500
          const readable = code === 'TEAM_LEAD_REQUIRED'
            ? '这个会话是子智能体，请到它的根会话里切换智能体协作'
            : `电脑端拒绝了这个切换：${message}`
          await record(logFile, `${String(status)} POST team-mode session=${sessionId} enabled=${String(enabled)} code=${code} err=${message}`)
          send(res, status, { error: readable })
          return
        }
        await record(logFile, `200 POST team-mode session=${sessionId} enabled=${String(enabled)}`)
        send(res, 200, { ok: true, enabled })
        return
      }

      // --- Host extras: scheduled tasks ---------------------------------------
      if (path === '/api/host/schedules' && method === 'GET') {
        // 两种来源（活服务与磁盘上的单元）都由 normalizeScheduleTask 归一，手机端
        // 只渲染一种行，不必猜宿主内部结构。
        const svc = service('schedule')
        if (svc !== null && typeof svc.list === 'function') {
          const page: unknown = await Promise.resolve((svc.list as (arg: unknown) => unknown)({ limit: 100 }))
          const bag = (page !== null && typeof page === 'object' ? page : {}) as Record<string, unknown>
          const rows = Array.isArray(bag.items) ? (bag.items as unknown[]) : []
          send(res, 200, { ok: true, source: 'service', items: rows.map(normalizeScheduleTask) })
          return
        }
        let raw = ''
        try {
          raw = readFileSync(join(dshHome(), 'storages', 'schedule.json'), 'utf8')
        } catch (err) {
          send(res, 503, { error: `scheduled tasks unavailable: ${err instanceof Error ? err.message : String(err)}` })
          return
        }
        let items: unknown[] = []
        try {
          const bag = JSON.parse(raw) as { tables?: { tasks?: Record<string, unknown> } }
          const table = (bag.tables !== undefined && bag.tables.tasks !== undefined ? bag.tables.tasks : {}) as Record<string, unknown>
          items = Object.keys(table).map((key) => normalizeScheduleTask(table[key]))
        } catch (err) {
          send(res, 500, { error: `cannot read scheduled tasks: ${err instanceof Error ? err.message : String(err)}` })
          return
        }
        send(res, 200, { ok: true, source: 'file', items })
        return
      }

      // --- Host extras: one write on a scheduled task -------------------------
      // 宿主把四种动作拆在两个方法上：`edit`（更新时带 active 补丁、以及 delete）
      // 和 `run`（立即执行一次）。不同版本的方法与动词都变过，所以先探测能力，再
      // 逐条候选试到对得上为止；一条都对不上就回 501 并说明原因，不假装成功。
      const scheduleActionMatch = /^\/api\/host\/schedules\/([^/]+)\/action$/.exec(path)
      if (scheduleActionMatch !== null && method === 'POST') {
        let body: Record<string, unknown> = {}
        try {
          body = await readJson(req)
        } catch (error) {
          send(res, 400, { error: `请求体不是合法 JSON：${error instanceof Error ? error.message : String(error)}` })
          return
        }
        const action = String(body.action ?? '').trim()
        if (action !== 'pause' && action !== 'resume' && action !== 'run' && action !== 'delete') {
          send(res, 400, { error: 'action 只能是 pause、resume、run 或 delete' })
          return
        }
        let id = ''
        try {
          id = decodeURIComponent(scheduleActionMatch[1])
        } catch {
          send(res, 400, { error: '任务 id 编码不合法' })
          return
        }
        if (id === '') {
          send(res, 400, { error: '任务 id 不能为空' })
          return
        }
        const svc = service('schedule')
        if (svc === null) {
          send(res, 503, { error: '这台电脑没有挂载自动化任务（schedule 服务不可用）' })
          return
        }
        const canEdit = typeof svc.edit === 'function'
        const canRun = typeof svc.run === 'function'
        // 每条候选保持服务实例作 receiver（服务内部要用 this.ctx），所以一律
        // 写成 svc.xxx(...) 的成员调用，不把方法取出来单独存。
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
            // 新版宿主：update 带 active 补丁；老版宿主：直接认 pause/resume 动词。
            attempts.push({
              label: 'edit.update',
              call: () => Promise.resolve(svc.edit({ id, action: 'update', patch: { active: wantResume } })),
            })
            attempts.push({ label: `edit.${action}`, call: () => Promise.resolve(svc.edit({ id, action })) })
          }
        }
        if (attempts.length === 0) {
          await record(logFile, `501 POST schedule-action id=${id} action=${action} unsupported`)
          send(res, 501, {
            error: '这台电脑的定时任务服务不支持这个操作（缺少 edit / run 方法），升级 DSH 后再试',
            action,
            unsupported: true,
          })
          return
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
            // 只有「不认这个参数或动词」才换下一条候选；别的错误换参数只会让同一
            // 个动作写第二次，所以直接停在这里。
            const retryable = coded === 'schedule/input-invalid'
              || /unknown action|invalid|not supported|unsupported/i.test(message)
            if (!retryable) {
              const archived = coded === 'schedule/target-archived' || message.indexOf('schedule/target-archived') >= 0
              const status = archived ? 409 : 500
              const readable = archived
                ? '这个任务的目标会话已归档，先在电脑上恢复那个会话再试'
                : `电脑端拒绝了这个操作：${message}`
              await record(logFile, `${String(status)} POST schedule-action id=${id} action=${action} code=${coded} err=${message}`)
              send(res, status, { error: readable, action })
              return
            }
          }
        }
        if (used === '') {
          const detail = failures.length > 0 ? failures[failures.length - 1] : '没有可用的方法'
          await record(logFile, `501 POST schedule-action id=${id} action=${action} none-of: ${failures.join(' | ')}`)
          send(res, 501, {
            error: `这台电脑的定时任务服务没有接受这个操作，升级 DSH 后再试（${detail}）`,
            action,
            unsupported: true,
            tried: failures,
          })
          return
        }
        const bag = (result !== null && typeof result === 'object' ? result : {}) as Record<string, unknown>
        const code = typeof bag.code === 'string' ? bag.code : ''
        if (code === 'schedule_not_found') {
          await record(logFile, `404 POST schedule-action id=${id} action=${action} not-found`)
          send(res, 404, { error: '这个任务在电脑上已经不存在了，刷新列表看看', action })
          return
        }
        if (code === 'schedule_conflict') {
          await record(logFile, `409 POST schedule-action id=${id} action=${action} conflict`)
          send(res, 409, { error: '任务刚被别处改过，刷新列表再试一次', action })
          return
        }
        if (code === 'schedule_execution_pending') {
          await record(logFile, `409 POST schedule-action id=${id} action=${action} pending`)
          send(res, 409, { error: '这个任务正在执行，稍等一会儿再点「立即」', action, pending: true })
          return
        }
        if (bag.deleted === true) {
          await record(logFile, `200 POST schedule-action id=${id} action=${action} via=${used} deleted`)
          send(res, 200, { ok: true, action, id, via: used, deleted: true })
          return
        }
        await record(logFile, `200 POST schedule-action id=${id} action=${action} via=${used}`)
        send(res, 200, { ok: true, action, id, via: used, item: normalizeScheduleTask(result) })
        return
      }

      // --- Workspace files ----------------------------------------------------
      // cwd 有两个来源：活着的 Session 对象，以及 sessionController 的列表投影。
      // 重启之后大部分会话并不在内存里，只有列表里还留着 cwd，所以这里必须问列表。
      const tidyCwd = (raw: string): string => raw.replace(/\\\\/g, '\\')
      const cwdOf = async (sid: string): Promise<string> => {
        const sessions = service('sessions')
        if (sessions !== null && typeof sessions.get === 'function') {
          let live: unknown = null
          try {
            live = (sessions.get as (id: string) => unknown)(sid)
          } catch {
            live = null
          }
          if (live !== null && live !== undefined) {
            const cwd = (live as Record<string, unknown>).cwd
            if (typeof cwd === 'string' && cwd.length > 0) return tidyCwd(cwd)
          }
        }
        const ctl = controller()
        if (ctl !== null && typeof ctl.list === 'function') {
          try {
            const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(10000)))
            const row = projectSessions(listed).find((r) => r.id === sid)
            if (row !== undefined && row.cwd.length > 0) return tidyCwd(row.cwd)
          } catch {
            // Fall through to the process directory.
          }
        }
        return ''
      }
      // 会话没有 cwd 时（比如从手机新建的空会话）退回宿主进程的当前目录，
      // 并把 fallback 标给 App，界面上说明一句，而不是直接 404。
      const rootOf = async (sid: string): Promise<{ root: string; fallback: boolean }> => {
        const cwd = await cwdOf(sid)
        if (cwd !== '') return { root: cwd, fallback: false }
        try {
          return { root: process.cwd(), fallback: true }
        } catch {
          return { root: '', fallback: false }
        }
      }
      const underRoot = (root: string, rel: string): string | null => {
        const base = resolve(root)
        const target = resolve(base, rel.length === 0 ? '.' : rel)
        if (!(target === base || target.startsWith(base + sep))) return null
        // 字面校验挡不住符号链接 / junction：解析真实路径再比一次，否则工作区里的一个链接
        // 就能把 /fs/file、/fs/raw、/fs/download 引到工作区之外读任意文件。
        try {
          const realBase = realpathSync(base)
          const realTarget = realpathSync(target)
          return realTarget === realBase || realTarget.startsWith(realBase + sep) ? realTarget : null
        } catch {
          // 解析失败：路径不存在就按原样交给调用方报 404，存在却解析不了则一律拒绝。
          return existsSync(target) ? null : target
        }
      }

      const fsMatch = /^\/api\/sessions\/([^/]+)\/fs$/.exec(path)
      if (fsMatch !== null && method === 'GET') {
        const sid = decodeURIComponent(fsMatch[1])
        const picked = await rootOf(sid)
        const root = picked.root
        if (root === '') {
          send(res, 404, { error: `session ${sid} has no working directory` })
          return
        }
        const rel = String(url.searchParams.get('path') ?? '')
        const target = underRoot(root, rel)
        if (target === null) {
          send(res, 400, { error: 'path escapes the working directory' })
          return
        }
        let names: string[] = []
        try {
          names = readdirSync(target)
        } catch (err) {
          send(res, 404, { error: `cannot read folder: ${err instanceof Error ? err.message : String(err)}` })
          return
        }
        const entries: Array<{ name: string; dir: boolean; size: number; mtime: number }> = []
        for (const name of names) {
          if (name === '.git' || name === 'node_modules' || name === '.hvigor' || name === 'oh_modules') continue
          try {
            const st = statSync(join(target, name))
            entries.push({ name, dir: st.isDirectory(), size: st.size, mtime: Math.round(st.mtimeMs) })
          } catch {
            // Unreadable entries are simply skipped.
          }
        }
        entries.sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1))
        const trimmed = entries.length > 400 ? entries.slice(0, 400) : entries
        await record(logFile, `200 GET fs session=${sid} path=${rel} n=${trimmed.length}`)
        send(res, 200, { ok: true, root, path: rel, entries: trimmed, more: entries.length > trimmed.length, fallback: picked.fallback })
        return
      }

      const fsFileMatch = /^\/api\/sessions\/([^/]+)\/fs\/file$/.exec(path)
      if (fsFileMatch !== null && method === 'GET') {
        const sid = decodeURIComponent(fsFileMatch[1])
        const root = (await rootOf(sid)).root
        const rel = String(url.searchParams.get('path') ?? '')
        const target = root === '' ? null : underRoot(root, rel)
        if (root === '' || target === null) {
          send(res, 400, { error: 'bad path' })
          return
        }
        const LIMIT = 512 * 1024
        let buf: Buffer
        try {
          const st = statSync(target)
          if (!st.isFile()) {
            send(res, 400, { error: 'not a file' })
            return
          }
          if (st.size > LIMIT) {
            send(res, 413, { error: `file is too large to preview (${st.size} bytes)` })
            return
          }
          buf = readFileSync(target)
        } catch (err) {
          send(res, 404, { error: `cannot read file: ${err instanceof Error ? err.message : String(err)}` })
          return
        }
        if (buf.indexOf(0) >= 0) {
          send(res, 415, { error: 'binary file: no text preview' })
          return
        }
        send(res, 200, { ok: true, name: String(rel).split(/[\\/]/).pop() ?? rel, size: buf.length, text: buf.toString('utf8') })
        return
      }

      const fsRawMatch = /^\/api\/sessions\/([^/]+)\/fs\/raw$/.exec(path)
      if (fsRawMatch !== null && method === 'GET') {
        const sid = decodeURIComponent(fsRawMatch[1])
        const root = (await rootOf(sid)).root
        const rel = String(url.searchParams.get('path') ?? '')
        const target = root === '' ? null : underRoot(root, rel)
        if (root === '' || target === null) {
          send(res, 400, { error: 'bad path' })
          return
        }
        const ext = extname(target).toLowerCase()
        const types: Record<string, string> = {
          '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp',
          '.gif': 'image/gif', '.bmp': 'image/bmp', '.svg': 'image/svg+xml',
        }
        const type = types[ext]
        if (type === undefined) {
          send(res, 415, { error: 'not an image' })
          return
        }
        let body: Buffer
        try {
          body = readFileSync(target)
        } catch (err) {
          send(res, 404, { error: `cannot read image: ${err instanceof Error ? err.message : String(err)}` })
          return
        }
        res.writeHead(200, { 'content-type': type, 'content-length': String(body.length), 'cache-control': 'private, max-age=60' })
        res.end(body)
        return
      }

      const fsDownloadMatch = /^\/api\/sessions\/([^/]+)\/fs\/download$/.exec(path)
      if (fsDownloadMatch !== null && method === 'GET') {
        const sid = decodeURIComponent(fsDownloadMatch[1])
        const root = (await rootOf(sid)).root
        const rel = String(url.searchParams.get('path') ?? '')
        const target = root === '' ? null : underRoot(root, rel)
        if (root === '' || target === null) {
          send(res, 400, { error: 'bad path' })
          return
        }
        const LIMIT = 64 * 1024 * 1024
        let body: Buffer
        try {
          const st = statSync(target)
          if (!st.isFile()) {
            send(res, 400, { error: 'not a file' })
            return
          }
          if (st.size > LIMIT) {
            send(res, 413, { error: `file is too large to download (${st.size} bytes)` })
            return
          }
          body = readFileSync(target)
        } catch (err) {
          send(res, 404, { error: `cannot read file: ${err instanceof Error ? err.message : String(err)}` })
          return
        }
        const name = String(rel).split(/[\\/]/).pop() ?? rel
        await record(logFile, `200 GET fs/download session=${sid} path=${rel} n=${body.length}`)
        res.writeHead(200, {
          'content-type': 'application/octet-stream',
          'content-length': String(body.length),
          'content-disposition': "attachment; filename*=UTF-8''" + encodeURIComponent(name),
          'cache-control': 'private, max-age=0',
        })
        res.end(body)
        return
      }

      // \u76ee\u6807\uff08goal\uff09\uff1a\u624b\u673a\u7aef\u5728\u8f93\u5165\u6846\u73af\u5f62\u7528\u91cf\u53f3\u4fa7\u70b9\u5f00\u9762\u677f\u67e5\u770b/\u4fee\u6539/\u6682\u505c/\u7ee7\u7eed/\u5b8c\u6210\u3002
    const goalMatch = /^\/api\/sessions\/([^/]+)\/goal(?:\/(action))?$/.exec(path)
    if (goalMatch) {
      const sid = goalMatch[1]
      const goalSvc = service('goals') as unknown as {
        get(agent: unknown): unknown
        pause(agent: unknown, ref: unknown): unknown
        resume(agent: unknown, ref: unknown): unknown
        complete(agent: unknown, ref: unknown): unknown
        clear(agent: unknown, ref: unknown): unknown
        edit(agent: unknown, ref: unknown, patch: unknown): unknown
      } | null
      if (goalSvc === null) {
        send(res, 503, { error: 'goals are unavailable on this host' })
        return true
      }
      const agent = (service('agents') as unknown as { get(id: string): unknown } | null)?.get(sid)
      if (agent === undefined || agent === null) {
        send(res, 503, { error: '\u8fd9\u4e2a\u4f1a\u8bdd\u5728\u7535\u8111\u4e0a\u6ca1\u6709\u6253\u5f00\uff1a\u5148\u5728\u7535\u8111\u70b9\u5f00\u5b83\u4e00\u6b21\uff0c\u518d\u56de\u6765\u770b\u76ee\u6807\u3002' })
        return true
      }
      const viewOf = (v: unknown): Record<string, unknown> | null => {
        if (v === undefined || v === null || typeof v !== 'object') {
          return null
        }
        const o = v as Record<string, unknown>
        return { id: o.id, objective: o.objective, phase: o.phase, revision: o.revision, roundsStarted: o.roundsStarted, maxGoalRounds: o.maxGoalRounds, activation: o.activation, updatedAt: o.updatedAt }
      }
      if (goalMatch[2] === undefined) {
        try {
          send(res, 200, { ok: true, sessionId: sid, goal: viewOf(goalSvc.get(agent)) })
        } catch (ex) {
          send(res, 500, { error: String(ex) })
        }
        return true
      }
      const body = await readJson(req)
      const action = typeof body.action === 'string' ? body.action : ''
      let current: Record<string, unknown> | null = null
      try {
        current = viewOf(goalSvc.get(agent))
      } catch (ex) {
        send(res, 500, { error: String(ex) })
        return true
      }
      if (current === null) {
        send(res, 404, { error: '\u8fd9\u4e2a\u4f1a\u8bdd\u73b0\u5728\u6ca1\u6709\u76ee\u6807' })
        return true
      }
      const ref = { id: current.id, revision: current.revision }
      try {
        if (action === 'pause') {
          goalSvc.pause(agent, ref)
        } else if (action === 'resume') {
          goalSvc.resume(agent, ref)
        } else if (action === 'complete') {
          goalSvc.complete(agent, ref)
        } else if (action === 'clear') {
          goalSvc.clear(agent, ref)
        } else if (action === 'edit') {
          const patch: Record<string, unknown> = {}
          if (typeof body.objective === 'string' && body.objective !== '') {
            patch.objective = body.objective
          }
          if (typeof body.maxGoalRounds === 'number' && body.maxGoalRounds > 0) {
            patch.maxGoalRounds = body.maxGoalRounds
          }
          goalSvc.edit(agent, ref, patch)
        } else {
          send(res, 400, { error: 'action must be pause, resume, complete, clear or edit' })
          return true
        }
        const after = action === 'clear' ? null : viewOf(goalSvc.get(agent))
        send(res, 200, { ok: true, sessionId: sid, action, goal: after })
      } catch (ex) {
        const err = ex as { code?: string; message?: string }
        send(res, 409, { error: err.message ?? String(ex), code: err.code ?? '' })
      }
      return true
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
    const alts = Array.isArray(snapshot.alts) ? (snapshot.alts as string[]) : []
    const payload = base.length > 0 ? pairPayload(base, String(snapshot.code ?? ''), alts) : ''
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
    const alts = Array.isArray(snapshot.alts) ? (snapshot.alts as string[]) : []
    const text = asked !== null && asked.length > 0
      ? asked
      : base.length > 0
        ? pairPayload(base, String(snapshot.code ?? ''), alts)
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


