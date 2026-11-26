/**
 * 远程交互式终端路由（R6）：
 * - 受 `allowTerminal` 开关控制（关闭返回 403）
 * - `POST /api/sessions/:id/terminal/open`
 * - `GET /api/sessions/:id/terminal/poll?since=<seq>`
 * - `POST /api/sessions/:id/terminal/input`
 * Windows 下使用 `powershell.exe -NoLogo -NoProfile` + UTF-8 (`chcp 65001`) + `windowsHide: true`。
 */
import { execFile, spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { existsSync, statSync } from 'node:fs'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { homedir } from 'node:os'
import { StringDecoder } from 'node:string_decoder'
import { readJson, send } from '../http-util.ts'
import { allowTerminal, record } from '../state.ts'
import type { WorkspaceFsHelper } from './workspace-fs.ts'

const MAX_TERM_BUFFER_BYTES = 64 * 1024
const IDLE_TTL_MS = 30 * 60 * 1000
const MAX_TERMINALS = 16

interface TermChunk {
  seq: number
  text: string
  bytes: number
}

interface TermSession {
  sessionId: string
  cwd: string
  proc: ChildProcessWithoutNullStreams | null
  running: boolean
  exitCode: number | null
  seq: number
  totalBytes: number
  chunks: TermChunk[]
  lastActiveAt: number
}

function killProcessTree(proc: ChildProcessWithoutNullStreams | null): void {
  if (proc === null) return
  const pid = proc.pid
  if (process.platform === 'win32' && typeof pid === 'number' && pid > 0) {
    execFile('taskkill', ['/PID', String(pid), '/T', '/F'], { windowsHide: true }, () => {
      // ignore exit error if already dead
    })
  }
  try {
    proc.kill('SIGTERM')
  } catch {
    // ignore
  }
}

export interface TerminalRoutesBundle {
  tryHandle: (req: IncomingMessage, res: ServerResponse, url: URL, path: string, method: string) => Promise<boolean>
  disposeTerminals: () => void
}

export function createTerminalRoutes(
  fsHelper: WorkspaceFsHelper,
  logFile: string,
): TerminalRoutesBundle {
  const terminals = new Map<string, TermSession>()

  const pushChunk = (term: TermSession, rawText: string): void => {
    if (rawText.length === 0) return
    let text = rawText
    let bytes = Buffer.byteLength(text, 'utf8')
    if (bytes > MAX_TERM_BUFFER_BYTES) {
      const buf = Buffer.from(text, 'utf8')
      text = buf.subarray(buf.length - MAX_TERM_BUFFER_BYTES).toString('utf8')
      if (text.startsWith('\uFFFD')) text = text.slice(1)
      bytes = Buffer.byteLength(text, 'utf8')
    }
    term.seq += 1
    term.chunks.push({ seq: term.seq, text, bytes })
    term.totalBytes += bytes
    term.lastActiveAt = Date.now()
    while (term.totalBytes > MAX_TERM_BUFFER_BYTES && term.chunks.length > 1) {
      const dropped = term.chunks.shift()
      if (dropped !== undefined) term.totalBytes -= dropped.bytes
    }
  }

  const outputSince = (term: TermSession, since: number): string =>
    term.chunks
      .filter((c) => c.seq > since)
      .map((c) => c.text)
      .join('')

  const spawnInto = (term: TermSession): void => {
    killProcessTree(term.proc)
    let proc: ChildProcessWithoutNullStreams
    if (process.platform === 'win32') {
      const initCmd = [
        'chcp 65001 > $null',
        '[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)',
        '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)',
        '$OutputEncoding = [System.Text.UTF8Encoding]::new($false)',
      ].join('; ')
      proc = spawn(
        'powershell.exe',
        ['-NoLogo', '-NoProfile', '-NoExit', '-Command', initCmd],
        {
          cwd: term.cwd,
          stdio: ['pipe', 'pipe', 'pipe'],
          windowsHide: true,
        },
      )
    } else {
      const sh = process.env.SHELL && process.env.SHELL.length > 0 ? process.env.SHELL : '/bin/sh'
      proc = spawn(sh, ['-i'], {
        cwd: term.cwd,
        stdio: ['pipe', 'pipe', 'pipe'],
        windowsHide: true,
        env: { ...process.env, TERM: 'dumb' },
      })
    }

    term.proc = proc
    term.running = true
    term.exitCode = null
    term.lastActiveAt = Date.now()

    const outDecoder = new StringDecoder('utf8')
    const errDecoder = new StringDecoder('utf8')

    proc.stdout.on('data', (buf: Buffer) => {
      pushChunk(term, outDecoder.write(buf))
    })
    proc.stderr.on('data', (buf: Buffer) => {
      pushChunk(term, errDecoder.write(buf))
    })
    proc.on('error', (err) => {
      pushChunk(term, `\n[terminal error: ${err.message}]\n`)
      if (term.proc === proc) {
        term.running = false
        term.exitCode = -1
        term.proc = null
      }
    })
    proc.on('close', (code) => {
      const tailOut = outDecoder.end()
      const tailErr = errDecoder.end()
      if (tailOut) pushChunk(term, tailOut)
      if (tailErr) pushChunk(term, tailErr)
      if (term.proc === proc) {
        term.running = false
        term.exitCode = code ?? 0
        term.proc = null
      }
    })
  }

  const resolveSessionCwd = async (sid: string): Promise<string> => {
    const picked = await fsHelper.rootOf(sid)
    if (picked.root !== '') {
      try {
        if (existsSync(picked.root) && statSync(picked.root).isDirectory()) {
          return picked.root
        }
      } catch {
        // fall through
      }
    }
    return homedir()
  }

  const openOrReuse = async (sid: string, forceRestart = false): Promise<TermSession> => {
    const existing = terminals.get(sid)
    if (existing !== undefined && existing.running && !forceRestart) {
      existing.lastActiveAt = Date.now()
      terminals.delete(sid)
      terminals.set(sid, existing)
      return existing
    }
    if (existing !== undefined) {
      killProcessTree(existing.proc)
      terminals.delete(sid)
    }

    while (terminals.size >= MAX_TERMINALS) {
      const oldestKey = terminals.keys().next().value
      if (oldestKey === undefined) break
      const oldest = terminals.get(oldestKey)
      if (oldest !== undefined) killProcessTree(oldest.proc)
      terminals.delete(oldestKey)
    }

    const cwd = await resolveSessionCwd(sid)
    const term: TermSession = {
      sessionId: sid,
      cwd,
      proc: null,
      running: false,
      exitCode: null,
      seq: 0,
      totalBytes: 0,
      chunks: [],
      lastActiveAt: Date.now(),
    }
    spawnInto(term)
    terminals.set(sid, term)
    // 短暂让出事件循环以便捕获首屏提示符（不阻塞长耗时）。
    await new Promise((r) => {
      setTimeout(r, 60)
    })
    return term
  }

  const sweepTimer = setInterval(() => {
    const now = Date.now()
    for (const [sid, term] of terminals) {
      if (now - term.lastActiveAt > IDLE_TTL_MS) {
        killProcessTree(term.proc)
        terminals.delete(sid)
        void record(logFile, `terminal idle-reclaimed session=${sid}`)
      }
    }
  }, 60_000)
  sweepTimer.unref?.()

  const disposeTerminals = (): void => {
    clearInterval(sweepTimer)
    for (const term of terminals.values()) {
      killProcessTree(term.proc)
      term.proc = null
      term.running = false
    }
    terminals.clear()
  }

  const tryHandle = async (
    req: IncomingMessage,
    res: ServerResponse,
    url: URL,
    path: string,
    method: string,
  ): Promise<boolean> => {
    const match = /^\/api\/sessions\/([^/]+)\/terminal\/(open|poll|input)$/.exec(path)
    if (match === null) return false

    const sid = decodeURIComponent(match[1] as string)
    const op = match[2] as 'open' | 'poll' | 'input'

    if (!allowTerminal()) {
      send(res, 403, { error: '电脑端已关闭远程终端权限' })
      return true
    }

    if (op === 'open' && method === 'POST') {
      const term = await openOrReuse(sid, false)
      await record(logFile, `200 POST terminal/open session=${sid} cwd=${term.cwd}`)
      send(res, 200, {
        ok: true,
        cwd: term.cwd,
        running: term.running,
        exitCode: term.exitCode,
        output: outputSince(term, 0),
        seq: term.seq,
      })
      return true
    }

    if (op === 'poll' && method === 'GET') {
      const sinceRaw = Number(url.searchParams.get('since') ?? '0')
      const since = Number.isFinite(sinceRaw) ? Math.max(Math.trunc(sinceRaw), 0) : 0
      const term = terminals.get(sid)
      if (term === undefined) {
        send(res, 200, { ok: true, running: false, exitCode: null, output: '', seq: 0 })
        return true
      }
      term.lastActiveAt = Date.now()
      send(res, 200, {
        ok: true,
        running: term.running,
        exitCode: term.exitCode,
        output: outputSince(term, since),
        seq: term.seq,
      })
      return true
    }

    if (op === 'input' && method === 'POST') {
      const body = await readJson(req, 256 * 1024)
      const action = typeof body.action === 'string' ? body.action.trim() : ''

      if (action === 'close') {
        const existing = terminals.get(sid)
        if (existing !== undefined) {
          killProcessTree(existing.proc)
          existing.proc = null
          existing.running = false
          terminals.delete(sid)
        }
        await record(logFile, `200 POST terminal/input close session=${sid}`)
        send(res, 200, {
          ok: true,
          running: false,
          exitCode: existing?.exitCode ?? 0,
          output: '',
          seq: existing?.seq ?? 0,
        })
        return true
      }

      if (action === 'restart') {
        const term = await openOrReuse(sid, true)
        await record(logFile, `200 POST terminal/input restart session=${sid}`)
        send(res, 200, {
          ok: true,
          cwd: term.cwd,
          running: term.running,
          exitCode: term.exitCode,
          output: outputSince(term, 0),
          seq: term.seq,
        })
        return true
      }

      if (action === 'sigint') {
        const term = terminals.get(sid)
        if (term === undefined) {
          send(res, 200, { ok: true, running: false, exitCode: null, output: '', seq: 0 })
          return true
        }
        term.lastActiveAt = Date.now()
        if (process.platform === 'win32') {
          // Windows 匿名管道无控制台 Ctrl+C 信号组：杀掉当前挂起命令进程树并原地重启常驻 shell，保留历史缓冲区。
          pushChunk(term, '\n^C\n')
          spawnInto(term)
        } else if (term.proc !== null) {
          try {
            term.proc.stdin.write('\x03')
            term.proc.kill('SIGINT')
          } catch {
            // ignore
          }
        }
        await record(logFile, `200 POST terminal/input sigint session=${sid}`)
        send(res, 200, {
          ok: true,
          running: term.running,
          exitCode: term.exitCode,
          seq: term.seq,
        })
        return true
      }

      if (action !== '') {
        send(res, 400, { error: 'action must be sigint, close or restart' })
        return true
      }

      const rawData = typeof body.data === 'string' ? body.data : ''
      if (rawData === '') {
        send(res, 400, { error: 'data or action is required' })
        return true
      }

      const term = await openOrReuse(sid, false)
      if (term.proc === null || !term.running) {
        send(res, 500, { error: '终端进程未能启动' })
        return true
      }

      const payload = body.raw === true || rawData.endsWith('\n') || rawData.endsWith('\r')
        ? rawData
        : `${rawData}\n`
      const lineEndingNormalized = process.platform === 'win32'
        ? payload.replace(/\r?\n/g, '\r\n')
        : payload
      term.proc.stdin.write(lineEndingNormalized, 'utf8')
      term.lastActiveAt = Date.now()

      send(res, 200, {
        ok: true,
        running: term.running,
        exitCode: term.exitCode,
        seq: term.seq,
      })
      return true
    }

    return false
  }

  return { tryHandle, disposeTerminals }
}
