/**
 * Api 的纯函数部分：HTTP 方法映射、错误文案、错误分类、幂等键、sleep。
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
    if (msg.indexOf('401') >= 0 || msg.indexOf('403') >= 0) {
      return 'auth';
    }
    if (msg.startsWith('请求') || msg.startsWith('这台电脑') || msg.startsWith('电脑端出错')) {
      return 'http';
    }
    return 'net';
  }

export function sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(() => resolve(), ms));
  }
