import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { Machines, Machine } from '../common/Machines';
import { ago } from '../common/Format';

/**
 * 已配对的电脑列表：点一行切换、长按重命名/忘记、右上角 × 直接移除。
 *
 * 单独做成组件：它挂在 NavDestination 的二级页里，而二级页的内容不会因为
 * 父级 @State 变化重新构建，所以「当前这台」的高亮必须由组件自己的
 * @StorageLink 驱动，切换后才会立刻变。
 */
/**
 * 已配对的电脑列表。
 * 单独做成组件：它挂在 NavDestination 的二级页里，而二级页的内容不会因为
 * 父级 @State 变化重新构建，所以「当前这台」的高亮必须由组件自己的
 * @StorageLink 驱动，切换后才会立刻变。
 */
@Component
export struct MachineList {
  @StorageLink('machinesVer') ver: number = 0;
  onPick: (id: string) => void = () => {};
  onRemove: (id: string) => void = () => {};
  onRename: (id: string, name: string) => void = () => {};

  @Builder
  rowMenu(m: Machine) {
    Menu() {
      MenuItem({ content: '重命名' })
        .onClick(() => {
          Haptics.tap();
          this.onRename(m.id, m.name);
        })
      MenuItem({ content: '忘记这台电脑' })
        .onClick(() => {
          Haptics.tap();
          this.onRemove(m.id);
        })
    }
  }

  @Builder
  row(m: Machine) {
    Row() {
      Column() {
        Row() {
          Text(m.name)
            .fontSize(13)
            .fontColor(Tokens.fg)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (m.id === Machines.activeId()) {
            Text('当前')
              .fontSize(11)
              .fontColor(Tokens.accent)
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(999)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .margin({ left: 6 })
          }
        }
        .width('100%')
        Text(m.wan + ' · ' + ago(m.at))
          .fontSize(11)
          .fontColor(Tokens.dim2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (Machines.list().length > 1) {
        Text('×')
          .fontSize(17)
          .fontColor(Tokens.dim2)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .borderRadius(999)
          .onClick(() => {
            Haptics.tap();
            this.onRemove(m.id);
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 10, bottom: 10 })
    .borderRadius(Tokens.rGroup)
    .backgroundColor(m.id === Machines.activeId() ? Tokens.accentSoft : Tokens.surface2)
    .margin({ bottom: 8 })
    .onClick(() => {
      Haptics.tap();
      this.onPick(m.id);
    })
    .bindContextMenu(this.rowMenu(m), ResponseType.LongPress)
  }

  build() {
    Column() {
      ForEach(Machines.list(), (m: Machine) => {
        this.row(m)
      }, (m: Machine) => m.id + '@' + m.at)
    }
    .width('100%')
  }
}
