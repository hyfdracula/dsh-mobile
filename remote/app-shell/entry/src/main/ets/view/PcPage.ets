import preferences from '@ohos.data.preferences';
import { Api, ApiInfo, SessionRow } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { Pairing } from '../common/Pairing';

const PREF_STORE: string = 'dsh_mobile_cfg';

interface KVRow {
  k: string;
  v: string;
}

/**
 * 电脑管理：一台电脑的连接实况 + 与它相关的几个开关。
 * 结构对齐桌面端控制台的设备页（设备卡 / 连接 / 版本与标识 / 高级）。
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
  @State private renaming: boolean = false;
  @State private nameEdit: string = '';
  @State private confirmRemove: boolean = false;
  /** 主题底色：顶部渐变要和页面底色同色，切换主题时跟着走 */
  @StorageLink('themeBg') themeBg: string = Tokens.bg;

  aboutToAppear(): void {
    this.loadPrefs();
    this.reload();
  }

  private async loadPrefs(): Promise<void> {
    try {
      const p = await preferences.getPreferences(getContext(this), PREF_STORE);
      const name = await p.get('deviceName', '') as string;
      this.label = name;
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

  private async commitName(): Promise<void> {
    const v = this.nameEdit.trim();
    this.label = v;
    this.renaming = false;
    Haptics.tap();
    await this.savePref('deviceName', v);
  }

  // ---------- 头部（二级页统一：内容和设置一级页同一套，标题浮在渐变上） ----------

  /** 顶部同色渐变：内容滚上来时在标题下面淡出，替掉原来那块不透明标题栏 */

  @Builder
  subHeader(title: string) {
    Row() {
      Stack() {
        Image($r('app.media.ic_back'))
          .width(20)
          .height(20)
          .fillColor(Tokens.fg)
          .objectFit(ImageFit.Contain)
      }
      .width(38)
      .height(38)
      .borderRadius(999)
      .backgroundColor(Tokens.isDark ? '#3DFFFFFF' : '#8CFFFFFF')
      .backdropBlur(22)
      .border({ width: 1, color: Tokens.isDark ? '#40FFFFFF' : '#D9FFFFFF' })
      .shadow({ radius: 14, color: Tokens.isDark ? '#40000000' : '#26000000', offsetY: 4 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .onClick(() => {
        Haptics.tap();
        this.onExit();
      })
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ left: 12 })
      Blank()
    }
    .width('100%')
    .height(48)
    // 父级 NavDestination 已经有 16/54 的留白，这里只补一点上边距，
    // 标题才能和设置页其它二级页（通知/外观/连接）停在同一条水平线上
    .margin({ top: 4 })
    .alignItems(VerticalAlign.Center)
  }

  // ---------- 通用件 ----------

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
  versionGroup() {
    this.group('版本')
    Column() {
      this.row('host', false)
      this.row('plugin', true)
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
    Stack({ alignContent: Alignment.Top }) {
      // 内容在最底层：顶部留出浮动标题行的高度，底部留出底部导航的高度
      List() {
        ListItem() {
          Column() {
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
          .padding({ top: 66, bottom: 120 })
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)

      // 同色渐变：滚上来的卡片在标题下面淡出，不再有硬边遮罩

      // 浮动的玻璃返回钮 + 标题
      this.subHeader('电脑管理')

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
    .height('100%')
    .backgroundColor(this.themeBg)
  }
}
