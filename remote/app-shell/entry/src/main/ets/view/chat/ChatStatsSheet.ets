import { Message, SessionStats, TokenUsage, TurnInfo } from '../../common/Api';
import { num } from '../../common/Format';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Tokens } from '../../common/Tokens';
import { HintLabel } from '../../common/Widgets';

const EMPTY_TOKENS: TokenUsage = {
  uncachedInputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheWriteTokens: 0
};

const EMPTY_STATS: SessionStats = {
  turns: 0,
  steps: 0,
  toolCalls: 0,
  tokens: EMPTY_TOKENS
};

function cacheHitRate(t: TokenUsage): string {
  const cached: number = t.cacheReadTokens;
  const total: number = t.uncachedInputTokens + cached;
  if (total <= 0) {
    return '--';
  }
  return String(Math.round((cached / total) * 100)) + '%';
}

function finishClockText(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  const now: Date = new Date();
  const pad = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  const hm: string = pad(d.getHours()) + ':' + pad(d.getMinutes());
  const isToday: boolean = d.getFullYear() === now.getFullYear()
    && d.getMonth() === now.getMonth()
    && d.getDate() === now.getDate();
  return isToday ? hm : String(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + hm;
}

/**
 * 上下文与 Token 用量统计半模态面板（F04）：
 * - 彻底去重，将原理说明收进 HintLabel；
 * - 顶部「上下文占用」主卡：30fp Bold 分级预警百分比 + 右侧 used/window + 清晰进度条；
 * - 「Token 构成」卡片：四色多段水平堆叠比例条 + 紧凑图例 + 缓存命中率 + 本会话/最近一轮切换；
 * - 「运行指标」卡片：单排 4 列紧凑指标格（轮次 / 步骤 / 工具 / 消息）；右上角刷新钮带加载态。
 */
@Component
export struct ChatStatsSheet {
  @Prop hasCtx: boolean = false;
  @Prop ctxUsed: number = 0;
  @Prop ctxWindow: number = 0;
  @Prop hasStats: boolean = false;
  @Prop stats: SessionStats = EMPTY_STATS;
  @Prop msgs: Message[] = [];
  @Prop hasMore: boolean = false;
  @Prop curModel: string = '';
  @Prop refreshing: boolean = false;
  onRefresh: () => void = () => {};
  onClose: () => void = () => {};
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private statsScope: string = 'session';

  private ctxPercent(): number {
    if (!this.hasCtx || this.ctxWindow <= 0) {
      return 0;
    }
    const p: number = (this.ctxUsed / this.ctxWindow) * 100;
    return p < 0 ? 0 : (p > 100 ? 100 : p);
  }

  private ctxPctText(): string {
    if (!this.hasCtx) {
      return '--';
    }
    const p: number = this.ctxPercent();
    return (p >= 10 ? String(Math.round(p)) : p.toFixed(1)) + '%';
  }

  private ctxAccentColor(): string {
    if (!this.hasCtx) {
      return Tokens.dim2;
    }
    const p: number = this.ctxPercent();
    if (p >= 90) {
      return Tokens.err;
    }
    if (p >= 75) {
      return Tokens.intrInk;
    }
    return Tokens.accent;
  }

  private ctxPctColor(): string {
    if (!this.hasCtx) {
      return Tokens.dim2;
    }
    const p: number = this.ctxPercent();
    if (p >= 90) {
      return Tokens.err;
    }
    if (p >= 75) {
      return Tokens.intrInk;
    }
    return Tokens.fg;
  }

  private sessionTotalTokens(): number {
    if (!this.hasStats) {
      return 0;
    }
    const t: TokenUsage = this.stats.tokens;
    return t.uncachedInputTokens + t.cacheReadTokens + t.cacheWriteTokens + t.outputTokens;
  }

  private lastTurnIn(): number {
    for (let i = this.msgs.length - 1; i >= 0; i--) {
      const t: TurnInfo | undefined = this.msgs[i].turn;
      if (t !== undefined) {
        return t.tokensIn;
      }
    }
    return 0;
  }

  private lastTurnOut(): number {
    for (let i = this.msgs.length - 1; i >= 0; i--) {
      const t: TurnInfo | undefined = this.msgs[i].turn;
      if (t !== undefined) {
        return t.tokensOut;
      }
    }
    return 0;
  }

  private lastTurnWhen(): string {
    for (let i = this.msgs.length - 1; i >= 0; i--) {
      const t: TurnInfo | undefined = this.msgs[i].turn;
      if (t !== undefined && t.finishedAt !== undefined) {
        return finishClockText(t.finishedAt);
      }
    }
    return '';
  }

  private segWeight(value: number, total: number): number {
    if (value <= 0 || total <= 0) {
      return 0;
    }
    const w: number = Math.round((value * 1000) / total);
    return w < 12 ? 12 : w;
  }

  private sharePct(value: number, total: number): string {
    if (total <= 0) {
      return '--';
    }
    const p: number = (value / total) * 100;
    return p >= 10 ? String(Math.round(p)) + '%' : p.toFixed(1) + '%';
  }

  @Builder
  private scopeTab(label: string, value: string) {
    Text(label)
      .fontSize(Tokens.fsCaption)
      .fontColor(this.statsScope === value ? Tokens.fg : Tokens.dim2)
      .fontWeight(this.statsScope === value ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(Tokens.rPill)
      .backgroundColor(this.statsScope === value ? Tokens.surface : Color.Transparent)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
      .onClick(() => {
        Haptics.tap();
        this.statsScope = value;
      })
  }

  @Builder
  private legendCell(color: string, label: string, value: number, total: number) {
    Row({ space: 6 }) {
      Circle().width(8).height(8).fill(color)
      Column() {
        Text(label)
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .maxLines(1)
        Row({ space: 4 }) {
          Text(num(value))
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontFamily('monospace')
            .fontColor(Tokens.fg)
          Text(this.sharePct(value, total))
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
        }
        .alignItems(VerticalAlign.Bottom)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .layoutWeight(1)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private metricCell(label: string, value: string) {
    Column({ space: 4 }) {
      Text(value)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontFamily('monospace')
        .fontColor(Tokens.fg)
        .maxLines(1)
      Text(label)
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .maxLines(1)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 4, bottom: 4 })
  }

  build() {
    Column() {
      // 标题栏
      Row({ space: 8 }) {
        Text('上下文与统计')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)

        Stack({ alignContent: Alignment.Center }) {
          if (this.refreshing) {
            LoadingProgress().width(16).height(16).color(Tokens.accent)
          } else {
            Text('↻')
              .fontSize(17)
              .fontColor(Tokens.dim)
          }
        }
        .width(34)
        .height(34)
        .borderRadius(Tokens.rPill)
        .backgroundColor(Tokens.surface2)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .accessibilityText('刷新统计')
        .onClick(() => {
          if (this.refreshing) {
            return;
          }
          Haptics.tap();
          this.onRefresh();
        })

        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.ic_close'))
            .width(14)
            .height(14)
            .fillColor(Tokens.dim)
            .objectFit(ImageFit.Contain)
        }
        .width(34)
        .height(34)
        .borderRadius(Tokens.rPill)
        .backgroundColor(Tokens.surface2)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .accessibilityText('关闭')
        .onClick(() => {
          Haptics.tap();
          this.onClose();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ bottom: 14 })

      Scroll() {
        Column({ space: 12 }) {
          // 卡片一：上下文占用主卡
          Column() {
            Row() {
              HintLabel({
                title: '上下文占用',
                tipText: '按当前模型窗口与宿主下一次请求 prompt 估算计算；接近上限时会自动压缩较早历史，也可在 + 号菜单中手动压缩。',
                dim: true
              })
              Blank()
              if (this.curModel !== '') {
                Text(this.curModel)
                  .fontSize(Tokens.fsCaption)
                  .fontColor(Tokens.dim2)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 160 })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Row() {
              Text(this.ctxPctText())
                .fontSize(30)
                .fontWeight(FontWeight.Bold)
                .fontFamily('monospace')
                .fontColor(this.ctxPctColor())
                .layoutWeight(1)

              Column({ space: 2 }) {
                Text(this.hasCtx ? (num(this.ctxUsed) + ' / ' + num(this.ctxWindow)) : '暂无上下文数据')
                  .fontSize(Tokens.fsBody)
                  .fontWeight(FontWeight.Medium)
                  .fontFamily('monospace')
                  .fontColor(Tokens.fg)
                Text(this.hasCtx ? ('剩余 ' + num(Math.max(0, this.ctxWindow - this.ctxUsed))) : '完成一轮后更新')
                  .fontSize(Tokens.fsCaption)
                  .fontColor(Tokens.dim2)
              }
              .alignItems(HorizontalAlign.End)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ top: 10, bottom: 12 })

            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(8)
                .borderRadius(Tokens.rPill)
                .backgroundColor(Tokens.surface3)
              if (this.ctxPercent() > 0) {
                Row()
                  .width(String(this.ctxPercent()) + '%')
                  .height(8)
                  .borderRadius(Tokens.rPill)
                  .backgroundColor(this.ctxAccentColor())
              }
            }
            .width('100%')
            .height(8)
            .clip(true)
          }
          .width('100%')
          .padding(16)
          .borderRadius(Tokens.rCard)
          .backgroundColor(Mat.subCardBg(this.hdsOn))
          .border(Mat.subCardBorder(this.hdsOn))
          .alignItems(HorizontalAlign.Start)

          // 卡片二：Token 构成（四色水平堆叠条 + 紧凑图例 + 缓存命中率）
          Column() {
            Row() {
              HintLabel({
                title: 'Token 构成',
                tipText: '区分输入（未缓存）、缓存命中、缓存写入与模型输出；高缓存命中率可显著降低延迟与费用。',
                dim: true
              })
              Blank()
              Row() {
                this.scopeTab('本会话', 'session')
                this.scopeTab('最近一轮', 'turn')
              }
              .padding(3)
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.surface3)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 14 })

            if (!this.hasStats) {
              Text('完成一轮对话后将展示 Token 构成明细')
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.dim2)
                .padding({ top: 8, bottom: 8 })
            } else if (this.statsScope === 'session') {
              // 四色多段水平堆叠比例条
              Row({ space: 2 }) {
                if (this.stats.tokens.uncachedInputTokens > 0) {
                  Row()
                    .layoutWeight(this.segWeight(this.stats.tokens.uncachedInputTokens, this.sessionTotalTokens()))
                    .height(10)
                    .backgroundColor(Tokens.bucket0)
                }
                if (this.stats.tokens.cacheReadTokens > 0) {
                  Row()
                    .layoutWeight(this.segWeight(this.stats.tokens.cacheReadTokens, this.sessionTotalTokens()))
                    .height(10)
                    .backgroundColor(Tokens.bucket2)
                }
                if (this.stats.tokens.cacheWriteTokens > 0) {
                  Row()
                    .layoutWeight(this.segWeight(this.stats.tokens.cacheWriteTokens, this.sessionTotalTokens()))
                    .height(10)
                    .backgroundColor(Tokens.bucket1)
                }
                if (this.stats.tokens.outputTokens > 0) {
                  Row()
                    .layoutWeight(this.segWeight(this.stats.tokens.outputTokens, this.sessionTotalTokens()))
                    .height(10)
                    .backgroundColor(Tokens.bucket3)
                }
              }
              .width('100%')
              .height(10)
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.surface3)
              .clip(true)

              Column({ space: 10 }) {
                Row({ space: 12 }) {
                  this.legendCell(Tokens.bucket0, '输入', this.stats.tokens.uncachedInputTokens, this.sessionTotalTokens())
                  this.legendCell(Tokens.bucket2, '缓存命中', this.stats.tokens.cacheReadTokens, this.sessionTotalTokens())
                }
                .width('100%')

                Row({ space: 12 }) {
                  this.legendCell(Tokens.bucket1, '缓存写入', this.stats.tokens.cacheWriteTokens, this.sessionTotalTokens())
                  this.legendCell(Tokens.bucket3, '输出', this.stats.tokens.outputTokens, this.sessionTotalTokens())
                }
                .width('100%')
              }
              .width('100%')
              .margin({ top: 14 })

              Divider().color(Tokens.lineSoft).margin({ top: 12, bottom: 10 })

              Row() {
                Text('累计 ' + num(this.sessionTotalTokens()))
                  .fontSize(Tokens.fsFoot)
                  .fontFamily('monospace')
                  .fontColor(Tokens.dim)
                Blank()
                Text('缓存命中率 ' + cacheHitRate(this.stats.tokens))
                  .fontSize(Tokens.fsFoot)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Tokens.ok)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            } else {
              // 最近一轮
              Row({ space: 2 }) {
                if (this.lastTurnIn() > 0) {
                  Row()
                    .layoutWeight(this.segWeight(this.lastTurnIn(), this.lastTurnIn() + this.lastTurnOut()))
                    .height(10)
                    .backgroundColor(Tokens.bucket0)
                }
                if (this.lastTurnOut() > 0) {
                  Row()
                    .layoutWeight(this.segWeight(this.lastTurnOut(), this.lastTurnIn() + this.lastTurnOut()))
                    .height(10)
                    .backgroundColor(Tokens.bucket3)
                }
              }
              .width('100%')
              .height(10)
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.surface3)
              .clip(true)

              Row({ space: 12 }) {
                this.legendCell(Tokens.bucket0, '输入', this.lastTurnIn(), this.lastTurnIn() + this.lastTurnOut())
                this.legendCell(Tokens.bucket3, '输出', this.lastTurnOut(), this.lastTurnIn() + this.lastTurnOut())
              }
              .width('100%')
              .margin({ top: 14 })

              Divider().color(Tokens.lineSoft).margin({ top: 12, bottom: 10 })

              Row() {
                Text('本轮合计 ' + num(this.lastTurnIn() + this.lastTurnOut()))
                  .fontSize(Tokens.fsFoot)
                  .fontFamily('monospace')
                  .fontColor(Tokens.dim)
                Blank()
                if (this.lastTurnWhen() !== '') {
                  Text('完成于 ' + this.lastTurnWhen())
                    .fontSize(Tokens.fsCaption)
                    .fontColor(Tokens.dim2)
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
          }
          .width('100%')
          .padding(16)
          .borderRadius(Tokens.rCard)
          .backgroundColor(Mat.subCardBg(this.hdsOn))
          .border(Mat.subCardBorder(this.hdsOn))
          .alignItems(HorizontalAlign.Start)

          // 卡片三：运行指标（单排 4 列紧凑指标格）
          Column() {
            Text('运行指标')
              .fontSize(Tokens.fsFoot)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.dim)
              .margin({ left: 4, bottom: 10 })

            Row() {
              this.metricCell('轮次', this.hasStats ? String(this.stats.turns) : '--')
              Row().width(0.5).height(28).backgroundColor(Tokens.line)
              this.metricCell('步骤', this.hasStats ? String(this.stats.steps) : '--')
              Row().width(0.5).height(28).backgroundColor(Tokens.line)
              this.metricCell('工具', this.hasStats ? String(this.stats.toolCalls) : '--')
              Row().width(0.5).height(28).backgroundColor(Tokens.line)
              this.metricCell('消息', String(this.msgs.length) + (this.hasMore ? '+' : ''))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 14, bottom: 14 })
          .borderRadius(Tokens.rCard)
          .backgroundColor(Mat.subCardBg(this.hdsOn))
          .border(Mat.subCardBorder(this.hdsOn))
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ bottom: this.bottomInset + 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 10, bottom: 8 })
    .backgroundColor(Color.Transparent)
  }
}
