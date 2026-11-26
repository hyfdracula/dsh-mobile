/**
 * 跨平台（重点适配 Windows + Electron）安全子进程工具：
 * - 解析 npm `.cmd` shim 直接定位 `.exe` 或 `node.exe + .js`，彻底杜绝 `shell: true` 注入；
 * - 强制真实 Node 可执行文件（避免 Electron 宿主下误用 Electron 二进制跑 CLI）；
 * - Windows 进程树清理（`taskkill /PID <pid> /T /F`）防止孤儿进程残留；
 * - 工作目录 `realpathSync` 校验。
 */
import { execFile, spawn, type ChildProcess } from 'node:child_process'
import { existsSync, readFileSync, realpathSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { delimiter, dirname, join, resolve } from 'node:path'

export interface ResolvedCli {
  command: string
  prefixArgs: string[]
  displayPath: string
}

const cliCache = new Map<string, ResolvedCli | null>()
const versionCache = new Map<string, { version: string; at: number }>()
const VERSION_TTL_MS = 5 * 60 * 1000

let cachedNodeExe: string | null = null

/** 解析系统真实 `node` 可执行文件（Electron 内 `process.execPath` 不是纯 Node）。 */
export function resolveNodeExecutable(): string {
  if (cachedNodeExe !== null) return cachedNodeExe
  const isElectron = typeof (process.versions as Record<string, unknown>).electron === 'string'
  if (!isElectron && existsSync(process.execPath)) {
    cachedNodeExe = process.execPath
    return cachedNodeExe
  }

  const isWin = process.platform === 'win32'
  const candidates: string[] = []
  if (process.env.NODE_HOME) {
    candidates.push(join(process.env.NODE_HOME, isWin ? 'node.exe' : 'bin/node'))
  }
  if (isWin) {
    candidates.push(
      join(process.env.ProgramFiles || 'C:\\Program Files', 'nodejs', 'node.exe'),
      join(process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'nodejs', 'node.exe'),
      join(process.env.LOCALAPPDATA || '', 'Programs', 'nodejs', 'node.exe'),
    )
  } else {
    candidates.push('/usr/local/bin/node', '/usr/bin/node', '/opt/homebrew/bin/node')
  }

  const pathEnv = process.env.PATH || process.env.Path || ''
  for (const dir of pathEnv.split(delimiter)) {
    if (!dir) continue
    candidates.push(join(dir, isWin ? 'node.exe' : 'node'))
  }

  for (const c of candidates) {
    try {
      if (c && existsSync(c) && statSync(c).isFile()) {
        cachedNodeExe = c
        return cachedNodeExe
      }
    } catch {
      // skip invalid path
    }
  }
  cachedNodeExe = isWin ? 'node.exe' : 'node'
  return cachedNodeExe
}

/** 解析 Windows npm `.cmd` shim 指向的真实 `.exe` 或 `.js` 入口，免走 `cmd.exe`。 */
function parseWindowsCmdShim(cmdFile: string): ResolvedCli | null {
  try {
    const raw = readFileSync(cmdFile, 'utf8')
    const dp0 = dirname(cmdFile)
    const exeMatch = /"%dp0%\\([^"]+\.exe)"/i.exec(raw)
    if (exeMatch) {
      const target = resolve(dp0, exeMatch[1])
      if (existsSync(target)) {
        return { command: target, prefixArgs: [], displayPath: target }
      }
    }
    const jsMatch = /"%dp0%\\([^"]+\.(?:m?js|cjs))"/i.exec(raw)
    if (jsMatch) {
      const target = resolve(dp0, jsMatch[1])
      if (existsSync(target)) {
        return { command: resolveNodeExecutable(), prefixArgs: [target], displayPath: target }
      }
    }
  } catch {
    // ignore
  }
  return null
}

/** 按白名单名称解析本机 CLI（禁止传入含路径分隔符或特殊字符的任意命令）。 */
export function resolveCliCommand(name: string, force = false): ResolvedCli | null {
  if (!/^[a-z0-9._-]+$/i.test(name)) {
    return null
  }
  if (!force && cliCache.has(name)) {
    return cliCache.get(name) ?? null
  }

  const isWin = process.platform === 'win32'
  const searchDirs: string[] = []
  if (isWin && process.env.APPDATA) {
    searchDirs.push(join(process.env.APPDATA, 'npm'))
  }
  if (isWin && process.env.LOCALAPPDATA) {
    searchDirs.push(join(process.env.LOCALAPPDATA, 'agy', 'bin'))
  }
  if (isWin && process.env.USERPROFILE) {
    searchDirs.push(join(process.env.USERPROFILE, '.local', 'bin'))
    searchDirs.push(join(process.env.USERPROFILE, '.antigravity', 'bin'))
  }
  const pathEnv = process.env.PATH || process.env.Path || ''
  for (const d of pathEnv.split(delimiter)) {
    if (d && !searchDirs.includes(d)) searchDirs.push(d)
  }

  for (const dir of searchDirs) {
    if (!dir) continue
    if (isWin) {
      const directExe = join(dir, `${name}.exe`)
      if (existsSync(directExe)) {
        const res: ResolvedCli = { command: directExe, prefixArgs: [], displayPath: directExe }
        cliCache.set(name, res)
        return res
      }
      const cmdShim = join(dir, `${name}.cmd`)
      if (existsSync(cmdShim)) {
        const parsed = parseWindowsCmdShim(cmdShim)
        if (parsed) {
          cliCache.set(name, parsed)
          return parsed
        }
      }
    } else {
      const direct = join(dir, name)
      try {
        if (existsSync(direct) && statSync(direct).isFile()) {
          const res: ResolvedCli = { command: direct, prefixArgs: [], displayPath: direct }
          cliCache.set(name, res)
          return res
        }
      } catch {
        // skip
      }
    }
  }

  cliCache.set(name, null)
  return null
}

/** 以非 shell 方式安全拉起已解析的白名单 CLI。 */
export function spawnCli(
  cli: ResolvedCli,
  args: string[],
  opts?: { cwd?: string; env?: NodeJS.ProcessEnv },
): ChildProcess {
  const fullArgs = [...cli.prefixArgs, ...args]
  const env: NodeJS.ProcessEnv = { ...process.env, ...(opts?.env ?? {}) }
  // 去掉 Electron 环境变量，防止下游 Node CLI 误以为处于 Electron 渲染环境
  delete env.ELECTRON_RUN_AS_NODE
  return spawn(cli.command, fullArgs, {
    cwd: opts?.cwd,
    env,
    shell: false,
    windowsHide: true,
    stdio: ['pipe', 'pipe', 'pipe'],
  })
}

/** 清理整个子进程树（Windows 用 `taskkill /T /F`，防止孙子进程残留占用文件锁）。 */
export function killProcessTree(child: ChildProcess | null | undefined): void {
  if (!child || child.killed) return
  const pid = child.pid
  if (pid === undefined || pid <= 0) {
    try {
      child.kill()
    } catch {
      // ignore
    }
    return
  }
  if (process.platform === 'win32') {
    try {
      execFile('taskkill', ['/PID', String(pid), '/T', '/F'], { windowsHide: true, timeout: 4000 }, () => {})
    } catch {
      // fallback below
    }
  }
  try {
    child.kill('SIGTERM')
  } catch {
    // ignore
  }
}

/** 校验并规范化工作目录；若为空或不存在，回退到用户主目录或抛错。 */
export function validateWorkingDir(cwd: string | undefined, fallbackHome = true): string {
  const raw = typeof cwd === 'string' ? cwd.trim() : ''
  if (raw === '') {
    if (fallbackHome) return homedir()
    throw new Error('工作目录不能为空')
  }
  if (raw.includes('\0')) {
    throw new Error('非法工作目录路径')
  }
  const real = realpathSync(raw)
  const st = statSync(real)
  if (!st.isDirectory()) {
    throw new Error('指定路径不是目录')
  }
  return real
}

/** 探测 CLI 版本号（带 5 分钟缓存，避免频繁拉起进程）。 */
export async function probeCliVersion(cli: ResolvedCli, force = false): Promise<string> {
  const key = cli.displayPath
  const cached = versionCache.get(key)
  if (!force && cached && Date.now() - cached.at < VERSION_TTL_MS) {
    return cached.version
  }
  const version = await new Promise<string>((resolveVer) => {
    let out = ''
    let settled = false
    const finish = (v: string): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolveVer(v)
    }
    const child = spawnCli(cli, ['--version'])
    const timer = setTimeout(() => {
      killProcessTree(child)
      finish('')
    }, 4500)
    child.stdout?.on('data', (d: Buffer) => {
      out += d.toString('utf8')
    })
    child.stderr?.on('data', (d: Buffer) => {
      out += d.toString('utf8')
    })
    child.on('error', () => finish(''))
    child.on('exit', () => {
      const firstLine = out
        .split(/\r?\n/)
        .map((s) => s.trim())
        .find((s) => s.length > 0)
      finish(firstLine ? firstLine.slice(0, 64) : '')
    })
  })
  versionCache.set(key, { version, at: Date.now() })
  return version
}
