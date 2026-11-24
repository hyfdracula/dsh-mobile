import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';

/**
 * 「这台电脑」卡片：名称 / 地址 / 插件版本 / 会话数 + 重连 + 移除。
 * 从 SettingsPage 抽出来，只收显示值与两个回调；确认弹窗仍留在设置页（它要关二级栈）。
 */
@Component
export struct DeviceCard {
  name: string = '';
  base: string = '';
  pluginVersion: string = '';
  sessions: number = -1;
  onReconnect: () => void = () => {};
  onRemove: () => void = () => {};

  @Builder
  devRow(label: string, value: string, mono: boolean) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(Tokens.dim)
        .width(84)
      Text(value)
        .fontSize(13)
        .fontColor(Tokens.fg)
        .fontFamily(mono ? 'monospace' : 'sans-serif')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      Text('这台电脑')
        .fontSize(11)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.6)
        .width('100%')
        .margin({ left: 6, top: 18, bottom: 8 })

      Column() {
        this.devRow('名称', this.name !== '' ? this.name : '—', false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.devRow('地址', this.base, true)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.devRow('连接插件', this.pluginVersion !== '' ? this.pluginVersion : '—', false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.devRow('会话', this.sessions >= 0 ? (String(this.sessions) + ' 个') : '—', false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Text('重新连接')
            .fontSize(13)
            .fontColor(Tokens.accent)
            .layoutWeight(1)
          Text('›')
            .fontSize(17)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 15, bottom: 15 })
        .alignItems(VerticalAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          Haptics.tap();
          this.onReconnect();
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Text('移除此电脑')
            .fontSize(13)
            .fontColor(Tokens.err)
            .layoutWeight(1)
          Text('›')
            .fontSize(17)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 15, bottom: 15 })
        .alignItems(VerticalAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          Haptics.tap();
          this.onRemove();
        })
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
