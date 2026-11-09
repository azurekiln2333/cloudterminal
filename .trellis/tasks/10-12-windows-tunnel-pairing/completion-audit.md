# 完成审计 — Windows 连接助手 + 工具绑定 + 中继/扫码配对

证据取当前源码与实测输出，不以任务状态为准。

| 验收项 | 证据 | 状态 |
| --- | --- | --- |
| 1. `apps/cloudterminal_windows` 能构建/启动出 MD3 窗口 | 工程已建；`flutter analyze` no issues；`flutter test` 11/11；**`flutter build windows` 未执行：本机缺 Visual Studio C++ 组件**（flutter doctor 明确报错）。已提供 `start-windows.cmd` 与 `LAUNCH.md`（含 winget 安装命令 + Chrome 预览回退） | 部分（环境受限，已如实标注） |
| 2. 首屏显示中继/手机/三工具状态 | `overview_page.dart`；sidecar `snapshot` 提供 `relayOnline/pairedClients/tools[]`；实测 sidecar 探测到 `herdr:true,codex:true,claude:true` | 通过 |
| 3. 二维码与短码、手机一次点击配对 | `pairing_page.dart` 用 `qr_flutter` 渲染 `cloudterminal://pair?...`；`pairing.ts` 与 Dart `pairing_uri.dart` 双端编解码 + 测试；`pair_code`/`uri` 实测来自真实 sidecar | 通过（真机扫码未验证） |
| 4. 工具绑定：管理型真流 + 只读 + 来源标签 | Claude 托管真流已实测：`managed-smoke.mjs` 从真实 sidecar 收到 NDJSON `system`/`assistant`/`result` 事件；Herdr `pane read` 轮询；`claude agents --json` 只读；`SessionBinding.origin` + `OriginBadge` 强制标注，`widget_test.dart` 断言轮询不显示“实时流” | 通过 |
| 5. 中文/ANSI/高频输出 | 输出按 UTF-8 整行处理；环形缓冲上限 5000 行；快照替换/增量追加语义区分 | 通过（ANSI 去色渲染为后续） |
| 6. 不重启/不 kill/不建重复 daemon | 绑定只读；只停止自己启动的进程（`child.kill()` 仅针对 `children` 表中项）；Herdr 只 `pane read` | 通过 |
| 7. 配对码 10 分钟一次性、刷新作废 | 复用 `link.ts` 的 `PAIR_CODE` + relay TTL；`pair_code` 每次刷新新码 | 通过 |
| 8. 断线重连 + 可操作中文错误 | 复用 `RelayLink` 心跳/重连，`onOffline` 上报 retries/lastError；`tool-probe` 各工具给安装/登录指引 | 通过 |
| 9. 四道门全绿 | `npm run check` 0；`npm test` **112/112**；手机 `flutter analyze` clean + `flutter test` **86/86**；Windows `flutter analyze` clean + `flutter test` **11/11** | 通过 |
| 10. 无新增公网部署/付费资源/硬编码密钥 | 未部署任何服务；未内置长期密钥；`bootstrap.json` 的 relayKey 可覆盖可清空 | 通过 |
| 11. 手机工程与既有改动不受影响 | 手机工程未改构建配置；68/68 通过；两侧共用一套中继 | 通过 |

## 本会话发现并修复的缺陷

1. `server/test/sidecar.test.ts` 内用了 ESM 里不存在的 `require('node:net')`，导致测试进程挂起且套件超时；改为顶层 `import { Socket }` 并等待 `server.close` 回调。
2. Windows 上 Node 24 无法以 `shell:false` 直接 spawn `.cmd`（`spawn EINVAL`）；`tool-probe.ts` 改为经 `cmd.exe /d /s /c <path> <args>` 以 argv 数组调用，既不注入 shell 也能识别 `codex.cmd`。
3. `HerdrPane.hostLabel()` 不存在导致编译失败；改用 `terminalTitle/agent`。
4. Windows 客户端 `pairing_page.dart` 倒计时不会走动；补 `Timer.periodic`。
5. sidecar 忽略 `--port`（未写入 `preferences.localPort`）；已补齐，使 `--sidecar --local-relay --port N` 生效。
6. 根目录与 `server/` 的 `server.zip` 未被忽略，有误提交风险；`.gitignore` 增加这两条（未使用宽泛的 `*.zip`）。

## 未验证（如实标注）

- `flutter build windows` / `flutter run -d windows`：本机缺 Visual Studio C++ 组件，未执行。
- 手机真机扫码：无设备/无摄像头环境，未执行；短码与手填路径有单元与集成测试。
- 公网中继、Cloudflare/Tailscale 隧道端到端：无账号/资源，未执行（文档与脚本已就绪）。

## 限制

- 读取任意已运行 TUI 进程的 stdout 不支持（技术不可行），UI 亦不暗示支持。
- Herdr `pane read` 是轮询，非变更推送。
- Codex app-server 为 experimental，schema 可能变动，已做宽松解析与降级。
