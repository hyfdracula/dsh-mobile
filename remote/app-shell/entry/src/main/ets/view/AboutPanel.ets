import { Tokens } from '../common/Tokens';

/** 关于页的一行「键 — 值」。 */
export interface AboutRow {
  k: string;
  v: string;
  mono: boolean;
}

/**
 * 「关于与支持」：版本/插件/端口/数据四行 + 反馈与许可入口。
 * 只收展示值，跳转交给父级（要操作二级栈）。
 */
@Component
export struct AboutPanel {
  rows: AboutRow[] = [];
  onFeedback: () => void = () => {};
  onLicense: () => void = () => {};

  build() {
    Column() {
      Column() {
        ForEach(this.rows, (r: AboutRow, i: number) => {
          Row() {
            Text(r.k)
              .fontSize(13)
              .fontColor(Tokens.dim)
              .width(88)
            Text(r.v)
              .fontSize(13)
              .fontColor(Tokens.fg)
              .fontFamily(r.mono ? 'monospace' : 'HarmonyOS Sans')
              .layoutWeight(1)
              .textAlign(TextAlign.End)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .alignItems(VerticalAlign.Center)
          if (i < this.rows.length - 1) {
            Divider().color(Tokens.lineSoft).margin({ left: 16 })
          }
        }, (r: AboutRow) => r.k)
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .margin({ top: 10 })

      Column() {
        Row() {
          Text('反馈与支持')
            .fontSize(15)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
          Text('›')
            .fontSize(17)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .onClick(() => {
          this.onFeedback();
        })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        Row() {
          Text('开源许可')
            .fontSize(15)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
          Text('›')
            .fontSize(17)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .onClick(() => {
          this.onLicense();
        })
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .margin({ top: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
