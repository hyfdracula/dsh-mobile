/**
 * 时间 / 字节 / 短数字的统一格式化。
 *
 * 这些函数以前在 SessionList、AgentsPage、ChatPage、SettingsPage 各有一份，
 * 「刚刚」的阈值、小时与天的进位、日期分隔的文案都略有差别。统一后：
 *  - ago()      相对时间（列表、成员行）
 *  - dayKey()   粗粒度分组（今天 / 昨天 / 更早）
 *  - dayLabel() 消息流里的日期胶囊（今天 / 昨天 / M 月 D 日）
 *  - clock()    HH:mm
 *  - stamp()    M-D HH:mm
 *  - bytes()    文件大小
 *  - num()      1.2K / 3.4M 这类短数字
 *  - wsOf()     工作区显示名
 */

export function ago(ms: number): string {
  const d: number = Date.now() - ms;
  if (d < 60_000) {
    return '刚刚';
  }
  if (d < 3_600_000) {
    return Math.floor(d / 60_000) + ' 分钟前';
  }
  if (d < 86_400_000) {
    return Math.floor(d / 3_600_000) + ' 小时前';
  }
  if (d < 172_800_000) {
    return '昨天';
  }
  return Math.floor(d / 86_400_000) + ' 天前';
}

export function dayKey(ms: number): string {
  const now: Date = new Date();
  const t: Date = new Date(ms);
  const a: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const b: number = new Date(t.getFullYear(), t.getMonth(), t.getDate()).getTime();
  const diff: number = Math.round((a - b) / 86_400_000);
  if (diff <= 0) {
    return '今天';
  }
  if (diff === 1) {
    return '昨天';
  }
  return '更早';
}

export function dayLabel(ms: number): string {
  const now: Date = new Date();
  const d: Date = new Date(ms);
  const today: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const that: number = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  if (that === today) {
    return '今天';
  }
  if (today - that === 86_400_000) {
    return '昨天';
  }
  return (d.getMonth() + 1) + ' 月 ' + d.getDate() + ' 日';
}

export function sameDay(a: number, b: number): boolean {
  const x: Date = new Date(a);
  const y: Date = new Date(b);
  return x.getFullYear() === y.getFullYear() && x.getMonth() === y.getMonth() && x.getDate() === y.getDate();
}

export function clock(ms: number): string {
  const d: Date = new Date(ms);
  const h: number = d.getHours();
  const m: number = d.getMinutes();
  return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m;
}

export function stamp(ms: number): string {
  const d: Date = new Date(ms);
  const pad = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return String(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
}

export function bytes(n: number): string {
  if (n >= 1024 * 1024 * 1024) {
    return (n / (1024 * 1024 * 1024)).toFixed(1) + ' GB';
  }
  if (n >= 1024 * 1024) {
    return (n / (1024 * 1024)).toFixed(1) + ' MB';
  }
  if (n >= 1024) {
    return (n / 1024).toFixed(1) + ' KB';
  }
  return String(n) + ' B';
}

export function num(n: number): string {
  if (n >= 1000000000) {
    return (n / 1000000000).toFixed(2) + 'B';
  }
  if (n >= 1000000) {
    return (n / 1000000).toFixed(2) + 'M';
  }
  if (n >= 1000) {
    return (n / 1000).toFixed(1) + 'K';
  }
  return '' + n;
}

export function wsOf(cwd: string): string {
  const parts: string[] = cwd.split(/[\\/]/).filter((s: string) => s.length > 0);
  return parts.length > 0 ? parts[parts.length - 1] : '默认';
}
