import curves from '@ohos.curves';
import { Api, AgentRef, SessionRow } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { ChatParam } from '../common/Types';
import { NavFx, NavFxSink } from '../common/NavFx';

interface AgentGroup {
  sessionId: string;
  title: string;
  rows: AgentRef[];
}

function ago(ms: number): string {
  const d = Date.now() - ms;
  if (d < 60_000) return '刚刚';
  if (d < 3_600_000) return Math.floor(d / 60_000) + ' 分钟前';
  if (d < 86_400_000) return Math.floor(d / 3_600_000) + ' 小时前';
  return Math.floor(d / 86_400_000) + ' 天前';
}

@Component
export struct AgentsPage {
  api: Api = new Api('', '');
  @Consume('stack') stack: NavPathStack;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @State private groups: AgentGroup[] = [];
  @State private total: number = 0;
  @State private loading: boolean = true;
  @State private enter: boolean = false;
  @State private err: string = '';
  /** 转场状态：由 Navigation 的 customNavContentTransition 按 navDestinationId 驱动。 */
  @State private fxTx: string = '0%';
  @State private fxOp: number = 1;
  @State private fxSc: number = 1;
  private fxId: string = '';
  private fxSink: NavFxSink | undefined = undefined;

  /** 把本页的转场状态登记给 Navigation。 */
  private bindFx(id: string): void {
    const sink: NavFxSink = {
      apply: (tx: string, op: number, sc: number): void => {
        this.fxTx = tx;
        this.fxOp = op;
        this.fxSc = sc;
      }
    };
    this.fxId = id;
    this.fxSink = sink;
    NavFx.register(id, sink);
  }

  aboutToDisappear(): void {
    const s = this.fxSink;
    if (s !== undefined) {
      NavFx.unregister(this.fxId, s);
    }
  }

  aboutToAppear(): void {
    this.load();
    setTimeout(() => {
      animateTo({ duration: 420, curve: curves.springMotion(0.36, 0.95) }, () => {
        this.enter = true;
      });
    }, 50);
  }

  private async load(): Promise<void> {
    try {
      const rows = await this.api.sessions();
      const out: AgentGroup[] = [];
      let n = 0;
      for (let i = 0; i < rows.length; i++) {
        const r: SessionRow = rows[i];
        const subs: AgentRef[] = (r.agents && r.agents.subagents) ? r.agents.subagents : [];
        if (subs.length > 0) {
          out.push({ sessionId: r.id, title: r.title || '(untitled)', rows: subs });
          n += subs.length;
        }
      }
      this.groups = out;
      this.total = n;
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  @Builder
  agentRow(a: AgentRef, last: boolean) {
    Column() {
      Row() {
        Column() {
          Text(a.label || a.id)
            .fontSize(15)
            .fontColor(Tokens.fg)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(a.mode + ' · ' + ago(a.createdAt))
            .fontSize(11.5)
            .fontColor(Tokens.dim2)
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 13, bottom: 13 })

      if (!last) {
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
      }
    }
    .width('100%')
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          Text('‹')
            .fontSize(30)
            .fontColor(Tokens.fg)
            .width(34)
            .height(34)
            .textAlign(TextAlign.Center)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => this.stack.pop())
          Column() {
            Text('智能体团队')
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor(Tokens.fg)
            Text(this.loading ? '加载中…' : (this.total + ' 个子智能体 · ' + this.groups.length + ' 个会话'))
              .fontSize(11)
              .fontColor(Tokens.dim2)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 4 })

          Text('⟳')
            .fontSize(17)
            .fontColor(Tokens.dim)
            .padding(6)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              this.loading = true;
              this.load();
            })
        }
        .width('100%')
        .margin({ bottom: 12 })

        if (this.loading) {
          Row() {
            LoadingProgress().width(18).height(18).color(Tokens.dim2)
            Text('加载中…').fontSize(13).fontColor(Tokens.dim2).margin({ left: 8 })
          }.padding(24)
        } else if (this.err !== '') {
          Text('读取失败：' + this.err).fontSize(13).fontColor(Tokens.err).padding(20)
        } else if (this.groups.length === 0) {
          Text('还没有子智能体')
            .fontSize(13)
            .fontColor(Tokens.dim2)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(40)
        } else {
          List({ space: 14 }) {
            ForEach(this.groups, (g: AgentGroup) => {
              ListItem() {
                Column() {
                  Row() {
                    Text(g.title)
                      .fontSize(12.5)
                      .fontColor(Tokens.dim)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text(g.rows.length + ' 个')
                      .fontSize(11)
                      .fontColor(Tokens.dim2)
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 12, bottom: 8 })

                  Column() {
                    ForEach(g.rows, (a: AgentRef, idx: number) => {
                      this.agentRow(a, idx === g.rows.length - 1)
                    }, (a: AgentRef) => a.id)
                  }
                  .width('100%')
                  .backgroundColor(Tokens.surface)
                  .borderRadius(Tokens.rGroup)
                  .clip(true)
                }
                .width('100%')
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                .onClick(() => {
                  this.stack.pushPathByName('chat', { id: g.sessionId, title: g.title } as ChatParam);
                })
              }
            }, (g: AgentGroup) => g.sessionId)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 50 })
      .opacity(this.enter ? 1 : 0)
      .translate({ y: this.enter ? 0 : 12 })
      .animation({ duration: 320, curve: curves.springMotion(0.35, 1.0) })
    }
    .hideTitleBar(true)
    .backgroundColor(this.themeBg)
    .mode(NavDestinationMode.STANDARD)
    .onReady((context: NavDestinationContext) => {
      const id: string | undefined = context.navDestinationId;
      if (id !== undefined && id !== '') {
        this.bindFx(id);
      }
    })
    .translate({ x: this.fxTx })
    .opacity(this.fxOp)
    .scale({ x: this.fxSc, y: this.fxSc })
  }
}
