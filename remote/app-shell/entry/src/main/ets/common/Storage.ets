/**
 * 存储空间统计与真实清理（F10）：
 *
 * 严格区分「可清理缓存」与「不可删除的系统配置/配对数据」：
 * - 可清理缓存 buckets（清理后总额真实归零 0 B）：
 *   1) msgs  : 对话快照缓存（ctx.filesDir/msgs，即 ChatCache 本地快照）
 *   2) temp  : 图片与临时缓存（ctx.cacheDir + appCtx.cacheDir）
 *   3) files : 下载与导出缓存（appCtx.filesDir）
 * - 不可清理系统配置 prefs（单独返回 prefsBytes 与 prefsItems，绝不混入可清理缓存总额）：
 *   ctx.preferencesDir 及 ctx.filesDir 下非 msgs 的业务文件（如离线待发队列）。
 */

import { fileIo } from '@kit.CoreFileKit';
import statvfs from '@ohos.file.statvfs';
import { common } from '@kit.AbilityKit';
import { bytes as fmtBytes } from './Format';
import { Tokens } from './Tokens';

/** 一条缓存或数据文件条目。 */
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
  cleanable?: boolean;
}

/** 完整存储概览：可清理缓存分类 + 独立的系统配置统计。 */
export interface StorageSummary {
  buckets: Bucket[];
  cacheBytes: number;
  prefsBytes: number;
  prefsItems: CacheItem[];
}

/** 设备可用空间（字节）。 */
export interface DeviceSpace {
  free: number;
  total: number;
}

const MAX_DEPTH: number = 6;
const MAX_ITEMS: number = 200;

function join(dir: string, name: string): string {
  return dir.endsWith('/') ? dir + name : dir + '/' + name;
}

function walk(dir: string, out: CacheItem[], depth: number, skipDir: string = ''): number {
  if (depth > MAX_DEPTH || dir === '') {
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
    if (skipDir !== '' && p === skipDir) {
      continue;
    }
    try {
      const st = fileIo.statSync(p);
      if (st.isDirectory()) {
        sum += walk(p, out, depth + 1, skipDir);
      } else {
        sum += st.size;
        out.push({ path: p, size: st.size });
      }
    } catch (e) {
      // 单个文件不可读时跳过
    }
  }
  return sum;
}

function trim(items: CacheItem[]): CacheItem[] {
  const copy: CacheItem[] = items.slice(0);
  copy.sort((a: CacheItem, b: CacheItem) => b.size - a.size);
  return copy.length > MAX_ITEMS ? copy.slice(0, MAX_ITEMS) : copy;
}

function sumBytes(items: CacheItem[]): number {
  let sum: number = 0;
  for (let i = 0; i < items.length; i++) {
    sum += items[i].size;
  }
  return sum;
}

function uniqueDirs(raw: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < raw.length; i++) {
    const d: string = raw[i];
    if (d !== undefined && d !== null && d.length > 0 && out.indexOf(d) < 0) {
      out.push(d);
    }
  }
  return out;
}

function msgsDirOf(ctx: common.UIAbilityContext): string {
  if (ctx.filesDir === undefined || ctx.filesDir === null || ctx.filesDir.length === 0) {
    return '';
  }
  return join(ctx.filesDir, 'msgs');
}

function tempDirsOf(ctx: common.UIAbilityContext): string[] {
  const appCtx = ctx.getApplicationContext();
  return uniqueDirs([ctx.cacheDir, appCtx.cacheDir]);
}

function appFilesDirsOf(ctx: common.UIAbilityContext): string[] {
  const appCtx = ctx.getApplicationContext();
  if (appCtx.filesDir === undefined || appCtx.filesDir === null || appCtx.filesDir.length === 0) {
    return [];
  }
  if (appCtx.filesDir === ctx.filesDir) {
    return [];
  }
  return [appCtx.filesDir];
}

/**
 * 扫描完整本机存储概览：
 * 返回 3 个可清理缓存分类（msgs / temp / files）以及独立的不可删系统配置 prefsBytes。
 */
export function scanStorageSummary(ctx: common.UIAbilityContext): StorageSummary {
  const msgsItems: CacheItem[] = [];
  const tempItems: CacheItem[] = [];
  const filesItems: CacheItem[] = [];
  const prefsItems: CacheItem[] = [];

  const msgsDir: string = msgsDirOf(ctx);
  if (msgsDir !== '') {
    walk(msgsDir, msgsItems, 0);
  }

  const tempDirs: string[] = tempDirsOf(ctx);
  for (let i = 0; i < tempDirs.length; i++) {
    walk(tempDirs[i], tempItems, 0);
  }

  const appFilesDirs: string[] = appFilesDirsOf(ctx);
  for (let i = 0; i < appFilesDirs.length; i++) {
    walk(appFilesDirs[i], filesItems, 0);
  }

  // 不可删的系统配置与配对/草稿数据，单独统计，绝不混入可清理缓存总额
  if (ctx.preferencesDir !== undefined && ctx.preferencesDir !== null && ctx.preferencesDir.length > 0) {
    walk(ctx.preferencesDir, prefsItems, 0);
  }
  if (ctx.filesDir !== undefined && ctx.filesDir !== null && ctx.filesDir.length > 0) {
    walk(ctx.filesDir, prefsItems, 0, msgsDir);
  }

  const msgsBytes: number = sumBytes(msgsItems);
  const tempBytes: number = sumBytes(tempItems);
  const filesBytes: number = sumBytes(filesItems);
  const prefsBytes: number = sumBytes(prefsItems);

  const buckets: Bucket[] = [
    {
      key: 'msgs',
      name: '对话快照缓存',
      hint: '本机加速首屏渲染的最近消息快照',
      color: Tokens.bucket0,
      bytes: msgsBytes,
      items: trim(msgsItems),
      cleanable: true
    },
    {
      key: 'temp',
      name: '图片与临时缓存',
      hint: '图片预览与运行过程产生的临时副本',
      color: Tokens.bucket1,
      bytes: tempBytes,
      items: trim(tempItems),
      cleanable: true
    },
    {
      key: 'files',
      name: '下载与导出缓存',
      hint: '导出预览与系统组件缓存文件',
      color: Tokens.bucket2,
      bytes: filesBytes,
      items: trim(filesItems),
      cleanable: true
    }
  ];

  console.info('DSH_STORAGE msgs=' + String(msgsBytes) + ' temp=' + String(tempBytes) +
    ' files=' + String(filesBytes) + ' prefs=' + String(prefsBytes));

  return {
    buckets: buckets,
    cacheBytes: msgsBytes + tempBytes + filesBytes,
    prefsBytes: prefsBytes,
    prefsItems: trim(prefsItems)
  };
}

/** 扫描可清理缓存分类（兼容旧调用方，不含 preferences）。 */
export function scanStorage(ctx: common.UIAbilityContext): Bucket[] {
  return scanStorageSummary(ctx).buckets;
}

/** 单独返回系统配置与配对数据分类（不可删除，供详情展示）。 */
export function scanPrefsBucket(ctx: common.UIAbilityContext): Bucket {
  const summary: StorageSummary = scanStorageSummary(ctx);
  return {
    key: 'prefs',
    name: '配置与配对数据',
    hint: '电脑配对、主题偏好与离线待发数据（受保护不清理）',
    color: Tokens.bucket3,
    bytes: summary.prefsBytes,
    items: summary.prefsItems,
    cleanable: false
  };
}

/** 设备可用空间；拿不到就返回 0。 */
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

function clearDirectoryContents(dir: string, removeEmptySubdirs: boolean = true): number {
  if (dir === '') {
    return 0;
  }
  let names: string[] = [];
  try {
    names = fileIo.listFileSync(dir);
  } catch (e) {
    return 0;
  }
  let freed: number = 0;
  for (let k = 0; k < names.length; k++) {
    const p: string = join(dir, names[k]);
    try {
      const st = fileIo.statSync(p);
      if (st.isDirectory()) {
        freed += clearDirectoryContents(p, true);
        if (removeEmptySubdirs) {
          try {
            fileIo.rmdirSync(p);
          } catch (e) {
            // 目录非空或占用中时跳过
          }
        }
      } else {
        freed += removeFile(p);
      }
    } catch (e) {
      // 单个条目失败不影响其余清理
    }
  }
  return freed;
}

/**
 * 单项清理指定缓存分类（'msgs' | 'temp' | 'files'）。
 * 绝不触碰 preferencesDir 与离线待发队列。
 */
export function clearCacheBucket(ctx: common.UIAbilityContext, bucketId: string): number {
  let freed: number = 0;
  if (bucketId === 'msgs') {
    freed += clearDirectoryContents(msgsDirOf(ctx), true);
  } else if (bucketId === 'temp') {
    const dirs: string[] = tempDirsOf(ctx);
    for (let i = 0; i < dirs.length; i++) {
      freed += clearDirectoryContents(dirs[i], true);
    }
  } else if (bucketId === 'files') {
    const dirs: string[] = appFilesDirsOf(ctx);
    for (let i = 0; i < dirs.length; i++) {
      freed += clearDirectoryContents(dirs[i], true);
    }
  }
  console.info('DSH_STORAGE clearBucket ' + bucketId + ' freed=' + String(freed));
  return freed;
}

/**
 * 清理全部可清理缓存（含对话快照 filesDir/msgs、图片与临时缓存、下载与导出缓存），
 * 清完后可清理缓存总额真实归零 0 B，同时完整保留配对、主题与待发数据。
 */
export function clearCache(ctx: common.UIAbilityContext): number {
  let freed: number = 0;
  freed += clearCacheBucket(ctx, 'msgs');
  freed += clearCacheBucket(ctx, 'temp');
  freed += clearCacheBucket(ctx, 'files');
  return freed;
}

/** 人类可读的体积：统一委托 Format.bytes，保留原导出名兼容。 */
export function sizeText(n: number): string {
  return fmtBytes(n <= 0 ? 0 : n);
}
