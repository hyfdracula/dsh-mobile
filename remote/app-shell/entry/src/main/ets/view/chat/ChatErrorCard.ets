import { copyText } from '../../common/Clipboard';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Tokens } from '../../common/Tokens';
import { errCategoryTitle } from './ChatHelpers';

/**
 * 消息流底部原始报错卡与本地 Outbox 断线未发影子恢复条。
 */
@Component
export struct ChatErrorCard {
  @Prop errText: string = '';
  @Prop errCode: string = '';
  @Prop hasRetry: boolean = false;
  onRetry: () => void = () => {};
  onDismiss: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('这一轮出错了 · ' + errCategoryTitle(this.errText))
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.err)
          .layoutWeight(1)
        if (this.errCode !== '') {
          Text(this.errCode)
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .backgroundColor(Tokens.isDark ? '#1FFFFFFF' : '#14000000')
            .borderRadius(Tokens.rXs)
            .maxLines(1)
        }
        Text('×')
          .fontSize(Tokens.fsBodyLg)
          .fontColor(Tokens.dim2)
          .width(28)
          .height(22)
          .textAlign(TextAlign.Center)
          .margin({ left: 2 })
          .onClick(() => {
            this.onDismiss();
          })
      }
      .width('100%')

      Scroll() {
        Text(this.errText)
          .fontSize(Tokens.fsFoot)
          .lineHeight(17)
          .fontColor(Tokens.dim)
          .width('100%')
          .textAlign(TextAlign.Start)
          .copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .constraintSize({ maxHeight: 190 })
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)

      Row({ space: 8 }) {
        if (this.hasRetry) {
          Text('重试')
            .fontSize(Tokens.fsFoot)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accentInk)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor(Tokens.accent)
            .borderRadius(Tokens.rPill)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              Haptics.tap();
              this.onRetry();
            })
        }
        Text('复制报错')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.accent)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            void copyText(this.errText, '已复制报错');
          })
        Text('收起')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(Tokens.rPill)
          .border({ width: 1, color: Tokens.lineSoft })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.onDismiss();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(13)
    .backgroundColor(this.hdsOn
      ? (Tokens.isDark ? '#24FF5C5C' : '#1AFF3B30')
      : (Tokens.isDark ? '#1D1418' : '#FFF3F4'))
    .backdropBlur(this.hdsOn ? 16 : 0)
    .borderRadius(Tokens.rCard)
    .border({ width: 1, color: Tokens.isDark ? '#4DFF5C5C' : '#33FF3B30' })
  }
}

@Component
export struct OutboxRescueCard {
  @Prop count: number = 0;
  @Prop firstText: string = '';
  @Prop busy: boolean = false;
  onResend: () => void = () => {};
  onDismiss: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Column({ space: 6 }) {
      Row() {
        Text('未发出 ' + String(this.count))
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.err)
          .backgroundColor(Tokens.surface3)
          .borderRadius(Tokens.rSm)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        Text(this.firstText !== '' ? this.firstText : '（图片消息）')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: 8 })
        Text(this.busy ? '重发中' : '重发')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.accent)
          .padding({ left: 10, right: 8, top: 2, bottom: 2 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => {
            this.onResend();
          })
        Text('忽略')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim)
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => {
            this.onDismiss();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 10, top: 8, bottom: 8 })
      .backgroundColor(Mat.subCardBg(this.hdsOn))
      .border(Mat.subCardBorder(this.hdsOn))
      .borderRadius(Tokens.rMd)

      Text('这一轮被中断（多半是电脑端重启），这几条还留在手机上，重发会按原顺序再发一遍。')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim)
        .width('100%')
        .padding({ left: 4 })
    }
    .width('100%')
    .margin({ bottom: 8 })
  }
}
