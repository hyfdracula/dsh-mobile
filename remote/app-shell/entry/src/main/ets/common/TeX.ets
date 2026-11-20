/**
 * 轻量 TeX -> 可读文本。
 *
 * 手机上不引入完整的排版引擎，这里只做「看得懂」的等价替换：
 * 分式写成 a/b，根号写成 √x，上下标尽量用 Unicode，
 * 希腊字母与常见算子直接映射成符号。
 */

const SUP: string[] = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];
const SUB: string[] = ['₀', '₁', '₂', '₃', '₄', '₅', '₆', '₇', '₈', '₉'];

const GREEK: string[] = [
  'alpha:α', 'beta:β', 'gamma:γ', 'delta:δ', 'epsilon:ε', 'varepsilon:ε',
  'zeta:ζ', 'eta:η', 'theta:θ', 'vartheta:ϑ', 'iota:ι', 'kappa:κ', 'lambda:λ',
  'mu:μ', 'nu:ν', 'xi:ξ', 'pi:π', 'rho:ρ', 'sigma:σ', 'tau:τ', 'upsilon:υ',
  'phi:φ', 'varphi:ϕ', 'chi:χ', 'psi:ψ', 'omega:ω',
  'Gamma:Γ', 'Delta:Δ', 'Theta:Θ', 'Lambda:Λ', 'Xi:Ξ', 'Pi:Π', 'Sigma:Σ',
  'Upsilon:Υ', 'Phi:Φ', 'Psi:Ψ', 'Omega:Ω'
];

const OPS: string[] = [
  'times:×', 'cdot:·', 'div:÷', 'pm:±', 'mp:∓',
  'le:≤', 'leq:≤', 'ge:≥', 'geq:≥', 'ne:≠', 'neq:≠', 'approx:≈', 'equiv:≡', 'sim:∼',
  'infty:∞', 'sum:∑', 'prod:∏', 'int:∫', 'iint:∬', 'oint:∮',
  'partial:∂', 'nabla:∇', 'prime:′',
  'to:→', 'rightarrow:→', 'leftarrow:←', 'Rightarrow:⇒', 'Leftarrow:⇐', 'leftrightarrow:↔',
  'in:∈', 'notin:∉', 'subset:⊂', 'supset:⊃', 'cup:∪', 'cap:∩', 'emptyset:∅',
  'forall:∀', 'exists:∃', 'therefore:∴', 'because:∵',
  'angle:∠', 'degree:°', 'circ:∘',
  'ldots:…', 'cdots:⋯', 'vdots:⋮', 'ddots:⋱',
  'quad: ', 'qquad:  ', 'space: ', 'left:', 'right:',
  'langle:⟨', 'rangle:⟩', 'lfloor:⌊', 'rfloor:⌋', 'lceil:⌈', 'rceil:⌉',
  'mathbb: ', 'mathcal: ', 'mathrm: ', 'mathbf: ', 'mathit: ', 'text: ', 'operatorname: ',
  'begin: ', 'end: '
];

function mapWord(word: string): string {
  for (const pair of GREEK) {
    const i: number = pair.indexOf(':');
    if (pair.slice(0, i) === word) return pair.slice(i + 1);
  }
  for (const pair of OPS) {
    const i: number = pair.indexOf(':');
    if (pair.slice(0, i) === word) return pair.slice(i + 1);
  }
  // 不认识的命令（\mathrm{d}x 之类）直接丢掉反斜杠，保留字母
  return word;
}

/** 把一串字符拆成 单个字符 / 花括号分组 两种元素，便于做上下标与根号。 */
function groupBetween(src: string, open: number): number {
  let depth: number = 0;
  for (let i: number = open; i < src.length; i++) {
    const ch: string = src.charAt(i);
    if (ch === '{') depth++;
    if (ch === '}') {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function toSup(text: string): string {
  let out: string = '';
  for (let i: number = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    const n: number = '0123456789'.indexOf(ch);
    if (n >= 0) {
      out += SUP[n];
    } else if (ch === '+') {
      out += '⁺';
    } else if (ch === '-') {
      out += '⁻';
    } else if (ch === '=') {
      out += '⁼';
    } else if (ch === '(') {
      out += '⁽';
    } else if (ch === ')') {
      out += '⁾';
    } else if (ch === 'n') {
      out += 'ⁿ';
    } else if (ch === 'i') {
      out += 'ⁱ';
    } else if (ch === '°') {
      out += '°';
    } else {
      return '^' + text;
    }
  }
  return out;
}

function toSub(text: string): string {
  let out: string = '';
  for (let i: number = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    const n: number = '0123456789'.indexOf(ch);
    if (n >= 0) {
      out += SUB[n];
    } else if (ch === '+') {
      out += '₊';
    } else if (ch === '-') {
      out += '₋';
    } else if (ch === '=') {
      out += '₌';
    } else if (ch === '(') {
      out += '₍';
    } else if (ch === ')') {
      out += '₎';
    } else if (ch === 'a') {
      out += 'ₐ';
    } else if (ch === 'e') {
      out += 'ₑ';
    } else if (ch === 'i') {
      out += 'ᵢ';
    } else if (ch === 'j') {
      out += 'ⱼ';
    } else if (ch === 'n') {
      out += 'ₙ';
    } else if (ch === 'x') {
      out += 'ₓ';
    } else {
      return '_' + text;
    }
  }
  return out;
}

/** 波浪线等「\bar{x}」统一成 x̄ 这种组合字符。 */
function accent(text: string, mark: string): string {
  let out: string = '';
  for (let i: number = 0; i < text.length; i++) {
    out += text.charAt(i) + mark;
  }
  return out;
}

function convert(src: string): string {
  let s: string = src;
  let guard: number = 0;

  // \frac{a}{b} 可能嵌套，反复扫几轮
  while (guard < 40) {
    const at: number = s.indexOf('\\frac');
    const isDfrac: boolean = at < 0 && s.indexOf('\\dfrac') >= 0;
    const pos: number = at >= 0 ? at : s.indexOf('\\dfrac');
    if (pos < 0) break;
    const open1: number = s.indexOf('{', pos);
    if (open1 < 0) break;
    const close1: number = groupBetween(s, open1);
    if (close1 < 0) break;
    const open2: number = s.indexOf('{', close1);
    if (open2 < 0) break;
    const close2: number = groupBetween(s, open2);
    if (close2 < 0) break;
    const a: string = convert(s.slice(open1 + 1, close1));
    const b: string = convert(s.slice(open2 + 1, close2));
    const simpleA: boolean = /^[0-9A-Za-z.]+$/.test(a);
    const simpleB: boolean = /^[0-9A-Za-z.]+$/.test(b);
    const rep: string = simpleA && simpleB ? a + '/' + b : '(' + a + ')/(' + b + ')';
    s = s.slice(0, pos) + rep + s.slice(close2 + 1);
    guard++;
    if (isDfrac) continue;
  }

  // \sqrt[n]{x} / \sqrt{x}
  s = s.replace(/\\sqrt\s*\[([^\]]*)\]\s*\{([^{}]*)\}/g, (_all: string, idx: string, body: string): string => {
    return toSup(convert(idx)) + '√(' + convert(body) + ')';
  });
  s = s.replace(/\\sqrt\s*\{([^{}]*)\}/g, (_all: string, body: string): string => {
    return '√(' + convert(body) + ')';
  });

  // \bar{x} \hat{x} \vec{x}
  s = s.replace(/\\bar\s*\{([^{}]*)\}/g, (_a: string, t: string): string => accent(convert(t), '\u0304'));
  s = s.replace(/\\hat\s*\{([^{}]*)\}/g, (_a: string, t: string): string => accent(convert(t), '\u0302'));
  s = s.replace(/\\vec\s*\{([^{}]*)\}/g, (_a: string, t: string): string => accent(convert(t), '\u20D7'));

  // ^{...} 与 _{...}
  s = s.replace(/\^\{([^{}]*)\}/g, (_a: string, t: string): string => toSup(convert(t)));
  s = s.replace(/_\{([^{}]*)\}/g, (_a: string, t: string): string => toSub(convert(t)));
  // ^2 / _1 这种单字符
  s = s.replace(/\^([0-9a-zA-Z+\-()])/g, (_a: string, t: string): string => toSup(t));
  s = s.replace(/_([0-9a-zA-Z+\-()])/g, (_a: string, t: string): string => toSub(t));

  // 其余 \{word} 形式的命令
  s = s.replace(/\\([A-Za-z]+)/g, (_a: string, w: string): string => mapWord(w));

  // 转义与排版噪声
  s = s.replace(/\\\\/g, '\n');
  s = s.replace(/\\[,;:! ]/g, ' ');
  s = s.replace(/\\[{}%$&#_]/g, (all: string): string => all.charAt(1));
  s = s.replace(/[{}]/g, '');
  s = s.replace(/\s+/g, ' ');
  return s.trim();
}

/** 把一段 TeX 换成能直接显示的文字。 */
export function texToText(tex: string): string {
  if (tex === '') return '';
  return convert(tex);
}

/** 判断一段文本里有没有像样的公式（避免把货币符号当公式）。 */
export function looksLikeTex(body: string): boolean {
  if (body.length === 0 || body.length > 400) return false;
  if (/\\[A-Za-z]+/.test(body)) return true;
  if (/[\^_]\{?[0-9A-Za-z]/.test(body)) return true;
  if (/[=<>±≤≥∑∫√∞]/.test(body) && /[A-Za-z0-9]/.test(body)) return true;
  return false;
}
