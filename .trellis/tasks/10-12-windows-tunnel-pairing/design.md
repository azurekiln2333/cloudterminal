# 设计：Windows Flutter(MD3) 连接助手 + 工具绑定 + 中继/扫码配对

## 0. 架构总览

```
┌─ apps/cloudterminal_windows  (Flutter Windows, MD3) ─┐
│  导航: 总览 / 工具 / 会话 / 配对 / 设置                    │
│  ┌───────────┐  ┌────────────┐  ┌───────────────┐     │
│  │ RelayLink │  │ ToolRegistry│  │  Pairing UI  │     │
│  │ (内嵌 Node│  │ herdr/codex │  │ QR + 短码    │     │
│  │  子进程)  │  │  /claude    │  │              │     │
│  └─────┬─────┘  └──────┬──────┘  └───────────────┘     │
│        │                │  (IPC: 本地 stdout JSON 行)     │
└────────┼────────────────┼───────────────────────────────┘
         │ wss(outbound)  │ spawn (argv, shell:false)
         ▼                ▼
  中继服务器         herdr / codex app-server / claude
  (现有 server/)      (本机已装，0.9.3 / 0.162.1 / 2.1.296)
```

关键决策：**Flutter Windows 仍通过现有 Node agent 接入中继**（复用 `RelayLink`
的全部认证/重连/协议），**同时**自己 spawn 并管理三个工具的进程以拿到真输出流。
两者通过本地 IPC 通信（见 §2.3），Flutter 侧只做 UI 与展示。

为什么不在 Flutter 里重写中继客户端：中继握手、配对码、心跳、重连、协议镜像
（`protocol.ts` ↔ `protocol.dart`）已在 Node 侧完整且有测试；重写等于双份维护
且会与手机端行为分叉。

## 1. 目录与工程边界

```
apps/
  cloudterminal_windows/        # 新 Flutter Windows 工程（不碰手机工程）
    windows/                    # flutter create 生成的 Windows runner
    lib/
      main.dart                 # MD3 App, useMaterial3, ColorScheme.fromSeed
      theme/app_theme.dart      # 与手机端同一套 seed/排版风格
      models/                   # 工具模型 + 配对 URI + 状态
      state/                    # ChangeNotifier controllers
      engine/                   # 与 Node sidecar 的 IPC 客户端
      screens/                  # overview / tools / sessions / pair / settings
      widgets/
    tool/                       # 打包脚本（组装 sidecar + 资源）
server/                         # 现有 Node agent（新增 sidecar 入口，不大改）
```

约束：手机工程 `lib/`、`android/`、`ohos/`、`pubspec.yaml` **不动**。Windows 工程
独立 `pubspec.yaml`；两边若要共享代码，用 `path:` 依赖指向仓库内共享包，而不是改手机工程。

## 2. 与现有手机端 / 桌面 agent / 中继的关系

| 组件 | 关系 |
| --- | --- |
| 手机 Flutter 端 | 不改动；仍是手机客户端。两者可同时连同一 agent（多客户端已支持）。 |
| 桌面 Node agent (`server/`) | **继续由 Windows 客户端承载**：新增一个本地 IPC 层 + 可选的"sidecar 模式"入口；核心 `RelayLink`/`AgentCore`/`HerdrBridge` 复用。 |
| 中继 (`server/src/relay`) | 不改；仍是部署者的一次性服务。 |
| 工具进程 | 由 Windows 客户端按需 spawn（argv 数组，`shell:false`），不接管已有 TUI 进程。 |

### 2.3 IPC 设计（Flutter ↔ Node sidecar）

两种可行实现，按落地成本选择：

- **A. 本地 WebSocket/HTTP（推荐）**：sidecar 启动后监听 `127.0.0.1` 随机端口，
  把端口写到 stdout 首行；Flutter 连接后收发 JSON 行。优点：双向、可推送事件流、
  调试方便；回环绑定，同机访问。
- **B. stdio JSON 行**：Flutter `Process.start` 后读写 stdin/stdout，每行一个 JSON。
  更简单，但 Windows 下管道缓冲/编码需小心（统一 UTF-8，禁用控制台代码页干扰）。

默认选 **A**（双向事件流 + 断线可重连），并把协议固定为带 `type` 的 JSON 行。

## 3. 工具注册表与绑定模型

```dart
enum ToolKind { herdr, codex, claude }

/// 每个工具一个探测结果：装没装、版本、能否管理。
class ToolProbe {
  final ToolKind kind;
  final bool installed;
  final String? version;
  final bool daemonRunning;   // codex app-server / claude 后台
  final String? executable;
  final String? reason;       // 未安装/未登录的可操作中文原因
}

/// 绑定来源：决定 UI 能否声称"实时"。
enum StreamOrigin { managedStream, daemonHistory, panePoll }

class SessionBinding {
  final ToolKind kind;
  final String id;            // threadId / paneId / session id
  final String title;         // 工具/目录/昵称
  final StreamOrigin origin;
  final Duration? pollInterval; // 仅 panePoll 非空
  final bool canAcceptInput;  // 是否允许发消息（只读历史=false）
}
```

UI 对每个绑定显示来源标签：`真流` / `只读历史` / `轮询 Ns`。

### 3.1 各工具接入路径（实测确认）

**Codex (`codex app-server` JSON-RPC)**
- 启动：`codex app-server --listen stdio://`（由客户端 spawn），或连接已运行 daemon
  的 control socket（`~/.codex/app-server-control/app-server-control.sock`）。
- 真流：`ThreadStart`/`TurnStart` 后处理 `AgentMessageDelta`、
  `Command/exec/outputDelta`、`TurnStarted` 等通知 → `StreamOrigin.managedStream`。
- 只读：`ThreadList` + `ThreadRead`/`ThreadItemsList` → `daemonHistory`。
- **不**启动第二个 daemon，**不** kill 用户的线程。

**Claude Code**
- 真流：`claude -p --output-format stream-json --verbose --input-format stream-json`
  按 NDJSON 读 `system`/`assistant`/`result` 事件 → `managedStream`。
- 只读：`claude agents --json --all` 列表 + `claude logs <id>` 快照 → `daemonHistory`。
- 续接：`--resume <session-id>`。
- 受权限/付费约束：真流启动需要用户已登录；未登录/无额度时给明确提示，不假装可用。

**Herdr**
- 只读：`herdr pane read <id> --source recent-unwrapped --lines N` 轮询 → `panePoll`
  （默认 1s，可在 UI 调成 2s/5s/手动）。Herdr CLI 无变更推送，**不声称真流**。
- 管理：`herdr workspace/tab/pane/agent` 控制（已在上一任务接入中继）。

## 4. 分发配置（bootstrap）与回退

沿用上面的三级回退（CLI → env → `agent.json` → `bootstrap.json` → 空）。

新增 `bootstrap.json`（打包/部署者提供，放在客户端分发包，可选）：

```json
{
  "relayUrl": "wss://relay.example.com/ws",
  "relayKey": "",            // 可选；空表示该中继不需要注册密钥
  "invite": "ABCD-EFGH"      // 可选；短码邀请
}
```

`bootstrap.json` 里的 `relayKey` 是**注册密钥**，它只决定"谁能往这个中继注册
agent"，不等于手机配对凭据。默认分发包**不内置**；若要内置，客户端 UI 必须
提供覆盖与清空。

## 5. 不重写服务端：复用边界

现有拓扑已经解决了"无入站端口"这个最难的问题——`RelayLink` 是 agent →
中继的 **outbound** 长连接，中继 → agent 复用同一条 TCP。因此：

```
手机 App ──wss──▶ 中继服务器(部署者) ◀──wss── Windows 客户端(Node sidecar)
                                                  ├─ PTY / Claude SDK / Codex
                                                  └─ Herdr CLI
```

保持不变：`relay.ts` 的注册与配对码交换、`link.ts` 的重连/心跳、`core.ts`
的会话、`herdr.ts` 的桥接、手机端 `RemoteController` 的请求相关性。

新增仅三处：

1. **客户端外壳**（Flutter Windows）：承载 Node sidecar + MD3 UI + 二维码展示。
2. **分发配置（bootstrap）**：中继地址/注册密钥的来源从"用户手填"变为
   "打包配置 / 短码 / 环境变量"回退。
3. **配对握手内容扩展**：二维码与短码承载 `relayUrl + 一次性码`，
   手机端解析后调用现有 `pairWithCode`。

## 6. 二维码 / 短码内容契约

二维码内容是一个 `cloudterminal://pair?...` URI，字段对齐现有握手：

```
cloudterminal://pair?relay=<urlencoded ws(s) url>&code=ABCD-EFGH[&key=<relayKey>][&v=1]
```

- `relay`：中继地址（必填）。
- `code`：8 位一次性配对码（必填，10 分钟 TTL）。
- `key`：中继注册密钥（可选）。**注意**：注册密钥是 agent 侧注册用的；把它放进
  二维码只在"中继要求密钥"时才需要，且它不能替代 `code`。默认不放。
- `v`：协议版本，便于将来演进。

短码：直接展示 8 位一次性码 + （如需要）中继地址的**域名简写**。手机端若已
记录或从分发包拿到中继地址，只需输 8 位码；否则输"地址 + 8 位码"两栏（现有
逻辑），或用"粘贴二维码内容"。

安全等价性：二维码 = 现有配对横幅的机器可读形式，**不含**长期 secret；扫描后
手机仍通过 `pair_code` → 中继交换拿到 `agentId + secret` 并持久化。二维码本身
过期即失效，不产生新的攻击面。

## 7. 中继侧改动（最小）

现有 `relay.ts` 已保存 `pairCodes: Map<code,{agentId,expiresAt}>` 并允许客户端用
`pair_code` 交换。新增配对只需**客户端侧**把码交出来，中继无需新接口。

唯一可能需要的中继改动：**可选**的 `invite`（部署者短码）——把"中继地址 + 注册
密钥"用一个人可读的短码下发，避免用户手填 URL。默认设计**不新增中继接口**，
只复用现有能力。

## 8. 手机端改动

`lib/screens/pair_screen.dart`：

- 顶部增加两个大按钮：**扫描二维码**（需摄像头权限）/ **输入短码**。
- 现有"服务器地址 + 配对码"折叠为"手工输入"。
- 扫码/短码解析结果 → 预填 `relay` 与 `code` → 用户点"连接" → 复用
  `controller.pairWithCode`。
- 若解析到的 `relay` 与 `AppStore.lastRelayUrl` 不同，展示"将连接新服务器"确认。
- 若引入 `mobile_scanner`（待确认 4），扫描页复用 Material 3 风格；不引入则提供
  "粘贴二维码内容"框（二维码内容就是上面的 URI，可复制粘贴）。

`lib/state/remote_controller.dart`：新增 `pairWithQr(String payload)`，解析 URI 后
调用现有 `pairWithCode`；解析失败给明确错误。无协议层新增消息。

## 9. 状态与生命周期

- 客户端状态来源：
  - `RelayLink.isOnline` → 中继在线；`onPaired` → 手机配对事件；
    `onOffline(reason)` → 重试计数/最近错误；
  - `core.herdrAvailability()` → Herdr 状态；
  - 工具探测（`where`/`--version`/daemon 存在性）→ 各工具状态；
  - 绑定会话的健康（进程退出、daemon 断开、流结束）。
- 这条状态由 Node sidecar 汇成一份 `snapshot`，通过 IPC (§2.3) 推给 Flutter；
  Flutter 只用 `ChangeNotifier` + `ListenableBuilder` 重建受影响区域。
- 断线重连沿用 `RelayLink`；工具流断开时 UI 显式提示并允许手动重连；
  **不自动重启用户的工具进程**。

## 10. UI：标准 Material 3 与输出性能

- `MaterialApp(theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seed)))`；
  沿用与手机端一致的 seed/排版，不自定义视觉体系。
- 导航：`NavigationRail`（宽屏）+ `NavigationDrawer`（窄窗）；页面为标准
  `Scaffold` + `Card`/`ListTile`/`Chip`/`FilledButton`/`SegmentedButton`。
- 输出视图使用等宽字体 + 可选 ANSI 渲染；中文按 UTF-8 整行处理，不按字节切。
- 持续输出性能：环形缓冲（默认保留最近 N 行，如 5000，可配）；批量合并
  高频事件（如 50ms 合并一次 setState）；只在贴底时自动滚动否则显示"跳到底部"；
  后台会话未选中时降级（仅计数/丢弃增量）。
- 来源标签必须可见：`真流` / `只读历史` / `轮询 1s`。

## 11. 安全设计（流程而非降级）

| 风险 | 处理 |
| --- | --- |
| 无认证远控 | 不提供。配对码仍是唯一入口；二维码只省去手抄 |
| 二维码泄漏 | 10 分钟 TTL、一次性、刷新即作废；不含长期 secret |
| 注册密钥内置分发包 | 默认不内置；若内置则可覆盖/清空，且它不用于客户端认证 |
| IPC 端口暴露 | sidecar 仅绑定 `127.0.0.1`；不监听 LAN |
| 凭据落盘 | 复用 `config.ts`：用户私有目录 + 0600 |
| 忘记取消授权 | 手机端 unpair + 客户端"重置配对身份"两个入口 |
| 明文传输 | 公网必须 `wss://`；`ws://` 仅限局域网/隧道，UI 警告 |
| 误操作影响用户会话 | 绑定只读不写；不 kill/respawn；不建第二个 daemon |

## 12. 回滚

- Windows 工程是新增目录；不发布即回到现有 CLI（`start.cmd` 保持可用）。
- 二维码/短码是配对入口的**增量**，删除后回到"手填地址+码"。
- sidecar IPC 是可选的：不启用时 `server/` 行为与今天一致。
- 工具绑定全是只读/独立进程，不产生持久化迁移。

## 13. 里程碑（供 implement.md 展开）

1. 创建 Flutter Windows 工程（MD3 骨架 + 导航 + 主题）。
2. Node sidecar 模式：本地回环 IPC + `snapshot` 推送 + 复用 `RelayLink`。
3. `bootstrap.json` + 配对 URI（TS 与 Dart 两份，跨层测试）。
4. 工具探测与绑定模型（Herdr / Codex / Claude）。
5. Codex app-server 与 Claude stream-json 的"管理型真流"最小可用。
6. 只读路径（`claude agents`/`ThreadList`/`pane read` 轮询）+ 来源标签。
7. 输出视图性能与 MD3 打磨；Windows 构建/运行验证。
8. 文档 + 验收 + 试用步骤。
