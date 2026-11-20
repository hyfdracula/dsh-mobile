import { Api, PermRow, PresetRow } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { ChatParam } from '../common/Types';
import { NavFx, NavFxSink } from '../common/NavFx';

/**
 * Two session-level switches that live outside the model picker:
 * the Agent preset (which instructions and tools this session runs with) and
 * the permission preset (what it may do without asking).
 *
 * Both catalogs are host services that may be absent on other builds, so every
 * read has an empty fallback and the page says so instead of failing.
 */
@Component
export struct PresetsPage {
  @Consume('stack') stack: NavPathStack;
  api: Api = new Api('', '');
  param: ChatParam = { id: '', title: '' };

  @State private presets: PresetRow[] = [];
  @State private currentPreset: string = '';
  @State private permPresets: PermRow[] = [];
  @State private currentPerm: string = '';
  @State private loading: boolean = true;
  @State private err: string = '';
  @State private note: string = '';
  /** 转场状态：由 Navigation 的 customNavContentTransition 按 navDestinationId 驱动。 */
  @State private fxTx: string = '0%';
  @State private fxOp: number = 1;
  @State private fxSc: number = 1;
  private fxId: string = '';
  private fxSink: NavFxSink | undefined = undefined;

  /** 把本页的转场状态登记给 Navigation。 */
  private bindFx(id: string): void {
    const sink: NavFxSink = {
      apply: (tx: string, op: number, sc: number): void => {
        this.fxTx = tx;
        this.fxOp = op;
        this.fxSc = sc;
      }
    };
    this.fxId = id;
    this.fxSink = sink;
    NavFx.register(id, sink);
  }

  aboutToDisappear(): void {
    const s = this.fxSink;
    if (s !== undefined) {
      NavFx.unregister(this.fxId, s);
    }
  }

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.err = '';
    try {
      const p = await this.api.presets();
      this.presets = p.presets;
      this.currentPreset = p.current;
      const q = await this.api.permissions(this.param.id);
      this.permPresets = q.presets;
      this.currentPerm = q.current;
      if (p.unavailable && q.unavailable) {
        this.note = '这台宿主没有暴露预设服务';
      } else if (p.unavailable) {
        this.note = 'Agent 预设目录不可用，权限仍可切换';
      } else if (q.unavailable) {
        this.note = '权限预设不可用，Agent 预设仍可切换';
      }
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private async choosePreset(id: string, name: string): Promise<void> {
    try {
      const r = await this.api.selectPreset(this.param.id, id);
      this.currentPreset = id;
      this.note = r === 'global'
        ? ('这个会话已经开过轮，已把「' + name + '」设为新会话的默认预设')
        : ('已切到「' + name + '」');
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  private async choosePerm(value: string, name: string): Promise<void> {
    try {
      const now = await this.api.setPermission(this.param.id, value);
      this.currentPerm = now;
      this.note = '权限已改为「' + name + '」';
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  @Builder
  row(title: string, sub: string, active: boolean, onTap: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(14.5)
          .fontColor(Tokens.fg)
        if (sub !== '') {
          Text(sub)
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
            .margin({ top: 3 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (active) {
        Text('当前')
          .fontSize(11)
          .fontColor(Tokens.accent)
          .borderRadius(999)
          .border({ width: 1, color: Tokens.accent })
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: 14, right: 14 })
    .borderRadius(12)
    .backgroundColor(active ? Tokens.surface3 : Tokens.surface)
    .margin({ bottom: 8 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .onClick(onTap)
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          Text('‹')
            .fontSize(30)
            .fontColor(Tokens.fg)
            .width(34)
            .height(34)
            .textAlign(TextAlign.Center)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => this.stack.pop())
          Column() {
            Text('预设与权限')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.fg)
            Text(this.param.title !== '' ? this.param.title : '当前会话')
              .fontSize(11)
              .fontColor(Tokens.dim2)
              .margin({ top: 2 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 4 })

          Text('刷新')
            .fontSize(12.5)
            .fontColor(Tokens.dim)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(999)
            .border({ width: 1, color: Tokens.line })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.load();
            })
        }
        .width('100%')
        .padding({ left: 8, right: 14, top: 8, bottom: 8 })

        if (this.err !== '') {
          Text(this.err)
            .fontSize(12)
            .fontColor(Tokens.err)
            .width('100%')
            .padding({ left: 18, right: 18, bottom: 8 })
        }
        if (this.note !== '') {
          Text(this.note)
            .fontSize(12)
            .fontColor(Tokens.ok)
            .width('100%')
            .padding({ left: 18, right: 18, bottom: 8 })
        }

        List() {
          ListItem() {
            Column() {
              Text('Agent 预设')
                .fontSize(11)
                .fontColor(Tokens.dim2)
                .letterSpacing(1.2)
                .width('100%')
                .margin({ top: 6, bottom: 10 })

              if (this.loading) {
                Row() {
                  LoadingProgress().width(18).height(18).color(Tokens.dim2)
                  Text('读取中…').fontSize(13).fontColor(Tokens.dim2).margin({ left: 8 })
                }
                .height(60)
              } else if (this.presets.length === 0) {
                Text('宿主没有提供预设目录')
                  .fontSize(12.5)
                  .fontColor(Tokens.dim2)
                  .width('100%')
                  .margin({ bottom: 12 })
              } else {
                ForEach(this.presets, (p: PresetRow) => {
                  this.row(p.name, p.description, p.id === this.currentPreset, () => {
                    this.choosePreset(p.id, p.name);
                  })
                }, (p: PresetRow) => 'p-' + p.id)
              }

              Text('权限')
                .fontSize(11)
                .fontColor(Tokens.dim2)
                .letterSpacing(1.2)
                .width('100%')
                .margin({ top: 18, bottom: 10 })

              if (this.permPresets.length === 0) {
                Text('宿主没有提供权限目录')
                  .fontSize(12.5)
                  .fontColor(Tokens.dim2)
                  .width('100%')
                  .margin({ bottom: 20 })
              } else {
                ForEach(this.permPresets, (p: PermRow) => {
                  this.row(p.name, p.description, p.value === this.currentPerm, () => {
                    this.choosePerm(p.value, p.name);
                  })
                }, (p: PermRow) => 'q-' + p.value)
              }
            }
            .width('100%')
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .padding({ top: 46 })
    }
    .hideTitleBar(true)
    .backgroundColor(Tokens.bg)
    .onReady((context: NavDestinationContext) => {
      const id: string | undefined = context.navDestinationId;
      if (id !== undefined && id !== '') {
        this.bindFx(id);
      }
    })
    .translate({ x: this.fxTx })
    .opacity(this.fxOp)
    .scale({ x: this.fxSc, y: this.fxSc })
  }
}

