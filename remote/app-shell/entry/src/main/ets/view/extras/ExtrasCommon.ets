export interface ExtrasTabOpt {
  key: string;
  label: string;
  title: string;
  subtitle: string;
}

export const GATEWAY_404_TITLE: string = '电脑端网关尚未加载此新接口';
export const GATEWAY_404_HINT: string = '重启电脑端 DSH 后即可启用';

export function isGateway404(msg: string): boolean {
  return msg.indexOf('HTTP 404') >= 0 || msg.indexOf('404 Not Found') >= 0;
}

export function shortPluginName(name: string): string {
  const at: number = name.lastIndexOf('/');
  return at >= 0 ? name.substring(at + 1) : name;
}

export function isImageFileName(name: string): boolean {
  const n: string = name.toLowerCase();
  return n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.webp') ||
    n.endsWith('.gif') || n.endsWith('.bmp') || n.endsWith('.svg');
}

export function splitFileLeaf(path: string): string {
  const cut: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  return cut >= 0 ? path.substring(cut + 1) : path;
}
