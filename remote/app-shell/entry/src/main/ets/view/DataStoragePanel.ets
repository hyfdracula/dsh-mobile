import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';

/**
 * 「数据与存储」：存储空间入口 + 应用数据（草稿/待发送/阅读标记）+ 数据说明。
 * 计数与清理动作由父级提供；这里只负责画与转发。
 */
@Component
export struct DataStoragePanel {
  @Prop draftN: number = 0;
  @Prop outN: number = 0;
  @Prop markN: number = 0;
  onStorage: () => void = () => {};
  onClear: (what: string) => void = () => {};

  @Builder
  dataRow(label: string, n: number, what: string) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor(Tokens.fg)
        .layoutWeight(1)
      Text(String(n) + ' 条')
        .fontSize(12)
        .fontColor(Tokens.dim2)
      if (n > 0) {
        Text('清空')
          .fontSize(12)
          .fontColor(Tokens.err)
          .padding({ left: 10, right: 4, top: 4, bottom: 4 })
          .margin({ left: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            Haptics.tap();
            this.onClear(what);
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  note(k: string, v: string, mono: boolean) {
    Row() {
      Text(k)
        .fontSize(13)
        .fontColor(Tokens.dim)
        .width(88)
      Text(v)
        .fontSize(13)
        .fontColor(Tokens.fg)
        .fontFamily(mono ? 'monospace' : 'HarmonyOS Sans')
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      Column() {
        Row() {
          Column() {
            Text('存储空间')
              .fontSize(15)
              .fontColor(Tokens.fg)
            Text('缓存占用、分类明细、一键清理')
              .fontSize(12)
              .fontColor(Tokens.dim2)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('›')
            .fontSize(17)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          Haptics.tap();
          this.onStorage();
        })
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .margin({ top: 10 })

      Text('应用数据')
        .fontSize(11)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.6)
        .margin({ left: 6, top: 18, bottom: 8 })
      Column() {
        this.dataRow('草稿', this.draftN, 'draft')
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.dataRow('待发送（重启兜底）', this.outN, 'outbox')
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.dataRow('阅读标记', this.markN, 'marks')
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)

      Text('数据说明')
        .fontSize(11)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.6)
        .margin({ left: 6, top: 18, bottom: 8 })
      Column() {
        this.note('本地设置', '服务器地址 · 令牌 · 主题', false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.note('消息', '不落地，每次从电脑读取', false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.note('缓存', '可按分类清理，不影响电脑', false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.note('上传文件', '保存在电脑 .dsh/mobile-uploads', false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.note('归档', '与桌面控制台共享同一份数据', false)
      }
      .width('100%')
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rGroup)
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
