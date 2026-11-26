import { PermRow } from '../../common/Api';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Tokens } from '../../common/Tokens';
import { EmptyState } from '../../common/Widgets';

/**
 * 轻量权限档位切换半模态面板（F09 /permission）：
 * 在聊天页内直接切换会话权限档位，无需跳离当前对话流。
 */
@Component
export struct PermPickerSheet {
  @Prop loading: boolean = false;
  @Prop unavailable: boolean = false;
  @Prop presets: PermRow[] = [];
  @Prop current: string = '';
  @Prop savingVal: string = '';
  onPick: (permValue: string) => void = () => {};
  onOpenFullPresets: () => void = () => {};
  onClose: () => void = () => {};
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Column() {
      Row() {
        Text('权限档位')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.ic_close'))
            .width(14)
            .height(14)
            .fillColor(Tokens.dim)
            .objectFit(ImageFit.Contain)
        }
        .width(34)
        .height(34)
        .borderRadius(Tokens.rPill)
        .backgroundColor(Tokens.surface2)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .accessibilityText('关闭')
        .onClick(() => {
          Haptics.tap();
          this.onClose();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 12 })

      if (this.loading) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18).color(Tokens.accent)
          Text('读取权限档位…')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .height(96)
        .justifyContent(FlexAlign.Center)
      } else if (this.unavailable || this.presets.length === 0) {
        EmptyState({
          icon: $r('app.media.ic_gear'),
          title: '当前主机未提供权限档位',
          hint: '请升级电脑端 DSH 或前往完整预设与权限页面查看。',
          action: '打开预设与权限',
          onAction: (): void => {
            this.onClose();
            this.onOpenFullPresets();
          }
        })
      } else {
        Column() {
          ForEach(this.presets, (p: PermRow, idx: number) => {
            Column() {
              if (idx > 0) {
                Divider().color(Tokens.lineSoft).margin({ left: 14 })
              }
              Row() {
                Column() {
                  Text(p.name !== '' ? p.name : p.value)
                    .fontSize(Tokens.fsBodyLg)
                    .fontWeight(this.current === p.value ? FontWeight.Medium : FontWeight.Normal)
                    .fontColor(this.current === p.value ? Tokens.accent : Tokens.fg)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (p.description !== '') {
                    Text(p.description)
                      .fontSize(Tokens.fsCaption)
                      .fontColor(Tokens.dim2)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 2 })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.savingVal === p.value) {
                  LoadingProgress()
                    .width(16)
                    .height(16)
                    .color(Tokens.accent)
                    .margin({ left: 10 })
                } else if (this.current === p.value) {
                  Text('√')
                    .fontSize(16)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Tokens.accent)
                    .margin({ left: 10 })
                }
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .alignItems(VerticalAlign.Center)
              .backgroundColor(this.current === p.value ? Tokens.accentSoft : Color.Transparent)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.99 })
              .onClick(() => {
                if (this.savingVal !== '' || this.current === p.value) {
                  return;
                }
                Haptics.tap();
                this.onPick(p.value);
              })
            }
            .width('100%')
          }, (p: PermRow) => p.value + '_' + (this.current === p.value ? '1' : '0') + '_' +
            (this.savingVal === p.value ? 's' : 'n'))
        }
        .width('100%')
        .backgroundColor(Mat.subCardBg(this.hdsOn))
        .border(Mat.subCardBorder(this.hdsOn))
        .borderRadius(Tokens.rCard)
        .clip(true)

        Row() {
          Blank()
          Text('前往完整预设与权限页面 ›')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.accent)
            .padding({ top: 12, bottom: 4, left: 6, right: 2 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              Haptics.tap();
              this.onClose();
              this.onOpenFullPresets();
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 10, bottom: this.bottomInset + 20 })
    .alignItems(HorizontalAlign.Start)
  }
}
