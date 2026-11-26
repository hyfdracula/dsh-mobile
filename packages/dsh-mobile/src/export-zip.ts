/**
 * 会话日志导出工具：生成完整 Markdown 与零外部依赖的标准 ZIP 压缩包（仅用 `node:zlib`）。
 */
import { hostname } from 'node:os'
import * as zlib from 'node:zlib'
import type { SessionStats } from './projections.ts'
import { VERSION } from './state.ts'
import type { ChatMessage } from './transcript.ts'

export interface ZipEntryInput {
  name: string
  data: Buffer | string
}

function computeCrc32(buf: Buffer): number {
  return zlib.crc32(buf) >>> 0
}

function dosDateTime(date: Date): { dosTime: number; dosDate: number } {
  const year = Math.max(1980, Math.min(2107, date.getFullYear()))
  const month = date.getMonth() + 1
  const day = date.getDate()
  const hours = date.getHours()
  const minutes = date.getMinutes()
  const seconds = Math.floor(date.getSeconds() / 2)
  const dosTime = (hours << 11) | (minutes << 5) | seconds
  const dosDate = ((year - 1980) << 9) | (month << 5) | day
  return { dosTime, dosDate }
}

/** 构造规范的 PKZIP 归档字节（DEFLATE 压缩，UTF-8 文件名标志位）。 */
export function buildZipBuffer(entries: readonly ZipEntryInput[], now = new Date()): Buffer {
  const { dosTime, dosDate } = dosDateTime(now)
  const localParts: Buffer[] = []
  const centralParts: Buffer[] = []
  let offset = 0

  for (const entry of entries) {
    const nameBuf = Buffer.from(entry.name.replace(/\\/g, '/'), 'utf8')
    const rawBuf = Buffer.isBuffer(entry.data) ? entry.data : Buffer.from(entry.data, 'utf8')
    const crc = computeCrc32(rawBuf)
    const deflated = zlib.deflateRawSync(rawBuf)
    const useDeflate = deflated.length < rawBuf.length
    const method = useDeflate ? 8 : 0
    const compBuf = useDeflate ? deflated : rawBuf

    // Local File Header (30 bytes + name)
    const localHeader = Buffer.alloc(30)
    localHeader.writeUInt32LE(0x04034b50, 0)
    localHeader.writeUInt16LE(20, 4) // version needed: 2.0
    localHeader.writeUInt16LE(0x0800, 6) // UTF-8 filename flag
    localHeader.writeUInt16LE(method, 8)
    localHeader.writeUInt16LE(dosTime, 10)
    localHeader.writeUInt16LE(dosDate, 12)
    localHeader.writeUInt32LE(crc, 14)
    localHeader.writeUInt32LE(compBuf.length, 18)
    localHeader.writeUInt32LE(rawBuf.length, 22)
    localHeader.writeUInt16LE(nameBuf.length, 26)
    localHeader.writeUInt16LE(0, 28)

    localParts.push(localHeader, nameBuf, compBuf)

    // Central Directory File Header (46 bytes + name)
    const cdHeader = Buffer.alloc(46)
    cdHeader.writeUInt32LE(0x02014b50, 0)
    cdHeader.writeUInt16LE(20, 4) // version made by
    cdHeader.writeUInt16LE(20, 6) // version needed
    cdHeader.writeUInt16LE(0x0800, 8) // UTF-8 flag
    cdHeader.writeUInt16LE(method, 10)
    cdHeader.writeUInt16LE(dosTime, 12)
    cdHeader.writeUInt16LE(dosDate, 14)
    cdHeader.writeUInt32LE(crc, 16)
    cdHeader.writeUInt32LE(compBuf.length, 20)
    cdHeader.writeUInt32LE(rawBuf.length, 24)
    cdHeader.writeUInt16LE(nameBuf.length, 28)
    cdHeader.writeUInt16LE(0, 30) // extra len
    cdHeader.writeUInt16LE(0, 32) // comment len
    cdHeader.writeUInt16LE(0, 34) // disk number
    cdHeader.writeUInt16LE(0, 36) // internal attrs
    cdHeader.writeUInt32LE(0, 38) // external attrs
    cdHeader.writeUInt32LE(offset, 42)

    centralParts.push(cdHeader, nameBuf)
    offset += localHeader.length + nameBuf.length + compBuf.length
  }

  const centralDir = Buffer.concat(centralParts)
  const eocd = Buffer.alloc(22)
  eocd.writeUInt32LE(0x06054b50, 0)
  eocd.writeUInt16LE(0, 4)
  eocd.writeUInt16LE(0, 6)
  eocd.writeUInt16LE(entries.length, 8)
  eocd.writeUInt16LE(entries.length, 10)
  eocd.writeUInt32LE(centralDir.length, 12)
  eocd.writeUInt32LE(offset, 16)
  eocd.writeUInt16LE(0, 20)

  return Buffer.concat([...localParts, centralDir, eocd])
}

/** 将会话消息轨迹渲染为清晰可读的 Markdown 导出文本。 */
export function renderSessionMarkdown(options: {
  sessionId: string
  title: string
  cwd: string
  messages: readonly ChatMessage[]
  stats: SessionStats
  exportedAt?: string
}): string {
  const exportedAt = options.exportedAt ?? new Date().toISOString()
  const lines: string[] = [
    `# ${options.title || options.sessionId}`,
    '',
    `- 会话 ID: \`${options.sessionId}\``,
    ...(options.cwd !== '' ? [`- 工作目录: \`${options.cwd}\``] : []),
    `- 导出时间: ${exportedAt}`,
    `- 轮次 / 步骤 / 工具调用: ${String(options.stats.turns)} / ${String(options.stats.steps)} / ${String(options.stats.toolCalls)}`,
    `- Token 统计: 输入 ${String(options.stats.tokens.uncachedInputTokens)} · 输出 ${String(options.stats.tokens.outputTokens)} · 缓存命中 ${String(options.stats.tokens.cacheReadTokens)}`,
    '',
    '---',
    '',
  ]

  for (const msg of options.messages) {
    const roleLabel = msg.role === 'user' ? '用户' : '助手'
    const ts = msg.time > 0 ? ` (${new Date(msg.time).toISOString()})` : ''
    lines.push(`## ${roleLabel}${ts}`)
    lines.push('')
    if (msg.thinking !== undefined && msg.thinking.trim() !== '') {
      lines.push('<details>')
      lines.push('<summary>思考过程</summary>')
      lines.push('')
      lines.push(msg.thinking.trim())
      lines.push('')
      lines.push('</details>')
      lines.push('')
    }
    if (msg.tools !== undefined && msg.tools.length > 0) {
      lines.push('**工具调用:**')
      for (const tool of msg.tools) {
        const summary = tool.summary !== '' ? ` — ${tool.summary}` : ''
        lines.push(`- \`${tool.name}\` [${tool.status}]${summary}`)
      }
      lines.push('')
    }
    if (msg.text.trim() !== '') {
      lines.push(msg.text.trim())
      lines.push('')
    }
    if (msg.images !== undefined && msg.images.length > 0) {
      lines.push(`> 附带 ${String(msg.images.length)} 张图片附件`)
      lines.push('')
    }
  }

  return `${lines.join('\n').trimEnd()}\n`
}

/** 构造导出元数据 JSON 字符串。 */
export function buildExportMetaJson(options: {
  sessionId: string
  title: string
  cwd: string
  stats: SessionStats
  messageCount: number
  exportedAt: string
}): string {
  return `${JSON.stringify({
    sessionId: options.sessionId,
    title: options.title,
    cwd: options.cwd,
    exportedAt: options.exportedAt,
    host: hostname(),
    pluginVersion: VERSION,
    messageCount: options.messageCount,
    stats: options.stats,
  }, null, 2)}\n`
}
