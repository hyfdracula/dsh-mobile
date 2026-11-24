import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';

/** 待发送板的一行：本机待发图片/文件，或宿主队列里的消息。 */
export interface PendRow {
  key: string;
  kind: string;
  idx: number;
  id: string;
  title: string;
  sub: string;
  thumb: string;
}

/**
 * 输入框上方「待发送」板：拖拽排序、立即发、编辑、删除。
 * 从 ChatPage 抽出来：行数据由父级算好，动作都以回调传进来，组件只管画和拖。
 */
@Component
export struct PendingBoard {
  @Prop rows: PendRow[] = [];
  /** 卡片高度（最多露三行），由父级按条数算。 */
  @Prop cardH: number = 0;
  onFire: (r: PendRow) => void = () => {};
  onEdit: (r: PendRow) => void = () => {};
  onRemove: (r: PendRow) => void = () => {};
  onMove: (from: number, to: number) => void = () => {};
  onHeight: (h: number) => void = () => {};

  @State private dragTitle: string = '';
  private dragFrom: number = -1;

  /** 拖动时跟着手指的小卡片 */
  @Builder
  dragChip() {
    Row() {
      Text(this.dragTitle)
        .fontSize(13)
        .fontColor(Tokens.fg)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .constraintSize({ maxWidth: 240 })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(Tokens.surface2)
    .borderRadius(14)
    .shadow({ radius: 16, color: '#55000000', offsetY: 6 })
  }

  @Builder
  rowView(r: PendRow) {
    Row() {
      // 六点手柄：长按这里可以上下拖动
      Column({ space: 2 }) {
        Row({ space: 2 }) {
          Circle().width(2).height(2).fill(Tokens.dim2)
          Circle().width(2).height(2).fill(Tokens.dim2)
        }
        Row({ space: 2 }) {
          Circle().width(2).height(2).fill(Tokens.dim2)
          Circle().width(2).height(2).fill(Tokens.dim2)
        }
        Row({ space: 2 }) {
          Circle().width(2).height(2).fill(Tokens.dim2)
          Circle().width(2).height(2).fill(Tokens.dim2)
        }
      }
      .width(16)
      .height(34)
      .justifyContent(FlexAlign.Center)

      if (r.thumb !== '') {
        Image(r.thumb)
          .width(30)
          .height(30)
          .borderRadius(10)
          .objectFit(ImageFit.Cover)
          .backgroundColor(Tokens.surface2)
          .margin({ right: 8 })
      } else if (r.kind === 'file') {
        Text('件')
          .fontSize(11)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .width(30)
          .height(30)
          .borderRadius(10)
          .backgroundColor(Tokens.accentStrong)
          .margin({ right: 8 })
      }

      Column({ space: 2 }) {
        Text(r.title)
          .fontSize(13)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (r.sub !== '') {
          Text(r.sub)
            .fontSize(11)
            .fontColor(Tokens.dim2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 2 }) {
        Row({ space: 3 }) {
          Image($r('app.media.ic_now'))
            .width(13)
            .height(13)
            .fillColor(Tokens.dim)
          Text(r.kind === 'queue' ? '立即' : '现在发')
            .fontSize(12)
            .fontColor(Tokens.dim)
        }
        .padding({ left: 4, right: 6, top: 6, bottom: 6 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => {
          this.onFire(r);
        })

        if (r.kind === 'queue') {
          Row() {
            Image($r('app.media.ic_edit'))
              .width(17)
              .height(17)
              .fillColor(Tokens.dim)
          }
          .width(32)
          .height(36)
          .justifyContent(FlexAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => {
            this.onEdit(r);
          })
        }

        Row() {
          Image($r('app.media.ic_trash'))
            .width(17)
            .height(17)
            .fillColor(Tokens.dim)
        }
        .width(32)
        .height(36)
        .justifyContent(FlexAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => {
          this.onRemove(r);
        })
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(42)
    .padding({ left: 2, right: 2 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      List({ space: 0 }) {
        ForEach(this.rows, (r: PendRow) => {
          ListItem() {
            this.rowView(r)
          }
        }, (r: PendRow) => r.key)
      }
      .width('100%')
      .height(this.cardH)
      .scrollBar(BarState.Off)
      .onItemDragStart((e: ItemDragInfo, index: number) => {
        this.dragFrom = index;
        this.dragTitle = index >= 0 && index < this.rows.length ? this.rows[index].title : '';
        Haptics.tap();
        return this.dragChip;
      })
      .onItemDrop((e: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
        if (!isSuccess || insertIndex < 0) {
          return;
        }
        this.onMove(itemIndex, insertIndex);
      })
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 4, bottom: 2 })
    // 待发送板比输入框更透：只留一层薄雾，下面的正文要能透出来
    .backgroundColor(Tokens.isDark ? '#14FFFFFF' : '#3DFFFFFF')
    .backdropBlur(24)
    .borderRadius(20)
    .border({ width: 1, color: Tokens.isDark ? '#33FFFFFF' : '#B3FFFFFF' })
    .shadow({ radius: 18, color: Tokens.shadow, offsetY: 2 })
    .margin({ left: 0, right: 0, bottom: 8 })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const h: number = Number(newValue.height);
      if (h > 0) {
        this.onHeight(h);
      }
    })
  }
}
