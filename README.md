# CloudTerminal

用手机远程盯住电脑上的 Claude Code：实时看进度流、在手机上发消息、直接在手机上批准或拒绝权限请求。

```
 手机 App (Flutter, MD3) ──wss──▶ 中继服务器 (公网) ◀──wss── Agent (你的电脑)
                                                              │
                                                              ▼
                                               Claude Agent SDK → claude CLI
```

- **Agent**（`server/src/agent`）跑在电脑上，通过官方 [Claude Agent SDK](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk) 启动和驱动 Claude Code。它**主动连出去**到中继，所以电脑不需要公网 IP、端口映射或改路由器。
- **Relay**（`server/src/relay`）跑在一台有公网地址的服务器上，只负责认证和转发，不解析会话内容。
- **App**（`lib/`）是 Flutter 手机端，UI 风格与 terminax 一致（同一套 MD3 主题）。

## 能做什么

- 实时进度：Claude 的回复逐字流式显示，思考过程、每个工具调用（命令、文件读写、diff、输出）都能展开看
- 权限授权：Claude 要跑命令或改文件时，手机上弹出卡片：**允许 / 始终允许 / 拒绝 / 拒绝并说明原因**
- 回答问题：Claude 用 AskUserQuestion 提问时直接在手机上选；计划模式下可以批准计划开始执行
- 发消息：会话进行中也可以追加指令；随时停止当前任务；切换权限模式
- 新建会话：在手机上浏览电脑目录选择工作目录；也可以继续电脑上的历史会话（包括在终端里开的）
- 断线恢复：网络断了自动重连，按序号补齐错过的事件，不丢进度

## 快速开始

需要 Node.js ≥ 23.6（直接运行 TypeScript）和已登录的 Claude Code（`claude` 能正常使用）。

```bash
cd server
npm install
```

### 方式一：局域网 / 隧道（最简单）

```bash
npm run agent -- --local-relay
```

中继直接跑在 agent 进程里。终端会显示：

```
┌──────────────────── 手机配对 ────────────────────
│ 服务器地址：ws://192.168.1.5:8787/ws
│ 配对码：    K7QM-4XTP   （10 分钟内有效，仅可使用一次）
```

手机和电脑在同一 Wi-Fi 下时，在 App 里填这个地址和配对码即可。出门在外想用这种方式，可以配合 [Tailscale](https://tailscale.com)（手机填电脑的 Tailscale IP）或 Cloudflare Tunnel（`cloudflared tunnel --url http://localhost:8787`，手机填隧道给的 `https://…` 地址）。

### 方式二：公网中继服务器（推荐外出使用）

在服务器上：

```bash
cd server && npm install
RELAY_KEY=一段随机字符串 PORT=8787 HOST=127.0.0.1 RELAY_TRUST_PROXY=1 npm run relay
```

前面放一个 TLS 反向代理，比如 Caddy：

```
relay.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

在电脑上：

```bash
npm run agent -- --relay wss://relay.example.com/ws --relay-key 同一段随机字符串
```

地址和 key 会记住，以后直接 `npm run agent`。手机上填 `relay.example.com` 和配对码。

### Agent 参数

| 参数 | 说明 |
| --- | --- |
| `--relay <url>` | 中继地址，记住供下次使用 |
| `--relay-key <key>` | 中继要求的注册密钥 |
| `--local-relay` / `--port` | 在本进程内跑中继 |
| `--public-url <url>` | 配对横幅里显示给手机的地址 |
| `--root <dir>` | 手机能选的目录范围，可重复，默认用户主目录 |
| `--cwd <dir>` | 新建会话的默认目录，默认当前目录 |
| `--allow-bypass` | 允许手机选择「跳过权限」模式（默认禁止） |
| `--claude-path <p>` | 指定 claude 可执行文件 |
| `--reset-pairing` | 生成新身份，所有已配对的手机都要重新配对 |

运行中在终端按回车会生成一个新的配对码。

### 手机 App

```bash
flutter run            # 连着手机或模拟器
flutter build apk      # Android
```

鸿蒙（`ohos/`）、iOS 工程都已配置网络权限。

## 安全

- **配对密钥等同于这台电脑的操作权限**：拿到它的人能让 Claude 在你电脑上执行命令。密钥保存在电脑的 `~/.cloudterminal/agent.json`（权限 600）和手机的应用私有目录。怀疑泄露就 `--reset-pairing`。
- 中继只保存密钥的 SHA-256，用常量时间比较；认证失败按 IP 限流；配对码 8 位、10 分钟过期、只能用一次。
- 设置 `RELAY_KEY` 后，只有知道 key 的 agent 能注册到你的中继。
- 公网部署务必用 `wss://`（TLS）。`ws://` 只适合局域网。
- 中继运营者（就是你自己）能看到明文会话内容；v1 没有做端到端加密。
- 默认不允许 `bypassPermissions`；手机只能访问 `--root` 范围内的目录。

## 开发

```bash
cd server
npm run check      # tsc 类型检查
npm test           # relay / agent 单元与集成测试
npm run demo       # 中继 + 脚本化的假 Claude，不消耗额度，适合调 UI
npm run e2e        # 真实 Claude 端到端冒烟测试（会消耗少量额度）

cd ..
flutter analyze
flutter test       # 含一个 Dart ↔ Node 的真实 WebSocket 集成测试
```

协议定义在 `server/src/shared/protocol.ts`，Dart 端镜像在 `lib/models/protocol.dart`，设计文档见 `.trellis/tasks/10-01-remote-console/design.md`。

## 与官方 Remote Control 的区别

Claude Code 自带 `claude --remote-control`，可以在 claude.ai / Claude 官方 App 里接管会话。CloudTerminal 是自托管的替代方案：中继在你自己的服务器上，手机端可以按自己的需要定制。
