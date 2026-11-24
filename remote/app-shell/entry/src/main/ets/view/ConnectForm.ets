import { Tokens } from '../common/Tokens';

/**
 * 「连接地址」表单：地址 + 访问令牌 + 保存并重连。
 * 两个字段用 @Link 与设置页双向绑定，保存动作仍由页面执行（它要同时写资产库与重连）。
 */
@Component
export struct ConnectForm {
  @Link base: string;
  @Link token: string;
  @Prop saved: string = '';
  onSave: () => void = () => {};

  build() {
    Column() {
      Text('地址')
        .fontSize(12)
        .fontColor(Tokens.dim2)
        .margin({ bottom: 6 })
      TextInput({ text: this.base, placeholder: 'https://your-tunnel.example.com' })
        .height(44)
        .fontSize(13)
        .borderRadius(Tokens.rInput)
        .backgroundColor(Tokens.surface2)
        .onChange((v: string) => {
          this.base = v;
        })
      Text('访问令牌')
        .fontSize(12)
        .fontColor(Tokens.dim2)
        .margin({ top: 12, bottom: 6 })
      TextInput({ text: this.token, placeholder: '访问令牌' })
        .type(InputType.Password)
        .height(44)
        .fontSize(13)
        .borderRadius(Tokens.rInput)
        .backgroundColor(Tokens.surface2)
        .onChange((v: string) => {
          this.token = v;
        })
      Row() {
        Text(this.saved)
          .fontSize(12)
          .fontColor(Tokens.ok)
          .layoutWeight(1)
        Button(this.saved === '已保存' ? '已保存' : '保存并重连')
          .fontSize(13)
          .height(38)
          .padding({ left: 18, right: 18 })
          .backgroundColor(Tokens.accent)
          .fontColor(Tokens.accentInk)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            this.onSave();
          })
      }
      .width('100%')
      .margin({ top: 14 })
      .alignItems(VerticalAlign.Center)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(16)
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rGroup)
    .clip(true)
  }
}
