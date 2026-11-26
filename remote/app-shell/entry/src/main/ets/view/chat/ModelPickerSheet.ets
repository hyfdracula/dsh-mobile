import { CatalogGroup, CatalogModel, EffortRef } from '../../common/Api';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Tokens } from '../../common/Tokens';
import { EmptyState, HintLabel } from '../../common/Widgets';

interface ActiveModelLookup {
  groupId: string;
  model: CatalogModel | null;
}

/**
 * 模型与推理强度选择半模态面板（F04）：
 * - 纯净 Tokens.surface 底色 + 20fp Medium 标题 + 圆形关闭钮；
 * - 智能体协作收进独立 Tokens.surface2 卡片行；
 * - 仅对当前选中模型在顶部展示简洁「推理强度」分段胶囊卡，彻底消除满屏灰色小胶囊；
 * - 供应商分组卡片内以细线分隔、选中行整行高亮 + 蓝勾、切换中显示 LoadingProgress、无目录使用 EmptyState。
 */
@Component
export struct ModelPickerSheet {
  @Prop groups: CatalogGroup[] = [];
  @Prop groupsLoaded: boolean = false;
  @Prop curModelId: string = '';
  @Prop curModel: string = '';
  @Prop curEffort: string = '';
  @Prop pickingId: string = '';
  @Prop allowTeam: boolean = true;
  @Prop teamOn: boolean = false;
  @Prop teamBusy: boolean = false;
  onToggleTeam: (v: boolean) => void = () => {};
  onPick: (groupId: string, modelId: string, effort: string, effortOnly: boolean) => void = () => {};
  onClose: () => void = () => {};
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  private findActiveModel(): ActiveModelLookup {
    for (let i = 0; i < this.groups.length; i++) {
      const g: CatalogGroup = this.groups[i];
      for (let k = 0; k < g.models.length; k++) {
        if (g.models[k].id === this.curModelId) {
          const hit: ActiveModelLookup = { groupId: g.id, model: g.models[k] };
          return hit;
        }
      }
    }
    const none: ActiveModelLookup = { groupId: '', model: null };
    return none;
  }

  private activeEfforts(): EffortRef[] {
    const found: ActiveModelLookup = this.findActiveModel();
    if (found.model === null || found.model.efforts === undefined) {
      return [];
    }
    return found.model.efforts;
  }

  private activeGroupId(): string {
    return this.findActiveModel().groupId;
  }

  private effectiveEffort(m: CatalogModel): string {
    if (this.curEffort !== '') {
      return this.curEffort;
    }
    return m.defaultEffort;
  }

  private activeEffortId(): string {
    const found: ActiveModelLookup = this.findActiveModel();
    if (found.model === null) {
      return this.curEffort;
    }
    return this.effectiveEffort(found.model);
  }

  build() {
    Column() {
      // 顶部标题栏
      Row() {
        Text('选择模型')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
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
      .padding({ bottom: 12 })

      // 智能体协作独立卡片行（仅主智能体会话展示）
      if (this.allowTeam) {
        Row() {
          Row() {
            HintLabel({
              title: '智能体协作',
              tipText: '开启后可派遣多个子智能体并行处理复杂任务。'
            })
          }
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)

          if (this.teamBusy) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color(Tokens.accent)
              .margin({ right: 8 })
          }

          Toggle({ type: ToggleType.Switch, isOn: this.teamOn })
            .selectedColor(Tokens.accent)
            .enabled(!this.teamBusy)
            .onChange((v: boolean) => {
              if (v !== this.teamOn) {
                this.onToggleTeam(v);
              }
            })
        }
        .width('100%')
        .padding({ left: 14, right: 12, top: 10, bottom: 10 })
        .backgroundColor(Mat.subCardBg(this.hdsOn))
        .border(Mat.subCardBorder(this.hdsOn))
        .borderRadius(Tokens.rMd)
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 10 })
      }

      // 顶部推理强度分段胶囊卡（仅当前模型支持多档推理强度时展示）
      if (this.activeEfforts().length > 1) {
        Column({ space: 8 }) {
          Row() {
            Text('推理强度')
              .fontSize(Tokens.fsFoot)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.dim)
              .layoutWeight(1)
            if (this.pickingId === '__effort__') {
              LoadingProgress().width(14).height(14).color(Tokens.accent)
            } else if (this.curModel !== '') {
              Text(this.curModel)
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim2)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: 4 }) {
            ForEach(this.activeEfforts(), (e: EffortRef) => {
              Text(e.name)
                .fontSize(Tokens.fsFoot)
                .fontWeight(this.activeEffortId() === e.id ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.activeEffortId() === e.id ? Tokens.accentInk : Tokens.dim)
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
                .height(32)
                .borderRadius(Tokens.rPill)
                .backgroundColor(this.activeEffortId() === e.id ? Tokens.accent : Color.Transparent)
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
                .onClick(() => {
                  if (this.pickingId !== '' || this.activeEffortId() === e.id) {
                    return;
                  }
                  Haptics.tap();
                  this.onPick(this.activeGroupId(), this.curModelId, e.id, true);
                })
            }, (e: EffortRef) => e.id + '_' + (this.activeEffortId() === e.id ? '1' : '0'))
          }
          .width('100%')
          .padding(3)
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.surface3)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 12 })
        .backgroundColor(Mat.subCardBg(this.hdsOn))
        .border(Mat.subCardBorder(this.hdsOn))
        .borderRadius(Tokens.rMd)
        .margin({ bottom: 12 })
        .alignItems(HorizontalAlign.Start)
      }

      if (!this.groupsLoaded) {
        Column() {
          LoadingProgress().width(24).height(24).color(Tokens.accent)
          Text('正在读取模型目录…')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .margin({ top: 10 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.groups.length === 0) {
        Column() {
          EmptyState({
            icon: $r('app.media.ic_pc'),
            title: '暂无可用模型',
            hint: '请检查电脑端是否已配置模型供应商，或稍后重试。'
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 14 }) {
            ForEach(this.groups, (g: CatalogGroup) => {
              Column() {
                Row() {
                  Text(g.name)
                    .fontSize(Tokens.fsFoot)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Tokens.dim2)
                    .letterSpacing(0.5)
                    .layoutWeight(1)
                  if (g.models.some((m: CatalogModel) => m.id === this.curModelId)) {
                    Text('当前使用')
                      .fontSize(Tokens.fsCaption)
                      .fontColor(Tokens.accent)
                  }
                }
                .width('100%')
                .padding({ left: 4, right: 4, bottom: 6 })

                Column() {
                  ForEach(g.models, (m: CatalogModel, idx: number) => {
                    Column() {
                      if (idx > 0) {
                        Divider()
                          .color(Tokens.lineSoft)
                          .margin({ left: 14 })
                      }
                      Row() {
                        Column() {
                          Text(m.name)
                            .fontSize(Tokens.fsBodyLg)
                            .fontWeight(this.curModelId === m.id ? FontWeight.Medium : FontWeight.Normal)
                            .fontColor(this.curModelId === m.id ? Tokens.accent : Tokens.fg)
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                          if (m.description !== '') {
                            Text(m.description)
                              .fontSize(Tokens.fsCaption)
                              .fontColor(Tokens.dim2)
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                              .margin({ top: 2 })
                          }
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)

                        if (this.pickingId === m.id) {
                          LoadingProgress()
                            .width(16)
                            .height(16)
                            .color(Tokens.accent)
                            .margin({ left: 10 })
                        } else if (this.curModelId === m.id) {
                          Text('√')
                            .fontSize(16)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(Tokens.accent)
                            .margin({ left: 10 })
                        }
                      }
                      .width('100%')
                      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                      .alignItems(VerticalAlign.Center)
                      .backgroundColor(this.curModelId === m.id ? Tokens.accentSoft : Color.Transparent)
                      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.99 })
                      .onClick(() => {
                        if (this.pickingId !== '') {
                          return;
                        }
                        Haptics.tap();
                        const eff: string = this.curModelId === m.id ? this.effectiveEffort(m) : m.defaultEffort;
                        this.onPick(g.id, m.id, eff, false);
                      })
                    }
                    .width('100%')
                  }, (m: CatalogModel) => m.id + '_' + (this.curModelId === m.id ? '1' : '0') + '_' +
                    (this.pickingId === m.id ? 'p' : 'n'))
                }
                .width('100%')
                .backgroundColor(Mat.subCardBg(this.hdsOn))
                .border(Mat.subCardBorder(this.hdsOn))
                .borderRadius(Tokens.rCard)
                .clip(true)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }, (g: CatalogGroup) => g.id + '_' +
              (g.models.some((m: CatalogModel) => m.id === this.curModelId) ? this.curModelId : '0') +
              '_' + this.pickingId)
          }
          .width('100%')
          .padding({ bottom: this.bottomInset + 20 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 10, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Color.Transparent)
  }
}
