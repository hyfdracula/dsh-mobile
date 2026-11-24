import { Api, PermRow, PresetRow } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { ChatParam } from '../common/Types';
import { PageHeader } from '../common/Chrome';

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

  /** 一行预设/权限：选中的那行用蓝色描边+浅蓝底+实心勾，必须一眼看得出。 */
  @Builder
  row(title: string, sub: string, active: boolean, onTap: () => void) {
    Row() {
      // 左侧圆点：选中是实心蓝底白勾，未选是空心圈
      Stack() {
        if (active) {
          Circle()
            .width(20)
            .height(20)
            .fill(Tokens.accentStrong)
          Text('√')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
        } else {
          Circle()
            .width(20)
            .height(20)
            .fill(Color.Transparent)
            .stroke(Tokens.line)
            .strokeWidth(1.5)
        }
      }
      .width(20)
      .height(20)
      .margin({ right: 12 })

      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(active ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(active ? Tokens.accent : Tokens.fg)
        if (sub !== '') {
          Text(sub)
            .fontSize(12)
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
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .borderRadius(999)
          .backgroundColor(Tokens.accentStrong)
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: 12, right: 12 })
    .borderRadius(14)
    .backgroundColor(active ? Tokens.accentSoft : Tokens.surface)
    .border({ width: active ? 1.5 : 1, color: active ? Tokens.accent : Tokens.lineSoft })
    .margin({ bottom: 8 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .onClick(onTap)
  }

  build() {
    NavDestination() {
      Column() {
        PageHeader({
          title: '预设与权限',
          subtitle: this.param.title !== '' ? this.param.title : '当前会话',
          rightKind: 'label',
          rightLabel: '刷新',
          onBack: () => {
            this.stack.pop();
          },
          onRight: () => {
            this.load();
          }
        })
        .padding({ left: 16, right: 16 })

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
                  .fontSize(13)
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
                  .fontSize(13)
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
  }
}

