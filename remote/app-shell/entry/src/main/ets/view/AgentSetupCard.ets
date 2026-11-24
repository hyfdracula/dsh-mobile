import pasteboard from '@ohos.pasteboard';
import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { Toast } from '../common/Toast';

/** 给用户复制给 AI 的一段配置说明：目标是让 agent 在电脑上把外网访问配好。 */
const PROMPT: string[] = [
  '我在电脑上装着 DeepSeek Harness（DSH），手机端 dsh-mobile 需要在外网连到它。请在我的电脑上完成下面几步，最后只输出两行结果。',
  '',
  '1. 安装并启用 dsh-mobile 插件（默认监听 127.0.0.1:8901），确认 curl http://127.0.0.1:8901/health 返回 ok。',
  '2. 安装 cloudflared（Windows: winget install Cloudflare.cloudflared；macOS: brew install cloudflared）。',
  '3. 用我的 Cloudflare 账号登录并创建命名隧道：cloudflared tunnel login，然后 cloudflared tunnel create dsh-mobile。',
  '4. 给隧道加 DNS 路由：cloudflared tunnel route dns dsh-mobile dsh-mobile.<我的域名>。',
  '5. 安装成服务并启动：cloudflared service install <隧道 token>。',
  '6. 用公网地址访问 /health，确认返回 ok。',
  '',
  '插件访问令牌在电脑的 ~/.dsh/dsh-mobile.json 的 token 字段（也可以从 DSH 的「设置 → 手机连接」面板里读）。',
  '最后只输出两行，不要别的解释：',
  '地址: https://dsh-mobile.<我的域名>',
  '令牌: <这个 token>'
];

/**
 * 「让 AI 帮你配外网」：把这段说明复制给用户自己的 agent，由它在电脑上装插件与隧道。
 * 账号与域名仍由用户自备；App 只负责把要求讲清楚，不内置任何密钥。
 */
@Component
export struct AgentSetupCard {
  @State private copied: boolean = false;

  private copyAll(): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, PROMPT.join('\n'));
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.copied = true;
      Haptics.tap();
      Toast.ok('已复制，粘贴给你的 AI');
      setTimeout(() => {
        this.copied = false;
      }, 1800);
    } catch (e) {
      Toast.err('复制失败：' + (e as Error).message);
    }
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('让 AI 帮你配')
            .fontSize(15)
            .fontColor(Tokens.fg)
          Text('把下面这段复制给你的 AI（Codex / Claude / 任意 agent），它在电脑上装好插件和隧道，再把两行结果填回这里')
            .fontSize(12)
            .fontColor(Tokens.dim2)
            .margin({ top: 3 })
            .lineHeight(17)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Text(PROMPT.join('\n'))
        .fontSize(11)
        .lineHeight(16)
        .fontColor(Tokens.dim)
        .fontFamily('monospace')
        .width('100%')
        .maxLines(6)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .backgroundColor(Tokens.surface2)
        .borderRadius(12)
        .padding(10)
        .margin({ top: 10 })

      Row() {
        Text(this.copied ? '已复制' : '复制给 AI')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accentInk)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(Tokens.accent)
          .borderRadius(999)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            this.copyAll();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 8 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 12 })
    .backgroundColor(Tokens.surface)
    .borderRadius(Tokens.rGroup)
    .clip(true)
    .margin({ top: 12 })
  }
}
