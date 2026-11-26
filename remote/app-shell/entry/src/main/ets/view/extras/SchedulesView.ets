import { Api, HostTaskRow } from '../../common/Api';
import { AppCtx } from '../../common/AppCtx';
import { Tokens } from '../../common/Tokens';
import { EmptyState } from '../../common/Widgets';
import { Haptics } from '../../common/Haptics';
import { Toast } from '../../common/Toast';
import { GATEWAY_404_HINT, GATEWAY_404_TITLE, isGateway404 } from './ExtrasCommon';

interface TaskRowVm {
  key: string;
  kindLabel: string;
  whenLabel: string;
  raw: HostTaskRow;
}

/**
 * 电脑端自动化定时任务视图（K4）：
 * 支持暂停 / 恢复、立即执行一次、确认删除与友好降级展示。
 */
@Component
export struct SchedulesView {
  api: Api = new Api('', '');
  @Prop @Watch('onReload') reloadTick: number = 0;
  @Prop topPad: number = 140;

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private busy: boolean = false;
  @State private missing404: boolean = false;
  @State private err: string = '';
  @State private acting: string = '';
  @State private taskVms: TaskRowVm[] = [];

  aboutToAppear(): void {
    void this.loadSchedules();
  }

  onReload(): void {
    void this.loadSchedules();
  }

  private formatKind(kind: string): string {
    if (kind === 'at') {
      return '定时';
    }
    if (kind === 'after') {
      return '延时';
    }
    if (kind === 'every') {
      return '周期';
    }
    if (kind === 'daily') {
      return '每天';
    }
    if (kind === 'weekly') {
      return '每周';
    }
    if (kind === 'cron') {
      return '计划';
    }
    if (kind === 'rrule') {
      return '规则';
    }
    return kind === '' ? '定时' : kind;
  }

  private formatWhen(iso: string): string {
    if (iso === '') {
      return '';
    }
    const d: Date = new Date(iso);
    const t: number = d.getTime();
    if (Number.isNaN(t)) {
      return iso;
    }
    const pad = (n: number): string => n < 10 ? '0' + String(n) : String(n);
    return String(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  private async loadSchedules(): Promise<void> {
    this.busy = true;
    this.missing404 = false;
    try {
      const list: HostTaskRow[] = await this.api.hostSchedules();
      const vms: TaskRowVm[] = [];
      for (let i = 0; i < list.length; i++) {
        const it: HostTaskRow = list[i];
        vms.push({
          key: it.id + '/' + (it.active ? '1' : '0') + '/' + it.when,
          kindLabel: this.formatKind(it.kind),
          whenLabel: this.formatWhen(it.when),
          raw: it
        });
      }
      this.taskVms = vms;
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

  private actLabel(action: string): string {
    if (action === 'pause') {
      return '已暂停任务';
    }
    if (action === 'resume') {
      return '已恢复任务';
    }
    if (action === 'run') {
      return '已通知电脑立即运行一次';
    }
    if (action === 'delete') {
      return '已删除任务';
    }
    return '已处理';
  }

  private async act(id: string, action: string): Promise<void> {
    if (this.acting !== '') {
      return;
    }
    Haptics.tap();
    this.acting = id;
    try {
      await this.api.scheduleAction(id, action);
      await this.loadSchedules();
      Toast.ok(this.actLabel(action));
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.acting = '';
    }
  }

  private confirmDelete(t: HostTaskRow): void {
    Haptics.tap();
    AppCtx.confirm(
      '删除这条自动化任务',
      '删除后该任务不会再自动触发，已产生的会话记录不受影响。',
      '删除',
      () => {
        void this.act(t.id, 'delete');
      },
      true
    );
  }

  build() {
    Scroll() {
      Column() {
        if (this.busy) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18).color(Tokens.accent)
            Text('读取自动化任务...')
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
            icon: $r('app.media.ic_now'),
            title: GATEWAY_404_TITLE,
            hint: GATEWAY_404_HINT
          })
        } else if (this.taskVms.length === 0 && !this.busy && this.err === '') {
          EmptyState({
            icon: $r('app.media.ic_now'),
            title: '这台电脑上还没有自动化任务',
            hint: '在对话或电脑端创建的定时巡检、周期汇报任务会显示在这里'
          })
        } else {
          ForEach(this.taskVms, (vm: TaskRowVm) => {
            Column() {
              Row() {
                Text(vm.raw.title !== '' ? vm.raw.title : vm.raw.id)
                  .fontSize(Tokens.fsBody)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Tokens.fg)
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(vm.raw.active ? '启用' : '已暂停')
                  .fontSize(Tokens.fsCaption)
                  .fontColor(vm.raw.active ? Tokens.accent : Tokens.dim2)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .backgroundColor(vm.raw.active ? Tokens.accentGlass : Tokens.chip)
                  .borderRadius(Tokens.rPill)
                  .margin({ left: 8 })
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)

              Row() {
                Text(vm.kindLabel)
                  .fontSize(Tokens.fsCaption)
                  .fontColor(Tokens.dim2)
                if (vm.whenLabel !== '') {
                  Text(vm.whenLabel)
                    .fontSize(Tokens.fsCaption)
                    .fontColor(Tokens.dim2)
                    .margin({ left: 8 })
                }
                Blank()

                if (this.acting === vm.raw.id) {
                  Text('处理中...')
                    .fontSize(Tokens.fsFoot)
                    .fontColor(Tokens.dim2)
                } else {
                  Text(vm.raw.active ? '暂停' : '恢复')
                    .fontSize(Tokens.fsFoot)
                    .fontColor(Tokens.accent)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .backgroundColor(Tokens.accentGlass)
                    .borderRadius(Tokens.rPill)
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                    .onClick(() => {
                      void this.act(vm.raw.id, vm.raw.active ? 'pause' : 'resume');
                    })

                  Text('立即运行')
                    .fontSize(Tokens.fsFoot)
                    .fontColor(Tokens.fg)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .backgroundColor(Tokens.chip)
                    .borderRadius(Tokens.rPill)
                    .margin({ left: 6 })
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                    .onClick(() => {
                      void this.act(vm.raw.id, 'run');
                    })

                  Stack({ alignContent: Alignment.Center }) {
                    Image($r('app.media.ic_trash'))
                      .width(15)
                      .height(15)
                      .fillColor(Tokens.dim)
                      .objectFit(ImageFit.Contain)
                  }
                  .width(30)
                  .height(28)
                  .margin({ left: 4 })
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                  .onClick(() => {
                    this.confirmDelete(vm.raw);
                  })
                }
              }
              .width('100%')
              .margin({ top: 10 })
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .padding({ left: 14, right: 12, top: 12, bottom: 12 })
            .margin({ bottom: 8 })
            .backgroundColor(Tokens.surface)
            .borderRadius(Tokens.rMd)
            .border({ width: 1, color: Tokens.lineSoft })
          }, (vm: TaskRowVm) => vm.key)
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
