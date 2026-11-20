# 从零构建这套东西

这篇是照着做就能跑起来的步骤。分两块：电脑端的 DSH 插件（`packages/dsh-mobile`），
手机端的鸿蒙 App（`remote/app-shell`）。两块可以分开构建，互不依赖。

---

## 0. 需要装什么

| 东西 | 用途 | 本机路径/版本 |
|---|---|---|
| Node.js 22+ | 跑插件构建、跑 DSH 宿主 | `D:\software\DevEco Studio\tools\node`（用 DevEco 自带的也行） |
| pnpm 或 npm | 装插件依赖 | 包内直接用 `npm install` 即可 |
| DevEco Studio | 编鸿蒙 HAP，自带 SDK 和 hvigor | `D:\software\DevEco Studio` |
| hdc | 装包、看日志、截图 | `D:\software\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe` |
| 手机/模拟器 | 运行 App | 真机开「无线调试」，或启动模拟器 |

---

## 1. 构建电脑端插件

```powershell
cd <repo>\packages\dsh-mobile

# 只装一次（首次或 package.json 变了才需要重跑）
npm install --no-audit --no-fund --legacy-peer-deps

# 每次改完源码都要重新构建
npm run build
```

产物：

- `lib/index.js`：宿主侧（Node 半边），负责 8901 的 HTTP 服务和配对/面板路由
- `lib/client.js`：DSH 内置 Web UI 里的「设置 → 手机连接」面板

**这一步不重启宿主不生效。** 宿主是把 `lib/index.js` 加载进内存的，
改完必须退出 DSH 再打开；重启不会丢会话（会话日志在磁盘上）。

宿主怎么知道加载哪个包：`%USERPROFILE%\.dsh\profiles\desktop\package.json` 里有一行

```json
"@deepseek-ai/dsh-mobile": "link:/绝对路径/dsh-mobile/packages/dsh-mobile"
```

`link:` 表示直接用本地目录，所以改完源码重新 build 就行，不用发布。

插件自己的开关在 `packages/dsh-mobile/cordis.patch.yml`：

```yaml
- id: mobile
  name: '@deepseek-ai/dsh-mobile'
  config: { port: 8901, host: '::' }
```

改端口就改这里。改完同样要重启。

---

## 2. 构建手机端 App

```powershell
# 清一下磁盘：构一次会占 4 GB 左右，空间不够会报 11017002 Write zip file failed
cd <repo>
python tools\clean_storage.py

# DevEco 的 SDK 与 Node 要给 hvigor 指路（每个新终端都要设一次）
$env:DEVECO_SDK_HOME = 'D:\software\DevEco Studio\sdk'
$env:NODE_HOME      = 'D:\software\DevEco Studio\tools\node'

cd remote\app-shell
node 'D:\software\DevEco Studio\tools\hvigor\bin\hvigorw.js' assembleHap --no-daemon
```

看到 `BUILD SUCCESSFUL` 就成了。**命令退出码是 1 但构建成功是正常的**，
那是 ArkTS 的 WARN 让 hvigor 返回了非零，不是失败。

产物：

```
remote\app-shell\entry\build\default\outputs\default\entry-default-signed.hap
```

---

## 3. 装到设备

模拟器：

```powershell
$hdc = 'D:\software\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
& $hdc -t 127.0.0.1:5555 install -r entry\build\default\outputs\default\entry-default-signed.hap
& $hdc -t 127.0.0.1:5555 shell aa force-stop com.dsh.mobile
& $hdc -t 127.0.0.1:5555 shell aa start -a EntryAbility -b com.dsh.mobile
```

真机（无线调试）：

```powershell
# 手机：设置 → 关于本机 → 连点版本号 → 开发者选项 → 无线调试 → 记下 IP:端口
& $hdc tconn 192.168.1.20:34429
cmd /c "<repo>\remote\install-phone.cmd 192.168.1.20:34429"
```

注意两点：

- 装完第一次 `aa start` 进程常常立刻被杀（hilog 里是 `HandleAppDied`），再 start 一次就好。
- 截图前等 12 秒以上，否则截到的是桌面。

---

## 4. 连起来（配对）

1. 电脑浏览器打开 DSH 内置 Web UI → 设置 → **手机连接**，面板上有二维码和 6 位配对码。
2. 手机 App → 设置 → **配对这台电脑** → 扫码，或手动输入电脑地址 + 6 位码。
3. 连上后手机记住的是「局域网优先、公网兜底」：在家走 `http://192.168.1.10:8901`，
   在外面自动退到公网地址。

公网入口不是必须的。要用就在电脑上起一条隧道，把 8901 暴露出去（本项目用的是
cloudflared 的快速隧道），然后在面板的「公网访问」里填那个 https 地址。

---

## 5. 改代码时怎么验证

```powershell
# 应用日志（一次性 dump，不要用 -T，会挂住）
& $hdc -t 127.0.0.1:5555 shell "hilog -x" | Select-String 'DSH_'

# 截图
& $hdc -t 127.0.0.1:5555 shell "snapshot_display -f /data/local/tmp/x.jpeg"
& $hdc -t 127.0.0.1:5555 file recv /data/local/tmp/x.jpeg .\x.jpeg

# 点按钮 / 输入文字（坐标从 dumpLayout 里取，不要按截图估）
& $hdc -t 127.0.0.1:5555 shell "uitest dumpLayout -p /data/local/tmp/l.json"
& $hdc -t 127.0.0.1:5555 shell "uitest uiInput click 400 969"
& $hdc -t 127.0.0.1:5555 shell "uitest uiInput inputText 650 2644 'hello'"
```

插件侧不用重启也能验：`packages/dsh-mobile/temp/harness.mjs` 会在 8902 上把路由全跑一遍。

```powershell
cd <repo>\packages\dsh-mobile
node temp\harness.mjs
```

---

## 6. 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `11017002 Write zip file failed` | C 盘满 | 先 `python tools\clean_storage.py` |
| 构建成功但退出码 1 | ArkTS WARN | 忽略，看有没有 BUILD SUCCESSFUL |
| 装完点开是桌面 | 应用被系统杀掉 | 再 `aa start` 一次，等 12 秒 |
| 改插件没反应 | 宿主还在跑旧的 `lib/index.js` | 退出 DSH 重开 |
| 手机在外面连不上 | 电脑地址被存成了局域网 IP | 设置 → 连接 → 隧道域名填公网地址，保存并重连 |
| 面板 401 | 面板走 Web UI 的登录态 | 只能在浏览器里从 DSH 页面打开，不要直接 curl 17325 |
| 状态栏挡住顶栏 | App 是 `setWindowLayoutFullScreen(true)` | 自绘顶栏自己留 `padding({ top: 46 })` |
