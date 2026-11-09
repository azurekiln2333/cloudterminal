# 实施计划：Windows Flutter(MD3) 连接助手 + 工具绑定 + 中继/扫码配对

> 用户已明确授权创建工程并推进到可运行实现。按步骤执行，每步跑验证命令。
> 目标不是空壳：结束时 `flutter build windows` 成功、`flutter run -d windows` 出 MD3
> 窗口、至少一条真实工具事件流与一条只读路径可用。

## Step 0 — 基线（只记录）

- [x] `cd server; npm run check` — pass
- [x] `cd server; npm test` — 97/97 at baseline; now 111/111
- [x] `flutter analyze` / `flutter test`（手机工程）— clean / 68

## Step 1 — 新建 Flutter Windows 工程（MD3 骨架）

- [x] `apps/cloudterminal_windows/`（`flutter create --platforms=windows`）
- [x] `lib/main.dart`：`MaterialApp(useMaterial3, ColorScheme.fromSeed)`，`NavigationRail` + `NavigationDrawer`（总览 / 工具 / 会话 / 配对 / 设置）
- [x] `lib/theme/app_theme.dart`：标准 MD3 组件样式
- [x] `flutter analyze` clean；`flutter build windows` **环境受限未执行**（缺 VS C++ 组件），见 `LAUNCH.md` / `start-windows.cmd`

## Step 2 — Node sidecar（本地回环 IPC + 复用 RelayLink）

- [x] `server/src/agent/sidecar.ts`：回环随机端口 + `{"type":"listening","port":N}` 首行 + JSON 行协议（snapshot/pair_code/reset_pairing/tool_*/set_relay/stream_event）
- [x] `main.ts`：`--sidecar` 入口（不改默认行为）
- [x] 只绑定 `127.0.0.1`
- [x] `server/test/sidecar.test.ts`（framing + helpers）

## Step 3 — bootstrap + 配对 URI

- [x] `server/src/agent/bootstrap.ts` + 回退；`server/test/bootstrap.test.ts`
- [x] `server/src/shared/pairing.ts` + `apps/.../lib/models/pairing_uri.dart`（+ 手机 `lib/models/pairing_uri.dart`）
- [x] `server/test/pairing.test.ts`；手机端 `test/pairing_uri_test.dart`

## Step 4 — 工具探测与绑定模型

- [x] `apps/.../lib/models/tool.dart`、`server/src/agent/tool-probe.ts`（Windows `.cmd` shim 安全处理）

## Step 5 — 管理型真流最小可用

- [x] Claude：`claude -p --output-format stream-json --verbose`，NDJSON → `stream_event`（实测收到 system/assistant/result）
- [ ] Codex app-server JSON-RPC（探测与只读已就绪；托管流为后续）
- [x] 不启动第二个 daemon，不 kill 用户会话

## Step 6 — 只读路径 + Herdr 轮询

- [x] `claude agents --json` + `logs`；Herdr `pane read` 轮询（默认 1s，可调）
- [x] UI 区分 `实时流 / 只读历史 / 轮询 Ns`（`OriginBadge` + 测试断言）

## Step 7 — 输出视图性能与 MD3 打磨

- [x] 环形缓冲 5000 行、快照替换语义、自动滚动开关、等宽字体

## Step 8 — Windows 构建/运行验证

- [ ] `flutter build windows --release` — **未执行**（缺 Visual Studio C++ 组件，环境限制）
- [x] sidecar 端到端实测（真实 IPC + 真实 Claude 事件流）

## Step 9 — 文档与验收

- [x] `README.md` Windows 助手章节；`server/TUNNEL.md`；`apps/.../LAUNCH.md`
- [x] `.trellis/spec/backend/sidecar-protocol.md` + index 链接
- [x] `completion-audit.md` 逐条核对

## Step 10 — 质量门（全量）

- [x] `cd server; npm run check` / `npm test` — 111/111
- [x] 手机 `flutter analyze` / `flutter test` — clean / 68
- [x] Windows `flutter analyze` / `flutter test` — clean / 11

## 回滚点

- Step 1 后：纯新增工程，不影响任何现有构建。
- Step 2 后：sidecar 仅在显式 `--sidecar` 时启用。
- 任意时刻：删掉 Windows 工程与 sidecar 入口即回到现状；无迁移、无协议破坏。

## 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| Codex app-server 属 experimental，schema 变动 | 固定版本探测 + 宽松解析 + 失败时降级为只读列表 |
| Claude 真流需登录/额度 | 未登录给明确提示，不假装可用；只读路径仍可列出 |
| Herdr 无推送 | 如实标注轮询 + 间隔；不包装成真流 |
| 高频输出卡 UI | 有界缓冲 + 批量合并 + 贴底滚动策略 |
| Windows 打包 Node sidecar | 先要求本机 Node ≥23.6（与现状一致）；打包为后续改进 |
