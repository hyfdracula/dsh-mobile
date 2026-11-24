import { Tokens } from './Tokens';
import { Haptics } from './Haptics';

/**
 * 统一页面头部与顶部渐隐。
 *
 * 以前每个二级页各写一套：38 玻璃返回 / 30 文字箭头 / 40 无模糊圆钮、
 * 标题 16/19/20/24、刷新有文字胶囊也有 38 圆钮。这里收成一份：
 * 38x38 玻璃圆钮 + 20 号标题 + 右侧同款圆钮（图标或字符），高度 56。
 */
@Component
export struct GlassIconButton {
  icon: Resource = $r('app.media.ic_back');
  glyph: string = '';
  label: string = '';
  btnSize: number = 38;
  onTap: () => void = () => {};

  build() {
    Stack() {
      if (this.glyph !== '') {
        Text(this.glyph)
          .fontSize(20)
          .fontColor(Tokens.fg)
      } else {
        Image(this.icon)
          .width(20)
          .height(20)
          .fillColor(Tokens.fg)
          .objectFit(ImageFit.Contain)
      }
    }
    .width(this.btnSize)
    .height(this.btnSize)
    .borderRadius(Tokens.rPill)
    .backgroundColor(Tokens.glassBtnBg)
    .backdropBlur(22)
    .border({ width: 1, color: Tokens.glassBtnLine })
    .shadow({ radius: 14, color: Tokens.glassBtnShadow, offsetY: 4 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .accessibilityText(this.label)
    .onClick(() => {
      Haptics.tap();
      this.onTap();
    })
  }
}

/** 右侧槽位：不显示 / 图标 / 字符（如 ↻）/ 文字（如「刷新」）。 */
@Component
export struct PageHeader {
  title: string = '';
  subtitle: string = '';
  hasBack: boolean = true;
  /** none | glyph | icon | label */
  rightKind: string = 'none';
  rightGlyph: string = '\u21bb';
  rightIcon: Resource = $r('app.media.ic_scan');
  rightLabel: string = '';
  /** 第二个右侧圆钮（聊天页的「任务」与「更多」） */
  hasRight2: boolean = false;
  rightIcon2: Resource = $r('app.media.ic_group');
  onBack: () => void = () => {};
  onRight: () => void = () => {};
  onRight2: () => void = () => {};

  build() {
    Row() {
      if (this.hasBack) {
        GlassIconButton({
          icon: $r('app.media.ic_back'),
          label: '返回',
          onTap: () => {
            this.onBack();
          }
        })
      }
      Column() {
        Text(this.title)
          .fontSize(Tokens.fsTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.subtitle !== '') {
          Text(this.subtitle)
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 1 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: this.hasBack ? 12 : 0 })
      if (this.rightKind === 'glyph') {
        GlassIconButton({
          glyph: this.rightGlyph,
          label: '刷新',
          onTap: () => {
            this.onRight();
          }
        })
      } else if (this.rightKind === 'icon') {
        GlassIconButton({
          icon: this.rightIcon,
          label: '更多',
          onTap: () => {
            this.onRight();
          }
        })
      } else if (this.rightKind === 'label') {
        Text(this.rightLabel)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.accent)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.accentSoft)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            Haptics.tap();
            this.onRight();
          })
      }
      if (this.hasRight2) {
        GlassIconButton({
          icon: this.rightIcon2,
          label: '更多',
          onTap: () => {
            this.onRight2();
          }
        })
        .margin({ left: 8 })
      }
    }
    .width('100%')
    .height(56)
    .alignItems(VerticalAlign.Center)
  }
}

/** 顶部同色渐隐：滚上来的内容在浮动标题下淡出，高度全 App 统一 96。 */
@Component
export struct TopFade {
  fadeHeight: number = 96;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;

  build() {
    Row()
      .width('100%')
      .height(this.fadeHeight)
      .linearGradient({
        angle: 180,
        colors: [[this.themeBg, 0.0], [this.themeBg, 0.58], ['#00' + this.themeBg.slice(1), 1.0]]
      })
      .hitTestBehavior(HitTestMode.None)
  }
}
