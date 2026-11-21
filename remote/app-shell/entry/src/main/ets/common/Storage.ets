/**
 * 存储空间：手机这边到底存了什么、还剩多少。
 *
 * 设计取舍要说清：会话正文、图片、文件全部在电脑那一侧（`~/.dsh/…`），手机只在
 * 本地留下自己产生的东西——会话列表的本地索引、草稿、状态标记、待发队列、配对与
 * 主题这些偏好，以及运行时写进沙箱的临时文件。所以这里的数字天然比桌面控制台小
 * 得多，页面上也照实写「清了不影响电脑上的任何数据」。
 *
 * 统计口径：
 * - 聊天记录：本机缓存的消息索引与偏好（preferences 目录）
 * - 图片：沙箱里以 image/img/photo 命名的目录（图片历史上传副本等）
 * - 临时文件：cache 目录里除图片之外的东西
 * - 文件预览：files 目录里的文件副本
 */

import { fileIo } from '@kit.CoreFileKit';
import statvfs from '@ohos.file.statvfs';
import { common } from '@kit.AbilityKit';

/** 一条可清理的缓存条目。 */
export interface CacheItem {
  path: string;
  size: number;
}

/** 一个分类的统计结果。 */
export interface Bucket {
  key: string;
  name: string;
  hint: string;
  color: string;
  bytes: number;
  items: CacheItem[];
}

/** 设备可用空间（字节）。 */
export interface DeviceSpace {
  free: number;
  total: number;
}

/** 走目录树的上限，防止符号链接或异常深的目录把扫描拖死。 */
const MAX_DEPTH: number = 6;
/** 单个分类最多留多少条明细给详情页看。 */
const MAX_ITEMS: number = 200;

function join(dir: string, name: string): string {
  return dir.endsWith('/') ? dir + name : dir + '/' + name;
}

/** 深度优先收集文件与总大小；读不了的目录直接跳过，不让一个坏节点毁掉整页。 */
function walk(dir: string, out: CacheItem[], depth: number): number {
  if (depth > MAX_DEPTH) {
    return 0;
  }
  let names: string[] = [];
  try {
    names = fileIo.listFileSync(dir);
  } catch (e) {
    return 0;
  }
  let sum: number = 0;
  for (let i = 0; i < names.length; i++) {
    const p: string = join(dir, names[i]);
    try {
      const st = fileIo.statSync(p);
      if (st.isDirectory()) {
        sum += walk(p, out, depth + 1);
      } else {
        sum += st.size;
        out.push({ path: p, size: st.size });
      }
    } catch (e) {
      // 单个文件读不到（权限、正在写）就跳过
    }
  }
  return sum;
}

/** 按路径里的关键字把文件归到某一类。 */
function classify(path: string): string {
  const p: string = path.toLowerCase();
  if (p.indexOf('/image') >= 0 || p.indexOf('/img') >= 0 || p.indexOf('photo') >= 0) {
    return 'img';
  }
  if (p.indexOf('/preview') >= 0 || p.indexOf('/document') >= 0 || p.indexOf('/doc') >= 0) {
    return 'preview';
  }
  return 'tmp';
}

/** 从沙箱路径前缀判断这是 preferences 还是 files 还是 cache。 */
function isPrefs(path: string, prefsDir: string): boolean {
  return prefsDir.length > 0 && path.indexOf(prefsDir) === 0;
}

/**
 * 扫一遍本机沙箱，返回四个分类。
 * 一次返回全部明细，详情页直接拿 items，不用再扫第二遍。
 */
export function scanStorage(ctx: common.UIAbilityContext): Bucket[] {
  const chat: CacheItem[] = [];
  const img: CacheItem[] = [];
  const tmp: CacheItem[] = [];
  const preview: CacheItem[] = [];

  const prefsDir: string = ctx.preferencesDir;
  const roots: string[] = [];
  if (prefsDir !== undefined && prefsDir !== null && prefsDir.length > 0) {
    roots.push(prefsDir);
  }
  if (ctx.filesDir !== undefined && ctx.filesDir !== null && ctx.filesDir.length > 0) {
    roots.push(ctx.filesDir);
  }
  if (ctx.cacheDir !== undefined && ctx.cacheDir !== null && ctx.cacheDir.length > 0) {
    roots.push(ctx.cacheDir);
  }
  // 应用级沙箱：ArkUI 与资源缓存落在 base 这一层，模块自己的 cache 常是空的
  const appCtx = ctx.getApplicationContext();
  if (appCtx.cacheDir !== undefined && appCtx.cacheDir !== null && appCtx.cacheDir.length > 0) {
    roots.push(appCtx.cacheDir);
  }
  if (appCtx.filesDir !== undefined && appCtx.filesDir !== null && appCtx.filesDir.length > 0) {
    roots.push(appCtx.filesDir);
  }

  for (let i = 0; i < roots.length; i++) {
    const root: string = roots[i];
    const found: CacheItem[] = [];
    const rootBytes: number = walk(root, found, 0);
    console.info('DSH_STORAGE root=' + root + ' bytes=' + rootBytes + ' files=' + found.length);
    for (let k = 0; k < found.length; k++) {
      const it: CacheItem = found[k];
      const kind: string = isPrefs(it.path, prefsDir) ? 'chat' : classify(it.path);
      if (kind === 'chat') {
        chat.push(it);
      } else if (kind === 'img') {
        img.push(it);
      } else if (kind === 'preview') {
        preview.push(it);
      } else {
        tmp.push(it);
      }
    }
  }

  const buckets: Bucket[] = [
    { key: 'chat', name: '聊天记录', hint: '本机的会话索引与设置', color: '#2F6BFF', bytes: 0, items: [] },
    { key: 'img', name: '图片', hint: '上传时的图片副本', color: '#F2B230', bytes: 0, items: [] },
    { key: 'tmp', name: '临时文件', hint: '运行过程中产生的临时副本', color: '#3ED598', bytes: 0, items: [] },
    { key: 'preview', name: '文件预览', hint: '分享或预览留下的文件', color: '#A07CF0', bytes: 0, items: [] }
  ];
  buckets[0].items = trim(chat);
  buckets[1].items = trim(img);
  buckets[2].items = trim(tmp);
  buckets[3].items = trim(preview);
  buckets[0].bytes = total(buckets[0].items);
  buckets[1].bytes = total(buckets[1].items);
  buckets[2].bytes = total(buckets[2].items);
  buckets[3].bytes = total(buckets[3].items);
  return buckets;
}

/** 明细按大小倒序，只留前 MAX_ITEMS 条。 */
function trim(items: CacheItem[]): CacheItem[] {
  const copy: CacheItem[] = items.slice(0);
  copy.sort((a: CacheItem, b: CacheItem) => b.size - a.size);
  return copy.length > MAX_ITEMS ? copy.slice(0, MAX_ITEMS) : copy;
}

function total(items: CacheItem[]): number {
  let sum: number = 0;
  for (let i = 0; i < items.length; i++) {
    sum += items[i].size;
  }
  return sum;
}

/** 设备可用空间；拿不到就返回 0，页面显示「--」。 */
export function deviceSpace(ctx: common.UIAbilityContext): DeviceSpace {
  let free: number = 0;
  let total: number = 0;
  const probe: string = ctx.filesDir;
  try {
    free = statvfs.getFreeSizeSync(probe);
  } catch (e) {
    free = 0;
  }
  try {
    total = statvfs.getTotalSizeSync(probe);
  } catch (e) {
    total = 0;
  }
  return { free: free, total: total };
}

/** 删一个文件；返回释放的字节数。 */
function removeFile(path: string): number {
  let size: number = 0;
  try {
    size = fileIo.statSync(path).size;
  } catch (e) {
    return 0;
  }
  try {
    fileIo.unlinkSync(path);
    return size;
  } catch (e) {
    return 0;
  }
}

/**
 * 清理缓存：只动 cacheDir 与「非 preferences」的 files 目录内容，
 * 偏好（配对、主题、草稿、待发队列）一律保留，所以清完不需要重新配对。
 */
export function clearCache(ctx: common.UIAbilityContext): number {
  let freed: number = 0;
  const roots: string[] = [];
  if (ctx.cacheDir !== undefined && ctx.cacheDir !== null && ctx.cacheDir.length > 0) {
    roots.push(ctx.cacheDir);
  }
  const appCtx = ctx.getApplicationContext();
  if (appCtx.cacheDir !== undefined && appCtx.cacheDir !== null && appCtx.cacheDir.length > 0) {
    roots.push(appCtx.cacheDir);
  }
  // 应用级 files 里是 SDK 写的事件缓存（hiappevent），属于可再生的临时数据；
  // preferences 在另一条路径（haps/entry/preferences），这里碰不到，配对与主题安全。
  if (appCtx.filesDir !== undefined && appCtx.filesDir !== null && appCtx.filesDir.length > 0) {
    roots.push(appCtx.filesDir);
  }
  for (let i = 0; i < roots.length; i++) {
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(roots[i]);
    } catch (e) {
      continue;
    }
    for (let k = 0; k < names.length; k++) {
      const p: string = join(roots[i], names[k]);
      try {
        const st = fileIo.statSync(p);
        if (st.isDirectory()) {
          const inner: CacheItem[] = [];
          walk(p, inner, 0);
          for (let j = 0; j < inner.length; j++) {
            freed += removeFile(inner[j].path);
          }
          try {
            fileIo.rmdirSync(p);
          } catch (e) {
            // 目录里还有删不掉的文件，留着即可
          }
        } else {
          freed += removeFile(p);
        }
      } catch (e) {
        // 单个条目失败不影响其它
      }
    }
  }
  return freed;
}

/** 人类可读的体积：1.2 MB / 143 MB / 6 KB / 35 B。 */
export function sizeText(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return bytes.toString() + ' B';
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return kb < 10 ? kb.toFixed(1) + ' KB' : Math.round(kb).toString() + ' KB';
  }
  const mb: number = kb / 1024;
  if (mb < 1024) {
    return mb < 10 ? mb.toFixed(1) + ' MB' : Math.round(mb).toString() + ' MB';
  }
  const gb: number = mb / 1024;
  return gb.toFixed(1) + ' GB';
}
