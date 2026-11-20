/**
 * 轻量 Markdown 解析：把一段文本拆成可渲染的块。
 * 支持标题、圆点列表、引用、代码块、表格、普通段落。
 * 行内 **粗体** 与 `代码` 切成片段。
 */

import { texToText, looksLikeTex } from './TeX';

export interface MdSeg {
  t: string;
  b: boolean;
  c: boolean;
}

export interface MdBlock {
  kind: string;
  text: string;
  segs: MdSeg[];
  head: string[];
  rows: string[][];
  lang: string;
}

export function parseInline(text: string): MdSeg[] {
  return inlineSegs(text);
}

function mathInline(text: string): string {
  let s: string = text;
  s = s.replace(/\\\((.+?)\\\)/g, (all: string, body: string): string => {
    return looksLikeTex(body) ? texToText(body) : all;
  });
  s = s.replace(/\$([^$\n]{1,300})\$/g, (all: string, body: string): string => {
    return looksLikeTex(body) ? texToText(body) : all;
  });
  return s;
}

function inlineSegs(raw: string): MdSeg[] {
  const text: string = mathInline(raw);
  const out: MdSeg[] = [];
  const re: RegExp = /(\*\*[^*\n]+\*\*|`[^`\n]+`)/g;
  let last: number = 0;
  let m: RegExpExecArray | null = re.exec(text);
  while (m !== null) {
    if (m.index > last) {
      out.push({ t: text.slice(last, m.index), b: false, c: false });
    }
    const tok: string = m[0];
    if (tok.startsWith('**')) {
      out.push({ t: tok.slice(2, tok.length - 2), b: true, c: false });
    } else {
      out.push({ t: tok.slice(1, tok.length - 1), b: false, c: true });
    }
    last = m.index + tok.length;
    m = re.exec(text);
  }
  if (last < text.length) {
    out.push({ t: text.slice(last), b: false, c: false });
  }
  return out;
}

/** 表格分隔行：|---|:--:|---| */
function isDivider(line: string): boolean {
  const s: string = line.trim();
  if (s.indexOf('-') < 0) return false;
  const body: string = s.replace(/\|/g, '').replace(/:/g, '').replace(/-/g, '').replace(/\s/g, '');
  return body === '';
}

function cells(line: string): string[] {
  let s: string = line.trim();
  if (s.startsWith('|')) s = s.slice(1);
  if (s.endsWith('|')) s = s.slice(0, s.length - 1);
  return s.split('|').map((x: string) => x.trim());
}

function blank(): MdBlock {
  return { kind: 'p', text: '', segs: [], head: [], rows: [], lang: '' };
}

export function parseMd(src: string): MdBlock[] {
  const out: MdBlock[] = [];
  const lines: string[] = [];
  const raw: string[] = src.split('\n');
  for (let k = 0; k < raw.length; k++) {
    const t: string = raw[k].trim();
    // 图片语法在手机上无法解析成本地文件，整行丢掉；行内的一并去掉
    if (/^!\[[^\]]*\]\([^)]*\)$/.test(t)) {
      continue;
    }
    lines.push(raw[k].replace(/!\[[^\]]*\]\([^)]*\)/g, ''));
  }
  let i: number = 0;
  let para: string[] = [];

  const flushPara = (): void => {
    if (para.length === 0) return;
    const text: string = para.join('\n').trim();
    if (text !== '') {
      const b: MdBlock = blank();
      b.kind = 'p';
      b.text = text;
      b.segs = inlineSegs(text);
      out.push(b);
    }
    para = [];
  };

  while (i < lines.length) {
    const line: string = lines[i];
    const trimmed: string = line.trim();

    // 独立公式块：$$ ... $$ 或 \\[ ... \\]
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
      out.push(b);
      continue;
    }

    // 代码块
    if (trimmed.startsWith('```')) {
      flushPara();
      const lang: string = trimmed.slice(3).trim();
      const body: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        body.push(lines[i]);
        i++;
      }
      i++;
      const b: MdBlock = blank();
      b.kind = 'code';
      b.lang = lang;
      b.text = body.join('\n');
      out.push(b);
      continue;
    }

    // 表格：当前行含 | 且下一行是分隔行
    if (trimmed.indexOf('|') >= 0 && i + 1 < lines.length && isDivider(lines[i + 1])) {
      flushPara();
      const head: string[] = cells(trimmed);
      i += 2;
      const rows: string[][] = [];
      while (i < lines.length && lines[i].trim().indexOf('|') >= 0) {
        rows.push(cells(lines[i]));
        i++;
      }
      const b: MdBlock = blank();
      b.kind = 'table';
      b.head = head;
      b.rows = rows;
      out.push(b);
      continue;
    }

    // 标题
    if (/^#{1,6}\s+/.test(trimmed)) {
      flushPara();
      const level: number = (trimmed.match(/^#+/) as string[])[0].length;
      const text: string = trimmed.replace(/^#{1,6}\s+/, '');
      const b: MdBlock = blank();
      b.kind = level <= 1 ? 'h1' : (level === 2 ? 'h2' : 'h3');
      b.text = text;
      b.segs = inlineSegs(text);
      out.push(b);
      i++;
      continue;
    }

    // 引用
    if (trimmed.startsWith('>')) {
      flushPara();
      const body: string[] = [];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        body.push(lines[i].trim().replace(/^>\s?/, ''));
        i++;
      }
      const text: string = body.join(' ');
      const b: MdBlock = blank();
      b.kind = 'quote';
      b.text = text;
      b.segs = inlineSegs(text);
      out.push(b);
      continue;
    }

    // 圆点列表
    if (/^\s*[-*+]\s+/.test(line)) {
      flushPara();
      const text: string = line.replace(/^\s*[-*+]\s+/, '');
      const b: MdBlock = blank();
      b.kind = 'bullet';
      b.text = text;
      b.segs = inlineSegs(text);
      out.push(b);
      i++;
      continue;
    }

    // 有序列表按圆点处理
    if (/^\s*\d+[.)]\s+/.test(line)) {
      flushPara();
      const text: string = line.replace(/^\s*\d+[.)]\s+/, '');
      const b: MdBlock = blank();
      b.kind = 'bullet';
      b.text = text;
      b.segs = inlineSegs(text);
      out.push(b);
      i++;
      continue;
    }

    if (trimmed === '') {
      flushPara();
      i++;
      continue;
    }

    para.push(line);
    i++;
  }
  flushPara();
  return out;
}
