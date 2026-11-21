/**
 * 存储空间：本机缓存占了多少、设备还剩多少、能一键清掉哪些。
 *
 * 结构与桌面端控制台的「存储空间」页对齐：缓存占用环形图 + 分类明细 + 清理全部缓存。
 * 差别在于数据来源——那边统计的是电脑上的会话库，这边只统计手机沙箱（见 Storage.ets
 * 的说明），所以页面文案会说明「清了不影响电脑上的数据」。
 */

import { common } from '@kit.AbilityKit';
import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { Bucket, DeviceSpace, scanStorage, clearCache, deviceSpace, sizeText } from '../common/Storage';

/** 环形图内圈留白与线宽（vp）。 */
const RING_WIDTH: number = 18;
const RING_SIZE: number = 168;

@Component
export struct StoragePage {
  onExit: () => void = () => {};

  @State private buckets: Bucket[] = [];
  @State private device: DeviceSpace = { free: 0, total: 0 };
  @State private loading: boolean = true;
  @State private detailOn: boolean = false;
  @State private detailKey: string = '';
  /** 主题底色：顶部渐变要和页面底色同色，切换主题时跟着走 */
  @StorageLink('themeBg') themeBg: string = Tokens.bg;

  private ringSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private ring: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.ringSettings);

  aboutToAppear(): void {
    this.refresh();
  }

  /** 多个文件写一次盘很慢，放在页面出现时统一扫一次。 */
  private refresh(): void {
    this.loading = true;
    const ctx = getContext(this) as common.UIAbilityContext;
    // 先清空再赋新数组：ForEach 按 key 复用节点，只换对象引用时个别文本不会刷新
    this.buckets = [];
    const next: Bucket[] = scanStorage(ctx);
    this.buckets = next;
    this.device = deviceSpace(ctx);
    this.loading = false;
  }

  private totalBytes(): number {
    let sum: number = 0;
    for (let i = 0; i < this.buckets.length; i++) {
      sum += this.buckets[i].bytes;
    }
    return sum;
  }

  private bucketOf(key: string): Bucket | null {
    for (let i = 0; i < this.buckets.length; i++) {
      if (this.buckets[i].key === key) {
        return this.buckets[i];
      }
    }
    return null;
  }

  /** 画环形图：按分类占比分段，每段之间留一点空隙。 */
  private drawRing(): void {
    const ctx = this.ring;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    const cx: number = w / 2;
    const cy: number = h / 2;
    const radius: number = Math.min(w, h) / 2 - RING_WIDTH / 2 - 2;
    const line: number = RING_WIDTH;

    // 底环
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.strokeStyle = Tokens.isDark ? '#2A2A2E' : '#EFEFF2';
    ctx.lineWidth = line;
    ctx.stroke();

    const total: number = this.totalBytes();
    if (total <= 0) {
      return;
    }
    const gap: number = 0.035;
    let start: number = -Math.PI / 2;
    for (let i = 0; i < this.buckets.length; i++) {
      const b: Bucket = this.buckets[i];
      if (b.bytes <= 0) {
        continue;
      }
      const sweep: number = (b.bytes / total) * Math.PI * 2;
      const from: number = start + (sweep > gap * 2 ? gap / 2 : 0);
      const to: number = start + sweep - (sweep > gap * 2 ? gap / 2 : 0);
      ctx.beginPath();
      ctx.arc(cx, cy, radius, from, to);
      ctx.strokeStyle = b.color;
      ctx.lineWidth = line;
      ctx.lineCap = 'butt';
      ctx.stroke();
      start += sweep;
    }
  }

  /** 首屏与每次刷新后重画一次环。 */
  private redraw(): void {
    this.drawRing();
  }

  private async confirmClear(): Promise<void> {
    Haptics.tap();
    AlertDialog.show({
      title: '清理全部缓存',
      message: '会删掉本机的缓存副本、临时文件与设置缓存，电脑上的会话与文件不受影响。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清理',
        fontColor: Tokens.err,
        action: () => {
          const ctx = getContext(this) as common.UIAbilityContext;
          const freed: number = clearCache(ctx);
          // 对话框回调里直接改状态偶发不触发重绘，挪到下一拍再刷新
          setTimeout(() => {
            this.refresh();
            this.redraw();
          }, 80);
          this.getUIContext().getPromptAction().showToast({
            message: freed > 0 ? '已清理 ' + sizeText(freed) : '本来就没有可清理的缓存'
          });
        }
      }
    });
  }

  /** 顶部同色渐变：内容滚上来时在标题下面淡出，替掉原来那块不透明标题栏 */
  @Builder
  topFade() {
    Row()
      .width('100%')
      .height(78)
      .linearGradient({
        angle: 180,
        colors: [[this.themeBg, 0.0], [this.themeBg, 0.58], ['#00' + this.themeBg.slice(1), 1.0]],
      })
      .hitTestBehavior(HitTestMode.None)
  }

  /** 二级页标题行：38 玻璃返回钮 + 标题 + 右侧同款刷新钮，浮在渐变上 */
  @Builder
  pageHeader() {
    Row() {
      Stack() {
        Image($r('app.media.ic_back'))
          .width(20)
          .height(20)
          .fillColor(Tokens.fg)
          .objectFit(ImageFit.Contain)
      }
      .width(38)
      .height(38)
      .borderRadius(999)
      .backgroundColor(Tokens.isDark ? '#3DFFFFFF' : '#8CFFFFFF')
      .backdropBlur(22)
      .border({ width: 1, color: Tokens.isDark ? '#40FFFFFF' : '#D9FFFFFF' })
      .shadow({ radius: 14, color: Tokens.isDark ? '#40000000' : '#26000000', offsetY: 4 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .onClick(() => {
        Haptics.tap();
        this.onExit();
      })

      Text('存储空间')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ left: 12 })

      Blank()

      Stack() {
        Text('\u21bb')
          .fontSize(20)
          .fontColor(Tokens.fg)
      }
      .width(38)
      .height(38)
      .borderRadius(999)
      .backgroundColor(Tokens.isDark ? '#3DFFFFFF' : '#8CFFFFFF')
      .backdropBlur(22)
      .border({ width: 1, color: Tokens.isDark ? '#40FFFFFF' : '#D9FFFFFF' })
      .shadow({ radius: 14, color: Tokens.isDark ? '#40000000' : '#26000000', offsetY: 4 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .onClick(() => {
        Haptics.soft();
        this.refresh();
        this.redraw();
      })
      .accessibilityText('重新统计')
    }
    .width('100%')
    .height(48)
    // 父级 NavDestination 已经有 16/54 的留白，这里只补一点上边距，
    // 标题才能和设置页其它二级页（通知/外观/连接）停在同一条水平线上
    .margin({ top: 4 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 内容在最底层：顶部留出浮动标题行的高度，底部留出底部导航的高度
      List() {
        ListItem() {
          Column() {
            Text('缓存占用')
              .fontSize(13)
              .fontColor(Tokens.dim)
              .margin({ left: 4, bottom: 8 })

            // 环形卡片
            Column() {
              Stack() {
                Canvas(this.ring)
                  .width(RING_SIZE)
                  .height(RING_SIZE)
                  .onReady(() => {
                    this.redraw();
                  })
                Column() {
                  Text(sizeText(this.totalBytes()))
                    .fontSize(34)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Tokens.fg)
                  Text('本机缓存')
                    .fontSize(13)
                    .fontColor(Tokens.dim)
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Center)
              }
              .width(RING_SIZE)
              .height(RING_SIZE)
              .margin({ top: 14 })

              // 图例
              Row() {
                ForEach(this.buckets, (b: Bucket) => {
                  Row() {
                    Circle()
                      .width(7)
                      .height(7)
                      .fill(b.color)
                    Text(b.name)
                      .fontSize(12)
                      .fontColor(Tokens.dim)
                      .margin({ left: 5 })
                  }
                  .margin({ right: 12 })
                }, (b: Bucket) => b.key + ':' + b.bytes)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .margin({ top: 10 })

              Divider()
                .color(Tokens.lineSoft)
                .margin({ top: 12, bottom: 10 })

              Row() {
                Text('设备可用空间')
                  .fontSize(14)
                  .fontColor(Tokens.dim)
                Blank()
                Text(this.deviceText())
                  .fontSize(14)
                  .fontColor(Tokens.fg)
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 14 })
            .backgroundColor(Tokens.surface)
            .borderRadius(Tokens.rGroup)
            .clip(true)

            Text('分类')
              .fontSize(13)
              .fontColor(Tokens.dim)
              .margin({ left: 4, top: 18, bottom: 8 })

            // 分类列表
            Column() {
              ForEach(this.buckets, (b: Bucket, i: number) => {
                Column() {
                  Row() {
                    Stack() {
                      Text(this.glyphOf(b.key))
                        .fontSize(15)
                        .fontColor(b.color)
                    }
                    .width(34)
                    .height(34)
                    .borderRadius(10)
                    .backgroundColor(this.tintOf(b.key))

                    Column() {
                      Text(b.name)
                        .fontSize(15)
                        .fontColor(Tokens.fg)
                      Text(b.hint)
                        .fontSize(12)
                        .fontColor(Tokens.dim)
                        .margin({ top: 2 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    .margin({ left: 12 })

                    Text(sizeText(b.bytes))
                      .fontSize(14)
                      .fontColor(Tokens.dim)
                    Text('›')
                      .fontSize(18)
                      .fontColor(Tokens.dim2)
                      .margin({ left: 6 })
                  }
                  .width('100%')
                  .height(58)
                  .padding({ left: 14, right: 14 })
                  .onClick(() => {
                    Haptics.soft();
                    this.detailKey = b.key;
                    this.detailOn = true;
                  })

                  if (i < this.buckets.length - 1) {
                    Divider()
                      .color(Tokens.lineSoft)
                      .margin({ left: 60 })
                  }
                }
              }, (b: Bucket) => b.key + ':' + b.bytes)
            }
            .width('100%')
            .backgroundColor(Tokens.surface)
            .borderRadius(Tokens.rGroup)
            .clip(true)

            // 清理全部
            Row() {
              Text('清理全部缓存')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.err)
            }
            .width('100%')
            .height(52)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Tokens.surface)
            .borderRadius(Tokens.rGroup)
            .margin({ top: 14 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
            .onClick(() => {
              this.confirmClear();
            })

            Text('缓存只是加速用的本地副本，清掉不影响电脑上的任何数据；配对与主题也在缓存里，清完不用重新配对。')
              .fontSize(12)
              .fontColor(Tokens.dim)
              .lineHeight(18)
              .margin({ top: 8, left: 4, right: 4 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 66, bottom: 120 })
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)

      // 同色渐变：滚上来的卡片在标题下面淡出，不再有硬边遮罩
      this.topFade()

      // 浮动的玻璃返回钮 + 标题 + 刷新钮
      this.pageHeader()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
    .bindSheet($$this.detailOn, this.detailSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      backgroundColor: Tokens.bg,
      onDisappear: () => {
        this.detailOn = false;
      }
    })
  }

  private deviceText(): string {
    if (this.device.total <= 0) {
      return '--';
    }
    return sizeText(this.device.free) + ' / ' + sizeText(this.device.total);
  }

  private glyphOf(key: string): string {
    if (key === 'chat') {
      return '≡';
    }
    if (key === 'img') {
      return '▣';
    }
    if (key === 'tmp') {
      return '◷';
    }
    return '▤';
  }

  private tintOf(key: string): string {
    if (key === 'chat') {
      return Tokens.isDark ? '#1F2F6BFF' : '#152F6BFF';
    }
    if (key === 'img') {
      return Tokens.isDark ? '#1FF2B230' : '#1AF2B230';
    }
    if (key === 'tmp') {
      return Tokens.isDark ? '#1F3ED598' : '#1A3ED598';
    }
    return Tokens.isDark ? '#1FA07CF0' : '#1AA07CF0';
  }

  @Builder
  detailSheet() {
    Column() {
      Text(this.bucketOf(this.detailKey) === null ? '明细' : (this.bucketOf(this.detailKey) as Bucket).name)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ top: 6, bottom: 2 })
      Text('按大小排，最多列 30 项')
        .fontSize(12)
        .fontColor(Tokens.dim)
        .margin({ bottom: 10 })

      List() {
        ForEach(this.detailRows(), (it: string) => {
          ListItem() {
            Column() {
              Row() {
                Text(it)
                  .fontSize(13)
                  .fontColor(Tokens.dim)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .padding({ top: 9, bottom: 9 })
              Divider().color(Tokens.lineSoft)
            }
          }
        }, (it: string, i: number) => it + i)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, bottom: 20 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 明细行文案：`相对路径 · 大小`。 */
  private detailRows(): string[] {
    const b: Bucket | null = this.bucketOf(this.detailKey);
    const rows: string[] = [];
    if (b === null) {
      return rows;
    }
    const limit: number = Math.min(b.items.length, 30);
    for (let i = 0; i < limit; i++) {
      const p: string = b.items[i].path;
      const cut: number = p.lastIndexOf('/');
      const tail: string = cut >= 0 ? p.slice(cut + 1) : p;
      rows.push(tail + ' · ' + sizeText(b.items[i].size));
    }
    if (rows.length === 0) {
      rows.push('这一类现在是空的');
    }
    return rows;
  }
}
