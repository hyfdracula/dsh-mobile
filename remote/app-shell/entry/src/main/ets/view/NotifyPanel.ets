import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { RowSwitch } from '../common/Widgets';

/**
 * 「通知」页：回合结束提醒、仅后台提醒、系统设置入口、测试通知、清除未读。
 * 通知权限状态与发送动作都在父级，组件只负责显示与转发。
 */
@Component
export struct NotifyPanel {
  @Prop done: boolean = true;
  @Prop bgOnly: boolean = true;
  @Prop allowed: boolean = false;
  onDone: (v: boolean) => void = () => {};
  onBgOnly: (v: boolean) => void = () => {};
  onOpenSettings: () => void = () => {};
  onTest: () => void = () => {};
  onClearUnread: () => void = () => {};

  @State private pop: boolean = false;

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

  build() {
    Column() {
      Column() {
        RowSwitch({
          title: '回合结束提醒',
          hint: '一轮回答跑完时发一条系统通知',
          value: this.done,
          onChanged: (v: boolean) => {
            this.onDone(v);
          }
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        RowSwitch({
          title: '仅在后台提醒',
          hint: '正在看这个 App 时不打扰，退到后台才提醒',
          value: this.bgOnly,
          onChanged: (v: boolean) => {
            this.onBgOnly(v);
          }
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Text(this.allowed ? '重新打开系统通知设置' : '打开系统通知设置')
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
          this.onOpenSettings();
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Text('发一条测试通知')
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
          this.onTest();
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Row() {
            Text('清除未读提醒')
              .fontSize(13)
              .fontColor(Tokens.accent)
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
              .bindPopup(this.pop, {
                builder: this.tip('清掉通知栏里没点开的消息，以及桌面图标上的角标数字。'),
                placement: Placement.Bottom,
                popupColor: Color.Transparent,
                enableArrow: false,
                onStateChange: (e) => {
                  if (!e.isVisible) {
                    this.pop = false;
                  }
                }
              })
              .onClick(() => {
                this.pop = !this.pop;
              })
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
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
          this.onClearUnread();
        })
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
