# v3.1.0（自 v3.0.0 以来的完整更新说明）

版本区间：`v3.0.0`（2026-11-26） -> `v3.1.0`（2026-11-27）
版本号统一升级至 **3.1.0**（鸿蒙客户端 `versionCode 3001000`，桌面网关插件 `dsh-mobile-connect@3.1.0`）。
本版把开发仓 `dsh-mobile-dev` 从 3.0.1 到 3.0.16 的全部改动并入正式仓。

---

## 一、双模式交互动效引擎（灵动 / 经典）

- **「交互动效」双档实时切换**（设置 → 外观与交互，默认灵动，零重启生效）。
- **经典档（基础动效）**：`springMotion` 物理弹簧、首页首屏前 8 张卡片阶梯错峰入场、浮层/菜单/沉底球/新消息气泡非对称弹簧出入场、`NumericTextTransition` 数字翻滚（上下文百分比、未读计数、多选计数）。
- **经典档补充 P1 视效**：`HdsVisualComponent` AI 思考蓝青双边流光（回复等待气泡与输入框边缘，生成结束自动停止释放 GPU）、`geometryTransition` 共享元素一镜到底（缩略图/待发图 ↔ 全屏看图、会话页搜索圆钮 ↔ 展开搜索栏）、`SymbolGlyph + SymbolEffect` 矢量图标形变（发送/停止、加号/关闭、复制/已复制、思考折叠箭头、沉底球、新建按钮）。
- **灵动档（旗舰动效，3.0.7 确立架构，3.0.11 至 3.0.16 定稿）**：
  - 设置页景深虚化卡片栈：点选任意设置项，底层设置页同步高斯模糊（18vp）与景深缩退（0.945x），上方浮现可拖拽圆角半模态卡片，下拉手势实时反算底层虚化与缩放；二级页面 30% 左右视差推拉、56%~84% 弹簧高度自适应。
  - 全设置页实体分段弹性滑块（`SlidingSegment`）：主题、交互动效、正文字号、连接策略、提问优先端统一为凹槽轨道 + 弹簧滑移胶囊。
  - 锚点下拉卡（`PopupPicker`）替换主题、交互动效、正文字号、连接优先策略、回答者、反馈类型等全部选择控件。
  - 顶层液态玻璃弹簧 Toast（`GlassToastHost`），切换档位支持原地形态热转换。
  - 设置首页与全部设置子页重构为独立单条圆角卡片（取消组内分隔线），`Motion.bloomCard` 逐条瀑布绽放（0.04 → 1.0 纯中心缩放、24ms 错峰）；顶栏标题与功能按钮改为右向左横扫入场，统一欠阻尼 `springMotion(0.54, 0.80)`（约 1.5% 过冲、约 780ms 稳定）。
- **聊天输入与键盘（3.0.16）**：`SafeArea` 引用计数令牌管理 `KeyboardAvoidMode.NONE`，`ChatPage` 过滤 `TYPE_KEYBOARD` 避让并配合 `ChatHelpers.clampKeyboardByContainer` 几何兜底，彻底消除键盘双重避让；键盘弹起/收起时输入框带动气泡惯性推上（46ms / 34ms 错拍 `scrollTo` + `interpolatingSpring`）；输入框 5 套同色系液态水波纹变体按轮次切换，并新增 `composerGlassEffect` 提升沉浸光感输入框通透度。
- **会话列表无跳变揭示（3.0.14）**：新增首屏摘要本地持久缓存 `dsh_mobile_previews`（最多 80 条），冷加载与共享会话合流入口统一预取首屏摘要后再揭示，消除公网冷启「两行跳三行」的高度跳变与二次闪动。

## 二、设置、路由与视觉定稿

- **默认曜黑分层图标**（设置内可切回冷银瓷白）；冷启动改为无边框透明闪屏，与首页底色无缝衔接。
- **隐私政策 / 用户协议 / 开源组件许可**迁至原生 `bindSheet` + `Mat.sheetOpts`，修复沉浸光感下半屏纯透明透字；全站仅这三份阅读卡与外网访问向导保留底部悬浮卡形态。
- **配对页与反馈页**统一改为鸿蒙原生 `Navigation` + `HdsNavDestination` 路由栈，修复「电脑端准备 ↔ 连接电脑」元素重合、返回键延时弹出与多层切换动画打架。
- **「Agent 引擎与控制台」独立成页**（`AgentEnginesPanel`），新增「电脑端智能体引擎」「预设与控制台」提示气泡，明确电脑端 DSH 是宿主网关、使用多引擎与控制台期间必须保持启动；新建会话选择引擎处同步提示。
- **电脑完整网页控制台 ArkWeb 兼容修复**：默认开启 `wcMobileCompat`，通过 `MutationObserver` 隔离冲突的 `style[data-plugin="dsh-web-mobile"]` 并注入 `ARKWEB_COMPAT_CSS`，修复白屏、侧栏布局与抽屉容器异常。
- **细节修复**：移除聊天气泡蓝色文字、对齐会话页与聊天页顶栏控件（46）、输入框沉浸点光源按压微光、会话页 `···` 菜单开放全部 4 项预设与控制台入口。

## 三、通知精确化与后台推送

- **回合精确化（阶段 A）**：桌面网关新增 `NotifyMonitor` 与回合投影 `lastTurnId` / `lastTurnStatus` / `lastDoneAt`，仅响应真实 `running -> false` 与新完成回合；彻底消除会话重命名、置顶、同步导致的误报，以及回到前台瞬间在眼前延迟弹横幅的问题。
- **前台通知策略**：关闭「仅在后台提醒」时，前台打开其他页面或聊天也能收到其他会话的完成/提问通知；正在查看或通知点开的目标会话自动静音并清理未读。
- **华为 Push Kit 后台推送（方案 B1）**：客户端 `PushBridge` + `action.ohos.push.listener`，`EntryAbility` 启动仅登记引用，严格延后至同意隐私政策后才激活并获取 Token；通知页新增「推送显示会话标题」（默认开启）与诊断测试卡片。
- **推送合规与防刷**：云端中继新增 `/v1/push/bind`、`/v1/push/revoke` 与 D1 `push_bindings` 表（仅存 SHA-256 摘要、懒建表与 schema 迁移）；`/v1/push/send` 强制 `Authorization: Bearer <relaySecret>`，Worker 侧使用 Web Crypto PS256 鉴权与 D1 限流；客户端用 Asset Store Kit 持久化 `relaySecret`，经 E2EE 传给网关，断开/清除配对时自动注销推送目标。

## 四、反馈与支持

- **应用内在线反馈恢复**：直连 Cloudflare Worker + D1 + R2，支持提交描述与截图/录屏/日志附件、查看回复；隐私政策同步更新。
- **反馈交流 QQ 群**（1131519744）一键复制。
- **电脑端 DSH 面板**恢复默认连接反馈服务，本机持有 `feedback-admin.key` 时自动显示「用户反馈」管理页，可查看工单、R2 附件并回复。
- **插件 3.1.0 新增**「复制给 AI」按钮与深色 `>_<` 新图标。

## 五、桌面网关 3.1.0

- 新增 `src/notify-monitor.ts`（回合去重与推送注册），`/api/presence` 活跃会话上报与 `/api/push/*` 注册/状态/测试接口。
- 多 Agent 引擎统一接入（DSH / Codex / Claude Code / OpenCode / Antigravity），ACP 自动审批、历史会话恢复与断线自愈。
- 插件面板与图标更新（`icon.svg`），反馈页「复制给 AI」入口与「用户反馈」管理页。

## 六、修复清单（3.0.1 - 3.0.16）

- 图标默认值、WebConsole 白屏与布局、LegalSheet 透字、通知误报与延迟横幅、键盘双重避让、配对/反馈路由动画打架、`SlidingSegment` 与 `GlassToastHost` 冲突、`ExtrasPanel` 顶栏重建、会话列表摘要跳变、设置页分隔线与卡片入场时序。

---

## 安装与升级说明

- **鸿蒙客户端**：下载附件 `dsh-mobile-3.1.0-signed.hap`（6,989,872 字节，SHA-256 `18819F7E480E31D282CFF669A22C64532C6CCA0C96081406B6896BD1E684F3B2`），bundle 名 `com.dsh.mobile`，使用开发调试证书签名（签名 profile 仅授权作者登记过的设备，其他设备请按 [`release/README.md`](README.md) 重签）。
- **与 3.0.0 的关系**：同为 `com.dsh.mobile`，可直接覆盖升级。
- **电脑端网关插件（3.1.0）**：
  ```bash
  dsh plugin --profile desktop add dsh-mobile-connect
  # 或
  dsh plugin --profile desktop add github:hyfdracula/dsh-mobile-connect
  ```
