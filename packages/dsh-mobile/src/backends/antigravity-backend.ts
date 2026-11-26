/**
 * Antigravity CLI 后端适配器（基于通用 ACP 引擎驱动 `agy acp` / `agy_acp_server`）：
 * - 按官方白名单顺序探测 `agy` -> `antigravity` -> `agy_acp_server` -> `antigravity-acp`；
 * - 通过 ACP stdio 协议完成会话新建、历史重放、流式增量输出、权限审批与模型切换；
 * - 无私有磁盘结构强依赖，完全遵循 ACP v1 规范。
 */
import { AcpSessionBackend, type AcpCliSpec } from './acp-backend.ts'
import { killProcessTree, resolveCliCommand, spawnCli } from './process-util.ts'
import type { BackendCapabilities, BackendModelOption } from './types.ts'

export const ANTIGRAVITY_CAPABILITIES: BackendCapabilities = {
  listExistingSessions: true,
  historyReplay: true,
  streamDelta: true,
  approval: true,
  abort: true,
  images: true,
  files: false,
  modelSwitch: true,
  reasoningEffort: false,
  planMode: false,
  goalMode: false,
  compact: false,
  fork: false,
  archivePin: false,
  webConsole: false,
}

export class AntigravityBackend extends AcpSessionBackend {
  readonly id = 'antigravity' as const
  readonly label = 'Antigravity'
  readonly capabilities = ANTIGRAVITY_CAPABILITIES

  protected autoApprovePermissions(): boolean {
    return true
  }

  protected override autoInitForList(): boolean {
    return true
  }

  protected override async listModelsViaCliFallback(): Promise<BackendModelOption[]> {
    const spec = this.ensureSpec()
    if (!spec || spec.args[0] !== 'acp') return []
    return await new Promise<BackendModelOption[]>((resolveModels) => {
      let out = ''
      let done = false
      const finish = (items: BackendModelOption[]): void => {
        if (done) return
        done = true
        clearTimeout(timer)
        resolveModels(items)
      }
      const child = spawnCli(spec.cli, ['models'])
      const timer = setTimeout(() => {
        killProcessTree(child)
        finish([])
      }, 12_000)
      child.stdout?.on('data', (d: Buffer) => {
        out += d.toString('utf8')
      })
      child.on('error', () => finish([]))
      child.on('exit', () => {
        const parsed: BackendModelOption[] = []
        const seen = new Set<string>()
        for (const rawLine of out.split(/\r?\n/)) {
          const line = rawLine.trim()
          if (!line) continue
          const tabIdx = line.indexOf('\t')
          let id = ''
          let name = ''
          if (tabIdx > 0) {
            id = line.slice(0, tabIdx).trim()
            name = line.slice(tabIdx + 1).trim()
          } else if (/^[a-z0-9][a-z0-9._-]{2,}$/i.test(line)) {
            id = line
            name = line
          } else {
            continue
          }
          if (!id || seen.has(id)) continue
          seen.add(id)
          parsed.push({
            id,
            name: name || id,
            provider: this.id,
          })
        }
        finish(parsed)
      })
    })
  }

  protected resolveSpec(force = false): AcpCliSpec | null {
    const agy = resolveCliCommand('agy', force)
    if (agy) return { cli: agy, args: ['acp', '--dangerously-skip-permissions'] }

    const antigravity = resolveCliCommand('antigravity', force)
    if (antigravity) return { cli: antigravity, args: ['acp', '--dangerously-skip-permissions'] }

    const server = resolveCliCommand('agy_acp_server', force)
    if (server) return { cli: server, args: ['--dangerously-skip-permissions'] }

    const hyphenServer = resolveCliCommand('antigravity-acp', force)
    if (hyphenServer) return { cli: hyphenServer, args: ['--dangerously-skip-permissions'] }

    return null
  }

  protected missingCliMessage(): string {
    return '未检测到 agy 命令（安装 Antigravity CLI 并执行 agy acp --login 后可用）'
  }
}
