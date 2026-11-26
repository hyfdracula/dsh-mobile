import { appVersion, envLine } from './Feedback';

const MAX_ENTRIES: number = 500;
const MAX_DETAIL_LEN: number = 240;

function pad2(n: number): string {
  return n < 10 ? '0' + String(n) : String(n);
}

function pad3(n: number): string {
  if (n < 10) {
    return '00' + String(n);
  }
  if (n < 100) {
    return '0' + String(n);
  }
  return String(n);
}

function nowStamp(): string {
  const d: Date = new Date();
  return pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) + ' ' +
    pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds()) + '.' +
    pad3(d.getMilliseconds());
}

/**
 * 连接与远控诊断日志（R7）：
 * 维护容量 500 条的内存环形缓冲，只记录时间戳、类别（PROBE / NET / API / SSE / PAIR）、
 * HTTP 方法、脱敏路径、状态码、耗时与简短结果，绝不记录长期令牌、短签名或对话正文。
 */
export class LinkLog {
  private static ring: string[] = [];

  /** 剥离 URL / 日志片段中的敏感查询参数与 Bearer 凭据。 */
  static sanitize(raw: string): string {
    if (raw === '') {
      return '';
    }
    let clean: string = raw
      .replace(/([?&](?:t|sig|token|payload|c|key|g|grant)=)[^&\s#]+/gi, '$1***')
      .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer ***');
    if (clean.length > MAX_DETAIL_LEN) {
      clean = clean.slice(0, MAX_DETAIL_LEN) + '...';
    }
    return clean;
  }

  /** 记录一条诊断事件。 */
  static record(cat: string, detail: string): void {
    const tag: string = cat !== '' ? cat.toUpperCase() : 'INFO';
    const line: string = nowStamp() + ' [' + tag + '] ' + LinkLog.sanitize(detail);
    LinkLog.ring.push(line);
    while (LinkLog.ring.length > MAX_ENTRIES) {
      LinkLog.ring.shift();
    }
  }

  /** 当前已缓冲的日志条数。 */
  static count(): number {
    return LinkLog.ring.length;
  }

  /** 取最近 limit 条日志（按时间正序，末尾为最新）。 */
  static recent(limit: number = 100): string[] {
    if (limit <= 0 || LinkLog.ring.length === 0) {
      return [];
    }
    if (limit >= LinkLog.ring.length) {
      return LinkLog.ring.slice();
    }
    return LinkLog.ring.slice(LinkLog.ring.length - limit);
  }

  /** 清空内存诊断缓冲。 */
  static clear(): void {
    LinkLog.ring = [];
  }

  /** 拼装环境头 + 最近 500 条日志文本，供复制或通过 Saver.saveText 导出 .txt。 */
  static exportContent(appVer: string = ''): string {
    const ver: string = appVer !== '' ? appVer : appVersion();
    const d: Date = new Date();
    const exportedAt: string = String(d.getFullYear()) + '-' + pad2(d.getMonth() + 1) + '-' +
      pad2(d.getDate()) + ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
    const header: string[] = [
      '# Agent Mobile 连接诊断日志',
      '导出时间: ' + exportedAt,
      '应用版本: ' + (ver !== '' ? ver : 'unknown'),
      '运行环境: ' + envLine(),
      '记录条数: ' + String(LinkLog.ring.length),
      '说明: 已自动剥离令牌、签名与对话正文',
      '----------------------------------------'
    ];
    const body: string[] = LinkLog.recent(MAX_ENTRIES);
    if (body.length === 0) {
      header.push('(暂无连接日志)');
      return header.join('\n');
    }
    return header.join('\n') + '\n' + body.join('\n');
  }
}
