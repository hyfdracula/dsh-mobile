/**
 * 完整 GFM Markdown 解析引擎（F13）：
 * - 块级：h1~h6、hr 分割线、N 反引号/~~~ 围栏代码块、精确表格（列对齐/动态列宽/内容指纹）、
 *   多级缩进无序与有序列表、- [ ] / - [x] 任务复选框、多行保留换行引用、独立公式块、普通段落。
 * - 行内：递归扫描支持 **粗体**、*斜体*、***粗斜体***、~~删除线~~、`行内代码`（含双反引号与粗体嵌套）、
 *   [文案](url) 链接、http(s):// 裸链接与 TeX 公式。
 */

import { texToText, looksLikeTex } from './TeX';

export interface MdSeg {
  t: string;
  b: boolean;
  c: boolean;
  i?: boolean;
  s?: boolean;
  href?: string;
}

export interface MdBlock {
  kind: string;
  /** 有序列表的序号（1 起）；其余块为 0 */
  ord: number;
  text: string;
  segs: MdSeg[];
  head: string[];
  rows: string[][];
  lang: string;
  /** 列表缩进层级 0..3 */
  indent?: number;
  /** 任务列表状态：-1 普通列表，0 未勾选，1 已勾选 */
  checked?: number;
  /** 表格列对齐：'left' | 'center' | 'right' */
  aligns?: string[];
  /** 表格每列推荐宽度（vp，范围 64..260） */
  colWidths?: number[];
  /** 块内容指纹：用于流式渲染 ForEach 稳定刷新 Key */
  fp?: string;
}

function hash32(s: string): string {
  let h: number = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0).toString(36);
}

/** 对非代码片段执行行内 TeX 转换，避免把反引号内的 `$HOME` 误转成公式。 */
function mathOutsideCode(raw: string): string {
  if (raw.indexOf('$') < 0 && raw.indexOf('\\(') < 0) {
    return raw;
  }
  let out: string = '';
  let i: number = 0;
  let plainStart: number = 0;
  const flushPlain = (end: number): void => {
    if (end <= plainStart) {
      return;
    }
    let chunk: string = raw.slice(plainStart, end);
    chunk = chunk.replace(/\\\((.+?)\\\)/g, (all: string, body: string): string => {
      return looksLikeTex(body) ? texToText(body) : all;
    });
    chunk = chunk.replace(/\$([^$\n]{1,300})\$/g, (all: string, body: string): string => {
      return looksLikeTex(body) ? texToText(body) : all;
    });
    out += chunk;
  };

  while (i < raw.length) {
    if (raw.charAt(i) === '`') {
      let ticks: number = 0;
      while (i + ticks < raw.length && raw.charAt(i + ticks) === '`') {
        ticks++;
      }
      const close: number = findClosingTicks(raw, i + ticks, ticks);
      if (close >= 0) {
        flushPlain(i);
        out += raw.slice(i, close + ticks);
        i = close + ticks;
        plainStart = i;
        continue;
      }
      i += ticks;
      continue;
    }
    i++;
  }
  flushPlain(raw.length);
  return out;
}

function findClosingTicks(s: string, from: number, count: number): number {
  let pos: number = from;
  while (pos < s.length) {
    if (s.charAt(pos) === '`') {
      let n: number = 0;
      while (pos + n < s.length && s.charAt(pos + n) === '`') {
        n++;
      }
      if (n === count) {
        return pos;
      }
      pos += n;
    } else {
      pos++;
    }
  }
  return -1;
}

function isWordChar(ch: string): boolean {
  if (ch === '') {
    return false;
  }
  const code: number = ch.charCodeAt(0);
  return (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    code === 95;
}

function findDelimClose(s: string, from: number, delim: string): number {
  let pos: number = from;
  const len: number = delim.length;
  while (pos <= s.length - len) {
    const ch: string = s.charAt(pos);
    if (ch === '\\') {
      pos += 2;
      continue;
    }
    if (ch === '`') {
      let ticks: number = 0;
      while (pos + ticks < s.length && s.charAt(pos + ticks) === '`') {
        ticks++;
      }
      const closeT: number = findClosingTicks(s, pos + ticks, ticks);
      if (closeT >= 0) {
        pos = closeT + ticks;
        continue;
      }
      pos += ticks;
      continue;
    }
    if (s.startsWith(delim, pos)) {
      // 单星号斜体遇到双星号时，若前后可匹配双星号则优先跳过，直到单星号闭合
      if (len === 1 && pos + 1 < s.length && s.charAt(pos + 1) === delim) {
        pos += 2;
        continue;
      }
      const prev: string = pos > 0 ? s.charAt(pos - 1) : '';
      const next: string = pos + len < s.length ? s.charAt(pos + len) : '';
      if (prev === ' ' || prev === '\t' || prev === '\n') {
        pos += 1;
        continue;
      }
      if ((delim === '_' || delim === '__') && isWordChar(next)) {
        pos += 1;
        continue;
      }
      if (pos > from) {
        return pos;
      }
    }
    pos += 1;
  }
  return -1;
}

interface LinkMatch {
  label: string;
  href: string;
  end: number;
}

function parseMdLink(s: string, start: number): LinkMatch | null {
  if (s.charAt(start) !== '[') {
    return null;
  }
  let depth: number = 0;
  let closeBracket: number = -1;
  for (let i = start; i < s.length; i++) {
    const ch: string = s.charAt(i);
    if (ch === '\\') {
      i++;
      continue;
    }
    if (ch === '[') {
      depth++;
    } else if (ch === ']') {
      depth--;
      if (depth === 0) {
        closeBracket = i;
        break;
      }
    }
  }
  if (closeBracket < 0 || closeBracket + 1 >= s.length || s.charAt(closeBracket + 1) !== '(') {
    return null;
  }
  let pDepth: number = 0;
  let closeParen: number = -1;
  for (let i = closeBracket + 1; i < s.length; i++) {
    const ch: string = s.charAt(i);
    if (ch === '\\') {
      i++;
      continue;
    }
    if (ch === '(') {
      pDepth++;
    } else if (ch === ')') {
      pDepth--;
      if (pDepth === 0) {
        closeParen = i;
        break;
      }
    } else if (ch === '\n') {
      return null;
    }
  }
  if (closeParen < 0) {
    return null;
  }
  const label: string = s.slice(start + 1, closeBracket);
  let rawUrl: string = s.slice(closeBracket + 2, closeParen).trim();
  // 去掉可选的链接 title（如 url "title"）
  if (rawUrl.startsWith('<') && rawUrl.endsWith('>')) {
    rawUrl = rawUrl.slice(1, rawUrl.length - 1).trim();
  } else {
    const sp: number = rawUrl.search(/\s/);
    if (sp > 0) {
      rawUrl = rawUrl.slice(0, sp);
    }
  }
  if (rawUrl === '') {
    return null;
  }
  return { label: label, href: rawUrl, end: closeParen + 1 };
}

function parseBareUrl(s: string, start: number): string {
  if (!s.startsWith('https://', start) && !s.startsWith('http://', start)) {
    return '';
  }
  let end: number = start;
  while (end < s.length) {
    const ch: string = s.charAt(end);
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' ||
      ch === '<' || ch === '>' || ch === '"' || ch === '\'' || ch === '`') {
      break;
    }
    const code: number = ch.charCodeAt(0);
    // 遇到全角中文标点或汉字即截断裸链接
    if (code >= 0x3000) {
      break;
    }
    end++;
  }
  let url: string = s.slice(start, end);
  while (url.length > 0) {
    const tail: string = url.charAt(url.length - 1);
    if (tail === '.' || tail === ',' || tail === ';' || tail === ':' || tail === '!' || tail === '?') {
      url = url.slice(0, url.length - 1);
    } else if (tail === ')' && countChar(url, ')') > countChar(url, '(')) {
      url = url.slice(0, url.length - 1);
    } else if (tail === ']' && countChar(url, ']') > countChar(url, '[')) {
      url = url.slice(0, url.length - 1);
    } else {
      break;
    }
  }
  return url.length > 8 ? url : '';
}

function countChar(s: string, ch: string): number {
  let n: number = 0;
  for (let i = 0; i < s.length; i++) {
    if (s.charAt(i) === ch) {
      n++;
    }
  }
  return n;
}

function pushSeg(out: MdSeg[], t: string, b: boolean, c: boolean, it: boolean, st: boolean, href: string): void {
  if (t === '') {
    return;
  }
  if (out.length > 0) {
    const prev: MdSeg = out[out.length - 1];
    const prevI: boolean = prev.i === true;
    const prevS: boolean = prev.s === true;
    const prevHref: string = prev.href !== undefined ? prev.href : '';
    if (prev.b === b && prev.c === c && prevI === it && prevS === st && prevHref === href && !c) {
      prev.t += t;
      return;
    }
  }
  const seg: MdSeg = { t: t, b: b, c: c };
  if (it) {
    seg.i = true;
  }
  if (st) {
    seg.s = true;
  }
  if (href !== '') {
    seg.href = href;
  }
  out.push(seg);
}

function scanInline(
  text: string,
  out: MdSeg[],
  bold: boolean,
  italic: boolean,
  strike: boolean,
  href: string,
  depth: number
): void {
  if (text === '') {
    return;
  }
  if (depth > 8) {
    pushSeg(out, text, bold, false, italic, strike, href);
    return;
  }
  let i: number = 0;
  while (i < text.length) {
    const ch: string = text.charAt(i);

    // 反斜杠转义常见 Markdown 标点
    if (ch === '\\' && i + 1 < text.length) {
      const next: string = text.charAt(i + 1);
      if ('\\`*_{}[]()#+-.!~|'.indexOf(next) >= 0) {
        pushSeg(out, next, bold, false, italic, strike, href);
        i += 2;
        continue;
      }
    }

    // 行内代码（支持单反引号与多反引号）
    if (ch === '`') {
      let ticks: number = 0;
      while (i + ticks < text.length && text.charAt(i + ticks) === '`') {
        ticks++;
      }
      const close: number = findClosingTicks(text, i + ticks, ticks);
      if (close >= 0) {
        let code: string = text.slice(i + ticks, close);
        if (code.length >= 2 && code.startsWith(' ') && code.endsWith(' ') && code.trim() !== '') {
          code = code.slice(1, code.length - 1);
        }
        pushSeg(out, code, bold, true, italic, strike, href);
        i = close + ticks;
        continue;
      }
      pushSeg(out, text.slice(i, i + ticks), bold, false, italic, strike, href);
      i += ticks;
      continue;
    }

    // Markdown 链接 [label](url)
    if (ch === '[' && href === '') {
      const link: LinkMatch | null = parseMdLink(text, i);
      if (link !== null) {
        const displayLabel: string = link.label !== '' ? link.label : link.href;
        scanInline(displayLabel, out, bold, italic, strike, link.href, depth + 1);
        i = link.end;
        continue;
      }
    }

    // 裸链接 http(s)://...
    if (ch === 'h' && href === '' && (text.startsWith('https://', i) || text.startsWith('http://', i))) {
      const url: string = parseBareUrl(text, i);
      if (url !== '') {
        pushSeg(out, url, bold, false, italic, strike, url);
        i += url.length;
        continue;
      }
    }

    // 删除线 ~~...~~
    if (ch === '~' && text.startsWith('~~', i) && !strike) {
      const next: string = i + 2 < text.length ? text.charAt(i + 2) : '';
      if (next !== '' && next !== ' ' && next !== '\t' && next !== '\n') {
        const close: number = findDelimClose(text, i + 2, '~~');
        if (close > i + 2) {
          scanInline(text.slice(i + 2, close), out, bold, italic, true, href, depth + 1);
          i = close + 2;
          continue;
        }
      }
    }

    // 粗斜体 ***...*** / ___...___
    if ((ch === '*' && text.startsWith('***', i)) || (ch === '_' && text.startsWith('___', i))) {
      const delim: string = ch + ch + ch;
      const prev: string = i > 0 ? text.charAt(i - 1) : '';
      const next: string = i + 3 < text.length ? text.charAt(i + 3) : '';
      const boundaryOk: boolean = ch === '*' || !isWordChar(prev);
      if (boundaryOk && next !== '' && next !== ' ' && next !== '\t' && next !== '\n') {
        const close: number = findDelimClose(text, i + 3, delim);
        if (close > i + 3) {
          scanInline(text.slice(i + 3, close), out, true, true, strike, href, depth + 1);
          i = close + 3;
          continue;
        }
      }
    }

    // 粗体 **...** / __...__
    if (((ch === '*' && text.startsWith('**', i)) || (ch === '_' && text.startsWith('__', i))) && !bold) {
      const delim: string = ch + ch;
      const prev: string = i > 0 ? text.charAt(i - 1) : '';
      const next: string = i + 2 < text.length ? text.charAt(i + 2) : '';
      const boundaryOk: boolean = ch === '*' || !isWordChar(prev);
      if (boundaryOk && next !== '' && next !== ' ' && next !== '\t' && next !== '\n') {
        const close: number = findDelimClose(text, i + 2, delim);
        if (close > i + 2) {
          scanInline(text.slice(i + 2, close), out, true, italic, strike, href, depth + 1);
          i = close + 2;
          continue;
        }
      }
    }

    // 斜体 *...* / _..._
    if ((ch === '*' || ch === '_') && !italic) {
      const prev: string = i > 0 ? text.charAt(i - 1) : '';
      const next: string = i + 1 < text.length ? text.charAt(i + 1) : '';
      const boundaryOk: boolean = ch === '*' || !isWordChar(prev);
      if (boundaryOk && next !== '' && next !== ch && next !== ' ' && next !== '\t' && next !== '\n') {
        const close: number = findDelimClose(text, i + 1, ch);
        if (close > i + 1) {
          scanInline(text.slice(i + 1, close), out, bold, true, strike, href, depth + 1);
          i = close + 1;
          continue;
        }
      }
    }

    pushSeg(out, ch, bold, false, italic, strike, href);
    i += 1;
  }
}

export function parseInline(text: string): MdSeg[] {
  const prepared: string = mathOutsideCode(text);
  const out: MdSeg[] = [];
  scanInline(prepared, out, false, false, false, '', 0);
  return out;
}

/** 逐字符拆分表格行单元格：自动跳过行内代码 `a | b` 与转义 \|。 */
function splitTableCells(line: string): string[] {
  let s: string = line.trim();
  if (s.startsWith('|')) {
    s = s.slice(1);
  }
  if (s.endsWith('|') && !endsWithEscapedPipe(s)) {
    s = s.slice(0, s.length - 1);
  }
  const cells: string[] = [];
  let cur: string = '';
  let i: number = 0;
  while (i < s.length) {
    const ch: string = s.charAt(i);
    if (ch === '\\' && i + 1 < s.length && s.charAt(i + 1) === '|') {
      cur += '|';
      i += 2;
      continue;
    }
    if (ch === '`') {
      let ticks: number = 0;
      while (i + ticks < s.length && s.charAt(i + ticks) === '`') {
        ticks++;
      }
      const close: number = findClosingTicks(s, i + ticks, ticks);
      if (close >= 0) {
        cur += s.slice(i, close + ticks);
        i = close + ticks;
        continue;
      }
      cur += s.slice(i, i + ticks);
      i += ticks;
      continue;
    }
    if (ch === '|') {
      cells.push(cur.trim());
      cur = '';
      i += 1;
      continue;
    }
    cur += ch;
    i += 1;
  }
  cells.push(cur.trim());
  return cells;
}

function endsWithEscapedPipe(s: string): boolean {
  let slashes: number = 0;
  for (let i = s.length - 2; i >= 0 && s.charAt(i) === '\\'; i--) {
    slashes++;
  }
  return slashes % 2 === 1;
}

/** 严格表格分隔行判定：必须包含 | 且每列匹配 ^:?-{1,}:?$ 并与表头列数一致。 */
function isTableDivider(line: string, colCount: number): boolean {
  const s: string = line.trim();
  if (s === '' || s.indexOf('|') < 0 || s.indexOf('-') < 0) {
    return false;
  }
  const parts: string[] = splitTableCells(s);
  if (parts.length === 0) {
    return false;
  }
  if (colCount > 0 && parts.length !== colCount) {
    return false;
  }
  for (let i = 0; i < parts.length; i++) {
    if (!/^:?-{1,}:?$/.test(parts[i])) {
      return false;
    }
  }
  return true;
}

function parseTableAligns(line: string, colCount: number): string[] {
  const parts: string[] = splitTableCells(line);
  const aligns: string[] = [];
  for (let i = 0; i < colCount; i++) {
    const raw: string = i < parts.length ? parts[i] : '';
    const left: boolean = raw.startsWith(':');
    const right: boolean = raw.endsWith(':');
    if (left && right) {
      aligns.push('center');
    } else if (right) {
      aligns.push('right');
    } else {
      aligns.push('left');
    }
  }
  return aligns;
}

function normalizeRowCells(raw: string[], colCount: number): string[] {
  const out: string[] = [];
  for (let i = 0; i < colCount; i++) {
    out.push(i < raw.length ? raw[i] : '');
  }
  return out;
}

function estimateTextWidthVp(cell: string): number {
  const plain: string = cell
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/[*_`~]/g, '');
  let w: number = 24;
  for (let i = 0; i < plain.length; i++) {
    const code: number = plain.charCodeAt(i);
    if (code >= 0x2e80) {
      w += 14;
    } else {
      w += 8;
    }
  }
  return w;
}

function computeColWidths(head: string[], rows: string[][]): number[] {
  const widths: number[] = [];
  for (let c = 0; c < head.length; c++) {
    let maxW: number = estimateTextWidthVp(head[c]) + 8;
    for (let r = 0; r < rows.length; r++) {
      if (c < rows[r].length) {
        const cw: number = estimateTextWidthVp(rows[r][c]);
        if (cw > maxW) {
          maxW = cw;
        }
      }
    }
    if (maxW < 64) {
      maxW = 64;
    }
    if (maxW > 260) {
      maxW = 260;
    }
    widths.push(Math.ceil(maxW));
  }
  return widths;
}

function isHorizontalRule(trimmed: string): boolean {
  if (trimmed.length < 3) {
    return false;
  }
  const ch: string = trimmed.charAt(0);
  if (ch !== '-' && ch !== '*' && ch !== '_') {
    return false;
  }
  let count: number = 0;
  for (let i = 0; i < trimmed.length; i++) {
    const c: string = trimmed.charAt(i);
    if (c === ch) {
      count++;
    } else if (c !== ' ' && c !== '\t') {
      return false;
    }
  }
  return count >= 3;
}

interface FenceOpen {
  ch: string;
  len: number;
  lang: string;
}

function parseFenceOpen(trimmed: string): FenceOpen | null {
  if (trimmed.length < 3) {
    return null;
  }
  const ch: string = trimmed.charAt(0);
  if (ch !== '`' && ch !== '~') {
    return null;
  }
  let len: number = 0;
  while (len < trimmed.length && trimmed.charAt(len) === ch) {
    len++;
  }
  if (len < 3) {
    return null;
  }
  const info: string = trimmed.slice(len).trim();
  // 反引号围栏的 info 字符串不能包含反引号（避免误判行内代码行）
  if (ch === '`' && info.indexOf('`') >= 0) {
    return null;
  }
  const sp: number = info.search(/\s/);
  const lang: string = sp >= 0 ? info.slice(0, sp) : info;
  return { ch: ch, len: len, lang: lang };
}

function isFenceClose(trimmed: string, open: FenceOpen): boolean {
  if (trimmed.length < open.len || trimmed.charAt(0) !== open.ch) {
    return false;
  }
  let n: number = 0;
  while (n < trimmed.length && trimmed.charAt(n) === open.ch) {
    n++;
  }
  if (n < open.len) {
    return false;
  }
  return trimmed.slice(n).trim() === '';
}

function indentLevelOf(line: string): number {
  let spaces: number = 0;
  for (let i = 0; i < line.length; i++) {
    const c: string = line.charAt(i);
    if (c === ' ') {
      spaces += 1;
    } else if (c === '\t') {
      spaces += 2;
    } else {
      break;
    }
  }
  const lv: number = Math.floor(spaces / 2);
  return lv > 3 ? 3 : lv;
}

function blank(): MdBlock {
  return {
    ord: 0,
    kind: 'p',
    text: '',
    segs: [],
    head: [],
    rows: [],
    lang: ''
  };
}

export function parseMd(src: string): MdBlock[] {
  const out: MdBlock[] = [];
  const normalized: string = src.replace(/\r\n/g, '\n');
  const lines: string[] = [];
  const raw: string[] = normalized.split('\n');
  for (let k = 0; k < raw.length; k++) {
    const t: string = raw[k].trim();
    // 图片语法在手机端由附件区承载，独立图片行跳过，行内图片标记剥离
    if (/^!\[[^\]]*\]\([^)]*\)$/.test(t)) {
      continue;
    }
    lines.push(raw[k].replace(/!\[[^\]]*\]\([^)]*\)/g, ''));
  }

  let i: number = 0;
  let para: string[] = [];

  const flushPara = (): void => {
    if (para.length === 0) {
      return;
    }
    const text: string = para.join('\n').trim();
    if (text !== '') {
      const b: MdBlock = blank();
      b.kind = 'p';
      b.text = text;
      b.segs = parseInline(text);
      b.fp = 'p:' + String(text.length) + ':' + hash32(text);
      out.push(b);
    }
    para = [];
  };

  while (i < lines.length) {
    const line: string = lines[i];
    const trimmed: string = line.trim();

    if (trimmed === '') {
      flushPara();
      i++;
      continue;
    }

    // 独立公式块：$$ ... $$ 或 \[ ... \]
    if (trimmed.startsWith('$$') || trimmed.startsWith('\\[')) {
      flushPara();
      const open: string = trimmed.startsWith('$$') ? '$$' : '\\[';
      const close: string = open === '$$' ? '$$' : '\\]';
      let body: string = trimmed.slice(open.length);
      const same: number = body.indexOf(close);
      if (same >= 0) {
        body = body.slice(0, same);
        i++;
      } else {
        const buf: string[] = [];
        if (body.trim() !== '') {
          buf.push(body);
        }
        i++;
        while (i < lines.length && lines[i].trim().indexOf(close) < 0) {
          buf.push(lines[i].trim());
          i++;
        }
        if (i < lines.length) {
          const tail: string = lines[i].trim();
          const cut: number = tail.indexOf(close);
          if (cut > 0) {
            buf.push(tail.slice(0, cut));
          }
          i++;
        }
        body = buf.join(' ');
      }
      const b: MdBlock = blank();
      b.kind = 'math';
      b.text = texToText(body);
      b.fp = 'math:' + String(b.text.length) + ':' + hash32(b.text);
      out.push(b);
      continue;
    }

    // 围栏代码块（支持 N 个反引号与 ~~~，内层短围栏不提前截断）
    const fence: FenceOpen | null = parseFenceOpen(trimmed);
    if (fence !== null) {
      flushPara();
      const body: string[] = [];
      i++;
      while (i < lines.length && !isFenceClose(lines[i].trim(), fence)) {
        body.push(lines[i]);
        i++;
      }
      if (i < lines.length) {
        i++;
      }
      const codeText: string = body.join('\n');
      const b: MdBlock = blank();
      b.kind = 'code';
      b.lang = fence.lang;
      b.text = codeText;
      b.fp = 'code:' + fence.lang + ':' + String(codeText.length) + ':' + hash32(codeText);
      out.push(b);
      continue;
    }

    // 表格：当前行含 | 且下一行严格匹配分隔行
    if (trimmed.indexOf('|') >= 0 && i + 1 < lines.length) {
      const headCand: string[] = splitTableCells(trimmed);
      if (headCand.length > 0 && isTableDivider(lines[i + 1], headCand.length)) {
        flushPara();
        const aligns: string[] = parseTableAligns(lines[i + 1], headCand.length);
        i += 2;
        const rows: string[][] = [];
        while (i < lines.length) {
          const rt: string = lines[i].trim();
          if (rt === '' || rt.indexOf('|') < 0 || parseFenceOpen(rt) !== null ||
            /^#{1,6}\s+/.test(rt) || isHorizontalRule(rt)) {
            break;
          }
          rows.push(normalizeRowCells(splitTableCells(rt), headCand.length));
          i++;
        }
        const b: MdBlock = blank();
        b.kind = 'table';
        b.head = headCand;
        b.rows = rows;
        b.aligns = aligns;
        b.colWidths = computeColWidths(headCand, rows);
        const flatParts: string[] = [headCand.join('\t')];
        for (let r = 0; r < rows.length; r++) {
          flatParts.push(rows[r].join('\t'));
        }
        const flat: string = flatParts.join('\n');
        const sig: string = hash32(flat);
        b.fp = 'table:' + String(headCand.length) + 'x' + String(rows.length) + ':' + sig;
        // 填充 b.text 防止旧版以 b.text 拼 Key 时流式表格卡死不刷新
        b.text = b.fp;
        out.push(b);
        continue;
      }
    }

    // 水平分割线（--- / *** / ___）
    if (isHorizontalRule(trimmed)) {
      flushPara();
      const b: MdBlock = blank();
      b.kind = 'hr';
      b.text = '---';
      b.fp = 'hr';
      out.push(b);
      i++;
      continue;
    }

    // 标题 h1~h6
    if (/^#{1,6}\s+/.test(trimmed)) {
      flushPara();
      let level: number = 0;
      while (level < trimmed.length && trimmed.charAt(level) === '#') {
        level++;
      }
      const text: string = trimmed.slice(level).trim().replace(/\s+#+$/, '');
      const b: MdBlock = blank();
      b.kind = 'h' + String(level > 6 ? 6 : level);
      b.text = text;
      b.segs = parseInline(text);
      b.fp = b.kind + ':' + String(text.length) + ':' + hash32(text);
      out.push(b);
      i++;
      continue;
    }

    // 引用块（保留多行换行分段）
    if (trimmed.startsWith('>')) {
      flushPara();
      const body: string[] = [];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        body.push(lines[i].trim().replace(/^>\s?/, ''));
        i++;
      }
      const text: string = body.join('\n').trim();
      const b: MdBlock = blank();
      b.kind = 'quote';
      b.text = text;
      b.segs = parseInline(text);
      b.fp = 'quote:' + String(text.length) + ':' + hash32(text);
      out.push(b);
      continue;
    }

    // 无序列表与任务复选框（- [ ] / - [x]）
    if (/^[ \t]*[-*+]\s+/.test(line)) {
      flushPara();
      const indent: number = indentLevelOf(line);
      let text: string = line.replace(/^[ \t]*[-*+]\s+/, '');
      let checked: number = -1;
      const taskMatch: RegExpExecArray | null = /^\[([ xX])\]\s+(.*)$/.exec(text);
      if (taskMatch !== null) {
        checked = (taskMatch[1] === 'x' || taskMatch[1] === 'X') ? 1 : 0;
        text = taskMatch[2];
      }
      const b: MdBlock = blank();
      b.kind = 'bullet';
      b.indent = indent;
      b.checked = checked;
      b.text = text;
      b.segs = parseInline(text);
      b.fp = 'bullet:' + String(indent) + ':' + String(checked) + ':' + hash32(text);
      out.push(b);
      i++;
      continue;
    }

    // 有序列表（保留缩进与序号）
    if (/^[ \t]*\d+[.)]\s+/.test(line)) {
      flushPara();
      const indent: number = indentLevelOf(line);
      const numMatch: RegExpExecArray | null = /^\d+/.exec(trimmed);
      const ord: number = numMatch !== null ? Number(numMatch[0]) : 0;
      const text: string = line.replace(/^[ \t]*\d+[.)]\s+/, '');
      const b: MdBlock = blank();
      b.kind = 'ordered';
      b.ord = ord;
      b.indent = indent;
      b.checked = -1;
      b.text = text;
      b.segs = parseInline(text);
      b.fp = 'ordered:' + String(indent) + ':' + String(ord) + ':' + hash32(text);
      out.push(b);
      i++;
      continue;
    }

    para.push(line);
    i++;
  }
  flushPara();
  return out;
}
