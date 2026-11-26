/**
 * Git 状态与 Unified Diff 路由（G5）：
 * - `GET /api/sessions/:id/git/status`
 * - `GET /api/sessions/:id/git/diff?path=<rel>&staged=0|1`
 * 所有子进程调用强制 `windowsHide: true`。
 */
import { execFile } from 'node:child_process'
import { existsSync, openSync, readSync, closeSync, statSync } from 'node:fs'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { send } from '../http-util.ts'
import type { WorkspaceFsHelper } from './workspace-fs.ts'

const MAX_DIFF_BYTES = 200 * 1024

function runGit(cwd: string, args: string[], timeout = 5000): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolvePromise) => {
    execFile(
      'git',
      args,
      { cwd, windowsHide: true, timeout, maxBuffer: 2 * 1024 * 1024, encoding: 'utf8' },
      (error, stdout, stderr) => {
        if (error !== null) {
          const code = typeof (error as { code?: unknown }).code === 'number' ? (error as { code: number }).code : 1
          resolvePromise({ code, stdout: String(stdout ?? ''), stderr: String(stderr ?? error.message) })
          return
        }
        resolvePromise({ code: 0, stdout: String(stdout ?? ''), stderr: String(stderr ?? '') })
      },
    )
  })
}

/** 解码 Git porcelain C 风格转义路径（如八进制 UTF-8 字节与引号）。 */
function unquoteGitPath(raw: string): string {
  const s = raw.trim()
  if (!s.startsWith('"') || !s.endsWith('"') || s.length < 2) return s
  const inner = s.slice(1, -1)
  const bytes: number[] = []
  for (let i = 0; i < inner.length; i += 1) {
    const ch = inner[i] as string
    if (ch === '\\' && i + 1 < inner.length) {
      const next = inner[i + 1] as string
      if (next >= '0' && next <= '7' && i + 3 < inner.length) {
        const oct = inner.slice(i + 1, i + 4)
        if (/^[0-7]{3}$/.test(oct)) {
          bytes.push(Number.parseInt(oct, 8))
          i += 3
          continue
        }
      }
      i += 1
      const map: Record<string, number> = { n: 10, r: 13, t: 9, '\\': 92, '"': 34 }
      bytes.push(map[next] ?? next.charCodeAt(0))
      continue
    }
    const encoded = Buffer.from(ch, 'utf8')
    for (const b of encoded) bytes.push(b)
  }
  return Buffer.from(bytes).toString('utf8')
}

function parsePorcelainStatus(output: string): {
  branch: string
  ahead: number
  behind: number
  files: Array<{ path: string; status: string; staged: boolean }>
} {
  let branch = ''
  let ahead = 0
  let behind = 0
  const files: Array<{ path: string; status: string; staged: boolean }> = []

  for (const rawLine of output.split(/\r?\n/)) {
    if (rawLine.length === 0) continue
    if (rawLine.startsWith('## ')) {
      let head = rawLine.slice(3).trim()
      const bracketMatch = /\[([^\]]+)\]$/.exec(head)
      if (bracketMatch !== null) {
        const meta = bracketMatch[1] ?? ''
        const aMatch = /ahead\s+(\d+)/.exec(meta)
        const bMatch = /behind\s+(\d+)/.exec(meta)
        if (aMatch !== null) ahead = Number.parseInt(aMatch[1] ?? '0', 10) || 0
        if (bMatch !== null) behind = Number.parseInt(bMatch[1] ?? '0', 10) || 0
        head = head.slice(0, bracketMatch.index).trim()
      }
      const initMatch = /^(?:No commits yet on|Initial commit on)\s+(.+)$/.exec(head)
      if (initMatch !== null) {
        branch = (initMatch[1] ?? '').trim()
      } else {
        branch = (head.split('...')[0] ?? '').trim()
      }
      continue
    }
    if (rawLine.length < 4) continue
    const x = rawLine[0] ?? ' '
    const y = rawLine[1] ?? ' '
    const xy = `${x}${y}`.trim() || '?'
    let targetPath = rawLine.slice(3)
    if ((x === 'R' || x === 'C' || y === 'R' || y === 'C') && targetPath.includes(' -> ')) {
      const parts = targetPath.split(' -> ')
      targetPath = parts[parts.length - 1] ?? targetPath
    }
    const cleanPath = unquoteGitPath(targetPath)
    const staged = x !== ' ' && x !== '?' && x !== '!'
    files.push({ path: cleanPath, status: xy, staged })
  }

  return { branch, ahead, behind, files }
}

/** 为未跟踪文本文件拼装标准新文件 Unified Diff。 */
function buildUntrackedDiff(filePath: string, displayRel: string): string {
  const norm = displayRel.replace(/\\/g, '/')
  let size = 0
  try {
    const st = statSync(filePath)
    if (!st.isFile()) return ''
    size = st.size
  } catch {
    return ''
  }
  const readLen = Math.min(size, MAX_DIFF_BYTES + 4096)
  const buf = Buffer.allocUnsafe(readLen)
  let fd: number | undefined
  let actual = 0
  try {
    fd = openSync(filePath, 'r')
    actual = readSync(fd, buf, 0, readLen, 0)
  } catch {
    return ''
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd)
      } catch {
        // ignore
      }
    }
  }
  const slice = buf.subarray(0, actual)
  if (slice.indexOf(0) >= 0) {
    return `diff --git a/${norm} b/${norm}\nnew file mode 100644\nBinary files /dev/null and b/${norm} differ\n`
  }
  const text = slice.toString('utf8')
  if (text.length === 0) {
    return `diff --git a/${norm} b/${norm}\nnew file mode 100644\n--- /dev/null\n+++ b/${norm}\n`
  }
  const rawLines = text.replace(/\r\n/g, '\n').split('\n')
  if (rawLines.length > 0 && rawLines[rawLines.length - 1] === '') {
    rawLines.pop()
  }
  const added = rawLines.map((l) => `+${l}`).join('\n')
  return [
    `diff --git a/${norm} b/${norm}`,
    'new file mode 100644',
    '--- /dev/null',
    `+++ b/${norm}`,
    `@@ -0,0 +1,${String(rawLines.length)} @@`,
    added,
    '',
  ].join('\n')
}

/** 按 UTF-8 安全字节边界截断到最多 200 KB。 */
function truncateUtf8(text: string, maxBytes: number): { text: string; truncated: boolean } {
  const buf = Buffer.from(text, 'utf8')
  if (buf.length <= maxBytes) return { text, truncated: false }
  let sliced = buf.subarray(0, maxBytes).toString('utf8')
  if (sliced.endsWith('\uFFFD')) {
    sliced = sliced.slice(0, -1)
  }
  return { text: sliced, truncated: true }
}

export function createGitRoutes(fsHelper: WorkspaceFsHelper): {
  tryHandle: (req: IncomingMessage, res: ServerResponse, url: URL, path: string, method: string) => Promise<boolean>
} {
  const tryHandle = async (
    _req: IncomingMessage,
    res: ServerResponse,
    url: URL,
    path: string,
    method: string,
  ): Promise<boolean> => {
    const statusMatch = /^\/api\/sessions\/([^/]+)\/git\/status$/.exec(path)
    if (statusMatch !== null && method === 'GET') {
      const sid = decodeURIComponent(statusMatch[1] as string)
      const picked = await fsHelper.rootOf(sid)
      if (picked.root === '' || !existsSync(picked.root)) {
        send(res, 200, { ok: true, isRepo: false, branch: '', ahead: 0, behind: 0, files: [] })
        return true
      }
      const out = await runGit(picked.root, ['status', '--porcelain=v1', '-b'], 5000)
      if (out.code !== 0) {
        send(res, 200, { ok: true, isRepo: false, branch: '', ahead: 0, behind: 0, files: [] })
        return true
      }
      const parsed = parsePorcelainStatus(out.stdout)
      send(res, 200, {
        ok: true,
        isRepo: true,
        branch: parsed.branch,
        ahead: parsed.ahead,
        behind: parsed.behind,
        files: parsed.files,
      })
      return true
    }

    const diffMatch = /^\/api\/sessions\/([^/]+)\/git\/diff$/.exec(path)
    if (diffMatch !== null && method === 'GET') {
      const sid = decodeURIComponent(diffMatch[1] as string)
      const rel = String(url.searchParams.get('path') ?? '').trim()
      if (rel === '') {
        send(res, 400, { error: 'path is required' })
        return true
      }
      const staged = url.searchParams.get('staged') === '1' || url.searchParams.get('staged') === 'true'
      const picked = await fsHelper.rootOf(sid)
      if (picked.root === '') {
        send(res, 404, { error: 'session has no working directory' })
        return true
      }
      const target = fsHelper.underRoot(picked.root, rel)
      if (target === null) {
        send(res, 400, { error: 'path escapes the working directory' })
        return true
      }

      const args = staged
        ? ['diff', '--cached', '--no-ext-diff', '--no-color', '--', rel]
        : ['diff', '--no-ext-diff', '--no-color', '--', rel]
      const resDiff = await runGit(picked.root, args, 5000)
      let diffText = resDiff.code === 0 ? resDiff.stdout : ''

      // 若工作区 diff 为空且非 staged，检查是否为未跟踪新文件（??）并拼装新文件 diff。
      if (!staged && diffText.length === 0 && existsSync(target)) {
        const stOut = await runGit(picked.root, ['status', '--porcelain=v1', '--', rel], 4000)
        if (stOut.code === 0 && stOut.stdout.trimStart().startsWith('??')) {
          diffText = buildUntrackedDiff(target, rel)
        }
      }

      const capped = truncateUtf8(diffText, MAX_DIFF_BYTES)
      send(res, 200, {
        ok: true,
        path: rel,
        diff: capped.text,
        truncated: capped.truncated,
      })
      return true
    }

    return false
  }

  return { tryHandle }
}
