import { AskAnswer, AskOption, AskQuestion, PendingAsk } from '../../common/Api';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Motion } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';

/**
 * 模型向用户提问的交互卡片（I4 / K4）：
 * - 支持多题步进与多选；
 * - 渲染 AskOption.description（12vp Tokens.dim2）；
 * - 提供「其他（自由填写回答）」展开输入框，支持随预设选项或单独提交。
 */
@Component
export struct AskQuestionCard {
  @Prop @Watch('onAskChanged') ask: PendingAsk = { callId: '', questions: [], state: '' };
  onSubmit: (callId: string, answers: AskAnswer[]) => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private curIdx: number = 0;
  @State private selMap: Record<string, string[]> = {};
  @State private customMap: Record<string, string> = {};
  @State private customOpenMap: Record<string, boolean> = {};
  @State private submitting: boolean = false;
  private lastCallId: string = '';

  aboutToAppear(): void {
    this.lastCallId = this.ask.callId;
  }

  onAskChanged(): void {
    if (this.ask.callId !== this.lastCallId) {
      this.lastCallId = this.ask.callId;
      this.submitting = false;
    }
  }

  private safeIdx(): number {
    const n: number = this.ask.questions.length;
    if (n <= 1) {
      return 0;
    }
    if (this.curIdx < 0) {
      return 0;
    }
    return this.curIdx >= n ? n - 1 : this.curIdx;
  }

  private goIdx(nextIdx: number): void {
    const n: number = this.ask.questions.length;
    if (n <= 1) {
      this.curIdx = 0;
      return;
    }
    let j: number = nextIdx;
    if (j < 0) {
      j = 0;
    }
    if (j > n - 1) {
      j = n - 1;
    }
    this.curIdx = j;
  }

  private pickedOf(qid: string): string[] {
    const hit: string[] | undefined = this.selMap[qid];
    return hit === undefined ? [] : hit;
  }

  private customOf(qid: string): string {
    const hit: string | undefined = this.customMap[qid];
    return hit === undefined ? '' : hit;
  }

  private isCustomOpen(qid: string): boolean {
    return this.customOpenMap[qid] === true;
  }

  private setPicked(qid: string, list: string[]): void {
    const next: Record<string, string[]> = {};
    const keys: string[] = Object.keys(this.selMap);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.selMap[keys[i]];
    }
    next[qid] = list;
    this.selMap = next;
  }

  private setCustom(qid: string, val: string): void {
    const next: Record<string, string> = {};
    const keys: string[] = Object.keys(this.customMap);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.customMap[keys[i]];
    }
    next[qid] = val;
    this.customMap = next;
  }

  private toggleCustomOpen(qid: string): void {
    const next: Record<string, boolean> = {};
    const keys: string[] = Object.keys(this.customOpenMap);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.customOpenMap[keys[i]];
    }
    next[qid] = !this.isCustomOpen(qid);
    this.getUIContext().animateTo({ duration: Motion.move, curve: Motion.std }, () => {
      this.customOpenMap = next;
    });
  }

  private isAnswered(q: AskQuestion): boolean {
    return this.pickedOf(q.id).length > 0 || this.customOf(q.id).trim() !== '';
  }

  private doneCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.ask.questions.length; i++) {
      if (this.isAnswered(this.ask.questions[i])) {
        n++;
      }
    }
    return n;
  }

  private tapOption(q: AskQuestion, label: string): void {
    Haptics.tap();
    const cur: string[] = this.pickedOf(q.id);
    if (q.multiSelect === true) {
      const next: string[] = cur.indexOf(label) >= 0
        ? cur.filter((x: string) => x !== label)
        : cur.concat([label]);
      this.setPicked(q.id, next);
      return;
    }
    // 单选：若用户已展开自定义输入且已有选中同项，允许再次点击取消该预设项以便纯自定义回答
    if ((this.isCustomOpen(q.id) || this.customOf(q.id).trim() !== '') && cur.indexOf(label) >= 0) {
      this.setPicked(q.id, []);
      return;
    }
    this.setPicked(q.id, [label]);
    if (this.isCustomOpen(q.id) || this.customOf(q.id).trim() !== '') {
      return;
    }
    const idx: number = this.safeIdx();
    if (idx < this.ask.questions.length - 1) {
      this.goIdx(idx + 1);
      return;
    }
    if (this.doneCount() >= this.ask.questions.length) {
      this.fireSubmit();
    }
  }

  private fireSubmit(): void {
    if (this.submitting) {
      return;
    }
    const answers: AskAnswer[] = [];
    for (let i = 0; i < this.ask.questions.length; i++) {
      const one: AskQuestion = this.ask.questions[i];
      const picked: string[] = this.pickedOf(one.id);
      const custom: string = this.customOf(one.id).trim();
      if (picked.length === 0 && custom === '') {
        return;
      }
      const ans: AskAnswer = { id: one.id, selected: picked };
      if (custom !== '') {
        ans.custom = custom;
      }
      answers.push(ans);
    }
    if (answers.length === 0) {
      return;
    }
    this.submitting = true;
    this.onSubmit(this.ask.callId, answers);
  }

  private needFooter(q: AskQuestion): boolean {
    const opts: AskOption[] = q.options === undefined ? [] : q.options;
    return this.ask.questions.length > 1
      || q.multiSelect === true
      || opts.length === 0
      || this.isCustomOpen(q.id)
      || this.customOf(q.id).trim() !== '';
  }

  @Builder
  private questionView(q: AskQuestion) {
    Column({ space: 8 }) {
      Row() {
        Text(q.header === undefined || q.header === '' ? '等待你的操作' : q.header)
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.accent)
          .fontWeight(FontWeight.Medium)
        Blank()
        Text(this.ask.questions.length > 1
          ? ('第 ' + String(this.safeIdx() + 1) + ' / ' + String(this.ask.questions.length) + ' 题')
          : (q.multiSelect === true ? '可多选' : '请选择'))
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
      }
      .width('100%')

      if (this.ask.questions.length > 1) {
        Row() {
          Row()
            .width(String(Math.round(((this.safeIdx() + 1) * 100) / this.ask.questions.length)) + '%')
            .height(2.5)
            .borderRadius(Tokens.rXs)
            .backgroundColor(Tokens.accent)
        }
        .width('100%')
        .height(2.5)
        .borderRadius(Tokens.rXs)
        .backgroundColor(Tokens.surface3)
      }

      if (q.prompt !== undefined && q.prompt !== '') {
        Text(q.prompt)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .lineHeight(19)
          .width('100%')
      }

      if (q.detail !== undefined && q.detail !== '') {
        Text(q.detail)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim)
          .lineHeight(18)
          .width('100%')
      }

      // 预设选项（含 AskOption.description 说明）
      ForEach(q.options === undefined ? [] : q.options, (o: AskOption) => {
        Row() {
          Column({ space: 3 }) {
            Text(o.label)
              .fontSize(Tokens.fsBody)
              .fontColor(this.pickedOf(q.id).indexOf(o.label) >= 0 ? Tokens.fg : Tokens.accent)
              .fontWeight(this.pickedOf(q.id).indexOf(o.label) >= 0 ? FontWeight.Medium : FontWeight.Normal)
            if (o.description !== undefined && o.description.trim() !== '') {
              Text(o.description.trim())
                .fontSize(12)
                .lineHeight(17)
                .fontColor(Tokens.dim2)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(this.pickedOf(q.id).indexOf(o.label) >= 0 ? '已选' : '›')
            .fontSize(Tokens.fsFoot)
            .fontColor(this.pickedOf(q.id).indexOf(o.label) >= 0 ? Tokens.accent : Tokens.dim2)
            .margin({ left: 8 })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius(Tokens.rMd)
        .backgroundColor(this.pickedOf(q.id).indexOf(o.label) >= 0 ? Tokens.surface : Tokens.surface3)
        .border({
          width: this.pickedOf(q.id).indexOf(o.label) >= 0 ? 1 : 0,
          color: Tokens.accent
        })
        .alignItems(VerticalAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          this.tapOption(q, o.label);
        })
      }, (o: AskOption) => this.ask.callId + '_' + q.id + '_' + o.label + '_' +
        (this.pickedOf(q.id).indexOf(o.label) >= 0 ? '1' : '0'))

      // 其他（自由填写回答）开关与展开输入框
      Column({ space: 8 }) {
        Row() {
          Text('其他（自由填写回答）')
            .fontSize(Tokens.fsBody)
            .fontColor(this.customOf(q.id).trim() !== '' ? Tokens.fg : Tokens.dim)
            .fontWeight(this.customOf(q.id).trim() !== '' ? FontWeight.Medium : FontWeight.Normal)
            .layoutWeight(1)
          Text(this.isCustomOpen(q.id) ? '收起' : (this.customOf(q.id).trim() !== '' ? '已填' : '展开'))
            .fontSize(Tokens.fsFoot)
            .fontColor(this.customOf(q.id).trim() !== '' || this.isCustomOpen(q.id) ? Tokens.accent : Tokens.dim2)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .borderRadius(Tokens.rMd)
        .backgroundColor(this.customOf(q.id).trim() !== '' ? Tokens.surface : Tokens.surface3)
        .border({
          width: this.customOf(q.id).trim() !== '' || this.isCustomOpen(q.id) ? 1 : 0,
          color: Tokens.accent
        })
        .alignItems(VerticalAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          Haptics.tap();
          this.toggleCustomOpen(q.id);
        })

        if (this.isCustomOpen(q.id)) {
          TextArea({
            text: this.customOf(q.id),
            placeholder: '输入补充想法或自定义回答…'
          })
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .placeholderColor(Tokens.dim2)
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rMd)
            .border({ width: 1, color: Tokens.line })
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .constraintSize({ minHeight: 42, maxHeight: 96 })
            .width('100%')
            .onChange((v: string) => {
              this.setCustom(q.id, v);
            })
        }
      }
      .width('100%')

      // 底部翻题 / 提交栏
      if (this.needFooter(q)) {
        Row() {
          Text(this.doneCount() < this.ask.questions.length
            ? ('还差 ' + String(this.ask.questions.length - this.doneCount()) + ' 题')
            : '已填好，可提交回答')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .layoutWeight(1)

          if (this.ask.questions.length > 1 && this.safeIdx() > 0) {
            Text('上一题')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.surface3)
              .margin({ right: 8 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                Haptics.tap();
                this.goIdx(this.safeIdx() - 1);
              })
          }

          if (this.ask.questions.length > 1 && this.safeIdx() < this.ask.questions.length - 1) {
            Text('下一题')
              .fontSize(Tokens.fsFoot)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isAnswered(q) ? Tokens.accentInk : Tokens.dim2)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .borderRadius(Tokens.rPill)
              .backgroundColor(this.isAnswered(q) ? Tokens.accent : Tokens.surface3)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                if (!this.isAnswered(q)) {
                  return;
                }
                Haptics.tap();
                this.goIdx(this.safeIdx() + 1);
              })
          } else {
            Text(this.submitting ? '提交中…' : '提交')
              .fontSize(Tokens.fsFoot)
              .fontWeight(FontWeight.Medium)
              .fontColor(!this.submitting && this.doneCount() >= this.ask.questions.length ? Tokens.accentInk : Tokens.dim2)
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .borderRadius(Tokens.rPill)
              .backgroundColor(!this.submitting && this.doneCount() >= this.ask.questions.length ? Tokens.accent : Tokens.surface3)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                if (!this.submitting && this.doneCount() >= this.ask.questions.length) {
                  Haptics.tap();
                  this.fireSubmit();
                }
              })
          }
        }
        .width('100%')
        .margin({ top: 2 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
  }

  build() {
    if (this.ask.questions.length > 0) {
      Column() {
        this.questionView(this.ask.questions[this.safeIdx()])
      }
      .width('100%')
      .padding(12)
      .margin({ bottom: 8 })
      .borderRadius(Tokens.rCard)
      .backgroundColor(Mat.drawerBg(this.hdsOn))
      .backdropBlur(Mat.drawerBlur(this.hdsOn))
      .systemMaterial(Mat.drawer(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .transition(
        TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std })
          .combine(TransitionEffect.translate({ y: 8 }).animation({ duration: Motion.move, curve: Motion.std }))
      )
    }
  }
}
