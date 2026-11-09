# 设计：Herdr 入口死锁

## 变更边界

单层改动（Flutter app 层），**不碰 agent 端、不碰协议**。

涉及文件：

| 文件 | 改动性质 |
| --- | --- |
| `lib/state/herdr_controller.dart` | 核心：拆分 gating、连接时自动探测、状态语义 |
| `lib/widgets/workspace_sidebar.dart` | 入口 `enabled` 条件 + 文案诚实化 |
| `lib/screens/herdr_screen.dart` | 可能微调：首次探测由 controller 负责后避免重复请求 |
| `test/` | 新增 controller / widget 测试 |

## 契约设计

### 1. HerdrController 状态语义

当前只有一个 `availability`（可空），被同时用于两个不同问题：

- **能否进入/浏览**（能力发现问题）
- **能否下发写操作**（权限/可用性问题）

拆成三个显式状态：

```dart
/// 是否已成功探测过 Herdr 能力（与"可用"无关）。
bool get probed => _availability != null || _probeFailed;

/// 已连接且 Herdr 报可用 —— 写操作与只读数据的前置条件。
bool get canControl => _remote.isOnline && (_availability?.available ?? false);

/// 已连接（与 Herdr 是否可用无关）—— 允许进入页面查看状态/原因。
bool get canBrowse => _remote.isOnline;
```

- `canBrowse`：给入口 `enabled` 用。
- `canControl`：给写操作按钮用（**保持现有语义不变**，避免影响既有页内逻辑）。
- `probed`：给文案用，区分"未探测"与"探测过但不可用"。

新增 `_probeFailed` 与 `_probing` 标志：

```dart
bool _probing = false;      // 探测进行中
bool _probeFailed = false;  // 探测请求本身失败（网络/异常）
```

### 2. 连接建立自动探测

`_onRemote()` 扩展：监听 `isOnline` 的 false→true 跃迁。

```dart
bool _wasOnline = false;

void _onRemote() {
  final online = _remote.isOnline;
  if (online && !_wasOnline) {
    _wasOnline = true;
    // 连接建立：主动探测一次，不依赖用户打开页面。
    unawaited(refresh());
  } else if (!online && _wasOnline) {
    _wasOnline = false;
    _loaded = false;
    _availability = null;
    _probeFailed = false;
    _error = null;
    _notify();
  }
}
```

注意：`refresh()` 内部已有 `if (!_remote.isOnline)` 守卫，安全。
需要 `import 'dart:async';`（已存在）。

### 3. refresh() 并发去重

`refresh()` 可能被"连接建立"和"页面 initState"同时触发。加最小互斥，
避免重复请求和 loading 抖动：

```dart
Future<void>? _inflightRefresh;

Future<void> refresh({bool force = false}) {
  if (!_remote.isOnline) { _error = '电脑未连接'; _notify(); return Future.value(); }
  // force 请求不与其他请求合并（用户显式意图）。
  if (!force && _inflightRefresh != null) return _inflightRefresh!;
  final future = _doRefresh(force: force);
  _inflightRefresh = future;
  return future.whenComplete(() { if (identical(_inflightRefresh, future)) _inflightRefresh = null; });
}
```

`_doRefresh` 为现有实现主体，并设置 `_probing` / `_probeFailed`。

### 4. 侧边栏文案（诚实化）

`_herdrHint()` 重写为显式分支，**禁止**把 null 说成"未启用"：

```dart
String? _herdrHint(BuildContext context) {
  if (herdr.canControl) {
    return herdr.attentionCount > 0 ? '${herdr.attentionCount} 个 agent 需要处理' : null;
  }
  if (controller.agent == null) return '连接电脑后读取 Herdr 工作区';
  final availability = herdr.availability;
  if (availability != null) return availability.summary;  // 真实原因
  if (herdr.probing) return '正在检测 Herdr…';
  return '正在检测 Herdr…';   // 未探测：中性，不断言
}
```

入口：

```dart
NavigationDrawerDestination(
  label: const Text('Herdr 工作区'),
  enabled: herdr.canBrowse,   // 连接即可进
),
```

「不可进入」的唯一情形是**未连接**（此时文案是"连接电脑后读取"）。

### 5. herdr_screen

页面 `initState` 的 `refresh()` **保留**（作为幂等保障），因 controller 已去重，
不会产生额外请求。`_content` 分支（`herdr_screen.dart:283-295`）已能处理
`availability == null && loading`，无需改动；但需确认 `loading` 在自动探测时
被正确置位，以显示"检测中"而不是"不可用"。

## 兼容性与风险

- `canControl` 语义**不变** → 页内写操作、`run()`、`loadWorkspace`、
  `loadLayout` 行为不变。
- 入口从"可用才可点"变为"连接即可点" → 唯一行为变化，正是修复目标。
- 若 agent 不支持 Herdr（老版本），进入页面会看到 `_UnavailableBanner`
  显示真实原因 —— 比现在"灰按钮 + 错误文案"更好。
- 自动探测在连接建立时发生 → 每次重连多一次轻量请求（`herdr_info`），可接受。

## 回滚

改动集中在 2 个文件、无协议/持久化变更，`git revert` 即可完整回滚。

## 验证策略

1. 单测（controller）：未探测时 `canBrowse == true`、`canControl == false`；
   `null` availability 时 `probed == false`；连接跃迁触发 refresh。
2. Widget 测试：`availability == null` 时不渲染"电脑端未启用 Herdr 接入"。
3. 手工验证：清 App 数据 → 配对 → 不刷新直接点进 Herdr 页 → 看到工作区列表。
