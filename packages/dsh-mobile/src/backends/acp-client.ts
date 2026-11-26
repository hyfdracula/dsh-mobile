/**
 * 通用 ACP（Agent Client Protocol，JSON-RPC 2.0 over stdio）客户端引擎：
 * - 负责 `initialize` 握手、请求/响应路由、`session/update` 流式通知与 `session/request_permission` 双向审批；
 * - 支持任意兼容 ACP v1 的 CLI（如 OpenCode、Antigravity CLI `agy acp` 等）；
 * - 内置空闲超时回收与 Windows 进程树安全退出。
 */
import type { ChildProcess } from 'node:child_process'
import { killProcessTree, spawnCli, type ResolvedCli } from './process-util.ts'

export interface AcpPermissionOption {
  optionId: string
  name: string
  kind?: string
}

export interface AcpPermissionRequest {
  rpcId: number | string
  sessionId: string
  title: string
  toolCallId?: string
  rawInput?: unknown
  options: AcpPermissionOption[]
}

export interface AcpSessionUpdate {
  sessionId: string
  update: Record<string, unknown>
}

export interface AcpClientHooks {
  onSessionUpdate?: (ev: AcpSessionUpdate) => void
  onPermissionRequest?: (req: AcpPermissionRequest) => void
  onClose?: (err?: string) => void
}

interface PendingRpc {
  resolve: (val: unknown) => void
  reject: (err: Error) => void
  timer: ReturnType<typeof setTimeout>
}

const DEFAULT_IDLE_MS = 60 * 60 * 1000

export class AcpClient {
  private readonly cli: ResolvedCli
  private readonly extraArgs: string[]
  private readonly cwd: string
  private readonly hooks: AcpClientHooks
  private child: ChildProcess | null = null
  private stdoutBuf = ''
  private stderrTail: string[] = []
  private nextId = 1
  private readonly pending = new Map<number, PendingRpc>()
  private initPromise: Promise<Record<string, unknown>> | null = null
  private initResult: Record<string, unknown> | null = null
  private lastActivity = Date.now()
  private idleTimer: ReturnType<typeof setInterval> | null = null
  private activeTurns = 0

  constructor(cli: ResolvedCli, extraArgs: string[], cwd: string, hooks: AcpClientHooks = {}) {
    this.cli = cli
    this.extraArgs = extraArgs
    this.cwd = cwd
    this.hooks = hooks
  }

  get capabilities(): Record<string, unknown> {
    const caps = this.initResult?.agentCapabilities
    return caps !== null && typeof caps === 'object' ? (caps as Record<string, unknown>) : {}
  }

  private ensureProcess(): void {
    if (this.child && !this.child.killed && this.child.exitCode === null) return
    this.stdoutBuf = ''
    const child = spawnCli(this.cli, this.extraArgs, { cwd: this.cwd })
    this.child = child
    this.lastActivity = Date.now()

    child.stdout?.on('data', (chunk: Buffer) => {
      this.lastActivity = Date.now()
      this.stdoutBuf += chunk.toString('utf8')
      let nl: number
      while ((nl = this.stdoutBuf.indexOf('\n')) >= 0) {
        const line = this.stdoutBuf.slice(0, nl).trim()
        this.stdoutBuf = this.stdoutBuf.slice(nl + 1)
        if (!line) continue
        this.handleLine(line)
      }
    })

    child.stderr?.on('data', (chunk: Buffer) => {
      const lines = chunk.toString('utf8').split(/\r?\n/).map((s) => s.trim()).filter(Boolean)
      for (const l of lines) {
        this.stderrTail.push(l.slice(0, 240))
        if (this.stderrTail.length > 12) this.stderrTail.shift()
      }
    })

    child.on('exit', (code, signal) => {
      const tail = this.stderrTail.length > 0 ? ` :: ${this.stderrTail.slice(-2).join(' | ')}` : ''
      const reason = `ACP process exited (code=${String(code)}, signal=${String(signal)})${tail}`
      this.failAllPending(reason)
      this.child = null
      this.initPromise = null
      this.initResult = null
      this.hooks.onClose?.(reason)
    })

    child.on('error', (err) => {
      this.failAllPending(err.message)
      this.child = null
      this.initPromise = null
      this.initResult = null
      this.hooks.onClose?.(err.message)
    })

    if (!this.idleTimer) {
      this.idleTimer = setInterval(() => {
        if (this.activeTurns === 0 && this.child && Date.now() - this.lastActivity > DEFAULT_IDLE_MS) {
          this.dispose()
        }
      }, 60_000)
      this.idleTimer.unref?.()
    }
  }

  private failAllPending(reason: string): void {
    for (const [, p] of this.pending) {
      clearTimeout(p.timer)
      p.reject(new Error(reason))
    }
    this.pending.clear()
  }

  private writeFrame(frame: Record<string, unknown>): void {
    this.ensureProcess()
    if (!this.child?.stdin || this.child.stdin.destroyed) {
      throw new Error('ACP stdin is not writable')
    }
    this.lastActivity = Date.now()
    this.child.stdin.write(JSON.stringify(frame) + '\n')
  }

  private handleLine(line: string): void {
    let msg: Record<string, unknown>
    try {
      const parsed = JSON.parse(line)
      if (parsed === null || typeof parsed !== 'object') return
      msg = parsed as Record<string, unknown>
    } catch {
      return
    }

    // 1. Response to our outgoing request
    if (msg.id !== undefined && msg.method === undefined) {
      const id = Number(msg.id)
      const p = this.pending.get(id)
      if (!p) return
      this.pending.delete(id)
      clearTimeout(p.timer)
      if (msg.error !== undefined && msg.error !== null) {
        const errObj = msg.error as Record<string, unknown>
        const detail = typeof errObj.message === 'string' ? errObj.message : JSON.stringify(errObj)
        p.reject(new Error(detail))
      } else {
        p.resolve(msg.result)
      }
      return
    }

    // 2. Server -> Client bidirectional request (e.g. session/request_permission)
    if (msg.id !== undefined && typeof msg.method === 'string') {
      const rpcId = msg.id as number | string
      const params = (msg.params !== null && typeof msg.params === 'object' ? msg.params : {}) as Record<string, unknown>
      if (msg.method === 'session/request_permission') {
        const sid = typeof params.sessionId === 'string' ? params.sessionId : ''
        const tc = (params.toolCall !== null && typeof params.toolCall === 'object'
          ? params.toolCall
          : {}) as Record<string, unknown>
        const title =
          typeof tc.title === 'string' && tc.title.trim() !== ''
            ? tc.title
            : typeof tc.kind === 'string'
              ? `允许执行 ${tc.kind} 操作？`
              : '允许 Agent 执行此操作？'
        const rawOpts = Array.isArray(params.options) ? params.options : []
        const options: AcpPermissionOption[] = []
        for (const item of rawOpts) {
          if (item && typeof item === 'object') {
            const o = item as Record<string, unknown>
            const oid = typeof o.optionId === 'string' ? o.optionId : ''
            const name = typeof o.name === 'string' ? o.name : oid
            if (oid) {
              options.push({ optionId: oid, name, kind: typeof o.kind === 'string' ? o.kind : undefined })
            }
          }
        }
        if (this.hooks.onPermissionRequest) {
          this.hooks.onPermissionRequest({
            rpcId,
            sessionId: sid,
            title,
            toolCallId: typeof tc.toolCallId === 'string' ? tc.toolCallId : undefined,
            rawInput: tc.rawInput,
            options,
          })
        } else {
          // 无审批处理器时安全 fail-closed 拒绝
          this.replyPermission(rpcId, null)
        }
        return
      }
      // 未知服务端请求：明确返回 Method not found（绝不放行通用 fs/terminal RPC）
      try {
        this.writeFrame({
          jsonrpc: '2.0',
          id: rpcId,
          error: { code: -32601, message: `Unsupported client method: ${msg.method}` },
        })
      } catch {
        // ignore
      }
      return
    }

    // 3. Server -> Client notification
    if (typeof msg.method === 'string') {
      const params = (msg.params !== null && typeof msg.params === 'object' ? msg.params : {}) as Record<string, unknown>
      if (msg.method === 'session/update') {
        const sid = typeof params.sessionId === 'string' ? params.sessionId : ''
        const update = (params.update !== null && typeof params.update === 'object'
          ? params.update
          : {}) as Record<string, unknown>
        this.hooks.onSessionUpdate?.({ sessionId: sid, update })
      }
    }
  }

  /** 回应 `session/request_permission`：传 `optionId` 选中，传 `null` 取消拒绝。 */
  replyPermission(rpcId: number | string, optionId: string | null): void {
    const outcome =
      optionId !== null && optionId !== ''
        ? { outcome: 'selected', optionId }
        : { outcome: 'cancelled' }
    this.writeFrame({
      jsonrpc: '2.0',
      id: rpcId,
      result: { outcome },
    })
  }

  async initialize(): Promise<Record<string, unknown>> {
    if (this.initResult && this.child && this.child.exitCode === null) {
      return this.initResult
    }
    if (this.initPromise) return this.initPromise
    this.initPromise = this.request('initialize', {
      protocolVersion: 1,
      clientCapabilities: {},
      clientInfo: { name: 'agent-mobile', version: '3.0.0' },
    }, 20_000).then((res) => {
      this.initResult = (res !== null && typeof res === 'object' ? res : {}) as Record<string, unknown>
      return this.initResult
    }).catch((err) => {
      this.initPromise = null
      throw err
    })
    return this.initPromise
  }

  async request(method: string, params: Record<string, unknown>, timeoutMs = 30_000): Promise<unknown> {
    this.ensureProcess()
    const id = this.nextId++
    return await new Promise<unknown>((resolveReq, rejectReq) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        rejectReq(new Error(`ACP request timeout: ${method}`))
      }, timeoutMs)
      this.pending.set(id, { resolve: resolveReq, reject: rejectReq, timer })
      try {
        this.writeFrame({ jsonrpc: '2.0', id, method, params })
      } catch (err) {
        clearTimeout(timer)
        this.pending.delete(id)
        rejectReq(err instanceof Error ? err : new Error(String(err)))
      }
    })
  }

  notify(method: string, params: Record<string, unknown>): void {
    this.writeFrame({ jsonrpc: '2.0', method, params })
  }

  async listSessions(cwd?: string): Promise<Array<Record<string, unknown>>> {
    await this.initialize()
    const params: Record<string, unknown> = {}
    if (cwd) params.cwd = cwd
    try {
      const res = (await this.request('session/list', params, 20_000)) as Record<string, unknown> | null
      const arr = res && Array.isArray(res.sessions) ? res.sessions : []
      return arr.filter((x): x is Record<string, unknown> => x !== null && typeof x === 'object')
    } catch (err) {
      const msg = err instanceof Error ? err.message.toLowerCase() : String(err).toLowerCase()
      if (msg.includes('not found') || msg.includes('unsupported') || msg.includes('-32601')) {
        return []
      }
      throw err
    }
  }

  async setModel(sessionId: string, modelId: string): Promise<boolean> {
    await this.initialize()
    try {
      await this.request('session/set_model', { sessionId, modelId }, 15_000)
      return true
    } catch (err) {
      const msg = err instanceof Error ? err.message.toLowerCase() : String(err).toLowerCase()
      if (msg.includes('not found') || msg.includes('unsupported') || msg.includes('-32601')) {
        return false
      }
      throw err
    }
  }

  async newSession(cwd: string): Promise<{ sessionId: string; raw: Record<string, unknown> }> {
    await this.initialize()
    const res = (await this.request('session/new', { cwd, mcpServers: [] }, 25_000)) as Record<string, unknown>
    const sessionId = typeof res?.sessionId === 'string' ? res.sessionId : ''
    if (!sessionId) throw new Error('ACP session/new 未返回 sessionId')
    return { sessionId, raw: res }
  }

  async loadSession(sessionId: string, cwd: string): Promise<Record<string, unknown>> {
    await this.initialize()
    const res = await this.request('session/load', { sessionId, cwd, mcpServers: [] }, 45_000)
    return (res !== null && typeof res === 'object' ? res : {}) as Record<string, unknown>
  }

  async resumeSession(sessionId: string, cwd: string): Promise<Record<string, unknown>> {
    await this.initialize()
    const res = await this.request('session/resume', { sessionId, cwd, mcpServers: [] }, 30_000)
    return (res !== null && typeof res === 'object' ? res : {}) as Record<string, unknown>
  }

  async prompt(sessionId: string, promptBlocks: Array<Record<string, unknown>>): Promise<Record<string, unknown>> {
    await this.initialize()
    this.activeTurns++
    try {
      // 单轮最长允许 30 分钟（大型 coding turn）
      const res = await this.request('session/prompt', { sessionId, prompt: promptBlocks }, 30 * 60 * 1000)
      return (res !== null && typeof res === 'object' ? res : {}) as Record<string, unknown>
    } finally {
      this.activeTurns = Math.max(0, this.activeTurns - 1)
    }
  }

  cancel(sessionId: string): void {
    if (!this.child || this.child.exitCode !== null) return
    try {
      this.notify('session/cancel', { sessionId })
    } catch {
      // ignore
    }
  }

  dispose(): void {
    if (this.idleTimer) {
      clearInterval(this.idleTimer)
      this.idleTimer = null
    }
    this.failAllPending('ACP client disposed')
    killProcessTree(this.child)
    this.child = null
    this.initPromise = null
    this.initResult = null
  }
}
