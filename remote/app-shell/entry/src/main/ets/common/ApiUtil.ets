/**
 * Api 的纯函数部分：HTTP 方法映射、错误文案、错误分类、幂等键、局域网判定、sleep。
 *
 * 从 Api.ets 拆出来：不依赖连接状态；Api 保留同名包装，调用方不用动。
 */
import http from '@ohos.net.http';
import { ErrBody } from './ApiTypes';

export function httpMethodOf(method: string): http.RequestMethod {
  if (method === 'POST') {
    return http.RequestMethod.POST;
  }
  if (method === 'PATCH') {
    return http.RequestMethod.PATCH;
  }
  if (method === 'PUT') {
    return http.RequestMethod.PUT;
  }
  if (method === 'DELETE') {
    return http.RequestMethod.DELETE;
  }
  return http.RequestMethod.GET;
}

export function friendlyError(code: number, text: string, path: string): string {
  const body: string = (text ?? '').trim();
  const lower: string = body.toLowerCase();
  const html: boolean = lower.startsWith('<!doctype html') || lower.startsWith('<html') || lower.includes('<html');
  console.info('DSH_API_ERR ' + path + ' code=' + String(code));
  if (code === 401) {
    return '这台电脑不认这个令牌了，去设置里重新配对';
  }
  if (body.startsWith('{')) {
    try {
      const obj: ErrBody = JSON.parse(body) as ErrBody;
      const msg: string = obj.error !== undefined ? obj.error : '';
      if (msg !== '') {
        return (code >= 500 ? '电脑端出错（HTTP ' + String(code) + '）：' : '请求被拒（HTTP ' + String(code) + '）：') + msg;
      }
    } catch (e) {
      // 不是合法 JSON，退回通用说法
    }
  }
  if (code >= 500) {
    return html ? '连不上电脑（隧道 HTTP ' + String(code) + '），稍后自动重试'
      : '电脑端出错（HTTP ' + String(code) + '）';
  }
  const tail: string = html ? '' : body.slice(0, 80);
  return '请求失败（HTTP ' + String(code) + '）' + (tail !== '' ? '：' + tail : '');
}

export function newIdemKey(): string {
  return Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
}

export function classifyError(msg: string): string {
  if (msg.startsWith('还没连上')) {
    return 'nobase';
  }
  if (msg.startsWith('响应格式')) {
    return 'parse';
  }
  if (msg.indexOf('401') >= 0 || msg.indexOf('403') >= 0 ||
    msg.indexOf('不认这个令牌') >= 0 || msg.indexOf('拒绝了此设备') >= 0) {
    return 'auth';
  }
  if (msg.startsWith('请求') || msg.startsWith('这台电脑') || msg.startsWith('电脑端出错')) {
    return 'http';
  }
  return 'net';
}

/**
 * 判断地址是否为局域网/本机回环地址：
 * 覆盖 IPv4 私有段（10/127/169.254/192.168/172.16..31）、localhost、单段主机名/.local、
 * 以及 IPv6 回环与链路/唯一本地地址（::1 / fe80 / fc / fd）。
 */
export function isLanUrl(u: string): boolean {
  const trimmed: string = u.trim();
  if (trimmed === '') {
    return false;
  }
  const noScheme: string = trimmed.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, '');
  const cutMatch: number = noScheme.search(/[/?#]/);
  const hostPort: string = cutMatch >= 0 ? noScheme.substring(0, cutMatch) : noScheme;
  let host: string = '';
  if (hostPort.startsWith('[')) {
    const closeIdx: number = hostPort.indexOf(']');
    host = closeIdx > 1 ? hostPort.substring(1, closeIdx) : hostPort.substring(1);
  } else if (hostPort.indexOf(':') !== hostPort.lastIndexOf(':')) {
    host = hostPort;
  } else {
    const colonIdx: number = hostPort.indexOf(':');
    host = colonIdx >= 0 ? hostPort.substring(0, colonIdx) : hostPort;
  }
  const zoneIdx: number = host.indexOf('%');
  if (zoneIdx >= 0) {
    host = host.substring(0, zoneIdx);
  }
  host = host.toLowerCase();
  if (host === '') {
    return false;
  }
  if (host === 'localhost' || host === '0.0.0.0' || host === '::1' || host === '::' || host === '0:0:0:0:0:0:0:1') {
    return true;
  }
  if (host.indexOf(':') >= 0) {
    if (host.startsWith('fe80') || host.startsWith('fc') || host.startsWith('fd')) {
      return true;
    }
    return false;
  }
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host)) {
    if (host.startsWith('127.') || host.startsWith('10.') || host.startsWith('192.168.') ||
      host.startsWith('169.254.') || host.startsWith('0.')) {
      return true;
    }
    const parts: string[] = host.split('.');
    if (parts[0] === '172') {
      const second: number = Number.parseInt(parts[1], 10);
      return second >= 16 && second <= 31;
    }
    return false;
  }
  if (host.endsWith('.local') || host.endsWith('.lan')) {
    return true;
  }
  return host.indexOf('.') < 0;
}

export function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(() => resolve(), ms));
}
