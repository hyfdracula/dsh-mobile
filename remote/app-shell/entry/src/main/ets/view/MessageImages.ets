import { ImageRef, Api } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';

/**
 * 消息里的图片区：按原图比例给一个不超过 280 宽的框，点开看大图。
 * 没有有效签名时显示占位，不渲染空 URL。
 */
@Component
export struct MessageImages {
  images: ImageRef[] = [];
  api: Api = new Api('', '');
  onTap: (url: string) => void = () => {};

  private widthOf(img: ImageRef): number {
    return img.width > 0 && img.height > 0 && img.width < 280 ? img.width : 280;
  }

  private heightOf(img: ImageRef): number {
    if (img.width > 0 && img.height > 0) {
      const w: number = this.widthOf(img);
      return Math.round((w * img.height) / img.width);
    }
    return 180;
  }

  build() {
    Column({ space: 8 }) {
      ForEach(this.images, (img: ImageRef) => {
        if (this.api.attachmentUrl(img) !== '') {
          Image(this.api.attachmentUrl(img))
            .width(this.widthOf(img))
            .height(this.heightOf(img))
            .objectFit(ImageFit.Contain)
            .borderRadius(14)
            .backgroundColor(Tokens.surface2)
            .alt($r('app.media.app_icon'))
            .onClick(() => {
              Haptics.tap();
              this.onTap(this.api.attachmentUrl(img));
            })
        } else {
          Row() {
            Text('图片待加载')
              .fontSize(11)
              .fontColor(Tokens.dim)
          }
          .width(this.widthOf(img))
          .height(72)
          .justifyContent(FlexAlign.Center)
          .borderRadius(14)
          .backgroundColor(Tokens.surface2)
        }
      }, (img: ImageRef) => img.id)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
