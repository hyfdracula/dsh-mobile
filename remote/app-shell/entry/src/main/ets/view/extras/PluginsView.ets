import { Api, HostPluginGroup, HostPluginRow } from '../../common/Api';
import { Mat } from '../../common/Mat';
import { Tokens } from '../../common/Tokens';
import { EmptyState } from '../../common/Widgets';
import { Haptics } from '../../common/Haptics';
import { GATEWAY_404_HINT, GATEWAY_404_TITLE, isGateway404, shortPluginName, splitFileLeaf } from './ExtrasCommon';
import { PluginSettingsSheet } from './PluginSettingsSheet';

interface PluginItemVm {
  key: string;
  profile: string;
  name: string;
  shortLabel: string;
  subLabel: string;
  enabled: boolean;
  raw: HostPluginRow;
}

interface PluginGroupVm {
  profile: string;
  countSummary: string;
  items: PluginItemVm[];
}

/**
 * 电脑端宿主插件列表与动态配置入口视图（K4 / R5）：
 * 预计算分组启用统计与副标题文案，避免滚动重绘时重复做字符串切割。
 */
@Component
export struct PluginsView {
  api: Api = new Api('', '');
  @Prop @Watch('onReload') reloadTick: number = 0;
  @Prop topPad: number = 140;

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private busy: boolean = false;
  @State private missing404: boolean = false;
  @State private err: string = '';
  @State private notice: string = '';
  @State private pluginBusy: string = '';
  @State private rawGroups: HostPluginGroup[] = [];
  @State private groupVms: PluginGroupVm[] = [];

  @State private cfgSheetOn: boolean = false;
  @State private cfgProfile: string = '';
  @State private cfgPluginName: string = '';

  aboutToAppear(): void {
    void this.loadPlugins();
  }

  onReload(): void {
    void this.loadPlugins();
  }

  private buildSubLabel(it: HostPluginRow): string {
    if (!it.local) {
      return it.version !== '' ? it.version : '已安装';
    }
    const raw: string = it.version.indexOf('link:') === 0 ? it.version.substring(5) : it.version;
    const tail: string = splitFileLeaf(raw);
    return '本地链接 · ' + (tail === '' ? '工作区' : tail);
  }

  private rebuildVms(groups: HostPluginGroup[]): void {
    const out: PluginGroupVm[] = [];
    for (let i = 0; i < groups.length; i++) {
      const g: HostPluginGroup = groups[i];
      let enabledN: number = 0;
      const items: PluginItemVm[] = [];
      for (let j = 0; j < g.items.length; j++) {
        const it: HostPluginRow = g.items[j];
        if (it.enabled) {
          enabledN++;
        }
        items.push({
          key: g.profile + '/' + it.name + '/' + (it.enabled ? '1' : '0'),
          profile: g.profile,
          name: it.name,
          shortLabel: shortPluginName(it.name),
          subLabel: this.buildSubLabel(it),
          enabled: it.enabled,
          raw: it
        });
      }
      out.push({
        profile: g.profile,
        countSummary: String(enabledN) + ' / ' + String(g.items.length) + ' 已启用',
        items: items
      });
    }
    this.groupVms = out;
  }

  private async loadPlugins(): Promise<void> {
    this.busy = true;
    this.missing404 = false;
    try {
      const groups: HostPluginGroup[] = await this.api.hostPlugins();
      this.rawGroups = groups;
      this.rebuildVms(groups);
      this.err = '';
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      if (isGateway404(msg)) {
        this.missing404 = true;
        this.err = '';
      } else {
        this.err = msg;
      }
    } finally {
      this.busy = false;
    }
  }

  private setPluginEnabledLocal(profile: string, name: string, enabled: boolean): void {
    const next: HostPluginGroup[] = [];
    for (let i = 0; i < this.rawGroups.length; i++) {
      const g: HostPluginGroup = this.rawGroups[i];
      if (g.profile !== profile) {
        next.push(g);
        continue;
      }
      const items: HostPluginRow[] = [];
      for (let j = 0; j < g.items.length; j++) {
        const it: HostPluginRow = g.items[j];
        if (it.name === name) {
          items.push({
            name: it.name,
            version: it.version,
            enabled: enabled,
            local: it.local
          });
        } else {
          items.push(it);
        }
      }
      next.push({ profile: g.profile, items: items });
    }
    this.rawGroups = next;
    this.rebuildVms(next);
  }

  private async togglePlugin(profile: string, row: HostPluginRow, enabled: boolean): Promise<void> {
    if (row.enabled === enabled || this.pluginBusy !== '') {
      return;
    }
    Haptics.tap();
    this.pluginBusy = profile + '/' + row.name;
    try {
      const changed: boolean = await this.api.pluginToggle(profile, row.name, enabled);
      this.setPluginEnabledLocal(profile, row.name, enabled);
      this.err = '';
      const label: string = shortPluginName(row.name);
      this.notice = changed
        ? ('已' + (enabled ? '启用' : '停用') + '「' + label + '」，重启电脑端 DSH 后生效')
        : ('「' + label + '」原本已是' + (enabled ? '启用' : '停用') + '状态');
    } catch (e) {
      this.err = (e as Error).message;
      this.setPluginEnabledLocal(profile, row.name, !enabled);
    } finally {
      this.pluginBusy = '';
    }
  }

  @Builder
  private settingsSheetBuilder() {
    PluginSettingsSheet({
      api: this.api,
      profile: this.cfgProfile,
      pluginName: this.cfgPluginName,
      onClose: () => {
        this.cfgSheetOn = false;
      },
      onSaved: (msg: string) => {
        this.notice = msg;
      }
    })
  }

  build() {
    Stack() {
      Scroll() {
        Column() {
          if (this.notice !== '') {
            Row() {
              Text(this.notice)
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.accent)
                .layoutWeight(1)
              Text('知道了')
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.dim2)
                .padding({ left: 12, top: 2, bottom: 2 })
                .onClick(() => {
                  this.notice = '';
                })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor(Tokens.accentGlass)
            .borderRadius(Tokens.rMd)
            .margin({ bottom: 10 })
          }

          if (this.busy) {
            Row({ space: 8 }) {
              LoadingProgress().width(18).height(18).color(Tokens.accent)
              Text('读取插件清单...')
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.dim2)
            }
            .width('100%')
            .padding({ top: 8, bottom: 12 })
          }

          if (this.err !== '') {
            Text(this.err)
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.err)
              .width('100%')
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .backgroundColor(Tokens.surface)
              .borderRadius(Tokens.rMd)
              .margin({ bottom: 10 })
          }

          if (this.missing404) {
            EmptyState({
              icon: $r('app.media.ic_gear'),
              title: GATEWAY_404_TITLE,
              hint: GATEWAY_404_HINT
            })
          } else if (this.groupVms.length === 0 && !this.busy && this.err === '') {
            EmptyState({
              icon: $r('app.media.ic_gear'),
              title: '没有读到已安装的插件',
              hint: '电脑端宿主配置的插件清单会展示在这里'
            })
          } else {
            ForEach(this.groupVms, (g: PluginGroupVm) => {
              Column() {
                Row() {
                  Text(g.profile)
                    .fontSize(Tokens.fsFoot)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Tokens.dim)
                    .layoutWeight(1)
                  Text(g.countSummary)
                    .fontSize(Tokens.fsCaption)
                    .fontColor(Tokens.dim2)
                }
                .width('100%')
                .padding({ left: 4, right: 4, top: 10, bottom: 8 })

                ForEach(g.items, (it: PluginItemVm) => {
                  Row() {
                    Column() {
                      Text(it.shortLabel)
                        .fontSize(Tokens.fsBody)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Tokens.fg)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(it.subLabel)
                        .fontSize(Tokens.fsCaption)
                        .fontColor(Tokens.dim2)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 3 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    .margin({ right: 10 })

                    Text('配置')
                      .fontSize(Tokens.fsFoot)
                      .fontColor(Tokens.accent)
                      .backgroundColor(Tokens.accentSoft)
                      .borderRadius(Tokens.rPill)
                      .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                      .margin({ right: 10 })
                      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                      .onClick(() => {
                        Haptics.tap();
                        this.cfgProfile = it.profile;
                        this.cfgPluginName = it.name;
                        this.cfgSheetOn = true;
                      })

                    Toggle({ type: ToggleType.Switch, isOn: it.enabled })
                      .selectedColor(this.pluginBusy === it.profile + '/' + it.name ? Tokens.dim2 : Tokens.accent)
                      .enabled(this.pluginBusy === '')
                      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                      .onChange((v: boolean) => {
                        void this.togglePlugin(it.profile, it.raw, v);
                      })
                  }
                  .width('100%')
                  .padding({ left: 14, right: 12, top: 11, bottom: 11 })
                  .margin({ bottom: 8 })
                  .backgroundColor(Mat.cardBg(this.hdsOn))
                  .borderRadius(Tokens.rMd)
                  .border(Mat.cardBorder(this.hdsOn))
                  .shadow(Mat.cardShadow(this.hdsOn))
                  .alignItems(VerticalAlign.Center)
                }, (it: PluginItemVm) => it.key)
              }
              .width('100%')
            }, (g: PluginGroupVm) => g.profile + '|' + g.countSummary)
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: 820 })
        .padding({ left: 16, right: 16, top: this.topPad, bottom: this.bottomInset + 32 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      Row()
        .width(0)
        .height(0)
        .bindSheet($$this.cfgSheetOn, this.settingsSheetBuilder(),
          Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => {
            this.cfgSheetOn = false;
          }))
    }
    .width('100%')
    .height('100%')
  }
}
