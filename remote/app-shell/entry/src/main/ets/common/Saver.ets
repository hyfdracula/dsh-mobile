/**
 * 保存到手机：把电脑端工作区里的文件落到手机本地。
 *
 * 分两步，缺一不可：
 *
 * 1. 下载。request.downloadFile 把带令牌的直链先下到应用缓存目录。手机端没有写公共
 *    下载目录的权限，只能先落在自己的沙箱里；缓存目录被系统空间紧张时自动回收，正好
 *    适合这种用完即删的中间文件。走下载任务而不是 fetch，是因为工作区文件上限 64 MiB，
 *    一次性读进内存不划算。
 * 2. 保存。DocumentViewPicker 让用户自己挑位置（下载目录、文档目录或第三方网盘），
 *    拿到的 uri 用 fileIo.copyFile 从缓存拷过去。用户在选择器里取消时返回空数组，
 *    这里按「什么都没发生」处理，不报错。
 *
 * 失败一律抛 Error，消息已经带好「下载失败：」「保存失败：」前缀，调用方直接显示即可。
 */

import { common } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';

/** 整体下载超时：64 MiB 的大文件在慢网下也得给足时间，但不至于一直转圈。 */
const DOWNLOAD_TIMEOUT_MS: number = 180000;
/** 轮询下载状态的间隔，够密以免看起来卡住，又不至于空转。 */
const POLL_INTERVAL_MS: number = 120;
/** 缓存目录里的临时文件前缀，出问题好认。 */
const TEMP_PREFIX: string = 'dsh-save-';
/** 临时名保留多少位扩展名：超过这个长度的不像扩展名，宁可不带。 */
const MAX_SUFFIX_LEN: number = 12;

export class Saver {
  /**
   * 下载 url 指向的文件，并让用户选择保存到手机的哪个位置。
   *
   * @param ctx 能拿到 cacheDir 的上下文（页面里用 getContext(this) 转 UIAbilityContext）
   * @param url Api.fsDownloadUrl 拼好的带令牌直链
   * @param name 保存时显示的文件名，一般是电脑那边的原文件名
   * @returns true 已保存；false 用户取消（不是错误，调用方不要提示失败）
   * @throws Error 下载失败或写入失败，message 带中文前缀
   */
  static async save(ctx: common.UIAbilityContext, url: string, name: string, auth: string = ''): Promise<boolean> {
    const fileName: string = Saver.baseName(name);
    const tmpPath: string = Saver.tempPath(ctx, fileName);
    try {
      await Saver.download(ctx, url, tmpPath, auth);
    } catch (e) {
      Saver.drop(tmpPath);
      throw new Error('下载失败：' + Saver.reason(e as Error));
    }
    try {
      return await Saver.pickAndCopy(ctx, tmpPath, fileName);
    } catch (e) {
      throw new Error('保存失败：' + Saver.reason(e as Error));
    } finally {
      // 无论存成没存成，缓存里的中间文件都不该留下
      Saver.drop(tmpPath);
    }
  }

  /** 下载到沙箱路径，完成或失败都会把下载任务从系统队列里删掉。 */
  private static async download(ctx: common.UIAbilityContext, url: string, filePath: string, auth: string): Promise<void> {
    // 同名残留会让下载任务直接失败，先清掉
    Saver.drop(filePath);
    const header: Record<string, string> = {};
    if (auth !== '') {
      header['Authorization'] = auth;
    }
    const config: request.DownloadConfig = {
      url: url,
      filePath: filePath,
      // 蜂窝网也允许下载：手机上不一定接着 Wi-Fi，拦住反而莫名其妙
      enableMetered: true,
      enableRoaming: true,
      background: false,
      header: header
    };
    const task: request.DownloadTask = await request.downloadFile(ctx, config);
    try {
      await Saver.awaitTask(task);
    } finally {
      await Saver.dropTask(task);
    }
  }

  /** 轮询任务状态直到有结果。下载任务的 complete 回调注册有竞态，轮询更稳。 */
  private static async awaitTask(task: request.DownloadTask): Promise<void> {
    const started: number = Date.now();
    while (true) {
      const info: request.DownloadInfo = await task.getTaskInfo();
      // 老版下载接口的状态是数字常量（request.SESSION_*），没有枚举类型可引用
      if (info.status === request.SESSION_SUCCESSFUL) {
        return;
      }
      if (info.status === request.SESSION_FAILED) {
        throw new Error('下载任务失败，原因码 ' + String(info.failedReason));
      }
      if (Date.now() - started > DOWNLOAD_TIMEOUT_MS) {
        throw new Error('下载超时，请确认手机和电脑在同一个网络');
      }
      await Saver.wait(POLL_INTERVAL_MS);
    }
  }

  /** 删掉下载任务记录。删不掉不影响已经下好的文件，忽略即可。 */
  private static async dropTask(task: request.DownloadTask): Promise<void> {
    try {
      await task.delete();
    } catch (e) {
      // 任务已被系统回收，没什么可做的
    }
  }

  /** 弹系统保存面板，把缓存文件拷到用户选的位置。返回 false 表示用户取消。 */
  private static async pickAndCopy(ctx: common.UIAbilityContext, tmpPath: string, fileName: string): Promise<boolean> {
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    const uris: string[] = await viewPicker.save(options);
    if (uris.length === 0 || uris[0] === '') {
      return false;
    }
    const uri: string = uris[0];
    const target = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE);
    try {
      try {
        // 用户挑了个同名旧文件时，先截断，免得新内容比旧的短而留下尾巴
        fileIo.truncateSync(target.fd, 0);
      } catch (e) {
        // 面板默认建的是空文件，截不了也无所谓
      }
      await fileIo.copyFile(tmpPath, target.fd);
    } finally {
      fileIo.closeSync(target);
    }
    return true;
  }

  /**
   * 把一段文本存成文件（导出会话 Markdown 用）：走系统保存面板，用户自己挑位置。
   * 返回 false 表示用户取消，不是错误。
   */
  static async saveText(ctx: common.UIAbilityContext, text: string, name: string): Promise<boolean> {
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [Saver.baseName(name)];
    const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    const uris: string[] = await viewPicker.save(options);
    if (uris.length === 0 || uris[0] === '') {
      return false;
    }
    const target = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE);
    try {
      try {
        fileIo.truncateSync(target.fd, 0);
      } catch (e) {
      }
      fileIo.writeSync(target.fd, text);
    } finally {
      fileIo.closeSync(target);
    }
    return true;
  }
  /** 缓存目录里的一次性临时文件路径，带原扩展名以便选择器按类型排序。 */
  private static tempPath(ctx: common.UIAbilityContext, name: string): string {
    return ctx.cacheDir + '/' + TEMP_PREFIX + String(Date.now()) + Saver.suffix(name);
  }

  /** 只取文件名部分，去掉路径；路径分隔符两种都认，电脑那边可能是反斜杠。 */
  private static baseName(name: string): string {
    let base: string = name;
    const slash: number = base.lastIndexOf('/');
    if (slash >= 0) {
      base = base.substring(slash + 1);
    }
    const back: number = base.lastIndexOf('\\');
    if (back >= 0) {
      base = base.substring(back + 1);
    }
    return base.length > 0 ? base : '工作区文件';
  }

  /** 取扩展名（含点）。太长或没有就不带，免得拼出奇怪的文件名。 */
  private static suffix(name: string): string {
    const dot: number = name.lastIndexOf('.');
    if (dot <= 0 || dot === name.length - 1) {
      return '';
    }
    const raw: string = name.substring(dot);
    return raw.length <= MAX_SUFFIX_LEN ? raw : '';
  }

  /** 出错原因：拿得到 message 就用，拿不到退回通用文案。 */
  private static reason(e: Error): string {
    try {
      const msg: string = e.message;
      if (msg.length > 0) {
        return msg;
      }
    } catch (inner) {
      // 抛出来的不是 Error，只能给通用文案
    }
    return '未知错误';
  }

  /** 删临时文件，本来就不存在也算成功。 */
  private static drop(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (e) {
      // 文件不存在或已经被系统清理
    }
  }

  /** 轮询之间的停顿。写法跟 Api.ets 里的 sleep 一致，靠上下文推断 Promise 回调类型。 */
  private static wait(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(() => resolve(), ms));
  }
}
