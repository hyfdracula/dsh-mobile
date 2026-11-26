import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Tokens } from '../../common/Tokens';

const FEEDBACK_CATS: string[] = ['问题报错', '功能建议', '体验优化', '其他'];

/**
 * 会话内轻量反馈表单半模态（F09 /feedback）：
 * 选择分类并填写内容后通过 /feedback 指令直接记录到电脑端当前会话。
 */
@Component
export struct FeedbackQuickSheet {
  @Prop busy: boolean = false;
  @Prop kbH: number = 0;
  onSubmit: (category: string, content: string) => Promise<boolean> = async () => false;
  onClose: () => void = () => {};
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private selectedCat: string = '问题报错';
  @State private draft: string = '';
  @State private submitting: boolean = false;

  build() {
    Column() {
      Row() {
        Text('会话反馈')
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
      .margin({ bottom: 10 })

      Text('反馈内容会记录到电脑端当前会话中，方便后续复盘与定位问题。')
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim2)
        .lineHeight(18)
        .width('100%')
        .margin({ bottom: 12 })

      Row({ space: 8 }) {
        ForEach(FEEDBACK_CATS, (cat: string) => {
          Text(cat)
            .fontSize(Tokens.fsFoot)
            .fontWeight(this.selectedCat === cat ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.selectedCat === cat ? Tokens.accentInk : Tokens.dim)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(Tokens.rPill)
            .backgroundColor(this.selectedCat === cat ? Tokens.accent : Tokens.surface2)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              this.selectedCat = cat;
            })
        }, (cat: string) => cat + '_' + (this.selectedCat === cat ? '1' : '0'))
      }
      .width('100%')
      .margin({ bottom: 12 })

      TextArea({ text: this.draft, placeholder: '写下你的反馈或现象描述…' })
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .placeholderColor(Tokens.dim2)
        .backgroundColor(Mat.subCardBg(this.hdsOn))
        .borderRadius(Tokens.rMd)
        .border(Mat.subCardBorder(this.hdsOn))
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .constraintSize({ minHeight: 88, maxHeight: 148 })
        .width('100%')
        .onChange((v: string) => {
          this.draft = v;
        })

      Row({ space: 10 }) {
        Blank()
        Text('取消')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.dim)
          .padding({ left: 18, right: 18, top: 10, bottom: 10 })
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.surface2)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            Haptics.tap();
            this.onClose();
          })
        Text(this.busy || this.submitting ? '提交中…' : '提交反馈')
          .fontSize(Tokens.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.draft.trim() === '' || this.busy || this.submitting ? Tokens.dim2 : Tokens.accentInk)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .borderRadius(Tokens.rPill)
          .backgroundColor(this.draft.trim() === '' || this.busy || this.submitting ? Tokens.surface2 : Tokens.accent)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            const text: string = this.draft.trim();
            if (text === '' || this.busy || this.submitting) {
              return;
            }
            Haptics.tap();
            this.submitting = true;
            this.onSubmit(this.selectedCat, text).then((ok: boolean) => {
              if (ok) {
                this.draft = '';
              }
            }).finally(() => {
              this.submitting = false;
            });
          })
      }
      .width('100%')
      .margin({ top: 14 })
    }
    .width('100%')
    .padding({
      left: 20,
      right: 20,
      top: 10,
      bottom: this.kbH > 0 ? this.kbH + 16 : this.bottomInset + 20
    })
    .alignItems(HorizontalAlign.Start)
  }
}
