import preferences from '@ohos.data.preferences';
import { Api, ApiInfo, SessionRow } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { Pairing } from '../common/Pairing';

const PREF_STORE: string = 'dsh_mobile_cfg';

/** 「忙碌时发送」两个档位：排队等这一轮跑完，或插话替掉当前轮。 */
const SEND_MODES: string[] = ['queue', 'steer'];

interface KVRow {
  k: string;
  v: string;
}

/**
 * 电脑管理：一台电脑的连接实况 + 与它相关的几个开关。
 * 结构对齐桌面端控制台的设备页（设备卡 / 连接 / 设置 / 版本与标识 / 高级）。
 */
@Component
export struct PcPage {
  api: Api = new Api('', '');
  wanBase: string = '';
  defaultLan: string = '';
  onExit: () => void = () => {};
  onRemove: () => void = () => {};
  @State private info: ApiInfo | null = null;
  @State private base: string = '';
  @State private lanIp: string = '';
  @State private publicUrl: string = '';
  @State private lan: boolean = false;
  @State private ms: number = 0;
  @State private count: number = 0;
  @State private loading: boolean = true;
  @State private err: string = '';
  @State private label: string = '';
  @State private sendMode: string = 'queue';
  @State private renaming: boolean = false;
  @State private nameEdit: string = '';
  @State private confirmRemove: boolean = false;

  aboutToAppear(): void {
    this.loadPrefs();
    this.reload();
  }

  private async loadPrefs(): Promise<void> {
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      const name = await p.get('deviceName', '') as string;
      const mode = await p.get('sendMode', 'queue') as string;
      this.label = name;
      this.sendMode = mode === 'steer' ? 'steer' : 'queue';
      AppStorage.setOrCreate('sendMode', this.sendMode);
    } catch (e) {
      console.error('DSH_PC pref load failed :: ' + (e as Error).message);
    }
  }

  private async savePref(key: string, value: string): Promise<void> {
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      await p.put(key, value);
      await p.flush();
    } catch (e) {
      console.error('DSH_PC pref save failed :: ' + (e as Error).message);
    }
  }

  private async reload(): Promise<void> {
    this.loading = true;
    const t0 = Date.now();
    try {
      const inf: ApiInfo = await this.api.info();
      this.ms = Date.now() - t0;
      this.info = inf;
      this.base = this.api.currentBase();
      this.lan = this.api.isLan();
      this.err = '';
      try {
        const rows: SessionRow[] = await this.api.sessions();
        this.count = rows.length;
      } catch (e2) {
        this.count = 0;
      }
      // 局域网地址只有 /api/pair/info 给得到（老版插件没有这条路由，
      // 失败就退回当前 base，不影响本页其余字段）。
      try {
        const pinfo = await Pairing.info(this.base);
        this.lanIp = pinfo.lan.length > 0 ? pinfo.lan[0].replace('http://', '') : '';
        this.publicUrl = pinfo.publicUrl;
      } catch (e3) {
        this.lanIp = '';
        this.publicUrl = '';
      }
    } catch (e) {
      this.err = (e as Error).message;
      this.ms = 0;
    } finally {
      this.loading = false;
    }
  }

  private deviceName(): string {
    if (this.label !== '') {
      return this.label;
    }
    return this.info !== null ? this.info.host : '这台电脑';
  }

  private stateText(): string {
    if (this.loading) {
      return '检测中…';
    }
    if (this.err !== '') {
      return '未连接';
    }
    return (this.lan ? '局域网' : '公网') + ' · ' + this.ms + 'ms';
  }

  private async setSendMode(v: string): Promise<void> {
    this.sendMode = v;
    AppStorage.setOrCreate('sendMode', v);
    Haptics.tap();
    await this.savePref('sendMode', v);
  }

  private async commitName(): Promise<void> {
    const v = this.nameEdit.trim();
    this.label = v;
    this.renaming = false;
    Haptics.tap();
    await this.savePref('deviceName', v);
  }

  // ---------- 通用件 ----------

  @Builder
  backRow(title: string) {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor(Tokens.fg)
        .width(40)
        .textAlign(TextAlign.Start)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          Haptics.soft();
          this.onExit();
        })
      Column() {
        Text('设置')
          .fontSize(11)
          .fontColor(Tokens.dim2)
        Text(title)
          .fontSize(19)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .margin({ top: 1 })
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
    }
    .width('100%')
    .height(52)
    .margin({ bottom: 10 })
  }

  @Builder
  group(title: string) {
    Text(title)
      .fontSize(10.5)
      .fontColor(Tokens.dim2)
      .letterSpacing(1.2)
      .margin({ left: 6, top: 18, bottom: 8 })
  }

  /**
   * 行的键值按 id 现算：@Builder 的值传参拿到的是首帧快照，
   * 「连接中…」这类状态变化传不进去，所以只传静态 id。
   */
  private kvOf(id: string): KVRow {
    if (id === 'ip') {
      if (this.lanIp !== '') {
        return { k: '电脑 IP', v: this.lanIp };
      }
      return { k: '电脑 IP', v: this.base !== '' ? this.base.replace('http://', '').replace('https://', '') : '—' };
    }
    if (id === 'wan') {
      if (this.publicUrl !== '') {
        return { k: '公网', v: this.publicUrl.replace('https://', '').replace('http://', '') };
      }
      return { k: '公网', v: this.wanBase !== '' ? this.wanBase.replace('https://', '') : '未配置' };
    }
    if (id === 'lan') {
      return { k: '局域网', v: this.lan ? '加密连接使用中' : '未使用（走公网）' };
    }
    if (id === 'count') {
      return { k: '会话数', v: this.count + ' 个' };
    }
    if (id === 'host') {
      return { k: '电脑名称', v: this.info !== null ? this.info.host : '—' };
    }
    if (id === 'plugin') {
      return { k: '连接插件', v: this.info !== null ? 'v' + this.info.version : '—' };
    }
    if (id === 'inst') {
      return { k: '实例标识', v: 'dsh-mobile' };
    }
    return { k: '端口', v: this.info !== null ? '' + this.info.port : '8901' };
  }

  @Builder
  row(id: string, last: boolean) {
    Column() {
      Row() {
        Text(this.kvOf(id).k)
          .fontSize(13.5)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text(this.kvOf(id).v)
          .fontSize(12.5)
          .fontColor(Tokens.dim)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 12 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .alignItems(VerticalAlign.Center)
      if (!last) {
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
      }
    }
    .width('100%')
  }

  // ---------- 设备卡 ----------

  @Builder
  deviceCard() {
    Row() {
      Image($r('app.media.app_icon'))
        .width(44)
        .height(44)
        .borderRadius(12)
      Column() {
        Text(this.deviceName())
          .fontSize(15.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Row()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.err === '' ? Tokens.ok : Tokens.err)
          Text(this.stateText())
            .fontSize(11.5)
            .fontColor(this.err === '' ? Tokens.dim : Tokens.err)
            .margin({ left: 6 })
        }
        .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
      Text('重命名')
        .fontSize(11.5)
        .fontColor(Tokens.accentInk)
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor(Tokens.accent)
        .borderRadius(Tokens.rPill)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          this.nameEdit = this.deviceName();
          this.renaming = true;
        })
    }
    .width('100%')
    .padding(14)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rGroup)
  }

  // ---------- 各分组 ----------

  @Builder
  connGroup() {
    this.group('连接')
    Column() {
      this.row('ip', false)
      this.row('wan', false)
      this.row('lan', false)
      this.row('count', false)
      Row() {
        Text('重新连接')
          .fontSize(13.5)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text(this.loading ? '连接中…' : '⟳')
          .fontSize(this.loading ? 12 : 17)
          .fontColor(Tokens.accent)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .alignItems(VerticalAlign.Center)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        Haptics.soft();
        this.reload();
      })
    }
    .width('100%')
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rGroup)
    .clip(true)
  }

  @Builder
  sendGroup() {
    this.group('设置')
    Column() {
      Row() {
        Column() {
          Text('忙碌时发送')
            .fontSize(13.5)
            .fontColor(Tokens.fg)
          Text(this.sendMode === 'steer' ? '插话：替掉正在跑的这一轮' : '排队：等这一轮跑完再发')
            .fontSize(10.5)
            .fontColor(Tokens.dim2)
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Row() {
          ForEach(SEND_MODES, (m: string) => {
            Text(m === 'queue' ? '排队' : '插话')
              .fontSize(11.5)
              .fontColor(this.sendMode === m ? Tokens.accentInk : Tokens.dim)
              .backgroundColor(this.sendMode === m ? Tokens.accent : Tokens.surface3)
              .borderRadius(Tokens.rPill)
              .padding({ left: 13, right: 13, top: 7, bottom: 7 })
              .margin({ left: 6 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
              .onClick(() => {
                this.setSendMode(m);
              })
          }, (m: string) => m)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 13, bottom: 13 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rGroup)
    .clip(true)
  }

  @Builder
  versionGroup() {
    this.group('版本与标识')
    Column() {
      this.row('host', false)
      this.row('plugin', false)
      this.row('inst', false)
      this.row('port', true)
    }
    .width('100%')
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rGroup)
    .clip(true)
  }

  @Builder
  advGroup() {
    this.group('高级')
    Column() {
      Row() {
        Text('移除此电脑')
          .fontSize(13.5)
          .fontColor(Tokens.err)
          .layoutWeight(1)
        Text('›')
          .fontSize(18)
          .fontColor(Tokens.dim2)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .alignItems(VerticalAlign.Center)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        Haptics.soft();
        this.confirmRemove = true;
      })
    }
    .width('100%')
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rGroup)
    .clip(true)
  }

  // ---------- 弹窗 ----------

  @Builder
  renameSheet() {
    Column() {
      Text('重命名这台电脑')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
      Text('只改手机里的显示名，电脑本身不受影响。')
        .fontSize(11.5)
        .fontColor(Tokens.dim2)
        .margin({ top: 6 })
      TextInput({ text: this.nameEdit, placeholder: '给这台电脑起个名字' })
        .fontSize(14)
        .height(46)
        .backgroundColor(Tokens.surface2)
        .borderRadius(Tokens.rInput)
        .margin({ top: 14 })
        .onChange((v: string) => {
          this.nameEdit = v;
        })
      Row() {
        Text('取消')
          .fontSize(14)
          .fontColor(Tokens.dim)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(44)
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.surface3)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.renaming = false;
          })
        Text('保存')
          .fontSize(14)
          .fontColor(Tokens.accentInk)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(44)
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.accentStrong)
          .margin({ left: 10 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.commitName();
          })
      }
      .width('100%')
      .margin({ top: 14 })
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rGroup)
    .shadow({ radius: 30, color: Tokens.shadow, offsetY: 8 })
  }

  @Builder
  removeSheet() {
    Column() {
      Text('移除这台电脑？')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
      Text('只清除手机里的连接配置，电脑上的 DSH 和会话都不受影响。之后可以重新配对。')
        .fontSize(11.5)
        .fontColor(Tokens.dim2)
        .margin({ top: 8 })
        .lineHeight(17)
      Row() {
        Text('取消')
          .fontSize(14)
          .fontColor(Tokens.dim)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(44)
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.surface3)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.confirmRemove = false;
          })
        Text('移除')
          .fontSize(14)
          .fontColor(Tokens.accentInk)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(44)
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.err)
          .margin({ left: 10 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.confirmRemove = false;
            Haptics.tap();
            this.onRemove();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rGroup)
    .shadow({ radius: 30, color: Tokens.shadow, offsetY: 8 })
  }

  build() {
    Stack() {
      Column() {
        this.backRow('电脑管理')
        this.deviceCard()
        if (this.err !== '') {
          Text(this.err)
            .fontSize(11)
            .fontColor(Tokens.err)
            .width('100%')
            .margin({ top: 8, left: 4 })
            .lineHeight(16)
        }
        this.connGroup()
        this.sendGroup()
        this.versionGroup()
        this.advGroup()
        Text('这台电脑的配对码与二维码在电脑端「设置 → 手机连接」里。')
          .fontSize(10.5)
          .fontColor(Tokens.dim2)
          .margin({ top: 16, left: 4 })
          .lineHeight(16)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ bottom: 120 })

      if (this.renaming || this.confirmRemove) {
        Column() {
          if (this.renaming) {
            this.renameSheet()
          } else {
            this.removeSheet()
          }
        }
        .width('100%')
        .padding({ left: 18, right: 18 })
        .justifyContent(FlexAlign.Center)
        .height('100%')
        .backgroundColor('#99000000')
        .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
        .onClick(() => {
          // 点遮罩不误关：对话框上的点击不会冒泡到这里，误触就让它留着
        })
      }
    }
    .width('100%')
    .alignContent(Alignment.Top)
  }
}
