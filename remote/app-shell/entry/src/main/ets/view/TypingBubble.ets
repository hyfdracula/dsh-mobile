import { Tokens } from '../common/Tokens';

/**
 * 「正在回复」的三点气泡。
 *
 * 从 ChatPage 里抽出来：它只依赖一个当前高亮的点下标，没理由让聊天页多背 30 行；
 * 抽成组件后 ChatPage 只负责每 320ms 推进 active。
 */
@Component
export struct TypingBubble {
  /** 当前不透明的那颗点（0/1/2），由父级定时推进。 */
  @Prop active: number = 0;

  build() {
    Column() {
      Row() {
        Image($r('app.media.app_icon'))
          .width(20)
          .height(20)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
      }
      .width('100%')
      .margin({ bottom: 6 })

      Row({ space: 5 }) {
        ForEach([0, 1, 2], (i: number) => {
          Circle()
            .width(6)
            .height(6)
            .fill(Tokens.accent)
            .opacity(this.active === i ? 1 : 0.28)
        }, (i: number) => 'dot' + i)
      }
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .backgroundColor(Tokens.surface)
      .borderRadius(20)
      .border({ width: 1, color: Tokens.lineSoft })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 20 })
  }
}
