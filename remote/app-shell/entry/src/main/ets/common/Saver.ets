/**
 * 保存到手机：基于 @kit.NetworkKit HTTP 流式接收落沙箱缓存再由 DocumentViewPicker 导出，
 * 避免大文件内存溢出，并移除已废弃的 request.downloadFile。
 */

import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { AppCtx } from './AppCtx';

const DOWNLOAD_TIMEOUT_MS: number = 180000;
const TEMP_PREFIX: string = 'am-save-';
const MAX_SUFFIX_LEN: number = 12;

export class Saver {
  static async save(ctx: common.UIAbilityContext, url: string, name: string, auth: string = ''): Promise<boolean> {
    const abilityCtx: common.UIAbilityContext = ctx !== undefined && ctx !== null ? ctx : AppCtx.ability();
    const fileName: string = Saver.baseName(name);
    const tmpPath: string = Saver.tempPath(abilityCtx, fileName);
    try {
      await Saver.downloadStream(url, tmpPath, auth);
    } catch (e) {
      Saver.drop(tmpPath);
      throw new Error('下载失败：' + Saver.reason(e as Error));
    }
    try {
      return await Saver.pickAndCopy(abilityCtx, tmpPath, fileName);
    } catch (e) {
      throw new Error('保存失败：' + Saver.reason(e as Error));
    } finally {
      Saver.drop(tmpPath);
    }
  }

  private static async downloadStream(url: string, filePath: string, auth: string): Promise<void> {
    Saver.drop(filePath);
    const header: Record<string, string> = {};
    if (auth !== '') {
      header['Authorization'] = auth;
    }
    const req: http.HttpRequest = http.createHttp();
    const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    let writeErrMsg: string = '';
    const onChunk = (chunk: ArrayBuffer): void => {
      if (writeErrMsg !== '') {
        return;
      }
      try {
        fileIo.writeSync(file.fd, chunk);
      } catch (e) {
        writeErrMsg = (e as Error).message ?? 'write failed';
      }
    };
    req.on('dataReceive', onChunk);
    try {
      const code: number = await req.requestInStream(url, {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: 10000,
        readTimeout: DOWNLOAD_TIMEOUT_MS
      });
      if (writeErrMsg !== '') {
        throw new Error(writeErrMsg);
      }
      if (code < 200 || code >= 300) {
        throw new Error('HTTP ' + String(code));
      }
    } finally {
      try {
        req.off('dataReceive', onChunk);
      } catch (e) {
      }
      try {
        fileIo.closeSync(file);
      } catch (e) {
      }
      req.destroy();
    }
  }

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
        fileIo.truncateSync(target.fd, 0);
      } catch (e) {
      }
      await fileIo.copyFile(tmpPath, target.fd);
    } finally {
      fileIo.closeSync(target);
    }
    return true;
  }

  static async saveText(ctx: common.UIAbilityContext, text: string, name: string): Promise<boolean> {
    const abilityCtx: common.UIAbilityContext = ctx !== undefined && ctx !== null ? ctx : AppCtx.ability();
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [Saver.baseName(name)];
    const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(abilityCtx);
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

  private static tempPath(ctx: common.UIAbilityContext, name: string): string {
    return ctx.cacheDir + '/' + TEMP_PREFIX + String(Date.now()) + Saver.suffix(name);
  }

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

  private static suffix(name: string): string {
    const dot: number = name.lastIndexOf('.');
    if (dot <= 0 || dot === name.length - 1) {
      return '';
    }
    const raw: string = name.substring(dot);
    return raw.length <= MAX_SUFFIX_LEN ? raw : '';
  }

  private static reason(e: Error): string {
    try {
      const msg: string = e.message;
      if (msg.length > 0) {
        return msg;
      }
    } catch (inner) {
    }
    return '未知错误';
  }

  private static drop(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (e) {
    }
  }
}
