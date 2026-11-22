# v1.1.17

只改新手引导里的一句话：插件已经发到 npm 了。

## 连接电脑 → 新手引导 的第一步

以前写的是「下载 zip 解压，选目录」，现在改成两条路并列：

1. **电脑上有 npm（最省事）**：一条命令就装好，命令块里的「复制」直接给就是这条
   ```
   dsh plugin --profile desktop add dsh-mobile-connect
   ```
2. **没有 npm**：在 App 发布页下载 `dsh-mobile-plugin-*.zip` 解压，打开 DSH 侧栏
   「插件 → 添加插件」，选解压出来的那个目录。

包已在 npm 上验证过：`dsh plugin --profile <profile> add dsh-mobile-connect` 能解析、能写进
profile 的 `cordis.patch.yml`（`- id: mobile-connect`）。

## 说明

- 这一版**只改文案**，配对、消息、文件、局域网那些逻辑没有变动，可以直接覆盖安装。
- 电脑端插件这一版没有新内容；之前「二维码里带多个候选地址」的改动要**重启一次 DSH** 才生效，
  如果还没重启，重启后二维码会同时携带局域网网卡和公网隧道，手机逐个试。
