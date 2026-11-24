import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';

interface ThemeOpt {
  id: string;
  name: string;
}

const THEMES: ThemeOpt[] = [
  { id: 'dark', name: '深色' },
  { id: 'light', name: '浅色' },
  { id: 'auto', name: '跟随系统' }
];

/**
 * 「外观与交互」：主题、触感、沉浸光感、回车发送、正文字号。
 * 显示状态由父级给，变更以回调抛回；提示气泡是组件自己的临时状态。
 */
@Component
export struct AppearancePanel {
  @Prop themeMode: string = 'auto';
  @Prop haptics: boolean = true;
  @Prop hds: boolean = true;
  @Prop enterSend: boolean = true;
  @Prop textScale: number = 1;
  onTheme: (m: string) => void = () => {};
  onHaptics: (v: boolean) => void = () => {};
  onHds: (v: boolean) => void = () => {};
  onEnterSend: (v: boolean) => void = () => {};
  onTextScale: (v: number) => void = () => {};

  @State private popKey: string = '';

  @Builder
  tip(text: string) {
    Text(text)
      .fontSize(12)
      .lineHeight(18)
      .fontColor(Tokens.dim)
      .width(240)
      .padding(12)
      .backgroundColor(Tokens.surface)
      .borderRadius(14)
      .border({ width: 1, color: Tokens.lineSoft })
      .shadow({ radius: 18, color: Tokens.shadow, offsetY: 6 })
  }

  @Builder
  hint(title: string, text: string, key: string, dim: boolean) {
    Row() {
      Text(title)
        .fontSize(13)
        .fontColor(dim ? Tokens.dim : Tokens.fg)
      Text('!')
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.dim2)
        .textAlign(TextAlign.Center)
        .width(15)
        .height(15)
        .borderRadius(10)
        .border({ width: 1, color: Tokens.isDark ? '#59FFFFFF' : '#33000000' })
        .margin({ left: 6 })
        .bindPopup(this.popKey === key, {
          builder: this.tip(text),
          placement: Placement.Bottom,
          popupColor: Color.Transparent,
          enableArrow: false,
          onStateChange: (e) => {
            if (!e.isVisible) {
              this.popKey = '';
            }
          }
        })
        .onClick(() => {
          this.popKey = this.popKey === key ? '' : key;
        })
    }
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      Column() {
        Row() {
          Text('主题')
            .fontSize(13)
            .fontColor(Tokens.dim)
            .layoutWeight(1)
          Row() {
            ForEach(THEMES, (o: ThemeOpt) => {
              Text(o.name)
                .fontSize(12)
                .fontColor(this.themeMode === o.id ? Tokens.accentInk : Tokens.dim)
                .backgroundColor(this.themeMode === o.id ? Tokens.accent : Tokens.surface3)
                .borderRadius(999)
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .margin({ left: 6 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                .onClick(() => {
                  Haptics.tap();
                  this.onTheme(o.id);
                })
            }, (o: ThemeOpt) => o.id)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(VerticalAlign.Center)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        Row() {
          Row() {
            this.hint('触感反馈', '点击、归档、发送时轻轻振一下。', 'haptics', true)
          }
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.haptics })
            .selectedColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onChange((v: boolean) => {
              this.onHaptics(v);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        Row() {
          Row() {
            this.hint('沉浸光感', '系统级玻璃材质：底栏与顶栏跟随内容折射；低端机自动降级。', 'hds', true)
          }
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.hds })
            .selectedColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onChange((v: boolean) => {
              this.onHds(v);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        Row() {
          Row() {
            this.hint('回车发送', '关掉后回车只换行，用右侧按钮发送；适合经常写多行的人。', 'enter', true)
          }
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.enterSend })
            .selectedColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onChange((v: boolean) => {
              this.onEnterSend(v);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        Row() {
          Row() {
            this.hint('正文字号', '只缩放聊天正文，界面控件不跟着变。', 'text', false)
          }
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)
          ForEach([0.92, 1, 1.08], (sc: number) => {
            Text(sc === 0.92 ? '小' : (sc === 1 ? '标准' : '大'))
              .fontSize(12)
              .fontColor(this.textScale === sc ? Tokens.accentInk : Tokens.dim)
              .backgroundColor(this.textScale === sc ? Tokens.accent : Tokens.surface2)
              .borderRadius(Tokens.rPill)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .margin({ left: 6 })
              .onClick(() => {
                Haptics.tap();
                this.onTextScale(sc);
              })
          }, (sc: number) => String(sc))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .margin({ top: 10 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
