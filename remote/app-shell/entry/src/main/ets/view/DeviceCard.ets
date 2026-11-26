import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { Tokens } from '../common/Tokens';

/**
 * 「这台电脑」卡片：名称 / 地址 / 插件版本 / 会话数 + 重连 + 移除。
 */
@Component
export struct DeviceCard {
  @Prop name: string = '';
  @Prop base: string = '';
  @Prop pluginVersion: string = '';
  @Prop sessions: number = -1;
  onReconnect: () => void = () => {};
  onRemove: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @Builder
  devRow(label: string, value: string, mono: boolean, copyable: boolean) {
    Row() {
      Text(label)
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.dim)
        .width(84)
      Text(value)
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .fontFamily(mono ? 'monospace' : 'sans-serif')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
      if (copyable && this.base !== '') {
        Image($r('app.media.ic_copy'))
          .width(14)
          .height(14)
          .fillColor(Tokens.dim2)
          .objectFit(ImageFit.Contain)
          .margin({ left: 6 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (copyable && this.base !== '') {
        void copyText(this.base, '已复制当前地址');
      }
    })
  }

  build() {
    Column() {
      Text('这台电脑')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .width('100%')
        .margin({ left: 6, top: 18, bottom: 8 })

      Column() {
        this.devRow('名称', this.name !== '' ? this.name : '-', false, false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.devRow('地址', this.base !== '' ? this.base : '-', true, true)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.devRow('连接插件', this.pluginVersion !== '' ? this.pluginVersion : '-', false, false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.devRow('会话', this.sessions >= 0 ? (String(this.sessions) + ' 个') : '-', false, false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Text('重新连接')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.accent)
            .layoutWeight(1)
          Text('›')
            .fontSize(17)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(VerticalAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          Haptics.tap();
          this.onReconnect();
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Text('移除此电脑')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.err)
            .layoutWeight(1)
          Text('›')
            .fontSize(17)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(VerticalAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          Haptics.tap();
          this.onRemove();
        })
      }
      .width('100%')
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
