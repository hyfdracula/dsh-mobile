/**
 * OpenCode 后端适配器（基于通用 ACP 引擎驱动 `opencode acp --pure`）：
 * - 发现本机已有 OpenCode 会话（ACP `session/list` + `opencode session list --format json` 兜底）；
 * - 通过 ACP `session/load` 重放历史消息到标准 `ChatMessage[]`；
 * - 通过 ACP `session/prompt` / `session/update` / `session/request_permission` 实现流式输出、审批弹窗与安全中断。
 */
import { homedir } from 'node:os'
import { AcpSessionBackend, type AcpCliSpec } from './acp-backend.ts'
import { killProcessTree, resolveCliCommand, spawnCli } from './process-util.ts'
import type { BackendCapabilities } from './types.ts'

export const OPENCODE_CAPABILITIES: BackendCapabilities = {
  listExistingSessions: true,
  historyReplay: true,
  streamDelta: true,
  approval: true,
  abort: true,
  images: true,
  files: false,
  modelSwitch: false,
  reasoningEffort: false,
  planMode: false,
  goalMode: false,
  compact: false,
  fork: false,
  archivePin: false,
  webConsole: false,
}

export class OpenCodeBackend extends AcpSessionBackend {
  readonly id = 'opencode' as const
  readonly label = 'OpenCode'
  readonly capabilities = OPENCODE_CAPABILITIES

  protected resolveSpec(force = false): AcpCliSpec | null {
    const cli = resolveCliCommand('opencode', force)
    if (!cli) return null
    return { cli, args: ['acp', '--pure', '--cwd', homedir()] }
  }

  protected missingCliMessage(): string {
    return '本机未检测到 opencode 命令'
  }

  /** 快速通过 CLI 列出本机历史会话（避免首次列举必须等整个 ACP 进程初始化）。 */
  protected override async listViaCliFallback(limit: number): Promise<Array<Record<string, unknown>>> {
    const spec = this.ensureSpec()
    if (!spec) return []
    return await new Promise((resolveList) => {
      let out = ''
      let done = false
      const finish = (rows: Array<Record<string, unknown>>): void => {
        if (done) return
        done = true
        clearTimeout(timer)
        resolveList(rows)
      }
      const child = spawnCli(spec.cli, ['session', 'list', '--format', 'json', '-n', String(limit)])
      const timer = setTimeout(() => {
        killProcessTree(child)
        finish([])
      }, 10_000)
      child.stdout?.on('data', (d: Buffer) => {
        out += d.toString('utf8')
      })
      child.on('error', () => finish([]))
      child.on('exit', () => {
        try {
          const parsed = JSON.parse(out.trim())
          if (Array.isArray(parsed)) {
            finish(parsed.filter((x): x is Record<string, unknown> => x !== null && typeof x === 'object'))
            return
          }
        } catch {
          // ignore
        }
        finish([])
      })
    })
  }
}
