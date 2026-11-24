import { Tokens } from './Tokens';

/**
 * 设置里最常见的「标题 + 说明 + 开关」一行。
 * 以前每个页面各写一份：字号、间距、副标题颜色都在漂；现在只从这里取。
 */
@Component
export struct RowSwitch {
  title: string = '';
  hint: string = '';
  @Prop value: boolean = false;
  onChanged: (v: boolean) => void = () => {};

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(Tokens.fsBodyLg)
          .fontColor(Tokens.fg)
          .width('100%')
        if (this.hint !== '') {
          Text(this.hint)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .maxLines(2)
            .width('100%')
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .selectedColor(Tokens.accent)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onChange((v: boolean) => {
          this.onChanged(v);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }
}

/**
 * 统一空态：图标 + 一句标题 + 可选说明 + 可选动作。
 * 以前每个页面手写一段，字号、间距、是否居中都不一致。
 */
@Component
export struct EmptyState {
  icon: Resource = $r('app.media.ic_chat');
  title: string = '';
  hint: string = '';
  action: string = '';
  onAction: () => void = () => {};

  build() {
    Column() {
      Image(this.icon)
        .width(44)
        .height(44)
        .fillColor(Tokens.dim2)
        .objectFit(ImageFit.Contain)
      Text(this.title)
        .fontSize(Tokens.fsBodyLg)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ top: 12 })
        .textAlign(TextAlign.Center)
      if (this.hint !== '') {
        Text(this.hint)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .lineHeight(18)
          .margin({ top: 6 })
          .textAlign(TextAlign.Center)
      }
      if (this.action !== '') {
        Text(this.action)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.accent)
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .margin({ top: 14 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 72, bottom: 40 })
    .alignItems(HorizontalAlign.Center)
  }
}
