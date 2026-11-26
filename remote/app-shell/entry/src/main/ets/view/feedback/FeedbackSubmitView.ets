import { Api } from '../../common/Api';
import { copyText } from '../../common/Clipboard';
import { envLine, FEEDBACK_KINDS, FeedbackKind, setNotifyPref } from '../../common/Feedback';
import { Haptics } from '../../common/Haptics';
import { LinkLog } from '../../common/LinkLog';
import { Net } from '../../common/Net';
import { Tokens } from '../../common/Tokens';
import { RowSwitch } from '../../common/Widgets';
import { PendingAttachment } from './FeedbackTypes';

/**
 * 提交反馈表单视图：
 * 分类选择、描述输入、附件管理、环境与脱敏诊断一键复制、进度通知与联系方式。
 */
@Component
export struct FeedbackSubmitView {
  @Link kind: string;
  @Link text: string;
  @Link contact: string;
  @Link notifyOn: boolean;
  @Prop pend: PendingAttachment[] = [];
  @Prop busy: boolean = false;
  @Prop err: string = '';

  onAddShot: () => void = () => {};
  onAddLog: () => void = () => {};
  onAddVideo: () => void = () => {};
  onDropPending: (idx: number) => void = () => {};
  onBottomFieldFocus: () => void = () => {};
  onSubmit: () => void = () => {};

  @StorageLink('themeDark') themeDark: boolean = true;

  private countOf(targetKind: string): number {
    let n: number = 0;
    for (let i = 0; i < this.pend.length; i++) {
      if (this.pend[i].spec.kind === targetKind) {
        n++;
      }
    }
    return n;
  }

  private copyDiagnostics(): void {
    const parts: string[] = [];
    parts.push(envLine());
    parts.push('网络：' + (Net.isOnline() ? '在线' : '离线'));
    const errs: string[] = Api.recentErrors();
    if (errs.length === 0) {
      parts.push('最近错误：无');
    } else {
      parts.push('最近错误：');
      for (let i = 0; i < errs.length; i++) {
        parts.push('  ' + errs[i]);
      }
    }
    const logs: string[] = LinkLog.recent(10);
    if (logs.length > 0) {
      parts.push('最近链路记录：');
      for (let i = 0; i < logs.length; i++) {
        parts.push('  ' + logs[i]);
      }
    }
    void copyText(parts.join('\n'), '诊断信息已复制');
  }

  @Builder
  attachBtn(label: string, kindKey: string, act: () => void) {
    Row() {
      Text('+')
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.accent)
      Text(label)
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.fg)
        .margin({ left: 4 })
      if (this.countOf(kindKey) > 0) {
        Text(String(this.countOf(kindKey)))
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.accentInk)
          .backgroundColor(Tokens.accent)
          .borderRadius(Tokens.rPill)
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .margin({ left: 5 })
      }
    }
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .margin({ right: 8, bottom: 6 })
    .borderRadius(Tokens.rPill)
    .backgroundColor(Tokens.surface)
    .border({ width: 1, color: Tokens.lineSoft })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .onClick(() => {
      Haptics.tap();
      act();
    })
  }

  build() {
    Column() {
      Text('反馈类型')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .width('100%')
        .margin({ left: 4, bottom: 8 })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(FEEDBACK_KINDS, (k: FeedbackKind) => {
          Text(k.name)
            .fontSize(Tokens.fsBody)
            .fontColor(this.kind === k.id ? Tokens.accentInk : Tokens.dim)
            .backgroundColor(this.kind === k.id ? Tokens.accent : Tokens.surface2)
            .borderRadius(Tokens.rPill)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .margin({ right: 8, bottom: 8 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              this.kind = k.id;
            })
        }, (k: FeedbackKind) => k.id)
      }
      .width('100%')

      TextArea({
        placeholder: '请描述发生了什么：在哪一步、看到什么提示、期待什么结果。第一行会自动作为工单标题。',
        text: this.text
      })
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .placeholderColor(Tokens.dim2)
        .lineHeight(21)
        .padding(12)
        .backgroundColor(Tokens.surface)
        .borderRadius(Tokens.rCard)
        .border({ width: 1, color: Tokens.lineSoft })
        .constraintSize({ minHeight: 136, maxHeight: 240 })
        .barState(BarState.Auto)
        .margin({ top: 6 })
        .onChange((v: string) => {
          this.text = v;
        })

      Row() {
        Blank()
        Text(String(this.text.length) + ' / 10000')
          .fontSize(Tokens.fsCaption)
          .fontColor(this.text.length > 10000 ? Tokens.err : Tokens.dim2)
      }
      .width('100%')
      .margin({ top: 4, bottom: 14 })

      Text('附件（可选）')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .width('100%')
        .margin({ left: 4, bottom: 8 })

      Flex({ wrap: FlexWrap.Wrap }) {
        this.attachBtn('添加截图', 'screenshot', () => {
          this.onAddShot();
        })
        this.attachBtn('日志与样本', 'log', () => {
          this.onAddLog();
        })
        this.attachBtn('录屏', 'video', () => {
          this.onAddVideo();
        })
      }
      .width('100%')

      if (this.pend.length > 0) {
        Column() {
          ForEach(this.pend, (p: PendingAttachment, i: number) => {
            Row() {
              Text(p.spec.label)
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.accentInk)
                .backgroundColor(Tokens.accent)
                .borderRadius(Tokens.rPill)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              Text(p.name)
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.fg)
                .margin({ left: 8 })
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('×')
                .fontSize(16)
                .fontColor(Tokens.dim2)
                .padding({ left: 8, right: 4, top: 2, bottom: 2 })
                .onClick(() => {
                  this.onDropPending(i);
                })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .alignItems(VerticalAlign.Center)
          }, (p: PendingAttachment, i: number) => p.spec.kind + '-' + String(i) + '-' + p.name)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .margin({ top: 6 })
        .backgroundColor(Tokens.surface)
        .borderRadius(Tokens.rMd)
        .border({ width: 1, color: Tokens.lineSoft })
      }

      Column() {
        Row() {
          Text('运行环境')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.fg)
          Blank()
          Text('随工单自动附带')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(envLine())
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim)
          .lineHeight(16)
          .width('100%')
          .margin({ top: 6 })

        Text('不含账号、对话正文、访问令牌与本地私人文件。')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .width('100%')
          .margin({ top: 3 })

        Text('复制诊断信息')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.accent)
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .margin({ top: 9 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
          .onClick(() => {
            this.copyDiagnostics();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .margin({ top: 14 })
      .borderRadius(Tokens.rCard)
      .backgroundColor(Tokens.surface)
      .border({ width: 1, color: Tokens.lineSoft })

      Column() {
        RowSwitch({
          title: '工单有新动态时通知我',
          hint: '开发者回复或工单状态更新时发送提醒',
          value: this.notifyOn,
          onChanged: (on: boolean) => {
            this.notifyOn = on;
            setNotifyPref(on);
          }
        })
      }
      .width('100%')
      .margin({ top: 10 })
      .borderRadius(Tokens.rCard)
      .backgroundColor(Tokens.surface)
      .border({ width: 1, color: Tokens.lineSoft })
      .clip(true)

      Column() {
        Row() {
          Text('联系方式')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.fg)
          Text('选填')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rPill)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .margin({ left: 6 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        TextInput({ placeholder: '邮箱或微信号（选填），方便补充复现信息时联系你', text: this.contact })
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .height(42)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rInput)
          .margin({ top: 8 })
          .onEditChange((editing: boolean) => {
            if (editing) {
              this.onBottomFieldFocus();
            }
          })
          .onChange((v: string) => {
            this.contact = v;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .margin({ top: 10 })
      .borderRadius(Tokens.rCard)
      .backgroundColor(Tokens.surface)
      .border({ width: 1, color: Tokens.lineSoft })

      if (this.err !== '') {
        Text(this.err)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.err)
          .lineHeight(18)
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding(12)
          .margin({ top: 12 })
          .backgroundColor(Tokens.intrBg)
          .border({ width: 1, color: Tokens.err })
          .borderRadius(Tokens.rMd)
      }

      Text(this.busy ? '正在提交…' : '提交反馈')
        .fontSize(Tokens.fsBodyLg)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.busy ? Tokens.dim : Tokens.accentInk)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(48)
        .borderRadius(Tokens.rPill)
        .backgroundColor(this.busy ? Tokens.surface3 : Tokens.accentStrong)
        .margin({ top: 16 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          if (!this.busy) {
            this.onSubmit();
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
