import { Api, TeamMemberRow, TeamResp, TeamTaskRow } from '../../common/Api';
import { Tokens } from '../../common/Tokens';
import { EmptyState, RowSwitch } from '../../common/Widgets';
import { Toast } from '../../common/Toast';
import { GATEWAY_404_HINT, GATEWAY_404_TITLE, isGateway404 } from './ExtrasCommon';

/**
 * 智能体团队成员与任务进度视图（K4）。
 */
@Component
export struct TeamView {
  api: Api = new Api('', '');
  @Prop sessionId: string = '';
  @Prop @Watch('onReload') reloadTick: number = 0;
  @Prop topPad: number = 140;

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private busy: boolean = false;
  @State private toggling: boolean = false;
  @State private missing404: boolean = false;
  @State private err: string = '';
  @State private teamOn: boolean = false;
  @State private sawMode: boolean = false;
  @State private members: TeamMemberRow[] = [];
  @State private tasks: TeamTaskRow[] = [];

  aboutToAppear(): void {
    void this.loadTeam();
  }

  onReload(): void {
    void this.loadTeam();
  }

  private async loadTeam(): Promise<void> {
    if (this.sessionId === '') {
      return;
    }
    this.busy = true;
    this.missing404 = false;
    try {
      const r: TeamResp = await this.api.team(this.sessionId);
      this.members = r.members !== undefined ? r.members : [];
      this.tasks = r.tasks !== undefined ? r.tasks : [];
      this.teamOn = r.enabled === true;
      this.sawMode = r.sawMode === true;
      this.err = '';
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      if (isGateway404(msg)) {
        this.missing404 = true;
        this.err = '';
      } else {
        this.err = msg;
      }
    } finally {
      this.busy = false;
    }
  }

  private async setTeamMode(enabled: boolean): Promise<void> {
    if (this.toggling || this.teamOn === enabled || this.sessionId === '') {
      return;
    }
    this.toggling = true;
    try {
      const next: boolean = await this.api.teamMode(this.sessionId, enabled);
      this.teamOn = next;
      this.sawMode = true;
      Toast.ok(next ? '已开启智能体团队协作' : '已关闭智能体团队协作');
      await this.loadTeam();
    } catch (e) {
      Toast.err((e as Error).message);
    } finally {
      this.toggling = false;
    }
  }

  private phaseText(phase: string): string {
    if (phase === 'active') {
      return '运行中';
    }
    if (phase === 'provisioning') {
      return '准备中';
    }
    if (phase === 'failed') {
      return '失败';
    }
    return phase !== '' ? phase : '就绪';
  }

  private phaseColor(phase: string): string {
    if (phase === 'active') {
      return Tokens.runInk;
    }
    if (phase === 'failed') {
      return Tokens.err;
    }
    return Tokens.dim2;
  }

  private taskText(status: string): string {
    if (status === 'in_progress') {
      return '进行中';
    }
    if (status === 'completed') {
      return '已完成';
    }
    if (status === 'pending') {
      return '待开始';
    }
    return status;
  }

  private taskColor(status: string): string {
    if (status === 'in_progress') {
      return Tokens.runInk;
    }
    if (status === 'completed') {
      return Tokens.doneInk;
    }
    return Tokens.dim2;
  }

  private completedTaskCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === 'completed') {
        n++;
      }
    }
    return n;
  }

  build() {
    Scroll() {
      Column() {
        if (this.busy) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18).color(Tokens.accent)
            Text('同步团队状态...')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim2)
          }
          .width('100%')
          .padding({ top: 8, bottom: 12 })
        }

        if (this.err !== '') {
          Text(this.err)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.err)
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor(Tokens.surface)
            .borderRadius(Tokens.rMd)
            .margin({ bottom: 10 })
        }

        if (this.missing404) {
          EmptyState({
            icon: $r('app.media.ic_group'),
            title: GATEWAY_404_TITLE,
            hint: GATEWAY_404_HINT
          })
        } else {
          Column() {
            RowSwitch({
              title: '智能体团队协作',
              hint: this.members.length > 0
                ? ('当前 ' + String(this.members.length) + ' 名成员 · 已完成 ' +
                  String(this.completedTaskCount()) + ' / ' + String(this.tasks.length) + ' 项任务')
                : '开启后主控智能体可并行分派多位成员协同完成复杂任务',
              value: this.teamOn,
              switchEnabled: !this.busy && !this.toggling,
              onChanged: (v: boolean) => {
                void this.setTeamMode(v);
              }
            })
          }
          .width('100%')
          .backgroundColor(Tokens.surface)
          .borderRadius(Tokens.rMd)
          .border({ width: 1, color: Tokens.lineSoft })
          .margin({ bottom: 12 })

          if (this.members.length === 0 && this.tasks.length === 0 && !this.busy) {
            EmptyState({
              icon: $r('app.media.ic_group'),
              title: this.teamOn ? '团队已就绪，等待分配成员' : '当前会话暂无团队活动',
              hint: '发起复杂开发任务后，子智能体成员与任务板进度会实时展示在这里'
            })
          } else {
            if (this.members.length > 0) {
              Text('团队成员 (' + String(this.members.length) + ')')
                .fontSize(Tokens.fsFoot)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.dim)
                .width('100%')
                .padding({ left: 4, bottom: 8 })

              ForEach(this.members, (m: TeamMemberRow) => {
                Column() {
                  Row() {
                    Text(m.name === '' ? m.id : m.name)
                      .fontSize(Tokens.fsBody)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Tokens.fg)
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.phaseText(m.phase))
                      .fontSize(Tokens.fsCaption)
                      .fontColor(this.phaseColor(m.phase))
                  }
                  .width('100%')

                  if (m.description !== '') {
                    Text(m.description)
                      .fontSize(Tokens.fsFoot)
                      .fontColor(Tokens.dim2)
                      .width('100%')
                      .margin({ top: 4 })
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  if (m.error !== '') {
                    Text(m.error)
                      .fontSize(Tokens.fsCaption)
                      .fontColor(Tokens.err)
                      .width('100%')
                      .margin({ top: 4 })
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 11, bottom: 11 })
                .margin({ bottom: 8 })
                .backgroundColor(Tokens.surface)
                .borderRadius(Tokens.rMd)
                .border({ width: 1, color: Tokens.lineSoft })
              }, (m: TeamMemberRow) => m.id + '|' + m.phase)
            }

            if (this.tasks.length > 0) {
              Text('任务进度 (' + String(this.completedTaskCount()) + ' / ' + String(this.tasks.length) + ')')
                .fontSize(Tokens.fsFoot)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.dim)
                .width('100%')
                .padding({ left: 4, top: 8, bottom: 8 })

              ForEach(this.tasks, (t: TeamTaskRow) => {
                Column() {
                  Text(t.subject === '' ? t.id : t.subject)
                    .fontSize(Tokens.fsBody)
                    .fontColor(Tokens.fg)
                    .width('100%')
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Row() {
                    Text(this.taskText(t.status))
                      .fontSize(Tokens.fsCaption)
                      .fontColor(this.taskColor(t.status))
                    if (t.ownerName !== '') {
                      Text('· ' + t.ownerName)
                        .fontSize(Tokens.fsCaption)
                        .fontColor(Tokens.dim2)
                        .margin({ left: 6 })
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    Blank()
                    Text('#' + String(t.revision))
                      .fontSize(Tokens.fsCaption)
                      .fontFamily('monospace')
                      .fontColor(Tokens.dim2)
                  }
                  .width('100%')
                  .margin({ top: 6 })
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 11, bottom: 11 })
                .margin({ bottom: 8 })
                .backgroundColor(Tokens.surface)
                .borderRadius(Tokens.rMd)
                .border({ width: 1, color: Tokens.lineSoft })
              }, (t: TeamTaskRow) => t.id + '|' + String(t.revision) + '|' + t.status)
            }
          }
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 820 })
      .padding({ left: 16, right: 16, top: this.topPad, bottom: this.bottomInset + 32 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }
}
