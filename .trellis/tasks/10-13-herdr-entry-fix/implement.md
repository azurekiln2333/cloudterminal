# 实施计划：Herdr 入口死锁

## 前置

- 任务：`.trellis/tasks/10-13-herdr-entry-fix`
- 目标：消除首次连接无法进入 Herdr 工作区的死锁；修正误导性文案。
- 范围：仅 `lib/state/herdr_controller.dart`、`lib/widgets/workspace_sidebar.dart`，
  以及必要时的 `lib/screens/herdr_screen.dart` 与 `test/`。

## 有序检查清单

- [ ] 1. `herdr_controller.dart`：新增状态字段
      `_probing` / `_probeFailed` / `_wasOnline` / `_inflightRefresh`，
      新增 getter `probing`、`probed`、`canBrowse`。
- [ ] 2. `herdr_controller.dart`：`refresh()` 拆为公开入口（去重、守卫）+
      `_doRefresh()` 主体（置 `_probing`、探测成功/失败时维护 `_probeFailed`）。
- [ ] 3. `herdr_controller.dart`：`_onRemote()` 处理 `isOnline` 跃迁，
      上线时 `unawaited(refresh())`；下线时清理 `_availability`、`_probeFailed`、
      `_loaded`、`_error`。构造函数初始化 `_wasOnline = _remote.isOnline`。
- [ ] 4. `workspace_sidebar.dart`：入口 `enabled: herdr.canControl` → `herdr.canBrowse`。
- [ ] 5. `workspace_sidebar.dart`：重写 `_herdrHint()`，未知状态不得显示"未启用"。
- [ ] 6. `herdr_screen.dart`：确认 `loading` 分支在自动探测时显示"检测中"；
      如 `availability == null && !loading && !probed` 也需给中性提示，补齐。
- [ ] 7. 新增测试：
      - controller：`canBrowse` / `canControl` / `probed` 三态矩阵；
      - controller：`isOnline` 跃迁触发探测；
      - widget：`availability == null` 时不出现"电脑端未启用 Herdr 接入"。
- [ ] 8. 运行 `flutter analyze`。
- [ ] 9. 运行 `flutter test`。
- [ ] 10. 手工验证（真机 + 运行中的 agent）：
      清 App 数据 → 配对 → **不手动刷新**直接点「Herdr 工作区」→ 出现真实工作区。

## 验证命令

```powershell
cd D:\MyNewProjects\cloudterminal
flutter analyze
flutter test
```

Agent 端（用于手工验证，需已配置 `--herdr-path`）：

```powershell
cd D:\MyNewProjects\cloudterminal\server
npm run agent -- --no-terminal
```

## 审阅闸口

- 闸口 A（步骤 1-3 后）：controller 状态语义自洽，`canControl` 语义**未变**。
  确认无既有调用点被破坏（`loadWorkspace` / `loadLayout` / `run` 仍用 `canControl`）。
- 闸口 B（步骤 4-6 后）：无任何路径在 `availability == null` 时输出"未启用"。
- 闸口 C（步骤 7-9 后）：分析/测试全绿。

## 回滚点

- 任一闸口失败 → `git checkout -- lib/state/herdr_controller.dart lib/widgets/workspace_sidebar.dart`。
- 改动不涉及协议与持久化，回滚无副作用。

## 明确不做

- 不改 agent 端 `resolveHerdrBinary` 的探测策略（不查 PATH 的问题另案）。
- 不改 Herdr 协议帧。
- 不引入推送流。
