# DSH Mobile

用手机远程控制本机的 [DeepSeek Harness](https://github.com/deepseek-ai)（DSH）：在鸿蒙手机上收发消息、看流式回复、传图片和文件、切换模型，跟坐在电脑前一样用。

它由两部分组成：

| 部分 | 是什么 | 位置 |
|---|---|---|
| `packages/dsh-mobile` | DSH 插件（Node 侧）。在本机起一个 HTTP 网关，把 DSH 的会话能力暴露成移动端 API，并在 DSH 的「设置」里加一个「手机连接」面板（二维码 + 6 位配对码）。 | `packages/dsh-mobile` |
| `remote/app-shell` | 鸿蒙客户端（ArkTS / ArkUI）。会话列表、聊天页、设置与配对向导，包名 `com.dsh.mobile`。 | `remote/app-shell` |

两端通过同一台电脑上的网关通信。手机和电脑在同一个局域网时走局域网直连；不在同一局域网时可以给网关套一层公网隧道（例如 cloudflared），在 App 的「设置 → 连接」里填隧道地址即可。

## 它能做什么

- 会话列表：置顶、归档、多选、重命名、下拉刷新，运行中的会话有状态标记
- 聊天：流式回复、Markdown、代码块、表格、图片、数学公式、消息复制
- 发附件：图片和文件都先挂成待发送胶囊，和文字作为同一条消息一起发出
- 生成中再发消息：进入「待发送」停泊区，可以改、删、插队
- 模型切换：按 provider 分组的模型目录，可指定推理强度
- 手机拍照或选图时自动上传到电脑，保存在 `~/.dsh/mobile-uploads/<日期>/`
- 任务完成通知：会话跑完一轮时手机收到一条通知，点开直达会话
- 配对与访问控制：6 位配对码 / 二维码，局域网与公网访问可分别开关，猜码有节流与锁定

## 直接安装（不构建）

`release/` 目录里放了打包好的 HAP：

| 文件 | 说明 |
|---|---|
| `dsh-mobile-1.0.0-20261120-signed.hap` | 已签名，但签名 profile 只授权了作者登记过的设备，换手机装会验签失败 |
| `dsh-mobile-1.0.0-20261120-unsigned.hap` | 未签名，用自己的证书签完就能装 |

```bash
hdc install -r release/dsh-mobile-1.0.0-20261120-signed.hap
```

装不上就照 [`release/README.md`](release/README.md) 里的两种签名方式重签一次。安装包内不含任何服务器地址或令牌，首次启动直接进配对向导。

## 从源码构建

### 1. 装插件并重启 DSH

```bash
git clone https://github.com/hyfdracula/dsh-mobile.git
cd dsh-mobile/packages/dsh-mobile
npm install --no-audit --no-fund --legacy-peer-deps
npm run build
```

把插件挂进 DSH 的 profile（`~/.dsh/profiles/<name>/package.json`）：

```json
{
  "dependencies": {
    "@deepseek-ai/dsh-mobile": "link:/绝对路径/dsh-mobile/packages/dsh-mobile"
  }
}
```

然后重启 DSH。插件默认监听 `8901`，配置写在 `cordis.patch.yml`：

```yaml
- id: mobile
  name: '@deepseek-ai/dsh-mobile'
  config: { port: 8901, host: '::' }
```

### 2. 配对

DSH 的「设置 → 手机连接」面板里会显示二维码和 6 位配对码（15 分钟有效，用过即换）。手机 App 首次启动会直接进配对向导：扫码，或者手输电脑地址 + 6 位码。

### 3. 构建并安装手机端

需要 DevEco Studio 与 HarmonyOS SDK（`compatibleSdkVersion` / `targetSdkVersion` 均为 `26.0.0`，因为用到了 API 26 的沉浸光感材质）。

```bash
cd dsh-mobile/remote/app-shell
# 用 DevEco 打开工程，先配置签名（Build > Generate Key and CSR，或 Signing Configs）
hvigorw assembleHap --no-daemon
```

产物在 `entry/build/default/outputs/default/entry-default-signed.hap`，用 `hdc install` 装到手机或模拟器。

更完整的构建与调试说明见 [docs/BUILD.md](docs/BUILD.md)，开发交接笔记见 [docs/HANDOFF.md](docs/HANDOFF.md)。

## 安全说明

- 网关默认只绑定本机，令牌保存在 `~/.dsh/dsh-mobile.json`（权限 0600）。没有令牌的请求一律 401。
- 配对码 6 位、15 分钟过期、用后轮换；连续猜错 8 次锁定 5 分钟。
- 「允许局域网连接」与「允许公网访问」是两个独立开关，默认都开；关掉公网开关后，从非内网地址来的请求会被拒绝（按 Host 判断，兼容隧道反代）。
- 把网关暴露到公网请只走 HTTPS 隧道，并考虑给隧道加一层身份校验。

## 已知限制

- 手机端只做了鸿蒙（ArkTS），没有 iOS / Android 客户端。
- 会话归档在「该会话正有一轮在跑」时会失败并返回 500，需要等这一轮结束。
- 桌面 Web 端的「手机连接」面板只在 DSH 内置 Web UI 里可用（走会话鉴权，直接 curl 会 401）。

## 许可证

MIT，见 [LICENSE](LICENSE)。
