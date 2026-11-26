/**
 * 心跳自动化消息净化（L2）：
 * 宿主定时/后台自动化回合有时会把 XML 结构的 <heartbeat>...</heartbeat> 写入会话记录，
 * 这里精准抽取其中面向用户的干净正文（<message> 或 <instructions>），
 * 屏蔽 <automation_id> / <decision> 等内部元信息标签，同时保留外围普通正文。
 */

function extractTag(block: string, tag: string): string {
  const openRe: RegExp = new RegExp('<' + tag + '(?:\\s[^>]*)?>', 'i');
  const openMatch: RegExpExecArray | null = openRe.exec(block);
  if (openMatch === null) {
    return '';
  }
  const start: number = openMatch.index + openMatch[0].length;
  const closeTag: string = '</' + tag + '>';
  const lower: string = block.toLowerCase();
  const end: number = lower.indexOf(closeTag.toLowerCase(), start);
  const raw: string = end >= 0 ? block.slice(start, end) : block.slice(start);
  return raw.trim();
}

function stripKnownMetaTags(block: string): string {
  let s: string = block;
  const metaTags: string[] = [
    'automation_id',
    'automationId',
    'decision',
    'reason',
    'schedule',
    'timestamp',
    'run_id',
    'runId',
    'status',
    'meta'
  ];
  for (let i = 0; i < metaTags.length; i++) {
    const tag: string = metaTags[i];
    const re: RegExp = new RegExp('<' + tag + '(?:\\s[^>]*)?>[\\s\\S]*?<\\/' + tag + '>', 'gi');
    s = s.replace(re, '');
  }
  s = s.replace(/<\/?heartbeat(?:\s[^>]*)?>/gi, '');
  return s.trim();
}

/**
 * 判断消息是否包含 <heartbeat> 包裹结构。
 */
export function isHeartbeatText(text: string): boolean {
  if (text === '') {
    return false;
  }
  return /<heartbeat(?:\s[^>]*)?>/i.test(text);
}

/**
 * 抽取 <heartbeat> 中的干净正文；非心跳消息原样返回。
 * role 为 'user' 时优先取 <instructions> 再取 <message>；
 * 其他角色（如 'assistant'）优先取 <message> 再取 <instructions>。
 */
export function heartbeatBodyOf(text: string, role: string): string {
  if (!isHeartbeatText(text)) {
    return text;
  }
  const openRe: RegExp = /<heartbeat(?:\s[^>]*)?>/i;
  const openMatch: RegExpExecArray | null = openRe.exec(text);
  if (openMatch === null) {
    return text;
  }
  const blockStart: number = openMatch.index;
  const innerStart: number = blockStart + openMatch[0].length;
  const lower: string = text.toLowerCase();
  const closePos: number = lower.indexOf('</heartbeat>', innerStart);
  const inner: string = closePos >= 0 ? text.slice(innerStart, closePos) : text.slice(innerStart);
  const prefix: string = text.slice(0, blockStart).trim();
  const suffix: string = closePos >= 0 ? text.slice(closePos + '</heartbeat>'.length).trim() : '';

  const msg: string = extractTag(inner, 'message');
  const instr: string = extractTag(inner, 'instructions');
  const decision: string = extractTag(inner, 'decision');

  let body: string = '';
  if (role === 'user') {
    body = instr !== '' ? instr : msg;
  } else {
    body = msg !== '' ? msg : instr;
  }
  if (body === '') {
    const summary: string = extractTag(inner, 'summary');
    const content: string = extractTag(inner, 'content');
    body = summary !== '' ? summary : content;
  }
  if (body === '') {
    body = stripKnownMetaTags(inner);
  }
  if (body === '' && decision !== '') {
    body = decision;
  }

  const parts: string[] = [];
  if (prefix !== '') {
    parts.push(prefix);
  }
  if (body !== '') {
    parts.push(body);
  }
  if (suffix !== '') {
    parts.push(suffix);
  }
  return parts.join('\n\n').trim();
}
