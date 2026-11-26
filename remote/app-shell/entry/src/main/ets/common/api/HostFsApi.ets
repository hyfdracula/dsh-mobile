import { ApiTransport } from '../ApiTransport';
import {
  FsDeleteBody,
  FsFile,
  FsFileResp,
  FsListing,
  FsMkdirBody,
  FsResp,
  FsUploadBody,
  FsUploadItem,
  FsUploadResp,
  FsWriteBody,
  GitDiffResp,
  GitStatusResp,
  HostDirsResp,
  HostPluginGroup,
  HostPluginsResp,
  HostPluginToggleBody,
  HostPluginToggleResp,
  HostSchedulesResp,
  HostTaskActionBody,
  HostTaskRow,
  LoopbackPortsResp,
  LoopbackSignBody,
  LoopbackSignResp,
  PluginSettingField,
  PluginSettingsResp,
  PluginSettingsSaveBody,
  RawSignBody,
  RawSignResp,
  TerminalInputBody,
  TerminalOpenResp,
  TerminalPollResp
} from '../ApiTypes';

/**
 * 宿主能力、工作区文件系统、Git 状态/Diff、受控终端与本机开发服预览（G5 / G6 / R5 / R6 / R9）。
 */
export class HostFsApi {
  static async hostPlugins(t: ApiTransport): Promise<HostPluginGroup[]> {
    const r: HostPluginsResp = await t.call<HostPluginsResp>('/api/host/plugins', 'GET');
    return r.groups === undefined ? [] : r.groups;
  }

  static async pluginToggle(t: ApiTransport, profile: string, name: string, enabled: boolean): Promise<boolean> {
    const body: HostPluginToggleBody = { profile: profile, name: name, enabled: enabled };
    const r: HostPluginToggleResp = await t.call<HostPluginToggleResp>(
      '/api/host/plugins/toggle', 'POST', JSON.stringify(body));
    return r.changed === true;
  }

  static async pluginSettings(t: ApiTransport, profile: string, name: string): Promise<PluginSettingsResp> {
    const q: string = '/api/host/plugins/settings?profile=' + encodeURIComponent(profile) +
      '&name=' + encodeURIComponent(name);
    const r: PluginSettingsResp = await t.call<PluginSettingsResp>(q, 'GET');
    return {
      ok: r.ok,
      writable: r.writable === true,
      restartRequired: r.restartRequired,
      fields: r.fields !== undefined ? r.fields : []
    };
  }

  static async savePluginSettings(
    t: ApiTransport,
    profile: string,
    name: string,
    fields: PluginSettingField[]
  ): Promise<PluginSettingsResp> {
    const body: PluginSettingsSaveBody = { profile: profile, name: name, fields: fields };
    const r: PluginSettingsResp = await t.call<PluginSettingsResp>(
      '/api/host/plugins/settings', 'POST', JSON.stringify(body));
    return {
      ok: r.ok,
      writable: r.writable === true,
      restartRequired: r.restartRequired === true,
      fields: r.fields !== undefined ? r.fields : []
    };
  }

  static async hostSchedules(t: ApiTransport): Promise<HostTaskRow[]> {
    const r: HostSchedulesResp = await t.call<HostSchedulesResp>('/api/host/schedules', 'GET');
    return r.items === undefined ? [] : r.items;
  }

  static async scheduleAction(t: ApiTransport, id: string, action: string): Promise<void> {
    const body: HostTaskActionBody = { action: action };
    await t.call<object>(
      '/api/host/schedules/' + encodeURIComponent(id) + '/action', 'POST', JSON.stringify(body));
  }

  static async hostDirs(t: ApiTransport, path: string = ''): Promise<HostDirsResp> {
    const q: string = path === '' ? '' : '?path=' + encodeURIComponent(path);
    const r: HostDirsResp = await t.call<HostDirsResp>('/api/host/dirs' + q, 'GET');
    return {
      ok: r.ok,
      path: r.path !== undefined ? r.path : '',
      parent: r.parent !== undefined ? r.parent : '',
      roots: r.roots,
      dirs: r.dirs !== undefined ? r.dirs : [],
      recent: r.recent !== undefined ? r.recent : []
    };
  }

  static async fsList(
    t: ApiTransport,
    id: string,
    path: string,
    offset: number = 0,
    limit: number = 400
  ): Promise<FsListing> {
    const params: string[] = [];
    if (path !== '') {
      params.push('path=' + encodeURIComponent(path));
    }
    if (offset > 0) {
      params.push('offset=' + String(offset));
    }
    if (limit !== 400 && limit > 0) {
      params.push('limit=' + String(limit));
    }
    const q: string = params.length > 0 ? '?' + params.join('&') : '';
    const r: FsResp = await t.call<FsResp>('/api/sessions/' + encodeURIComponent(id) + '/fs' + q, 'GET');
    return {
      root: r.root === undefined ? '' : r.root,
      path: r.path === undefined ? '' : r.path,
      entries: r.entries === undefined ? [] : r.entries,
      more: r.more === true,
      fallback: r.fallback === true,
      total: r.total,
      offset: r.offset,
      nextOffset: r.nextOffset
    };
  }

  static async fsFile(t: ApiTransport, id: string, path: string): Promise<FsFile> {
    const r: FsFileResp = await t.call<FsFileResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/fs/file?path=' + encodeURIComponent(path), 'GET');
    return {
      name: r.name === undefined ? '' : r.name,
      size: r.size === undefined ? 0 : r.size,
      text: r.text === undefined ? '' : r.text
    };
  }

  static async fsMkdir(t: ApiTransport, id: string, path: string): Promise<void> {
    const body: FsMkdirBody = { path: path };
    await t.call<object>(
      '/api/sessions/' + encodeURIComponent(id) + '/fs/mkdir', 'POST', JSON.stringify(body));
  }

  static async fsUpload(t: ApiTransport, id: string, dir: string, files: FsUploadItem[]): Promise<FsUploadResp> {
    const body: FsUploadBody = { dir: dir, files: files };
    const r: FsUploadResp = await t.call<FsUploadResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/fs/upload',
      'POST',
      JSON.stringify(body),
      undefined,
      undefined,
      20000
    );
    return {
      ok: r.ok,
      saved: r.saved !== undefined ? r.saved : [],
      bytes: r.bytes !== undefined ? r.bytes : 0
    };
  }

  static async fsRename(t: ApiTransport, id: string, path: string, to: string): Promise<void> {
    const body: FsWriteBody = { path: path, to: to };
    await t.call<object>(
      '/api/sessions/' + encodeURIComponent(id) + '/fs/rename', 'POST', JSON.stringify(body));
  }

  static async fsDelete(t: ApiTransport, id: string, path: string): Promise<void> {
    const body: FsDeleteBody = { path: path };
    await t.call<object>(
      '/api/sessions/' + encodeURIComponent(id) + '/fs/delete', 'POST', JSON.stringify(body));
  }

  static async signFsRaw(t: ApiTransport, id: string, path: string): Promise<void> {
    const key: string = id + '|' + path;
    const nowSec: number = Math.floor(Date.now() / 1000);
    if (t.rawSig.has(key) && (t.rawExp.get(key) ?? 0) > nowSec + 60) {
      return;
    }
    try {
      const body: RawSignBody = { path: path };
      const r: RawSignResp = await t.call<RawSignResp>(
        '/api/sessions/' + encodeURIComponent(id) + '/fs/sign', 'POST', JSON.stringify(body));
      if (r.sig !== undefined && r.e !== undefined) {
        t.rawSig.set(key, 'e=' + r.e + '&sig=' + r.sig);
        const e: number = Number(r.e);
        t.rawExp.set(key, Number.isFinite(e) ? e : 0);
      }
    } catch (e) {
      console.info('DSH_RAW_SIGN skipped :: ' + (e as Error).message);
    }
  }

  static fsRawUrl(t: ApiTransport, id: string, path: string): string {
    const key: string = id + '|' + path;
    const sig: string | undefined = t.rawSig.get(key);
    if (sig !== undefined && (t.rawExp.get(key) ?? 0) > Math.floor(Date.now() / 1000) + 30) {
      return t.currentBase() + '/api/sessions/' + encodeURIComponent(id) + '/fs/raw?path=' +
        encodeURIComponent(path) + '&' + sig;
    }
    return '';
  }

  static fsDownloadUrl(t: ApiTransport, id: string, path: string): string {
    return t.currentBase() + '/api/sessions/' + encodeURIComponent(id) + '/fs/download?path=' +
      encodeURIComponent(path);
  }

  static async gitStatus(t: ApiTransport, id: string): Promise<GitStatusResp> {
    const r: GitStatusResp = await t.call<GitStatusResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/git/status', 'GET');
    return {
      ok: r.ok,
      isRepo: r.isRepo === true,
      branch: r.branch !== undefined ? r.branch : '',
      ahead: r.ahead !== undefined ? r.ahead : 0,
      behind: r.behind !== undefined ? r.behind : 0,
      files: r.files !== undefined ? r.files : []
    };
  }

  static async gitDiff(t: ApiTransport, id: string, path: string, staged: boolean = false): Promise<GitDiffResp> {
    const q: string = '?path=' + encodeURIComponent(path) + '&staged=' + (staged ? '1' : '0');
    const r: GitDiffResp = await t.call<GitDiffResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/git/diff' + q, 'GET');
    return {
      ok: r.ok,
      path: r.path !== undefined ? r.path : path,
      diff: r.diff !== undefined ? r.diff : '',
      truncated: r.truncated === true
    };
  }

  static async terminalOpen(t: ApiTransport, id: string): Promise<TerminalOpenResp> {
    const r: TerminalOpenResp = await t.call<TerminalOpenResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/terminal/open', 'POST', '{}');
    return {
      ok: r.ok,
      cwd: r.cwd !== undefined ? r.cwd : '',
      running: r.running === true,
      exitCode: r.exitCode !== undefined ? r.exitCode : null,
      output: r.output !== undefined ? r.output : '',
      seq: r.seq !== undefined ? r.seq : 0
    };
  }

  static async terminalPoll(t: ApiTransport, id: string, since: number = 0): Promise<TerminalPollResp> {
    const r: TerminalPollResp = await t.call<TerminalPollResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/terminal/poll?since=' + String(since), 'GET');
    return {
      ok: r.ok,
      cwd: r.cwd,
      running: r.running === true,
      exitCode: r.exitCode !== undefined ? r.exitCode : null,
      output: r.output !== undefined ? r.output : '',
      seq: r.seq !== undefined ? r.seq : 0
    };
  }

  static async terminalInput(
    t: ApiTransport,
    id: string,
    data: string,
    action: string = '',
    raw: boolean = false
  ): Promise<TerminalPollResp> {
    const body: TerminalInputBody = {};
    if (action !== '') {
      body.action = action;
    }
    if (data !== '') {
      body.data = data;
    }
    if (raw) {
      body.raw = true;
    }
    const r: TerminalPollResp = await t.call<TerminalPollResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/terminal/input', 'POST', JSON.stringify(body));
    return {
      ok: r.ok,
      cwd: r.cwd,
      running: r.running === true,
      exitCode: r.exitCode !== undefined ? r.exitCode : null,
      output: r.output !== undefined ? r.output : '',
      seq: r.seq !== undefined ? r.seq : 0
    };
  }

  static async loopbackPorts(t: ApiTransport): Promise<number[]> {
    try {
      const r: LoopbackPortsResp = await t.call<LoopbackPortsResp>('/api/loopback/ports', 'GET');
      return r.ports !== undefined ? r.ports : [];
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      if (msg.indexOf('HTTP 404') >= 0) {
        return [];
      }
      throw new Error(msg !== '' ? msg : '获取本机授权预览端口失败');
    }
  }

  static async signLoopback(t: ApiTransport, port: number): Promise<boolean> {
    const nowSec: number = Math.floor(Date.now() / 1000);
    if (t.lbSig.has(port) && (t.lbExp.get(port) ?? 0) > nowSec + 60) {
      return true;
    }
    try {
      const body: LoopbackSignBody = { port: port };
      const r: LoopbackSignResp = await t.call<LoopbackSignResp>(
        '/api/loopback/sign', 'POST', JSON.stringify(body));
      if (r.sig !== undefined && r.e !== undefined) {
        t.lbSig.set(port, 'e=' + r.e + '&sig=' + r.sig);
        const exp: number = Number(r.e);
        t.lbExp.set(port, Number.isFinite(exp) ? exp : 0);
        return true;
      }
    } catch (e) {
      console.info('DSH_LB_SIGN failed :: ' + (e as Error).message);
    }
    return false;
  }

  static loopbackUrl(t: ApiTransport, port: number, subPath: string = '/'): string {
    const sig: string | undefined = t.lbSig.get(port);
    if (sig === undefined || (t.lbExp.get(port) ?? 0) <= Math.floor(Date.now() / 1000) + 30) {
      return '';
    }
    const cleanSub: string = subPath.startsWith('/') ? subPath : '/' + subPath;
    const sep: string = cleanSub.indexOf('?') >= 0 ? '&' : '?';
    return t.currentBase() + '/api/loopback/' + String(port) + cleanSub + sep + sig;
  }
}
