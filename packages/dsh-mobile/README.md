# Agent Mobile Gateway (`agent-mobile-gateway`)

桌面端网关插件：在自选端口（默认 `8901`）暴露统一的多 Agent 远程交互与工作区接口，供 **Agent Mobile** 鸿蒙客户端直接连接。

## 核心能力

- **多引擎调度**：内置 DSH 引擎，并按需探测接入本地 `Codex`、`Claude Code`、`OpenCode` 与 `Antigravity`（`agy acp` / `agy_acp_server`）CLI。
- **端到端加密**：支持标准 `Noise_IK_25519_ChaChaPoly_SHA256` 握手与密文信封传输，全部密码原语基于 Node 原生 `node:crypto`。
- **二维码与一次性配对码**：桌面设置面板提供二维码、6 位 15 分钟有效配对码、已授权设备管理（支持即时撤销）。
- **工作区代理**：受安全边界约束的工作区文件浏览、Git 状态查看、交互式终端与本机开发端口白名单预览。

## 安装与构建

```bash
dsh plugin --profile desktop add link:<repo>/packages/dsh-mobile
npm run typecheck
npm run build
```

## 开源许可

本模块采用 Apache-2.0 许可证，第三方依赖声明见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。
