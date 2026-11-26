import { Api, PluginSettingField, PluginSettingsResp } from '../../common/Api';
import { Tokens } from '../../common/Tokens';
import { EmptyState, RowSwitch } from '../../common/Widgets';
import { Haptics } from '../../common/Haptics';
import { Toast } from '../../common/Toast';
import { GATEWAY_404_HINT, GATEWAY_404_TITLE, isGateway404, shortPluginName } from './ExtrasCommon';

/**
 * 宿主插件动态配置半模态表单（R5）：
 * - 调用 api.pluginSettings(profile, name) 读取标量配置项
 * - boolean 渲染为 RowSwitch，number / string 渲染为 TextInput
 * - 保存调用 api.savePluginSettings(...) 并根据 restartRequired 提示是否需重启电脑端 DSH
 */
@Component
export struct PluginSettingsSheet {
  api: Api = new Api('', '');
  @Prop profile: string = '';
  @Prop pluginName: string = '';
  onClose: () => void = () => {};
  onSaved: (notice: string) => void = () => {};

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private loading: boolean = true;
  @State private saving: boolean = false;
  @State private missing404: boolean = false;
  @State private err: string = '';
  @State private writable: boolean = false;
  @State private restartHint: boolean = false;
  @State private fields: PluginSettingField[] = [];

  aboutToAppear(): void {
    void this.loadSettings();
  }

  private async loadSettings(): Promise<void> {
    if (this.profile === '' || this.pluginName === '') {
      this.loading = false;
      return;
    }
    this.loading = true;
    this.err = '';
    this.missing404 = false;
    try {
      const r: PluginSettingsResp = await this.api.pluginSettings(this.profile, this.pluginName);
      this.writable = r.writable === true;
      this.restartHint = r.restartRequired === true;
      const cloned: PluginSettingField[] = [];
      for (let i = 0; i < r.fields.length; i++) {
        cloned.push({
          key: r.fields[i].key,
          kind: r.fields[i].kind,
          value: r.fields[i].value
        });
      }
      this.fields = cloned;
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      if (isGateway404(msg)) {
        this.missing404 = true;
      } else {
        this.err = msg !== '' ? msg : '读取插件配置失败';
      }
    } finally {
      this.loading = false;
    }
  }

  private updateFieldValue(key: string, nextVal: string): void {
    const updated: PluginSettingField[] = [];
    for (let i = 0; i < this.fields.length; i++) {
      const f: PluginSettingField = this.fields[i];
      if (f.key === key) {
        updated.push({ key: f.key, kind: f.kind, value: nextVal });
      } else {
        updated.push(f);
      }
    }
    this.fields = updated;
  }

  private async submitSave(): Promise<void> {
    if (this.saving || !this.writable) {
      return;
    }
    for (let i = 0; i < this.fields.length; i++) {
      const f: PluginSettingField = this.fields[i];
      if (f.kind === 'number') {
        const trimmed: string = f.value.trim();
        if (trimmed === '' || !Number.isFinite(Number(trimmed))) {
          Toast.err('字段「' + f.key + '」需要填写有效数字');
          return;
        }
      }
    }

    Haptics.tap();
    this.saving = true;
    this.err = '';
    try {
      const r: PluginSettingsResp = await this.api.savePluginSettings(this.profile, this.pluginName, this.fields);
      const shortLabel: string = shortPluginName(this.pluginName);
      const needRestart: boolean = r.restartRequired === true || this.restartHint;
      const msg: string = needRestart
        ? ('已保存「' + shortLabel + '」配置，重启电脑端 DSH 后生效')
        : ('已保存「' + shortLabel + '」配置');
      Toast.ok(msg);
      this.onSaved(msg);
      this.onClose();
    } catch (e) {
      const msg: string = (e as Error).message ?? '保存插件配置失败';
      this.err = msg;
      Toast.err(msg);
    } finally {
      this.saving = false;
    }
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text(shortPluginName(this.pluginName) + ' 配置')
            .fontSize(Tokens.fsTitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('Profile: ' + this.profile)
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('×')
          .fontSize(20)
          .fontColor(Tokens.dim)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.surface2)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            Haptics.tap();
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 10 }) {
          if (this.loading) {
            Row({ space: 8 }) {
              LoadingProgress().width(18).height(18).color(Tokens.accent)
              Text('读取插件配置...')
                .fontSize(Tokens.fsBody)
                .fontColor(Tokens.dim2)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 36, bottom: 36 })
          } else if (this.missing404) {
            EmptyState({
              icon: $r('app.media.ic_gear'),
              title: GATEWAY_404_TITLE,
              hint: GATEWAY_404_HINT
            })
          } else if (this.err !== '' && this.fields.length === 0) {
            EmptyState({
              icon: $r('app.media.ic_gear'),
              title: '无法读取配置',
              hint: this.err,
              action: '重试',
              onAction: () => {
                void this.loadSettings();
              }
            })
          } else if (this.fields.length === 0) {
            EmptyState({
              icon: $r('app.media.ic_gear'),
              title: '没有可编辑的标量配置',
              hint: '该插件暂未声明布尔、数值或字符串类型的配置项'
            })
          } else {
            if (!this.writable) {
              Text('该插件配置当前为只读模式，仅支持查看')
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.intrInk)
                .width('100%')
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .backgroundColor(Tokens.intrBg)
                .borderRadius(Tokens.rSm)
            }

            if (this.err !== '') {
              Text(this.err)
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.err)
                .width('100%')
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .backgroundColor(Tokens.surface2)
                .borderRadius(Tokens.rSm)
            }

            ForEach(this.fields, (f: PluginSettingField) => {
              if (f.kind === 'boolean') {
                Column() {
                  RowSwitch({
                    title: f.key,
                    hint: '布尔开关',
                    value: f.value === 'true',
                    switchEnabled: this.writable,
                    onChanged: (v: boolean) => {
                      if (this.writable) {
                        this.updateFieldValue(f.key, v ? 'true' : 'false');
                      }
                    }
                  })
                }
                .width('100%')
                .backgroundColor(Tokens.surface2)
                .borderRadius(Tokens.rMd)
              } else {
                Column({ space: 6 }) {
                  Row() {
                    Text(f.key)
                      .fontSize(Tokens.fsBody)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Tokens.fg)
                      .layoutWeight(1)
                    Text(f.kind === 'number' ? '数字' : '文本')
                      .fontSize(Tokens.fsCaption)
                      .fontColor(Tokens.dim2)
                      .backgroundColor(Tokens.chip)
                      .borderRadius(Tokens.rPill)
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  TextInput({
                    text: f.value,
                    placeholder: f.kind === 'number' ? '输入数字值' : '输入文本值'
                  })
                    .fontSize(Tokens.fsBody)
                    .fontFamily('monospace')
                    .fontColor(Tokens.fg)
                    .placeholderColor(Tokens.dim2)
                    .backgroundColor(Tokens.surface)
                    .borderRadius(Tokens.rSm)
                    .height(42)
                    .enabled(this.writable)
                    .onChange((v: string) => {
                      this.updateFieldValue(f.key, v);
                    })
                }
                .width('100%')
                .padding(12)
                .backgroundColor(Tokens.surface2)
                .borderRadius(Tokens.rMd)
                .alignItems(HorizontalAlign.Start)
              }
            }, (f: PluginSettingField) => f.key + '|' + f.kind)

            if (this.writable) {
              Row({ space: 10 }) {
                Text('取消')
                  .fontSize(Tokens.fsBodyLg)
                  .fontColor(Tokens.dim)
                  .backgroundColor(Tokens.surface2)
                  .borderRadius(Tokens.rInput)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .layoutWeight(1)
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
                  .onClick(() => {
                    Haptics.tap();
                    this.onClose();
                  })
                Text(this.saving ? '保存中...' : '保存配置')
                  .fontSize(Tokens.fsBodyLg)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Tokens.accentInk)
                  .backgroundColor(Tokens.accent)
                  .borderRadius(Tokens.rInput)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .layoutWeight(1)
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
                  .onClick(() => {
                    void this.submitSave();
                  })
              }
              .width('100%')
              .margin({ top: 6 })
            }
          }
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 4, bottom: this.bottomInset + 18 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: 460 })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .backgroundColor(Color.Transparent)
  }
}
