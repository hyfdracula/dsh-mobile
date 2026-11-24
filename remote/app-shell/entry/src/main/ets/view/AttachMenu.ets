import { Tokens } from '../common/Tokens';

/**
 * 输入框上方的附件菜单：拍照 / 照片 / 本地文件。
 * 只是三枚胶囊，抽出来让聊天页少一段模板，回调仍由父级决定。
 */
@Component
export struct AttachMenu {
  onCamera: () => void = () => {};
  onPhotos: () => void = () => {};
  onFiles: () => void = () => {};

  @Builder
  chip(label: string, act: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(Tokens.fg)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(999)
      .backgroundColor(Tokens.surface3)
      .border({ width: 1, color: Tokens.glassLine })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
      .onClick(() => {
        act();
      })
  }

  build() {
    Row({ space: 8 }) {
      this.chip('拍照', (): void => {
        this.onCamera();
      })
      this.chip('照片', (): void => {
        this.onPhotos();
      })
      this.chip('本地文件', (): void => {
        this.onFiles();
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 10, right: 10, top: 2 })
    .margin({ bottom: 10 })
  }
}
