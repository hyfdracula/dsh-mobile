import { Haptics } from '../common/Haptics';
import { legalBodyOf, LegalDocKind, legalTitleOf } from '../common/LegalDocs';
import { Mat } from '../common/Mat';
import { Tokens } from '../common/Tokens';
import { SheetHeader } from '../common/Widgets';

/**
 * 合规文档阅读半屏（支持隐私政策 / 用户协议 / 开源组件许可声明）。
 */
@Component
export struct LegalSheet {
  @Prop kind: LegalDocKind = 'privacy';
  onClose: () => void = () => {};

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('wideScreen') wideScreen: boolean = false;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor(Tokens.scrim)
        .onClick(() => {
          Haptics.tap();
          this.onClose();
        })

      Column() {
        Column() {
          SheetHeader({
            title: legalTitleOf(this.kind),
            onClose: () => {
              this.onClose();
            }
          })

          Scroll() {
            Text(legalBodyOf(this.kind))
              .fontSize(Tokens.fsBody)
              .fontColor(Tokens.fg)
              .lineHeight(22)
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
          .width('100%')
          .constraintSize({ maxHeight: '62%' })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .margin({ top: 10 })

          Row() {
            Text('关闭')
              .fontSize(Tokens.fsBodyLg)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.accentInk)
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding({ top: 12, bottom: 12 })
              .backgroundColor(Tokens.accent)
              .borderRadius(Tokens.rInput)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
              .onClick(() => {
                Haptics.tap();
                this.onClose();
              })
          }
          .width('100%')
          .margin({ top: 14 })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.wideScreen ? 560 : 520 })
        .padding({ left: 18, right: 18, top: 14, bottom: this.bottomInset + 16 })
        .backgroundColor(Mat.popupBg(this.hdsOn))
        .backdropBlur(Mat.floatBlur(this.hdsOn))
        .systemMaterial(Mat.overlay(this.hdsOn))
        .borderRadius({ topLeft: Tokens.rXl, topRight: Tokens.rXl })
        .border({
          width: { top: 1, left: 1, right: 1 },
          color: this.hdsOn ? Mat.floatBorderColor(true) : Tokens.line
        })
        .shadow(Mat.cardShadow(this.hdsOn))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }
}
