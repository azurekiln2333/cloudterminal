# 设计：Pane 切换 UI + 等比缩放渲染

父任务：`10-13-herdr-mobile-render`
覆盖两个子任务：
- `10-13-herdr-pane-switcher`（Tab 栏 + pane chips + 滑动）→ 本文件 §1
- `10-13-herdr-pane-viewport` 的渲染模式扩展 → 本文件 §2

## 变更边界

只改移动端 `lib/` 与 `test/`。**不改 `server/`、不改协议、不改 `herdr.dart` 解析。**

| 文件 | 改动 |
| --- | --- |
| `lib/screens/herdr_pane_screen.dart` | 加 Tab 栏 + chip 栏 + PageView；pane 由外部索引驱动 |
| `lib/widgets/herdr_pane_viewport.dart` | 新增 `HerdrViewportMode.scaledToFit` 并设为默认 |
| `test/herdr_test.dart` | 新增切换与渲染测试 |

## §1 Pane 切换 UI

### 状态

`HerdrPaneScreen` 从「只认一个 `pane`」升级为「认工作区 + 当前选中 pane」：

```dart
String _selectedTabId;   // 当前 tab
int _paneIndex;          // 当前 tab 下的 pane 序号
final Map<String, String> _lastPaneOfTab = {};  // 每个 tab 记忆上次看的 pane
```

**兼容**：构造时仍接受 `pane`，用它初始化 `_selectedTabId` / `_paneIndex`，
所以从列表点进来的行为不变。

### 派生数据

```dart
List<HerdrTab> get _tabs => widget.herdr.tabs(widget.workspace.workspaceId);
List<HerdrPane> get _tabPanes =>
    widget.herdr.panes(widget.workspace.workspaceId)
        .where((p) => p.tabId == _selectedTabId).toList();
HerdrPane? get _currentPane =>
    _tabPanes.isEmpty ? null : _tabPanes[_paneIndex.clamp(0, _tabPanes.length - 1)];
```

**边界处理**：
- tab 无 pane（`_tabPanes` 空）→ 内容区显示"该标签没有面板"，不崩。
- tab 列表为空（老 agent 不报 tab）→ 退化为"所有 pane 一组"，Tab 栏隐藏，
  chip 行显示全部 pane（用 pane 的 `tabId` 分组不安全，直接平铺）。

### 布局

```
Scaffold
 ├─ AppBar（标题=工作区 + 当前 pane）
 └─ Column
     ├─ _TabBar        ← 仅当 _tabs.length > 1
     ├─ _PaneChips     ← 仅当 _tabPanes.length > 1
     ├─ Expanded(PageView.builder)   ← 只有一个 pane 时仍用 PageView(1 页)
     └─ _inputBar      ← 操作的是 _currentPane
```

**PageView 与 chips 联动**：
- `PageController` 由 chips 点击驱动 `animateToPage`。
- `onPageChanged` 回写 `_paneIndex` 并记录 `_lastPaneOfTab[tabId]`。
- 切 tab 时 `jumpToPage` 到记忆的索引（用 `jump` 避免跨 tab 的滑动动画）。

**不动渲染层**：每页就是一个 `HerdrPaneViewport`，`outputKey` 带 paneId。

### 输入栏目标

`_send` / `_sendKey` / `_runCommand` / `_controls` 全部改用 `_currentPane`
而不是 `widget.pane`。这是本改动最容易出错的点——所有 `pane.xxx` 引用都要
经过 `_currentPane`，否则会操作错的 pane。

## §2 渲染：等比缩放模式

### 为什么加这个模式

现有两个模式满足不了用户：

| 模式 | 问题 |
| --- | --- |
| `fitWidth` | 按手机列数重排 → TUI 的绝对定位/边框被重排破坏 → **错位** |
| `rawColumns` | 保持 122 列 → 手机只能看左侧一截 → **截断** |

用户要求「不错位 **且** 不截断」。**唯一同时满足的做法是等比缩小整屏**：
保持桌面原始列宽（布局不变 → 不错位），把整个画布缩放到手机宽度
（全部可见 → 不截断）。

### 实现

新增 `HerdrViewportMode.scaledToFit`，用 `FittedBox` 缩放固定尺寸画布：

```dart
// 画布按桌面列数 × 行数渲染，不 reflow。
final canvasW = cols * char.width + padding;
final canvasH = rows * char.height + padding;
FittedBox(
  fit: BoxFit.contain,
  child: SizedBox(
    width: canvasW,
    height: canvasH,
    child: TerminalView(_terminal, readOnly: true, autoResize: false, ...),
  ),
)
```

- 列数取 `sourceColumns ?? _inferColumns(text)`（复用 `rawColumns` 的取值逻辑）。
- 行数 = 内容实际行数（保证整屏内容都在画布里，不被裁剪）。
- `BoxFit.contain` 等比缩放并居中；容器宽度固定为可用宽度，高度用
  `Expanded` 剩余空间。
- 用户可用双指缩放查看细节：外层包 `InteractiveViewer(minScale: 0.5, maxScale: 4)`。
  **注意**：`InteractiveViewer` 与 `PageView` 的手势会冲突 —— 见下。

### 手势冲突处理

`InteractiveViewer` 的平移会和 `PageView` 的横滑抢手势。解决：

- `InteractiveViewer(panEnabled: false)` —— 只在**双指缩放**时接管，
  单指横滑仍交给 `PageView`。
- 需要平移查看放大后的区域时，用缩放态下的双指拖动（`scaleEnabled` 自带）。

### 默认模式

`_viewMode` 默认从 `fitWidth` 改为 **`scaledToFit`**。三个模式都保留，
用户可在来源栏旁边的 chip 循环切换：

- `适应手机`（fitWidth）：reflow，字大，TUI 可能错位
- `整屏缩放`（scaledToFit，**默认**）：布局与电脑一致、无截断、字小可放大
- `原始列宽`（rawColumns）：原始尺寸 + 横向拖动

## 兼容性与风险

| 风险 | 处理 |
| --- | --- |
| 老 agent 不报 tab | 退化为单组平铺，Tab 栏隐藏 |
| tab 无 pane | 显示空态，不崩 |
| 操作发到错的 pane | 所有写操作经 `_currentPane`；`_currentPane == null` 时禁用 |
| 缩放后字太小 | `InteractiveViewer` 双指放大；也可切 `fitWidth` |
| PageView 与缩放抢手势 | `panEnabled: false` |
| 大量 pane 时 chips 溢出 | chips 行横向滚动，选中项自动 `ensureVisible` |

## 验证策略

Widget 测试：

1. 两个 tab → 显示 tab 行；点第二个 tab → chips 与内容切到该 tab 的 pane。
2. 同 tab 多个 pane → 点 chip → 当前 pane 变化；滑动 → chip 高亮跟随。
3. 单 tab → 不渲染 tab 行；单 pane → 不渲染 chip 行。
4. 从列表进入某 pane → 初始 tab/chip 选中态与之一致。
5. `scaledToFit` → 画布列数等于桌面列数（断言 `debugCols`），且
   `FittedBox` 存在。
6. 写操作作用于当前 pane（发消息后断言请求里的 `paneId` 是选中的那个）。

手工：真机打开真实工作区，切 tab / 点 chip / 左右滑 / 双指放大。

## 回滚

改动集中在 2 个文件，无协议与持久化变更，`git revert` 即回滚。
