import { MdBlock, MdSeg, parseInline, parseMd } from '../common/Md';
import { Tokens } from '../common/Tokens';

/**
 * 消息正文渲染：用户气泡走行内富文本，助手气泡按块渲染（标题/列表/引用/代码/表格/公式）。
 *
 * 从 ChatPage 抽出来：这些块只依赖字号与主题，不依赖聊天页状态；
 * 解析结果（blocks）仍由聊天页缓存后传进来，避免每条消息重复 parse。
 */
@Component
export struct MdBody {
  /** true 时按用户气泡渲染：白字、整段一个 Text、保留换行。 */
  user: boolean = false;
  /** 用户气泡的原文。 */
  userText: string = '';
  /** 助手气泡的已解析块。 */
  blocks: MdBlock[] = [];
  @StorageLink('textScale') textScale: number = 1;

  @Builder
  mdText(segs: MdSeg[], size: number, lineH: number) {
    Text() {
      ForEach(segs, (s: MdSeg, i: number) => {
        Span(s.t)
          .fontWeight(s.b ? FontWeight.Bold : FontWeight.Normal)
          .fontFamily(s.c ? 'monospace' : 'HarmonyOS Sans')
          .fontColor(Tokens.fg)
      }, (s: MdSeg, i: number) => i + '_' + s.t.length + (s.b ? 'b' : '') + (s.c ? 'c' : ''))
    }
    .fontSize(size * this.textScale)
    .lineHeight(lineH * this.textScale)
    .width('100%')
    .copyOption(CopyOptions.LocalDevice)
  }

  /**
   * 用户气泡里的正文：以前直接把 Markdown 原文塞进一个 Text，发 **重点**
   * 看到的就是两个星号。这里改走 parseMd 的块与行内片段，粗体与行内代码
   * 在蓝底气泡里也能认出来；整段仍是一个 Text，长按照样能选中复制。
   */
  @Builder
  userRich(src: string) {
    Text() {
      ForEach(parseMd(src), (b: MdBlock, i: number) => {
        if (i > 0) {
          Span('\n')
        }
        ForEach(this.richSegs(b), (s: MdSeg, j: number) => {
          Span(s.t)
            .fontWeight(s.b ? FontWeight.Bold : FontWeight.Normal)
            .decoration({ type: s.c ? TextDecorationType.Underline : TextDecorationType.None })
        })
      })
    }
    .fontSize(15 * this.textScale)
    .lineHeight(24 * this.textScale)
    .fontColor('#FFFFFF')
    .copyOption(CopyOptions.LocalDevice)
  }

  /**
   * 取一个块的行内片段。代码块、独立公式这类块 parseMd 只填 text、segs 为空，
   * 直接按 segs 渲染会把整段内容吞掉，这里退回整段文本。
   */
  private richSegs(b: MdBlock): MdSeg[] {
    if (b.segs.length > 0) {
      return b.segs;
    }
    const one: MdSeg = { t: b.text, b: false, c: false };
    return [one];
  }

  /** 独立公式：居中、等宽感，两侧留白，避免跟正文黏在一起。 */
  @Builder
  mdMath(b: MdBlock) {
    Row() {
      Text(b.text)
        .fontSize(15)
        .lineHeight(26)
        .fontColor(Tokens.fg)
        .textAlign(TextAlign.Center)
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 6, bottom: 10 })
  }

  /** 表格：首行淡蓝底，单元格细线，可横向滚动 */
  @Builder
  mdTable(b: MdBlock) {
    Column() {
      if (b.head.length > 2) {
        Text('左右滑动查看整张表')
          .fontSize(11)
          .fontColor(Tokens.dim2)
          .margin({ left: 2, bottom: 4 })
      }
      Scroll() {
        Column() {
          Row() {
            ForEach(b.head, (h: string, ci: number) => {
              Text() {
                ForEach(parseInline(h), (s: MdSeg, si: number) => {
                  Span(s.t)
                    .fontWeight(s.b ? FontWeight.Bold : FontWeight.Medium)
                    .fontFamily(s.c ? 'monospace' : 'HarmonyOS Sans')
                    .fontColor(Tokens.fg)
                }, (s: MdSeg, si: number) => 'th' + ci + '_' + si)
              }
              .fontSize(13)
              .width(132)
              .padding(8)
              .border({ width: 0.5, color: Tokens.line })
              .backgroundColor(Tokens.accentSoft)
              .copyOption(CopyOptions.LocalDevice)
            }, (h: string, ci: number) => 'th' + ci)
          }
          ForEach(b.rows, (r: string[], ri: number) => {
            Row() {
              ForEach(r, (c: string, ci: number) => {
                Text() {
                  ForEach(parseInline(c), (s: MdSeg, si: number) => {
                    Span(s.t)
                      .fontWeight(s.b ? FontWeight.Bold : FontWeight.Normal)
                      .fontFamily(s.c ? 'monospace' : 'HarmonyOS Sans')
                      .fontColor(Tokens.fg)
                  }, (s: MdSeg, si: number) => 'td' + ri + '_' + ci + '_' + si)
                }
                .fontSize(13)
                .width(132)
                .padding(8)
                .border({ width: 0.5, color: Tokens.line })
                .copyOption(CopyOptions.LocalDevice)
              }, (c: string, ci: number) => 'td' + ri + '_' + ci)
            }
          }, (r: string[], ri: number) => 'tr' + ri)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
    }
    .alignItems(HorizontalAlign.Start)
    .borderRadius(14)
    .border({ width: 0.5, color: Tokens.line })
    .margin({ top: 8, bottom: 4 })
    .width('100%')
  }

  @Builder
  mdBlock(b: MdBlock, idx: number) {
    if (b.kind === 'h1') {
      this.mdText(b.segs, 19, 27)
    } else if (b.kind === 'h2') {
      this.mdText(b.segs, 17, 25)
    } else if (b.kind === 'h3') {
      this.mdText(b.segs, 15.5, 23)
    } else if (b.kind === 'bullet') {
      Row() {
        Text('·')
          .fontSize(15)
          .fontColor(Tokens.fg)
          .width(12)
        this.mdText(b.segs, 15, 24)
      }
      .alignItems(VerticalAlign.Top)
      .padding({ left: 2 })
    } else if (b.kind === 'ordered') {
      Row() {
        Text(String(b.ord) + '.')
          .fontSize(15)
          .fontColor(Tokens.fg)
          .width(22)
        this.mdText(b.segs, 15, 24)
      }
      .alignItems(VerticalAlign.Top)
      .padding({ left: 2 })
    } else if (b.kind === 'quote') {
      Row() {
        Row()
          .width(3)
          .height('100%')
          .backgroundColor(Tokens.accent)
          .borderRadius(6)
          .margin({ right: 10 })
        this.mdText(b.segs, 14.5, 23)
      }
      .alignItems(VerticalAlign.Top)
      .margin({ top: 4, bottom: 4 })
    } else if (b.kind === 'code') {
      Column() {
        Text(b.text)
          .fontSize(13)
          .fontFamily('monospace')
          .fontColor(Tokens.fg)
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      .alignItems(HorizontalAlign.Start)
      .padding(12)
      .backgroundColor(Tokens.surface2)
      .borderRadius(14)
      .margin({ top: 6, bottom: 6 })
      .width('100%')
    } else if (b.kind === 'table') {
      this.mdTable(b)
    } else if (b.kind === 'math') {
      this.mdMath(b)
    } else {
      this.mdText(b.segs, 15, 24)
    }
  }

  build() {
    Column() {
      if (this.user) {
        this.userRich(this.userText)
      } else {
        ForEach(this.blocks, (b: MdBlock, i: number) => {
          this.mdBlock(b, i)
        }, (b: MdBlock, i: number) => 'b' + i + '_' + b.kind + b.text.length)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
