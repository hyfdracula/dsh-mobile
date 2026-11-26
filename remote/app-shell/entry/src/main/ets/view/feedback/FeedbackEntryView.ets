import { copyText } from '../../common/Clipboard';
import { Haptics } from '../../common/Haptics';
import { Tokens } from '../../common/Tokens';
import { QQ_GROUP } from './FeedbackTypes';

/**
 * 反馈入口视图：提交反馈 / 我的反馈 / QQ 交流群快捷复制。
 */
@Component
export struct FeedbackEntryView {
  onGoSubmit: () => void = () => {};
  onGoMine: () => void = () => {};
  @StorageLink('themeDark') themeDark: boolean = true;

  @Builder
  entryRow(title: string, sub: string, act: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .width('100%')
        if (sub !== '') {
          Text(sub)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .lineHeight(17)
            .width('100%')
            .margin({ top: 3 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(17)
        .fontColor(Tokens.dim2)
    }
    .width('100%')
    .padding({ left: 16, right: 14, top: 14, bottom: 14 })
    .margin({ bottom: 10 })
    .borderRadius(Tokens.rCard)
    .backgroundColor(Tokens.surface)
    .border({ width: 1, color: Tokens.lineSoft })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(act)
  }

  build() {
    Column() {
      Text('遇到问题或有新功能想法都可以在这里直接提交；无需电脑在线也可发送。')
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.dim)
        .lineHeight(19)
        .width('100%')
        .margin({ bottom: 16 })

      this.entryRow('提交反馈', '填写描述并附带截图、录屏或脱敏日志', () => {
        Haptics.tap();
        this.onGoSubmit();
      })
      this.entryRow('我的反馈', '查看本机提交过的工单与处理进展', () => {
        Haptics.tap();
        this.onGoMine();
      })
      if (QQ_GROUP !== '') {
        this.entryRow('交流群 ' + QQ_GROUP, '点此复制群号，进群反馈交流', () => {
          void copyText(QQ_GROUP, '群号已复制');
        })
      }

      Text('隐私说明：提交内容仅开发者可见，不会采集账号、会话正文、访问令牌或本地私人文件。')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .lineHeight(17)
        .width('100%')
        .margin({ top: 14 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
