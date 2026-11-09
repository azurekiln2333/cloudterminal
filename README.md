# CloudTerminal

电脑上运行终端，手机连接并控制同一个会话。支持 PowerShell / Shell，以及其中运行的 Codex、Claude Code、Gemini CLI、构建工具等命令行程序；同时保留 Claude 的结构化会话与权限卡片。

```
 手机 App (Flutter, MD3) ──wss──▶ 中继服务器 (公网) ◀──wss── Agent (你的电脑)
                                                              │
                                                              ▼
                                               PTY → PowerShell / Shell / CLI
                                               Claude SDK → 结构化 Claude 会话
```

- **Agent**（`server/src/agent`）跑在电脑上，用真实 PTY 启动终端；Claude 专用模式通过官方 SDK 驱动。它**主动连出去**到中继，所以电脑不需要公网 IP、端口映射或改路由器。
- **Relay** 只负责认证和转发，不解析会话内容。公网中继独立在 [cloudterminal-relay-server](https://github.com/azurekiln2333/cloudterminal-relay-server) 仓库；本仓库保留一份中继核心副本（`server/src/relay/relay.ts` 等），供 Agent 在进程内提供局域网入口。
- **App**（`lib/`）是 Flutter 手机端，UI 风格与 terminax 一致（同一套 MD3 主题）。

## 能做什么

- **通用终端**：手机新建终端，显示 ANSI 颜色、光标和交互界面，发送键盘输入及 Ctrl-C、Tab、Esc、方向键；在 Shell 中运行自己已安装的工具
- **桌面与手机共享**：电脑通过 `--terminal` 启动会话后，手机可以打开同一个终端；手机断开后程序继续运行
- **Herdr 工作区**：电脑上装了 [Herdr](https://herdr.dev) 时，手机可以列出真实的工作区、标签页、面板和 agent，读取面板实时输出，向 agent 发任务、发送按键和运行命令，并执行新建/重命名/切换/关闭等 Herdr 原生操作
- **Claude 专用模式**（以下结构化功能）：
- 实时进度：Claude 的回复逐字流式显示，思考过程、每个工具调用（命令、文件读写、diff、输出）都能展开看
- 权限授权：Claude 要跑命令或改文件时，手机上弹出卡片：**允许 / 始终允许 / 拒绝 / 拒绝并说明原因**
- 回答问题：Claude 用 AskUserQuestion 提问时直接在手机上选；计划模式下可以批准计划开始执行
- 发消息：会话进行中也可以追加指令；随时停止当前任务；切换权限模式
- 新建会话：在手机上浏览电脑目录选择工作目录；也可以继续电脑上的历史会话（包括在终端里开的）
- 断线恢复：网络断了自动重连，按序号补齐错过的事件，不丢进度

## 快速开始

需要 Node.js ≥ 23.6（推荐 Node 24 LTS）。通用终端不需要 Claude 登录或 AI API；运行某个工具时使用该工具自己的安装和登录状态。Claude 专用模式才需要可用的 Claude Code。`node-pty` 含本机组件，安装需适合当前系统；没有预编译包时需本机编译工具链。

Windows 双击仓库根目录的 **`start.cmd`**。首次会自动安装依赖，并询问本机端口、中继地址（可留空）、注册密钥和工作目录；之后直接双击即可复用。macOS / Linux 使用 `sh start.sh`。

电脑启动后需要保持窗口打开。修改连接信息用 `start.cmd --setup`；不在电脑上接管终端用 `start.cmd --no-terminal`，恢复用 `start.cmd --terminal`，这两项选择都会保存。已有手机配对身份会保留。

### 局域网默认开启，填了中继地址就同时支持外网

**局域网入口始终开启**，不需要任何选择：手机和电脑连同一个网络即可用。
允许防火墙中的 Node/TCP 入站（端口默认 8787，可用 `--port` 改）。

**如果同时填了中继地址，两个入口会一起工作** —— 局域网和外网各自独立，
在家走局域网，出门走公网，不需要切换模式、不需要重启 agent。

启动后终端会列出两个地址：

```
┌──────────────────── 手机配对 ────────────────────
│ 局域网：    ws://192.168.1.5:8787/ws
│ 外网：      wss://your.domain/ws
│ 配对码：    K7QM-4XTP   （10 分钟内有效，仅可使用一次）
```

手机和电脑在同一 Wi-Fi 下时填局域网地址；出门在外填外网地址。两者的配对码相同。

只用局域网也可以走 Tailscale 或 Cloudflare Tunnel：
`cloudflared tunnel --url http://localhost:8787`，手机填隧道给的地址。

只想用外网、不开放本机端口时，加 `--no-local-relay`（此时必须配中继地址）。

### 同时在电脑上操作终端

在交互式桌面终端中运行：

```powershell
cd server
npm run agent -- --terminal --root D:\MyNewProjects --cwd D:\MyNewProjects\cloudterminal
```

macOS / Linux 请将 `--root`、`--cwd` 换成自己的目录。配对后，在手机的会话列表中打开这个终端，电脑和手机控制的是同一个进程。在终端里直接输入 `codex`、`claude` 或其他已安装的命令即可。

也可以只运行 Agent，在手机上点新建会话并选择「终端」。已有旧 Agent 不支持终端时，App 继续显示 Claude 会话入口。

### 公网中继服务器（推荐外出使用）

公网中继单独放在 **[cloudterminal-relay-server](https://github.com/azurekiln2333/cloudterminal-relay-server)**：镜像与 GitHub Actions 发布、`compose.yml` / `compose.tls.yml`、`.env.example`、Caddy 配置、账号与数据库、升级和排障说明都在那个仓库里，部署直接照它的 [README](https://github.com/azurekiln2333/cloudterminal-relay-server#readme) 做。

本仓库只保留电脑端需要的中继核心副本：`server/src/relay/relay.ts` 与 `server/src/shared/{relay-protocol,protocol-account,crypto,log}.ts`。局域网入口由 Agent 在进程内直接运行这份副本，不需要 Docker，也不需要公网服务器。

副本以服务端仓库为准：先在服务端仓库改，再在 `server/` 里运行 `npm run sync-relay -- <服务端仓库目录>` 同步；`server` 的 `npm test` 会检查副本与服务端仓库是否一致。镜像由服务端仓库的 CI 发布，首次发布之前镜像还不存在，需要按那份 README 自行构建。

服务器部署完成后，电脑首次向导选择「连接中继」，填 `wss://你的域名/ws` 和服务器上显示的注册密钥；手机使用同一地址加电脑显示的短配对码。**注册密钥填电脑，短配对码填手机。**

局域网 / VPN / 隧道怎么把中继暴露给手机，见 [中继对外部署](server/TUNNEL.md)。

### Agent 参数

| 参数 | 说明 |
| --- | --- |
| `--setup` | 重新运行连接向导，保留配对身份 |
| `--relay <url>` | 中继地址（可选）。配了就在局域网之外再加一个外网入口 |
| `--relay-key <key>` | 中继要求的注册密钥 |
| `--port <n>` | 局域网中继端口，默认 8787 |
| `--no-local-relay` | 不开放局域网入口；此时必须配 `--relay` |
| `--public-url <url>` | 覆盖配对横幅里显示给手机的地址 |
| `--root <dir>` | 手机能选的目录范围，可重复，默认用户主目录 |
| `--cwd <dir>` | 新建会话的默认目录，默认当前目录 |
| `--allow-bypass` | 允许手机选择「跳过权限」模式（默认禁止） |
| `--claude-path <p>` | 指定 claude 可执行文件 |
| `--terminal` | 启动电脑和手机共享的交互式终端 |
| `--no-terminal` | 不在电脑上接管共享终端，保存此偏好 |
| `--herdr-path <p>` | 指定 herdr 可执行文件，默认自动探测 |
| `--no-herdr` | 不接入本机 Herdr 工作区管理 |
| `--reset-pairing` | 生成新身份，所有已配对的手机都要重新配对 |

普通 Agent 模式下按回车会生成一个新的配对码；共享终端模式下按键直接发送给终端程序，Ctrl-C 交给子进程处理。按 **Ctrl-]** 暂时退出桌面接管，终端继续供手机使用；输入 `attach` 并回车可重新接管，空行回车生成配对码。在退出接管的状态下按 Ctrl-C 才会关闭 Agent。

Windows 默认使用 `ComSpec`（通常为 `cmd.exe`），可在终端里输入 `powershell` 或 `pwsh`；macOS / Linux 使用 `SHELL`，未设置时使用 `/bin/sh`。

### 手机 App

```bash
flutter run            # 连着手机或模拟器
flutter build apk      # Android
```

鸿蒙（`ohos/`）、iOS 工程都已配置网络权限。

### 用手机操控 Herdr 工作区

[Herdr](https://herdr.dev) 是电脑上的终端多路复用器，也是各类编码 agent（pi、codex、claude 等）的宿主。CloudTerminal 不会自己启动 Herdr，它连接**已经安装并在运行**的 Herdr，把工作区状态转发给手机。

前提：

- 电脑上已安装 Herdr 0.9 以上，并且它正在运行（打开过 Herdr，或执行过 `herdr server`）。
- Agent 正常启动。启动日志会打印 `herdr available`（可用）或 `herdr unavailable`（附原因）。
- 没装 Herdr 也能用，只是手机端会显示“Herdr 不可用”及可操作的原因，不影响终端和 Claude 会话。

手机端从导航进入 **Herdr 工作区**。这里列出真实的工作区、标签、面板和 agent 状态；展开工作区后，点击面板直接打开终端，无需先创建另一个 PTY 会话。面板内可以：

- 点击终端打开手机键盘，直接输入中文、英文；用「粘贴」按钮或键盘粘贴快捷键插入剪贴板文本。输入由电脑上的程序处理，显示内容来自电脑。
- 使用辅助按键发送回车、退格、方向键、Esc、Tab 和 Ctrl-C；长行按手机宽度换行，键盘弹出后终端填满剩余区域。
- 切换标签或面板，查看可见屏幕的持续更新。手机排版不会改变电脑的终端尺寸，读取可见屏幕也不会滚动电脑面板。
- 在管理菜单执行运行命令、拆分/缩放/移动/重命名、切换焦点或关闭等操作。
- 新建工作区/标签页，重命名或关闭它们（关闭为破坏操作，会先确认）。

安全与真实边界：

- 所有来自手机的值（面板号、工作区号、名称、按键、命令）先在电脑端校验再调用 Herdr；结构操作使用参数数组，终端输入使用 socket 请求，**不经过 shell 拼接**。
- 终端输入逐次有序发送；真实 Windows 链路已验证中英文、空格、Tab、回车、退格、方向键和 Ctrl-C 到达接收程序。断线或发送失败会提示，未送达的内容不会自动重发。
- 显式粘贴由电脑上目标面板的真实粘贴模式处理，保留剪贴板中的空格和换行。需要支持粘贴能力的新版电脑端；能力未确认时会提示更新后重新连接，不会把剪贴板当成普通按键发送。输入法自身若只提交普通文字，仍按普通输入处理。
- NUL（`\u0000`）在请求校验和 JSON/socket 中保留，但当前 Herdr 0.9.3 / Windows ConPTY 链路会丢失它：直接调用 Herdr socket 也返回成功，接收程序却收不到 NUL，具体内部环节尚未确认。因此不能将成功回执当成任意控制字节的端到端支持。
- 不同步驱动 Herdr 的交互式 TUI，不支持 `--machine`/`--remote` 远程转发，不新建假数据。
- 与终端一样，Herdr 控制走同一套配对密钥和中继认证；中继不解析内容。

想不连手机先看效果，可以直接跑一次真实本机冒烟（会临时新建并关闭一个 `ct-probe-*` 工作区，不碰你已有的任何工作区）：

```bash
cd server
$env:CLOUDTERMINAL_HERDR_SMOKE=1; node scripts/herdr-smoke.ts   # PowerShell
CLOUDTERMINAL_HERDR_SMOKE=1 node scripts/herdr-smoke.ts          # bash
```

只想在手机上看真实 Herdr 而不连真机时，可先用演示 Agent（带脚本化的 Herdr 数据，不读取也不需要本机 Herdr）：

```bash
cd server
node scripts/demo-agent.ts --port 8790 --herdr
```

## 安全

- **配对密钥等同于这台电脑的操作权限**：拿到它的人能以当前桌面用户身份在电脑上执行命令。密钥保存在电脑的 `~/.cloudterminal/agent.json`（权限 600）和手机的应用私有目录。怀疑泄露就 `--reset-pairing`。
- 中继只保存密钥的 SHA-256，用常量时间比较；认证失败按 IP 限流；配对码 8 位、10 分钟过期、只能用一次。
- 设置 `RELAY_KEY` 后，只有知道 key 的 agent 能注册到你的中继。
- 公网部署务必用 `wss://`（TLS）。`ws://` 只适合局域网。
- 中继运营者（就是你自己）能看到明文会话内容；v1 没有做端到端加密。
- Claude 专用模式默认不允许 `bypassPermissions`。通用终端直接执行输入，权限提示由终端中运行的工具负责。
- `--root` 只约束目录浏览和新会话的初始目录，**不是沙箱**；终端命令和子进程仍拥有桌面用户的权限。

## Windows 连接助手（Flutter, MD3）

除了手机端，仓库里还有一个独立的 Windows 客户端 `apps/cloudterminal_windows/`。
它的作用是：在电脑上一眼看到连接/配对/工具状态，直接显示配对二维码，并**绑定与
查看 Herdr / Codex / Claude Code 的会话输出**。

它与手机端共用同一条中继与同一套配对：Windows 客户端后台会启动现有 Node agent
（`--sidecar` 模式），复用其认证、重连与协议，再通过**仅回环**的本地 JSON 协议把
状态和工具输出喂给界面（见 `.trellis/spec/backend/sidecar-protocol.md`）。

### 启动

```powershell
cd apps/cloudterminal_windows
flutter pub get
flutter run -d windows        # 需要 Visual Studio 的 Desktop development with C++ 组件
```

没装 Visual Studio 时，可用 `flutter run -d chrome` 预览界面（web 目标无法启动
后台 Node，界面会显示“无法启动后台服务”，这是预期）。安装 C++ 组件的命令：

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

### 绑定真实工具（只说真话）

**无法读取任意已在终端里运行的进程的 stdout。** 本项目只通过工具自己的
daemon/接口接入，并在界面上为每个会话标注来源：

| 工具 | 管理型（真流） | 只读 | 不支持 |
| --- | --- | --- | --- |
| Codex | `codex app-server` JSON-RPC（线程/回合事件） | 线程历史列表 | 接管别人终端里的 TUI |
| Claude Code | `claude -p --output-format stream-json` | `claude agents --json` + `logs` 快照 | 附着到交互式 TUI |
| Herdr | 经中继的工作区/面板控制 | `pane read` 屏幕轮询（标注间隔） | 无变更推送 |

界面上的来源标签分为 **实时流 / 只读历史 / 轮询 Ns**；轮询或历史快照绝不会被
标成实时流。绑定与查看不会重启、接管或新建重复的后台，也不会结束你已有的会话。

### 用手机连上它

在客户端的“配对”页会显示二维码与 8 位短码；手机端扫码（或输短码）即可，无需手抄
中继地址。二维码内容为 `cloudterminal://pair?relay=…&code=…`，10 分钟一次性，不含
长期密钥。

## 开发

```bash
cd server
npm run check      # tsc 类型检查
npm test           # relay / agent 单元与集成测试
npm run demo       # 脚本化 Claude + 真实本机终端；仅 Claude 演示不消耗额度
npm run e2e        # 真实 Claude 端到端冒烟测试（会消耗少量额度）

cd ..
flutter analyze
flutter test       # 含一个 Dart ↔ Node 的真实 WebSocket 集成测试
```

演示 Agent 仅监听本机回环地址，启动时生成随机设备凭据。Android 模拟器可用 `adb reverse tcp:8790 tcp:8790` 后连接 `127.0.0.1:8790`。演示中的终端仍会真实执行命令。

终端渲染使用 `third_party/xterm` 中保留许可证的 xterm.dart 源码，带有当前鸿蒙 Flutter 所需的最小平台兼容修补；升级说明见该目录。

协议定义在 `server/src/shared/protocol.ts`，Dart 端镜像在 `lib/models/protocol.dart`，设计文档见 `.trellis/tasks/10-01-remote-console/design.md`。Herdr 桥接见 `server/src/agent/herdr.ts`、`lib/models/herdr.dart` 与 `.trellis/tasks/10-12-herdr-mobile/design.md`。

## 当前边界

- 共享的是由 CloudTerminal 启动的终端，不能直接接管已经独立启动的任意终端窗口。
- 手机断线不结束会话；Agent 退出或电脑重启会结束所管理的进程，不提供重启后进程恢复。
- 输出按有界缓存重放；缓存较旧内容被淘汰后，App 会重置终端并重放保留部分。复杂全屏程序的旧画面可能需要触发重绘。
- 多个连接共享同一终端尺寸；最后一次调整尺寸生效。
- 任意工具的可用性取决于电脑环境；这里不为各个 AI 工具提供专用会话解析或账号代理。
- Herdr 集成只支持本机已运行的服务，不驱动交互式 TUI、不做远程转发；Herdr 没装或没运行时，Herdr 入口会禁用并给出原因，不影响其他功能。

## 与官方 Remote Control 的区别

Claude Code 自带 `claude --remote-control`，可以在 claude.ai / Claude 官方 App 里接管会话。CloudTerminal 提供通用终端和可选的 Claude 专用模式：中继在你自己的服务器上，手机端可以按自己的需要定制。
