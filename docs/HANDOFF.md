# dsh-mobile 项目交接（HANDOFF）

> 这份文件是「远控手机端」项目的完整交接单。新会话读它就能接着干，不需要回溯旧会话。
> 最后更新：2026-11-19

## 一、这个项目是什么

把运行在本机的 DeepSeek Harness（DSH）变成可以**用手机远程控制**的服务：

- 服务端：一个 DSH 插件 `@deepseek-ai/dsh-mobile`，跑在本机 8901 端口，暴露会话列表 / 历史消息 / 发消息 / 归档 / 置顶 / 模型切换 / 预设权限 / 图片与文件上传等 HTTP 接口。
- 客户端：一个鸿蒙原生 App（ArkTS），包名 `com.dsh.mobile`，两栏结构（会话 / 设置），风格参照 CubeAgent，配色 DeepSeek 蓝。
- 公网入口：Cloudflare 命名隧道 `https://your-tunnel.example.com`。
- 目标形态：功能对齐作者的控制台 `dsh-console-hm`，但完全自建、互不影响。

## 二、代码位置

| 东西 | 路径 |
|---|---|
| 插件源码 | `<repo>\packages\dsh-mobile\src\index.ts` |
| 设置面板源码 | `packages\dsh-mobile\src\client\index.ts` + `MobileSection.tsx`（React，编到 `lib/client.js`） |
| 插件产物 | `packages\dsh-mobile\lib\index.js`（宿主半边）+ `lib/client.js`（设置面板） |
| 配对页 / 电脑管理页 | `remote\app-shell\entry\src\main\ets\view\PairPage.ets` / `PcPage.ets`，配对协议客户端 `common\Pairing.ets` |
| 插件挂载配置 | `<repo>\packages\dsh-mobile\cordis.patch.yml`（`host: '::'`、`port: 8901`） |
| 手机 App 工程 | `<repo>\remote\app-shell\` |
| 页面代码 | `...\app-shell\entry\src\main\ets\{pages,view,common}\` |
| HAP 产物 | `...\app-shell\entry\build\default\outputs\default\entry-default-signed.hap` |
| 插件日志 | `%USERPROFILE%\.dsh\dsh-mobile.log` |
| 本机 token 文件 | `%USERPROFILE%\.dsh\dsh-mobile.json` |

**访问令牌**（手机 App 里已内置，也可在设置里改）：存在上面 json 里，字段 `token`。

## 三、常用命令

### 构建插件（必须在包目录里跑）
```powershell
Set-Location '<repo>\packages\dsh-mobile'
& '<repo>\node_modules\.bin\tsdown.cmd'
```
在仓库根目录跑会报 `ERROR Error: undefined No input files`。

### 让宿主加载新插件（**不要直接重启**）
```powershell
& '<repo>\remote\request-restart.ps1'
```
它只写一个标记 `%USERPROFILE%\.dsh\dsh-desktop-restart.request`，由每 2 分钟跑一次的官方看门狗在**会话静默后**重启。

**血的教训**：不要用「延迟 N 秒 + `-NoIdleWait`」自己重启，也不要在这轮里 sleep 几十秒等它 —— 看门狗只看会话文件有没有在写，看不出工具正在跑，会把正在执行的命令砍掉（历史上砍断过 9 次）。

### 构建 App
```powershell
$env:DEVECO_SDK_HOME='D:\software\DevEco Studio\sdk'
$env:NODE_HOME='D:\software\DevEco Studio\tools\node'
Set-Location '<repo>\remote\app-shell'
Remove-Item -Recurse -Force 'entry\build\default\outputs\default' -ErrorAction SilentlyContinue
node 'D:\software\DevEco Studio\tools\hvigor\bin\hvigorw.js' assembleHap --no-daemon
```
**必须删掉 outputs 目录再构建**：ArkTS 增量构建会漏掉部分 UI 改动（曾经出现改了渲染仍是旧的）。

### 装到模拟器 / 真机
```powershell
$hdc = 'D:\software\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
& $hdc -t 127.0.0.1:5555 install -r <hap 路径>
& $hdc -t 127.0.0.1:5555 shell aa force-stop com.dsh.mobile
& $hdc -t 127.0.0.1:5555 shell aa start -a EntryAbility -b com.dsh.mobile
```
真机：先 `& $hdc tconn <手机IP>:<端口>`（手机要开「无线调试」，且和电脑同一个 Wi-Fi）。
现成的 `<repo>\remote\install-phone.cmd` 会自动挑设备。

**`aa start` 之后至少等 12–18 秒**再截图/取控件树，否则拿到的是桌面，会被误判成崩溃。

### 截图与点击
```powershell
& $hdc -t 127.0.0.1:5555 shell snapshot_display -f /data/local/tmp/s.jpeg
& $hdc -t 127.0.0.1:5555 file recv /data/local/tmp/s.jpeg <本地路径>
& $hdc -t 127.0.0.1:5555 shell uitest uiInput click <x> <y>
& $hdc -t 127.0.0.1:5555 shell uitest uiInput swipe <x1> <y1> <x2> <y2> <ms>
```
**找坐标用 `uitest dumpLayout -p /data/local/tmp/lay.json` + `file recv` 读 `attributes.bounds`**，不要按降采样截图估（曾经偏 200px 白折腾）。

### 模拟器
```powershell
schtasks /run /tn DshEmulator     # 约 60 秒后 127.0.0.1:5555 可用
```
启动器 `<repo>\remote\start-emu.vbs`：隐藏窗口冷启动，并在前 2 分钟每 3 秒杀一次 `emulator-crash-service.exe`（它会误判「快照启动超时」把正常启动的模拟器杀掉）。

### 隧道
- 守护：`<repo>\remote\cf-tunnel.ps1` + `cf-tunnel.vbs`，启动目录里有副本，挂在 explorer 下，宿主重启不影响。
- token：`...\remote\bin\tunnel-token.txt`（**不要打印到对话里**）
- 健康检查：`curl https://your-tunnel.example.com/health`
- Cloudflare 侧：账号/zone/隧道 id 属本机私有配置，不写进仓库。
- 已踩过的坑：该域名解析到两个边缘 IP，其中一个（`172.67.163.35`）从这条宽带曾完全不通，导致「隧道活着但 HTTP 不通」。客户端已做 3 次重试规避。

## 四、功能现状

### 已完成并验证
- **会话列表**：搜索、工作区筛选、按「置顶 / 今天 / 昨天 / 更早」分组、下拉刷新、左滑置顶·归档、`⋮` 菜单（多选 / 重命名 / 置顶 / 归档 / 复制 ID）、多选批量归档、右下角悬浮新建。
- **聊天页**：历史分页（顶部「加载更早」）、4 秒增量轮询（`since`，每轮只有几百字节）、Markdown（标题/列表/引用/代码块/**表格**/粗体/行内代码）、图片渲染（`/api/attachments/<sha>`）、发送、停止生成、复制消息（长按）、聊天顶部智能体成员条、运行统计弹层、模型切换抽屉（92% 高，分组 + 档位胶囊，无简介文字）、文件与图片上传。
- **智能体团队页**：按会话分组列出子智能体。
- **预设与权限页**：Agent 预设、会话权限切换。
- **设置**：设备卡、外观（深色/浅色/跟随系统 + 触感反馈开关）、连接（局域网/公网、地址、令牌掩码）、公网地址（域名与令牌可改）、数据与缓存、关于；二级菜单 + 220ms 转场。
- **交互**：58 个点击点统一 `clickEffect`；会话卡片按下缩放；列表错峰入场；新消息淡入；统计条随滚动淡出；主要操作有触感反馈（`common/Haptics.ets`）。
- **页面转场（2026-11-19 新增）**：`Navigation.customNavContentTransition` 自制 push/pop —— 新页从右侧整屏滑入，旧页同时左移 12% 并压暗到 0.72，形成前后层叠；pop 反向。时长 340（push）/ 300（pop）ms，缓动 `curves.cubicBezierCurve(0.32, 0.72, 0, 1)`。首页是 Navigation 内容区、`index === -1`、没有 `navDestinationId`，用固定键 `home` 参与。实现见 `common/NavFx.ets` + `pages/Index.ets` 的 `navTransition()`，每个页面在 `NavDestination.onReady` 里注册自己的位移/透明度 setter。两端都必须已注册才自绘，否则退回系统默认。已过一轮 Codex 复审（裁定 FAIL），三条问题已修：`rebuildNav()` 误以为 `getAllPathName()` 第 0 项是首页（实际不含首页，原写法会丢页）、40ms 回填会覆盖用户新压的页面（加 `navRev` 令牌 + 栈非空即放弃）、只校验了 from 端是否注册（改为两端都校验）。
- **重命名（2026-11-20 修好并验证）**：原来 `Api.once()` 只区分 POST / GET，PATCH 被静默降级成 GET → 插件 `/api/sessions/:id` 的 PATCH 路由永远 404。改成 `methodOf()`（POST/PATCH/PUT/DELETE）。列表侧改名、聊天页 ⋯ → 改名两条入口都在模拟器上跑通，服务端日志 `PATCH rename session=... title=...`。
- **列表标题/时间不同步（2026-11-20 修好并验证）**：改名成功后列表仍显示旧标题、时间停在「xx 分钟前」。根因是 `ForEach` 只用 `m.key`（= 会话 id）做复用键，而列表数据来自方法 `this.models()` 现算，子组件的 `row` 不是父级状态变量 → `@Prop` 也不触发更新。修法：行 key 里带上标题/updatedAt/running/pinned（`rowKey()`），内容一变就换 key 重建；`SessionTile.row` 同时改为 `@Prop`。聊天页改名后标题即时更新（`titleNow` 状态），退回列表时靠 `onVisibleAreaChange` 触发一次 `load()` 对齐。
- **新会话首屏红字（2026-11-20 修好并验证）**：新建会话后立刻取消息，宿主那边日志文件还没落盘，先 404 `session log not found`，客户端当成致命错误糊一屏红字，草稿也不清空。改成：命中这个 404 时静默重试（最多 6 次，间隔 500ms），不显示错误；轮询能拿到数据时再清一次 `err`，避免重试次数用完后又红着不消。
- **摘要/条数也要进 key（2026-11-20 修，Codex 复审 P2）**：`loadPreviews()` 是行先渲染完才回填的，`previewOf()/countOf()` 同样是方法求值 → 不进 key 就会一直空白。现在 `rowKey()` 里额外拼了条数和「有无摘要」。
- 当前 HAP **1,145,430 B（2026-11-20 10:30，底部导航改为系统浮岛材质）**，模拟器已验；底部两枚 tab 现在是一整块 `barFloatingStyle` 浮岛（系统沉浸光感材质），聊天页顶栏/底栏用 `backgroundBlurStyle(COMPONENT_THICK, { colorMode })` 补的原生模糊。
- **回滚记录（2026-11-20 09:1x，用户反馈「做的很差，恢复上一版」）**：把 08:2x 那轮「液态玻璃」全部撤掉——`Tokens.glass/glassStrong/glassBar` 回到 90% 不透明的 `#E6171B24`（浅色 `#D9FFFFFF`）、`glassBlur` 30→24、`glassBarRadius` 22→20、`accentGlass` 回 `#1A3B6EF6`；`ChatPage` 里 8 处 `.backgroundEffect(...)` 改回 `.backgroundColor(Tokens.glassBar)`，删掉顶栏 168 高与底栏 250 高的渐变压暗遮罩；`ShellPage.floatingBar()` 删掉 `backgroundBlurStyle(BlurStyle.COMPONENT_THIN)` 与斜向高光层，选中胶囊底色回 `Tokens.accentSoft`；`SessionList` 搜索钮同样回 `backgroundColor`。教训：`backgroundEffect({ brightness, saturation })` 在深色底上会把玻璃渲染成一块发灰的板子，`backgroundBlurStyle(COMPONENT_*)` 跟系统主题不跟应用主题，两者都别再往深色 UI 上用。
- **UI 对齐 CubeAgent（2026-11-20，按用户 14 条反馈）**：
  - 玻璃（**已按用户反馈回滚，见上条**）：曾用 `.backdropBlur(Tokens.glassBlur)` / `backgroundEffect` 做液态玻璃，深色下观感差且压掉文字可读性，现统一为 90% 不透明底色 + 1px 亮边 + 阴影的扁平玻璃。
  - 设置二级页返回不再退应用：SettingsPage.sub 改 @StorageLink('settingsSub')，pages/Index.ets 加 onBackPress() 清这个键并返回 true。
  - 外观页去掉「当前 / 深色 / 浅色」三行说明。
  - 应用图标重做：pp_icon.png 去掉内嵌圆角白卡，白底放大 1.15 倍居中裁回 512（脚本 
emote/temp/mkicon.py）。
  - 列表顶部留白 10 → 34，工作区与搜索不再贴顶。
  - 搜索按钮：searching 时 scale 1.1 + 蓝色光晕 + 弹簧曲线；搜索框从上方滑入淡入。
  - 聊天页：用户气泡改右侧蓝底白字（圆角 20/右下 6、maxWidth 300vp），助手改「头像 + 模型名 + 白卡正文」；顶栏改 Cube 式（圆形玻璃返回 + 标题/模型胶囊 + 统计/更多圆钮）；底栏改「模型 / 运行统计 / 工具」三枚玻璃胶囊 + 输入胶囊（＋、发送↑ 或停止■）+ 免责声明；生成中三点循环动的占位气泡；轮询自适应（生成中 1.2 s、空闲 4 s）。
  - 顶部模型名：目录接口 /api/models?sessionId= 的 current 对没选过模型的会话是 null，此时退到 /api/sessions 行里的 model，用目录里的展示名（labelOf()），否则顶栏只能显示「共 N 条」。
  - 底部 Tab：选中项加蓝色光晕 + 玻璃描边 + spring 缩放（curves.springCurve(0.62, 0.85, 220, 16)），未选中 0.97 缩放；会话卡片按下 0.972 + 光晕 + 弹簧。
  - 通知（要用户开权限）：common/Notifier.ets 用 SOCIAL_COMMUNICATION 通道 + wantAgent 点击回应用；ShellPage 每 3 秒巡检，扫描到「上一轮在跑、这一轮不跑」就发「任务完成」；Api 透传 
unning。模拟器已验通知中心可见、状态栏出图标；横幅受系统通知设置影响，真机待验。
- **配对与面板（2026-11-20，对齐 dsh-console）**：
  - 插件新增配对协议：`GET /api/pair/info`（免鉴权，只暴露名字/版本/端口/局域网地址）、`POST /api/pair/claim`（拿 6 位码换令牌；错码累计 8 次锁 5 分钟；成功后码立即轮换并把本次请求的 Host 当作 base 写回去）、`GET /api/pair/state`、`POST /api/pair/newcode`、`POST /api/pair/config`（`allowLan` / `allowRemote` / `publicUrl` 三项偏好持久化在 token 文件里）。码 15 分钟过期，日志只打 `pair code minted` / `pair code rotated`，**从不打印码值**。
  - 面板路由走宿主 `connection.fetch` 注册（不是自带 http server），前缀 `/api/dsh-mobile/panel`：`GET /state`、`POST /newcode`、`POST /config`、`GET /qr.svg?payload=`（qrcode 动态 import，缺依赖返回 503 而不是崩）。DSH 设置里因此多出「手机连接」一节：二维码 + 6 位码 + 倒计时 + 允许连接/允许异地配对开关 + 局域网直连地址（IPv4 优先）+ 公网地址 + 插件版本。
  - 手机端新增「配对步骤」两页向导（`view/PairPage.ets`）：第 1 步电脑端准备（装插件命令块可复制 → 重启 DSH → 打开面板），第 2 步扫码（`@hms.core.scan.scanBarcode`）或手输 6 位码，连不上时还能手输电脑 IP。
  - 手机端新增「电脑管理」页（`view/PcPage.ets`）：设备卡（名称 + 局域网延迟）、连接信息（电脑 IP / 公网 / 线路 / 会话数 / 重新连接）、忙碌时发送（排队 / 插话）、版本与标识（电脑名 / 插件版本 / 实例 / 端口）、高级（移除此电脑 = 清配置回默认）。
  - **`Api.rebase(base, token)`**：配对成功后必须**改这个对象本身**，因为子组件持有的都是同一个引用，非装饰成员不会随父组件重建刷新；原来在 `Index.saveCfg()` 里 `new Api(...)` 会导致「配对成功但 App 还在用旧地址旧令牌」。
  - **局域网探针要带令牌**：`ensureBase()` 原来探免鉴权的 `/health`，换了令牌后仍判「局域网可用」，随后每个业务请求 401。改成探 `/api/info`（带 Authorization），200 才算这个入口可用。
  - 电脑管理页的「电脑 IP」优先取 `/api/pair/info` 的局域网地址（老插件没有这条路由，失败就退回当前 base，不影响其余字段）。
  - 端到端已在模拟器验过：向导第 1/2 步切换、扫码入口、6 位码 + 手输 IP 配对（`200 PAIR claim`，日志 `DSH_PAIR ok … host=秋风骤的matebook`，配置落盘 `DSH_CFG saved`）、电脑管理页全部字段、移除此电脑后重新走局域网（`DSH_BASE lan` + `/api/sessions 200`）。
- **真机验证（2026-11-20 07:2x，HarmonyOS 手机 192.168.1.20:34429，无线调试）**：
  - 装的是同一个 HAP（1,127,812 B），`install-phone.cmd 192.168.1.20:34429` 一次成功。
  - 打字发消息：真机软键盘输入 + 发送 → 右侧蓝气泡、计数「共 1 条」、三点生成中气泡、停止键；约 40 s 后助手回复带 Markdown（列表 + 行内代码）正常渲染。
  - 选图上传：聊天页 ＋ → 系统图片选择器 → 选 1 张 → 应用提示「（来自手机）已保存到这台机器：%USERPROFILE%\.dsh\mobile-uploads\<日期>\<毫秒>-<原名>」→ 回落成一轮对话。
  - 传文件：⋯ 菜单「上传文件」→ 系统文件选择器（下载/微信/华为分享）→ 选 199 KB 的 HAP → 同样落盘并回显路径。
  - 配对：电脑端 6 位码 → 手机「配对这台电脑」第 2 步输入 → 服务端日志 `200 PAIR claim base=http://192.168.1.10:8901 ... local=true`，手机日志 `DSH_PAIR ok` / `DSH_CFG saved base=http://192.168.1.10:8901 lan=http://192.168.1.10:8901`，随后 `DSH_BASE lan http://192.168.1.10:8901`，App 从公网切到局域网。
  - 电脑管理页真机正常：电脑 IP 192.168.1.10:8901（新插件按 rank 挑 IPv4）、公网 your-tunnel.example.com、会话数、忙碌时发送、插件版本、端口、移除此电脑。
  - **`uitest` 注不进弹窗里的 TextInput**（重命名 sheet、配对码 sheet）：`uiInput text` / `inputText x y` / 逐个 `keyEvent` 字母码都只留一个空格，真机 IME 的模态窗接管了输入焦点。聊天页主输入框可以注进去（会混入 IME 联想词，如 "phonetest"）。所以「重命名」这类要打字的弹窗只能人工点验，模拟器上已验证通过。
- **网络**：`Api.ensureBase()` 先带令牌探局域网 `/api/info`（1.5 s 超时）再回落公网隧道；失败重试 3 次。

### 已知限制
- **删除会话只能映射成归档** —— 宿主没有删除 API（查过 `dsh-console-hm`，0 处命中）。
- 摘要只取前 40 个会话、只读日志尾部 96KB；工具输出多的大会话摘要可能为空。
- **模拟器验不了的**：打字发消息（无输入法）、选图/选文件（相册为空）、振动（无马达，报 `Device operation failed`）、动效手感（软件渲染）、公网隧道。（2026-11-20 补：`uitest uiInput inputText` 能注入文字，可以验发送流程，但验不了真实输入法体验。）
- **空壳会话会赖在列表里**：`POST /api/sessions` 返回的 id 如果一直没发消息，宿主既不落日志、也归档不了 —— `POST /api/sessions/<id>/archive` 报 500 `live sessions and session persistence hold no such session`。列表里表现为一条 `(untitled)`，点进去 404。要根治得改插件（把「查不到会话」当已归档返回 ok，或列表里过滤掉无日志的会话），需要宿主重启。
- **归档活跃会话仍 500**：turn 在跑时 `archive` 直接 500（`the session is active (turn)`），插件 `src/index.ts:1288` 的 cancel-后重试没等到 turn 真正结束。
- 页面 push 转场已改成自定义（见上），模拟器上实测「开始/结束」日志 340–400 ms；模拟器软件渲染会慢 100–160 ms，真机手感待验。

### 2026-11-20 11:4x 一批界面/交互整改（15 条里的 14 条）

- 删除重复：聊天页底部三枚胶囊、设置页「自建控制台…」副标题、关于页「自建替代实现」都删了。
- 列表顶部蓝色渐变去掉（ShellPage 不再调 	opGlow()）。
- 搜索：ic_search.svg 矢量图标居中；点开从顶栏气泡式展开成搜索胶囊，收起有回缩动画。
- 转场：Index.navTransition() 420/380ms、cubicBezierCurve(0.2,0.72,0.32,1)；设置二级页统一右侧滑入。
- 复制按钮：每条消息下方一行「复制」（ic_copy.svg），copyMessage() 走 pasteboard。
- 数学公式：新增 common/TeX.ets（	exToText/looksLikeTex），common/Md.ets 支持 $...$、$...、\(...\)、\[...\]，独立公式居中渲染（ChatPage.mdMath）。
- 待发送停泊区：ChatPage 新增 dock: DockItem[]，生成中按发送先入停泊区，可编辑/删除/插队（steer），本轮结束后自动补发。
- 聊天顶栏四个控件改半透明+背景模糊（Tokens.glassFloat + .backdropBlur(18)）。
- 配对向导文案改成自己的说法：连接电脑 / 第一步 · 在电脑上 / 先把电脑准备好 / 电脑好了，下一步 › / 扫一下就连上。
- 新增 
emote/BUILD.md：插件与 App 的完整构建/装机/配对/排障步骤。
- 删除消息气泡需要插件新增路由 + 重启宿主，用户明确说「不做」，暂缺。


## 五、宿主能力速查（写新接口前先看）

控制器 `ctx.get('sessionController')` 的方法：
`archive / cancel / create / fork / history / list / modelCatalog / page / projections / prompt / rename / selectModel / unarchive / updateQueue / workspaceDesktop`
外加 `pin / unpin`（存在 `workspaceRegistry`）。

**没有**：删除会话、重新生成标题、头像、收藏、分享、多选（多选要在客户端做）。

- 发消息：`ctl.prompt({ requestId, sessionId, mode, content })`，`mode` 空闲用 `steer`、运行中用 `queue`（对空闲会话用 queue 是空操作）。
- 模型目录：`ctl.modelCatalog({ sessionId })` → 层层剥 `value` / `catalog`。
- 选模型：`ctl.selectModel({ sessionId, provider, model, reasoningEffort })`。
- 归档标记在 `workspaceRegistry.archivedSessionIds`，置顶在 `workspaceRegistry.pinnedSessionIds`。

## 六、ArkTS 坑位清单（都踩过）

1. `Scroll { Column }` 的单子元素会被**垂直居中**，长页面必须用 `List { ListItem { Column } }`。
2. `@Builder` **按值传参不触发刷新** —— 要传对象（`$$: Param`）或用 `@Prop`。
3. 普通成员属性父组件后到的数据不同步 —— 用 `@Prop`。
4. `@Builder` 返回 void，不能链式 `.margin()`（报 `Property 'margin' does not exist on type 'void'`）。
5. UI 代码不能写在普通方法里，必须 `@Builder`；方法名不能叫 `mask`（与组件属性冲突）。
6. `backgroundBlurStyle(...)` 跟的是**系统**深浅色，不跟应用自己的调色板 → 深色主题下卡片会变浅灰。已全部改用半透明色值。
7. ArkTS 不支持结构化类型：同形状的两个 interface 也不通用；对象字面量必须对应显式声明的类型。
8. `@Provide` 的属性不能赋给普通属性，要用 `@Consume`。
9. 换主题这类「改全局静态变量」不会自动重绘，需要 `@StorageLink('themeRev')` + `ForEach` 重建，或重建导航栈。
10. `onConsole` 回调必须 `return false`。
11. 图标别用 `Path().commands()` 手画（实机会糊成一坨），改用 SVG 资源 + `fillColor`。
12. `@ohos.curves` **不能具名导入** `curves`（报 `has no exported member 'curves'`），要 `import curves from '@ohos.curves'`。
13. 转场里拿到的 `NavContentInfo`：push 的 `to.index === -1` 表示「首页内容区」，**它没有 `navDestinationId`**，要用固定键；`from.index === -1` 同理。REPLACE / DIALOG 模式不要自绘，直接 `return undefined` 交回系统。
14. 转场不要用 `springMotion`：`springMotion(0.38, 0.92)` 实测 1.1–1.35 s 才停稳（模拟器连拍比对得出），时长不可控；用 `cubicBezierCurve(0.32, 0.72, 0, 1)` + 固定 duration。
15. `springMotion` / `animateTo` 的 `onFinish` 可能因打断触发两次 —— 用布尔位防重复 `finishTransition()`。
16. 验证转场不要只靠截图（`snapshot_display` 单张 240–430 ms，抓不到 340 ms 的中间帧）：在转场里打 `console.info`，用 `hdc shell hilog -x` 读时间戳算真实时长。`hilog` 没有 `-d` 选项（报 `unrecognized option: d`）。
17. 换主题重建导航栈时要把 `clear/pushPathByName` 的 `animated` 传 `false`，否则重建过程会播一串转场。
18. `NavPathStack.getAllPathName()` **不包含首页**（首页是 Navigation 内容区，不在栈里）——按下标 1 开始保存/恢复会丢页；按 0 开始并保持 name/param 同下标。
19. 清栈后延迟回填（`setTimeout` 40ms 让栈稳定）必须做两件事：代次令牌（`navRev`）防过期回调，回填前再查一次栈是否空（用户可能已经点了新页面）。
20. `ForEach` 的 key 必须带上会变的内容。数据是方法现算的（`this.models()`）时，子组件的 `@Prop` **不更新**（`@Prop` 只认父级状态变量），列表就会一直显示第一次渲染的标题/时间。key 里拼上标题与 updatedAt 即可强制重建（`SessionList.rowKey()`）。
21. `http.RequestMethod` 只有显式映射才安全：`method === 'POST' ? POST : GET` 这种写法会把 PATCH 变 GET，且在日志里表现为「路由 404」，极难联想。统一走 `methodOf()`。
22. 新建会话后立刻 `GET /messages` 会 404 `session log not found`（日志文件还没落盘），几百毫秒后就正常 —— 客户端必须把这种 404 当「暂时为空」重试，不能当错误；重试放弃后若轮询成功，记得清 `err`。
23. `loadPreviews()` 这类「行先渲染、数据后到」的回填，同样要把回填内容并进 ForEach 的 key，否则卡片摘要、条数永远空白。
24. `wantAgent.WantAgent` 这个类型**不存在**（编译报 `'wantAgent' has no exported member named 'WantAgent'`）。`getWantAgent()` 的返回值声明成 `object | undefined` 再塞进 `NotificationRequest.wantAgent`。
25. 通知要弹横幅必须走 `notificationSlotType: SOCIAL_COMMUNICATION`（映射 LEVEL_HIGH）；默认通道只进通知中心。权限先 `isNotificationEnabled()` 再 `requestEnableNotification()`，一次就够。
26. 设置二级页的返回要在根页面接管：`SettingsPage.sub` 用 `@StorageLink('settingsSub')` 暴露状态，`pages/Index.ets` 的 `onBackPress()` 读 `AppStorage.get<string>('settingsSub')`，非空就清掉并 `return true`，否则直接退出应用。
27. 玻璃效果用 `.backdropBlur(24)` + 半透明底色，**不要**用 `backgroundBlurStyle`（跟系统主题、不跟应用调色板，深色下会发灰）。
28. `/api/models?sessionId=` 返回的 `catalog.current` 对「没选过模型」的会话是 `null`，不能当唯一来源 —— 顶栏/底栏的模型名要退到 `/api/sessions` 行里的 `model`，再用目录取展示名。
29. 展示名与 id 要分开存：`curModel` 放目录里的 name（给人看），`curModelId` 放 id（给选择器比较）。混用一个字段会让「当前」标记永远不亮，或者顶部显示裸 id。
30. 异步轮询必须带存活标志 + 代次令牌：`aboutToDisappear()` 里 `alive = false; gen++`，每个 `await` 之后先 `if (!alive || g !== gen) return;` 再写状态、再排下一拍；`setTimeout` 重试也要存句柄并清掉。
31. `load()`（全量）与 `pollOnce()`（增量）会并发：增量结果要按 `seq` 过滤掉本地已有的，否则同一条消息出现两次。
32. 通知 id 不能只用 `id.length` 取模（等长 id 会互相覆盖），按字符串算个稳定哈希。
33. 切走设置 Tab 时要清 `settingsSub`，否则隐藏的二级页状态会吞掉当前页面的返回键。
34. `@Builder` 的值传参是**首帧快照**：`stepText(left, right)` 在步骤变了以后还是「第 1 步」，`primaryBtn(text, enabled, tap)` 的「连接中…」永远不刷新。只传静态 kind/id，可变状态在 builder 里读 `this.…`（配合 `btnText(kind)/btnOn(kind)/kvOf(id)` 这类辅助方法）。
35. 对象字面量必须对应显式声明的 interface：`JSON.stringify({ code } as Record<string, string>)` 会触发 `arkts-no-untyped-obj-literals`；写个 `interface CodeBody { code: string }` 就过。
36. `@hms.core.scan.scanBarcode` 可以静态 import（SDK 在 `D:\software\DevEco Studio\sdk\default\hms\ets\api\`），`startScanForResult(context)` 返回 `{ originalValue }`，默认 UI 已带相机授权，不用自己申请。
37. 子组件里的 `api: Api` 是非装饰成员，父组件 `new` 一个新对象**不会**传进去 —— 要么 `rebase()` 就地改，要么改成 `@Provide/@Consume`。同一类问题还会表现成「设置页显示新地址、列表还在用旧地址」。
38. 探活接口不能只探免鉴权的 `/health`：换令牌后它照样 200，会把客户端误导到一条 401 的线路上；要探一个需要鉴权的接口（`/api/info`）。
39. **NavDestination 上别设 .backgroundColor()**：一旦设了不透明底色，子节点里的 ackgroundEffect 就只会糊到那层底色上（等于什么都不糊），玻璃看着像块实心板。底色要画成 Stack 的第一层子节点（Row().width('100%').height('100%').backgroundColor(themeBg)）。
40. ackgroundEffect({ color }) 的 color 在模糊真的生效时几乎看不见（更像降级填充色）。想要「深色磨砂」，靠的是背后内容被压暗：在玻璃下面垫一层与底色同色的渐变遮罩（顶栏 168 高、底栏 250 高，透明度 0.34 / 0.55）。
41. ackgroundBlurStyle(BlurStyle.COMPONENT_*) 跟的是**系统**主题而不是应用主题：应用深色 + 系统浅色时会糊出一块浅灰板，文字不可读，别用。
42. 列表用 padding({ top, bottom }) 会把视口裁掉，正文永远滚不到玻璃底下，背景模糊没有内容可糊；留白要用 ListItem 占位项（顶部 104、底部 200）。

## 七、Shell 层坑位

1. 本 agent 环境里有 `ELECTRON_RUN_AS_NODE=1`，启任何 Electron/IDE 图形程序前要 `Remove-Item Env:ELECTRON_RUN_AS_NODE` 并 detached 启动，否则静默退化成 node（退出码 0、无窗口）。
2. bash/pwsh 里按命令行字符串过滤进程时，**自己的命令行也含这个字符串**，会把自己杀掉（踩过两次，退出码 4294967295）。用 `$PID` 排除。
3. PowerShell 双引号里 `"…/$sid?t=$tok"` 会把 `$sid?t` 当成变量名，URL 被吞 → 显式字符串拼接。
4. 用 PowerShell `-Raw` + `.Replace()` 改源码，锚点没匹配时 `Set-Content` 仍静默成功 → 改完必须 `Select-String` 校验源码，再确认构建产物。
5. `cmd` 批处理只能写纯 ASCII（中文注释会被按 ANSI 解读，报 `'...' is not recognized`）。

## 八、下一步可以做的

1. **重启宿主，让配对与面板真正在 8901 生效**。插件（`lib/index.js` 与 `lib/client.js`）已经构建，宿主是 `link:` 挂的，重启即加载；但 8901 现在跑的还是旧代码 —— 用新令牌访问 `/api/pair/info` 仍是 404。重启会掐断当前会话，**必须先问用户**；正确做法是 `remote\request-restart.ps1`（由看门狗在会话静默后重启），不要自己 sleep 等。
2. **真机验证**（最大缺口）：手机开无线调试 → `install-phone.cmd` → 补验 5 项：打字发消息、选图上传、传文件、改名/改地址、动效手感与振动。
3. ~~自定义页面 push 转场~~ —— 已完成（2026-11-19），模拟器已验证，只剩真机手感确认。
4. 通知横幅在真机上的表现与点击跳转（wantAgent）。
5. 分发给别人用的方案（**尚未定，等讨论**）：见下。

## 九、给别人用需要什么（已与用户讨论，方向已定）

**用户核心要求（2026-11-19 晚）**：别的用户操作要尽量简洁，面向小白。

**讨论后确定的目标形态**：把用户操作压到 **2 步** —— 双击安装包走下一步、手机扫一个二维码。其余全部自动。

**安装器要自动做的事**
1. 检查/静默安装 DSH 宿主
2. 把插件装进用户 profile（需要把 `packages/dsh-mobile` 打包成可安装的 npm 包，一条 `dsh plugin add`，而不是现在的本地 link）
3. 写启动项，保证开机后服务在跑
4. 起服务后生成一次性配对码，在屏幕上铺二维码
5. 手机 App 首启只有一个「扫一扫」按钮，扫完自动拿到地址 + 令牌

**关键决策：默认只走局域网**
- 不注册 Cloudflare、不建隧道、不碰路由器。同一 Wi-Fi 下直连电脑 IP（9 ms）。
- 外网做成安装器里的勾选框（默认关）：勾上则自动起 **Cloudflare 快速隧道**（`cloudflared tunnel --url`，**不需要注册账号**，直接给 https 域名）。二维码里同时带局域网与外网地址，App 两个都存、自动择优（客户端 `Api.ensureBase()` 已实现先探局域网再回落公网）。
- 已知代价：快速隧道域名每次重启会变，人在外面时可能连不上，需要回家重扫。要彻底稳定就得上命名隧道（需注册 Cloudflare）或自建 frps（需 VPS）。

**三个卡点**
| 卡点 | 影响 | 解法 |
|---|---|---|
| HAP 装机 | 装了才能用 | AppGallery Connect 邀请测试（免费），发测试链接 |
| 外网域名漂移 | 在外面偶尔连不上 | 默认局域网；要稳定需注册 CF 或自建服务器 |
| 安全 | 别人电脑暴露 | 每设备独立令牌 + 配对绑定 + 可吊销 |

**建议推进顺序（用户已听，尚未拍板动手）**
1. 先做局域网版的「双击安装 + 扫码配对」（80% 价值，不依赖任何账号与云服务）
2. 找 2–3 个熟人跑通验证
3. 再决定是否为外网加 Cloudflare 自动化与 AGC 上架

**其它已确认的事实**
- 现在的 APP 分发卡在 HarmonyOS 签名：调试证书 profile 绑定设备 UDID（当前只认 3 台），换机装不上；正式分发必须 AGC 邀请测试或上架。
- 现有隧道用的是买来的 Cloudflare 账号（`4lgv1u55@sunix.eu.org`），有被回收风险；已建议换成用户自己邮箱注册的账号（用户自己在浏览器登录、我接手建隧道与绑域名，或直接给我凭据）。用户尚未决定。
- 安全现状：单共享令牌、无本地 TLS 终止、无限流无审计，给别人用之前必须补。
43. 底部导航想做成「一条连起来的胶囊」，正解是 `Tabs(...).barFloatingStyle({ barWidth: { smallBarWidth: 288, mediumBarWidth: 288, largeBarWidth: 288 }, barBottomMargin: 18, systemMaterial: Mat.bar() })`（API 26）——底板和材质由系统画一整块，两个 `tabBar` 只是里面的内容，天然没有接缝。不要用「两块 tabBar 各挂 systemMaterial 再拼在一起」：材质每块各画一圈边缘，中间会留一道亮缝。`barWidth` 不吃百分比，只能给具体长度（按屏宽 320vp 算）。
44. 沉浸光感材质跟的是**应用色彩模式**，不是我们自己的 Tokens：`getContext().getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK)` 之后材质才会变深色。不设的话，深色界面里会糊出一块浅色玻璃板（看着像坏了）。`applyTheme()` 里跟着 `resolveDark()` 一起切即可。
45. 想给自绘的浮动顶栏也上系统材质是走不通的：`NavigationTitleOptions.systemMaterial` 在「全屏沉浸 + 自定义 title builder」组合下不画底板（带不带 `backgroundColor: Color.Transparent` 都一样），内容会直接从标题栏背后穿过、和文字打架。自绘顶栏要么退回扁平玻璃，要么单独用 `backgroundBlurStyle(..., { colorMode })` 补一层原生模糊。


## 2026-11-20 12:0x 底栏/浮层/二级页一轮

- 底栏：去掉蓝色选中胶囊，只让选中的图标与文字变蓝；按压给一层 26% 白高亮 + scale 0.82 spring(0.42,0.62) 弹回；系统沉浸光感仍由 `Tabs.barFloatingStyle({ systemMaterial })` 一整块画。
- 列表页顶部（工作区胶囊 / 会话统计 / 搜索）抽成 `headerBlock()`，浮在列表上、半透明 + backdropBlur(18)；列表首项留 118 高占位，滑动时内容从头部底下穿过。
- 列表页 ＋ 改成毛玻璃（glassFloat + blur + 1px 亮边）。
- 搜索胶囊下移：`margin({ left:16, right:16, top:34 })`，底色 glassFloat + backdropBlur(18)。
- 设置二级页：根页常驻淡出 + 二级页整页从右滑入（380ms spring），顶部左上角统一为「设置」小字 + 页名大字；`PcPage.backRow` / `PairPage.backRow` / `SettingsPage.subHeader` 三处一致。
- 当前 HAP 1,235,033 B（12:12 构建），装机 127.0.0.1:5555；深色/浅色两套均已截图核对。重命名弹窗打开时会把底部 Tab 收起（AppStorage sheetOpen），弹窗与蒙层盖全屏。

