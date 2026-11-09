# 工具会话接入与输出流能力（实测，2026-10-12）

本机环境：Windows 10 19045；Flutter 3.27.5-ohos（Windows desktop 已启用，设备列表含
`Windows (desktop)`）；codex-cli 0.162.1；claude 2.1.296；herdr 0.9.3。

结论先行：**三个工具都有"真实受支持"的程序化接入面**，但都只覆盖"由该工具的
server/daemon 管理的会话"，**无法读取一个已在别人终端里跑的 TUI 进程的 stdout**。
因此 Windows 客户端必须区分两类绑定：

- **A. 管理型（assistant-managed）**：由 Windows 客户端启动/驱动，能拿到真正的
  事件流（JSON-RPC / NDJSON），可实时增量显示。
- **B. 只读型（attach/adopt）**：对 daemon 里已存在的会话做只读列表/读取，或在
  Herdr 里对已有 pane 读取屏幕。能看但语义受限，必须如实标注。

## 1. Codex（codex-cli 0.162.1）

真实能力（`codex app-server` 是 JSON-RPC 服务，`--listen` 支持 `stdio://`、
`unix://`、`ws://IP:PORT`）：

- **协议是一等公民**：`codex app-server generate-json-schema --out DIR` 生成
  `ClientRequest.json`(211KB)、`codex_app_server_protocol.v2.schemas.json` 等，
  含 `JSONRPCRequest/Notification/Response`、`Thread*`、`Turn*`、
  `AgentMessageDeltaNotification`、`Command/exec/outputDeltaNotification`。
- 关键方法（来自生成 schema 的定义名）：`ThreadList`、`ThreadRead`、`ThreadStart`、
  `ThreadResume`、`ThreadItemsList`、`TurnStart`、`TurnStartedNotification`、
  `ThreadStartedNotification`、`CommandExecOutputDeltaNotification`。
- 会话浏览：`codex agents`（"Browse all agent sessions on the shared local
  app-server daemon"）、`codex resume`、`codex fork`、`codex queue`。
- daemon 管理：`codex app-server daemon start|stop|restart|version|enable-remote-control`；
  本机 `~/.codex/app-server-daemon/` 已有 `daemon.pid`、`app-server-control.sock`，
  说明 **daemon 正在运行**。
- `codex remote-control pair` 能生成"short-lived manual pairing code"。

**A 类（管理型）**：客户端用 `app-server --listen stdio://`（或连接已运行的 control
socket）建立 JSON-RPC，`ThreadStart`/`TurnStart` 后订阅 `AgentMessageDelta` /
`CommandExecOutputDelta` 通知 → 真·增量流。

**B 类（只读型）**：`ThreadList`/`ThreadRead`/`ThreadItemsList` 可列出并读回 daemon
里已有线程历史；但不是实时流，且**不能接管 TUI 里的交互**。

## 2. Claude Code（claude 2.1.296）

真实能力：

- **A 类（管理型）**：
  `claude -p --output-format stream-json --verbose [--input-format stream-json]`
  → 实测输出为逐行 NDJSON，含 `{"type":"system",...}`、`{"type":"assistant",...}`、
  tool_use/tool_result、`{"type":"result",...}`，并带 `session_id`。
  这是官方文档化的实时流（`--output-format` 可选 `text|json|stream-json`）。
- **后台会话**：`claude --bg/--background`（返回 id）、`claude attach <id|name>`、
  `claude logs <id|name>`（"Print the background session's recent terminal output"）、
  `claude agents [--json] [--all]`、`claude stop/kill <id>`、`claude respawn`、
  `claude rm <id>`。本机 `claude agents --json` 实测返回 `[]`（无后台会话）。
- `--resume <session-id>` / `--session-id <uuid>` 可续接指定会话。

**A 类（管理型）**：由客户端启动 `claude -p --output-format stream-json`（或 `--bg`
后 `claude logs`）→ 真流。
**B 类（只读型）**：`claude agents --json` 列后台会话 + `claude logs <id>` 读最近输出。
注意 `logs` 是"最近终端输出"快照，不是挂载式实时流；要看实时需 `attach`（会占用
该终端）或改用 stream-json。

## 3. Herdr（0.9.3）——已在上一任务完成接入

`herdr workspace|tab|pane|agent ...` 返回结构化 JSON；`pane read`/`agent read` 返回原始
屏幕文本。详见 `.trellis/tasks/10-12-herdr-mobile/research/herdr-cli-0.9.3.md`。
Herdr 是"多路复用器 + agent 宿主"，天然同时具备 A（`agent start/prompt`）与 B
（`pane read`）两种能力。

## 4. 明确的能力边界（必须如实呈现，不能美化）

| 场景 | 支持？ | 正确做法 |
| --- | --- | --- |
| 读取"助手启动"的 Codex 会话实时输出 | ✅ | app-server JSON-RPC 通知 |
| 读取"助手启动"的 Claude 会话实时输出 | ✅ | `-p --output-format stream-json` |
| 读取"助手启动"的 Herdr 面板实时输出 | ⚠️ | `pane read` 轮询；Herdr 无 CLI 变更推送 |
| 列出 daemon 里已存在的 Codex 会话 | ✅ | `ThreadList`/`ThreadRead` |
| 列出已存在的 Claude 后台会话 | ✅ | `claude agents --json` |
| 读取已在**别人终端**里跑的 Codex/Claude TUI 的 stdout | ❌ | 不可能；只能通过其 daemon 面 |
| 对任意已运行进程"挂上去"读 stdout | ❌ | 不支持，不要假装支持 |

因此 UI 必须为每个绑定显示**来源（source）**：`managed-stream`（真流）/
`daemon-history`（只读历史）/`pane-poll`（轮询，注明刷新间隔）。
**绝不把 `pane-poll` 或历史快照标成"实时输出流"。**

## 5. Windows 客户端形态结论

Flutter Windows desktop 可用（`Windows (desktop)` 设备在线）。因此采用**独立
Flutter Windows 工程**（用户明确要求），而不是上一方案里的"本地 Web UI"。
它与现有手机 Flutter 工程共享 `lib/models` 与 MD3 主题思路，但独立成 app，避免
破坏手机端构建（手机端有 ohos/android 专属配置）。
