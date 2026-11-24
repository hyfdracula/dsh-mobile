import curves from '@ohos.curves';
import { Api, AgentRef, SessionRow } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { ago } from '../common/Format';
import { ChatParam } from '../common/Types';
import { PageHeader } from '../common/Chrome';
import { EmptyState } from '../common/Widgets';

interface AgentGroup {
  sessionId: string;
  title: string;
  rows: AgentRef[];
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
            .fontSize(12)
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
        PageHeader({
          title: '智能体团队',
          subtitle: this.loading ? '加载中…' : (this.total + ' 个子智能体 · ' + this.groups.length + ' 个会话'),
          rightKind: 'glyph',
          onBack: () => {
            this.stack.pop();
          },
          onRight: () => {
            this.loading = true;
            this.load();
          }
        })
        .margin({ bottom: 12 })

        if (this.loading) {
          Row() {
            LoadingProgress().width(18).height(18).color(Tokens.dim2)
            Text('加载中…').fontSize(13).fontColor(Tokens.dim2).margin({ left: 8 })
          }.padding(24)
        } else if (this.err !== '') {
          Text('读取失败：' + this.err).fontSize(13).fontColor(Tokens.err).padding(20)
        } else if (this.groups.length === 0) {
          EmptyState({
            icon: $r('app.media.ic_group'),
            title: '还没有子智能体',
            hint: '在电脑端这个会话的菜单里打开「智能体团队」，成员与任务才会同步到这里。'
          })
        } else {
          List({ space: 14 }) {
            ForEach(this.groups, (g: AgentGroup) => {
              ListItem() {
                Column() {
                  Row() {
                    Text(g.title)
                      .fontSize(13)
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
  }
}
