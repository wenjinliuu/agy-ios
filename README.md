# agy-ios

专为 Antigravity CLI（`agy`）打造的原生 SwiftUI iOS 客户端、VPS Bridge 与 Cloudflare Worker Durable Object 中继一体仓库。

与自建后端共享 VPS 本机的 `~/.gemini/antigravity-cli/` 数据目录，做到：
- **与 `antigravity.google` 网页端 100% 互通**：共用同一份 SQLite 对话索引、`.pbtxt` 标题（兼容 `auto-zh-title` 中文标题钩子）与 `transcript.jsonl`。
- **零域名稳定远程访问**：VPS 通过出站 WebSocket 连入 Cloudflare Worker Durable Object（`*.workers.dev`），无需在 VPS 暴露公网端口，也无需购买自定义域名。
- **云端 CI 编译与分发**：iOS 工程通过 [wenjinliuu/ios-ci-workflows](https://github.com/wenjinliuu/ios-ci-workflows) 在 GitHub Actions 自动完成 Build & Test、Live Preview 与 TestFlight 发布。

## 仓库结构

```text
.
├── worker/    # Cloudflare Worker + Durable Object WebSocket Hibernation 中继 (TypeScript)
├── bridge/    # VPS Bridge 服务：读取 agy 数据 + 拉起 stream-json 子进程 (Node 24 + TS)
└── ios/       # SwiftUI 原生 iOS 客户端 (XcodeGen + iOS 26 SDK)
```

## 快速部署指南

### 1. 部署 Cloudflare Worker 中继（`worker/`）

```bash
cd worker
npm install
cp wrangler.jsonc.example wrangler.jsonc
npx wrangler login
npx wrangler deploy

# 配置共享访问密钥（或拆分 CLIENT_AUTH_TOKEN / VPS_AUTH_TOKEN）
npx wrangler secret put AUTH_TOKEN
```

部署完成后你会获得固定地址：`https://agy-bridge.<your-subdomain>.workers.dev`。

### 2. 启动 VPS Bridge（`bridge/`）

需要 VPS 已安装 Node.js 24（内置 `node:sqlite` 与 TS 运行支持）与 `agy` CLI：

```bash
cd bridge
npm install
cp env.example .env
# 编辑 .env：填写 BRIDGE_AUTH_TOKEN（与 Worker 的 AUTH_TOKEN 一致）及 RELAY_WS_URL
npm run check
npm start
```

如需开机自启，可参考 `bridge/systemd/agy-bridge.service.example` 配置 `systemd`。

### 3. 配置 iOS CI 与 TestFlight（`.github/`）

在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 中添加：

- `APPLE_TEAM_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`（`.p8` 私钥全文）
- `AGENT_PREVIEW_PASSWORD`（可选，用于 Live Preview，≥12 位）
